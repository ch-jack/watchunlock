#include <windows.h>
// Copyright (c) 2026 JACK <2518926462@qq.com>

#include <credentialprovider.h>
#include <wincred.h>
#include <wincrypt.h>
#include <ntsecapi.h>
#include <strsafe.h>
#include <new>
#include <string>
#include <vector>

extern "C" IMAGE_DOS_HEADER __ImageBase;

// {B2B7A4C9-6170-4B34-8B95-A4B3E7BBEA6C}
static const CLSID CLSID_WatchUnlockProvider =
{ 0xb2b7a4c9, 0x6170, 0x4b34, { 0x8b, 0x95, 0xa4, 0xb3, 0xe7, 0xbb, 0xea, 0x6c } };

static const wchar_t* kProviderName = L"WatchUnlock";
static const wchar_t* kProviderGuidString = L"{B2B7A4C9-6170-4B34-8B95-A4B3E7BBEA6C}";
static const wchar_t* kDefaultConfigPath = L"C:\\ProgramData\\WatchUnlockCli\\config.json";
static const wchar_t* kDefaultStatePath = L"C:\\ProgramData\\WatchUnlockCli\\state.json";

static long g_dllRefCount = 0;
static std::wstring g_lastSubmittedToken;

static void SecureClearString(std::wstring& text)
{
    if (!text.empty())
    {
        SecureZeroMemory(&text[0], text.size() * sizeof(wchar_t));
        text.clear();
    }
}

enum FIELD_ID
{
    FI_LABEL = 0,
    FI_STATUS,
    FI_SUBMIT,
    FI_NUM_FIELDS
};

static HRESULT DupString(const wchar_t* value, wchar_t** out)
{
    if (!out)
    {
        return E_INVALIDARG;
    }
    *out = nullptr;
    if (!value)
    {
        value = L"";
    }

    const size_t chars = wcslen(value) + 1;
    wchar_t* copy = static_cast<wchar_t*>(CoTaskMemAlloc(chars * sizeof(wchar_t)));
    if (!copy)
    {
        return E_OUTOFMEMORY;
    }

    HRESULT hr = StringCchCopyW(copy, chars, value);
    if (FAILED(hr))
    {
        CoTaskMemFree(copy);
        return hr;
    }

    *out = copy;
    return S_OK;
}

static bool ReadTextFile(const std::wstring& path, std::wstring& text)
{
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
    {
        return false;
    }

    LARGE_INTEGER size = {};
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 || size.QuadPart > 1024 * 1024)
    {
        CloseHandle(file);
        return false;
    }

    std::vector<char> bytes(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    const BOOL ok = ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr);
    CloseHandle(file);
    if (!ok)
    {
        return false;
    }
    bytes.resize(read);

    if (bytes.size() >= 3 &&
        static_cast<unsigned char>(bytes[0]) == 0xEF &&
        static_cast<unsigned char>(bytes[1]) == 0xBB &&
        static_cast<unsigned char>(bytes[2]) == 0xBF)
    {
        bytes.erase(bytes.begin(), bytes.begin() + 3);
    }

    const int chars = MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), nullptr, 0);
    if (chars <= 0)
    {
        return false;
    }

    text.assign(static_cast<size_t>(chars), L'\0');
    return MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), &text[0], chars) > 0;
}

static bool WriteTextFile(const std::wstring& path, const std::wstring& text)
{
    const int bytesNeeded = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (bytesNeeded <= 1)
    {
        return false;
    }

    std::vector<char> bytes(static_cast<size_t>(bytesNeeded - 1));
    if (!WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, bytes.data(), bytesNeeded, nullptr, nullptr))
    {
        return false;
    }

    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
    {
        return false;
    }

    DWORD written = 0;
    const BOOL ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr);
    CloseHandle(file);
    return ok && written == bytes.size();
}

