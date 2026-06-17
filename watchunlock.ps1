# Copyright (c) 2026 JACK <2518926462@qq.com>

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$ScriptName = Split-Path -Leaf $PSCommandPath
$DefaultDataRoot = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
    Join-Path $env:APPDATA "WatchUnlockCli"
}
else {
    Join-Path $env:ProgramData "WatchUnlockCli"
}
$DefaultConfigPath = Join-Path $DefaultDataRoot "config.json"
$DefaultStatePath = Join-Path $DefaultDataRoot "state.json"

function Show-Help {
    @"
WatchUnlock CLI

Usage:
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName <command> [options]

Commands:
  help       Show this help.
  scan       Scan nearby BLE advertisements.
  scan-test  Check BLE watcher status and event count.
  paired     List paired Bluetooth/BLE devices known to Windows.
  keys       Try to list paired Bluetooth LE IRKs from the Windows registry.
  keys-system
             Run a one-shot SYSTEM task to read paired Bluetooth LE IRKs.
  resolve    Scan and print advertisements matching an IRK.
  init       Save monitor defaults to %ProgramData%\WatchUnlockCli\config.json.
  remove-device
             Remove the configured trusted Bluetooth device from config.
  set-credential
             Save the Windows logon account/password for the Credential Provider.
  monitor    Watch an IRK and trigger actions on near/away transitions.
  install-provider
             Register the native Credential Provider DLL.
  uninstall-provider
             Unregister the native Credential Provider DLL.
  lock       Lock the workstation immediately.
  selftest   Run local parser and BLE runtime self-tests.

Common options:
  -Irk <hex>             16-byte IRK as 32 hex chars. Separators are allowed.
  -Seconds <n>           Scan duration. Default: 20 for scan, 60 for resolve.
  -RssiMin <dbm>         Ignore advertisements weaker than this. Default: -100.
  -Active                Use active BLE scanning. This is the default.
  -Passive               Use passive BLE scanning for diagnostics.
  -Json                  Emit JSON instead of table/log lines.
  -Config <path>         Config path. Default: $DefaultConfigPath

Monitor options:
  -NearRssi <dbm>        RSSI needed to become near. Default: -70.
  -AwayRssi <dbm>        RSSI floor to keep the target present. Default: -86.
  -AwaySeconds <n>       Seconds without target above AwayRssi before away. Default: 30.
  -NearHits <n>          Consecutive near hits before near transition. Default: 2.
  -LockOnAway            Lock Windows on away transition.
  -OnNear <command>      Command to run on near transition.
  -OnAway <command>      Command to run on away transition.
  -Once                  Exit after the first near/away transition.
  -LogFile <path>        Append monitor logs to a file.

Credential Provider options:
  -Username <name>       Windows account, for example ".\alice" or "MicrosoftAccount\name@example.com".
  -Password <password>   Password to encrypt into config. If omitted, prompts securely.
  -UnlockWindow <n>      Seconds the provider may auto-submit after a near event. Default: 30.
  -ProviderDll <path>    Native provider DLL path for install/uninstall.
  -PasswordStdin         Read the password from stdin instead of the command line.

Examples:
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName scan -Seconds 20
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName keys
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName resolve -Irk 00112233445566778899AABBCCDDEEFF -Seconds 60
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName init -Irk 00112233445566778899AABBCCDDEEFF -LockOnAway
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName remove-device
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName set-credential -Username ".\alice"
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName monitor -OnNear "powershell -NoProfile -Command Write-Host near"
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName install-provider
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName selftest
  powershell.exe -ExecutionPolicy Bypass -File .\$ScriptName selftest -NoBluetooth

Notes:
  Copyright (c) 2026 JACK <2518926462@qq.com>
  Full automatic Windows unlock requires the native Credential Provider DLL under credential-provider\.
  The CLI monitor writes unlock state; the Credential Provider reads config/state on the secure logon desktop.
"@ | Write-Host
}

function Get-CommandName {
    if ($args.Count -eq 0) {
        return "help"
    }
    return ([string]$args[0]).ToLowerInvariant()
}

function Get-RawOptions {
    if ($args.Count -le 1) {
        return @()
    }
    return @($args[1..($args.Count - 1)])
}

function Parse-Options {
    param([string[]]$RawOptions)

    if ($null -eq $RawOptions) {
        $RawOptions = @()
    }

    $result = @{}
    $positionals = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $RawOptions.Count; $i++) {
        $token = [string]$RawOptions[$i]
        if ($token -match "^-{1,2}(.+)$") {
            $key = $Matches[1].ToLowerInvariant()
            $nextIsValue = $false
            if ($i + 1 -lt $RawOptions.Count) {
                $next = [string]$RawOptions[$i + 1]
                if ($next -notmatch "^-{1,2}[A-Za-z][A-Za-z0-9_-]*$") {
                    $nextIsValue = $true
                }
            }
            if ($nextIsValue) {
                $result[$key] = [string]$RawOptions[$i + 1]
                $i++
            }
            else {
                $result[$key] = $true
            }
        }
        else {
            [void]$positionals.Add($token)
        }
    }

    $result["_positionals"] = @($positionals)
    return $result
}

function Get-OptionValue {
    param(
        [hashtable]$Options,
        [string[]]$Names,
        $Default = $null
    )

    foreach ($name in $Names) {
        $key = $name.ToLowerInvariant()
        if ($Options.ContainsKey($key)) {
            return $Options[$key]
        }
    }
    return $Default
}

function Get-StringOption {
    param([hashtable]$Options, [string[]]$Names, [string]$Default = $null)
    $value = Get-OptionValue -Options $Options -Names $Names -Default $Default
    if ($null -eq $value -or $value -is [bool]) {
        return $Default
    }
    return [string]$value
}

function Get-IntOption {
    param([hashtable]$Options, [string[]]$Names, [int]$Default)
    $value = Get-OptionValue -Options $Options -Names $Names -Default $Default
    if ($value -is [bool]) {
        return $Default
    }
    return [int]$value
}

function Get-BoolOption {
    param([hashtable]$Options, [string[]]$Names, [bool]$Default = $false)
    $value = Get-OptionValue -Options $Options -Names $Names -Default $Default
    if ($value -is [bool]) {
        return [bool]$value
    }
    if ($null -eq $value) {
        return $Default
    }
    $text = ([string]$value).ToLowerInvariant()
    return @("1", "true", "yes", "y", "on") -contains $text
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Normalize-Hex {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][int]$Bytes,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $hex = ($Value -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
    if ($hex.Length -ne ($Bytes * 2)) {
        throw "$Label must be $Bytes bytes ($($Bytes * 2) hex chars)."
    }
    return $hex
}

function Convert-HexToBytes {
    param([Parameter(Mandatory = $true)][string]$Hex)

    $clean = ($Hex -replace "[^0-9A-Fa-f]", "")
    if ($clean.Length % 2 -ne 0) {
        throw "Hex string length must be even."
    }

    $bytes = New-Object byte[] ($clean.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16)
    }
    return $bytes
}

function Convert-BytesToHex {
    param($Bytes)
    if ($null -eq $Bytes) {
        return ""
    }
    $source = [byte[]]@($Bytes)
    return (($source | ForEach-Object { $_.ToString("X2") }) -join "")
}

function Format-BluetoothAddress {
    param([UInt64]$Address)
    $hex = "{0:X12}" -f $Address
    return (($hex -split "(.{2})" | Where-Object { $_ }) -join ":")
}

