# SQLSetupTool

PowerShell-basiertes WinForms-Tool zur standardisierten Installation und Konfiguration von Microsoft SQL Server in Enterprise-Umgebungen.

Entwickelt von [Uwe Janke](https://www.powershelldba.de) | [powershelldba.de](https://www.powershelldba.de)

---

## Rollenkonzept

Das Tool trennt Konfiguration strikt nach drei Rollen:

| Rolle | Starter | Beschreibung |
|-------|---------|--------------|
| **Anwender** | `Start-Tool.cmd` | Startet das Setup-Hauptfenster |
| **Admin** | `Start-AdminConfig.cmd` | Pflegt globale Pfade und SQL-Defaults (`Config\settings.ini`) |
| **Domain-Admin** | `Start-DomainConfig.cmd` | Pflegt domain-spezifische Profile (`Config\domains\*.ini`) |

---

## Anwender

`Start-Tool.cmd` oeffnet das Haupt-Setup-Fenster. Konfigurationsaenderungen sind hier nicht moeglich.

Das Tool laedt automatisch das Domain-Profil des aktuellen Computers (NetBIOS-Domainname). Gibt es keinen Match, wird `DEFAULT.ini` verwendet.

---

## Admin-Konfiguration

`Start-AdminConfig.cmd` oeffnet den Admin-Konfigurations-Editor.

### Tab "Pfade"

| Einstellung | Beschreibung |
|-------------|--------------|
| `SetupSourceRoot` | Stammverzeichnis der SQL-Installationsquellen |
| `BackupRoot` | Zielverzeichnis fuer System-DB-Backups |
| `ScriptsRoot` | Pfad zu Post-Install-Skripten |
| `Versionen` | Kommagetrennte Liste verfuegbarer SQL-Versionen |

### Tab "Defaults"

| Einstellung | Beschreibung |
|-------------|--------------|
| `DefaultVersion` | Vorausgewaehlte SQL Server Version (z.B. `2022`) |
| `DefaultEdition` | Vorausgewaehlte Edition (Developer / Standard / Enterprise) |
| `DefaultPort` | TCP-Port (Standard: `1433`) |
| `BrowserPort` | SQL Browser UDP-Port (Standard: `1434`) |
| `Format64kCheck` | 64k-Blockgroessen-Check fuer Datenlaufwerke |
| `PowerBI_Enabled` | Power BI RS als optionale Komponente anbieten |
| `PowerBI_SourcePath` | Installationsquelle fuer Power BI RS |

---

## Domain-Profil-Konfiguration

`Start-DomainConfig.cmd` oeffnet den Domain-Profil-Editor.

### Profile verwalten

- **Linke Spalte**: Liste aller Profile in `Config\domains\`
- **+ Neu**: Legt ein neues Profil an - Eingabe ist der NetBIOS-Domainname (z.B. `CONTOSO`)
- **- Loeschen**: Entfernt ein Profil (DEFAULT ist geschuetzt)
- **Speichern**: Schreibt das aktuell angezeigte Profil

### Tab "Allgemein"

| Feld | Beschreibung |
|------|--------------|
| Anzeigename | Beschreibender Name des Profils |
| Sortierung | SQL Server Collation (z.B. `Latin1_General_CI_AS`) |
| Sysadmin-Gruppen | Kommagetrennte AD-Gruppen, die nach Installation die `sysadmin`-Rolle erhalten |
| Monitoring-Typ | 0-basierter Index in die Monitoring-Typen-Liste aus `settings.ini [Monitoring]` |
| Ziel-Server BasePath | Pfad fuer ZIP-Export (leer = Export deaktiviert) |

### Tab "Laufwerke"

Laufwerksbuchstaben fuer die SQL Server Datenbereiche:

| Laufwerk | Verwendung |
|----------|------------|
| Datenlaufwerk | MDF / NDF User-Datenbanken |
| Log-Laufwerk | LDF Transaction Logs |
| TempDB-Laufwerk | TempDB-Dateien |
| Backup-Laufwerk | Backups + SystemDB-Verzeichnis |
| Install-Laufwerk | SQL Server Binaerdateien |

---

## Dateistruktur

```
SQLSetupTool\
  Start-Tool.cmd              # Anwender
  Start-AdminConfig.cmd       # Admin
  Start-DomainConfig.cmd      # Domain-Admin
  Config\
    settings.ini              # Globale Konfiguration
    collations.txt            # Liste verfuegbarer Collations
    domains\
      DEFAULT.ini             # Fallback-Profil (immer vorhanden)
      <DOMAIN>.ini            # Ein Profil pro Active-Directory-Domain
  GUI\
    MainForm.ps1              # Haupt-Setup-Formular
    ConfigForm.ps1            # Admin-Konfigurationsformular
    DomainConfigForm.ps1      # Domain-Profil-Editor
  Modules\
    Config.psm1               # INI-Lese- und Merge-Logik
    Setup.psm1                # SQL-Server-Installations-Logik
```

---

## Systemvoraussetzungen

- Windows Server 2016 / 2019 / 2022 oder Windows 10/11
- PowerShell 5.1
- .NET Framework 4.7.2 oder hoeher
- SQL Server Installationsmedien (ISO oder entpackt)
