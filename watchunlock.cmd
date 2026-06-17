@echo off
rem Copyright (c) 2026 JACK <2518926462@qq.com>
setlocal

set "SCRIPT_DIR=%~dp0"
if /I "%~1"=="monitor" if exist "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" (
  "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" %*
  exit /b %ERRORLEVEL%
)
if /I "%~1"=="scan" if exist "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" (
  "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" %*
  exit /b %ERRORLEVEL%
)
if /I "%~1"=="scan-test" if exist "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" (
  "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" %*
  exit /b %ERRORLEVEL%
)
if /I "%~1"=="resolve" if exist "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" (
  "%SCRIPT_DIR%native-monitor\bin\x64\watchunlock-native.exe" %*
  exit /b %ERRORLEVEL%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%watchunlock.ps1" %*
exit /b %ERRORLEVEL%
