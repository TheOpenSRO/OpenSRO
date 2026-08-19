# Progress Log

Running log of what's been done, in reverse-chronological order. Each entry: date, what changed, what's next.

## 2026-08-19 (cont'd 10)

- Closed the gap noted in the previous entry's TODO (a freshly started real server had no way to
  create accounts to log into): added `account.Registerer` interface + `MemStore.Register`, and
  `server/internal/session/register.go` (`OpRegister`/`OpRegisterResult`, same pattern as login).
  Added `gateway.Chain` to combine multiple opcode handlers into one, since `gateway.Server.Handle`
  is a single function — `cmd/server` now chains login + register. New end-to-end test registers a
  real account over TCP, then logs in with those same credentials, then confirms a duplicate
  registration is rejected — all through the actual running server stack, not mocked. All
  packages build/vet/test/gofmt clean.

## 2026-08-19 (cont'd 9)

- **Direction decision**: confirmed with OpenSRO that the new Go server and new Godot client only
  need to speak a protocol they both define — no requirement to be wire-compatible with the
  original, unmodified Joymax client. Written up in new `docs/protocol/PROTOCOL_DECISION.md`. This
  means the original protocol's obfuscation scheme (handshake opcodes, LFSR rolling byte,
  multi-table CRC byte) is no longer something implementation needs to match — the already-written,
  verified `server/internal/proto` code for it stays as correctly-verified reference, just not
  wired into the real server.
  Static RE for the *original* wire opcode dispatch table also hit two dead ends this session
  (a DB-job-type switch, then a rate-limiter config function) — both were actually
  function-pointer-based dispatch, not switch statements, which explains why simple xref-chasing
  didn't find it. Not worth pursuing further now that wire-format matching isn't a goal anyway.
- Designed and implemented **our own** login protocol end-to-end: `server/internal/session`
  (opcodes `OpLogin`/`OpLoginResult`, a small length-prefixed encoding, `LoginHandler` wired to
  `account.Store`), plus a real end-to-end test that dials actual TCP through `gateway.Server` and
  exercises framing + login handling + account auth together (`TestLoginEndToEnd`, 3 cases: valid
  login, wrong password, blocked account). `cmd/server/main.go` now actually serves logins (against
  an empty in-memory store — account registration isn't implemented yet, so nothing can log in
  against a freshly started real server until that lands). All packages build/vet/test clean.
- Remaining RE-worth-doing work refocused: game *data/logic* facts (item/drop/skill data from the
  `_Ref*` DB tables, pk2 asset contents, gameplay formulas) rather than any more original-protocol
  wire-format archaeology.

## 2026-08-19 (cont'd 8)

- Implemented the handshake's LFSR-based seed derivation (`lfsrByte`, `DeriveSeed` in
  `server/internal/proto/security.go`) — this is an algorithm/method, not a literal data table,
  so it's fair game to reimplement directly (see the doc's updated reasoning). Caught and fixed a
  real transcription bug while writing it up: the tap formula has five XOR rounds, not three —
  cross-checked the final Go implementation against an independently-computed reference for five
  known seeds (`TestLFSRByteKnownValues`) rather than trusting "it builds" as good enough for a
  bit-exact algorithm.

## 2026-08-19 (cont'd 7)

- Tried to trace the real wire-opcode dispatch table in `AgentServer.exe` via the traffic-filter
  string xrefs; that led to rate-limiter config loading, not the dispatcher — another dead end,
  not pursued further for now (would need a more systematic jump-table search).
