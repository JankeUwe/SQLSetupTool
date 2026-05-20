#Requires -Version 5.1
<#
.SYNOPSIS
    Legt die SQLSources-Verzeichnisstruktur fuer das SQL Server Setup Tool an.

.DESCRIPTION
    Erstellt den erwarteten Ordnerbaum unterhalb eines angegebenen Basispfades.
    Liest die verfuegbaren Versionen aus settings.ini (Versions\Available) oder
    verwendet den Parameter -Versions.

    Struktur je Version:
        <Base>\SQL<Ver>\SQL_Install\
        <Base>\SQL<Ver>\SQL_Install\Updates\
        <Base>\SQL<Ver>\Reporting\
        <Base>\SQL<Ver>\Management\

    Versionsunabhaengig:
        <Base>\TDP\

    Jeder Ordner erhaelt eine README.txt mit Hinweis was dort abgelegt werden soll.

.PARAMETER BasePath
    Zielpfad. Standard: SourceShare aus settings.ini (z.B. \\srv\SQLSources).
    Kann auch ein lokaler Pfad sein (z.B. C:\SQLSources).

.PARAMETER Versions
    Kommagetrennte SQL-Versionen. Standard: Wert aus settings.ini [Versions] Available.

.PARAMETER IniPath
    Pfad zur settings.ini. Standard: <ScriptRoot>\..\Config\settings.ini

.PARAMETER Force
    Ueberspringt die Bestaetigung bei bereits vorhandenem Basispfad.

.EXAMPLE
    .\New-SqlSourceStructure.ps1
    Legt Struktur gemaess settings.ini an.

.EXAMPLE
    .\New-SqlSourceStructure.ps1 -BasePath \\fileserver\SQLSources
    Legt Struktur auf dem angegebenen Share an.

.EXAMPLE
    .\New-SqlSourceStructure.ps1 -BasePath C:\SQLSources -Versions 2022,2025 -Force
    Legt lokale Struktur nur fuer 2022 und 2025 an, ohne Rueckfrage.
#>
param(
    [string]$BasePath  = '',
    [string[]]$Versions = @(),
    [string]$IniPath   = '',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        Write-Host "  [=] $Path (bereits vorhanden)" -ForegroundColor Gray
    }
    $readme = Join-Path $Path 'README.txt'
    if (-not (Test-Path $readme)) {
        Set-Content -Path $readme -Value $ReadmeText -Encoding UTF8
    }
}

# ---------------------------------------------------------------------------
# 1. INI einlesen
# ---------------------------------------------------------------------------
if ($IniPath -eq '') {
    $IniPath = Join-Path $PSScriptRoot '..\Config\settings.ini'
}
$IniPath = [System.IO.Path]::GetFullPath($IniPath)

if (-not (Test-Path $IniPath)) {
    Write-Warning "settings.ini nicht gefunden: $IniPath"
    Write-Warning "Bitte -IniPath angeben oder -BasePath und -Versions explizit setzen."
    exit 1
}
$ini = Read-IniFile -Path $IniPath

# ---------------------------------------------------------------------------
# 2. Parameter aus INI ergaenzen
# ---------------------------------------------------------------------------
if ($BasePath -eq '') {
    $BasePath = $ini['General']['SourceShare']
    if (-not $BasePath) {
        Write-Error "SourceShare nicht in settings.ini gefunden. Bitte -BasePath angeben."
        exit 1
    }
}

