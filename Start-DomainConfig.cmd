@echo off
:: Domain-Konfiguration: Config\domains\*.ini (Collation, Gruppen, Laufwerke, ZIP-Pfad)
"%~dp0SQLSetupTool.exe" --domain-config "%~dp0Config"
