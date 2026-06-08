#Requires -Version 5.1
<#
.SYNOPSIS
    GUI/MainForm.ps1
    WinForms Hauptformular fuer das SQL-Server Setup-Tool.
    Wird von Main.ps1 aufgerufen. Benoetigt $script:Config (PSCustomObject aus Config.psm1).

    Threading-Konzept:
    - Lange Operationen (Robocopy, Installation) laufen in separatem Runspace
    - GUI-Updates erfolgen ausschliesslich ueber Control.Invoke() - thread-safe
    - ProgressBar laeuft im Marquee-Modus waehrend Operationen aktiv sind
    - BringToFront wird im Form_Shown-Event ausgefuehrt

    Stand: April 2025
    Anpassungen gegenueber v6:
    - Config.CurrentDomain  -> Config.Domain
    - Config.EditionsStandard / Config.Editions2025 -> Config.EditionMap (OrderedDictionary)
    - Config.CollationDomain -> abgeleitet aus Config.Domain + INI (nicht mehr eigenes Property)
    - Config.OptionalComponents.SSRS.Enabled -> Config.OptionalComponents['SSRS_Enabled'] -eq 'true'
    - Config.OptionalComponents.SSRS.SourcePath -> Config.OptionalComponents['SSRS_SourcePath']
    - Config.SqlSubPaths -> Config.Paths
    - Config.PostInstallScriptPathAbsolute -> Config.PostInstallScript
    - Funktionsname Copy-SqlSources -> Copy-SqlSource
    - Funktionsname Copy-OptionalComponentSource -> Copy-ComponentSource
    - Funktionsname Install-SqlInstance -> Invoke-SqlInstallation
    - New-WorkerBlock: Funktionsliste aktualisiert
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region --- Hilfsfunktionen GUI ---

function Add-Label {
    param($Parent, $Text, $X, $Y, $Width = 160, $Height = 20)
    $lbl           = New-Object System.Windows.Forms.Label
    $lbl.Text      = $Text
    $lbl.Location  = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size      = New-Object System.Drawing.Size($Width, $Height)
    $lbl.TextAlign = 'MiddleLeft'
    $Parent.Controls.Add($lbl)
    return $lbl
}

function Add-ComboBox {
    param($Parent, $X, $Y, $Width = 220, $Items = @(), $Default = '')
    $cb               = New-Object System.Windows.Forms.ComboBox
    $cb.Location      = New-Object System.Drawing.Point($X, $Y)
    $cb.Size          = New-Object System.Drawing.Size($Width, 24)
    $cb.DropDownStyle = 'DropDownList'
    foreach ($item in $Items) { [void]$cb.Items.Add($item) }
    if ($Default -ne '' -and $cb.Items.Contains($Default)) {
        $cb.SelectedItem = $Default
    }
    elseif ($cb.Items.Count -gt 0) {
        $cb.SelectedIndex = 0
    }
    $Parent.Controls.Add($cb)
    return $cb
}

function Add-TextBox {
    param($Parent, $X, $Y, $Width = 220, $Default = '', $IsPassword = $false)
    $tb          = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point($X, $Y)
    $tb.Size     = New-Object System.Drawing.Size($Width, 24)
    $tb.Text     = $Default
    if ($IsPassword) { $tb.PasswordChar = '*' }
    $Parent.Controls.Add($tb)
    return $tb
}

function Add-Button {
    param($Parent, $Text, $X, $Y, $Width = 90, $Height = 26)
    $btn          = New-Object System.Windows.Forms.Button
    $btn.Text     = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size     = New-Object System.Drawing.Size($Width, $Height)
    $Parent.Controls.Add($btn)
    return $btn
}

function Add-CheckBox {
    param($Parent, $Text, $X, $Y, $Checked = $false)
    $chk          = New-Object System.Windows.Forms.CheckBox
    $chk.Text     = $Text
    $chk.Location = New-Object System.Drawing.Point($X, $Y)
    $chk.Size     = New-Object System.Drawing.Size(220, 20)
    $chk.Checked  = $Checked
    $Parent.Controls.Add($chk)
    return $chk
}

function Add-GroupBox {
    param($Parent, $Text, $X, $Y, $Width, $Height)
    $gb          = New-Object System.Windows.Forms.GroupBox
    $gb.Text     = $Text
    $gb.Location = New-Object System.Drawing.Point($X, $Y)
    $gb.Size     = New-Object System.Drawing.Size($Width, $Height)
    $Parent.Controls.Add($gb)
    return $gb
}

# Berechnet TCP-Port aus Instanzname, BasePort und PortIncrement
function Get-TcpPortForInstance {
    param(
        [string]$InstanceName,
        [int]$BasePort      = 1433,
        [int]$PortIncrement = 10
    )
    if ([string]::IsNullOrWhiteSpace($InstanceName) -or
        $InstanceName -eq 'MSSQLSERVER') {
        return $BasePort
    }
    if ($InstanceName -match '(\d+)') {
        $n = [int]$matches[1]
        return $BasePort + ($n * $PortIncrement)
    }
    # Named instance ohne Nummer: erste freie Port-Stufe
    return $BasePort + $PortIncrement
}

# Write-Log: thread-sicher via Invoke wenn noetig
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line      = "[$timestamp] $Message`r`n"
    $logBox    = $script:LogBox
    if ($logBox.InvokeRequired) {
        $logBox.Invoke([System.Windows.Forms.MethodInvoker]{ $logBox.AppendText($line); $logBox.ScrollToCaret() })
    } else {
        $logBox.AppendText($line)
        $logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# Progress-Steuerung: thread-sicher
function Start-Progress {
    param([string]$StatusText = 'Bitte warten...')
    $form = $script:MainForm
    $bar  = $script:ProgressBar
    $lbl  = $script:StatusLabel
    if ($form.InvokeRequired) {
        $form.Invoke([System.Windows.Forms.MethodInvoker]{
            $bar.Style   = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $bar.Visible = $true
            $lbl.Text    = $StatusText
        })
    } else {
        $bar.Style   = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $bar.Visible = $true
        $lbl.Text    = $StatusText
    }
}

function Stop-Progress {
    param([string]$StatusText = 'Bereit.')
    $form = $script:MainForm
    $bar  = $script:ProgressBar
    $lbl  = $script:StatusLabel
    if ($form.InvokeRequired) {
        $form.Invoke([System.Windows.Forms.MethodInvoker]{
            $bar.Style   = [System.Windows.Forms.ProgressBarStyle]::Blocks
            $bar.Value   = 0
            $bar.Visible = $false
            $lbl.Text    = $StatusText
        })
    } else {
        $bar.Style   = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $bar.Value   = 0
        $bar.Visible = $false
        $lbl.Text    = $StatusText
    }
}

# Controls sperren/freigeben: thread-sicher
function Set-ControlsEnabled {
    param([bool]$Enabled)
    $form        = $script:MainForm
    $enableBlock = {
        $script:BtnInstall.Enabled  = $Enabled
        $script:BtnCopy.Enabled     = $Enabled
        $script:BtnClose.Enabled    = $Enabled
        $script:CbVersion.Enabled   = $Enabled
        $script:CbEdition.Enabled   = $Enabled
        $script:CbCollation.Enabled = $Enabled
        $script:TbInstance.Enabled  = $Enabled
        $script:TbAccount.Enabled   = $Enabled
        $script:TbPassword.Enabled  = $Enabled
        $script:BtnCheckAD.Enabled  = $Enabled
    }
    if ($form.InvokeRequired) {
        $form.Invoke([System.Windows.Forms.MethodInvoker]$enableBlock)
    } else {
        & $enableBlock
    }
}

# Runspace-basierter Hintergrundthread
function Start-BackgroundJob {
    param(
        [scriptblock]$Work,
        [hashtable]$Variables = @{}
    )

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    foreach ($kv in $Variables.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Work)

    $handle = $ps.BeginInvoke()

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        if ($handle.IsCompleted) {
            $timer.Stop()
            try   { $ps.EndInvoke($handle) }
            catch { Write-Log "Hintergrundthread Fehler: $_" }
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    })
    $timer.Start()

    return $timer
}