if ($Versions.Count -eq 0) {
    $raw = $ini['Versions']['Available']
    if ($raw) {
        $Versions = $raw -split '\s*,\s*' | Where-Object { $_ -ne '' }
    } else {
        $Versions = @('2019','2022','2025')
        Write-Warning "Keine Versionen in settings.ini gefunden. Verwende Standard: $($Versions -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# 3. Zusammenfassung und Bestaetigung
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "SQL Server Setup Tool - SQLSources Struktur anlegen" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Basispfad : $BasePath"
Write-Host "  Versionen : $($Versions -join ', ')"
Write-Host ""

if (Test-Path $BasePath) {
    if (-not $Force) {
        $answer = Read-Host "Basispfad '$BasePath' existiert bereits. Fortfahren? (j/n)"
        if ($answer -notmatch '^[jJyY]') {
            Write-Host "Abgebrochen." -ForegroundColor Yellow
            exit 0
        }
    }
} else {
    if (-not $Force) {
        $answer = Read-Host "Basispfad '$BasePath' wird neu erstellt. Fortfahren? (j/n)"
        if ($answer -notmatch '^[jJyY]') {
            Write-Host "Abgebrochen." -ForegroundColor Yellow
            exit 0
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Ordnerstruktur anlegen
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Erstelle Ordnerstruktur..." -ForegroundColor Cyan

foreach ($ver in $Versions) {
    $verBase = Join-Path $BasePath "SQL$ver"
    Write-Host ""
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
"@

    New-SourceFolder -Path (Join-Path $verBase 'Management') -ReadmeText @"
SQL Server $ver - SQL Server Management Studio (SSMS)
======================================================
Inhalt: SSMS-Installer. SSMS ist versionsneutral - ein Installer reicht fuer alle
        SQL Server Versionen. Dennoch hier versionsspezifisch abgelegt damit der
        Robocopy-Lauf fuer SQL$ver alles in einem Durchgang kopiert.

Beispiel: SSMS-Setup-ENU.exe

Quelle: https://aka.ms/ssmsfullsetup
"@
}

# TDP (versionsneutral)
Write-Host ""
Write-Host "  TDP (IBM Spectrum Protect - versionsneutral)" -ForegroundColor White
New-SourceFolder -Path (Join-Path $BasePath 'TDP') -ReadmeText @"
IBM Spectrum Protect (Tivoli Data Protection) - SQL Server Agent
=================================================================
Inhalt: TDP-Installer fuer SQL Server Backup-Integration.
        Versionsneutral - gilt fuer alle SQL Server Versionen.

TDP_SourcePath in settings.ini muss auf diesen Ordner zeigen.

Beispiel-Inhalt:
  setup.exe  (oder *.msi)
  ...
"@

# dbaTools offline (optional, nur wenn ShareBasePath auf diesen Share zeigen soll)
$dbaBase = $ini['dbaTools']['ShareBasePath']
if ($dbaBase -and $dbaBase -like "$BasePath*") {
    Write-Host ""
    Write-Host "  dbaTools (ShareBasePath aus INI)" -ForegroundColor White
    New-SourceFolder -Path (Join-Path $dbaBase 'dbatools') -ReadmeText @"
dbaTools PowerShell-Modul (Offline-Kopie)
==========================================
Inhalt: Vollstaendig entpacktes dbaTools-Modul.
        Wird verwendet wenn keine Internet-Verbindung zur PowerShell Gallery besteht.

Struktur:
  dbatools\
    dbatools.psd1
    dbatools.psm1
    ...

Quelle: https://github.com/dataplat/dbatools/releases
"@
    New-SourceFolder -Path (Join-Path $dbaBase 'dbatools.library') -ReadmeText @"
dbatools.library (Unterstuetzungsbibliothek ab dbaTools 2.x)
=============================================================
Inhalt: dbatools.library-Modul, wird zusammen mit dbatools benoetigt.

Quelle: https://github.com/dataplat/dbatools.library/releases
"@
}

# ---------------------------------------------------------------------------
# 5. Zusammenfassung
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "Fertig. Angelegte Struktur:" -ForegroundColor Green
Write-Host ""

$allFolders = Get-ChildItem -Path $BasePath -Recurse -Directory |
              Where-Object { $_.Name -ne 'dbatools' -and $_.Name -ne 'dbatools.library' }

foreach ($folder in ($allFolders | Sort-Object FullName)) {
    $rel = $folder.FullName.Substring($BasePath.Length).TrimStart('\','/')
    Write-Host "  $BasePath\$rel" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Naechste Schritte:" -ForegroundColor Cyan
Write-Host "  1. SQL Server ISO entpacken nach: $BasePath\SQL<Version>\SQL_Install\" -ForegroundColor White
Write-Host "  2. Aktuelles CU ablegen in:       $BasePath\SQL<Version>\SQL_Install\Updates\" -ForegroundColor White
Write-Host "  3. SSRS-Installer ablegen in:     $BasePath\SQL<Version>\Reporting\" -ForegroundColor White
Write-Host "  4. SSMS-Installer ablegen in:     $BasePath\SQL<Version>\Management\" -ForegroundColor White
Write-Host "  5. SourceShare in settings.ini pruefen: $BasePath" -ForegroundColor White
Write-Host ""
