@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-aab-ui.ps1"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
    echo.
    echo Installer closed with error code %EXITCODE%.
    if exist "%~dp0aab-install-last.log" (
        echo.
        echo Last installer log:
        type "%~dp0aab-install-last.log"
    )
    echo.
    pause
)
exit /b %EXITCODE%