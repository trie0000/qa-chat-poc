@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" broker.py
) else (
  python broker.py
)
echo.
echo exit code: %ERRORLEVEL%
pause
