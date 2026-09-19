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
| 3 | 8 | `0` ×188, `5000` ×57, `500` ×31, `40000` | **fee** — use-site read 2026-09-19 (below) |
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

## The fee, read at its use-site (2026-09-19)

`FUN_00513590` (`0x00513590`, 1,227 bytes) is the teleport-use handler: it reads a
kind byte and a destination **index** out of the message, and for kind 2 (a link):

```
piVar5 = FUN_00485d60()                     ; the gate's link for that index
                                            ;   (FUN_004884c0: links[index] from gate+0x3c/+0x40;
                                            ;    the gate's ref object must be a teleporter, ref+0x190 != 0)
if piVar5 == 0 or piVar5[0] == 0: refuse 2  ; no such link
fee = piVar5[1]                             ; THE FEE
if level (PC vtable slot 74) < 21: fee = 0  ; waived for low levels (a second `< 11` test is redundant)
if gate flag (vtable slot 276): fee += FUN_00486390(fee, 0)   ; a surcharge on top -- unread; the siege
                                                             ;   tax by context, labelled an inference
if gold (inv+0x7c:+0x78, 64-bit) < fee: refuse 0x1c07        ; NOT_ENOUGH_MONEY, the repair code
CGObjPC::FUN_004e0a40(...)                  ; set the teleport state; the trip proceeds
```

So the link's fee is the value compared against the character's gold and refused
with `NOT_ENOUGH_MONEY` -- a use-site, not a shape. The runtime link is the
record the generic schema reader fills (there is no `CRefTeleLink::ExtractData`;
its vtable's nine slots are GetClassName, the destructor, the two table-name
getters and five shared base implementations), and `piVar5[1]` is its second
word after the target: **column 3 is the fee.** What is NOT read is the
row-to-runtime copy in `RefInstanceGenerator`, so the column number rests on
the reader filling fields in text order plus this being the only gold-valued
column; the fee's *meaning* is settled.

**The other refusals on this path:** `0x1c14` is `GObjPC::FUN_004a8e10`, a
per-kind interaction-range test (distance constants including the 10.0 at
`0xb45b44`), i.e. too far from the gate; `0x1c0f` is `FUN_00486a40`, the
destination index outside the gate's 28-byte link list; `0x1c21` an empty
selection; `0x1c31` a state-byte value of 30.

**Columns 8/9 (the level range) stay inferred.** No comparison of the level
against a link field appears on this path -- the only level rule here is the
fee waiver below 21 -- so if the restriction columns are enforced, it is
elsewhere (`FUN_00485d00`, which fails with code 3 before the switch, is the
unread candidate) or client-side in the destination list.

## The columns' structure, from the client's own parser (2026-09-19)

`GlobalDataManager::RefParse_teleportlink` (`sro_client.exe`, `0x00976c80`) reads
a row as sequential tokens: five direct fields to `+0x8, +0xc, +0x10, +0x14,
+0x18`, then **five triples stored column-major** -- `(type_k, data_k_1,
data_k_2)` to `+0x1c+4k`, `+0x30+4k`, `+0x44+4k` for `k = 0..4`. That is the
shape the data shows: column 7 (`{0,1,2}`), 8 and 9 (the level-looking pair),
then 10 (`{0,1,2}`) again -- **restriction type, data, data, five times from
column 7.** So columns 8/9 are the first restriction's two data words; whether
its type value denotes a *level* restriction is what remains unread: the
client's teleport dialog (`UI_TELEPORT::FUN_006fd3e0`, `0x006fd3e0`) formats
each destination with `UIIT_CTL_TELEPORT_FREE_RESULT` when the entry's fee word
is 0 and `UIIT_CTL_TELEPORT_RESULT` (with the fee) otherwise, and compares a
byte at `entry+6` against a level-shaped value -- but those entries are the
**server's list reply**, so the gate is applied when the server builds that
list. *Next probe:* the server's reply to a gate talk (the list builder), or
the list packet's layout on the client side of that same function.

One more structural fact (2026-09-19): the runtime link vector hangs off the gate's
`CRefTeleport` ref object (`ref+0x190`, vector at `+0x3c/+0x40`), and a link's first
word is a **pointer to the destination `CRefTeleport`** (`CGObjNPCNPC::Create` reads its
code name through it -- the `GATE_TD` special case) with the fee second; the pass that
builds those links from `_REFTELELINK` rows is not among `RefInstanceGenerator`'s named
helpers and is unread.

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
