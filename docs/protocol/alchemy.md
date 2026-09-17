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

Success is **1**. The base precondition check (`CEnchant::vslot_004`,
`0x00501cd0`) is the clearest specimen:

	if (ctx->slot[0].item == 0) return 0x5406;   // nothing to work on
	if (ctx->target        == 0) return 0x5407;  // no second item
	return  <third check>  ? 1 : 0x5408;

The client's matching codes are in `sro_client.exe`, so the pair is a real
protocol vocabulary rather than an internal enum. **The codes are the engine's;
no string in either binary names them**, so this document quotes the numbers and
does not invent names for them.

`0x5423` is special-cased by the client's result handler and is not shown as a
generic error.

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

**What the offset means is not settled.** `(tier + 21) * 32` yields `0x2c0`,
`0x2e0` and `0x300`, three fields 32 bytes apart in the `_RefObjItem` record.
That spacing looks like a strided array, but `RefObjItem::ExtractData`
(`0x006a3d50`) is a **sequential field-by-field deserializer** — it advances a
cursor by each field's own width and counts fields as it goes — so the offsets
are a struct layout, not a column index, and the tempting reading "itemdata
columns 22, 23, 24" is **not** supported. Mapping offset to column means counting
fields through 7,052 bytes of `ExtractData`, and that is this system's next
probe.

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

## What is not recovered

- **Which ref-record offset holds the packed rates.** See §1.
- **What the server sends on failure** beyond the code — whether the plus level,
  durability or destruction outcome is decided server-side and transmitted, or
  derived. The client's flag byte says what it *can* display; which server path
  sets which bit is unread.
- **The other seven operations' rates.** Only `CEnchant_Reinforce`'s slots 6
  and 7 were read; magic stones, attribute stones and the three socket
  operations each have their own pair.
- **The `CMakeStuff_*` trio** entirely.