function Convert-BufferToBytes {
    param($Buffer)

    if ($null -eq $Buffer -or $Buffer.Length -eq 0) {
        return New-Object byte[] 0
    }

    $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($Buffer)
    $bytes = New-Object byte[] ([int]$Buffer.Length)
    $reader.ReadBytes($bytes)
    return $bytes
}

function Get-SafeProperty {
    param($Object, [string]$Name, $Default = $null)
    try {
        return $Object.$Name
    }
    catch {
        return $Default
    }
}

function Get-AdvertisementInfo {
    param($EventArgs)

    $advertisement = $EventArgs.Advertisement
    $name = Get-SafeProperty -Object $advertisement -Name "LocalName" -Default ""
    $address = Format-BluetoothAddress -Address ([UInt64]$EventArgs.BluetoothAddress)
    $addressType = Get-SafeProperty -Object $EventArgs -Name "BluetoothAddressType" -Default ""
    $rssi = [int]$EventArgs.RawSignalStrengthInDBm
    $timestamp = Get-SafeProperty -Object $EventArgs -Name "Timestamp" -Default ([DateTimeOffset]::Now)

    $serviceUuids = @()
    try {
        foreach ($uuid in $advertisement.ServiceUuids) {
            $serviceUuids += $uuid.ToString()
        }
    }
    catch {}

    $manufacturer = @()
    try {
        foreach ($item in $advertisement.ManufacturerData) {
            $bytes = Convert-BufferToBytes -Buffer $item.Data
            $manufacturer += ("{0:X4}:{1}" -f ([int]$item.CompanyId), (Convert-BytesToHex -Bytes $bytes))
        }
    }
    catch {}

    [pscustomobject]@{
        timestamp    = $timestamp.ToString("o")
        address      = $address
        addressType  = [string]$addressType
        rssi         = $rssi
        name         = [string]$name
        services     = $serviceUuids
        manufacturer = $manufacturer
    }
}

function Ensure-BluetoothRuntime {
    $null = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
}

function Wait-WinRtAsyncOperation {
    param($Operation, [Type]$ResultType)

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "AsTask" -and
            $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -like "IAsyncOperation*"
        } |
        Select-Object -First 1

    if ($null -eq $method) {
        throw "Cannot find WinRT AsTask helper."
    }

    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Get-PairedBluetoothDevicesFromSelector {
    param([string]$Selector, [string]$Kind)

    $rows = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Selector)) {
        return @()
    }

    $operation = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($Selector)
    $devices = Wait-WinRtAsyncOperation -Operation $operation -ResultType ([Windows.Devices.Enumeration.DeviceInformationCollection])

    foreach ($device in @($devices)) {
        [void]$rows.Add([pscustomobject]@{
            kind      = $Kind
            name      = [string]$device.Name
            id        = [string]$device.Id
            address   = Get-BluetoothAddressFromDeviceId -DeviceId ([string]$device.Id)
            isEnabled = [bool]$device.IsEnabled
            isPaired  = [bool]$device.Pairing.IsPaired
        })
    }

    return @($rows)
}

function Get-BluetoothAddressFromDeviceId {
    param([string]$DeviceId)

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        return ""
    }

    $tail = (($DeviceId -split "-") | Select-Object -Last 1)
    $colonMatch = [regex]::Match($tail, "(?i)([0-9A-F]{2}(?::[0-9A-F]{2}){5})")
    if ($colonMatch.Success) {
        return $colonMatch.Groups[1].Value.ToUpperInvariant()
    }

    $match = [regex]::Match($DeviceId, "(?i)(?:Dev_|BluetoothDevice_|_)([0-9A-F]{12})(?:\\|$|_)")
    if (-not $match.Success) {
        $match = [regex]::Match($DeviceId, "(?i)([0-9A-F]{12})")
    }
    if (-not $match.Success) {
        return ""
    }

    $hex = $match.Groups[1].Value.ToUpperInvariant()
    return (($hex -split "(.{2})" | Where-Object { $_ }) -join ":")
}

function Get-RegistryPairedBluetoothDevices {
    $root = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\BTHENUM"
    $rows = New-Object System.Collections.ArrayList

    if (-not (Test-Path $root)) {
        return @()
    }

    foreach ($deviceRoot in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "Dev_*" })) {
        foreach ($instance in @(Get-ChildItem -Path $deviceRoot.PSPath -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path $instance.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) {
                continue
            }

            $name = [string]$props.FriendlyName
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = [string]$props.DeviceDesc
            }
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            [void]$rows.Add([pscustomobject]@{
                kind      = "Registry"
                name      = $name
                id        = [string]$instance.PSChildName
                address   = Get-BluetoothAddressFromDeviceId -DeviceId ([string]$instance.PSChildName)
                isEnabled = $true
                isPaired  = $true
            })
        }
    }

    return @($rows)
}

function Start-BleWatcher {
    param([string]$SourceIdentifier, [bool]$Active = $true)

    Ensure-BluetoothRuntime
    $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()
    if ($Active) {
        $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active
    }
    else {
        $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Passive
    }
    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $handler = [Windows.Foundation.TypedEventHandler[Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementReceivedEventArgs]]{
        param($sender, $eventArgs)
        $queue.Enqueue($eventArgs)
    }
    $token = $watcher.add_Received($handler)
    $watcher.Start()

    [pscustomobject]@{
        Watcher      = $watcher
        Queue        = $queue
        Handler      = $handler
        Token        = $token
    }
}

function Stop-BleWatcher {
    param($WatcherInfo, [string]$SourceIdentifier)

    if ($null -ne $WatcherInfo -and $null -ne $WatcherInfo.Watcher) {
        try {
            if ($null -ne $WatcherInfo.Token) {
                $WatcherInfo.Watcher.remove_Received($WatcherInfo.Token)
            }
        }
        catch {}

        try {
            $WatcherInfo.Watcher.Stop()
        }
        catch {}
    }

    try {
        Get-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
    catch {}

    try {
        Unregister-Event -SourceIdentifier $SourceIdentifier -ErrorAction SilentlyContinue
    }
    catch {}
}

function Receive-BleEvents {
    param($WatcherInfo, [int]$TimeoutSeconds = 1)

    $events = New-Object System.Collections.ArrayList
    if ($null -eq $WatcherInfo -or $null -eq $WatcherInfo.Queue) {
        return @()
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $item = $null
        while ($WatcherInfo.Queue.TryDequeue([ref]$item)) {
            [void]$events.Add([pscustomobject]@{ SourceEventArgs = $item })
            $item = $null
        }
        if ($events.Count -gt 0) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    $item = $null
    while ($WatcherInfo.Queue.TryDequeue([ref]$item)) {
        [void]$events.Add([pscustomobject]@{ SourceEventArgs = $item })
        $item = $null
    }

    return @($events)
}

function Complete-BleEvent {
    param($Event)
    if ($null -ne $Event -and $null -ne $Event.PSObject.Properties["EventIdentifier"]) {
        Remove-Event -EventIdentifier $Event.EventIdentifier -ErrorAction SilentlyContinue
    }
}

function New-AesEncryptor {
    param([byte[]]$Key)

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
    $aes.KeySize = 128
    $aes.BlockSize = 128
    $aes.Key = $Key
    return $aes
}

function Invoke-AesBlock {
    param([byte[]]$Key, [byte[]]$Block)

    $aes = New-AesEncryptor -Key $Key
    try {
        $encryptor = $aes.CreateEncryptor()
        try {
            return $encryptor.TransformFinalBlock($Block, 0, 16)
        }
        finally {
            $encryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }
}

function Test-ByteArrayEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) {
            return $false
        }
    }
    return $true
}

