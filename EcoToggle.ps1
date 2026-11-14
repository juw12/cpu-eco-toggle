# CPU Eco toggle - tray icon + pinnable taskbar switch.
#
# Vector guard (always, ON or OFF): background workloads (opencode agents, cargo/rustc and Lean
#      builds, headless Edge, Python jobs, Ollama/llama-server) run at BelowNormal priority, so
#      the apps you are using - Vector included - get the CPU first. A tray warning appears when
#      Windows is about to run out of virtual memory, because that is what makes apps crash.
#      Processes with a visible window and anything started by Vector are never touched.
#      New background processes are picked up every 30 s. Nothing is stopped.
# ON : the same background workloads are also kept off some cores.
# OFF: the cores are given back. The guard priority stays.
# Exit: every process changed by this tool gets its original priority and cores back.
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
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace EcoNative
{
    public static class Psapi
    {
        [DllImport("psapi.dll")]
        public static extern bool EmptyWorkingSet(IntPtr hProcess);
    }

    public class ProcessEntry
    {
        public int ProcessId;
        public int ParentProcessId;
        public string Name;
    }

    // One cheap snapshot of every process (id, parent id, exe name). The WMI query it replaces
    // took about 5 s on a busy PC, too slow to repeat every 30 s on the tray's UI thread.
    public static class ProcessTable
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll")]
        private static extern bool GetProcessAffinityMask(IntPtr process, out IntPtr processMask, out IntPtr systemMask);

        // Core mask of every process that can be opened; the rest are left out. Asking .NET
        // instead costs about half a second for each process that refuses (services, other
        // users), which froze the tray for two minutes on a busy PC.
        public static Dictionary<int, long> GetAffinityMasks(int[] processIds)
        {
            const uint QueryLimitedInformation = 0x1000;
            Dictionary<int, long> masks = new Dictionary<int, long>();
            foreach (int processId in processIds)
            {
                IntPtr process = OpenProcess(QueryLimitedInformation, false, processId);
                if (process == IntPtr.Zero)
                {
                    continue;
                }
                IntPtr processMask;
                IntPtr systemMask;
                if (GetProcessAffinityMask(process, out processMask, out systemMask))
                {
                    masks[processId] = processMask.ToInt64();
                }
                CloseHandle(process);
            }
            return masks;
        }

        public static ProcessEntry[] Get()
        {
            const uint SnapProcess = 0x2;
            List<ProcessEntry> result = new List<ProcessEntry>();
            IntPtr snapshot = CreateToolhelp32Snapshot(SnapProcess, 0);
            if (snapshot == new IntPtr(-1))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            try
            {
                PROCESSENTRY32 entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                bool more = Process32FirstW(snapshot, ref entry);
                while (more)
                {
                    // An ended process stays listed with no threads while something still
                    // holds a handle to it; skip those.
                    if (entry.cntThreads > 0)
                    {
                        ProcessEntry item = new ProcessEntry();
                        item.ProcessId = (int)entry.th32ProcessID;
                        item.ParentProcessId = (int)entry.th32ParentProcessID;
                        item.Name = entry.szExeFile;
                        result.Add(item);
                    }
                    more = Process32NextW(snapshot, ref entry);
                }
            }
            finally
            {
                CloseHandle(snapshot);
            }
            return result.ToArray();
        }
    }

    public static class Windows
    {
        private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr window, uint command);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        // Ids of all processes that own a visible main window, found in one pass over the
        // desktop. Same rule as Process.MainWindowHandle, which repeats that pass per process.
        public static int[] GetWindowOwnerIds()
        {
            const uint GetOwner = 4;
            Dictionary<int, bool> ownerIds = new Dictionary<int, bool>();
            EnumWindowsCallback callback = delegate(IntPtr window, IntPtr parameter)
            {
                if (IsWindowVisible(window) && GetWindow(window, GetOwner) == IntPtr.Zero)
                {
                    uint processId;
                    GetWindowThreadProcessId(window, out processId);
                    ownerIds[(int)processId] = true;
                }
                return true;
            };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            int[] result = new int[ownerIds.Count];
            ownerIds.Keys.CopyTo(result, 0);
            return result;
        }
    }

    public static class Memory
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct PERFORMANCE_INFORMATION
        {
            public uint cb;
            public UIntPtr CommitTotal;
            public UIntPtr CommitLimit;
            public UIntPtr CommitPeak;
            public UIntPtr PhysicalTotal;
            public UIntPtr PhysicalAvailable;
            public UIntPtr SystemCache;
            public UIntPtr KernelTotal;
            public UIntPtr KernelPaged;
            public UIntPtr KernelNonpaged;
            public UIntPtr PageSize;
            public uint HandleCount;
            public uint ProcessCount;
            public uint ThreadCount;
        }

        [DllImport("psapi.dll", SetLastError = true)]
        private static extern bool GetPerformanceInfo(out PERFORMANCE_INFORMATION info, uint size);

        // Virtual memory (RAM + pagefile) Windows can still hand out, in GB.
        // When this reaches zero, allocations fail and apps crash.
        public static double GetCommitFreeGB()
        {
            PERFORMANCE_INFORMATION info;
            uint size = (uint)Marshal.SizeOf(typeof(PERFORMANCE_INFORMATION));
            if (!GetPerformanceInfo(out info, size))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            double freePages = (double)info.CommitLimit.ToUInt64() - (double)info.CommitTotal.ToUInt64();
            return freePages * info.PageSize.ToUInt64() / (1024.0 * 1024.0 * 1024.0);
        }
    }
}
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
$backgroundNames = @(
    'opencode', 'cargo', 'rustc', 'lean', 'lake', 'ollama', 'llama-server', 'msedge', 'python', 'pythonw'
)
$reapplyEveryTicks = 10               # 10 x 3 s = 30 s
$guardCommitFreeGB = 6                # warn when less virtual memory than this is left
$restartVectorAfterCrash = $true      # start Vector again after a crash (never after you close it)
$maxVectorRestartsPerHour = 3         # then stop, so a crash loop cannot keep going
$afterRestartScript = Join-Path $PSScriptRoot 'after_vector_restart.ps1'   # optional, runs after a restart

