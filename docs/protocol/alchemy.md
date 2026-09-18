# Alchemy: reinforcing, stones and sockets

How the server runs an alchemy operation, and — for reinforcing — the complete
success formula, recovered from `SR_GameServer.exe` and corroborated against the
client.

Implemented in `server/internal/alchemy`.

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

**The array is not reinforce-specific.** Element 0 (`0x2a0`) is read elsewhere via
`TimeSpan_SetDaysMinutesSeconds`, and `ExtractData`'s own error string for a bad
element is *"invalid parameter has been assigned for item cooltime"* — so this is
a general per-index array (item cooltimes and, in elements 1–3, the packed
reinforce rates), one dword + one string per element. `LookupPackedRate` is one
consumer of it, not its definition.

**Progress on it, 2026-09-17.** `client/tools/re/fields.py` reads these
deserializers mechanically and is now **validated**: it returns exactly the 58
fields `docs/protocol/refobj_binary_format.md` fixes for `_RefObjCommon`, with
three of that document's own anchors landing. It gives `RefObjItem::ExtractData`
153 fields with ~77 offsets resolved.

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

	rate = base()
	if (ctx->+0x226a != 0) {           // a second element is loaded
	    if (rate > 99) return rate;    // already certain, don't bother
	    rate += base()                 // a second contribution
	}

### 3. Lucky adds five — same function

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

- **Which ref-record offset holds the packed rates.** See §1.
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