# ---------------------------------------------------------------------------
# Invoke-PathValidation: Prüft alle konfigurierten Pfade beim Start.
# Disabled betroffene Checkboxen und schreibt Warnungen ins Log.
# Gibt $true zurück wenn SourceShare erreichbar (Installation möglich).
# ---------------------------------------------------------------------------
function Invoke-PathValidation {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $sourceShareOk = $true

    # --- SourceShare (kritisch fuer Quellen-Kopie und Installation) ---
    if ($Config.SourceShare -and $Config.SourceShare -ne '') {
        if (-not (Test-Path -Path $Config.SourceShare -ErrorAction SilentlyContinue)) {
            Write-Log "WARNUNG: SourceShare nicht erreichbar: $($Config.SourceShare)"
            Write-Log "         'Quellen kopieren' und 'Installation starten' sind deaktiviert."
            $script:BtnCopy.Enabled    = $false
            $script:BtnInstall.Enabled = $false
            $sourceShareOk = $false
        }
        else {
            Write-Log "OK: SourceShare erreichbar: $($Config.SourceShare)"
        }
    }
    else {
        Write-Log "WARNUNG: SourceShare nicht konfiguriert (settings.ini [General] SourceShare)."
        $script:BtnCopy.Enabled    = $false
        $script:BtnInstall.Enabled = $false
        $sourceShareOk = $false
    }

    # --- dbaTools-Share (kritisch fuer Installation) ---
    if ($Config.DbaTools) {
        $dbaPath = $Config.DbaTools.ShareBasePath
        if ($dbaPath -and -not (Test-Path -Path $dbaPath -ErrorAction SilentlyContinue)) {
            Write-Log "WARNUNG: dbaTools-Share nicht erreichbar: $dbaPath"
            Write-Log "         Installation möglicherweise nicht möglich (kein lokales dbaTools)."
        }
        else {
            Write-Log "OK: dbaTools-Share erreichbar: $dbaPath"
        }
    }
    else {
        Write-Log "INFO: dbaTools-Share nicht konfiguriert - verwende lokale Installation oder Gallery."
    }

    # --- sqmSQLTool-Share (kritisch fuer PostInstall) ---
    if ($Config.sqmSQLTool) {
        $sqmPath = $Config.sqmSQLTool.ShareBasePath
        if ($sqmPath -and -not (Test-Path -Path $sqmPath -ErrorAction SilentlyContinue)) {
            Write-Log "WARNUNG: sqmSQLTool-Share nicht erreichbar: $sqmPath"
            Write-Log "         PostInstall-Funktionen (Monitoring, Ola, etc.) nicht verfuegbar."
        }
        else {
            Write-Log "OK: sqmSQLTool-Share erreichbar: $sqmPath"
        }
    }

    # --- Optionale Komponenten ---

    # SSRS
    if ($null -ne $script:ChkSSRS) {
        $ssrsPath = $Config.OptionalComponents['SSRS_SourcePath']
        if ($ssrsPath -and $ssrsPath -ne '') {
            if (-not (Test-Path -Path $ssrsPath -ErrorAction SilentlyContinue)) {
                Write-Log "WARNUNG: SSRS-Quellpfad nicht erreichbar: $ssrsPath"
                Write-Log "         Checkbox 'SSRS' wurde deaktiviert."
                $script:ChkSSRS.Checked = $false
                $script:ChkSSRS.Enabled = $false
                $script:ChkSSRS.Text    = 'SSRS (Reporting Services) - Pfad nicht erreichbar'
            }
            else {
                Write-Log "OK: SSRS-Quellpfad erreichbar: $ssrsPath"
            }
        }
        # Kein SourcePath konfiguriert: kein separater Check noetig (wird aus SourceShare kopiert)
    }

    # TDP
    if ($null -ne $script:ChkTDP) {
        $tdpPath = $Config.OptionalComponents['TDP_SourcePath']
        if ($tdpPath -and $tdpPath -ne '') {
            if (-not (Test-Path -Path $tdpPath -ErrorAction SilentlyContinue)) {
                Write-Log "WARNUNG: TDP-Quellpfad nicht erreichbar: $tdpPath"
                Write-Log "         Checkbox 'TDP' wurde deaktiviert."
                $script:ChkTDP.Checked = $false
                $script:ChkTDP.Enabled = $false
                $script:ChkTDP.Text    = 'TDP - Pfad nicht erreichbar'
            }
            else {
                Write-Log "OK: TDP-Quellpfad erreichbar: $tdpPath"
            }
        }
        else {
            # TDP aktiviert aber kein Pfad konfiguriert
            Write-Log "WARNUNG: TDP aktiviert aber kein TDP_SourcePath konfiguriert."
            $script:ChkTDP.Checked = $false
            $script:ChkTDP.Enabled = $false
            $script:ChkTDP.Text    = 'TDP - Quellpfad fehlt in settings.ini'
        }
    }

    # --- Treiber-Quellpfade ---
    $driverMap = @(
        @{ Key = 'JDBC'; EnabledKey = 'JDBC_Enabled'; PathKey = 'JDBC_SourcePath'; Chk = { $script:ChkJDBC } },
        @{ Key = 'ODBC'; EnabledKey = 'ODBC_Enabled'; PathKey = 'ODBC_SourcePath'; Chk = { $script:ChkODBC } },
        @{ Key = 'DB2';  EnabledKey = 'DB2_Enabled';  PathKey = 'DB2_SourcePath';  Chk = { $script:ChkDB2  } }
    )
    foreach ($drv in $driverMap) {
        $chkCtrl = & $drv.Chk
        if ($null -eq $chkCtrl) { continue }
        $drvPath = $Config.Drivers[$drv.PathKey]
        if ($drvPath -and $drvPath -ne '') {
            if (-not (Test-Path -Path $drvPath -ErrorAction SilentlyContinue)) {
                Write-Log "WARNUNG: $($drv.Key)-Quellpfad nicht erreichbar: $drvPath"
                Write-Log "         Checkbox '$($drv.Key)' wurde deaktiviert."
                $chkCtrl.Checked = $false
                $chkCtrl.Enabled = $false
                $chkCtrl.Text    = "$($drv.Key) Driver - Pfad nicht erreichbar"
            }
            else {
                Write-Log "OK: $($drv.Key)-Quellpfad erreichbar: $drvPath"
            }
        }
        else {
            Write-Log "WARNUNG: $($drv.Key) aktiviert aber kein SourcePath konfiguriert."
            $chkCtrl.Checked = $false
            $chkCtrl.Enabled = $false
            $chkCtrl.Text    = "$($drv.Key) Driver - Quellpfad fehlt in settings.ini"
        }
    }

    # --- Ola Hallengren lokaler Fallback-Pfad ---
    if ($Config.OlaSourcePath -and $Config.OlaSourcePath -ne '') {
        if (-not (Test-Path -Path $Config.OlaSourcePath -ErrorAction SilentlyContinue)) {
            Write-Log "WARNUNG: OlaSourcePath nicht erreichbar: $($Config.OlaSourcePath)"
            Write-Log "         GitHub-Download wird als Fallback verwendet."
        }
        else {
            Write-Log "OK: OlaSourcePath erreichbar: $($Config.OlaSourcePath)"
        }
    }

    return $sourceShareOk
}

