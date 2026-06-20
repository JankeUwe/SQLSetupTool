#Requires -Version 5.1
<#
.SYNOPSIS
    PreInstall.psm1 - Vorab-Pruefungen vor der SQL Server-Installation

.DESCRIPTION
    Fuehrt alle konfigurierten PreInstall-Checks durch bevor die eigentliche
    SQL Server-Installation startet. Gibt $true zurueck wenn die Installation
    fortgesetzt werden soll, $false wenn der Benutzer abbricht.

    Implementierte Checks (in Reihenfolge):
        1. SQL-Instanz bereits installiert?
           -> Warnung, kein Abbruch (Treiber-Installation laeuft immer)
        2. NTFS-Blockgroesse (64K-Check) wenn Config.Format64kCheck = $true
           -> Prueft alle konfigurierten Laufwerke (Data, Log, Temp, Backup)
           -> Bei Abweichung: WinForms-Dialog mit Details und OK/Abbrechen
           -> Bei OK: Invoke-sqmFormatDrive64k fuer betroffene Laufwerke
        3. Snapshot-Hinweis wenn Config.SnapshotEnabled = $true
           -> Informations-Dialog, kein automatischer Checkpoint
        4. HPU AD-Gruppenmitgliedschaft wenn Config.HpuCheck = $true
           -> Get-sqmHpuAllowGroup ermittelt Gruppe per Domain-Mapping
           -> Prueft ob Computerkonto Mitglied ist (ADSI, kein AD-Modul)
           -> Bei Nicht-Mitgliedschaft: Installation wird blockiert
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
function Invoke-PreInstallChecks {
    <#
    .SYNOPSIS
        Fuehrt alle PreInstall-Checks durch.
    .PARAMETER Config
        PSCustomObject aus Get-SetupConfig (Config.psm1).
    .PARAMETER DiskLayout
        Hashtable mit Laufwerksbuchstaben (DataDrive, LogDrive, TempDrive, BackupDrive).
        Kommt aus Get-DiskLayoutFromForm in der GUI.
    .PARAMETER InstanceName
        Name der zu installierenden SQL-Instanz.
    .PARAMETER LogCallback
        ScriptBlock fuer GUI-Logging: { param($msg) Write-Log $msg }
    .OUTPUTS
        $true  = Installation fortsetzen
        $false = Benutzer hat abgebrochen
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][hashtable]$DiskLayout,
        [Parameter(Mandatory)][string]$InstanceName,
        [ScriptBlock]$LogCallback
    )

    function log([string]$msg) {
        if ($LogCallback) { & $LogCallback $msg } else { Write-Host $msg }
    }

    log '--- PreInstall-Pruefungen ---'

    # =========================================================================
    # CHECK 1: SQL-Instanz bereits installiert?
    # =========================================================================
    log "PreInstall: Pruefe ob SQL-Instanz '$InstanceName' bereits installiert..."
    try {
        $instCheck = Test-sqmSqlInstanceInstalled -InstanceName $InstanceName -ErrorAction SilentlyContinue
        if ($instCheck -and $instCheck.IsInstalled) {
            log "  WARNUNG: SQL-Instanz '$InstanceName' ist bereits installiert!"
            log "           Status   : $($instCheck.Status)"
            log "           Version  : $($instCheck.Version)"
            log "           Dienst   : $($instCheck.ServiceName) [$($instCheck.ServiceState)]"
            log "           -> Installation wird trotzdem fortgesetzt (Treiber laufen immer)."

            $warnResult = [System.Windows.Forms.MessageBox]::Show(
                "SQL-Instanz '$InstanceName' ist bereits installiert!`n`n" +
                "Version : $($instCheck.Version)`n" +
                "Dienst  : $($instCheck.ServiceName) [$($instCheck.ServiceState)]`n`n" +
                "Trotzdem fortfahren? (Nur sinnvoll fuer Treiber-Installation oder Re-Konfiguration)",
                'Instanz bereits vorhanden',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($warnResult -ne [System.Windows.Forms.DialogResult]::Yes) {
                log '  -> Abgebrochen durch Benutzer.'
                return $false
            }
        }
        else {
            log "  OK: Instanz '$InstanceName' noch nicht installiert."
        }
    }
    catch {
        log "  INFO: Instanz-Pruefung nicht moeglich (sqmSQLTool nicht geladen?): $_"
    }

    # =========================================================================
    # CHECK 2: NTFS 64K-Blockgroesse
    # =========================================================================
    if ($Config.Format64kCheck) {
        log 'PreInstall: Pruefe NTFS-Blockgroesse (64K-Empfehlung fuer SQL Server)...'

        # Laufwerke aus DiskLayout zusammenstellen (ohne Doppelpunkte, eindeutig)
        $drivesToCheck = @(
            $DiskLayout['DataDrive'],
            $DiskLayout['LogDrive'],
            $DiskLayout['TempDrive'],
            $DiskLayout['BackupDrive']
        ) | ForEach-Object { $_.TrimEnd(':').Trim().ToUpper() } |
            Where-Object   { $_ -ne '' -and $_ -ne 'C' } |
            Sort-Object -Unique

        if ($drivesToCheck.Count -eq 0) {
            log '  INFO: Keine Laufwerke fuer 64K-Pruefung konfiguriert.'
        }
        else {
            try {
                $blockResults = Get-sqmDiskBlockSize -Drive $drivesToCheck -ErrorAction SilentlyContinue
                $notOk = @($blockResults | Where-Object { -not $_.IsRecommended -and $_.Status -ne 'Error' })

                foreach ($r in $blockResults) {
                    $icon = if ($r.IsRecommended) { 'OK  ' } else { 'WARN' }
                    log "  $icon Laufwerk $($r.Drive): $($r.BlockSizeKB) KB (Empfehlung: 64 KB) - $($r.Status)"
                }

                if ($notOk.Count -gt 0) {
                    # Detailtext fuer Dialog
                    $driveList = ($notOk | ForEach-Object {
                        "$($_.Drive): $($_.BlockSizeKB) KB statt 64 KB"
                    }) -join "`n"

                    $dialogText = "Folgende Laufwerke haben NICHT die empfohlene 64 KB-Blockgroesse:`n`n" +
                                  $driveList + "`n`n" +
                                  "WARNUNG: Das Formatieren loescht alle Daten auf den betroffenen Laufwerken!`n" +
                                  "Vorher sicherstellen dass die Laufwerke leer sind.`n`n" +
                                  "Jetzt auf 64 KB formatieren?"

                    $formatResult = [System.Windows.Forms.MessageBox]::Show(
                        $dialogText,
                        'NTFS-Blockgroesse - 64K-Formatierung',
                        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )

                    if ($formatResult -eq [System.Windows.Forms.DialogResult]::Cancel) {
                        log '  -> PreInstall abgebrochen durch Benutzer (Cancel).'
                        return $false
                    }
                    elseif ($formatResult -eq [System.Windows.Forms.DialogResult]::Yes) {
                        log '  -> Starte 64K-Formatierung der betroffenen Laufwerke...'
                        foreach ($drive in $notOk) {
                            log "  Formatiere Laufwerk $($drive.Drive): ..."
                            try {
                                $fmtResult = Invoke-sqmFormatDrive64k -DriveLetter $drive.Drive -Force -ErrorAction Stop
                                log "  $($fmtResult.Status): Laufwerk $($drive.Drive): - $($fmtResult.Message)"
                            }
                            catch {
                                log "  FEHLER beim Formatieren von $($drive.Drive):: $_"
                                $errResult = [System.Windows.Forms.MessageBox]::Show(
                                    "Fehler beim Formatieren von Laufwerk $($drive.Drive):`n$_`n`nTrotzdem fortfahren?",
                                    'Formatierungsfehler',
                                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                                    [System.Windows.Forms.MessageBoxIcon]::Error
                                )
                                if ($errResult -ne [System.Windows.Forms.DialogResult]::Yes) {
                                    return $false
                                }
                            }
                        }
                        log '  -> 64K-Formatierung abgeschlossen.'
                    }
                    else {
                        # No: Warnung ignorieren, Installation fortsetzen
                        log '  -> 64K-Warnung ignoriert. Installation wird fortgesetzt.'
                    }
                }
                else {
                    log '  OK: Alle Laufwerke haben korrekte 64 KB-Blockgroesse.'
                }
            }
            catch {
                log "  INFO: 64K-Pruefung nicht moeglich (sqmSQLTool nicht geladen?): $_"
            }
        }
    }
    else {
        log 'PreInstall: 64K-Check deaktiviert (settings.ini [PreInstall] Format64kCheck = false).'
    }

    # =========================================================================
    # CHECK 3: Snapshot-Hinweis
    # =========================================================================
    if ($Config.SnapshotEnabled) {
        log 'PreInstall: Snapshot-Hinweis aktiv...'

        $snapResult = [System.Windows.Forms.MessageBox]::Show(
            "Snapshot empfohlen!`n`n" +
            "Bevor die SQL Server-Installation startet, wird empfohlen einen`n" +
            "VM-Snapshot / Checkpoint des Servers zu erstellen.`n`n" +
            "Bitte jetzt manuell einen Snapshot anlegen und danach OK klicken.`n`n" +
            "Snapshot bereits erstellt oder nicht erforderlich?",
            'Snapshot-Empfehlung',
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($snapResult -ne [System.Windows.Forms.DialogResult]::OK) {
            log '  -> Installation abgebrochen fuer manuellen Snapshot.'
            return $false
        }
        log '  OK: Snapshot bestaetigt. Installation wird fortgesetzt.'
    }

    # =========================================================================
    # CHECK 4: HPU AD-Gruppenmitgliedschaft (nur wenn HpuCheck = true)
    # =========================================================================
    if ($Config.HpuCheck) {
        log 'PreInstall: Pruefe HPU AD-Gruppenmitgliedschaft...'
        try {
            $hpuGroupDN = Get-sqmHpuAllowGroup -ErrorAction Stop

            if (-not $hpuGroupDN) {
                log '  FEHLER: HPU-Allow-Gruppe nicht gefunden (kein Domain-Mapping konfiguriert?).'
                [System.Windows.Forms.MessageBox]::Show(
                    "HPU-Check fehlgeschlagen!`n`n" +
                    "Fuer die Domain '$($Config.Domain)' ist keine HPU-Allow-Gruppe konfiguriert.`n`n" +
                    "Bitte HpuDomainGroupMap in sqmSQLTool konfigurieren oder`n" +
                    "HpuCheck in settings.ini auf false setzen.`n`n" +
                    "Installation wird abgebrochen.",
                    'HPU-Check — Konfigurationsfehler',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
                return $false
            }

            log "  HPU-Gruppe gefunden: $hpuGroupDN"
            log "  Pruefe Mitgliedschaft von '$env:COMPUTERNAME'..."

            # Computerkonto-DN via ADSI ermitteln (kein AD-Modul erforderlich)
            $computerSearcher = [adsisearcher]"(samaccountname=$($env:COMPUTERNAME)`$)"
            $computerSearcher.PropertiesToLoad.Add('distinguishedname') | Out-Null
            $computerResult = $computerSearcher.FindOne()

            if (-not $computerResult) {
                log "  WARN: Computerkonto '$env:COMPUTERNAME' nicht im AD gefunden — Pruefung nicht moeglich."
                [System.Windows.Forms.MessageBox]::Show(
                    "HPU-Check: Computerkonto '$env:COMPUTERNAME' wurde im Active Directory nicht gefunden.`n`n" +
                    "Moegliche Ursache: Kein Domainbeitritt oder fehlende AD-Verbindung.`n`n" +
                    "Installation wird abgebrochen.",
                    'HPU-Check — Computerkonto nicht gefunden',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
                return $false
            }

            $computerDN = $computerResult.Properties['distinguishedname'][0]
            log "  Computerkonto-DN: $computerDN"

            # Gruppenmitgliedschaft via ADSI pruefen (rekursive Member-Liste)
            $group   = [ADSI]"LDAP://$hpuGroupDN"
            $members = $group.psbase.Invoke('Members') |
                       ForEach-Object { ([ADSI]$_).distinguishedName }

            $isMember = $members -contains $computerDN

            if (-not $isMember) {
                log "  FEHLER: '$env:COMPUTERNAME' ist NICHT Mitglied der HPU-Gruppe."
                log "          Gruppe : $hpuGroupDN"
                [System.Windows.Forms.MessageBox]::Show(
                    "HPU-Check fehlgeschlagen!`n`n" +
                    "Der Computer '$env:COMPUTERNAME' ist nicht Mitglied der HPU-Allow-Gruppe:`n" +
                    "$hpuGroupDN`n`n" +
                    "Bitte den Server zuerst in die HPU-Gruppe aufnehmen und danach erneut starten.`n`n" +
                    "Installation wird abgebrochen.",
                    'HPU-Check — Keine Mitgliedschaft',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Stop
                ) | Out-Null
                return $false
            }

            log "  OK: '$env:COMPUTERNAME' ist Mitglied der HPU-Gruppe."
        }
        catch {
            log "  FEHLER HPU-Check: $_"
            [System.Windows.Forms.MessageBox]::Show(
                "HPU-Check fehlgeschlagen!`n`nFehler: $_`n`nInstallation wird abgebrochen.",
                'HPU-Check — Fehler',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return $false
        }
    }
    else {
        log 'PreInstall: HPU-Check deaktiviert (settings.ini [PreInstall] HpuCheck = false).'
    }

    log '--- PreInstall-Pruefungen abgeschlossen. ---'
    return $true
}

Export-ModuleMember -Function Invoke-PreInstallChecks
