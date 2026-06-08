#Requires -Version 5.1
<#
.SYNOPSIS
    Config.psm1 - INI-Parser, Domaenenerkennung, Konfigurationsobjekt
.DESCRIPTION
    Liest settings.ini, erkennt die aktuelle AD-Domaene und baut ein
    typisiertes Konfigurationsobjekt auf das von allen anderen Modulen
    und der GUI verwendet wird.

    Neu ab April 2025:
    - Collation-Liste wird aus Config\collations.txt gelesen (eine pro Zeile).
      Standard-Collation und Domaenen-Overrides bleiben in settings.ini.
    - dbaTools-Pfade (ShareBasePath, ModulePath, LibraryPath, ManifestPath)
      werden automatisch aus dem einzigen INI-Schluessel ShareBasePath abgeleitet.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Hilfsfunktion: einfacher INI-Parser
# ---------------------------------------------------------------------------
function Read-IniFile {
    <#
    .SYNOPSIS
        Liest eine INI-Datei und gibt ein Hashtable [Sektion][Schluessel]=Wert zurueck.
    .NOTES
        - Kommentare beginnen mit # oder ;
        - Zeilen ohne = werden ignoriert
        - Werte werden getrimmt
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $ini = [ordered]@{}
    $currentSection = '__global__'
    $ini[$currentSection] = [ordered]@{}

    foreach ($line in (Get-Content $Path -Encoding UTF8)) {
        $line = $line.Trim()

        # Leerzeilen und Kommentare ueberspringen
        if ($line -eq '' -or $line -match '^[#;]') { continue }

        # Sektions-Header
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1].Trim()
            if (-not $ini.Contains($currentSection)) {
                $ini[$currentSection] = [ordered]@{}
            }
            continue
        }

        # Schluessel=Wert
        if ($line -match '^([^=]+)=(.*)$') {
            $key   = $matches[1].Trim()
            $value = $matches[2].Trim()
            $ini[$currentSection][$key] = $value
        }
        # Zeilen ohne = werden ignoriert (kein Fehler)
    }

    return $ini
}

# ---------------------------------------------------------------------------
# Domaenenerkennung
# ---------------------------------------------------------------------------
function Get-CurrentDomain {
    <#
    .SYNOPSIS
        Liest den NetBIOS-Domaenennamen des aktuellen Computers (Grossbuchstaben).
    .NOTES
        Gibt $null zurueck wenn der Computer keiner Domaene angehoert.
    #>
    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain) {
            return $cs.Domain.ToUpper().Split('.')[0]   # NetBIOS-Name = erster Teil
        }
    }
    catch {
        Write-Warning "Domaenenerkennung fehlgeschlagen: $_"
    }
    return $null
}

# ---------------------------------------------------------------------------
# Collation-Liste einlesen
# ---------------------------------------------------------------------------
function Get-CollationList {
    <#
    .SYNOPSIS
        Liest die Collation-Auswahlliste aus Config\collations.txt.
    .DESCRIPTION
        - Leerzeilen und Zeilen die mit # beginnen werden ignoriert.
        - Ist die Datei nicht vorhanden oder leer, wird nur die DefaultCollation zurueckgegeben.
        - Ist DomainCollation angegeben, wird diese an die erste Position gestellt;
          ein eventuell vorhandenes Duplikat in der Liste wird entfernt.
    .PARAMETER ConfigDir
        Verzeichnis in dem collations.txt liegt (i.d.R. Config\).
    .PARAMETER DefaultCollation
        Fallback-Sortierung aus settings.ini ([Collations] Standard=).
    .PARAMETER DomainCollation
        Domaenenspezifische Vorgabe aus settings.ini ([Collations] Domain_<NAME>=).
        Kann leer oder $null sein.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$DefaultCollation,
        [string]$DomainCollation
    )

    $collationFile = Join-Path $ConfigDir 'collations.txt'

    if (-not (Test-Path $collationFile)) {
        Write-Warning "collations.txt nicht gefunden: $collationFile - verwende nur Standardsortierung."
        return @($DefaultCollation)
    }

    $list = Get-Content $collationFile -Encoding UTF8 |
            Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
            ForEach-Object { $_.Trim() }

    if ($list.Count -eq 0) {
        Write-Warning "collations.txt ist leer - verwende nur Standardsortierung."
        return @($DefaultCollation)
    }

    # Domaenen-Collation an erste Stelle, Duplikate entfernen
    if ($DomainCollation -and $DomainCollation -ne '') {
        $list = @($DomainCollation) + ($list | Where-Object { $_ -ne $DomainCollation })
    }

    return $list
}

