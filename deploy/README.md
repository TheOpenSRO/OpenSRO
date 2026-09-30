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
for f in itemdata.txt skilldata.txt characterdata.txt leveldata.txt levelgold.txt textdata_object.txt; do
  /tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\\silkroad\\textdata\\$f" -out $f; done
/tmp/pk2list -pk2 "$MEDIA" -filter 'textdata\' | awk '{print $2}' \
  | grep -iE 'textdata\\(itemdata|skilldata|characterdata)_[0-9]+\.txt$' | while IFS= read -r p; do
    /tmp/pk2list -pk2 "$MEDIA" -extract "$p" -out "$(basename "$(echo "$p" | tr '\\' /)")"; done
order() { iconv -f UTF-16LE -t UTF-8 "$1" | tr -d '\r' | sed 's/^\xef\xbb\xbf//' | grep -v '^$' \
          | tr 'A-Z' 'a-z' | while read -r n; do [ -f "$n" ] && echo "$n"; done; }
/tmp/export-refdata  -mode items  -out items.csv  $(order itemdata.txt)     # 15,338 rows from a retail archive
/tmp/export-refdata  -mode skills -out skills.csv $(order skilldata.txt)    # 33,698 rows
/tmp/export-refdata  -mode monsters -out monsters.csv $(order characterdata.txt) levelgold.txt textdata_object.txt
                     # 7,604 monster species (round 654); the server reads it with -monsters-csv
/tmp/export-leveldata -out leveldata.csv leveldata.txt                      # 140 levels
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\npcpos.txt" -out npcpos.txt
/tmp/export-refdata  -mode npcpos -out npcpos.csv npcpos.txt                # 12,367 placements; the server reads it with -npcpos-csv
for f in teleportdata.txt teleportlink.txt teleportbuilding.txt; do
  /tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\\silkroad\\textdata\\$f" -out $f; done
/tmp/export-refdata  -mode teleport -out teleport teleportdata.txt teleportlink.txt teleportbuilding.txt
                     # a DIRECTORY of three CSVs: 222 points, 292 links, 77 buildings; the server reads it with -teleport-dir
rm -f itemdata_* skilldata_* characterdata_* levelgold.txt textdata_object.txt npcpos.txt teleport*.txt
                     # the extracted tables are game data; keep only the CSVs

