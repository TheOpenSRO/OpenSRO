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
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\refregion.txt" -out refregion.txt
/tmp/export-refdata  -mode regions -out regions.csv refregion.txt         # 3,194 regions, 103 towns; the server reads it with -regions-csv (round 674)
rm -f itemdata.txt itemdata_* skilldata.txt skilldata_* characterdata.txt characterdata_* leveldata.txt \
      levelgold.txt textdata_object.txt npcpos.txt teleport*.txt refregion.txt
                     # the extracted tables are game data; keep only the CSVs (and the teleport/ directory)

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
#   a. re-run `export-refdata -mode skills` with the NEW binary (step 2; the CSV grew to 90
#      columns here -- 91 since round 659, see "Deploying the monster-epic release" -- column 89 is AI_AttackChance, skilldata column 66), then the NEW `import-refdata`
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
# ROUND 659 (status effects) -- THE MONSTER-EPIC RELEASE NEEDS THE SKILLS RE-EXPORTED AND
# RE-IMPORTED, even on a server that did round 654's: the skills CSV is 91 columns, column 90
# StatusParams (every status run of the Param block), stored as skills.status_params. A skills
# table imported before round 659 loads with the column empty on every row and NO skill lands a
# status -- no poison, bleeding, burn, stun or freeze, on players or monsters -- and nothing
# fails. Re-run `export-refdata -mode skills` with the NEW binary (step 2), then the NEW
# `import-refdata` (step 3), then restart. Check both:
#   `SELECT count(*) FROM skills WHERE status_params <> '';` must answer MORE THAN 0, and
#   `SELECT count(*) FROM skills WHERE ai_attack_chance > 0;` should answer about 26650 (round
#   654's count on a retail archive).
# Since round 666 the server also WARNs at every boot while no skill carries status params:
# `skills store has NO status params (N skills, 0 with status_params) ... RE-EXPORT skills.csv`.

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
#         - "-regions-csv=/data/regions.csv"     # the towns (round 674): a monster entering one is removed; see "Towns"
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

- **Without `-full-map`, who spawns where does not change.** The roster in `cmd/server` (eleven
  species) is still what spawns, where it spawned before; with `-npcpos-csv` those eleven take
  their real rows as before. Measured on a retail export: 413 monsters spawn with the table and
  413 without, the same species, zones and levels. **With `-full-map`** (round 660) the table is
  what every field nest hatches from, and the roster's placements are replaced -- see "The full
  map (round 660)".
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
46-124-unit leg at their walk speed, and run home once they stray past their roam radius. Which
numbers a monster runs by depends on the flags: with `-full-map` and `-nest-db-dir` (round 660)
each monster takes its DB nest's radius and its tactics row -- aggressive or passive, its sight,
the 500-unit give-up, its roam rule (EXTERNAL); otherwise the OURS stand-ins (roam radius 200,
give-up 400, and under `-monster-aggro` every monster aggressive at sight +100). On its own (`-monster-ai` alone) a struck monster stops and
stands while anyone keeps auto-attacking it (the interim hold); `-monster-battle` (below) makes it
chase and swing on its own, `-monster-aggro` makes it notice players, and a unique fights with its
own skills and summons (round 661). The players whose area of interest holds a monster see each
move (round 664: the 3 x 3 blocks of 320 units around each player). What is grounded and what is a
stand-in is in `docs/protocol/monster_ai.md`, "srrevamp's runtime" and the rounds after it.

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
collision world yet. Under the interim hold (`-monster-battle` off) a monster hit only by skills
that do not hand off to the auto-attack is let go between casts and may wander off. A client that
stops reading its socket no longer stalls the tick: since round 662 every player is written from
its own queue, and a player whose queue passes 2 MB, or whose writes stay blocked past their
budget, is closed without holding anyone else.

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
Since round 665 the client offers retail's two choices and `OpRevive 0x0028` carries the
option: "Resurrect at the specified point." takes the character to its return point and revives
it there at 40 % HP -- srrevamp's return point is the world entry in Jangan, a stand-in for
retail's designated gate -- and "Resurrect at the present point." revives it where it lies (HP at
1 + 40 % of the maximum, the retail handler's arithmetic), at level 10 or under only, as retail.
Nothing revives a dead player unasked any more: retail has no timed revive outside a fortress war,
and round 549's 30 s in-place fallback revived players among the monsters that had killed them.
A character that logs out dead is saved at the return point (with `-persist-position`).
What is grounded and what is a stand-in is in `docs/protocol/character_state.md`, "The
resurrect choices (round 665)".

It is behind the `-player-dead-state` flag (env `SRREVAMP_PLAYER_DEAD_STATE`), and **the default
is off**. Off, a kill respawns the player at once, and since round 665 the respawn is moved to the
return point after the kill's messages (an `OpChangeZoneResult` to Jangan), so it no longer comes
back among its killers; the one other flag-independent piece is the entry revive of a stored HP 0
(the last paragraph). It does not
depend on the monster flags: it covers the counterattack inside the attacker's result and the
monster's own swings under `-monster-battle` alike. After an update the boot log reads
`player dead state off (-player-dead-state / SRREVAMP_PLAYER_DEAD_STATE): a monster's kill respawns
the player at once at the return point`.

**Turn it on only when both of these hold:**

1. A client release that carries round 665 is tagged, CI is green for it (`gh run list`), and its
   zips are published. **A client older than round 548 stays dead until it logs out**: it sees
   HP 0 and no Revive button after a kill, and since round 665 nothing revives a player unasked;
   it comes back alive (at 40 %) only by logging in again, at its return point with
   `-persist-position`, else at the world entry. Retail is the same above level 10 for a player
   who never picks a button. A client between rounds 548 and 665 has one Revive button, which the
   server reads as the present point at level 10 or under and the return point above it.
