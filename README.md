# CPU Eco Toggle

A one-click Windows tray switch that gives your PC breathing room when background work
(AI agents, builds, local LLMs, long Python jobs) pins the CPU at 100% — **without stopping that work**.

- **Vector guard (always on, in both states):** background workloads run at BelowNormal priority,
  so the apps you are using — Vector included — get the CPU first. It starts with Windows and
  picks up new background processes every 30 s.
- **ON (green):** background workloads are moved to fewer CPU cores (5 of 8 on an 8-core machine)
  as well. They keep running, just a little slower, and about 3/8 of the CPU stays free for
  whatever you are actually using.
- **OFF (grey):** the cores are given back. The guard priority stays.
- **Exit:** every process the tool changed gets its original priority and cores back.

No background job is ever killed or paused. The one thing the tool can end is a frozen Vector,
so that it can be started again (see below).

### Low-memory warning

Apps crash when Windows runs out of *virtual memory* (RAM + pagefile), and no CPU limit can stop
that. The guard therefore also warns in the tray, and writes the biggest memory users to
`EcoToggle.log`, when less than 6 GB is left (`$guardCommitFreeGB` in `EcoToggle.ps1`). It warns
once and re-arms after memory recovers. It never closes anything — that decision stays with you.

### Restart Vector after a crash or freeze

The guard keeps an eye on Vector's main process. When it ends with an error code (a crash, or a
forced close from Task Manager) and no Vector process is left, Vector is started again and a tray
notice tells you. Closing Vector yourself ends with code 0 and is left alone.

A frozen Vector is restarted too. When Windows reports its window as "Not responding" for 3 minutes
in a row (`$restartVectorWhenFrozenMinutes`, 0 = never), the guard ends Vector and its helper
processes and starts it again. Every chat that was running is interrupted by this, so the wait is
deliberately long: a window that answers again in the meantime is left alone. Programs the chats
started keep running.

- It waits while less than 6 GB of virtual memory is free, so Vector is not started into the same
  shortage that crashed it.
- It stops after 3 restarts in an hour (`$maxVectorRestartsPerHour`), so a crash loop cannot run on.
  A frozen Vector is then left as it is, and a tray notice tells you.
- Only a frozen *window* is seen. A chat that hangs inside a window that still answers, or a Vector
  hidden in the tray, is not noticed.
- Switch it off for this session in the tray menu, or for good with `$restartVectorAfterCrash`.

**Vector does not continue its chats after a restart**, and nothing outside Vector can do that for
it: each interrupted chat needs a reply such as *continue*. To make that quick, put a script named
`after_vector_restart.ps1` next to `EcoToggle.ps1`. It runs after every restart — for example to
open a list of the tasks that were in progress. The file is yours and is not committed.

## Get it on your device

