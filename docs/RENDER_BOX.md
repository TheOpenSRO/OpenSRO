# The render / RE box

Operational notes for the machine this project renders and reverse-engineers on. Written so the
setup can be checked, repaired, or rebuilt without anyone remembering how it was done.

**No credentials are recorded here or anywhere in this repo.** Access is by SSH key; if a key is
missing, ask the repo owner rather than storing a password.

## The machines

**Since 2026-09-30 the box is CT 103 on the new host at the other house.** The old box is kept
as a fallback (`RENDER_HOST=root@192.168.5.78`) until it is retired. **The RE work moved too:** the
old box's 15-minute tick is off (its crontab is saved as `/root/crontab.bak-20260930` there), so the
new box's Ghidra projects are the only ones anything writes to. Everything under the old box's
`/var/tmp` came across except rendered frames and temp dirs (9,686 files, matched by name and size).

| Address | What |
|---|---|
| `192.168.10.78` | **CT 103 `ghidra-mcp`**, the box everything below runs on. Proxmox LXC, unprivileged, 28 cores / 64 GB / 8 GB swap / 250 GB rootfs on `local-lvm`, Debian 13, starts on boot. |
| `192.168.10.100` | **`pve`**, the Proxmox host holding it. Ryzen 9 5950X (16 cores / 32 threads), 125 GB, and the GPU, an **AMD Radeon RX 7600** (Navi 33, `0a:00.0`) on the host's `amdgpu` driver. |
| `192.168.5.95` | **VM 101 `ubuntu-01`** on `ca-pve-02` (192.168.5.121): the WireGuard link between the houses. It routes 192.168.10.0/24 for this house (IP forwarding on, NAT on `wg0`, MTU 1380, `/etc/wireguard/wg0.conf`, `wg-quick@wg0` enabled). |
| `192.168.5.78` | The old CT 103 on `ca-pve-01` (192.168.5.120): 10 cores / 20 GB / RX 5700 XT. Fallback only. |
| `192.168.5.121` | `ca-pve-02`: the k8s cluster (CI runner), PBS, the Cloudflare tunnel, NFS. **Must stay up**; VM 101 is the only thing added there. |

**Reaching it from this house:** the UniFi gateway routes 192.168.10.0/24 to 192.168.5.95, but its
intrusion prevention blocked repeated SSH through it (2026-09-30), so the dev machine routes
192.168.10.0/24 and 172.31.211.248/29 straight to 192.168.5.95
(`/etc/systemd/network/eth0.network.d/10-wireguard-route.conf`). The new host's fail2ban ignores
the tunnel's address, 172.31.211.250, which every machine here shares through the NAT. The link
adds about 35 ms a round trip, so `~/.ssh/config` keeps one multiplexed connection per host
(`ControlMaster`/`ControlPersist 4h`) instead of a handshake per command.

**Measured on the new box against the old (same build, 2026-09-30):** Jangan spawn 10.8-11.3 ms a
frame against 12.5-12.7; world entry 9.7-10.7 s against 14.0-15.5; longest freeze 3.4 s against
4.7-5.0; the full test suite 26 s (16 at a time, including the ship) against 59 s.

## What lives on the box

| Path | What |
|---|---|
| `/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64` | Godot, matching the version CI builds with. |
| `/opt/opensro-client` | A copy of this repo's `client/`. Refresh with `scp` of changed files; re-run `--import --quit` only when a new `class_name` appears. Owned by `ghidra`. |
| `/opt/opensro-server` | A copy of `server/`, for the Go analysis tools (`whatishere`, `o2sectors`, `pk2list`, `findregionassets`). Go 1.24 is installed. |
| `/opt/sro-files/client/` | Real client archives — `Data.pk2`, `Map.pk2`, `Media.pk2`, `Music.pk2`, `Particles.pk2` — plus `sro_client.exe`, byte-identical to the image in Ghidra. On the new box all five are real files here, and `/var/tmp/pslocal/*.pk2` are symlinks back to them for older scripts (on the old box it was the reverse: `Data.pk2` and `Map.pk2` lived in `pslocal` because its 40 GB disk could not hold two copies). Everything (`qa_shot.sh`, `remote_godot.sh`, the docs) addresses them through this directory, so if a run reports `pk2: could not open .../Data.pk2: 7`, check the symlinks resolve before looking anywhere else — that error means the file is missing, not that the archive is corrupt. |
| `/opt/sro-files/server/.../Data/` | ~264 already-extracted `.nvm` files, handy for format work without pk2 decryption. |
| `/opt/ghidra_12.1.3_PUBLIC` | Ghidra. Project `/home/ghidra/re_client/sro_client_re.gpr` holds the analysed client and server binaries. |

