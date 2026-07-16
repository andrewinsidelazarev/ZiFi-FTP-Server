@echo off
setlocal
chcp 65001
cd /d "%~dp0"

call build.bat
if errorlevel 1 exit /b 1

python -m unittest discover -s tests -v
if errorlevel 1 exit /b 1

python tools\verify_build.py
if errorlevel 1 exit /b 1

echo Все проверки пройдены.
