@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
rem Startup is now split into two separate processes:
rem   start-broker.bat  = backend answerer (RAG + AI, holds the keys)
rem   start-chat.bat    = user-facing chat screen (open the SharePoint page + chat UI)
rem Run start-broker once, and start-chat for each user. This file just launches the broker.
rem If you get "running scripts is disabled", run once in PowerShell:
rem   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
powershell -NoProfile -File "%~dp0broker.ps1" -Role broker
echo.
echo exit code: %ERRORLEVEL%
pause
