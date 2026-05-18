# SQLSetupTool

PowerShell WinForms-Tool zur vollautomatischen Installation und Konfiguration von SQL Server — entwickelt von [dtcSoftware](https://www.powershelldba.de) (Uwe Janke).

## Übersicht

`SQLSetupTool` ist eine grafische PowerShell-Anwendung (WinForms) die eine standardisierte, reproduzierbare SQL Server Installation auf Basis einer zentralen INI-Konfiguration durchführt. Alle Parameter werden vor der Installation validiert — keine interaktiven Setup-Dialoge mehr.

**Getestet auf:** Windows Server 2022 / SQL Server 2022

## Features

- **WinForms GUI**: Übersichtliche Oberfläche zur Konfiguration aller Setup-Parameter
- **INI-basierte Konfiguration**: Zentrale `settings.ini` für alle Installationsparameter — versionierbar und wiederverwendbar
- **Automatische Validierung**: Prüft alle Parameter vor der Installation (Pfade, Ports, Dienst-Konten etc.)
- **Disk Layout**: Automatische Konfiguration der SQL Server Datenträgerlayouts (64K-Cluster, Laufwerksbuchstaben)
- **Installationsquellenmanagement**: Kopiert Setup-Medien auf den Zielserver
- **dbaTools-Integration**: Post-Install Konfiguration über dbaTools (Speichereinstellungen, MaxDOP, TEMPDB etc.)
- **Post-Install-Skripte**: Standardisierte Nachkonfiguration nach erfolgreicher Installation

## Voraussetzungen

| Anforderung | Mindestversion |
|-------------|---------------|
| Windows Server | 2022 |
| SQL Server | 2022 (Enterprise oder Standard) |
| PowerShell | 5.1 |

**Module** (werden automatisch geladen):
- `dbaTools` >= 2.0

## Verwendung

```powershell
# Als lokaler Administrator ausführen
.\Main.ps1
```

## Projektstruktur

```
SQLSetupTool/
├── Main.ps1                  # Einstiegspunkt: prüft Adminrechte, lädt Module, startet GUI
├── Config/
│   ├── settings.ini          # Alle Installationsparameter (Pfade, Konten, Features)
│   └── collations.txt        # Verfügbare SQL Server Collations
├── GUI/
│   └── MainForm.ps1          # WinForms-Hauptfenster
├── Modules/
│   ├── Config.psm1           # INI-Parsing, Konfigurationsmanagement
│   ├── Validation.psm1       # Parameter-Validierung vor Installation
│   ├── DiskLayout.psm1       # Datenträgerkonfiguration
│   ├── CopySource.psm1       # Setup-Medien kopieren
│   ├── Installation.psm1     # SQL Server Setup-Ausführung
│   ├── PostInstall.psm1      # Post-Install Konfiguration (dbaTools)
│   └── DbaToolsSetup.psm1    # dbaTools Installation/Update
├── Scripts/
│   └── PostInstall.ps1       # Standalone Post-Install Skript
└── Docs/
    ├── SQLSetupTool_Installationsablauf.docx
    └── SQLSetupTool_Konfigurationsreferenz.docx
```

## Version

- **1.0** — April 2025 — Erstveröffentlichung

## Mehr Informationen

- Website: [www.powershelldba.de](https://www.powershelldba.de)
- Entwickler: Uwe Janke, Senior IT-Spezialist / SQL Server DBA
