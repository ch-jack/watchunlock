@echo off
rem Copyright (c) 2026 JACK <2518926462@qq.com>
setlocal

set "DLL=%~dp0bin\x64\WatchUnlockCredentialProvider.dll"
if not exist "%DLL%" (
  echo Missing "%DLL%".
  echo Run build.cmd first.
  exit /b 1
)

regsvr32.exe /s "%DLL%"
if errorlevel 1 (
  echo regsvr32 failed. Run this command as Administrator.
  exit /b 1
)

echo Registered WatchUnlock Credential Provider.
