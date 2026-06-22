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

    Checkpoint/Resume:
    - Jeder Schritt wird nach Erfolg in einer State-Datei je Instanz vermerkt
      (<StatePath>\SqlSetup_<Instanz>_state.json).
    - Bei einem erneuten Lauf (z.B. nach Abbruch/Neustart) werden bereits als
      'Completed' markierte Schritte uebersprungen - vorherige Ausgaben werden NICHT
      wiederholt. -Force ignoriert den State und fuehrt alle Schritte erneut aus.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-PostInstall {
    <#
    .SYNOPSIS
        Orchestriert alle Post-Installation Tasks (mit Checkpoint/Resume).
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
    .PARAMETER QualysEnabled
        Enable-sqmMonitoringAccess nach der Installation ausfuehren? (aus settings.ini [Qualys]).
        Standard: $false.
    .PARAMETER QualysMonitoringUser
        Windows-Login des Qualys-Accounts. Leer = Wert aus sqmSQLTool DefaultMonitoringUser.
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
    .PARAMETER StatePath
        Verzeichnis fuer die Checkpoint-Datei (Standard: C:\System\WinSrvLog\MSSQL).
        Pro Instanz wird dort SqlSetup_<Instanz>_state.json gefuehrt.
    .PARAMETER Force
        Vorhandenen Fortschritt ignorieren und ALLE Schritte erneut ausfuehren.
    #>
    param(
        [Parameter(Mandatory)][string]$SqlInstance,
        [Parameter(Mandatory)][PSCustomObject]$SqlPaths,
        [ValidateSet(0, 1, 2)][int]$MonitoringType = 1,
        [string]$PostInstallScript,
        [bool]$EnableTsm = $false,
        [PSCustomObject]$InstallConfig,
        [bool]$SplunkEnabled = $false,
        [bool]$QualysEnabled = $false,
        [string]$QualysMonitoringUser = '',
        [string[]]$SysadminGroups = @(),
        [string]$OlaSourcePath = '',
        [string]$SqlScriptsPath = '',
        [int]$BasePort = 0,
        [int]$PortIncrement = 10,
        [string]$ComputerName = $env:COMPUTERNAME,
        [ScriptBlock]$LogCallback,
        [string]$StatePath = 'C:\System\WinSrvLog\MSSQL',
        [switch]$Force
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg }
        else              { Write-Host $msg }
    }

    # ------------------------------------------------------------------
    # Checkpoint / Resume - State je Instanz
    # ------------------------------------------------------------------
    $safeInst  = $SqlInstance -replace '[\\/:*?"<>|]', '_'
    $stateFile = Join-Path $StatePath ("SqlSetup_${safeInst}_state.json")
    $state     = @{ }

    function Save-State {
        try {
            $dir = Split-Path $stateFile -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $arr = $state.GetEnumerator() | ForEach-Object {
                [PSCustomObject]@{ Id = $_.Key; Status = $_.Value.Status; Timestamp = $_.Value.Timestamp; Message = $_.Value.Message }
            }
            (@($arr) | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $stateFile -Encoding UTF8
        }
        catch { log "  WARN: Fortschritt konnte nicht gespeichert werden: $_" }
    }

    if ($Force) {
        log "PostInstall: -Force gesetzt - vorhandener Fortschritt wird ignoriert, alle Schritte laufen erneut."
        if (Test-Path $stateFile) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue }
    }
    elseif (Test-Path $stateFile) {
        try {
            $loaded = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in @($loaded)) {
                $state[[string]$e.Id] = @{ Status = [string]$e.Status; Timestamp = [string]$e.Timestamp; Message = [string]$e.Message }
            }
            $done = @($state.Values | Where-Object { $_.Status -eq 'Completed' }).Count
            log "PostInstall: Fortschritt geladen ($done Schritt(e) bereits erledigt) - setze fort. State: $stateFile"
        }
        catch {
            log "  WARN: State-Datei nicht lesbar - starte komplett neu: $_"
            $state = @{ }
        }
    }

    # Wrapper: ueberspringt erledigte Schritte, fuehrt sonst aus und persistiert sofort.
    function Invoke-Step {
        param(
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][scriptblock]$Body
        )
        if ($state.ContainsKey($Id) -and $state[$Id].Status -eq 'Completed') {
            log "PostInstall: [$Id] $Name - bereits erledigt ($($state[$Id].Timestamp)), uebersprungen."
            return
        }
        log "PostInstall: [$Id] $Name ..."
        try {
            & $Body
            $state[$Id] = @{ Status = 'Completed'; Timestamp = (Get-Date).ToString('o'); Message = '' }
            Save-State
        }
        catch {
            $state[$Id] = @{ Status = 'Failed'; Timestamp = (Get-Date).ToString('o'); Message = "$_" }
            Save-State
            throw
        }
    }

    try {
        # ===== 1. NTFS-Berechtigungen =====
        Invoke-Step '01-Ntfs' 'NTFS-Berechtigungen' {
            Invoke-sqmNtfsSetup -SqlInstance $SqlInstance -ErrorAction Stop
            log "  OK: NTFS-Berechtigungen konfiguriert"
        }

        # ===== 2. Performance-Einstellungen (+ TCP-Port) =====
        Invoke-Step '02-Performance' 'Performance-Parameter' {
            Set-SqlMaxMemory -SqlInstance $SqlInstance
            log "  OK: Max Server Memory = 90% RAM"
            Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'optimize for ad hoc workloads' -Value 1 -Confirm:$false
            log "  OK: optimize for ad hoc workloads = 1"
            Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'cost threshold for parallelism' -Value 50 -Confirm:$false
            log "  OK: Cost Threshold for Parallelism = 50"
            Set-SqlMaxDop -SqlInstance $SqlInstance
            log "  OK: MAXDOP konfiguriert"
            if ($BasePort -gt 0) {
                try {
                    $portResult = Set-sqmTcpPort -SqlInstance $SqlInstance -BasePort $BasePort -PortIncrement $PortIncrement -ErrorAction Stop
                    log "  OK: TCP-Port $($portResult.Port) [$($portResult.Status)]"
                    log '  HINWEIS: SQL Server muss neu gestartet werden damit der Port aktiv wird.'
                }
                catch { log "  WARN: TCP-Port konnte nicht gesetzt werden: $_" }
            }
        }

        # ===== 3. SQL Server Agent =====
        Invoke-Step '03-Agent' 'SQL Server Agent (Autostart)' {
            Enable-SqlAgentAutoStart -SqlInstance $SqlInstance
            log "  OK: SQL Agent auf Automatisch gesetzt"
        }

        # ===== 4. TempDB =====
        Invoke-Step '04-TempDb' 'TempDB-Optimierung' {
            Set-SqlTempDbFiles -SqlInstance $SqlInstance -SqlPaths $SqlPaths -InstallConfig $InstallConfig
            log "  OK: TempDB konfiguriert (CPU-basierte Dateianzahl, Groesse aus Konfiguration)"
        }

        # ===== 5. Recovery-Modell =====
        Invoke-Step '05-Recovery' 'Recovery-Modell FULL (system, msdb)' {
            Invoke-sqmSetDatabaseRecoveryMode -SqlInstance $SqlInstance -Database 'system', 'msdb' -RecoveryMode 'FULL' -ErrorAction Stop
            log "  OK: Recovery-Modell = FULL (system, msdb)"
        }

        # ===== 6. SQL Browser Service deaktivieren =====
        $browserDisabled = if ($InstallConfig) { $InstallConfig.BrowserSvcDisabled } else { $true }
        if ($browserDisabled) {
            Invoke-Step '06-BrowserDisable' 'SQL Browser deaktivieren' {
                try { Disable-SqlBrowserService; log "  OK: SQLBrowser deaktiviert." }
                catch { log "  WARN: SQLBrowser konnte nicht deaktiviert werden: $_" }
            }
        }

        # ===== 7. AD-Sysadmin-Gruppen zuweisen =====
        Invoke-Step '07-SysadminGroups' 'AD-Sysadmin-Gruppen zuweisen' {
            if ($SysadminGroups -and $SysadminGroups.Count -gt 0) {
                $assignedCount = 0
                foreach ($group in $SysadminGroups) {
                    try {
                        Add-DbaServerRoleMember -SqlInstance $SqlInstance -Login $group -ServerRole sysadmin -Confirm:$false -ErrorAction Stop
                        log "  OK: '$group' zur sysadmin-Rolle hinzugefuegt"
                        $assignedCount++
                    }
                    catch { log "  WARN: '$group' konnte nicht zugewiesen werden: $_" }
                }
                log "  Ergebnis: $assignedCount von $($SysadminGroups.Count) Gruppe(n) erfolgreich zugewiesen."
            }
            else {
                log "  Keine Sysadmin-Gruppen konfiguriert (settings.ini [SysadminGroups])."
                log "  HINWEIS: SA-Obfuscation wird nur durchgefuehrt wenn ein anderer Sysadmin existiert."
            }
        }

        # ===== 8. SA-Obfuscation =====
        # Durabel abgesichert (auch ohne State): nur wenn SID 0x01 noch 'sa' heisst UND ein
        # weiteres aktives sysadmin-Login existiert. So wird ein bereits verschleierter SA
        # NICHT erneut umbenannt und kein neues Passwort erzeugt.
        Invoke-Step '08-SaObfuscation' 'SA-Obfuscation' {
            $saRow = Invoke-DbaQuery -SqlInstance $SqlInstance -Database master `
                -Query "SELECT name FROM sys.server_principals WHERE sid = 0x01" -ErrorAction Stop
            if ($saRow -and $saRow.name -and $saRow.name -ne 'sa') {
                log "  SA-Konto bereits verschleiert (SID 0x01 = '$($saRow.name)') - uebersprungen, kein neues Passwort."
                return
            }
            $otherAdmins = (Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query @"
SELECT COUNT(*) AS c FROM sys.server_principals
WHERE IS_SRVROLEMEMBER('sysadmin', name) = 1 AND sid <> 0x01 AND name NOT LIKE '##%'
"@ -ErrorAction Stop).c
            if ([int]$otherAdmins -le 0) {
                log "  WARN: Kein weiteres aktives sysadmin-Login - SA-Obfuscation uebersprungen (Sicherheitsabbruch)."
                log "  HINWEIS: [SysadminGroups] konfigurieren und mit -Force erneut ausfuehren."
                return
            }
            try {
                $saResult = @(Invoke-sqmSaObfuscation -SqlInstance $SqlInstance -ContinueOnError -ErrorAction Stop)[0]
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
                else { log "  WARN: SA-Obfuscation fehlgeschlagen: $($saResult.Message)" }
            }
            catch { log "  WARN: SA-Obfuscation fehlgeschlagen: $_" }
        }

        # ===== 9. Monitoring-Key =====
        Invoke-Step '09-MonitoringKey' 'Monitoring-Key' {
            $monMap = @{ 0 = 'None'; 1 = 'Standard'; 2 = 'Full' }
            $monStr = $monMap[$MonitoringType]
            $tsmValue = if ($EnableTsm) { 1 } else { 0 }
            Invoke-sqmMonitoringKey -ComputerName $ComputerName -Operation 'Set' -SQL $monStr -TSM $tsmValue -ErrorAction Stop
            $tsmStatus = if ($EnableTsm) { 'Aktiv' } else { 'Inaktiv' }
            log "  OK: Monitoring SQL=$monStr TSM=$tsmStatus"
        }

        # ===== 10a. Qualys Monitoring-Zugang =====
        if ($QualysEnabled) {
            Invoke-Step '10a-Qualys' 'Qualys Monitoring-Zugang' {
                try {
                    $qualysParams = @{ ComputerName = $ComputerName; ContinueOnError = $true }
                    if ($QualysMonitoringUser -and $QualysMonitoringUser -ne '') { $qualysParams['MonitoringUser'] = $QualysMonitoringUser }
                    Enable-sqmMonitoringAccess @qualysParams -ErrorAction Stop
                    log "  OK: Qualys Monitoring-Zugang eingerichtet."
                }
                catch { log "  WARN: Qualys Monitoring-Zugang fehlgeschlagen: $_" }
            }
        }
        else {
            log "PostInstall: Qualys-Schritt deaktiviert (settings.ini [Qualys] Enabled = false)."
        }

        # ===== 10. Instanz-Validierung =====
        Invoke-Step '10-InstanceCheck' 'Instanz-Validierung' {
            $check = Get-sqmSQLInstanceCheck -SqlInstance $SqlInstance -ErrorAction Stop
            log "  OK: Instanz-Status: $($check.Status)"
        }

        # ===== 11. Benutzerdefiniertes PostInstall-Script =====
        if ($PostInstallScript -and (Test-Path $PostInstallScript)) {
            Invoke-Step '11-CustomScript' 'Benutzerdefiniertes PostInstall-Script' {
                Invoke-CustomPostInstallScript -ScriptPath $PostInstallScript -SqlInstance $SqlInstance -LogCallback $LogCallback
                log "  OK: Benutzerdefiniertes Script abgeschlossen"
            }
        }

        # ===== 12. Ola Hallengren Maintenance Solution =====
        # Inline (nicht via Invoke-Step), damit der Schritt nur bei tatsaechlichem Erfolg als
        # 'Completed' markiert wird - so wird er bei einem Fehlschlag (z.B. kein Internet) beim
        # naechsten Lauf erneut versucht. OlaOk wird beim Resume aus dem State abgeleitet.
        $olaOk = $false
        if ($state.ContainsKey('12-OlaInstall') -and $state['12-OlaInstall'].Status -eq 'Completed') {
            $olaOk = $true
            log "PostInstall: [12-OlaInstall] Ola Hallengren - bereits erledigt ($($state['12-OlaInstall'].Timestamp)), uebersprungen."
        }
        else {
            log "PostInstall: [12-OlaInstall] Ola Hallengren Maintenance Solution ..."
            try {
                Install-sqmOlaMaintenanceSolution -SqlInstance $SqlInstance -ErrorAction Stop
                $olaOk = $true
                log "  OK: Maintenance Solution von GitHub installiert"
            }
            catch {
                log "  Hinweis: GitHub nicht erreichbar ($_)"
                if ($OlaSourcePath -and (Test-Path $OlaSourcePath)) {
                    try {
                        Install-sqmOlaMaintenanceSolution -SqlInstance $SqlInstance -SourcePath $OlaSourcePath -ErrorAction Stop
                        $olaOk = $true
                        log "  OK: Maintenance Solution von lokalem Pfad installiert ($OlaSourcePath)"
                    }
                    catch { log "  Warnung: Ola-Installation auch lokal fehlgeschlagen: $_" }
                }
                else {
                    log "  Warnung: OlaSourcePath nicht konfiguriert - Maintenance Solution wird uebersprungen"
                    log "           (Tipp: OlaSourcePath in settings.ini [Maintenance] setzen)"
                }
            }
            if ($olaOk) {
                $state['12-OlaInstall'] = @{ Status = 'Completed'; Timestamp = (Get-Date).ToString('o'); Message = '' }
                Save-State
            }
        }

        if ($olaOk) {
            # ===== 13. Maintenance Jobs (IndexOptimize + IntegrityCheck) =====
            Invoke-Step '13-MaintenanceJobs' 'Maintenance Jobs (IndexOptimize + IntegrityCheck)' {
                New-sqmOlaMaintenanceJobs -SqlInstance $SqlInstance
                log "  OK: IndexOptimize + IntegrityCheck Jobs erstellt"
            }
            # ===== 14. System-DB Backup Job =====
            Invoke-Step '14-SysDbBackupJob' 'System-DB Backup Job' {
                New-sqmOlaSysDbBackupJob -SqlInstance $SqlInstance
                log "  OK: System-DB Backup Job erstellt"
            }
            # ===== 15. User-DB Backup Jobs (FULL + DIFF + LOG) =====
            Invoke-Step '15-UserDbBackupJobs' 'User-DB Backup Jobs (FULL/DIFF/LOG)' {
                New-sqmOlaUsrDbBackupJob -SqlInstance $SqlInstance -Full -Diff -Log
                log "  OK: User-DB Backup Jobs FULL/DIFF/LOG erstellt"
            }
        }
        else {
            log "PostInstall: Ola nicht verfuegbar - Maintenance/Backup-Jobs (13-15) uebersprungen."
        }

        # ===== 16. Splunk Universal Forwarder konfigurieren =====
        if ($SplunkEnabled) {
            Invoke-Step '16-Splunk' 'Splunk Universal Forwarder' {
                try { Invoke-sqmSplunkConfiguration -ErrorAction Stop; log "  OK: Splunk-Konfiguration abgeschlossen." }
                catch { log "  WARN: Splunk-Konfiguration fehlgeschlagen: $_" }
            }
        }
        else {
            log "PostInstall: Splunk-Konfiguration deaktiviert (settings.ini [PostInstall] SplunkEnabled = false)."
        }

        # ===== 17. Firmen-SQL-Skripte ausfuehren =====
        if ($SqlScriptsPath -and (Test-Path $SqlScriptsPath)) {
            Invoke-Step '17-SqlScripts' 'Firmen-SQL-Skripte' {
                Invoke-SqlScriptFolder -SqlInstance $SqlInstance -ScriptsPath $SqlScriptsPath -LogCallback $LogCallback
            }
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
        Invoke-Step '18-Report' 'Setup-Abschlussbericht' {
            try {
                $reportFile = Invoke-sqmSetupReport -SqlInstance $SqlInstance -PassThru -ErrorAction Stop
                log "  OK: Setup-Report erstellt: $reportFile"
            }
            catch { log "  WARN: Setup-Report konnte nicht erstellt werden: $_" }
        }

        log "PostInstall: Alle Tasks abgeschlossen"
    }
    catch {
        $errMsg = "PostInstall-Fehler: $_"
        log $errMsg
        log "PostInstall: Fortschritt gesichert in '$stateFile' - ein erneuter Lauf setzt beim fehlgeschlagenen Schritt fort (oder -Force fuer kompletten Neulauf)."
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
