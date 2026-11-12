# Installs the CPU Eco tray switch from whatever folder this script sits in:
# checks the script, builds the icon, writes the hidden-window launcher, (re)creates the Start menu
# shortcut and any taskbar pin, then starts the tray switch through Explorer.
# Re-run it after moving the folder.
$folder = $PSScriptRoot
$mainScript = Join-Path $folder 'EcoToggle.ps1'
$iconPath = Join-Path $folder 'EcoToggle.ico'
$launcher = Join-Path $folder 'EcoToggle.vbs'

$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { "PARSE ERROR line $($_.Extent.StartLineNumber): $($_.Message)" }
    return
}
'Script parses OK'

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -ExportIcon $iconPath
"Icon: $iconPath"

$vbs = @(
    "' Launches the CPU Eco tray switch without a console window.",
    "' If it is already running, this toggles it ON/OFF instead.",
    'Set shell = CreateObject("WScript.Shell")',
    ('shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""' + $mainScript + '""", 0, False')
)
Set-Content -Path $launcher -Value $vbs -Encoding ASCII
"Launcher: $launcher"

$shell = New-Object -ComObject WScript.Shell
$shortcutPaths = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'CPU Eco Toggle.lnk')
)
$pinnedPath = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\CPU Eco Toggle.lnk'
if (Test-Path $pinnedPath) {
    $shortcutPaths += $pinnedPath
}
foreach ($shortcutPath in $shortcutPaths) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $shortcut.Arguments = '"' + $launcher + '"'
    $shortcut.WorkingDirectory = $folder
    $shortcut.IconLocation = $iconPath
    $shortcut.Description = 'CPU Eco: switch background-process limits on/off'
    $shortcut.Save()
    "Shortcut: $shortcutPath"
}

Start-Process explorer.exe -ArgumentList ('"' + $shortcutPaths[0] + '"')
'Launched'
