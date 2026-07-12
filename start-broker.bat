@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
rem Backend answerer: polls the QA_PoC list, runs RAG + AI, writes answers back. No chat UI here.
rem Holds the AI keys / embeddings / cosine. Run ONE of these; it answers every chat.
rem If you get "running scripts is disabled", run once in PowerShell:
rem   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
powershell -NoProfile -File "%~dp0broker.ps1" -Role broker
echo.
echo exit code: %ERRORLEVEL%
pause
