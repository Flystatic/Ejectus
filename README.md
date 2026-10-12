<p align="center">
  <img src="icon/icon.png" width="160" alt="Ejectus icon">
</p>

<h1 align="center">Ejectus</h1>

<p align="center">Cleans macOS junk off SD cards and external drives when you eject them.</p>

Removes macOS junk (`.DS_Store`, `._*`, `.Spotlight-V100`, `.fseventsd`, `.Trashes`,
`.TemporaryItems`, `.DocumentRevisions-V100`, `.apdisk`) from external drives.

- **Finder:** right-click a drive → Services → **Clean Junk Files**
- **Eject:** cleans automatically when you eject (toggle in the menu bar icon)
- **Menu bar icon:** Clean & Eject per drive, plus switches for Clean When Ejecting,
  Empty Drive Trash (on by default; off keeps `.Trashes`), and Open at Login
- **Skip This Drive:** per-drive switch in the menu. Skipped drives (e.g. Mac-only editing
  drives) are never cleaned; their menu item becomes a plain Eject
- **Log:** every clean is recorded in `~/Library/Logs/Ejectus.log`

There's no plain "Clean" button: while a drive stays plugged in, macOS rebuilds
`.Spotlight-V100` and `.fseventsd` within minutes, so cleaning only sticks at eject.

Only touches external/removable drives. Never the internal disk, Time Machine, or network drives.

### Setup
1. **Full Disk Access:** System Settings → Privacy & Security → Full Disk Access → add Ejectus.
   Recent macOS locks `.Trashes` and `.TemporaryItems` on drives; without this they stay.
2. **Spotlight helper:** `.Spotlight-V100` is locked even from Full Disk Access, so a tiny root
   helper removes it with `mdutil -X`. Menu bar icon → "Set Up Spotlight Helper…" and enter your
   password once. It installs to `/Library/PrivilegedHelperTools/local.ejectus.privhelper` with a
   launchd entry in `/Library/LaunchDaemons`, and only ever runs `mdutil -X` on a verified
   external drive. App updates don't affect it.

To remove the helper:
```
sudo launchctl bootout system/local.ejectus.privhelper
sudo rm /Library/LaunchDaemons/local.ejectus.privhelper.plist /Library/PrivilegedHelperTools/local.ejectus.privhelper
```

## Download
Get `Ejectus-x.y.dmg` from the [Releases](https://github.com/Flystatic/Ejectus/releases) page.
Open it, drag Ejectus into Applications, and follow "How to Install.txt".
The app isn't signed with an Apple Developer ID, so the first launch needs
right-click → Open (or System Settings → Privacy & Security → Open Anyway).

## Build
```
./build.sh      # → build/Ejectus.app (Apple silicon + Intel, macOS 13+)
./test.sh       # end-to-end test on a FAT32 disk image
```

## Install on another Mac
Copy `Ejectus.app` to `/Applications`, then right-click → Open the first time.
Then do the Setup steps above.

Builds are signed with a local "Ejectus Local Signing" certificate when the build machine has one,
so macOS keeps Full Disk Access across updates. Without it, `build.sh` signs ad-hoc and Full Disk
Access has to be granted again after each update.
