@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
rem User-facing chat: opens the SharePoint page and injects the chat UI (its own Edge profile +
rem debug port, separate from the broker). Posts questions to the list and shows answers. No AI
rem keys here. Answers only appear while a broker (start-broker.bat) is running.
rem If you get "running scripts is disabled", run once in PowerShell:
rem   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
powershell -NoProfile -File "%~dp0broker.ps1" -Role chat
echo.
echo exit code: %ERRORLEVEL%
pause
