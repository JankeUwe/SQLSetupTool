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
    $form.Size            = New-Object System.Drawing.Size(820, 870)
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
    $gbInstance = Add-GroupBox -Parent $form -Text 'Instanzname' -X 10 -Y 90 -Width 780 -Height 60

    Add-Label -Parent $gbInstance -Text 'Instanzname:' -X 10 -Y 22 -Width 100
    $script:TbInstance       = Add-TextBox -Parent $gbInstance -X 115 -Y 20 -Width 200 `
                                           -Default $Config.DefaultInstanceName
    $script:BtnResetInstance = Add-Button  -Parent $gbInstance -Text 'Standard' -X 325 -Y 19 -Width 80
    Add-Label -Parent $gbInstance -Text '(Standard: MSSQLServer)' -X 415 -Y 22 -Width 200

    #=== GroupBox: Sortierung ===
    $gbCollation = Add-GroupBox -Parent $form -Text 'Sortierung (Collation)' -X 10 -Y 160 -Width 780 -Height 60

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
                              -X 10 -Y 230 -Width 780 -Height 90

    Add-Label -Parent $gbAccount -Text 'Konto (DOMAIN\User):' -X 10 -Y 22 -Width 150
    $script:TbAccount  = Add-TextBox -Parent $gbAccount -X 165 -Y 20 -Width 250

    Add-Label -Parent $gbAccount -Text 'Passwort:' -X 10 -Y 54 -Width 150
    $script:TbPassword = Add-TextBox -Parent $gbAccount -X 165 -Y 52 -Width 250 -IsPassword $true

    $script:BtnCheckAD  = Add-Button -Parent $gbAccount -Text 'AD pruefen' -X 430 -Y 20 -Width 90
    $script:LblAdStatus = Add-Label  -Parent $gbAccount -Text '' -X 530 -Y 22 -Width 220

    #=== GroupBox: Plattenlayout ===
    $gbDisk = Add-GroupBox -Parent $form -Text 'Plattenlayout' -X 10 -Y 330 -Width 780 -Height 110

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
    $gbMonitor = Add-GroupBox -Parent $form -Text 'Monitoring' -X 10 -Y 450 -Width 780 -Height 60

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
    $gbOpt = Add-GroupBox -Parent $form -Text 'Optionale Komponenten' -X 10 -Y 520 -Width 780 -Height 100

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

    #=== Aktions-Buttons ===
    $gbActions = Add-GroupBox -Parent $form -Text 'Aktionen' -X 10 -Y 630 -Width 780 -Height 50

    $script:BtnCopy    = Add-Button -Parent $gbActions -Text 'Quellen kopieren'    -X 10  -Y 15 -Width 140
    $script:BtnInstall = Add-Button -Parent $gbActions -Text 'Installation starten' -X 160 -Y 15 -Width 150
    $script:BtnClose   = Add-Button -Parent $gbActions -Text 'Schliessen'          -X 680 -Y 15 -Width 90

    #=== Log-Fenster ===
    $gbLog = Add-GroupBox -Parent $form -Text 'Protokoll' -X 10 -Y 690 -Width 780 -Height 135

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

    # Form_Shown: BringToFront + initiales Log
    $form.Add_Shown({
        $form.BringToFront()
        $form.Activate()
        # Config.Domain statt Config.CurrentDomain
        $domainInfo = if ($script:Config.Domain) { $script:Config.Domain } else { 'keine' }
        Write-Log 'SQL Server Setup Tool gestartet.'
        Write-Log "Konfiguration geladen. Domain: $domainInfo"
        Write-Log "Sortierung: $($script:Config.DefaultCollation)"
        Write-Log "Quell-Share: $($script:Config.SourceShare)"
        if ($script:Config.DbaTools) {
            Write-Log "dbaTools-Share: $($script:Config.DbaTools.ShareBasePath)"
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
                        Install-SsrsComponent `
                            -SourcePath  "$($snapLayout['InstallDrive']):\SQLSources\SQL$snapVer\Reporting" `
                            -InstanceName $snapInstance `
                            -LogCallback  $logSB
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

                    # PostInstall AFTER optional components - TSM valid now
                    Invoke-PostInstall -SqlInstance        $snapInstance `
                                       -SqlPaths          $sqlPaths `
                                       -MonitoringType    $snapMonitoring `
                                       -EnableTsm         $snapChkTDP `
                                       -InstallConfig     $snapConfig.InstallationConfig `
                                       -SplunkEnabled     $snapConfig.SplunkEnabled `
                                       -SysadminGroups    $snapConfig.SysadminGroups `
                                       -OlaSourcePath     $snapConfig.OlaSourcePath `
                                       -PostInstallScript $snapConfig.PostInstallScript `
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

    $script:BtnClose.Add_Click({ $form.Close() })

    #endregion --- Event-Handler Ende ---

    [System.Windows.Forms.Application]::Run($form)

} # Ende Show-SetupForm


