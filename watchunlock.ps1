# Copyright (c) 2026 JACK <2518926462@qq.com>

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

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
  keys       Try to list paired Bluetooth LE IRKs from the Windows registry.
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
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) {
        return ""
    }
    return (($Bytes | ForEach-Object { $_.ToString("X2") }) -join "")
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
}

function Start-BleWatcher {
    param([string]$SourceIdentifier)

    Ensure-BluetoothRuntime
    $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()
    $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active
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

function Resolve-RpaAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][byte[]]$Irk
    )

    $addressHex = Normalize-Hex -Value $Address -Bytes 6 -Label "Bluetooth address"
    $addr = Convert-HexToBytes -Hex $addressHex
    $keys = @($Irk, @($Irk[15..0]))

    $layouts = @(
        @{ Name = "prand-high/hash-low"; PrandStart = 0; HashStart = 3; RpaByte = 0 },
        @{ Name = "hash-high/prand-low"; PrandStart = 3; HashStart = 0; RpaByte = 3 }
    )

    foreach ($layout in $layouts) {
        $marker = $addr[$layout.RpaByte] -band 0xC0
        if ($marker -ne 0x40) {
            continue
        }

        $prand = Get-SubBytes -Bytes $addr -Start $layout.PrandStart -Length 3
        $observedHash = Get-SubBytes -Bytes $addr -Start $layout.HashStart -Length 3

        $blocks = @(
            @{ Name = "tail-prand"; Block = Join-Bytes -Left (New-Object byte[] 13) -Right $prand },
            @{ Name = "head-prand"; Block = Join-Bytes -Left $prand -Right (New-Object byte[] 13) }
        )

        foreach ($keyCandidate in $keys) {
            $keyName = if (Test-ByteArrayEqual -Left $keyCandidate -Right $Irk) { "key" } else { "reversed-key" }
            foreach ($blockCandidate in $blocks) {
                $encrypted = Invoke-AesBlock -Key ([byte[]]$keyCandidate) -Block ([byte[]]$blockCandidate.Block)
                $hashes = @(
                    @{ Name = "tail-hash"; Hash = Get-SubBytes -Bytes $encrypted -Start 13 -Length 3 },
                    @{ Name = "head-hash"; Hash = Get-SubBytes -Bytes $encrypted -Start 0 -Length 3 }
                )

                foreach ($hashCandidate in $hashes) {
                    if (Test-ByteArrayEqual -Left ([byte[]]$hashCandidate.Hash) -Right $observedHash) {
                        return [pscustomobject]@{
                            matched   = $true
                            layout    = $layout.Name
                            keyOrder  = $keyName
                            blockMode = $blockCandidate.Name
                            hashMode  = $hashCandidate.Name
                        }
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        matched   = $false
        layout    = ""
        keyOrder  = ""
        blockMode = ""
        hashMode  = ""
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

    @($Items) | ConvertTo-Json -Depth $Depth
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

function Invoke-ScanCommand {
    param([hashtable]$Options)

    $seconds = Get-IntOption -Options $Options -Names @("seconds", "s") -Default 20
    $rssiMin = Get-IntOption -Options $Options -Names @("rssimin", "rssi-min") -Default -100
    $json = Get-BoolOption -Options $Options -Names @("json") -Default $false
    $continuous = Get-BoolOption -Options $Options -Names @("continuous") -Default $false
    $sourceId = "watchunlock-scan-$([Guid]::NewGuid().ToString("N"))"
    $watcherInfo = $null
    $seen = @{}
    $records = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($seconds)

    try {
        $watcherInfo = Start-BleWatcher -SourceIdentifier $sourceId
        if (-not $json) {
            Write-Host ("Scanning for {0}s, RSSI >= {1} dBm..." -f $seconds, $rssiMin)
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
    $sourceId = "watchunlock-resolve-$([Guid]::NewGuid().ToString("N"))"
    $watcherInfo = $null
    $seen = @{}
    $matches = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($seconds)

    try {
        $watcherInfo = Start-BleWatcher -SourceIdentifier $sourceId
        if (-not $json) {
            Write-Host ("Resolving for {0}s, RSSI >= {1} dBm..." -f $seconds, $rssiMin)
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
    $root = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys"
    $rows = New-Object System.Collections.ArrayList

    try {
        if (-not (Test-Path $root)) {
            throw "Bluetooth key registry path not found: $root"
        }
        $adapters = @(Get-ChildItem -Path $root -ErrorAction Stop)
    }
    catch {
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

    Write-LogLine -Level "info" -Message ("monitor started; near >= {0} dBm, present >= {1} dBm, away after {2}s, lockOnAway={3}, credentialProvider={4}" -f $nearRssi, $awayRssi, $awaySeconds, $lockOnAway, $credentialProviderEnabled) -LogFile $logFile

    try {
        if ($credentialProviderEnabled) {
            Clear-ProviderUnlockState -StatePath $statePath
        }

        $watcherInfo = Start-BleWatcher -SourceIdentifier $sourceId
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

                    if ($state -ne "near" -and $nearHits -ge $nearHitsRequired) {
                        $state = "near"
                        $hasBeenNear = $true
                        Write-LogLine -Level "info" -Message ("near: {0}, rssi={1} dBm, best={2} dBm" -f $info.address, $info.rssi, $bestRssi) -LogFile $logFile
                        if ($credentialProviderEnabled) {
                            Set-ProviderUnlockState -StatePath $statePath -UnlockWindowSeconds $unlockWindowSeconds -Address $info.address -Rssi $info.rssi
                            Write-LogLine -Level "info" -Message ("credential provider unlock window opened for {0}s" -f $unlockWindowSeconds) -LogFile $logFile
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
                        Clear-ProviderUnlockState -StatePath $statePath
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
    $irk = Convert-HexToBytes -Hex "00112233445566778899AABBCCDDEEFF"
    $prand = [byte[]](0x40, 0x11, 0x22)
    $block = Join-Bytes -Left (New-Object byte[] 13) -Right $prand
    $encrypted = Invoke-AesBlock -Key $irk -Block $block
    $hash = Get-SubBytes -Bytes $encrypted -Start 13 -Length 3
    $addrBytes = Join-Bytes -Left $prand -Right $hash
    $address = Convert-BytesToHex -Bytes $addrBytes
    $match = Resolve-RpaAddress -Address $address -Irk $irk

    if (-not $match.matched) {
        throw "RPA resolver self-test failed."
    }

    Ensure-BluetoothRuntime
    $watcher = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher]::new()
    if ($watcher.Status.ToString() -ne "Created") {
        throw "BLE watcher self-test failed."
    }

    Write-Host "PASS: RPA resolver"
    Write-Host "PASS: BLE watcher creation"
}

$Command = Get-CommandName @args
$Options = Parse-Options -RawOptions (Get-RawOptions @args)

try {
    switch ($Command) {
        "help" { Show-Help }
        "-h" { Show-Help }
        "--help" { Show-Help }
        "scan" { Invoke-ScanCommand -Options $Options }
        "keys" { Invoke-KeysCommand -Options $Options }
        "resolve" { Invoke-ResolveCommand -Options $Options }
        "init" { Invoke-InitCommand -Options $Options }
        "remove-device" { Invoke-RemoveDeviceCommand -Options $Options }
        "set-credential" { Invoke-SetCredentialCommand -Options $Options }
        "monitor" { Invoke-MonitorCommand -Options $Options }
        "install-provider" { Invoke-InstallProviderCommand -Options $Options }
        "uninstall-provider" { Invoke-UninstallProviderCommand -Options $Options }
        "lock" { Invoke-LockWorkstation }
        "selftest" { Invoke-SelfTestCommand }
        default {
            throw "Unknown command: $Command. Run '.\$ScriptName help'."
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
