## The public server had no reference data: no EXP, floor-band damage, empty shop -- fed, and measured

The user's playtest on sro.opensro.org: no EXP on a kill, monster health that "felt wrong",
nothing dropping. The first two had one cause, and it was not a formula. The public server's
database held `items 0, skills 0, monster_drops 0, drop_group_entries 0`, and its compose command
passed only `-addr` and `-postgres-dsn` -- the server had been booting since 2026-09-11 with the
line `no leveldata CSV set (SRREVAMP_LEVELDATA_CSV) -- characters will not level` in its log.
Without items a weapon has no stats, so every hit was the floor band's 1; without leveldata a
kill pays nothing; without skills nothing can be learned. Every grounded formula in the server
was running on empty tables.

**What was done (all from the user's own Media.pk2, nothing from the repo).** `cmd/pk2list`
extracted the text tables on the render box; `export-refdata` produced 15,338 item rows and
33,698 skill rows, `export-leveldata` 140 levels. One correction along the way: the archive holds
more `itemdata_*`/`skilldata_*` parts than the client loads (124 against the 63 + 47 the index
files name), and the exporter keeps the *last* definition of a duplicated id, so the parts were
fed in the index files' own order rather than glob order (they differ: `1000, 2000, ...` against
`1000, 10000, 11000, ...`) -- 326 item and 290 skill ids conflict across parts and the client's
load order is the only defensible tiebreak. The CSVs now sit beside the pk2s on the render box
(the QA harness reads them from `PK2_DIR`) and in `~/srrevamp-data` on the VM; the raw extracted
tables were deleted. Items and skills were imported into Postgres (`items 15338, skills 33698`);
leveldata went in through the untracked `docker-compose.override.yml` as a read-only mount plus
`-leveldata-csv=/data/leveldata.csv`, with the base command restated because a compose override
*replaces* `command`. Boot log after: `loaded EXP curve path=/data/leveldata.csv maxLevel=140`.

**Measured, against the public server, from the render box.** A fresh level-1 china_man QA
character (`SRREVAMP_QA_SERVER=192.168.5.25:15779`, `--attack`, `QA_ATTACK_FAST`).

First attempt, booted at `--region 96\168.m`: the nearest monster was a **Yeoha** (249 HP, level
10) and the hits were 1-2 with the counter-blows 80-93. That is the floor band doing its grounded
job against a monster nine levels up, not a data failure -- and it exposed a QA trap: the client's
world frame is anchored on the region it boots with, while the server's frame is fixed on the
town, so booting one region south displaced every entity by a region. For `--server` runs, boot
`97\168.m` and address other regions through local coordinates past 1920.

Second attempt, `--region 97\168.m --at 130,2280` (the real Mangyang spawn, npcpos region 24744
local 1089.65/600.09 in the server's frame): **hits of 12-14, 26 on a crit; a Mangyang dead in
four; five kills in the run**. The character's row afterwards, read from Postgres:

| character | level | exp | gold | str/int | stat points | hp |
|---|---|---|---|---|---|---|
| DataProbe (first run, no kill) | 1 | 0 | 1000 | 20/20 | 0 | 80 |
| DataProbe2 (after five kills) | **2** | **3** | **1267** | **21/21** | **3** | **185** |

Five kills at level 1's 24-exp unit is 120 against a 118-exp threshold: level 2 with two or three
over, which is what the row says (the per-kill amount and the last point's rounding are the
combat lane's to reconcile, not this one's). EXP, levelling, stat growth and gold all move on the
public server now.

**Shipped in code.** One boot log in `cmd/server/main.go`: `reference data in PostgreSQL
items=N skills=N monsterDrops=N dropGroupEntries=N`, and a WARN when `items` is 0 that names the
recipe -- the EXP curve already warned; the tables did not, which is how a week went by.
`deploy/README.md`'s reference-data section is rewritten as the recipe actually run (it had
covered items only and still spoke of a flat "5"); `docs/HANDOFF_OPENSRO.md` points at it.

**Not this lane's, seen in passing.** (1) A fresh character's first HP reading was 107 after a
93 blow, so it started at 200, but after dying it respawned at 80 and later at 185 as level 2 --
the spawn-time HP looks like the old 200/200 placeholder where the respawn uses the grounded
formula. (2) Drops: with `monster_drops` and `drop_group_entries` empty the loot roll has nothing
to roll; the real tables are DB-only and the server package on the render box has no shard
backup (`smc.bak` is the manager DB), so "items don't drop" stays a mechanic-and-content question
for the drops lane. (3) Two QA characters (`DataProbe`, `DataProbe2`, account `qa-data`) now
exist on the public server; harmless, deletable.
