#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
// Copyright (c) 2026 JACK <2518926462@qq.com>

#include <bcrypt.h>
#include <objbase.h>
#include <shellapi.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cwctype>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "windowsapp.lib")

using namespace winrt;
using namespace Windows::Devices::Bluetooth::Advertisement;

static const wchar_t* kDefaultConfigPath = L"C:\\ProgramData\\WatchUnlockCli\\config.json";
static const wchar_t* kDefaultStatePath = L"C:\\ProgramData\\WatchUnlockCli\\state.json";

static std::atomic_bool g_stop{ false };

struct Options
{
    std::wstring command = L"monitor";
    std::map<std::wstring, std::wstring> values;
};

struct Settings
{
    std::wstring configPath = kDefaultConfigPath;
    std::wstring statePath = kDefaultStatePath;
    std::wstring signalStatePath = kDefaultStatePath;
    std::wstring logFile;
    std::wstring irkHex;
    std::vector<unsigned char> irk;
    int nearRssi = -70;
    int awayRssi = -86;
    int awaySeconds = 30;
    int nearHitsRequired = 2;
    int unlockWindowSeconds = 30;
    bool lockOnAway = false;
    bool credentialProviderEnabled = false;
    bool active = true;
    bool once = false;
    std::wstring onNear;
    std::wstring onAway;
};

struct RuntimeState
{
    std::wstring state = L"unknown";
    int nearHits = 0;
    std::optional<std::chrono::steady_clock::time_point> lastPresentAt;
    std::optional<int> bestRssi;
    std::wstring lastAddress;
    bool hasBeenNear = false;
};

struct ScanRecord
{
    std::wstring timestamp;
    std::wstring address;
    int rssi = 0;
    std::wstring name;
    std::vector<std::wstring> services;
    std::vector<std::wstring> manufacturer;
};

static std::wstring IsoNow();

static std::wstring ToLower(std::wstring value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
        return static_cast<wchar_t>(std::towlower(ch));
    });
    return value;
}

static std::wstring NormalizeKey(std::wstring key)
{
    while (!key.empty() && key[0] == L'-')
    {
        key.erase(key.begin());
    }
    key = ToLower(key);
    key.erase(std::remove(key.begin(), key.end(), L'-'), key.end());
    return key;
}

static bool IsOptionToken(const wchar_t* text)
{
    if (!text || text[0] != L'-' || text[1] == L'\0')
    {
        return false;
    }
    return std::iswalpha(text[1]) || text[1] == L'-';
}

static Options ParseOptions(int argc, wchar_t** argv)
{
    Options parsed;
    int index = 1;
    if (argc > 1 && !IsOptionToken(argv[1]))
    {
        parsed.command = ToLower(argv[1]);
        index = 2;
    }

    for (int i = index; i < argc; ++i)
    {
        if (!IsOptionToken(argv[i]))
        {
            continue;
        }

        std::wstring key = NormalizeKey(argv[i]);
        std::wstring value = L"true";
        if (i + 1 < argc && !IsOptionToken(argv[i + 1]))
        {
            value = argv[++i];
        }
        parsed.values[key] = value;
    }
    return parsed;
}

static std::wstring OptionString(const Options& options, std::initializer_list<const wchar_t*> keys, const std::wstring& fallback)
{
    for (const wchar_t* key : keys)
    {
        auto found = options.values.find(NormalizeKey(key));
        if (found != options.values.end() && found->second != L"true")
        {
            return found->second;
        }
    }
    return fallback;
}

static int OptionInt(const Options& options, std::initializer_list<const wchar_t*> keys, int fallback)
{
    const std::wstring value = OptionString(options, keys, L"");
    if (value.empty())
    {
        return fallback;
    }
    return _wtoi(value.c_str());
}

static bool ParseBoolText(const std::wstring& value, bool fallback)
{
    if (value.empty())
    {
        return fallback;
    }
    const std::wstring lower = ToLower(value);
    if (lower == L"1" || lower == L"true" || lower == L"yes" || lower == L"y" || lower == L"on")
    {
        return true;
    }
    if (lower == L"0" || lower == L"false" || lower == L"no" || lower == L"n" || lower == L"off")
    {
        return false;
    }
    return fallback;
}

static bool OptionBool(const Options& options, std::initializer_list<const wchar_t*> keys, bool fallback)
{
    for (const wchar_t* key : keys)
    {
        auto found = options.values.find(NormalizeKey(key));
        if (found != options.values.end())
        {
            return ParseBoolText(found->second, true);
        }
    }
    return fallback;
}

