#Requires -Version 5.1
<#
.SYNOPSIS
    Erstellt beide Word-Dokumente (.docx) ohne Word-Installation.
    Nutzt System.IO.Compression (Open XML = ZIP-Struktur).
#>
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ── Open-XML Bausteine ────────────────────────────────────────────────────────
$NS = 'xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'

function xml-escape([string]$s) { $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' }

function p-style([string]$style,[string]$text,[bool]$bold=$false) {
    $t = xml-escape $text
    $b = if($bold){'<w:rPr><w:b/></w:rPr>'}else{''}
    "<w:p><w:pPr><w:pStyle w:val=`"$style`"/></w:pPr><w:r>$b<w:t xml:space=`"preserve`">$t</w:t></w:r></w:p>"
}

function p-normal([string]$text) {
    "<w:p><w:r><w:t xml:space=`"preserve`">$(xml-escape $text)</w:t></w:r></w:p>"
}

function p-break { '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' }

function make-table([string[]]$headers, [object[]]$rows) {
    # Spaltenbreiten: gleichmässig auf 9360 Twips (16.5 cm) verteilt
    $cols = $headers.Count
    $colW = [int](9360 / $cols)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<w:tbl>')
    [void]$sb.Append('<w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="9360" w:type="dxa"/><w:tblLook w:val="04A0"/></w:tblPr>')
    [void]$sb.Append('<w:tblGrid>')
    for($i=0;$i -lt $cols;$i++) { [void]$sb.Append("<w:gridCol w:w=`"$colW`"/>") }
    [void]$sb.Append('</w:tblGrid>')

    # Header-Zeile
    [void]$sb.Append('<w:tr><w:trPr><w:trPr/></w:trPr>')
    foreach($h in $headers) {
        [void]$sb.Append("<w:tc><w:tcPr><w:tcW w:w=`"$colW`" w:type=`"dxa`"/><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"BDD7EE`"/></w:tcPr>")
        [void]$sb.Append("<w:p><w:pPr><w:pStyle w:val=`"Normal`"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t xml:space=`"preserve`">$(xml-escape $h)</w:t></w:r></w:p>")
        [void]$sb.Append('</w:tc>')
    }
    [void]$sb.Append('</w:tr>')

    # Daten-Zeilen
    foreach($row in $rows) {
        [void]$sb.Append('<w:tr>')
        for($ci=0;$ci -lt $cols;$ci++) {
            $val = if($ci -lt $row.Count){xml-escape $row[$ci]}else{''}
            [void]$sb.Append("<w:tc><w:tcPr><w:tcW w:w=`"$colW`" w:type=`"dxa`"/></w:tcPr>")
            [void]$sb.Append("<w:p><w:r><w:t xml:space=`"preserve`">$val</w:t></w:r></w:p>")
            [void]$sb.Append('</w:tc>')
        }
        [void]$sb.Append('</w:tr>')
    }
    [void]$sb.Append('</w:tbl>')
    [void]$sb.Append('<w:p/>')   # Leerzeile nach Tabelle
    return $sb.ToString()
}

# ── DOCX-Paket zusammenbauen ──────────────────────────────────────────────────
function New-Docx([string]$outPath,[string]$title,[string]$author,[string]$bodyXml) {

    $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml"  ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml"   ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml"  ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>'

    $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"           Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"         Target="docProps/app.xml"/>
</Relationships>'

    $docRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"   Target="styles.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
</Relationships>'

    $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults>
    <w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/><w:lang w:val="de-DE"/></w:rPr></w:rPrDefault>
  </w:docDefaults>
  <w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/>
    <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>
    <w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr><w:spacing w:before="240" w:after="60"/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:color w:val="2E74B5"/><w:sz w:val="32"/><w:b/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/>
    <w:pPr><w:spacing w:before="200" w:after="40"/><w:outlineLvl w:val="1"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:color w:val="2E74B5"/><w:sz w:val="26"/><w:b/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/>
    <w:pPr><w:spacing w:before="160" w:after="40"/><w:outlineLvl w:val="2"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:color w:val="1F4E79"/><w:sz w:val="24"/><w:b/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>
    <w:pPr><w:spacing w:before="0" w:after="80"/><w:jc w:val="left"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:color w:val="2E74B5"/><w:sz w:val="52"/><w:b/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>
    <w:pPr><w:spacing w:before="0" w:after="80"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/><w:color w:val="595959"/><w:sz w:val="28"/></w:rPr>
  </w:style>
  <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/>
    <w:tblPr><w:tblBorders>
      <w:top    w:val="single" w:sz="4" w:space="0" w:color="auto"/>
      <w:left   w:val="single" w:sz="4" w:space="0" w:color="auto"/>
      <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>
      <w:right  w:val="single" w:sz="4" w:space="0" w:color="auto"/>
      <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/>
      <w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>
    </w:tblBorders></w:tblPr>
    <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="20"/></w:rPr>
  </w:style>
</w:styles>'

    $settings = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:defaultTabStop w:val="708"/>
</w:settings>'

    $now = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $core = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>
<cp:coreProperties xmlns:cp=""http://schemas.openxmlformats.org/package/2006/metadata/core-properties""
  xmlns:dc=""http://purl.org/dc/elements/1.1/"" xmlns:dcterms=""http://purl.org/dc/terms/"">
  <dc:title>$(xml-escape $title)</dc:title>
  <dc:creator>$(xml-escape $author)</dc:creator>
  <dcterms:created xsi:type=""dcterms:W3CDTF"" xmlns:xsi=""http://www.w3.org/2001/XMLSchema-instance"">$now</dcterms:created>
</cp:coreProperties>"

    $app = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
  <Application>dtcSoftware SQLSetupTool</Application>
</Properties>'

    $document = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>
<w:document xmlns:w=""http://schemas.openxmlformats.org/wordprocessingml/2006/main"">
<w:body>
$bodyXml
<w:sectPr>
  <w:pgSz w:w=""11906"" w:h=""16838""/>
  <w:pgMar w:top=""1134"" w:right=""850"" w:bottom=""1134"" w:left=""1701"" w:header=""709"" w:footer=""709"" w:gutter=""0""/>
</w:sectPr>
</w:body>
</w:document>"

    # DOCX als ZIP erstellen
    if (Test-Path $outPath) { Remove-Item $outPath -Force }
    $stream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create)
    $zip    = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)

    function Add-ZipEntry([string]$name,[string]$content) {
        $entry  = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
        $writer = New-Object System.IO.StreamWriter($entry.Open(), [System.Text.Encoding]::UTF8)
        $writer.Write($content)
        $writer.Close()
    }

    Add-ZipEntry '[Content_Types].xml'          $contentTypes
    Add-ZipEntry '_rels/.rels'                  $rels
    Add-ZipEntry 'word/_rels/document.xml.rels' $docRels
    Add-ZipEntry 'word/document.xml'            $document
    Add-ZipEntry 'word/styles.xml'              $styles
    Add-ZipEntry 'word/settings.xml'            $settings
    Add-ZipEntry 'docProps/core.xml'            $core
    Add-ZipEntry 'docProps/app.xml'             $app

    $zip.Dispose()
    $stream.Close()
    Write-Host "OK: $outPath  ($([math]::Round((Get-Item $outPath).Length/1KB,1)) KB)"
}

# ════════════════════════════════════════════════════════════════════════════════
# DOKUMENT 1 — Konfigurationsreferenz
# ════════════════════════════════════════════════════════════════════════════════
$b1 = [System.Text.StringBuilder]::new()
function B([string]$s) { [void]$b1.AppendLine($s) }

B (p-style 'Title'    'SQL Server Setup Tool')
B (p-style 'Subtitle' 'Konfigurationsreferenz — settings.ini')
B (p-normal "dtcSoftware  |  Uwe Janke  |  Stand: $(Get-Date -Format 'MMMM yyyy')")
B (p-break)

# 1. Übersicht
B (p-style 'Heading1' '1. Übersicht')
B (p-normal 'Das SQL Server Setup Tool standardisiert die Installation von SQL Server in der FI-TS-Umgebung. Alle Parameter werden zentral in der Datei settings.ini konfiguriert. Das Tool liest diese Datei beim Start, erkennt die Active-Directory-Domäne des Servers und wählt automatisch domänenspezifische Werte (Sortierung, Laufwerkslayout, Monitoring-Typ, Sysadmin-Gruppen).')
B (p-normal 'Pfad zur Konfigurationsdatei:  C:\CCM\SQLSetupTool\Config\settings.ini')
B (p-style 'Heading2' '1.1 Domänenlogik')
B (p-normal 'Für mehrere Sektionen können domänenspezifische Werte hinterlegt werden. Das Tool erkennt den NetBIOS-Namen der Domäne (z. B. HLB, CONTOSO) und verwendet bevorzugt den Eintrag Domain_<NETBIOSNAME>. Existiert kein Domänen-Eintrag, gilt der Schlüssel Standard als Fallback.')
B (make-table @('Sektion','Domänen-Schlüsselformat','Beispiel') @(
    @('[Collations]',     'Domain_<NAME>',       'Domain_HLB = SQL_Latin1_General_CP1_CI_AS'),
    @('[DiskLayout_*]',   'Eigener Sektionsname', 'DiskLayout_HLB'),
    @('[SysadminGroups]', 'Domain_<NAME>',        'Domain_HLB = HLB\Fg_DC_SqlAdminAll_Mod'),
    @('[Monitoring]',     'Domain_<NAME>',        'Domain_HLB = 2')
))

# 2. [General]
B (p-style 'Heading1' '2. [General] — Grundeinstellungen')
B (p-normal 'Enthält die Vorgabewerte für das Installationsformular sowie den Pfad zum Quellenverzeichnis.')
B (make-table @('Schlüssel','Standardwert','Beschreibung') @(
    @('DefaultVersion',      '2022',                 'SQL Server Version — füllt Versions-Combobox vor'),
    @('DefaultEdition',      'Developer',            'SQL Server Edition — füllt Editions-Combobox vor'),
    @('DefaultInstanceName', 'MSSQLServer',          'Instanzname; leer = Standard-Instanz'),
    @('DefaultCollation',    'Latin1_General_CI_AS', 'Sortierung wenn keine Domänen-Collation greift'),
    @('SourceShare',         '\\srv\SQLSources',     'UNC-Pfad zum Installationsmedien-Share')
))

# 3. [Versions] / [Editions]
B (p-style 'Heading1' '3. [Versions] und [Editions]')
B (p-style 'Heading2' '3.1 [Versions]')
B (make-table @('Schlüssel','Beispielwert','Beschreibung') @(
    @('Available','2019,2022,2025','Kommagetrennte Liste — füllt die Versions-Combobox')
))
B (p-style 'Heading2' '3.2 [Editions]')
B (make-table @('Schlüssel','Beispielwert','Beschreibung') @(
    @('Standard','Developer,Standard,Enterprise',         'Editionen für SQL 2019 und 2022'),
    @('SQL2025', 'Developer-Standard,Developer-Enterprise','Sonderbezeichnungen für SQL Server 2025')
))

# 4. [Collations]
B (p-style 'Heading1' '4. [Collations] — Sortierungseinstellungen')
B (p-normal 'Legt Standard-Sortierung und domänenspezifische Vorgaben fest. Die vollständige Auswahlliste für das Formular wird aus Config\collations.txt gelesen (eine Sortierung pro Zeile, # = Kommentar). Ist eine Domänen-Sortierung konfiguriert, erscheint diese automatisch an erster Position der Combobox.')
B (make-table @('Schlüssel','Beispielwert','Beschreibung') @(
    @('Standard',       'Latin1_General_CI_AS',         'Globale Vorgabe-Sortierung (Fallback)'),
    @('Domain_CONTOSO', 'Latin1_General_CI_AS',         'Sortierung für Domäne CONTOSO'),
    @('Domain_HLB',     'SQL_Latin1_General_CP1_CI_AS', 'Sortierung für Domäne HLB')
))

# 5. [SerialNumbers]
B (p-style 'Heading1' '5. [SerialNumbers] — Produktschlüssel')
B (p-normal 'Enthält die Lizenzschlüssel für jede Version-Editions-Kombination. Developer-Editionen benötigen keinen Schlüssel — Wert leer lassen. Das Tool wählt den passenden Schlüssel automatisch anhand der gewählten Kombination.')
B (make-table @('Format','Beispiel','Hinweis') @(
    @('SQL<Version>_<Edition>','SQL2022_Standard = XXXXX-XXXXX-XXXXX-XXXXX-XXXXX','Genau wie Version + Edition im Formular benennen'),
    @('Developer-Edition',     'SQL2022_Developer =',                              'Leer lassen — kein Schlüssel erforderlich'),
    @('SQL2025-Format',        'SQL2025_Developer-Standard =',                     'Bindestrich im Editionsnamen beachten')
))

# 6. [DiskLayout_Standard]
B (p-style 'Heading1' '6. [DiskLayout_Standard] — Laufwerkszuordnung (FI-TS Standard)')
B (p-normal 'Definiert die Laufwerksbuchstaben für alle SQL-relevanten Verzeichnisse. Entspricht dem FI-TS-Referenzstandard für SQL Server 2022 Enterprise. Für ein abweichendes Layout eine eigene Sektion [DiskLayout_<NETBIOS>] anlegen.')
B (make-table @('Schlüssel','FI-TS Laufwerk','Verwendung') @(
    @('DataDrive',   'G','Benutzerdatenbankdateien (.mdf, .ndf)  →  G:\Daten\SQL\<Instanz>\DATA'),
    @('LogDrive',    'H','Transaktionsprotokolle (.ldf)           →  H:\Daten\SQL\<Instanz>\LOG'),
    @('TempDrive',   'I','TempDB-Dateien                          →  I:\Daten\SQL\<Instanz>\DATA+LOG'),
    @('BackupDrive', 'F','SQL-Backups + System-DBs (master etc.)  →  F:\Daten\SQL\Backup + F:\Microsoft SQL Server'),
    @('InstallDrive','C','SQL-Binärdateien (INSTALLSHAREDDIR)     →  C:\Program Files\Microsoft SQL Server')
))

# 7. [Paths]
B (p-style 'Heading1' '7. [Paths] — Unterverzeichnispfade')
B (p-normal 'Definiert die Unterverzeichnisse unterhalb der Laufwerksbuchstaben. Der Instanz-Suffix (MSSQLSERVER bzw. MSSQL$<Name>) wird automatisch angehängt.')
B (make-table @('Schlüssel','Standardwert','Ergibt (FI-TS Standard)') @(
    @('InstallSubPath','Program Files\Microsoft SQL Server','C:\Program Files\Microsoft SQL Server'),
    @('SysDbSubPath',  'Microsoft SQL Server',              'F:\Microsoft SQL Server  (INSTALLSQLDATADIR)'),
    @('DataSubPath',   'Daten\SQL',                         'G:\Daten\SQL\MSSQLSERVER\DATA'),
    @('LogSubPath',    'Daten\SQL',                         'H:\Daten\SQL\MSSQLSERVER\LOG'),
    @('TempSubPath',   'Daten\SQL',                         'I:\Daten\SQL\MSSQLSERVER\DATA und LOG'),
    @('BackupSubPath', 'Daten\SQL\Backup',                  'F:\Daten\SQL\Backup\MSSQLSERVER')
))
B (p-normal 'SysDbSubPath entspricht INSTALLSQLDATADIR in der SQL-Setup-INI. Hier werden master, model, msdb und tempdb (initial) abgelegt.')

# 8. [Installation]
B (p-style 'Heading1' '8. [Installation] — Installationsparameter')
B (p-style 'Heading2' '8.1 Features')
B (p-normal 'Kommagetrennte Liste der SQL-Server-Features die bei der Installation aktiviert werden. Wird direkt an Install-DbaInstance übergeben.')
B (make-table @('Schlüssel','FI-TS Standardwert','Beschreibung') @(
    @('Features','Engine,FullText,IS','Engine = SQL-Datenbank-Engine (Pflicht), FullText = Volltext-Suche, IS = Integration Services (SSIS)')
))
B (p-normal 'Hinweis: SSIS (IS) kann über die GUI-Checkbox deaktiviert werden. Das Tool entfernt IS dann dynamisch aus der Feature-Liste vor der Installation.')
B (p-style 'Heading2' '8.2 Sicherheit')
B (make-table @('Schlüssel','Standardwert','Beschreibung') @(
    @('InstantFileInit',  'true',               'Sofortige Dateiinitialisierung (SqlSvcInstantFileInit=True) — beschleunigt Datenbankoperationen erheblich'),
    @('SysAdminAccounts', 'BUILTIN\Administrators','Initiale Sysadmin-Konten bei der Installation. AD-Gruppen werden separat über [SysadminGroups] zugewiesen.')
))
B (p-style 'Heading2' '8.3 TempDB-Initialkonfiguration')
B (p-normal 'Diese Werte werden beim SQL-Setup gesetzt. PostInstall optimiert die Dateianzahl anschliessend anhand der CPU-Anzahl (4–8 Dateien).')
B (make-table @('Schlüssel','FI-TS Standard','Beschreibung') @(
    @('TempDbFileCount',     '2',    'Anzahl TempDB-Datendateien beim Setup (PostInstall erhöht auf CPU-Basis)'),
    @('TempDbFileSizeMB',    '1024', 'Initiale Grösse je TempDB-Datendatei in MB'),
    @('TempDbFileGrowthMB',  '512',  'Autogrowth je TempDB-Datendatei in MB'),
    @('TempDbLogFileSizeMB', '1024', 'Initiale Grösse TempDB-Logdatei in MB'),
    @('TempDbLogGrowthMB',   '512',  'Autogrowth TempDB-Logdatei in MB')
))
B (p-style 'Heading2' '8.4 Netzwerk und Dienste')
B (make-table @('Schlüssel','Standardwert','Beschreibung') @(
    @('TcpEnabled',        'true', 'TCP/IP-Protokoll aktivieren (FI-TS Standard: true)'),
    @('NpEnabled',         'false','Named Pipes aktivieren (FI-TS Standard: false)'),
    @('BrowserSvcDisabled','true', 'SQL Browser Service nach Installation deaktivieren (FI-TS Standard: true)')
))

# 9. Module
B (p-style 'Heading1' '9. Modul-Konfiguration')
B (p-style 'Heading2' '9.1 [dbaTools]')
B (p-normal 'Pfad zum dbaTools-Modul im Netzwerk-Share. Das Tool prüft die Erreichbarkeit und fällt auf die PowerShell Gallery zurück wenn der Share nicht verfügbar ist. Unter ShareBasePath werden zwei Unterordner erwartet: dbatools\ und dbatools.library\')
B (make-table @('Schlüssel','Beispielwert','Beschreibung') @(
    @('ShareBasePath','W:\75084-Datenbanken\MSSQL\CCM\_MSSQL_GUI\01_PreInstall','Basisverzeichnis auf dem Share'),
    @('ModuleName',   'dbatools',                                                 'Name des Moduls und Unterordners (Standard: dbatools)')
))
B (p-style 'Heading2' '9.2 [sqmSQLTool]')
B (make-table @('Schlüssel','Beispielwert','Beschreibung') @(
    @('ShareBasePath','C:\CCM oder W:\...\DTC','Basisverzeichnis; darunter: sqmSQLTool\sqmSQLTool.psd1'),
    @('ModuleName',   'sqmSQLTool',             'Name des Moduls (Standard: sqmSQLTool)')
))

# 10. [Maintenance]
B (p-style 'Heading1' '10. [Maintenance] — Ola Hallengren')
B (make-table @('Schlüssel','Standardwert','Beschreibung') @(
    @('OlaSourcePath','(leer)','Lokaler Fallback-Pfad wenn GitHub nicht erreichbar. Leer = nur GitHub-Download (neueste Version).')
))

# 11. [PostInstall]
B (p-style 'Heading1' '11. [PostInstall] — PostInstall-Optionen')
B (make-table @('Schlüssel','Standardwert','Beschreibung') @(
    @('SplunkEnabled','false','true = Invoke-sqmSplunkConfiguration wird nach der Installation aufgerufen. false = Splunk-Konfiguration wird übersprungen.')
))

# 12. [SysadminGroups]
B (p-style 'Heading1' '12. [SysadminGroups] — AD-Sysadmin-Gruppen')
B (p-normal 'Definiert AD-Gruppen die nach der Installation zur sysadmin-Serverrolle hinzugefügt werden. Domänenspezifischer Eintrag hat Vorrang vor Standard.')
B (p-normal 'Sicherheitsprinzip: SA-Obfuscation wird nur ausgeführt wenn mindestens eine Gruppe erfolgreich zugewiesen wurde. So ist gewährleistet dass immer ein alternativer Sysadmin-Zugang existiert bevor der SA-Account verschleiert wird.')
B (make-table @('Schlüssel','Beispielwert','Beschreibung') @(
    @('Domain_CONTOSO','CONTOSO\Rg_SQL_Sysadmin',   'Sysadmin-Gruppe für Domäne CONTOSO (kommagetrennt für mehrere Gruppen)'),
    @('Domain_HLB',    'HLB\Fg_DC_SqlAdminAll_Mod', 'Sysadmin-Gruppe für Domäne HLB'),
    @('Standard',      '(leer)',                     'Fallback — leer = keine Gruppe, SA-Obfuscation wird übersprungen')
))

# 13. [Monitoring]
B (p-style 'Heading1' '13. [Monitoring] — Monitoring-Konfiguration')
B (make-table @('Schlüssel','Standardwert','Beschreibung') @(
    @('Enabled',      'true',                'Monitoring-Abschnitt im Formular anzeigen (false = ausblenden)'),
    @('DefaultType',  '1',                   'Standard-Typ: 0 = Kein Monitoring, 1 = Service Monitoring, 2 = Vollständiges Monitoring'),
    @('Domain_HLB',   '2',                   'Domänenspezifischer Standard-Typ für Domäne HLB'),
    @('Types',        'Kein Monitoring,...', 'Anzeigenamen für Combobox (kommagetrennt, Index = Typ-Wert 0/1/2)')
))

# 14. [OptionalComponents]
B (p-style 'Heading1' '14. [OptionalComponents] — Optionale Komponenten')
B (p-normal 'Steuert welche Komponenten-Checkboxen im Installationsformular sichtbar sind. true = Checkbox anzeigen, false = ausblenden. Im Formular werden SSMS und SSIS standardmässig angehakt.')
B (make-table @('Schlüssel','Standard','Beschreibung') @(
    @('SSRS_Enabled',   'true', 'SQL Server Reporting Services — eigenständiger Installer (SQLServerReportingServices.exe)'),
    @('SSAS_Enabled',   'true', 'SQL Server Analysis Services — via SQL-Setup.exe /FEATURES=AS'),
    @('SSMS_Enabled',   'true', 'SQL Server Management Studio — eigenständiger Installer. Im Formular: Standard gecheckt.'),
    @('SSIS_Enabled',   'true', 'Integration Services — Feature IS im SQL-Engine-Setup. Im Formular: Standard gecheckt.'),
    @('TDP_Enabled',    'true', 'IBM Spectrum Protect (TSM/TDP) Client'),
    @('SSRS_SourcePath','\\srv\SSRS','UNC-Pfad zum SSRS-Installer-Verzeichnis')
))

# 15. Entscheidungsmatrix
B (p-style 'Heading1' '15. Konfigurationsmatrix — Automatische Entscheidungslogik')
B (p-normal 'Das Tool trifft beim Start und während der Installation folgende automatische Entscheidungen basierend auf der erkannten Domäne und den INI-Einstellungen:')
B (make-table @('Entscheidung','Prüflogik','Ergebnis') @(
    @('Sortierung',       'Domain_<NAME> in [Collations] vorhanden?',    'Ja = Domänen-Sortierung; Nein = [Collations]Standard'),
    @('Laufwerke',        'DiskLayout_<NAME> Sektion vorhanden?',         'Ja = Domänen-Layout; Nein = DiskLayout_Standard'),
    @('Monitoring-Typ',   'Domain_<NAME> in [Monitoring] vorhanden?',    'Ja = Domänen-Wert; Nein = DefaultType'),
    @('Sysadmin-Gruppen', 'Domain_<NAME> in [SysadminGroups] vorhanden?','Ja = Domänen-Gruppe; Nein = Standard'),
    @('SA-Obfuscation',   'Schritt 7 (Gruppen) erfolgreich?',            'Ja = SA-Obfuscation durchführen; Nein = überspringen'),
    @('SSIS installieren','SSIS-Checkbox im Formular gecheckt?',          'Ja = IS in Features; Nein = IS wird entfernt'),
    @('Splunk-Config',    '[PostInstall] SplunkEnabled = true?',          'Ja = Invoke-sqmSplunkConfiguration; Nein = überspringen')
))

$doc1Body = $b1.ToString()

# ════════════════════════════════════════════════════════════════════════════════
# DOKUMENT 2 — Installationsablauf
# ════════════════════════════════════════════════════════════════════════════════
$b2 = [System.Text.StringBuilder]::new()
function C([string]$s) { [void]$b2.AppendLine($s) }

C (p-style 'Title'    'SQL Server Setup Tool')
C (p-style 'Subtitle' 'Installations- und PostInstall-Ablauf')
C (p-normal "dtcSoftware  |  Uwe Janke  |  Stand: $(Get-Date -Format 'MMMM yyyy')")
C (p-break)

# 1. Übersicht
C (p-style 'Heading1' '1. Übersicht')
C (p-normal 'Das SQL Server Setup Tool führt eine standardisierte, vollautomatische SQL-Server-Installation durch. Alle Phasen laufen in einem separaten Hintergrundthread — die GUI bleibt während der gesamten Installation bedienbar. Der Ablauf gliedert sich in vier Phasen:')
C (make-table @('Phase','Bezeichnung','Beschreibung') @(
    @('1','Vorbereitung',         'Installationsquellen vom Netzwerk-Share auf den lokalen Server kopieren'),
    @('2','SQL Server Installation','Install-DbaInstance (dbaTools) führt das SQL-Setup durch'),
    @('3','Optionale Komponenten','SSAS, SSRS, SSMS, TDP werden bei Bedarf nachinstalliert'),
    @('4','PostInstall',          '16 Konfigurationsschritte härten und optimieren die Instanz')
))

# 2. Voraussetzungen
C (p-style 'Heading1' '2. Voraussetzungen')
C (p-style 'Heading2' '2.1 Software')
C (make-table @('Komponente','Version','Hinweis') @(
    @('PowerShell',    '5.1+',  'Pflicht — auf allen Windows-Servern vorhanden'),
    @('dbaTools',      '2.x+',  'Wird vom Share kopiert wenn nicht vorhanden; Fallback: PowerShell Gallery'),
    @('sqmSQLTool',    '1.0+',  'dtcSoftware-Modul — wird automatisch in Modulpfad installiert'),
    @('.NET Framework','4.5+',  'Voraussetzung für dbaTools'),
    @('Administrator', 'Lokal', 'Das Setup-Tool muss mit lokalen Administrator-Rechten ausgeführt werden')
))
C (p-style 'Heading2' '2.2 Netzwerkfreigaben und Laufwerke')
C (p-normal 'Alle in [DiskLayout_Standard] konfigurierten Laufwerke (G:, H:, I:, F:, C:) müssen auf dem Zielserver vorhanden und beschreibbar sein. Das Tool warnt wenn ein Laufwerk fehlt, ermöglicht aber das Fortfahren nach Bestätigung. Die SQL-Quelldateien müssen im Share SourceShare unter dem Pfad SQL<Version>\SQL_Install bereitstehen.')

# 3. GUI-Bedienung
C (p-style 'Heading1' '3. GUI-Bedienung')
C (p-normal 'Starten: C:\CCM\SQLSetupTool\Main.ps1 (Als Administrator ausführen)')
C (p-style 'Heading2' '3.1 Formularfelder')
C (make-table @('Feld','Quelle (INI)','Beschreibung') @(
    @('Version',       '[General] DefaultVersion',     'SQL Server Version — aus Combobox wählen'),
    @('Edition',       '[General] DefaultEdition',     'SQL Server Edition — passt sich automatisch an Version an'),
    @('Instanzname',   '[General] DefaultInstanceName','MSSQLServer = Standard-Instanz; anderer Name = benannte Instanz'),
    @('Sortierung',    '[Collations]',                 'Domänenspezifische Vorgabe an erster Position der Combobox'),
    @('Service-Konto', '(manuell)',                    'Leer = NT SERVICE\MSSQLSERVER; Format: DOMAIN\User'),
    @('Laufwerke',     '[DiskLayout_*]',               'Aus INI vorbelegt; domänenspezifisch; manuell anpassbar'),
    @('Monitoring',    '[Monitoring]',                 '0 = Kein, 1 = Service Monitoring, 2 = Vollständig; domänenspezifisch vorbelegt'),
    @('SSRS/SSAS/SSMS','[OptionalComponents]',         'Nur sichtbar wenn in INI aktiviert; SSMS+SSIS standard gecheckt')
))
C (p-style 'Heading2' '3.2 Schaltflächen')
C (make-table @('Schaltfläche','Funktion','Hinweis') @(
    @('AD prüfen',          'Service-Konto validieren',    'Prüft AD-Existenz und Passwort. ACHTUNG: zählt zur Lockout-Policy!'),
    @('Quellen kopieren',   'Phase 1 starten',             'Kopiert SQL-Medien per Robocopy vom Share auf lokales Laufwerk'),
    @('Installation starten','Phasen 2-4 starten',        'Bestätigungsdialog mit Version/Edition/Instanz erscheint vorher'),
    @('Schliessen',         'Formular beenden',            'Laufende Operationen werden NICHT abgebrochen')
))

# 4. Phase 1
C (p-style 'Heading1' '4. Phase 1 — Quellen kopieren')
C (p-normal 'Kopiert alle benötigten Installationsmedien vom Netzwerk-Share auf das lokale Laufwerk (InstallDrive: C:). Der Updates-Unterordner wird mitgenommen und dient als Slipstream-Quelle.')
C (make-table @('Komponente','Quellpfad (Share)','Zielpfad (lokal)') @(
    @('SQL Engine + Updates','\\srv\SQLSources\SQL<Ver>\SQL_Install',  'C:\SQLSources\SQL<Ver>\SQL_Install'),
    @('SSRS',                '\\srv\SQLSources\SQL<Ver>\Reporting',    'C:\SQLSources\SQL<Ver>\Reporting'),
    @('SSMS',                '\\srv\SQLSources\SQL<Ver>\Management',   'C:\SQLSources\SQL<Ver>\Management'),
    @('SSAS + SSIS',         'Teil von SQL_Install',                   'Kein separater Copy nötig'),
    @('TDP',                 'TDP_SourcePath aus INI',                 'C:\SQLSources\TDP')
))

# 5. Phase 2
C (p-style 'Heading1' '5. Phase 2 — SQL Server Installation')
C (p-normal 'Ruft Install-DbaInstance (dbaTools) auf. Das Setup.exe läuft im Hintergrund unbeaufsichtigt.')
C (p-style 'Heading2' '5.1 Verzeichnisse erstellen')
C (p-normal 'Vor dem Setup erstellt das Tool alle SQL-Zielverzeichnisse und protokolliert ob sie neu angelegt oder bereits vorhanden waren.')
C (make-table @('Verzeichnis','Pfad (FI-TS Standard)','Verwendung') @(
    @('SysDB',  'F:\Microsoft SQL Server',        'System-Datenbanken master, model, msdb (INSTALLSQLDATADIR)'),
    @('DATA',   'G:\Daten\SQL\MSSQLSERVER\DATA',  'Benutzerdatenbankdateien (.mdf, .ndf)'),
    @('LOG',    'H:\Daten\SQL\MSSQLSERVER\LOG',   'Transaktionsprotokolle (.ldf)'),
    @('TempDB', 'I:\Daten\SQL\MSSQLSERVER\DATA',  'TempDB-Datendateien'),
    @('TempLog','I:\Daten\SQL\MSSQLSERVER\LOG',   'TempDB-Logdatei'),
    @('Backup', 'F:\Daten\SQL\Backup\MSSQLSERVER','SQL-Backups')
))
C (p-style 'Heading2' '5.2 Wichtige Install-DbaInstance Parameter')
C (make-table @('Parameter','Wert / Quelle','Bedeutung') @(
    @('Feature',          '[Installation] Features',             'z.B. Engine,FullText,IS (SSIS wird bei abgewählter Checkbox entfernt)'),
    @('InstallPath',      'C:\Program Files\Microsoft SQL Server','Binärdateien (INSTALLSHAREDDIR)'),
    @('SystemDbPath',     'F:\Microsoft SQL Server',             'System-DBs (INSTALLSQLDATADIR)'),
    @('AdminAccount',     '[Installation] SysAdminAccounts',    'Initiale sysadmin-Konten bei der Installation'),
    @('PerformVolumeMaintenanceTasks','InstantFileInit = true',  'Sofortige Dateiinitialisierung (IFI)'),
    @('UpdateSourcePath', 'SQL_Install\Updates\ (automatisch)', 'Slipstream-Update wenn Unterordner vorhanden')
))
C (p-style 'Heading2' '5.3 Bereitschaftsprüfung nach Installation')
C (p-normal 'Das Tool wartet nach Abschluss des Setups maximal 30 Sekunden (15 Versuche × 2 Sek.) auf die SQL-Instanz (Connect-DbaInstance). Erst wenn die Verbindung erfolgreich ist, starten Phase 3 und Phase 4.')

# 6. Phase 3
C (p-style 'Heading1' '6. Phase 3 — Optionale Komponenten')
C (p-normal 'Nur die im Formular angehakten Komponenten werden installiert. Reihenfolge: SSAS → SSRS → TDP → SSMS.')
C (make-table @('Komponente','Methode','Quellpfad') @(
    @('SSAS','Setup.exe /FEATURES=AS /QUIET','C:\SQLSources\SQL<Ver>\SQL_Install\setup.exe'),
    @('SSRS','SQLServerReportingServices.exe (eigenständig)','C:\SQLSources\SQL<Ver>\Reporting'),
    @('TDP', 'Platzhalter — TDP_SourcePath in INI setzen',  'C:\SQLSources\TDP'),
    @('SSMS','SSMS-Setup-*.exe /install /quiet /norestart', 'C:\SQLSources\SQL<Ver>\Management')
))
C (p-normal 'Hinweis SSAS: ExitCode 3010 (Neustart empfohlen) wird als Erfolg behandelt. Die SSAS-Sortierung ist identisch mit der gewählten Instanz-Sortierung.')
C (p-normal 'Hinweis SSIS: Integration Services wird als Feature des SQL-Engine-Setups (Phase 2) installiert, nicht als separate Komponente. Die Checkbox in der GUI steuert ob IS in die Feature-Liste aufgenommen wird.')

# 7. Phase 4
C (p-style 'Heading1' '7. Phase 4 — PostInstall (16 Schritte)')
C (p-normal 'Der PostInstall-Prozess konfiguriert und härtet die installierte SQL-Instanz gemäss FI-TS-Standard. Kritische Schritte brechen den Prozess bei Fehler ab. Unkritische Schritte protokollieren eine Warnung und fahren fort.')

C (p-style 'Heading3' 'Schritt 1 — NTFS-Berechtigungen')
C (p-normal 'Ruft Invoke-sqmNtfsSetup auf. Ermittelt SQL-Dienstkonten automatisch via SMO/WMI. Setzt NTFS-Berechtigungen auf DATA, LOG, TempDB, Backup-Verzeichnissen. Erstellt vorher ein Berechtigungs-Backup. Kritisch — bricht bei Fehler ab.')

C (p-style 'Heading3' 'Schritt 2 — Performance-Konfiguration')
C (p-normal 'Drei SQL-Instanz-Parameter werden gesetzt: Max Server Memory = 90% des physischen RAM (automatisch berechnet). MAXDOP = Min(8, Anzahl logischer CPUs). Cost Threshold for Parallelism = 50.')

C (p-style 'Heading3' 'Schritt 3 — SQL Server Agent')
C (p-normal 'Setzt SQL Server Agent-Dienst auf automatischen Start und startet ihn. Dienstname: SQLSERVERAGENT (Standard) oder SQLSERVERAGENT$<Instanzname> (benannte Instanz).')

C (p-style 'Heading3' 'Schritt 4 — TempDB-Optimierung')
C (p-normal 'Optimiert TempDB nach CPU-Anzahl: Dateidateizahl = Max(4, Min(8, logische CPUs)). Grösse und Wachstum aus [Installation] (1024 MB / 512 MB). Dateien werden auf die konfigurierten TempDB-Pfade verteilt.')

C (p-style 'Heading3' 'Schritt 5 — Recovery-Modell')
C (p-normal 'Setzt Recovery-Modell FULL für Systemdatenbanken (master/msdb) via Invoke-sqmSetDatabaseRecoveryMode.')

C (p-style 'Heading3' 'Schritt 6 — SQL Browser Service')
C (p-normal 'Stoppt und deaktiviert den SQL Browser Service. Steuerung via [Installation] BrowserSvcDisabled. Fehler = Warnung, nicht kritisch.')

C (p-style 'Heading3' 'Schritt 7 — AD-Sysadmin-Gruppen')
C (p-normal 'Weist [SysadminGroups]-Gruppen der sysadmin-Serverrolle zu (Add-DbaServerRoleMember). Domänenspezifischer Eintrag hat Vorrang. Ergebnis steuert ob Schritt 8 ausgeführt wird.')

C (p-style 'Heading3' 'Schritt 8 — SA-Obfuscation')
C (p-normal 'Nur wenn Schritt 7 mindestens eine Gruppe erfolgreich zugewiesen hat. Invoke-sqmSaObfuscation: SA-Konto wird umbenannt und erhält ein langes Zufallspasswort. Sicherheitsbedingung: weiteres aktives sysadmin-Login muss existieren (SID 0x01-Check). Passwort wird nur im Rückgabeobjekt ausgegeben — sicher verwahren!')

C (p-style 'Heading3' 'Schritt 9 — Monitoring-Key')
C (p-normal 'Schreibt Monitoring-Registry-Schlüssel via Invoke-sqmMonitoringKey. Parameter: SQL-Monitoring-Typ (0/1/2 aus Formular) und TSM-Status (aktiv wenn TDP-Checkbox gecheckt).')

C (p-style 'Heading3' 'Schritt 10 — Instanz-Validierung')
C (p-normal 'Best-Practice-Check via Get-sqmSQLInstanceCheck. Prüft Konfiguration, Dienststatus und Erreichbarkeit. Ergebnis-Status wird protokolliert.')

C (p-style 'Heading3' 'Schritt 11 — Benutzerdefiniertes PostInstall-Script')
C (p-normal 'Optional: Wenn Config\Scripts\PostInstall.ps1 existiert, wird es mit -SqlInstance und -LogCallback aufgerufen. Ermöglicht standortspezifische Erweiterungen ohne Tool-Änderungen.')

C (p-style 'Heading3' 'Schritt 12 — Ola Hallengren Maintenance Solution')
C (p-normal 'Installiert Ola Hallengren Maintenance Solution via Install-sqmOlaMaintenanceSolution. Primär: GitHub (neueste Version). Fallback: OlaSourcePath aus [Maintenance]. Wenn nicht verfügbar: Schritt wird übersprungen, Schritte 13-15 entfallen.')

C (p-style 'Heading3' 'Schritt 13 — Maintenance Jobs')
C (p-normal 'Erstellt SQL Agent Jobs: IndexOptimize - USER_DATABASES (Index-Optimierung) und IntegrityCheck - ALL_DATABASES (Integritätsprüfung) via New-sqmOlaMaintenanceJobs.')

C (p-style 'Heading3' 'Schritt 14 — System-DB Backup Job')
C (p-normal 'Erstellt SQL Agent Job FITS-SystemDatabases-FULL für tägliche Backups von master, model, msdb via New-sqmOlaSysDbBackupJob.')

C (p-style 'Heading3' 'Schritt 15 — User-DB Backup Jobs')
C (p-normal 'Erstellt drei SQL Agent Jobs via New-sqmOlaUsrDbBackupJob: FITS-UserDatabases-FULL (wöchentlich), FITS-UserDatabases-DIFF (täglich), FITS-UserDatabases-LOG (stündlich).')

C (p-style 'Heading3' 'Schritt 16 — Splunk Universal Forwarder')
C (p-normal 'Nur wenn [PostInstall] SplunkEnabled = true. Ruft Invoke-sqmSplunkConfiguration auf. Konfiguriert den Splunk Universal Forwarder für SQL-Monitoring. Fehler = Warnung, nicht kritisch.')

# 8. Übersichtstabelle
C (p-style 'Heading1' '8. PostInstall-Schritte im Überblick')
C (make-table @('Schritt','Name','Kritisch','Bedingung') @(
    @('1',  'NTFS-Berechtigungen',       'Ja',  '—'),
    @('2',  'Performance-Parameter',     'Ja',  '—'),
    @('3',  'SQL Agent autostart',       'Ja',  '—'),
    @('4',  'TempDB-Optimierung',        'Ja',  '—'),
    @('5',  'Recovery-Modell FULL',      'Ja',  '—'),
    @('6',  'SQL Browser deaktivieren',  'Nein','BrowserSvcDisabled = true'),
    @('7',  'AD-Sysadmin-Gruppen',       'Nein','[SysadminGroups] konfiguriert'),
    @('8',  'SA-Obfuscation',            'Nein','Schritt 7 mindestens 1 Gruppe zugewiesen'),
    @('9',  'Monitoring-Key',            'Ja',  '—'),
    @('10', 'Instanz-Validierung',       'Ja',  '—'),
    @('11', 'Custom PostInstall-Script', 'Nein','Script-Datei vorhanden'),
    @('12', 'Ola Hallengren',            'Nein','GitHub oder OlaSourcePath erreichbar'),
    @('13', 'Maintenance Jobs',          'Nein','Schritt 12 erfolgreich'),
    @('14', 'System-DB Backup Job',      'Nein','Schritt 12 erfolgreich'),
    @('15', 'User-DB Backup Jobs',       'Nein','Schritt 12 erfolgreich'),
    @('16', 'Splunk-Konfiguration',      'Nein','SplunkEnabled = true')
))

# 9. Verzeichnisstruktur
C (p-style 'Heading1' '9. Verzeichnisstruktur nach erfolgreicher Installation')
C (make-table @('Pfad','Inhalt') @(
    @('C:\Program Files\Microsoft SQL Server','SQL-Binärdateien (INSTALLSHAREDDIR)'),
    @('F:\Microsoft SQL Server',              'System-DBs: master, model, msdb (INSTALLSQLDATADIR)'),
    @('G:\Daten\SQL\MSSQLSERVER\DATA',        'Benutzerdatenbankdateien (.mdf, .ndf)'),
    @('H:\Daten\SQL\MSSQLSERVER\LOG',         'Transaktionsprotokolle (.ldf)'),
    @('I:\Daten\SQL\MSSQLSERVER\DATA',        'TempDB-Datendateien (4–8 Dateien je nach CPU-Anzahl)'),
    @('I:\Daten\SQL\MSSQLSERVER\LOG',         'TempDB-Logdatei'),
    @('F:\Daten\SQL\Backup\MSSQLSERVER',      'SQL-Backups (Ola Hallengren Jobs)')
))
C (p-style 'Heading1' '10. SQL Agent Jobs nach PostInstall')
C (make-table @('Job-Name','Typ','Erstellt durch') @(
    @('FITS IndexOptimize - USER_DATABASES', 'Wöchentliche Index-Optimierung',  'Schritt 13'),
    @('FITS IntegrityCheck - ALL_DATABASES', 'Wöchentliche Integritätsprüfung', 'Schritt 13'),
    @('FITS-SystemDatabases-FULL',           'Tägliches System-DB Backup',      'Schritt 14'),
    @('FITS-UserDatabases-FULL',             'Wöchentliches FULL-Backup',       'Schritt 15'),
    @('FITS-UserDatabases-DIFF',             'Tägliches DIFF-Backup',           'Schritt 15'),
    @('FITS-UserDatabases-LOG',              'Stündliches LOG-Backup',          'Schritt 15')
))

# 11. Fehlerbehebung
C (p-style 'Heading1' '11. Fehlerbehebung')
C (make-table @('Symptom','Ursache','Lösung') @(
    @('Install-DbaInstance schlägt fehl',   'Quellen nicht kopiert',         'Erst Phase 1 (Quellen kopieren) ausführen. setup.exe unter C:\SQLSources\SQL<Ver>\SQL_Install prüfen.'),
    @('SQL Server nach Install unerreichbar','Dienst noch nicht bereit',      'Tool wartet 30 Sek. automatisch. Danach: Get-Service MSSQLSERVER prüfen.'),
    @('NTFS-Schritt fehlgeschlagen',        'Kein WMI-Zugriff',              'Als Administrator ausführen. WMI-Dienst (winmgmt) prüfen.'),
    @('SA-Obfuscation: AbortedNoSysadmin',  'Kein weiteres sysadmin-Login',  '[SysadminGroups] konfigurieren — Schritt 7 muss zuerst erfolgreich sein.'),
    @('Ola-Installation schlägt fehl',      'Kein Internet, kein lokaler Pfad','OlaSourcePath in [Maintenance] auf entpacktes ZIP-Verzeichnis setzen.'),
    @('dbaTools nicht verfügbar',           'Share unerreichbar',            'dbaTools manuell installieren: Install-Module dbatools -Scope AllUsers'),
    @('Laufwerk nicht gefunden (Warnung)',  'Laufwerk fehlt oder offline',   'Formular zeigt Warndialog — nach Bestätigung kann fortgefahren werden')
))

$doc2Body = $b2.ToString()

# ── Dokumente erzeugen ────────────────────────────────────────────────────────
New-Docx -outPath "C:\CCM\SQLSetupTool\Docs\SQLSetupTool_Konfigurationsreferenz.docx" `
         -title  'SQL Server Setup Tool — Konfigurationsreferenz' `
         -author 'Uwe Janke — dtcSoftware' `
         -bodyXml $doc1Body

New-Docx -outPath "C:\CCM\SQLSetupTool\Docs\SQLSetupTool_Installationsablauf.docx" `
         -title  'SQL Server Setup Tool — Installations- und PostInstall-Ablauf' `
         -author 'Uwe Janke — dtcSoftware' `
         -bodyXml $doc2Body
