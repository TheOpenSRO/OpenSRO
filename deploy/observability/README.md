# Observability: Prometheus, Loki and Grafana (round 858)

Metrics and logs from the production game server, kept on the monitoring container and read in
Grafana. OURS throughout: the original game has nothing of the kind.

## What runs where

| Where | What | Port |
|---|---|---|
| Proxmox `192.168.10.100`, **CT 111 `monitoring`**, `192.168.10.86` | this directory's Docker Compose stack, in `/opt/opensro-observability` | |
| | Prometheus v3.5.0: metrics, 90 days; remote-write receiver on (`/api/v1/write`); alert rules from `prometheus/rules/*.yml` | `9090` |
| | Loki 3.5.3: logs, 30 days (`loki/config.yaml`) | `3100` |
| | Grafana 12.1.1: datasources `Prometheus` (uid `prometheus`) and `Loki` (uid `loki`), dashboards from `grafana/dashboards/*.json` in the folder **OpenSRO**; admin password in `.env` (not committed) | `3000` |
| prod Mac mini `192.168.10.146` | the game server: Prometheus `/metrics` on **`127.0.0.1:9469`** (`-metrics-addr`), its log in `~/opensro/logs/` | `9469` (loopback) |
| | Grafana Alloy (Homebrew): tails the server's log into Loki and scrapes `127.0.0.1:9469/metrics` every 15 s, remote-writing to Prometheus | |

Never touch CT 104 on the same Proxmox host (the shard DB restore).

Nothing on the monitoring container scrapes the game server: the server's `/metrics` stays on
loopback on the Mac, and Alloy pushes. Prometheus's own scrapes are the stack's (itself, Loki,
Grafana).

## Feeding it: Alloy on the server's host

Alloy must label both streams the way the dashboards and rules select them:

