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

## Max durability (2026-09-19)

The number the tooltip shows and `ComputeRepair` divides by, `GItemEquip+0x194`,
is built in two steps.

### 1. The base, from the ref row and the instance's variance -- `Char_BuildAggregateStats`, `0x00495d60`

`Char_BuildAggregateStats` is shared by everything stat-bearing; called with an
item as `this` (which `GItemEquip::FUN_00495ca0` does after a rebuild), its first
block under the "is equipment" virtual (`slot 39 == 1`) reads the item's ref row
(`this[0xd]+0x18`) and stores `+0x194`:

```
495d99  fld [eax+0x1b8]        ; per-plus increment
495da7  fld [eax+0x1b0]        ; Dur_L   (itemdata column 63)
495db1  fld [eax+0x1b4]        ; Dur_U   (itemdata column 64)
495de1  xor esi,esi            ; variance group 0
495de3  call 0x495d10          ; q = Item_VarianceFactor(0)
495e25  mov [ebx+0x194],eax    ; max durability
```

	maxDurability = round( Dur_L + q * (Dur_U - Dur_L) + inc * plus )
	                assert(Dur_L <= Dur_U); plus = the item's +N level

`Item_VarianceFactor` (`0x00495d10`) is the item's "white stat" factor:

```
495d28  lea ecx,[esi+esi*4]    ; shift = 5 * group
495d2b  call __allshr          ; Variance (record+0x30, 64-bit) >> shift
495d30  and ax,0x1f            ; 5 bits
495d3f  fdiv qword [0xb45e28]  ; / 31.0   (.rdata, read: 31)
```

	q(group) = ((Variance >> 5*group) & 0x1f) / 31      ; group < 12 asserted

so durability's own 5 bits are **group 0** of the instance's `Variance`, and a
full-variance item gets `Dur_U`. Columns 63/64 are the text columns
`export-refdata` already maps to `DurabilityMin/Max` (the starter sword's
62/76). **`+0x1b8` is not a column at all: `RefObjItem::ExtractData` writes it as a
constant 0** -- the stream reader consumes two dwords into `+0x1b0/+0x1b4` and then stores
`+0x1b8 = 0` without advancing its cursor (2026-09-19; the next stat's third field, `PDInc`
at `+0x1c4`, *is* consumed, so the difference is deliberate). The `inc * plus` term is
therefore **zero for durability**, and the base is simply

	maxDurability = round( Dur_L + q * (Dur_U - Dur_L) )

with `q` from the instance's variance, group 0. See `refobj_binary_format.md` for the
triple array this sits in.

### 2. The magic options on top -- `GItemEquip::ApplyDurabilityAndRateOptions`, `0x00496a70`

Walks the instance's magic options (count at `record+0x58`, "Item's
MagParamNum(%d) is out of range" above 12), decoding each with
`Item_DecodeMagicOption`, and nets a percentage `pct`:

| tag | effect on `pct` |
|---|---|
| `'duru'` `0x64757275` | `+ value` (durability up) |
| `'dura'` `0x64757261` | `- value` when non-zero (the dec-dura penalty option) |
| `'nrep'` `0x6e726570` | `+ optionRecord[0x10]`, a fixed field of the option's own row |

	if pct != 0: max += round(max * pct / 100)   ; 100.0 from .rdata 0xb45af0
	if max == 0: max = 1

Two more tags in the same loop scale per-instance floats by `(1 + value/100)`:
`'er'` (`0x6572`) on `+0x19c` and `'hr'` (`0x6872`) on `+0x1d8`. Their identity is
**not read** (no other float reader of those instance fields turned up); by
their tags they are most likely the parry- and attack-rate percentage options,
and that is an inference.

## Creating an item: the variance roll and the initial durability (2026-09-19)

Where `q` comes from, read from the creation path so that srrevamp never has to
invent it.

### `GObjPC::InitItemVarianceAndData` -- `0x007286c0`

Takes a creation spec (`in_EAX`, flag word first). **Flag 1**: use the spec's
own 64-bit Variance (`spec[2..3]`), then set the initial `Data` to
`round(Dur_L + WhiteStatOffset(v0))`. **Flag 8**: use the spec's own `Data`
(`spec[4]`) directly. **Otherwise** roll every group:

	for each of the 12 groups:  v = round( RollWhiteStatUnit() * 31 )     ; 31.0 at 0xb45e28

