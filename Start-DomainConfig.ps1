#Requires -Version 5.1
<#
.SYNOPSIS
    Startet den Domain-Profil-Editor (Config\domains\*.ini).
    Sortierung, Sysadmin-Gruppen, Monitoring, Laufwerke, Ziel-Server-Pfad.
#>
param()
Add-Type -AssemblyName System.Windows.Forms

$toolRoot  = $PSScriptRoot
$domForm   = Join-Path $toolRoot 'GUI\DomainConfigForm.ps1'
$configDir = Join-Path $toolRoot 'Config'

if (-not (Test-Path $domForm)) {
    [System.Windows.Forms.MessageBox]::Show(
        "DomainConfigForm.ps1 nicht gefunden:`n$domForm",
        'Fehler', 'OK', 'Error') | Out-Null
    exit 1
}

. $domForm
Show-DomainConfigForm -ConfigDir $configDir
