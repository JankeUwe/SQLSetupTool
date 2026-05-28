#Requires -Version 5.1
<#
.SYNOPSIS
    Drivers.psm1 - Wrapper fuer JDBC / ODBC / DB2 Treiber-Installation mit Versionsvergleich

.DESCRIPTION
    Kapselt die sqmSQLTool-Funktionen Install-sqmJdbcDriver, Install-sqmOdbcDriver,
    Install-sqmDb2Driver sowie die neuen Uninstall-Funktionen als GUI-kompatible
    Komponenten mit einheitlichem Logging-Interface (LogCallback-ScriptBlock).

    Versionsvergleich-Logik (alle drei Treiber):
    1. Test-sqmDriverInstalled pruefen ob und welche Version installiert ist
    2. Quell-Version aus Installer-Datei ermitteln
    3. Wenn installierte Version aelter als Quelle: Dialog mit Ja/Nein
       - Ja: Uninstall-sqm*Driver + Install-sqm*Driver
       - Nein: ueberspringen
    4. Wenn gleich oder neuer: Log "aktuell"
    5. Wenn nicht installiert: normale Installation
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Private Hilfsfunktion: Quell-Version aus Installer-Datei ermitteln
# ---------------------------------------------------------------------------
function _GetSourceVersion {
    param(
        [string]$SourcePath,
        [ValidateSet('ODBC','JDBC','DB2')]
        [string]$DriverType
    )

    try {
        if ($DriverType -eq 'JDBC') {
            # JDBC: Version aus Dateiname per Regex
            $jar = Get-ChildItem -Path $SourcePath -Filter 'mssql-jdbc*.jar' -Recurse -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 1
            if ($jar -and $jar.Name -match 'mssql-jdbc-(\d+\.\d+\.\d+)') {
                return [System.Version]$Matches[1]
            }
            # Fallback: EXE-Installer pruefen
            $exe = Get-ChildItem -Path $SourcePath -Filter 'sqljdbc*.exe' -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($exe) {
                $fv = (Get-Item $exe.FullName).VersionInfo.FileVersion
                if ($fv -and $fv -match '^\d+\.\d+') { return [System.Version]$fv }
            }
        }
        elseif ($DriverType -eq 'ODBC') {
            # ODBC: VersionInfo aus MSI oder EXE
            $installer = $null
            if (Test-Path $SourcePath -PathType Leaf) {
                $installer = Get-Item $SourcePath
            } else {
                $installer = Get-ChildItem -Path $SourcePath -Include 'msodbcsql*.msi','msodbcsql*.exe' -Recurse -ErrorAction SilentlyContinue |
                             Sort-Object Name -Descending | Select-Object -First 1
            }
            if ($installer) {
                $fv = $installer.VersionInfo.FileVersion
                if ($fv -and $fv -match '^\d+\.\d+') { return [System.Version]$fv }
                # Fallback: Version aus Dateiname (z.B. msodbcsql18.msi)
                if ($installer.Name -match '(\d{2,})') { return [System.Version]"$($Matches[1]).0" }
            }
        }
        elseif ($DriverType -eq 'DB2') {
            # DB2: VersionInfo aus Installer-EXE
            $installer = $null
            if (Test-Path $SourcePath -PathType Leaf) {
                $installer = Get-Item $SourcePath
            } else {
                $installer = Get-ChildItem -Path $SourcePath -Include 'db2_odbc_cli_64.exe','db2_odbc_cli.exe','db2client*.exe','setup.exe','*.msi' -Recurse -ErrorAction SilentlyContinue |
                             Sort-Object { switch ($_.Name) { 'db2_odbc_cli_64.exe'{1} 'db2_odbc_cli.exe'{2} default{3} } } |
                             Select-Object -First 1
            }
            if ($installer) {
                $fv = $installer.VersionInfo.FileVersion
                if ($fv -and $fv -match '^\d+\.\d+') { return [System.Version]$fv }
            }
        }
    } catch { }

    return $null
}

