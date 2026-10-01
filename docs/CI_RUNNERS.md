# CI runners

Every srrevamp workflow (`.github/workflows/ci.yml` and `release.yml`) runs on
`runs-on: [self-hosted, srrevamp-pve]`, and only there.

| Runner | Where | Size |
|---|---|---|
| `pve-runner-1` | LXC CT 106 `gh-runner-1` on Proxmox `pve` (192.168.10.100), 192.168.10.80 | 8 cores, 12 GB, 100 GB |
| `pve-runner-2` | LXC CT 107 `gh-runner-2` on `pve`, 192.168.10.81 | 8 cores, 12 GB, 100 GB |

- **Setup (2026-10-01).** Ubuntu 24.04, unprivileged, `nesting=1,keyctl=1`, static IP, starts
  on boot.
  - Docker (`docker.io`, overlayfs) is there for the server job's `postgres:16` service
    container. A real run of that image answered `select 1` on both.
  - The runner is GitHub's `actions/runner` 2.337.0, checked against its published SHA-256,
    in `/home/runner/actions-runner` as user `runner`. That user is in the `docker` group and
    has passwordless sudo, because `native/ci_toolchain.sh` installs mingw-w64 with
    `sudo -n apt-get`.
  - The runner runs as a systemd service (`svc.sh install runner`), registered to
    `OpenSRO/srrevamp` with the label `srrevamp-pve`.
- **Why.** The old runner, the `kakariko-runner` ARC scale set in the kakariko cluster, ran
  one ephemeral pod at a time. Every job re-downloaded Godot, Rust, zig and mingw. On
  2026-10-01 slow downloads (zig 4.5 min, Godot setup 4 min 17 s) held that single runner
  while the v0.1.466 release queued.
  - These two runners are persistent. The toolchains, the Go module cache and the Godot
    install that setup-godot caches all stay between runs.
  - Two runners take two jobs at once.
- **The old runner is still registered.** No workflow targets it any more, but it hasn't been
  deleted; that's the user's call.
- **The work folder must be `/home/runner/_work`** (the `workFolder` in `~/actions-runner/.runner`).
  setup-godot's cache stores Godot at a path relative to the workspace, and the cache entries were
  saved on the old kakariko pod, whose workspace is `/home/runner/_work/srrevamp/srrevamp`. With the
  default `_work` under `~/actions-runner`, a cache hit unpacked Godot one level too deep, and both
  Godot jobs failed with "No Godot executable found" (CI run 36834736619, attempt 1). With
  `/home/runner/_work`, attempt 2 passed all four jobs. `--work /home/runner/_work` when
  re-registering.
- **Re-registering one** (e.g. after rebuilding the container): on a machine logged into `gh`
  as a repo admin, run
  `tok=$(gh api -X POST repos/OpenSRO/srrevamp/actions/runners/registration-token --jq .token)`.
  Then, as `runner` in `~/actions-runner`, run
  `./config.sh --url https://github.com/OpenSRO/srrevamp --token "$tok" --name pve-runner-N --labels srrevamp-pve --work /home/runner/_work --unattended --replace`,
  and as root `./svc.sh install runner && ./svc.sh start`. The token expires after an hour;
  don't commit or log it.
- **Checking them:** `gh api repos/OpenSRO/srrevamp/actions/runners --jq '.runners[] | "\(.name) \(.status) busy=\(.busy)"'`.
