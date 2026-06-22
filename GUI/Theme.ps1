#Requires -Version 5.1
<#
    GUI\Theme.ps1 - Visual Studio "Dark" Theme fuer die SQLSetupTool-WinForms-GUIs.

    Identische Palette wie sqmSQLTool\Show-sqmToolGui (VS "Dark").
    Verwendung: am Ende des Formularaufbaus (vor ShowDialog / Application::Run):

        . (Join-Path $PSScriptRoot 'Theme.ps1')
        $palette = Get-VsDarkPalette
        $form.BackColor = $palette.Panel
        $form.ForeColor = $palette.Text
        Set-VsDarkTheme -Control $form -Palette $palette

    Set-VsDarkTheme faerbt rekursiv alle Kind-Controls anhand ihres Typs. Bewusst gesetzte
    semantische Farben (Status gruen/rot, Konsolen-Gruen der Logboxen, Hinweis-Orange/Blau) werden
    auf dunkel-taugliche Varianten gemappt statt plump ueberschrieben.
#>

function Get-VsDarkPalette {
    @{
        Window = [System.Drawing.Color]::FromArgb(30, 30, 30)    # Editoren / Logboxen
        Panel  = [System.Drawing.Color]::FromArgb(45, 45, 48)    # Formular / Panels / GroupBox
        Text   = [System.Drawing.Color]::FromArgb(220, 220, 220) # Vordergrund
        Dim    = [System.Drawing.Color]::FromArgb(153, 153, 153) # sekundaerer Text
        Btn    = [System.Drawing.Color]::FromArgb(62, 62, 66)    # Buttons
        Accent = [System.Drawing.Color]::FromArgb(0, 122, 204)   # VS-Blau
        Border = [System.Drawing.Color]::FromArgb(63, 63, 70)
    }
}

# Mappt eine (oft bewusst gesetzte) Vordergrundfarbe auf eine dunkel-taugliche Variante.
function ConvertTo-VsDarkForeground {
    param(
        [System.Drawing.Color]$Color,
        [hashtable]$Palette
    )
    switch -Regex ($Color.Name) {
        '^(ControlText|WindowText|Black)$'                  { return $Palette.Text }
        '^(Blue|DarkBlue|Navy|MidnightBlue|MediumBlue)$'    { return $Palette.Accent }
        '^(DarkOrange|Orange|Goldenrod|DarkGoldenrod)$'     { return [System.Drawing.Color]::FromArgb(230, 160, 60) }
        '^(Green|DarkGreen|ForestGreen|SeaGreen)$'          { return [System.Drawing.Color]::FromArgb(120, 200, 120) }
        '^(LightGreen|LimeGreen|Lime|GreenYellow|Chartreuse)$' { return $Color }  # Konsolen-Gruen bleibt
        '^(Red|DarkRed|Firebrick|Crimson|Maroon)$'          { return [System.Drawing.Color]::FromArgb(240, 110, 110) }
        '^(Gray|DarkGray|Silver|DimGray|LightGray|Gainsboro)$' { return $Palette.Dim }
        default {
            # Bereits helle Farben behalten, dunkle auf Standard-Text heben.
            if (($Color.R + $Color.G + $Color.B) -gt 360) { return $Color }
            return $Palette.Text
        }
    }
}

function Set-VsDarkTheme {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$Control,
        [hashtable]$Palette = (Get-VsDarkPalette)
    )
    $p = $Palette
    foreach ($c in $Control.Controls) {
        if ($c -is [System.Windows.Forms.Button]) {
            $c.FlatStyle = 'Flat'
            $c.BackColor = $p.Btn
            $c.ForeColor = $p.Text
            $c.FlatAppearance.BorderColor = $p.Border
            $c.FlatAppearance.MouseOverBackColor = $p.Accent
        }
        elseif ($c -is [System.Windows.Forms.TextBoxBase] -or
                $c -is [System.Windows.Forms.ListControl]  -or
                $c -is [System.Windows.Forms.DataGridView]) {
            $c.BackColor = $p.Window
            $c.ForeColor = (ConvertTo-VsDarkForeground -Color $c.ForeColor -Palette $p)
            if ($c -is [System.Windows.Forms.ComboBox]) { try { $c.FlatStyle = 'Flat' } catch { } }
            if ($c -is [System.Windows.Forms.DataGridView]) {
                try {
                    $c.EnableHeadersVisualStyles = $false
                    $c.BackgroundColor = $p.Window
                    $c.GridColor       = $p.Border
                    $c.DefaultCellStyle.BackColor          = $p.Window
                    $c.DefaultCellStyle.ForeColor          = $p.Text
                    $c.DefaultCellStyle.SelectionBackColor = $p.Accent
                    $c.ColumnHeadersDefaultCellStyle.BackColor = $p.Panel
                    $c.ColumnHeadersDefaultCellStyle.ForeColor = $p.Text
                    $c.RowHeadersDefaultCellStyle.BackColor    = $p.Panel
                    $c.RowHeadersDefaultCellStyle.ForeColor    = $p.Text
                } catch { }
            }
        }
        else {
            # Form/Panel/GroupBox/TabControl/TabPage/Label/CheckBox/RadioButton/LinkLabel/ProgressBar/...
            $c.BackColor = $p.Panel
            $c.ForeColor = (ConvertTo-VsDarkForeground -Color $c.ForeColor -Palette $p)
        }
        if ($c.HasChildren) { Set-VsDarkTheme -Control $c -Palette $p }
    }
}