# ---------------------------------------------------------------------------
# Private Hilfsfunktion: Versionsvergleich + optionaler Upgrade-Dialog
# Gibt $true zurueck wenn Installation durchgefuehrt werden soll
# ---------------------------------------------------------------------------
function _CheckAndPromptUpgrade {
    param(
        [string]$DriverType,
        [string]$SourcePath,
        [ScriptBlock]$LogCallback
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg } else { Write-Host $msg }
    }

    # Installierte Version pruefen
    $installed = $null
    try {
        $installed = Test-sqmDriverInstalled -DriverType $DriverType -ErrorAction SilentlyContinue
    } catch { }

    if (-not $installed -or -not $installed.Installed) {
        # Nicht installiert -> normale Installation
        return $true
    }

    # Quell-Version ermitteln
    $sourceVer    = _GetSourceVersion -SourcePath $SourcePath -DriverType $DriverType
    $installedVer = $null
    if ($installed.Version) {
        try { $installedVer = [System.Version]$installed.Version } catch { }
    }

    if (-not $sourceVer -or -not $installedVer) {
        # Versionen nicht vergleichbar -> wie bisher AlreadyInstalled behandeln
        log "  INFO: $DriverType bereits installiert (v$($installed.Version)) - Versionsvergleich nicht moeglich."
        return $false
    }

    if ($sourceVer -gt $installedVer) {
        # Quelle ist neuer -> Dialog
        log "  INFO: $DriverType Update verfuegbar: installiert v$installedVer, Quelle v$sourceVer"
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "$DriverType Driver Update verfuegbar!`n`n" +
            "Installiert : v$installedVer`n" +
            "Quelle      : v$sourceVer`n`n" +
            "Jetzt aktualisieren (Deinstallation + Neuinstallation)?",
            "$DriverType Driver Update",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            log "  -> Upgrade bestaetigt. Starte Deinstallation v$installedVer..."
            return $true   # Caller fuehrt Uninstall + Install durch
        } else {
            log "  -> Upgrade abgelehnt. $DriverType bleibt bei v$installedVer."
            return $false
        }
    } elseif ($sourceVer -eq $installedVer) {
        log "  OK: $DriverType aktuell (v$installedVer)."
        return $false
    } else {
        # Installiert ist neuer als Quelle
        log "  OK: $DriverType neuer als Quelle (installiert v$installedVer, Quelle v$sourceVer) - keine Aktion."
        return $false
    }
}

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

    log 'Treiber: Starte JDBC-Versionscheck...'

    if (-not $SourcePath -or $SourcePath -eq '') {
        log 'JDBC: Kein SourcePath konfiguriert - wird uebersprungen.'
        return
    }

    try {
        $doInstall = _CheckAndPromptUpgrade -DriverType 'JDBC' -SourcePath $SourcePath -LogCallback $LogCallback
        if (-not $doInstall) { return }

        # Upgrade-Pfad: zuerst Deinstallation
        $installed = Test-sqmDriverInstalled -DriverType 'JDBC' -ErrorAction SilentlyContinue
        if ($installed -and $installed.Installed) {
            log '  Deinstalliere vorhandene JDBC-Version...'
            $unResult = Uninstall-sqmJdbcDriver -ErrorAction Stop
            log "  Deinstallation: $($unResult.Status) - $($unResult.Message)"
            if ($unResult.Status -eq 'Error') { throw "JDBC-Deinstallation fehlgeschlagen: $($unResult.Message)" }
        }

        log '  Installiere JDBC...'
        $result = Install-sqmJdbcDriver -SourcePath $SourcePath -ErrorAction Stop
        switch ($result.Status) {
            'Installed' { log "  OK: JDBC installiert - $($result.Message)" }
            default     { log "  WARN: JDBC - $($result.Message)" }
        }
    }
    catch {
        log "  FEHLER JDBC: $_"
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

    log 'Treiber: Starte ODBC-Versionscheck...'

    if (-not $SourcePath -or $SourcePath -eq '') {
        log 'ODBC: Kein SourcePath konfiguriert - wird uebersprungen.'
        return
    }

    try {
        $doInstall = _CheckAndPromptUpgrade -DriverType 'ODBC' -SourcePath $SourcePath -LogCallback $LogCallback
        if (-not $doInstall) { return }

        # Upgrade-Pfad: zuerst Deinstallation
        $installed = Test-sqmDriverInstalled -DriverType 'ODBC' -ErrorAction SilentlyContinue
        if ($installed -and $installed.Installed) {
            log "  Deinstalliere vorhandene ODBC-Version ($($installed.DriverName))..."
            $unResult = Uninstall-sqmOdbcDriver -DriverName $installed.DriverName -ErrorAction Stop
            log "  Deinstallation: $($unResult.Status) - $($unResult.Message)"
            if ($unResult.Status -eq 'Error') { throw "ODBC-Deinstallation fehlgeschlagen: $($unResult.Message)" }
        }

        log '  Installiere ODBC...'
        $params = @{ SourcePath = $SourcePath }
        if ($DriverName -and $DriverName -ne '') { $params['DriverName'] = $DriverName }

        $result = Install-sqmOdbcDriver @params -ErrorAction Stop
        switch ($result.Status) {
            'Installed' { log "  OK: ODBC installiert - $($result.Message)" }
            default     { log "  WARN: ODBC - $($result.Message)" }
        }
    }
    catch {
        log "  FEHLER ODBC: $_"
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

    log 'Treiber: Starte DB2-Versionscheck...'

    if (-not $SourcePath -or $SourcePath -eq '') {
        log 'DB2: Kein SourcePath konfiguriert - wird uebersprungen.'
        return
    }

    try {
        $doInstall = _CheckAndPromptUpgrade -DriverType 'DB2' -SourcePath $SourcePath -LogCallback $LogCallback
        if (-not $doInstall) { return }

        # Upgrade-Pfad: zuerst Deinstallation
        $installed = Test-sqmDriverInstalled -DriverType 'DB2' -ErrorAction SilentlyContinue
        if ($installed -and $installed.Installed) {
            log '  Deinstalliere vorhandene DB2-Version...'
            $unResult = Uninstall-sqmDb2Driver -ErrorAction Stop
            log "  Deinstallation: $($unResult.Status) - $($unResult.Message)"
            if ($unResult.Status -eq 'Error') { throw "DB2-Deinstallation fehlgeschlagen: $($unResult.Message)" }
        }

        log '  Installiere DB2...'
        $result = Install-sqmDb2Driver -SourcePath $SourcePath -ErrorAction Stop
        switch ($result.Status) {
            'Installed' { log "  OK: DB2 installiert - $($result.Message)" }
            default     { log "  WARN: DB2 - $($result.Message)" }
        }
    }
    catch {
        log "  FEHLER DB2: $_"
        throw
    }
}

Export-ModuleMember -Function Install-JdbcComponent, Install-OdbcComponent, Install-Db2Component
