# The teleport network

Three real tables describe every gate in the game and how they connect. srrevamp
builds its town teleporters from them (rounds 575 to 577, "What srrevamp built"
below).

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
| 3 | **associated object id** | `2094` — joins `teleportbuilding` for a gate; an NPC for a ferry (`2011` `NPC_CH_FERRY`); `0` in 118 rows |
| 4 | zone-name string id | `SN_ZONE_22001` |
| 5 | **region id** | `25000` |
| 6, 7, 8 | local x, y, z | `969, 0, 1369` |
| 9 | radius | `70` (85 rows), `10`, `150`, `200`, `50`, `30` |
| 10, 11 | interaction flags | registrations of interaction ids 7 and 9 (round 454, below) |
| 12 | a small integer | `1` ×153, up to `170`; the client's parser never reads it; unread |

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
| 4, 5, 6 | 1 each | `0` in all 292 rows | unread |
| 7 | 4 | `2` ×174, `1` ×81, `0` ×36, `4` ×1 | **restriction 1's type** — use-site read, round 575 |
| 8, 9 | 10, 3 | `110`, `999`, `0` | **restriction 1's two data words** (type 1: a level range) |
| 10..21 | | | restrictions 2-5, (type, data, data) each |

**Cols 3 and 7-21 are READ (round 575); cols 8 and 9 are not a level range
by themselves.** Col 3 is the fee (the use-site below). Cols 7-21 are five
(type, data, data) restriction triples, and the server's evaluator
`FUN_00513a70` walks them: type 1 compares the character's level with the two
data words, so a `(1, 1, 110)` triple is a level range and a `(2, 0, 0)` one is
a trade-cart rule -- "The restriction triples are enforced" below. (Until
round 575 this paragraph called cols 3, 8 and 9 INFERRED and sent the next
probe to the `_REFTELELINK` loader at `0x0082d770`; the consumer turned out
to be the evaluator, found from its error code.)

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

**The other refusals on this path:** `0x1c14`
(`UIIT_MSG_INTERACTION_FAIL_TELESCROLL_ALREADY_WORKING`) is the FIRST test:
`IGObj::GetTeleportState` (vslot 72, `+0x120`, the call at `0x513634`) returning
non-zero -- a teleport already under way. The interaction-range test is the
next one, `GObjPC::IsWithinInteractionRange` (`0x4a8e10`; distance constants
including the 10.0 at `0xb45b44`), and the handler refuses with ITS return
value -- `4` beyond the distance, `0` or `3` on its early exits, `1` passing --
not with `0x1c14`. (Until round 575 this said `0x1c14` was the range test;
round 575 re-read `0x513590`: `mov eax,[edx+0x120]` then `0x1c14` at
`0x513642`, before the range call.) `0x1c0f` is `FUN_00486a40`, the
destination index outside the gate's 28-byte link list; `0x1c21` an empty
selection; `0x1c31` a state-byte value of 30.

**No level test against a link field is on this path** -- the only level
rule here is the fee waiver below 21. The restriction columns ARE enforced,
on the other teleport path: see "The restriction triples are enforced" below
(round 575; until then this paragraph left columns 8/9 inferred).

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
`UIIT_CTL_TELEPORT_RESULT` with that word (through `FUN_006fc910`) otherwise.
**`FUN_006fc910` is not a formatter** (round 578's review, re-read in
`/var/tmp/decomp_client`): called as `FUN_006fc910(fee, 0, 1)`, it returns a 64-bit
`fee + share`, the share computed through `FUN_00b42d46` from a short at
`this+0x804` (added when `param_4` is 1, subtracted when 0); the sum is printed with
`%d`. So the retail list shows the fee **plus a surcharge** from that short, whose
meaning is unread (a fortress-tax-shaped rate is a guess, not a reading). srrevamp's
board shows the raw link fee -- the same number while that short is 0, which is all
srrevamp has (no fortresses). The dialog uses `UIIT_CTL_TELEPORT_RESULT` and
`_FREE_RESULT` only; `UIIT_CTL_TELEPORT_RESULT_IMPROVE` (`[%s]gold`, a string
argument) is in `textuisystem.txt` but `FUN_006fd3e0` never asks for it -- not a
drop-in for the board's price line. `+0x10` is the third direct field of `RefParse_teleportlink`
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

**Superseded in round 575** -- the consumer is the server's evaluator
`FUN_00513a70`, "The restriction triples are enforced" below. What this
paragraph said then: **Where that leaves columns 8/9:** no consumer in the server's use handler, none in
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
`STORE_CH_GATE`. The `STORE_` prefix is the same family the shop chain uses, and a
gate is talked to the way an NPC is -- but it is **not an NPC**: no npcpos row
names a teleportbuilding id (the join of npcpos's NPC ids with the building ids is
empty), so nothing places a gate as a character. The structure the player clicks is
a placed map object, and the building row's position finds it: "The clickable gate
(round 577)" below.

