#Requires -Version 5.1
<#
.SYNOPSIS
    SQL Server Setup Tool - Einstiegspunkt
.DESCRIPTION
    Prueft Adminrechte, laedt alle Module, liest die INI-Konfiguration,
    stellt dbaTools sicher und startet die WinForms-GUI.
.NOTES
    Stand   : April 2025
    Autor   : SQL-Infrastruktur-Team
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# ---------------------------------------------------------------------------
# 2. Basispfade bestimmen
# ---------------------------------------------------------------------------
$ScriptDir  = $PSScriptRoot
$ModulesDir = Join-Path $ScriptDir 'Modules'
$ConfigDir  = Join-Path $ScriptDir 'Config'
$IniPath    = Join-Path $ConfigDir 'settings.ini'

# ---------------------------------------------------------------------------
# 3. Module laden
# ---------------------------------------------------------------------------
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
        Write-Error "Modul nicht gefunden: $modPath"
        exit 1
    }
    Import-Module $modPath -Force -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 4. INI-Konfiguration lesen und Konfigurationsobjekt aufbauen
# ---------------------------------------------------------------------------
if (-not (Test-Path $IniPath)) {
    Write-Error "Konfigurationsdatei nicht gefunden: $IniPath"
    exit 1
}

$Config = Get-SetupConfig -IniPath $IniPath

# ---------------------------------------------------------------------------
# 5. dbaTools sicherstellen (Share -> lokal -> Gallery)
#    Splash-Fenster wird in Assert-DbaToolsReady angezeigt
# ---------------------------------------------------------------------------
Assert-DbaToolsReady -DbaToolsConfig $Config.DbaTools

# ---------------------------------------------------------------------------
# 5a. sqmSQLTool sicherstellen (Share -> lokal mit Versions-Check)
# ---------------------------------------------------------------------------
Assert-sqmSQLToolReady -sqmSQLToolConfig $Config.sqmSQLTool

# ---------------------------------------------------------------------------
# 6. Relative PostInstall-Skriptpfade in absolute Pfade aufloesen
# ---------------------------------------------------------------------------
if ($Config.PostInstallScript -and -not [System.IO.Path]::IsPathRooted($Config.PostInstallScript)) {
    $Config.PostInstallScript = Join-Path $ScriptDir $Config.PostInstallScript
}

# ---------------------------------------------------------------------------
# 7. GUI starten
# ---------------------------------------------------------------------------
. (Join-Path $ScriptDir 'GUI\MainForm.ps1')
Show-SetupForm -Config $Config

