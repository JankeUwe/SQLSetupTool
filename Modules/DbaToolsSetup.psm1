#Requires -Version 5.1
<#
.SYNOPSIS
    DbaToolsSetup.psm1 - dbaTools laden und auf lokalem System bereitstellen
.DESCRIPTION
    Assert-DbaToolsReady stellt sicher dass dbaTools im aktuellen PowerShell-
    Runspace verfuegbar ist. Die Pruefung erfolgt in dieser Prioritaet:

    1. Bereits im aktuellen Runspace geladen            -> fertig
    2. Lokal installiert (Get-Module -ListAvailable)    -> importieren
    3. Share erreichbar                                 -> beide Verzeichnisse
       (dbatools + dbatools.library) nach
       C:\Program Files\WindowsPowerShell\Modules\ kopieren und importieren
    4. Fallback: Install-Module aus PowerShell Gallery  -> erfordert Internet
       oder internen NuGet-Feed

    Neu ab April 2025:
    - ShareBasePath ersetzt SharePath; dbatools und dbatools.library werden
      automatisch als Unterordner abgeleitet.
    - dbatools.library wird vor dem Import temporaer in PSModulePath eingetragen
      damit dbatools.psd1 die Abhaengigkeit aufloesen kann.
    - Beide Verzeichnisse werden per Copy-Item in den lokalen Modulpfad kopiert
      sofern sie dort noch nicht vorhanden sind.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DbaToolsReady {
    <#
    .SYNOPSIS
        Stellt sicher dass dbaTools im aktuellen Runspace geladen ist.
    .PARAMETER DbaToolsConfig
        PSCustomObject aus Get-DbaToolsConfig (Config.psm1).
        Enthaelt ShareBasePath, ModulePath, LibraryPath, ManifestPath,
        ModuleName und LocalTargetDir.
        Kann $null sein (kein Share konfiguriert -> direkt Gallery).
    #>
    param(
        [PSCustomObject]$DbaToolsConfig
    )

    # 1. Bereits im aktuellen Runspace geladen
    if (Get-Module -Name 'dbatools') {
        Write-Verbose "dbaTools bereits im Runspace geladen."
        return
    }

    # 2. Lokal installiert
    if (Get-Module -Name 'dbatools' -ListAvailable) {
        Write-Host "dbaTools lokal gefunden - importiere ..."
        Import-Module dbatools -ErrorAction Stop
        Write-Verbose "dbaTools aus lokalem Modulpfad geladen."
        return
    }

    # 3. Share
    if ($null -ne $DbaToolsConfig -and (Test-Path $DbaToolsConfig.ManifestPath)) {

        Write-Host "dbaTools vom Share laden: $($DbaToolsConfig.ShareBasePath)"

        # dbatools.library muss VOR dem Import des Hauptmoduls bekannt sein.
        # Dazu den uebergeordneten Ordner temporaer in PSModulePath eintragen.
        $libParent = Split-Path $DbaToolsConfig.LibraryPath -Parent
        if ($env:PSModulePath -notlike "*$libParent*") {
            $env:PSModulePath = $libParent + ';' + $env:PSModulePath
        }

        # Beide Verzeichnisse in den lokalen WindowsPowerShell-Modulpfad kopieren
        foreach ($folder in @($DbaToolsConfig.ModuleName, "$($DbaToolsConfig.ModuleName).library")) {
            $src = Join-Path $DbaToolsConfig.ShareBasePath $folder
            $dst = Join-Path $DbaToolsConfig.LocalTargetDir $folder

            if (-not (Test-Path $dst)) {
                Write-Host "  Kopiere $folder -> $dst ..."
                Copy-Item -Path $src -Destination $dst -Recurse -Force -ErrorAction Stop
            }
            else {
                Write-Verbose "  $folder bereits lokal vorhanden: $dst"
            }
        }

        # Modul laden
        Import-Module $DbaToolsConfig.ManifestPath -ErrorAction Stop
        Write-Verbose "dbaTools geladen: $($DbaToolsConfig.ManifestPath)"
        return
    }

    # 4. Fallback: PowerShell Gallery
    Write-Warning 'dbaTools weder lokal noch auf dem Share gefunden - versuche PowerShell Gallery ...'

    try {
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                    -Force -Scope AllUsers -ErrorAction SilentlyContinue

        Install-Module dbatools -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module dbatools -ErrorAction Stop
        Write-Verbose 'dbaTools aus Gallery installiert und geladen.'
        return
    }
    catch {
        Write-Warning "Gallery-Installation fehlgeschlagen: $_"
    }

    # Letzter Versuch: vielleicht wurde dbaTools inzwischen doch irgendwo gefunden
    if (Get-Module -Name 'dbatools' -ListAvailable) {
        Import-Module dbatools -ErrorAction Stop
        return
    }

    # Nichts hat funktioniert -> klare Fehlermeldung, kein stiller Abbruch
    throw ('dbaTools konnte nicht geladen werden. ' +
           'Bitte dbaTools manuell installieren oder ShareBasePath in settings.ini konfigurieren.')
}