$script:ecoOn = $false
$script:changed = @{}                 # pid -> original Priority / Affinity / StartTime, Limited = on eco cores
$script:headlessEdge = @{}            # msedge pid -> is it a headless automation browser?
$script:memoryWarned = $false
$script:tickCount = 0
$script:restartVector = $restartVectorAfterCrash
$script:vectorProcess = $null         # Vector's main process, held open so its exit code can be read
$script:vectorExePath = $null
$script:vectorGoneAt = $null          # when that process ended
$script:vectorCrashed = $false        # it ended with an error and has not been restarted yet
$script:vectorRestarts = @()          # times of the restarts in the last hour
$script:vectorWaitLogged = $false

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

function Get-ProcessTable {
    $byId = @{}
    foreach ($entry in [EcoNative.ProcessTable]::Get()) {
        $byId[$entry.ProcessId] = $entry
    }
    return $byId
}

function Get-WindowOwnerIds {
    $ownerIds = @{}
    foreach ($id in [EcoNative.Windows]::GetWindowOwnerIds()) {
        $ownerIds[$id] = $true
    }
    return $ownerIds
}

function Get-LiveProcesses {
    # One call for all processes. Asking for them one at a time with GetProcessById costs about
    # 0.2 s each on a busy PC, which froze the tray for many seconds.
    $procById = @{}
    foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
        $procById[$proc.Id] = $proc
    }
    return $procById
}

function Get-ProcessesOnMasks([hashtable]$procById, [int64[]]$masks) {
    # The processes pinned to one of the given core masks.
    $maskById = [EcoNative.ProcessTable]::GetAffinityMasks([int[]]@($procById.Keys))
    foreach ($pair in $maskById.GetEnumerator()) {
        if ($pair.Value -ne $allCoresMask -and $masks -contains $pair.Value) {
            $procById[$pair.Key]
        }
    }
}

function Update-HeadlessEdgeCache([hashtable]$byId) {
    # Only the headless automation browser is limited, never the Edge you browse with. Telling
    # them apart needs the command line, which is slow to read, so each Edge process is asked once.
    foreach ($id in @($script:headlessEdge.Keys)) {
        if (-not $byId.ContainsKey($id)) {
            $script:headlessEdge.Remove($id)
        }
    }
    $unknownIds = @(
        foreach ($p in $byId.Values) {
            if ($p.Name -eq 'msedge.exe' -and -not $script:headlessEdge.ContainsKey($p.ProcessId)) {
                $p.ProcessId
            }
        }
    )
    if ($unknownIds.Count -eq 0) {
        return
    }
    $filter = "Name='msedge.exe'"
    if ($unknownIds.Count -le 20) {
        $filter = ($unknownIds | ForEach-Object { "ProcessId=$_" }) -join ' OR '
    }
    $headlessIds = @{}
    foreach ($p in Get-CimInstance Win32_Process -Filter $filter -Property ProcessId, CommandLine) {
        if ("$($p.CommandLine)" -match '--headless') {
            $headlessIds[[int]$p.ProcessId] = $true
        }
    }
    foreach ($id in $unknownIds) {
        $script:headlessEdge[$id] = $headlessIds.ContainsKey($id)
    }
}

