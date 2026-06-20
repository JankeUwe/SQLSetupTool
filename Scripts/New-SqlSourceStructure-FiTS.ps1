#Requires -Version 5.1
<#
.SYNOPSIS
    Legt die zentrale SQLSources-Verzeichnisstruktur fuer FI-TS an.

.DESCRIPTION
    FI-TS-Variante von New-SqlSourceStructure.ps1.
    Verwendet W:\75084-Datenbanken\MSSQL\SQLSources als festen Standard-Zielpfad,
    da das Skript nicht remote auf dem FI-TS-Server ausgefuehrt werden kann.

    Typischer Workflow:
      1. Skript lokal ausfuehren (ggf. mit -BasePath C:\Temp\FiTSTest zum Testen)
      2. Erzeugten Ordner als ZIP verpacken
      3. ZIP auf den Zielserver uebertragen und nach W:\75084-...\SQLSources entpacken

    Struktur (je SQL-Version):
        <Base>\SQL<Ver>\SQL_Install\
        <Base>\SQL<Ver>\SQL_Install\Updates\
        <Base>\SQL<Ver>\Reporting\
        <Base>\SQL<Ver>\Management\

    Versionsneutrale Abschnitte:
        <Base>\Drivers\JDBC\
        <Base>\Drivers\ODBC\
        <Base>\Drivers\OLEDB\
        <Base>\Drivers\DB2\
        <Base>\Secpol\
        <Base>\Modules\dbaTools\
        <Base>\Modules\dbatools.library\
        <Base>\Modules\sqmSQLTool\
        <Base>\Tools\AlwaysOnSetup\
        <Base>\Tools\SQLSetupTool\
        <Base>\Tools\SQLMigration\
        <Base>\Tools\InplaceUpgrade\
        <Base>\Tools\SSRSDeployment\
        <Base>\Scripts\
        <Base>\TDP\
        <Base>\TDP\ConfigFile\
        <Base>\TDP\TSMConfig\
        <Base>\OlaHallengren\

    Mit -UpdateIni werden die Pfade in settings.ini auf W:\75084-...\-Pfade gesetzt.

.PARAMETER BasePath
    Zielpfad. Standard: W:\75084-Datenbanken\MSSQL\SQLSources
    Fuer lokale Tests: -BasePath C:\Temp\FiTSTest

.PARAMETER Versions
    Kommagetrennte SQL-Versionen. Standard: 2019,2022

.PARAMETER IniPath
    Pfad zur settings.ini. Standard: <ScriptRoot>\..\Config\settings.ini

.PARAMETER UpdateIni
    Aktualisiert settings.ini mit W:\75084-...\-Pfaden.
    Betrifft: dbaTools, sqmSQLTool, Drivers, OptionalComponents (SSRS), Maintenance (Ola).

.PARAMETER Force
    Ueberspringt die Bestaetigung bei bereits vorhandenem Basispfad.

.EXAMPLE
    .\New-SqlSourceStructure-FiTS.ps1 -Force
    Legt Struktur unter W:\75084-Datenbanken\MSSQL\SQLSources an.

.EXAMPLE
    .\New-SqlSourceStructure-FiTS.ps1 -BasePath C:\Temp\FiTSTest -Force
    Lokaler Test: Struktur wird unter C:\Temp\FiTSTest angelegt.

.EXAMPLE
    .\New-SqlSourceStructure-FiTS.ps1 -Force -UpdateIni
    Legt Struktur an und aktualisiert settings.ini mit W:\-Pfaden.