# The exporter grows a strict-suffix column now and then (latest: skill columns 47-61, round 616 -- the buff
# and self-cast columns; before them 45 CooldownGroup, round 504,
# and 46 SitGate, round 607 -- the skill-use gate's sitting refusals; before them item columns 61-65 -- the three
# elixir reinforce-rate dwords and the cooltime group/ms, rounds 262-263, 2026-09-19; and the six skill
# prerequisite columns, round 250);
# an older CSV still loads, but the new column reads as 0 until the export is re-run.
# Re-run steps 1-3 after pulling such a change.
#
# ROUND 607 (sitting) NEEDS THIS ON srrevamp-01: re-run `export-refdata -mode skills` with the NEW
# binary (step 2), then the NEW `import-refdata` (step 3) -- the import is what applies the schema
# change: its store adds the skills.sit_gate column before it writes the rows. The server restart
# (`docker compose up -d` after the pull) is only to run the new server binary, which reads the
# column. Until then every skill's SitGate is 0 and the gate FAILS OPEN: the 59 skills the
# retail server refuses to a seated caster (the Cold/Fire walls, the fortress repair kits, the
# monster transform) can be cast sitting. Check: `SELECT count(*) FROM skills WHERE sit_gate <> 0;`
# answers 59 on a retail archive.
#
# ROUND 616 (buffs, Grass Walk, Ghost Walk) NEEDS THE SAME ON srrevamp-01: re-run `export-refdata
# -mode skills` with the NEW binary (step 2; the CSV grows to 62 columns), then the NEW
# `import-refdata` (step 3) -- its store adds the fifteen columns (skills.action_kind,
# target_required, target_land, target_self/ally/party, dura_ms, cbuf, nbuf, bbuf, lnks, tele0,
# tele1, buff_params, lks2) before it writes the rows -- then restart the server. Until then every
# skill loads action kind 0 with no 'tele': no buff starts (Grass Walk and the imbues cast as
# before and do nothing) and Ghost Walk is refused for want of a ground move. Check:
# `SELECT count(*) FROM skills WHERE action_kind = 3;` answers 2348, and
# `SELECT count(*) FROM skills WHERE tele1 <> 0;` answers 19, and
# `SELECT count(*) FROM skills WHERE lks2;` answers 160, on a retail archive.
# ROUND 622 (Heal on another player) adds two more columns, TargetHealHP/MP (the CSV is 64
# columns; the store adds skills.target_heal_hp and target_heal_mp): the same re-export and
# re-import. Until then Heal is cast at the named player and heals nobody. Check:
# `SELECT count(*) FROM skills WHERE target_heal_hp > 0;` answers 27 on a retail archive.
# ROUND 636 (buffs that must not stack) adds thirteen columns, the recast rule's (the CSV is 77
# columns; the store adds skills.action_overlap, ovl2, has_dttp, dttp0, dttp1, efr2, offensive,
# msch1, hide, skc_end, basic_group, activity, dtt): the same re-export and re-import, then restart.
# Until then every state byte loads 0 and Fire Protection stacks and the Grass Walks run together,
# as before. Check: `SELECT count(*) FROM skills WHERE action_overlap <> 0;` answers 1835 on a
# retail archive.
# ROUND 636'S REVIEW (one trap at a time, one guard link too many) adds six more, FUN_0059dc80's and
# the collector flag (the CSV is 83 columns; the store adds skills.lnks_group, lnks_max, efr3, qest,
# trap, efr1): the same re-export and re-import. Until then a Fire Trap can be cast again while one
# runs and a Warrior guard links any number of party members. Check:
# `SELECT count(*) FROM skills WHERE efr3 AND lnks;` answers 32 on a retail archive (every one a
# Target_Required 0 row: the Fire Traps and seven quest traps).
# ROUND 640 (the protection walls) adds four columns, 'pw' value[0..3] (the CSV is 87 columns; the
# store adds skills.pw0..pw3): the same re-export and re-import, then restart. Until then no wall
# takes a blow (the toggles' MP drain and switch-off work without them: 'onff' rides in
# BuffParams). Check: `SELECT count(*) FROM skills WHERE pw0 <> 0;` answers 55 on a retail archive.
# ROUND 632 (berserk potions, the Energy of life scroll) NEEDS THE ITEMS RE-EXPORT ON srrevamp-01:
# re-run `export-refdata -mode items` with the NEW binary (step 1; items.csv grows to 72 columns --
# column 70 CodeName, round 497, which an older CSV may also lack, and the new column 71
# CompositeDesc), then the NEW `import-refdata` (step 3) -- its store adds items.composite_desc and
# the items_code_name_idx index before it writes the rows -- then restart the server. Until then
# the scroll (23944-23947) is refused and the fill it grants cannot be resolved by code. Check:
# `SELECT composite_desc FROM items WHERE id = 23944;` answers
# `[UIL1:ITEM_ETC_SECOND_HWAN,A,3600,1],[UIU1:ITEM_ETC_INCREASE_HWAN_TIME_01]`, and
# `SELECT code_name FROM items WHERE id = 23937;` answers `ITEM_ETC_SECOND_HWAN`, on a retail
# archive. A client that predates round 632 ignores the new opcodes 0x0104-0x0108.
# ROUND 654 (the monster species table) NEEDS THREE THINGS ON srrevamp-01, in this order:
#   a. re-run `export-refdata -mode skills` with the NEW binary (step 2; the CSV grows to 90
#      columns -- column 89 is AI_AttackChance, skilldata column 66), then the NEW `import-refdata`
#      (step 3) -- its store adds skills.ai_attack_chance (default -1, "unknown") before it writes
#      the rows. Check: `SELECT count(*) FROM skills WHERE ai_attack_chance > 0;` answers 26650,
#      and `... WHERE ai_attack_chance < 0;` answers 0, on a retail archive.
#   b. run the NEW `export-refdata -mode monsters` line from step 2 (characterdata parts in the
#      index's order, plus levelgold.txt and textdata_object.txt) and copy monsters.csv to
#      ~/srrevamp-data. It reports 7,604 species, 156 of them drawing their Org row's model, 7,604
#      with a levelgold row and 7,509 whose name key resolves, on a retail archive.
#   c. add "-monsters-csv=/data/monsters.csv" to the override's command (step 4) and restart.
#   The boot log then reads `monster species table loaded ... species=7604 roster_overlaid=11
#   roster_missing=0 roster_changed=0` and `npcpos placements loaded ... roster_species_placed=11
#   npcpos_species_in_monster_table=355`. A WARN naming `kept` means (a) or the levelgold/
#   textdata_object inputs of (b) were skipped: those roster fields keep their hand-typed values.

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
#         - "-teleport-dir=/data/teleport"       # the teleport network (round 575); the town teleporters use it (round 576)
#         - "-monsters-csv=/data/monsters.csv"   # the monster species table (round 654); see "Monster species table"
docker compose up -d
```

**At a host's boot** Docker restarts the server and postgres containers together and ignores the
compose file's `depends_on: condition: service_healthy`, which applies only to `docker compose up`.
The server therefore waits for postgres itself: `-postgres-wait` (default 60s) retries every second,
logging `waiting for postgres` each time. Before this, every reboot of srrevamp-01 logged one
`opening account store ... connection refused` and a Docker restart of the server.

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
same three CSVs from beside the pk2s (`PK2_DIR`), so keep a copy there too -- and the teleport
directory as `PK2_DIR/teleport` (`qa_shot.sh` passes `-teleport-dir` when
`teleport/teleportdata.csv` is there).

The teleport directory (round 575) is what the town teleporters charge and move by (round 576,
"Town teleporters" below): the boot log gains `msg="teleport network loaded" dir=... points=222
links=292 buildings=77`, and a directory that is configured but does not load (a missing file, a
header that is not the exporter's, a link to a point the table lacks) stops the server at boot, as a
bad `-npcpos-csv` does. Without the directory every teleport is refused.

**Re-export the teleport directory after round 642.** teleportdata.csv gained a twelfth column,
`WorldID` (teleportdata.txt column 12). A directory exported before round 642 still loads, and every
NPC teleporter works with it. But without the column, a link into an instanced area is not refused
up front: the fortress, tomb, temple, survival and Roc gates. To re-export:
1. Re-run the `pk2list` loop and the `export-refdata -mode teleport` line from step 1 into a
   directory named `teleport`.
2. Copy it over `~/srrevamp-data/teleport` on the server host. It is mounted as `/data/teleport`.
3. Run `docker compose up -d`.

The new `teleportdata.csv` header ends in `Interaction9,WorldID`. There is no database step.

Reference data is otherwise not touched by the update loop.

## Monster species table

`-monsters-csv` (env `SRREVAMP_MONSTERS_CSV`, round 654) loads every monster species in the
client's characterdata: `cmd/export-refdata -mode monsters` writes one row per TypeID (1,2,1,x)
row -- id, code name, the Org code name and id, the name key and its English, TypeID4, rarity,
level, HP, walk/run speed, collision radius, the eight combat columns 71-78, the ten attack-skill
ids 83-92, the model (or the Org row's, flagged) and the levelgold range at its level. See
`server/internal/species` for what each column is and how it is known.

What it changes, and what it does not:

- **Who spawns where does not change.** The roster in `cmd/server` (eleven species) is still
  what spawns, where it spawned before; with `-npcpos-csv` those eleven take their real rows as
  before. Measured on a retail export: 413 monsters spawn with the table and 413 without, the
  same species, zones and levels.
- Each roster species takes its numbers from its row (level, rarity, HP, the combat columns,
  radius, speeds, gold, and the attack list through the skill store). On a retail export all
  eleven come back identical to the hand-typed values (`roster_changed=0`); a difference is
  logged as a WARN naming both.
- The GM console's `/spawn` finds any species in the table by code name, characterdata id or
  English name (`/spawn 1933 3`, `/spawn MOB_CH_TIGERWOMAN`), with its own level, HP (scaled
  by rarity as the engine scales it) and rarity in the monster list. `/goto` refuses a species
  the server does not place.
- The attack lists need the round-654 skills re-export (AI_AttackChance); with an older skills
  table a non-roster species swings its primary skill only, and the roster keeps its hand-typed
  lists (logged as `kept`).

A configured path that does not load is fatal at boot, the `-npcpos-csv` rule. Without the flag
the server behaves exactly as before.

## Monster AI (off by default)

The server can run the monster AI tick: monsters stand for 2-6 s, then 76 times in 100 walk a
46-124-unit leg at their walk speed; more than 200 units from their spawn point they run back; a
monster a player hits stops where it is and stays there while anyone in the zone keeps
auto-attacking it, then idles. Everyone in the zone sees each move. A monster still strikes back
only when struck. What is grounded and what is a stand-in is in `docs/protocol/monster_ai.md`,
"srrevamp's runtime".

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
   zips are published. v0.1.436 (round 542) carries it, and its `Release client` run was green on
   2026-09-24. An older client ignores the push and warns "unhandled opcode" once per connection,
   so its players see nothing new.
2. The live check in that `monster_ai.md` section passes on the render box. It passed in round
   543 ("Measured (round 543)" there).

**On.** Add `SRREVAMP_MONSTER_STRIKE_PUSH: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-monster-strike-push=true"` to the override's
restated `command:` list. The boot log then reads
`monster strike push on: OpMonsterAttacked 0x007D to the zone after each counterattack`.

