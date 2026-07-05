Add-Type -AssemblyName System.Windows.Forms

$resultFile = Join-Path $env:TEMP 'ps2exe-test-result.txt'
$info = @"
ps2exe-Test erfolgreich ausgefuehrt.
Zeit       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Host       : $env:COMPUTERNAME
Benutzer   : $env:USERDOMAIN\$env:USERNAME
PSVersion  : $($PSVersionTable.PSVersion)
ProcessPath: $([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
"@

Write-Host $info
Set-Content -Path $resultFile -Value $info -Encoding UTF8

[System.Windows.Forms.MessageBox]::Show(
    "$info`n`nErgebnis auch gespeichert in:`n$resultFile",
    'ps2exe-Test',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null