function Get-SubBytes {
    param([byte[]]$Bytes, [int]$Start, [int]$Length)
    $result = New-Object byte[] $Length
    [Array]::Copy($Bytes, $Start, $result, 0, $Length)
    return $result
}

function Join-Bytes {
    param([byte[]]$Left, [byte[]]$Right)
    $result = New-Object byte[] ($Left.Length + $Right.Length)
    [Array]::Copy($Left, 0, $result, 0, $Left.Length)
    [Array]::Copy($Right, 0, $result, $Left.Length, $Right.Length)
    return $result
}

function Reverse-Bytes {
    param($Bytes)
    if ($null -eq $Bytes) {
        return New-Object byte[] 0
    }
    $source = [byte[]]@($Bytes)
    if ($source.Length -eq 0) {
        return New-Object byte[] 0
    }
    $result = New-Object byte[] $source.Length
    for ($i = 0; $i -lt $source.Length; $i++) {
        $result[$i] = $source[$source.Length - 1 - $i]
    }
    return $result
}

function New-ZeroBytes {
    param([int]$Length)
    return New-Object byte[] $Length
}

function Resolve-RpaAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][byte[]]$Irk
    )

    $addressHex = Normalize-Hex -Value $Address -Bytes 6 -Label "Bluetooth address"
    $addrOriginal = Convert-HexToBytes -Hex $addressHex
    $keys = @(
        @{ Name = "key"; Bytes = [byte[]]$Irk },
        @{ Name = "reversed-key"; Bytes = Reverse-Bytes -Bytes $Irk }
    )

    $addressCandidates = @(
        @{ Name = "display"; Bytes = [byte[]]$addrOriginal },
        @{ Name = "reversed-address"; Bytes = Reverse-Bytes -Bytes $addrOriginal }
    )

    foreach ($addressCandidate in $addressCandidates) {
        $addr = [byte[]]$addressCandidate.Bytes
        $layouts = @(
            @{ Name = "hash-high/prand-low"; Prand = (Get-SubBytes -Bytes $addr -Start 3 -Length 3); Hash = (Get-SubBytes -Bytes $addr -Start 0 -Length 3); RpaByte = 3 },
            @{ Name = "prand-high/hash-low"; Prand = (Get-SubBytes -Bytes $addr -Start 0 -Length 3); Hash = (Get-SubBytes -Bytes $addr -Start 3 -Length 3); RpaByte = 0 }
        )

        foreach ($layout in $layouts) {
            $marker = $addr[$layout.RpaByte] -band 0xC0
            if ($marker -ne 0x40) {
                continue
            }

            $prandRaw = [byte[]]$layout.Prand
            $hashRaw = [byte[]]$layout.Hash
            $prands = @(
                @{ Name = "prand"; Bytes = $prandRaw },
                @{ Name = "reversed-prand"; Bytes = (Reverse-Bytes -Bytes $prandRaw) }
            )
            $observedHashes = @(
                @{ Name = "hash"; Bytes = $hashRaw },
                @{ Name = "reversed-hash"; Bytes = (Reverse-Bytes -Bytes $hashRaw) }
            )

            foreach ($keyCandidate in $keys) {
                foreach ($prandCandidate in $prands) {
                    $blocks = @(
                        @{ Name = "tail-prand"; Block = Join-Bytes -Left (New-ZeroBytes -Length 13) -Right ([byte[]]$prandCandidate.Bytes) },
                        @{ Name = "head-prand"; Block = Join-Bytes -Left ([byte[]]$prandCandidate.Bytes) -Right (New-ZeroBytes -Length 13) }
                    )

                    foreach ($blockCandidate in $blocks) {
                        $encrypted = Invoke-AesBlock -Key ([byte[]]$keyCandidate.Bytes) -Block ([byte[]]$blockCandidate.Block)
                        $hashes = @(
                            @{ Name = "tail-hash"; Hash = Get-SubBytes -Bytes $encrypted -Start 13 -Length 3 },
                            @{ Name = "reversed-tail-hash"; Hash = Reverse-Bytes -Bytes (Get-SubBytes -Bytes $encrypted -Start 13 -Length 3) },
                            @{ Name = "head-hash"; Hash = Get-SubBytes -Bytes $encrypted -Start 0 -Length 3 },
                            @{ Name = "reversed-head-hash"; Hash = Reverse-Bytes -Bytes (Get-SubBytes -Bytes $encrypted -Start 0 -Length 3) }
                        )

                        foreach ($hashCandidate in $hashes) {
                            foreach ($observedHash in $observedHashes) {
                                if (Test-ByteArrayEqual -Left ([byte[]]$hashCandidate.Hash) -Right ([byte[]]$observedHash.Bytes)) {
                                    return [pscustomobject]@{
                                        matched      = $true
                                        addressOrder = $addressCandidate.Name
                                        layout       = $layout.Name
                                        keyOrder     = $keyCandidate.Name
                                        prandOrder   = $prandCandidate.Name
                                        blockMode    = $blockCandidate.Name
                                        hashMode     = $hashCandidate.Name
                                        observedHash = $observedHash.Name
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        matched      = $false
        addressOrder = ""
        layout       = ""
        keyOrder     = ""
        prandOrder   = ""
        blockMode    = ""
        hashMode     = ""
        observedHash = ""
    }
}

function Invoke-LockWorkstation {
    Start-Process -FilePath "rundll32.exe" -ArgumentList "user32.dll,LockWorkStation" -WindowStyle Hidden
}

function Invoke-UserCommand {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return
    }

    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $CommandLine) -WindowStyle Hidden
}

function Write-LogLine {
    param(
        [string]$Level,
        [string]$Message,
        [string]$LogFile = $null
    )

    $line = "[{0}][{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level.ToUpperInvariant(), $Message
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $folder = Split-Path -Parent $LogFile
        if (-not [string]::IsNullOrWhiteSpace($folder) -and -not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}

function Write-JsonArray {
    param($Items, [int]$Depth = 6)

    if ($null -eq $Items -or $Items.Count -eq 0) {
        Write-Output "[]"
        return
    }

    ConvertTo-Json -InputObject @($Items) -Depth $Depth
}

function Get-Config {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }

    return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function ConvertTo-ConfigMap {
    param($Config)

    $map = [ordered]@{}
    if ($null -eq $Config) {
        return $map
    }

    foreach ($property in $Config.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function Save-ConfigMap {
    param($Map, [string]$Path)

    $folder = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($folder) -and -not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $Map | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
}

function Get-ConfigValue {
    param($Config, [string]$Name, $Default = $null)
    if ($null -eq $Config) {
        return $Default
    }
    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function Convert-SecureStringToPlainText {
    param([Security.SecureString]$SecureString)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function Protect-TextForMachine {
    param([Parameter(Mandatory = $true)][string]$Text)

    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::Unicode.GetBytes($Text)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        return [Convert]::ToBase64String($protected)
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Test-WindowsCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    if (-not ("WatchUnlock.NativeLogon" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace WatchUnlock {
    public static class NativeLogon {
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool LogonUser(string username, string domain, string password, int logonType, int logonProvider, out IntPtr token);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
"@
    }

    $domain = $null
    $user = $Username
    if ($Username -match "^([^\\]+)\\(.+)$") {
        $domain = $Matches[1]
        $user = $Matches[2]
    }

    $token = [IntPtr]::Zero
    $ok = [WatchUnlock.NativeLogon]::LogonUser($user, $domain, $Password, 2, 0, [ref]$token)
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($token -ne [IntPtr]::Zero) {
        [void][WatchUnlock.NativeLogon]::CloseHandle($token)
    }

    [pscustomobject]@{
        ok        = [bool]$ok
        username  = $Username
        domain    = $domain
        user      = $user
        errorCode = if ($ok) { 0 } else { $errorCode }
        message   = if ($ok) { "OK" } else { ([ComponentModel.Win32Exception]$errorCode).Message }
    }
}

function Get-UnixTimeSeconds {
    $epoch = [DateTime]"1970-01-01T00:00:00Z"
    return [int64](([DateTime]::UtcNow - $epoch).TotalSeconds)
}

function Set-ProviderUnlockState {
    param(
        [string]$StatePath,
        [int]$UnlockWindowSeconds,
        [string]$Address,
        [int]$Rssi
    )

    $folder = Split-Path -Parent $StatePath
    if (-not [string]::IsNullOrWhiteSpace($folder) -and -not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $now = Get-UnixTimeSeconds
    $state = [ordered]@{
        allowUnlockUntil = $now + $UnlockWindowSeconds
        unlockToken      = [Guid]::NewGuid().ToString("N")
        lastNearAt       = $now
        address          = $Address
        rssi             = $Rssi
    }

    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $StatePath -Encoding UTF8
}

function Clear-ProviderUnlockState {
    param([string]$StatePath)

    $folder = Split-Path -Parent $StatePath
    if (-not [string]::IsNullOrWhiteSpace($folder) -and -not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    [ordered]@{
        allowUnlockUntil = 0
        unlockToken      = ""
        lastNearAt       = 0
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $StatePath -Encoding UTF8
}

function Set-MonitorSignalState {
    param(
        [string]$StatePath,
        [string]$Address,
        [int]$Rssi,
        [int]$BestRssi,
        [string]$Presence,
        [int]$NearHits
    )

    $folder = Split-Path -Parent $StatePath
    if (-not [string]::IsNullOrWhiteSpace($folder) -and -not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $now = [DateTimeOffset]::Now
    [ordered]@{
        allowUnlockUntil = 0
        unlockToken      = ""
        lastNearAt       = 0
        lastSeenAt       = $now.ToUnixTimeSeconds()
        lastSeenIso      = $now.ToString("o")
        address          = $Address
        rssi             = $Rssi
        bestRssi         = $BestRssi
        presence         = $Presence
        nearHits         = $NearHits
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $StatePath -Encoding UTF8
}

function Invoke-ScanCommand {
    param([hashtable]$Options)

    $seconds = Get-IntOption -Options $Options -Names @("seconds", "s") -Default 20
    $rssiMin = Get-IntOption -Options $Options -Names @("rssimin", "rssi-min") -Default -100
    $json = Get-BoolOption -Options $Options -Names @("json") -Default $false
    $continuous = Get-BoolOption -Options $Options -Names @("continuous") -Default $false
    $passive = Get-BoolOption -Options $Options -Names @("passive") -Default $false
    $active = (Get-BoolOption -Options $Options -Names @("active") -Default $true) -and -not $passive
    $sourceId = "watchunlock-scan-$([Guid]::NewGuid().ToString("N"))"
    $watcherInfo = $null
    $seen = @{}
    $records = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($seconds)

    try {
        $watcherInfo = Start-BleWatcher -SourceIdentifier $sourceId -Active $active
        if (-not $json) {
            $scanType = if ($active) { "active" } else { "passive" }
            Write-Host ("Scanning for {0}s, RSSI >= {1} dBm, mode={2}..." -f $seconds, $rssiMin, $scanType)
        }

        while ((Get-Date) -lt $deadline) {
            $events = Receive-BleEvents -WatcherInfo $watcherInfo -TimeoutSeconds 1
            foreach ($event in $events) {
                try {
                    $info = Get-AdvertisementInfo -EventArgs $event.SourceEventArgs
                    if ($info.rssi -lt $rssiMin) {
                        continue
                    }

                    if (-not $seen.ContainsKey($info.address) -or $continuous) {
                        $seen[$info.address] = $true
                        [void]$records.Add($info)
                        if (-not $json) {
                            $services = ($info.services | Select-Object -First 3) -join ","
                            $manufacturer = ($info.manufacturer | Select-Object -First 2) -join ","
                            "{0,-8} {1,-17} {2,4} dBm  {3,-24} {4} {5}" -f (Get-Date -Format "HH:mm:ss"), $info.address, $info.rssi, $info.name, $services, $manufacturer | Write-Host
                        }
                    }
                }
                finally {
                    Complete-BleEvent -Event $event
                }
            }
        }
    }
    finally {
        Stop-BleWatcher -WatcherInfo $watcherInfo -SourceIdentifier $sourceId
    }

    if ($json) {
        Write-JsonArray -Items $records -Depth 6
    }
}

function Invoke-ScanTestCommand {
    param([hashtable]$Options)

    $seconds = Get-IntOption -Options $Options -Names @("seconds", "s") -Default 10
    $json = Get-BoolOption -Options $Options -Names @("json") -Default $false
    $passive = Get-BoolOption -Options $Options -Names @("passive") -Default $false
    $active = (Get-BoolOption -Options $Options -Names @("active") -Default $true) -and -not $passive
    Ensure-BluetoothRuntime

    $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()
    if ($active) {
        $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active
    }
    else {
        $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Passive
    }
    $count = 0
    $lastRssi = $null
    $lastAddress = ""
    $stoppedReason = ""
    $received = [Windows.Foundation.TypedEventHandler[Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementReceivedEventArgs]]{
        param($sender, $eventArgs)
        $script:scanTestCount++
        $script:scanTestLastRssi = [int]$eventArgs.RawSignalStrengthInDBm
        $script:scanTestLastAddress = Format-BluetoothAddress -Address ([UInt64]$eventArgs.BluetoothAddress)
    }
    $stopped = [Windows.Foundation.TypedEventHandler[Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcherStoppedEventArgs]]{
        param($sender, $eventArgs)
        $script:scanTestStoppedReason = [string]$eventArgs.Error
    }

    $script:scanTestCount = 0
    $script:scanTestLastRssi = $null
    $script:scanTestLastAddress = ""
    $script:scanTestStoppedReason = ""
    $receivedToken = $watcher.add_Received($received)
    $stoppedToken = $watcher.add_Stopped($stopped)
    $before = [string]$watcher.Status
    try {
        $watcher.Start()
        $afterStart = [string]$watcher.Status
        Start-Sleep -Seconds $seconds
        $count = [int]$script:scanTestCount
        $lastRssi = $script:scanTestLastRssi
        $lastAddress = [string]$script:scanTestLastAddress
        $stoppedReason = [string]$script:scanTestStoppedReason
        $afterWait = [string]$watcher.Status
    }
    finally {
        try { $watcher.Stop() } catch {}
        Start-Sleep -Milliseconds 200
        $afterStop = [string]$watcher.Status
        try { $watcher.remove_Received($receivedToken) } catch {}
        try { $watcher.remove_Stopped($stoppedToken) } catch {}
    }

    $row = [pscustomobject]@{
        seconds       = $seconds
        mode          = if ($active) { "active" } else { "passive" }
        before        = $before
        afterStart    = $afterStart
        afterWait     = $afterWait
        afterStop     = $afterStop
        count         = $count
        lastAddress   = $lastAddress
        lastRssi      = $lastRssi
        stoppedReason = $stoppedReason
    }

    if ($json) {
        $row | ConvertTo-Json -Depth 4
        return
    }

    "Watcher before: {0}" -f $row.before | Write-Host
    "Mode: {0}" -f $row.mode | Write-Host
    "Watcher after start: {0}" -f $row.afterStart | Write-Host
    "Watcher after wait: {0}" -f $row.afterWait | Write-Host
    "Events received: {0}" -f $row.count | Write-Host
    "Last event: {0} {1} dBm" -f $row.lastAddress, $row.lastRssi | Write-Host
    "Stopped reason: {0}" -f $row.stoppedReason | Write-Host
}

function Invoke-PairedCommand {
    param([hashtable]$Options)

    $json = Get-BoolOption -Options $Options -Names @("json") -Default $false
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}

    function Add-PairedRow {
        param($Row)

        if ($null -eq $Row) {
            return
        }

        $address = if ($null -ne $Row.PSObject.Properties["address"]) { [string]$Row.address } else { "" }
        $id = if ($null -ne $Row.PSObject.Properties["id"]) { [string]$Row.id } else { "" }
        $name = if ($null -ne $Row.PSObject.Properties["name"]) { [string]$Row.name } else { "" }

        $key = if (-not [string]::IsNullOrWhiteSpace($address)) {
            $address
        }
        elseif (-not [string]::IsNullOrWhiteSpace($id)) {
            $id
        }
        else {
            $name
        }

        if ([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)) {
            return
        }

        $seen[$key] = $true
        [void]$rows.Add($Row)
    }

    foreach ($row in @(Get-RegistryPairedBluetoothDevices)) {
        Add-PairedRow -Row $row
    }

    try {
        Ensure-BluetoothRuntime
        $bleSelector = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($true)
        foreach ($row in @(Get-PairedBluetoothDevicesFromSelector -Selector $bleSelector -Kind "BLE")) {
            Add-PairedRow -Row $row
        }
    }
    catch {
        if (-not $json) {
            Write-Host ("Cannot list paired BLE devices: {0}" -f $_.Exception.Message)
        }
    }

    try {
        $classicSelector = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($true)
        foreach ($row in @(Get-PairedBluetoothDevicesFromSelector -Selector $classicSelector -Kind "Bluetooth")) {
            Add-PairedRow -Row $row
        }
    }
    catch {
        if (-not $json) {
            Write-Host ("Cannot list paired Bluetooth devices: {0}" -f $_.Exception.Message)
        }
    }

    if ($json) {
        Write-JsonArray -Items $rows -Depth 5
        return
    }

    if ($rows.Count -eq 0) {
        Write-Host "No paired Bluetooth devices found. Windows may still hide IRK/RSSI; use 'scan' for live advertisements and 'keys' for IRK."
        return
    }

    foreach ($row in $rows) {
        "{0,-9} {1,-24} paired={2,-5} enabled={3,-5} {4} {5}" -f $row.kind, $row.name, $row.isPaired, $row.isEnabled, $row.address, $row.id | Write-Host
    }
}

function Invoke-ResolveCommand {
    param([hashtable]$Options)

    $configPath = Get-StringOption -Options $Options -Names @("config") -Default $DefaultConfigPath
    $config = Get-Config -Path $configPath
    $defaultIrk = Get-ConfigValue -Config $config -Name "irk" -Default $null
    $irkText = Get-StringOption -Options $Options -Names @("irk") -Default $defaultIrk
    if ([string]::IsNullOrWhiteSpace($irkText)) {
        throw "Missing -Irk. Run 'keys' to look for paired device IRKs, or pass -Irk <32 hex chars>."
    }

    $irk = Convert-HexToBytes -Hex (Normalize-Hex -Value $irkText -Bytes 16 -Label "IRK")
    $seconds = Get-IntOption -Options $Options -Names @("seconds", "s") -Default 60
    $rssiMin = Get-IntOption -Options $Options -Names @("rssimin", "rssi-min") -Default -100
    $json = Get-BoolOption -Options $Options -Names @("json") -Default $false
    $passive = Get-BoolOption -Options $Options -Names @("passive") -Default $false
    $active = (Get-BoolOption -Options $Options -Names @("active") -Default $true) -and -not $passive
    $sourceId = "watchunlock-resolve-$([Guid]::NewGuid().ToString("N"))"
    $watcherInfo = $null
    $seen = @{}
    $matches = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($seconds)

    try {
        $watcherInfo = Start-BleWatcher -SourceIdentifier $sourceId -Active $active
        if (-not $json) {
            $scanType = if ($active) { "active" } else { "passive" }
            Write-Host ("Resolving for {0}s, RSSI >= {1} dBm, mode={2}..." -f $seconds, $rssiMin, $scanType)
        }

        while ((Get-Date) -lt $deadline) {
            $events = Receive-BleEvents -WatcherInfo $watcherInfo -TimeoutSeconds 1
            foreach ($event in $events) {
                try {
                    $info = Get-AdvertisementInfo -EventArgs $event.SourceEventArgs
                    if ($info.rssi -lt $rssiMin -or $seen.ContainsKey($info.address)) {
                        continue
                    }

                    $match = Resolve-RpaAddress -Address $info.address -Irk $irk
                    if ($match.matched) {
                        $seen[$info.address] = $true
                        $row = [pscustomobject]@{
                            timestamp = $info.timestamp
                            address   = $info.address
                            rssi      = $info.rssi
                            name      = $info.name
                            match     = $match
                        }
                        [void]$matches.Add($row)
                        if (-not $json) {
                            "{0,-8} MATCH {1,-17} {2,4} dBm  {3}  {4}/{5}/{6}/{7}" -f (Get-Date -Format "HH:mm:ss"), $info.address, $info.rssi, $info.name, $match.layout, $match.keyOrder, $match.blockMode, $match.hashMode | Write-Host
                        }
                    }
                }
                finally {
                    Complete-BleEvent -Event $event
                }
            }
        }
    }
    finally {
        Stop-BleWatcher -WatcherInfo $watcherInfo -SourceIdentifier $sourceId
    }

    if ($json) {
        Write-JsonArray -Items $matches -Depth 6
    }
}

function Invoke-KeysCommand {
    param([hashtable]$Options)

    $json = Get-BoolOption -Options $Options -Names @("json") -Default $false
    $noSystem = Get-BoolOption -Options $Options -Names @("nosystem", "no-system") -Default $false
    $root = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys"
    $rows = New-Object System.Collections.ArrayList

    try {
        if (-not (Test-Path $root)) {
            throw "Bluetooth key registry path not found: $root"
        }
        $adapters = @(Get-ChildItem -Path $root -ErrorAction Stop)
    }
    catch {
        if (-not $noSystem) {
            Invoke-KeysSystemCommand -Options $Options
            return
        }

        Write-Host "Cannot read Bluetooth key registry path: $root"
        Write-Host ("Reason: {0}" -f $_.Exception.Message)
        Write-Host "Try running PowerShell as Administrator or SYSTEM. The script only reads this path; it does not elevate itself."
        return
    }

    foreach ($adapter in $adapters) {
        foreach ($device in @(Get-ChildItem -Path $adapter.PSPath -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -Path $device.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) {
                continue
            }

            $irkValue = $props.PSObject.Properties["IRK"]
            if ($null -eq $irkValue) {
                continue
            }

            $irkBytes = [byte[]]$irkValue.Value
            $irk = Convert-BytesToHex -Bytes $irkBytes
            $reversed = Convert-BytesToHex -Bytes ([byte[]]@($irkBytes[($irkBytes.Length - 1)..0]))
            $row = [pscustomobject]@{
                adapter     = Split-Path -Leaf $adapter.PSPath
                device      = Split-Path -Leaf $device.PSPath
                irk         = $irk
                irkReversed = $reversed
            }
            [void]$rows.Add($row)
        }
    }

    if ($json) {
        Write-JsonArray -Items $rows -Depth 4
        return
    }

    if ($rows.Count -eq 0) {
        Write-Host "No IRK values found. You may need to run PowerShell as Administrator or SYSTEM, and the device must be paired."
        return
    }

    foreach ($row in $rows) {
        "Adapter: {0}  Device: {1}" -f $row.adapter, $row.device | Write-Host
        "  IRK:         {0}" -f $row.irk | Write-Host
        "  IRK reverse: {0}" -f $row.irkReversed | Write-Host
    }
}

function Invoke-KeysSystemCommand {
    param([hashtable]$Options)

    $json = Get-BoolOption -Options $Options -Names @("json") -Default $false
    $timeoutSeconds = Get-IntOption -Options $Options -Names @("timeout", "timeoutseconds", "timeout-seconds") -Default 20
    $runtimeRoot = Join-Path (Split-Path -Parent $PSCommandPath) ".runtime"

    $id = [Guid]::NewGuid().ToString("N")
    $taskName = "WatchUnlock-ReadBluetoothIrk-$id"
    $outputPath = Join-Path $runtimeRoot "$taskName.json"
    $errorPath = Join-Path $runtimeRoot "$taskName.err.txt"
    $scriptPath = $PSCommandPath

    $inner = @"
try {
  `$OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
  & '$scriptPath' keys -Json -NoSystem 2> '$errorPath' | Set-Content -Path '$outputPath' -Encoding UTF8
  exit `$LASTEXITCODE
}
catch {
  `$_.Exception.Message | Set-Content -Path '$errorPath' -Encoding UTF8
  exit 1
}
"@

    try {
        if (-not (Test-Path $runtimeRoot)) {
            New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
        }

        $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddSeconds($timeoutSeconds)
        do {
            if (Test-Path $outputPath) {
                break
            }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)

        if (-not (Test-Path $outputPath)) {
            $message = "Timed out waiting for SYSTEM IRK reader task."
            if (Test-Path $errorPath) {
                $errorText = Get-Content -Path $errorPath -Raw -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($errorText)) {
                    $message = "$message $errorText"
                }
            }
            throw $message
        }

        $text = Get-Content -Path $outputPath -Raw -Encoding UTF8
        if ($json) {
            Write-Output $text.Trim()
            return
        }

        $rows = $text | ConvertFrom-Json
        if ($null -eq $rows -or @($rows).Count -eq 0) {
            Write-Host "No IRK values found while running as SYSTEM."
            return
        }

        foreach ($row in @($rows)) {
            "Adapter: {0}  Device: {1}" -f $row.adapter, $row.device | Write-Host
            "  IRK:         {0}" -f $row.irk | Write-Host
            "  IRK reverse: {0}" -f $row.irkReversed | Write-Host
        }
    }
    catch {
        if ($json) {
            Write-Output "[]"
            return
        }
        $adminText = if (Test-IsAdministrator) { "yes" } else { "no" }
        Write-Error ("Cannot run SYSTEM IRK reader. IsAdministrator={0}. Start this command/web UI from an elevated Administrator terminal, and stop any old non-admin web server first. Reason: {1}" -f $adminText, $_.Exception.Message)
        exit 1
    }
    finally {
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Remove-Item -Path $outputPath -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -Path $errorPath -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Invoke-InitCommand {
    param([hashtable]$Options)

    $configPath = Get-StringOption -Options $Options -Names @("config") -Default $DefaultConfigPath
    $existingConfig = Get-Config -Path $configPath
    $irkText = Get-StringOption -Options $Options -Names @("irk") -Default $null
    if ([string]::IsNullOrWhiteSpace($irkText)) {
        throw "Missing -Irk."
    }

    $irk = Normalize-Hex -Value $irkText -Bytes 16 -Label "IRK"
    $settings = ConvertTo-ConfigMap -Config $existingConfig
    $settings["irk"] = $irk
    $settings["nearRssi"] = Get-IntOption -Options $Options -Names @("nearrssi", "near-rssi") -Default ([int](Get-ConfigValue -Config $existingConfig -Name "nearRssi" -Default -70))
    $settings["awayRssi"] = Get-IntOption -Options $Options -Names @("awayrssi", "away-rssi") -Default ([int](Get-ConfigValue -Config $existingConfig -Name "awayRssi" -Default -86))
    $settings["awaySeconds"] = Get-IntOption -Options $Options -Names @("awayseconds", "away-seconds") -Default ([int](Get-ConfigValue -Config $existingConfig -Name "awaySeconds" -Default 30))
    $settings["nearHits"] = Get-IntOption -Options $Options -Names @("nearhits", "near-hits") -Default ([int](Get-ConfigValue -Config $existingConfig -Name "nearHits" -Default 2))
    $settings["lockOnAway"] = Get-BoolOption -Options $Options -Names @("lockonaway", "lock-on-away") -Default ([bool](Get-ConfigValue -Config $existingConfig -Name "lockOnAway" -Default $false))
    $settings["unlockWindowSeconds"] = Get-IntOption -Options $Options -Names @("unlockwindow", "unlock-window") -Default ([int](Get-ConfigValue -Config $existingConfig -Name "unlockWindowSeconds" -Default 30))
    $settings["onNear"] = Get-StringOption -Options $Options -Names @("onnear", "on-near") -Default ([string](Get-ConfigValue -Config $existingConfig -Name "onNear" -Default ""))
    $settings["onAway"] = Get-StringOption -Options $Options -Names @("onaway", "on-away") -Default ([string](Get-ConfigValue -Config $existingConfig -Name "onAway" -Default ""))
    $deviceName = Get-StringOption -Options $Options -Names @("devicename", "device-name", "devicelabel", "device-label") -Default ([string](Get-ConfigValue -Config $existingConfig -Name "deviceName" -Default ""))
    if (-not [string]::IsNullOrWhiteSpace($deviceName)) {
        $settings["deviceName"] = $deviceName
    }

    Save-ConfigMap -Map $settings -Path $configPath
    Write-Host "Saved config: $configPath"
}

function Invoke-RemoveDeviceCommand {
    param([hashtable]$Options)

    $configPath = Get-StringOption -Options $Options -Names @("config") -Default $DefaultConfigPath
    $config = Get-Config -Path $configPath
    if ($null -eq $config) {
        Write-Host "No config found: $configPath"
        return
    }

    $settings = ConvertTo-ConfigMap -Config $config
    foreach ($key in @("irk", "deviceName", "deviceAddress")) {
        if ($settings.Contains($key)) {
            $settings.Remove($key)
        }
    }

    Save-ConfigMap -Map $settings -Path $configPath
    try {
        Clear-ProviderUnlockState -StatePath ([string](Get-ConfigValue -Config $config -Name "statePath" -Default $DefaultStatePath))
    }
    catch {
        Write-Host ("Warning: could not clear unlock state: {0}" -f $_.Exception.Message)
    }
    Write-Host "Removed trusted Bluetooth device from config: $configPath"
}

function Invoke-SetCredentialCommand {
    param([hashtable]$Options)

    $configPath = Get-StringOption -Options $Options -Names @("config") -Default $DefaultConfigPath
    $config = Get-Config -Path $configPath
    $settings = ConvertTo-ConfigMap -Config $config

    $username = Get-StringOption -Options $Options -Names @("username", "user") -Default ([string](Get-ConfigValue -Config $config -Name "username" -Default ""))
    if ([string]::IsNullOrWhiteSpace($username)) {
        throw "Missing -Username. Examples: '.\alice', 'DOMAIN\alice', or 'MicrosoftAccount\name@example.com'."
    }

    $passwordStdin = Get-BoolOption -Options $Options -Names @("passwordstdin", "password-stdin") -Default $false
    $password = Get-StringOption -Options $Options -Names @("password", "pass") -Default $null
    if ($passwordStdin) {
        $password = [Console]::In.ReadToEnd()
        $password = $password.TrimEnd("`r", "`n")
    }
    if ($null -eq $password) {
        $securePassword = Read-Host -AsSecureString -Prompt "Windows password for $username"
        $password = Convert-SecureStringToPlainText -SecureString $securePassword
    }

    if ([string]::IsNullOrEmpty($password)) {
        throw "Password cannot be empty."
    }

    $settings["credentialProviderEnabled"] = $true
    $settings["username"] = $username
    $settings["passwordProtected"] = Protect-TextForMachine -Text $password
    $settings["unlockWindowSeconds"] = Get-IntOption -Options $Options -Names @("unlockwindow", "unlock-window") -Default ([int](Get-ConfigValue -Config $config -Name "unlockWindowSeconds" -Default 30))
    $settings["statePath"] = Get-StringOption -Options $Options -Names @("state", "statepath", "state-path") -Default ([string](Get-ConfigValue -Config $config -Name "statePath" -Default $DefaultStatePath))

    Save-ConfigMap -Map $settings -Path $configPath
    Write-Host "Saved encrypted credential config: $configPath"
    Write-Host "Username: $username"
    $validation = Test-WindowsCredential -Username $username -Password $password
    if ($validation.ok) {
        Write-Host "Credential validation: OK"
    }
    else {
        Write-Host ("Credential validation: FAILED ({0}) {1}" -f $validation.errorCode, $validation.message)
        Write-Host "If this is a Microsoft account, use the account password, not Windows Hello PIN. Passwordless Microsoft accounts may need password sign-in re-enabled."
    }
    Write-Host "Password: encrypted with Windows DPAPI LocalMachine scope"
}

function Get-DefaultProviderDllPath {
    $scriptDir = Split-Path -Parent $PSCommandPath
    return Join-Path $scriptDir "credential-provider\bin\x64\WatchUnlockCredentialProvider.dll"
}

function Invoke-InstallProviderCommand {
    param([hashtable]$Options)

    $dllPath = Get-StringOption -Options $Options -Names @("providerdll", "provider-dll", "dll") -Default (Get-DefaultProviderDllPath)
    if (-not (Test-Path $dllPath)) {
        throw "Credential Provider DLL not found: $dllPath. Build it with credential-provider\build.cmd first."
    }

    $process = Start-Process -FilePath "regsvr32.exe" -ArgumentList @("/s", "`"$dllPath`"") -Wait -PassThru -Verb RunAs
    if ($process.ExitCode -ne 0) {
        throw "regsvr32 failed with exit code $($process.ExitCode)."
    }
    Write-Host "Registered Credential Provider: $dllPath"
}

function Invoke-UninstallProviderCommand {
    param([hashtable]$Options)

    $dllPath = Get-StringOption -Options $Options -Names @("providerdll", "provider-dll", "dll") -Default (Get-DefaultProviderDllPath)
    if (-not (Test-Path $dllPath)) {
        throw "Credential Provider DLL not found: $dllPath."
    }

    $process = Start-Process -FilePath "regsvr32.exe" -ArgumentList @("/u", "/s", "`"$dllPath`"") -Wait -PassThru -Verb RunAs
    if ($process.ExitCode -ne 0) {
        throw "regsvr32 /u failed with exit code $($process.ExitCode)."
    }
    Write-Host "Unregistered Credential Provider: $dllPath"
}

function Invoke-MonitorCommand {
    param([hashtable]$Options)

    $configPath = Get-StringOption -Options $Options -Names @("config") -Default $DefaultConfigPath
    $config = Get-Config -Path $configPath
    $defaultIrk = Get-ConfigValue -Config $config -Name "irk" -Default $null
    $irkText = Get-StringOption -Options $Options -Names @("irk") -Default $defaultIrk
    if ([string]::IsNullOrWhiteSpace($irkText)) {
        throw "Missing -Irk and no saved config found. Run init first or pass -Irk."
    }

    $irk = Convert-HexToBytes -Hex (Normalize-Hex -Value $irkText -Bytes 16 -Label "IRK")
    $nearRssi = Get-IntOption -Options $Options -Names @("nearrssi", "near-rssi") -Default ([int](Get-ConfigValue -Config $config -Name "nearRssi" -Default -70))
    $awayRssi = Get-IntOption -Options $Options -Names @("awayrssi", "away-rssi") -Default ([int](Get-ConfigValue -Config $config -Name "awayRssi" -Default -86))
    $awaySeconds = Get-IntOption -Options $Options -Names @("awayseconds", "away-seconds") -Default ([int](Get-ConfigValue -Config $config -Name "awaySeconds" -Default 30))
    $nearHitsRequired = Get-IntOption -Options $Options -Names @("nearhits", "near-hits") -Default ([int](Get-ConfigValue -Config $config -Name "nearHits" -Default 2))
    $lockOnAway = Get-BoolOption -Options $Options -Names @("lockonaway", "lock-on-away") -Default ([bool](Get-ConfigValue -Config $config -Name "lockOnAway" -Default $false))
    $onNear = Get-StringOption -Options $Options -Names @("onnear", "on-near") -Default ([string](Get-ConfigValue -Config $config -Name "onNear" -Default ""))
    $onAway = Get-StringOption -Options $Options -Names @("onaway", "on-away") -Default ([string](Get-ConfigValue -Config $config -Name "onAway" -Default ""))
    $credentialProviderEnabled = [bool](Get-ConfigValue -Config $config -Name "credentialProviderEnabled" -Default $false)
    $unlockWindowSeconds = Get-IntOption -Options $Options -Names @("unlockwindow", "unlock-window") -Default ([int](Get-ConfigValue -Config $config -Name "unlockWindowSeconds" -Default 30))
    $statePath = Get-StringOption -Options $Options -Names @("state", "statepath", "state-path") -Default ([string](Get-ConfigValue -Config $config -Name "statePath" -Default $DefaultStatePath))
    $signalStatePath = Get-StringOption -Options $Options -Names @("signalstate", "signal-state", "signalstatepath", "signal-state-path") -Default $statePath
    $passive = Get-BoolOption -Options $Options -Names @("passive") -Default $false
    $active = (Get-BoolOption -Options $Options -Names @("active") -Default $true) -and -not $passive
    $once = Get-BoolOption -Options $Options -Names @("once") -Default $false
    $logFile = Get-StringOption -Options $Options -Names @("logfile", "log-file") -Default $null

    if ($awayRssi -ge $nearRssi) {
        throw "-AwayRssi should be weaker than -NearRssi, for example NearRssi=-70 and AwayRssi=-86."
    }

    $sourceId = "watchunlock-monitor-$([Guid]::NewGuid().ToString("N"))"
    $watcherInfo = $null
    $state = "unknown"
    $nearHits = 0
    $lastPresentAt = $null
    $bestRssi = $null
    $lastAddress = ""
    $hasBeenNear = $false

    $scanType = if ($active) { "active" } else { "passive" }
    Write-LogLine -Level "info" -Message ("monitor started; near >= {0} dBm, present >= {1} dBm, away after {2}s, lockOnAway={3}, credentialProvider={4}, scanMode={5}" -f $nearRssi, $awayRssi, $awaySeconds, $lockOnAway, $credentialProviderEnabled, $scanType) -LogFile $logFile

    try {
        if ($credentialProviderEnabled) {
            try {
                Clear-ProviderUnlockState -StatePath $statePath
            }
            catch {
                Write-LogLine -Level "warn" -Message ("could not clear provider state: {0}" -f $_.Exception.Message) -LogFile $logFile
            }
        }

        $watcherInfo = Start-BleWatcher -SourceIdentifier $sourceId -Active $active
        while ($true) {
            $events = Receive-BleEvents -WatcherInfo $watcherInfo -TimeoutSeconds 1
            $now = Get-Date

            foreach ($event in $events) {
                try {
                    $info = Get-AdvertisementInfo -EventArgs $event.SourceEventArgs
                    $match = Resolve-RpaAddress -Address $info.address -Irk $irk
                    if (-not $match.matched) {
                        continue
                    }

                    $lastAddress = $info.address
                    if ($null -eq $bestRssi -or $info.rssi -gt $bestRssi) {
                        $bestRssi = $info.rssi
                    }

                    if ($info.rssi -ge $awayRssi) {
                        $lastPresentAt = $now
                    }

                    if ($info.rssi -ge $nearRssi) {
                        $nearHits++
                    }
                    else {
                        $nearHits = 0
                    }
                    $presence = if ($info.rssi -ge $nearRssi) { "near" } elseif ($info.rssi -ge $awayRssi) { "present" } else { "weak" }
                    try {
                        Set-MonitorSignalState -StatePath $signalStatePath -Address $info.address -Rssi $info.rssi -BestRssi $bestRssi -Presence $presence -NearHits $nearHits
                    }
                    catch {
                        Write-LogLine -Level "warn" -Message ("could not write monitor signal state: {0}" -f $_.Exception.Message) -LogFile $logFile
                    }

                    if ($state -ne "near" -and $nearHits -ge $nearHitsRequired) {
                        $state = "near"
                        $hasBeenNear = $true
                        Write-LogLine -Level "info" -Message ("near: {0}, rssi={1} dBm, best={2} dBm" -f $info.address, $info.rssi, $bestRssi) -LogFile $logFile
                        if ($credentialProviderEnabled) {
                            try {
                                Set-ProviderUnlockState -StatePath $statePath -UnlockWindowSeconds $unlockWindowSeconds -Address $info.address -Rssi $info.rssi
                                Write-LogLine -Level "info" -Message ("credential provider unlock window opened for {0}s" -f $unlockWindowSeconds) -LogFile $logFile
                            }
                            catch {
                                Write-LogLine -Level "warn" -Message ("could not write provider unlock state: {0}" -f $_.Exception.Message) -LogFile $logFile
                            }
                        }
                        Invoke-UserCommand -CommandLine $onNear
                        if ($once) {
                            return
                        }
                    }
                }
                finally {
                    Complete-BleEvent -Event $event
                }
            }

            if ($hasBeenNear -and $state -ne "away" -and $null -ne $lastPresentAt) {
                $elapsed = ($now - $lastPresentAt).TotalSeconds
                if ($elapsed -ge $awaySeconds) {
                    $state = "away"
                    $nearHits = 0
                    $bestRssi = $null
                    Write-LogLine -Level "info" -Message ("away: last={0}, missing_or_weak_for={1:N0}s" -f $lastAddress, $elapsed) -LogFile $logFile
                    if ($credentialProviderEnabled) {
                        try {
                            Clear-ProviderUnlockState -StatePath $statePath
                        }
                        catch {
                            Write-LogLine -Level "warn" -Message ("could not clear provider state: {0}" -f $_.Exception.Message) -LogFile $logFile
                        }
                    }
                    Invoke-UserCommand -CommandLine $onAway
                    if ($lockOnAway) {
                        Write-LogLine -Level "info" -Message "locking workstation" -LogFile $logFile
                        Invoke-LockWorkstation
                    }
                    if ($once) {
                        return
                    }
                }
            }
        }
    }
    finally {
        Stop-BleWatcher -WatcherInfo $watcherInfo -SourceIdentifier $sourceId
        Write-LogLine -Level "info" -Message "monitor stopped" -LogFile $logFile
    }
}

function Invoke-SelfTestCommand {
    param([hashtable]$Options)

    $noBluetooth = Get-BoolOption -Options $Options -Names @("nobluetooth", "no-bluetooth") -Default $false
    $irk = Convert-HexToBytes -Hex "00112233445566778899AABBCCDDEEFF"
    $prand = [byte[]](0x40, 0x11, 0x22)
    $block = Join-Bytes -Left (New-Object byte[] 13) -Right $prand
    $encrypted = Invoke-AesBlock -Key $irk -Block $block
    $hash = Get-SubBytes -Bytes $encrypted -Start 13 -Length 3
    $prandHash = Join-Bytes -Left $prand -Right $hash
    $hashPrand = Join-Bytes -Left $hash -Right $prand
    $reversedHashPrand = Reverse-Bytes -Bytes $hashPrand
    $addresses = @(
        (Convert-BytesToHex -Bytes $prandHash),
        (Convert-BytesToHex -Bytes $hashPrand),
        (Convert-BytesToHex -Bytes $reversedHashPrand)
    )

    foreach ($address in $addresses) {
        $match = Resolve-RpaAddress -Address $address -Irk $irk
        if (-not $match.matched) {
            throw "RPA resolver self-test failed for address $address."
        }
    }

    Write-Host "PASS: RPA resolver"
    if (-not $noBluetooth) {
        Ensure-BluetoothRuntime
        $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()
        if ($watcher.Status.ToString() -ne "Created") {
            throw "BLE watcher self-test failed."
        }

        Write-Host "PASS: BLE watcher creation"
    }
    else {
        Write-Host "SKIP: BLE watcher creation"
    }
}

$Command = Get-CommandName @args
$Options = Parse-Options -RawOptions (Get-RawOptions @args)

try {
    switch ($Command) {
        "help" { Show-Help }
        "-h" { Show-Help }
        "--help" { Show-Help }
        "scan" { Invoke-ScanCommand -Options $Options }
        "scan-test" { Invoke-ScanTestCommand -Options $Options }
        "paired" { Invoke-PairedCommand -Options $Options }
        "keys" { Invoke-KeysCommand -Options $Options }
        "keys-system" { Invoke-KeysSystemCommand -Options $Options }
        "resolve" { Invoke-ResolveCommand -Options $Options }
        "init" { Invoke-InitCommand -Options $Options }
        "remove-device" { Invoke-RemoveDeviceCommand -Options $Options }
        "set-credential" { Invoke-SetCredentialCommand -Options $Options }
        "monitor" { Invoke-MonitorCommand -Options $Options }
        "install-provider" { Invoke-InstallProviderCommand -Options $Options }
        "uninstall-provider" { Invoke-UninstallProviderCommand -Options $Options }
        "lock" { Invoke-LockWorkstation }
        "selftest" { Invoke-SelfTestCommand -Options $Options }
        default {
            throw "Unknown command: $Command. Run '.\$ScriptName help'."
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
