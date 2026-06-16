@echo off
rem Copyright (c) 2026 JACK <2518926462@qq.com>
setlocal

set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%watchunlock.ps1" %*
exit /b %ERRORLEVEL%
