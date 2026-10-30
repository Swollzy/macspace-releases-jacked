# Large Files, Apps & Login Items, dry-run report and low-disk purge

This fork adds three features on top of upstream MacSpace. All three only ever move files to the Trash, and only files you check.
Nothing is deleted permanently, automatic cleanup never runs Large Files or Apps & Login Items, and no report, file list or path is
sent anywhere.

> **Status: not built or tested yet.** This code was written in a Linux container with no Swift toolchain and no macOS SDK, so it
> has never been compiled. Build it and run the tests on a Mac before you trust it. The steps are below.

## 1. Large Files (module, order 40)

`Modules/LargeFiles`

- **Where it looks:** `~/Documents`, `~/Downloads`, `~/Desktop`, `~/Movies`, `~/Music` and `~/Pictures`. To add more roots, put
  one absolute path per line in `~/Library/Application Support/MacSpace/large-files-roots.txt`. There is no Settings field yet,
  because the SDK has no text option.
- **Where it never goes:** `/System`, `/Library`, `~/Library` and Time Machine volumes, unless you add that exact folder as a
  root. It never follows links and never opens packages, so a Photos library or an app is never picked apart. Files that are only
  in iCloud (dataless) are skipped, because reading them would download them.
- **Large files:** 100 MB or more, largest first.
- **Duplicates:** files of 1 MB or more are grouped by size, then by a SHA-256 of their first and last 64 KB, then by a SHA-256 of
  the whole file. A group must have the same size and the same full hash. Hard links count as one file.
- **Keeping one copy:** each group keeps its oldest copy, which has no checkbox. The kept copy is also refused from the Large
  Files list. Before moving anything, MacSpace hashes the kept copy again. If it changed or is gone, nothing in the group moves.
  Each checked copy is hashed again too, and moves only if it still matches. At most N-1 copies of a group can go.
- **Nothing is pre-checked.** There is no main "Free" button.
- **Space:** freed only when you empty the Trash, so moving files is not recorded as freed in the cleanup history.

## 2. Apps & Login Items (module, order 50)

`Modules/AppsAndLoginItems`

- **Apps:** everything in `/Applications` and `~/Applications`, including one level of subfolders, with bundle ID and size.
  macOS's own apps (`com.apple.*`) and MacSpace are listed but never offered for the Trash.
- **Uninstall, two steps:**
  1. **Move to Trash** on an app moves only the `.app`, through the Finder. The app must not be running.
  2. The app's leftovers then appear under *Left by apps in the Trash*, none checked. **Keep** stops offering them.
  The list of apps moved this way is kept in `~/Library/Application Support/MacSpace/removed-apps.json`.
- **Leftover rules (strict):** only in `~/Library` under Application Support, Caches, Preferences (including ByHost), Containers,
  Saved Application State, WebKit and Group Containers. A leftover must match the bundle ID exactly, or the exact app name.
  Name matches are allowed only in Application Support and Caches, and only when no other installed app or macOS app has that
  name. A container must be recorded for that bundle ID in macOS's own container metadata. A group container must be named
  `<TEAMID>.<bundle id>` or the bundle ID itself, never a vendor's shared group. It never looks in Documents, Desktop, Pictures or
  Music, never in shared frameworks, and never follows links. Every path is matched again just before it moves.
- **Apps you no longer have (orphans):** the same seven places are searched for items named by a bundle ID whose owner is gone.
  This includes dependencies such as a vendor's updater left after its apps were removed. An item counts as an orphan only when:
  - no installed app, and no bundle inside one (helpers, extensions, frameworks), has that ID;
  - Launch Services knows no app with that ID anywhere on the Mac;
  - no installed app has the same vendor prefix (`com.google`, `com.microsoft`). So a shared updater stays while any app of
    that vendor is installed.

  Orphans are not pre-checked and go only to the Trash. Check what you recognise.