# ---------------------------------------------------------------------------
# dbaTools-Konfigurationsobjekt aus ShareBasePath ableiten
# ---------------------------------------------------------------------------
function Get-DbaToolsConfig {
    <#
    .SYNOPSIS
        Leitet alle dbaTools-Pfade aus dem konfigurierten ShareBasePath ab.
    .DESCRIPTION
        Erwartet unterhalb von ShareBasePath zwei Verzeichnisse:
            <ShareBasePath>\dbatools           - Hauptmodul
            <ShareBasePath>\dbatools.library   - Bibliothek (dbaTools >= 2.x)

        Zielverzeichnis beim Kopieren auf den lokalen Rechner:
            C:\Program Files\WindowsPowerShell\Modules\
    .PARAMETER IniSection
        Der [dbaTools]-Abschnitt als Hashtable.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$IniSection
    )

    $shareBase  = $IniSection['ShareBasePath']
    $moduleName = if ($IniSection['ModuleName']) { $IniSection['ModuleName'] } else { 'dbatools' }

    # Kein Pfad konfiguriert -> Fallback auf Gallery
    if (-not $shareBase -or $shareBase -eq '') {
        Write-Verbose 'dbaTools: kein ShareBasePath konfiguriert.'
        return $null
    }

    # Share-Laufwerk / UNC-Pfad erreichbar pruefen.
    # try/catch verhindert terminating error bei nicht vorhandenem Laufwerk (z.B. W:)
    $shareReachable = $false
    try   { $shareReachable = (Test-Path -Path $shareBase -ErrorAction Stop) }
    catch { Write-Warning "dbaTools-Share nicht erreichbar ('$shareBase'): $_" }

    if (-not $shareReachable) {
        Write-Warning "dbaTools-Share nicht erreichbar: '$shareBase' - verwende lokale Installation oder Gallery."
        return $null
    }

    # Share erreichbar -> Pfadobjekt aufbauen
    return [PSCustomObject]@{
        ShareBasePath  = $shareBase
        ModulePath     = Join-Path $shareBase $moduleName
        LibraryPath    = Join-Path $shareBase "$moduleName.library"
        ManifestPath   = Join-Path $shareBase "$moduleName\$moduleName.psd1"
        ModuleName     = $moduleName
        LocalTargetDir = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
    }
}

# ---------------------------------------------------------------------------
# sqmSQLTool-Konfigurationsobjekt aus ShareBasePath ableiten
# ---------------------------------------------------------------------------
function Get-sqmSQLToolConfig {
    <#
    .SYNOPSIS
        Leitet sqmSQLTool-Pfade aus dem konfigurierten ShareBasePath ab.
    .DESCRIPTION
        Erwartet unterhalb von ShareBasePath das Verzeichnis:
            <ShareBasePath>\sqmSQLTool\sqmSQLTool.psd1
        Zielverzeichnis beim Kopieren auf den lokalen Rechner:
            C:\Program Files\WindowsPowerShell\Modules\
    .PARAMETER IniSection
        Der [sqmSQLTool]-Abschnitt als Hashtable.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$IniSection
    )

    $shareBase  = $IniSection['ShareBasePath']
    $moduleName = if ($IniSection['ModuleName']) { $IniSection['ModuleName'] } else { 'sqmSQLTool' }

    if (-not $shareBase -or $shareBase -eq '') {
        Write-Verbose 'sqmSQLTool: kein ShareBasePath konfiguriert.'
        return $null
    }

    $shareReachable = $false
    try   { $shareReachable = (Test-Path -Path $shareBase -ErrorAction Stop) }
    catch { Write-Warning "sqmSQLTool-Share nicht erreichbar ('$shareBase'): $_" }

    if (-not $shareReachable) {
        Write-Warning "sqmSQLTool-Share nicht erreichbar: '$shareBase' - verwende lokale Installation."
        return $null
    }

    return [PSCustomObject]@{
        ShareBasePath  = $shareBase
        ModulePath     = Join-Path $shareBase $moduleName
        ManifestPath   = Join-Path $shareBase "$moduleName\$moduleName.psd1"
        ModuleName     = $moduleName
        LocalTargetDir = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
    }
}