static bool JsonString(const std::wstring& json, const wchar_t* name, std::wstring& value)
{
    std::wstring key = L"\"";
    key += name;
    key += L"\"";

    size_t pos = json.find(key);
    if (pos == std::wstring::npos)
    {
        return false;
    }
    pos = json.find(L':', pos + key.size());
    if (pos == std::wstring::npos)
    {
        return false;
    }
    pos = json.find(L'"', pos + 1);
    if (pos == std::wstring::npos)
    {
        return false;
    }
    ++pos;

    std::wstring decoded;
    bool escaped = false;
    for (; pos < json.size(); ++pos)
    {
        wchar_t ch = json[pos];
        if (escaped)
        {
            switch (ch)
            {
            case L'"': decoded.push_back(L'"'); break;
            case L'\\': decoded.push_back(L'\\'); break;
            case L'/': decoded.push_back(L'/'); break;
            case L'b': decoded.push_back(L'\b'); break;
            case L'f': decoded.push_back(L'\f'); break;
            case L'n': decoded.push_back(L'\n'); break;
            case L'r': decoded.push_back(L'\r'); break;
            case L't': decoded.push_back(L'\t'); break;
            default: decoded.push_back(ch); break;
            }
            escaped = false;
            continue;
        }

        if (ch == L'\\')
        {
            escaped = true;
            continue;
        }
        if (ch == L'"')
        {
            value = decoded;
            return true;
        }
        decoded.push_back(ch);
    }

    return false;
}

static bool JsonInt64(const std::wstring& json, const wchar_t* name, long long& value)
{
    std::wstring key = L"\"";
    key += name;
    key += L"\"";

    size_t pos = json.find(key);
    if (pos == std::wstring::npos)
    {
        return false;
    }
    pos = json.find(L':', pos + key.size());
    if (pos == std::wstring::npos)
    {
        return false;
    }
    ++pos;
    while (pos < json.size() && iswspace(json[pos]))
    {
        ++pos;
    }

    wchar_t* end = nullptr;
    value = _wcstoi64(json.c_str() + pos, &end, 10);
    return end && end != json.c_str() + pos;
}

static bool Base64Decode(const std::wstring& value, std::vector<BYTE>& bytes)
{
    DWORD needed = 0;
    if (!CryptStringToBinaryW(value.c_str(), 0, CRYPT_STRING_BASE64, nullptr, &needed, nullptr, nullptr) || needed == 0)
    {
        return false;
    }

    bytes.resize(needed);
    return !!CryptStringToBinaryW(value.c_str(), 0, CRYPT_STRING_BASE64, bytes.data(), &needed, nullptr, nullptr);
}

static bool UnprotectMachineText(const std::wstring& protectedBase64, std::wstring& plainText)
{
    std::vector<BYTE> protectedBytes;
    if (!Base64Decode(protectedBase64, protectedBytes))
    {
        return false;
    }

    DATA_BLOB input = {};
    input.pbData = protectedBytes.data();
    input.cbData = static_cast<DWORD>(protectedBytes.size());

    DATA_BLOB output = {};
    if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, 0, &output))
    {
        return false;
    }

    if (output.cbData % sizeof(wchar_t) != 0)
    {
        LocalFree(output.pbData);
        return false;
    }

    plainText.assign(reinterpret_cast<wchar_t*>(output.pbData), output.cbData / sizeof(wchar_t));
    if (!plainText.empty() && plainText.back() == L'\0')
    {
        plainText.pop_back();
    }

    SecureZeroMemory(output.pbData, output.cbData);
    LocalFree(output.pbData);
    return true;
}

static long long UnixNow()
{
    FILETIME ft = {};
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER uli = {};
    uli.LowPart = ft.dwLowDateTime;
    uli.HighPart = ft.dwHighDateTime;
    return static_cast<long long>((uli.QuadPart - 116444736000000000ULL) / 10000000ULL);
}

static bool LoadConfig(std::wstring& username, std::wstring& password, std::wstring& statePath)
{
    std::wstring json;
    if (!ReadTextFile(kDefaultConfigPath, json))
    {
        return false;
    }

    std::wstring protectedPassword;
    if (!JsonString(json, L"username", username) ||
        !JsonString(json, L"passwordProtected", protectedPassword))
    {
        return false;
    }

    if (!JsonString(json, L"statePath", statePath) || statePath.empty())
    {
        statePath = kDefaultStatePath;
    }

    return UnprotectMachineText(protectedPassword, password);
}

static bool LoadUnlockState(const std::wstring& statePath, std::wstring& token)
{
    std::wstring json;
    if (!ReadTextFile(statePath, json))
    {
        return false;
    }

    long long allowUntil = 0;
    if (!JsonInt64(json, L"allowUnlockUntil", allowUntil) ||
        !JsonString(json, L"unlockToken", token) ||
        token.empty())
    {
        return false;
    }

    return allowUntil >= UnixNow() && token != g_lastSubmittedToken;
}

