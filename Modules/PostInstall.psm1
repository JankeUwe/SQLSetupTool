#Requires -Version 5.1
<#
.SYNOPSIS
    PostInstall.psm1 - Nachkonfiguration nach erfolgreicher SQL-Installation

    Integration mit sqmSQLTool:
    - Invoke-sqmNtfsSetup         (NTFS-Berechtigungen)
    - Invoke-sqmSetDatabaseRecoveryMode (Recovery-Modell)
    - Invoke-sqmMonitoringKey     (Monitoring-Registry)
    - Get-sqmSQLInstanceCheck     (Validierung)
    - Install-sqmOlaMaintenanceSolution (Ola-Objekte)
    - New-sqmOlaMaintenanceJobs   (IndexOptimize + IntegrityCheck Jobs)
    - New-sqmOlaSysDbBackupJob    (System-DB Backup Job)
    - New-sqmOlaUsrDbBackupJob    (User-DB Backup Jobs FULL/DIFF/LOG)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-PostInstall {
    <#
    .SYNOPSIS
        Orchestriert alle Post-Installation Tasks.
    .PARAMETER SqlInstance
        Instanzname (z.B. MSSQLSERVER oder SERVER\INST01).
    .PARAMETER SqlPaths
        PSCustomObject mit Data/Log/TempDB/Backup Pfaden (aus Get-SqlPaths).
    .PARAMETER MonitoringType
        0=Kein Monitoring  1=Service Monitoring (Standard)  2=Vollstaendig
    .PARAMETER PostInstallScript
        Optionaler Pfad zu benutzerdefiniertem Script.
    .PARAMETER EnableTsm
        TSM/TDP aktivieren? (wird bei TDP-Installation auf $true gesetzt).
    .PARAMETER InstallConfig
        PSCustomObject aus Config.psm1 [Installation]-Sektion.
        Wird fuer TempDB-Groesse/Wachstum und BrowserSvc-Einstellung verwendet.
    .PARAMETER SplunkEnabled
        Invoke-sqmSplunkConfiguration nach der Installation ausfuehren? (aus settings.ini [PostInstall]).
        Standard: $false.
    .PARAMETER SqlScriptsPath
        Ordner mit Firmen-SQL-Skripten (*.sql). Alle Dateien werden alphabetisch ausgefuehrt.
        Leer oder Pfad nicht vorhanden = Schritt wird uebersprungen.
        Standard: <SourceShare>\Scripts (aus settings.ini).
    .PARAMETER SysadminGroups
        AD-Gruppen die zur sysadmin-Rolle hinzugefuegt werden (aus settings.ini [SysadminGroups]).
        Leer = keine Gruppe zuweisen, SA-Obfuscation wird uebersprungen.
    .PARAMETER OlaSourcePath
        Lokaler Fallback-Pfad fuer Ola Hallengren ZIP/Verzeichnis.
        Leer = nur GitHub. Wird verwendet wenn GitHub nicht erreichbar ist.
    .PARAMETER ComputerName
        Fuer Remote-Monitoring (Standard: lokaler Computer).
    .PARAMETER LogCallback
        Optionaler ScriptBlock fuer GUI-Logging.
    #>
    param(
        [Parameter(Mandatory)][string]$SqlInstance,
        [Parameter(Mandatory)][PSCustomObject]$SqlPaths,
        [ValidateSet(0, 1, 2)][int]$MonitoringType = 1,
        [string]$PostInstallScript,
        [bool]$EnableTsm = $false,
        [PSCustomObject]$InstallConfig,
        [bool]$SplunkEnabled = $false,
        [string[]]$SysadminGroups = @(),
        [string]$OlaSourcePath = '',
        [string]$SqlScriptsPath = '',
        [string]$ComputerName = $env:COMPUTERNAME,
        [ScriptBlock]$LogCallback
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg }
        else              { Write-Host $msg }
    }

    try {
        # ===== 1. NTFS-Berechtigungen =====
        log "PostInstall: Konfiguriere NTFS-Berechtigungen..."
        Invoke-sqmNtfsSetup -SqlInstance $SqlInstance -ErrorAction Stop
        log "  OK: NTFS-Berechtigungen konfiguriert"

        # ===== 2. Performance-Einstellungen =====
        log "PostInstall: Konfiguriere Performance-Parameter..."

        Set-SqlMaxMemory -SqlInstance $SqlInstance
        log "  OK: Max Server Memory = 90% RAM"

        Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'optimize for ad hoc workloads' -Value 1 -Confirm:$false
        log "  OK: optimize for ad hoc workloads = 1"

        Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'cost threshold for parallelism' -Value 50 -Confirm:$false
        log "  OK: Cost Threshold for Parallelism = 50"

        Set-SqlMaxDop -SqlInstance $SqlInstance
        log "  OK: MAXDOP konfiguriert"

        # ===== 3. SQL Server Agent =====
        log "PostInstall: Konfiguriere SQL Server Agent..."
        Enable-SqlAgentAutoStart -SqlInstance $SqlInstance
        log "  OK: SQL Agent auf Automatisch gesetzt"

        # ===== 4. TempDB =====
        log "PostInstall: Optimiere TempDB..."
        Set-SqlTempDbFiles -SqlInstance $SqlInstance -SqlPaths $SqlPaths -InstallConfig $InstallConfig
        log "  OK: TempDB konfiguriert (CPU-basierte Dateianzahl, Groesse aus Konfiguration)"

        # ===== 5. Recovery-Modell =====
        log "PostInstall: Setze Recovery-Modell..."
        Invoke-sqmSetDatabaseRecoveryMode -SqlInstance $SqlInstance `
            -Database 'system', 'msdb' `
            -RecoveryMode 'FULL' `
            -ErrorAction Stop
        log "  OK: Recovery-Modell = FULL (system, msdb)"

        # ===== 6. SQL Browser Service deaktivieren =====
        $browserDisabled = if ($InstallConfig) { $InstallConfig.BrowserSvcDisabled } else { $true }
        if ($browserDisabled) {
            log "PostInstall: Deaktiviere SQL Browser Service..."
            try {
                Disable-SqlBrowserService
                log "  OK: SQLBrowser deaktiviert."
            }
            catch {
                log "  WARN: SQLBrowser konnte nicht deaktiviert werden: $_"
            }
        }

        # ===== 7. AD-Sysadmin-Gruppen zuweisen =====
        $sysadminGroupsAssigned = $false
        if ($SysadminGroups -and $SysadminGroups.Count -gt 0) {
            log "PostInstall: Weise Sysadmin-Gruppen zu ($($SysadminGroups.Count) Gruppe(n))..."
            $assignedCount = 0
            foreach ($group in $SysadminGroups) {
                try {
                    Add-DbaServerRoleMember -SqlInstance $SqlInstance `
                        -Login $group -ServerRole sysadmin -Confirm:$false -ErrorAction Stop
                    log "  OK: '$group' zur sysadmin-Rolle hinzugefuegt"
                    $assignedCount++
                }
                catch {
                    log "  WARN: '$group' konnte nicht zugewiesen werden: $_"
                }
            }
            if ($assignedCount -gt 0) {
                $sysadminGroupsAssigned = $true
                log "  Ergebnis: $assignedCount von $($SysadminGroups.Count) Gruppe(n) erfolgreich zugewiesen."
            }
            else {
                log "  WARN: Keine Sysadmin-Gruppe konnte zugewiesen werden - SA-Obfuscation wird uebersprungen."
            }
        }
        else {
            log "PostInstall: Keine Sysadmin-Gruppen konfiguriert (settings.ini [SysadminGroups]) - wird uebersprungen."
            log "  HINWEIS: SA-Obfuscation wird nicht durchgefuehrt. Manuelle Haertung empfohlen."
        }

        # ===== 8. SA-Obfuscation (nur wenn mindestens eine Gruppe zugewiesen) =====
        if ($sysadminGroupsAssigned) {
            log "PostInstall: Starte SA-Obfuscation..."
            try {
                $saResult = Invoke-sqmSaObfuscation -SqlInstance $SqlInstance `
                    -ContinueOnError -ErrorAction Stop
                $saResult = @($saResult)[0]
                if ($saResult.Status -eq 'Success') {
                    log "  OK: SA-Konto verschleiert."
                    log "  Originaler Name : '$($saResult.OriginalLoginName)'"
                    log "  Neuer Name      : '$($saResult.NewLoginName)'"
                    log "  Passwortlaenge  : $($saResult.PasswordLength) Zeichen"
                    log "  WICHTIG: Das generierte Passwort wird nur im Rueckgabeobjekt"
                    log "           zurueckgegeben - sicher verwahren!"
                }
                elseif ($saResult.Status -eq 'AbortedNoSysadmin') {
                    log "  WARN: SA-Obfuscation abgebrochen - kein weiteres aktives sysadmin-Login."
                    log "  Details: $($saResult.Message)"
                }
                else {
                    log "  WARN: SA-Obfuscation fehlgeschlagen: $($saResult.Message)"
                }
            }
            catch {
                log "  WARN: SA-Obfuscation fehlgeschlagen: $_"
            }
        }
        else {
            log "PostInstall: SA-Obfuscation uebersprungen."
        }

        # ===== 9. Monitoring-Key =====
        log "PostInstall: Konfiguriere Monitoring..."
        $monMap = @{ 0 = 'None'; 1 = 'Standard'; 2 = 'Full' }
        $monStr = $monMap[$MonitoringType]
        $tsmValue = if ($EnableTsm) { 1 } else { 0 }

        Invoke-sqmMonitoringKey -ComputerName $ComputerName `
            -Operation 'Set' `
            -SQL $monStr `
            -TSM $tsmValue `
            -ErrorAction Stop

        $tsmStatus = if ($EnableTsm) { 'Aktiv' } else { 'Inaktiv' }
        log "  OK: Monitoring SQL=$monStr TSM=$tsmStatus"

        # ===== 10. Instanz-Validierung =====
        log "PostInstall: Validiere Installation..."
        $check = Get-sqmSQLInstanceCheck -SqlInstance $SqlInstance -ErrorAction Stop
        log "  OK: Instanz-Status: $($check.Status)"

        # ===== 11. Benutzerdefiniertes PostInstall-Script =====
        if ($PostInstallScript -and (Test-Path $PostInstallScript)) {
            log "PostInstall: Fuehre benutzerdefiniertes Script aus..."
            Invoke-CustomPostInstallScript -ScriptPath $PostInstallScript `
                -SqlInstance $SqlInstance `
                -LogCallback $LogCallback
            log "  OK: Benutzerdefiniertes Script abgeschlossen"
        }

        # ===== 12. Ola Hallengren Maintenance Solution =====
        log "PostInstall: Installiere Ola Hallengren Maintenance Solution..."
        $olaOk = $false

        try {
            # Versuch 1: GitHub (Standard - neueste Version)
            Install-sqmOlaMaintenanceSolution -SqlInstance $SqlInstance -ErrorAction Stop
            $olaOk = $true
            log "  OK: Maintenance Solution von GitHub installiert"
        }
        catch {
            log "  Hinweis: GitHub nicht erreichbar ($_)"

            # Versuch 2: Lokaler Fallback
            if ($OlaSourcePath -and (Test-Path $OlaSourcePath)) {
                try {
                    Install-sqmOlaMaintenanceSolution -SqlInstance $SqlInstance `
                        -SourcePath $OlaSourcePath -ErrorAction Stop
                    $olaOk = $true
                    log "  OK: Maintenance Solution von lokalem Pfad installiert ($OlaSourcePath)"
                }
                catch {
                    log "  Warnung: Ola-Installation auch lokal fehlgeschlagen: $_"
                }
            }
            else {
                log "  Warnung: OlaSourcePath nicht konfiguriert - Maintenance Solution wird uebersprungen"
                log "           (Tipp: OlaSourcePath in settings.ini [Maintenance] setzen)"
            }
        }

        if ($olaOk) {
            # ===== 13. Maintenance Jobs (IndexOptimize + IntegrityCheck) =====
            log "PostInstall: Erstelle Maintenance Jobs..."
            New-sqmOlaMaintenanceJobs -SqlInstance $SqlInstance
            log "  OK: IndexOptimize + IntegrityCheck Jobs erstellt"

            # ===== 14. System-DB Backup Job =====
            log "PostInstall: Erstelle System-DB Backup Job..."
            New-sqmOlaSysDbBackupJob -SqlInstance $SqlInstance
            log "  OK: System-DB Backup Job erstellt"

            # ===== 15. User-DB Backup Jobs (FULL + DIFF + LOG) =====
            log "PostInstall: Erstelle User-DB Backup Jobs..."
            New-sqmOlaUsrDbBackupJob -SqlInstance $SqlInstance -Full -Diff -Log
            log "  OK: User-DB Backup Jobs FULL/DIFF/LOG erstellt"
        }

        # ===== 16. Splunk Universal Forwarder konfigurieren =====
        if ($SplunkEnabled) {
            log "PostInstall: Konfiguriere Splunk Universal Forwarder..."
            try {
                Invoke-sqmSplunkConfiguration -ErrorAction Stop
                log "  OK: Splunk-Konfiguration abgeschlossen."
            }
            catch {
                log "  WARN: Splunk-Konfiguration fehlgeschlagen: $_"
            }
        }
        else {
            log "PostInstall: Splunk-Konfiguration deaktiviert (settings.ini [PostInstall] SplunkEnabled = false)."
        }

        # ===== 17. Firmen-SQL-Skripte ausfuehren =====
        if ($SqlScriptsPath -and (Test-Path $SqlScriptsPath)) {
            log "PostInstall: Fuehre Firmen-SQL-Skripte aus ($SqlScriptsPath)..."
            Invoke-SqlScriptFolder -SqlInstance $SqlInstance `
                -ScriptsPath $SqlScriptsPath `
                -LogCallback $LogCallback
        }
        else {
            if ($SqlScriptsPath) {
                log "PostInstall: SQL-Skripte-Ordner nicht gefunden - wird uebersprungen ($SqlScriptsPath)"
            }
            else {
                log "PostInstall: Kein SQL-Skripte-Ordner konfiguriert - wird uebersprungen."
            }
        }

        # ===== 18. Setup-Abschlussbericht =====
        log "PostInstall: Erstelle Setup-Abschlussbericht..."
        try {
            $reportFile = Invoke-sqmSetupReport -SqlInstance $SqlInstance -PassThru -ErrorAction Stop
            log "  OK: Setup-Report erstellt: $reportFile"
        }
        catch {
            log "  WARN: Setup-Report konnte nicht erstellt werden: $_"
        }

        log "PostInstall: Alle Tasks abgeschlossen"
    }
    catch {
        $errMsg = "PostInstall-Fehler: $_"
        log $errMsg
        throw $errMsg
    }
}

