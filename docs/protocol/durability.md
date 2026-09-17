# Durability and repair

srrevamp has item durability columns in its reference data and no repair path.
This is the path, recovered from `SR_GameServer.exe`. Implemented in
`server/internal/repair`.

## The entry point

`GObjNPCNPC::FUN_004c7af0` (547 bytes) is what an NPC repair request runs:

	if (gold <= 0)                         goto NOT_ENOUGH_MONEY;   // 0x1c07
	item = GetItem(slot);                                           // vtable +0x578
	if (!item)                             return 3;
	if (!item->vt[0xd8]() || !item->vt[0x84]())
	                                       return 0x1c11;           // CANNOT_BE_REPAIRED
	if (item->vt[0x90]() == 1 || item->vt[0x410]() == 1)
	                                       return 1;                // nothing to do
	if (item[100] == 1) {                                           // the revive branch
	    if (!item->vt[0xdc]())             return 0x1c12;           // CANNOT_BE_REVIVED
	    cost = refRecord[0xa8];
	    if (gold < cost)                   goto NOT_ENOUGH_MONEY;
	    gold -= cost;
	}
	GItemEquip::FUN_00496e60(...);                                  // the repair proper
	return 2;

The gold comparison is again the 64-bit pair at `+0x78` / `+0x7c` — the
**fourth** unrelated subsystem in this project's recovery to read it that way.

There are two costs here and they are different things: **`refRecord[0xa8]` is a
flat revive fee** charged only on the `item[100] == 1` branch, and the repair
itself is priced separately below.

## The repair cost — `GItemEquip::FUN_00496e60` (`0x00496e60`)

This is the formula, read from the x87 sequence at `0x00496ee6`–`0x00496fa0`:

	maxDur  = item[0x194]
	curDur  = itemData[0x38]            ; 0 is treated as 1
	missing = maxDur - curDur
	if (missing < 1)                    -> 0x1c09, nothing to repair

	price      = clamp((float)refRecord[0xa4] / (float)maxDur, 1.0, 1e38)
	affordable = clamp((int64)((double)gold / price), 0, 100000)
	units      = min(missing, affordable)
	cost       = price * units

### The three constants

| constant | value | where |
|---|---|---|
| the unit cap | **100,000** (`0x186a0`) | `cmp esi,0x186a0` at `0x00496f78` |
| the price floor | **1.0** | a literal `fld1` at `0x00496f1b` |
| the price ceiling | `9.9999997e+37` | `.rdata 0x00b45c44` |

The ceiling is a float-overflow guard rather than a tuning value — no real item
approaches it — but the clamp is two-sided in the binary and a one-sided
reimplementation would not be faithful, so `server/internal/repair` carries both.

The floor is real and has an effect: **a repair never costs less than one gold
per durability point**, however cheap the item or however long its bar.

`0x00b45ba4` appears twice in the same block and is **not** a game constant: it
is `4294967296.0`, the compiler's unsigned-to-float fixup, which is how we know
both `refRecord[0xa4]` and `item[0x194]` are treated as unsigned.

### What the formula means

Dividing the price basis by the item's maximum durability spreads the basis
across the bar, so **restoring an item from zero to full costs exactly the price
basis**. Anything less is priced proportionally.

### A partial repair is not a refusal

If the character cannot afford to make the item whole, the engine **repairs what
the gold buys** — `units = min(missing, affordable)` — rather than refusing.
`0x1c07 NOT_ENOUGH_MONEY` is only raised when gold is zero or negative up front.

### The cap applies before the comparison

`affordable` is clamped to 100,000 *and then* compared against `missing`, so an
item missing more than 100,000 points cannot be made whole in one repair even by
a character who could pay for it. The order matters and is preserved.

## The field offsets

| offset | on | reading |
|---|---|---|
| `+0xa4` | the **common** record | the price basis |
| `+0xa8` | the **common** record | a flat restore cost |
| `+0x194` | the item instance | maximum durability |
| `+0x38` | the item's data block (the one whose `+0x18` is the reference record) | current durability |

### Which half of the record, settled 2026-09-17

A `CRefObjItem` is **one object with two adjacent halves**, written by two
different functions:

	0x000 .. 0x184   RefObjCommon_ExtractData   -- the common record
	0x198 .. 0x53d   RefObjItem::ExtractData    -- the item record

The ranges are **disjoint**, and that is the proof. Two facts, independently:

- Every `+0xa4` and `+0xa8` reference in `RefObjItem::ExtractData` is
  `[esp+0xa4]` / `[esp+0xa8]` — **stack locals, not record stores**. The item
  half never touches those offsets.
