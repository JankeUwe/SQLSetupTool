#Requires -Version 5.1
<#
.SYNOPSIS
    Startet das Admin-Konfigurationsformular (settings.ini).
    Pfade, Features, Optionen, Lizenzen.
#>
param()
Add-Type -AssemblyName System.Windows.Forms

$toolRoot = $PSScriptRoot
$cfgForm  = Join-Path $toolRoot 'GUI\ConfigForm.ps1'
$iniPath  = Join-Path $toolRoot 'Config\settings.ini'

if (-not (Test-Path $cfgForm)) {
    [System.Windows.Forms.MessageBox]::Show(
        "ConfigForm.ps1 nicht gefunden:`n$cfgForm",
        'Fehler', 'OK', 'Error') | Out-Null
    exit 1
}
if (-not (Test-Path $iniPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "settings.ini nicht gefunden:`n$iniPath",
        'Fehler', 'OK', 'Error') | Out-Null
    exit 1
}

. $cfgForm
Show-ConfigForm -IniPath $iniPath
