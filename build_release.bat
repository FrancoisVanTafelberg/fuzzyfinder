@echo off
rem Build fff.exe: one file, raylib and the font linked in. Put it anywhere on
rem your PATH and run `fff` in the folder you want to search.
setlocal
cd /d "%~dp0"
if not exist build mkdir build
odin build main_release -out:build\fff.exe -o:speed -no-bounds-check -subsystem:windows
if errorlevel 1 exit /b 1
echo ok - build\fff.exe
