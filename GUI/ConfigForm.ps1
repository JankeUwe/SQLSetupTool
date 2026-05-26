#Requires -Version 5.1
<#
.SYNOPSIS
    GUI\ConfigForm.ps1
    Konfigurationsfenster fuer das SQL Server Setup Tool.
    Erlaubt das Bearbeiten von settings.ini ueber eine grafische Oberflaeche.
    Wird von MainForm.ps1 per dot-source geladen und via Show-ConfigForm aufgerufen.

    Tabs:
      1  Quellpfade   - SourceShare, Module, Treiber, Opt. Komponenten, Wartung
      2  SQLSources   - Struktur anlegen (Standard + FI-TS mit ZIP-Option)
      3  Defaults     - DefaultVersion/Edition/Instance/Collation, Ports, PreInstall
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-ConfigForm {
    <#
    .SYNOPSIS
        Zeigt das Konfigurationsfenster als modalen Dialog.
    .PARAMETER IniPath
        Vollstaendiger Pfad zur settings.ini.
    .OUTPUTS
        $true wenn gespeichert, $false bei Abbrechen.
    #>
    param(
        [Parameter(Mandatory)][string]$IniPath
    )

    # ---------------------------------------------------------------------------
    # Hilfsfunktionen INI
    # ---------------------------------------------------------------------------
    function _ReadIni {
        param([string]$Path)
        $ini     = @{}
        $section = '_'
        foreach ($line in Get-Content $Path -Encoding UTF8) {
            $line = $line.Trim()
            if ($line -match '^\s*[#;]' -or $line -eq '') { continue }
            if ($line -match '^\[(.+)\]$') {
                $section = $matches[1]
                $ini[$section] = @{}
                continue
            }
            if ($line -match '^([^=]+?)\s*=\s*(.*)$') {
                $ini[$section][$matches[1].Trim()] = $matches[2].Trim()
            }
        }
        return $ini
    }

    function _UpdateIni {
        param([string]$IniPath, [string]$Section, [string]$Key, [string]$Value)
        $lines  = Get-Content $IniPath -Encoding UTF8
        $inSect = $false
        $found  = $false
        $result = @()
        foreach ($line in $lines) {
            if ($line -match '^\[(.+)\]$') {
                $inSect = ($matches[1] -eq $Section)
            }
            if ($inSect -and $line -match "^\s*$([regex]::Escape($Key))\s*=") {
                $result += "$Key = $Value"
                $found   = $true
                continue
            }
            $result += $line
        }
        if (-not $found) {
            Write-Warning "ConfigForm: Schluessel '$Key' in [$Section] nicht gefunden - uebersprungen."
        } else {
            Set-Content -Path $IniPath -Value $result -Encoding UTF8
        }
    }

    function _IniVal {
        param([string]$s, [string]$k, [string]$d = '')
        if ($ini.ContainsKey($s) -and $ini[$s].ContainsKey($k)) { return $ini[$s][$k] }
        return $d
    }

    # ---------------------------------------------------------------------------
    # Hilfsfunktionen GUI (lokal deklariert - Standalone-faehig)
    # ---------------------------------------------------------------------------
    function _Lbl {
        param($P, $T, $X, $Y, $W = 160, $H = 20)
        $l           = New-Object System.Windows.Forms.Label
        $l.Text      = $T
        $l.Location  = New-Object System.Drawing.Point($X, $Y)
        $l.Size      = New-Object System.Drawing.Size($W, $H)
        $l.TextAlign = 'MiddleLeft'
        $P.Controls.Add($l)
        return $l
    }

    function _Tb {
        param($P, $X, $Y, $W = 340, $Def = '', $Enabled = $true)
        $t          = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point($X, $Y)
        $t.Size     = New-Object System.Drawing.Size($W, 24)
        $t.Text     = $Def
        $t.Enabled  = $Enabled
        $P.Controls.Add($t)
        return $t
    }

    function _Btn {
        param($P, $T, $X, $Y, $W = 90, $H = 26)
        $b          = New-Object System.Windows.Forms.Button
        $b.Text     = $T
        $b.Location = New-Object System.Drawing.Point($X, $Y)
        $b.Size     = New-Object System.Drawing.Size($W, $H)
        $P.Controls.Add($b)
        return $b
    }

    function _Chk {
        param($P, $T, $X, $Y, $Checked = $false, $W = 200)
        $c          = New-Object System.Windows.Forms.CheckBox
        $c.Text     = $T
        $c.Location = New-Object System.Drawing.Point($X, $Y)
        $c.Size     = New-Object System.Drawing.Size($W, 20)
        $c.Checked  = $Checked
        $P.Controls.Add($c)
        return $c
    }

    function _Gb {
        param($P, $T, $X, $Y, $W, $H)
        $g          = New-Object System.Windows.Forms.GroupBox
        $g.Text     = $T
        $g.Location = New-Object System.Drawing.Point($X, $Y)
        $g.Size     = New-Object System.Drawing.Size($W, $H)
        $P.Controls.Add($g)
        return $g
    }

    function _BrowseBtn {
        param($P, $X, $Y, $Tb)
        $b = _Btn -P $P -T '...' -X $X -Y $Y -W 30 -H 24
        $tbRef = $Tb
        $b.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Ordner auswaehlen'
            if ($tbRef.Text -ne '' -and (Test-Path $tbRef.Text -ErrorAction SilentlyContinue)) {
                $dlg.SelectedPath = $tbRef.Text
            }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $tbRef.Text = $dlg.SelectedPath
            }
        })
        return $b
    }

    function _StartBgScript {
        <#
        Fuehrt ein PS-Skript als Kindprozess in einem Runspace aus.
        Alle Ausgaben gehen zeilenweise in $LogBox.
        $DoneCb ist ein ScriptBlock der im GUI-Thread nach Abschluss ausgefuehrt wird.
        #>
        param(
            [System.Windows.Forms.Form]$Form,
            [System.Windows.Forms.RichTextBox]$LogBox,
            [string[]]$ArgList,
            [scriptblock]$DoneCb
        )

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('_form',   $Form)
        $rs.SessionStateProxy.SetVariable('_logBox', $LogBox)
        $rs.SessionStateProxy.SetVariable('_args',   $ArgList)
        $rs.SessionStateProxy.SetVariable('_doneCb', $DoneCb)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            $output = & powershell.exe @_args 2>&1
            foreach ($line in $output) {
                $lineStr = $line.ToString()
                $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                    $_logBox.AppendText("$lineStr`n")
                    $_logBox.ScrollToCaret()
                })
            }
            $_form.Invoke([System.Windows.Forms.MethodInvoker]$_doneCb)
        }) | Out-Null

        $ps.BeginInvoke() | Out-Null
    }

    # ---------------------------------------------------------------------------
    # INI einlesen
    # ---------------------------------------------------------------------------
    $ini       = _ReadIni -Path $IniPath
    $scriptDir = Split-Path (Split-Path $IniPath -Parent) -Parent   # <ToolRoot>

    # ---------------------------------------------------------------------------
    # Formular
    # ---------------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'SQL Server Setup Tool - Konfiguration'
    $form.Size            = New-Object System.Drawing.Size(870, 720)
    $form.MinimumSize     = New-Object System.Drawing.Size(870, 680)
    $form.StartPosition   = 'CenterParent'
    $form.FormBorderStyle = 'Sizable'

    # TabControl
    $tabs          = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(10, 10)
    $tabs.Size     = New-Object System.Drawing.Size(835, 620)
    $tabs.Anchor   = 'Top,Bottom,Left,Right'
    $form.Controls.Add($tabs)

    # Footer
    $btnSave          = New-Object System.Windows.Forms.Button
    $btnSave.Text     = 'Speichern'
    $btnSave.Location = New-Object System.Drawing.Point(645, 648)
    $btnSave.Size     = New-Object System.Drawing.Size(105, 30)
    $btnSave.Anchor   = 'Bottom,Right'
    $form.Controls.Add($btnSave)

    $btnCancel          = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Abbrechen'
    $btnCancel.Location = New-Object System.Drawing.Point(758, 648)
    $btnCancel.Size     = New-Object System.Drawing.Size(95, 30)
    $btnCancel.Anchor   = 'Bottom,Right'
    $form.Controls.Add($btnCancel)

    # =========================================================================
    # TAB 1: Quellpfade
    # =========================================================================
    $tab1      = New-Object System.Windows.Forms.TabPage
    $tab1.Text = 'Quellpfade'
    $tabs.TabPages.Add($tab1)

    $pnl1            = New-Object System.Windows.Forms.Panel
    $pnl1.Dock       = 'Fill'
    $pnl1.AutoScroll = $true
    $tab1.Controls.Add($pnl1)

    # -- Allgemein --
    $gbGen = _Gb -P $pnl1 -T 'Allgemein & Installationsquellen' -X 5 -Y 5 -W 800 -H 87
    _Lbl -P $gbGen -T 'SourceShare:' -X 10 -Y 24 -W 130
    $tbSourceShare = _Tb  -P $gbGen -X 145 -Y 22 -W 575 -Def (_IniVal 'General' 'SourceShare')
    _BrowseBtn -P $gbGen -X 725 -Y 22 -Tb $tbSourceShare | Out-Null
    _Lbl -P $gbGen -T 'Versionen (kommagetrennt):' -X 10 -Y 56 -W 195
    $tbVersions = _Tb -P $gbGen -X 210 -Y 54 -W 220 -Def (_IniVal 'Versions' 'Available' '2019,2022,2025')

    # -- PowerShell Module --
    $gbMod = _Gb -P $pnl1 -T 'PowerShell Module' -X 5 -Y 102 -W 800 -H 87
    _Lbl -P $gbMod -T 'dbaTools ShareBasePath:' -X 10 -Y 24 -W 180
    $tbDbaTools = _Tb -P $gbMod -X 195 -Y 22 -W 525 -Def (_IniVal 'dbaTools' 'ShareBasePath')
    _BrowseBtn -P $gbMod -X 725 -Y 22 -Tb $tbDbaTools | Out-Null
    _Lbl -P $gbMod -T 'sqmSQLTool ShareBasePath:' -X 10 -Y 56 -W 180
    $tbSqm = _Tb -P $gbMod -X 195 -Y 54 -W 525 -Def (_IniVal 'sqmSQLTool' 'ShareBasePath')
    _BrowseBtn -P $gbMod -X 725 -Y 54 -Tb $tbSqm | Out-Null

    # -- Treiber --
    $gbDrv = _Gb -P $pnl1 -T 'Treiber-Installation' -X 5 -Y 199 -W 800 -H 148
    $chkJDBC  = _Chk -P $gbDrv -T 'JDBC'  -X 10 -Y 22 -Checked ((_IniVal 'Drivers' 'JDBC_Enabled')  -eq 'true') -W 60
    $tbJDBC   = _Tb  -P $gbDrv -X 75 -Y 20 -W 645 -Def (_IniVal 'Drivers' 'JDBC_SourcePath')
    _BrowseBtn -P $gbDrv -X 725 -Y 20 -Tb $tbJDBC | Out-Null
    $chkODBC  = _Chk -P $gbDrv -T 'ODBC'  -X 10 -Y 50 -Checked ((_IniVal 'Drivers' 'ODBC_Enabled')  -eq 'true') -W 60
    $tbODBC   = _Tb  -P $gbDrv -X 75 -Y 48 -W 645 -Def (_IniVal 'Drivers' 'ODBC_SourcePath')
    _BrowseBtn -P $gbDrv -X 725 -Y 48 -Tb $tbODBC | Out-Null
    $chkOLEDB = _Chk -P $gbDrv -T 'OLEDB' -X 10 -Y 78 -Checked ((_IniVal 'Drivers' 'OLEDB_Enabled') -eq 'true') -W 60
    $tbOLEDB  = _Tb  -P $gbDrv -X 75 -Y 76 -W 645 -Def (_IniVal 'Drivers' 'OLEDB_SourcePath')
    _BrowseBtn -P $gbDrv -X 725 -Y 76 -Tb $tbOLEDB | Out-Null
    $chkDB2   = _Chk -P $gbDrv -T 'DB2'   -X 10 -Y 106 -Checked ((_IniVal 'Drivers' 'DB2_Enabled')   -eq 'true') -W 60
    $tbDB2    = _Tb  -P $gbDrv -X 75 -Y 104 -W 645 -Def (_IniVal 'Drivers' 'DB2_SourcePath')
    _BrowseBtn -P $gbDrv -X 725 -Y 104 -Tb $tbDB2 | Out-Null

    # -- Optionale Komponenten --
    $gbOpt = _Gb -P $pnl1 -T 'Optionale Komponenten' -X 5 -Y 357 -W 800 -H 170
    $chkSSRS = _Chk -P $gbOpt -T 'SSRS' -X 10 -Y 22 -Checked ((_IniVal 'OptionalComponents' 'SSRS_Enabled') -eq 'true') -W 60
    $tbSSRS  = _Tb  -P $gbOpt -X 75 -Y 20 -W 645 -Def (_IniVal 'OptionalComponents' 'SSRS_SourcePath')
    _BrowseBtn -P $gbOpt -X 725 -Y 20 -Tb $tbSSRS | Out-Null
    $chkSSAS = _Chk -P $gbOpt -T 'SSAS (Analysis Services)'  -X 10 -Y 50 -Checked ((_IniVal 'OptionalComponents' 'SSAS_Enabled') -eq 'true') -W 220
    $chkSSMS = _Chk -P $gbOpt -T 'SSMS (Management Studio)' -X 10 -Y 78 -Checked ((_IniVal 'OptionalComponents' 'SSMS_Enabled') -eq 'true') -W 220
    $chkSSIS = _Chk -P $gbOpt -T 'SSIS (Integration Svc.)'  -X 10 -Y 106 -Checked ((_IniVal 'OptionalComponents' 'SSIS_Enabled') -eq 'true') -W 220
    $chkTDP  = _Chk -P $gbOpt -T 'TDP' -X 10 -Y 134 -Checked ((_IniVal 'OptionalComponents' 'TDP_Enabled') -eq 'true') -W 60
    $tbTDP   = _Tb  -P $gbOpt -X 75 -Y 132 -W 645 -Def (_IniVal 'OptionalComponents' 'TDP_SourcePath')
    _BrowseBtn -P $gbOpt -X 725 -Y 132 -Tb $tbTDP | Out-Null

    # -- Wartung & Scripts --
    $gbMaint = _Gb -P $pnl1 -T 'Wartung & Scripts' -X 5 -Y 537 -W 800 -H 122
    _Lbl -P $gbMaint -T 'OlaHallengren-Pfad:' -X 10 -Y 24 -W 145
    $tbOla = _Tb -P $gbMaint -X 160 -Y 22 -W 560 -Def (_IniVal 'Maintenance' 'OlaSourcePath')
    _BrowseBtn -P $gbMaint -X 725 -Y 22 -Tb $tbOla | Out-Null
    _Lbl -P $gbMaint -T 'SQL-Scripts-Pfad:' -X 10 -Y 54 -W 145
    $tbScripts = _Tb -P $gbMaint -X 160 -Y 52 -W 560 -Def (_IniVal 'PostInstall' 'SqlScriptsPath')
    _BrowseBtn -P $gbMaint -X 725 -Y 52 -Tb $tbScripts | Out-Null
    $chkSecpol = _Chk -P $gbMaint -T 'Secpol' -X 10 -Y 84 -Checked ((_IniVal 'Secpol' 'Enabled') -eq 'true') -W 70
    $tbSecpol  = _Tb  -P $gbMaint -X 85 -Y 82 -W 635 -Def (_IniVal 'Secpol' 'SourcePath')
    _BrowseBtn -P $gbMaint -X 725 -Y 82 -Tb $tbSecpol | Out-Null

    # =========================================================================
    # TAB 2: SQLSources anlegen
    # =========================================================================
    $tab2      = New-Object System.Windows.Forms.TabPage
    $tab2.Text = 'SQLSources anlegen'
    $tabs.TabPages.Add($tab2)

    # --- Standard ---
    $gbStd = _Gb -P $tab2 -T 'Standard-Variante (SourceShare aus Tab 1)' -X 5 -Y 5 -W 815 -H 115
    _Lbl -P $gbStd -T 'BasePath:' -X 10 -Y 24 -W 75
    $tbStdPath = _Tb -P $gbStd -X 90 -Y 22 -W 625 -Def (_IniVal 'General' 'SourceShare')
    _BrowseBtn -P $gbStd -X 720 -Y 22 -Tb $tbStdPath | Out-Null
    _Lbl -P $gbStd -T 'Versionen:' -X 10 -Y 56 -W 75
    $tbStdVer = _Tb -P $gbStd -X 90 -Y 54 -W 220 -Def (_IniVal 'Versions' 'Available' '2019,2022,2025')
    $chkStdUpdateIni = _Chk -P $gbStd -T 'UpdateIni - Pfade in settings.ini aktualisieren' -X 10 -Y 86 -W 340
    $btnStd   = _Btn -P $gbStd -T 'Struktur anlegen' -X 635 -Y 84 -W 145

    # --- FI-TS ---
    $gbFiTS = _Gb -P $tab2 -T 'FI-TS Variante (W:\75084-Datenbanken\MSSQL\SQLSources)' -X 5 -Y 130 -W 815 -H 148
    _Lbl -P $gbFiTS -T 'BasePath:' -X 10 -Y 24 -W 75
    $tbFiTSPath = _Tb -P $gbFiTS -X 90 -Y 22 -W 625 -Def 'W:\75084-Datenbanken\MSSQL\SQLSources'
    _BrowseBtn -P $gbFiTS -X 720 -Y 22 -Tb $tbFiTSPath | Out-Null
    _Lbl -P $gbFiTS -T 'Versionen:' -X 10 -Y 56 -W 75
    $tbFiTSVer = _Tb -P $gbFiTS -X 90 -Y 54 -W 220 -Def (_IniVal 'Versions' 'Available' '2019,2022,2025')
    $chkFiTSUpdateIni = _Chk -P $gbFiTS -T 'UpdateIni - W:\-Pfade in settings.ini schreiben' -X 10 -Y 86 -W 320
    $chkFiTSZip = _Chk -P $gbFiTS -T 'Als ZIP packen:' -X 10 -Y 114 -W 115
    $tbZipPath  = _Tb  -P $gbFiTS -X 128 -Y 112 -W 487 -Def 'C:\Temp\SQLSources-FiTS.zip' -Enabled $false
    $chkFiTSZip.Add_CheckedChanged({
        $tbZipPath.Enabled = $chkFiTSZip.Checked
    })
    $btnFiTS = _Btn -P $gbFiTS -T 'FiTS anlegen' -X 635 -Y 112 -W 145

    # --- Ausgabe ---
    $gbLog2          = _Gb -P $tab2 -T 'Ausgabe' -X 5 -Y 290 -W 815 -H 285
    $gbLog2.Anchor   = 'Top,Bottom,Left,Right'
    $cfgLogBox            = New-Object System.Windows.Forms.RichTextBox
    $cfgLogBox.Location   = New-Object System.Drawing.Point(10, 20)
    $cfgLogBox.Size       = New-Object System.Drawing.Size(790, 250)
    $cfgLogBox.ReadOnly   = $true
    $cfgLogBox.BackColor  = [System.Drawing.Color]::Black
    $cfgLogBox.ForeColor  = [System.Drawing.Color]::LightGreen
    $cfgLogBox.Font       = New-Object System.Drawing.Font('Consolas', 8.5)
    $cfgLogBox.ScrollBars = 'Vertical'
    $cfgLogBox.Anchor     = 'Top,Bottom,Left,Right'
    $gbLog2.Controls.Add($cfgLogBox)

    # Tab-Wechsel: Vorbelegung Versionen syncen
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedIndex -eq 1) {
            if ($tbStdPath.Text -eq '' -or $tbStdPath.Text -eq (_IniVal 'General' 'SourceShare')) {
                $tbStdPath.Text = $tbSourceShare.Text
            }
            $tbStdVer.Text  = $tbVersions.Text
            $tbFiTSVer.Text = $tbVersions.Text
        }
        if ($tabs.SelectedIndex -eq 2) {
            # DefaultVersion ComboBox bevoelkern
            $verList = $tbVersions.Text -split '\s*,\s*' | Where-Object { $_ -ne '' }
            $cbDefVer.Items.Clear()
            foreach ($v in $verList) { [void]$cbDefVer.Items.Add($v) }
            $current = $tbDefVer_hidden.Text
            if ($cbDefVer.Items.Contains($current)) {
                $cbDefVer.SelectedItem = $current
            } elseif ($cbDefVer.Items.Count -gt 0) {
                $cbDefVer.SelectedIndex = 0
            }
        }
    })

    # Standard-Struktur anlegen
    $btnStd.Add_Click({
        $scriptPath = Join-Path $scriptDir 'Scripts\New-SqlSourceStructure.ps1'
        if (-not (Test-Path $scriptPath)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Skript nicht gefunden:`n$scriptPath",
                'Fehler', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }
        $cfgLogBox.Clear()
        $btnStd.Enabled  = $false
        $btnFiTS.Enabled = $false

        $argList = [System.Collections.Generic.List[string]]@(
            '-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath,
            '-BasePath', $tbStdPath.Text.Trim(),
            '-Versions', $tbStdVer.Text.Trim(),
            '-Force'
        )
        if ($chkStdUpdateIni.Checked) {
            $argList.Add('-UpdateIni')
            $argList.Add('-IniPath')
            $argList.Add($IniPath)
        }

        _StartBgScript -Form $form -LogBox $cfgLogBox -ArgList $argList -DoneCb {
            $btnStd.Enabled  = $true
            $btnFiTS.Enabled = $true
        }
    })

    # FI-TS-Struktur anlegen (+ optionales ZIP)
    $btnFiTS.Add_Click({
        $scriptPath = Join-Path $scriptDir 'Scripts\New-SqlSourceStructure-FiTS.ps1'
        if (-not (Test-Path $scriptPath)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Skript nicht gefunden:`n$scriptPath",
                'Fehler', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        $doZip       = $chkFiTSZip.Checked
        $zipDest     = $tbZipPath.Text.Trim()
        $fitsBase    = $tbFiTSPath.Text.Trim()

        if ($doZip -and $zipDest -eq '') {
            [System.Windows.Forms.MessageBox]::Show(
                'Bitte ZIP-Zielpfad angeben.',
                'Fehler', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $cfgLogBox.Clear()
        $btnStd.Enabled  = $false
        $btnFiTS.Enabled = $false

        $argList = [System.Collections.Generic.List[string]]@(
            '-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath,
            '-BasePath', $fitsBase,
            '-Versions', $tbFiTSVer.Text.Trim(),
            '-Force'
        )
        if ($chkFiTSUpdateIni.Checked) {
            $argList.Add('-UpdateIni')
            $argList.Add('-IniPath')
            $argList.Add($IniPath)
        }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('_form',     $form)
        $rs.SessionStateProxy.SetVariable('_logBox',   $cfgLogBox)
        $rs.SessionStateProxy.SetVariable('_args',     ([string[]]$argList))
        $rs.SessionStateProxy.SetVariable('_doZip',    $doZip)
        $rs.SessionStateProxy.SetVariable('_zipDest',  $zipDest)
        $rs.SessionStateProxy.SetVariable('_fitsBase', $fitsBase)
        $rs.SessionStateProxy.SetVariable('_btnStd',   $btnStd)
        $rs.SessionStateProxy.SetVariable('_btnFiTS',  $btnFiTS)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            $output = & powershell.exe @_args 2>&1
            foreach ($line in $output) {
                $lineStr = $line.ToString()
                $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                    $_logBox.AppendText("$lineStr`n")
                    $_logBox.ScrollToCaret()
                })
            }
            if ($_doZip) {
                $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                    $_logBox.AppendText("Erstelle ZIP: $_zipDest`n")
                    $_logBox.ScrollToCaret()
                })
                try {
                    if (Test-Path $_zipDest) { Remove-Item $_zipDest -Force }
                    Compress-Archive -Path "$_fitsBase\*" -DestinationPath $_zipDest -ErrorAction Stop
                    $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                        $_logBox.AppendText("ZIP erstellt: $_zipDest`n")
                        $_logBox.ScrollToCaret()
                    })
                } catch {
                    $errMsg = $_.Exception.Message
                    $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                        $_logBox.AppendText("FEHLER ZIP: $errMsg`n")
                        $_logBox.ScrollToCaret()
                    })
                }
            }
            $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                $_btnStd.Enabled  = $true
                $_btnFiTS.Enabled = $true
            })
        }) | Out-Null
        $ps.BeginInvoke() | Out-Null
    })

    # =========================================================================
    # TAB 3: Instanz-Defaults
    # =========================================================================
    $tab3      = New-Object System.Windows.Forms.TabPage
    $tab3.Text = 'Instanz-Defaults'
    $tabs.TabPages.Add($tab3)

    # -- Defaults --
    $gbDef = _Gb -P $tab3 -T 'Instanz-Vorgaben' -X 5 -Y 5 -W 815 -H 145
    _Lbl -P $gbDef -T 'Standard-Version:' -X 10 -Y 24 -W 145
    # Verstecktes TextBox speichert den INI-Wert zum Vergleich bei Tab-Wechsel
    $tbDefVer_hidden      = New-Object System.Windows.Forms.TextBox
    $tbDefVer_hidden.Text = (_IniVal 'General' 'DefaultVersion' '2022')
    $tbDefVer_hidden.Visible = $false
    $tab3.Controls.Add($tbDefVer_hidden)

    $cbDefVer          = New-Object System.Windows.Forms.ComboBox
    $cbDefVer.Location = New-Object System.Drawing.Point(160, 22)
    $cbDefVer.Size     = New-Object System.Drawing.Size(140, 24)
    $cbDefVer.DropDownStyle = 'DropDownList'
    # Vorbefuellen mit Versionen aus INI
    $initVers = (_IniVal 'Versions' 'Available' '2019,2022,2025') -split '\s*,\s*' | Where-Object { $_ -ne '' }
    foreach ($v in $initVers) { [void]$cbDefVer.Items.Add($v) }
    $defVer = _IniVal 'General' 'DefaultVersion' '2022'
    if ($cbDefVer.Items.Contains($defVer)) { $cbDefVer.SelectedItem = $defVer }
    elseif ($cbDefVer.Items.Count -gt 0)   { $cbDefVer.SelectedIndex = 0 }
    $tab3.Controls.Add($cbDefVer)

    _Lbl -P $gbDef -T 'Standard-Edition:' -X 10 -Y 56 -W 145
    $tbDefEd  = _Tb -P $gbDef -X 160 -Y 54 -W 200 -Def (_IniVal 'General' 'DefaultEdition' 'Developer')
    _Lbl -P $gbDef -T 'Instanzname:' -X 10 -Y 88 -W 145
    $tbDefInst = _Tb -P $gbDef -X 160 -Y 86 -W 200 -Def (_IniVal 'General' 'DefaultInstanceName' 'MSSQLServer')
    _Lbl -P $gbDef -T 'Sortierung:' -X 10 -Y 120 -W 145
    $tbDefColl = _Tb -P $gbDef -X 160 -Y 118 -W 360 -Def (_IniVal 'General' 'DefaultCollation' 'Latin1_General_CI_AS')

    # -- Ports --
    $gbPorts = _Gb -P $tab3 -T 'TCP-Ports' -X 5 -Y 160 -W 815 -H 90
    _Lbl -P $gbPorts -T 'BasePort:' -X 10 -Y 24 -W 100
    $tbBasePort = _Tb -P $gbPorts -X 115 -Y 22 -W 80 -Def (_IniVal 'Ports' 'BasePort' '1433')
    _Lbl -P $gbPorts -T 'BrowserPort:' -X 210 -Y 24 -W 100
    $tbBrwPort  = _Tb -P $gbPorts -X 315 -Y 22 -W 80 -Def (_IniVal 'Ports' 'BrowserPort' '1434')
    _Lbl -P $gbPorts -T 'PortIncrement:' -X 410 -Y 24 -W 110
    $tbPortIncr = _Tb -P $gbPorts -X 525 -Y 22 -W 80 -Def (_IniVal 'Ports' 'PortIncrement' '10')
    _Lbl -P $gbPorts -T '(Named Instance N = BasePort + N * Increment)' -X 10 -Y 56 -W 450

    # -- PreInstall --
    $gbPre = _Gb -P $tab3 -T 'Pre-Install Pruefungen' -X 5 -Y 260 -W 815 -H 80
    $chkFormat64k = _Chk -P $gbPre -T 'NTFS 64k-Format-Check (alle konfigurierten Laufwerke)' `
        -X 10 -Y 22 -Checked ((_IniVal 'PreInstall' 'Format64kCheck') -ne 'false') -W 500
    $chkSnapshot  = _Chk -P $gbPre -T 'Snapshot-Hinweis vor Installation anzeigen' `
        -X 10 -Y 50 -Checked ((_IniVal 'PreInstall' 'SnapshotEnabled') -eq 'true') -W 400

    # =========================================================================
    # Speichern-Handler
    # =========================================================================
    $btnSave.Add_Click({
        try {
            # --- Tab 1: Quellpfade ---
            _UpdateIni -IniPath $IniPath -Section 'General'   -Key 'SourceShare'  -Value $tbSourceShare.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'Versions'  -Key 'Available'    -Value $tbVersions.Text.Trim()

            _UpdateIni -IniPath $IniPath -Section 'dbaTools'   -Key 'ShareBasePath' -Value $tbDbaTools.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'sqmSQLTool' -Key 'ShareBasePath' -Value $tbSqm.Text.Trim()

            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'JDBC_Enabled'   -Value ($chkJDBC.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'JDBC_SourcePath' -Value $tbJDBC.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'ODBC_Enabled'   -Value ($chkODBC.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'ODBC_SourcePath' -Value $tbODBC.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'OLEDB_Enabled'  -Value ($chkOLEDB.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'OLEDB_SourcePath' -Value $tbOLEDB.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'DB2_Enabled'    -Value ($chkDB2.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'DB2_SourcePath'  -Value $tbDB2.Text.Trim()

            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSRS_Enabled'   -Value ($chkSSRS.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSRS_SourcePath' -Value $tbSSRS.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSAS_Enabled'   -Value ($chkSSAS.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSMS_Enabled'   -Value ($chkSSMS.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSIS_Enabled'   -Value ($chkSSIS.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'TDP_Enabled'    -Value ($chkTDP.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'TDP_SourcePath'  -Value $tbTDP.Text.Trim()

            _UpdateIni -IniPath $IniPath -Section 'Maintenance' -Key 'OlaSourcePath'  -Value $tbOla.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'PostInstall' -Key 'SqlScriptsPath' -Value $tbScripts.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'Secpol'      -Key 'Enabled'        -Value ($chkSecpol.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'Secpol'      -Key 'SourcePath'     -Value $tbSecpol.Text.Trim()

            # --- Tab 3: Instanz-Defaults ---
            $selVer = if ($cbDefVer.SelectedItem) { $cbDefVer.SelectedItem.ToString() } else { '' }
            if ($selVer -ne '') {
                _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultVersion'      -Value $selVer
            }
            _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultEdition'      -Value $tbDefEd.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultInstanceName'  -Value $tbDefInst.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultCollation'     -Value $tbDefColl.Text.Trim()

            _UpdateIni -IniPath $IniPath -Section 'Ports' -Key 'BasePort'      -Value $tbBasePort.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'Ports' -Key 'BrowserPort'   -Value $tbBrwPort.Text.Trim()
            _UpdateIni -IniPath $IniPath -Section 'Ports' -Key 'PortIncrement' -Value $tbPortIncr.Text.Trim()

            _UpdateIni -IniPath $IniPath -Section 'PreInstall' -Key 'Format64kCheck'  -Value ($chkFormat64k.Checked.ToString().ToLower())
            _UpdateIni -IniPath $IniPath -Section 'PreInstall' -Key 'SnapshotEnabled' -Value ($chkSnapshot.Checked.ToString().ToLower())

            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Fehler beim Speichern:`n$($_.Exception.Message)",
                'Fehler', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $btnCancel.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })

    # ---------------------------------------------------------------------------
    # Dialog anzeigen
    # ---------------------------------------------------------------------------
    $result = $form.ShowDialog()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}