# --- Hilfsfunktionen ---

function Set-SqlMaxMemory {
    param([Parameter(Mandatory)][string]$SqlInstance)
    $totalMb = [math]::Round((Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    $maxMb   = [math]::Round($totalMb * 0.9)
    Set-DbaMaxMemory -SqlInstance $SqlInstance -MaxMb $maxMb -Confirm:$false
}

function Set-SqlMaxDop {
    param([Parameter(Mandatory)][string]$SqlInstance)
    $cpus   = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors
    $maxdop = [math]::Min(8, $cpus)
    Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'max degree of parallelism' -Value $maxdop -Confirm:$false
}

function Enable-SqlAgentAutoStart {
    param([Parameter(Mandatory)][string]$SqlInstance)
    $svcName = if ($SqlInstance -match '\\') {
        "SQLSERVERAGENT`$$($SqlInstance.Split('\')[1])"
    } else {
        'SQLSERVERAGENT'
    }
    Set-Service  -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name $svcName                        -ErrorAction SilentlyContinue
}

function Set-SqlTempDbFiles {
    param(
        [Parameter(Mandatory)][string]$SqlInstance,
        [Parameter(Mandatory)][PSCustomObject]$SqlPaths,
        [PSCustomObject]$InstallConfig
    )
    # Dateianzahl: CPU-basiert (4-8), unabhaengig vom Installationswert
    $cpus  = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors
    $files = [math]::Max(4, [math]::Min(8, $cpus))

    # Groesse/Wachstum aus InstallConfig oder Defaults (1024 MB / 512 MB gemaess SQLConfig.INI)
    $sizeMB      = if ($InstallConfig -and $InstallConfig.TempDbFileSizeMB)    { $InstallConfig.TempDbFileSizeMB }    else { 1024 }
    $growthMB    = if ($InstallConfig -and $InstallConfig.TempDbFileGrowthMB)  { $InstallConfig.TempDbFileGrowthMB }  else { 512 }
    $logSizeMB   = if ($InstallConfig -and $InstallConfig.TempDbLogFileSizeMB) { $InstallConfig.TempDbLogFileSizeMB } else { 1024 }
    $logGrowthMB = if ($InstallConfig -and $InstallConfig.TempDbLogGrowthMB)   { $InstallConfig.TempDbLogGrowthMB }   else { 512 }

    Set-DbaTempDbConfig -SqlInstance $SqlInstance `
        -DataFileCount $files `
        -DataPath      $SqlPaths.TempDB `
        -LogPath       $SqlPaths.TempLog `
        -DataFileSize  $sizeMB `
        -DataFileGrowth $growthMB `
        -LogFileSize   $logSizeMB `
        -LogFileGrowth $logGrowthMB `
        -Confirm:$false
}

function Disable-SqlBrowserService {
    param([string]$LogCallback)
    try {
        $svc = Get-Service -Name 'SQLBrowser' -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service  -Name 'SQLBrowser' -Force -ErrorAction SilentlyContinue
            Set-Service   -Name 'SQLBrowser' -StartupType Disabled -ErrorAction Stop
        }
    }
    catch {
        # nicht-kritisch, nur loggen
        throw $_
    }
}

function Invoke-CustomPostInstallScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$SqlInstance,
        [ScriptBlock]$LogCallback
    )
    & $ScriptPath -SqlInstance $SqlInstance -LogCallback $LogCallback
}