# ---------------------------------------------------------------------------
# Domain-Profil laden (Config\domains\<DOMAIN>.ini oder DEFAULT.ini)
# ---------------------------------------------------------------------------
function Get-DomainProfile {
    <#
    .SYNOPSIS
        Laedt das Domain-Profil fuer die angegebene Domain.
    .DESCRIPTION
        Sucht in Config\domains\ zuerst nach <DOMAIN>.ini, dann nach DEFAULT.ini.
        Gibt $null zurueck wenn weder Domain-Profil noch DEFAULT.ini vorhanden.
    .PARAMETER ConfigDir
        Verzeichnis in dem der domains-Unterordner liegt (i.d.R. Config\).
    .PARAMETER Domain
        NetBIOS-Domainname (Grossbuchstaben). Kann $null sein.
    .OUTPUTS
        PSCustomObject mit DisplayName, Collation, SysadminGroups, MonitoringType,
        DiskLayout (Hashtable), SQLSourcesPath. Fehlende Felder sind leer/null.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$Domain
    )

    $domainsDir = Join-Path $ConfigDir 'domains'
    $profileIni = $null

    # 1. Domain-spezifisches Profil suchen
    if ($Domain -and $Domain -ne '') {
        $domPath = Join-Path $domainsDir "$Domain.ini"
        if (Test-Path $domPath) {
            $profileIni = Read-IniFile -Path $domPath
            Write-Verbose "DomainProfile: Profil geladen fuer Domain '$Domain': $domPath"
        }
    }

    # 2. Fallback auf DEFAULT.ini
    if ($null -eq $profileIni) {
        $defPath = Join-Path $domainsDir 'DEFAULT.ini'
        if (Test-Path $defPath) {
            $profileIni = Read-IniFile -Path $defPath
            Write-Verbose "DomainProfile: DEFAULT.ini geladen: $defPath"
        }
    }

    # 3. domains-Ordner nicht vorhanden oder leer -> $null
    if ($null -eq $profileIni) {
        Write-Verbose "DomainProfile: Kein Profil gefunden - verwende settings.ini-Werte."
        return $null
    }

    # Helper: sicherer Zugriff auf INI-Wert
    function _PVal { param($s, $k, $d = '')
        if ($profileIni.Contains($s) -and $profileIni[$s].Contains($k)) {
            return $profileIni[$s][$k]
        }
        return $d
    }

    # DiskLayout als Hashtable aufbauen
    $diskLayout = $null
    if ($profileIni.Contains('DiskLayout')) {
        $diskLayout = [ordered]@{}
        foreach ($key in $profileIni['DiskLayout'].Keys) {
            $diskLayout[$key] = $profileIni['DiskLayout'][$key]
        }
    }

    # SysadminGroups als Array
    $sysAdminGroups = @()
    $groupsRaw = _PVal 'SysadminGroups' 'Groups'
    if ($groupsRaw -and $groupsRaw.Trim() -ne '') {
        $sysAdminGroups = $groupsRaw -split ',' |
                          ForEach-Object { $_.Trim() } |
                          Where-Object { $_ -ne '' }
    }

    # MonitoringType als int
    $monType = 1
    $monRaw  = _PVal 'Monitoring' 'Type' '1'
    if ($monRaw -match '^\d+$') { $monType = [int]$monRaw }

    return [PSCustomObject]@{
        DisplayName    = _PVal 'Profile'    'DisplayName'
        Collation      = _PVal 'Collation'  'Default'
        SysadminGroups = $sysAdminGroups
        MonitoringType = $monType
        DiskLayout     = $diskLayout
        SQLSourcesPath = _PVal 'SQLSources' 'SourcePath'
    }
}

