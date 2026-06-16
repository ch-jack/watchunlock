@echo off
rem Copyright (c) 2026 JACK <2518926462@qq.com>
setlocal

set "ROOT=%~dp0"
set "PORT=8765"
if not "%~1"=="" set "PORT=%~1"

set "LISTEN_PID="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do (
  set "LISTEN_PID=%%P"
)

if defined LISTEN_PID (
  echo WatchUnlock Web is already running on http://127.0.0.1:%PORT%
  echo PID: %LISTEN_PID%
  exit /b 0
)

node "%ROOT%web\server.js" %PORT%
exit /b %ERRORLEVEL%
