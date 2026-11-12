# CPU Eco toggle - tray icon + pinnable taskbar switch.
#
# ON : background workloads (opencode agents, cargo/rustc builds, headless Edge, Python jobs,
#      Ollama/llama-server) run on fewer cores at BelowNormal priority. Nothing is stopped.
#      Processes with a visible window and anything started by Vector are never touched.
#      New background processes are picked up every 30 s while ON.
# OFF: every process changed by this tool gets its original priority and cores back.
#
# Left-click the tray icon to toggle. Launching the script again while it runs also toggles
# (that is what the pinned taskbar button does). Right-click for status, memory trim and exit.

param(
    [string]$ExportIcon
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-EcoBitmap([int]$size, [bool]$isOn) {
    $bitmap = New-Object System.Drawing.Bitmap($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    if ($isOn) {
        $fillColor = [System.Drawing.Color]::FromArgb(34, 170, 85)
    }
    else {
        $fillColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
    }
    $brush = New-Object System.Drawing.SolidBrush($fillColor)
    $graphics.FillEllipse($brush, 0, 0, $size - 1, $size - 1)

    # White power symbol: open arc plus a vertical bar through the gap.
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single][math]::Max(2, $size / 10))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $inset = [single]($size * 0.27)
    $arcSize = [single]($size - 2 * $inset)
    $graphics.DrawArc($pen, $inset, $inset, $arcSize, $arcSize, [single]300, [single]300)
    $center = [single]($size / 2)
    $graphics.DrawLine($pen, $center, [single]($size * 0.18), $center, [single]($size * 0.5))

    $pen.Dispose()
    $brush.Dispose()
    $graphics.Dispose()
    return $bitmap
}

# --- Icon export for the taskbar shortcut (PNG-in-ICO) ----------------------------------
if ($ExportIcon) {
    $bitmap = New-EcoBitmap 64 $true
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $stream.ToArray()
    $file = [System.IO.File]::Create($ExportIcon)
    $writer = New-Object System.IO.BinaryWriter($file)
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]1)
    $writer.Write([byte]64)
    $writer.Write([byte]64)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$png.Length)
    $writer.Write([uint32]22)
    $writer.Write($png)
    $writer.Close()
    return
}

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -Namespace EcoNative -Name Psapi -MemberDefinition @'
[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess);
'@

$appName = 'CPU Eco'
$logPath = Join-Path $PSScriptRoot 'EcoToggle.log'

function Write-Log([string]$message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $message
    Add-Content -Path $logPath -Value $line
}

# --- Single instance: a second launch just asks the running copy to toggle ---------------
$isFirstInstance = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CpuEcoToggle', [ref]$isFirstInstance)
$toggleSignal = New-Object System.Threading.EventWaitHandle(
    $false,
    [System.Threading.EventResetMode]::AutoReset,
    'Local\CpuEcoToggle.Toggle'
)
if (-not $isFirstInstance) {
    [void]$toggleSignal.Set()
    return
}

# --- Settings -----------------------------------------------------------------------------
$coreCount = [Environment]::ProcessorCount
$allCoresMask = [int64]([math]::Pow(2, $coreCount) - 1)
$freeCoreCount = [math]::Max(1, [int][math]::Round($coreCount * 3 / 8))   # 3 of 8 cores stay free
$ecoMask = $allCoresMask -band (-bnot [int64]([math]::Pow(2, $freeCoreCount) - 1))
$legacyMasks = @(0xFC, 0xF8)          # limits applied manually earlier in chat
$backgroundNames = @('opencode', 'cargo', 'rustc', 'ollama', 'llama-server', 'msedge', 'python', 'pythonw')
$reapplyEveryTicks = 10               # 10 x 3 s = 30 s

$script:ecoOn = $false
$script:changed = @{}                 # pid -> original Priority / Affinity / StartTime
$script:tickCount = 0