# ---------------------------------------------------------------------------
# Hauptfunktion: Konfigurationsobjekt aufbauen
# ---------------------------------------------------------------------------
function Get-SetupConfig {
    <#
    .SYNOPSIS
        Liest settings.ini und gibt ein vollstaendiges Konfigurationsobjekt zurueck.
    .PARAMETER IniPath
        Vollstaendiger Pfad zur settings.ini.
    #>
    param(
        [Parameter(Mandatory)][string]$IniPath
    )

    $ini           = Read-IniFile -Path $IniPath
    $configDir     = Split-Path $IniPath -Parent
    $domain        = Get-CurrentDomain
    $domainProfile = Get-DomainProfile -ConfigDir $configDir -Domain $domain

    # -- [General] -----------------------------------------------------------
    $general = $ini['General']

    # -- [Versions] ----------------------------------------------------------
    $versions = @()
    if ($ini.Contains('Versions') -and $ini['Versions']['Available']) {
        $versions = $ini['Versions']['Available'] -split ',' | ForEach-Object { $_.Trim() }
    }

    # -- [Editions] ----------------------------------------------------------
    $editionMap = [ordered]@{}
    if ($ini.Contains('Editions')) {
        foreach ($key in $ini['Editions'].Keys) {
            $editionMap[$key] = $ini['Editions'][$key] -split ',' | ForEach-Object { $_.Trim() }
        }
    }

    # -- [Collations] --------------------------------------------------------
    # Prioritaet: 1. Domain-Profil, 2. settings.ini Domain_*, 3. settings.ini Standard
    $stdCollation    = 'SQL_Latin1_General_CP1_CI_AS'
    if ($general['DefaultCollation']) { $stdCollation = $general['DefaultCollation'] }

    $domainCollation = $null

    if ($domainProfile -and $domainProfile.Collation -and $domainProfile.Collation -ne '') {
        # Domain-Profil hat Vorrang
        $domainCollation = $domainProfile.Collation
        $stdCollation    = $domainCollation
    }
    elseif ($domain -and $ini.Contains('Collations') -and $ini['Collations'].Contains("Domain_$domain")) {
        # Rueckwaertskompatibilitaet: Domain_* in settings.ini
        $domainCollation = $ini['Collations']["Domain_$domain"]
        $stdCollation    = $domainCollation
    }
    elseif ($ini.Contains('Collations') -and $ini['Collations']['Standard']) {
        $stdCollation = $ini['Collations']['Standard']
    }

    $collationDefaultFallback = 'SQL_Latin1_General_CP1_CI_AS'
    if ($ini.Contains('Collations') -and $ini['Collations']['Standard']) {
        $collationDefaultFallback = $ini['Collations']['Standard']
    }

    $collationList = Get-CollationList `
        -ConfigDir        $configDir `
        -DefaultCollation $collationDefaultFallback `
        -DomainCollation  $domainCollation

    # -- [SerialNumbers] -----------------------------------------------------
    $serialNumbers = [ordered]@{}
    if ($ini.Contains('SerialNumbers')) {
        foreach ($key in $ini['SerialNumbers'].Keys) {
            $serialNumbers[$key] = $ini['SerialNumbers'][$key]
        }
    }

    # -- [DiskLayout] --------------------------------------------------------
    # Prioritaet: 1. Domain-Profil, 2. settings.ini DiskLayout_<Domain>, 3. DiskLayout_Standard
    $diskSectionName = 'DiskLayout_Standard'
    if ($domain -and $ini.Contains("DiskLayout_$domain")) {
        $diskSectionName = "DiskLayout_$domain"
    }
    $diskLayout = $ini[$diskSectionName]

    if ($domainProfile -and $domainProfile.DiskLayout -and $domainProfile.DiskLayout.Count -gt 0) {
        $diskLayout      = $domainProfile.DiskLayout
        $diskSectionName = "DomainProfile:$domain"
    }

    # -- [Paths] -------------------------------------------------------------
    $paths = $ini['Paths']

    # -- [dbaTools] ----------------------------------------------------------
    $dbaSection = if ($ini.Contains('dbaTools')) { $ini['dbaTools'] } else { @{} }
    $dbaConfig  = Get-DbaToolsConfig -IniSection $dbaSection

    # -- [sqmSQLTool] --------------------------------------------------------
    $sqmSection = if ($ini.Contains('sqmSQLTool')) { $ini['sqmSQLTool'] } else { @{} }
    $sqmConfig  = Get-sqmSQLToolConfig -IniSection $sqmSection

    # -- [Maintenance] - Ola Hallengren lokaler Fallback ---------------------
    $olaSourcePath = ''
    if ($ini.Contains('Maintenance') -and $ini['Maintenance'].Contains('OlaSourcePath')) {
        $olaSourcePath = $ini['Maintenance']['OlaSourcePath'].Trim()
    }

    # -- [Monitoring] --------------------------------------------------------
    # Prioritaet: 1. Domain-Profil, 2. settings.ini Domain_*, 3. settings.ini DefaultType
    $monitoringEnabled = $true
    $monitoringDefault = 1
    $monitoringTypes   = @()
    if ($ini.Contains('Monitoring')) {
        $monitoringEnabled = ($ini['Monitoring']['Enabled'] -ne 'false')
        $rawDefault = if ($domain -and $ini['Monitoring'].Contains("Domain_$domain")) {
                          $ini['Monitoring']["Domain_$domain"]
                      } else {
                          $ini['Monitoring']['DefaultType']
                      }
        if ($rawDefault) { $monitoringDefault = [int]$rawDefault } else { $monitoringDefault = 1 }
        if ($ini['Monitoring']['Types']) {
            $monitoringTypes = $ini['Monitoring']['Types'] -split ',' | ForEach-Object { $_.Trim() }
        }
    }
    # Domain-Profil ueberschreibt Monitoring-Default
    if ($domainProfile -and $null -ne $domainProfile.MonitoringType) {
        $monitoringDefault = $domainProfile.MonitoringType
    }

    # -- [Installation] ----------------------------------------------------------
    $instSection = if ($ini.Contains('Installation')) { $ini['Installation'] } else { @{} }

    $instFeatures = @('Engine')
    if ($instSection.Contains('Features') -and $instSection['Features'].Trim() -ne '') {
        $instFeatures = $instSection['Features'] -split ',' |
                        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    $instSysAdmins = @('BUILTIN\Administrators')
    if ($instSection.Contains('SysAdminAccounts') -and $instSection['SysAdminAccounts'].Trim() -ne '') {
        $instSysAdmins = $instSection['SysAdminAccounts'] -split ',' |
                         ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    $instConfig = [PSCustomObject]@{
        Features            = $instFeatures
        InstantFileInit     = ($instSection['InstantFileInit'] -eq 'true')
        SysAdminAccounts    = $instSysAdmins
        TempDbFileCount     = if ($instSection['TempDbFileCount'])     { [int]$instSection['TempDbFileCount'] }     else { 2 }
        TempDbFileSizeMB    = if ($instSection['TempDbFileSizeMB'])    { [int]$instSection['TempDbFileSizeMB'] }    else { 1024 }
        TempDbFileGrowthMB  = if ($instSection['TempDbFileGrowthMB'])  { [int]$instSection['TempDbFileGrowthMB'] }  else { 512 }
        TempDbLogFileSizeMB = if ($instSection['TempDbLogFileSizeMB']) { [int]$instSection['TempDbLogFileSizeMB'] } else { 1024 }
        TempDbLogGrowthMB   = if ($instSection['TempDbLogGrowthMB'])   { [int]$instSection['TempDbLogGrowthMB'] }   else { 512 }
        TcpEnabled          = ($instSection['TcpEnabled']          -ne 'false')
        NpEnabled           = ($instSection['NpEnabled']           -eq 'true')
        BrowserSvcDisabled  = ($instSection['BrowserSvcDisabled']  -ne 'false')
    }

    # -- [PostInstall] -----------------------------------------------------------
    $splunkEnabled = $false
    if ($ini.Contains('PostInstall') -and $ini['PostInstall'].Contains('SplunkEnabled')) {
        $splunkEnabled = ($ini['PostInstall']['SplunkEnabled'].Trim() -eq 'true')
    }

    # Effektiver SourceShare: Domain-Profil SQLSourcesPath hat Vorrang vor globalem SourceShare.
    $effectiveSourceShare = $general['SourceShare']
    if ($domainProfile -and $domainProfile.SQLSourcesPath -and $domainProfile.SQLSourcesPath -ne '') {
        $effectiveSourceShare = $domainProfile.SQLSourcesPath
        Write-Verbose "SourceShare: Domain-spezifischer SQLSourcesPath verwendet: $effectiveSourceShare"
    }

    # SqlScriptsPath: explizit aus INI oder Fallback auf <effectiveSourceShare>\Scripts
    $sqlScriptsPath = ''
    if ($ini.Contains('PostInstall') -and $ini['PostInstall'].Contains('SqlScriptsPath')) {
        $sqlScriptsPath = $ini['PostInstall']['SqlScriptsPath'].Trim()
    }
    if ($sqlScriptsPath -eq '' -and $effectiveSourceShare) {
        $sqlScriptsPath = Join-Path $effectiveSourceShare 'Scripts'
    }

    # -- [SysadminGroups] --------------------------------------------------------
    # Prioritaet: 1. Domain-Profil, 2. settings.ini Domain_*, 3. settings.ini Standard
    $sysadminGroups = @()
    if ($domainProfile -and $domainProfile.SysadminGroups -and $domainProfile.SysadminGroups.Count -gt 0) {
        $sysadminGroups = $domainProfile.SysadminGroups
    }
    elseif ($ini.Contains('SysadminGroups')) {
        $sgSection = $ini['SysadminGroups']
        $sgKey = $null
        if ($domain -and $sgSection.Contains("Domain_$domain")) {
            $sgKey = "Domain_$domain"
        }
        elseif ($sgSection.Contains('Standard')) {
            $sgKey = 'Standard'
        }
        if ($sgKey) {
            $raw = $sgSection[$sgKey]
            if ($raw -and $raw.Trim() -ne '') {
                $sysadminGroups = $raw -split ',' |
                                  ForEach-Object { $_.Trim() } |
                                  Where-Object { $_ -ne '' }
            }
        }
    }

    # -- [OptionalComponents] ------------------------------------------------
    $optComp = [ordered]@{}
    if ($ini.Contains('OptionalComponents')) {
        foreach ($key in $ini['OptionalComponents'].Keys) {
            $optComp[$key] = $ini['OptionalComponents'][$key]
        }
    }

    # -- [Drivers] -----------------------------------------------------------
    $drivers = [ordered]@{}
    if ($ini.Contains('Drivers')) {
        foreach ($key in $ini['Drivers'].Keys) {
            $drivers[$key] = $ini['Drivers'][$key]
        }
    }

    # -- [Ports] -------------------------------------------------------------
    $portsSection  = if ($ini.Contains('Ports')) { $ini['Ports'] } else { @{} }
    $cfgBasePort   = if ($portsSection['BasePort']       -and $portsSection['BasePort']       -match '^\d+$') { [int]$portsSection['BasePort'] }       else { 1433 }
    $cfgBrowserPort = if ($portsSection['BrowserPort']   -and $portsSection['BrowserPort']    -match '^\d+$') { [int]$portsSection['BrowserPort'] }     else { 1434 }
    $cfgPortIncrement = if ($portsSection['PortIncrement'] -and $portsSection['PortIncrement'] -match '^\d+$') { [int]$portsSection['PortIncrement'] }  else { 10 }

    # -- [Qualys] ------------------------------------------------------------
    $qualysEnabled        = $false
    $qualysMonitoringUser = ''
    if ($ini.Contains('Qualys')) {
        if ($ini['Qualys'].Contains('Enabled')) {
            $qualysEnabled = ($ini['Qualys']['Enabled'].Trim() -eq 'true')
        }
        if ($ini['Qualys'].Contains('MonitoringUser')) {
            $qualysMonitoringUser = $ini['Qualys']['MonitoringUser'].Trim()
        }
    }

    # -- [PreInstall] --------------------------------------------------------
    $preSection         = if ($ini.Contains('PreInstall')) { $ini['PreInstall'] } else { @{} }
    $cfgFormat64kCheck  = ($preSection['Format64kCheck']  -eq 'true')
    $cfgSnapshotEnabled = ($preSection['SnapshotEnabled'] -eq 'true')
    $cfgHpuCheck        = ($preSection['HpuCheck']        -eq 'true')

    # PS 5.1-kompatible Fallback-Werte
    $cfgVersion      = if ($general['DefaultVersion'])      { $general['DefaultVersion'] }      else { '2022' }
    $cfgEdition      = if ($general['DefaultEdition'])      { $general['DefaultEdition'] }      else { 'Developer' }
    $cfgInstanceName = if ($general['DefaultInstanceName']) { $general['DefaultInstanceName'] } else { 'MSSQLServer' }

    # -- Konfigurationsobjekt zusammenbauen ----------------------------------
    return [PSCustomObject]@{
        # Allgemein
        DefaultVersion      = $cfgVersion
        DefaultEdition      = $cfgEdition
        DefaultInstanceName = $cfgInstanceName
        DefaultCollation    = $stdCollation
        SourceShare         = $effectiveSourceShare

        # Listen fuer Comboboxen
        Versions            = $versions
        EditionMap          = $editionMap
        CollationList       = $collationList

        # Seriennummern
        SerialNumbers       = $serialNumbers

        # Laufwerke und Pfade
        DiskLayout          = $diskLayout
        Paths               = $paths
        ActiveDiskSection   = $diskSectionName

        # dbaTools
        DbaTools            = $dbaConfig

        # sqmSQLTool
        sqmSQLTool          = $sqmConfig

        # Maintenance
        OlaSourcePath       = $olaSourcePath

        # Installations-Parameter (aus [Installation])
        InstallationConfig  = $instConfig

        # PostInstall-Optionen
        SplunkEnabled         = $splunkEnabled
        SqlScriptsPath        = $sqlScriptsPath
        QualysEnabled         = $qualysEnabled
        QualysMonitoringUser  = $qualysMonitoringUser

        # Sysadmin-Gruppen (domänenspezifisch, fuer PostInstall)
        SysadminGroups      = $sysadminGroups

        # Monitoring
        MonitoringEnabled   = $monitoringEnabled
        MonitoringDefault   = $monitoringDefault
        MonitoringTypes     = $monitoringTypes

        # Optionale Komponenten
        OptionalComponents  = $optComp

        # Treiber-Installation (aus [Drivers])
        Drivers             = $drivers

        # TCP-Port-Konfiguration (aus [Ports])
        BasePort            = $cfgBasePort
        BrowserPort         = $cfgBrowserPort
        PortIncrement       = $cfgPortIncrement

        # PreInstall-Pruefungen (aus [PreInstall])
        Format64kCheck      = $cfgFormat64kCheck
        SnapshotEnabled     = $cfgSnapshotEnabled
        HpuCheck            = $cfgHpuCheck

        # PostInstall-Skript (wird in Main.ps1 in absoluten Pfad aufgeloest)
        PostInstallScript   = 'Scripts\PostInstall.ps1'

        # Metadaten
        Domain              = $domain
        DomainProfile       = $domainProfile
        SQLSourcesPath      = if ($domainProfile) { $domainProfile.SQLSourcesPath } else { '' }
        ConfigDir           = $configDir
        IniPath             = $IniPath
    }
}

Export-ModuleMember -Function Get-SetupConfig, Get-CurrentDomain, Get-CollationList, Get-DbaToolsConfig, Get-sqmSQLToolConfig, Get-DomainProfile


