# SRRevamp

A from-scratch, clean-room reimplementation of a Silkroad Online–style MMO client and server.

## Why "clean-room"

This project does **not** contain, redistribute, or derive code from decompiled Joymax/Gravity
binaries. Two reasons:

1. **Legal.** Silkroad Online's client/server binaries and original data files are copyrighted
   works owned by their publisher. Decompiling them and shipping derivative code is a real
   copyright exposure, not something solved by asset substitution.
2. **Portability.** By building the engine/protocol layer independently and having players
   supply their **own legally-owned `*.pk2` archives**, we sidestep redistributing any original
   IP while still being compatible with the original data format.

All game logic, network protocol, and file-format handling here is implemented from public,
community-documented sources (long-standing private-server protocol docs, public pk2/blowfish
format writeups, etc.), not from reverse engineering official binaries in this repo's history.
If protocol details are ever derived from independent reverse engineering (e.g. someone running
their own RE pass against binaries they legally own), only the resulting *structured findings*
(packet layouts, struct shapes) are implemented here — never disassembled/decompiled code.

See [docs/LEGAL.md](docs/LEGAL.md) for the full policy.

## Layout

- `client/` — Godot 4 client. Loads user-supplied `*.pk2` archives at runtime; ships with none.
- `server/` — Go server (world/login/gateway services).
- `docs/` — architecture, protocol notes, decomp/RE tracking log.

## Branching

- `main` — protected, production. Requires PR + passing CI. Repo admins can bypass (force push)
  when truly necessary.
- `dev` — integration branch, default target for feature branches and day-to-day work.

## Status

Early scaffolding. See `docs/PROGRESS.md` for the running log.
