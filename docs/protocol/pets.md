# Pets, carts and the rest of the COS family

**COS is the engine's own abbreviation**, and it covers more than pets — six
classes carry it. "Pet" names only two of the six, which is why
`server/internal/cos` is called what it is.

| class | vtable | slots |
|---|---|---|
| `CGObjCOS` | `0x00af0c1c` | 403 |
| `CGObjCOS_Cart` | `0x00af127c` | 403 |
| `CGObjCOS_Pet` | `0x00af1a4c` | 403 |
| `CGObjCOS_GoldPet` | `0x00af20ac` | 403 |
| `CGObjCOS_SilkPet` | `0x00af270c` | 403 |
| `CGObjCOS_Mercenary` | `0x00af343c` | 404 |

Those 400-slot vtables are the `IGObj` interface every world entity has, which
is why a summoned COS can be attacked, damaged and killed through the same paths
a monster is — and why a pet appears in the object index at all.

## Summoning — `GObjPC::FUN_004fcef0`

One function dispatches every kind, on a switch with cases 1 through 5. Each
case has its own rules, and the pet cases are 3 and 4.

### The level gate, for pets

	bVar3 = GetLevel();                                       // vtable slot 73
	if ((hasOwner && bVar3 < 5) || bVar3 < *(byte *)(item + 0x198))
	    return 0x186c;    // STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM

Two things, in one condition:

- **An absolute floor of level 5**, the same number `party.MinCreatorLevel`
  uses. `CGItemCOSSummoner::vslot_307` (`0x00493100`) enforces it independently,
  so it is read twice from different functions.
- **The item's own requirement, at byte `+0x198` of its reference record.** That
  is per-item data, not a constant, so `server/internal/cos` records the
  **offset** and deliberately no value.

The floor sits behind a `hasOwner` guard; with no owner object only the item's
own requirement applies.

### One pet per type

After the level tests, the function walks the character's active COS objects and
compares type ids:

	if (typeID == requestedTypeID) return 0x18a9;  // COS_CANT_SUMMON_DUPLICATE_PETTYPE

So a character may have several COS out at once, but **not two of the same
type**. A separate refusal, `0x185c` `STRGERR_CANT_SUMMON_MULTIPLE_COSOBJ`,
applies to the kinds that permit only one at all.

### Case 5 wants a guild

	bVar3 = CGuild::GetLevel();
	if (bVar3 < 3) return 5;

**Guild level 3** — the same threshold the fortress war requires to register
(`siege.MinGuildLevel`). Worth noting, but two checks reading one number are two
checks, not one rule; nothing here ties them together.

### `CANT_PETSUM_HIGHLEVEL` reads backwards

`0x18a5` `COSPETERR_CANT_PETSUM_HIGHLEVEL` fires when the **owner's** level is
**below** the pet's requirement — the "HIGHLEVEL" is the pet's, not the
player's. The name is easy to read the wrong way round, so it is written down
here.

## What the switch is switching on (round 289, 2026-09-20)

