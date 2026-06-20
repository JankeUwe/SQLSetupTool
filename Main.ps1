#Requires -Version 5.1
<#
.SYNOPSIS
    SQL Server Setup Tool - Einstiegspunkt
.DESCRIPTION
    Prueft Adminrechte, laedt alle Module, liest die INI-Konfiguration,
    stellt dbaTools sicher und startet die WinForms-GUI.

    Startup-Fehler werden abgefangen und als Dialog + Logdatei angezeigt
    (sonst schliesst sich das elevated Fenster kommentarlos = "GUI startet nicht").
.NOTES
    Stand   : Juni 2026
    Autor   : SQL-Infrastruktur-Team
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 0. WinForms frueh laden - wird fuer den Admin-Check-Dialog UND den
#    Startup-Fehlerdialog benoetigt (sonst "Typ nicht gefunden").
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Startup-Protokoll (auch wenn das Fenster sich sofort schliesst nachvollziehbar)
$script:StartupLog = Join-Path $env:ProgramData 'SQLSetupTool\startup.log'
function Write-StartupLog {
    param([string]$Message)
    try {
        $dir = Split-Path $script:StartupLog -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) |
            Add-Content -LiteralPath $script:StartupLog -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# 1. Adminrechte pruefen
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Dieses Tool muss als Administrator ausgefuehrt werden.",
        "Fehlende Berechtigungen",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

Write-StartupLog "Start: Benutzer=$env:USERDOMAIN\$env:USERNAME, Computer=$env:COMPUTERNAME, PS=$($PSVersionTable.PSVersion)"

# Ab hier alles in try/catch: Startup-Fehler werden sichtbar gemacht statt das
# Fenster kommentarlos zu schliessen.
try {
    # -----------------------------------------------------------------------
    # 2. Basispfade bestimmen
    # -----------------------------------------------------------------------
    $ScriptDir  = $PSScriptRoot
    $ModulesDir = Join-Path $ScriptDir 'Modules'
    $ConfigDir  = Join-Path $ScriptDir 'Config'
    $IniPath    = Join-Path $ConfigDir 'settings.ini'

    # -----------------------------------------------------------------------
    # 3. Module laden
    # -----------------------------------------------------------------------
    $moduleNames = @(
        'Config',
        'Validation',
        'DiskLayout',
        'CopySource',
        'Installation',
        'PostInstall',
        'DbaToolsSetup',
        'Drivers',
        'PreInstall'
    )

    foreach ($mod in $moduleNames) {
        $modPath = Join-Path $ModulesDir "$mod.psm1"
        if (-not (Test-Path $modPath)) {
            throw "Modul nicht gefunden: $modPath"
        }
        Write-StartupLog "Importiere Modul: $mod"
        Import-Module $modPath -Force -ErrorAction Stop
    }

    # -----------------------------------------------------------------------
    # 4. INI-Konfiguration lesen und Konfigurationsobjekt aufbauen
    # -----------------------------------------------------------------------
    if (-not (Test-Path $IniPath)) {
        throw "Konfigurationsdatei nicht gefunden: $IniPath"
    }

    Write-StartupLog "Lese Konfiguration: $IniPath"
    $Config = Get-SetupConfig -IniPath $IniPath
    Write-StartupLog "Konfiguration geladen. Domain=$($Config.Domain)"

    # -----------------------------------------------------------------------
    # 5. dbaTools sicherstellen (Share -> lokal -> Gallery)
    # -----------------------------------------------------------------------
    Write-StartupLog "Stelle dbaTools sicher ..."
    Assert-DbaToolsReady -DbaToolsConfig $Config.DbaTools

    # -----------------------------------------------------------------------
    # 5a. sqmSQLTool sicherstellen (Share -> lokal mit Versions-Check)
    # -----------------------------------------------------------------------
    Write-StartupLog "Stelle sqmSQLTool sicher ..."
    Assert-sqmSQLToolReady -sqmSQLToolConfig $Config.sqmSQLTool

    # -----------------------------------------------------------------------
    # 6. Relative PostInstall-Skriptpfade in absolute Pfade aufloesen
    # -----------------------------------------------------------------------
    if ($Config.PostInstallScript -and -not [System.IO.Path]::IsPathRooted($Config.PostInstallScript)) {
        $Config.PostInstallScript = Join-Path $ScriptDir $Config.PostInstallScript
    }

    # -----------------------------------------------------------------------
    # 7. GUI starten
    # -----------------------------------------------------------------------
    Write-StartupLog "Starte GUI ..."
    . (Join-Path $ScriptDir 'GUI\MainForm.ps1')
    Show-SetupForm -Config $Config
}
catch {
    $err = $_
    $detail = "$($err.Exception.Message)`n`n$($err.ScriptStackTrace)"
    Write-StartupLog "STARTUP-FEHLER: $detail"

    $msg = "Das SQL Setup Tool konnte nicht gestartet werden.`n`n" +
           "Fehler: $($err.Exception.Message)`n`n" +
           "Moegliche Ursachen (gesperrte / Bank-Domaene):`n" +
           "- Quell-Share (W:\ / UNC) ist nach der UAC-Elevation nicht erreichbar`n" +
           "- dbatools oder sqmSQLTool sind nicht lokal installiert und kein Internet/Feed verfuegbar`n" +
           "- Fehlende Rechte (z. B. HPU) zum Kopieren der Module nach`n" +
           "  C:\Program Files\WindowsPowerShell\Modules`n`n" +
           "Details siehe Protokoll:`n$script:StartupLog"

    try {
        [System.Windows.Forms.MessageBox]::Show(
            $msg, 'SQL Setup Tool - Startfehler',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-Host $msg -ForegroundColor Red
    }
    exit 1
}
