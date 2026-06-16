# WatchUnlock Credential Provider

Copyright (c) 2026 JACK <2518926462@qq.com>

This native DLL is the Windows logon piece. The PowerShell/cmd monitor detects the trusted BLE device and writes:

`%ProgramData%\WatchUnlockCli\state.json`

The provider reads that state plus:

`%ProgramData%\WatchUnlockCli\config.json`

When `allowUnlockUntil` is still valid and the `unlockToken` was not already consumed, it loads the saved username and DPAPI-protected password, packs them with `CredPackAuthenticationBufferW`, and asks LogonUI to submit them.

## Build

Install Visual Studio Build Tools with:

- Desktop development with C++
- Windows 10/11 SDK

Then open **x64 Native Tools Command Prompt for VS**:

```cmd
cd /d C:\Users\Administrator\Documents\watchunlock\credential-provider
build.cmd
```

## Install

Run as Administrator:

```cmd
install.cmd
```

or from the repository root:

```cmd
watchunlock.cmd install-provider
```

## Uninstall

Run as Administrator:

```cmd
uninstall.cmd
```

or:

```cmd
watchunlock.cmd uninstall-provider
```
