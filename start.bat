@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
rem PowerShell broker (no Python). If you get "running scripts is disabled",
rem run once in PowerShell:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
powershell -NoProfile -File "%~dp0broker.ps1"
echo.
echo exit code: %ERRORLEVEL%
pause