## Also extracted, unread

`refoptionalteleport.txt` (6,204 bytes) — the counterpart to the
`_REFOPTIONALTELEPORT` table in the server's catalogue.

## What srrevamp built

The points are grounded and positioned, the graph is real, and the cost and the
level gate are read: the fee at its use-site (2026-09-19) and the restriction
evaluator (round 575, below). srrevamp loads the three tables since round 575
(`internal/teleport`, cmd/server's `-teleport-dir`), and since round 576 a gate's
MOVE is charged and moved by them. Since round 577 the client reads them too
(`TeleportReader`): each town's Dimensional Gate is clickable and lists its lines
("The clickable gate (round 577)").

### srrevamp wire: OpTeleportUse / OpTeleportResult (round 576)

srrevamp's own placeholder pair (`docs/protocol/PROTOCOL_DECISION.md`), free on
2026-09-26 (the highest op in `server/internal/session` and `client/scripts/net`
was `0x00F2`, `OpGMCommandResult`):

| op | direction | payload |
|---|---|---|
| `0x00F3` `OpTeleportUse` | client -> server | u16 gate, u16 destination -- both **teleportdata ids** |
| `0x00F4` `OpTeleportResult` | server -> the requester | u8 ok, u16 code, u8 waiver, u64 gold charged, string destination (the point's `SN_ZONE_*` token), string reason |

On success the server then sends an ordinary `OpChangeZoneResult` (0x0027, its
layout untouched), and everyone left behind gets `OpEntityLeft` and everyone at
the destination `OpEntityEntered` -- the zone change's own arrival, factored out
of `handleChangeZone` as `session.warpTo`. The client marks the change-zone
result that follows an accepted receipt as the teleport's arrival
(`World3D._on_teleport_result`), so it reloads behind the loading screen as any
zone change does, but keeps the server's position (below).

**The order is the engine's where it has one** (`session.teleporter.use`): the
character in the world and alive; the gate point, which must belong to a
teleportbuilding row (a ferry's object is an NPC, so a ferry point is not a gate);
the link (`teleport.Table.LinkBetween`) -- refused with the engine's own code `2`
when there is none, `GObjPC::HandleTeleportUse`'s `uStack_2c = 2` at `0x513910`;
the link's restrictions (`teleport.CheckRestrictions`, run before the fee as on
`CMainProcess::FUN_004f2b50`'s path, call `0x4f2e24`) with the PvP state passed as
NEUTRAL (srrevamp models none -- a stand-in; no retail link has a type-3 rule);
the fee and its waiver (`teleport.QuoteFee`: below level 21 the engine's, then a
GM account and `-teleport-free`, own design); the charge, refused `0x1c07` with
nothing moved -- `HandleTeleportUse` refuses on the gold compare (`0x513749`)
before it sets the teleport state; then the receipt and the move.

**The arrival spot is an inference, disclosed.** A destination row carries one
position, its teleportdata point (region + local x, y, z + radius), and srrevamp
lands the player there: `worldmap.ToWorld(region, x, z, frame)` at height 0, which
the client replaces with its walkable graph's landing height at that point
(`World3D._land_teleport_arrival`). The retail completion stage
(`CGObjPC::vslot_309` `0x4ef480`, `CMainProcess::FUN_004f2b50`) was not read, so
whether retail lands on the point, scatters within its radius, or uses another
position is not known. It is not the gate structure's point: in Jangan building
2094's row puts `STORE_CH_GATE` at 97/168 local (1254, -6, 1374), 285 units east of
GATE_CH's point (969, 0, 1369) (both rows read on the box, round 576). The portal
model stands at the building's point -- `cj_portal.bsr` at (1257.14, -33.00,
1375.71), 3.6 units from it in x/z (the heights differ by 27), with nothing placed
within 60 units of GATE_CH's point -- by the item's verifier's `whatishere` run on
2026-09-26, not re-run in round 576.

**The zone label** is own design (`session.teleportZoneFor`): the town whose
centre (`worldmap.ZoneCentre`) is the point's region -- Jangan, Donwhang, Hotan,
Constantinople, whose gates stand in their centre regions since round 569 --
else a town whose centre is one region away (Samarkand: GATE_CA is in 106/108,
its centre 106/107; the client's radius-2 grid holds the neighbour cell), else
the region's own "x/y". The position is named in that label's frame
(`FrameRegion`), which is `worldmap.WorldOrigin`'s under `-single-frame`. A
dungeon point (a negative region) is refused: worldmap has no frame for one.

**The client keeps the point.** A Jangan arrival is not moved on to the town
square (`ZONE_SPAWN_LOCAL`) as every other zone change is; the player is stood on
the walkable graph at the point, and held there -- no walk, no fall -- while the
point's region is still queued behind the loading screen (Samarkand), then
released to the ordinary ground snap if no graph ever appears.

**The retail pair, for the record, not copied.** The request is `0x705a`, written
by `CIF_NPCTalk::FUN_0081ddf0`: `{u32 gate object, u8 kind, kind 2: u32 target}`
(its log line `"TELEPORTGATE -> Type(%d), Target(%d)"`). The reply `0xb05a` is
read by `FUN_008809d0`, which `FUN_0086fbb0` registers for `0xb05a`: a u8 result,
and on 2 a u16 code passed to `FUN_00778190(0xd, code, ...)` -- category `0xd`,
the interaction message table, where `0x1c07`, `0x1c10` and `0x1c15` have
messages (`client/scripts/net/error_text.gd`). srrevamp's client shows those three
in the archive's words, our own wording for `2` (category `0xd` sends it to the
default, no message), and the server's words for its own refusals (code 0).

**Not modelled, disclosed:** the interaction-range test (retail's
`GObjPC::IsWithinInteractionRange` `0x4a8e10` was not read into a distance; the
client offers a gate's destinations only after a click on the gate, and closes
the board and the gate's talk box on every zone change -- `World3D._close_gate_ui`,
round 578's review -- so a gate's links are not offered from another zone. Walking
away from a gate inside the same zone does **not** close them: that distance is the
same unread `0x4a8e10`, so the client does not guess one either), the
"already teleporting" state (`0x1c14`: a srrevamp teleport completes inside one
request), the fortress tax (no fortresses), and the retail receipt line's source
(the client shows `UIIT_CTL_TELEPORT_RESULT` / `_FREE_RESULT` from its own
archive, choosing the free one when nothing was charged -- the retail dialog's
own choice on a zero fee word, `UI_TELEPORT::FUN_006fd3e0`).

### The clickable gate (round 577)

The client binds each gate structure to the object the player sees and gives it
the gate's talk lines. `TeleportReader` (`client/scripts/npc/teleport_reader.gd`)
reads the three tables out of the player's own Media.pk2 -- the columns in "The
columns srrevamp reads" below, the same ones the server's exporter reads -- and
`World3D._bind_region_gates` runs when a region's NPCs are placed, after its
objects commit, and again when a streamed-out region comes back.

**Only the town gates are bound: points that register interaction id 7.** A
teleportbuilding row is bound only when the teleportdata point that names it has
column 10 = 1 (id 7, the designate registration, round 454). This is a rule read
off the table, not the client's own selection: joining the retail tables
(teleportbuilding column 3 against teleportdata column 3, serviced points,
region > 0) gives 61 building rows in a world region, and exactly 7 of them carry
the id-7 flag -- `STORE_CH_GATE`, `STORE_WC_GATE`, `STORE_KT_GATE`,
`STORE_EU_GATE`, `STORE_CA_GATE` and Alexandria's `STORE_SD_GATE1`/`STORE_SD_GATE2`.
The other 54 are left alone: the fortress, charge, glory and revival gates
(`STORE_JA/CH/BD/BJ/KT/HT_FORT_GATE*`, ...), the tomb, desert, delta and
Tahomet/Roc gates, the rows named `STORE_SURVIVAL*`, `STORE_TOGUI_TRADEROUTE_*`,
`STORE_ARABIAN_*`, `STORE_BAGHDAD`, `STORE_GARDEN_DUNGEON`, `STORE_PALACE` and
`STORE_SOLO_STR` (`STORE_SURVIVAL_DW` stands in Donwhang's 102/153 at local
(621, 320) with 14 outgoing links), and `STORE_TD_GATE` (id 9 only). Nothing ties any of those rows
to a placed object, and binding them (the first cut of round 577) made whatever
scenery stood within 10 units a talk target, or put a stand-in collider at the
point.

**The binding rule is a disclosed stand-in.** For each such row, the nearest
placed object (x/z, region-local) within 10 units of the row's point is taken as
the gate. Nothing read ties a building row to a placed object. The rule rests on
the placements, measured by the client's own bind lines in one run per town on
the render box (round 577; Alexandria's two gates were not run):

| gate | region | bound object | x/z from the point |
|---|---|---|---|
| `STORE_CH_GATE` Jangan | 97/168 | `cj_portal` (`cj_portal_stone` at 7.5) | 3.6 |
| `STORE_WC_GATE` Donwhang | 103/153 | `w_cd_portal` | 3.3 |
| `STORE_KT_GATE` Hotan | 92/135 | `oas_hot_portal` | 0.7 |
| `STORE_EU_GATE` Constantinople | 105/79 | `euro_esteuro_fountain01` | 2.6 |
| `STORE_CA_GATE` Samarkand | 107/107 | `samarkand_center_01` (its piece `samarkand_potal_03` took the click) | 1.0 |

Four of the five model names say portal. Constantinople's is a fountain, and
whether retail's gate there is that model is **not established**: it is the object
the rule picks, and a click on it opens the gate's talk window. The copy placed in the world gets the tags an NPC holder carries
(`npc_name` from the building's name string through textdata_object --
`SN_NPC_CH_GATE` is "Dimensional Gate" -- `npc_code` `STORE_CH_GATE`,
`gate_point_id`), and the talk ray's layer is OR-ed into every piece body under it.
The shared template in `ObjectTemplateCache` is never touched. When no object is
within 10 units, the gate is **left unbound** -- not clickable -- and the log says
so. There is no stand-in collider: the talk layer is the navmesh-wall bit
(`NPC_COLLISION_LAYER`, 0b10000), which the player's body masks
(`collision_mask = 17` in World3D.tscn), so any body put there is a wall where
retail has none. Measured on the render box (radius 0, 102/153 at (621, 330),
`SRREVAMP_QA_CLICK=gate`): the first cut printed `teleport gate STORE_SURVIVAL_DW
-- no placed object within 10 units ... a stand-in collider was used (cylinder
r=5 h=30 at local y -103.46)`; with the id-7 rule the region prints no gate line
and the click finds no target. Jangan's gate still binds (`Obj_cj_portal_312`, 3.6
units) and its on-screen click (640, 405) opens the three lines.

**What the click runs measure.** Jangan's (640, 405) and Donwhang's (640, 313)
clicks were on-screen. The QA click aims at the middle of the bound object's whole
drawn box, and for Samarkand (640, -1013), Constantinople (640, -1838) and Hotan
(640, -34) that point was outside the 1280x720 frame: those runs prove the tag,
the layer and the talk path, **not a click a player could make there**. The QA log
now marks such a point `OFF-SCREEN`.

**Every piece of the bound object is talkable.** The layer goes on every piece
body under the object, and the talk ray runs before the walk ray. Samarkand's bind
covered all 10 piece bodies of `samarkand_center_01`, Constantinople's 7 of the
fountain; if those composites hold walkable plaza, stair or wall pieces, a click
meant to walk there opens the gate window instead. Not measured. The hover
cursor over a gate is the talk cursor (`_hover_kind_at`), not `CursorSet.ID_GATE`;
wiring the gate cursor is left to the board.

**The lines follow the client's menu.** `FUN_00700440` asks for id 7 (`0x700c57`,
item 9), then id 9 (`0x700ca7`, item 0x10), then id 8 (`0x700cfb`, the
desert-gate company lines, then item 0xa). `FUN_006fcd60`'s switch pushes
`UIIT_CTL_RECALL_POSITION` for item 9 (`0x6fcf10`), `UIIT_CTL_TELEPORT_TO_RESURRECT_POS`
for 0x10 (`0x6fcf1a`) and `UIIT_CTL_TELEPORT_TARGET` for 0xa (`0x6fcf24`), all read
as UTF-16 out of `sro_client.exe` (`NpcServiceReader.gate_services`). Ids 7 and 9
come from teleportdata columns 10 and 11. **Id 8 does not have a table to read:**
its registrar (`0x6a7f70`) reads a table this project has not attributed
(`character_state.md`, "One discrepancy left open"), so "the gate's point has an
outgoing link" stands in for it, disclosed. Whether a gate also offers id 2 ("Talk
to this person.") is not read, and srrevamp does not offer it. A town gate
(columns 10/11 = 1, 0, with links) therefore lists the designate line, the
teleport line and the end line. The text is whatever the player's
textuisystem.txt resolves. `UiTextTable` keeps the later 19-column rows ("Designate
as return/recall point", "Select teleport area"), not the earlier 16-column rows'
"Designate this region as your return & recall point!" / "Select a teleport area:".

Since round 603 "teleport" lists the gate's destinations in the talk box itself ("The
destination list (round 603)" below; round 578 opened a separate board). The two recall lines still say "... is not available yet"
(`World3D._on_npc_service_selected`'s default): srrevamp models no return point.
`SRREVAMP_QA_CLICK=gate` clicks the nearest bound gate through the real
dispatcher.

### The destination list (round 603)

**The retail client has no teleport window.** Its talk box lists the destinations in place
(read in `sro_client.exe`; the full record is `docs/RE_COMPLETION.md`, round 603):

- `CIF_NPCTalk::FUN_007020c0`, the talk box's click handler, switches on the clicked line's
  type. Type 10 is the line `FUN_006fcd60` labels `UIIT_CTL_TELEPORT_TARGET`. With sub-type 0 it
  calls `UI_TELEPORT::FUN_006fd3e0` on the talk box (`call 0x6fd3e0` at `0x702973`), passing a
  counter set to 1.
- `FUN_006fd3e0` clears the box's list and adds the box's own current text back on top
  (`FUN_006fb530` with `this+0x7d4`: that text, then a line of two spaces). For each of the
  gate's links in the client's own order, it adds a line `"%d. %s"` of type 10, sub-type 1, which
  carries the destination. The `%s` is `UIIT_CTL_TELEPORT_FREE_RESULT` or
  `UIIT_CTL_TELEPORT_RESULT` ("The client's list, read", above). Last comes
  `FUN_006fcd60(n, 0, 0)`, the box's own end line, numbered next.
- A click on a sub-type-1 line sends at once: `push 2; push [line+0xc]; push npc; call 0x81ddf0`
  (`0x70293d..0x702946`). `0x81ddf0` logs `"TELEPORTGATE -> Type(%d), Target(%d)"` and writes
  request `0x705a`. There is no confirmation, no Move button and no paging, and the click path
  does not close the talk box: the two calls after the send, `0x6f74a0` and `0x6f74c0`, only
  store zeros.
- `ifteleportboard.txt`, `ifteleportareaslot.txt`, `CIFTeleportAreaSlot`, `GDR_TB_`/`GDR_TAS_`
  and `tpt_window` are in neither the exe's ASCII nor its UTF-16 strings, and no `.2dt` of the 42
  is a teleport window.

srrevamp now does the same. The gate's 'Select teleport area' line rewrites the talk box
(`HudPanels.open_teleport_list`, `TeleportBoard.list_lines`). The box's own text stays on top,
followed by a blank line, one numbered line per link in file order, and the end line. A click on
a destination line is `OpTeleportUse` (srrevamp's wire, round 576). The talk box stays up and
closes on any zone change. The fee, the place, the level-waiver display and the one-request
guard are as in round 578 (below), and the guard is srrevamp's own: the retail click path sends
through `Net_SendRequestPacket(0x705a, 0)`, which marks nothing pending. An accepted reply keeps
the request pending until the arrival's zone change, since the list is still up between the two
(round 603's review). The server still serves a second request once the first has moved the
player; see `docs/TODO.md`, "Town teleporters". Not reproduced,
disclosed: the line colours (`0xffefdaa4` and `0xffff8a00`, `0xff969696` greyed; the talk box
draws every line in one colour), the tomb gate's greying, the surcharge, and the client-side
checks that end in messages `0x1c1c`/`0x1c1e`.

### The teleport board (round 578) -- superseded by round 603

The board below is gone. Its layouts are not in the exe, and the retail destinations are talk
lines (above). It is kept here as the record of what round 578 built.

The talk line opens the authored Dimensional Teleporter, `resinfo\ifteleportboard.txt`
(`HudPanels.PANELS["teleport"]`, `TeleportBoard`). Its five `CIFTeleportAreaSlot` controls
(`GDR_TB_TASLOT1..5`, `47,{105,185,265,345,425},357,76`) are each filled with
`resinfo\ifteleportareaslot.txt`'s section: `GDR_TAS_STATIC_PLACE` (70,14,182,21),
`GDR_TAS_STATIC_PRICE` (70,44,182,21), `GDR_TAS_BTN_MOVE` (252,20,92,36, `UIIT_CTL_MOVE`) and
an empty `GDR_TAS_STATIC_ICON`. `GDR_TB_SPIN_PAGE` (181,520,80,24) pages five at a time. The
rows are the gate point's links in file order -- the order `UI_TELEPORT::FUN_006fd3e0` numbers
them in -- with the link's fee (column 3). PLACE is the destination's zone name through
textdata_object (else its teleportdata codename); PRICE is the list format the retail dialog
chooses, `UIIT_CTL_TELEPORT_RESULT` with the fee, or `UIIT_CTL_TELEPORT_FREE_RESULT` when the
fee word is 0. srrevamp also shows the free format when the engine's level waiver applies (the
character's current level is 20 or less; the engine reads `GetMaxLevel`), which the retail
dialog does not -- own display, disclosed; the GM and testing waivers show only in the receipt.
Move sends `OpTeleportUse` with the board's gate; the board closes on the server's yes and on
any zone change, and stays up on a refusal. Not wired, disclosed: the board's window art
(`interface\teleport\tpt_window_zangan.ddj`, its use unread -- the layout has no frame of its
own), per-destination icons, the Move button's art (its layout names none), the `"%d. %s"`
numbering, the gate cursor. Measured on the render box: `docs/RE_COMPLETION.md`, round 578.

### srrevamp wire: FrameRegion (round 570)

A teleport lands a player in another town's coordinates, so both ends must
agree which region those coordinates are relative to. srrevamp's own
placeholder world results name it (`docs/protocol/PROTOCOL_DECISION.md`: own
scaffolding, not a retail layout). `OpEnterWorldResult` (0x0021) and
`OpChangeZoneResult` (0x0027) end with a **FrameRegion**: a u16 length, then
the "x/y" of the region whose middle is the world origin for the X/Y/Z in
the same result. It follows the entity list, which is where a client before
round 570 stops reading, so the result still decodes there. A payload that
ends at the list, from a server before round 570, means "" (no frame named),
and the client uses the zone's own centre, which is what the frame was.
Since round 573 an `OpEnterWorldResult` -- not an `OpChangeZoneResult` -- may
carry ONE more byte after the FrameRegion, **Restored** = 0x01, sent only
when the server's `-persist-position` (default off) read X/Y/Z back from the
character's row; a payload that ends at the FrameRegion means false, so every
other entry ends there as above (`session.EnterWorldResult.Restored`,
`docs/RE_COMPLETION.md` round 573; line added in round 574).

- Value: `worldmap.FrameFor(zone)`. That is `worldmap.ZoneCentre` for a named
  zone, the region itself for an "x/y" label, and "" otherwise. For every
  label it is the zone's own centre (the same region `World3D._resolve_zone_region`
  gives, which round 569 made agree), so naming it changed no coordinate's
  meaning.
- Client: `World3D._reload_zone_assets(zone, frame)` builds the grid around
  the zone's centre inside the named frame.
- A frame that is not the zone's centre is `-single-frame`'s (round 571,
  default off): the server then names "97/168" (`worldmap.WorldOrigin`) for
  every zone with a frame and sends `worldmap.Landing`, the middle of the
  zone's centre region named in that frame -- a position inside the centre
  region, since (0, 0, 0) would be the frame region's middle, off the
  client's grid. The drawn heights under that frame's anchor
  (`World3D._frame_anchor_height`, -2.49) were measured for every town and its
  radius-2 neighbours in `docs/RE_COMPLETION.md`, round 571.

The transform in the frame is `worldmap.ToWorld`: `x = (ry-fy)*1920 + lx-960`,
`z = (fx-rx)*1920 + 960-lz`. Region y drives world X, region x drives world
Z, and Z is mirrored. A point moved from the frame of 97/168 into that of
98/157 shifts by (+21120, +1920). `docs/RE_COMPLETION.md`, round 570, has
the evidence and the tests.


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
offered services on the gate object. **The client names them** (round 577): its
talk menu turns id 7 into item 9, `UIIT_CTL_RECALL_POSITION` ("Designate this
region as your return & recall point!"), and id 9 into item 0x10,
`UIIT_CTL_TELEPORT_TO_RESURRECT_POS` ("Teleport to your return point.") --
`character_state.md`, "Interaction id to menu item", rows 10 and 11, and "The
clickable gate (round 577)" below. What the server does when either is chosen is
still unread.

This is the first grounded example of **where interaction ids come from**: a
refdata loader registers them on a ref object from boolean columns at table-load
time.

## The restriction triples are enforced (round 575)

`FUN_00513a70` (`0x513a70`, 1,058 bytes; `error_emitters.tsv` lists it as the only
emitter of `0x1c15`) takes a runtime link and walks the 12-byte records between
`link+0x10` and `link+0x14` -- the (type, data, data) triples -- stopping at the
first that fails. It returns `1` when every rule passes (and the post-pass below
refuses nothing). The arms, with the IGObj
slots from `igobj_vtable.md`:

| type | test (0x513a70) | refusal |
|---|---|---|
| 1 | `IGObj::GetLevel` (vslot 73, `+0x124`) as a byte, **unsigned**: below data 1 (`jb` at `0x513b02`) or above data 2 (`jbe` at `0x513b07` skips the refusal) | `0x1c15` `..._OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT` |
| 2 | `IGObj::IHaveCart` (vslot 187, `+0x2ec`) returns 1 | `0x1c10` `..._CANT_USE_TELEPORT_WITH_TRADECART` |
| 3 | data 1 has the bit for the character's **PvP state**: `mov eax,[ebx+0x30]` (EBX is the PC -- each caller does `mov ebx,ebp` just before the call -- and `+0x30` is its chardata pointer), `mov cl,[eax+0xc]` (chardata `+0xc` is `PvPSTATE`: 0 `NEUTRAL`, 1 `ASSAULTER`, 2 `MURDERER`, `character_state.md`), `mov edx,1; shl edx,cl; test [esi+0x4],edx` at `0x513b46`-`0x513b53`, and `je` at `0x513b56` skips the refusal. So data 1 is a mask of barred states (bit 0 neutral, bit 1 assaulter, bit 2 murderer) | `0x1c19` (no row in `error_codes.md`) |
| 4 | data 1 != 0 and `CGStorage::FindItemHasSameRefObj(0xd, ...)` finds no item of ref object data 1 | `0x1c23` `UIIT_MSG_QUEST_ROC_CANNOT_ENTRANCE` |
| 5 | as 4; a found item goes on to `FUN_004d9030` (unread) | `0x1c23` |
| 6 | data 1 == data 2 == 0 and `IGObj::GetJobState` (vslot 71, `+0x11c`) != 4; other data asserts and passes | `0x1c24` (same token) |
| 7 | `CGStorage::GetItem(8)` returns an item whose vslot `0x41c` answers 1, and `IHaveCart` returns 1 | `0x1c10` |
| other, 0 included | no arm | passes |

A byte at `link+8` is the walk's mode, tested at `0x513ccf` after each rule and
at `0x513d35` after the last. At 0 the first failing rule returns its code. Any
non-zero value walks every rule and drops their failures (`local_38` is reset to
1 per rule); then 1 asserts (`call 0x964b60`) and returns `2` (`0x513d65`), and
any other value ends the way a clean walk at 0 does: the post-pass below,
returning `1` or `0x1c23`. The post-pass (`0x513d7d`) walks a byte vector the
function owns (begin at `esp+0x28`, freed before each return) -- the one whose
address the type-5 arm passes to `FUN_004d9030` in `eax` (`0x513c4b`), with the
address of the slot byte `FindItemHasSameRefObj` filled in `edi` (`0x513c18`,
`0x513c47`) -- and calls the character's vslot `0x230` per byte (`push 0 / 3 /
&one / 1 / byte / 0`, `0x513dfe`-`0x513e0a`), refusing `0x1c23` when one answers
0. What `FUN_004d9030` puts in the vector and what vslot `0x230` does are not
read. The table's columns 4-6 are 0 in all 292 retail rows, and which value
fills `+8` is not read: the `_REFTELELINK` table loads through a reflective
descriptor (`FUN_0082d770` registers `"_REFTELELINK"` as `CRefTeleLink`, `0x30`
bytes), not a column parser this project has read.

**So whether the retail server enforces these rules at all turns on that
byte.** At 0 a failing rule refuses; at any non-zero value other than 1 every
failure is dropped (`0x513ccf`, `0x513d35`) and the walk ends like a clean one.
srrevamp enforces them -- it models mode 0 -- and that is a **disclosed
stand-in**, not a read value. It also refuses type 5 before any post-pass could
run.

**Where it runs.** Not on `GObjPC::HandleTeleportUse`'s kind-2 path (above), but
on `CMainProcess::FUN_004f2b50`'s: `Gate_LinkForTeleportUse`, then the evaluator
(call `0x4f2e24`), and only when it passes the fee -- `piStack_88[1]`, zeroed
while `GetMaxLevel` (vslot 74) is below `0x15`, the fortress tax, and the 64-bit
gold compare refusing `0x1c07`. The same path calls it again at `0x4f34a0`, and
`CGObjPC::vslot_309` (`0x4ef480`) calls it at `0x4ef7b9`, on a branch taken
when a string of its second argument compares equal to `"TELEPORT"`, for the
link `GObjPC::FUN_004f88d0` returns. The three call sites were read in
`srv.asm` (`e8 .. call 0x513a70`).

**The triples' position is settled by the data.** The client's parser
(`RefParse_teleportlink`, `0x976c80`, called at `0x954be4` after the loader's own
service-column read at `0x954b9d`) reads five direct tokens and then the triples
-- one leading token fewer than the file's six (source, destination, fee and
columns 4-6), so by that parser alone the triples would start at column 6. They
start at column 7: every one of the 1,125 type-0 slots carries blank or zero data
words at 8-9, 11-12, ... (3 blank, all on link `1 -> 5`, and 1,122 zero); read
from column 6 the types would include 999 (69 slots), 110 (14), 102 and two
blanks, with every row's first type the always-0 column 6; and the one type-4
slot (link `160 -> 162`,
`GATE_RC_MOUNTAIN_GATE -> GATE_RC_ROC_GATE`) names `23973`, which itemdata calls
`ITEM_QNO_RM_MEETROC_6_01` -- the item the type-4 arm looks up, refusing with the
Roc-entrance code. Which token the client's parser drops is not read; nothing in
the client reads the triples (above).

In the retail table the non-zero types are 1 (84 slots: `(1, 1, 110)` ×12,
`(1, 0, 999)` ×24, `(1, 110, 999)` ×21, and eight other ranges), 2 (245), 7 (3),
and one each of 4, 5 and 6 -- all on the Roc link. **No slot has type 3**: 0 of
the 1,460, so no retail link bars a PvP state and there are no type-3 data
values to report (counted over `/var/tmp/tables/teleportlink.txt` with the BOM
stripped, twice, by `awk` over an `iconv` copy and by Python decoding the raw
UTF-16; no cell in columns 7-21 is `3` at all, so the column-6 reading has none
either). At level 50, 245 links pass,
46 refuse `0x1c15` and the Roc link refuses `0x1c23` (measured over the exported
CSVs with `teleport.CheckRestrictions`, round 575).

## The columns srrevamp reads (round 575)

`cmd/export-refdata -mode teleport -out <dir>` writes `teleportdata.csv`,
`teleportlink.csv` and `teleportbuilding.csv`; `internal/teleport` reads them
(`teleport.Load`), and cmd/server's `-teleport-dir` loads the directory at boot.
Columns are 0-based as everywhere on this page (column 0 is the service flag, `1`
in every row; the client's loader reads it and skips a 0 before each parser --
`0x954b1a` for teleportdata, `0x954b9d` for teleportlink, through `FUN_00b9cc80`,
which returns the column's integer -- and the exporter skips those rows too;
teleportbuilding's loader is elsewhere, its service handling is not read, and
its column 0 is not filtered). Every column was
checked against the retail rows on the render box (`/var/tmp/tables`, round 575):

| file | column | CSV field | grounding |
|---|---|---|---|
| teleportdata | 1, 2, 3, 4 | ID, Code, ObjectID, ZoneName | the client's `RefParse_teleportdata` (`0x976840`) reads id, codename, associated object, zone name in this order |
| teleportdata | 5, 6, 7, 8, 9 | Region, X, Y, Z, Radius | the same parser's next five tokens; the server's `RefTeleport_ExtractData` (`0x6a7be0`) reads them as five words (`wwwww`); 98 rows carry a negative (dungeon) region |
| teleportdata | 10, 11 | Interaction7, Interaction9 | the two tokens the client throws away; the server's `bb`, registering interaction ids 7 and 9 (round 454 numbered them 9/10, as if the server's copy had no zone name; whether it lacks that column or skips it is not settled -- `RefTeleport_ExtractData` calls the column-skip helper `FUN_006b1a80` right after the associated-object dword -- and either way its two bytes follow its five words, so they are the two tokens after radius). 7 rows set the first, 1 row the second |
| teleportlink | 1, 2, 3 | From, To, Fee | the fee's use-site (above) |
| teleportlink | 7..21 | Rule1Type .. Rule5Data2 | the evaluator (above); a type-0 slot is empty and is not loaded as a rule |
| teleportbuilding | 1, 2, 5 | ID, Code, NameStrID | the `_RefObjCommon` prefix: id, codename, name string (`SN_NPC_CH_GATE`) |
| teleportbuilding | 41, 43, 44, 45 | Region, X, Y, Z | the prefix's RegionID and OffsetX/Y/Z (`refobj_binary_format.md`, "Fields 43-51 of the common prefix"; 42 is Dir) |
| teleportbuilding | 55 | Fortress | a `FORTRESS_*` code on the five town gates, `xxx` (loaded as "") on the other 72; read from the values, no use-site |

Joins, measured on the retail rows: every link's two ends are points (292 of 292;
the loader refuses a link that does not join), no two points name one object, and
no ids or building codes repeat. The five town gates are `GATE_CH` Jangan,
`GATE_WC` Donwhang, `GATE_KT` Hotan, `GATE_EU` Constantinople and `GATE_CA`
Samarkand (`SN_ZONE_22001..22005`); `GATE_SD1`/`GATE_SD2` are Alexandria (South)
and (North), not Samarkand (`docs/RE_COMPLETION.md`, round 569). Jangan's links,
in file order: to 2 `GATE_WC` 5000 `(2,0,0)`; to 175 `GATE_SD1` and 176 `GATE_SD2`
40000 `(1,0,999)+(2,0,0)`; to 5 `GATE_KT`, 20 `GATE_EU` and 25 `GATE_CA` 5000
`(1,1,110)+(2,0,0)`.

The rules srrevamp applies (`internal/teleport/rules.go`): `QuoteFee` -- the
link's fee, waived below level 21 (`cmp al,0x14; ja` at `0x5136de`), then two
own-design waivers, GM accounts and a testing flag; `CheckRestrictions` -- the
table above, with the arms that need state srrevamp does not model disclosed:
types 2 and 7 pass (no trade carts); type 3 is evaluated against the PvP state
the caller passes, and srrevamp, which models no PvP state (no PK system; the
own-design duel sets none), passes `NEUTRAL` -- a disclosed stand-in; types 4
and 5 refuse when their data 1 is non-zero and type 6 refuses on `(0, 0)` (the
inventory and the job state are not consulted -- fail closed with the engine's
code); and the rules are enforced as mode 0 enforces them, the mode byte's
filler being unread (above). Level stands in for MaxLevel (equal unless a
character lost levels, which srrevamp cannot do); no fortress tax (no
fortresses).