static bool EnsureParentFolder(const std::wstring& path)
{
    try
    {
        const std::filesystem::path folder = std::filesystem::path(path).parent_path();
        if (!folder.empty())
        {
            std::filesystem::create_directories(folder);
        }
        return true;
    }
    catch (...)
    {
        return false;
    }
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
    EnsureParentFolder(path);
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

    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, CREATE_ALWAYS,
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

static bool AppendTextFile(const std::wstring& path, const std::wstring& text)
{
    if (path.empty())
    {
        return true;
    }

    EnsureParentFolder(path);
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

    HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
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

static std::wstring JsonEscape(const std::wstring& value)
{
    std::wstring escaped;
    for (wchar_t ch : value)
    {
        switch (ch)
        {
        case L'"': escaped += L"\\\""; break;
        case L'\\': escaped += L"\\\\"; break;
        case L'\b': escaped += L"\\b"; break;
        case L'\f': escaped += L"\\f"; break;
        case L'\n': escaped += L"\\n"; break;
        case L'\r': escaped += L"\\r"; break;
        case L'\t': escaped += L"\\t"; break;
        default:
            escaped.push_back(ch);
            break;
        }
    }
    return escaped;
}

static void WriteJsonStringArray(std::wstringstream& json, const std::vector<std::wstring>& values)
{
    json << L"[";
    for (size_t i = 0; i < values.size(); ++i)
    {
        if (i != 0)
        {
            json << L",";
        }
        json << L"\"" << JsonEscape(values[i]) << L"\"";
    }
    json << L"]";
}

static std::wstring ScanRecordsToJson(const std::vector<ScanRecord>& records, bool includeMatch)
{
    std::wstringstream json;
    json << L"[\n";
    for (size_t i = 0; i < records.size(); ++i)
    {
        const ScanRecord& record = records[i];
        if (i != 0)
        {
            json << L",\n";
        }
        json << L"  {\n"
             << L"    \"timestamp\": \"" << JsonEscape(record.timestamp) << L"\",\n"
             << L"    \"address\": \"" << JsonEscape(record.address) << L"\",\n"
             << L"    \"addressType\": \"\",\n"
             << L"    \"rssi\": " << record.rssi << L",\n"
             << L"    \"name\": \"" << JsonEscape(record.name) << L"\",\n"
             << L"    \"services\": ";
        WriteJsonStringArray(json, record.services);
        json << L",\n"
             << L"    \"manufacturer\": ";
        WriteJsonStringArray(json, record.manufacturer);
        if (includeMatch)
        {
            json << L",\n"
                 << L"    \"match\": { \"layout\": \"native\", \"keyOrder\": \"auto\" }";
        }
        json << L"\n  }";
    }
    json << L"\n]\n";
    return json.str();
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

static bool JsonInt(const std::wstring& json, const wchar_t* name, int& value)
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
    while (pos < json.size() && std::iswspace(json[pos]))
    {
        ++pos;
    }

    wchar_t* end = nullptr;
    const long parsed = wcstol(json.c_str() + pos, &end, 10);
    if (!end || end == json.c_str() + pos)
    {
        return false;
    }
    value = static_cast<int>(parsed);
    return true;
}

static bool JsonBool(const std::wstring& json, const wchar_t* name, bool& value)
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
    while (pos < json.size() && std::iswspace(json[pos]))
    {
        ++pos;
    }

    if (json.compare(pos, 4, L"true") == 0)
    {
        value = true;
        return true;
    }
    if (json.compare(pos, 5, L"false") == 0)
    {
        value = false;
        return true;
    }
    return false;
}

static std::wstring CleanHex(const std::wstring& value)
{
    std::wstring hex;
    for (wchar_t ch : value)
    {
        if (std::iswxdigit(ch))
        {
            hex.push_back(static_cast<wchar_t>(std::towupper(ch)));
        }
    }
    return hex;
}

static bool HexToBytes(const std::wstring& hexText, size_t expectedBytes, std::vector<unsigned char>& bytes)
{
    const std::wstring hex = CleanHex(hexText);
    if (hex.size() != expectedBytes * 2)
    {
        return false;
    }

    bytes.clear();
    bytes.reserve(expectedBytes);
    for (size_t i = 0; i < hex.size(); i += 2)
    {
        wchar_t pair[3] = { hex[i], hex[i + 1], L'\0' };
        bytes.push_back(static_cast<unsigned char>(wcstoul(pair, nullptr, 16)));
    }
    return true;
}

static std::wstring BytesToHex(const std::vector<unsigned char>& bytes)
{
    std::wstringstream stream;
    stream << std::uppercase << std::hex << std::setfill(L'0');
    for (unsigned char byte : bytes)
    {
        stream << std::setw(2) << static_cast<int>(byte);
    }
    return stream.str();
}

static std::vector<unsigned char> ReverseBytes(std::vector<unsigned char> bytes)
{
    std::reverse(bytes.begin(), bytes.end());
    return bytes;
}

static std::vector<unsigned char> SubBytes(const std::vector<unsigned char>& bytes, size_t start, size_t length)
{
    if (start >= bytes.size())
    {
        return {};
    }
    const size_t end = std::min(bytes.size(), start + length);
    return std::vector<unsigned char>(bytes.begin() + start, bytes.begin() + end);
}

static std::vector<unsigned char> JoinBytes(const std::vector<unsigned char>& left, const std::vector<unsigned char>& right)
{
    std::vector<unsigned char> bytes = left;
    bytes.insert(bytes.end(), right.begin(), right.end());
    return bytes;
}

static std::vector<unsigned char> ZeroBytes(size_t length)
{
    return std::vector<unsigned char>(length, 0);
}

static bool AesEncryptBlock(const std::vector<unsigned char>& key, const std::vector<unsigned char>& block, std::vector<unsigned char>& encrypted)
{
    if (key.size() != 16 || block.size() != 16)
    {
        return false;
    }

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_KEY_HANDLE keyHandle = nullptr;
    bool ok = false;

    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_AES_ALGORITHM, nullptr, 0) != 0)
    {
        return false;
    }

    const wchar_t chainingMode[] = BCRYPT_CHAIN_MODE_ECB;
    if (BCryptSetProperty(algorithm, BCRYPT_CHAINING_MODE,
                          reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(chainingMode)),
                          static_cast<ULONG>(sizeof(chainingMode)), 0) != 0)
    {
        BCryptCloseAlgorithmProvider(algorithm, 0);
        return false;
    }

    DWORD objectLength = 0;
    DWORD resultLength = 0;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&objectLength),
                          sizeof(objectLength), &resultLength, 0) == 0)
    {
        std::vector<unsigned char> keyObject(objectLength);
        if (BCryptGenerateSymmetricKey(algorithm, &keyHandle, keyObject.data(), objectLength,
                                       const_cast<PUCHAR>(key.data()), static_cast<ULONG>(key.size()), 0) == 0)
        {
            encrypted.assign(16, 0);
            DWORD encryptedLength = 0;
            ok = BCryptEncrypt(keyHandle, const_cast<PUCHAR>(block.data()), static_cast<ULONG>(block.size()),
                               nullptr, nullptr, 0, encrypted.data(), static_cast<ULONG>(encrypted.size()),
                               &encryptedLength, 0) == 0 && encryptedLength == encrypted.size();
            BCryptDestroyKey(keyHandle);
        }
    }

    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

