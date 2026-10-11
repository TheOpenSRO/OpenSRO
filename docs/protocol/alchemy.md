# Alchemy: reinforcing, stones and sockets

How the server runs an alchemy operation, and — for reinforcing — the complete
success formula, recovered from `SR_GameServer.exe` and corroborated against the
client.

Implemented in `server/internal/alchemy` (the rules), `server/internal/session/alchemy.go` (the
request), `server/internal/magicopt` (the magic option table) and, on the client,
`client/scripts/ui/hud/alchemy_reinforce.gd` and `alchemy_window.gd` (round 768). **Round 768,
at the end of this page, corrects §2, §3 and "The result packet" below; read it first.**

## One interface, eight operations

`CEnchant` is an abstract base with **six pure virtuals** (slots 0, 1, 5, 6, 7
and 9 all point at `__purecall`, `0x009dd3ad`). Eight concrete operations
implement it, each with its own vtable:

| class | vtable | what it is |
|---|---|---|
| `CEnchant_Reinforce` | `0x00af6a10` | the ordinary plus-level upgrade |
| `CEnchant_UpperReinforce` | `0x00af6a4c` | a second reinforce path, 15 slots |
| `CEnchant_EnchantMagicStone` | `0x00af68c4` | magic stones |
| `CEnchant_EnchantAttrStone` | `0x00af688c` | attribute stones |
| `CEnchant_EnchantAvatarItem` | `0x00af68fc` | avatar items, 15 slots |
| `CEnchant_SocketMaker` | `0x00af693c` | creates a socket |
| `CEnchant_SocketStoneInserter` | `0x00af69ac` | fills one |
| `CEnchant_SocketStoneEraser` | `0x00af6974` | empties one |

Three more classes sit beside them for the non-enchant alchemy —
`CMakeStuff_Compound`, `CMakeStuff_ResolveEquip`, `CMakeStuff_ResolveMaterial` —
each with a 4-slot vtable.

The interface, from the base's own slots and the eight implementations:

| slot | in the base | what it does |
|---|---|---|
| 0 | pure | **load a slot** — takes an item, validates it, stores it in the operation's slot array, returns 1 or an error code |
| 1 | pure | **execute** — the operation proper |
| 2 | `0x00501c00` | releases the loaded items; SocketMaker and SocketStoneEraser override it |
| 3 | `0x00501d10` | 22 bytes, shared by all eight |
| 4 | `0x00501cd0` | **precondition check**, overridden by all eight; the base is the common part |
| 5 | pure | the operation's own extra preconditions |
| 6 | pure | the **base success rate** |
| 7 | pure | the **final success rate** |
| 8 | `0x00501d30` | shared |
| 9 | pure | the result/commit step |
| 10–12 | `CEnchant__SetEnchantAttrToAttrAssim`, `…MagicToAttrAssim`, `0x00502350` | shared by all eight |

The operation keeps its loaded items in a **12-byte-stride slot array** starting
at context `+0x2242`: `+0x2242` is a handle, `+0x2246` the item pointer,
`+0x224a` a flag, and slot *n* is 12 bytes further on. `CEnchant_Reinforce`'s
loader writes index 0, 1 or 3 depending on what kind of item was handed to it.

## The error codes

Failures return a `0x54xx` code, which the server sends and the client shows.
Fifteen distinct codes appear across the family:

	0x5406 0x5407 0x5408 0x5409 0x540a 0x540f 0x5410 0x5412
	0x5420 0x5421 0x5422 0x5423 0x5424 0x5425 0x5426

Success is **1**.

**CORRECTION (2026-09-17).** This section first said *"no string in either
binary names them"*. That is wrong, and the way it went wrong is worth keeping:
the probe was a search for message strings **inside the CEnchant functions**, it
came back empty, and the conclusion drawn from it was about the whole image.
Fourteen of the fifteen were already named **in this repository** —
`docs/protocol/error_codes.md` decoded them from the client's 643-case message
switch in an earlier pass. An empty grep is a fact about the grep.

