# mac-reaper

A disk and memory watchdog for macOS in one bash script, with a SwiftBar menu.

It was written for an 8 GB Mac that kept filling its disk: memory ran out, macOS wrote
many gigabytes of swap, the disk hit zero and the machine froze. The reaper clears
regenerable caches before that happens and warns when swap is climbing.

## What it does

A background check runs every 10 minutes (a launchd agent). On each run it:

1. Measures free disk and swap.
2. Works out what could be cleared and sorts each item into one of two groups:
   - **Safe**: caches whose app is not open, Xcode build data while Xcode is closed,
     the npm cache, dangling Docker images, old Homebrew downloads.
   - **Needs your OK**: caches of apps that are open right now, Gradle and Maven
     caches, `~/.cache`, the Docker build cache, Trash items older than 30 days.
3. If free disk is below `WARN_FREE_GB` (10 GB), clears the safe group, then shows a
   dialog listing the rest and waits for "Clear all" or "Not now".
4. Warns about memory when macOS reports memory pressure and swap is above
   `SWAP_WARN_MB` (4 GB), when swap grows quickly between two checks, or when swap
   passes `SWAP_CRIT_MB` (10 GB). The warning names the apps using the most memory,
   measured the way Activity Monitor does. Swap left on disk after a busy spell does
   not count as pressure.

It never quits an app unless you pick Quit in the menu, and never touches documents, logs
or crash reports.

## Menu bar

With [SwiftBar](https://github.com/swiftbar/SwiftBar) installed, a scythe icon shows
the disk percentage. The dropdown shows free space, swap and the biggest memory users,
how much was cleared (today, 7 days, all time), every item that could be cleared with
its size, and a full HTML report. Items can be cleared one at a time from the menu.

Click an app in the memory list to quit it, so the fix for a memory warning is in the
same menu. Ordinary apps end in "quit…"; system processes are listed but can't be
clicked. A dialog offers Quit, which closes the app the normal way so it can ask about
unsaved work, Force quit, which stops it at once and asks once more first, or Not now.
The first time, macOS asks whether SwiftBar may control that app; allow it.

Warnings can be snoozed from the menu for 1, 4 or 24 hours. Critical warnings still come
through, and safe clean-ups still run. The report also lists large things the reaper
leaves alone (virtual machine disks, simulators, model downloads), so nothing hides.

## Install

```
brew install --cask swiftbar      # optional, for the menu bar icon
open -a SwiftBar                  # choose a plugin folder when asked
bash mac-reaper.sh --install
```

`--install` copies the script to `~/.mac-reaper/`, schedules the background check and
adds a three-line launcher to the SwiftBar plugin folder. If SwiftBar isn't running, it
starts it; turn on Launch at Login in SwiftBar's settings to keep the icon after a
restart. Run `--install` again after editing the script to deploy the new version.

## Commands

| Command | What it does |
|---|---|
| `--install` | Schedule the background check and add the SwiftBar plugin |
| `--install-plugin [folder]` | Add or refresh only the SwiftBar plugin |
| `--uninstall` | Remove the schedule and the plugin |
| `--status` | Disk, swap, what was cleared, what could be |
| `--report` | Build the HTML report and open it |
| `--dry-run` | Show what a clean-up would do, delete nothing |
| `--force` | Run a clean-up now, whatever the free space is |
| `--scan` | Refresh the list of what could be cleared |
| `--clean-safe` | Clear every safe item now |
| `--approve <item> [--yes]` | Clear one item; asks first if it needs an OK |
| `--approve-all [--yes]` | Clear everything that needs an OK, after one dialog |
| `--snooze <minutes>` | Silence warnings for that long; `0` resumes |
| `--app <App.app path>` | The dialog the menu shows: Quit, Force quit or Not now |
| `--quit-app <App.app path>` | Ask an app to quit the normal way, after a confirmation |
| `--kill-app <App.app path>` | Force quit an app, after a confirmation |

## Settings

Edit `~/.mac-reaper/config` (created on install). The main ones:

| Setting | Default | Meaning |
|---|---|---|
| `WARN_FREE_GB` | 10 | Act when free disk drops below this |
| `CRIT_FREE_GB` | 5 | Urgent warning below this |
| `WARN_USED_PCT` | 0 | Also act when the disk is this % full; 0 = off |
| `SWAP_WARN_MB` | 4096 | Notify when swap in use passes this |
| `SWAP_CRIT_MB` | 10240 | Urgent notification past this |
| `SWAP_RISE_MB` | 1024 | Also warn when swap grows this much between two checks |
| `AUTO_STOP_COLIMA` | 0 | 1 = run `colima stop` at `SWAP_CRIT_MB` |
| `TRASH_MAX_AGE_DAYS` | 30 | Offer Trash items older than this; 0 = never |
| `KEEP_CACHES` | empty | Folders in `~/Library/Caches` to keep, colon-separated |
| `ASK_MIN_MB` | 200 | Only ask for an OK when at least this much is at stake |

## Files

Everything lives in `~/.mac-reaper/`:

- `mac-reaper.sh`: the installed script
- `config`: settings
- `reaper.log`: what each run did
- `history.tsv`: every deletion (when, how, KB freed, item)
- `candidates.tsv`, `caches.tsv`: the latest scan
- `memory.tsv`: memory by app at the last check
- `large.tsv`: large items it leaves alone
- `report.html`: the latest report

## Notes

- Written for the bash 3.2 that macOS ships; no dependencies beyond macOS tools.
- SwiftBar runs the script directly when you click a menu item, so it must stay
  executable. `--install` sets this. If clicks stop doing anything, run
  `chmod 755 ~/.mac-reaper/mac-reaper.sh`. Every click is recorded in the log as a
  "menu action" line, so a click that fails still leaves a trace.
- The Trash is only reachable if `/bin/bash` has Full Disk Access; otherwise it is skipped.
- The schedule is the launchd agent `local.mac-reaper` in `~/Library/LaunchAgents/`.
