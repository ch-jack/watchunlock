@echo off
rem Copyright (c) 2026 JACK <2518926462@qq.com>
setlocal

set "PORT=8765"
if not "%~1"=="" set "PORT=%~1"

set "FOUND="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /R /C:":%PORT% .*LISTENING"') do (
  set "FOUND=1"
  echo Stopping WatchUnlock Web on http://127.0.0.1:%PORT%  PID: %%P
  taskkill /PID %%P /T /F >nul 2>nul
  if errorlevel 1 (
    echo Failed to stop PID %%P. Try running this command as Administrator.
    exit /b 1
  )
)

if not defined FOUND (
  echo WatchUnlock Web is not running on http://127.0.0.1:%PORT%
)

exit /b 0
