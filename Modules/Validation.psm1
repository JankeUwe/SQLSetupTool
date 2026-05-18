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

Export-ModuleMember -Function Test-AdCredential, Test-InstanceName, Test-DriveLetter