#>
param(
    [string]   $BasePath  = 'W:\75084-Datenbanken\MSSQL\SQLSources',
    [string[]] $Versions  = @('2019','2022'),
    [string]   $IniPath   = '',
    [switch]   $UpdateIni,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# FI-TS W:\-Pfad fuer -UpdateIni (immer der echte Zielpfad, unabhaengig von -BasePath)
$FiTSBasePath = 'W:\75084-Datenbanken\MSSQL\SQLSources'

# ---------------------------------------------------------------------------
# Hilfsfunktion: INI-Datei einlesen
# ---------------------------------------------------------------------------
function Read-IniFile {
    param([string]$Path)
    $ini     = @{}
    $section = '_'
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $line = $line.Trim()
        if ($line -match '^\s*[#;]' -or $line -eq '') { continue }
        if ($line -match '^\[(.+)\]$') { $section = $matches[1]; $ini[$section] = @{}; continue }
        if ($line -match '^([^=]+?)\s*=\s*(.*)$') {
            $ini[$section][$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $ini
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Ordner + README anlegen
# ---------------------------------------------------------------------------
function New-SourceFolder {
    param(
        [string]$Path,
        [string]$ReadmeText
    )
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Host "  [+] $Path" -ForegroundColor Green
    } else {
        Write-Host "  [=] $Path" -ForegroundColor Gray
    }
    $readme = Join-Path $Path 'README.txt'
    if (-not (Test-Path $readme)) {
        Set-Content -Path $readme -Value $ReadmeText -Encoding UTF8
    }
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: INI-Zeile aktualisieren (Key = Value in [Section])
# ---------------------------------------------------------------------------
function Update-IniValue {
    param(
        [string]$IniPath,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )
    $lines   = Get-Content $IniPath -Encoding UTF8
    $inSect  = $false
    $found   = $false
    $result  = @()

    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]$') {
            $inSect = ($matches[1] -eq $Section)
        }
        if ($inSect -and $line -match "^\s*$([regex]::Escape($Key))\s*=") {
            $result += "$Key = $Value"
            $found = $true
            continue
        }
        $result += $line
    }

    if (-not $found) {
        Write-Warning "INI-Update: Schluessel '$Key' in [$Section] nicht gefunden - uebersprungen."
    } else {
        Set-Content -Path $IniPath -Value $result -Encoding UTF8
        Write-Host "  [INI] [$Section] $Key = $Value" -ForegroundColor Cyan
    }
}

# ---------------------------------------------------------------------------
# 1. INI einlesen (nur fuer -UpdateIni und optionale Versionsuebernahme)
# ---------------------------------------------------------------------------
if ($IniPath -eq '') {
    $IniPath = Join-Path $PSScriptRoot '..\Config\settings.ini'
}
$IniPath = [System.IO.Path]::GetFullPath($IniPath)

$ini = $null
if (Test-Path $IniPath) {
    $ini = Read-IniFile -Path $IniPath
} else {
    if ($UpdateIni) {
        Write-Error "settings.ini nicht gefunden: $IniPath`nBitte -IniPath angeben oder -UpdateIni weglassen."
        exit 1
    }
    Write-Warning "settings.ini nicht gefunden: $IniPath - wird ignoriert (kein -UpdateIni)."
}

# ---------------------------------------------------------------------------
# 2. Zusammenfassung und Bestaetigung
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'SQL Server Setup Tool - SQLSources Struktur anlegen (FI-TS)' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host "  Basispfad  : $BasePath"
Write-Host "  Versionen  : $($Versions -join ', ')"
if ($UpdateIni) {
    Write-Host "  INI-Update : JA - settings.ini wird auf W:\-Pfade aktualisiert" -ForegroundColor Yellow
}
Write-Host ''

if (Test-Path $BasePath) {
    if (-not $Force) {
        $answer = Read-Host "Basispfad '$BasePath' existiert bereits. Fortfahren? (j/n)"
        if ($answer -notmatch '^[jJyY]') {
            Write-Host 'Abgebrochen.' -ForegroundColor Yellow; exit 0
        }
    }
} else {
    if (-not $Force) {
        $answer = Read-Host "Basispfad '$BasePath' wird neu erstellt. Fortfahren? (j/n)"
        if ($answer -notmatch '^[jJyY]') {
            Write-Host 'Abgebrochen.' -ForegroundColor Yellow; exit 0
        }
    }
}

# ---------------------------------------------------------------------------
# 3. SQL Server Installationsquellen (je Version)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- SQL Server Installationsmedien ---' -ForegroundColor White

foreach ($ver in $Versions) {
    $verBase = Join-Path $BasePath "SQL$ver"
    Write-Host ''
    Write-Host "  SQL Server $ver" -ForegroundColor White

    New-SourceFolder -Path (Join-Path $verBase 'SQL_Install') -ReadmeText @"
SQL Server $ver - Installationsmedium
======================================
Inhalt: Entpacktes ISO / Setup-Verzeichnis von SQL Server $ver.
        setup.exe muss direkt in diesem Ordner liegen.

Beispiel-Inhalt:
  setup.exe
  x64\
  resources\
  ...

Quelle: Microsoft Volume Licensing Service Center (VLSC)
        https://www.microsoft.com/licensing/servicecenter
"@

    New-SourceFolder -Path (Join-Path $verBase 'SQL_Install\Updates') -ReadmeText @"
SQL Server $ver - Kumulative Updates (Slipstream)
==================================================
Inhalt: CU-Paket fuer SQL Server $ver als .exe-Datei.
        Wird von Install-DbaInstance automatisch als UpdateSourcePath verwendet
        wenn dieser Ordner eine .exe-Datei enthaelt.

Nur EINE CU-Datei ablegen (die aktuellste).
Beispiel: SQLServer${ver}-KB5040939-x64.exe

Quelle: https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates
"@

    New-SourceFolder -Path (Join-Path $verBase 'Reporting') -ReadmeText @"
SQL Server $ver - Reporting Services (SSRS)
============================================
Inhalt: Eigenstaendiger SSRS-Installer fuer SQL Server $ver.
        Ab SQL 2017 wird SSRS als separates Paket ausgeliefert.

Beispiel: SQLServerReportingServices.exe

Quelle: https://www.microsoft.com/en-us/download/details.aspx?id=100122 (SSRS 2022)
        https://www.microsoft.com/en-us/download/details.aspx?id=100068 (SSRS 2019)

settings.ini: [OptionalComponents] SSRS_SourcePath = <SQLSources>\SQL$ver\Reporting
"@

    New-SourceFolder -Path (Join-Path $verBase 'Management') -ReadmeText @"
SQL Server $ver - SQL Server Management Studio (SSMS)
======================================================
Inhalt: SSMS-Installer. SSMS ist versionsneutral - ein Installer reicht fuer alle
        SQL Server Versionen. Dennoch hier versionsspezifisch abgelegt damit ein
        Robocopy-Lauf fuer SQL$ver alles in einem Durchgang kopiert.

Beispiel: SSMS-Setup-ENU.exe

Quelle: https://aka.ms/ssmsfullsetup
"@
}

# ---------------------------------------------------------------------------
# 4. Treiber (versionsneutral)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Treiber ---' -ForegroundColor White

New-SourceFolder -Path (Join-Path $BasePath 'Drivers\JDBC') -ReadmeText @"
Microsoft JDBC Driver for SQL Server
=====================================
Inhalt: JDBC-Treiber-Paket (ZIP mit .jar-Dateien) oder direktes .jar.

Unterstuetzte Dateiformate:
  sqljdbc_<Version>_enu.zip   -> wird automatisch entpackt
  mssql-jdbc-<Version>.jar    -> wird direkt in den Zielordner kopiert

Typische Zielpfade:
  C:\Program Files\Microsoft SQL Server JDBC Driver\
  oder Applikationsserver-Classpath

settings.ini: [Drivers] JDBC_SourcePath = <SQLSources>\Drivers\JDBC

Quelle: https://learn.microsoft.com/en-us/sql/connect/jdbc/download-microsoft-jdbc-driver-for-sql-server
"@

New-SourceFolder -Path (Join-Path $BasePath 'Drivers\ODBC') -ReadmeText @"
Microsoft ODBC Driver for SQL Server
=====================================
Inhalt: ODBC-Treiber-Installer fuer Windows.

Unterstuetzte Dateiformate:
  msodbcsql*.msi   -> stille Installation via msiexec
  msodbcsql*.exe   -> stille Installation

Aktuell empfohlen: ODBC Driver 18 for SQL Server

settings.ini: [Drivers] ODBC_SourcePath = <SQLSources>\Drivers\ODBC

Quelle: https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server
"@

New-SourceFolder -Path (Join-Path $BasePath 'Drivers\OLEDB') -ReadmeText @"
Microsoft OLE DB Driver for SQL Server
=======================================
Inhalt: OLE DB-Treiber-Installer fuer Windows (msoledbsql.msi).
        Wird von Anwendungen benoetigt die ADO/OLE DB zur SQL-Verbindung nutzen.
        Eigenstaendiger Nachfolger des veralteten SQLOLEDB-Providers.

Unterstuetzte Dateiformate:
  msoledbsql*.msi   -> stille Installation via msiexec

Aktuell empfohlen: Microsoft OLE DB Driver 19 for SQL Server

settings.ini: [Drivers] OLEDB_SourcePath = <SQLSources>\Drivers\OLEDB

Quelle: https://learn.microsoft.com/en-us/sql/connect/oledb/download-oledb-driver-for-sql-server
"@

New-SourceFolder -Path (Join-Path $BasePath 'Drivers\DB2') -ReadmeText @"
IBM DB2 ODBC/CLI-Treiber
=========================
Inhalt: IBM Data Server Driver fuer ODBC und CLI (64-Bit).

Unterstuetzte Dateiformate:
  db2_odbc_cli_64.exe   -> bevorzugt (stille Installation)
  ibm_data_server_driver_package_win64_v*.exe

Nach der Installation wird db2cli -setup -registerall ausgefuehrt
um den Treiber systemweit zu registrieren.

settings.ini: [Drivers] DB2_SourcePath = <SQLSources>\Drivers\DB2

Quelle: IBM Fix Central / IBM Passport Advantage
"@

# ---------------------------------------------------------------------------
# 5. PowerShell Module (versionsneutral)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- PowerShell Module ---' -ForegroundColor White

New-SourceFolder -Path (Join-Path $BasePath 'Modules\dbaTools') -ReadmeText @"
dbaTools PowerShell-Modul (Offline-Kopie)
==========================================
Inhalt: Vollstaendig entpacktes dbaTools-Modul.
        Wird verwendet wenn keine Internet-Verbindung zur PowerShell Gallery besteht.

Erwartete Struktur:
  Modules\dbaTools\
    dbatools.psd1
    dbatools.psm1
    bin\
    functions\
    ...

settings.ini: [dbaTools] ShareBasePath = <SQLSources>\Modules

Quelle: https://github.com/dataplat/dbatools/releases
"@

New-SourceFolder -Path (Join-Path $BasePath 'Modules\dbatools.library') -ReadmeText @"
dbatools.library (Pflichtabhaengigkeit ab dbaTools 2.x)
========================================================
Inhalt: dbatools.library-Modul - muss zusammen mit dbatools vorhanden sein.

Erwartete Struktur:
  Modules\dbatools.library\
    dbatools.library.psd1
    dbatools.library.psm1
    ...

settings.ini: [dbaTools] ShareBasePath = <SQLSources>\Modules
              (gleicher Basispfad wie dbaTools)

Quelle: https://github.com/dataplat/dbatools.library/releases
"@

New-SourceFolder -Path (Join-Path $BasePath 'Modules\sqmSQLTool') -ReadmeText @"
sqmSQLTool PowerShell-Modul (Offline-Kopie)
============================================
Inhalt: Vollstaendig entpacktes sqmSQLTool-Modul.
        Wird verwendet wenn kein Zugriff auf die PowerShell Gallery oder den
        Entwicklungspfad besteht.

Erwartete Struktur:
  Modules\sqmSQLTool\
    sqmSQLTool.psd1
    sqmSQLTool.psm1
    Public\
    ...

settings.ini: [sqmSQLTool] ShareBasePath = <SQLSources>\Modules

Quelle: https://github.com/JankeUwe/sqmSQLTool
        https://www.powershellgallery.com/packages/sqmSQLTool
"@

# ---------------------------------------------------------------------------
# 6. GUI-Tools (versionsneutral)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Tools ---' -ForegroundColor White

New-SourceFolder -Path (Join-Path $BasePath 'Tools\AlwaysOnSetup') -ReadmeText @"
AlwaysOn Setup Tool
====================
Inhalt: Aktuelles Release des AlwaysOn Setup Tools (entpackt oder als ZIP).
        PowerShell WinForms-Wizard zur Einrichtung von SQL Server AlwaysOn
        Availability Groups.

Erwartete Dateien:
  AlwaysOnSetup.ps1   (Einstiegspunkt)
  Modules\
  Config\
  ...

Quelle: https://github.com/JankeUwe/AlwaysOnSetup
"@

New-SourceFolder -Path (Join-Path $BasePath 'Tools\SQLSetupTool') -ReadmeText @"
SQL Server Setup Tool
======================
Inhalt: Aktuelles Release des SQL Server Setup Tools (dieses Tool selbst).
        Kann zur Verteilung an andere Server hier zentral abgelegt werden.

Erwartete Dateien:
  Main.ps1
  Modules\
  Config\settings.ini
  GUI\
  ...

Quelle: https://github.com/JankeUwe/SQLSetupTool
"@

New-SourceFolder -Path (Join-Path $BasePath 'Tools\SQLMigration') -ReadmeText @"
SQL Migration Tool
===================
Inhalt: Aktuelles Release des SQL Migration Tools.
        Zweiphasige SQL Server Migration mit GUI (Backup/Restore oder Detach/Attach).

Quelle: https://github.com/JankeUwe/SQLMigration
"@

New-SourceFolder -Path (Join-Path $BasePath 'Tools\InplaceUpgrade') -ReadmeText @"
SQL Server Inplace Upgrade Tool
================================
Inhalt: Aktuelles Release des Inplace Upgrade Tools.
        Automatisiert SQL Server Inplace-Upgrades (2016 -> 2019 -> 2022).
        Pre-Checks, Upgrade-Ausfuehrung, Post-Validierung.

Quelle: https://github.com/JankeUwe/InplaceUpDate
"@

New-SourceFolder -Path (Join-Path $BasePath 'Tools\SSRSDeployment') -ReadmeText @"
SSRS Report Deployment Tool
=============================
Inhalt: Aktuelles Release des SSRS Report Deployment Tools.
        Massendeployment von SSRS-Reports auf den Report Server.
        Unterstuetzt SSRS und Power BI Report Server.

Quelle: https://github.com/JankeUwe/SSRSDeploymentTool
"@

# ---------------------------------------------------------------------------
# 7. TDP - IBM Spectrum Protect (versionsneutral)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- TDP / Wartung ---' -ForegroundColor White

New-SourceFolder -Path (Join-Path $BasePath 'TDP') -ReadmeText @"
IBM Spectrum Protect (Tivoli Data Protection) - SQL Server Agent
=================================================================
Inhalt: TDP-Installer fuer SQL Server Backup-Integration.
        Versionsneutral - gilt fuer alle SQL Server Versionen.

Unterordner:
  ConfigFile\  -> Domainspezifische TDP-Konfigurationsdateien (dsm.opt, tdpsql.cfg)
  TSMConfig\   -> Standalone TSM-Client-Konfiguration (ie_dsm.opt)

settings.ini: [OptionalComponents] TDP_Enabled = true
              (TDP_SourcePath wird auf <SQLSources>\TDP gesetzt)

Beispiel-Inhalt:
  TSMSQL_WIN_8.1.21.0\SetupFCM.exe
  TSMSQL_WIN_8.1.21.0\spinstall.exe
  ...
"@

New-SourceFolder -Path (Join-Path $BasePath 'TDP\ConfigFile') -ReadmeText @"
TDP - Domainspezifische Konfigurationsdateien
=============================================
Inhalt: Konfigurationsdateien fuer den TDP SQL Server Agent.
        Wird nach der TDP-Installation in den TDP-Konfigurationsordner kopiert.

Typische Dateien:
  dsm.opt         -> TSM/SP-Clientoptionen (Serveradresse, Knotenname, Passwort)
  tdpsql.cfg      -> TDP SQL Agent Konfiguration (Backup-Einstellungen)
  tdpvss.cfg      -> TDP VSS-Konfiguration (wenn verwendet)

Backup-Skripte (Beispiel):
  full_backup.cmd    -> Vollsicherung per TDP
  diff_backup.cmd    -> Differentialsicherung per TDP
  log_backup.cmd     -> Transaktionsprotokolsicherung per TDP

PowerShell-Skript:
  CreateSqlTdpJobs.ps1  -> Legt SQL Agent Jobs fuer TDP-Backups an

HINWEIS: Diese Dateien sind umgebungsspezifisch. Nicht oeffentlich!
         Knotenname, Serveradresse und Passwoerter anpassen vor dem Einsatz.
"@

New-SourceFolder -Path (Join-Path $BasePath 'TDP\TSMConfig') -ReadmeText @"
TSM - Standalone Client-Konfiguration
======================================
Inhalt: Konfigurationsdatei fuer den eigenstaendigen IBM Spectrum Protect (TSM) Client.
        Wird verwendet wenn nur der TSM-Basis-Client (kein TDP/FCM) installiert ist.

Typische Dateien:
  ie_dsm.opt   -> TSM-Clientoptionsdatei (Serververbindung, Knotenname)
  dsm.sys      -> Systemkonfiguration (Linux-Aequivalent: nicht unter Windows erforderlich)

Unterschied zu TDP\ConfigFile:
  TDP\ConfigFile  -> TDP SQL Agent ist installiert (Datenbankbackups via ISC Agent)
  TDP\TSMConfig   -> Nur TSM-Basisclient (Filesystembackups, kein SQL-Agent)

HINWEIS: Diese Dateien sind umgebungsspezifisch. Nicht oeffentlich!
"@

# ---------------------------------------------------------------------------
# 7b. Security Policy (versionsneutral)
# ---------------------------------------------------------------------------
New-SourceFolder -Path (Join-Path $BasePath 'Secpol') -ReadmeText @"
Windows Security Policy - SQL Server Haertung
===============================================
Inhalt: Exportierte Windows-Sicherheitsrichtlinien fuer SQL Server Server.
        Wird via secedit /configure angewendet um SQL Server Sicherheitsanforderungen
        automatisch zu konfigurieren.

Enthaltene Richtlinien:
  Instant File Initialization  -> Recht "Volumewartungsaufgaben ausfuehren" (SE_MANAGE_VOLUME_NAME)
  Lock Pages in Memory         -> Recht "Seiten im Arbeitsspeicher sperren" (SeLockMemoryPrivilege)
  Perform OS Backups           -> Recht "Dateien und Verzeichnisse sichern" (SeBackupPrivilege)

Dateien:
  secedt.sdb   -> Binaere Security Database (exportiert via secedit /export)
  secedt.jfm   -> Journal File (Begleiter zur .sdb-Datei)
  import.inf   -> Lesbare INF-Datei mit den Richtlinieneintraegen (Optional)

Anwendung:
  secedit /configure /db secedt.sdb /cfg import.inf /overwrite /quiet

HINWEIS: Diese Datei ist maschinenspezifisch und enthaelt ggf. alle lokalen
         Sicherheitsrichtlinien des Export-Servers. Inhalte vor Einsatz pruefen!
         Nur die SQL-relevanten Rechte (Privileges) uebertragen.
"@

# ---------------------------------------------------------------------------
# 8. Ola Hallengren Maintenance Solution (versionsneutral)
# ---------------------------------------------------------------------------
New-SourceFolder -Path (Join-Path $BasePath 'OlaHallengren') -ReadmeText @"
Ola Hallengren Maintenance Solution
=====================================
Inhalt: SQL-Skripte von Ola Hallengren - lokaler Fallback wenn kein GitHub-Zugriff.
        Wird verwendet wenn [Maintenance] OlaSourcePath gesetzt ist.

Erwartete Datei:
  MaintenanceSolution.sql

Ohne diese Datei (Ordner leer): Download direkt von GitHub waehrend der Installation.

settings.ini: [Maintenance] OlaSourcePath = <SQLSources>\OlaHallengren

Quelle: https://ola.hallengren.com
        https://github.com/olahallengren/sql-server-maintenance-solution
"@

# ---------------------------------------------------------------------------
# 9. Post-Install SQL-Skripte (versionsneutral)
# ---------------------------------------------------------------------------
New-SourceFolder -Path (Join-Path $BasePath 'Scripts') -ReadmeText @"
Firmen-SQL-Skripte fuer die PostInstall-Routine
================================================
Inhalt: *.sql-Dateien die nach jeder SQL-Server-Installation automatisch
        ausgefuehrt werden. Typische Verwendung:
          - Firmen-Logins anlegen
          - Standard-LinkedServer registrieren
          - Datenbank-Optionen setzen (model, msdb)
          - Firmeneigene gespeicherte Prozeduren / Wartungsscripte

Ausfuehrungsreihenfolge: Alphabetisch nach Dateiname.
Empfohlene Benennung:    01_logins.sql, 02_linkedserver.sql, ...

GO-Trenner werden unterstuetzt (Batch-Ausfuehrung).

settings.ini: [PostInstall] SqlScriptsPath = <SQLSources>\Scripts
              (Leer lassen = dieser Ordner wird automatisch verwendet)
"@

# ---------------------------------------------------------------------------
# 10. Optional: settings.ini aktualisieren (immer W:\-Pfade)
# ---------------------------------------------------------------------------
if ($UpdateIni) {
    Write-Host ''
    Write-Host '--- settings.ini aktualisieren (W:\-Pfade) ---' -ForegroundColor Yellow

    $defaultVer = $Versions[0]
    if ($ini -and $ini['General'] -and $ini['General']['DefaultVersion']) {
        $defaultVer = $ini['General']['DefaultVersion']
    }

    # dbaTools ShareBasePath
    Update-IniValue -IniPath $IniPath -Section 'dbaTools'   -Key 'ShareBasePath' -Value "$FiTSBasePath\Modules"

    # sqmSQLTool ShareBasePath
    Update-IniValue -IniPath $IniPath -Section 'sqmSQLTool' -Key 'ShareBasePath' -Value "$FiTSBasePath\Modules"

    # Treiber-Pfade
    Update-IniValue -IniPath $IniPath -Section 'Drivers'    -Key 'JDBC_SourcePath'  -Value "$FiTSBasePath\Drivers\JDBC"
    Update-IniValue -IniPath $IniPath -Section 'Drivers'    -Key 'ODBC_SourcePath'  -Value "$FiTSBasePath\Drivers\ODBC"
    Update-IniValue -IniPath $IniPath -Section 'Drivers'    -Key 'OLEDB_SourcePath' -Value "$FiTSBasePath\Drivers\OLEDB"
    Update-IniValue -IniPath $IniPath -Section 'Drivers'    -Key 'DB2_SourcePath'   -Value "$FiTSBasePath\Drivers\DB2"

    # SSRS-SourcePath (auf Default-Version)
    Update-IniValue -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSRS_SourcePath' -Value "$FiTSBasePath\SQL$defaultVer\Reporting"

    # TDP-SourcePath
    Update-IniValue -IniPath $IniPath -Section 'OptionalComponents' -Key 'TDP_SourcePath'  -Value "$FiTSBasePath\TDP"

    # Ola Hallengren
    Update-IniValue -IniPath $IniPath -Section 'Maintenance'        -Key 'OlaSourcePath'   -Value "$FiTSBasePath\OlaHallengren"

    # Security Policy
    Update-IniValue -IniPath $IniPath -Section 'Secpol'             -Key 'SourcePath'       -Value "$FiTSBasePath\Secpol"

    Write-Host '  settings.ini aktualisiert.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 11. Zusammenfassung
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host 'Fertig. Angelegte Struktur:' -ForegroundColor Green
Write-Host ''

$allFolders = Get-ChildItem -Path $BasePath -Recurse -Directory | Sort-Object FullName
foreach ($folder in $allFolders) {
    $rel = $folder.FullName.Substring($BasePath.Length).TrimStart('\','/')
    $depth = ($rel -split '\\').Count - 1
    $indent = '  ' * $depth
    Write-Host "$indent  $($folder.Name)\" -ForegroundColor Gray
}

Write-Host ''
Write-Host 'Naechste Schritte:' -ForegroundColor Cyan
Write-Host "  1. SQL Server ISO entpacken nach:  $BasePath\SQL<Version>\SQL_Install\" -ForegroundColor White
Write-Host "  2. CU ablegen in:                  $BasePath\SQL<Version>\SQL_Install\Updates\" -ForegroundColor White
Write-Host "  3. SSRS-Installer ablegen nach:    $BasePath\SQL<Version>\Reporting\" -ForegroundColor White
Write-Host "  4. SSMS-Installer ablegen in:      $BasePath\SQL<Version>\Management\" -ForegroundColor White
Write-Host "  5. dbaTools entpacken nach:        $BasePath\Modules\dbaTools\" -ForegroundColor White
Write-Host "  6. sqmSQLTool entpacken nach:      $BasePath\Modules\sqmSQLTool\" -ForegroundColor White
Write-Host "  7. JDBC/ODBC/OLE DB ablegen in:    $BasePath\Drivers\<Treiber>\" -ForegroundColor White
Write-Host "  8. TDP-Config ablegen in:          $BasePath\TDP\ConfigFile\" -ForegroundColor White
Write-Host "  9. Secpol exportieren nach:        $BasePath\Secpol\" -ForegroundColor White
Write-Host " 10. Tools ablegen in:               $BasePath\Tools\<Tool>\" -ForegroundColor White
Write-Host ''
Write-Host 'ZIP-Tipp fuer FI-TS-Uebertragung:' -ForegroundColor Cyan
Write-Host "  Compress-Archive -Path '$BasePath\*' -DestinationPath 'C:\Temp\SQLSources-FiTS.zip'" -ForegroundColor White
if (-not $UpdateIni) {
    Write-Host ''
    Write-Host "  Tipp: Starte mit -UpdateIni um settings.ini auf W:\-Pfade zu aktualisieren." -ForegroundColor Cyan
}
Write-Host ''
