@echo off
:: ============================================================
:: Start-AdminConfig.cmd
:: Startet das Konfigurationsformular direkt (Admin-Tool).
:: Bearbeitet: settings.ini (Pfade, Features, Optionen).
:: Fuer Domain-Konfiguration: Start-DomainConfig.cmd verwenden.
:: ============================================================
setlocal

set "TOOLDIR=%~dp0"
set "INIPATH=%TOOLDIR%Config\settings.ini"
set "CFGFORM=%TOOLDIR%GUI\ConfigForm.ps1"

if not exist "%CFGFORM%" (
    echo FEHLER: ConfigForm.ps1 nicht gefunden: %CFGFORM%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    ". '%CFGFORM%'; Show-ConfigForm -IniPath '%INIPATH%'"

endlocal
