@echo off
rem Copyright (c) 2026 JACK <2518926462@qq.com>
setlocal

set "ROOT=%~dp0"
set "OUT=%ROOT%bin\x64"
set "SRC=%ROOT%WatchUnlockNativeMonitor.cpp"

where cl.exe >nul 2>nul
if errorlevel 1 call :load_vs_env
if errorlevel 1 exit /b %ERRORLEVEL%

if not exist "%OUT%" mkdir "%OUT%"

cl.exe /nologo /std:c++17 /EHsc /W4 /permissive- /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX /D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS ^
  /Fe:"%OUT%\watchunlock-native.exe" ^
  /Fo:"%OUT%\WatchUnlockNativeMonitor.obj" ^
  "%SRC%" ^
  /link windowsapp.lib bcrypt.lib user32.lib ole32.lib shell32.lib

exit /b %ERRORLEVEL%

:load_vs_env
set "VSWHERE=C:\PROGRA~2\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=C:\Program Files\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo cl.exe was not found, and vswhere.exe was not found.
  echo Install Visual Studio Build Tools with the C++ workload and Windows SDK.
  exit /b 1
)

set "VCVARS="
for /f "delims=" %%I in ('"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find VC\Auxiliary\Build\vcvars64.bat') do set "VCVARS=%%I"
if not defined VCVARS (
  for /f "delims=" %%I in ('"%VSWHERE%" -latest -products * -find VC\Auxiliary\Build\vcvars64.bat') do set "VCVARS=%%I"
)
if not defined VCVARS (
  echo cl.exe was not found.
  echo Install the "Desktop development with C++" workload and Windows SDK.
  exit /b 1
)

call "%VCVARS%"
exit /b %ERRORLEVEL%
