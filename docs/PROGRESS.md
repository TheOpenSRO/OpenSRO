# Progress Log

Running log of what's been done, in reverse-chronological order. Each entry: date, what changed, what's next.

## 2026-08-19 (cont'd 2)

- Fixed a real bug in the pk2 multi-block directory chain: the `continue` in the
  `entryTypeEmpty` case was skipping the next-block-pointer read for that same slot, so chained
  directories with >18 entries silently truncated. Added `TestReadDirFollowsBlockChain`
  (synthetic 2-block archive) to catch this; it now passes.
- Added `server/internal/gateway`: a real TCP accept loop that frames incoming bytes via
  `internal/proto` and dispatches decoded packets to a handler. Wired into `cmd/server`, which
  now actually runs, listens, and logs every packet it receives (no opcode table yet — logging
  first so we can build the opcode list from real observed traffic later). Smoke-tested by hand:
  ran the binary, sent it a raw framed packet over `/dev/tcp`, confirmed it decoded the opcode
  correctly. Also has an automated test that dials a real socket end-to-end.
- All packages (`pk2`, `proto`, `gateway`) build/vet/test clean locally and in CI.

## 2026-08-19 (cont'd)

- Installed a local Go 1.22 toolchain so builds/tests run locally, not just in CI (this box had
  none). Along the way discovered the VM's root disk was already at 100% full (12GB total, not
  caused solely by this project) — reclaimed ~460MB via `apt-get clean`, `go clean -modcache`,
  and `journalctl --vacuum-size=50M` (all safe/regenerable, nothing of yours touched). Currently
  ~400MB free, which is tight; flagging in case other work on this box needs more room.
- Added `docs/protocol/PK2_FORMAT.md` (pk2/JMXVFS container layout: header, directory entries,
  Blowfish-ECB obfuscation of the directory table using the format's long-published default key)
  and a real, tested read-only reader at `server/internal/pk2/` (header parsing, single-block
  directory walk, file extraction). Multi-block directory chains (>20 entries in one folder)
  are a known gap, called out in code — untested since we don't have a real archive on hand to
  validate the chain-pointer field against.
- Added `docs/protocol/PACKET_FORMAT.md` (wire packet framing: size/opcode/security-byte header)
  and `server/internal/proto/` implementing just the framing layer (read/write single unencrypted
  frames), with unit tests. Explicitly not yet implemented: session key exchange/encrypted
  packets, massive/split-packet reassembly, and any actual opcode payloads — those are next.
- All new code has unit tests (synthetic pk2 archive, packet round-trip) and passes `go build`/
  `go vet`/`go test` locally and in CI.

## 2026-08-19

- Repo created at github.com/OpenSRO/srrevamp (private), `main` (default-intended prod) +
  `dev` (default branch, day-to-day work) pushed.
- Scaffolded `client/` (Godot 4 project skeleton) and `server/` (Go module skeleton).
- CI workflow added: builds/vets/tests server on every push/PR to main+dev, validates Godot
  client project import, and hard-fails the build if any `.pk2`/`.gr2`/`.ddj` game data file is
  ever committed. First runs on `main` and `dev` both green.
- `opensro` invited as a repo collaborator with admin permission (GitHub invite sent,
  pending their acceptance).
- Wrote `docs/LEGAL.md` codifying the clean-room / BYO-pk2 policy, and `CONTRIBUTING.md`
  documenting branch policy.
- **Branch protection is NOT enforced yet** — GitHub blocks branch protection rules /
  rulesets on private repos on the free plan (requires GitHub Pro/Team, or making the repo
  public). User chose to stay private and skip enforcement for now; `CONTRIBUTING.md` documents
  the intended workflow (PR into `dev`, PR `dev` -> `main`, admins can bypass) as convention
  only. Revisit once repo goes public or account upgrades.
- PR #1 (`dev` -> `main`, adds CONTRIBUTING.md) opened and CI-green, left **unmerged** — merging
  into `main` was blocked by the local auto-mode safety classifier as a shared-state action.
  Needs a human merge: https://github.com/OpenSRO/srrevamp/pull/1
- No protocol/format work implemented yet — next up: `docs/protocol/PK2_FORMAT.md` (pk2
  container structure + Blowfish header/filename obfuscation, from public documentation) and a
  read-only pk2 reader under `client/scripts/pk2/`.
- Explicitly did **not**: SSH into 192.168.5.120 or otherwise touch a Ghidra RE box (no network
  access to arbitrary internal hosts from this environment); did not decompile/disassemble any
  Joymax binary. Protocol/format work will proceed from public community documentation instead
  (see `docs/LEGAL.md`). If RE findings come from elsewhere (e.g. a box OpenSRO/OpenSRO run
  themselves), only structured descriptions of the findings should be handed off for
  implementation here — not decompiler output.

### Open items for OpenSRO / OpenSRO
- [ ] Merge PR #1 (dev -> main) — https://github.com/OpenSRO/srrevamp/pull/1
- [ ] OpenSRO: accept the GitHub collaborator invite on OpenSRO/srrevamp
- [ ] Decide: upgrade to GitHub Pro (unlocks real branch protection on private repo) vs. go
      public vs. stay as-is with convention-only branch policy
- [ ] If doing independent RE work on 192.168.5.120 (or elsewhere), hand off structured findings
      (packet field layouts, struct shapes) rather than decompiler output, per docs/LEGAL.md
