#Requires -Version 5.1
<#
.SYNOPSIS
    Headless CLI for the SQL Server Setup Tool - installs SQL Server 2019/2022/2025 on a dbatools basis,
    optionally up to a full AlwaysOn Availability Group, with no GUI.

.DESCRIPTION
    Command-line counterpart to GUI\MainForm.ps1. Reuses the existing SQLSetupTool modules unchanged
    (Config, Validation, DiskLayout, CopySource, Installation, PostInstall, DbaToolsSetup, Drivers,
    PreInstall) plus sqmSQLTool, and reproduces the exact install flow of the GUI's "Install" button
    headlessly:

        Admin check -> import modules -> Get-SetupConfig (settings.ini + domain profile)
        -> apply CLI parameter overrides -> Assert-DbaToolsReady / Assert-sqmSQLToolReady
        -> (optional) Invoke-PreInstallChecks -> Get-SqlPaths -> New-SqlDirectories
        -> Invoke-SqlInstallation (Install-DbaInstance) -> optional components (SSAS/SSRS/TDP/SSMS)
        -> optional drivers (JDBC/ODBC/DB2) -> Invoke-PostInstall
        -> (optional) Invoke-sqmAlwaysOnSetup for the AlwaysOn AG.

    Configuration is the existing Config\settings.ini (and Config\domains\*.ini). CLI parameters only
    override individual values (version, edition, instance, collation, service account, drives).

    Logging goes to the console and to a per-run log file under -LogPath.

.PARAMETER ConfigPath
    Path to settings.ini. Default: <ScriptDir>\Config\settings.ini.

.PARAMETER Version
    SQL Server version: 2019, 2022 or 2025. Default: settings.ini [General] DefaultVersion.

.PARAMETER Edition
    Edition name (must match the version's [Editions] list, e.g. Developer, Standard,
    Developer-Standard for 2025). Default: settings.ini DefaultEdition.

.PARAMETER InstanceName
    Instance name. 'MSSQLServer' (default) = default instance, otherwise a named instance.

.PARAMETER Collation
    Server collation. Default: resolved collation from settings.ini / domain profile.

.PARAMETER ServiceAccount
    SQL service account (DOMAIN\User). When set with -ServicePassword a PSCredential is built and
    passed to Install-DbaInstance. Leave empty for the default virtual service account.

.PARAMETER ServicePassword
    Password for -ServiceAccount (SecureString). Prefer -ServiceCredential.

.PARAMETER ServiceCredential
    PSCredential for the SQL service account (alternative to -ServiceAccount/-ServicePassword).

.PARAMETER InstallDrive / DataDrive / LogDrive / TempDrive / BackupDrive
    Override the drive letters from the resolved disk layout (single letter, e.g. 'G').

.PARAMETER Component
    Optional components to install: SSRS, SSAS, SSMS, SSIS, TDP. When omitted, the components enabled
    in settings.ini [OptionalComponents] are used (SSMS and SSIS default on, matching the GUI). SSIS is
    part of the engine feature set (IS); listing it keeps IS, omitting it removes IS from Features.

.PARAMETER Driver
    Optional drivers to install: JDBC, ODBC, DB2. Only those with a configured source path run.

.PARAMETER MonitoringType
    Monitoring type for PostInstall (0=None, 1=Service, 2=Full). Default: configured MonitoringDefault.

.PARAMETER SkipPreInstall
    Skip Invoke-PreInstallChecks (64K/IFI/HPU). Forced on in -NonInteractive because those checks use
    interactive dialogs.

.PARAMETER SkipPostInstall
    Skip Invoke-PostInstall (memory/tempdb/ports/Ola/monitoring/etc.).

.PARAMETER AlwaysOn
    After install + PostInstall, run Invoke-sqmAlwaysOnSetup to create an AlwaysOn AG on the WSFC.

.PARAMETER AvailabilityGroupName / AgDatabase / AgListenerName / AgListenerIPAddress / AgListenerPort
    AlwaysOn parameters forwarded to Invoke-sqmAlwaysOnSetup (most are auto-discovered from the cluster
    when omitted).

.PARAMETER NonInteractive
    Fully unattended: no prompts, PreInstall interactive checks skipped, confirmations suppressed.

