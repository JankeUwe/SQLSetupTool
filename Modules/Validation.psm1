#Requires -Version 5.1
<#
.SYNOPSIS
    Validation.psm1 - AD-Konto-/Passwortpruefung, Instanzname, Laufwerke
.NOTES
    ACHTUNG: Jeder fehlgeschlagene Pruefversuch erhoeht den AD-Lockout-Zaehler.
    Das Tool weist den Benutzer explizit darauf hin.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.DirectoryServices.AccountManagement

function Test-AdCredential {
    <#
    .SYNOPSIS
        Prueft AD-Anmeldedaten (exakt 1 Versuch - Lockout-sicher).
    .DESCRIPTION
        UPN-Normalisierung: user@domain.com wird zu DOMAIN\user umgeschrieben.
        Anschliessend ValidateCredentials ueber AccountManagement.
    .PARAMETER Credential
        PSCredential mit Benutzername und Passwort.
    .OUTPUTS
        [bool] - $true wenn Anmeldedaten korrekt.
    #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    $username = $Credential.UserName

    # UPN -> DOMAIN\user normalisieren
    if ($username -match '^(.+)@(.+)$') {
        $user   = $matches[1]
        $domain = $matches[2].Split('.')[0].ToUpper()
        $username = "$domain\$user"
    }

    $domainPart = ($username -split '\\')[0]
    $userPart   = ($username -split '\\')[-1]

    try {
        $ctx = [System.DirectoryServices.AccountManagement.PrincipalContext]::new(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain,
            $domainPart
        )
        $result = $ctx.ValidateCredentials($userPart, $Credential.GetNetworkCredential().Password)
        $ctx.Dispose()
        return $result
    }
    catch {
        Write-Warning "AD-Pruefung fehlgeschlagen: $_"
        return $false
    }
}

function Test-InstanceName {
    <#
    .SYNOPSIS
        Prueft ob ein Instanzname fuer SQL Server zulaessig ist.
    .DESCRIPTION
        Erlaubt: Buchstaben, Ziffern, Unterstrich. Laenge 1-16 Zeichen.
        'MSSQLServer' ist reserviert fuer die Standardinstanz.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][string]$InstanceName
    )

    if ($InstanceName -match '^[A-Za-z0-9_]{1,16}$') {
        return $true
    }
    return $false
}

function Test-DriveLetter {
    <#
    .SYNOPSIS
        Prueft ob ein Laufwerksbuchstabe auf dem System existiert und erreichbar ist.
    .OUTPUTS
        [bool]
    #>
    param(
        [Parameter(Mandatory)][string]$Letter
    )

    $path = "$($Letter.ToUpper()):\\"
    return (Test-Path $path)
}