- metrics: `job="opensro-server"`, `instance="prod"` (every rule and panel filters on
  `job="opensro-server"`; the server dashboard's *Instance* variable lists the `instance` values);
- logs: the same `job="opensro-server"`, `instance="prod"` stream labels (the logs dashboard's
  *Stream* box defaults to `{job="opensro-server"}`). The lines are slog's text format, logfmt
  (`time=... level=INFO msg="..." key=value ...`); the dashboards parse them at query time
  (`| logfmt`), so Alloy needs no parsing stage. Keep `level` out of the stream labels or add
  it as one; both work.

The shape (a sketch; the file on the Mac is the source of truth):

```alloy
prometheus.scrape "opensro" {
  targets         = [{"__address__" = "127.0.0.1:9469", "job" = "opensro-server", "instance" = "prod"}]
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.monitoring.receiver]
}
prometheus.remote_write "monitoring" {
  endpoint { url = "http://192.168.10.86:9090/api/v1/write" }
}
local.file_match "opensro" {
  path_targets = [{"__path__" = "/Users/gaigelama/opensro/logs/opensro.log", "job" = "opensro-server", "instance" = "prod"}]
}
loki.source.file "opensro" {
  targets    = local.file_match.opensro.targets
  forward_to = [loki.write.monitoring.receiver]
}
loki.write "monitoring" {
  endpoint { url = "http://192.168.10.86:3100/loki/api/v1/push" }
}
```

`loki.source.file` follows the file by name, so the server's own rotation (below) is picked up:
the renamed file is read to its end and the new one from its start.

## The server's side

### Metrics (`-metrics-addr`, on by default)

`-metrics-addr ADDR` (env `OPENSRO_METRICS_ADDR`, default `127.0.0.1:9469`; empty turns it off)
serves `/metrics` (`internal/metrics`). A listen error on an address the operator named stops the boot; the default address already taken (a second server on the host) only logs a warning and runs without metrics. Bind it to loopback: the
game port is the only one meant for the internet (the server warns otherwise).

The families, all prefixed `opensro_` unless named otherwise. No label carries a player, a
character or an account; every label takes its values from a fixed set.

| Family | Type | Labels | Where it is counted |
|---|---|---|---|
| `go_*`, `process_*`, `go_sched_latencies_seconds` | runtime | | Go and process collectors (scheduler latency: the CPU-starved signal) |
| `build_info` | gauge (1) | `version` (`-ldflags -X main.version=`), `commit`, `modified`, `go_version` | `cmd/server` |
| `start_time_seconds` | gauge | | process start (a restart moves it) |
| `gateway_connections_accepted_total`, `gateway_connections_active` | counter, gauge | | `gateway.serveConn`, every listener |
| `gateway_disconnects_total` | counter | `reason`: client_closed, read_error, handler_error, handler_panic, ended, send_stalled, shutdown, codec_start | `gateway.serveConn` |
| `gateway_send_stalls_total` | counter | `reason`: timeout, budget, queue | `gateway.stallLocked` |
| `gateway_bytes_total` | counter | `dir`: in, out | the socket reader; the session writer |
| `gateway_packets_total` | counter | `dir`, `opcode` (hex of an opcode the code names, else `other`), `group` | the read loop; `Session.enqueue` |
| `gateway_handler_seconds` | histogram | `group`: login, lobby, world, combat, item, economy, guild, social, quest, cos, gm, other | `gateway.dispatch` |
| `gateway_handler_errors_total` | counter | `group`, `kind`: error, panic | `gateway.dispatch` |
| `world_broadcasts_total`, `world_broadcast_deliveries_total` | counter | | `gateway.NewFrame` (one per broadcast), `SendFrames` (per recipient) |
| `sessions` | gauge | `state`: connected, authenticated, in_world | scrape time |
| `players_online`, `players_online_by_zone` | gauge | `zone`: a named town (in the one world frame: the town whose centre region is nearest), a served dungeon's label, `dungeon`, `other` | scrape time (`session.MetricsSource`) |
| `world_entities` | gauge | `kind`: player, monster, npc, cos, ground_item, stall | scrape time |
| `world_mover_lock_hold_seconds` | gauge | | the last mover pass's write-lock hold |
| `logins_total` | counter | `result`: ok, wrong_password, blocked, inspection, already_connected, full, ip_limit, failed, ... | `session.LoginService.Login` (both wires) |
| `world_entries_total`, `character_ops_total` | counter | `op`: create, delete, restore | `enterOwned`; the lobby |
| `move_legs_total` | counter | `kind`: destination, heading | `world.Hub.StartMove` |
| `move_refused_total` | counter | `reason`: near | `world.Hub.StartMove` |
| `move_leg_ends_total` | counter | `reason`: wall, run_limit | `world.Hub.AdvanceMovers` |
| `move_claims_total` | counter | `result`: taken, refused, refused_wall (round 857), refused_state | `session.handleMove` |
| `move_corrections_total` | counter | | `correctMover` |
| `teleports_total` | counter | `kind`: gate, zone_change, walk_in, return_scroll, guild_recall, revive, unstuck, gm, other | `session.warpVia` |
| `zone_change_refused_total` | counter | `reason`: not_gm (round 854), dead, same_zone, not_in_world, malformed | `handleChangeZone` |
| `player_deaths_total`, `player_revives_total` | counter | | `markDead`, `reviveWith` |
| `gm_commands_total` | counter | `verb` (the console's commands, else unknown), `result`: ok, refused | `GMCommandHandler` |
| `loop_tick_seconds`, `loop_overruns_total`, `loop_last_tick_timestamp_seconds`, `loop_period_seconds` | histogram, counter, gauge, gauge | `loop`: monster_ai, monster_aoi, cos, buffs, toggles, status, regen, mover, potions, ground_items, nest | each ticker |
| `skill_casts_total` | counter | | `nextCastID` (every announced player cast) |
| `combat_damage_events_total`, `combat_damage_total` | counter | `target`: monster, player; `source`: attack, effect, monster, duel, pvp | `combat.Hub.ApplyDamageFrom`; the player-damage sites |
| `monsters_spawned_total`, `monsters_killed_total`, `monsters_removed_total` | counter | | `combat.Hub` |
| `items_dropped_total`, `items_picked_total`, `items_expired_total` | counter | `kind`: gold, item; `by`: player, pet | `grounditem.Hub`; the pick-ups |
| `gold_total` | counter | `dir`: in, out | the character stores' `AddGold` / `DeductGold` (summed over everyone) |
| `mall_purchases_total`, `silk_spent_total`, `gacha_draws_total` | counter | `result`: ok, refused | `mallBuy`; the draw |
| `stall_events_total`, `exchanges_total` | counter | `event`: opened, closed, sold, sale_failed; `result`: done, failed | the stall and exchange handlers |
| `db_queries_total`, `db_errors_total`, `db_query_seconds`, `db_transactions_total` | counter, counter, histogram, counter | `pool`: stores, refdata; `op`: select, insert, update, delete, with, ddl, savepoint, other; `table` (first table named, capped at 128) | the driver connector `txn.OpenNamedPool` wraps |
| `go_sql_*` | gauge, counter | `db_name`: stores, refdata | the pools' `sql.DBStats` |
| `log_messages_total` | counter | `level` | the slog handler |
| `panics_recovered_total` | counter | `where`: handler, disconnect_hook, cos_tick, session_* | each `recover` |

Guild operations are `gateway_packets_total{dir="in", group="guild"}` by opcode.

A new opcode constant needs `go generate ./internal/metrics` (the opcode table;
`TestOpcodeTableIsCurrent` fails until it is run).

### Logs (`-log-file`, `-log-level`)

The format stays slog's text (logfmt). Keys are consistent: `character` is a character's name,
`character_id` its id, `account` the account name, `account_id` its id, `zone` a zone label,
`opcode` hex (`0x7021`), errors `err=`. Events worth a panel have one line each: `msg=login`
(account, ip, result), `entered world` / `left world`, `warp` (via, kind, from, zone),
`gm command` (verb, line, refused), `lobby: character created`, `mall: purchase`, `stall: ...`,
`exchange: ...`. No password, PIN or DSN is logged.

Every packet's `packet received` line is DEBUG since round 858 (it was INFO and is most of the
847 MB prod log); `-log-level debug` (env `OPENSRO_LOG_LEVEL`) brings it back.

**Rotation: the server rotates its own file.** `-log-file PATH` (env `OPENSRO_LOG_FILE`) writes the
log there instead of stdout; past `-log-max-size-mb` (default 100) it is renamed `PATH.1`, older
ones shift up to `-log-max-files` (default 10) and are gzipped (`-log-compress`, default on), and
a new file is opened. A file already past the limit at boot is rotated at once. Why this and not
newsyslog: launchd holds the stdout file open, so rotating it means renaming under launchd and
then making the writer reopen -- newsyslog's config lives in `/etc/newsyslog.d` (root) and the
server would need a signal handler -- or copy-truncate, which races the writer. A file the
server opens itself rotates with no root, no signal and no race. stdout/stderr stay with
launchd and now carry only what bypasses the logger: a crash's Go stack.

### On the Mac mini (what to set)

In `~/opensro/run.sh`, with the other exports:

```
export OPENSRO_LOG_FILE=$HOME/opensro/logs/opensro.log   # the server's own rotating log (Alloy tails this)
# OPENSRO_METRICS_ADDR is 127.0.0.1:9469 by default; nothing to set
```

The launch agent's `StandardOutPath`/`StandardErrorPath` (`server.log`) keep only crash stacks
from then on. Archive the old 847 MB file during the deploy's restart:

```
launchctl kill TERM gui/$(id -u)/com.opensro.server      # or bootout; launchd restarts it with KeepAlive
mv ~/opensro/logs/server.log ~/opensro/logs/server.log.pre858 && gzip ~/opensro/logs/server.log.pre858
launchctl kickstart -k gui/$(id -u)/com.opensro.server
curl -s 127.0.0.1:9469/metrics | grep opensro_build_info
tail -f ~/opensro/logs/opensro.log
```

Stamp the version when building: `go build -ldflags "-X main.version=v0.1.623" ./cmd/server`.

## Dashboards and alert rules

- **OpenSRO server** (`grafana/dashboards/opensro-server.json`, uid `opensro-server`): health
  tiles (up, version, uptime, players, errors, panics, DB errors, worst loop p99, overruns,
  stalest loop, scheduler latency, mover lock hold), players and sessions, gateway, game loops,
  world, combat, economy, database, Go runtime. Restarts are annotated.
- **OpenSRO logs** (`grafana/dashboards/opensro-logs.json`, uid `opensro-logs`): lines by level,
  ERROR/WARN by message, the live log filtered by character, account, zone, level and a search,
  and logins, warps, GM commands and the economy's lines.

The JSON is generated: edit `grafana/gen_dashboards.py` and run it, then redeploy. Grafana reloads
the directory on its own (provisioning, `allowUiUpdates`: a change made in the UI is lost on the
next reload unless it is copied back into the generator).

`prometheus/rules/opensro.yml` (rules only; no Alertmanager yet -- firing alerts show in
Prometheus's `/alerts` and in Grafana under Alerting > Alert rules): server down, restarted, tick
overrun, a loop that stopped ticking, slow ticks, ERROR log rate, handler errors, recovered
panics, DB errors, slow DB, a saturated pool, send stalls, scheduler latency. Check them with
`promtool check rules` (the Prometheus image has it).

## Redeploying the stack

From this repo, to the container:

```
rsync -av --exclude .env deploy/observability/ root@192.168.10.86:/opt/opensro-observability/
ssh root@192.168.10.86 'cd /opt/opensro-observability && docker compose up -d'
# a rules or prometheus.yml change alone: reload without a restart (--web.enable-lifecycle)
ssh root@192.168.10.86 'curl -s -X POST localhost:9090/-/reload'
```

Dashboards need nothing more than the copy. A changed compose file (a new mount) needs the
`up -d`, which recreates only the services that changed; the data volumes stay.
