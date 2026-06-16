@echo off
rem Copyright (c) 2026 JACK <2518926462@qq.com>
setlocal

set "DLL=%~dp0bin\x64\WatchUnlockCredentialProvider.dll"
if not exist "%DLL%" (
  echo Missing "%DLL%".
  exit /b 1
)

regsvr32.exe /u /s "%DLL%"
if errorlevel 1 (
  echo regsvr32 /u failed. Run this command as Administrator.
  exit /b 1
)

echo Unregistered WatchUnlock Credential Provider.