# --- Process selection ----------------------------------------------------------------------
function Test-UnderVector([hashtable]$byId, [int]$id) {
    $seen = @{}
    while ($byId.ContainsKey($id) -and -not $seen.ContainsKey($id)) {
        $seen[$id] = $true
        if ($byId[$id].Name -eq 'Vector.exe') {
            return $true
        }
        $id = [int]$byId[$id].ParentProcessId
    }
    return $false
}

function Get-BackgroundTargetIds {
    $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine
    $byId = @{}
    foreach ($p in $all) {
        $byId[[int]$p.ProcessId] = $p
    }
    foreach ($p in $all) {
        $name = $p.Name -replace '\.exe$', ''
        if ($backgroundNames -notcontains $name) {
            continue
        }
        # Only the headless automation browser, never the Edge you browse with.
        if ($name -eq 'msedge' -and "$($p.CommandLine)" -notmatch '--headless') {
            continue
        }
        if (Test-UnderVector $byId ([int]$p.ProcessId)) {
            continue
        }
        [int]$p.ProcessId
    }
}

function Invoke-EcoLimits {
    foreach ($id in Get-BackgroundTargetIds) {
        if ($script:changed.ContainsKey($id)) {
            continue
        }
        try {
            $proc = [System.Diagnostics.Process]::GetProcessById($id)
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                continue      # has a visible window: interactive, leave it at full speed
            }
            $original = @{
                Priority = $proc.PriorityClass
                Affinity = [int64]$proc.ProcessorAffinity
                Start    = $proc.StartTime
            }
            $proc.ProcessorAffinity = [IntPtr]$ecoMask
            if ($proc.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::Idle) {
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
            }
            $script:changed[$id] = $original
        }
        catch {
        }
    }
}

function Restore-AllLimits {
    $restored = 0
    foreach ($id in @($script:changed.Keys)) {
        $original = $script:changed[$id]
        try {
            $proc = [System.Diagnostics.Process]::GetProcessById($id)
            if ($proc.StartTime -eq $original.Start) {
                $proc.ProcessorAffinity = [IntPtr]$original.Affinity
                $proc.PriorityClass = $original.Priority
                $restored++
            }
        }
        catch {
        }
    }
    $script:changed.Clear()

    # Child processes (e.g. rustc under cargo) inherit the eco cores from their parent without
    # being tracked; release anything still on an eco/legacy mask too.
    foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $mask = [int64]$proc.ProcessorAffinity
            if ($mask -ne $allCoresMask -and ($mask -eq $ecoMask -or $legacyMasks -contains $mask)) {
                $proc.ProcessorAffinity = [IntPtr]$allCoresMask
                if ($proc.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::BelowNormal) {
                    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
                }
                $restored++
            }
        }
        catch {
        }
    }
    return $restored
}

function Add-LegacyLimits {
    # Adopt processes limited earlier by hand so OFF restores them too.
    $adopted = 0
    foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $mask = [int64]$proc.ProcessorAffinity
            if ($legacyMasks -contains $mask -and $mask -ne $allCoresMask) {
                $priority = [System.Diagnostics.ProcessPriorityClass]::Normal
                if ($proc.ProcessName -eq 'llama-server') {
                    $priority = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
                }
                $script:changed[$proc.Id] = @{
                    Priority = $priority
                    Affinity = $allCoresMask
                    Start    = $proc.StartTime
                }
                $adopted++
            }
        }
        catch {
        }
    }
    return $adopted
}

function Invoke-MemoryTrim {
    $before = $computerInfo.AvailablePhysicalMemory
    foreach ($id in Get-BackgroundTargetIds) {
        try {
            $proc = [System.Diagnostics.Process]::GetProcessById($id)
            if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
                [void][EcoNative.Psapi]::EmptyWorkingSet($proc.Handle)
            }
        }
        catch {
        }
    }
    Start-Sleep -Milliseconds 1500
    $freedGB = ($computerInfo.AvailablePhysicalMemory - $before) / 1GB
    return [math]::Max(0, $freedGB)
}