static bool CanAutoUnlock(std::wstring* tokenOut = nullptr)
{
    std::wstring username;
    std::wstring password;
    std::wstring statePath;
    if (!LoadConfig(username, password, statePath))
    {
        return false;
    }

    std::wstring token;
    if (!LoadUnlockState(statePath, token))
    {
        SecureClearString(password);
        return false;
    }

    if (tokenOut)
    {
        *tokenOut = token;
    }
    SecureClearString(password);
    return true;
}

static HRESULT GetAuthenticationPackage(ULONG* package)
{
    if (!package)
    {
        return E_INVALIDARG;
    }

    HANDLE lsa = nullptr;
    NTSTATUS status = LsaConnectUntrusted(&lsa);
    if (status < 0)
    {
        return HRESULT_FROM_NT(status);
    }

    LSA_STRING name = {};
    const char packageName[] = "Negotiate";
    name.Buffer = const_cast<PCHAR>(packageName);
    name.Length = sizeof(packageName) - 1;
    name.MaximumLength = sizeof(packageName);

    status = LsaLookupAuthenticationPackage(lsa, &name, package);
    LsaDeregisterLogonProcess(lsa);
    return HRESULT_FROM_NT(status);
}

static HRESULT PackCredentials(CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* serialization, std::wstring& token)
{
    if (!serialization)
    {
        return E_INVALIDARG;
    }

    ZeroMemory(serialization, sizeof(*serialization));

    std::wstring username;
    std::wstring password;
    std::wstring statePath;
    if (!LoadConfig(username, password, statePath))
    {
        return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    }

    if (!LoadUnlockState(statePath, token))
    {
        SecureClearString(password);
        return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    }

    ULONG authPackage = 0;
    HRESULT hr = GetAuthenticationPackage(&authPackage);
    if (FAILED(hr))
    {
        SecureClearString(password);
        return hr;
    }

    DWORD packedSize = 0;
    CredPackAuthenticationBufferW(0, &username[0], &password[0], nullptr, &packedSize);
    if (packedSize == 0)
    {
        SecureClearString(password);
        return HRESULT_FROM_WIN32(GetLastError());
    }

    BYTE* packed = static_cast<BYTE*>(CoTaskMemAlloc(packedSize));
    if (!packed)
    {
        SecureClearString(password);
        return E_OUTOFMEMORY;
    }

    if (!CredPackAuthenticationBufferW(0, &username[0], &password[0], packed, &packedSize))
    {
        hr = HRESULT_FROM_WIN32(GetLastError());
        CoTaskMemFree(packed);
        SecureClearString(password);
        return hr;
    }

    serialization->ulAuthenticationPackage = authPackage;
    serialization->clsidCredentialProvider = CLSID_WatchUnlockProvider;
    serialization->cbSerialization = packedSize;
    serialization->rgbSerialization = packed;

    SecureClearString(password);
    return S_OK;
}

class WatchUnlockCredential : public ICredentialProviderCredential
{
public:
    WatchUnlockCredential() : _ref(1)
    {
        InterlockedIncrement(&g_dllRefCount);
    }

