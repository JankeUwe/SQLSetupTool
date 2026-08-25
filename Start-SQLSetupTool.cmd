@echo off
:: ============================================================
:: Start-SQLSetupTool.cmd
:: ============================================================
:: Kopiert das Tool nach C:\ProgramData\SQLSetupTool und
:: startet es als Administrator (UAC).
::
:: Warum ProgramData?
::   - Nach UAC-Elevation ist W:\ nicht mehr erreichbar
::   - AppLocker/AV-unbedenklich
::   - Nicht von Cleanup-Scripts betroffen
::
:: Verwendung: Doppelklick vom Share genuegt.
:: ============================================================
setlocal EnableDelayedExpansion

set "SRCDIR=%~dp0"
set "LOCALDIR=%ProgramData%\SQLSetupTool"
set "LOCALEXE=%LOCALDIR%\SQLSetupTool.exe"

echo.
echo  Start-SQLSetupTool
echo  ============================================================
echo  Dieser Rechner : %COMPUTERNAME%
echo  Quelle         : %SRCDIR%
echo  Ziel           : %LOCALDIR%
echo.

if /I "%SESSIONNAME:~0,7%"=="Console" (
    echo  WARNUNG: Diese Sitzung ist keine RDP-Sitzung ^(SESSIONNAME=%SESSIONNAME%^).
    echo  %%ProgramData%% zeigt dann auf DIESEN Rechner ^(%COMPUTERNAME%^), nicht auf den
    echo  SQL-Zielserver. Falls %COMPUTERNAME% nicht der Zielserver ist: erst per RDP auf
    echo  den Zielserver verbinden, dort zum Share navigieren und das Skript von DORT
    echo  aus starten - sonst installiert das Tool moeglicherweise auf dem falschen
    echo  Rechner bzw. schlaegt mangels Berechtigung auf %%ProgramData%% fehl.
    echo.
    choice /M "Trotzdem hier auf %COMPUTERNAME% fortfahren"
    if errorlevel 2 (
        endlocal
        exit /b 1
    )
    echo.
)

if not exist "%LOCALDIR%" (
    mkdir "%LOCALDIR%"
    if errorlevel 1 (
        echo  FEHLER: Verzeichnis konnte nicht angelegt werden: %LOCALDIR%
        pause
        exit /b 1
    )
)

xcopy /Y /Q /E "%SRCDIR%." "%LOCALDIR%\" >nul 2>&1
if errorlevel 1 (
    echo  FEHLER: Kopieren fehlgeschlagen.
    pause
    exit /b 1
)

echo  Dateien bereit - starte als Administrator ...
echo.

powershell.exe -NoProfile -Command ^
    "Start-Process -FilePath '%LOCALEXE%' -Verb RunAs"

endlocal