- **Launch agents:** `~/Library/LaunchAgents` and `/Library/LaunchAgents`, listed with Label, program and RunAtLoad
  (macOS's own are hidden). A **Program missing** pill marks an agent whose program is gone. Switching one off runs
  `launchctl disable gui/<uid>/<label>` and stops it. The plist is never moved or edited. Each switch-off is recorded in
  `~/Library/Application Support/MacSpace/disabled-launch-agents.json`. Switching it on again runs `launchctl enable` and loads
  it again. Uninstalling MacSpace switches every recorded agent back on (`prepareForUninstall`).

## 3. Dry-run report and low-disk emergency purge

- **Settings › Cleanup › Export dry-run report…:**
  - You pick a folder. MacSpace writes `MacSpace Dry Run <date>.json` and `.md` there and shows them in the Finder.
  - The report lists each module, what its own Free would free, whether automatic cleanup may run it, and every row offered for
    checking: checked rows in full, unchecked rows as a count.
  - It only reads the pages; no module acts.
  - Selection actions say whether they free or trash through the `macspace.disposition` parameter (`DryRunReport.dispositionKey`).
- **Low disk:** free space is under `max(15 GB, 10% of the disk)`, and the threshold is never below 5 GB (`LowDiskPolicy`). This
  replaces the earlier 10 GB / 5% rule for the low-space notification.
- **The only automatic emergency action:** Other System Files' own cleanup, which is macOS's purge of files apps marked
  purgeable.
  - It runs at most once an hour while the disk stays low. You can turn it off in Settings › Cleanup.
  - Then a notification says what was freed and offers the dry-run report. Clicking it opens Settings.
  - It never trashes user files, snapshots, backups, duplicates, large files or app leftovers.
- **Only while MacSpace is open.** Nothing watches the disk with the app closed. That needs a login item and is a follow-up.

## Build and test on your Mac

```bash
swift test
```

```bash
INSTALL=1 Scripts/Assemble.sh
```

- `Tests/LargeFiles/Feature123Tests.swift` runs the temp-folder flow. It creates known duplicates and a same-size lookalike that
  differs only in the middle, then: scan → dry-run report → move one checked copy to a stand-in Trash → scan again → one copy
  remains and the other is in the stand-in Trash. It also checks that the kept copy is refused and that hard links are not
  duplicates. This test lives in `Tests/LargeFiles/`, not `Tests/` itself, because SwiftPM only runs tests inside a test target's
  folder.
- `Tests/AppsAndLoginItems/` runs strict leftover matching, the two-step uninstall, orphans, and launch agents with a recording
  `launchctl`, all on a fake home folder.
- `Tests/Platform/DryRunReportTests.swift` covers the report and `LowDiskPolicy`.

Then try it on a test folder in the real app:
1. Add a scratch folder as a root in `large-files-roots.txt`.
2. Put two copies of a file in it.
3. Scan, export a report, check one copy, Move to Trash, refresh, and confirm the other copy remains.
4. Only then use your real home folders, and only with a backup.

## Known gaps

- **Translations:** the new texts are English only. `Localization/LargeFiles.json` and `Localization/AppsAndLoginItems.json`
  are empty, and the new Settings texts are not in `Localization/App.json`. So CI's `swift Scripts/Localize.swift --check` step
  will list them until they are translated.
- **APFS clones:** two cloned copies share blocks. Trashing one frees less than its size, so the figures are estimates.
- **Login Items from SMAppService** (System Settings › General › Login Items) are not listed. A button opens that pane.

## Compared with CCleaner for Mac

Covered:
- duplicate finder;
- large files;
- app uninstaller with leftovers;
- leftovers of apps already removed;
- startup items and launch agents;
- a report before cleaning.

System junk and caches were already covered by System Data and Other System Files.

Left out on purpose:
- browser history and privacy cleaning;
- app updating;
- malware scanning;
- cloud cleanup;
- anything paid.
