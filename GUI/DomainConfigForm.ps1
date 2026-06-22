#Requires -Version 5.1
<#
.SYNOPSIS
    GUI\DomainConfigForm.ps1
    Editor fuer Domain-Profile (Config\domains\*.ini).
    Jedes Profil steuert Sortierung, Sysadmin-Gruppen, Monitoring-Typ,
    Laufwerkslayout und Ziel-Server-Pfad fuer eine Active-Directory-Domaene.

    Aufruf:
      . .\GUI\DomainConfigForm.ps1
      Show-DomainConfigForm -ConfigDir 'C:\...\Config'
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-DomainConfigForm {
    <#
    .SYNOPSIS
        Zeigt den Domain-Profil-Editor als modalen Dialog.
    .PARAMETER ConfigDir
        Pfad zum Config-Verzeichnis (enthaelt domains\ und collations.txt).
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir
    )

    $domainsDir = Join-Path $ConfigDir 'domains'
    if (-not (Test-Path $domainsDir)) {
        New-Item -ItemType Directory -Path $domainsDir -Force | Out-Null
    }

    # ---------------------------------------------------------------------------
    # INI-Hilfsfunktionen
    # ---------------------------------------------------------------------------
    function _ReadIni {
        param([string]$Path)
        $ini = [ordered]@{}
        $sec = '__global__'
        $ini[$sec] = [ordered]@{}
        foreach ($line in Get-Content $Path -Encoding UTF8) {
            $line = $line.Trim()
            if ($line -eq '' -or $line -match '^[#;]') { continue }
            if ($line -match '^\[(.+)\]$') {
                $sec = $matches[1].Trim()
                if (-not $ini.Contains($sec)) { $ini[$sec] = [ordered]@{} }
                continue
            }
            if ($line -match '^([^=]+)=(.*)$') {
                $ini[$sec][$matches[1].Trim()] = $matches[2].Trim()
            }
        }
        return $ini
    }

    function _IniVal {
        param($ini, [string]$s, [string]$k, [string]$d = '')
        if ($ini.Contains($s) -and $ini[$s].Contains($k)) { return $ini[$s][$k] }
        return $d
    }

    function _WriteProfile {
        param([string]$Path, [string]$DisplayName, [string]$Collation,
              [string]$Groups, [string]$MonType,
              [string]$DataDrive, [string]$LogDrive, [string]$TempDrive,
              [string]$BackupDrive, [string]$InstallDrive,
              [string]$SQLSourcesPath)

        $lines = @(
            "# Domain-Profil: $(Split-Path $Path -LeafBase)",
            '',
            '[Profile]',
            "DisplayName = $DisplayName",
            '',
            '[Collation]',
            "Default = $Collation",
            '',
            '[SysadminGroups]',
            '# Kommagetrennte AD-Gruppen fuer sysadmin-Rolle nach der Installation.',
            "Groups = $Groups",
            '',
            '[Monitoring]',
            '# 0-basierter Index in die Monitoring-Typen-Liste (settings.ini [Monitoring] Types)',
            "Type = $MonType",
            '',
            '[DiskLayout]',
            "DataDrive    = $DataDrive",
            "LogDrive     = $LogDrive",
            "TempDrive    = $TempDrive",
            "BackupDrive  = $BackupDrive",
            "InstallDrive = $InstallDrive",
            '',
            '[SQLSources]',
            '# Pfad zu den SQL-Installationsquellen auf Servern dieser Domain.',
            '# Das Setup-Tool sucht hier nach SQL<Version>\SQL_Install\setup.exe usw.',
            '# Leer = globaler SourceShare aus settings.ini wird verwendet.',
            "SourcePath = $SQLSourcesPath"
        )
        Set-Content -Path $Path -Value $lines -Encoding UTF8
    }

    # ---------------------------------------------------------------------------
    # Collation-Liste laden
    # ---------------------------------------------------------------------------
    $collationsFile = Join-Path $ConfigDir 'collations.txt'
    $collationList  = @('Latin1_General_CI_AS', 'SQL_Latin1_General_CP1_CI_AS')
    if (Test-Path $collationsFile) {
        $loaded = Get-Content $collationsFile -Encoding UTF8 |
                  Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } |
                  ForEach-Object { $_.Trim() }
        if ($loaded.Count -gt 0) { $collationList = $loaded }
    }

    # Monitoring-Typen aus settings.ini lesen
    $settingsIni  = Join-Path $ConfigDir 'settings.ini'
    $monTypes     = @('Kein Monitoring', 'Service Monitoring', 'Vollstaendiges Monitoring')
    if (Test-Path $settingsIni) {
        $sIni = _ReadIni -Path $settingsIni
        if ($sIni.Contains('Monitoring') -and $sIni['Monitoring']['Types']) {
            $loaded = $sIni['Monitoring']['Types'] -split ',' | ForEach-Object { $_.Trim() }
            if ($loaded.Count -gt 0) { $monTypes = $loaded }
        }
    }

    # ---------------------------------------------------------------------------
    # Profil-Liste laden
    # ---------------------------------------------------------------------------
    function _LoadProfileList {
        return @(Get-ChildItem -Path $domainsDir -Filter '*.ini' -ErrorAction SilentlyContinue |
                 Sort-Object Name |
                 ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })
    }

    # ---------------------------------------------------------------------------
    # Formular aufbauen
    # ---------------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Domain-Konfiguration'
    $form.Size            = New-Object System.Drawing.Size(820, 620)
    $form.MinimumSize     = New-Object System.Drawing.Size(820, 580)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'

    # ---- Linke Spalte: Domain-Liste ----
    $pnlLeft          = New-Object System.Windows.Forms.Panel
    $pnlLeft.Location = New-Object System.Drawing.Point(10, 10)
    $pnlLeft.Size     = New-Object System.Drawing.Size(160, 540)
    $pnlLeft.Anchor   = 'Top,Bottom,Left'
    $form.Controls.Add($pnlLeft)

    $lblDomains          = New-Object System.Windows.Forms.Label
    $lblDomains.Text     = 'Domain-Profile:'
    $lblDomains.Location = New-Object System.Drawing.Point(0, 0)
    $lblDomains.Size     = New-Object System.Drawing.Size(160, 20)
    $pnlLeft.Controls.Add($lblDomains)

    $lbDomains               = New-Object System.Windows.Forms.ListBox
    $lbDomains.Location      = New-Object System.Drawing.Point(0, 24)
    $lbDomains.Size          = New-Object System.Drawing.Size(160, 430)
    $lbDomains.Anchor        = 'Top,Bottom,Left'
    $lbDomains.SelectionMode = 'One'
    $pnlLeft.Controls.Add($lbDomains)

    $btnNew          = New-Object System.Windows.Forms.Button
    $btnNew.Text     = '+ Neu'
    $btnNew.Location = New-Object System.Drawing.Point(0, 462)
    $btnNew.Size     = New-Object System.Drawing.Size(75, 26)
    $btnNew.Anchor   = 'Bottom,Left'
    $pnlLeft.Controls.Add($btnNew)

    $btnDel          = New-Object System.Windows.Forms.Button
    $btnDel.Text     = '- Loeschen'
    $btnDel.Location = New-Object System.Drawing.Point(82, 462)
    $btnDel.Size     = New-Object System.Drawing.Size(78, 26)
    $btnDel.Anchor   = 'Bottom,Left'
    $pnlLeft.Controls.Add($btnDel)

    # ---- Trennlinie ----
    $sep          = New-Object System.Windows.Forms.Panel
    $sep.Location = New-Object System.Drawing.Point(178, 10)
    $sep.Size     = New-Object System.Drawing.Size(2, 540)
    $sep.Anchor   = 'Top,Bottom,Left'
    $sep.BorderStyle = 'Fixed3D'
    $form.Controls.Add($sep)

    # ---- Rechte Seite: Tabs ----
    $tabs          = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(188, 10)
    $tabs.Size     = New-Object System.Drawing.Size(610, 540)
    $tabs.Anchor   = 'Top,Bottom,Left,Right'
    $form.Controls.Add($tabs)

    # =========================================================================
    # Tab 1: Allgemein
    # =========================================================================
    $tabGen      = New-Object System.Windows.Forms.TabPage
    $tabGen.Text = 'Allgemein'
    $tabs.TabPages.Add($tabGen)

    function _Lbl { param($P,$T,$X,$Y,$W=160,$H=20)
        $l = New-Object System.Windows.Forms.Label
        $l.Text=$T; $l.Location=New-Object System.Drawing.Point($X,$Y)
        $l.Size=New-Object System.Drawing.Size($W,$H); $l.TextAlign='MiddleLeft'
        [void]$P.Controls.Add($l); return $l }

    function _Tb { param($P,$X,$Y,$W=340,$Def='',$Enabled=$true)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location=New-Object System.Drawing.Point($X,$Y)
        $t.Size=New-Object System.Drawing.Size($W,24); $t.Text=$Def; $t.Enabled=$Enabled
        [void]$P.Controls.Add($t); return $t }

    function _Cb { param($P,$X,$Y,$W=340,$Items=@(),$Def='')
        $c = New-Object System.Windows.Forms.ComboBox
        $c.Location=New-Object System.Drawing.Point($X,$Y)
        $c.Size=New-Object System.Drawing.Size($W,24); $c.DropDownStyle='DropDown'
        foreach($i in $Items){ [void]$c.Items.Add($i) }
        if($Def -ne '' -and $c.Items.Contains($Def)){ $c.SelectedItem=$Def }
        elseif($c.Items.Count -gt 0){ $c.SelectedIndex=0 }
        [void]$P.Controls.Add($c); return $c }

    function _BrowseBtn { param($P,$X,$Y,$Tb)
        $b = New-Object System.Windows.Forms.Button
        $b.Text='...'; $b.Location=New-Object System.Drawing.Point($X,$Y)
        $b.Size=New-Object System.Drawing.Size(30,24)
        $tbRef = $Tb
        $b.Add_Click({
            $dlg=New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description='Ordner auswaehlen'
            if($tbRef.Text -ne '' -and (Test-Path $tbRef.Text -ErrorAction SilentlyContinue)){
                $dlg.SelectedPath=$tbRef.Text }
            if($dlg.ShowDialog()-eq[System.Windows.Forms.DialogResult]::OK){
                $tbRef.Text=$dlg.SelectedPath } })
        [void]$P.Controls.Add($b); return $b }

    $y = 20
    _Lbl -P $tabGen -T 'Anzeigename:' -X 10 -Y $y -W 150
    $tbDisplayName = _Tb -P $tabGen -X 165 -Y $y -W 420

    $y += 36
    _Lbl -P $tabGen -T 'Sortierung:' -X 10 -Y $y -W 150
    $cbCollation = _Cb -P $tabGen -X 165 -Y $y -W 420 -Items $collationList

    $y += 36
    _Lbl -P $tabGen -T 'Sysadmin-Gruppen:' -X 10 -Y ($y) -W 150
    _Lbl -P $tabGen -T '(kommagetrennt)' -X 10 -Y ($y+18) -W 150
    $tbGroups          = New-Object System.Windows.Forms.TextBox
    $tbGroups.Location = New-Object System.Drawing.Point(165, $y)
    $tbGroups.Size     = New-Object System.Drawing.Size(420, 42)
    $tbGroups.Multiline = $true
    $tbGroups.ScrollBars = 'Vertical'
    $tabGen.Controls.Add($tbGroups)

    $y += 60
    _Lbl -P $tabGen -T 'Monitoring-Typ:' -X 10 -Y $y -W 150
    $cbMonType = New-Object System.Windows.Forms.ComboBox
    $cbMonType.Location = New-Object System.Drawing.Point(165, $y)
    $cbMonType.Size     = New-Object System.Drawing.Size(260, 24)
    $cbMonType.DropDownStyle = 'DropDownList'
    for ($mi = 0; $mi -lt $monTypes.Count; $mi++) {
        [void]$cbMonType.Items.Add("$mi - $($monTypes[$mi])")
    }
    if ($cbMonType.Items.Count -gt 0) { $cbMonType.SelectedIndex = 1 }
    $tabGen.Controls.Add($cbMonType)

    $y += 50
    $sepLine          = New-Object System.Windows.Forms.Panel
    $sepLine.Location = New-Object System.Drawing.Point(10, $y)
    $sepLine.Size     = New-Object System.Drawing.Size(575, 2)
    $sepLine.BorderStyle = 'Fixed3D'
    $tabGen.Controls.Add($sepLine)

    $y += 12
    _Lbl -P $tabGen -T 'SQLSources-Pfad:' -X 10 -Y $y -W 150
    $tbSQLSourcesPath = _Tb -P $tabGen -X 165 -Y $y -W 390
    _BrowseBtn -P $tabGen -X 560 -Y $y -Tb $tbSQLSourcesPath | Out-Null
    _Lbl -P $tabGen -T '(Leer = globaler SourceShare aus settings.ini wird verwendet)' -X 165 -Y ($y+26) -W 420

    # =========================================================================
    # Tab 2: Laufwerke
    # =========================================================================
    $tabDisk      = New-Object System.Windows.Forms.TabPage
    $tabDisk.Text = 'Laufwerke'
    $tabs.TabPages.Add($tabDisk)

    $driveLetters = @('A','B','C','D','E','F','G','H','I','J','K','L','M',
                      'N','O','P','Q','R','S','T','U','V','W','X','Y','Z')

    function _DriveCb { param($P,$Label,$X,$Y,$Def='C')
        $null = _Lbl -P $P -T $Label -X $X -Y $Y -W 120   # Rueckgabewert unterdruecken!
        $c = New-Object System.Windows.Forms.ComboBox
        $c.Location = New-Object System.Drawing.Point(($X+125),$Y)
        $c.Size     = New-Object System.Drawing.Size(60,24)
        $c.DropDownStyle = 'DropDownList'
        foreach ($dl in $driveLetters) { [void]$c.Items.Add($dl) }
        if ($c.Items.Contains($Def)) { $c.SelectedItem = $Def }
        else { $c.SelectedIndex = 0 }
        [void]$P.Controls.Add($c)
        return $c
    }

    _Lbl -P $tabDisk -T 'SQL Server Laufwerkszuordnung fuer diese Domain:' -X 10 -Y 10 -W 550

    $cbDataDrive    = _DriveCb -P $tabDisk -Label 'Datenlaufwerk:'    -X 10  -Y 45  -Def 'G'
    $cbLogDrive     = _DriveCb -P $tabDisk -Label 'Log-Laufwerk:'     -X 10  -Y 85  -Def 'H'
    $cbTempDrive    = _DriveCb -P $tabDisk -Label 'TempDB-Laufwerk:'  -X 10  -Y 125 -Def 'I'
    $cbBackupDrive  = _DriveCb -P $tabDisk -Label 'Backup-Laufwerk:'  -X 10  -Y 165 -Def 'F'
    $cbInstallDrive = _DriveCb -P $tabDisk -Label 'Install-Laufwerk:' -X 10  -Y 205 -Def 'C'

    _Lbl -P $tabDisk -T '(DataDrive, LogDrive, TempDrive -> SQL-Dateien)' -X 10 -Y 250 -W 450
    _Lbl -P $tabDisk -T '(BackupDrive -> Backup + SystemDB-Verzeichnis)'  -X 10 -Y 270 -W 450
    _Lbl -P $tabDisk -T '(InstallDrive -> SQL Server Binaerdateien)'       -X 10 -Y 290 -W 450

    # =========================================================================
    # Footer: Speichern / Schliessen
    # =========================================================================
    $btnSave          = New-Object System.Windows.Forms.Button
    $btnSave.Text     = 'Speichern'
    $btnSave.Location = New-Object System.Drawing.Point(630, 558)
    $btnSave.Size     = New-Object System.Drawing.Size(90, 28)
    $btnSave.Anchor   = 'Bottom,Right'
    $btnSave.Enabled  = $false
    $form.Controls.Add($btnSave)

    $btnClose          = New-Object System.Windows.Forms.Button
    $btnClose.Text     = 'Schliessen'
    $btnClose.Location = New-Object System.Drawing.Point(725, 558)
    $btnClose.Size     = New-Object System.Drawing.Size(85, 28)
    $btnClose.Anchor   = 'Bottom,Right'
    $form.Controls.Add($btnClose)

    # =========================================================================
    # Hilfsfunktionen: Profil laden / leeren
    # =========================================================================
    function _ClearForm {
        $tbDisplayName.Text = ''
        if ($cbCollation.Items.Count -gt 0) { $cbCollation.SelectedIndex = 0 }
        $tbGroups.Text      = ''
        if ($cbMonType.Items.Count -gt 0)   { $cbMonType.SelectedIndex = 1 }
        $tbSQLSourcesPath.Text = ''
        if ($cbDataDrive.Items.Contains('G'))    { $cbDataDrive.SelectedItem    = 'G' }
        if ($cbLogDrive.Items.Contains('H'))     { $cbLogDrive.SelectedItem     = 'H' }
        if ($cbTempDrive.Items.Contains('I'))    { $cbTempDrive.SelectedItem    = 'I' }
        if ($cbBackupDrive.Items.Contains('F'))  { $cbBackupDrive.SelectedItem  = 'F' }
        if ($cbInstallDrive.Items.Contains('C')) { $cbInstallDrive.SelectedItem = 'C' }
    }

    function _LoadProfile {
        param([string]$Name)
        $iniPath = Join-Path $domainsDir "$Name.ini"
        if (-not (Test-Path $iniPath)) { _ClearForm; return }
        $d = _ReadIni -Path $iniPath

        $tbDisplayName.Text = _IniVal $d 'Profile' 'DisplayName'
        $coll = _IniVal $d 'Collation' 'Default'
        if ($cbCollation.Items.Contains($coll)) { $cbCollation.SelectedItem = $coll }
        elseif ($coll -ne '') { $cbCollation.Text = $coll }
        elseif ($cbCollation.Items.Count -gt 0) { $cbCollation.SelectedIndex = 0 }

        $tbGroups.Text = _IniVal $d 'SysadminGroups' 'Groups'

        $monRaw = _IniVal $d 'Monitoring' 'Type' '1'
        $monIdx = 1
        if ($monRaw -match '^\d+$') { $monIdx = [int]$monRaw }
        if ($monIdx -lt $cbMonType.Items.Count) { $cbMonType.SelectedIndex = $monIdx }

        $tbSQLSourcesPath.Text = _IniVal $d 'SQLSources' 'SourcePath'

        $dd = _IniVal $d 'DiskLayout' 'DataDrive'    'G'
        $ld = _IniVal $d 'DiskLayout' 'LogDrive'     'H'
        $td = _IniVal $d 'DiskLayout' 'TempDrive'    'I'
        $bd = _IniVal $d 'DiskLayout' 'BackupDrive'  'F'
        $id = _IniVal $d 'DiskLayout' 'InstallDrive' 'C'
        if ($cbDataDrive.Items.Contains($dd))    { $cbDataDrive.SelectedItem    = $dd }
        if ($cbLogDrive.Items.Contains($ld))     { $cbLogDrive.SelectedItem     = $ld }
        if ($cbTempDrive.Items.Contains($td))    { $cbTempDrive.SelectedItem    = $td }
        if ($cbBackupDrive.Items.Contains($bd))  { $cbBackupDrive.SelectedItem  = $bd }
        if ($cbInstallDrive.Items.Contains($id)) { $cbInstallDrive.SelectedItem = $id }
    }

    function _RefreshList {
        param([string]$SelectName = '')
        $lbDomains.Items.Clear()
        foreach ($n in (_LoadProfileList)) { [void]$lbDomains.Items.Add($n) }
        if ($SelectName -ne '' -and $lbDomains.Items.Contains($SelectName)) {
            $lbDomains.SelectedItem = $SelectName
        } elseif ($lbDomains.Items.Count -gt 0) {
            $lbDomains.SelectedIndex = 0
        }
    }

    # =========================================================================
    # Event-Handler
    # =========================================================================
    $lbDomains.Add_SelectedIndexChanged({
        if ($lbDomains.SelectedIndex -lt 0) {
            _ClearForm
            $btnSave.Enabled = $false
            $btnDel.Enabled  = $false
            return
        }
        $selName = $lbDomains.SelectedItem.ToString()
        _LoadProfile -Name $selName
        $btnSave.Enabled = $true
        $btnDel.Enabled  = ($selName -ne 'DEFAULT')
    })

    $btnNew.Add_Click({
        $inp = [Microsoft.VisualBasic.Interaction]::InputBox(
            'NetBIOS-Domainname des neuen Profils (z.B. CONTOSO):',
            'Neues Domain-Profil', '')
        if ($inp -eq '') { return }
        $newName = $inp.ToUpper().Trim()
        if ($newName -match '[\\/:*?"<>|]') {
            [System.Windows.Forms.MessageBox]::Show(
                "Ungueltiger Name: '$newName'",
                'Fehler', 'OK', 'Error') | Out-Null
            return
        }
        $newPath = Join-Path $domainsDir "$newName.ini"
        if (Test-Path $newPath) {
            [System.Windows.Forms.MessageBox]::Show(
                "Profil '$newName' existiert bereits.",
                'Hinweis', 'OK', 'Information') | Out-Null
            $lbDomains.SelectedItem = $newName
            return
        }
        _WriteProfile -Path $newPath -DisplayName $newName `
            -Collation 'Latin1_General_CI_AS' -Groups '' -MonType '1' `
            -DataDrive 'G' -LogDrive 'H' -TempDrive 'I' `
            -BackupDrive 'F' -InstallDrive 'C' -SQLSourcesPath ''
        _RefreshList -SelectName $newName
    })

    $btnDel.Add_Click({
        if ($lbDomains.SelectedIndex -lt 0) { return }
        $selName = $lbDomains.SelectedItem.ToString()
        if ($selName -eq 'DEFAULT') {
            [System.Windows.Forms.MessageBox]::Show(
                'Das DEFAULT-Profil kann nicht geloescht werden.',
                'Hinweis', 'OK', 'Warning') | Out-Null
            return
        }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Profil '$selName' wirklich loeschen?",
            'Loeschen bestaetigen',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        Remove-Item (Join-Path $domainsDir "$selName.ini") -Force
        _RefreshList
    })

    $btnSave.Add_Click({
        if ($lbDomains.SelectedIndex -lt 0) { return }
        $selName = $lbDomains.SelectedItem.ToString()
        $savePath = Join-Path $domainsDir "$selName.ini"
        $monIdx  = if ($cbMonType.SelectedIndex -ge 0) { $cbMonType.SelectedIndex } else { 1 }
        _WriteProfile -Path $savePath `
            -DisplayName  $tbDisplayName.Text.Trim() `
            -Collation    $cbCollation.Text.Trim() `
            -Groups       ($tbGroups.Text -replace '\r?\n', ',' -replace ',+', ',').Trim(',') `
            -MonType      $monIdx.ToString() `
            -DataDrive    $cbDataDrive.SelectedItem.ToString() `
            -LogDrive     $cbLogDrive.SelectedItem.ToString() `
            -TempDrive    $cbTempDrive.SelectedItem.ToString() `
            -BackupDrive  $cbBackupDrive.SelectedItem.ToString() `
            -InstallDrive $cbInstallDrive.SelectedItem.ToString() `
            -SQLSourcesPath $tbSQLSourcesPath.Text.Trim()
        [System.Windows.Forms.MessageBox]::Show(
            "Profil '$selName' gespeichert.",
            'Gespeichert', 'OK', 'Information') | Out-Null
    })

    $btnClose.Add_Click({ $form.Close() })

    # =========================================================================
    # Initialisierung
    # =========================================================================
    # Microsoft.VisualBasic fuer InputBox laden
    Add-Type -AssemblyName Microsoft.VisualBasic

    _RefreshList

    # --- Visual Studio "Dark" Theme anwenden (einheitlich mit unseren anderen GUIs) ---
    . (Join-Path $PSScriptRoot 'Theme.ps1')
    $vsPalette = Get-VsDarkPalette
    $form.BackColor = $vsPalette.Panel
    $form.ForeColor = $vsPalette.Text
    Set-VsDarkTheme -Control $form -Palette $vsPalette

    [System.Windows.Forms.Application]::Run($form)
}
