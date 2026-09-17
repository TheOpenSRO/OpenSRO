# The teleport network

Three real tables describe every gate in the game and how they connect. srrevamp
has no teleport system at all, and this is what one would be built from.

**All three came out of `Media.pk2` this pass.** Only `teleportdata.txt` had been
extracted before; `teleportlink.txt` and `teleportbuilding.txt` were in the
archive all along under `server_dep\silkroad\textdata\`. Worth noting as a
method: the server-side `_REFTELELINK` table looked like a dead end because no
file had been extracted, and the file existed.

## `teleportdata.txt` — the points

**222 enabled rows, 14 columns.** Every gate, with its position.

| col | meaning | example |
|---|---|---|
| 0 | service | `1` |
| 1 | teleport id | `1` |
| 2 | codename | `GATE_CH`, `GATE_NPC_CH_FERRY`, `GATE_KT` |
| 3 | **building object id** | `2094` — joins `teleportbuilding` |
| 4 | zone-name string id | `SN_ZONE_22001` |
| 5 | **region id** | `25000` |
| 6, 7, 8 | local x, y, z | `969, 0, 1369` |
| 9 | radius | `70` (85 rows), `10`, `150`, `200`, `50`, `30` |
| 10-12 | flags | |

**The positions decode, and that is checked rather than assumed.** Using this
project's own region transform — `regionId = (x << 8) | y`,
`serverX = (ry*1920 + localX) - 323562`, `serverZ = (rx*1920 + localZ) - 187260`:

	GATE_CH   region 25000 (97/168) local(969, 0, 1369)  ->  server(-33, 349)

Region 97/168 is Jangan, and the server origin is Jangan's own spawn point, so
the Chinese main gate lands **33 units west and 349 north of the town spawn** —
where the gate is. A table decoded with a transform derived from unrelated
evidence (terrain edges and minimap tiling) landing on the right spot is the
confirmation.

117 distinct regions carry a teleport point. One row (`GATE_NPC_CH_KISAENG6`)
has region 0 and is a placeholder.

## `teleportlink.txt` — the edges

**292 enabled rows, 23 columns.** A directed graph over the points above.

| col | distinct | shape | reading |
|---|---|---|---|
| 1 | 169 | teleport ids | **source point** |
| 2 | 157 | teleport ids | **destination point** |
| 3 | 8 | `0` ×188, `5000` ×57, `500` ×31, `40000` | **cost** — inferred |
| 7 | 4 | `2` ×174, `1` ×81, `0` ×36 | a kind |
| 8, 9 | 10, 3 | `110`, `999`, `0` | **level range** — inferred |
| 10 | 4 | `2` ×71, `1`, `0` | a flag |

**Cols 3, 8 and 9 are INFERRED, not proven.** The shapes are strongly
suggestive — col 3 holds round gold amounts and teleporting costs gold; `110` is
the level cap and `999` reads as "no limit" — but this project's rule is that a
use-site settles meaning, and none has been read. *Next probe:* the consumer of
`_REFTELELINK` in the server (loader at `0x0082d770`), which is what would turn
these into grounded columns.

Cols 1 and 2 are safe: 169 sources and 157 destinations over a 222-point table
is a graph, and nothing else fits.

## `teleportbuilding.txt` — the gate objects

**77 enabled rows, 59 columns.** The physical gates: `2094 STORE_CH_GATE`,
`2095 STORE_WC_GATE`, `2096 STORE_KT_GATE`, `19554 STORE_EU_GATE`.

**The join is confirmed by a shared id**: `GATE_CH` in `teleportdata` carries
building object `2094`, and `teleportbuilding`'s first row is id `2094`,
`STORE_CH_GATE`. The `STORE_` prefix is the same family the shop chain uses, so a
gate is an NPC you talk to.

## Also extracted, unread

`refoptionalteleport.txt` (6,204 bytes) — the counterpart to the
`_REFOPTIONALTELEPORT` table in the server's catalogue.

## What srrevamp could build from this

The points are grounded and positioned, the graph is real, and the gate NPCs
join to the existing NPC machinery. A teleport system built on these three
tables would be as grounded as the monster spawns are — the same shape of
recovery, from the same kind of table.

What it could **not** yet claim is the cost and the level gate, until the
`_REFTELELINK` consumer is read.
