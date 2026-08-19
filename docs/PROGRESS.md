# Progress Log

Running log of what's been done, in reverse-chronological order. Each entry: date, what changed, what's next.

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