# --- Tray UI --------------------------------------------------------------------------------
$iconOn = [System.Drawing.Icon]::FromHandle((New-EcoBitmap 32 $true).GetHicon())
$iconOff = [System.Drawing.Icon]::FromHandle((New-EcoBitmap 32 $false).GetHicon())
$computerInfo = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
try {
    $cpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
    [void]$cpuCounter.NextValue()
}
catch {
    $cpuCounter = $null
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$toggleItem = $menu.Items.Add('Turn ON')
$statusItem = $menu.Items.Add('')
$statusItem.Enabled = $false
$trimItem = $menu.Items.Add('Trim background memory now')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitItem = $menu.Items.Add('Exit (restores everything)')
$notifyIcon.ContextMenuStrip = $menu

function Update-TrayUi {
    $cpuText = '?'
    if ($cpuCounter) {
        $cpuText = [int]$cpuCounter.NextValue()
    }
    $ramUsed = 100 * (1 - $computerInfo.AvailablePhysicalMemory / $computerInfo.TotalPhysicalMemory)
    if ($script:ecoOn) {
        $notifyIcon.Icon = $iconOn
        $state = 'ON'
        $toggleItem.Text = 'Turn OFF (restore full speed)'
        $statusItem.Text = "Limiting $($script:changed.Count) background processes to $($coreCount - $freeCoreCount) of $coreCount cores"
    }
    else {
        $notifyIcon.Icon = $iconOff
        $state = 'OFF'
        $toggleItem.Text = 'Turn ON (limit background work)'
        $statusItem.Text = 'Off - nothing is limited'
    }
    $notifyIcon.Text = ('{0}: {1} | CPU {2}% | RAM {3:N0}%' -f $appName, $state, $cpuText, $ramUsed)
}

function Switch-Eco {
    try {
        if ($script:ecoOn) {
            $count = Restore-AllLimits
            $script:ecoOn = $false
            $notifyIcon.ShowBalloonTip(2500, "$appName OFF", "Full speed restored for $count processes.", 'Info')
            Write-Log "OFF - restored $count processes"
        }
        else {
            $script:ecoOn = $true
            Invoke-EcoLimits
            $notifyIcon.ShowBalloonTip(
                2500,
                "$appName ON",
                "$($script:changed.Count) background processes limited to $($coreCount - $freeCoreCount) of $coreCount cores. Nothing was stopped.",
                'Info'
            )
            Write-Log "ON - limited $($script:changed.Count) processes"
        }
        Update-TrayUi
    }
    catch {
        Write-Log "toggle error: $($_.Exception.Message)"
    }
}

$notifyIcon.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Switch-Eco
    }
})
$toggleItem.Add_Click({
    Switch-Eco
})
$trimItem.Add_Click({
    try {
        $freed = Invoke-MemoryTrim
        $notifyIcon.ShowBalloonTip(2500, $appName, ('Freed about {0:N1} GB of RAM from background processes.' -f $freed), 'Info')
        Write-Log ('memory trim freed {0:N1} GB' -f $freed)
        Update-TrayUi
    }
    catch {
        Write-Log "trim error: $($_.Exception.Message)"
    }
})
$exitItem.Add_Click({
    if ($script:ecoOn) {
        [void](Restore-AllLimits)
    }
    Write-Log 'exit - everything restored'
    $notifyIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    try {
        if ($toggleSignal.WaitOne(0)) {
            Switch-Eco
        }
        $script:tickCount++
        if ($script:ecoOn -and ($script:tickCount % $reapplyEveryTicks -eq 0)) {
            Invoke-EcoLimits
        }
        Update-TrayUi
    }
    catch {
        Write-Log "timer error: $($_.Exception.Message)"
    }
})

# Start in the state the PC is actually in: ON if earlier limits are still active.
$adoptedCount = Add-LegacyLimits
if ($adoptedCount -gt 0) {
    $script:ecoOn = $true
    Invoke-EcoLimits
}
Write-Log "started - eco is $(if ($script:ecoOn) { 'ON' } else { 'OFF' }) ($($script:changed.Count) processes tracked)"

$notifyIcon.Visible = $true
Update-TrayUi
$timer.Start()
try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $mutex.ReleaseMutex()
}