.PARAMETER LogPath
    Directory for the run log. Default: C:\System\WinSrvLog\MSSQL.

.PARAMETER WhatIf
    Dry-run: resolve config, validate inputs, print the planned paths and steps - but execute nothing.

.EXAMPLE
    .\Start-SqlSetup.ps1 -Version 2022 -Edition Developer -InstanceName MSSQLServer -NonInteractive

.EXAMPLE
    .\Start-SqlSetup.ps1 -Version 2025 -Edition Developer-Standard -InstanceName SQL01 `
        -Component SSMS,SSIS -Driver ODBC -WhatIf

.EXAMPLE
    .\Start-SqlSetup.ps1 -Version 2022 -NonInteractive -AlwaysOn `
        -AvailabilityGroupName ProdAG -AgDatabase AppDb

.NOTES
    Run elevated (Administrator). Requires the SQLSetupTool modules, dbatools and sqmSQLTool reachable
    (share / local / Gallery as configured). Existing GUI modules are reused unchanged.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath,

    [ValidateSet('2019', '2022', '2025')]
    [string]$Version,

    [string]$Edition,

    [string]$InstanceName,

    [string]$Collation,

    [string]$ServiceAccount,

    [System.Security.SecureString]$ServicePassword,

    [System.Management.Automation.PSCredential]$ServiceCredential,

    [string]$InstallDrive,
    [string]$DataDrive,
    [string]$LogDrive,
    [string]$TempDrive,
    [string]$BackupDrive,

    [ValidateSet('SSRS', 'SSAS', 'SSMS', 'SSIS', 'TDP')]
    [string[]]$Component,

    [ValidateSet('JDBC', 'ODBC', 'DB2')]
    [string[]]$Driver,

    [ValidateRange(0, 2)]
    [int]$MonitoringType = -1,

    [switch]$SkipPreInstall,
    [switch]$SkipPostInstall,

    [switch]$AlwaysOn,
    [string]$AvailabilityGroupName,
    [string[]]$AgDatabase,
    [string]$AgListenerName,
    [string[]]$AgListenerIPAddress,
    [int]$AgListenerPort,

    [switch]$NonInteractive,

    [string]$LogPath = 'C:\System\WinSrvLog\MSSQL',

    [switch]$ProgressReport,
    [string]$ProgressReportPath,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging: console + per-run file. Returned as a -LogCallback ScriptBlock.
# ---------------------------------------------------------------------------
$script:LogFile = $null
try {
    if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
    $script:LogFile = Join-Path $LogPath ("SqlSetupCli_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
} catch {
    Write-Warning "Log-Verzeichnis nicht beschreibbar ($LogPath): $_ - es wird nur auf die Konsole geloggt."
}

function Write-CliLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARNING' { Write-Host $line -ForegroundColor Yellow }
        'OK'      { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

# --- Progress-Report (optionaler animierter HTML-Ablauf) ---
$script:EventLog    = $null
$script:ReportPath  = $null
$script:CurrentPhase = $null
if ($ProgressReport) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $base  = if ($ProgressReportPath) { [System.IO.Path]::GetDirectoryName($ProgressReportPath) } else { $LogPath }
    if (-not $base) { $base = $LogPath }
    try { if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null } } catch { }
    $script:EventLog   = Join-Path $base "SqlSetup_$stamp.events.jsonl"
    $script:ReportPath = if ($ProgressReportPath) { $ProgressReportPath } else { Join-Path $base "SqlSetup_$stamp.html" }
}

# Emit a setup event (no-op unless -ProgressReport and the sqm function is loaded)
function Emit {
    param([string]$Phase, [string]$Step, [string]$State = 'progress', [string]$Title = '', [string]$Detail = '', [string]$Node = '', [string]$Viz = '')
    if (-not $script:EventLog) { return }
    if (Get-Command Write-sqmSetupEvent -ErrorAction SilentlyContinue) {
        Write-sqmSetupEvent -Path $script:EventLog -Phase $Phase -Step $Step -State $State -Title $Title -Detail $Detail -Node $Node -Viz $Viz
    }
}
function Set-Phase { param([string]$Phase, [string]$Title) $script:CurrentPhase = $Phase; Emit -Phase $Phase -Step $Phase -State 'start' -Title $Title }
function End-Phase { param([string]$Phase, [string]$Title) Emit -Phase $Phase -Step $Phase -State 'done' -Title $Title; $script:CurrentPhase = $null }

