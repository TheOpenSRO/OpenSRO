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
3. You accept the monster list's size. It is one packet, capped at 32,767 payload bytes (`sizeMask`,
   `internal/proto/packet.go`), and each monster costs 40 bytes plus its name and code name
   (`MonsterSnapshot.Encode`). With `-npcpos-csv` Jangan's 348 roster monsters are 23,769 bytes
   today; the one bucket holds them and the Earth Ghost's 65, 28,189 bytes, for every player.
   72 more Mangyang-sized entries (64 bytes each; four GM `/spawn 20`s, which nothing respawns and
   `combat.Hub` drops only when they die) push it over the cap: every list request then fails in
   `proto.Write` (`payload ... too large for a single frame`) and the gateway closes that player's
   session (`handler error, closing session`). With the flag off it takes 141 in Jangan's bucket
   alone; with it on, 72 anywhere, and every player's list fails.

**On.** Add `SRREVAMP_SINGLE_FRAME: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `SRREVAMP_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-single-frame=true"` to the override's restated
`command:` list. The boot log then reads `single frame on: origin 97/168 ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Nothing is stored in the frame, so every zone is back in its own frame on the next login.
