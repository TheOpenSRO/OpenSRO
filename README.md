# SRRevamp

A from-scratch, clean-room reimplementation of a Silkroad Online–style MMO client and server.

See [docs/LEGAL.md](docs/LEGAL.md) for the full policy.

## Layout

- `client/` — Godot 4 client. Loads user-supplied `*.pk2` archives at runtime; ships with none.
- `server/` — Go server (world/login/gateway services).
- `docs/` — architecture, protocol notes, decomp/RE tracking log.

## Running locally

**Docker Compose** (server + Postgres, no local Go/Postgres install needed):

```
docker compose up --build
```

Server listens on `localhost:15779` (plain TCP by default). Postgres data persists in a named
volume across restarts; `docker compose down -v` wipes it for a clean slate. Requires a Docker
host that can actually run containers — an LXC container needs nesting enabled for this to work.

**Without Docker** (needs a local Postgres at `localhost:5432`, user/pass `postgres`/`postgres`,
databases `srrevamp` + `srrevamp_test`):

```
cd server
go run ./cmd/server
```

Either way, then open `client/` in the Godot 4.2 editor (or `godot4 --path client`) — it boots to
the login screen and connects to `127.0.0.1:15779` by default (see `client/scripts/Login.gd`).

Run the test suites from `server/` (`go test ./...`, needs the same local Postgres) and `client/`
(`godot4 --headless --path . --script res://scripts/net/<name>_test.gd` for each file, or see
`.github/workflows/ci.yml` for the full list CI runs).

## Branching

- `main` — protected, production. Requires PR + passing CI. Repo admins can bypass (force push)
  when truly necessary.
- `dev` — integration branch, default target for feature branches and day-to-day work.

## Status

Server-side protocol (accounts, characters, world/chat, combat/loot, inventory/equipment, shop,
quests, party/guild, duels, trade, friends) is implemented and tested end-to-end, with a matching
2D client HUD (`client/scenes/World.tscn`) wired to all of it. No 3D rendering yet — that needs
its own reverse-engineering pass on the original asset formats (mesh/texture/animation), which
hasn't started. See `docs/PROGRESS.md` for the detailed running log.