**Off.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.

## Monster battle (off by default)

The server can let a struck monster fight on its own (round 546). It chases its attacker to its
attack band at its run speed (every step an `OpMonsterMoved`, mode 1), swings as soon as it is in
the band and then every ReuseDelay of its attack skill (3000 ms for a Mangyang), each blow reaching
everyone in the zone as an `OpMonsterAttacked 0x007D` -- the blow itself is the same one the
counterattack dealt -- and gives up when its target is more than 400 units away (an own-design
stand-in for a server-database column) and walks home. The counterattack inside the attacker's own
`OpAttackResult` is then no longer made: a player standing out of the band takes nothing until the
monster gets there. What is grounded and what is a stand-in is in `docs/protocol/monster_ai.md`,
"BATTLE's chase and the monster's own swing (round 546)".

Since round 553 the flag also carries the **aggro link**: a party member's first blow on a monster that
is not yet fighting pulls in as many of the ten nearest other monsters -- within the struck monster's
detection radius, scaled by the level gap between it and the attacker -- as the party has members
within 1000 units of the attacker; each runs at the attacker and swings like a struck monster. A solo
player links nothing, and an older client needs nothing new: the linked monsters' legs and blows are
the same `OpMonsterMoved` and `OpMonsterAttacked` a struck monster's are. There is no separate switch;
turning this flag off turns the link off. Its reading and stand-ins: `docs/protocol/monster_ai.md`,
"The aggro link: the runtime (round 553)".