#endregion

#region --- Formular aufbauen ---

function Show-SetupForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $script:Config = $Config

    #--- Hauptformular ---
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'SQL Server Setup - Standardisierte Installation'
    $form.Size            = New-Object System.Drawing.Size(820, 980)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:MainForm      = $form

    #--- Statusleiste mit ProgressBar ---
    $statusBar                    = New-Object System.Windows.Forms.StatusStrip
    $script:StatusLabel           = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:StatusLabel.Text      = 'Bereit.'
    $script:StatusLabel.Spring    = $true
    $script:StatusLabel.TextAlign = 'MiddleLeft'

    $script:ProgressBar                       = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:ProgressBar.Style                 = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:ProgressBar.MarqueeAnimationSpeed = 30
    $script:ProgressBar.Size                  = New-Object System.Drawing.Size(160, 16)
    $script:ProgressBar.Visible               = $false

    [void]$statusBar.Items.Add($script:StatusLabel)
    [void]$statusBar.Items.Add($script:ProgressBar)
    $form.Controls.Add($statusBar)

    # -----------------------------------------------------------------------
    # Hilfsfunktion: Editions-Liste aus EditionMap fuer gewaehlte Version
    # Config.EditionMap ist ein OrderedDictionary:
    #   Key 'Standard'  -> Array fuer 2019/2022
    #   Key 'SQL2025'   -> Array fuer 2025
    # -----------------------------------------------------------------------
    function Get-EditionsForVersion {
        param([string]$Version)
        $key = "SQL$Version"
        if ($Config.EditionMap.Contains($key)) {
            return $Config.EditionMap[$key]
        }
        if ($Config.EditionMap.Contains('Standard')) {
            return $Config.EditionMap['Standard']
        }
        return @('Developer')
    }

    #=== GroupBox: SQL Server Version & Edition ===
    $gbVersion = Add-GroupBox -Parent $form -Text 'SQL Server Version & Edition' -X 10 -Y 10 -Width 780 -Height 70

    Add-Label -Parent $gbVersion -Text 'Version:' -X 10 -Y 22 -Width 80
    $script:CbVersion = Add-ComboBox -Parent $gbVersion -X 95 -Y 20 -Width 120 `
        -Items $Config.Versions -Default $Config.DefaultVersion

    Add-Label -Parent $gbVersion -Text 'Edition:' -X 240 -Y 22 -Width 70
    # Editionen werden initial fuer die DefaultVersion geladen
    $initEditions = Get-EditionsForVersion -Version $Config.DefaultVersion
    $script:CbEdition = Add-ComboBox -Parent $gbVersion -X 315 -Y 20 -Width 180 `
        -Items $initEditions -Default $Config.DefaultEdition

    # Domain-Anzeige: Config.Domain statt Config.CurrentDomain
    $domInfo = if ($Config.Domain) { "Domain: $($Config.Domain)" } else { 'Keine Domain erkannt' }
    Add-Label -Parent $gbVersion -Text $domInfo -X 520 -Y 22 -Width 230 -Height 20

    #=== GroupBox: Instanzname ===
    $gbInstance = Add-GroupBox -Parent $form -Text 'Instanzname' -X 10 -Y 90 -Width 780 -Height 80

    Add-Label -Parent $gbInstance -Text 'Instanzname:' -X 10 -Y 22 -Width 100
    $script:TbInstance       = Add-TextBox -Parent $gbInstance -X 115 -Y 20 -Width 200 `
                                           -Default $Config.DefaultInstanceName
    $script:BtnResetInstance = Add-Button  -Parent $gbInstance -Text 'Standard' -X 325 -Y 19 -Width 80
    Add-Label -Parent $gbInstance -Text '(Standard: MSSQLServer)' -X 415 -Y 22 -Width 200

    # TCP-Port-Anzeige (berechnet aus BasePort + Instanznummer * PortIncrement)
    Add-Label -Parent $gbInstance -Text 'TCP-Port:' -X 10 -Y 52 -Width 100
    $script:LblTcpPort = Add-Label -Parent $gbInstance -Text '' -X 115 -Y 52 -Width 200 -Height 20
    $script:LblTcpPort.ForeColor = [System.Drawing.Color]::DarkBlue
    $script:LblTcpPort.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    Add-Label -Parent $gbInstance -Text '(aus settings.ini [Ports])' -X 415 -Y 52 -Width 220

    #=== GroupBox: Sortierung ===
    $gbCollation = Add-GroupBox -Parent $form -Text 'Sortierung (Collation)' -X 10 -Y 180 -Width 780 -Height 60

    Add-Label -Parent $gbCollation -Text 'Sortierung:' -X 10 -Y 22 -Width 90
    $script:CbCollation = Add-ComboBox -Parent $gbCollation -X 105 -Y 20 -Width 320 `
        -Items $Config.CollationList -Default $Config.DefaultCollation

    # CollationDomain: in v5 Config nicht mehr als eigenes Property vorhanden.
    # Ableiten: wenn Domain gesetzt und DefaultCollation != Standard -> Domain-Vorgabe aktiv.
    $collHint = if ($Config.Domain -and
                    $Config.CollationList.Count -gt 0 -and
                    $Config.CollationList[0] -ne 'SQL_Latin1_General_CP1_CI_AS') {
        "Domain-Sortierung aktiv: $($Config.CollationList[0])"
    } else {
        'Standard-Sortierung'
    }
    Add-Label -Parent $gbCollation -Text $collHint -X 440 -Y 22 -Width 310

    #=== GroupBox: Service-Konto ===
    $gbAccount = Add-GroupBox -Parent $form -Text 'Service-Konto (leer = NT SERVICE\MSSQLSERVER)' `
                              -X 10 -Y 250 -Width 780 -Height 90

    Add-Label -Parent $gbAccount -Text 'Konto (DOMAIN\User):' -X 10 -Y 22 -Width 150
    $script:TbAccount  = Add-TextBox -Parent $gbAccount -X 165 -Y 20 -Width 250

    Add-Label -Parent $gbAccount -Text 'Passwort:' -X 10 -Y 54 -Width 150
    $script:TbPassword = Add-TextBox -Parent $gbAccount -X 165 -Y 52 -Width 250 -IsPassword $true

    $script:BtnCheckAD  = Add-Button -Parent $gbAccount -Text 'AD pruefen' -X 430 -Y 20 -Width 90
    $script:LblAdStatus = Add-Label  -Parent $gbAccount -Text '' -X 530 -Y 22 -Width 220

    #=== GroupBox: Plattenlayout ===
    $gbDisk = Add-GroupBox -Parent $form -Text 'Plattenlayout' -X 10 -Y 350 -Width 780 -Height 110

    $diskLayout = $Config.DiskLayout
    # Config.Domain statt Config.CurrentDomain
    $diskSource = if ($Config.Domain -and $Config.DiskLayout) {
        "Domain: $($Config.Domain)"
    } else {
        'Standard'
    }

    Add-Label -Parent $gbDisk -Text "Layout-Quelle: $diskSource" -X 10 -Y 18 -Width 300

    $drives = @(
        [PSCustomObject]@{ Label = 'Installation:'; Key = 'InstallDrive'; X = 10;  Y = 38 },
        [PSCustomObject]@{ Label = 'Daten:';        Key = 'DataDrive';    X = 10;  Y = 60 },
        [PSCustomObject]@{ Label = 'Log:';          Key = 'LogDrive';     X = 200; Y = 60 },
        [PSCustomObject]@{ Label = 'TempDB:';       Key = 'TempDrive';    X = 390; Y = 60 },
        [PSCustomObject]@{ Label = 'Backup:';       Key = 'BackupDrive';  X = 580; Y = 60 }
    )

    $script:DiskTextBoxes = @{}
    foreach ($d in $drives) {
        Add-Label -Parent $gbDisk -Text $d.Label -X $d.X -Y $d.Y -Width 70
        $driveTb = Add-TextBox -Parent $gbDisk -X ($d.X + 75) -Y ($d.Y - 2) -Width 40 `
                               -Default ($diskLayout[$d.Key] + ':')
        $script:DiskTextBoxes[$d.Key] = $driveTb
    }

    Add-Label -Parent $gbDisk -Text '(Laufwerksbuchstaben aus INI - je Domain konfigurierbar)' `
              -X 10 -Y 88 -Width 500

    #=== GroupBox: Monitoring ===
    $gbMonitor = Add-GroupBox -Parent $form -Text 'Monitoring' -X 10 -Y 470 -Width 780 -Height 60

    if ($Config.MonitoringEnabled) {
        Add-Label -Parent $gbMonitor -Text 'Monitoring-Typ:' -X 10 -Y 22 -Width 110
        # MonitoringDefault ist ein int; ToString() fuer ComboBox-Vergleich
        $script:CbMonitoring = Add-ComboBox -Parent $gbMonitor -X 125 -Y 20 -Width 160 `
            -Items $Config.MonitoringTypes -Default $Config.MonitoringDefault.ToString()
        # SelectedIndex explizit setzen - String-Match funktioniert nicht bei beschreibenden Namen
        if ($script:CbMonitoring.Items.Count -gt $Config.MonitoringDefault) {
            $script:CbMonitoring.SelectedIndex = $Config.MonitoringDefault
        }
        $monHint = if ($Config.Domain) {
            "Domain-Standard: $($Config.MonitoringDefault)"
        } else {
            "Standard: $($Config.MonitoringDefault)"
        }
        Add-Label -Parent $gbMonitor -Text $monHint -X 300 -Y 22 -Width 300
    }
    else {
        Add-Label -Parent $gbMonitor -Text 'Monitoring nicht konfiguriert (in INI deaktiviert).' `
                  -X 10 -Y 22 -Width 500
        $script:CbMonitoring = $null
    }

    #=== GroupBox: Optionale Komponenten ===
    # 2-Zeilen-Layout: Zeile 1 (Y=22) SSRS | SSAS | SSMS  /  Zeile 2 (Y=50) SSIS | TDP
    # Abstand 265px (Checkbox-Breite 220px + 45px Luft) = kein Ueberlappen
    $gbOpt = Add-GroupBox -Parent $form -Text 'Optionale Komponenten' -X 10 -Y 540 -Width 780 -Height 100

    $script:ChkSSRS = $null
    $script:ChkSSAS = $null
    $script:ChkSSMS = $null
    $script:ChkSSIS = $null
    $script:ChkTDP  = $null

    # Zeile 1: SSRS (X=10) | SSAS (X=275) | SSMS (X=540, Standard: gecheckt)
    if ($Config.OptionalComponents['SSRS_Enabled'] -eq 'true') {
        $script:ChkSSRS = Add-CheckBox -Parent $gbOpt -Text 'SSRS (Reporting Services)' -X 10  -Y 22
    }
    if ($Config.OptionalComponents['SSAS_Enabled'] -eq 'true') {
        $script:ChkSSAS = Add-CheckBox -Parent $gbOpt -Text 'SSAS (Analysis Services)'  -X 275 -Y 22
    }
    if ($Config.OptionalComponents['SSMS_Enabled'] -eq 'true') {
        $script:ChkSSMS = Add-CheckBox -Parent $gbOpt -Text 'SSMS (Management Studio)'  -X 540 -Y 22 -Checked $true
    }

    # Zeile 2: SSIS (X=10, Standard: gecheckt) | TDP (X=275)
    if ($Config.OptionalComponents['SSIS_Enabled'] -eq 'true') {
        $script:ChkSSIS = Add-CheckBox -Parent $gbOpt -Text 'SSIS (Integration Services)' -X 10  -Y 50 -Checked $true
    }
    if ($Config.OptionalComponents['TDP_Enabled'] -eq 'true') {
        $script:ChkTDP  = Add-CheckBox -Parent $gbOpt -Text 'TDP'                          -X 275 -Y 50
    }

    Add-Label -Parent $gbOpt -Text 'Sortierung fuer SSAS: identisch mit Instanz-Sortierung' `
              -X 10 -Y 76 -Width 500

    #=== GroupBox: Treiber-Installation (konditionell) ===
    $script:ChkJDBC = $null
    $script:ChkODBC = $null
    $script:ChkDB2  = $null

    $jdbcEnabled = ($Config.Drivers -and $Config.Drivers['JDBC_Enabled'] -eq 'true' -and $Config.Drivers['JDBC_SourcePath'] -ne '')
    $odbcEnabled = ($Config.Drivers -and $Config.Drivers['ODBC_Enabled'] -eq 'true' -and $Config.Drivers['ODBC_SourcePath'] -ne '')
    $db2Enabled  = ($Config.Drivers -and $Config.Drivers['DB2_Enabled']  -eq 'true' -and $Config.Drivers['DB2_SourcePath']  -ne '')

    $anyDriverConfigured = $jdbcEnabled -or $odbcEnabled -or $db2Enabled

    if ($anyDriverConfigured) {
        $gbDrivers = Add-GroupBox -Parent $form -Text 'Treiber-Installation' -X 10 -Y 650 -Width 780 -Height 80

        if ($jdbcEnabled) {
            $script:ChkJDBC = Add-CheckBox -Parent $gbDrivers -Text 'JDBC Driver (Microsoft SQL Server)' -X 10  -Y 22
        }
        if ($odbcEnabled) {
            $script:ChkODBC = Add-CheckBox -Parent $gbDrivers -Text 'ODBC Driver (Microsoft SQL Server)' -X 10  -Y 44
        }
        if ($db2Enabled) {
            $script:ChkDB2  = Add-CheckBox -Parent $gbDrivers -Text 'DB2 ODBC/CLI Driver (IBM)'          -X 400 -Y 22
        }

        $driverOffset = 90
    }
    else {
        $driverOffset = 0
    }

    #=== Aktions-Buttons ===
    $gbActions = Add-GroupBox -Parent $form -Text 'Aktionen' -X 10 -Y (650 + $driverOffset) -Width 780 -Height 50

    $script:BtnCopy    = Add-Button -Parent $gbActions -Text 'Quellen kopieren'    -X 10  -Y 15 -Width 140
    $script:BtnInstall = Add-Button -Parent $gbActions -Text 'Installation starten' -X 160 -Y 15 -Width 150
    $script:BtnConfig          = Add-Button -Parent $gbActions -Text 'Konfiguration...' -X 320 -Y 15 -Width 130
    $script:BtnConfig.Visible  = $false   # Nur ueber Start-AdminConfig.cmd erreichbar
    $script:BtnClose   = Add-Button -Parent $gbActions -Text 'Schliessen'          -X 680 -Y 15 -Width 90

    #=== Log-Fenster ===
    $gbLog = Add-GroupBox -Parent $form -Text 'Protokoll' -X 10 -Y (710 + $driverOffset) -Width 780 -Height 135

    $script:LogBox            = New-Object System.Windows.Forms.RichTextBox
    $script:LogBox.Location   = New-Object System.Drawing.Point(10, 18)
    $script:LogBox.Size       = New-Object System.Drawing.Size(755, 105)
    $script:LogBox.ReadOnly   = $true
    $script:LogBox.BackColor  = [System.Drawing.Color]::Black
    $script:LogBox.ForeColor  = [System.Drawing.Color]::LightGreen
    $script:LogBox.Font       = New-Object System.Drawing.Font('Consolas', 8.5)
    $script:LogBox.ScrollBars = 'Vertical'
    $gbLog.Controls.Add($script:LogBox)

    #region --- Hilfsfunktionen fuer Event-Handler ---

    function Get-DiskLayoutFromForm {
        $layout = @{}
        foreach ($key in $script:DiskTextBoxes.Keys) {
            $layout[$key] = $script:DiskTextBoxes[$key].Text.TrimEnd(':').Trim()
        }
        return $layout
    }

    function Invoke-ValidateInputs {
        $instResult = Test-InstanceName -InstanceName $script:TbInstance.Text.Trim()
        if (-not $instResult.IsValid) {
            [System.Windows.Forms.MessageBox]::Show(
                "Ungueltiger Instanzname:`n$($instResult.ErrorMessage)",
                'Validierungsfehler',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return $false
        }

        $layout  = Get-DiskLayoutFromForm
        $missing = Test-DiskLayout -DiskLayout $layout
        if ($missing.Count -gt 0) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Folgende Laufwerke wurden nicht gefunden:`n" + ($missing -join "`n") + "`n`nTrotzdem fortfahren?",
                'Laufwerke nicht gefunden',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
        }

        return $true
    }

    # Baut den vollstaendigen Worker-Scriptblock fuer den Hintergrundthread.
    # Modulfunktionen werden per ScriptBlock in den neuen Runspace kopiert.
    # Funktionsliste entspricht den tatsaechlichen Exporten der v5-Module.
    function New-WorkerBlock {
        param([scriptblock]$CoreWork)

        # Resolve module paths in main runspace where PSScriptRoot is set
        $toolRoot    = Split-Path $PSScriptRoot -Parent
        $modulesDir  = Join-Path $toolRoot 'Modules'

        # Build module import block - runs first in every worker runspace
        $moduleImports = @"
Import-Module sqmSQLTool -Force -ErrorAction Stop
Import-Module dbatools   -Force -ErrorAction Stop
Get-ChildItem '$modulesDir' -Filter '*.psm1' | ForEach-Object {
    Import-Module `$_.FullName -Force -ErrorAction SilentlyContinue
}
"@

        # Only GUI thread-safe helpers cannot be imported - copy them by definition
        $guiFunctions = @('Write-Log','Start-Progress','Stop-Progress','Set-ControlsEnabled')

        $funcDefs = foreach ($name in $guiFunctions) {
            $cmd = Get-Command $name -ErrorAction SilentlyContinue
            if ($cmd) { "function $name {`n$($cmd.ScriptBlock)`n}" }
        }

        $fullScript = $moduleImports + "`n`n" + ($funcDefs -join "`n`n") + "`n`n" + $CoreWork.ToString()
        return [scriptblock]::Create($fullScript)
    }

    #endregion

    #region --- Event-Handler ---

    # TbInstance TextChanged -> TCP-Port-Anzeige aktualisieren
    $script:TbInstance.Add_TextChanged({
        $inst      = $script:TbInstance.Text.Trim()
        $basePort  = if ($script:Config.BasePort -gt 0) { $script:Config.BasePort } else { 1433 }
        $portIncr  = if ($script:Config.PortIncrement -gt 0) { $script:Config.PortIncrement } else { 10 }
        $port      = Get-TcpPortForInstance -InstanceName $inst -BasePort $basePort -PortIncrement $portIncr
        $script:LblTcpPort.Text = "Port $port"
    })

    # Form_Shown: BringToFront + initiales Log + Pfadprüfung
    $form.Add_Shown({
        $form.BringToFront()
        $form.Activate()
        $domainInfo = if ($script:Config.Domain) { $script:Config.Domain } else { 'keine' }
        Write-Log 'SQL Server Setup Tool gestartet.'
        Write-Log "Konfiguration geladen. Domain: $domainInfo"
        Write-Log "Sortierung: $($script:Config.DefaultCollation)"

        # TCP-Port initial setzen
        $basePort = if ($script:Config.BasePort -gt 0) { $script:Config.BasePort } else { 1433 }
        $portIncr = if ($script:Config.PortIncrement -gt 0) { $script:Config.PortIncrement } else { 10 }
        $initPort = Get-TcpPortForInstance -InstanceName $script:Config.DefaultInstanceName `
                        -BasePort $basePort -PortIncrement $portIncr
        $script:LblTcpPort.Text = "Port $initPort"

        Write-Log '--- Pfad-Pruefung ---'
        $sourceOk = Invoke-PathValidation -Config $script:Config
        if ($sourceOk) {
            Write-Log '--- Pfad-Pruefung abgeschlossen. Alle kritischen Pfade erreichbar. ---'
        }
        else {
            Write-Log '--- Pfad-Pruefung: KRITISCHE PFADE FEHLEN - Installation gesperrt. ---'
        }
    })

    # Version-Wechsel -> Editionen anpassen
    # Nutzt EditionMap (OrderedDictionary) statt separater EditionsStandard/Editions2025
    $script:CbVersion.Add_SelectedIndexChanged({
        $ver      = $script:CbVersion.SelectedItem
        $editions = Get-EditionsForVersion -Version $ver
        $script:CbEdition.Items.Clear()
        foreach ($e in $editions) { [void]$script:CbEdition.Items.Add($e) }
        if ($script:CbEdition.Items.Contains($script:Config.DefaultEdition)) {
            $script:CbEdition.SelectedItem = $script:Config.DefaultEdition
        } else {
            $script:CbEdition.SelectedIndex = 0
        }
    })

    # Instanzname Reset
    $script:BtnResetInstance.Add_Click({
        $script:TbInstance.Text = $script:Config.DefaultInstanceName
        Write-Log "Instanzname auf Standard zurueckgesetzt: $($script:Config.DefaultInstanceName)"
    })

    # AD-Pruefung
    $script:BtnCheckAD.Add_Click({
        $account  = $script:TbAccount.Text.Trim()
        $password = $script:TbPassword.Text

        if ([string]::IsNullOrWhiteSpace($account)) {
            $script:LblAdStatus.Text      = 'Kein Konto eingetragen.'
            $script:LblAdStatus.ForeColor = [System.Drawing.Color]::Gray
            return
        }

        Set-ControlsEnabled -Enabled $false
        Start-Progress -StatusText 'AD-Pruefung laeuft...'
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $normalized = ConvertTo-DomainAccountFormat -AccountName $account
            if ($normalized -ne $account) {
                $script:TbAccount.Text = $normalized
                Write-Log "Konto normalisiert: $account -> $normalized"
            }

            $script:LblAdStatus.Text      = 'Pruefe...'
            $script:LblAdStatus.ForeColor = [System.Drawing.Color]::Blue
            [System.Windows.Forms.Application]::DoEvents()

            $result = Test-ADCredentials -AccountName $normalized -Password $password

            if ($result.IsValid) {
                $script:LblAdStatus.Text      = 'OK: Konto gueltig'
                $script:LblAdStatus.ForeColor = [System.Drawing.Color]::Green
                Write-Log "AD-Pruefung OK: $normalized"
            }
            elseif ($result.AccountExists) {
                $script:LblAdStatus.Text      = 'Passwort falsch!'
                $script:LblAdStatus.ForeColor = [System.Drawing.Color]::Red
                Write-Log "AD-Pruefung: Konto gefunden, Passwort falsch. $($result.ErrorMessage)"
                [System.Windows.Forms.MessageBox]::Show(
                    "Passwort ist falsch.`n`nACHTUNG: Fehlversuche zaehlen zur Lockout-Policy!",
                    'Authentifizierungsfehler',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
            else {
                $script:LblAdStatus.Text      = 'Konto nicht gefunden'
                $script:LblAdStatus.ForeColor = [System.Drawing.Color]::Red
                Write-Log "AD-Pruefung fehlgeschlagen: $($result.ErrorMessage)"
            }
        }
        finally {
            Stop-Progress -StatusText 'Bereit.'
            Set-ControlsEnabled -Enabled $true
        }
    })

    # --- Quellen kopieren (Hintergrundthread) ---
    $script:BtnCopy.Add_Click({
        if (-not (Invoke-ValidateInputs)) { return }

        $snapVer     = $script:CbVersion.SelectedItem
        $snapLayout  = Get-DiskLayoutFromForm
        $snapConfig  = $script:Config
        $snapChkSSRS = ($null -ne $script:ChkSSRS -and $script:ChkSSRS.Checked)
        $snapChkSSAS = ($null -ne $script:ChkSSAS -and $script:ChkSSAS.Checked)
        $snapChkSSMS = ($null -ne $script:ChkSSMS -and $script:ChkSSMS.Checked)
        $snapChkSSIS = ($null -ne $script:ChkSSIS -and $script:ChkSSIS.Checked)
        $snapChkTDP  = ($null -ne $script:ChkTDP  -and $script:ChkTDP.Checked)

        Set-ControlsEnabled -Enabled $false
        Start-Progress -StatusText 'Kopiere Quellen...'

        $workerCore = {
            try {
                Write-Log '=== Quellen kopieren startet ==='

                $logSB = { param($msg) Write-Log $msg }

                # v5 Funktionsname: Copy-SqlSource (nicht Copy-SqlSources)
                $result = Copy-SqlSource -SourceShare  $snapConfig.SourceShare `
                                         -Version      $snapVer `
                                         -InstallDrive $snapLayout['InstallDrive'] `
                                         -LogCallback  $logSB

                if (-not $result.Success) {
                    $errMsg = "Fehler beim Kopieren der SQL-Quellen:`n$($result.Message)"
                    $form.Invoke([System.Windows.Forms.MethodInvoker]{
                        [System.Windows.Forms.MessageBox]::Show(
                            $errMsg, 'Fehler',
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Error
                        ) | Out-Null
                    })
                }

                # SSRS/SSAS/SSMS sind Unterordner von SQL$Version - Copy-SqlSource /E kopiert alle mit
                # Kein separater Copy-ComponentSource Aufruf fuer diese Komponenten noetig
                if ($snapChkSSRS) { Write-Log "SSRS-Quellen: enthalten in SQLSources\SQL$snapVer\Reporting (kein Extra-Copy)" }
                if ($snapChkSSAS) { Write-Log "SSAS-Quellen: enthalten in SQLSources\SQL$snapVer\SQL_Install (kein Extra-Copy)" }
                if ($snapChkSSIS) { Write-Log "SSIS-Quellen: enthalten in SQLSources\SQL$snapVer\SQL_Install (kein Extra-Copy)" }
                if ($snapChkSSMS) { Write-Log "SSMS-Quellen: enthalten in SQLSources\SQL$snapVer\Management (kein Extra-Copy)" }
                if ($snapChkTDP) {
                    Copy-ComponentSource -ComponentName 'TDP' `
                        -SourcePath   $snapConfig.OptionalComponents['TDP_SourcePath'] `
                        -InstallDrive $snapLayout['InstallDrive'] `
                        -LogCallback  $logSB
                }

                Write-Log '=== Quellen kopieren abgeschlossen ==='
            }
            finally {
                Stop-Progress -StatusText 'Quellen kopieren abgeschlossen.'
                Set-ControlsEnabled -Enabled $true
            }
        }

        $worker = New-WorkerBlock -CoreWork $workerCore

        $vars = @{
            snapVer     = $snapVer
            snapLayout  = $snapLayout
            snapConfig  = $snapConfig
            snapChkSSRS = $snapChkSSRS
            snapChkSSAS = $snapChkSSAS
            snapChkSSMS = $snapChkSSMS
            snapChkSSIS = $snapChkSSIS
            snapChkTDP  = $snapChkTDP
            form        = $form
            script_LogBox      = $script:LogBox
            script_ProgressBar = $script:ProgressBar
            script_StatusLabel = $script:StatusLabel
            script_MainForm    = $script:MainForm
            script_BtnInstall  = $script:BtnInstall
            script_BtnCopy     = $script:BtnCopy
            script_BtnClose    = $script:BtnClose
            script_CbVersion   = $script:CbVersion
            script_CbEdition   = $script:CbEdition
            script_CbCollation = $script:CbCollation
            script_TbInstance  = $script:TbInstance
            script_TbAccount   = $script:TbAccount
            script_TbPassword  = $script:TbPassword
            script_BtnCheckAD  = $script:BtnCheckAD
        }

        $workerFull = [scriptblock]::Create(@"
`$script:LogBox      = `$script_LogBox
`$script:ProgressBar = `$script_ProgressBar
`$script:StatusLabel = `$script_StatusLabel
`$script:MainForm    = `$script_MainForm
`$script:BtnInstall  = `$script_BtnInstall
`$script:BtnCopy     = `$script_BtnCopy
`$script:BtnClose    = `$script_BtnClose
`$script:CbVersion   = `$script_CbVersion
`$script:CbEdition   = `$script_CbEdition
`$script:CbCollation = `$script_CbCollation
`$script:TbInstance  = `$script_TbInstance
`$script:TbAccount   = `$script_TbAccount
`$script:TbPassword  = `$script_TbPassword
`$script:BtnCheckAD  = `$script_BtnCheckAD
$($worker.ToString())
"@)

        $script:_CopyTimer = Start-BackgroundJob -Work $workerFull -Variables $vars
    })

    # --- Installation starten (Hintergrundthread) ---
    $script:BtnInstall.Add_Click({
        if (-not (Invoke-ValidateInputs)) { return }

        $confirmMsg = "Installation wirklich starten?`n`n" +
                      "Version : $($script:CbVersion.SelectedItem)`n" +
                      "Edition : $($script:CbEdition.SelectedItem)`n" +
                      "Instanz : $($script:TbInstance.Text)"

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $confirmMsg, 'Bestaetigung',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $snapVer       = $script:CbVersion.SelectedItem
        $snapEdition   = $script:CbEdition.SelectedItem
        $snapInstance  = $script:TbInstance.Text.Trim()
        $snapCollation = $script:CbCollation.SelectedItem
        $snapAccount   = $script:TbAccount.Text.Trim()
        $snapPassword  = $script:TbPassword.Text
        $snapLayout    = Get-DiskLayoutFromForm
        $snapConfig    = $script:Config
        $snapChkSSRS         = ($null -ne $script:ChkSSRS -and $script:ChkSSRS.Checked)
        $snapChkSSAS         = ($null -ne $script:ChkSSAS -and $script:ChkSSAS.Checked)
        $snapChkSSMS         = ($null -ne $script:ChkSSMS -and $script:ChkSSMS.Checked)
        $snapChkSSIS         = ($null -ne $script:ChkSSIS -and $script:ChkSSIS.Checked)
        $snapSsisCheckboxShown = ($null -ne $script:ChkSSIS)
        $snapChkTDP          = ($null -ne $script:ChkTDP  -and $script:ChkTDP.Checked)
        $snapChkJDBC         = ($null -ne $script:ChkJDBC -and $script:ChkJDBC.Checked)
        $snapChkODBC         = ($null -ne $script:ChkODBC -and $script:ChkODBC.Checked)
        $snapChkDB2          = ($null -ne $script:ChkDB2  -and $script:ChkDB2.Checked)

        # --- PreInstall-Pruefungen (synchron im GUI-Thread) ---
        $preLayout = Get-DiskLayoutFromForm
        $preOk = Invoke-PreInstallChecks `
            -Config       $script:Config `
            -DiskLayout   $preLayout `
            -InstanceName $snapInstance `
            -LogCallback  { param($msg) Write-Log $msg }
        if (-not $preOk) {
            Write-Log 'Installation abgebrochen (PreInstall-Pruefung).'
            return
        }

        # Monitoring value (0=Kein, 1=Service, 2=Vollstaendig)
        # SelectedIndex entspricht direkt dem MonitoringType-Parameter (0/1/2)
        $snapMonitoring = $Config.MonitoringDefault
        if ($null -ne $script:CbMonitoring -and $script:CbMonitoring.SelectedIndex -ge 0) {
            $snapMonitoring = $script:CbMonitoring.SelectedIndex
        }

        $serialKey  = "SQL${snapVer}_${snapEdition}"
        $snapSerial = if ($snapConfig.SerialNumbers.Contains($serialKey)) {
                          $snapConfig.SerialNumbers[$serialKey]
                      } else { '' }

        Set-ControlsEnabled -Enabled $false
        Start-Progress -StatusText 'Installation laeuft...'

        $workerCore = {
            try {
                $logSB = { param($msg) Write-Log $msg }

                # Get-SqlPaths: v5 Signatur: -DiskLayout, -Paths, -InstanceName
                # Config.Paths statt Config.SqlSubPaths
                $sqlPaths = Get-SqlPaths -DiskLayout   $snapLayout `
                                         -Paths        $snapConfig.Paths `
                                         -InstanceName $snapInstance

                Write-Log (Format-DiskLayoutSummary -SqlPaths $sqlPaths)
                Write-Log 'Erstelle Verzeichnisse...'
                $dirResults = New-SqlDirectories -SqlPaths $sqlPaths
                foreach ($dr in $dirResults) { Write-Log "  $($dr.Status): $($dr.Pfad)" }

                # Build PSCredential for service account if provided
                $serviceCredential = $null
                if ($snapAccount -and $snapPassword) {
                    $secPwd = ConvertTo-SecureString -String $snapPassword -AsPlainText -Force
                    $serviceCredential = New-Object System.Management.Automation.PSCredential($snapAccount, $secPwd)
                }

                $installResult = Invoke-SqlInstallation `
                    -SqlPaths          $sqlPaths `
                    -Version           $snapVer `
                    -Edition           $snapEdition `
                    -InstanceName      $snapInstance `
                    -Collation         $snapCollation `
                    -ProductKey        $snapSerial `
                    -ServiceCredential $serviceCredential `
                    -InstallDrive      $snapLayout['InstallDrive'] `
                    -InstallConfig     $snapConfig.InstallationConfig `
                    -LogCallback       $logSB

                if ($installResult.Success) {
                    # Wait for SQL Server to be ready before post-install
                    Write-Log "Pruefe SQL Server Readiness..."
                    $maxTries = 15
                    $tryCount = 0
                    $sqlReady = $false
                    while ($tryCount -lt $maxTries -and -not $sqlReady) {
                        try {
                            $null = Connect-DbaInstance -SqlInstance $snapInstance -ErrorAction Stop
                            $sqlReady = $true
                            Write-Log "  OK: SQL Server $snapInstance ist bereit"
                        }
                        catch {
                            $tryCount++
                            if ($tryCount -lt $maxTries) {
                                Write-Log "  Versuch $tryCount/$maxTries - warte 2 Sekunden..."
                                Start-Sleep -Seconds 2
                            }
                        }
                    }
                    if (-not $sqlReady) {
                        throw "SQL Server $snapInstance nicht erreichbar nach 30 Sekunden"
                    }

                    # SSIS: IS-Feature aus Features-Liste entfernen wenn Checkbox abgewaehlt
                    if ($snapSsisCheckboxShown -and -not $snapChkSSIS) {
                        if ($snapConfig.InstallationConfig.Features -contains 'IS') {
                            $snapConfig.InstallationConfig.Features = @(
                                $snapConfig.InstallationConfig.Features | Where-Object { $_ -ne 'IS' }
                            )
                            Write-Log '  Info: SSIS (IS) wird nicht installiert (Checkbox abgewaehlt).'
                        }
                    }

                    # Install optional components FIRST (before PostInstall sets TSM monitoring)
                    if ($snapChkSSAS) {
                        Write-Log "Installiere SSAS..."
                        Install-SsasComponent `
                            -SourcePath   "$($snapLayout['InstallDrive']):\SQLSources\SQL$snapVer\SQL_Install" `
                            -InstanceName $snapInstance `
                            -Collation    $snapCollation `
                            -LogCallback  $logSB
                    }
                    if ($snapChkSSRS) {
                        Write-Log "Installiere SSRS..."
                        # SSRS-Edition und ProductKey aus der gleichen Seriennummern-Logik wie SQL-Engine
                        $ssrsEdition = if ($snapEdition) { $snapEdition } else { 'Developer' }
                        $ssrsSplat = @{
                            SourcePath   = "$($snapLayout['InstallDrive']):\SQLSources\SQL$snapVer\Reporting"
                            InstanceName = $snapInstance
                            Edition      = $ssrsEdition
                            LogCallback  = $logSB
                        }
                        if ($snapSerial -and $snapSerial -ne '') {
                            $ssrsSplat['ProductKey'] = $snapSerial
                        }
                        Install-SsrsComponent @ssrsSplat
                    }
                    if ($snapChkTDP) {
                        Write-Log "Installiere TDP..."
                        Install-TdpComponent `
                            -SourcePath  "$($snapLayout['InstallDrive']):\SQLSources\TDP" `
                            -InstanceName $snapInstance `
                            -LogCallback  $logSB
                    }
                    if ($snapChkSSMS) {
                        Write-Log "Installiere SSMS..."
                        Install-SsmsComponent `
                            -SourcePath  "$($snapLayout['InstallDrive']):\SQLSources\SQL$snapVer\Management" `
                            -LogCallback  $logSB
                    }

                    # Treiber-Installation
                    if ($snapChkJDBC) {
                        Write-Log 'Installiere JDBC-Treiber...'
                        Install-JdbcComponent -SourcePath $snapConfig.Drivers['JDBC_SourcePath'] `
                                              -LogCallback $logSB
                    }
                    if ($snapChkODBC) {
                        Write-Log 'Installiere ODBC-Treiber...'
                        Install-OdbcComponent -SourcePath $snapConfig.Drivers['ODBC_SourcePath'] `
                                              -LogCallback $logSB
                    }
                    if ($snapChkDB2) {
                        Write-Log 'Installiere DB2-Treiber...'
                        Install-Db2Component  -SourcePath $snapConfig.Drivers['DB2_SourcePath'] `
                                              -LogCallback $logSB
                    }

                    # PostInstall AFTER optional components + drivers
                    Invoke-PostInstall -SqlInstance        $snapInstance `
                                       -SqlPaths          $sqlPaths `
                                       -MonitoringType    $snapMonitoring `
                                       -EnableTsm         $snapChkTDP `
                                       -InstallConfig     $snapConfig.InstallationConfig `
                                       -SplunkEnabled        $snapConfig.SplunkEnabled `
                                       -QualysEnabled        $snapConfig.QualysEnabled `
                                       -QualysMonitoringUser $snapConfig.QualysMonitoringUser `
                                       -SysadminGroups       $snapConfig.SysadminGroups `
                                       -OlaSourcePath     $snapConfig.OlaSourcePath `
                                       -SqlScriptsPath    $snapConfig.SqlScriptsPath `
                                       -PostInstallScript $snapConfig.PostInstallScript `
                                       -BasePort          $snapConfig.BasePort `
                                       -PortIncrement     $snapConfig.PortIncrement `
                                       -LogCallback       $logSB
                }

                $finalMsg  = if ($installResult.Success) { 'Installation abgeschlossen.' } else { 'Fehler bei der Installation.' }
                $finalBody = $finalMsg + "`n`n" + $installResult.Message
                $finalIcon = if ($installResult.Success) {
                    [System.Windows.Forms.MessageBoxIcon]::Information
                } else {
                    [System.Windows.Forms.MessageBoxIcon]::Error
                }

                $form.Invoke([System.Windows.Forms.MethodInvoker]{
                    [System.Windows.Forms.MessageBox]::Show(
                        $finalBody, 'Status',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        $finalIcon
                    ) | Out-Null
                })
            }
            finally {
                $statusText = if ($installResult -and $installResult.Success) {
                    'Installation abgeschlossen.'
                } else {
                    'Fehler - siehe Protokoll.'
                }
                Stop-Progress -StatusText $statusText
                Set-ControlsEnabled -Enabled $true
            }
        }

        $worker = New-WorkerBlock -CoreWork $workerCore

        $vars = @{
            snapVer        = $snapVer
            snapEdition    = $snapEdition
            snapInstance   = $snapInstance
            snapCollation  = $snapCollation
            snapAccount    = $snapAccount
            snapPassword   = $snapPassword
            snapLayout     = $snapLayout
            snapConfig     = $snapConfig
            snapSerial     = $snapSerial
            snapChkSSRS          = $snapChkSSRS
            snapChkSSAS          = $snapChkSSAS
            snapChkSSMS          = $snapChkSSMS
            snapChkSSIS          = $snapChkSSIS
            snapSsisCheckboxShown = $snapSsisCheckboxShown
            snapChkTDP           = $snapChkTDP
            snapChkJDBC          = $snapChkJDBC
            snapChkODBC          = $snapChkODBC
            snapChkDB2           = $snapChkDB2
            snapMonitoring       = $snapMonitoring
            form           = $form
            script_LogBox      = $script:LogBox
            script_ProgressBar = $script:ProgressBar
            script_StatusLabel = $script:StatusLabel
            script_MainForm    = $script:MainForm
            script_BtnInstall  = $script:BtnInstall
            script_BtnCopy     = $script:BtnCopy
            script_BtnClose    = $script:BtnClose
            script_CbVersion   = $script:CbVersion
            script_CbEdition   = $script:CbEdition
            script_CbCollation = $script:CbCollation
            script_TbInstance  = $script:TbInstance
            script_TbAccount   = $script:TbAccount
            script_TbPassword  = $script:TbPassword
            script_BtnCheckAD  = $script:BtnCheckAD
        }

        $workerFull = [scriptblock]::Create(@"
`$script:LogBox      = `$script_LogBox
`$script:ProgressBar = `$script_ProgressBar
`$script:StatusLabel = `$script_StatusLabel
`$script:MainForm    = `$script_MainForm
`$script:BtnInstall  = `$script_BtnInstall
`$script:BtnCopy     = `$script_BtnCopy
`$script:BtnClose    = `$script_BtnClose
`$script:CbVersion   = `$script_CbVersion
`$script:CbEdition   = `$script_CbEdition
`$script:CbCollation = `$script_CbCollation
`$script:TbInstance  = `$script_TbInstance
`$script:TbAccount   = `$script_TbAccount
`$script:TbPassword  = `$script_TbPassword
`$script:BtnCheckAD  = `$script_BtnCheckAD
$($worker.ToString())
"@)

        $script:_InstallTimer = Start-BackgroundJob -Work $workerFull -Variables $vars
    })

    # --- Konfiguration oeffnen ---
    $script:BtnConfig.Add_Click({
        $toolRoot   = Split-Path $PSScriptRoot -Parent
        $cfgFormPs1 = Join-Path $toolRoot 'GUI\ConfigForm.ps1'
        if (-not (Test-Path $cfgFormPs1)) {
            Write-Log "ConfigForm nicht gefunden: $cfgFormPs1"
            return
        }
        . $cfgFormPs1
        $saved = Show-ConfigForm -IniPath $script:Config.IniPath
        if ($saved) {
            Write-Log 'Konfiguration gespeichert. Aenderungen werden erst nach Neustart des Tools wirksam.'
        } else {
            Write-Log 'Konfiguration: Abgebrochen (keine Aenderungen gespeichert).'
        }
    })

    $script:BtnClose.Add_Click({ $form.Close() })

    #endregion --- Event-Handler Ende ---

    [System.Windows.Forms.Application]::Run($form)

} # Ende Show-SetupForm


