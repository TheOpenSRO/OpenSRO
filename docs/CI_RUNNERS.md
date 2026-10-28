# CI runners

Each kind of job has its own runners, picked by label (2026-10-28, at the user's request), so
a 20-minute test run never holds up a release or the website:

| Label | Runs | Runners |
|---|---|---|
| `opensro-test` | `.github/workflows/ci.yml` (every push and PR to main/dev) | `gh-test-1`, `gh-test-2` |
| `opensro-release` | `.github/workflows/release.yml` (tags and manual dev builds) | `pve-runner-1`, `pve-runner-2` |
| `opensro-web` | TheOpenSRO/website `deploy.yml` (opensro.org) | `gh-web-1` |

| Runner | Where | Size |
|---|---|---|
| `pve-runner-1` | LXC CT 106 `gh-runner-1` on Proxmox `pve` (192.168.10.100), 192.168.10.80 | 8 cores, 12 GB, 100 GB |
| `pve-runner-2` | LXC CT 107 `gh-runner-2` on `pve`, 192.168.10.81 | 8 cores, 12 GB, 100 GB |
| `gh-test-1` | LXC CT 108 `gh-test-1` on `pve`, 192.168.10.82 (a full clone of CT 106) | 8 cores, 12 GB, 100 GB |
| `gh-test-2` | LXC CT 109 `gh-test-2` on `pve`, 192.168.10.83 (a full clone of CT 106) | 8 cores, 12 GB, 100 GB |
| `gh-web-1` | LXC CT 110 `gh-web-1` on `pve`, 192.168.10.85 (fresh Ubuntu 24.04; git, curl, python3; setup-node fetches Node) | 2 cores, 2 GB, 16 GB |

- **Labels.** `pve-runner-1`/`-2` were relabelled through the API
  (`gh api -X PUT orgs/TheOpenSRO/actions/runners/<id>/labels -f 'labels[]=opensro-release'`);
  they no longer carry `opensro-pve` or `srrevamp-pve`. Re-registering one with `config.sh`
  resets its labels, so pass the right `--labels` then.
- **The test runners are clones of CT 106.** Before their first boot, runner 1's registration
  (`.runner`, `.credentials*`, `.service`) and systemd unit were moved out of the copies. After
  boot they got new machine ids and SSH host keys, then were registered as themselves. They keep
  runner 1's toolchains, Docker and the Godot cache.
- **The website runner must reach Cloudflare from the WAN address the API token allows**
  (99.151.222.255, checked from CT 110).

- **Setup (2026-10-01).** Ubuntu 24.04, unprivileged, `nesting=1,keyctl=1`, static IP, starts
  on boot.
  - Docker (`docker.io`, overlayfs) is there for the server job's `postgres:16` service
    container. A real run of that image answered `select 1` on both.
  - The runner is GitHub's `actions/runner` 2.337.0, checked against its published SHA-256,
    in `/home/runner/actions-runner` as user `runner`. That user is in the `docker` group and
    has passwordless sudo, because `native/ci_toolchain.sh` installs mingw-w64 with
    `sudo -n apt-get`.
  - The runner runs as a systemd service (`svc.sh install runner`).
  - **Where they are registered (2026-10-13, the move to TheOpenSRO):** both are organization
    runners of `TheOpenSRO` (Default group), so they serve `TheOpenSRO/OpenSRO`. The old repo
    `OpenSRO/OpenSRO` has no runner, and its release workflow is disabled; v0.1.541 was mirrored
    there by hand so clients that check the old repo update across to the new one.
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
  with a token that has the organization's "Self-hosted runners: read and write", run
  `tok=$(gh api -X POST orgs/TheOpenSRO/actions/runners/registration-token --jq .token)`.
  Then, as `runner` in `~/actions-runner`, run
  `./config.sh --url https://github.com/TheOpenSRO --token "$tok" --name <name> --labels <its label from the table above> --work /home/runner/_work --unattended --replace`,
  and as root `./svc.sh install runner && ./svc.sh start`. The token expires after an hour;
  don't commit or log it.
- **Moving one off a repo:** `./config.sh remove` fails with a 404 when the repo was renamed
  since the runner registered (it posts the old name). Delete the runner's record through the API
  instead (`gh api -X DELETE repos/<owner>/<repo>/actions/runners/<id>`), stop and uninstall the
  service, move `.runner`, `.credentials`, `.credentials_rsaparams`, `.service` and
  `.runner_migrated` out of `~/actions-runner`, then register as above.
- **Checking them:** `gh api orgs/TheOpenSRO/actions/runners --jq '.runners[] | "\(.name) \(.status) busy=\(.busy) \([.labels[].name] | join(","))"'`.
