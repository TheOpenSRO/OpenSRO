# Progress Log

Running log of what's been done, in reverse-chronological order. Each entry: date, what changed, what's next.

## 2026-08-19

- Repo initialized: `main` (protected) + `dev` branches.
- Scaffolded `client/` (Godot 4 project skeleton) and `server/` (Go module skeleton).
- CI workflow added: builds server on every push/PR, validates client project structure.
- Wrote `docs/LEGAL.md` codifying the clean-room / BYO-pk2 policy.
- No protocol/format work implemented yet — next up: `docs/protocol/PK2_FORMAT.md` and a
  read-only pk2 container parser in `client/` (JOYMAX pk2 format + Blowfish-based filename/
  header obfuscation are publicly documented; implementing from that documentation, not from
  disassembly).
