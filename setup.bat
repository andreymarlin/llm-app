@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if errorlevel 1 (
    echo.
    echo Настройка завершилась с ошибкой. Смотрите сообщения выше.
    pause
)
