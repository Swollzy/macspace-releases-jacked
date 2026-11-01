# Molt

**Swollzy's cleanup app for the Mac.** Molt shows what fills System Data and frees what is safe, finds big and duplicate files,
moves apps you no longer use to the Trash with what they left behind, and cleans up after older versions of Swollzy's own apps
(Wallflower, Burrow, Swivel). It keeps your settings and libraries, it puts everything it removes in the Trash first, and it collects
no data about you.

Molt is built on [MacSpace](https://github.com/1architect/macspace-releases) by Gio Mantovani / 1architect, under the MIT License.
See [NOTICE](NOTICE) and [LICENSE](LICENSE).

## What it does

| Page | What it does |
|---|---|
| **Old Versions** | What earlier versions of Wallflower, Burrow, Swivel and any other `com.swollzy.` app left: an older second copy of the app, caches, saved windows, logs, crash reports, launch agents whose program is gone, and Burrow's old logs and build folder. Your settings, Wallflower's library, Swivel's slices and Burrow's bottles are listed as kept and never offered. Checked items go to the Trash after you confirm. |
| **System Data** | Explains what fills System Data and frees caches, old reports and unused system assets. |
| **Large Files** | Files over 100 MB and duplicate copies, to the Trash one by one. |
| **Apps & Login Items** | Moves an app to the Trash, then offers what it left; switches launch agents off and on. |
| **Other System Files** | Purgeable space, stale macOS updates and old Time Machine snapshots. |
| **Debloat** | Switches for analytics, ads and background data collection. |
| **Siri & Apple Intelligence** | Switches Apple Intelligence off and deletes its models (macOS 27). |

## Install

Get `Molt-x.y.z.dmg`, open it and drag Molt to Applications. The DMG's *Read Me First* has the one-time *Open Anyway* step.

**Used MacSpace before?** Open MacSpace, choose *About MacSpace > Uninstall* so it puts back the settings it changed, then open Molt.
Molt brings your history along.

Molt runs on **macOS 26 or later**, on Apple silicon and Intel Macs. Siri & Apple Intelligence needs macOS 27.

## Make the DMG

On a Mac with Xcode 27 or later, double-click **`dmg/Make DMG.command`**. It builds Molt and puts `Molt-x.y.z.dmg` in a *DMGs* folder
on your Desktop. If the build fails it writes `Molt-build-error.log` there.

## For developers

SwiftPM only, no Xcode project. `swift test` runs the tests; `Scripts/Assemble.sh` builds `Build/Molt.app` (see the comment at its
top; `MOLT_MIN_MACOS` and `ARCHS` choose the oldest macOS and the architectures). How it is put together is in
[Docs/Handoff.md](Docs/Handoff.md), which still describes the original MacSpace in places. Adding an app to Old Versions is one entry
in `Modules/OldVersions/Module/Engine/KnownApps.swift`.
