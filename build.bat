@echo off
setlocal
chcp 65001
cd /d "%~dp0\src"

set "SJASM="
if defined SJASMPLUS if exist "%SJASMPLUS%" set "SJASM=%SJASMPLUS%"
if not defined SJASM if exist "C:\z80\zuma\sjasmplus.exe" set "SJASM=C:\z80\zuma\sjasmplus.exe"
if not defined SJASM if exist "..\..\ZiFi\sjasmplus.exe" set "SJASM=..\..\ZiFi\sjasmplus.exe"
if not defined SJASM (
  where sjasmplus.exe
  if not errorlevel 1 set "SJASM=sjasmplus.exe"
)
if not defined SJASM (
  echo Ошибка: sjasmplus.exe не найден.
  exit /b 1
)

"%SJASM%" --sym=..\ZIFIFTP.sym --lst=..\ZIFIFTP.lst main.asm
if errorlevel 1 exit /b 1

echo Собрано: %~dp0ZIFIFTP.WMF
