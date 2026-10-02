@echo off
rem The headless tests: the matcher and the ignore rules.
cd /d "%~dp0"
odin test source\fuzzy || exit /b 1
odin test source\ignore || exit /b 1
