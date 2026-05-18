#Requires -Version 5.1
<#
.SYNOPSIS
    Installation.psm1 - SQL Server Installation, SSRS, SSAS, SSMS, TDP
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SqlInstallation {
    <#
    .SYNOPSIS
        Fuehrt die SQL Server Installation per Install-DbaInstance (dbaTools) durch.
    .PARAMETER SqlPaths
        PSCustomObject aus Get-SqlPaths.
    .PARAMETER Version
        SQL-Version (z.B. 2022).
    .PARAMETER Edition
        SQL-Edition (z.B. Developer).
    .PARAMETER InstanceName
        Instanzname.
    .PARAMETER Collation
        Datenbanksortierung.
    .PARAMETER ProductKey
        Lizenzschluessel - leer bei Developer.
    .PARAMETER ServiceCredential
        PSCredential fuer SQL-Dienstkonto - $null fuer NT SERVICE\MSSQLSERVER.
    .PARAMETER InstallDrive
        Laufwerksbuchstabe auf dem die Installationsmedien liegen.
    .PARAMETER InstallConfig
        PSCustomObject aus Config.psm1 [Installation]-Sektion.
        Enthaelt Features, InstantFileInit, SysAdminAccounts, TempDB-Einstellungen usw.
    .PARAMETER LogCallback
        Optionaler ScriptBlock fuer GUI-Logging.
    .NOTES
        Quellpfad-Konvention: $InstallDrive:\SQLSources\SQL$Version\SQL_Install
        Updates:              $InstallDrive:\SQLSources\SQL$Version\SQL_Install\Updates
        Der Updates-Ordner wird automatisch als UpdateSourcePath uebergeben wenn er existiert.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$SqlPaths,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)][string]$InstanceName,
        [Parameter(Mandatory)][string]$Collation,
        [string]$ProductKey,
        [System.Management.Automation.PSCredential]$ServiceCredential,
        [Parameter(Mandatory)][string]$InstallDrive,
        [PSCustomObject]$InstallConfig,
        [ScriptBlock]$LogCallback
    )

    # Versions-spezifischer Quellpfad
    $sourcePath = "$($InstallDrive):\SQLSources\SQL$Version\SQL_Install"
    $updatePath = Join-Path $sourcePath 'Updates'

    # InstallConfig-Defaults wenn nicht uebergeben
    $features        = if ($InstallConfig -and $InstallConfig.Features)         { $InstallConfig.Features }         else { @('Engine') }
    $ifi             = if ($InstallConfig)                                        { $InstallConfig.InstantFileInit }  else { $true }
    $sysAdmins       = if ($InstallConfig -and $InstallConfig.SysAdminAccounts)  { $InstallConfig.SysAdminAccounts } else { @('BUILTIN\Administrators') }
    $tmpFileCount    = if ($InstallConfig)                                        { $InstallConfig.TempDbFileCount }     else { 2 }
    $tmpFileSize     = if ($InstallConfig)                                        { $InstallConfig.TempDbFileSizeMB }    else { 1024 }
    $tmpFileGrowth   = if ($InstallConfig)                                        { $InstallConfig.TempDbFileGrowthMB }  else { 512 }
    $tmpLogSize      = if ($InstallConfig)                                        { $InstallConfig.TempDbLogFileSizeMB } else { 1024 }
    $tmpLogGrowth    = if ($InstallConfig)                                        { $InstallConfig.TempDbLogGrowthMB }   else { 512 }

    $params = @{
        SqlInstance                  = $InstanceName
        Version                      = $Version
        Feature                      = $features
        Path                         = $sourcePath
        InstallPath                  = $SqlPaths.Install
        SystemDbPath                 = $SqlPaths.SysDb
        DataPath                     = $SqlPaths.Data
        LogPath                      = $SqlPaths.Log
        TempPath                     = $SqlPaths.TempDB
        BackupPath                   = $SqlPaths.Backup
        Collation                    = $Collation
        AuthenticationMode           = 'Windows'
        AdminAccount                 = $sysAdmins
        PerformVolumeMaintenanceTasks = $ifi
        SqlTempdbFileCount           = $tmpFileCount
        SqlTempdbFileSize            = $tmpFileSize
        SqlTempdbFileGrowth          = $tmpFileGrowth
        SqlTempdbLogFileSize         = $tmpLogSize
        SqlTempdbLogFileGrowth       = $tmpLogGrowth
        Confirm                      = $false
    }

    # Updates-Ordner: aktueller Hotfix/KB/CU wird automatisch einbezogen
    if (Test-Path $updatePath) {
        $params['UpdateSourcePath'] = $updatePath
        if ($LogCallback) { & $LogCallback "  Updates-Ordner gefunden: $updatePath" }
    }

    # Seriennummer: nur bei Nicht-Developer-Editionen
    if ($ProductKey -and $ProductKey -ne '') {
        $params['ProductID'] = $ProductKey
    }

    # Dienstkonto: nur wenn explizit angegeben
    if ($null -ne $ServiceCredential) {
        $params['EngineCredential'] = $ServiceCredential
    }

    if ($LogCallback) { & $LogCallback "Starte Install-DbaInstance fuer SQL $Version $Edition ..." }
    if ($LogCallback) { & $LogCallback "  Quelle     : $sourcePath" }
    if ($LogCallback) { & $LogCallback "  SysDb-Pfad : $($SqlPaths.SysDb)" }
    if ($LogCallback) { & $LogCallback "  Features   : $($features -join ', ')" }
    if ($LogCallback) { & $LogCallback "  IFI        : $ifi | TempDB-Files: $tmpFileCount x ${tmpFileSize}MB" }

    Install-DbaInstance @params

    if ($LogCallback) { & $LogCallback "Install-DbaInstance abgeschlossen." }
}