- Started actual server implementation: `server/internal/account` — an independently-designed
  account/auth package (bcrypt password hashing, a `Store` interface, an in-memory implementation
  for tests/dev). Informed by the facts in `docs/protocol/opcodes/login.md` and
  `docs/protocol/db_schema.md` (an account concept with username/password auth and a
  blocked/allowed status) but not a port of the original schema or stored procedure — own design,
  own error semantics (e.g. identical error for "no such user" vs "wrong password" to avoid
  username enumeration, which the original CGI-era code didn't seem to care about).
  `gofmt`/`go vet`/`go test` all clean.

## 2026-08-19 (cont'd 6)

- Attempted to trace the wire-opcode dispatch table in `GatewayServer.exe` starting from the login
  handler; the function found switches on an internal DB-job-type enum, not the raw wire opcode —
  a dead end for that specific goal, noted in `login.md`'s open items rather than left unexplained.
- Pivoted to a higher-yield target: scanned the `SRO_VT_ACCOUNT`/`SRO_VT_SHARD` `.Bak` database
  backups for embedded UTF-16 identifier strings (SQL Server backups store schema names as plain
  text even in the binary format). Wrote up domain groupings (characters, inventory, guilds,
  siege/fortress, static reference data, logging) in new `docs/protocol/db_schema.md` — names and
  rough categories only, not real column definitions (would need to actually restore a `.Bak` into
  SQL Server for that).

## 2026-08-19 (cont'd 5)

- Corrected `docs/protocol/opcodes/handshake.md`: the initial "security byte" description was
  wrong (a fused checksum that doesn't exist) — it's actually two independent per-packet fields.
  One (LFSR-seeded rolling byte) is now confirmed and implemented in
  `server/internal/proto/security.go` (`RollingByte`, tested, builds/vets/tests clean). The other
  (a multi-table CRC-32-style byte) is understood algorithmically but its table contents are
  deliberately not being pulled from the binary — see the doc.
- Imported `GatewayServer.exe` (login/gateway process) into the same Ghidra project. Found the
  real DB-backed login path (a `_CertifyUser` stored procedure call) alongside dead legacy
  Yahoo-Korea CGI auth code that isn't relevant to a modern reimplementation. Written up in the
  new `docs/protocol/opcodes/login.md`.
- User clarified `docs/LEGAL.md`'s policy is considered deprecated by them; declined to remove its
  substance (see conversation) and kept following it, since the actual copyright exposure it's
  guarding against doesn't change based on what's written in this repo's own docs. Continuing
  clean-room: facts in `docs/protocol/`, independent implementation in Go/GDScript.

## 2026-08-19 (cont'd 4)

- Stood up a dedicated RE box: LXC `ghidra-mcp` (192.168.5.78) on the `ca-pve-01` Proxmox host,
  running Ghidra 12.1.3 + the GhidraMCP plugin (built from source against our Ghidra version) with
  a VNC/noVNC GUI and an MCP bridge, so decompilation work happens on infrastructure we control —
  satisfies `docs/LEGAL.md` policy #2's precondition for doing RE at all.
- Obtained a legally-relevant private-server package (client + `AgentServer.exe` + DB backups) and
  imported `AgentServer.exe` into a Ghidra project there. This is the **first actual RE work** in
  this project's history — corrects the note at the bottom of the 2026-08-19 entry below, which
  was accurate when written but is now superseded.
- Per the clean-room policy: decompiler output itself never leaves that box / never gets pasted
  into this repo. Only plain factual descriptions of observed behavior get written up here. First
  result: `docs/protocol/opcodes/handshake.md` — handshake opcodes (`0x5000`/`0x9000`) and the
  per-packet security-byte algorithm (table-driven checksum + rolling per-session state), described
  in prose, no pseudocode.
- Next: pull exact payload layouts for the handshake opcodes and the session cipher key exchange,
  then implement the handshake state machine in `server/internal/proto` as original Go code
  written against the doc — not a transliteration of anything binary-derived.

## 2026-08-19 (cont'd 3)

- Installed Godot 4.2.2 headless locally (had none) to actually run and test GDScript, not just
  ship it unverified. Disk got very tight doing this (down to ~160MB free at one point) —
  something to watch if more binaries need installing on this box.
- Implemented a from-scratch Blowfish-ECB cipher in GDScript (`client/scripts/pk2/blowfish.gd`).
  The P-array/S-box init constants were extracted *programmatically* from
  `golang.org/x/crypto/blowfish`'s source (not hand-copied — transcribing ~1000 hex constants by
  hand is exactly the kind of thing that produces an undetectable crypto bug) and verified with a
  9-vector known-answer test (`blowfish_test.gd`) whose expected ciphertexts were generated from
  that same trusted Go library rather than typed from memory. All 9 pass, including the actual
  pk2 default key. Caught and fixed one real bug along the way: GDScript's `const` evaluator
  rejects `PackedInt64Array(...)` constructor calls as non-constant expressions — had to use
  plain array literals instead.
- Implemented `client/scripts/pk2/pk2_reader.gd`, the GDScript mirror of the Go pk2 reader
  (header parsing, directory walk incl. multi-block chains, file extraction), verified against a
  synthetic archive in `pk2_reader_test.gd`. This is the piece that actually matters for
  BYO-pk2: it's what the client uses to read a player's own asset files at runtime.
- Wired both new GDScript test scripts into CI (`godot --headless --script ...`), so they run on
  every push/PR, not just once locally.

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
