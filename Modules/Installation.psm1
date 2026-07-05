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

    # settings.ini [Installation] Features verwendet Kurzformen (siehe Kommentar dort:
    # "Gueltige Werte: Engine, FullText, Replication, IS, AS, RS, Tools, MDS"), aber
    # Install-DbaInstance (dbatools) erwartet die vollen Feature-Namen im -Feature-
    # ValidateSet (u.a. IntegrationServices, AnalysisServices, ReportingServices,
    # MasterDataServices). Ohne diese Abbildung schlaegt z.B. "IS" mit
    # ParameterArgumentValidationError fehl. Unbekannte Werte (z.B. bereits volle
    # dbatools-Namen) werden unveraendert durchgereicht - Install-DbaInstance validiert selbst.
    $featureShortNameMap = @{
        IS  = 'IntegrationServices'
        AS  = 'AnalysisServices'
        RS  = 'ReportingServices'
        MDS = 'MasterDataServices'
    }
    $features = @($features | ForEach-Object {
        if ($featureShortNameMap.ContainsKey($_)) { $featureShortNameMap[$_] } else { $_ }
    })
    $ifi             = if ($InstallConfig)                                        { $InstallConfig.InstantFileInit }  else { $true }
    $sysAdmins       = if ($InstallConfig -and $InstallConfig.SysAdminAccounts)  { $InstallConfig.SysAdminAccounts } else { @('BUILTIN\Administrators') }
    $tmpFileCount    = if ($InstallConfig)                                        { $InstallConfig.TempDbFileCount }     else { 2 }
    $tmpFileSize     = if ($InstallConfig)                                        { $InstallConfig.TempDbFileSizeMB }    else { 1024 }
    $tmpFileGrowth   = if ($InstallConfig)                                        { $InstallConfig.TempDbFileGrowthMB }  else { 512 }
    $tmpLogSize      = if ($InstallConfig)                                        { $InstallConfig.TempDbLogFileSizeMB } else { 1024 }
    $tmpLogGrowth    = if ($InstallConfig)                                        { $InstallConfig.TempDbLogGrowthMB }   else { 512 }

    # Install-DbaInstance (dbatools) kennt weder eigene TempDB-Datei-Parameter noch
    # SystemDbPath/Collation unter diesen Namen - das laeuft ueber -InstancePath,
    # -SqlCollation und die generische -Configuration-Hashtable (rohe setup.exe
    # Configuration.ini-Schluessel: INSTALLSQLDATADIR, SQLTEMPDBFILECOUNT, ...).
    # Frueherer Code nutzte erfundene Parameternamen (InstallPath, SystemDbPath,
    # Collation, SqlTempdbFileCount/...), die es in dieser dbatools-Version nicht
    # gibt -> NamedParameterNotFound / ParameterArgumentValidationError.
    $configuration = @{
        INSTALLSQLDATADIR       = $SqlPaths.SysDb
        SQLTEMPDBFILECOUNT      = $tmpFileCount
        SQLTEMPDBFILESIZE       = $tmpFileSize
        SQLTEMPDBFILEGROWTH     = $tmpFileGrowth
        SQLTEMPDBLOGFILESIZE    = $tmpLogSize
        SQLTEMPDBLOGFILEGROWTH  = $tmpLogGrowth
    }

    # -SqlInstance wird von Install-DbaInstance IMMER als Netzwerkziel aufgeloest
    # (Resolve-DbaNetworkName) - der blosse Instanzname (z.B. "MSSQLServer") ist dafuer
    # kein gueltiges Ziel und schlaegt mit "DNS name ... not found" fehl. Install-DbaInstance
    # hat dafuer bewusst zwei getrennte Parameter: -SqlInstance (Zielcomputer) und
    # -InstanceName (der eigentliche Instanzname) - beide zusammen ergeben das Ziel.
    $params = @{
        SqlInstance                  = $env:COMPUTERNAME
        InstanceName                 = $InstanceName
        Version                      = $Version
        Feature                      = $features
        Path                         = $sourcePath
        InstancePath                 = $SqlPaths.Install
        DataPath                     = $SqlPaths.Data
        LogPath                      = $SqlPaths.Log
        TempPath                     = $SqlPaths.TempDB
        BackupPath                   = $SqlPaths.Backup
        SqlCollation                 = $Collation
        AuthenticationMode           = 'Windows'
        AdminAccount                 = $sysAdmins
        PerformVolumeMaintenanceTasks = $ifi
        Configuration                = $configuration
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

    # Install-DbaInstance delegiert intern an die private Invoke-DbaAdvancedInstall, die bei einem
    # Fehlschlag Stop-Function aufruft. OHNE -EnableException ist das ein NICHT-terminierender
    # Fehler: Stop-Function schreibt eine Warnung und die Funktion kehrt zurueck, OHNE das
    # Ergebnisobjekt (Successful/ExitCode/Log/...) auszugeben - Install-DbaInstance liefert dann
    # schlicht GAR NICHTS ($null) statt eines Objekts mit Successful=$false. Der Aufrufer crasht in
    # diesem Fall mit einer nichtssagenden "Successful wurde nicht gefunden"-Exception auf $null,
    # obwohl der eigentliche Fehler (z.B. ungueltige setup.exe-Konfiguration) schon vorher geloggt
    # wurde. Mit -EnableException wird ein echter Fehlschlag stattdessen als PowerShell-Exception
    # geworfen, mit vollem dbatools-Kontext (ExitCode/Log-Auszug) in der Fehlermeldung.
    $params['EnableException'] = $true

    if ($LogCallback) { & $LogCallback "Starte Install-DbaInstance fuer SQL $Version $Edition ..." }
    if ($LogCallback) { & $LogCallback "  Quelle     : $sourcePath" }
    if ($LogCallback) { & $LogCallback "  SysDb-Pfad : $($SqlPaths.SysDb)" }
    if ($LogCallback) { & $LogCallback "  Features   : $($features -join ', ')" }
    if ($LogCallback) { & $LogCallback "  IFI        : $ifi | TempDB-Files: $tmpFileCount x ${tmpFileSize}MB" }

    $result = Install-DbaInstance @params

    if ($LogCallback) { & $LogCallback "Install-DbaInstance abgeschlossen." }

    # Sicherheitsnetz: sollte trotz -EnableException dennoch kein Objekt zurueckkommen, hier mit
    # einer klaren Meldung abbrechen statt den Aufrufer spaeter mit einer kryptischen
    # PropertyNotFoundException auf $installResult.Successful crashen zu lassen.
    if ($null -eq $result) {
        throw 'Install-DbaInstance hat kein Ergebnisobjekt zurueckgegeben. Installation vermutlich fehlgeschlagen - siehe vorherige Log-Zeilen.'
    }

    return $result
}