and pack them 5 bits apiece (group k at bits `5k..5k+4`; `Item_VarianceFactor`
reads them back the same way).

### `GObjPC::RollWhiteStatUnit` -- `0x00729280` -- the shape of a white stat

```
u = 1.0
three times:  r = rand() / 32767 ; if r < u: u = r      ; 32767 at 0xb45af8
assert(u < 1)
return u
```

**The minimum of three uniform draws.** Its density is `3(1-x)^2`: mean 25%,
median 21%; a group at 31/31 needs `u >= 30.5/31` on all three draws, about
**1 in 250,000**, and >= 90% about 1 in 1,000. This is the skew players know
from the game, read rather than remembered.

### `GObjPC::WhiteStatOffset` -- `0x00728ed0`

For an `(L, U)` pair at ESI (`assert(L <= U)`) and a group value `v` in AL:
`round(U - L) * (v / 31)`. So a fresh item's `Data` is its own max durability,
`Dur_L + round(Dur_U - Dur_L) * v0/31`.

### `RefItemDrop::SetInitialItemData` -- `0x00728470`

Clamps the requested `Data` into the item's valid range (`CLAMP()` log at
`RefItemDrop.cpp:3592`), writes it with dirty bit 4, and then keeps group 0
honest: for equipment kinds it computes
`v0 = round((Data - min) / (max - min) * 31)` and ORs it into the low five bits
through `GObjPC::SetItemVariance` (`0x0042fb80`, a plain `(lo, hi)` setter).
Durability's variance and the durability itself can therefore never disagree.

### What srrevamp needs, all of it now grounded

| step | rule | source |
|---|---|---|
| roll | 12 groups, `round(min(u1,u2,u3) * 31)`, `u = rand()/32767` | `RollWhiteStatUnit`, `InitItemVarianceAndData` |
| max durability | `round(Dur_L + v0/31 * (Dur_U - Dur_L))` | `Char_BuildAggregateStats`, loader zeroes the increment |
| initial durability | = max durability | `WhiteStatOffset`, `SetInitialItemData` |
| loss | -1 at `min(2*hits,100)`% weapon / 2% per armour slot in order / 2% shield on block | `RollDurabilityLoss`, `Combat_ResolveDamage` |
| broken | at 0 the item's stats are removed; refuses to go below 0 | `ChangeItemDurability` |
| client | `0x3052 [u8 slot][s32 durability]` | `ChangeItemDurability` |
| repair | `cost = ceil-ish(col28 / max) * units`, see above | `ComputeRepair` |

## What consumes durability (2026-09-18)

Read from the Ghidra dump by following the **writers** of the durability field,
not by guessing a mechanic. The chain, innermost first:

### 1. The field and its persistence

