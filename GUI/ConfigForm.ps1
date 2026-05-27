#Requires -Version 5.1
<#
.SYNOPSIS
    GUI\ConfigForm.ps1
    Konfigurationsfenster fuer das SQL Server Setup Tool.
    Erlaubt das Bearbeiten von settings.ini ueber eine grafische Oberflaeche.
    Wird von MainForm.ps1 per dot-source geladen und via Show-ConfigForm aufgerufen.

    Tabs:
      1  Quellpfade   - PropertyGrid: SourceShare, Module, Treiber, Opt. Komponenten, Wartung
      2  SQLSources   - Struktur anlegen (Standard + Ziel-Server-Variante mit ZIP-Option)
      3  Instanz-Defaults - PropertyGrid: Version/Edition/Instance/Collation, Ports, PreInstall
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================================================================
# C# TypeDefinitionen fuer PropertyGrid (einmalig, Guard verhindert Doppel-Load)
# =============================================================================
if (-not ([System.Management.Automation.PSTypeName]'SqlSetupTool.SqlPathConfig').Type) {
    Add-Type -ReferencedAssemblies (
        'System.Windows.Forms',
        'System.Drawing'
    ) -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Drawing.Design;
using System.Windows.Forms;
using System.Windows.Forms.Design;

namespace SqlSetupTool
{
    // -------------------------------------------------------------------------
    // FolderPathEditor: "..."-Button oeffnet FolderBrowserDialog
    // -------------------------------------------------------------------------
    public class FolderPathEditor : UITypeEditor
    {
        public override UITypeEditorEditStyle GetEditStyle(ITypeDescriptorContext context)
        {
            return UITypeEditorEditStyle.Modal;
        }

        public override object EditValue(ITypeDescriptorContext context,
                                         IServiceProvider provider, object value)
        {
            if (provider == null) return value;
            IWindowsFormsEditorService svc =
                provider.GetService(typeof(IWindowsFormsEditorService))
                as IWindowsFormsEditorService;
            if (svc == null) return value;

            using (FolderBrowserDialog dlg = new FolderBrowserDialog())
            {
                dlg.Description = "Ordner auswaehlen";
                string current = value as string;
                if (current != null && current != "")
                {
                    try
                    {
                        if (System.IO.Directory.Exists(current))
                            dlg.SelectedPath = current;
                    }
                    catch { }
                }
                if (dlg.ShowDialog() == DialogResult.OK)
                    return dlg.SelectedPath;
            }
            return value;
        }
    }

    // -------------------------------------------------------------------------
    // EditionConverter: EXKLUSIV - nur definierte Werte erlaubt
    // -------------------------------------------------------------------------
    public class EditionConverter : StringConverter
    {
        private static readonly string[] _values = new string[]
        {
            "Developer", "Standard", "Enterprise",
            "Developer-Standard", "Developer-Enterprise"
        };

        public override bool GetStandardValuesExclusive(ITypeDescriptorContext context)
        {
            return true;
        }

        public override bool GetStandardValuesSupported(ITypeDescriptorContext context)
        {
            return true;
        }

        public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext context)
        {
            return new StandardValuesCollection(_values);
        }
    }

    // -------------------------------------------------------------------------
    // VersionConverter: non-exklusiv - Freitext moeglich, Vorschlaege aus PS befuellt
    // -------------------------------------------------------------------------
    public class VersionConverter : StringConverter
    {
        public static string[] Values = new string[0];

        public override bool GetStandardValuesExclusive(ITypeDescriptorContext context)
        {
            return false;
        }

        public override bool GetStandardValuesSupported(ITypeDescriptorContext context)
        {
            return Values != null && Values.Length > 0;
        }

        public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext context)
        {
            return new StandardValuesCollection(Values);
        }
    }

    // -------------------------------------------------------------------------
    // CollationConverter: non-exklusiv - Freitext moeglich, aus collations.txt befuellt
    // -------------------------------------------------------------------------
    public class CollationConverter : StringConverter
    {
        public static string[] Values = new string[0];

        public override bool GetStandardValuesExclusive(ITypeDescriptorContext context)
        {
            return false;
        }

        public override bool GetStandardValuesSupported(ITypeDescriptorContext context)
        {
            return Values != null && Values.Length > 0;
        }

        public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext context)
        {
            return new StandardValuesCollection(Values);
        }
    }

    // =========================================================================
    // SqlPathConfig - Datenklass fuer Tab 1
    // =========================================================================
    public class SqlPathConfig
    {
        // --- 1 - Allgemein ---
        [Category("1 - Allgemein")]
        [DisplayName("SourceShare")]
        [Description("Zentraler Pfad der SQLSources-Freigabe. Alle anderen Pfade liegen typischerweise unterhalb dieses Verzeichnisses.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string SourceShare { get; set; }

        [Category("1 - Allgemein")]
        [DisplayName("Versionen")]
        [Description("Kommagetrennte Liste der verfuegbaren SQL-Server-Versionen. Beispiel: 2019,2022,2025")]
        public string Versionen { get; set; }

        // --- 2 - Module ---
        [Category("2 - Module")]
        [DisplayName("DbaTools_ShareBasePath")]
        [Description("Basisverzeichnis fuer dbaTools auf dem Share. Unterordner dbatools und dbatools.library werden automatisch erwartet.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string DbaTools_ShareBasePath { get; set; }

        [Category("2 - Module")]
        [DisplayName("SqmSQLTool_ShareBasePath")]
        [Description("Basisverzeichnis fuer sqmSQLTool auf dem Share. Unterordner sqmSQLTool mit sqmSQLTool.psd1 wird erwartet.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string SqmSQLTool_ShareBasePath { get; set; }

        // --- 3 - Treiber ---
        [Category("3 - Treiber")]
        [DisplayName("JDBC_Enabled")]
        [Description("JDBC-Treiber nach SQL-Installation installieren.")]
        public bool JDBC_Enabled { get; set; }

        [Category("3 - Treiber")]
        [DisplayName("JDBC_SourcePath")]
        [Description("Quellpfad fuer den JDBC-Installer.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string JDBC_SourcePath { get; set; }

        [Category("3 - Treiber")]
        [DisplayName("ODBC_Enabled")]
        [Description("ODBC-Treiber nach SQL-Installation installieren.")]
        public bool ODBC_Enabled { get; set; }

        [Category("3 - Treiber")]
        [DisplayName("ODBC_SourcePath")]
        [Description("Quellpfad fuer den ODBC-Installer.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string ODBC_SourcePath { get; set; }

        [Category("3 - Treiber")]
        [DisplayName("OLEDB_Enabled")]
        [Description("OLEDB-Treiber nach SQL-Installation installieren.")]
        public bool OLEDB_Enabled { get; set; }

        [Category("3 - Treiber")]
        [DisplayName("OLEDB_SourcePath")]
        [Description("Quellpfad fuer den OLEDB-Installer.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string OLEDB_SourcePath { get; set; }

        [Category("3 - Treiber")]
        [DisplayName("DB2_Enabled")]
        [Description("IBM DB2-Treiber nach SQL-Installation installieren.")]
        public bool DB2_Enabled { get; set; }

        [Category("3 - Treiber")]
        [DisplayName("DB2_SourcePath")]
        [Description("Quellpfad fuer den IBM DB2-Treiber-Installer.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string DB2_SourcePath { get; set; }

        // --- 4 - Opt. Komponenten ---
        [Category("4 - Opt. Komponenten")]
        [DisplayName("SSRS_Enabled")]
        [Description("SQL Server Reporting Services installieren.")]
        public bool SSRS_Enabled { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("SSRS_SourcePath")]
        [Description("Quellpfad fuer SSRS-Installer - pro Version ein eigener Unterordner: <SourceShare>\\SQL2019\\Reporting, \\SQL2022\\Reporting etc.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string SSRS_SourcePath { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("SSAS_Enabled")]
        [Description("SQL Server Analysis Services (SSAS) installieren.")]
        public bool SSAS_Enabled { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("SSMS_Enabled")]
        [Description("SQL Server Management Studio (SSMS) installieren.")]
        public bool SSMS_Enabled { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("SSIS_Enabled")]
        [Description("SQL Server Integration Services (SSIS) installieren.")]
        public bool SSIS_Enabled { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("TDP_Enabled")]
        [Description("Telemetrie/Diagnosepakete (TDP) installieren.")]
        public bool TDP_Enabled { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("TDP_SourcePath")]
        [Description("Quellpfad fuer den TDP-Installer.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string TDP_SourcePath { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("PowerBI_Enabled")]
        [Description("Power BI Report Server installieren.")]
        public bool PowerBI_Enabled { get; set; }

        [Category("4 - Opt. Komponenten")]
        [DisplayName("PowerBI_SourcePath")]
        [Description("Quellpfad fuer den Power BI Report Server Installer.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string PowerBI_SourcePath { get; set; }

        // --- 5 - Wartung ---
        [Category("5 - Wartung")]
        [DisplayName("Ola_SourcePath")]
        [Description("Lokaler Pfad fuer Ola Hallengren Maintenance Solution. Leer = GitHub-Download.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string Ola_SourcePath { get; set; }

        [Category("5 - Wartung")]
        [DisplayName("SqlScripts_Path")]
        [Description("Pfad zu Firmen-SQL-Skripten die nach der Installation ausgefuehrt werden. Alle *.sql-Dateien werden alphabetisch ausgefuehrt.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string SqlScripts_Path { get; set; }

        [Category("5 - Wartung")]
        [DisplayName("Secpol_Enabled")]
        [Description("Windows-Sicherheitsrichtlinien nach der Installation anwenden.")]
        public bool Secpol_Enabled { get; set; }

        [Category("5 - Wartung")]
        [DisplayName("Secpol_SourcePath")]
        [Description("Ordner mit secedt.sdb und/oder import.inf fuer Secpol-Haertung.")]
        [Editor(typeof(FolderPathEditor), typeof(UITypeEditor))]
        public string Secpol_SourcePath { get; set; }

        public SqlPathConfig()
        {
            SourceShare            = "";
            Versionen              = "2019,2022,2025";
            DbaTools_ShareBasePath = "";
            SqmSQLTool_ShareBasePath = "";
            JDBC_SourcePath        = "";
            ODBC_SourcePath        = "";
            OLEDB_SourcePath       = "";
            DB2_SourcePath         = "";
            SSRS_SourcePath        = "";
            TDP_SourcePath         = "";
            PowerBI_SourcePath     = "";
            Ola_SourcePath         = "";
            SqlScripts_Path        = "";
            Secpol_SourcePath      = "";
        }
    }

    // =========================================================================
    // SqlDefaultsConfig - Datenklass fuer Tab 3
    // =========================================================================
    public class SqlDefaultsConfig
    {
        // --- 1 - Vorgaben ---
        [Category("1 - Vorgaben")]
        [DisplayName("DefaultVersion")]
        [Description("Standard-SQL-Server-Version fuer neue Installationen. Muss in der Versionsliste (Tab 1) enthalten sein.")]
        [TypeConverter(typeof(VersionConverter))]
        public string DefaultVersion { get; set; }

        [Category("1 - Vorgaben")]
        [DisplayName("DefaultEdition")]
        [Description("Vorgabe-Edition fuer neue SQL-Server-Installationen. Developer = kostenlos, kein Produktiveinsatz.")]
        [TypeConverter(typeof(EditionConverter))]
        public string DefaultEdition { get; set; }

        [Category("1 - Vorgaben")]
        [DisplayName("DefaultInstanceName")]
        [Description("Standard-Instanzname. MSSQLServer = Default-Instanz (kein Instanznamen-Suffix).")]
        public string DefaultInstanceName { get; set; }

        [Category("1 - Vorgaben")]
        [DisplayName("DefaultCollation")]
        [Description("Standard-Sortierung (Collation) fuer neue SQL-Server-Instanzen.")]
        [TypeConverter(typeof(CollationConverter))]
        public string DefaultCollation { get; set; }

        // --- 2 - TCP-Ports ---
        [Category("2 - TCP-Ports")]
        [DisplayName("BasePort")]
        [Description("TCP-Port fuer die Default-Instanz (MSSQLSERVER). Standard: 1433.")]
        public int BasePort { get; set; }

        [Category("2 - TCP-Ports")]
        [DisplayName("BrowserPort")]
        [Description("UDP-Port fuer den SQL Browser Service. Standard: 1434.")]
        public int BrowserPort { get; set; }

        [Category("2 - TCP-Ports")]
        [DisplayName("PortIncrement")]
        [Description("Portabstand fuer Named Instances. Named Instance N bekommt Port: BasePort + (N * Increment).")]
        public int PortIncrement { get; set; }

        // --- 3 - Pre-Install ---
        [Category("3 - Pre-Install")]
        [DisplayName("Format64kCheck")]
        [Description("NTFS-Allokationseinheit aller konfigurierten Laufwerke vor der Installation pruefen. Bei Abweichung: Dialog mit OK/Abbrechen.")]
        public bool Format64kCheck { get; set; }

        [Category("3 - Pre-Install")]
        [DisplayName("SnapshotEnabled")]
        [Description("Hinweis-Dialog anzeigen: Snapshot vor Installation empfohlen.")]
        public bool SnapshotEnabled { get; set; }

        public SqlDefaultsConfig()
        {
            DefaultVersion      = "2022";
            DefaultEdition      = "Developer";
            DefaultInstanceName = "MSSQLServer";
            DefaultCollation    = "Latin1_General_CI_AS";
            BasePort            = 1433;
            BrowserPort         = 1434;
            PortIncrement       = 10;
            Format64kCheck      = true;
            SnapshotEnabled     = false;
        }
    }
}
'@
}

# =============================================================================
# Show-ConfigForm
# =============================================================================
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
    # Hilfsfunktionen WinForms (fuer Tab 2 - bleibt klassisches Layout)
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
    $configDir = Split-Path $IniPath -Parent
    $scriptDir = Split-Path $configDir -Parent   # <ToolRoot>

    # Domain-Profil fuer SQLSourcesPath-Vorbelegung lesen
    function _GetDomainSQLSourcesPath {
        try {
            $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
            $dom = if ($cs -and $cs.PartOfDomain) { $cs.Domain.ToUpper().Split('.')[0] } else { $null }
            $domainsDir = Join-Path $configDir 'domains'
            foreach ($try in @($dom, 'DEFAULT')) {
                if ($null -ne $try -and $try -ne '') {
                    $p = Join-Path $domainsDir "$try.ini"
                    if (Test-Path $p) {
                        $d = _ReadIni -Path $p
                        if ($d.ContainsKey('SQLSources') -and $d['SQLSources']['SourcePath'] -ne '') {
                            return $d['SQLSources']['SourcePath']
                        }
                    }
                }
            }
        } catch {}
        return ''
    }
    $zielBasePath = _GetDomainSQLSourcesPath

    # ---------------------------------------------------------------------------
    # collations.txt laden fuer CollationConverter
    # ---------------------------------------------------------------------------
    $collationsFile = Join-Path (Split-Path $IniPath -Parent) 'collations.txt'
    if (Test-Path $collationsFile) {
        [SqlSetupTool.CollationConverter]::Values = @(
            Get-Content $collationsFile -Encoding UTF8 |
            Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } |
            ForEach-Object { $_.Trim() }
        )
    }

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
    # TAB 1: Quellpfade (PropertyGrid)
    # =========================================================================
    $tab1      = New-Object System.Windows.Forms.TabPage
    $tab1.Text = 'Quellpfade'
    $tabs.TabPages.Add($tab1)

    # SqlPathConfig mit INI-Werten befuellen
    $pathConfig = [SqlSetupTool.SqlPathConfig]::new()
    $pathConfig.SourceShare            = _IniVal 'General'    'SourceShare'
    $pathConfig.Versionen              = _IniVal 'Versions'   'Available' '2019,2022,2025'
    $pathConfig.DbaTools_ShareBasePath = _IniVal 'dbaTools'   'ShareBasePath'
    $pathConfig.SqmSQLTool_ShareBasePath = _IniVal 'sqmSQLTool' 'ShareBasePath'
    $pathConfig.JDBC_Enabled           = ((_IniVal 'Drivers' 'JDBC_Enabled')  -eq 'true')
    $pathConfig.JDBC_SourcePath        = _IniVal 'Drivers' 'JDBC_SourcePath'
    $pathConfig.ODBC_Enabled           = ((_IniVal 'Drivers' 'ODBC_Enabled')  -eq 'true')
    $pathConfig.ODBC_SourcePath        = _IniVal 'Drivers' 'ODBC_SourcePath'
    $pathConfig.OLEDB_Enabled          = ((_IniVal 'Drivers' 'OLEDB_Enabled') -eq 'true')
    $pathConfig.OLEDB_SourcePath       = _IniVal 'Drivers' 'OLEDB_SourcePath'
    $pathConfig.DB2_Enabled            = ((_IniVal 'Drivers' 'DB2_Enabled')   -eq 'true')
    $pathConfig.DB2_SourcePath         = _IniVal 'Drivers' 'DB2_SourcePath'
    $pathConfig.SSRS_Enabled           = ((_IniVal 'OptionalComponents' 'SSRS_Enabled')  -eq 'true')
    $pathConfig.SSRS_SourcePath        = _IniVal 'OptionalComponents' 'SSRS_SourcePath'
    $pathConfig.SSAS_Enabled           = ((_IniVal 'OptionalComponents' 'SSAS_Enabled')  -eq 'true')
    $pathConfig.SSMS_Enabled           = ((_IniVal 'OptionalComponents' 'SSMS_Enabled')  -eq 'true')
    $pathConfig.SSIS_Enabled           = ((_IniVal 'OptionalComponents' 'SSIS_Enabled')  -eq 'true')
    $pathConfig.TDP_Enabled            = ((_IniVal 'OptionalComponents' 'TDP_Enabled')   -eq 'true')
    $pathConfig.TDP_SourcePath         = _IniVal 'OptionalComponents' 'TDP_SourcePath'
    $pathConfig.PowerBI_Enabled        = ((_IniVal 'OptionalComponents' 'PowerBI_Enabled') -eq 'true')
    $pathConfig.PowerBI_SourcePath     = _IniVal 'OptionalComponents' 'PowerBI_SourcePath'
    $pathConfig.Ola_SourcePath         = _IniVal 'Maintenance' 'OlaSourcePath'
    $pathConfig.SqlScripts_Path        = _IniVal 'PostInstall' 'SqlScriptsPath'
    $pathConfig.Secpol_Enabled         = ((_IniVal 'Secpol' 'Enabled') -eq 'true')
    $pathConfig.Secpol_SourcePath      = _IniVal 'Secpol' 'SourcePath'

    $propGrid1                = New-Object System.Windows.Forms.PropertyGrid
    $propGrid1.Dock           = 'Fill'
    $propGrid1.PropertySort   = [System.Windows.Forms.PropertySort]::Categorized
    $propGrid1.HelpVisible    = $true
    $propGrid1.SelectedObject = $pathConfig
    $tab1.Controls.Add($propGrid1)

    # =========================================================================
    # TAB 2: SQLSources anlegen (WinForms - unveraendert ausser Gruppenbox-Titel)
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

    # --- Ziel-Server-Export ---
    # BasePath wird aus Domain-Profil vorbelegt.
    # GroupBox-Hoehe: 148 (mit Hinweis-Label) damit nichts abgeschnitten wird.
    $gbFiTS = _Gb -P $tab2 -T 'Ziel-Server-Export (lokal generieren + als ZIP uebertragen)' -X 5 -Y 130 -W 815 -H 148
    _Lbl -P $gbFiTS -T 'BasePath:' -X 10 -Y 24 -W 75
    $tbFiTSPath = _Tb -P $gbFiTS -X 90 -Y 22 -W 590 -Def $zielBasePath
    _BrowseBtn -P $gbFiTS -X 685 -Y 22 -Tb $tbFiTSPath | Out-Null
    _Lbl -P $gbFiTS -T 'Versionen:' -X 10 -Y 56 -W 75
    $tbFiTSVer = _Tb -P $gbFiTS -X 90 -Y 54 -W 220 -Def (_IniVal 'Versions' 'Available' '2019,2022,2025')
    _Lbl -P $gbFiTS -T 'ZIP-Ziel:' -X 10 -Y 88 -W 75
    $tbZipPath = _Tb -P $gbFiTS -X 90 -Y 86 -W 590 -Def 'C:\Temp\SQLSources-Ziel.zip'
    _BrowseBtn -P $gbFiTS -X 685 -Y 86 -Tb $tbZipPath | Out-Null
    $btnFiTS = _Btn -P $gbFiTS -T 'Als ZIP generieren' -X 715 -Y 52 -W 90 -H 26

    # Hinweis-Label INNERHALB der GroupBox (nicht auf dem Tab - wuerde sonst von GroupBox ueberdeckt)
    $lblZielHint           = New-Object System.Windows.Forms.Label
    $lblZielHint.Text      = 'Hinweis: Kein SQLSources-Pfad im Domain-Profil. Pfad manuell eintragen oder in Start-DomainConfig.cmd konfigurieren.'
    $lblZielHint.Location  = New-Object System.Drawing.Point(10, 122)
    $lblZielHint.Size      = New-Object System.Drawing.Size(790, 18)
    $lblZielHint.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblZielHint.Visible   = ($zielBasePath -eq '')
    $gbFiTS.Controls.Add($lblZielHint)

    # Hint ausblenden sobald etwas eingetragen
    $tbFiTSPath.Add_TextChanged({
        $lblZielHint.Visible = ($tbFiTSPath.Text.Trim() -eq '')
    })

    # --- Ausgabe ---
    $gbLog2        = _Gb -P $tab2 -T 'Ausgabe' -X 5 -Y 290 -W 815 -H 285
    $gbLog2.Anchor = 'Top,Bottom,Left,Right'
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

    # =========================================================================
    # TAB 3: Instanz-Defaults (PropertyGrid)
    # =========================================================================
    $tab3      = New-Object System.Windows.Forms.TabPage
    $tab3.Text = 'Instanz-Defaults'
    $tabs.TabPages.Add($tab3)

    # VersionConverter initial befuellen
    [SqlSetupTool.VersionConverter]::Values = @(
        $pathConfig.Versionen -split '\s*,\s*' | Where-Object { $_ -ne '' }
    )

    # SqlDefaultsConfig mit INI-Werten befuellen
    $defaultsConfig = [SqlSetupTool.SqlDefaultsConfig]::new()
    $defaultsConfig.DefaultVersion     = _IniVal 'General' 'DefaultVersion' '2022'
    $defaultsConfig.DefaultEdition     = _IniVal 'General' 'DefaultEdition' 'Developer'
    $defaultsConfig.DefaultInstanceName = _IniVal 'General' 'DefaultInstanceName' 'MSSQLServer'
    $defaultsConfig.DefaultCollation   = _IniVal 'General' 'DefaultCollation' 'Latin1_General_CI_AS'
    $defaultsConfig.BasePort           = [int](_IniVal 'Ports' 'BasePort' '1433')
    $defaultsConfig.BrowserPort        = [int](_IniVal 'Ports' 'BrowserPort' '1434')
    $defaultsConfig.PortIncrement      = [int](_IniVal 'Ports' 'PortIncrement' '10')
    $defaultsConfig.Format64kCheck     = ((_IniVal 'PreInstall' 'Format64kCheck' 'true') -ne 'false')
    $defaultsConfig.SnapshotEnabled    = ((_IniVal 'PreInstall' 'SnapshotEnabled') -eq 'true')

    $propGrid3                = New-Object System.Windows.Forms.PropertyGrid
    $propGrid3.Dock           = 'Fill'
    $propGrid3.PropertySort   = [System.Windows.Forms.PropertySort]::Categorized
    $propGrid3.HelpVisible    = $true
    $propGrid3.SelectedObject = $defaultsConfig
    $tab3.Controls.Add($propGrid3)

    # =========================================================================
    # Tab-Wechsel: Versionen und BasePath syncen
    # =========================================================================
    $tabs.Add_SelectedIndexChanged({
        if ($tabs.SelectedIndex -eq 1) {
            # Tab 2: Versionen aus Tab 1 synchronisieren
            if ($tbStdPath.Text -eq '') { $tbStdPath.Text = $pathConfig.SourceShare }
            $tbStdVer.Text  = $pathConfig.Versionen
            $tbFiTSVer.Text = $pathConfig.Versionen
        }
        if ($tabs.SelectedIndex -eq 2) {
            # Tab 3: VersionConverter mit aktuellen Versionen befuellen
            [SqlSetupTool.VersionConverter]::Values = @(
                $pathConfig.Versionen -split '\s*,\s*' | Where-Object { $_ -ne '' }
            )
            $propGrid3.Refresh()
        }
    })

    # =========================================================================
    # Tab 2: Standard-Struktur anlegen
    # =========================================================================
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

    # =========================================================================
    # Tab 2: Ziel-Server-Export als ZIP generieren
    # =========================================================================
    $btnFiTS.Add_Click({
        $fitsBase = $tbFiTSPath.Text.Trim()
        $zipDest  = $tbZipPath.Text.Trim()
        $versions = $tbFiTSVer.Text.Trim()

        if ($fitsBase -eq '') {
            [System.Windows.Forms.MessageBox]::Show(
                'Bitte BasePath des Ziel-Servers angeben.',
                'Fehler', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($zipDest -eq '') {
            [System.Windows.Forms.MessageBox]::Show(
                'Bitte ZIP-Zielpfad angeben.',
                'Fehler', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $cfgLogBox.Clear()
        $btnStd.Enabled  = $false
        $btnFiTS.Enabled = $false

        # Struktur erst lokal aufbauen (New-SqlSourceStructure-FiTS.ps1), dann als ZIP
        $scriptPath = Join-Path $scriptDir 'Scripts\New-SqlSourceStructure-FiTS.ps1'
        $useScript  = Test-Path $scriptPath

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('_form',       $form)
        $rs.SessionStateProxy.SetVariable('_logBox',     $cfgLogBox)
        $rs.SessionStateProxy.SetVariable('_fitsBase',   $fitsBase)
        $rs.SessionStateProxy.SetVariable('_zipDest',    $zipDest)
        $rs.SessionStateProxy.SetVariable('_versions',   $versions)
        $rs.SessionStateProxy.SetVariable('_scriptPath', $scriptPath)
        $rs.SessionStateProxy.SetVariable('_useScript',  $useScript)
        $rs.SessionStateProxy.SetVariable('_btnStd',     $btnStd)
        $rs.SessionStateProxy.SetVariable('_btnFiTS',    $btnFiTS)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $ps.AddScript({
            # Schritt 1: Struktur aufbauen (wenn Skript vorhanden)
            if ($_useScript) {
                $argList = @('-NonInteractive','-NoProfile','-ExecutionPolicy','Bypass',
                             '-File', $_scriptPath,
                             '-BasePath', $_fitsBase,
                             '-Versions', $_versions,
                             '-Force')
                $output = & powershell.exe @argList 2>&1
                foreach ($line in $output) {
                    $lineStr = $line.ToString()
                    $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                        $_logBox.AppendText("$lineStr`n")
                        $_logBox.ScrollToCaret()
                    })
                }
            } else {
                $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                    $_logBox.AppendText("Hinweis: New-SqlSourceStructure-FiTS.ps1 nicht gefunden - uebersprungen.`n")
                    $_logBox.ScrollToCaret()
                })
            }

            # Schritt 2: ZIP erstellen
            $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                $_logBox.AppendText("Erstelle ZIP: $_zipDest`n")
                $_logBox.ScrollToCaret()
            })
            try {
                if (Test-Path $_zipDest) { Remove-Item $_zipDest -Force }
                Compress-Archive -Path "$_fitsBase\*" -DestinationPath $_zipDest -ErrorAction Stop
                $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                    $_logBox.AppendText("OK: ZIP erstellt: $_zipDest`n")
                    $_logBox.ScrollToCaret()
                })
            } catch {
                $errMsg = $_.Exception.Message
                $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                    $_logBox.AppendText("FEHLER ZIP: $errMsg`n")
                    $_logBox.ScrollToCaret()
                })
            }

            $_form.Invoke([System.Windows.Forms.MethodInvoker]{
                $_btnStd.Enabled  = $true
                $_btnFiTS.Enabled = $true
            })
        }) | Out-Null
        $ps.BeginInvoke() | Out-Null
    })

    # =========================================================================
    # Speichern-Handler
    # =========================================================================
    $btnSave.Add_Click({
        try {
            # --- Tab 1: Quellpfade aus $pathConfig ---
            _UpdateIni -IniPath $IniPath -Section 'General'    -Key 'SourceShare'   -Value $pathConfig.SourceShare
            _UpdateIni -IniPath $IniPath -Section 'Versions'   -Key 'Available'     -Value $pathConfig.Versionen
            _UpdateIni -IniPath $IniPath -Section 'dbaTools'   -Key 'ShareBasePath' -Value $pathConfig.DbaTools_ShareBasePath
            _UpdateIni -IniPath $IniPath -Section 'sqmSQLTool' -Key 'ShareBasePath' -Value $pathConfig.SqmSQLTool_ShareBasePath

            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'JDBC_Enabled'    -Value $pathConfig.JDBC_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'JDBC_SourcePath'  -Value $pathConfig.JDBC_SourcePath
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'ODBC_Enabled'    -Value $pathConfig.ODBC_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'ODBC_SourcePath'  -Value $pathConfig.ODBC_SourcePath
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'OLEDB_Enabled'   -Value $pathConfig.OLEDB_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'OLEDB_SourcePath' -Value $pathConfig.OLEDB_SourcePath
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'DB2_Enabled'     -Value $pathConfig.DB2_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'Drivers' -Key 'DB2_SourcePath'   -Value $pathConfig.DB2_SourcePath

            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSRS_Enabled'      -Value $pathConfig.SSRS_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSRS_SourcePath'    -Value $pathConfig.SSRS_SourcePath
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSAS_Enabled'      -Value $pathConfig.SSAS_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSMS_Enabled'      -Value $pathConfig.SSMS_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'SSIS_Enabled'      -Value $pathConfig.SSIS_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'TDP_Enabled'       -Value $pathConfig.TDP_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'TDP_SourcePath'     -Value $pathConfig.TDP_SourcePath
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'PowerBI_Enabled'   -Value $pathConfig.PowerBI_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'OptionalComponents' -Key 'PowerBI_SourcePath' -Value $pathConfig.PowerBI_SourcePath

            _UpdateIni -IniPath $IniPath -Section 'Maintenance' -Key 'OlaSourcePath'  -Value $pathConfig.Ola_SourcePath
            _UpdateIni -IniPath $IniPath -Section 'PostInstall' -Key 'SqlScriptsPath' -Value $pathConfig.SqlScripts_Path
            _UpdateIni -IniPath $IniPath -Section 'Secpol'      -Key 'Enabled'        -Value $pathConfig.Secpol_Enabled.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'Secpol'      -Key 'SourcePath'     -Value $pathConfig.Secpol_SourcePath

            # --- Tab 3: Defaults aus $defaultsConfig ---
            _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultVersion'      -Value $defaultsConfig.DefaultVersion
            _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultEdition'      -Value $defaultsConfig.DefaultEdition
            _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultInstanceName' -Value $defaultsConfig.DefaultInstanceName
            _UpdateIni -IniPath $IniPath -Section 'General' -Key 'DefaultCollation'    -Value $defaultsConfig.DefaultCollation

            _UpdateIni -IniPath $IniPath -Section 'Ports' -Key 'BasePort'      -Value $defaultsConfig.BasePort.ToString()
            _UpdateIni -IniPath $IniPath -Section 'Ports' -Key 'BrowserPort'   -Value $defaultsConfig.BrowserPort.ToString()
            _UpdateIni -IniPath $IniPath -Section 'Ports' -Key 'PortIncrement' -Value $defaultsConfig.PortIncrement.ToString()

            _UpdateIni -IniPath $IniPath -Section 'PreInstall' -Key 'Format64kCheck'  -Value $defaultsConfig.Format64kCheck.ToString().ToLower()
            _UpdateIni -IniPath $IniPath -Section 'PreInstall' -Key 'SnapshotEnabled' -Value $defaultsConfig.SnapshotEnabled.ToString().ToLower()

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
