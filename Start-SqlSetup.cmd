@echo off
:: ============================================================
:: Start-SqlSetup.cmd
:: ============================================================
:: Headless CLI launcher for Start-SqlSetup.ps1.
:: Self-elevates via UAC (forwarding all arguments) and runs the
:: PowerShell script with ExecutionPolicy Bypass. Works on a
:: double-click as well as from a command prompt.
::
:: Examples:
::   Start-SqlSetup.cmd -Version 2022 -Edition Developer -NonInteractive
::   Start-SqlSetup.cmd -Version 2025 -Edition Developer-Standard -InstanceName SQL01 -WhatIf
::   Start-SqlSetup.cmd -Version 2022 -NonInteractive -AlwaysOn -AvailabilityGroupName ProdAG -AgDatabase AppDb
:: ============================================================
setlocal EnableExtensions

set "SCRIPTDIR=%~dp0"
set "PS1=%SCRIPTDIR%Start-SqlSetup.ps1"

if not exist "%PS1%" (
    echo  FEHLER: Start-SqlSetup.ps1 nicht gefunden: "%PS1%"
    echo.
    pause
    exit /b 1
)

:: Already elevated? net session only succeeds with admin rights.
net session >nul 2>&1
if not errorlevel 1 goto :run

:: Not elevated -> relaunch this script elevated (UAC), forwarding all arguments.
echo  Fordere Administrator-Rechte an - bitte UAC-Dialog bestaetigen ...
if "%~1"=="" (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
)
exit /b 0

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
echo.
echo  Beendet (ExitCode %RC%). Fenster kann geschlossen werden.
pause
endlocal & exit /b %RC%
