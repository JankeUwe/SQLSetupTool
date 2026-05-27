@echo off
:: Domain-Konfiguration: Config\domains\*.ini (Collation, Gruppen, Laufwerke, ZIP-Pfad)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DomainConfig.ps1"