function Install-SsrsComponent {
    <#
    .SYNOPSIS
        Installiert und konfiguriert SQL Server Reporting Services.
        Delegiert an Install-sqmSsrsReportServer aus sqmSQLTool.
    .PARAMETER SourcePath
        Verzeichnis das SQLServerReportingServices*.exe enthaelt.
        Wildcard: SQLServerReportingServices_2022.exe u.ae. werden erkannt.
        Konvention: $InstallDrive:\SQLSources\SQL$Version\Reporting
    .PARAMETER InstanceName
        SQL-Server-Instanzname (MSSQLSERVER fuer Default-Instanz).
        Wird als DatabaseServer und InstanceName an Set-sqmSsrsConfiguration uebergeben.
    .PARAMETER Edition
        SSRS-Lizenzedition: Eval, Developer, Standard, Enterprise.
        Standard/Enterprise erfordern einen ProductKey.
    .PARAMETER ProductKey
        Lizenzschluessel (25 Zeichen). Ersetzt -Edition wenn angegeben.
        Muss zur installierten SQL-Server-Edition passen.
    .PARAMETER LogCallback
        Optionaler ScriptBlock fuer GUI-Logging.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$InstanceName  = 'MSSQLSERVER',
        [string]$Edition       = 'Developer',
        [string]$ProductKey    = '',
        [ScriptBlock]$LogCallback
    )

    # Wildcard-Suche: findet SQLServerReportingServices.exe UND SQLServerReportingServices_2022.exe usw.
    $installer = Get-ChildItem -Path $SourcePath -Filter 'SQLServerReportingServices*.exe' |
                 Sort-Object Name -Descending |
                 Select-Object -First 1

    if (-not $installer) {
        throw "SSRS-Installer nicht gefunden unter: $SourcePath (erwartet: SQLServerReportingServices*.exe)"
    }

    if ($LogCallback) { & $LogCallback "Installiere SSRS: $($installer.FullName)" }
    if ($LogCallback) { & $LogCallback "  Edition: $(if ($ProductKey) { 'Key gesetzt' } else { $Edition })  Instanz: $InstanceName" }

    # Parameter fuer Install-sqmSsrsReportServer aufbauen
    $ssrsParams = @{
        InstallerPath  = $installer.FullName
        InstanceName   = $InstanceName
        DatabaseServer = $env:COMPUTERNAME
    }

    if ($ProductKey -and $ProductKey -ne '') {
        $ssrsParams['ProductKey'] = $ProductKey
    } else {
        $ssrsParams['Edition'] = $Edition
    }

    # Installation + Konfiguration in einem Schritt (Install-sqmSsrsReportServer ruft Set-sqmSsrsConfiguration intern auf)
    Install-sqmSsrsReportServer @ssrsParams

    if ($LogCallback) { & $LogCallback "SSRS erfolgreich installiert und konfiguriert." }
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
