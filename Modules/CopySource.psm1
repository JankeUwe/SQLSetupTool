#Requires -Version 5.1
<#
.SYNOPSIS
    CopySource.psm1 - Robocopy-Wrapper: Share -> lokales Ziel
.DESCRIPTION
    Kopiert Installationsmedien vom konfigurierten SourceShare auf das Zielsystem.
    Robocopy-ExitCodes 0-7 gelten als Erfolg, ab 8 als Fehler.
    Das vollstaendige Robocopy-Log wird unter %TEMP% gespeichert.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Copy-SqlSource {
    <#
    .SYNOPSIS
        Kopiert SQL-Installationsmedien vom Share auf das lokale System.
    .PARAMETER SourceShare
        UNC-Basispfad (z.B. \\srv\SQLSources).
    .PARAMETER Version
        SQL-Version (z.B. 2022).
    .PARAMETER InstallDrive
        Ziel-Laufwerksbuchstabe.
    .PARAMETER LogCallback
        Optionaler ScriptBlock der jede Ausgabezeile empfaengt (fuer GUI-Log).
    #>
    param(
        [Parameter(Mandatory)][string]$SourceShare,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$InstallDrive,
        [ScriptBlock]$LogCallback
    )

    $src = "$SourceShare\SQL$Version"
    $dst = "$($InstallDrive):\SQLSources\SQL$Version"

    Invoke-Robocopy -Source $src -Destination $dst -LogCallback $LogCallback
}

function Copy-ComponentSource {
    <#
    .SYNOPSIS
        Kopiert Quellverzeichnis einer optionalen Komponente (SSRS, SSAS, TDP).
    .PARAMETER SourcePath
        Vollstaendiger UNC-Quellpfad.
    .PARAMETER ComponentName
        Name der Komponente (z.B. SSRS).
    .PARAMETER InstallDrive
        Ziel-Laufwerksbuchstabe.
    .PARAMETER LogCallback
        Optionaler ScriptBlock der jede Ausgabezeile empfaengt.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ComponentName,
        [Parameter(Mandatory)][string]$InstallDrive,
        [ScriptBlock]$LogCallback
    )

    $dst = "$($InstallDrive):\SQLSources\$ComponentName"
    Invoke-Robocopy -Source $SourcePath -Destination $dst -LogCallback $LogCallback
}

function Invoke-Robocopy {
    <#
    .SYNOPSIS
        Interner Robocopy-Wrapper mit Logging.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [ScriptBlock]$LogCallback
    )

    $logFile = Join-Path $env:TEMP "SQLSetup_Robocopy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    $args = @(
        $Source,
        $Destination,
        '/E',    # Alle Unterverzeichnisse inkl. leere
        '/Z',    # Neustartbarer Modus
        '/R:3',  # 3 Wiederholungen
        '/W:10', # 10 Sekunden Wartezeit
        "/LOG:$logFile"
    )

    Write-Verbose "Robocopy: $Source -> $Destination"
    $proc = Start-Process -FilePath 'robocopy' -ArgumentList $args -PassThru -Wait -NoNewWindow

    # ExitCode 0-7 = Erfolg (Bits 0-2 = Dateistatus-Flags), ab 8 = Fehler
    if ($proc.ExitCode -ge 8) {
        $msg = "Robocopy fehlgeschlagen (ExitCode $($proc.ExitCode)). Log: $logFile"
        if ($LogCallback) { & $LogCallback $msg }
        throw $msg
    }

    if ($LogCallback) {
        & $LogCallback "Robocopy abgeschlossen (ExitCode $($proc.ExitCode)). Log: $logFile"
    }
}

Export-ModuleMember -Function Copy-SqlSource, Copy-ComponentSource
