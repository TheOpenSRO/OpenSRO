# Testing the native readers on Windows

From round 668, the Windows zip ships `srrevamp_native.dll` next to `srrevamp.exe`. The DLL holds
the native (Rust) asset readers from round 667. The game runs with or without it: without it,
every reader is GDScript, exactly as before.

**Nothing in this page has been run on Windows.** The log lines below come from the code and from
the same lines measured on the Linux build on the render box (round 668's WORLD_ISSUES entry).
The Windows paths are shown in the form Godot prints them (`C:/…`, forward slashes). This is
INFERRED from `OS.get_executable_path()`, not seen.

## Where to look

The log the game writes is named on its second line, `SRRevamp log file: …/srrevamp.log`. It
lives under `%APPDATA%\Godot\app_userdata\SRRevamp\logs\`. The same line also shows in game: open
Shift+F3 (the debug panel). Its first block, `== build`, carries the readers' line, without the
`NativeAssets: ` prefix.

## The lines, one per outcome

Exactly one of these lines is printed at startup, right after `SRRevamp version: …`.

**Native ON.** The DLL loaded:

```
NativeAssets: native readers ON (library loaded, srrevamp_native 0.1.0, API 4, C:/Games/srrevamp-windows/srrevamp_native.dll)
```

**OFF, the DLL is missing.** This is what renaming it gives, e.g. to `srrevamp_native.dll.off`.
Godot prints its own errors first, while loading the extension. On Linux these were the four
lines below (MEASURED); on Windows the first one's wording differs. Then the game carries on:

```
ERROR: Can't open dynamic library: native_bin/srrevamp_native.dll. …
ERROR: GDExtension dynamic library not found: native_bin/srrevamp_native.dll
ERROR: Failed loading resource: res://srrevamp_native.gdextension. …
ERROR: Error loading extension: res://srrevamp_native.gdextension
NativeAssets: native readers OFF (library not found: C:/Games/srrevamp-windows/srrevamp_native.dll) -- using the GDScript readers
```

**OFF, the DLL is there but did not load.** Antivirus blocking it is the likely cause, or a
damaged file:

```
NativeAssets: native readers OFF (library failed to load: C:/Games/srrevamp-windows/srrevamp_native.dll is there but Godot could not load it -- blocked by antivirus, or a build for another system?) -- using the GDScript readers
```

**OFF, the DLL is from another version.** This happens when an update could not replace it,
for example because antivirus blocked the new one. The client checks the library's interface
number (round 667's API check) and refuses a mismatch rather than calling into it:

```
NativeAssets: native readers OFF (library REFUSED: API 3, this client needs API 4 -- a stale library, rebuild it with native/build.sh) -- using the GDScript readers
```

The "rebuild" advice is for developers. For a player the fix is the next update, or the DLL
from the current release's zip. A DLL from an older release that speaks the same API number is
used. The number changes only when the interface does (native/README.md, "The interface
number").

**Forced OFF** by `set SRREVAMP_NATIVE=0` before starting the game, from a `cmd` window in the
game's folder:

```
NativeAssets: native readers OFF (forced off by SRREVAMP_NATIVE=0; the library is loaded but unused) -- using the GDScript readers
```

## The rename test, step by step

1. Start the game and check the log for `native readers ON`.
2. Quit, then rename `srrevamp_native.dll` to `srrevamp_native.dll.off`.
3. Start again. The log shows Godot's extension errors, then `native readers OFF (library not
   found: …)`. The game plays normally, only slower to load.
4. Rename it back and the next start says `ON` again.

**If an update arrives while the DLL is renamed**, the updater installs a fresh
`srrevamp_native.dll` from the new release. The next start is native ON again. The `.dll.off`
copy is left where it is, because the updater never deletes a file the new version does not
have. The Linux equivalent was run for real (round 668, `upd_test.sh off`).

## What an update logs

**The first update to this release looks different.** An update is installed by the version you
are running, not by the new one. Going from v0.1.464 to the release that brings the DLL is
therefore v0.1.464's own updater at work (READ, its `auto_updater.gd`):
- It unpacks the zip next to the game, quits, and runs a batch file. That file tries `timeout /t
  2`, then `robocopy … /E /XD pk2`, then starts the game again.
- None of the `SRRevamp update: …` lines below appear in either log. The old log ends at
  `SRRevamp: downloading update …`.
- The new client's log starts with its `NativeAssets: …` line and has no `SRRevamp update (last
  run)` summary.
- v0.1.464 has no DLL loaded, so `srrevamp_native.dll` is a new file to it and nothing blocks the
  copy. The running `srrevamp.exe` is still locked when robocopy starts, though, and robocopy's
  default is to wait 30 seconds before retrying. Expect up to half a minute, possibly more,
  before the game comes back (INFERRED from robocopy's documented defaults; not timed on
  Windows). The round 668 review ran this old updater for real on Linux: every file arrived
  byte for byte, and the relaunched game logged native ON.

**From the next update on**, the new updater installs, and the old version logs these lines
before it restarts:

```
SRRevamp update: srrevamp-windows.zip downloaded and verified, sha256 …
SRRevamp update: installed srrevamp_native.dll (the old one was moved aside to srrevamp_native.dll.old-update)
SRRevamp update: installed srrevamp.exe (the old one was moved aside to srrevamp.exe.old-update)
SRRevamp update: installed srrevamp.pck (the old one was moved aside to srrevamp.pck.old-update)
SRRevamp update: srrevamp_native.dll.old-update is still in use; it is deleted at the next start
SRRevamp update: srrevamp.exe.old-update is still in use; it is deleted at the next start
SRRevamp update: installed v0.1.466, restarting (the new client starts as soon as this one has exited)
```

The new version then repeats that summary at the top of its own log, as
`SRRevamp update (last run): …`. It also logs `removed srrevamp_native.dll.old-update, left over
from the last update` for each file it could now delete.

If the update cannot be unpacked whole, nothing is changed. For example, when the disk is too
full:

```
SRRevamp update: refused: not enough disk space next to the game: the update needs 78.4 MB (plus 32 MB to spare), 40.0 MB is free
SRRevamp: update failed (could not unpack v0.1.466, nothing was changed (…)) -- continuing with the current version
```

**A game folder whose path has non-ASCII characters** (e.g. `C:\Users\José\…`) probably never
auto-updated with v0.1.464 or earlier (PRE-EXISTING, found by the round 668 review). Their batch
file wrote the install path into a file that `cmd.exe` reads in the OEM code page, which mangles
those characters. Such an install will not get this release automatically either: copy the zip
over it by hand once. From this release on, the batch file holds no path at all.

**If the game will not start after an interrupted update** (the PC lost power mid-install): look
in the game folder for `srrevamp.exe.old-update` or `srrevamp.pck.old-update` with no
`srrevamp.exe` or `srrevamp.pck` beside it, and rename it back. The game puts back any other
file the same way by itself, at its next start.

Why "moved aside": Windows refuses to overwrite or delete a running exe or a loaded DLL, but lets
it be renamed. The game renames the old file and puts the new one under the real name. The old
copy is deleted at the next start, once nothing holds it. That Windows allows the rename is
INFERRED from its documented sharing rules. It is exercised only by a test that simulates those
rules (`client/scripts/update/update_installer_test.gd`).

If antivirus removes the new DLL during an update, that DLL is reported as `NOT installed
srrevamp_native.dll: …` and the rest of the update still installs. If the new exe or the new
`.pck` cannot be installed, everything is put back, the game says `update failed (…) --
continuing with the current version`, and the old version keeps working.

## Antivirus exclusion

The DLL and the exe are unsigned, so some antivirus products distrust a fresh one. Adding the game
folder to the exclusions is the workaround the user chose (2026-09-30). Without it, the worst
case is the `library failed to load` or `library not found` line, and the GDScript readers.