Analyse client data **on this box** and bring back only statistics, so pulled game data never
reaches the repo tree.

## The 15-minute tick, and the lock you must actually take

`/opt/opensro-re/re_tick.sh` runs from cron every 15 minutes. It keeps the
evidence fresh — rebuilds a decomp dump whose binary is newer than the dump's
own `DONE` marker, re-runs the standing probes, and writes `STATUS`.

**It guards itself with `flock -n 9` on `/opt/opensro-re/lock`.** That is an
*advisory* lock on the open file descriptor, not a lock on the file existing.
Two consequences, both of which have already cost this project a dump:

- **`touch /opt/opensro-re/lock` takes no lock and prevents nothing.** A job
  that announces itself that way will be run straight over.
- **`rm -f /opt/opensro-re/lock` is worse than useless** — it destroys the
  inode the cron holds its lock on, so the next tick creates a fresh file and
  locks that, and the mutex stops working entirely.

Any long Ghidra job must do `exec 9>/opt/opensro-re/lock; flock -n 9 || exit`
and simply let the descriptor close when it finishes. `/var/tmp/dump_all.sh`
does this and is the thing to copy.

The failure mode when you get it wrong is not obvious: the tick's staleness
check is `[ ! -f "$out/DONE" ]`, and an in-progress dump has no `DONE` yet
(`DecompAll.java` writes it at the end), so the tick concludes the dump is
stale and `rm -rf`s the directory out from under the running job. On
2026-09-15 that killed a client dump at shard 1513 with a
`FileNotFoundException` on the next shard — a message that points at disk, not
at a scheduler.

Note also that the cron's own dumps use a **30-second** per-function timeout
where `re_pass.sh` uses 180. The 27 KB `Client_LoadRefDataFile` needs ~30 s, so
a cron-built dump can carry `failed=1` where a hand-run one does not. Check the
`failed=` field in `DONE` before trusting a dump to be complete.

## Hardware rendering

The host has an **AMD RX 5700 XT (Navi 10, `03:00.0`)**. It had been configured for VFIO
passthrough — `amdgpu` blacklisted, `vfio-pci ids=1002:687f` — but no VM ever claimed it, so it
sat unbound with no driver while every frame was rasterised on the CPU by llvmpipe. That was the
difference between a screenshot costing minutes and costing seconds.

Reclaiming it needed no reboot: `blacklist` only suppresses udev auto-loading, and the card was
unbound, so `modprobe amdgpu` bound it live.

**Host** (`192.168.5.120`), now persistent across reboots:

- `/etc/modprobe.d/blacklist-amdgpu.conf` emptied, `blacklist amdgpu` commented out in
  `blacklist.conf`, and `1002:687f,1002:aaf8` removed from the `vfio-pci` ids in `vfio.conf`,
  followed by `update-initramfs -u`.
- **Originals are backed up in `/root/gpu-revert/` on the host.** Restore them and rebuild the
  initramfs to hand the card back to passthrough.

**Container**, in `/etc/pve/lxc/103.conf` — note the gids differ inside an unprivileged container
(`render` is **992** inside, `video` 44). On the new host the card is `card1`, not `card0`:

```
dev0: /dev/dri/renderD128,gid=992
dev1: /dev/dri/card1,gid=44          # the old host's was card0
```

This is not VFIO passthrough: the host keeps the card on its own `amdgpu` driver and the container
is given the device nodes, so the host and other containers can share it. The old host's notes
below (the RX 5700 XT reclaimed from a VFIO setup) apply to `ca-pve-01` only; the new host needed
nothing, its card was already on `amdgpu`.

The `ghidra` user is in the container's `render` and `video` groups. Installed inside:
`libgl1-mesa-dri`, `mesa-utils`, `mesa-utils-extra` (radeonsi), and **VirtualGL 3.1.1** from the
project's own `.deb` — Debian trixie has no `virtualgl` package.

**Why VirtualGL.** Godot's Linux GL backend draws through GLX on X11, and Xvfb has no DRI, so the
GPU would go unused even though it is present. VirtualGL services GLX through EGL on the render
node. `client/tools/qa_shot.sh` applies it automatically when `vglrun` and a readable
`/dev/dri/renderD128` are both present, and says on stderr which path it took.

### Checking it

```
# On the host: is the card bound?
lspci -k -s 03:00.0 | grep "driver in use"          # want: amdgpu
ls /dev/dri                                          # want: card0, renderD128

# In the container: does GL reach the GPU?
EGL_PLATFORM=surfaceless eglinfo -B | grep "core profile renderer"
xvfb-run -a vglrun -d egl0 glxinfo -B | grep "OpenGL renderer"
```