| code | the client's name |
|---|---|
| `0x5406` | **no case in the client's switch** |
| `0x5407` | `UIIT_MSG_REINFORCERR_RECIPE_NOT_LOADED` |
| `0x5408` | `UIIT_MSG_REINFORCERR_ONLY_EQUIPITEM_CAN_BE_REINFORCED` |
| `0x5409` | `UIIT_MSG_REINFORCERR_RECIPE_MISMATCH` |
| `0x540a` | `UIIT_MSG_REINFORCERR_EQUIPCLASS_MISMATCH_PROB_UP` |
| `0x540f` | `UIIT_MSG_REINFORCERR_TARGETEQUIP_CANT_BE_REINFORCED` |
| `0x5410` | `UIIT_MSG_REINFORCERR_IS_NOT_REINFORCE_STUFF` |
| `0x5412` | `UIIT_MSG_REINFORCERR_STUFF_CANT_BE_LOADED_MULTIPLE_TIME` |
| `0x5420` | `UIIT_MSG_STRGERR_ASTRAL` |
| `0x5421` | `UIIT_MSG_ENCHANT_EQUIPCLASS_MISMATCH` |
| `0x5422` | `UIIT_MSG_STRGERR_MAGICSTONE2_MAX` |
| `0x5423` | `UIIT_MSG_ENCHANT_FAILED` |
| `0x5424` | `UIIT_MSG_STRGERR_ASTRAL` |
| `0x5425` | `UIIT_MSG_TC_ERROR_ENCHANT_HONOR_ITEM` |
| `0x5426` | `UIIT_MSG_REINFORCERR_ALREADY_DONE` |

Three of these change what an earlier reading of this page said:

- **`0x5407` is `RECIPE_NOT_LOADED`**, so the operation's second slot
  (`ctx+0x2252`) holds a **recipe**, which the offset alone did not say.
- **`0x5408` is `ONLY_EQUIPITEM_CAN_BE_REINFORCED`**, which names the third,
  virtual check in `CEnchant::vslot_004`: it asks whether the loaded item is
  equipment.
- **`0x540a` is `EQUIPCLASS_MISMATCH_PROB_UP`.** This one is a confirmation
  rather than a correction: the optional second element whose presence makes
  slot 6 add the base rate twice is a **probability-boosting item**, which is
  exactly why it contributes to the rate. That was read out of the arithmetic
  before the name was found.

So the base precondition check (`CEnchant::vslot_004`, `0x00501cd0`) reads:

	if (ctx->slot[0].item == 0) return 0x5406;   // nothing to work on
	if (ctx->recipe        == 0) return 0x5407;  // no recipe loaded
	return  <is this equipment?>  ? 1 : 0x5408;

`0x5423` — `ENCHANT_FAILED` — is special-cased by the client's result handler
and is deliberately **not** shown through the generic error box, because a
plain failed enchant has its own UI. That is consistent with its name.

## Reinforcing: the complete success formula

This is the part worth having. Every term below is read from the binary.

### 1. The base rate — `CEnchant_Reinforce::vslot_006` → `FUN_00505f00`

`FUN_00505f00` takes the item's current plus level *n* in `EBX` and returns one
byte:

	tier = clamp(n/4 + 1, 1, 3)              ; 505f9c..505fbb, signed div by 4
	within = (n < 12) ? n % 4 : 3            ; 505fc0..505fd6
	shift  = (3 - within) * 8                ; 505fdb, 505ffa
	dword  = *(uint32*)(refObjItem + (tier + 21) * 32)
	return (dword >> shift) & 0xff

So **four success percentages are packed into each 32-bit field**, one per plus
level inside a tier, ordered high byte first; `n >= 12` always takes the low byte
of the tier-3 field.

**SETTLED 2026-09-18: it IS a strided array, and here is the loop that fills it.**
`RefObjItem::ExtractData` (`0x006a3d50`) is a sequential deserializer for most of
the record, but the `0x2a0..0x520` region is a **20-element strided array**
written by one loop (`local_104 = 0; do { ... } while (local_104 < 0x14)`):

	element = param_1 + (local_104 + 0x15) * 0x20      ; (tier+21)*0x20, base 0x2a0, stride 0x20
	*(uint32*)element        = next 4-byte token       ; the dword LookupPackedRate reads
	RefData_ReadStringField(element + 4)               ; a per-element string

So each element is `[+0 dword] [+4 string]`, 0x20 bytes, 20 of them, base `0x2a0`.
`(tier + 21) * 32` is `element[tier]`, and `CEnchant_Reinforce::LookupPackedRate`
reads the dword of elements 1–3 (`0x2c0`/`0x2e0`/`0x300`). This is why the
"tempting" text-column reading fails: the offsets are array indices, not
sequential columns, so no field count maps them — confirmed below, and now with
the mechanism rather than only the conclusion.