    ~WatchUnlockCredential()
    {
        InterlockedDecrement(&g_dllRefCount);
    }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (!ppv)
        {
            return E_INVALIDARG;
        }
        *ppv = nullptr;
        if (riid == IID_IUnknown || riid == IID_ICredentialProviderCredential)
        {
            *ppv = static_cast<ICredentialProviderCredential*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef()
    {
        return InterlockedIncrement(&_ref);
    }

    IFACEMETHODIMP_(ULONG) Release()
    {
        const ULONG ref = InterlockedDecrement(&_ref);
        if (!ref)
        {
            delete this;
        }
        return ref;
    }

    IFACEMETHODIMP Advise(ICredentialProviderCredentialEvents*) { return S_OK; }
    IFACEMETHODIMP UnAdvise() { return S_OK; }

    IFACEMETHODIMP SetSelected(BOOL* autoLogon)
    {
        if (autoLogon)
        {
            *autoLogon = CanAutoUnlock() ? TRUE : FALSE;
        }
        return S_OK;
    }

    IFACEMETHODIMP SetDeselected() { return S_OK; }

    IFACEMETHODIMP GetFieldState(DWORD fieldId, CREDENTIAL_PROVIDER_FIELD_STATE* state, CREDENTIAL_PROVIDER_FIELD_INTERACTIVE_STATE* interactiveState)
    {
        if (!state || !interactiveState)
        {
            return E_INVALIDARG;
        }
        if (fieldId >= FI_NUM_FIELDS)
        {
            return E_INVALIDARG;
        }

        *state = CPFS_DISPLAY_IN_SELECTED_TILE;
        *interactiveState = CPFIS_NONE;
        if (fieldId == FI_SUBMIT)
        {
            *interactiveState = CPFIS_FOCUSED;
        }
        return S_OK;
    }

    IFACEMETHODIMP GetStringValue(DWORD fieldId, wchar_t** value)
    {
        if (fieldId == FI_LABEL)
        {
            return DupString(L"WatchUnlock", value);
        }
        if (fieldId == FI_STATUS)
        {
            return DupString(CanAutoUnlock() ? L"Trusted device nearby. Unlocking..." : L"Waiting for trusted BLE device.", value);
        }
        return DupString(L"", value);
    }

    IFACEMETHODIMP GetBitmapValue(DWORD, HBITMAP*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetCheckboxValue(DWORD, BOOL*, wchar_t**) { return E_NOTIMPL; }
    IFACEMETHODIMP GetSubmitButtonValue(DWORD fieldId, DWORD* adjacentTo)
    {
        if (!adjacentTo || fieldId != FI_SUBMIT)
        {
            return E_INVALIDARG;
        }
        *adjacentTo = FI_STATUS;
        return S_OK;
    }
    IFACEMETHODIMP GetComboBoxValueCount(DWORD, DWORD*, DWORD*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetComboBoxValueAt(DWORD, DWORD, wchar_t**) { return E_NOTIMPL; }
    IFACEMETHODIMP SetStringValue(DWORD, const wchar_t*) { return E_NOTIMPL; }
    IFACEMETHODIMP SetCheckboxValue(DWORD, BOOL) { return E_NOTIMPL; }
    IFACEMETHODIMP SetComboBoxSelectedValue(DWORD, DWORD) { return E_NOTIMPL; }
    IFACEMETHODIMP CommandLinkClicked(DWORD) { return E_NOTIMPL; }

    IFACEMETHODIMP GetSerialization(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* response,
                                    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* serialization,
                                    wchar_t** statusText,
                                    CREDENTIAL_PROVIDER_STATUS_ICON* statusIcon)
    {
        if (!response || !serialization || !statusText || !statusIcon)
        {
            return E_INVALIDARG;
        }

        *response = CPGSR_NO_CREDENTIAL_NOT_FINISHED;
        *statusText = nullptr;
        *statusIcon = CPSI_NONE;

        std::wstring token;
        HRESULT hr = PackCredentials(serialization, token);
        if (SUCCEEDED(hr))
        {
            g_lastSubmittedToken = token;
            *response = CPGSR_RETURN_CREDENTIAL_FINISHED;
            return S_OK;
        }

        DupString(L"Trusted device is not nearby, or the unlock window expired.", statusText);
        *statusIcon = CPSI_ERROR;
        return S_OK;
    }

    IFACEMETHODIMP ReportResult(NTSTATUS, NTSTATUS, wchar_t** statusText, CREDENTIAL_PROVIDER_STATUS_ICON* statusIcon)
    {
        if (statusText)
        {
            *statusText = nullptr;
        }
        if (statusIcon)
        {
            *statusIcon = CPSI_NONE;
        }
        return S_OK;
    }

private:
    long _ref;
};

class WatchUnlockProvider : public ICredentialProvider
{
public:
    WatchUnlockProvider() : _ref(1), _usage(CPUS_INVALID), _events(nullptr), _adviseContext(0), _stopEvent(nullptr), _thread(nullptr)
    {
        InterlockedIncrement(&g_dllRefCount);
    }

    ~WatchUnlockProvider()
    {
        StopWatcher();
        if (_events)
        {
            _events->Release();
        }
        InterlockedDecrement(&g_dllRefCount);
    }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (!ppv)
        {
            return E_INVALIDARG;
        }
        *ppv = nullptr;
        if (riid == IID_IUnknown || riid == IID_ICredentialProvider)
        {
            *ppv = static_cast<ICredentialProvider*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef()
    {
        return InterlockedIncrement(&_ref);
    }

    IFACEMETHODIMP_(ULONG) Release()
    {
        const ULONG ref = InterlockedDecrement(&_ref);
        if (!ref)
        {
            delete this;
        }
        return ref;
    }

    IFACEMETHODIMP SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO usage, DWORD)
    {
        _usage = usage;
        if (usage == CPUS_LOGON || usage == CPUS_UNLOCK_WORKSTATION)
        {
            return S_OK;
        }
        return E_NOTIMPL;
    }

    IFACEMETHODIMP SetSerialization(const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION*) { return E_NOTIMPL; }

    IFACEMETHODIMP Advise(ICredentialProviderEvents* events, UINT_PTR context)
    {
        if (_events)
        {
            _events->Release();
            _events = nullptr;
        }
        _adviseContext = context;
        if (events)
        {
            _events = events;
            _events->AddRef();
        }
        StartWatcher();
        return S_OK;
    }

    IFACEMETHODIMP UnAdvise()
    {
        StopWatcher();
        if (_events)
        {
            _events->Release();
            _events = nullptr;
        }
        _adviseContext = 0;
        return S_OK;
    }

    IFACEMETHODIMP GetFieldDescriptorCount(DWORD* count)
    {
        if (!count)
        {
            return E_INVALIDARG;
        }
        *count = FI_NUM_FIELDS;
        return S_OK;
    }

    IFACEMETHODIMP GetFieldDescriptorAt(DWORD fieldId, CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** descriptor)
    {
        if (!descriptor || fieldId >= FI_NUM_FIELDS)
        {
            return E_INVALIDARG;
        }
        *descriptor = static_cast<CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR*>(CoTaskMemAlloc(sizeof(CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR)));
        if (!*descriptor)
        {
            return E_OUTOFMEMORY;
        }
        ZeroMemory(*descriptor, sizeof(CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR));
        (*descriptor)->dwFieldID = fieldId;
        (*descriptor)->guidFieldType = GUID_NULL;

        if (fieldId == FI_LABEL)
        {
            (*descriptor)->cpft = CPFT_LARGE_TEXT;
            return DupString(L"WatchUnlock", &(*descriptor)->pszLabel);
        }
        if (fieldId == FI_STATUS)
        {
            (*descriptor)->cpft = CPFT_SMALL_TEXT;
            return DupString(L"Status", &(*descriptor)->pszLabel);
        }

        (*descriptor)->cpft = CPFT_SUBMIT_BUTTON;
        return DupString(L"Unlock", &(*descriptor)->pszLabel);
    }

    IFACEMETHODIMP GetCredentialCount(DWORD* count, DWORD* defaultCredential, BOOL* autoLogonWithDefault)
    {
        if (!count || !defaultCredential || !autoLogonWithDefault)
        {
            return E_INVALIDARG;
        }

        *count = 1;
        *defaultCredential = 0;
        *autoLogonWithDefault = CanAutoUnlock() ? TRUE : FALSE;
        return S_OK;
    }

    IFACEMETHODIMP GetCredentialAt(DWORD index, ICredentialProviderCredential** credential)
    {
        if (!credential || index != 0)
        {
            return E_INVALIDARG;
        }
        *credential = new (std::nothrow) WatchUnlockCredential();
        return *credential ? S_OK : E_OUTOFMEMORY;
    }

private:
    static DWORD WINAPI WatchThreadProc(void* param)
    {
        static_cast<WatchUnlockProvider*>(param)->WatchLoop();
        return 0;
    }

    void StartWatcher()
    {
        if (_thread)
        {
            return;
        }
        _stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!_stopEvent)
        {
            return;
        }
        _thread = CreateThread(nullptr, 0, WatchThreadProc, this, 0, nullptr);
    }

    void StopWatcher()
    {
        if (_stopEvent)
        {
            SetEvent(_stopEvent);
        }
        if (_thread)
        {
            WaitForSingleObject(_thread, 3000);
            CloseHandle(_thread);
            _thread = nullptr;
        }
        if (_stopEvent)
        {
            CloseHandle(_stopEvent);
            _stopEvent = nullptr;
        }
    }

    void WatchLoop()
    {
        bool wasAllowed = CanAutoUnlock();
        while (_stopEvent && WaitForSingleObject(_stopEvent, 1000) == WAIT_TIMEOUT)
        {
            const bool allowed = CanAutoUnlock();
            if (allowed && !wasAllowed && _events)
            {
                _events->CredentialsChanged(_adviseContext);
            }
            wasAllowed = allowed;
        }
    }

    long _ref;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO _usage;
    ICredentialProviderEvents* _events;
    UINT_PTR _adviseContext;
    HANDLE _stopEvent;
    HANDLE _thread;
};

class ClassFactory : public IClassFactory
{
public:
    ClassFactory() : _ref(1)
    {
        InterlockedIncrement(&g_dllRefCount);
    }

    ~ClassFactory()
    {
        InterlockedDecrement(&g_dllRefCount);
    }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (!ppv)
        {
            return E_INVALIDARG;
        }
        *ppv = nullptr;
        if (riid == IID_IUnknown || riid == IID_IClassFactory)
        {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef()
    {
        return InterlockedIncrement(&_ref);
    }

    IFACEMETHODIMP_(ULONG) Release()
    {
        const ULONG ref = InterlockedDecrement(&_ref);
        if (!ref)
        {
            delete this;
        }
        return ref;
    }

    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv)
    {
        if (outer)
        {
            return CLASS_E_NOAGGREGATION;
        }
        WatchUnlockProvider* provider = new (std::nothrow) WatchUnlockProvider();
        if (!provider)
        {
            return E_OUTOFMEMORY;
        }
        HRESULT hr = provider->QueryInterface(riid, ppv);
        provider->Release();
        return hr;
    }

    IFACEMETHODIMP LockServer(BOOL lock)
    {
        if (lock)
        {
            InterlockedIncrement(&g_dllRefCount);
        }
        else
        {
            InterlockedDecrement(&g_dllRefCount);
        }
        return S_OK;
    }

private:
    long _ref;
};

static HRESULT SetRegistryString(HKEY root, const std::wstring& path, const wchar_t* name, const std::wstring& value)
{
    HKEY key = nullptr;
    LONG result = RegCreateKeyExW(root, path.c_str(), 0, nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key, nullptr);
    if (result != ERROR_SUCCESS)
    {
        return HRESULT_FROM_WIN32(result);
    }

    result = RegSetValueExW(key, name, 0, REG_SZ,
                            reinterpret_cast<const BYTE*>(value.c_str()),
                            static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    return HRESULT_FROM_WIN32(result);
}

STDAPI DllCanUnloadNow()
{
    return g_dllRefCount == 0 ? S_OK : S_FALSE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv)
{
    if (clsid != CLSID_WatchUnlockProvider)
    {
        return CLASS_E_CLASSNOTAVAILABLE;
    }

    ClassFactory* factory = new (std::nothrow) ClassFactory();
    if (!factory)
    {
        return E_OUTOFMEMORY;
    }
    HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

STDAPI DllRegisterServer()
{
    wchar_t modulePath[MAX_PATH] = {};
    if (!GetModuleFileNameW(reinterpret_cast<HMODULE>(&__ImageBase), modulePath, ARRAYSIZE(modulePath)))
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    std::wstring clsidPath = L"SOFTWARE\\Classes\\CLSID\\";
    clsidPath += kProviderGuidString;

    HRESULT hr = SetRegistryString(HKEY_LOCAL_MACHINE, clsidPath, nullptr, kProviderName);
    if (FAILED(hr)) return hr;

    hr = SetRegistryString(HKEY_LOCAL_MACHINE, clsidPath + L"\\InprocServer32", nullptr, modulePath);
    if (FAILED(hr)) return hr;

    hr = SetRegistryString(HKEY_LOCAL_MACHINE, clsidPath + L"\\InprocServer32", L"ThreadingModel", L"Apartment");
    if (FAILED(hr)) return hr;

    std::wstring providerPath = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Authentication\\Credential Providers\\";
    providerPath += kProviderGuidString;

    return SetRegistryString(HKEY_LOCAL_MACHINE, providerPath, nullptr, kProviderName);
}

STDAPI DllUnregisterServer()
{
    std::wstring providerPath = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Authentication\\Credential Providers\\";
    providerPath += kProviderGuidString;
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, providerPath.c_str());

    std::wstring clsidPath = L"SOFTWARE\\Classes\\CLSID\\";
    clsidPath += kProviderGuidString;
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, clsidPath.c_str());
    return S_OK;
}