function Assert-sqmSQLToolReady {
    <#
    .SYNOPSIS
        Stellt sicher dass sqmSQLTool im aktuellen Runspace geladen ist.
    .DESCRIPTION
        Pruefung in dieser Prioritaet:
        1. Bereits im Runspace geladen              -> fertig
        2. Lokal installiert UND Share erreichbar   -> Versions-Vergleich
           - Lokal aktuell                          -> importieren
           - Share neuer oder nicht lokal           -> kopieren + importieren
        3. Kein Share - lokal installiert           -> importieren
        4. Nichts gefunden                          -> Fehler

        Quellpfad:  <ShareBasePath>\sqmSQLTool\
        Zielpfad:   C:\Program Files\WindowsPowerShell\Modules\sqmSQLTool\
    .PARAMETER sqmSQLToolConfig
        PSCustomObject aus Get-sqmSQLToolConfig (Config.psm1).
        Kann $null sein wenn Share nicht konfiguriert oder nicht erreichbar.
    #>
    param(
        [PSCustomObject]$sqmSQLToolConfig
    )

    $moduleName = 'sqmSQLTool'

    # 1. Bereits im aktuellen Runspace geladen
    if (Get-Module -Name $moduleName) {
        Write-Verbose "sqmSQLTool bereits im Runspace geladen."
        return
    }

    # Lokal installiert? (einmalig ermitteln, wird in mehreren Pfaden benoetigt)
    $localModule = Get-Module -Name $moduleName -ListAvailable |
                   Sort-Object Version -Descending |
                   Select-Object -First 1

    # 2. Share erreichbar und Manifest vorhanden?
    if ($null -ne $sqmSQLToolConfig -and (Test-Path $sqmSQLToolConfig.ManifestPath)) {

        $shareData    = Import-PowerShellDataFile $sqmSQLToolConfig.ManifestPath
        $shareVersion = [version]$shareData.ModuleVersion

        $needsCopy = $true

        if ($null -ne $localModule) {
            $localVersion = [version]$localModule.Version
            if ($localVersion -ge $shareVersion) {
                Write-Host "sqmSQLTool v$localVersion lokal aktuell - importiere..."
                $needsCopy = $false
            }
            else {
                Write-Host "sqmSQLTool Update: lokal v$localVersion -> Share v$shareVersion"
            }
        }
        else {
            Write-Host "sqmSQLTool nicht installiert - kopiere v$shareVersion vom Share..."
        }

        if ($needsCopy) {
            $dstFolder = Join-Path $sqmSQLToolConfig.LocalTargetDir $moduleName
            # Alte Version entfernen damit Copy-Item nicht in Unterordner kopiert
            if (Test-Path $dstFolder) {
                Remove-Item $dstFolder -Recurse -Force -ErrorAction Stop
            }
            # In den Modulpfad kopieren (erzeugt Modules\sqmSQLTool\)
            Copy-Item -Path $sqmSQLToolConfig.ModulePath `
                      -Destination $sqmSQLToolConfig.LocalTargetDir `
                      -Recurse -Force -ErrorAction Stop
            Write-Host "  OK: sqmSQLTool v$shareVersion nach $dstFolder kopiert"
        }

        Import-Module $moduleName -Force -ErrorAction Stop
        Write-Host "  OK: sqmSQLTool geladen"
        return
    }

    # 3. Kein Share konfiguriert oder nicht erreichbar - lokal installiert?
    if ($null -ne $localModule) {
        Write-Host "sqmSQLTool lokal gefunden (kein Share) - importiere..."
        Import-Module $moduleName -ErrorAction Stop
        return
    }

    # 4. Nichts gefunden -> klare Fehlermeldung
    throw ('sqmSQLTool konnte nicht geladen werden. ' +
           'Bitte sqmSQLTool installieren oder ShareBasePath in settings.ini [sqmSQLTool] konfigurieren.')
}

Export-ModuleMember -Function Assert-DbaToolsReady, Assert-sqmSQLToolReady

