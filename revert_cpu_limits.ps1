# Undo the CPU limits: every process still restricted to cores 2-7 (0xFC) or 3-7 (0xF8)
# goes back to all cores and Normal priority. llama-server goes back to its original AboveNormal.
foreach ($proc in Get-Process) {
    try {
        $mask = [int64]$proc.ProcessorAffinity
        if ($mask -eq 0xFC -or $mask -eq 0xF8) {
            $proc.ProcessorAffinity = [IntPtr]0xFF
            if ($proc.Name -eq 'llama-server') {
                $proc.PriorityClass = 'AboveNormal'
            }
            else {
                $proc.PriorityClass = 'Normal'
            }
            "restored: $($proc.Name) [$($proc.Id)]"
        }
    }
    catch {
    }
}