- **Windows:** [`CPUEcoToggle-Windows-Setup.exe`](https://github.com/juw12/cpu-eco-toggle/releases/download/desktop/CPUEcoToggle-Windows-Setup.exe) (no admin needed; if Windows says it protected your PC, choose *More info → Run anyway*), or without installing [`CPUEcoToggle-Windows-Portable.zip`](https://github.com/juw12/cpu-eco-toggle/releases/download/desktop/CPUEcoToggle-Windows-Portable.zip).
- **Mac:** [`CPUEcoToggle-macOS-AppleSilicon.dmg`](https://github.com/juw12/cpu-eco-toggle/releases/download/desktop/CPUEcoToggle-macOS-AppleSilicon.dmg) (M1 and newer) or [`CPUEcoToggle-macOS-Intel.dmg`](https://github.com/juw12/cpu-eco-toggle/releases/download/desktop/CPUEcoToggle-macOS-Intel.dmg). The first time, macOS blocks it because it is not notarized: **System Settings → Privacy & Security → Open Anyway**.
- **Android:** [`CPUEcoToggle-android.apk`](https://github.com/juw12/cpu-eco-toggle/releases/download/android/CPUEcoToggle-android.apk): open the file on the phone and allow your browser to install apps once.
- **iPhone:** open https://juw12.github.io/cpu-eco-toggle/ in Safari, tap Share, then **Add to Home Screen**.

The Windows, Mac and Android apps are the web app in its own window ([`desktop/`](desktop/README.md), [`android/`](android/README.md)) and change with it. Each build is opened on GitHub's machines before it is published: on Windows and on a Mac the page loads, the app starts and can store data; on an Android emulator it installs, opens and stays up. They are not code-signed or notarised, and no real phone or PC has run them yet.

## What it limits

Processes named `opencode`, `cargo`, `rustc`, `lean`, `lake`, `ollama`, `llama-server`, `python`,
`pythonw`, plus **headless** `msedge` (automation browsers only), when they:

- have **no visible window** (anything you are looking at stays full speed), and
- were **not** started by Vector.

Edit `$backgroundNames` in `EcoToggle.ps1` to change the list.

**Eco-only jobs** are the exception to the always-on guard: they are slowed only while the switch
is ON, and run at full speed while it is OFF. Slowed means fewer cores; their priority is not
lowered, because at low priority on a PC at 100% CPU they got no CPU at all. The list is
`$ecoOnlyJobs` in `EcoToggle.ps1`: a process name plus a text its command line must contain. It
covers that process and everything it starts. By default it holds the OpenCode research queue
workers (`opencode ... --title "queue: ..."`).

**Full-speed jobs** are never slowed, ON or OFF: no low priority, no core limit and no memory
trim. Use it for scheduled work with a deadline. The list is `$fullSpeedJobs` in `EcoToggle.ps1`,
matched the same way (a process name plus a text in its command line, and everything it
starts). By default it holds three weekly report runners (`run_weekly.ps1`,
`run_approval_weekly.ps1`, `run_weekly_ai_usage.ps1`): at low priority on a PC at 100% CPU their
page loads timed out and the Monday reports did not go out.

It also holds two small programs that something else waits for: **Titip** (`Titip.pyw`, Outlook
mail on the phone) and the **Outlook archiver** (`outlook_archiver.py`). Measured on 2026-11-17 on
a PC at 100% CPU: hidden Python programs at low priority were not run at all for 9 to 55 seconds
at a time. The phone waited that long for Titip to answer. Outlook calls the archiver for every
new and sent mail and waits for its answer, so a slowed archiver can freeze Outlook as well. Both
use almost no CPU, so leaving them at full speed costs nothing.

A change to these lists takes effect the next time CPU Eco Toggle starts (Exit in the tray menu,
then start it again, or the next sign-in).

## Install

```powershell
powershell -ExecutionPolicy Bypass -File install_eco_toggle.ps1
```

This checks the script, builds the icon, writes the hidden-window launcher (`EcoToggle.vbs`),
creates a Start menu shortcut **CPU Eco Toggle** and a Startup shortcut (so the guard is back after
every sign-in), and starts the tray icon. Re-run it if you move the folder.

To get a taskbar button: Start → *CPU Eco Toggle* → right-click → **Pin to taskbar**.

## Use

| Action | Result |
|---|---|
| Left-click tray icon | Toggle ON/OFF |
| Click pinned taskbar button | Toggle ON/OFF (a second launch signals the running copy) |
| Hover tray icon | Live state, CPU % and RAM % |
| Right-click | Status line: how many background processes the guard is holding |
| Right-click → *Trim background memory now* | Releases RAM from windowless background processes (pages reload on demand) |
| Right-click → *Restart Vector after a crash or freeze* | Tick or untick: start Vector again when it crashes or freezes |
| Right-click → *Exit* | Restores everything, then closes |

If the icon is hidden behind the tray **^** arrow, drag it onto the taskbar.

## Files

| File | Purpose |
|---|---|
| `EcoToggle.ps1` | The tray app (PowerShell + WinForms) |
| `install_eco_toggle.ps1` | Builds icon + launcher, (re)creates shortcuts, starts the app |
| `revert_cpu_limits.ps1` | Emergency undo: resets any process left on the eco core mask |

`EcoToggle.vbs`, `EcoToggle.ico` and `EcoToggle.log` are generated locally and not committed. The
same goes for your own `after_vector_restart.ps1` and the `VectorResume.txt` list it may write.

## Notes

- Affinity and priority changes last until a process restarts; nothing is written to the registry
  or system settings.
- Child processes inherit BelowNormal priority from a guarded parent. After *Exit*, such a child
  can stay at BelowNormal until it ends.
- On machines with a different core count the free share is still about 3/8 of the logical cores.
- Requires Windows PowerShell 5.1 (built into Windows 10/11). No admin rights needed.
