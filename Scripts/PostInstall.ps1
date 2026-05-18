#Requires -Version 5.1
<#
.SYNOPSIS
    Scripts\PostInstall.ps1 - Projektspezifische Nachkonfiguration (Vorlage)
.DESCRIPTION
    Wird von Invoke-PostInstall (PostInstall.psm1) nach der Standard-Nachkonfiguration
    ausgefuehrt. Hier koennen projektspezifische dbaTools-Befehle eingetragen werden.

    Parameter werden von Invoke-CustomPostInstallScript uebergeben.
#>
param(
    [Parameter(Mandatory)][string]$SqlInstance,
    [ScriptBlock]$LogCallback
)

function log([string]$msg) {
    if ($LogCallback) { & $LogCallback $msg }
    else { Write-Host $msg }
}

log "Projektspezifische Nachkonfiguration gestartet fuer: $SqlInstance"

# ---------------------------------------------------------------------------
# Beispiel: Linked Server anlegen
# ---------------------------------------------------------------------------
# Add-DbaLinkedServer -SqlInstance $SqlInstance -LinkedServer 'ANDERERSERVER' -Confirm:$false

# ---------------------------------------------------------------------------
# Beispiel: Standarddatenbank-Optionen setzen
# ---------------------------------------------------------------------------
# Set-DbaDbRecoveryModel -SqlInstance $SqlInstance -Database model -RecoveryModel Full -Confirm:$false

# ---------------------------------------------------------------------------
# Eigene Konfiguration hier eintragen
# ---------------------------------------------------------------------------

log "Projektspezifische Nachkonfiguration abgeschlossen."