function Get-BackgroundTargetIds([hashtable]$byId = (Get-ProcessTable)) {
    if ($backgroundNames -contains 'msedge') {
        Update-HeadlessEdgeCache $byId
    }
    foreach ($p in $byId.Values) {
        $name = $p.Name -replace '\.exe$', ''
        if ($backgroundNames -notcontains $name) {
            continue
        }
        if ($name -eq 'msedge' -and -not $script:headlessEdge[$p.ProcessId]) {
            continue
        }
        if (Test-UnderVector $byId $p.ProcessId) {
            continue
        }
        $p.ProcessId
    }
}

function Invoke-EcoLimits {
    # Runs every 30 s in both states. The Vector guard (BelowNormal priority) is always applied;
    # the core limit is added only while eco is ON.
    $byId = Get-ProcessTable
    foreach ($id in @($script:changed.Keys)) {
        if (-not $byId.ContainsKey($id)) {
            $script:changed.Remove($id)       # the process has ended
        }
    }
    # Opening a process is the slow part, so only the ones that need a change are opened.
    $windowOwnerIds = Get-WindowOwnerIds
    $pendingIds = @(
        foreach ($id in Get-BackgroundTargetIds $byId) {
            $entry = $script:changed[$id]
            $hasWindow = $windowOwnerIds.ContainsKey($id)
            if (-not $entry) {
                if (-not $hasWindow) {
                    $id                       # new background process
                }
            }
            elseif ($hasWindow -or ($script:ecoOn -and -not $entry.Limited)) {
                $id                           # now interactive, or still needs the core limit
            }
        }
    )
    if ($pendingIds.Count -eq 0) {
        return
    }
    $procById = Get-LiveProcesses
    foreach ($id in $pendingIds) {
        $proc = $procById[$id]
        if (-not $proc) {
            continue
        }
        try {
            $entry = $script:changed[$id]
            if ($entry -and $entry.Start -ne $proc.StartTime) {
                $script:changed.Remove($id)   # the id now belongs to a new process
                $entry = $null
            }
            if ($windowOwnerIds.ContainsKey($id)) {
                # Has a visible window: interactive, leave it (or put it back) at full speed.
                if ($entry) {
                    if ($entry.Limited) {
                        $proc.ProcessorAffinity = [IntPtr]$entry.Affinity
                    }
                    $proc.PriorityClass = $entry.Priority
                    $script:changed.Remove($id)
                }
                continue
            }
            if (-not $entry) {
                $entry = @{
                    Priority = $proc.PriorityClass
                    Affinity = [int64]$proc.ProcessorAffinity
                    Start    = $proc.StartTime
                    Limited  = $false
                }
                if ($proc.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::Idle) {
                    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                }
                $script:changed[$id] = $entry
            }
            if ($script:ecoOn -and -not $entry.Limited) {
                $proc.ProcessorAffinity = [IntPtr]$ecoMask
                $entry.Limited = $true
            }
        }
        catch {
        }
    }
}

function Restore-Limits([bool]$keepGuard) {
    # OFF ($keepGuard): give the cores back, the guard priority stays.
    # Exit: put the original priority back as well and forget everything.
    $restored = 0
    $procById = Get-LiveProcesses
    foreach ($id in @($script:changed.Keys)) {
        $entry = $script:changed[$id]
        $proc = $procById[$id]
        if (-not $proc) {
            continue
        }
        try {
            if ($proc.StartTime -eq $entry.Start) {
                if ($entry.Limited) {
                    $proc.ProcessorAffinity = [IntPtr]$entry.Affinity
                    $entry.Limited = $false
                    $restored++
                }
                if (-not $keepGuard) {
                    $proc.PriorityClass = $entry.Priority
                }
            }
        }
        catch {
        }
    }
    if (-not $keepGuard) {
        $script:changed.Clear()
    }

    # Child processes (e.g. rustc under cargo) inherit the eco cores from their parent without
    # being tracked; release anything still on an eco/legacy mask too.
    foreach ($proc in Get-ProcessesOnMasks $procById (@($ecoMask) + $legacyMasks)) {
        try {
            $proc.ProcessorAffinity = [IntPtr]$allCoresMask
            if (-not $keepGuard -and $proc.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::BelowNormal) {
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
            }
            $restored++
        }
        catch {
        }
    }
    return $restored
}