function Install-SsrsComponent {
    <#
    .SYNOPSIS
        Installiert SQL Server Reporting Services (eigenstaendiger Installer).
        Delegiert an Install-sqmSsrsReportServer aus sqmSQLTool.
    .PARAMETER SourcePath
        Verzeichnis das SQLServerReportingServices.exe enthaelt.
        Konvention: $InstallDrive:\SQLSources\SQL$Version\Reporting
    .PARAMETER InstanceName
        Wird von der GUI uebergeben - nicht benoetigt (spaeterer Konfigurationsschritt).
    .PARAMETER LogCallback
        Optionaler ScriptBlock fuer GUI-Logging.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$InstanceName,
        [ScriptBlock]$LogCallback
    )

    $installer = Get-ChildItem -Path $SourcePath -Filter 'SQLServerReportingServices.exe' |
                 Select-Object -First 1

    if (-not $installer) {
        throw "SSRS-Installer nicht gefunden unter: $SourcePath"
    }

    if ($LogCallback) { & $LogCallback "Installiere SSRS: $($installer.FullName)" }

    # Delegation an sqmSQLTool
    Install-sqmSsrsReportServer -InstallerPath $installer.FullName

    if ($LogCallback) { & $LogCallback "SSRS erfolgreich installiert." }
}

