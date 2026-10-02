@echo off
rem Build fff as a DLL. Safe to run while fff_dev.exe is running: the host
rem copies the DLL before loading it, so the compiler can always overwrite this.
setlocal
cd /d "%~dp0"
if not exist build\hot_reload mkdir build\hot_reload

rem The DLL uses raylib.dll (RAYLIB_SHARED), which must sit next to the exe.
rem `odin root` may or may not end in a backslash; strip one if it does.
for /f "delims=" %%i in ('odin root') do set "ODIN_ROOT=%%i"
if "%ODIN_ROOT:~-1%"=="\" set "ODIN_ROOT=%ODIN_ROOT:~0,-1%"
if not exist build\raylib.dll (
    copy "%ODIN_ROOT%\vendor\raylib\windows\raylib.dll" build\ >nul
    if errorlevel 1 (
        echo could not copy raylib.dll from "%ODIN_ROOT%\vendor\raylib\windows\"
        exit /b 1
    )
)

rem RAYLIB_SHARED: every reload must share the one raylib that owns the window.
odin build source -build-mode:dll -define:RAYLIB_SHARED=true -out:build\hot_reload\fff.dll -debug
if errorlevel 1 exit /b 1

rem Only rebuild the host when it is not already running.
tasklist /fi "imagename eq fff_dev.exe" | find /i "fff_dev.exe" >nul
if errorlevel 1 (
    odin build main_hot_reload -out:build\fff_dev.exe -debug
    if errorlevel 1 exit /b 1
)
echo ok - run build\fff_dev.exe [folder]   (F5 reloads, F6 restarts)