**The array is not reinforce-specific.** Element 0 (`0x2a0`) is read elsewhere as
an item **reuse cooltime in MINUTES** — the item-use result builder
(`GObjPC::FUN_00440120`, `0x440120`) does, from the asm at `0x4402ea`,
`TimeSpan_SetDaysMinutesSeconds(days=0, minutes=item[0x2a0], seconds=0)`, so the
span is `item[0x2a0] * 60s`, and it is copied into the use-result packet at
`+0x170..`. `ExtractData`'s own error string for a bad element is *"invalid
parameter has been assigned for item cooltime"*. So the array is a general
per-index structure — element 0 a minutes-scale reuse cooltime, elements 1–3 the
packed reinforce rates — one dword + one string per element, and
`LookupPackedRate` is one consumer of it, not its definition.

The unit is worth pinning because it is easy to get wrong: the value is
**minutes**, not seconds (so not an HP/MP-potion cooldown, which is seconds and
category-based elsewhere) and not days (the `TimeSpan` helper's first argument is
days, but the call passes the cooltime as its *minutes* argument). It is the
long-cooldown reuse delay a scroll or special consumable carries. OpenSRO
imports neither this column nor enforces any item cooldown; `session.useitem`
lets a consumable be used with no reuse delay at all. Recovered, not wired.

**Progress on it, 2026-09-17.** `client/tools/re/fields.py` reads these
deserializers mechanically and is now **validated**: it returns exactly the 58
fields `docs/protocol/refobj_binary_format.md` fixes for `_RefObjCommon`, with
three of that document's own anchors landing. It gives `RefObjItem::ExtractData`
153 fields with ~77 offsets resolved.

**SETTLED 2026-09-19 (round 262): the array IS the itemdata `Param`/`Desc128`
block, and the elixir rows name their own dwords.** The parser's loop consumes
its 20 `(dword, string)` pairs from the row stream in order after the fixed
fields, and the text table ends in exactly that shape: `Param1, Desc128_1, ...
Param20, Desc128_20` = columns `118 + 2k` / `119 + 2k` (0-based, 160 columns).
So element `k` at `0x2a0 + 0x20k` is `Param{k+1}`, and `LookupPackedRate`'s
elements 1–3 are **`Param2`, `Param3`, `Param4`** (columns 120/122/124). The
retail row for `ITEM_ETC_ARCHEMY_REINFORCE_RECIPE_WEAPON_A` (id 3675) reads:

| column | value | bytes, high first | its own `Desc128` |
|---|---|---|---|
| `Param2` (120) | 420744970 | `0x19 0x14 0x0F 0x0A` = 25, 20, 15, 10 % | **`1,2,3,4`** |
| `Param3` (122) | 168430090 | `0x0A 0x0A 0x0A 0x0A` = 10, 10, 10, 10 % | **`5,6,7,8`** |
| `Param4` (124) | 168101125 | `0x0A 0x05 0x05 0x05` = 10, 5, 5, 5 % | **`9,10,11,12`** |