Since round 554 the flag also carries the **second attack skill**: four species -- Mangyang, Water
Ghost slave, Water Ghost and Yeoha -- carry two attack skills in the client's own tables, and a
monster in BATTLE draws each swing between them (by the skill's AI_AttackChance and how far inside
its reach the target stands), walks to the drawn skill's band and cools down for its ReuseDelay. A
Yeoha may therefore open from up to ~115 units with its harder ATTACK03 instead of closing to 22,
and a Water Ghost's ATTACK02 (a status skill this server has no system for) lands a blow of 0. An
older client needs nothing new: the legs and blows are the same `OpMonsterMoved` and
`OpMonsterAttacked`. The other seven species and the flag-off counterattack are unchanged. No
separate switch. Its reading and stand-ins: `docs/protocol/monster_ai.md`, "The second attack
skill: the runtime (round 554)".

It is behind the `-monster-battle` flag (env `SRREVAMP_MONSTER_BATTLE`), and **the default is
off**. Off, the interim hold and the counter are exactly what they were. It also **needs
`SRREVAMP_MONSTER_AI` and `SRREVAMP_MONSTER_STRIKE_PUSH` both on**: without them the boot log reads
`monster battle forced off why=...` and the flag does nothing (never an exit, so the update loop
never rolls back over a flag combination). After an update the boot log reads
`monster battle off (-monster-battle / SRREVAMP_MONSTER_BATTLE)`.

**Turn it on only when all of these hold:**

1. The monster AI and the strike push are on (the two sections above), with their own conditions
   met.
2. A client release that carries round 546 is tagged, CI is green for it (`gh run list`), and its
   zips are published. An older client that carries round 540 still shows the monster's swing and
   the other players' blows, but a blow on the player itself is drawn as the swing alone, with no
   hit reaction, number or HP repaint, because that client pairs a blow on itself with its own
   counter result and there is none any more. A client older than round 540 shows no monster
   blow at all and takes silent HP loss.
3. The live check in that `monster_ai.md` section passes on the render box (its "Measured"
   paragraph says whether it has).

**On.** Add `SRREVAMP_MONSTER_BATTLE: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, beside `SRREVAMP_MONSTER_AI` and `SRREVAMP_MONSTER_STRIKE_PUSH`, then
run `docker compose up -d`. You can instead append `- "-monster-battle=true"` to the override's
restated `command:` list. The boot log then reads
`monster battle on: a struck monster chases to its attack band ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Turning `SRREVAMP_MONSTER_AI` off also turns this off (the chase runs in the AI tick).

## Monster spawn push (off by default)

The server can send a monster that has just appeared to everyone in its zone the moment it
appears. That covers a roster monster's respawn (10 s after its death) and every monster a GM's
`/spawn` makes. Without it, a client finds the monster only on its next monster list. The message
is `OpMonsterSpawned 0x007E` (round 542): the list's own record for the monster, then the heading
it hatched facing. A client faces a standing body whose model front was measured (round 533) along
that heading; a body walking a leg, or a model with no measured front, is left as it is
(`World3D._face_monster_heading`). The heading is the engine's hatch
roll, `rand() / 32767 * 2pi`, and the monster AI starts the monster from the same heading. The push
does not depend on the monster AI. What is grounded and what is a stand-in is in
`docs/protocol/monster_ai.md`, "The spawn push's server half (round 542)".

It is behind the `-monster-spawn-push` flag (env `SRREVAMP_MONSTER_SPAWN_PUSH`), and **the default
is off**. With it off nothing is sent, and the wire is exactly what it was. After an update the
boot log reads `monster spawn push off (-monster-spawn-push / SRREVAMP_MONSTER_SPAWN_PUSH)`.

**Turn it on only when both of these hold:**

1. A client release that carries round 540 is tagged, CI is green for it (`gh run list`), and its
   zips are published. It is the release the strike push needs too: v0.1.436 (round 542), whose
   `Release client` run was green on 2026-09-24. An older client ignores the push and warns
   "unhandled opcode" once per connection, so its players still find the monster on their next
   list.
2. The live check in that `monster_ai.md` section passes on the render box. It has not been run
   yet.

**On.** Add `SRREVAMP_MONSTER_SPAWN_PUSH: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-monster-spawn-push=true"` to the override's
restated `command:` list. The boot log then reads
`monster spawn push on: OpMonsterSpawned 0x007E to the zone for each respawn and GM /spawn`.