An item instance is a `CInstanceItem` (`CDBRecord`): its `Data` column sits at
`record+0x38` -- durability for equipment, stack count for expendables (the
server's own refdata check says "a durability or maxstack of a item"). The
record's `+8` word is a per-field dirty mask; `Data` is bit **4** (`CInstanceItem
::vslot_005` Reset and `vslot_008` CopyFrom set 4 / 8 / 0x10 / 0x20 field by
field). A `GItemEquip` reaches its record through `+0x34`; its **max**
durability is `GItemEquip+0x194` (`[0x65]`), the value `ComputeRepair` reads
too, recomputed by `FUN_00496a70` from the item's `'dura'` magic option
(`GItemEquip::FUN_00495ca0` then clamps `Data` down to a lowered max).

### 2. `GItemEquip::AddDurability(delta)` -- `0x00496d90`

```
new = Data + delta                        ; record+0x38
if max < 0: log CLAMP (GItemEquip.cpp:925), new = 0
new = clamp(new, 0, max)                  ; max = this+0x194
FUN_00495980(new < 1)                     ; the BROKEN flag
if new != Data and (DAT_00d2043c & 1):    ; a server-wide gate, unidentified
    record+8 |= 4 ; record+0x38 = new     ; persist
return new
```

The early `return 1` when virtual slot 36 answers non-zero is an item that has
no durability to lose (the slot's exact name is unread).

### 3. `CGObjPC::ChangeItemDurability(slot, delta)` -- `CGObjPC::vslot_312`, `0x004e7100`

Looks the item up in the slot; requires virtual slot 33 (equipment) true;
**refuses a decrease when `Data` is already 0**; applies `AddDurability`. For an
equipment slot (`< 13`) it then watches the zero crossing: falling to 0 calls
`RemoveParamKeeperItemEntry` -- **a broken item stops contributing its stats** --
and rising from 0 re-adds it (`FUN_004e3760`), followed by a stat rebuild
(`GObjPC::FUN_0059f0e0`) and publish (vslot `0x538`). Finally it sends the client
opcode **`0x3052` = `[u8 slot][s32 durability]`**.

### 4. `GObjPC::RollDurabilityLoss(kind, rate)` -- `0x004a9a90`

PCs only (vtable slot 7, `IsPC`). `chance = min(2 * rate, 100)` percent, rolled
as `rand() % 100 + 1 <= chance`. Every loss is **-1**, through
`ChangeItemDurability`:

| kind | what rolls | on success |
|---|---|---|
| 0 | one roll | **slot 6, the weapon**, -1 |
| 1 | slots 0..7 except 6, each rolled **in order** | the **first** to pass, -1 -- one piece per event |
| 2 | one roll | **slot 7, the shield**, -1 |

The slot numbers are the equipment slots (`EquipmentNet.SLOT_*`: 0 helm, 1 mail,
2 shoulder, 3 gauntlet, 4 pants, 5 boots, 6 weapon, 7 shield).

### 5. Where the rates come from -- `Combat_ResolveDamage`, `0x0058e5f0`

The rates are **hit counters**, not table values. At entry the action record's
weapon byte (`action+6`, `action = ctx+0x50`) is zeroed (line 150 of the
decompile) and each target's effect block zeroes `+0x14` / `+0x15`. Then, per
target:

- a **landed hit** (state byte 0): `action+6 += 1` (line 677) and that target's
  armour byte `+0x15 += 1` (line 690);
- a **blocked hit** (state byte 2; the block roll is `GObjPC::RollChance`,
  `0x005a1a20` -> `FUN_00599cc0`, the dice the critical-hit section already
  reads): that target's shield byte `+0x14 += 1` (line 459), and its armour byte
  too when `pc[0x34b] != 0` (line 465; that flag is not identified).

The apply pass (`FUN_00593800`) then spends them: **once per action** for the
attacker, `RollDurabilityLoss(0, action+6)` -- so a single-target blow gives the
weapon a 2% roll and a five-target skill a 10% one -- and **per target**
`RollDurabilityLoss(1, +0x15)` and `RollDurabilityLoss(2, +0x14)` on the
*target*. For one plain hit the victim's worn pieces are rolled in slot order at
2% each, first success loses the point (with all seven worn that is
1 - 0.98^7 = 13.2% that some piece loses one); a blocked hit costs the shield a
2% roll instead.

### 6. A timed drain -- `0x004a9a10` from `TickTimedSkillEffect`

A timed skill effect whose parameter record's first word is **1** (weapon, slot
6) or **2** (shield, slot 7) takes 1 durability off that slot per tick when it
holds a working item and a `RollChance` passes. The chance is carried in a
register the decompiler does not show; not recovered.

### Negative result: skill `'dura'` is not durability

The skill parameter `'dura'` (offset 0x280, two values, 1,979 skills) looked like
the obvious source and is not: `CGSkillObject::Update` compares its first value
against `GetTickCount() - start`, and `FUN_0059b8d0` divides it by 1000 for a
message. It is a **duration in milliseconds**. The item magic option spelled the
same way is the "Durability +%" attribute (`dec-dura` in the option dumper).

## Other repair paths, unread

| function | what |
|---|---|
| `CGItemExpendable::vslot_309` | repair by consumable — `STRGERR_THERE_IS_NO_ITEM_TO_REPAIR` |
| `GObjSiegeStruct::FUN_004cfd50`, `SiegeFortressMgr::FUN_00634950` | fortress structure repair — `FORT_BATTLEAIDE_REPAIR_FAIL` |
| `CMakeStuff_ResolveEquip::vslot_003`, `FUN_0050c160` | `ENCHANTERR_RONDO2_UNREPAIRABLE_ITEM` — some items cannot be repaired at all |

## Not recovered

- **Consumption is read (above); four small gates in it are not named:** the
  server-wide `DAT_00d2043c & 1` that permits the persisted write, `pc[0x34b]`
  (armour also rolls on a block when it is set), the chance fed to the timed
  drain's `RollChance`, and the two item virtuals (slot 33 "is equipment",
  slot 36 "has no durability"). Nothing here takes durability off on death or
  on a cast; only hits, blocks and that timed effect do.
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
