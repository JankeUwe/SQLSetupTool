#Requires -Version 5.1
<#
.SYNOPSIS
    Drivers.psm1 - Thin-Wrapper fuer JDBC / ODBC / DB2 Treiber-Installation

.DESCRIPTION
    Kapselt die sqmSQLTool-Funktionen Install-sqmJdbcDriver, Install-sqmOdbcDriver
    und Install-sqmDb2Driver als GUI-kompatible Komponenten mit einheitlichem
    Logging-Interface (LogCallback-ScriptBlock).

    Muster: identisch mit Install-SsrsComponent / Install-SsasComponent in
    Installation.psm1 - duenner Wrapper, Logik liegt in sqmSQLTool.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
function Install-JdbcComponent {
    <#
    .SYNOPSIS
        Installiert den Microsoft JDBC Driver for SQL Server (Wrapper).
    .PARAMETER SourcePath
        Quellpfad mit JDBC-Installer (.jar oder .exe). Aus Config.Drivers['JDBC_SourcePath'].
    .PARAMETER LogCallback
        ScriptBlock fuer GUI-Logging: { param($msg) Write-Log $msg }
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [ScriptBlock]$LogCallback
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg } else { Write-Host $msg }
    }

    log 'Treiber: Starte JDBC-Installation...'

    if (-not $SourcePath -or $SourcePath -eq '') {
        log 'JDBC: Kein SourcePath konfiguriert - wird uebersprungen.'
        return
    }

    try {
        $result = Install-sqmJdbcDriver -SourcePath $SourcePath -ErrorAction Stop
        switch ($result.Status) {
            'AlreadyInstalled' { log "  OK: JDBC bereits vorhanden ($($result.Message))" }
            'Installed'        { log "  OK: JDBC installiert - $($result.Message)" }
            default            { log "  WARN: JDBC - $($result.Message)" }
        }
    }
    catch {
        log "  FEHLER JDBC-Installation: $_"
        throw
    }
}

# ---------------------------------------------------------------------------
function Install-OdbcComponent {
    <#
    .SYNOPSIS
        Installiert den Microsoft ODBC Driver for SQL Server (Wrapper).
    .PARAMETER SourcePath
        Quellpfad mit ODBC-Installer (.msi oder .exe). Aus Config.Drivers['ODBC_SourcePath'].
    .PARAMETER DriverName
        Optionaler Treibername fuer die Vorab-Pruefung.
    .PARAMETER LogCallback
        ScriptBlock fuer GUI-Logging.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$DriverName,
        [ScriptBlock]$LogCallback
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg } else { Write-Host $msg }
    }

    log 'Treiber: Starte ODBC-Installation...'

    if (-not $SourcePath -or $SourcePath -eq '') {
        log 'ODBC: Kein SourcePath konfiguriert - wird uebersprungen.'
        return
    }

    try {
        $params = @{ SourcePath = $SourcePath }
        if ($DriverName -and $DriverName -ne '') { $params['DriverName'] = $DriverName }

        $result = Install-sqmOdbcDriver @params -ErrorAction Stop
        switch ($result.Status) {
            'AlreadyInstalled' { log "  OK: ODBC bereits vorhanden ($($result.Message))" }
            'Installed'        { log "  OK: ODBC installiert - $($result.Message)" }
            default            { log "  WARN: ODBC - $($result.Message)" }
        }
    }
    catch {
        log "  FEHLER ODBC-Installation: $_"
        throw
    }
}

# ---------------------------------------------------------------------------
function Install-Db2Component {
    <#
    .SYNOPSIS
        Installiert den IBM DB2 ODBC/CLI-Treiber (Wrapper).
    .PARAMETER SourcePath
        Quellpfad mit DB2-Installer. Aus Config.Drivers['DB2_SourcePath'].
    .PARAMETER LogCallback
        ScriptBlock fuer GUI-Logging.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [ScriptBlock]$LogCallback
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg } else { Write-Host $msg }
    }

    log 'Treiber: Starte DB2-Installation...'

    if (-not $SourcePath -or $SourcePath -eq '') {
        log 'DB2: Kein SourcePath konfiguriert - wird uebersprungen.'
        return
    }

    try {
        $result = Install-sqmDb2Driver -SourcePath $SourcePath -ErrorAction Stop
        switch ($result.Status) {
            'AlreadyInstalled' { log "  OK: DB2 bereits vorhanden ($($result.Message))" }
            'Installed'        { log "  OK: DB2 installiert - $($result.Message)" }
            default            { log "  WARN: DB2 - $($result.Message)" }
        }
    }
    catch {
        log "  FEHLER DB2-Installation: $_"
        throw
    }
}

Export-ModuleMember -Function Install-JdbcComponent, Install-OdbcComponent, Install-Db2Component
