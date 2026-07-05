#Requires -Version 5.1
<#
.SYNOPSIS
    GitFetch.psm1 - Fehlende Modul-Quellen (dbaTools, sqmSQLTool, ...) automatisch von Git laden.

.DESCRIPTION
    Wird von New-SqlSourceStructure.ps1 / New-SqlSourceStructure-FiTS.ps1 verwendet,
    wenn ein SQLSources\Modules\<Name>-Ordner beim Anlegen der Struktur noch leer ist
    (kein .psd1-Manifest enthaelt) und in settings.ini [GitSources] eine Repo-URL
    hinterlegt ist. Laeuft NUR beim Anlegen/Aktualisieren der Sources (Start-AdminConfig),
    nicht beim eigentlichen SQL-Server-Setup - der Zielserver bleibt damit offline-faehig.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ModuleFromGitSource {
    <#
    .SYNOPSIS
        Befuellt einen Modul-Zielordner per 'git clone', sofern er noch kein Manifest enthaelt.
    .PARAMETER ModuleFolder
        Zielordner, z.B. <SQLSources>\Modules\dbaTools. Muss bereits existieren (leer oder mit README).
    .PARAMETER RepoUrl
        Git-Repository-URL (https://github.com/<owner>/<repo>.git). Leer/$null = ueberspringen.
    .PARAMETER ManifestFilter
        Filter fuer die Manifest-Erkennung. Standard: '*.psd1'.
    .PARAMETER Log
        ScriptBlock fuer Logausgabe: { param($msg) Write-Host $msg }. Standard: Write-Host.
    .OUTPUTS
        $true  = Ordner ist jetzt befuellt (bereits vorhanden oder neu geklont)
        $false = nicht befuellt (keine RepoUrl, git fehlt, oder Clone fehlgeschlagen)
    #>
    param(
        [Parameter(Mandatory)][string]$ModuleFolder,
        [string]$RepoUrl,
        [string]$ManifestFilter = '*.psd1',
        [scriptblock]$Log = { param($msg) Write-Host $msg }
    )

    $hasManifest = @(Get-ChildItem -Path $ModuleFolder -Filter $ManifestFilter -File -ErrorAction SilentlyContinue).Count -gt 0
    if ($hasManifest) {
        & $Log "  [=] $ModuleFolder bereits befuellt - Git-Download uebersprungen."
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
        & $Log "  [ ] $ModuleFolder ist leer, keine Git-URL in settings.ini [GitSources] hinterlegt - manuell befuellen."
        return $false
    }

    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        & $Log "  [!] git.exe nicht im PATH gefunden - kann $ModuleFolder nicht automatisch laden. Bitte Git installieren oder Ordner manuell befuellen."
        return $false
    }

    & $Log "  Lade von Git: $RepoUrl -> $ModuleFolder ..."
    $tempClone = Join-Path ([System.IO.Path]::GetTempPath()) ("gitfetch_" + [guid]::NewGuid().ToString('N'))
    try {
        $gitOutput = & git.exe clone --depth 1 --quiet -- $RepoUrl $tempClone 2>&1
        if ($LASTEXITCODE -ne 0) {
            & $Log "  [!] Git-Clone fehlgeschlagen ($RepoUrl): $gitOutput"
            return $false
        }

        Remove-Item -LiteralPath (Join-Path $tempClone '.git') -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $tempClone -Force | Move-Item -Destination $ModuleFolder -Force
        & $Log "  [OK] $ModuleFolder von Git befuellt ($RepoUrl)."
        return $true
    }
    catch {
        & $Log "  [!] Fehler beim Git-Download von $RepoUrl : $($_.Exception.Message)"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempClone) {
            Remove-Item -LiteralPath $tempClone -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function Get-ModuleFromGitSource
