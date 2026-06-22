#Requires -Version 5.1
<#
.SYNOPSIS
    SetupState.psm1 - Checkpoint/Resume fuer die Installations-Phasen (Verzeichnisse, Installation,
    Komponenten, Treiber). Wird von Main.ps1 (GUI) und Start-SqlSetup.ps1 (CLI) genutzt.

    Spiegelt die in PostInstall.psm1 bewaehrte Logik auf Phasen-Ebene: jeder abgeschlossene
    Schritt wird in einer State-Datei je Instanz vermerkt (<StatePath>\SqlSetup_<Instanz>_<Scope>.json).
    Bei einem erneuten Lauf werden 'Completed'-Schritte uebersprungen - vorherige Ausgaben werden
    NICHT wiederholt. -Force ignoriert den State und fuehrt alles erneut aus.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SetupState {
    <#
    .SYNOPSIS
        Erzeugt/laed den Checkpoint-Kontext fuer eine Instanz + einen Scope (z.B. 'install').
    #>
    param(
        [Parameter(Mandatory)][string]$InstanceName,
        [string]$StatePath = 'C:\System\WinSrvLog\MSSQL',
        [string]$Scope = 'install',
        [switch]$Force,
        [ScriptBlock]$LogCallback
    )
    # GetNewClosure(): bindet $LogCallback fest ein, damit der Logger auch ausserhalb von
    # New-SetupState (im gespeicherten Kontext) funktioniert - sonst "variable not set" unter StrictMode.
    $log = {
        param($m)
        if ($LogCallback) { & $LogCallback $m } else { Write-Host $m }
    }.GetNewClosure()
    $safe = $InstanceName -replace '[\\/:*?"<>|]', '_'
    $file = Join-Path $StatePath ("SqlSetup_${safe}_${Scope}.json")
    $state = @{ }

    if ($Force) {
        & $log "[$Scope] -Force: vorhandener Fortschritt wird ignoriert, alle Schritte laufen erneut."
        if (Test-Path $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
    elseif (Test-Path $file) {
        try {
            foreach ($e in @(Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                $state[[string]$e.Id] = @{ Status = [string]$e.Status; Timestamp = [string]$e.Timestamp; Message = [string]$e.Message }
            }
            $done = @($state.Values | Where-Object { $_.Status -eq 'Completed' }).Count
            & $log "[$Scope] Fortschritt geladen ($done Schritt(e) bereits erledigt) - setze fort. State: $file"
        }
        catch {
            & $log "[$Scope] State-Datei nicht lesbar - starte komplett neu: $_"
            $state = @{ }
        }
    }

    return [PSCustomObject]@{ File = $file; State = $state; Log = $log; Scope = $Scope }
}

function Save-SetupState {
    param([Parameter(Mandatory)][PSCustomObject]$Context)
    try {
        $dir = Split-Path $Context.File -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $arr = $Context.State.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{ Id = $_.Key; Status = $_.Value.Status; Timestamp = $_.Value.Timestamp; Message = $_.Value.Message }
        }
        (@($arr) | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Context.File -Encoding UTF8
    }
    catch { & $Context.Log "  WARN: Fortschritt konnte nicht gespeichert werden: $_" }
}

function Test-SetupStepDone {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$Id
    )
    return ($Context.State.ContainsKey($Id) -and $Context.State[$Id].Status -eq 'Completed')
}

function Set-SetupStepDone {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$Id,
        [string]$Message = ''
    )
    $Context.State[$Id] = @{ Status = 'Completed'; Timestamp = (Get-Date).ToString('o'); Message = $Message }
    Save-SetupState -Context $Context
}

function Invoke-SetupStep {
    <#
    .SYNOPSIS
        Fuehrt einen Phasen-Schritt aus, sofern er nicht bereits 'Completed' ist, und persistiert
        das Ergebnis. Bei Erfolg -> Completed; bei Ausnahme -> Failed (und Re-Throw).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    if (Test-SetupStepDone -Context $Context -Id $Id) {
        & $Context.Log "[$($Context.Scope)] [$Id] $Name - bereits erledigt ($($Context.State[$Id].Timestamp)), uebersprungen."
        return
    }
    & $Context.Log "[$($Context.Scope)] [$Id] $Name ..."
    try {
        & $Body
        $Context.State[$Id] = @{ Status = 'Completed'; Timestamp = (Get-Date).ToString('o'); Message = '' }
        Save-SetupState -Context $Context
    }
    catch {
        $Context.State[$Id] = @{ Status = 'Failed'; Timestamp = (Get-Date).ToString('o'); Message = "$_" }
        Save-SetupState -Context $Context
        throw
    }
}

Export-ModuleMember -Function New-SetupState, Save-SetupState, Test-SetupStepDone, Set-SetupStepDone, Invoke-SetupStep
