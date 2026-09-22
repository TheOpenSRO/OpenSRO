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
if gate flag (vtable slot 276): fee += Fortress_TaxRatioAsFloat()  ; the fortress TAX -- READ, round 321
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

## The client's list, read (2026-09-19, second pass)

The earlier guess that the dialog's entries were "the server's list reply" was wrong.
`UI_TELEPORT::FUN_006fd3e0` (`0x006fd3e0`) builds the destination list from the
**client's own link records**: `UI_TELEPORT::FUN_009767b0` gives the count for the
current gate, `GlobalDataManager::FUN_00976a30(k)` selects link *k*, and for each it
allocates a 0x18-byte list item, numbers it `"%d. %s"`, and formats the name with
`UIIT_CTL_TELEPORT_FREE_RESULT` when the link record's word at `+0x10` is 0 and
`UIIT_CTL_TELEPORT_RESULT` with that word (through the thousands formatter
`FUN_006fc910`) otherwise. `+0x10` is the third direct field of `RefParse_teleportlink`
-- **column 3, the fee** -- so the client agrees with the server's use-site
(`FUN_00513590` above): two binaries, neither consulted about the other.

**Nothing in the dialog reads the restriction triples** (`+0x1c..`, `+0x30..`,
`+0x44..`), and the byte at `entry+6` is not a level: it is set only when the gate's
code name is `STORE_TOMB_GATE_IN` (the string at `0xdaddb8`, read from the image),
to the item's ordinal *k*, and the item is greyed (`entry+0x14 = 0`, colour
`0xff969696`) when the player byte at `+0x20ff` is 0 or less than *k*. That byte is
**sent by the server**: the NPC-talk reply handler `NetProcessInInterface::FUN_0088b200`
stores one payload byte there when the talked-to gate is `STORE_TOMB_GATE_IN` (and
reads a 2-byte payload for `STORE_DESERT_MERCHANT_HUNTER_GATE` / `STORE_DESERT_THIEF_GATE`,
`0xdae620`/`0xdae5f0`). So the tomb entrance's per-floor gating is a per-player count the
server hands the client at talk time -- a special case by gate name, not a link column.

The one level range the client's gate code does display, `UIIT_STT_GOD_LV_EXTENT`
(`CITeleportGate::vslot_025`, `0x009e9eb0`: `"%d - %d"` from `+0x2bc`/`+0x2c0`, a class
switch on `+0x2b4`), is formatted from the gate STRUCTURE's own object record
(`GlobalDataManager::FUN_0093f5f0` -> `RefData_usableresobjiddata`), not from a
teleport link.

**Where that leaves columns 8/9:** no consumer in the server's use handler, none in
the client's dialog, none in the client's gate object. Either the restriction triples
are applied when the server BINDS links at load (`RestrictBindMethod` would be the
name for it, if the DB column names match the client parser's shape -- the server's
`_REFTELELINK` binder keeps its column names in a static descriptor table, so they are
not greppable in the dump), or these builds do not apply them to ordinary gates at all.
srrevamp does not consume them. *Next probe:* the pass that fills a `CRefTeleport`'s
link vector from `CRefTeleLink` rows (the runtime link's first word is the destination
ref pointer, its second the fee); a read of the triples there would settle it.

One more structural fact (2026-09-19): the runtime link vector hangs off the gate's
`CRefTeleport` ref object (`ref+0x190`, vector at `+0x3c/+0x40`), and a link's first
word is a **pointer to the destination `CRefTeleport`** (`CGObjNPCNPC::Create` reads its
code name through it -- the `GATE_TD` special case) with the fee second; the pass that
builds those links from `_REFTELELINK` rows is not among `RefInstanceGenerator`'s named
helpers and is unread. (Round 271 checked the unnamed ones: `0x6f6ad0/6c40/6cb0/6e60/6ef0/6f60/6fd0`
and `0x6bef30/6c0950/6c55d0/6c7590/6d1b30` are `std::map` insert/find template instantiations
attributed to the namespace, not binders; the 0xe0-byte parser that carries a `TELEPORT` string
(`0x6a7650`, 6 columns) is a different table. The binder is still unread.)

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


## The gate surcharge is the fortress tax, and it is now read (round 321)

This page inferred it from context and said so. `Fortress_TaxRatioAsFloat`
(`0x00486390`) is a 36-byte wrapper over `Fortress_TaxRatioForActor`
(`0x004862a0`), which:

- looks the fortress up with `AQ_Siege::FUN_00456e20` from the object's
  association at `+0x148`, and reads a **short at `fortress[4] + 0x20`** -- the
  `TaxRatio` a guild master sets through `FUN_0062f640`, accepted range
  **-20..+20** (`docs/protocol/siege.md`);
- returns a **negative ratio unchanged** (`if (rate < 1) return rate`), which
  agrees with that page's separately read "a negative tax is legal" -- two
  independent readings meeting;
- returns **0** when there is no association, when the lookup fails, and on two
  membership tests (`GObjPC::FUN_0061d280` against `FUN_005e4390`, and
  `GObjPC::FUN_0061d300`).

**The exemptions' identity is NOT read.** By position they are the owning guild
and its alliance, and that is exactly the kind of by-position reading this
project has had to walk back before, so it stays an inference here.

One correction to the transcription above: the decompiled `FUN_00486390(fee, 0)`
signature is the decompiler's guess. The callee takes the object in EAX and the
actor in EBX and takes no stack arguments.

## Two columns of `teleportdata.txt` are interaction registrations (round 454)

`_RefTeleport`'s parser (`CGameServer::RefTeleport_ExtractData`, `0x6a7be0`) is
recorded in `refdata_tables.md` with 13 columns and the read sequence
`dd S d wwwww bb w b`. **The `bb` pair — columns 9 and 10 — are not data the
gate uses at runtime. They are registrations.** After parsing, the loader looks
up the ref object the row is associated with (failing with
`"can't find associated ref obj with this teleport[tel id: %s]"`) and, for each
flag that is set, inserts an **NPC interaction id** into that object's set at
`record + 0x90`:

	if (col 9  != 0)  insert id 7 into assocRefObj + 0x90
	if (col 10 != 0)  insert id 9 into assocRefObj + 0x90

with `+0x30` holding the associated object and the insert going through the same
`set<byte>` helper the rest of the interaction machinery uses
(`docs/protocol/character_state.md`).

**So these two columns say "this object offers teleport service 7" and
"…service 9".** Which service each of 7 and 9 *is* was not read and is not
guessed here: neither id has an explicit gate anywhere in the server, so both
fall to the `default` arm of the `0x046` switch, and no reader distinguishes
them. What is settled is that the columns are booleans controlling two distinct
offered services on the gate object.

This is the first grounded example of **where interaction ids come from**: a
refdata loader registers them on a ref object from boolean columns at table-load
time.
