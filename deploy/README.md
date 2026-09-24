# Keeping a deployed server current

A machine that runs the compose stack (`docker compose up -d --build` from the repo root, see
`docs/HANDOFF_OPENSRO.md`) can follow `dev` on its own. `update.sh` does one round: fetch, and if
`origin/dev` moved, fast-forward, rebuild the stack, and check that the gateway answers on 15779.
The timer runs it every five minutes, so **pushing to `dev` is deploying**.

```
deploy/install.sh                              # once, as the user that owns the checkout
systemctl list-timers srrevamp-update.timer    # when it next runs
journalctl -u srrevamp-update                  # every update, build failure and rollback
sudo systemctl start srrevamp-update.service   # do not wait for the timer
FORCE=1 deploy/update.sh                       # rebuild even if nothing changed
```

What it refuses to do, and says so in the journal:

- **Throw away local edits.** Uncommitted changes to tracked files stop the update until they
  are committed or stashed. Untracked files are left alone — the deployment's own
  `docker-compose.override.yml` (which pins Postgres to `127.0.0.1`) lives there.
- **Stay on a build that does not come up.** If the build fails or the server never listens
  twice ten seconds apart, the checkout goes back to the commit that was running, that stack is
  rebuilt, and the offending origin commit is recorded in `.git/update-held`. Nothing is tried
  again until `dev` moves past it, or the hold file is removed.

Old image layers are pruned after each successful update so the disk does not fill over months.

## Reference data: making EXP, real weapon damage and skills work (BYO)

