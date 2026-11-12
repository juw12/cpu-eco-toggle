# CPU Eco Toggle

A one-click Windows tray switch that gives your PC breathing room when background work
(AI agents, builds, local LLMs, long Python jobs) pins the CPU at 100% — **without stopping anything**.

- **ON (green):** background workloads are moved to fewer CPU cores (5 of 8 on an 8-core machine)
  and set to BelowNormal priority. They keep running, just a little slower, and about 3/8 of the CPU
  stays free for whatever you are actually using. New background processes are picked up every 30 s.
- **OFF (grey):** every process the tool changed gets its original priority and cores back.

Nothing is ever killed or paused.

## What it limits

Processes named `opencode`, `cargo`, `rustc`, `ollama`, `llama-server`, `python`, `pythonw`, plus
**headless** `msedge` (automation browsers only), when they:

- have **no visible window** (anything you are looking at stays full speed), and
- were **not** started by Vector.

Edit `$backgroundNames` in `EcoToggle.ps1` to change the list.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File install_eco_toggle.ps1
```

This checks the script, builds the icon, writes the hidden-window launcher (`EcoToggle.vbs`),
creates a Start menu shortcut **CPU Eco Toggle**, and starts the tray icon.
Re-run it if you move the folder.

To get a taskbar button: Start → *CPU Eco Toggle* → right-click → **Pin to taskbar**.

## Use

| Action | Result |
|---|---|
| Left-click tray icon | Toggle ON/OFF |
| Click pinned taskbar button | Toggle ON/OFF (a second launch signals the running copy) |
| Hover tray icon | Live state, CPU % and RAM % |
| Right-click → *Trim background memory now* | Releases RAM from windowless background processes (pages reload on demand) |
| Right-click → *Exit* | Restores everything, then closes |

If the icon is hidden behind the tray **^** arrow, drag it onto the taskbar.

## Files

| File | Purpose |
|---|---|
| `EcoToggle.ps1` | The tray app (PowerShell + WinForms) |
| `install_eco_toggle.ps1` | Builds icon + launcher, (re)creates shortcuts, starts the app |
| `revert_cpu_limits.ps1` | Emergency undo: resets any process left on the eco core mask |

`EcoToggle.vbs`, `EcoToggle.ico` and `EcoToggle.log` are generated locally and not committed.

## Notes

- Affinity and priority changes last until a process restarts; nothing is written to the registry
  or system settings.
- On machines with a different core count the free share is still about 3/8 of the logical cores.
- Requires Windows PowerShell 5.1 (built into Windows 10/11). No admin rights needed.