function Invoke-SqlScriptFolder {
    <#
    .SYNOPSIS
        Fuehrt alle *.sql-Dateien in einem Ordner alphabetisch gegen eine SQL-Instanz aus.
    .DESCRIPTION
        Liest alle *.sql-Dateien im angegebenen Ordner (keine Unterordner), sortiert sie
        alphabetisch und fuehrt sie nacheinander via Invoke-DbaQuery aus.
        Ein Fehler in einem Skript stoppt die Ausfuehrung und wird als WARN geloggt --
        die restlichen Skripte werden dennoch versucht (ContinueOnError-Verhalten).
    #>
    param(
        [Parameter(Mandatory)][string]$SqlInstance,
        [Parameter(Mandatory)][string]$ScriptsPath,
        [ScriptBlock]$LogCallback
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg }
        else              { Write-Host $msg }
    }

    $scripts = Get-ChildItem -Path $ScriptsPath -Filter '*.sql' -File |
               Sort-Object Name

    if ($scripts.Count -eq 0) {
        log "  Keine *.sql-Dateien in $ScriptsPath gefunden -- wird uebersprungen."
        return
    }

    log "  $($scripts.Count) SQL-Skript(e) gefunden -- Ausfuehrung beginnt..."
    $ok   = 0
    $fail = 0

    foreach ($script in $scripts) {
        log "  --> $($script.Name)"
        try {
            $sql = Get-Content -Path $script.FullName -Raw -Encoding UTF8
            # GO-Trenner unterstuetzen: Skript in Batches aufteilen
            $batches = $sql -split '\r?\nGO\r?\n|\r?\nGO$' |
                       Where-Object { $_.Trim() -ne '' }
            foreach ($batch in $batches) {
                Invoke-DbaQuery -SqlInstance $SqlInstance `
                    -Query $batch `
                    -MessagesToOutput $false `
                    -ErrorAction Stop
            }
            log "      OK"
            $ok++
        }
        catch {
            log "      WARN: $($script.Name) fehlgeschlagen -- $_"
            $fail++
        }
    }

    if ($fail -eq 0) {
        log "  Alle $ok SQL-Skript(e) erfolgreich ausgefuehrt."
    }
    else {
        log "  Ergebnis: $ok OK / $fail fehlgeschlagen -- bitte Log pruefen."
    }
}

Export-ModuleMember -Function Invoke-PostInstall, Invoke-SqlScriptFolder
