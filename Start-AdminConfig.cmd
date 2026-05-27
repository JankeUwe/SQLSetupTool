@echo off
:: Admin-Konfiguration: settings.ini (Pfade, Features, Optionen)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-AdminConfig.ps1"