The descriptors are the table's own words for what each dword packs -- the
plus levels being attempted -- and `BaseRate`'s `tier = n/4 + 1`, `within =
n % 4`, high byte first lands +1 on 25 %, +5 on 10 %, +9 on 10 % and +10..+12
(and everything past, via the low byte of tier 3) on 5 %. The shield, armour
and accessory elixirs of the same grade carry the same three dwords; their
`Param1` differs (`0x06000000` weapon, `0x04000000` shield, `0x01020300`
armour, `0x05000000` accessory -- by shape the TypeID3 set the elixir applies
to, **not read** at a use-site). Shipped: `refdata.Item.ReinforceRate1..3`
(export columns 61-63, a strict suffix), `Item.ReinforceRates()` for
`alchemy.Inputs.Tiers`, and `TestBaseRateFromTheRetailElixirRow`. The alchemy
handler itself is still unwired.

**Why 77 and not more, established 2026-09-18.** fields.py's resolved offsets run
`0x198..0x294` then jump to `0x524..0x570` — the gap `0x298..0x520` is exactly the
20-element strided array above, filled by a loop rather than sequential fields, so
a field-by-field walker cannot and should not sequence it. The gap is not missing
work; it is array data, and its structure is now known.

**Which half of the record they live in is settled**, which is half the
question. A `CRefObjItem` is one object with two adjacent halves —
`0x000..0x184` written by `RefObjCommon_ExtractData` and `0x198..0x53d` written
by `RefObjItem::ExtractData`, disjoint ranges — so `0x2c0`/`0x2e0`/`0x300` are
**item** fields, and their column index comes from `RefObjItem::ExtractData`'s
sequence, not the common prefix's. See `docs/protocol/durability.md` for the
proof, which was worked out there because the repair price basis turned out to
sit in the *other* half.

**Counting will never give these a text column, and that is now established
rather than suspected.** `RefObjItem::ExtractData` consumes **153** binary
fields; a real itemdata row has **160** columns. The two type-specific tables
both consume fewer binary fields than their text has columns — item by 7, char
by 24 — so binary field order and text column order agree only **through the
common prefix**, exactly as `docs/protocol/refobj_binary_format.md` said they
would.

So the plan this page carried — resolve the offset, count to a field index,
read off the column — **cannot work for these three**, because they are in the
item half. That is a dead end identified, not walked into.

**That route is closed too, and the question is now settled.** The per-column
schema records do carry a name — at `+0x04`, an SSO string — but
`Database::BindTableSchema` shows the names are *declared* by the binary and the
*indices* come from ODBC at runtime. And **not one of the 85 reference tables
declares any column names at all**: they are queried with `SELECT * FROM %s` and
consumed positionally, so the server does not know their column names either.
See `docs/protocol/db_columns.md`.

So there is nothing left to find: these three fields have **no name and no
stable index in the binary**, only an offset in the deserialised record. That
offset is what a reimplementation would use, and it is already cited above. The
line of enquiry is closed rather than parked.

### 2. The second element — `CEnchant_Reinforce::vslot_006`

**CORRECTED in round 768:** the second `LookupPackedRate` call runs on the lucky powder, not the
elixir (asm 0x506046-0x506055: EAX is the powder item). The second contribution is the POWDER's
own packed table, not the base rate again. The pseudo-code below is the shape, not the operand.

	rate = base()
	if (ctx->+0x226a != 0) {           // a second element is loaded
	    if (rate > 99) return rate;    // already certain, don't bother
	    rate += base()                 // a second contribution
	}

### 3. Lucky adds five — same function

**Round 768:** the test goes through FUN_00505e50, which also SPENDS one charge of the 'luck'
option (below 2 the option is removed). A bless option's value is a count of charges.

	if (rate < 100) {
	    if (HasMagicOption(item, 0x6c75636b) == 1) rate += 5;
	}

`0x6c75636b` is the tag `luck`, which `docs/protocol/magic_options.md` already
records as `MATTR_LUCK` (1819632491) from an entirely separate recovery. **The
constant in this function and the constant in that table are the same number.**
So a Lucky item is five percentage points easier to reinforce, and the value is
a flat 5, not a multiplier.

### 4. The character's own bonus — `CEnchant_Reinforce::vslot_007`

	rate = base_and_luck()             // slot 6
	rate += (int)GetParam(0xad)        // slot 65 / +0x104, truncated by __ftol2

**Param 173 is the reinforce success bonus.** Its registry row says `min 0,
max 100, default 0` — the right shape for percentage points — and that row was
recorded before this use-site was read. See `docs/protocol/param_registry.md`.

### 5. The clamp and the roll — `CEnchant_Reinforce::vslot_001` (`0x00506090`)

	rate = final_rate()                // slot 7
	if (rate < 10)      rate = 10;     // a floor of ten percent
	else if (rate > 99) rate = 100;    // 99 stays 99; 100 and above become 100
	if (rand() % 100 < rate) { ...success... }

Note the asymmetry, which is what the code says rather than what a tidy version
would say: the floor is applied with `<`, the ceiling with `99 <`, so **99
remains 99 and only values above 99 are raised to 100**. A rate of 100 makes the
roll certain, because `rand() % 100` is at most 99.

**So a reinforce attempt never falls below a 10% chance**, whatever the item and
whatever the level.

### The other preconditions — `CEnchant_Reinforce::vslot_005` (`0x00505db0`)

	if (ctx->slot[0].item == 0)              return 0x5406;
	if (second element loaded && its kind != the target's kind) return 0x540a;
	if (ctx->+0x2276 != 0 && !HasMagicOption(item, 0x61746861)) return 0x5420;

`0x61746861` is the tag `atha`, which `magic_options.md` records as
`MATTR_ATHANASIA` (1635018849) — the second tag constant in this system to match
that table exactly.

**The tag and the error message disagree, and this project does not resolve
it.** The code tests Athanasia; `0x5420` is `UIIT_MSG_STRGERR_ASTRAL`. Both
readings are independently solid — `0x61746861` really does spell `atha`, and
`error_codes.md` really does map `0x5420` to `STRGERR_ASTRAL` — so either one
message serves two stones, or the two vocabularies use different English words
for the same thing. Recorded as a conflict rather than decided either way.

## The outcome the client shows

`UI_REINFORCERR::FUN_00592650` in `sro_client.exe` takes a **flag byte** and
picks the message. Reading its branches gives the outcome taxonomy:

| bit | message | meaning |
|---|---|---|
| `0x10` | `UIIT_MSG_REINFORCERR_SUCCESS` | the plus level went up |
| `0x20` | see below | the attempt failed |
| `0x40` | `UIIT_MSG_REINFORCERR_BREAKDOWN` | the item was destroyed |

and when `0x20` is set, the **low nibble** says what else the failure cost:

| low nibble | message |
|---|---|
| `0` | `UIIT_MSG_REINFORCERR_FAIL` — nothing else happened |
| bit `0x01`, new level 0 | `UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_ZERO` |
| bit `0x01`, new level > 0 | `UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_DOWN` |
| bit `0x02` | `UIIT_MSG_REINFORCERR_FAILDOWN_DURABILITY` |

The bits are tested in the order `0x10`, `0x20`, `0x40`, and anything else
returns silently. `0x01` and `0x02` are not exclusive — an attempt can lose both
an option level and durability, and the function prints both messages.

## The result packet

**CORRECTED in round 768:** 0x872cd0 is the STONE result's handler (0xB151). The elixir's result
(0xB150) is handled by 0x8729e0, and has one more byte on failure (destroyed). The handlers are
registered at 0x871678..0x8716a9. See round 768 below for both layouts.

`FUN_00872cd0` in the client is the handler:

	byte result
	if (result == 1) {              // success
	    byte kind
	    if (kind == 1) show UIIT_MSG_ALCHEMY_CANCELED_COMPOUND
	    if (kind == 2) {
	        byte flag               // 0 -> show as failure (0x20), else success (0x10)
	        byte slot               // MINUS 13 before use
	        ...
	    }
	} else if (result == 2) {       // failure
	    uint16 errorCode            // one of the 0x54xx above
	}

**The `- 13` is a slot rebase, not a level.** The value is passed straight to the
client's inventory lookups, and 13 is `equipment.MaxEquipSlots` — the server
numbers inventory from 0 with equipment first, the client's alchemy grid does
not. This is a **fifth** independent witness for that 13, from a different
binary and a different subsystem than the four already recorded in
`docs/protocol/EQUIP_SLOTS.md`.

## The other operations' rates, read 2026-09-18

`CEnchant_Reinforce`'s pair was already recovered. The remaining classes:

| operation | slot 6, the base rate | slot 7, the final rate |
|---|---|---|
| `SocketMaker`, `SocketStoneInserter`, `SocketStoneEraser` | `Enchant_SuccessRateAlways100` | the same function |
| `EnchantAttrStone` | item ref record `+0x300` | `Enchant_SuccessRateBasePlusBonus` |
| `EnchantMagicStone` | item ref record `+0x300` | the same function |
| `EnchantAvatarItem` | assert, then `100` | the same function |
| `UpperReinforce` | a folded stub | a folded stub |

**The three socket operations cannot fail.** One function, `0x00504d00`, returns the
literal `100` and occupies *both* rate slots for all three of them (and slot 8 of
`CBless_AvatarItemWithNPC`). It is named flat rather than after any one class because
four classes share it.

**The two stone operations read their base rate from the item.** Both walk the loaded
item at context `+0x2252` to its ref record (`[item+0x34]+0x18`) and return the dword at
**`+0x300`** — the same offset in both, which is what makes it a record field rather than
a coincidence. Their final rate is `base + round(bonus)`; the addend passes through
`FUN_009fbb40`, a float-to-int rounding helper with 612 call sites across the binary,
not a game value.

This also answers part of "which ref-record offset holds the packed rates": for the
stone operations it is `+0x300`. Whether the reinforce rates live in the same record is
not established here.

## What is not recovered

(Round 768 answers "What the server sends on failure" below; see its section.)

- ~~**Which ref-record offset holds the packed rates.**~~ **Read** -- §1 of this
  page gives it: the record's `0x2a0..0x520` region is a 20-element strided
  array, `element = base + (tier + 0x15) * 0x20`, so the packed dwords sit at a
  **tier-dependent** offset rather than a fixed one. Round 262 then identified
  those dwords as the ELIXIR row's `Param2/3/4` (itemdata columns 120/122/124).
- **What the server sends on failure** beyond the code — whether the plus level,
  durability or destruction outcome is decided server-side and transmitted, or
  derived. The client's flag byte says what it *can* display; which server path
  sets which bit is unread.
- **`CEnchant_UpperReinforce`'s rate.** Its slots 6 and 7 do not point at rate
  functions at all — both hold a folded stub shared with `CAIState::OnLeave`.
  **Corrected 2026-09-18:** the guess that its rate is therefore computed in its
  own slot 1 is wrong. `MakeAttempt` was read and contains no roll — no `rand`,
  no clamp — it calls slot 4, slot 5, then slot 9 and logs the result. The
  outcome is decided in **slot 9** (`0x00506430`), which indexes the global
  reference-data singleton `DAT_00d6aa18` (the same one `PCData`, `CharData` and
  the async queries read), asserts the array holds at least `0x34` entries, and
  takes the pointer at `+0xcc` — entry 51. Identifying reference table 51 is the
  next step. The other six operations' rates were read the same day, below.
- **The `CMakeStuff_*` trio** entirely.

## Round 768: the whole operation, server and client

Read 2026-10-11 from `SR_GameServer.exe` (gs) and `sro_client.exe` (c). Labels: READ (addresses),
MEASURED (the retail tables), INFERRED, OURS, OPEN.

### The request (gs, READ)

- 0x7150 and 0x7151 reach `GObjPC_HandleAlchemyReinforceMsg` (0x506e20 / 0x506ee0, one body).
  `u8 action`: 2 starts, anything else cancels.
- A start carries `u8 op, u8 n, n x u8 slot` (FUN_00507cf0). The ops: 3 elixir, 4 magic or bless
  stone, 5 attribute stone, 7 avatar, 8 advanced elixir. The opcode is not checked against the op.
- Each slot is 13..111 (the bag after the 13 equipment slots); outside is 0x5414
  `INVALID_ITEM_SLOT`, an empty one 3. The first must be equipment (0x5408). Each goes to the
  op's slot-0 loader, which places it by KIND: 0x5410 not this op's stuff, 0x5412 twice.
- A refusal at the request answers `u8 2, u16 code` on 0xB150 (ops 3/6/8) or 0xB151 (4/5)
  (jump table 0x507fc8) and spends nothing.
- The operation then waits for the character's 1-second PeriodicUpdate to count to 3 and runs on
  the next tick: 3 to 4 s after the request.
- A cancel before that answers `u8 1, u8 1`; with nothing pending, nothing.

### The reply (gs and c, READ)

```
u8 2, u16 code                                    a refusal
u8 1, u8 1                                        cancelled
u8 1, u8 2, u8 success, u8 slot (13..111),
   [0xB150, failed: u8 destroyed],
   [unless destroyed: the item record]            (round 732's record)
```

- A stone's lost roll is `u8 2, u16 0x5423`. The client shows it as a failure (effect, sound,
  `REINFORCERR_FAIL`), not through the error line.
- The server never sends the 0x10/0x20/0x40 byte. The client builds it (0x8729e0) from success,
  destroyed, and the plus and durability against a snapshot taken at the send (0x57a390).
- Neither reply carries the spent elixir, powder or stone (OPEN: retail's packet for that was not
  read). OURS: this client lists the bag again after each reply.

### Reinforce (gs, READ)

- **Loader** (0x505bd0): equipment to slot 0 (refused 0x540f past +249); an elixir (3/3/10/1) to
  slot 1; a lucky powder (3/3/10/2) to slot 3; a magic cube (3/2/3/1) to slot 1 (not built here).
- **Slot 4** (0x505cb0): the target's TypeID3 is one of the four bytes of the elixir's Param1 or
  Param5, else 0x5409. MEASURED: weapon 0x06000000, shield 0x04000000, armour 0x01020300,
  accessory 0x05000000; the `_B` elixirs add Param5 0x090a0b00 / 0x0c000000.
- **Slot 5** (0x505db0): a powder's Param1 must be the target's degree, `(ItemClass - 1)/3 + 1`
  (FUN_004775a0), else 0x540a. MEASURED: PROB_UP_A_01..12 carry 1..12.
- **The rate:** the elixir's packed rate for the plus; with a powder, unless that already exceeds
  99, the powder's own packed rate; then, below 100, Lucky +5 and a charge spent; then param 173;
  floor 10, above 99 is 100; success iff `rand() % 100 < rate`. MEASURED powder tables:
  A_02..12 give +1..+4 100/100/100/80, +5..+8 65/50/30/19, +9.. 10/4/2/1.
- **Success** (0x506b20): the plus + 1 (the setter clamps at 250). Nothing else changes.
- **Failure** (FUN_00506ce0), n the plus before:
  - from +5, `rand() % 100 < 50` destroys the item (never a cash item, TypeID bit 0); the other
    half flaws its durability;
  - an Immortal ('atha') charge cancels the destruction, a Steady ('soli') charge the flaw;
  - the plus goes to 0, or to 4 when n >= 4 and an Astral ('astr') charge is spent. It never
    falls by one;
  - the flaw (FUN_00506b60) adds a fresh MATTR_DEC_MAXDUR value from the LEVEL-3 record (asm
    0x4906db) to any existing one, clamped to 1..99. MEASURED weapon level 3: 36..50.
- **Spent:** one elixir and one powder (ReleaseLoadedItems 0x501c00), success or failure, and the
  target too when destroyed.
- The 0x5420 test in slot 5 needs slot 4, which this loader never fills: dead here (INFERRED).
  `STRGERR_ASTRAL` belongs to the magic stone's Astral rule (below), which settles the old
  "tag and message disagree" note.

### Magic and bless stones (gs, READ)

- **Loader** (0x503ee0): a magic stone 3/3/11/1 or a bless stone 3/3/11/7.
- **The roll** (0x503680): Param4 (ref +0x300) + round(param 172); floor 5, above 99 is 100; the
  attempt FAILS iff `rate < rand() % 100`. A lost roll spends the stone and leaves the target:
  0x5423. MEASURED Param4: magic stones 50, bless stones 100.
- **The commit** (BlessItem 0x503810), only after a won roll:
  1. the option count must not exceed the cap (FUN_00491780: itemdata column 158, MEASURED 9 on
     most equipment, plus one per 'dura' and 'nrep' option, at most 12), else 2;
  2. the option is the stone's Desc128_1 (MEASURED "MATTR_STR"); no such group in the table: 2;
  3. the stone's Param1 must be the target's degree, else 0x540f;
  4. the group's record at that degree must exist and allow the item's kind, else 0x5409;
  5. 'rep' needs an existing 'rep' option (0x5425); 'astr' needs more 'atha' charges than 'astr'
     ones (0x5424, STRGERR_ASTRAL);
  6. the bless tags (atha, luck, soli, astr, ape) add one charge, at most 5; 'rep' at most 6;
     past it 0x5422 (MAGICSTONE2_MAX);
  7. every other option takes a FRESH value from the record's generator, clamped to 1..1700. It
     overwrites the same option in place (so it can go down) or is appended below the cap; at the
     cap nothing is written (2).
  - A refusal after a won roll does NOT spend the stone (only the lost roll releases it).
- **Assimilation** (slots 10/11): after a success, with probability `stone OptLevel / 101`
  another stat is disturbed, unless an 'ape' charge is spent instead. The draw is over the white
  groups (weapon 7, armour and shield 6, accessory 2) and the blue options: a white group is
  re-rolled the attribute stone's way; for a magic stone the blue re-roll is always option 0.

### Attribute stones (gs, READ)

- **Loader** (0x5029a0): 3/3/11/2. **Slot 4** (0x502a40): the stone's Param1 must be the degree
  and its Desc128_4 class list (MEASURED "weapon", "armor,shield", "shield", "armor",
  "accessory") must name the target's class, else 0x5421, before the roll.
- **The roll:** the same as a magic stone's.
- **Success** (0x503430): the white group named by the stone's NATTR_ position in the class list
  (FUN_00502c80: weapon DUR, PASTR, MAINT, HR, PA, MA, CRITICAL; armour DUR, PDSTR, MDINT, PD, MD,
  ER; shield DUR, PDSTR, MDINT, BR, PD, MD; accessory PAR, MAR, which are durability.go's groups)
  is SET to `{0, 7, 13, 19, 25, 31}[k]`, k the least of four draws of `rand() % 6`
  (FUN_00501ea0; five for an equip whose ref +0x89 is 2, INFERRED a Seal item; OURS: always four
  here). Then the same assimilation step.

### The client (c, READ)

- The strengthening tab is `CAlchemyMgrReinforce` (vtable 0xd8bf7c). Its slots are controls 17
  (the target), 26 (an elixir, magic cube, advanced elixir or stone) and 27 (a lucky powder) of
  pane 12. Stones and elixirs share the tab, and stones never open the powder slot.
- An item goes in by **Alt + left click** on the bag (0x681912) or by being put down on the window
  (0x59dca0). The slot comes from the item's kind (0x5781f0), not from where it was dropped. The
  check (0x578ac0) writes its refusal through 0x7781b0, type 0: LOAD_EQUIP_FIRST, RECIPE_MISMATCH,
  NOT_LOAD_INGREDIENT(2), EQUIPCLASS_MISMATCH, CANNOT_BE_USED_TO_TARGET.
- The action lights when the target and the stuff are loaded (0x578670). The click sends the
  request at once (no confirm, except for the advanced elixir), sets the caption to Cancel, plays
  `snd_elixir_use` and starts two 50 ms timers:
  - the effect: 16 cells of a 256 x 256 sheet drawn in a 96 x 96 window 0x20 up and left of the
    stuff slot, an 800 ms loop;
  - the gauge: fills over 3.0 s (0xd8adc4); when full the attempt can no longer be cancelled.
- **The reply** (0x59eb20): the success or fail effect and `snd_elixir_success` / `_failure`.
  - The lines: SUCCESS with the new plus (elixirs only); OPTLV_ZERO, or OPTLV_DOWN (new, loss);
    FAILDOWN_DURABILITY (new, loss); FAIL; BREAKDOWN.
  - At frame 8 the stuff and powder slots are emptied; at the wrap the effect hides.
  - A breakdown or a stone's lost roll empties the target slot too.
- **The effect's blend** (CIFDecoratedStatic +0x388, its draw 0x634640): mode 1 is additive
  (SRCALPHA, ONE). The click and a success use it; a failure, a breakdown and a lost stone roll set
  mode 0, the plain alpha blend. MEASURED: the sheets' DXT3 alpha is 15 everywhere, so mode 0
  shows their black square.

### OURS in this build

- The opcodes: one request 0x0113 for every op, replies 0x0114 (0xB150's body) and 0x0115
  (0xB151's).
- The wait: 4 s, the top of the READ window.
- Params 172 and 173 (the stone and reinforce bonuses) are 0: OpenSRO has no source of either.
- The magic cube and the advanced elixir are refused (0x5410).
- A loaded item that changed while the attempt waited cancels it (retail holds the item objects).
- The bag is listed again after each reply.
- The client's stone checks use the server's own rule: a stone that would be refused after a won
  roll is refused before it is sent, because a LOST roll spends even a mismatched stone.
- A second start while one waits is dropped unanswered; the client locks the window until the
  reply comes (and ends the attempt after 10 s without one).
- An attempt whose character left the world in the wait is dropped, nothing spent.
- A magic stone with no room for its option returns 2 before the assimilation step the binary
  still runs then.
- Three attribute-stone edge cases (an empty class list, one naming no known class, a NATTR_ name
  the class lacks) are refused with 0x5421 before the roll; the binary returns 2 or passes. No
  retail stone has any of them.
- FUN_00507fe0's 0x540f test (an item type answering vslot +0x470) and FUN_00502910's expiry test
  are not made: OpenSRO has neither kind.
- (Round 770: the export now leaves out Service 0 rows, as the server's loader does -- READ,
  FUN_00727c00 -- which settles the review's open point.)
- The client does not build the devil's spirit (Nasrun) refusal, message 0xe.

### OPEN

- Retail's packet for the spent stack counts; whether the server plays an effect on the character.
- The stone's option-change lines (0x594f40, `ALCHEMY_APPEND_ATTR` and friends).
- How a dropped stone's OptLevel (its assimilation %) is set.
- UpperReinforce (table 51), the avatar enchant, sockets, manufacture and decomposition.