# LogCallback compatible with the module's { param($msg) ... } contract; mirrors into a progress event
$logCb = {
    param($msg)
    Write-CliLog -Message $msg
    if ($script:EventLog -and $script:CurrentPhase) { Emit -Phase $script:CurrentPhase -Step 'log' -State 'progress' -Title $msg }
}

# ---------------------------------------------------------------------------
# 1. Admin check
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-CliLog 'Dieses Tool muss als Administrator ausgefuehrt werden.' 'ERROR'
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Base paths + module import (identical set to Main.ps1)
# ---------------------------------------------------------------------------
$ScriptDir  = $PSScriptRoot
$ModulesDir = Join-Path $ScriptDir 'Modules'
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'Config\settings.ini' }

$moduleNames = @('Config', 'Validation', 'DiskLayout', 'CopySource', 'Installation',
                 'PostInstall', 'DbaToolsSetup', 'Drivers', 'PreInstall', 'SetupState')
foreach ($mod in $moduleNames) {
    $modPath = Join-Path $ModulesDir "$mod.psm1"
    if (-not (Test-Path $modPath)) { Write-CliLog "Modul nicht gefunden: $modPath" 'ERROR'; exit 1 }
    Import-Module $modPath -Force -ErrorAction Stop
}

if (-not (Test-Path $ConfigPath)) { Write-CliLog "Konfigurationsdatei nicht gefunden: $ConfigPath" 'ERROR'; exit 1 }