Both should name the Radeon RX 7600 (the old box: RX 5700 XT). **`llvmpipe` means it is running on the CPU** — expect
4–8 minute screenshots until that is fixed.

A `qa_shot.sh` log also states it directly, and Godot's own startup line reads
`Using Device: AMD - AMD Radeon RX 7600 (radeonsi, navi33, …)` (the old box: RX 5700 XT, navi10).

## Vulkan (Forward+) -- set up 2026-10-02, round 693

Forward+ is the client's default renderer from round 693. It needs Vulkan, and Vulkan needs a way
to present a frame. What was found and what was changed:

- **The driver was already there.** `mesa-vulkan-drivers` 25.0.7 (RADV) and `libvulkan1` were
  installed, and `ghidra` was already in `render` (992) and `video` (44). As ghidra,
  `vulkaninfo --summary` lists `AMD Radeon RX 7600 (RADV NAVI33)`, driver `radv`, beside
  `llvmpipe` (MEASURED). No container or host change was needed.
- **Xvfb cannot take a Vulkan frame.** Mesa's X11 presentation needs DRI3, which Xvfb lacks. Under
  plain Xvfb, Godot skips the RX 7600 and silently renders on **llvmpipe, the CPU** (banner
  `Using Vulkan Device #1: Unknown - llvmpipe`, MEASURED). With `MESA_VK_WSI_DEBUG=sw` it gets the RX
  7600, but every frame is copied back through the CPU. An empty scene then takes 17.5 ms a frame
  at 1280x720 and 4.7 ms at 640x360 (MEASURED), which swamps any frame time. That path is still
  available as `QA_VK_PRESENT=sw` in `qa_shot.sh`, for correct pictures only, never for timings.
- **What works: a headless Wayland compositor with Xwayland.** Xwayland has DRI3 through glamor on
  the render node. `client/tools/xwl_run.sh [-s WxH] <command>` starts a private `weston
  --backend=headless --renderer=gl --xwayland` (its GL renderer on the RX 7600) in a private
  `XDG_RUNTIME_DIR` under `/var/tmp`. It runs the command on that Xwayland's display and stops
  weston by PID afterwards. The same empty scene draws in 0.24 ms a frame there (MEASURED).
  `qa_shot.sh`, `perf_gate.sh` and the lane scripts use it for Forward+.
- **Headless runs are unaffected.** `--headless` selects the headless display server, which always
  uses the dummy rasterizer (READ, 4.2.2 `main/main.cpp` 1164-1167). The test suites, `--import`,
  `check_scripts.gd` and CI's exports draw nothing under either renderer.
- **The GL path is unchanged:** VirtualGL on Xvfb with `--rendering-driver opengl3`. GL also runs
  on xwl_run.sh's Xwayland without VirtualGL (Jangan spawn 8.23 ms against VirtualGL's 10.52,
  MEASURED once each). The tools keep VirtualGL for Compatibility so older numbers stay comparable.

**Changes made, and how to revert them** (both apt installs, on 2026-10-02):

| Change | Revert |
|---|---|
| `apt-get install vulkan-tools` (`vulkaninfo`, diagnostics only) | `apt-get remove vulkan-tools` |
| `apt-get install --no-install-recommends weston xwayland` (49 packages; the list is in `/root/fplus693-installed-packages.txt`, and `dpkg --get-selections` from before is in `/root/dpkg-selections-before-fplus693.txt`) | `apt-get remove weston xwayland && apt-get autoremove`, or restore the saved selections with `dpkg --set-selections < /root/dpkg-selections-before-fplus693.txt && apt-get dselect-upgrade` |

Nothing else was changed: no X server configuration, no service, no group, no udev rule, and
nothing on the Proxmox host. Nothing runs between renders, because each `xwl_run.sh` call starts
its own compositor and stops it.

**Checking it:**

```
su - ghidra -c 'vulkaninfo --summary | grep deviceName'          # want: AMD Radeon RX 7600 (RADV NAVI33)
su - ghidra -c '/opt/opensro-client/tools/xwl_run.sh /opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64 \
  --rendering-method forward_plus --rendering-driver vulkan --path <client> --quit-after 30' | grep "Vulkan API"
# want: Vulkan API 1.4.305 - Forward+ - Using Vulkan Device #0: AMD - AMD Radeon RX 7600 (RADV NAVI33)
```

**`llvmpipe` in that banner means the run is on the CPU.** `qa_shot.sh` warns about it, and
`perf_gate.sh` fails the run.

## Wine (the Windows build) -- installed 2026-10-03, round 700

