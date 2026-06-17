# Copyright (c) 2026 JACK <2518926462@qq.com>

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$OutputDir = "",
    [switch]$SkipBuild
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$Root = Resolve-Path (Join-Path $ScriptDir "..")
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $Root "dist"
}

function Invoke-Cmd {
    param([Parameter(Mandatory = $true)][string]$Path)

    & cmd.exe /d /c "`"$Path`""
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Path"
    }
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "Missing required file: $Source"
    }
    $folder = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Get-PackageVersion {
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        return $Version
    }

    try {
        $gitVersion = (& git -C $Root describe --tags --always --dirty 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($gitVersion)) {
            return [string]$gitVersion
        }
    }
    catch {
    }

    return Get-Date -Format "yyyyMMdd-HHmmss"
}

if (-not $SkipBuild) {
    Invoke-Cmd -Path (Join-Path $Root "native-monitor\build.cmd")
    Invoke-Cmd -Path (Join-Path $Root "credential-provider\build.cmd")
}

$NativeExe = Join-Path $Root "native-monitor\bin\x64\watchunlock-native.exe"
$ProviderDll = Join-Path $Root "credential-provider\bin\x64\WatchUnlockCredentialProvider.dll"
if (-not (Test-Path $NativeExe)) {
    throw "Missing native monitor binary. Run native-monitor\build.cmd first."
}
if (-not (Test-Path $ProviderDll)) {
    throw "Missing Credential Provider DLL. Run credential-provider\build.cmd first."
}

$PackageVersion = Get-PackageVersion
$SafeVersion = ($PackageVersion -replace "[^0-9A-Za-z._-]", "-").Trim("-")
if ([string]::IsNullOrWhiteSpace($SafeVersion)) {
    $SafeVersion = "dev"
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$Stage = Join-Path $OutputDir "watchunlock-$SafeVersion"
$ZipPath = Join-Path $OutputDir "watchunlock-$SafeVersion.zip"
if (Test-Path $Stage) {
    Remove-Item -LiteralPath $Stage -Recurse -Force
}
if (Test-Path $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}

New-Item -ItemType Directory -Path $Stage -Force | Out-Null

foreach ($file in @("README.md", "watchunlock.cmd", "watchunlock.ps1", "web.cmd", "web-stop.cmd")) {
    Copy-RequiredFile -Source (Join-Path $Root $file) -Destination (Join-Path $Stage $file)
}

Copy-Item -LiteralPath (Join-Path $Root "web") -Destination (Join-Path $Stage "web") -Recurse -Force
if (Test-Path (Join-Path $Stage "web\.runtime")) {
    Remove-Item -LiteralPath (Join-Path $Stage "web\.runtime") -Recurse -Force
}

foreach ($file in @("build.cmd", "install.cmd", "uninstall.cmd", "README.md", "WatchUnlockCredentialProvider.cpp", "WatchUnlockCredentialProvider.def")) {
    Copy-RequiredFile -Source (Join-Path $Root "credential-provider\$file") -Destination (Join-Path $Stage "credential-provider\$file")
}
Copy-RequiredFile -Source $ProviderDll -Destination (Join-Path $Stage "credential-provider\bin\x64\WatchUnlockCredentialProvider.dll")

foreach ($file in @("build.cmd", "WatchUnlockNativeMonitor.cpp")) {
    Copy-RequiredFile -Source (Join-Path $Root "native-monitor\$file") -Destination (Join-Path $Stage "native-monitor\$file")
}
Copy-RequiredFile -Source $NativeExe -Destination (Join-Path $Stage "native-monitor\bin\x64\watchunlock-native.exe")

$Commit = ""
try {
    $Commit = (& git -C $Root rev-parse --short HEAD 2>$null)
}
catch {
}

@"
WatchUnlock $PackageVersion
Built: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")
Commit: $Commit

Run web.cmd to configure the trusted Bluetooth device, Windows credential, Credential Provider, and monitor.
"@ | Set-Content -Path (Join-Path $Stage "VERSION.txt") -Encoding UTF8

Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $ZipPath -Force
Write-Host "Package: $ZipPath"