function Install-SsasComponent {
    <#
    .SYNOPSIS
        Installiert SQL Server Analysis Services als SQL-Server-Feature (setup.exe /FEATURES=AS).
    .PARAMETER SourcePath
        Verzeichnis mit setup.exe (SQL_Install-Ordner der jeweiligen Version).
        Konvention: $InstallDrive:\SQLSources\SQL$Version\SQL_Install
    .PARAMETER InstanceName
        SQL-Server-Instanzname (MSSQLSERVER fuer Default-Instanz).
    .PARAMETER Collation
        SSAS-Sortierung (wird als /ASCOLLATION uebergeben).
    .PARAMETER LogCallback
        Optionaler ScriptBlock fuer GUI-Logging.
    .NOTES
        SSAS wird als Feature des SQL-Server-Setups installiert, nicht als eigener Installer.
        ExitCode 0: Erfolgreich. ExitCode 3010: Neustart empfohlen (wird als OK behandelt).
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$InstanceName,
        [string]$Collation = 'Latin1_General_CI_AS',
        [ScriptBlock]$LogCallback
    )

    $setupExe = Join-Path $SourcePath 'setup.exe'
    if (-not (Test-Path $setupExe)) {
        throw "SQL Server setup.exe nicht gefunden unter: $SourcePath"
    }

    # Instanzname fuer SSAS (Default-Instanz = MSSQLSERVER)
    $instName = $InstanceName
    if ($instName -match '\\') {
        # Benannte Instanz: SERVER\INST -> nur INST-Teil
        $instName = $instName.Split('\')[1]
    }

    $args = @(
        '/ACTION=Install',
        '/QUIET=True',
        '/IACCEPTSQLSERVERLICENSETERMS=True',
        "/INSTANCENAME=$instName",
        '/FEATURES=AS',
        "/ASCOLLATION=$Collation"
    )

    if ($LogCallback) { & $LogCallback "Installiere SSAS Feature: $setupExe" }
    if ($LogCallback) { & $LogCallback "  Instanz: $instName  Collation: $Collation" }

    $proc = Start-Process -FilePath $setupExe `
                          -ArgumentList $args `
                          -PassThru -Wait

    if ($proc.ExitCode -notin 0, 3010) {
        throw "SSAS-Installation fehlgeschlagen (ExitCode $($proc.ExitCode))"
    }

    if ($proc.ExitCode -eq 3010 -and $LogCallback) {
        & $LogCallback "SSAS installiert - Neustart empfohlen (ExitCode 3010)."
    }
    elseif ($LogCallback) {
        & $LogCallback "SSAS erfolgreich installiert."
    }
}

function Install-SsmsComponent {
    <#
    .SYNOPSIS
        Installiert SQL Server Management Studio (stiller Setup).
    .PARAMETER SourcePath
        Verzeichnis das SSMS-Setup-*.exe enthaelt.
        Konvention: $InstallDrive:\SQLSources\SQL$Version\Management
    .PARAMETER LogCallback
        Optionaler ScriptBlock fuer GUI-Logging.
    .NOTES
        ExitCode 3010: Erfolgreich installiert, Neustart empfohlen (bei SSMS haeufig).
        Neueste Datei (Sort Descending) wird gewaehlt falls mehrere vorliegen.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [ScriptBlock]$LogCallback
    )

    $installer = Get-ChildItem -Path $SourcePath -Filter 'SSMS-Setup-*.exe' |
                 Sort-Object Name -Descending |
                 Select-Object -First 1

    if (-not $installer) {
        throw "SSMS-Installer nicht gefunden unter: $SourcePath"
    }

    if ($LogCallback) { & $LogCallback "Installiere SSMS: $($installer.FullName)" }

    $proc = Start-Process -FilePath $installer.FullName `
                          -ArgumentList '/install /quiet /norestart' `
                          -PassThru -Wait

    if ($proc.ExitCode -notin 0, 3010) {
        throw "SSMS-Installation fehlgeschlagen (ExitCode $($proc.ExitCode))"
    }

    if ($proc.ExitCode -eq 3010 -and $LogCallback) {
        & $LogCallback "SSMS installiert - Neustart nach Abschluss empfohlen (ExitCode 3010)."
    }
    elseif ($LogCallback) {
        & $LogCallback "SSMS erfolgreich installiert."
    }
}

function Install-TdpComponent {
    <#
    .SYNOPSIS
        Installiert TDP/TSM-Client (Platzhalter - TDP_SourcePath in settings.ini setzen).
    .PARAMETER SourcePath
        Lokales Verzeichnis mit TDP-Installer (nach Copy-ComponentSource).
    .PARAMETER InstanceName
        SQL-Server-Instanzname.
    .PARAMETER LogCallback
        Optionaler ScriptBlock fuer GUI-Logging.
    #>
    param(
        [string]$SourcePath,
        [string]$InstanceName,
        [ScriptBlock]$LogCallback
    )

    if ($LogCallback) { & $LogCallback "TDP-Installation: Platzhalter - TDP_SourcePath in settings.ini konfigurieren." }
}

Export-ModuleMember -Function Invoke-SqlInstallation, Install-SsrsComponent, Install-SsasComponent, Install-SsmsComponent, Install-TdpComponent