# ---------------------------------------------------------------------------
# 3. Build configuration object
# ---------------------------------------------------------------------------
Write-CliLog "Lese Konfiguration: $ConfigPath"
$Config = Get-SetupConfig -IniPath $ConfigPath
Write-CliLog ("Domain: {0} | DefaultVersion: {1} | DefaultEdition: {2}" -f `
    ($(if ($Config.Domain) { $Config.Domain } else { 'keine' })), $Config.DefaultVersion, $Config.DefaultEdition)

# Resolve relative PostInstall script path (as Main.ps1 does)
if ($Config.PostInstallScript -and -not [System.IO.Path]::IsPathRooted($Config.PostInstallScript)) {
    $Config.PostInstallScript = Join-Path $ScriptDir $Config.PostInstallScript
}

# ---------------------------------------------------------------------------
# 4. Apply CLI overrides on top of config defaults
# ---------------------------------------------------------------------------
$selVersion   = if ($Version)      { $Version }      else { $Config.DefaultVersion }
$selEdition   = if ($Edition)      { $Edition }      else { $Config.DefaultEdition }
$selInstance  = if ($InstanceName) { $InstanceName } else { $Config.DefaultInstanceName }
$selCollation = if ($Collation)    { $Collation }    else { $Config.DefaultCollation }
$selMonitoring = if ($MonitoringType -ge 0) { $MonitoringType } else { $Config.MonitoringDefault }

# Validate version is available in config
if ($Config.Versions -and ($Config.Versions -notcontains $selVersion)) {
    Write-CliLog "Version '$selVersion' ist in settings.ini [Versions] Available nicht aufgefuehrt: $($Config.Versions -join ', ')" 'WARNING'
}

# Validate edition against the version's edition list
$edKey = "SQL$selVersion"
$validEditions = if ($Config.EditionMap.Contains($edKey)) { $Config.EditionMap[$edKey] }
                 elseif ($Config.EditionMap.Contains('Standard')) { $Config.EditionMap['Standard'] }
                 else { @($selEdition) }
if ($validEditions -notcontains $selEdition) {
    Write-CliLog "Edition '$selEdition' nicht in der Liste fuer SQL $selVersion ($($validEditions -join ', ')) - wird dennoch verwendet." 'WARNING'
}

# Disk layout (hashtable copy so overrides do not mutate the config object)
$diskLayout = @{}
foreach ($k in $Config.DiskLayout.Keys) { $diskLayout[$k] = $Config.DiskLayout[$k] }
if ($InstallDrive) { $diskLayout['InstallDrive'] = $InstallDrive.TrimEnd(':').Trim() }
if ($DataDrive)    { $diskLayout['DataDrive']    = $DataDrive.TrimEnd(':').Trim() }
if ($LogDrive)     { $diskLayout['LogDrive']     = $LogDrive.TrimEnd(':').Trim() }
if ($TempDrive)    { $diskLayout['TempDrive']    = $TempDrive.TrimEnd(':').Trim() }
if ($BackupDrive)  { $diskLayout['BackupDrive']  = $BackupDrive.TrimEnd(':').Trim() }

# Service credential
$serviceCredential = $null
if ($ServiceCredential) {
    $serviceCredential = $ServiceCredential
} elseif ($ServiceAccount -and $ServicePassword) {
    $serviceCredential = New-Object System.Management.Automation.PSCredential($ServiceAccount, $ServicePassword)
} elseif ($ServiceAccount) {
    Write-CliLog "ServiceAccount ohne Passwort angegeben - es wird kein EngineCredential gesetzt." 'WARNING'
}

# Component selection: default to config-enabled (SSMS + SSIS on, like the GUI)
$oc = $Config.OptionalComponents
function _OptEnabled([string]$key) { return ($oc -and $oc.Contains($key) -and $oc[$key] -eq 'true') }
if ($PSBoundParameters.ContainsKey('Component')) {
    $selComponents = @($Component)
} else {
    $selComponents = @()
    if (_OptEnabled 'SSRS_Enabled') { $selComponents += 'SSRS' }
    if (_OptEnabled 'SSAS_Enabled') { $selComponents += 'SSAS' }
    if (_OptEnabled 'SSMS_Enabled') { $selComponents += 'SSMS' }   # GUI default-checked
    if (_OptEnabled 'SSIS_Enabled') { $selComponents += 'SSIS' }   # GUI default-checked
    if (_OptEnabled 'TDP_Enabled')  { $selComponents += 'TDP' }
}

# Driver selection: default to config-enabled with a source path
$drv = $Config.Drivers
function _DrvReady([string]$en, [string]$path) { return ($drv -and $drv.Contains($en) -and $drv[$en] -eq 'true' -and $drv.Contains($path) -and $drv[$path] -ne '') }
if ($PSBoundParameters.ContainsKey('Driver')) {
    $selDrivers = @($Driver)
} else {
    $selDrivers = @()
    if (_DrvReady 'JDBC_Enabled' 'JDBC_SourcePath') { $selDrivers += 'JDBC' }
    if (_DrvReady 'ODBC_Enabled' 'ODBC_SourcePath') { $selDrivers += 'ODBC' }
    if (_DrvReady 'DB2_Enabled'  'DB2_SourcePath')  { $selDrivers += 'DB2' }
}

# Serial / product key
$serialKey  = "SQL${selVersion}_${selEdition}"
$productKey = if ($Config.SerialNumbers.Contains($serialKey)) { $Config.SerialNumbers[$serialKey] } else { '' }

# ---------------------------------------------------------------------------
# 5. dbatools + sqmSQLTool readiness
# ---------------------------------------------------------------------------
Write-CliLog 'Stelle dbatools sicher (Share -> lokal -> Gallery) ...'
Assert-DbaToolsReady -DbaToolsConfig $Config.DbaTools
Write-CliLog 'Stelle sqmSQLTool sicher ...'
Assert-sqmSQLToolReady -sqmSQLToolConfig $Config.sqmSQLTool

# ---------------------------------------------------------------------------
# 6. Resolve paths + print plan
# ---------------------------------------------------------------------------
$sqlPaths = Get-SqlPaths -DiskLayout $diskLayout -Paths $Config.Paths -InstanceName $selInstance

Write-CliLog '================= Installationsplan ================='
Write-CliLog ("  Version   : SQL Server $selVersion")
Write-CliLog ("  Edition   : $selEdition")
Write-CliLog ("  Instanz   : $selInstance")
Write-CliLog ("  Collation : $selCollation")
Write-CliLog ("  Konto     : {0}" -f $(if ($serviceCredential) { $serviceCredential.UserName } else { '(Standard-Dienstkonto)' }))
Write-CliLog ("  Komponenten: {0}" -f $(if ($selComponents.Count) { $selComponents -join ', ' } else { '(keine)' }))
Write-CliLog ("  Treiber    : {0}" -f $(if ($selDrivers.Count) { $selDrivers -join ', ' } else { '(keine)' }))
Write-CliLog ("  Monitoring : $selMonitoring")
Write-CliLog ("  AlwaysOn   : {0}" -f $(if ($AlwaysOn) { 'ja' } else { 'nein' }))
foreach ($l in (Format-DiskLayoutSummary -SqlPaths $sqlPaths) -split "`n") { Write-CliLog "  $l" }
Write-CliLog '====================================================='

# ---------------------------------------------------------------------------
# 7. Dry-run exit
# ---------------------------------------------------------------------------
if ($WhatIfPreference) {
    Write-CliLog '-WhatIf aktiv: Es werden keine Aenderungen vorgenommen. Plan oben.' 'OK'
    if ($AlwaysOn) {
        Write-CliLog 'AlwaysOn-Schritt wuerde Invoke-sqmAlwaysOnSetup -WhatIf ausfuehren (Cluster-Erkennung + AG-Plan).'
    }
    if ($script:EventLog) {
        # Replay des GEPLANTEN Ablaufs erzeugen (eine Phase je vorgesehenem Schritt)
        Emit -Phase 'install' -Step 'install' -State 'start' -Title "SQL Server $selVersion installieren" -Detail "$selEdition / $selInstance" -Viz 'gears'
        Emit -Phase 'install' -Step 'install' -State 'done' -Title 'Installation geplant'
        foreach ($comp in $selComponents) { Emit -Phase 'components' -Step $comp -State 'done' -Title "$comp installieren (geplant)" }
        foreach ($d in $selDrivers)       { Emit -Phase 'drivers' -Step $d -State 'done' -Title "$d-Treiber (geplant)" }
        if (-not $SkipPostInstall) { Emit -Phase 'postinstall' -Step 'postinstall' -State 'done' -Title 'PostInstall (geplant)' }
        if ($AlwaysOn) { Emit -Phase 'alwayson' -Step 'ag' -State 'done' -Title "AG '$AvailabilityGroupName' (geplant)" -Viz 'data-replicate' }
        $rep = New-sqmSetupReport -EventPath $script:EventLog -OutputPath $script:ReportPath -Title "SQL Server Setup (Plan)" -Server $env:COMPUTERNAME
        if ($rep) { Write-CliLog "Ablauf-Report (Plan): $rep" 'OK' }
    }
    return
}

# ---------------------------------------------------------------------------
# 7b. Drive pre-check (real run only): fail early with a clear message if a
#     configured drive is missing, instead of failing later in New-SqlDirectories.
# ---------------------------------------------------------------------------
$reqDrives = @('InstallDrive', 'DataDrive', 'LogDrive', 'TempDrive', 'BackupDrive') |
    ForEach-Object { $diskLayout[$_] } |
    Where-Object { $_ } |
    ForEach-Object { $_.TrimEnd(':').Trim().ToUpper() } |
    Select-Object -Unique
$missingDrives = @($reqDrives | Where-Object { -not (Test-Path -LiteralPath "$($_):\") })
if ($missingDrives.Count -gt 0) {
    $msg = 'Konfigurierte Laufwerke fehlen auf diesem Server: ' + (($missingDrives | ForEach-Object { "$($_):" }) -join ', ')
    Write-CliLog $msg 'ERROR'
    Write-CliLog 'Bitte Datentraeger bereitstellen oder Laufwerksbuchstaben anpassen (settings.ini / Domain-Profil / -InstallDrive/-DataDrive/...).' 'ERROR'
    Emit -Phase 'dirs' -Step 'drive-check' -State 'error' -Title 'Laufwerke fehlen' -Detail $msg
    if ($script:EventLog) { New-sqmSetupReport -EventPath $script:EventLog -OutputPath $script:ReportPath -Server $env:COMPUTERNAME | Out-Null }
    exit 4
}
Write-CliLog ('Laufwerks-Pruefung OK: ' + (($reqDrives | ForEach-Object { "$($_):" }) -join ', ') + ' vorhanden.') 'OK'

# ---------------------------------------------------------------------------
# 8. PreInstall checks (interactive dialogs -> only when not NonInteractive)
# ---------------------------------------------------------------------------
if (-not $SkipPreInstall -and -not $NonInteractive) {
    Set-Phase 'preinstall' 'PreInstall-Pruefungen'
    $preOk = Invoke-PreInstallChecks -Config $Config -DiskLayout $diskLayout -InstanceName $selInstance -LogCallback $logCb
    if (-not $preOk) {
        Emit -Phase 'preinstall' -Step 'preinstall' -State 'error' -Title 'PreInstall abgebrochen'
        if ($script:EventLog) { New-sqmSetupReport -EventPath $script:EventLog -OutputPath $script:ReportPath -Server $env:COMPUTERNAME | Out-Null }
        Write-CliLog 'Installation abgebrochen (PreInstall-Pruefung).' 'WARNING'; exit 2
    }
    End-Phase 'preinstall' 'PreInstall ok'
} else {
    Write-CliLog 'PreInstall-Pruefungen uebersprungen (NonInteractive oder -SkipPreInstall).'
}

# ---------------------------------------------------------------------------
# 9. Create directories
# ---------------------------------------------------------------------------
# Checkpoint/Resume-Kontext fuer die Installations-Phasen (Verzeichnisse, Installation, Komponenten,
# Treiber). Bei einem erneuten Lauf werden bereits erledigte Phasen uebersprungen. -Force = alles neu.
$setupState = New-SetupState -InstanceName $selInstance -StatePath $LogPath -Scope 'install' -Force:$Force -LogCallback $logCb

Set-Phase 'dirs' 'SQL-Verzeichnisse anlegen'
Invoke-SetupStep -Context $setupState -Id 'dirs' -Name 'SQL-Verzeichnisse anlegen' -Body {
    $dirResults = New-SqlDirectories -SqlPaths $sqlPaths
    foreach ($dr in $dirResults) { Write-CliLog "  $($dr.Status): $($dr.Pfad)" }
}
End-Phase 'dirs' 'Verzeichnisse angelegt'

# ---------------------------------------------------------------------------
# 10. SQL Server installation (Install-DbaInstance via Invoke-SqlInstallation)
# ---------------------------------------------------------------------------
# Honour SSIS selection: remove IS from Features if SSIS not requested (mirrors GUI behaviour)
if ($selComponents -notcontains 'SSIS' -and $Config.InstallationConfig.Features -contains 'IS') {
    $Config.InstallationConfig.Features = @($Config.InstallationConfig.Features | Where-Object { $_ -ne 'IS' })
    Write-CliLog '  SSIS (IS) wird nicht installiert (nicht in -Component).'
}

Set-Phase 'install' "SQL Server $selVersion installieren"
if (Test-SetupStepDone -Context $setupState -Id 'install') {
    Write-CliLog 'Installation bereits erledigt (Checkpoint) - uebersprungen.' 'OK'
}
else {
    # Durable: eine bereits vorhandene/erreichbare Instanz NICHT erneut installieren.
    $alreadyInstalled = $false
    try { $null = Connect-DbaInstance -SqlInstance $selInstance -ErrorAction Stop; $alreadyInstalled = $true } catch { }
    if ($alreadyInstalled) {
        Write-CliLog "Instanz '$selInstance' ist bereits vorhanden/erreichbar - Installation uebersprungen." 'OK'
        Set-SetupStepDone -Context $setupState -Id 'install' -Message 'pre-existing'
    }
    else {
        Write-CliLog "Starte Installation von SQL Server $selVersion ..."
        $installResult = Invoke-SqlInstallation `
            -SqlPaths          $sqlPaths `
            -Version           $selVersion `
            -Edition           $selEdition `
            -InstanceName      $selInstance `
            -Collation         $selCollation `
            -ProductKey        $productKey `
            -ServiceCredential $serviceCredential `
            -InstallDrive      $diskLayout['InstallDrive'] `
            -InstallConfig     $Config.InstallationConfig `
            -LogCallback       $logCb

        if (-not $installResult.Success) {
            Emit -Phase 'install' -Step 'install' -State 'error' -Title 'Installation fehlgeschlagen' -Detail $installResult.Message
            if ($script:EventLog) { New-sqmSetupReport -EventPath $script:EventLog -OutputPath $script:ReportPath -Server $env:COMPUTERNAME | Out-Null }
            Write-CliLog "Installation fehlgeschlagen: $($installResult.Message)" 'ERROR'
            exit 3
        }
        Set-SetupStepDone -Context $setupState -Id 'install'
        Write-CliLog "Installation abgeschlossen: $($installResult.Message)" 'OK'
    }
}
End-Phase 'install' 'Installation abgeschlossen'

# Wait for readiness (same loop as GUI)
Write-CliLog 'Pruefe SQL Server Readiness ...'
$sqlReady = $false
for ($try = 1; $try -le 15 -and -not $sqlReady; $try++) {
    try { $null = Connect-DbaInstance -SqlInstance $selInstance -ErrorAction Stop; $sqlReady = $true }
    catch { Start-Sleep -Seconds 2 }
}
if (-not $sqlReady) { Write-CliLog "SQL Server $selInstance nach 30s nicht erreichbar." 'ERROR'; exit 3 }
Write-CliLog "  OK: SQL Server $selInstance ist bereit" 'OK'

# ---------------------------------------------------------------------------
# 11. Optional components (before PostInstall, like the GUI)
# ---------------------------------------------------------------------------
$installDrive = $diskLayout['InstallDrive']
if (@($selComponents | Where-Object { $_ -in 'SSAS', 'SSRS', 'TDP', 'SSMS' }).Count -gt 0) { Set-Phase 'components' 'Optionale Komponenten' }
if ($selComponents -contains 'SSAS') {
    Invoke-SetupStep -Context $setupState -Id 'comp-SSAS' -Name 'SSAS installieren' -Body {
        Emit -Phase 'components' -Step 'SSAS' -State 'progress' -Title 'Installiere SSAS'
        Install-SsasComponent -SourcePath "${installDrive}:\SQLSources\SQL$selVersion\SQL_Install" `
            -InstanceName $selInstance -Collation $selCollation -LogCallback $logCb
    }
}
if ($selComponents -contains 'SSRS') {
    Invoke-SetupStep -Context $setupState -Id 'comp-SSRS' -Name 'SSRS installieren' -Body {
        Emit -Phase 'components' -Step 'SSRS' -State 'progress' -Title 'Installiere SSRS'
        $ssrsSplat = @{
            SourcePath   = "${installDrive}:\SQLSources\SQL$selVersion\Reporting"
            InstanceName = $selInstance
            Edition      = $(if ($selEdition) { $selEdition } else { 'Developer' })
            LogCallback  = $logCb
        }
        if ($productKey) { $ssrsSplat['ProductKey'] = $productKey }
        Install-SsrsComponent @ssrsSplat
    }
}
if ($selComponents -contains 'TDP') {
    Invoke-SetupStep -Context $setupState -Id 'comp-TDP' -Name 'TDP installieren' -Body {
        Emit -Phase 'components' -Step 'TDP' -State 'progress' -Title 'Installiere TDP'
        Install-TdpComponent -SourcePath "${installDrive}:\SQLSources\TDP" -InstanceName $selInstance -LogCallback $logCb
    }
}
if ($selComponents -contains 'SSMS') {
    Invoke-SetupStep -Context $setupState -Id 'comp-SSMS' -Name 'SSMS installieren' -Body {
        Emit -Phase 'components' -Step 'SSMS' -State 'progress' -Title 'Installiere SSMS'
        Install-SsmsComponent -SourcePath "${installDrive}:\SQLSources\SQL$selVersion\Management" -LogCallback $logCb
    }
}
if ($script:CurrentPhase -eq 'components') { End-Phase 'components' 'Komponenten installiert' }

# ---------------------------------------------------------------------------
# 12. Drivers
# ---------------------------------------------------------------------------
if ($selDrivers.Count -gt 0) { Set-Phase 'drivers' 'Treiber-Installation' }
if ($selDrivers -contains 'JDBC') { Invoke-SetupStep -Context $setupState -Id 'drv-JDBC' -Name 'JDBC-Treiber' -Body { Emit -Phase 'drivers' -Step 'JDBC' -State 'progress' -Title 'JDBC-Treiber'; Install-JdbcComponent -SourcePath $Config.Drivers['JDBC_SourcePath'] -LogCallback $logCb } }
if ($selDrivers -contains 'ODBC') { Invoke-SetupStep -Context $setupState -Id 'drv-ODBC' -Name 'ODBC-Treiber' -Body { Emit -Phase 'drivers' -Step 'ODBC' -State 'progress' -Title 'ODBC-Treiber'; Install-OdbcComponent -SourcePath $Config.Drivers['ODBC_SourcePath'] -LogCallback $logCb } }
if ($selDrivers -contains 'DB2')  { Invoke-SetupStep -Context $setupState -Id 'drv-DB2' -Name 'DB2-Treiber' -Body { Emit -Phase 'drivers' -Step 'DB2' -State 'progress' -Title 'DB2-Treiber'; Install-Db2Component -SourcePath $Config.Drivers['DB2_SourcePath'] -LogCallback $logCb } }
if ($script:CurrentPhase -eq 'drivers') { End-Phase 'drivers' 'Treiber installiert' }

# ---------------------------------------------------------------------------
# 13. PostInstall
# ---------------------------------------------------------------------------
if ($SkipPostInstall) {
    Write-CliLog 'PostInstall uebersprungen (-SkipPostInstall).'
} else {
    Set-Phase 'postinstall' 'PostInstall-Konfiguration'
    Write-CliLog 'Starte PostInstall-Konfiguration ...'
    Invoke-PostInstall `
        -SqlInstance          $selInstance `
        -SqlPaths             $sqlPaths `
        -MonitoringType       $selMonitoring `
        -EnableTsm            ($selComponents -contains 'TDP') `
        -InstallConfig        $Config.InstallationConfig `
        -SplunkEnabled        $Config.SplunkEnabled `
        -QualysEnabled        $Config.QualysEnabled `
        -QualysMonitoringUser $Config.QualysMonitoringUser `
        -SysadminGroups       $Config.SysadminGroups `
        -OlaSourcePath        $Config.OlaSourcePath `
        -SqlScriptsPath       $Config.SqlScriptsPath `
        -PostInstallScript    $Config.PostInstallScript `
        -BasePort             $Config.BasePort `
        -PortIncrement        $Config.PortIncrement `
        -StatePath            $LogPath `
        -Force:$Force `
        -LogCallback          $logCb
    End-Phase 'postinstall' 'PostInstall abgeschlossen'
    Write-CliLog 'PostInstall abgeschlossen.' 'OK'
}

# ---------------------------------------------------------------------------
# 14. Optional AlwaysOn setup
# ---------------------------------------------------------------------------
if ($AlwaysOn) {
    Write-CliLog '================= AlwaysOn-Setup ================='
    Import-Module sqmSQLTool -Force -ErrorAction Stop
    $aoParams = @{ }
    if ($AvailabilityGroupName)  { $aoParams.AvailabilityGroupName = $AvailabilityGroupName }
    if ($AgDatabase)             { $aoParams.Database              = $AgDatabase }
    if ($AgListenerName)         { $aoParams.ListenerName          = $AgListenerName }
    if ($AgListenerIPAddress)    { $aoParams.ListenerIPAddress     = $AgListenerIPAddress }
    if ($AgListenerPort)         { $aoParams.ListenerPort          = $AgListenerPort }
    if ($script:EventLog)        { $aoParams.EventLog              = $script:EventLog }
    $aoResult = Invoke-sqmAlwaysOnSetup @aoParams
    Write-CliLog "AlwaysOn-Setup Status: $($aoResult.Status)" $(if ($aoResult.Status -eq 'Success') { 'OK' } else { 'WARNING' })
}

Write-CliLog 'Fertig.' 'OK'
if ($script:LogFile) { Write-CliLog "Logdatei: $script:LogFile" }

# ---------------------------------------------------------------------------
# 15. Animierten Ablauf-Report erzeugen (optional)
# ---------------------------------------------------------------------------
if ($script:EventLog) {
    $rep = New-sqmSetupReport -EventPath $script:EventLog -OutputPath $script:ReportPath -Title 'SQL Server Setup' -Server $env:COMPUTERNAME
    if ($rep) { Write-CliLog "Ablauf-Report: $rep" 'OK' }
}