- `RefObjCommon_ExtractData` writes `record+0xa4` and `record+0xa8` at
  `0x006a35e4` and `0x006a360f`, through a register traced back to the record
  pointer it spills to `[esp+0x14]` at entry.

**So the price basis and the restore cost are properties every game object has**,
not item-specific columns. That is not a curiosity — see the next section.

This matters for a further reason: the two halves are deserialised by different
functions, so a column index derived from the wrong one would be wrong by the
whole 58-field common prefix. That risk was flagged as open on the previous tick
and is now closed.

### `+0xa8` is confirmed by a second, unrelated reader

Exactly two functions read it, and they are in different subsystems with the
same shape:

	if (!obj->vt[55]())   refuse;          // "can this be restored"
	cost = refRecord[0xa8];
	if (gold < cost)      refuse;
	gold -= cost;

| function | its refusal |
|---|---|
| `GObjNPCNPC::HandleRepairRequest` (`0x004c7af0`) | `0x1c12` `CANNOT_BE_REVIVED` |
| `SiegeFortressMgr::HandleStructureRepair` (`0x00634950`) | `0x2830` `FORT_BATTLEAIDE_REPAIR_FAIL` |

One field, two subsystems, **the same vtable slot 55 (`+0xdc`) guard**, and the
same charge-then-deduct. An item being revived and a fortress structure being
rebuilt are the same operation on the same common-record cost, which is exactly
what a common field should look like and is a stronger reading than the item
path alone supported.

The max/current assignment is a **reading**, not a label from the engine: it
follows from `missing = item[0x194] - itemData[0x38]` needing to be positive for
there to be anything to repair, and from the division producing a sensible
per-point price only in that direction. Nothing names either field.

## Other repair paths, unread

| function | what |
|---|---|
| `CGItemExpendable::vslot_309` | repair by consumable — `STRGERR_THERE_IS_NO_ITEM_TO_REPAIR` |
| `GObjSiegeStruct::FUN_004cfd50`, `SiegeFortressMgr::FUN_00634950` | fortress structure repair — `FORT_BATTLEAIDE_REPAIR_FAIL` |
| `CMakeStuff_ResolveEquip::vslot_003`, `FUN_0050c160` | `ENCHANTERR_RONDO2_UNREPAIRABLE_ITEM` — some items cannot be repaired at all |

## Not recovered

- **What consumes durability.** This page is entirely about restoring it;
  nothing here says how much a hit, a death or a cast takes off.
- **Which reference-data column feeds `refRecord[0xa4]`.** The same gap
  `docs/protocol/alchemy.md` has for its packed success rates: the record is
  deserialised field-by-field by `RefObjItem::ExtractData`, so mapping an offset
  to a column means counting through 7,052 bytes of it. That single unread
  function now blocks two systems, which makes it the most valuable one left.

  `client/tools/re/fields.py` does it mechanically and is **validated** — it
  returns exactly the 58 fields known for `_RefObjCommon`, and its requirement
  pairs now land as four `(dword, byte)` pairs at `0xb4/0xb8`, `0xbc/0xc0`,
  `0xc4/0xc8`, `0xcc/0xd0` — a stride-8 walk, matching the doc's "four
  requirement pairs" at columns 32..39.

  **Being in the common half is what makes this reachable at all.** Binary field
  order and text column order agree only through the common prefix; the item
  half consumes 153 binary fields against 160 text columns, so counting cannot
  convert there (see `refobj_binary_format.md`). `+0xa4` is common, so
  `field N → text column N−1` applies to it and not to alchemy's rates.

  **The index is still not published.** The scanner resolves `+0xa4` as field
  28 — which would be text column 27 — and that is *not* being claimed, for one
  specific reason: field 28 sits in a run whose offsets do not ascend with the
  field order (27 → `+0x9c`, 28 → `+0xa4`, 29 → `+0xa8`, **30 → `+0xa0`**), and
  no anchor brackets it. A struct need not be laid out in read order, so the
  jump is not proof of an error — but it removes the only sanity check available
  there, and the nearby columns 27 and 28 sit in a clean 1.5 ratio that would
  make a wrong answer look right.

  That is the `characterdata` column-79 shape exactly, and the rule is that a
  suggestive curve is not a use-site. **What would settle it**: verify the
  scanner against a common-prefix anchor that brackets field 28 — the doc's
  "Country at column 14" is field 15 and currently unresolved, so resolving that
  one offset would do it.