function Add-LegacyLimits {
    # Adopt processes limited earlier by hand so OFF restores them too.
    $adopted = 0
    foreach ($proc in Get-ProcessesOnMasks (Get-LiveProcesses) $legacyMasks) {
        try {
            $priority = [System.Diagnostics.ProcessPriorityClass]::Normal
            if ($proc.ProcessName -eq 'llama-server') {
                $priority = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
            }
            $script:changed[$proc.Id] = @{
                Priority = $priority
                Affinity = $allCoresMask
                Start    = $proc.StartTime
                Limited  = $true
            }
            $adopted++
        }
        catch {
        }
    }
    return $adopted
}

function Invoke-MemoryTrim {
    $before = $computerInfo.AvailablePhysicalMemory
    $windowOwnerIds = Get-WindowOwnerIds
    $procById = Get-LiveProcesses
    foreach ($id in Get-BackgroundTargetIds) {
        $proc = $procById[$id]
        if (-not $proc -or $windowOwnerIds.ContainsKey($id)) {
            continue
        }
        try {
            [void][EcoNative.Psapi]::EmptyWorkingSet($proc.Handle)
        }
        catch {
        }
    }
    Start-Sleep -Milliseconds 1500
    $freedGB = ($computerInfo.AvailablePhysicalMemory - $before) / 1GB
    return [math]::Max(0, $freedGB)
}

function Get-TopMemoryUsers([int]$count = 3) {
    $totals = @{}
    foreach ($proc in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $totals[$proc.ProcessName] += $proc.PrivateMemorySize64
        }
        catch {
        }
    }
    $top = $totals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $count
    return ($top | ForEach-Object { '{0} {1:N1} GB' -f $_.Key, ($_.Value / 1GB) }) -join ', '
}

function Test-MemoryGuard {
    # Apps (Vector included) crash when Windows runs out of virtual memory, and no CPU limit can
    # stop that. Warn once while there is still time to close something; nothing is killed.
    $freeGB = [EcoNative.Memory]::GetCommitFreeGB()
    if ($freeGB -lt $guardCommitFreeGB) {
        if (-not $script:memoryWarned) {
            $script:memoryWarned = $true
            $top = Get-TopMemoryUsers
            $notifyIcon.ShowBalloonTip(
                10000,
                "$appName - memory almost full",
                ('Only {0:N1} GB of virtual memory left. Apps crash when it runs out. Biggest users: {1}' -f $freeGB, $top),
                'Warning'
            )
            Write-Log ('LOW MEMORY - {0:N1} GB of virtual memory left. Biggest users: {1}' -f $freeGB, $top)
        }
    }
    elseif ($freeGB -gt $guardCommitFreeGB + 2) {
        $script:memoryWarned = $false         # recovered; warn again next time
    }
}

# --- Vector restart -------------------------------------------------------------------------
function Get-VectorMainId([hashtable]$byId) {
    # Vector's main process is the Vector.exe that was not started by another Vector.exe.
    foreach ($p in $byId.Values) {
        if ($p.Name -ne 'Vector.exe') {
            continue
        }
        $parent = $byId[[int]$p.ParentProcessId]
        if (-not $parent -or $parent.Name -ne 'Vector.exe') {
            return [int]$p.ProcessId
        }
    }
    return 0
}

function Start-VectorApp([string]$path) {
    # Through Explorer, so Vector does not start as a child of this tray app.
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $path)
}

function Start-AfterRestartScript {
    # Runs on its own, so a slow script cannot freeze the tray.
    if (Test-Path $afterRestartScript) {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $afterRestartScript)
        )
    }
}

function Restart-Vector {
    $oneHourAgo = (Get-Date).AddHours(-1)
    $script:vectorRestarts = @($script:vectorRestarts | Where-Object { $_ -gt $oneHourAgo })
    if ($script:vectorRestarts.Count -ge $maxVectorRestartsPerHour) {
        $script:vectorCrashed = $false
        $notifyIcon.ShowBalloonTip(
            10000,
            "$appName - Vector not restarted",
            "Vector crashed again after $maxVectorRestartsPerHour restarts in an hour. Start it yourself when the PC has calmed down.",
            'Warning'
        )
        Write-Log "Vector NOT restarted - already $maxVectorRestartsPerHour restarts in the last hour"
        return
    }
    $freeGB = [EcoNative.Memory]::GetCommitFreeGB()
    if ($freeGB -lt $guardCommitFreeGB) {
        # Starting it into a full memory would only crash it again. Try again on the next pass.
        if (-not $script:vectorWaitLogged) {
            $script:vectorWaitLogged = $true
            $notifyIcon.ShowBalloonTip(
                10000,
                "$appName - Vector crashed",
                ('Only {0:N1} GB of virtual memory left. Vector is restarted as soon as there is room; close something to speed that up.' -f $freeGB),
                'Warning'
            )
            Write-Log ('Vector restart waiting - only {0:N1} GB of virtual memory left' -f $freeGB)
        }
        return
    }
    $script:vectorCrashed = $false
    $script:vectorWaitLogged = $false
    $script:vectorRestarts += Get-Date
    Start-VectorApp $script:vectorExePath
    Start-AfterRestartScript
    $notifyIcon.ShowBalloonTip(
        10000,
        "$appName - Vector restarted",
        'Vector crashed and was started again. Its chats do not continue by themselves: open each one and send "continue".',
        'Warning'
    )
    Write-Log 'Vector restarted after a crash'
}