To run a player's Windows release on the box (round 700's cursor question):
`apt-get install --no-install-recommends wine wine64` added 7 packages -- `wine`, `wine64`,
`libwine`, `libcapi20-3t64`, `libpcap0.8t64`, `libxkbregistry0`, `libz-mingw-w64` (Wine 10.0,
64-bit only: Godot's export is x86_64, so no i386 multiarch). Revert: `apt-get remove wine wine64
libwine && apt-get autoremove`.

- A prefix must sit in a folder owned by the user who runs Wine ("'/var/tmp/x' is not owned by you,
  refusing to create a configuration directory"); keep it under the lane's `/var/tmp` folder and
  delete it afterwards. `WINEDLLOVERRIDES="mscoree,mshtml="` skips the Mono / Gecko download
  prompts, `WINEDEBUG=-all` the noise.
- **Compatibility** runs under Xvfb (Mesa llvmpipe through Wine's opengl32 -- slow but enough for
  the login screen). **Forward+** runs on the RX 7600 under Xvfb with `MESA_VK_WSI_DEBUG=sw`
  (MEASURED, round 700: `Vulkan API 1.4.305 - Forward+ - Using Vulkan Device #0: AMD - AMD Radeon
  RX 7600 (RADV NAVI33)` from the Windows build); under `xwl_run.sh`'s Xwayland xdotool does not
  move the pointer, so cursor checks there read nothing.
- **Reading the cursor back:** Wine draws Win32 cursors as X cursors, so `XFixesGetCursorImage` (a
  25-line ctypes script) returns what the Windows build set: round 700 read the game's 0x95 (32 x
  32, hotspot (2, 1), 359 opaque pixels, mean (130, 126, 93)) from the Windows v0.1.483 build.
- Stop it with `wineserver -k` (as the user who ran it); nothing stays running between runs.

## Services on the box

`vncserver` (`ghidra`'s desktop on `:1`, port 5901), `novnc` (the same desktop in a browser on port
6080) and `ghidra-mcp-bridge` (the MCP bridge on 8081, talking to the GhidraMCP plugin's server on
8080 while a CodeBrowser is open) are systemd units, enabled. The bridge's Python packages are
pinned in `/opt/GhidraMCP/requirements.lock` (the old box's `pip freeze`): the unpinned
`requirements.txt` installed `mcp` 1.5.0, which lacks `mcp.server.transport_security`, and the
bridge would not start until `mcp` 1.29.0 was installed from the lock.

The 15-minute tick (below) reads the client binary from `/opt/sro-files/client/sro_client.exe` on
the new box; on the old box it read a byte-identical copy on an NFS share (192.168.5.125), which the
other house cannot reach.

## Driving Ghidra

The `mcp__ghidra__*` tool wrapper has been broken; the plugin's own HTTP server works. From the
box:

```
curl -s "http://127.0.0.1:8080/strings?filter=<text>&limit=20"
curl -s "http://127.0.0.1:8080/xrefs_to?address=<addr>&limit=30"
curl -s "http://127.0.0.1:8080/decompile_function?address=<addr>"
curl -s "http://127.0.0.1:8080/searchFunctions?query=<name>&limit=10"
```

Endpoint names differ from the tool names (`strings`, not `list_strings`). Use
`curl --get --data-urlencode` for filters containing `#`, `\` or `%`. The server only exists while
a CodeBrowser tool is open, and serves whichever program tab has focus.

Two traps that have each cost hours: **format magics are compared as integers, never stored as
text** (no binary contains `JMXVMAPM`; the loader does `= (int *)0x56584d4a`), and **`.rdata` float
constants are often doubles**, so a 4-byte read shows zeros — always read 8.

## Housekeeping

- **`/tmp` is tmpfs — RAM, not disk.** Rendered frames written there once filled 6.9 GB of the
  container's memory and wedged it so hard that sshd could not complete a handshake while still
  answering ping. Write frames to `/var/tmp` and delete them afterwards.
- **The root disk is 40 GB and `/var/tmp` is on it.** Frame dumps accumulate fast — a couple of
  days of QA runs left 8 GB of them — and a full disk does not fail a render: the movie writer
  keeps going and writes 0-byte PNGs, and nothing complains until they are opened. Every frame
  directory under `/var/tmp` is regenerable; delete them freely (`du -sh /var/tmp/*`), and keep
  `/opt` (the archives, Ghidra, Godot) alone. `qa_shot.sh` warns below 2 GB free.
- **One client at a time.** `qa_shot.sh` kills any running client before starting, so overlapping
  runs silently truncate each other. Wait for a run's own "done" marker *and* for no live process.
- If the container stops answering SSH, reach it from the host with `pct exec 103 -- <cmd>`;
  container processes are visible and killable from the host's `ps` too. Per-container memory is
  at `/sys/fs/cgroup/lxc/103/memory.current`.
