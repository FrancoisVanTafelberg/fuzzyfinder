@echo off
rem Build (if needed) and start the hot-reload build, searching this repo.
cd /d "%~dp0"
call build_hot_reload.bat || exit /b 1
start "" build\fff_dev.exe .