**Off.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.

## Player dead state (off by default)

The server can leave a player a monster kills dead (round 549). The killing blow's result and
push then carry HP 0 (not the respawned 40 %), and the client that carries round 548 holds the
die pose, locks movement and attacks, and shows a Revive button. While dead the server refuses the
character's moves (neither stored nor relayed), attacks, casts, items, pick-ups, duel blows, trade
requests, zone changes, GM `/tp`/`/goto` and guild founding and level-ups, empties its potion
queue, and no monster targets it.
`OpRevive 0x0028` (the button) brings it back where it lies -- HP at 1 + 40 % of the maximum
(truncated; the retail resurrect handler's own arithmetic, round 550) and MP at 40 % -- which
retail grants in place only up to max level 10; above that
srrevamp's in-place revive is a disclosed stand-in for a return point it does not model. A session
that never sends `OpRevive` is revived unasked after 30 s (the auto-revive fallback, own design).
What is grounded and what is a stand-in is in `docs/protocol/monster_ai.md`, "The player's dead
state: the server half (round 549)".

It is behind the `-player-dead-state` flag (env `SRREVAMP_PLAYER_DEAD_STATE`), and **the default
is off**. Off, a kill respawns the player at once and the kill's wire is what it was; the one
flag-independent piece is the entry revive of a stored HP 0 (the last paragraph). It does not
depend on the monster flags: it covers the counterattack inside the attacker's result and the
monster's own swings under `-monster-battle` alike. After an update the boot log reads
`player dead state off (-player-dead-state / SRREVAMP_PLAYER_DEAD_STATE)`.

**Turn it on only when both of these hold:**

1. A client release that carries round 548 is tagged, CI is green for it (`gh run list`), and its
   zips are published. An older client sees HP 0 and no Revive button after a kill; only the 30 s
   fallback frees it, and until then its walk is not relayed and its attacks are refused.
2. The live check in that `monster_ai.md` section passes on the render box. It has not been run
   yet.

**On.** Add `SRREVAMP_PLAYER_DEAD_STATE: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-player-dead-state=true"` to the override's
restated `command:` list. The boot log then reads
`player dead state on: a monster's kill leaves the player dead ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
A character that was dead at the restart enters alive at 40 % on its next login (the load path's
own rule for a stored zero pool).

## Monster aggro (off by default)

The server can let monsters notice players (round 552). A monster idle, wandering or, once its
blackout has passed, running home scans on its own timer -- every 1001-1500 ms, rolled once per
spawn, the first scan at once -- for the nearest LIVING player within its acquisition radius, its
collision radius + 100 units (the detection distance is an own-design stand-in for a
server-database column; the roster's radii are 104-111 units), and engages it exactly as a blow
would: `-monster-battle`'s chase (`OpMonsterMoved` mode 1) and swings (`OpMonsterAttacked 0x007D`),
the give-up by distance and the walk home. A monster running home ignores players for the time it
takes to run its own radius (4818 ms for a Mangyang, a value derived from the stand-in). A dead
player is never noticed. What is grounded and what is a stand-in is in
`docs/protocol/monster_ai.md`, "Target acquisition: the runtime (round 552)".

It is behind the `-monster-aggro` flag (env `SRREVAMP_MONSTER_AGGRO`), and **the default is off**:
off, a monster fights only when struck, exactly as before. It also **needs `SRREVAMP_MONSTER_BATTLE`
in effect (so `SRREVAMP_MONSTER_AI` and `SRREVAMP_MONSTER_STRIKE_PUSH` too) and
`SRREVAMP_PLAYER_DEAD_STATE` on**: a noticed player is engaged by the chase and the monster's own
swings, and a monster that seeks players out kills ones who never struck it, who must then stay
dead rather than respawn in place. Without them the boot log reads `monster aggro forced off
why=...` and the flag does nothing (never an exit, so the update loop never rolls back over a flag
combination). After an update the boot log reads
`monster aggro off (-monster-aggro / SRREVAMP_MONSTER_AGGRO)`.

**Turn it on only when all of these hold:**

1. The monster battle and the player dead state are on (the two sections above), with their own
   conditions met -- in particular the client releases they need (rounds 546 and 548), since a
   noticed player is chased, struck and killed by a monster it never touched.
2. The live check in that `monster_ai.md` section passes on the render box (its "Measured"
   paragraph says whether it has).
3. You want EVERY roster species aggressive at 100 units. That is the stand-in; there is no
   per-species setting yet, and the only other setting is this flag off.

**On.** Add `SRREVAMP_MONSTER_AGGRO: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, beside the four flags above, then run `docker compose up -d`. You
can instead append `- "-monster-aggro=true"` to the override's restated `command:` list. The boot
log then reads `monster aggro on: a monster notices the nearest living player ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Turning `SRREVAMP_MONSTER_BATTLE` or `SRREVAMP_PLAYER_DEAD_STATE` off also turns this off.

## Single world frame (off by default)

The server can put the whole world in ONE coordinate frame (round 571), so a player who walks out
of Jangan toward Donwhang stays in everyone else's coordinates and meets Donwhang's monsters. Every
zone the server knows a frame for -- the named towns and any `x/y` region label -- is then named in
Jangan's frame (`FrameRegion` "97/168" on `OpEnterWorldResult` and `OpChangeZoneResult`) and kept in
ONE broadcast bucket, and every roster monster with it: each npcpos row is converted against 97/168,
and an own-design anchor is moved into that frame. A zone change (and so a GM `/goto <town>`) lands
at the middle of the town's centre region named in that frame -- the same place it lands with the
flag off, in the other frame's numbers (Donwhang: `ToWorld(102, 153, 960, 960, 97, 168)`). The zone
label stays the client's grid-centre hint. What the choice is and what it is not is in
`docs/RE_COMPLETION.md`, round 571: the frame and the bucket are OWN DESIGN.

What changes for players with it on: a change to a town is always a warp to its landing, never
"already in that zone", and the rest of the world sees the mover leave and re-enter (a flicker).
One bucket has no spatial filter, so moves, local chat and the monster list (413 monsters with
`-npcpos-csv`) reach every player. A label with no frame (a typo, "Jangan" with a capital) keeps its
own bucket and the old wire.

It is behind the `-single-frame` flag (env `SRREVAMP_SINGLE_FRAME`), and **the default is off**:
off, every zone keeps its own frame and bucket and the wire is what it was. After an update the boot
log reads `single frame off (-single-frame / SRREVAMP_SINGLE_FRAME)`.

**Turn it on only when all of these hold:**

1. A client release that carries rounds 569 to 571 is tagged, CI is green for it (`gh run list`),
   and its zips are published. Round 570's client builds a zone's grid inside the server's
   `FrameRegion`; an older client ignores the field, builds each zone in its own centre's frame and
   puts a zone change's one-frame coordinates inside that grid -- Donwhang's landing, 28,800 units
   out in X, lands it regions away, off the ground it built. Round 569's client resolves the
   server's "donwhang" label and builds the towns' corrected centres. Round 571's client finds the
   grid's corner without the centre's terrain: before it, a town whose centre region failed to load
   streamed its grid around the wrong region (Donwhang's landing as 107/138, not 102/153).
2. You accept these limits of that client, which the flag does not fix:
   - `/unstuck` returns to the ENTRY position, which in the one frame is Jangan's middle wherever
     the player is.
   - The GM console compares a `/goto` reply's zone with the zone the player ENTERED with, so a GM
     who walked to Donwhang and types `/goto jangan` stays put (the zone box's change works).
   - A monster is first drawn at the server's y 0 when no terrain is loaded under it, and nothing
     lowers or lifts a standing one when its region loads later; only the next monster list does
     (an attack, a kill, a GM refresh, the Refresh button). With the flag on, a player in Jangan is
     sent the Earth Ghost's 65 rows while Donwhang is unloaded, so after a walk there each ghost can
     stand up to 116.78 above or 124.44 below its ground until that list (round 571's heights).
   - The far towns sit up to 170,880 units from the origin, where a float32 position steps by 1/64
     of a unit (Constantinople) -- recorded, not rebased.
   - A player who warps to a far town is drawn by the others at the server's y 0: the client places
     another player's body at the snapshot's height with no snap to the ground
     (`World3D._spawn_or_update_other`), and the landings' ground draws 104.07 below that point
     (Donwhang) to 86.23, 182.49 and 246.32 above it (Constantinople, Samarkand, Hotan) under the
     one frame (round 571's heights). It rights itself when the mover's own client lifts it onto the
     ground or lets it fall, a move past `MIN_SEND_DISTANCE` that sends an `OpMove` -- read from the
     code, not measured (round 571's review, recorded in round 574).
   - Two regions near Samarkand come out of the +-1000 / -500 height envelope under the one frame
     and not without it: the peaks of 108/105 and 108/106 draw at 1052.1 and 1108.7 (869.6 and
     926.2 under Samarkand's own anchor). Nothing is placed there at y 0 today; round 571 gated no
     town on the envelope, because Jangan's own 99/170 already breaks it with the flag off
     (1075.41), and checked the places the client puts something at a server-given height instead
     (`docs/RE_COMPLETION.md`, round 571, "Heights under ONE frame").
3. You accept the monster list's size. It is one packet, capped at 32,767 payload bytes (`sizeMask`,
   `internal/proto/packet.go`), and each monster costs 40 bytes plus its name and code name
   (`MonsterSnapshot.Encode`). With `-npcpos-csv` Jangan's 348 roster monsters are 23,769 bytes
   today; the one bucket holds them and the Earth Ghost's 65, 28,189 bytes, for every player.
   72 more Mangyang-sized entries (64 bytes each; four GM `/spawn 20`s, which nothing respawns and
   `combat.Hub` drops only when they die) push it over the cap: every list request then fails in
   `proto.Write` (`payload ... too large for a single frame`) and the gateway closes that player's
   session (`handler error, closing session`). With the flag off it takes 141 in Jangan's bucket
   alone; with it on, 72 anywhere, and every player's list fails -- so under the flag one GM's
   four `/spawn 20`s close every player's session on their next list. No hard guard (a cap, or a
   list split over several packets in `handleMonsterList`) is built; it is a `docs/TODO.md` item to
   close before the flip (round 571's review).

**On.** Add `SRREVAMP_SINGLE_FRAME: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-single-frame=true"` to the override's restated
`command:` list. The boot log then reads `single frame on: origin 97/168 ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Every zone is back in its own frame on the next login. A position `-persist-position` saved in the
one frame (below) carries that frame and is named in the zone's own on the next login.

## Saved position (off by default)

The server can put a character back where it left off (round 573). With the flag on it saves the
character's zone label, the frame region its coordinates are in and its position on the character
row -- on a disconnect or logout, on each zone change, at most every 30 s while it walks, and for
everyone still in the world when the server stops (so a deploy keeps them too) -- and the next
login's `OpEnterWorldResult` answers them: the saved label, that label's bucket and frame as they
are that day, and the saved point named in that frame, with a trailing `Restored` byte after
`FrameRegion`. The engine keeps the same fields on its own row (`_CHAR.LatestRegion`, `PosX`,
`PosY`, `PosZ`, bound to charData +0x94..+0xa0 in `docs/protocol/db_bind_offsets.tsv`); when
srrevamp saves them, their shape and the frame rule are own design -- `docs/RE_COMPLETION.md`,
round 573.

The columns (`latest_zone`, `latest_frame`, `pos_x`, `pos_y`, `pos_z`) are added by the character
store's usual `ADD COLUMN IF NOT EXISTS` migration on the first start of this build, flag or no
flag; an existing row reads "nothing saved" and enters at the spawn.

What changes for players with it on:

- A disconnect, a logout or a server restart no longer sends them back to Jangan's square: they
  enter where they stood, in the zone they were in.
- A save made in one frame and read under another -- `-single-frame` flipped between the two, or a
  town's centre corrected by a later round -- is the same place named in the new frame
  (`worldmap.Rebase`: saved under 98/157 and read under 97/168, a point moves by
  `ToWorld(98, 157, 960, 960, 97, 168)` = (-21120, -1920)), at height 0, which the client lifts onto
  the ground. A save whose frame cannot be converted enters at the spawn.
- A character saved inside a building stays inside it: the client lifts a player only when the
  saved height is below the drawn ground, and moves one out from under a roof only after such a
  lift. `/unstuck` (round 573's client) then takes it to the zone's landing spot.
- A position more than two regions from the zone's centre -- reachable only by walking there, e.g.
  from Jangan toward Donwhang under `-single-frame`, where the label stays "jangan" -- is outside
  the grid the entry builds around the label's centre; the stream then builds around the player,
  as after a GM `/tp` far away. Not measured.
- With `-player-dead-state` on as well, a character that logs out dead is saved where it fell and
  re-enters there -- possibly beside the monster that killed it -- revived to 40 % by the entry
  rule that applies whatever the flags say (`handleEnterWorld`'s revive of a stored HP 0,
  `character.RespawnFraction`). That is the in-place revive stand-in `-player-dead-state` already
  uses (`deadstate.go`), now across a logout (round 573's review, recorded in round 574).

It is behind the `-persist-position` flag (env `SRREVAMP_PERSIST_POSITION`), and **the default is
off**: off, nothing is saved or read, every entry lands at the zone spawn, and the wire is what it
was. After an update the boot log reads
`persist position off (-persist-position / SRREVAMP_PERSIST_POSITION)`.

**Turn it on only when:** a client release that carries round 573 is tagged, CI is green for it
(`gh run list`), and its zips are published. An older client ignores the `Restored` byte: it moves
a restored Jangan entry on to Jangan's landing spot (local 1002, 1020 of 97/168) as it moves every
Jangan entry -- the flag then does nothing in Jangan, where testers log out, and until the player's
first move the server and everyone else hold it at the saved point, not at the landing spot -- keeps
a restored entry in any other zone where the server put it, and its `/unstuck` returns such a
player to the saved point itself.

**On.** Add `SRREVAMP_PERSIST_POSITION: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-persist-position=true"` to the override's
restated `command:` list. The boot log then reads `persist position on: a character re-enters
where it last stood ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Every login is back at the spawn. The saved columns stay; nothing reads or writes them while the
flag is off, so turning it on again restores each character to where it stood when the flag was
last on.

## Town teleporters

The Dimensional Gate in each town moves a player to another town for the link's fee (round 576).
The client sends `OpTeleportUse 0x00F3` with the gate and the destination (teleportdata ids); the
server checks the link and its restrictions (a level range refuses `0x1c15`), charges the fee from
the table (refusing `0x1c07`, with nothing charged or moved, when the gold is short), answers
`OpTeleportResult 0x00F4` with the fee and the destination's name, and moves the player with an
ordinary `OpChangeZoneResult` to the destination gate's own point -- the client reloads the zone
behind its loading screen, as for any zone change. Every teleport is logged:
`msg=teleport account=... character=... gate=STORE_CH_GATE from=GATE_CH dest=GATE_WC zone=donwhang
... fee=5000 waiver=0`. What is grounded and what is a stand-in: `docs/RE_COMPLETION.md`, round
576, and `docs/protocol/teleport_network.md`, "What srrevamp built".

It needs the teleport directory above (`-teleport-dir`). There is no flag for the teleport itself:
the request is new, and a client release before round 576's client half never sends it, so pushing
to `dev` changes nothing for tagged clients until the release that carries the gate and its board
(round 578: Talk -> 'Select teleport area' -> the Dimensional Teleporter -> Move).

**The teleport NPCs (round 642)** use the same request and rules. These are:
- the ferry and boat ticket sellers at the river crossings (500 gold);
- the airship sellers between Hotan's Karakoram docks, Roc Mountain and Central Asia (500);
- the Samarkand/Taklamakan tunnel managers (500);
- the Constantinople harbour and the pirates (500, or 5,000 and level 95 to Alexandria's Paros
  Light House);
- Jangan's four gate soldiers and Constantinople's three guides (free);
- the two NPCs that lead to Thief Town (free).

Since round 642's review the server also measures the retail interaction range from the
player: 300 units from an NPC and 800 from a gate structure, and the player's own region or a
neighbouring one. It measures NPCs from their npcpos rows, so it needs `-npcpos-csv`
(`/data/npcpos.csv` on srrevamp-01). Without it the boot log warns `teleport NPCs' interaction
range is not measured`, and NPC teleports are served from anywhere. A teleport directory
exported before round 642 logs `teleport network has no WorldID column` at boot; re-export it as
described above.

Talk to one, then 'Select teleport area', then a destination. The log names the NPC's point:
`gate=GATE_NPC_CH_FERRY`. A destination in an instanced area (a fortress, tomb, temple, arena or
survival map) is refused with nothing charged: srrevamp has only the open world.

**Who pays.** Everyone pays the link's fee from the table (5,000 gold from Jangan to Donwhang),
except:

- characters below level 21 -- the engine's own waiver (`GObjPC::HandleTeleportUse`, `0x513590`);
- GM accounts (`-gm-accounts` / `SRREVAMP_GM_ACCOUNTS`), always -- own design, the user's ask;
- everyone, while `-teleport-free` (env `SRREVAMP_TELEPORT_FREE`) is on -- own design, the
  free-while-testing switch. **The default is off**; after an update the boot log reads
  `teleport free off (-teleport-free / SRREVAMP_TELEPORT_FREE): ...`.

**Whether the public server runs `-teleport-free` on is the user's decision**, not the deploy
loop's. To turn it on, add `SRREVAMP_TELEPORT_FREE: "1"` under the server's `environment:` in the
untracked `docker-compose.override.yml` (or append `- "-teleport-free=true"` to the override's
restated `command:` list), then run `docker compose up -d`; the boot log then reads `teleport free
on: every gate teleport costs nothing ...`. Remove the line (or set it to `"0"`) and run
`docker compose up -d` to charge fees again.

## Inventory size

Round 633 gave every character its own bag size, and the client pages the bag by it: 32 slots a
page, up to three pages ("Page 1 / Page 2 / Page 3" above the grid, the client's own tabs), with the
slots of the last page past the size drawn locked, as the original draws them.

- `-inventory-size` (env `SRREVAMP_INVENTORY_SIZE`) is the size of every character nobody has sized:
  **96 by default, three full pages** -- our choice for the test server, not a retail value. Set
  it lower (for example 32, one page) with `- "-inventory-size=32"` in the override's `command`, or
  the env variable, and `docker compose up -d`.
- A GM changes their own with `/invsize <1-96>`, or `/invsize default` to go back to the flag.
  `/invsize` alone prints it.
- The inventory expansion item (ITEM_MALL_INVENTORY_ADDITION, +32) grows a character's bag the way
  the engine allows: only while the engine's array (bag + 13 equipment) stays within 77, so from a
  bag of 32 or fewer. With the 96 default it is refused and kept.

Lowering the size never strands what a character already carries: items held past the new size
stay listed and can be moved out, used or dropped, while every new item (pickups, buys, trades,
withdrawals, moves) keeps within the new size. The server logs this once per character
(`bag size below a held slot: the items past it stay reachable, nothing new is placed there`), and
the bag is at the lower size once those slots are emptied.

The retail starting size is not known: it is a `_CHAR.InventorySize` database default, and neither
the client nor the server executable carries it.
