@echo off
:: ============================================================
:: Start-DomainConfig.cmd
:: Startet den Domain-Profil-Editor.
:: Bearbeitet: Config\domains\*.ini
:: (Sortierung, Sysadmin-Gruppen, Monitoring, Laufwerke,
::  Ziel-Server-Pfad je Domaene)
:: ============================================================
setlocal

set "TOOLDIR=%~dp0"
set "CONFIGDIR=%TOOLDIR%Config"
set "DOMFORM=%TOOLDIR%GUI\DomainConfigForm.ps1"

if not exist "%DOMFORM%" (
    echo FEHLER: DomainConfigForm.ps1 nicht gefunden: %DOMFORM%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    ". '%DOMFORM%'; Show-DomainConfigForm -ConfigDir '%CONFIGDIR%'"

endlocal