function Test-OptionSourceAvailable {
    <#
    .SYNOPSIS
        Prueft ob die Installationsdateien fuer EINE Option (Engine/SSMS/SSRS/TDP/Treiber)
        tatsaechlich im konfigurierten Quellordner vorhanden sind.
    .DESCRIPTION
        Engine und SSMS sind versionsabhaengig (Quelle: <InstallDrive>:\SQLSources\SQL<Version>\...,
        siehe Scripts\New-SqlSourceStructure*.ps1). SSAS und SSIS werden als Feature der Engine-
        setup.exe installiert und brauchen daher keine eigene Pruefung (durch 'Engine' abgedeckt).
        SSRS/TDP/Treiber kommen aus den in settings.ini konfigurierten *_SourcePath-Werten.
    .PARAMETER Component
        'Engine', 'SSMS', 'SSRS', 'TDP', 'JDBC', 'ODBC' oder 'DB2'.
    .OUTPUTS
        $null wenn die Quelle vorhanden ist, sonst ein lesbarer Fehlertext.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Engine', 'SSMS', 'SSRS', 'TDP', 'JDBC', 'ODBC', 'DB2')]
        [string]$Component,
        [string]$InstallDrive,
        [string]$Version,
        [hashtable]$OptionalComponents = @{},
        [hashtable]$Drivers = @{}
    )

    switch ($Component) {
        'Engine' {
            $path = "$($InstallDrive):\SQLSources\SQL$Version\SQL_Install"
            if (Test-Path (Join-Path $path 'setup.exe')) { return $null }
            return "SQL Server Engine: setup.exe nicht gefunden unter '$path'"
        }
        'SSMS' {
            $path = "$($InstallDrive):\SQLSources\SQL$Version\Management"
            $found = Get-ChildItem -Path $path -Filter 'SSMS-Setup-*.exe' -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { return $null }
            return "SSMS: kein SSMS-Setup-*.exe gefunden unter '$path'"
        }
        'SSRS' {
            $path = $OptionalComponents['SSRS_SourcePath']
            if (-not $path -or -not (Test-Path -Path $path -ErrorAction SilentlyContinue)) {
                return "SSRS: Quellordner nicht erreichbar ('$path')"
            }
            $found = Get-ChildItem -Path $path -Filter 'SQLServerReportingServices*.exe' -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { return $null }
            return "SSRS: kein SQLServerReportingServices*.exe gefunden unter '$path'"
        }
        'TDP' {
            $path = $OptionalComponents['TDP_SourcePath']
            if ($path -and (Test-Path -Path $path -ErrorAction SilentlyContinue)) { return $null }
            return "TDP: Quellordner nicht erreichbar ('$path')"
        }
        'JDBC' {
            $path = $Drivers['JDBC_SourcePath']
            if ($path -and (Test-Path -Path $path -ErrorAction SilentlyContinue)) { return $null }
            return "JDBC-Treiber: Quellordner nicht erreichbar ('$path')"
        }
        'ODBC' {
            $path = $Drivers['ODBC_SourcePath']
            if ($path -and (Test-Path -Path $path -ErrorAction SilentlyContinue)) { return $null }
            return "ODBC-Treiber: Quellordner nicht erreichbar ('$path')"
        }
        'DB2' {
            $path = $Drivers['DB2_SourcePath']
            if ($path -and (Test-Path -Path $path -ErrorAction SilentlyContinue)) { return $null }
            return "DB2-Treiber: Quellordner nicht erreichbar ('$path')"
        }
    }
}

function Test-SelectedSourcesAvailable {
    <#
    .SYNOPSIS
        Prueft fuer alle aktuell ausgewaehlten Optionen ob die Installationsdateien vorhanden sind.
    .DESCRIPTION
        'Engine' sollte IMMER in -SelectedComponents enthalten sein (die Engine wird bei jeder
        Installation gebraucht, unabhaengig von Checkbox-Auswahl). Fuer jede fehlende Quelle wird
        ein lesbarer Fehlertext zurueckgegeben - der Aufrufer entscheidet ob/wie die Installation
        dann blockiert wird.
    .PARAMETER SelectedComponents
        Teilmenge von 'Engine','SSMS','SSRS','TDP','JDBC','ODBC','DB2' - je nachdem was ausgewaehlt ist.
    .OUTPUTS
        String[] - leer wenn alles verfuegbar ist, sonst ein Eintrag je fehlender Quelle.
    #>
    param(
        [string]$InstallDrive,
        [string]$Version,
        [hashtable]$OptionalComponents = @{},
        [hashtable]$Drivers = @{},
        [string[]]$SelectedComponents = @()
    )

    $problems = @()
    foreach ($component in $SelectedComponents) {
        $problem = Test-OptionSourceAvailable -Component $component -InstallDrive $InstallDrive `
            -Version $Version -OptionalComponents $OptionalComponents -Drivers $Drivers
        if ($problem) { $problems += $problem }
    }
    return @($problems)
}

Export-ModuleMember -Function Test-AdCredential, Test-InstanceName, Test-DriveLetter, `
    Test-OptionSourceAvailable, Test-SelectedSourcesAvailable