static bool SameBytes(const std::vector<unsigned char>& left, const std::vector<unsigned char>& right)
{
    return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin());
}

static bool ResolveRpaAddress(const std::vector<unsigned char>& address, const std::vector<unsigned char>& irk)
{
    if (address.size() != 6 || irk.size() != 16)
    {
        return false;
    }

    const std::vector<std::vector<unsigned char>> keys = { irk, ReverseBytes(irk) };
    const std::vector<std::vector<unsigned char>> addresses = { address, ReverseBytes(address) };

    for (const auto& addr : addresses)
    {
        struct Layout
        {
            std::vector<unsigned char> prand;
            std::vector<unsigned char> hash;
            size_t markerIndex;
        };

        const std::vector<Layout> layouts = {
            { SubBytes(addr, 3, 3), SubBytes(addr, 0, 3), 3 },
            { SubBytes(addr, 0, 3), SubBytes(addr, 3, 3), 0 },
        };

        for (const auto& layout : layouts)
        {
            if (layout.prand.size() != 3 || layout.hash.size() != 3 || (addr[layout.markerIndex] & 0xC0) != 0x40)
            {
                continue;
            }

            const std::vector<std::vector<unsigned char>> prands = { layout.prand, ReverseBytes(layout.prand) };
            const std::vector<std::vector<unsigned char>> observedHashes = { layout.hash, ReverseBytes(layout.hash) };
            for (const auto& key : keys)
            {
                for (const auto& prand : prands)
                {
                    const std::vector<std::vector<unsigned char>> blocks = {
                        JoinBytes(ZeroBytes(13), prand),
                        JoinBytes(prand, ZeroBytes(13)),
                    };

                    for (const auto& block : blocks)
                    {
                        std::vector<unsigned char> encrypted;
                        if (!AesEncryptBlock(key, block, encrypted))
                        {
                            continue;
                        }

                        const std::vector<std::vector<unsigned char>> hashes = {
                            SubBytes(encrypted, 13, 3),
                            ReverseBytes(SubBytes(encrypted, 13, 3)),
                            SubBytes(encrypted, 0, 3),
                            ReverseBytes(SubBytes(encrypted, 0, 3)),
                        };

                        for (const auto& candidateHash : hashes)
                        {
                            for (const auto& observedHash : observedHashes)
                            {
                                if (SameBytes(candidateHash, observedHash))
                                {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return false;
}

static std::wstring FormatAddress(uint64_t value)
{
    std::wstringstream stream;
    stream << std::uppercase << std::hex << std::setfill(L'0');
    for (int i = 5; i >= 0; --i)
    {
        if (i != 5)
        {
            stream << L":";
        }
        stream << std::setw(2) << static_cast<int>((value >> (i * 8)) & 0xFF);
    }
    return stream.str();
}

static std::vector<unsigned char> AddressToBytes(uint64_t value)
{
    std::vector<unsigned char> bytes;
    bytes.reserve(6);
    for (int i = 5; i >= 0; --i)
    {
        bytes.push_back(static_cast<unsigned char>((value >> (i * 8)) & 0xFF));
    }
    return bytes;
}

static ScanRecord MakeScanRecord(const BluetoothLEAdvertisementReceivedEventArgs& args)
{
    ScanRecord record;
    record.timestamp = IsoNow();
    record.address = FormatAddress(args.BluetoothAddress());
    record.rssi = args.RawSignalStrengthInDBm();
    record.name = args.Advertisement().LocalName().c_str();

    try
    {
        for (const auto& uuid : args.Advertisement().ServiceUuids())
        {
            record.services.push_back(winrt::to_hstring(uuid).c_str());
        }
    }
    catch (...)
    {
    }

    try
    {
        for (const auto& item : args.Advertisement().ManufacturerData())
        {
            std::vector<unsigned char> bytes(item.Data().Length());
            if (!bytes.empty())
            {
                Windows::Storage::Streams::DataReader::FromBuffer(item.Data()).ReadBytes(bytes);
            }
            std::wstringstream manufacturer;
            manufacturer << std::uppercase << std::hex << std::setfill(L'0')
                         << std::setw(4) << static_cast<int>(item.CompanyId())
                         << L":" << BytesToHex(bytes);
            record.manufacturer.push_back(manufacturer.str());
        }
    }
    catch (...)
    {
    }

    return record;
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

static std::wstring IsoNow()
{
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    wchar_t buffer[64] = {};
    swprintf_s(buffer, L"%04u-%02u-%02uT%02u:%02u:%02u.%03u",
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    return buffer;
}

static std::wstring LogTimestamp()
{
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    wchar_t buffer[32] = {};
    swprintf_s(buffer, L"%04u-%02u-%02u %02u:%02u:%02u",
               st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    return buffer;
}

static void LogLine(const Settings& settings, const std::wstring& level, const std::wstring& message)
{
    const std::wstring line = L"[" + LogTimestamp() + L"][" + level + L"] " + message + L"\r\n";
    std::wcout << line;
    AppendTextFile(settings.logFile, line);
}

static std::wstring NewToken()
{
    GUID guid = {};
    if (CoCreateGuid(&guid) != S_OK)
    {
        return std::to_wstring(UnixNow());
    }
    wchar_t buffer[33] = {};
    swprintf_s(buffer, L"%08x%04x%04x%02x%02x%02x%02x%02x%02x%02x%02x",
               guid.Data1, guid.Data2, guid.Data3,
               guid.Data4[0], guid.Data4[1], guid.Data4[2], guid.Data4[3],
               guid.Data4[4], guid.Data4[5], guid.Data4[6], guid.Data4[7]);
    return buffer;
}

static bool WriteProviderUnlockState(const std::wstring& statePath, int unlockWindowSeconds, const std::wstring& address, int rssi)
{
    const long long now = UnixNow();
    std::wstringstream json;
    json << L"{\n"
         << L"  \"allowUnlockUntil\": " << (now + unlockWindowSeconds) << L",\n"
         << L"  \"unlockToken\": \"" << JsonEscape(NewToken()) << L"\",\n"
         << L"  \"lastNearAt\": " << now << L",\n"
         << L"  \"address\": \"" << JsonEscape(address) << L"\",\n"
         << L"  \"rssi\": " << rssi << L"\n"
         << L"}\n";
    return WriteTextFile(statePath, json.str());
}

static bool ClearProviderUnlockState(const std::wstring& statePath)
{
    return WriteTextFile(statePath, L"{\n  \"allowUnlockUntil\": 0,\n  \"unlockToken\": \"\",\n  \"lastNearAt\": 0\n}\n");
}

static bool WriteMonitorSignalState(const std::wstring& statePath, const std::wstring& address, int rssi, int bestRssi,
                                    const std::wstring& presence, int nearHits)
{
    const long long now = UnixNow();
    std::wstringstream json;
    json << L"{\n"
         << L"  \"allowUnlockUntil\": 0,\n"
         << L"  \"unlockToken\": \"\",\n"
         << L"  \"lastNearAt\": 0,\n"
         << L"  \"lastSeenAt\": " << now << L",\n"
         << L"  \"lastSeenIso\": \"" << JsonEscape(IsoNow()) << L"\",\n"
         << L"  \"address\": \"" << JsonEscape(address) << L"\",\n"
         << L"  \"rssi\": " << rssi << L",\n"
         << L"  \"bestRssi\": " << bestRssi << L",\n"
         << L"  \"presence\": \"" << JsonEscape(presence) << L"\",\n"
         << L"  \"nearHits\": " << nearHits << L"\n"
         << L"}\n";
    return WriteTextFile(statePath, json.str());
}

static void StartUserCommand(const std::wstring& command)
{
    if (command.empty())
    {
        return;
    }

    std::wstring escaped;
    for (wchar_t ch : command)
    {
        if (ch == L'"')
        {
            escaped += L"\\\"";
        }
        else
        {
            escaped.push_back(ch);
        }
    }

    std::wstring args = L"-NoProfile -ExecutionPolicy Bypass -Command \"" + escaped + L"\"";
    ShellExecuteW(nullptr, L"open", L"powershell.exe", args.c_str(), nullptr, SW_HIDE);
}

static void LoadSettingsFromConfig(Settings& settings)
{
    std::wstring json;
    if (!ReadTextFile(settings.configPath, json))
    {
        return;
    }

    std::wstring text;
    int number = 0;
    bool flag = false;

    if (JsonString(json, L"irk", text))
    {
        settings.irkHex = CleanHex(text);
    }
    if (JsonInt(json, L"nearRssi", number))
    {
        settings.nearRssi = number;
    }
    if (JsonInt(json, L"awayRssi", number))
    {
        settings.awayRssi = number;
    }
    if (JsonInt(json, L"awaySeconds", number))
    {
        settings.awaySeconds = number;
    }
    if (JsonInt(json, L"nearHits", number))
    {
        settings.nearHitsRequired = number;
    }
    if (JsonInt(json, L"unlockWindowSeconds", number))
    {
        settings.unlockWindowSeconds = number;
    }
    if (JsonBool(json, L"lockOnAway", flag))
    {
        settings.lockOnAway = flag;
    }
    if (JsonBool(json, L"credentialProviderEnabled", flag))
    {
        settings.credentialProviderEnabled = flag;
    }
    if (JsonString(json, L"statePath", text) && !text.empty())
    {
        settings.statePath = text;
        settings.signalStatePath = text;
    }
    if (JsonString(json, L"onNear", text))
    {
        settings.onNear = text;
    }
    if (JsonString(json, L"onAway", text))
    {
        settings.onAway = text;
    }
}

static bool BuildSettings(const Options& options, Settings& settings, std::wstring& error)
{
    settings.configPath = OptionString(options, { L"config" }, settings.configPath);
    LoadSettingsFromConfig(settings);

    settings.irkHex = CleanHex(OptionString(options, { L"irk" }, settings.irkHex));
    settings.nearRssi = OptionInt(options, { L"nearrssi", L"near-rssi" }, settings.nearRssi);
    settings.awayRssi = OptionInt(options, { L"awayrssi", L"away-rssi" }, settings.awayRssi);
    settings.awaySeconds = OptionInt(options, { L"awayseconds", L"away-seconds" }, settings.awaySeconds);
    settings.nearHitsRequired = OptionInt(options, { L"nearhits", L"near-hits" }, settings.nearHitsRequired);
    settings.unlockWindowSeconds = OptionInt(options, { L"unlockwindow", L"unlock-window" }, settings.unlockWindowSeconds);
    settings.logFile = OptionString(options, { L"logfile", L"log-file" }, settings.logFile);
    settings.statePath = OptionString(options, { L"state", L"statepath", L"state-path" }, settings.statePath);
    settings.signalStatePath = OptionString(options, { L"signalstate", L"signal-state", L"signalstatepath", L"signal-state-path" }, settings.signalStatePath);
    settings.onNear = OptionString(options, { L"onnear", L"on-near" }, settings.onNear);
    settings.onAway = OptionString(options, { L"onaway", L"on-away" }, settings.onAway);
    settings.lockOnAway = OptionBool(options, { L"lockonaway", L"lock-on-away" }, settings.lockOnAway);
    settings.credentialProviderEnabled = OptionBool(options, { L"credentialproviderenabled", L"credential-provider-enabled" }, settings.credentialProviderEnabled);
    settings.once = OptionBool(options, { L"once" }, settings.once);

    const bool passive = OptionBool(options, { L"passive" }, false);
    settings.active = OptionBool(options, { L"active" }, true) && !passive;

    if (!HexToBytes(settings.irkHex, 16, settings.irk))
    {
        error = L"Missing or invalid IRK. Configure a 16-byte / 32-hex-character IRK first.";
        return false;
    }
    if (settings.awayRssi >= settings.nearRssi)
    {
        error = L"AwayRssi should be weaker than NearRssi, for example NearRssi=-70 and AwayRssi=-86.";
        return false;
    }
    if (settings.awaySeconds <= 0)
    {
        settings.awaySeconds = 30;
    }
    if (settings.nearHitsRequired <= 0)
    {
        settings.nearHitsRequired = 1;
    }
    if (settings.signalStatePath.empty())
    {
        settings.signalStatePath = settings.statePath;
    }
    return true;
}

static std::wstring WatcherStatusText(BluetoothLEAdvertisementWatcherStatus status)
{
    switch (status)
    {
    case BluetoothLEAdvertisementWatcherStatus::Created: return L"Created";
    case BluetoothLEAdvertisementWatcherStatus::Started: return L"Started";
    case BluetoothLEAdvertisementWatcherStatus::Stopping: return L"Stopping";
    case BluetoothLEAdvertisementWatcherStatus::Stopped: return L"Stopped";
    case BluetoothLEAdvertisementWatcherStatus::Aborted: return L"Aborted";
    default: return L"Unknown";
    }
}

static bool LoadIrkForResolve(const Options& options, std::vector<unsigned char>& irk, std::wstring& error)
{
    Settings settings;
    settings.configPath = OptionString(options, { L"config" }, settings.configPath);
    LoadSettingsFromConfig(settings);
    settings.irkHex = CleanHex(OptionString(options, { L"irk" }, settings.irkHex));
    if (!HexToBytes(settings.irkHex, 16, irk))
    {
        error = L"Missing or invalid IRK. Configure a 16-byte / 32-hex-character IRK first.";
        return false;
    }
    return true;
}

static BOOL WINAPI ConsoleHandler(DWORD)
{
    g_stop = true;
    return TRUE;
}

static int RunScanTest(const Options& options)
{
    init_apartment(apartment_type::multi_threaded);
    const int seconds = OptionInt(options, { L"seconds" }, 8);
    const bool passive = OptionBool(options, { L"passive" }, false);
    const bool active = OptionBool(options, { L"active" }, true) && !passive;
    std::atomic<int> count{ 0 };

    BluetoothLEAdvertisementWatcher watcher;
    watcher.ScanningMode(active ? BluetoothLEScanningMode::Active : BluetoothLEScanningMode::Passive);
    const event_token token = watcher.Received([&](BluetoothLEAdvertisementWatcher const&, BluetoothLEAdvertisementReceivedEventArgs const&) {
        ++count;
    });

    watcher.Start();
    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    const std::wstring status = WatcherStatusText(watcher.Status());
    watcher.Received(token);
    watcher.Stop();

    std::wcout << L"{\"ok\":true,\"status\":\"" << status << L"\",\"count\":" << count.load()
               << L",\"active\":" << (active ? L"true" : L"false") << L"}\n";
    return 0;
}

static int RunScan(const Options& options)
{
    init_apartment(apartment_type::multi_threaded);
    const int seconds = OptionInt(options, { L"seconds", L"s" }, 20);
    const int rssiMin = OptionInt(options, { L"rssimin", L"rssi-min" }, -100);
    const bool json = OptionBool(options, { L"json" }, false);
    const bool continuous = OptionBool(options, { L"continuous" }, false);
    const bool passive = OptionBool(options, { L"passive" }, false);
    const bool active = OptionBool(options, { L"active" }, true) && !passive;

    std::mutex mutex;
    std::map<std::wstring, bool> seen;
    std::vector<ScanRecord> records;

    BluetoothLEAdvertisementWatcher watcher;
    watcher.ScanningMode(active ? BluetoothLEScanningMode::Active : BluetoothLEScanningMode::Passive);
    const event_token token = watcher.Received([&](BluetoothLEAdvertisementWatcher const&, BluetoothLEAdvertisementReceivedEventArgs const& args) {
        if (args.RawSignalStrengthInDBm() < rssiMin)
        {
            return;
        }

        ScanRecord record = MakeScanRecord(args);
        std::lock_guard<std::mutex> guard(mutex);
        if (!continuous && seen.find(record.address) != seen.end())
        {
            return;
        }
        seen[record.address] = true;
        records.push_back(std::move(record));
    });

    watcher.Start();
    if (!json)
    {
        std::wcout << L"Scanning for " << seconds << L"s, RSSI >= " << rssiMin
                   << L" dBm, mode=" << (active ? L"active" : L"passive") << L"...\n";
    }
    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    watcher.Received(token);
    watcher.Stop();

    std::vector<ScanRecord> snapshot;
    {
        std::lock_guard<std::mutex> guard(mutex);
        snapshot = records;
    }

    if (json)
    {
        std::wcout << ScanRecordsToJson(snapshot, false);
    }
    else
    {
        for (const ScanRecord& record : snapshot)
        {
            std::wcout << record.address << L"  " << record.rssi << L" dBm  " << record.name << L"\n";
        }
    }
    return 0;
}

static int RunResolve(const Options& options)
{
    std::vector<unsigned char> irk;
    std::wstring error;
    if (!LoadIrkForResolve(options, irk, error))
    {
        std::wcerr << error << L"\n";
        return 1;
    }

    init_apartment(apartment_type::multi_threaded);
    const int seconds = OptionInt(options, { L"seconds", L"s" }, 60);
    const int rssiMin = OptionInt(options, { L"rssimin", L"rssi-min" }, -100);
    const bool json = OptionBool(options, { L"json" }, false);
    const bool passive = OptionBool(options, { L"passive" }, false);
    const bool active = OptionBool(options, { L"active" }, true) && !passive;

    std::mutex mutex;
    std::map<std::wstring, bool> seen;
    std::vector<ScanRecord> records;

    BluetoothLEAdvertisementWatcher watcher;
    watcher.ScanningMode(active ? BluetoothLEScanningMode::Active : BluetoothLEScanningMode::Passive);
    const event_token token = watcher.Received([&](BluetoothLEAdvertisementWatcher const&, BluetoothLEAdvertisementReceivedEventArgs const& args) {
        if (args.RawSignalStrengthInDBm() < rssiMin)
        {
            return;
        }

        if (!ResolveRpaAddress(AddressToBytes(args.BluetoothAddress()), irk))
        {
            return;
        }

        ScanRecord record = MakeScanRecord(args);
        std::lock_guard<std::mutex> guard(mutex);
        if (seen.find(record.address) != seen.end())
        {
            return;
        }
        seen[record.address] = true;
        records.push_back(std::move(record));
    });

    watcher.Start();
    if (!json)
    {
        std::wcout << L"Resolving for " << seconds << L"s, RSSI >= " << rssiMin
                   << L" dBm, mode=" << (active ? L"active" : L"passive") << L"...\n";
    }
    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    watcher.Received(token);
    watcher.Stop();

    std::vector<ScanRecord> snapshot;
    {
        std::lock_guard<std::mutex> guard(mutex);
        snapshot = records;
    }

    if (json)
    {
        std::wcout << ScanRecordsToJson(snapshot, true);
    }
    else
    {
        for (const ScanRecord& record : snapshot)
        {
            std::wcout << L"MATCH " << record.address << L"  " << record.rssi << L" dBm  " << record.name << L"\n";
        }
    }
    return 0;
}

static int RunSelfTest()
{
    std::vector<unsigned char> irk;
    if (!HexToBytes(L"00112233445566778899AABBCCDDEEFF", 16, irk))
    {
        std::wcerr << L"selftest failed: invalid fixture\n";
        return 1;
    }

    const std::vector<unsigned char> prand = { 0x40, 0x11, 0x22 };
    const std::vector<unsigned char> block = JoinBytes(ZeroBytes(13), prand);
    std::vector<unsigned char> encrypted;
    if (!AesEncryptBlock(irk, block, encrypted))
    {
        std::wcerr << L"selftest failed: AES unavailable\n";
        return 1;
    }

    const std::vector<unsigned char> hash = SubBytes(encrypted, 13, 3);
    const std::vector<unsigned char> address = JoinBytes(prand, hash);
    if (!ResolveRpaAddress(address, irk))
    {
        std::wcerr << L"selftest failed: RPA resolver did not match " << BytesToHex(address) << L"\n";
        return 1;
    }

    std::wcout << L"selftest ok\n";
    return 0;
}

static int RunMonitor(const Options& options)
{
    Settings settings;
    std::wstring error;
    if (!BuildSettings(options, settings, error))
    {
        std::wcerr << error << L"\n";
        return 1;
    }

    init_apartment(apartment_type::multi_threaded);
    SetConsoleCtrlHandler(ConsoleHandler, TRUE);

    std::mutex mutex;
    RuntimeState runtime;

    if (settings.credentialProviderEnabled)
    {
        ClearProviderUnlockState(settings.statePath);
    }

    LogLine(settings, L"INFO", L"native monitor started; near >= " + std::to_wstring(settings.nearRssi) +
        L" dBm, present >= " + std::to_wstring(settings.awayRssi) +
        L" dBm, away after " + std::to_wstring(settings.awaySeconds) +
        L"s, lockOnAway=" + (settings.lockOnAway ? std::wstring(L"true") : std::wstring(L"false")) +
        L", credentialProvider=" + (settings.credentialProviderEnabled ? std::wstring(L"true") : std::wstring(L"false")) +
        L", scanMode=" + (settings.active ? std::wstring(L"active") : std::wstring(L"passive")));

    BluetoothLEAdvertisementWatcher watcher;
    watcher.ScanningMode(settings.active ? BluetoothLEScanningMode::Active : BluetoothLEScanningMode::Passive);
    const event_token token = watcher.Received([&](BluetoothLEAdvertisementWatcher const&, BluetoothLEAdvertisementReceivedEventArgs const& args) {
        const std::vector<unsigned char> addressBytes = AddressToBytes(args.BluetoothAddress());
        if (!ResolveRpaAddress(addressBytes, settings.irk))
        {
            return;
        }

        const auto now = std::chrono::steady_clock::now();
        const int rssi = args.RawSignalStrengthInDBm();
        const std::wstring address = FormatAddress(args.BluetoothAddress());

        std::lock_guard<std::mutex> guard(mutex);
        runtime.lastAddress = address;
        if (!runtime.bestRssi.has_value() || rssi > runtime.bestRssi.value())
        {
            runtime.bestRssi = rssi;
        }
        if (rssi >= settings.awayRssi)
        {
            runtime.lastPresentAt = now;
        }
        if (rssi >= settings.nearRssi)
        {
            ++runtime.nearHits;
        }
        else
        {
            runtime.nearHits = 0;
        }

        const std::wstring presence = rssi >= settings.nearRssi ? L"near" : (rssi >= settings.awayRssi ? L"present" : L"weak");
        WriteMonitorSignalState(settings.signalStatePath, address, rssi, runtime.bestRssi.value_or(rssi), presence, runtime.nearHits);

        if (runtime.state != L"near" && runtime.nearHits >= settings.nearHitsRequired)
        {
            runtime.state = L"near";
            runtime.hasBeenNear = true;
            LogLine(settings, L"INFO", L"near: " + address + L", rssi=" + std::to_wstring(rssi) +
                L" dBm, best=" + std::to_wstring(runtime.bestRssi.value_or(rssi)) + L" dBm");
            if (settings.credentialProviderEnabled)
            {
                if (WriteProviderUnlockState(settings.statePath, settings.unlockWindowSeconds, address, rssi))
                {
                    LogLine(settings, L"INFO", L"credential provider unlock window opened for " +
                        std::to_wstring(settings.unlockWindowSeconds) + L"s");
                }
                else
                {
                    LogLine(settings, L"WARN", L"could not write provider unlock state");
                }
            }
            StartUserCommand(settings.onNear);
            if (settings.once)
            {
                g_stop = true;
            }
        }
    });

    watcher.Start();
    LogLine(settings, L"INFO", L"BLE watcher status: " + WatcherStatusText(watcher.Status()));

    while (!g_stop.load())
    {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        std::lock_guard<std::mutex> guard(mutex);
        if (!runtime.hasBeenNear || runtime.state == L"away" || !runtime.lastPresentAt.has_value())
        {
            continue;
        }

        const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - runtime.lastPresentAt.value()).count();
        if (elapsed < settings.awaySeconds)
        {
            continue;
        }

        runtime.state = L"away";
        runtime.nearHits = 0;
        runtime.bestRssi.reset();
        LogLine(settings, L"INFO", L"away: last=" + runtime.lastAddress + L", missing_or_weak_for=" +
            std::to_wstring(elapsed) + L"s");
        if (settings.credentialProviderEnabled)
        {
            ClearProviderUnlockState(settings.statePath);
        }
        StartUserCommand(settings.onAway);
        if (settings.lockOnAway)
        {
            LogLine(settings, L"INFO", L"locking workstation");
            LockWorkStation();
        }
        if (settings.once)
        {
            g_stop = true;
        }
    }

    watcher.Received(token);
    watcher.Stop();
    LogLine(settings, L"INFO", L"native monitor stopped");
    return 0;
}

static void PrintHelp()
{
    std::wcout << L"WatchUnlock native BLE monitor\n\n"
               << L"Usage:\n"
               << L"  watchunlock-native.exe monitor [--config path] [--irk hex] [--log-file path] [--signal-state path]\n"
               << L"  watchunlock-native.exe scan [--seconds n] [--rssi-min dbm] [--json]\n"
               << L"  watchunlock-native.exe resolve [--irk hex] [--seconds n] [--json]\n"
               << L"  watchunlock-native.exe scan-test [--seconds n] [--active|--passive]\n"
               << L"  watchunlock-native.exe selftest\n\n"
               << L"Copyright (c) 2026 JACK <2518926462@qq.com>\n";
}

int wmain(int argc, wchar_t** argv)
{
    try
    {
        const Options options = ParseOptions(argc, argv);
        if (options.command == L"help" || options.command == L"--help" || options.command == L"-h" ||
            OptionBool(options, { L"help", L"h", L"?" }, false))
        {
            PrintHelp();
            return 0;
        }
        if (options.command == L"scan-test" || options.command == L"scantest")
        {
            return RunScanTest(options);
        }
        if (options.command == L"scan")
        {
            return RunScan(options);
        }
        if (options.command == L"resolve")
        {
            return RunResolve(options);
        }
        if (options.command == L"selftest")
        {
            return RunSelfTest();
        }
        if (options.command == L"monitor")
        {
            return RunMonitor(options);
        }

        std::wcerr << L"Unknown command: " << options.command << L"\n";
        PrintHelp();
        return 1;
    }
    catch (const winrt::hresult_error& ex)
    {
        std::wcerr << L"WinRT error: 0x" << std::hex << static_cast<unsigned int>(ex.code()) << L" " << ex.message().c_str() << L"\n";
        return 1;
    }
    catch (const std::exception& ex)
    {
        std::cerr << "Error: " << ex.what() << "\n";
        return 1;
    }
}
