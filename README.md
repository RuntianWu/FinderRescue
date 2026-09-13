<p align="center"><img src="Resources/FinderRescue_icon.png" width="128" alt="Finder Rescue icon"></p>

# Finder Rescue

A menu bar app that keeps Finder responsive. It notices when Finder gets stuck, relaunches it for you (with a 30-second heads-up you can cancel), and keeps the fixes for the usual causes one click away.

On recent macOS, Finder can slowly grind to a halt: its main thread ends up spinning at 100% CPU, windows beachball, and nothing but relaunching Finder brings it back. Finder Rescue watches for exactly that, fixes it automatically, and shows you what's dragging Finder down — cloud sync, Spotlight, dead network drives, or a Finder add-on.

## Features

**Watches Finder**
- Live CPU, memory, uptime and a "responding" check in the menu bar, with a six-minute CPU graph
- The menu bar icon turns into a warning triangle when Finder is in trouble

**Auto-rescue**
- Relaunches Finder when it's stuck: sustained high CPU, not answering (or answering very slowly), or runaway memory
- A 30-second warning notification with **Relaunch Now** and **Not Now** (pauses auto-rescue for 30 minutes)
- Never interrupts a copy — it waits while Finder is writing files
- Saves a 3-second call-stack sample of the stuck Finder before relaunching, so the cause can be looked at later
- Or choose **Notify** (a notification with a Relaunch button) or **Off** (just monitoring)

**One-click fixes**
- Relaunch Finder, close stuck "Searching…" windows, reset Quick Look
- Restart iCloud Drive syncing (`bird`) or File Provider (`fileproviderd`) — the usual culprits when cloud folders hang Finder
- Reset the Open and Save dialogs
- Reset all Finder settings, with an automatic backup you can restore
- Switch hidden files, the preview pane, the folder new windows open on, and `.DS_Store` creation on network and USB drives
- Spotlight index status, plus how to rebuild it without an administrator password

Nothing needs an administrator password, and nothing deletes your files. Fixes that are often recommended online but are obsolete or risky on current macOS (`lsregister -kill`, `purge`, deleting iCloud folders, wiping caches with `sudo`) are deliberately left out.

**Finds what's slowing Finder down**
- CPU of the background services Finder depends on: File Provider, iCloud Drive, CloudKit and Spotlight indexing
- Network drives that stopped responding, with a one-click disconnect
- Every startup item (LaunchAgents and LaunchDaemons) with broken ones flagged — missing programs, repeated failures — and a switch to turn your own agents off and back on
- Every cloud-storage and Finder add-on extension, each with an on/off switch

**Also included**
- ⌃⌥⌘F relaunches Finder from any app — handy when Finder is too stuck to click
- A `finderrescue://` URL scheme for Shortcuts and scripts
- Open at login, a rescue log, and optional update checks

## How auto-rescue works

Every 5 seconds Finder Rescue reads Finder's CPU time, memory and disk writes directly from the kernel. Every 20 seconds it asks Finder a trivial question through AppleScript and times the answer. Finder counts as stuck when any of these is true:

| Signal | Default |
|---|---|
| CPU at or above the threshold for at least 90% of the window | 85% for 3 minutes |
| No answer, or an answer slower than 5 seconds | 3 checks in a row (about a minute) |
| Memory footprint | over 2.5 GB |

The 90% rule means one quiet moment doesn't reset the clock, but ordinary bursty work never trips it. Then:

1. If Finder is writing more than 3 MB/s it's probably copying, so nothing happens.
2. Otherwise you get a notification: *Finder will be relaunched in 30 seconds*, with **Relaunch Now** and **Not Now**.
3. If Finder is still stuck when the time is up, Finder Rescue saves a diagnostic sample to `~/Library/Logs/FinderRescue/`, quits Finder, and macOS starts it again straight away. Your Finder windows reopen.
4. It then waits (10 minutes by default) before it will rescue again.

Every threshold can be changed in **Auto-Rescue** settings.

## Installation

Download `FinderRescue-1.0.0.dmg` from the [Releases page](https://github.com/Micropeptide/FinderRescue/releases), open it, and drag Finder Rescue into Applications.

Finder Rescue isn't notarized by Apple, so the first time you open it, right-click (or Control-click) the app and choose **Open**, then confirm. You only need to do this once.

On first launch macOS asks two things:
- **Notifications** — for the stuck-Finder warning and rescue messages.
- **"Finder Rescue wants to control Finder"** — needed for the responsiveness check and for closing search windows. Everything else works without it.

Finder Rescue adds itself to Login Items so monitoring survives a restart; you can turn that off in its settings.

Requires macOS 15 Sequoia or later, on Apple silicon or Intel.

## Privacy

Everything runs on your Mac. The only network request is the optional daily update check, which asks GitHub for the latest release of this repository. There is no analytics or tracking.

## Scripting

```bash
open "finderrescue://relaunch"          # relaunch Finder
open "finderrescue://close-search"      # close "Searching…" windows
open "finderrescue://reset-quicklook"   # reset Quick Look
open "finderrescue://snooze"            # pause auto-rescue for 30 minutes
open "finderrescue://resume"            # resume auto-rescue
```

## Where things are kept

- Settings: `defaults read com.micropeptide.finderrescue`
- Rescue log and diagnostic samples: `~/Library/Logs/FinderRescue/`
- Finder settings backups: `~/Library/Application Support/Finder Rescue/Backups/`
- Startup agents you turn off: `~/Library/LaunchAgents-disabled-FinderRescue/`

## Building from source

Finder Rescue is a Swift package with no external dependencies. It needs Xcode 16 or later.

```bash
git clone https://github.com/Micropeptide/FinderRescue.git
cd FinderRescue
swift test               # run the unit tests
./build.sh               # builds "Finder Rescue.app" (universal) in the project root
./build.sh --install     # …and copies it to /Applications and launches it
./scripts/make_dmg.sh    # builds a distributable disk image in dist/
./scripts/make_icon.sh   # re-renders the app icon from scripts/render_icon.swift
```

The detection and repair logic lives in the `FinderRescueCore` library; the menu bar app is `FinderRescue`.

## Uninstall

Turn off **Open Finder Rescue at login** in Auto-Rescue settings, quit the app from its menu, and delete it from Applications. To remove its data too, delete the folders listed under *Where things are kept*.

## License

MIT — see [LICENSE](LICENSE).

Made by [Runtian Wu](https://runtian.uk) · more apps at [software.runtian.uk](https://software.runtian.uk) · [github.com/Micropeptide](https://github.com/Micropeptide)
