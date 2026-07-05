#Requires -Version 5.1
<#
.SYNOPSIS
    DiskLayout.psm1 - SQL-Pfade aus Laufwerksbuchstaben + SubPaths aufbauen
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SqlPaths {
    <#
    .SYNOPSIS
        Berechnet alle SQL Server-Pfade aus Laufwerksbuchstaben und Unterverzeichnissen.
    .DESCRIPTION
        Kombiniert die Laufwerksbuchstaben aus [DiskLayout_*] mit den Unterverzeichnissen
        aus [Paths] und dem Instanz-Suffix.

        InstSuffix:
            Standardinstanz (MSSQLServer) -> MSSQLSERVER
            Benannte Instanz              -> MSSQL$<Instanzname>

        Ergebnis-Pfade:
            Install : <InstallDrive>:\<InstallSubPath>
            Data    : <DataDrive>:\<DataSubPath>\<InstSuffix>\DATA
            Log     : <LogDrive>:\<LogSubPath>\<InstSuffix>\LOG
            TempDB  : <TempDrive>:\<TempSubPath>\<InstSuffix>\DATA  (Dateien)
            TempLog : <TempDrive>:\<TempSubPath>\<InstSuffix>\LOG
            Backup  : <BackupDrive>:\<BackupSubPath>\<InstSuffix>
    .PARAMETER DiskLayout
        Hashtable mit DataDrive, LogDrive, TempDrive, BackupDrive, InstallDrive.
    .PARAMETER Paths
        Hashtable mit DataSubPath, LogSubPath, TempSubPath, BackupSubPath, InstallSubPath.
    .PARAMETER InstanceName
        Name der SQL-Instanz (leer oder 'MSSQLServer' = Standardinstanz).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$DiskLayout,
        [Parameter(Mandatory)][hashtable]$Paths,
        [string]$InstanceName = 'MSSQLServer'
    )

    # Instanz-Suffix bestimmen
    $instSuffix = if ($InstanceName -eq '' -or $InstanceName -eq 'MSSQLServer') {
        'MSSQLSERVER'
    } else {
        "MSSQL`$$InstanceName"
    }

    # Build the path by string concatenation, NOT Join-Path: Join-Path resolves the
    # drive qualifier and throws DriveNotFoundException when the target drive is not
    # present yet (e.g. a -WhatIf dry run, or disks attached only on the real server).
    function p([string]$drive, [string]$sub, [string]$leaf) {
        return "$($drive):\$sub\$instSuffix\$leaf"
    }

    # SysDb-Pfad (INSTALLSQLDATADIR): BackupDrive + SysDbSubPath
    # Fallback wenn SysDbSubPath fehlt: BackupDrive:\Microsoft SQL Server
    $sysDbSub = if ($Paths['SysDbSubPath']) { $Paths['SysDbSubPath'] } else { 'Microsoft SQL Server' }

    return [PSCustomObject]@{
        Install    = "$($DiskLayout['InstallDrive']):\$($Paths['InstallSubPath'])"
        SysDb      = "$($DiskLayout['BackupDrive']):\$sysDbSub"
        Data       = p $DiskLayout['DataDrive']   $Paths['DataSubPath']   'DATA'
        Log        = p $DiskLayout['LogDrive']    $Paths['LogSubPath']    'LOG'
        TempDB     = p $DiskLayout['TempDrive']   $Paths['TempSubPath']   'DATA'
        TempLog    = p $DiskLayout['TempDrive']   $Paths['TempSubPath']   'LOG'
        Backup     = "$($DiskLayout['BackupDrive']):\$($Paths['BackupSubPath'])\$instSuffix"
        InstSuffix = $instSuffix
    }
}

function New-SqlDirectories {
    <#
    .SYNOPSIS
        Erstellt alle SQL-Verzeichnisse auf dem Zielsystem.
    .PARAMETER SqlPaths
        PSCustomObject aus Get-SqlPaths.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$SqlPaths
    )

    $dirs = @(
        $SqlPaths.Data,
        $SqlPaths.Log,
        $SqlPaths.TempDB,
        $SqlPaths.TempLog,
        $SqlPaths.Backup
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($dir in $dirs) {
        if (Test-Path $dir) {
            $results.Add([PSCustomObject]@{ Pfad = $dir; Status = 'Vorhanden' })
        }
        else {
            try {
                $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
                $results.Add([PSCustomObject]@{ Pfad = $dir; Status = 'Erstellt' })
            }
            catch {
                $results.Add([PSCustomObject]@{ Pfad = $dir; Status = "FEHLER: $_" })
            }
        }
    }
    return $results
}

function Format-DiskLayoutSummary {
    <#
    .SYNOPSIS
        Gibt eine lesbare Zusammenfassung aller SQL-Pfade zurueck.
    .PARAMETER SqlPaths
        PSCustomObject aus Get-SqlPaths.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$SqlPaths
    )

    $lines = @(
        '--- Pfad-Konfiguration ---',
        "  Install (Binaerdateien) : $($SqlPaths.Install)",
        "  SysDb  (master/model)   : $($SqlPaths.SysDb)",
        "  Data   (Benutzerdaten)  : $($SqlPaths.Data)",
        "  Log    (Transaktionslog): $($SqlPaths.Log)",
        "  TempDB (Datendateien)   : $($SqlPaths.TempDB)",
        "  TempLog(Logdatei)       : $($SqlPaths.TempLog)",
        "  Backup                  : $($SqlPaths.Backup)",
        '--------------------------'
    )
    return $lines -join "`n"
}

function Get-SqlConnectionInstance {
    <#
    .SYNOPSIS
        Baut aus einem (blossen) Instanznamen den fuer dbatools/sqmSQLTool
        -SqlInstance-Parameter noetigen Verbindungsstring.
    .DESCRIPTION
        settings.ini/GUI/Get-SqlPaths verwenden durchgehend blosse Instanznamen
        (z.B. 'MSSQLServer' fuer die Standardinstanz oder 'INST01' fuer eine
        benannte Instanz) - praktisch fuer Pfad-/Namensbildung, aber KEIN
        gueltiges Ziel fuer dbatools/sqmSQLTool: deren -SqlInstance-Parameter wird
        immer als Netzwerkziel aufgeloest (Resolve-DbaNetworkName). Ein blosser
        Instanzname wie 'MSSQLServer' ist kein Hostname und schlaegt dort mit
        "DNS name ... not found" fehl.

        Diese Funktion liefert stattdessen:
          - '<Computer>'            fuer die Standardinstanz (leer / MSSQLSERVER / MSSQLServer)
          - '<Computer>\<Instanz>'  fuer benannte Instanzen
        Ist der Eingabewert bereits qualifiziert (enthaelt '\'), wird er unveraendert
        zurueckgegeben.
    .PARAMETER InstanceName
        Blosser Instanzname oder bereits vollstaendig qualifiziert ('SERVER\INST01').
    .PARAMETER ComputerName
        Zielcomputer. Standard: lokaler Rechner ($env:COMPUTERNAME).
    #>
    param(
        [string]$InstanceName,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    if ($InstanceName -match '\\') {
        return $InstanceName
    }
    if ([string]::IsNullOrWhiteSpace($InstanceName) -or $InstanceName -eq 'MSSQLSERVER' -or $InstanceName -eq 'MSSQLServer') {
        return $ComputerName
    }
    return "$ComputerName\$InstanceName"
}

Export-ModuleMember -Function Get-SqlPaths, New-SqlDirectories, Format-DiskLayoutSummary, Get-SqlConnectionInstance
