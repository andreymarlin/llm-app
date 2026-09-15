@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
if errorlevel 1 (
    echo.
    echo Приложение завершилось с ошибкой. Смотрите сообщения выше.
    pause
)
