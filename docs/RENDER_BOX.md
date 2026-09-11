# The render / RE box

Operational notes for the machine this project renders and reverse-engineers on. Written so the
setup can be checked, repaired, or rebuilt without anyone remembering how it was done.

**No credentials are recorded here or anywhere in this repo.** Access is by SSH key; if a key is
missing, ask the repo owner rather than storing a password.

## The machines

| Address | What |
|---|---|
| `192.168.5.78` | **CT 103 `ghidra-mcp`** — the box everything below runs on. A Proxmox *LXC container*, unprivileged, currently 10 cores / 20 GB / 4 GB swap / 40 GB rootfs, Debian 13. |
| `192.168.5.120` | **`ca-pve-01`**, the Proxmox host holding CT 103. 12 cores, 31 GB, and the GPU. |
| `192.168.5.121` | Unrelated and **must stay up** — do not touch it. |

The host also has stopped VM guests (`win-01`, `sro-vm-02`, `sro-vm-03`) which are expendable;
CT 103 is not.

## What lives on the box

| Path | What |
|---|---|
| `/opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64` | Godot, matching the version CI builds with. |
| `/opt/srrevamp-client` | A copy of this repo's `client/`. Refresh with `scp` of changed files; re-run `--import --quit` only when a new `class_name` appears. Owned by `ghidra`. |
| `/opt/srrevamp-server` | A copy of `server/`, for the Go analysis tools (`whatishere`, `o2sectors`, `pk2list`, `findregionassets`). Go 1.24 is installed. |
| `/opt/sro-files/client/` | Real client archives — `Data.pk2`, `Map.pk2`, `Media.pk2`, `Music.pk2`, `Particles.pk2` — plus `sro_client.exe`, byte-identical to the image in Ghidra. |
| `/opt/sro-files/server/.../Data/` | ~264 already-extracted `.nvm` files, handy for format work without pk2 decryption. |
| `/opt/ghidra_12.1.3_PUBLIC` | Ghidra. Project `/home/ghidra/re_client/sro_client_re.gpr` holds the analysed client and server binaries. |

Analyse client data **on this box** and bring back only statistics, so pulled game data never
reaches the repo tree.

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
(`render` is 104 on the host but **992** inside):

```
dev0: /dev/dri/renderD128,gid=992
dev1: /dev/dri/card0,gid=44
```

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

Both should name the Radeon RX 5700 XT. **`llvmpipe` means it is running on the CPU** — expect
4–8 minute screenshots until that is fixed.

A `qa_shot.sh` log also states it directly, and Godot's own startup line reads
`Using Device: AMD - AMD Radeon RX 5700 XT (radeonsi, navi10, …)`.

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