`CheckCanSummonCOS` dispatches on `*(ushort *)(obj + 0x80) >> 11` -- a 16-bit
packed type id shifted down by eleven, which is how the client reads a
**TypeID4** as well (`ITEM_FORMAT.md` records `FUN_00a5a7d0` doing exactly that
to pick a weapon's animation group).

**Whose TypeID4 was settled by measurement, and the first answer was wrong.**
Read as the summoner ITEM's, the COS rows of `itemdata` carry TypeID4 1, 2, 4,
6, 7, 9 and 12 -- not a range a five-case switch could cover, so that reading
is out. Read as the summoned CHARACTER's, `characterdata`'s `TypeID3 == 3`
family runs exactly 1 to 5 and stops:

| TypeID4 | rows | the rows' own code names | the case's refusal |
|---:|---:|---|---|
| 1 | 63 | `COS_C_RUDOLPH`, `COS_C_UNICORN`, `COS_C_OSTRICH_5` | `STRGERR_YOU_CANT_ACTIVATE_CART` |
| 2 | 39 | `COS_T_LIZARD`, `COS_T_BEHEMOTH`, `COS_T_WHITEELEPHANT_20` | the same |
| 3 | 1,260 | `COS_P_WOLF_001` … | `COS_CANT_SUMMON_DUPLICATE_PETTYPE` |
| 4 | 11 | `COS_P_MYOWON`, `COS_P_SEOWON`, `COS_P_RABBIT` | the same |
| 5 | 2,100 | `COS_GUILD_CH_SOLDIER1_001` … | `GUILD_SOLDIER_SAME_SUMMON_LIMIT`, after a guild-level test |

**Two independent witnesses.** The table's own code prefixes and the binary's
refusal strings were read from different places and agree case for case: the
cart error sits on exactly the rows named `COS_C_`/`COS_T_`, the pet error on
the rows named `COS_P_`, the guild error on the rows named `COS_GUILD_`. That
is what makes this a reading rather than a correlation.

**What is still not named** is what separates 1 from 2 and 3 from 4. The code
prefixes differ and the row counts differ wildly (1,260 against 11), but this
function treats each pair identically, so the distinction lives somewhere this
pass did not read. `server/internal/cos` carries the five as constants with
that caveat on them.

## Naming — `FUN_00511bb0`

	if (len == 0 || 0xc < len) { refuse }

so a pet name is **1 to 12 characters**, validated against the `std::string`
size field. Note this is *not* the guild-name rule (`2` to `12`,
`docs/protocol/guild.md`): the maximum matches and the minimum does not, so the
two cannot share a helper.

The naming procedure is `_COS_Naming`, 2 arguments.

## The rest of the vocabulary, enumerated

Twenty-five COS codes exist and seventeen server functions return one. Beyond
those above:

| area | function | codes |
|---|---|---|
| dismissal | `FUN_00511a60` | `CANT_DEACTIVATE_IN_DEADSTATE`, `CANT_PETRE_BATTLE` |
| selling | `FUN_00511f40` | `CANT_SELL_COS_HAVE_ITEMS`, `CANT_SELL_REQUESTED_COS` |
| feeding | `CGItemExpendable::vslot_327` | `HGPFULL_NODRINK` — the pet's hunger gauge is full |
| control | `GObjPC::FUN_004d2200` | `YOU_CANT_CONTROL_THIS_OBJ` |
| moving items | `FUN_00523960`, `FUN_00523f70` | `CANT_MOVETO_SUMITEM`, `CANT_MOVETO_CHEST2` |

## The growth pet is the one with an experience method (round 290, 2026-09-20)

`pets.md` asked what distinguishes `CGObjCOS_GoldPet` from `CGObjCOS_SilkPet`
beyond their names. Their **method sets** do, and the difference is not subtle:

	GoldPet   Create GetRefObjID OffsetExpPoint ReleaseAndClear Update
	          vslot_000 vslot_215 vslot_310 vslot_311 vslot_399 vslot_402
	SilkPet   Create GetRefObjID                ReleaseAndClear Update
	          vslot_000 vslot_349 vslot_368

**Only GoldPet has `OffsetExpPoint`**, the engine's own name for the
experience-granting method, and it overrides four slots SilkPet does not.
SilkPet overrides two entirely different ones. So growth belongs to the gold
pet; the silk pet has no experience method to call.

(Those slot numbers -- 215, 310, 311, 349, 368, 399, 402 -- are past the 209
`IGObj` slots `igobj_vtable.md` recovered, so they are unnamed. The
`## Illegal ##` stub lever does not reach them.)

### What `OffsetExpPoint` does (`0x004d6370`)

Read as far as it is unambiguous, and no further:

- **Pet experience is 64-bit**, at the pet's data record `+0x60` (low) and
  `+0x64` (high); the delta arrives as a 64-bit pair too.
- **The level threshold is a 64-bit** read from `this+0x1ce0` at `+8`/`+0xc` --
  a reference row, not a constant.
- **Experience is clamped, not rolled over.** When the new total reaches the
  threshold the function sets it to `threshold - 1` and recomputes the delta to
  match, so this function never carries a pet past the boundary itself.
- On a real gain it calls `GObjPC::FUN_004496e0(lo, hi)` and sends text id
  `0x30c9`.

**The level branch, read in full (round 291).** In assembly:

	4d641b  cmp  BYTE PTR [esi+0x58], 0x6e     ; the data record's level byte vs 110
	4d641f  jae  4d643a                        ; >= 110 skips the owner test entirely
	4d642f  call [owner + 0x124]               ; the owner's GetLevel
	4d6431  cmp  BYTE PTR [esi+0x58], al
	4d6434  jb   4d653e                        ; below the owner's level -> elsewhere

`0x4d653e` is **not** a "no experience" return -- the caution was warranted.
It is the **level-up path**, and reading it settles the rule:

	4d6552  call [this + 0x124]           ; the PET's own level
	4d6596  cmp  level, 0x8c              ; 140
	4d65aa  jge  <elsewhere>              ; at 140 it does not run
	4d65b0  add/adc                       ; experience += delta, 64-bit
	4d65fb  cmp  exp, threshold           ; 64-bit
	4d6611  sub  exp, threshold           ; LEVEL UP: carry the remainder
	4d6619  add  level, 1
	4d668c  jmp  0x4d65f1                 ; and around again -- several levels in one gain

So the two paths are a clamp and a level-up, and the gate chooses between them:

| when | path | effect |
|---|---|---|
| pet level >= 110, **or** pet level >= owner's level | clamp | experience accumulates but is held at `threshold - 1`; the pet never advances |
| otherwise (and its own level < 140) | level-up | experience is added and each threshold subtracted in a loop; several levels can land at once |

**A gold pet levels only while it is below its owner's level and below 110.**
At or past either boundary it keeps gaining experience and stops advancing,
which is why the clamp writes `threshold - 1` rather than discarding the gain.

`server/internal/cos` carries the two boundaries and `PetLevelsUp`.

### Where the thresholds come from, as far as it is read (round 292)

`this+0x1ce0` is a **pointer to one row**, and two sites set it the same way:
`CGObjCOS_GoldPet::vslot_215` (`0x004d5d50`) and `GObjPC::FUN_004d6210` both
index a vector of row pointers and store `rows[n]`, bounds-checked against the
container's own end (`(end - begin) >> 2`, so pointers). The second reads that
vector out of the global **`DAT_00d6aa14`**, which `OffsetExpPoint` also loads
(`4d65eb: mov esi, ds:0xd6aa14`) when it walks to the next level's threshold.

So the shape is settled: a **singleton holding a vector of rows, indexed by
level**, each row carrying the 64-bit threshold at `+8`/`+0xc`.

**Which rows those are -- settled by a use site (round 293).** The same vector
is indexed by **`GObjPC::GObjPC_SetLevel`**:

	uVar3 = uVar3 - 1;                          ; level - 1, a 0-based index
	iVar4 = rows[uVar3];                        ; the same DAT_00d6aa14 +0x14/+0x18 vector
	piVar1[0x72c] = iVar4;                      ; stored on the CHARACTER at +0x1cb0

So the vector is **the per-level row table, indexed by `level - 1`**, and the
function that sets a character's level is what reads it. The pet does the same
thing into its own field (`+0x1ce0`) and takes a 64-bit at `row+8`/`+0xc` as
its experience threshold.

**Pet levelling and character levelling read the same per-level rows.** That is
the answer the previous round withheld, and it arrived as a use site rather
than a resemblance: not "140 rows looks like leveldata" but "the character's
own level-set indexes this exact vector by level".

By `refdata_tables.md`'s enumeration the per-level table is `_REFLEVEL`
(`leveldata.txt`), which srrevamp already loads as `leveldata.csv`. The link
from this vector to that loader is **not** traced -- the rows are placed from
further out than `0x0082afc0`, and no function references both the global and a
`"_REF…"` literal -- so the identification rests on the use site and the
enumeration, not on the loader.

**Which field, settled (round 294).** `GObjPC::GObjPC_GainExpAndLevel` reads the
character's own level row at **`+8`/`+0xc` as a 64-bit pair** -- the same offset
the pet takes its threshold from. The character's exp-to-next is
`leveldata.txt` **column 1**, which `docs/LEVELING.md` matched against a real
level-9 character's "Next Exp" of 17,978. So the pet's level-up threshold **is
the character EXP curve**, not a pet-specific table, and the same record's
`+0x1c` (column 5, the exp unit) anchors the layout from the other end.

## The database surface

	_AddNewCOS       12 args        _ChangeCOSState   2 args
	_DeleteCharCOS    3 args        _COS_Naming       2 args

plus the `_CHARCOS` and `_INVCOS` runtime tables. **No column layout is
recovered** for either.

## Not recovered

- ~~**What the five switch cases are.**~~ **Recovered 2026-09-20 (round 289)** --
  see "What the switch is switching on" above.
- **The hunger gauge** — `HGPFULL_NODRINK` names it, and its **rate** is still
  unread. Its capacity, threshold and penalty are read: see "A pet gauge with a
  capacity, a threshold and a penalty" below. Whether that gauge *is* the hunger
  gauge is the part still missing.
- ~~**Pet growth.**~~ **Recovered 2026-09-20 (round 291)** -- both paths read,
  see below. What remains is the reference row the thresholds come from.
- **The mercenary**, which is the only class of the six with a different vtable
  length and has not been looked at.

## A pet gauge with a capacity, a threshold and a penalty (round 299)

`CGObjCOS_GoldPet::vslot_215` -- the same periodic function that refreshes the
pet's level row -- ends on a test:

	(float)((uint)*(ushort *)(petData + 0x68) * 100) / (float)_DAT_00b45f90
	    < (float)_DAT_00b45e58            ; 10000.0 and 30.0
	  -> GObjPC::FUN_004d60a0()

So the field at **petData `+0x68` is a `ushort` gauge whose full value is
10,000**, and the test is a straight percentage against **30 %**.

**What falls below 30 % costs the pet half its combat stats.**
`GObjPC::FUN_004d60a0` (`0x004d60a0`) sets **eight** ParamKeeper params to
`_DAT_00b4603c` = **50.0** and flushes:

| params | what they are (`param_registry.md`) |
|---|---|
| 13, 14, 15, 16 | physical damage low/high, magical damage low/high |
| 5, 6 | flat physical and magical defence |
| 11 | `'hra'`, attack rate |
| 9 | `'era'`, parry rate |

The 50 reads as **half of normal** rather than a flat +50: the same leading
argument position writes **100.0 as the neutral** when electric shock's
contribution is removed (round 275, `AbnormalState_Apply03_p9`), so 100 is
"unchanged" in this space and 50 is half.

**Is this the hunger gauge?** It is the obvious candidate -- a pet-side gauge
with a capacity and a penalty for running low -- but **no writer for `+0x68` was
found**, in the COS range or elsewhere, so nothing here ties it to feeding or to
`HGPFULL_NODRINK`. Recorded as a gauge with its numbers, not as hunger. The
probe that would settle it is the feed path (`CGItemExpendable::vslot_327`)
writing this field.