2. Round 665's live check (`docs/WORLD_ISSUES.md`, round 665, section 4: a death in the densest
   window, "Resurrect at the specified point.", the arrival in Jangan alive with one EXP loss)
   passes on the render box with the release's server and client. It passed on 2026-09-30 with
   the round's own build. (The round-549 check in `monster_ai.md` asserted the 30 s auto-revive,
   which is gone.)

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
- With `-player-dead-state` on as well, a character that logs out dead is saved at its return
  point (round 665; retail's leave path writes the return point for a dead PC, `FUN_004df050`) and
  re-enters there, revived to 40 % by the entry rule that applies whatever the flags say
  (`handleEnterWorld`'s revive of a stored HP 0, `character.RespawnFraction`). Before round 665 it
  was saved where it fell and re-entered beside the monster that killed it.

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

## Unique monster notices (on by default)

Round 657: when a unique monster (characterdata rank 3) appears or dies, every character in the
world sees it -- a line in the system window and the blue banner at the top of the screen, as the
original does. The kill line names the player who dealt the most damage in the group (party) that
dealt the most. The message is `OpUniqueNotice 0x0110`, carrying the original's `0x300C` payload
(`0x0C05` appeared / `0x0C06` killed). `docs/protocol/unique_notice.md` has the read.

With `-full-map` and `-nest-db-dir` the seven field uniques are placed and rotate over their spots
(round 661, "The full map (round 660)" below): each hatch and each kill is announced. Without
them no unique is placed, and a notice follows only a GM's `/spawnunique <id|name>` and its death
(`/damage <n>`, `/kill`, or players' blows).

It is on by default, as the original is with its `CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG` key
absent. The boot log reads `unique notices on: ...`. **Off:** add
`SRREVAMP_UNIQUE_NOTICE_OFF: "1"` under the server's `environment:` in the override (or
`- "-unique-notice-off=true"` in its `command:`), then `docker compose up -d`; the boot log then
reads `unique notices off (-unique-notice-off): no nest-hatch or kill notice is sent; a GM spawn is still
announced`. As in the original, the
key silences a nest's hatch and every kill but not a GM's spawn: `/spawnunique` is still announced. A client older than
round 657 ignores the message and warns "unhandled opcode" once per connection.

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

## Branding your front-end (round 678)

The login screen is retail's title screen: an intro flown in 3D over the world's own regions, with
the archive's own letterbox frame, logo, login box and music. Everything a private server usually
re-brands can be changed without repacking any archive, and every piece falls back to the
archive's own when the operator's is missing or broken (the client's log says which and why). The
format and every recovered value: `docs/protocol/intro_script.md`.

**What can be branded, and where it comes from**

| Piece | Server setting (flag / env) | Client file (next to the executable) | Default |
|---|---|---|---|
| The intro (the camera's flight) | `-login-intro` / `SRREVAMP_LOGIN_INTRO` | `custom/intro/<name>.txt` | option.txt's `IntroName` (roc) |
| The title music | `-login-bgm` / `SRREVAMP_LOGIN_BGM` | -- (a file in the archives) | option.txt's `IntroBGM` |
| The logo above the login box | `-login-logo` / `SRREVAMP_LOGIN_LOGO` | `custom/frontend/<file>`, or `custom/frontend/logo.png` | Media.pk2 `interface\outer\logo.ddj` |
| The top band | `-login-band-top` / `SRREVAMP_LOGIN_BAND_TOP` | `custom/frontend/<file>`, or `custom/frontend/band_top.png` | `blackbar_up_18.ddj` |
| The bottom band | `-login-band-bottom` / `SRREVAMP_LOGIN_BAND_BOTTOM` | `custom/frontend/<file>`, or `custom/frontend/band_bottom.png` | `blackbar_down_copyright.ddj` |
| A copyright / branding line | `-login-copyright` / `SRREVAMP_LOGIN_COPYRIGHT` | -- | none (the archive's band art carries its own line) |

All server settings default to empty: with none set, players see retail's screen. Set them in the
compose override's `command` (`- "-login-intro=constantinople"`) or as environment variables, then
`docker compose up -d`. The server logs what it serves at startup (`front-end theme ...`) and warns
about, and refuses, anything that is not a plain file name.

**How the client picks** (per piece): a `SRREVAMP_LOGIN_*` variable on the player's own machine
(for previewing, below) > the server's answer > the answer it cached last launch > the client's
`setting/config.yaml` (round 679: only the intro, `global.loginScreen`; next section) > a
`custom/theme.json` shipped with the client > retail's default. The client asks the server it is
about to connect to (the address remembered from the last login) as it starts, waits at most 1.5 s,
and caches the answer per server address -- so a first launch against a new server may show the
default once, and every launch after it that server's choice. The server answers the question once
and closes that connection; it never logs it. `custom/theme.json` is the same structure the server sends:

```json
{"v":1,"intro":"myserver","bgm":"","logo":"mylogo.png","copyright":"(c) 2026 My Server","band_top":"","band_bottom":"","charselect":null,"create":null}
```

(`charselect` and `create` are reserved for the character select and creation scenes of a later
release; leave them `null`.)

**Choosing a built-in intro.** The archives carry these (vSRO's Media.pk2; `docs/protocol/
intro_script.md` has the table): `roc` (the default; `egypt` and `china_whatf` are the same file),
`constantinople`, `china_wharf`, `jupiter_login`, `rm`, `ruby_baghdad`. The last two also script
smoke, crowds and riders, which this client does not play yet -- their cameras fly over an empty
scene. A full archive path (`script\intro\roc.txt`) works too.

**Writing your own intro.** Put `custom/intro/<name>.txt` next to the client's executable (a name of
letters, digits, `_` and `-`), and set `-login-intro=<name>` on the server (or `"intro"` in
`custom/theme.json`). The file is retail's format, in UTF-16 or UTF-8:

```
[CAMERA]
0.0 S_CameraInsert 0.0 168 97 1002 40 900 0.20 3.14 0.0 100
0.0 S_CameraInsert 8.0 168 97 1002 60 1200 0.15 3.40 0.0 120
0.0 S_CameraInsert 16.0 168 97 900 120 1500 0.30 3.80 0.0 100
[END]
```

Each line: an unused first value, `S_CameraInsert`, the time in seconds, the region's two numbers in
the order **lo hi** (Jangan's region 97/168 is written `168 97`), the look-at point x y z inside that
region (it may run past 0..1920 into the neighbours), then pitch (radians, positive looks down), yaw
(radians, 0 looks north), roll, and the camera's distance back from the look-at point. The camera
eases through every point (a Catmull-Rom spline), every position is taken relative to the LAST line's
region, and it stops on the last point, where the login window fades in -- or earlier, on a click or
a key. The client checks the file when it loads it; one that does not parse falls back to the
archive's intro of that name, then to option.txt's, and logs why. A `[SCRIPT]` section is read but not
run yet. Values a camera cannot fly are refused, so the intro falls back: at most 1024 lines, times
0..3600 s, x and z within 32 regions of the named one (+-61440), heights within +-20000, angles within
+-1000 rad, distances 0..100000, and no `inf`/`nan` (our bounds; retail's own files sit far inside them).

**Memory.** The 3D title is always on; it is not a player option. Measured on the Linux render box,
it raises the process's resident memory once in the world by ~200 MB (glibc keeps what the title's worker threads freed in their own
arenas; `MALLOC_ARENA_MAX=2` in the environment removes it, and lowers the world's own footprint by ~215
MB besides). Windows' allocator does not keep per-thread arenas this way; not measured there.

**The music.** `-login-bgm=<file>` names an `.ogg` track in the player's Music.pk2 root (e.g.
`maintheme_cut.ogg`; only `.ogg` names are looked up there, so only `.ogg` is accepted). Retail has one
title track for every intro; choosing one per server is ours. A name that is not in the archive falls
back to IntroBGM.

**The logo and the bands.** PNG (or DDJ) files in `custom/frontend/`. The logo is shown at the size
and place of the archive's own (508 x 172 in retail's 1600 x 1200 layout, centred above the login
box) and keeps its aspect ratio inside that box -- a 508 x 172 image, or larger at the same shape,
fits it exactly. The bands are stretched to the archive's band rectangles (1600 x 172 in the same
layout: the top one at y 0, the bottom one at y 1030), so draw them 1600 x 172. Set
`-login-copyright` and the bottom band switches to the archive's plain one (`blackbar_down.ddj`) with
your line centred where the archive's own line sits, so the two never overlap.

**Previewing on your own machine, no server needed.** Run the client with the same names as
environment variables, e.g. `SRREVAMP_LOGIN_INTRO=myserver SRREVAMP_LOGIN_LOGO=mylogo.png`, and
`SRREVAMP_CUSTOM_DIR=<folder>` to use a folder other than `custom/` next to the executable. They win
over the server's answer, so you see your files at once; the client's log (`FrontEnd:` and `TITLE:`
lines) says what it used and why it fell back. For a render on the box: `SRREVAMP_QA_TITLE_SEEK=0,10,20`
stands the camera at those times and logs `QA TITLE SHOT t=.. frame ..`; `SRREVAMP_QA_TITLE_HOUR=0..3`
pins the time of day (retail picks 5, 14, 18 or 23 o'clock at random).

## Configuring the client: setting/config.yaml (round 679)

A private server configures the client it hands its players with **data files in a `setting/`
folder next to the client's executable**, beside its `pk2/` folder -- no rebuilding, and no
re-signing of the executable or its DLLs, because nothing in `setting/` is ever run: the client only
reads it. (Retail keeps its own options in a `Setting\` folder beside its exe too: `SROptionSet.dat`,
`wndpos.dat` and others.) This folder will later hold the client's own saved settings as well --
display, sound, hot bar and the rest; for now it holds one file, the general client config,
`setting/config.yaml`. Developers can point the client at another folder with
`SRREVAMP_SETTING_DIR=<folder>`.

```yaml
# setting/config.yaml -- every key is optional, except each server's type and gateway.
global:
  loginScreen: constantinople      # the title intro (same names as -login-intro)
  region: US                       # kept, reserved (see below)
servers:
  MyServer:                        # the name the login screen shows
    type: srrevamp                 # this project's server
    gateway: { address: login.example.com, port: 15779 }
    agent:   { address: agent.example.com, port: 15884 }
  SomePrivateServer:
    type: legacy                   # a server speaking the original protocol
    gateway: { address: 203.0.113.7 }      # the port defaults to 15779
```

| Key | Meaning |
|---|---|
| `global.loginScreen` | The title intro: a retail name (`roc`, `constantinople`, `china_wharf`, `jupiter_login`, `rm`, `ruby_baghdad`, ...) or your own `custom/intro/<name>.txt`. The server's `-login-intro` wins over it (below). |
| `global.region` | Kept and reserved: a short code (letters, digits, `_`, `-`). vSRO's client reads no region: its `DIVISIONINFO.TXT` starts with a locale byte (22 in vSRO's archive) that the client's own loader skips, and the iSRO "Located In" bar's art is in the archive but no code names it. A later round may use it for the language or the content id. |
| `servers.<name>` | One server. `<name>` is what the Server field and the list show (1-32 characters). The file's order is the list's order. |
| `servers.<name>.type` | **Required** (round 681): the protocol the server speaks. `srrevamp` -- this project's server: its status is asked with this project's own question. `legacy` -- the original gateway protocol (a retail-style private server): the client asks it for its shard list the way the original client does (the handshake, then the patch check and the list) and shows each shard's real status; it is never sent this project's own messages, the login screen keeps its own intro for it (no theme question), and logging in to it is not supported yet. An entry without a type, or with another word, is skipped with a `SETTING:` line naming the server and the two values. Once this project's server also speaks the original protocol (the superset plan in `docs/protocol/PROTOCOL_DECISION.md`), `srrevamp` will mean "also has our extensions" rather than a different wire. |
| `servers.<name>.gateway` | Where the client connects: `address` (a host name or IP address) and `port` (default 15779). Required. It plays the part of retail's `DIVISIONINFO.TXT` host and `GATEPORT.TXT` port. |
| `servers.<name>.agent` | Read and kept, **not used yet**: `address` and `port`, both required if given. Retail's gateway tells the client which agent server to connect to in its login reply; this server is one process and has no such hand-off yet. When it does, a configured agent will stand in for the address the gateway names (a proxy feature). |

**What the player sees.** With `servers` listed, the login screen's Server field shows the chosen
server's name (read-only, centred) and a **LIST** button opens the server list -- retail's window,
built from the archive's own layout and art -- with each server's status, asked of every server at
once and again every 5 s while the list is open (retail's own interval). Picking one with Select (or a
double click) puts its name in the field; the client remembers it for the next launch. Without
`servers`, the field is the old editable `host:port`.

**The status** (the words and colours are retail's, from the archive's text table):

| Shown | When |
|---|---|
| Check | the server runs with `-inspection` (env `SRREVAMP_INSPECTION`) |
| Easy | fewer than 35 % of `-max-players` in the world |
| Populated | 35 % to under 97 % |
| Crowded | 97 % to under 100 % |
| FULL | 100 % or more |
| Closed | the server did not answer within 2 s (not running, wrong address, blocked port) |

**A `legacy` server's status is its own.** The client asks its gateway for the shard list and shows
one row per shard, `<config name> - <shard name>`, with the words and colours above computed from
the numbers the gateway sends (Check when it marks the shard in inspection). It tells the gateway
the content id and version of the player's own archive (Media.pk2's `DIVISIONINFO.TXT` and
`SV.T`), as the original client does, so the client needs the Media.pk2 of the server's own client
version; a gateway that refuses that version (or is not in service) shows Closed, with the reason in
the log. Closed also means no answer within 4 s. To try it without a real server:
`go run ./cmd/retailgw serve -listen 127.0.0.1:15779 -shards "Test:120/1000:1,Check:0/500:0"` runs a
fake one (`server/README.md`).

The percentages come from the archive's text table (`UIO_STT_SERVER_35` / `UIO_STT_SERVER_75`, 35
and 97 in the English column), as retail's do. `-max-players` (env `SRREVAMP_MAX_PLAYERS`, 1-65535,
default 1000) is the capacity; a login is refused with retail's "The server is full, please try
again later." once that many characters are in the world (characters that have entered the world,
not accounts at character select). Under `-inspection` every login is refused with retail's "Cannot
connect to the server because the server is now in inspection." The `-gm-accounts` names are let
through both, so staff can test a server under inspection or a full one.

**Which setting wins when two places set the intro:** the player's `SRREVAMP_LOGIN_INTRO` (a preview)
> the server's `-login-intro` (its fresh answer, else the one cached from the last launch) >
`setting/config.yaml`'s `global.loginScreen` > `custom/theme.json`'s `intro` > retail's `option.txt`.
The reasoning: the server's answer is the branding of the server being connected to, which its own
operator controls; a config may list several servers, and its `global` choice is the fallback for
the ones that set nothing. `custom/theme.json` stays the place for the logo and band images. The
theme is asked of the chosen server.

**Mistakes.** The client logs every problem in its log file as a `SETTING:` line and carries on: a
file that does not parse (the line number is in the message) is ignored whole; a server entry
without a usable gateway, or without a `type` of `srrevamp` or `legacy`, is skipped and the others
kept; an unknown key is ignored. The file is a
strict subset of YAML: maps by indentation (spaces, not tabs), `{ a: 1, b: 2 }` and `[1, 2]` on one
line, `- item` lists, quoted or plain values, `#` comments; no anchors, tags or multi-line strings.

**Later (not built):** a server may also hand the client settings it wants kept out of the file,
during the server list or after login (docs/TODO.md).

## The full map (round 660)

`-full-map` (env `SRREVAMP_FULL_MAP`, off by default) places every field monster of the game.
Each monster row of `-npcpos-csv` outside the dungeon regions becomes a nest hatching its species
from `-monsters-csv`, run by the engine's own hatch rules (`server/internal/nest`,
`docs/protocol/monster_ai.md`, "Nests on the map"). Left out: the dungeons (1,915 rows), the
Pharaoh temple's 90 rows (their nests belong to the temple's instance worlds, round 661), MOB_SD_APIS
(no nest of its own) and the shard's custom species.

**The uniques (round 661)** need `-nest-db-dir`: each of the seven field uniques stands at one of its
npcpos spots at a time (its shard hive has a total of 1, EXTERNAL) and, killed, reappears at another
after its hive's window -- 1,200-1,400 s for Tiger Girl, Uruchi, Isyutaru, Cerberus and Captain
Ivy, 2,100-2,200 s for Lord Yarkan and Demon Shaitan (EXTERNAL). It fights with its own skills and
uses its summon skills each time it loses a tenth of its HP -- but only Cerberus's summon anything
(its Ladons): the other six uniques' tuples give a count of 0..0 and the engine's executor spawns
nothing for them (READ). For the summons and Captain Ivy's trigger the directory also needs
`Tab_RefAISkill.csv` and `_RefSkill.csv` (below). Without those two files the uniques still rotate
and fight but summon nothing, and the boot log says so. `-unique-respawn=60s` (env
`SRREVAMP_UNIQUE_RESPAWN`) shortens the wait for testing (OURS); `-nest-respawn` does not reach
the uniques. The boot log has one `unique rotation` line per unique, and every hatch, re-pin and
summon is logged (`unique hatched`, `unique rotation: re-pinned`, `unique summons`).

**`-full-map` forces `-single-frame` on**: every zone with a frame is one world and one broadcast
bucket, so local chat, other players' moves and the ground-item lists go world-wide rather than
zone-wide, and players need a client that carries rounds 569-571 (see "Single world frame").

- **With `-nest-db-dir`** (env `SRREVAMP_NEST_DB_DIR`, the three CSVs of the section below, mounted
  at `/data/nestdb`): a row whose spot's shard nest hatches the same species (`matched=4063` in this release's boot
  log; round 660 counted 4,068 before round 661's changes) takes that
  nest's numbers -- its cap (up to 17 alive), its respawn window (1-3 s on most, 8-12 s on 459), its
  hatch spread, its champion chance (10 % on most) -- and its tactics: aggressive or passive,
  sight, the 500-unit give-up distance, the roam radius and rule. A row whose nest the shard gave
  to its own custom monster (6,041 rows) places the original species, under its own tactics row
  when it has one (2,346 rows; the stand-in behaviour otherwise), on that nest's own cap, window,
  radii and champion chance (the user's decision, round 660's review). EXTERNAL values throughout.
  `-nest-swapped-stand-in` (env `SRREVAMP_NEST_SWAPPED_STAND_IN`, OURS) puts those rows back on a
  one-monster stand-in nest each (10 s, no champion roll) -- half the monsters.
- **Without it**: one monster per row, respawning 10 s after its death, all aggressive with the
  stand-in sight and leash, no champions. The boot log says so.

Measured on the shard in round 660 (its WORLD_ISSUES entry and review follow-up): 10,109 nests,
at most 65,982 monsters alive (34,663 with `-nest-swapped-stand-in`), AI tick p99 under 2 ms with
a player in a matched field and 6.4 ms at the densest window, RSS 127-165 MB. This release's boot
logs `placed=10104` and `matched=4063` (round 661 changed which rows are placed; the difference is
not re-derived here).

**The full population is what srrevamp-01 runs** (the user's decision, "DB numbers now", round
660's review): `-nest-swapped-stand-in` is NOT set there. Round 660 measured the client at 7-10 fps
where the swapped spots cluster (the Europe starter field 108/77, the densest window) with a
round-655 client; round 664 then made a player be sent only the monsters of the 3 x 3 blocks of 320
units around it (retail's message blocks, READ) and made the client draw a dense field at 60 fps
(its WORLD_ISSUES entry has the numbers). `-nest-swapped-stand-in` stays as an optional OURS
fallback -- one monster per swapped spot, about half the monsters -- for a host that cannot carry
the full population; it is off by default and off on srrevamp-01.

The flags srrevamp-01 needs for the monster world, in the override's `command:` (restate the whole
list) or as environment variables:

```
#         - "-npcpos-csv=/data/npcpos.csv"
#         - "-monsters-csv=/data/monsters.csv"
#         - "-skills-csv=/data/skills.csv"        # only with -in-memory; PostgreSQL holds the skills
#         - "-nest-db-dir=/data/nestdb"           # EXTERNAL, the three shard CSVs (+ the two of round 661)
#         - "-full-map=true"                      # turns -single-frame on itself
#         # -nest-swapped-stand-in=true           # OURS fallback, OFF on srrevamp-01: one monster per swapped spot
#         - "-monster-ai=true"
#         - "-monster-strike-push=true"
#         - "-monster-spawn-push=true"
#         - "-monster-battle=true"
#         - "-player-dead-state=true"
#         - "-monster-aggro=true"
#         # -monster-sleep is on by default; keep it on at this size.
#         # -nest-respawn=30s overrides every nest's window but the uniques', for testing only.
#         # -unique-respawn=60s shortens the uniques' wait after a death, for testing only.
```

A client must be a release that carries round 656 (the paged list and the enter/leave pushes) for
a window this dense; one that also carries round 660 gets the party flag and draws champions,
giants and elites at their retail scale. An older client is sent no party flag and draws every
rank at its species' size. `SRREVAMP_AI_TICK_STATS=1` logs the AI tick's p50/p99 once a minute.

## Towns (round 674)

`-regions-csv` (env `SRREVAMP_REGIONS_CSV`) gives the server the game's region table, `_RefRegion`,
whose `IsBattleField` 0 regions are the towns. With the monster AI on, a monster that walks into a
town region -- a monster chasing a player through Jangan's gate, say -- is removed at the line: no
death, no reward, the players who could see it told it left (`OpMonsterLeft`; the client drops the
body). That is SR_GameServer.exe's own rule (`CGObjMob::SetCurRegion` 0x4c1270, which sets life state
3 on every region change into a town; `docs/protocol/monster_ai.md`, "Towns"). A monster outside the
line can still hit a player standing just inside it, as in retail. Without the file no region is a
town and monsters follow players in, as before round 674.

On srrevamp-01, with this release's server running (the update timer, step 0 of the next section):
1. Export `regions.csv` (step 2 of "Reference data": the `refregion.txt` and `-mode regions` lines).
   The exporter prints `wrote 3194 regions to regions.csv, 103 of them towns (IsBattleField 0)` on
   a retail archive.
2. `scp regions.csv srrevamp@<server-host>:~/srrevamp-data/ && ssh srrevamp@<server-host> 'chmod 644 ~/srrevamp-data/regions.csv'`
3. Add `- "-regions-csv=/data/regions.csv"` to the override's `command:` list (edit only that key,
   as in step 6 of the next section), then `cd ~/srrevamp && docker compose up -d`.
4. The boot log (`docker compose logs server`) says
   `region table loaded: a monster entering a town region is removed (IsBattleField 0) ... regions=3194 towns=103`,
   and a monster that walks in logs `monster removed: it entered a town ... name=... how="walked in" ... area=Town_Jangan`
   at INFO. One removed where it was placed (hatched or spawned in a town) is logged at Debug, and
   counted once a minute at INFO: `monsters removed on placement in a town ... count=N`.

Six of the retail archive's 12,110 monster placements stand in a town region (two of Alexandria's
`town_Alex` regions, 90/49 and 91/51: one MOB_SD_UNEG, five MOB_SD_WENEG). With `-full-map` each
hatches, is removed on the first AI pass that runs it (with `-monster-sleep`, the default, once a
player comes near) and hatches again after its nest's window -- what the engine's rule does with a
nest in a town (INFERRED: its placement goes through the same region change). Each nest's window
is 1-3 s with a cap of 24 (EXTERNAL), so near them the per-minute count runs at about 30-60.

## Deploying the monster-epic release to srrevamp-01 (round 666)

The release that carries rounds 653-666 changes the reference data, adds the shard's nest files
and turns the monster world on. The final release review ran steps 1, 2 and 4 and checked step 7's boot lines on the render box (steps 0, 5 and 6 need srrevamp-01 and its Postgres, so they were not run there); do them in this order.
`<server-host>` is srrevamp-01 (`srrevamp@192.168.5.25`); the checkout there is `~/srrevamp`, and
`~/srrevamp-data` is mounted into the server container as `/data`.

0. **First, the host must be running this release's server.** Steps 6-7 pass `-full-map` and
   `-nest-db-dir`; a server built before them (dev at ab66d9c has neither) exits with `flag
   provided but not defined`, and Docker restarts it in a loop. srrevamp-01 follows `dev` by
   itself: `deploy/update.sh` runs from the `srrevamp-update.timer` (enabled there, every 5 min,
   `OnUnitActiveSec=5min`; checked 2026-09-30), fetches `origin/dev`, fast-forwards, rebuilds and
   restarts the stack, and rolls back a build that does not come up. So once the release is merged
   to `dev`, either wait for the timer or run it now, then check the host's commit:
   ```
   ssh srrevamp@<server-host> 'sudo systemctl start srrevamp-update.service; journalctl -u srrevamp-update -n 5 --no-pager'
   ssh srrevamp@<server-host> 'cd ~/srrevamp && git log --oneline -1'
   ```
   The journal line `server at <commit> listening on 15779` and a `git log` at the release's
   commit (or later) mean it is running. (By hand, the same thing: `cd ~/srrevamp && git pull &&
   docker compose up -d --build`.) Until then, change nothing in the override: the old server
   runs happily on the old one, and the new server boots on it too (without `-full-map` it places
   the roster as before).
1. **Build the tools** on the machine with the client's `Media.pk2`, with `CGO_ENABLED=0` (static
   binaries, as step 1 of "Reference data" builds them):
   ```
   cd server && for t in pk2list export-refdata export-leveldata import-refdata; do
     CGO_ENABLED=0 GOOS=linux go build -o /tmp/$t ./cmd/$t; done
   ```
2. **Export the reference data**: run step 2 of "Reference data" above in full, with these new
   binaries. It writes `skills.csv`, `monsters.csv`, `npcpos.csv`, `items.csv`, `leveldata.csv`
   and the `teleport/` directory, and its last `rm` deletes the extracted text tables (`ls *.txt`
   then finds nothing). `skills.csv` has no header, and a StatusParams cell is quoted with commas
   inside (`"bl:30000,100,1,200,0"`), so count its columns with a CSV reader, not `tr`:
   ```
   python3 -c 'import csv; print(sorted({len(r) for r in csv.reader(open("skills.csv"))}))'
   ```
   must print `[91]` (every row 91 columns, column 90 StatusParams).
3. **Copy the three changed CSVs and the importer** to the host, and make them readable by the
   container:
   ```
   scp skills.csv monsters.csv npcpos.csv /tmp/import-refdata srrevamp@<server-host>:~/srrevamp-data/
   ssh srrevamp@<server-host> 'chmod 644 ~/srrevamp-data/*.csv'
   ```
4. **Copy exactly the five shard files** into `~/srrevamp-data/nestdb/` -- `Tab_RefTactics.csv`,
   `tab_refnest.csv`, `tab_refhive.csv`, `Tab_RefAISkill.csv`, `_RefSkill.csv` (EXTERNAL; from the
   render box's `/opt/sro-files/db/csv/`, or exported as in "The three files `-nest-db-dir`
   reads" below) -- then, on the host:
   ```
   chmod 755 ~/srrevamp-data/nestdb; chmod 644 ~/srrevamp-data/nestdb/*.csv
   ```
   Without the chmod the nonroot container cannot read them and the server crash-loops (see that
   section).
5. **Re-import the skills** into Postgres on the host, then check them. The `psql` goes through
   compose, so it runs from the checkout (after `ssh` the working directory is `~`, where compose
   finds no file):
   ```
   ~/srrevamp-data/import-refdata -skills-csv ~/srrevamp-data/skills.csv \
       -postgres-dsn 'postgres://postgres:postgres@127.0.0.1:5432/srrevamp?sslmode=disable'
   cd ~/srrevamp && docker compose exec postgres psql -U postgres -d srrevamp \
       -c "SELECT count(*) FROM skills WHERE status_params <> '';" \
       -c "SELECT count(*) FROM skills WHERE ai_attack_chance > 0;"
   ```
   The first count must be **above 0** (0 means the import read an old CSV: no skill would land a
   status); the second should be about **26650**.
6. **Edit only the `command:` key of the override** (`~/srrevamp/docker-compose.override.yml`,
   untracked). Leave its `environment:` and `volumes:` as they are: srrevamp-01's override sets
   the GM accounts, `SRREVAMP_PERSIST_POSITION` and the six monster flags there (checked
   2026-09-30), and a pasted `services:` block would drop them. `command` REPLACES the base list,
   so it restates all of it; add the last three lines below to what is there. No
   `-nest-swapped-stand-in`, no `-unique-respawn`:
   ```
       command:
         - "-addr=:15779"
         - "-postgres-dsn=postgres://postgres:postgres@postgres:5432/srrevamp?sslmode=disable"
         - "-leveldata-csv=/data/leveldata.csv"
         - "-npcpos-csv=/data/npcpos.csv"
         - "-teleport-dir=/data/teleport"
         - "-monsters-csv=/data/monsters.csv"
         - "-nest-db-dir=/data/nestdb"
         - "-full-map=true"
   ```
   The six monster flags -- `-monster-ai`, `-monster-strike-push`, `-monster-spawn-push`,
   `-monster-battle`, `-player-dead-state`, `-monster-aggro` -- must be on too: as
   `SRREVAMP_MONSTER_AI: "1"` and the rest under `environment:` (srrevamp-01's way), or as
   `- "-monster-ai=true"` lines in `command:`. One of the two is enough.
7. **Start it and read the boot log**, from the checkout:
   `cd ~/srrevamp && docker compose up -d && docker compose logs server`.
   Expect:
   - `nest DB loaded (EXTERNAL ...) ... tactics=1743 nests=16381 hives=1170 ai_skill_tactics=132 skills=36144`
   - `full map: npcpos joined to nests ... placed=10104 ...`
   - seven `unique rotation` lines, one per field unique;
   - seven `unique hatched` lines;
   - and NO `skills store has NO status params` WARN (round 666; if it is there, step 5 imported
     an old CSV).

   A `loading the nest DB ... permission denied: chmod 644 ...` error means step 4's chmod was
   missed; `flag provided but not defined: -full-map` means step 0 was skipped (put the override's
   `command:` back and do step 0). **Players need this release's client**: an older one cannot
   draw the paged list, the area-of-interest pushes or the unique banner (the sections above name
   the round each needs).

## External shard DB: restore and export (user-supplied, EXTERNAL)

The monster AI's four tables (`Tab_RefTactics`, `tab_refnest`, `tab_refhive`, `Tab_RefAISkill`)
and a few others exist only as SQL Server rows. The client carries none of them
(`docs/protocol/monster_ai.md`). Round 658 restored a private shard's backup the user supplied and
exported it to CSV. **The backup, the database and the CSVs never enter this repo.** The CSVs live
on the render box at `/opt/sro-files/db/csv/`. What the export is worth (its layouts match the
parsers, but much of it is modded) is in `monster_ai.md`, "External shard DB".

SQL Server needs about 2 GB of RAM, so run it in a throwaway container on the Proxmox host, not on
the render box or the dev machine. Round 658 used CT 104 `mssql-temp` on `pve`: Debian 13, 4 cores,
8 GB, 40 GB on local-lvm, unprivileged with `nesting=1,keyctl=1`. **It is left stopped, not
deleted.** `pct start 104` brings it back with the database already restored.

```
# 1. The container (on the Proxmox host):
pct create 104 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst --hostname mssql-temp \
  --cores 4 --memory 8192 --swap 2048 --rootfs local-lvm:40 --unprivileged 1 \
  --features nesting=1,keyctl=1 --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --ssh-public-keys /root/.ssh/authorized_keys --ostype debian --onboot 0
pct start 104

# 2. Inside it: docker and SQL Server 2022. The SA password is generated here, is kept only
#    in /root/.sa_pass (mode 600), and is never written anywhere else.
apt-get update && apt-get install -y docker.io python3-venv
umask 077; echo "Sa$(openssl rand -hex 12)#9x" > /root/.sa_pass
mkdir -p /srv/mssql/data /srv/mssql/backup && chown -R 10001:0 /srv/mssql
docker run -d --name mssql -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$(cat /root/.sa_pass)" \
  -e MSSQL_MEMORY_LIMIT_MB=6144 -v /srv/mssql/data:/var/opt/mssql -v /srv/mssql/backup:/backup \
  mcr.microsoft.com/mssql/server:2022-latest

# 3. Copy the .bak into /srv/mssql/backup/ (check its md5sum on both ends), then restore.
#    FILELISTONLY gives the logical names that MOVE needs (this backup: SRO_VT_SHARD_Data / _Log).
S="docker exec mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P $(cat /root/.sa_pass)"
$S -Q "RESTORE FILELISTONLY FROM DISK=N'/backup/SRO_VT_SHARD.bak'"
$S -Q "RESTORE DATABASE SRO_VT_SHARD FROM DISK=N'/backup/SRO_VT_SHARD.bak' WITH
       MOVE N'SRO_VT_SHARD_Data' TO N'/var/opt/mssql/data/SRO_VT_SHARD.mdf',
       MOVE N'SRO_VT_SHARD_Log'  TO N'/var/opt/mssql/data/SRO_VT_SHARD_log.ldf', STATS=20"

# 4. Export with pymssql (python3 -m venv /root/venv && /root/venv/bin/pip install pymssql).
#    One CSV per table, header = the DB's own column names, written with Python's csv module.
#    Cells: NULL is empty, a SQL `real` is written as the shortest decimal that round-trips the
#    float32, and binary is 0x-hex. Also write _tables.csv (every table with its rows and
#    columns from sys.partitions/sys.columns). Round 658 exported the four AI tables,
#    _RefHWANLevel, the drop tables (_RefMonster_AssignedItemDrop, _RefMonster_AssignedItemRndDrop,
#    _RefDropGold, _RefDropItemAssign, _RefDropItemGroup, _RefDropOptLvlSel,
#    _RefCustomizingReservedItemDropForMonster, every _RefDropClassSel_*), _RefObjCommon,
#    _RefObjChar, _RefSkill, _UniqueInfo, _RefGame_World, _RefGame_World_Config,
#    _RefGameWorldGroup_Config, _RefServerEventReward_SpawnMonster and _RefGameWorldNPC. It also
#    wrote world_config_keys.csv (the PARTYMONSTER_SPAWN / GiantMonster* /
#    CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG rows) and _UniqueKillList_summary.csv (kills and gaps
#    between kills for each unique; the per-character rows are not exported).
#    Tar the directory to the render box's /opt/sro-files/db/csv/.

# 5. When done: pct stop 104 (on the host). pct destroy 104 only once nobody needs the DB.
```

Traps:

- The Korean description strings (`szDescString128` and similar) are cp949 bytes in
  `SQL_Latin1_General_CP1_CI_AS` varchar columns, so they export as mojibake. Nothing reads
  them. Recover a string with `.encode('latin1').decode('cp949')` if one is ever needed.
- `nRegionDBID` is a signed smallint. Mask it with `& 0xffff` before comparing it with
  npcpos's region: dungeon regions (>= 0x8000) come out negative.
- `tab_refnest.fLocalPosY` is NULL on 145 rows.

### The three files `-nest-db-dir` reads (round 660)

`-full-map` with `-nest-db-dir` joins every npcpos row to its shard nest (see "The full map
(round 660)" above). It reads three of the CSVs step 4 writes, under the table's own name, with the
DB's own column names as the header: `Tab_RefTactics.csv`, `tab_refnest.csv`, `tab_refhive.csv`.
Round 661 reads two more when they are there -- `Tab_RefAISkill.csv` (the uniques' triggers) and
`_RefSkill.csv` (their summon skills' Param blocks; 14 MB) -- and boots without them.
Round 658's full export (`/opt/sro-files/db/validation/export_db.py` on the render box) writes them;
to export only those three from the restored database (CT 104, step 4's venv):

```
# In CT 104 (pct start 104), with the database restored as above:
/root/venv/bin/python - /srv/export <<'PY'
import csv, os, struct, sys, pymssql
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
cn = pymssql.connect(server="127.0.0.1", user="sa", password=open("/root/.sa_pass").read().strip(),
                     database="SRO_VT_SHARD", charset="UTF-8")
cur = cn.cursor()
def f32(v):  # the shortest decimal that round-trips the float32 (a SQL `real`)
    b = struct.pack("<f", v)
    return next((s for s in ("%.*g" % (p, v) for p in range(6, 10)) if struct.pack("<f", float(s)) == b), repr(v))
for t in ("Tab_RefTactics", "tab_refnest", "tab_refhive", "Tab_RefAISkill", "_RefSkill"):
    cur.execute("SELECT c.name, ty.name FROM sys.columns c JOIN sys.types ty ON ty.user_type_id=c.user_type_id "
                "WHERE c.object_id=OBJECT_ID(%s) ORDER BY c.column_id", ("dbo." + t,))
    cols = cur.fetchall()
    cur.execute("SELECT * FROM dbo.[%s] ORDER BY [%s]" % (t, cols[0][0]))
    with open(os.path.join(out, t + ".csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow([c[0] for c in cols])
        for row in cur:
            w.writerow(["" if v is None else f32(v) if cols[i][1] == "real" else str(v) for i, v in enumerate(row)])
PY
# From the host: pct pull 104 /srv/export/tab_refnest.csv ./tab_refnest.csv (and the other four), then
# copy the five to the server host's ~/srrevamp-data/nestdb/ -- mounted as /data/nestdb:
scp Tab_RefTactics.csv tab_refnest.csv tab_refhive.csv Tab_RefAISkill.csv _RefSkill.csv \
  srrevamp@<server-host>:~/srrevamp-data/nestdb/
# Then, ON THE SERVER HOST, make them readable by the container:
chmod 755 ~/srrevamp-data/nestdb; chmod 644 ~/srrevamp-data/nestdb/*.csv
# The render box already holds all five, from round 658's full export: /opt/sro-files/db/csv/.
```

**The chmod is not optional.** The server image runs as distroless `nonroot` (`server/Dockerfile`),
not as the host user that owns `~/srrevamp-data`. The export above runs under `umask 077`, so its
CSVs are mode 0600, and scp keeps that mode on a new file: the container cannot read them, the
boot fails, and Docker restarts it in a loop. Since round 666 that boot error reads
`loading the nest DB ... permission denied: chmod 644 the nest DB's CSVs and chmod 755 their
directory ...` (before it, a bare `open ...: permission denied`).

They are EXTERNAL data from a private shard's backup, like the rest of this section: never commit
them. The loader reads the columns by name (43, 17 and 10 columns; `tab_refhive`'s last,
`szDescString128`, is not read), masks `nRegionDBID` to the engine's u16 itself, and treats an
empty `fLocalPosY` as NULL. A missing file or column is fatal at boot.