function Watch-Vector([hashtable]$byId = (Get-ProcessTable)) {
    # Runs every 30 s. A clean close ends with exit code 0; a crash or a forced close does not.
    if ($script:vectorProcess -and $script:vectorProcess.HasExited) {
        $exitCode = $script:vectorProcess.ExitCode
        $script:vectorGoneAt = $script:vectorProcess.ExitTime
        $script:vectorProcess.Dispose()
        $script:vectorProcess = $null
        $script:vectorCrashed = ($exitCode -ne 0)
        if ($script:vectorCrashed) {
            Write-Log ('Vector stopped unexpectedly (exit code 0x{0:X8})' -f $exitCode)
            return                        # one pass for it to come back by itself
        }
    }
    if ($script:vectorProcess) {
        return
    }
    $mainId = Get-VectorMainId $byId
    if ($mainId) {
        try {
            $proc = [System.Diagnostics.Process]::GetProcessById($mainId)
            # Leftover helper processes of the Vector that just ended are older than its exit.
            if (-not $script:vectorGoneAt -or $proc.StartTime -gt $script:vectorGoneAt) {
                [void]$proc.Handle        # the open handle keeps the exit code readable later
                $script:vectorExePath = $proc.MainModule.FileName
                $script:vectorProcess = $proc
                $script:vectorCrashed = $false
                $script:vectorWaitLogged = $false
                Write-Log "watching Vector (pid $mainId)"
            }
        }
        catch {
            # It ended between the scan and here; the next pass sorts it out.
        }
        return
    }
    if ($script:vectorCrashed -and $script:restartVector) {
        Restart-Vector
    }
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
$restartItem = $menu.Items.Add('Restart Vector after a crash')
$restartItem.CheckOnClick = $true
$restartItem.Checked = $script:restartVector
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
        $toggleItem.Text = 'Turn OFF (give all cores back)'
        $statusItem.Text = "Limiting $($script:changed.Count) background processes to $($coreCount - $freeCoreCount) of $coreCount cores"
    }
    else {
        $notifyIcon.Icon = $iconOff
        $state = 'OFF'
        $toggleItem.Text = 'Turn ON (limit background work)'
        $statusItem.Text = "Core limit off - Vector guard keeps $($script:changed.Count) background processes at low priority"
    }
    $notifyIcon.Text = ('{0}: {1} | CPU {2}% | RAM {3:N0}%' -f $appName, $state, $cpuText, $ramUsed)
}

function Switch-Eco {
    try {
        if ($script:ecoOn) {
            $count = Restore-Limits $true
            $script:ecoOn = $false
            $notifyIcon.ShowBalloonTip(
                2500,
                "$appName OFF",
                "All cores given back to $count processes. Vector guard stays on (background work at low priority).",
                'Info'
            )
            Write-Log "OFF - cores given back to $count processes, Vector guard stays on"
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
$restartItem.Add_CheckedChanged({
    $script:restartVector = $restartItem.Checked
})
$exitItem.Add_Click({
    [void](Restore-Limits $false)
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
        if ($script:tickCount % $reapplyEveryTicks -eq 0) {
            Invoke-EcoLimits
            Test-MemoryGuard
            Watch-Vector
        }
        Update-TrayUi
    }
    catch {
        Write-Log "timer error: $($_.Exception.Message)"
    }
})

# Start in the state the PC is actually in: ON if earlier limits are still active.
# The Vector guard starts in both states.
$adoptedCount = Add-LegacyLimits
if ($adoptedCount -gt 0) {
    $script:ecoOn = $true
}
Invoke-EcoLimits
Write-Log "started - eco is $(if ($script:ecoOn) { 'ON' } else { 'OFF' }), Vector guard on ($($script:changed.Count) processes at low priority)"
Watch-Vector

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