**The server ships with no reference data, and until an operator loads it a kill pays no EXP,
every hit deals the floor-band 1-2, the shop sells nothing and no skill can be learned.** The
public test server ran that way from 2026-09-11 to 2026-09-19 without anyone noticing, because
only the EXP curve warned in the log. The data comes from the operator's own client archives
(`Media.pk2` -> `server_dep\silkroad\textdata\`), never from this repo.

Three tables matter and they load two different ways: **items and skills** go into Postgres with
`cmd/import-refdata`; **leveldata is CSV-only** and is passed to the server on its command line.

```
# 1. On a machine with the client's Media.pk2 (BYO). Build the tools:
cd server && for t in pk2list export-refdata export-leveldata import-refdata; do
  CGO_ENABLED=0 GOOS=linux go build -o /tmp/$t ./cmd/$t; done

# 2. Extract the text tables. The archive carries more itemdata_*/skilldata_* parts than the
#    client loads; the index files itemdata.txt / skilldata.txt name the ones it does, in order,
#    and the exporter keeps the LAST definition of a duplicated id -- so feed the parts in the
#    index's order, not glob order (they differ: 1000,2000,... vs 1000,10000,11000,...).
MEDIA=/path/to/Media.pk2; mkdir refsrc && cd refsrc
for f in itemdata.txt skilldata.txt leveldata.txt; do
  /tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\$f" -out $f; done
/tmp/pk2list -pk2 "$MEDIA" -filter 'textdata\' | awk '{print $2}' \
  | grep -iE 'textdata\\(itemdata|skilldata)_[0-9]+\.txt$' | while IFS= read -r p; do
    /tmp/pk2list -pk2 "$MEDIA" -extract "$p" -out "$(basename "$(echo "$p" | tr '\\' /)")"; done
order() { iconv -f UTF-16LE -t UTF-8 "$1" | tr -d '\r' | sed 's/^\xef\xbb\xbf//' | grep -v '^$' \
          | tr 'A-Z' 'a-z' | while read -r n; do [ -f "$n" ] && echo "$n"; done; }
/tmp/export-refdata  -mode items  -out items.csv  $(order itemdata.txt)     # 15,338 rows from a retail archive
/tmp/export-refdata  -mode skills -out skills.csv $(order skilldata.txt)    # 33,698 rows
/tmp/export-leveldata -out leveldata.csv leveldata.txt                      # 140 levels
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\npcpos.txt" -out npcpos.txt
/tmp/export-refdata  -mode npcpos -out npcpos.csv npcpos.txt                # 12,367 placements; the server reads it with -npcpos-csv
rm -f itemdata_* skilldata_* npcpos.txt   # the extracted tables are game data; keep only the CSVs

# The exporter grows a strict-suffix column now and then (latest: item columns 61-65 -- the three elixir reinforce-rate dwords and the cooltime group/ms, rounds 262-263, 2026-09-19; before that the six skill prerequisite columns, round 250 -- re-run the SKILLS export too);
# an older items.csv still loads, but the new column reads as 0 until the export is re-run.
# Re-run steps 1-3 after pulling such a change.

# 3. On the server host (CSVs and import-refdata copied to ~/srrevamp-data; Postgres is pinned to
#    127.0.0.1:5432 by docker-compose.override.yml):
~/srrevamp-data/import-refdata -items-csv ~/srrevamp-data/items.csv -skills-csv ~/srrevamp-data/skills.csv \
    -postgres-dsn 'postgres://postgres:postgres@127.0.0.1:5432/srrevamp?sslmode=disable'

# 4. leveldata is a command-line flag: mount the directory and restate the command in the
#    (untracked) docker-compose.override.yml -- `command` in an override REPLACES the base list:
#   services:
#     server:
#       volumes:
#         - /home/srrevamp/srrevamp-data:/data:ro
#       command:
#         - "-addr=:15779"
#         - "-postgres-dsn=postgres://postgres:postgres@postgres:5432/srrevamp?sslmode=disable"
#         - "-leveldata-csv=/data/leveldata.csv"
#         - "-npcpos-csv=/data/npcpos.csv"       # real monster placements (round 253); omit for the town anchors
docker compose up -d
```

The boot log then reads `loaded EXP curve path=/data/leveldata.csv maxLevel=140` and
`reference data in PostgreSQL items=15338 skills=33698 ...`; an empty items table logs a WARN
naming this section. Verified on the public server on 2026-09-19 by a level-1 QA character at a
real Mangyang spawn (97/168 local 130,2280): hits of 12-14 (26 on a crit) instead of 1, a
Mangyang dead in four, and after five kills the character's row read level 2, exp 3, gold +267,
str/int 21, 3 stat points.

The exporter maps only the columns this project has measured (see its package doc and
`docs/protocol/ITEM_FORMAT.md`); fields it has not pinned are honest defaults, not guesses.
**This changes live gameplay**, so it is the operator's call to run, not something the deploy loop
does. It is reversible: `TRUNCATE items, skills;` returns the server to the empty state, and
removing the `-leveldata-csv` line stops levelling. The QA harness on the render box reads the
same three CSVs from beside the pk2s (`PK2_DIR`), so keep a copy there too.

Reference data is otherwise not touched by the update loop.

## Monster AI (off by default)

The server can run the monster AI tick: monsters stand for 2-6 s, then 76 times in 100 walk a
46-124-unit leg at their walk speed; more than 200 units from their spawn point they run back; a
monster a player hits stops where it is and stays there while anyone in the zone keeps
auto-attacking it, then idles. Everyone in the zone sees each move. A monster still strikes back only when struck. What is
grounded and what is a stand-in is in `docs/protocol/monster_ai.md`, "srrevamp's runtime".

It is behind the `-monster-ai` flag (env `SRREVAMP_MONSTER_AI`), and **the default is off**. Off,
nothing moves and the wire is exactly what it was, so pushing to `dev` changes nothing until the
operator turns it on. After an update the boot log reads
`monster AI off (-monster-ai / SRREVAMP_MONSTER_AI)`.

**Turn it on only when both of these hold:**

1. The client release that draws server-driven moves is tagged, CI is green for it (`gh run list`)
   and its zips are published. That is v0.1.435 (round 533) or later. An older client ignores the
   moves (its `NetClient` warns "unhandled opcode 0x007c" for each), so its players see monsters
   jump on each list refresh.
2. The two live checks in `monster_ai.md` ("The live checks") pass on the render box. Both have
   passed: Run 1 in round 538, and Run 2 in round 539. Re-run them after any change to the tick.

Know what it does before turning it on. Legs can cross walls and objects: the server holds no
collision world yet. A monster hit only by skills that do not hand off to the auto-attack is let go
between casts and may wander off. A client that stops reading its socket stalls the tick, as it
already stalls regen.

**On.** Add the variable under the server's `environment:` in the untracked
`docker-compose.override.yml`, then `docker compose up -d`:

```
services:
  server:
    environment:
      SRREVAMP_MONSTER_AI: "1"
      # SRREVAMP_AI_TRACE: "1"     # every state change, leg and strike in the log; only for a check
```

Or append `- "-monster-ai=true"` to the `command:` list the override already restates (step 4 of the
reference-data section above). An override's `command` REPLACES the base list, so restate all of
it. The boot log then reads
`monster AI on: tick 100ms (own design), roam radius 200 (own design)`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then `docker compose up -d`. The
update loop never touches the override, so the setting survives updates until it is removed.

## Monster strike push (off by default)

The server can send a monster's counterattack to everyone in its zone, not only to the player it
struck. The message is `OpMonsterAttacked 0x007D` (round 541), and it goes right after the
attacker's own result. Other players then see the monster swing and the number rise over its
target. The counter itself has not changed, and no number changes: the push repeats what the
attacker's result already says. It does not depend on the monster AI. What is grounded and what is
a stand-in is in `docs/protocol/monster_ai.md`, "The strike push's server half (round 541)".

It is behind the `-monster-strike-push` flag (env `SRREVAMP_MONSTER_STRIKE_PUSH`), and **the
default is off**. With it off nothing is sent, and the wire is exactly what it was. After an update
the boot log reads `monster strike push off (-monster-strike-push / SRREVAMP_MONSTER_STRIKE_PUSH)`.

**Turn it on only when both of these hold:**

1. A client release that carries round 540 is tagged, CI is green for it (`gh run list`), and its
   zips are published. No tag carries round 540 yet; v0.1.435 is round 534. An older client
   ignores the push and warns "unhandled opcode" once per connection, so its players see nothing
   new.
2. The live check in that `monster_ai.md` section passes on the render box. It has not been run
   yet.

**On.** Add `SRREVAMP_MONSTER_STRIKE_PUSH: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-monster-strike-push=true"` to the override's
restated `command:` list. The boot log then reads
`monster strike push on: OpMonsterAttacked 0x007D to the zone after each counterattack`.

**Off.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.

## Monster spawn push (off by default)

The server can send a monster that has just appeared to everyone in its zone the moment it
appears. That covers a roster monster's respawn (10 s after its death) and every monster a GM's
`/spawn` makes. Without it, a client finds the monster only on its next monster list. The message
is `OpMonsterSpawned 0x007E` (round 542): the list's own record for the monster, then the heading
it hatched facing. Clients face the new body along that heading. The heading is the engine's hatch
roll, `rand() / 32767 * 2pi`, and the monster AI starts the monster from the same heading. The push
does not depend on the monster AI. What is grounded and what is a stand-in is in
`docs/protocol/monster_ai.md`, "The spawn push's server half (round 542)".

It is behind the `-monster-spawn-push` flag (env `SRREVAMP_MONSTER_SPAWN_PUSH`), and **the default
is off**. With it off nothing is sent, and the wire is exactly what it was. After an update the
boot log reads `monster spawn push off (-monster-spawn-push / SRREVAMP_MONSTER_SPAWN_PUSH)`.

**Turn it on only when both of these hold:**

1. A client release that carries round 540 is tagged, CI is green for it (`gh run list`), and its
   zips are published. It is the release the strike push waits for too. An older client ignores
   the push and warns "unhandled opcode" once per connection, so its players still find the
   monster on their next list.
2. The live check in that `monster_ai.md` section passes on the render box. It has not been run
   yet.

**On.** Add `SRREVAMP_MONSTER_SPAWN_PUSH: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-monster-spawn-push=true"` to the override's
restated `command:` list. The boot log then reads
`monster spawn push on: OpMonsterSpawned 0x007E to the zone for each respawn and GM /spawn`.

**Off.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
