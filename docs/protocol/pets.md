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
family runs 1 to 5 for all but a handful of rows — **not "and stops", which
round 423 measured as inexact**: the family also has TypeID4 **6, 7 and 8**,
a tail of quest-scripted objects (`MOB_QT_*_COS`,
`NPC_CH_QT_MOONSHADOW_COS`, `NPC_CH_QT_FLAMEMASTER_COS`) whose names all end
`_COS`. They are far too few to matter to the argument — the five-case switch
still covers every summonable row, and the tail is spawned by quest script
rather than from an item — but the table below is the first five of eight
values, not the whole range. The five rows' own counts were re-measured
against every `characterdata` shard in `Media.pk2` and are correct:

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
(`leveldata.txt`), which OpenSRO already loads as `leveldata.csv`. The link
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
- ~~**The hunger gauge**~~ **Recovered 2026-09-20 (round 300)** -- field,
  capacity, both thresholds, the penalty and the per-feed restore. See "The
  hunger gauge, end to end" below.
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

**It is the hunger gauge** -- settled in round 300 by the feed path, below.
## The hunger gauge, end to end (round 300)

The previous round found a pet gauge and declined to call it hunger because
nothing tied it to feeding. The tie is the **error code**, not a string:
`HGPFULL_NODRINK` is not in either binary -- it is the client's name for
**`0x18b3`** (`error_codes.md`), and the server emits that number.

Exactly one function does, and it is the feed:

	local_54 = (int *)piVar4[0xd];                    ; the pet's data record
	local_58 = (float)((uint)*(ushort *)(local_54 + 0x1a) * 100)
	           / (float)_DAT_00b45f90;                ; +0x1a on an int* = byte +0x68, / 10000.0
	if (_DAT_00b462e4 <= local_58) { *local_60 = 0x18b3; ... }   ; >= 99.0  -> "gauge is full"

`local_54 + 0x1a` on an `int *` is **byte offset `0x68`** -- the same field, read
through the same `/ 10000.0` percentage as the penalty test. That is the
citation the last round was missing.

| | |
|---|---|
| field | pet data record `+0x68`, a `ushort` |
| capacity | **10,000** (`_DAT_00b45f90`); every test is `value * 100 / 10000.0`, i.e. a percentage |
| full | **>= 99 %** (`_DAT_00b462e4`) refuses a feed with `0x18b3 UIIT_MSG_COSPETERR_HGPFULL_NODRINK` |
| low | **< 30 %** (`_DAT_00b45e58`) applies the half-strength penalty (round 299) |
| restored per feed | `item[0x2a0] * 10000 / 100`, i.e. `item[0x2a0] * 100`, asserted into **1..9999** |

The restore amount is **per item**, from the same `+0x2a0` strided array
`alchemy.md` documents, so there is no single "rate" constant to recover -- the
drink's own record carries it.

**A naming caveat worth more than the gauge.** The feed is **case 9** of
`CGItemExpendable` vtable slot 327, which this project named
`SetEngagedCOSforOpenMarket` by propagation from `CGItemCOSSummoner`. The
function is a multi-case dispatcher over expendable-item operations; the
propagated name describes one of its cases and would send a reader looking for
pet feeding anywhere but here. The row now carries that caveat.
## Round 795: pets, rides and transports, built

Round 795 built the COS from this page's rules plus five research passes over both binaries
(summoning and state, the pickup pet and its bag, riding, the client's CICCos and rider, the client's
windows). Labels as everywhere: READ (code, address), MEASURED (data), INFERRED, OURS, OPEN. The code:
`server/internal/cos` (rules, store, wire), `server/internal/session/cos*.go` (the runtime),
`client/scripts/net/cos_net.gd` / `cos_spawn.gd`, `client/scripts/npc/cos_table.gd`, World3D's COS
sections, `client/scripts/ui/hud/hud_cos*.gd`.

### The kinds (READ, MEASURED)

The summoned characterdata row's TypeID4 decides everything (TypeID 1/2/3/x; the client's CICCos is one
class for all, vtable `0xde211c`):

| TypeID4 | server class | client kind byte | what | summoned by |
|---:|---|---:|---|---|
| 1 | CGObjCOS (IsVehicle, slot 13) | 0 | ride: `COS_C_HORSE1..3`, `DHORSE`, `DONKEY`, `CAMEL`, the mall rides `COS_C_TIGER_n`, `OSTRICH_n`, `SCARABAEUS_n`, `PEGASUS_n`, `WILDPIG_n`, `UNICORN`, `RUDOLPH`, `DRACO` | 3/3/3/2 scroll, consumed |
| 2 | CGObjCOS_Cart (IsCart, slot 12) | 1 | transport `COS_T_*` | 3/3/3/2 scroll, consumed |
| 3 | CGObjCOS_GoldPet | 3 | growth pet; **every fellow pet** (`COS_P_FELLOW_*`, `COS_P_CELES_FELLOW_*`: TypeID4 3, MEASURED) | 3/2/1/1, kept |
| 4 | CGObjCOS_SilkPet | 2 | ability ("silk") pet: the pickup pet | 3/2/1/2, kept |
| 5 | CGObjCOS_Mercenary | 4 | guild soldier | not built |

The item mall's own names: `SN_TAB_PET_GROWTH` "Growth Pet", `SN_TAB_PET_SILK` "Ability Pet",
`SN_TAB_PET_FELOW` "Fellow Pet", `SN_TAB_VEHICLE` "Vehicle", `SN_TAB_CART` "Trans" (MEASURED,
textuisystem). A growth row is one of 140 per family (36 families, 5,040 rows, identical numbers per
level); col 6 (DescStrID) names the next level's row, which a level-up swaps to (0x30C9 type 7).

### Summoning (READ)

Use of a pet item (`CGItemCOSSummoner::CheckCanUse` s:0x493100): owner level >= 5 (0x186c); never
summoned (the item's Data word 0): the row Desc128_1 names, owner level >= its Lvl (0x18a5),
`CheckCanSummonCOS`, `_AddNewCOS` (HP = MaxHP, HGP 10000, State 3, 28 slots for an ability pet,
PetOption 1 growth / 7 ability, RentEnd = now + Param1 minutes); existing: alive (0x18a4), the level,
an ability pet's rent (0x18a4), CheckCanSummonCOS. **Using the item on a pet that is out recalls it**
(within 100.0, else 0x1897; a ridden one 0x1896). The item is never spent.

Use of a ride or transport scroll (`CGItemExpendable::vslot_307` case 2): the row is Desc1, or with a
level list in Desc128_2 (col 121) Desc1 + `_<largest bracket <= owner level>` -- the "HP changes with
the user's level" of the tooltip is a different row, not a formula; dungeon 0x1879; CheckCanSummonCOS;
the scroll is spent; the owner mounts at once when nothing refuses.

`CheckCanSummonCOS` (s:0x4fcef0): a ride or transport while riding or with one out 0x185c; a transport
needs job state 1 or 2 (a trader's or thief's suit) 0x1849; a pet: one per TID word, so one growth
and one ability pet at most (0x18a9).

Order on success: the use's reply, [a new pet: 0x3040 state 2], the 0x3015 (spawn type 1: the client's
summon effect and `snd_cos_summon`), 0x30C8 to the owner, [an existing pet: 0x3040 state 2], 0x30CA for
a growth pet or transport.

### The wire (READ, both sides)

**The CICCos spawn record** (server slot 294 mode 2; client CICCos slot 25 c:0x9c60b0): the NPC's
common body (u32 RefObjID, u32 uid, u16 region, f32 x y z, u16 angle, the mover, four stance bytes,
f32 walk, run, 100, u8 buffs) and u8 flags (no NPC bit-2 block), then by TypeID4: [3, 4] string pet
name; [2..6] string owner name; [2..5] u8 owner job; [2, 3, 5] u8 owner PvP; [5] u32 guild; [not 1]
u32 owner uid. A ride ends at its flags: its rider names it.

**The rider's record** (`pc_spawn.md` rows 24/25): ride state 1 adds the COS uid after the battle
byte; a rider's walk/run are its COS's.

| message | layout |
|---|---|
| 0x30C8 | u32 uid, u32 ref, u32 HP, u32 MP, [growth: u64 exp, u8 level, u16 HGP], [pets: u32 PetOption, string name], u8 bag size [u8 n, n x (u8 slot, item record)], [pets, transport: u32 owner uid], [pets: u8 the item's slot + 13] |
| 0x30C9 | u32 uid, u8 type: 1 removed; 2 u8 size, u8 n, items; 3 i64 delta, u32 source; 4 u16 HGP; 5 string name; 7 u32 new ref |
| 0x30CA | u32 uid, u8 mask, [1: u8 owner job], [2: u8 owner PvP] |
| 0x3040 | u8 slot + 13, u8 mask, ...; 0x40 u8 the item's COS state (1 none, 2 out, 3 in the item, 4 dead / expired), 0x80 u32 rent seconds |
| 0x70C5 / 0xB0C5 | u32 uid, u8 command: 1 the 0x7021 body (a rider's move), 2 u32 target, 8 u32 ground item, 9 follow. 0xB0C5 {u8 result, u8 command, [2: u16 code], u32 uid, [8: u32 item]} |
| 0x70CB / 0xB0CB | {u8 1 mount / 0 dismount, u32 uid}; success broadcast {1, u32 rider, u8 flag, u32 COS}, refusal {2, u16} |
| 0x70C6 / 0xB0C6 | u32 uid: a ride or transport deleted; {1} |
| 0x7116 / 0xB116 | u32 uid: a pet put away; no reply on success |
| 0x7117 / 0xB117 | u32 uid, string: a pet named once (1..12, no space); the name comes back as 0x30C9 type 5 to the owner and the area |
| 0x7420 / 0xB420 | u32 uid, u8 kind (1 a growth pet's AI mode, 2 an ability pet's pickup flags), u32 value; {1, u32 uid, u8 kind, u32 value} |
| 0x30D0 | u32 uid, f32 walk, f32 run: a dismount gives the rider its own speeds back |
| 0x7034 | 0x10 pet -> pet {u32 uid, u8, u8, u16}; 0x1a pet -> bag {u32 uid, u8 pet slot, u8 bag + 13}; 0x1b bag -> pet; 0xB034 0x11 a pet's pick {u32 uid, u8 slot, item record} |

The summon item's record (`SOItem::FUN_008be4f0`): after the RefItemID, u8 state; past 1 u32 the COS
ref, [pets: string name], [ability: u32 rent seconds], u8 0 timed jobs. Expendables carry u16 count
(+ u8 for the alchemy stones 3/3/11/1-2). OpenSRO's bag lists now carry these records too
(`session.retailItemTail`, `ItemInstance._read_tail`).

### Riding (READ)

Mount (s:0x4fc4d0): standing (5), owner's COS (7), not riding (5), a ride or transport (8), within
30.0 (4). The client then steers the COS: its moves go out as 0x70C5 command 1 and the server drops a
rider's own 0x7021; the echo 0xB021 is under the COS uid. The rider's speeds are the COS's, no
multiplier. A blow aimed at a rider lands on the mount; a mount at 0 HP is deleted and throws its
rider; the owner's death deletes the ridden COS. **Dismounting a ride deletes it**; a transport stays.
The client places the rider each frame at the mount's animated `saddle` bone times the mount's world
transform (ICharactor::FUN_009d05d0), plays the rider's "cart" group (0 `cart_stand01`, 1 and 7
`cart_walk`; MEASURED in all 53 player .bsr) and refuses its attacks and skills (0x3021).

### The pets (READ)

- Follow: IDLE turns to FOLLOW at 65.0 from the owner; FOLLOW runs to a point selfBC + ownerBC (4,
  MEASURED) + rand()%10+1 from the owner **on the owner's side** (round 796, below) and settles within
  selfBC + 50.0.
- The ability pet's pick is the CLIENT's: every frame, the nearest eligible ground item within 500 of
  the pet (squared 250000.0) is asked for with 0x70C5 command 8, one request out per pet; eligible by the
  flags 0x80 on, 0x40 every owner, 1 gold, 2 equipment, 4 the rest; never trade goods. The server runs
  the pet there, takes it within 10.0 (gives up past 1000.0) and routes it: gold to the owner's purse,
  a quest, untradeable or undroppable item to the owner's bag, anything else to the pet's bag (0x18b4
  full, 0x18b5 the owner's full). A refused item is not asked for again (the client's reply handler
  compares a byte with u16 codes, c:0x8af960: READ).
- The growth pet attacks what its owner's client names: its owner's offensive action in attack mode
  (PetOption 1) while it has no target; its blow is its row's col-83 skill, halved below 30 % HGP.
- Every kill its owner is paid for pays the growth pet the reward recomputed at the pet's level;
  OffsetExpPoint levels it below its owner and 110, else holds it at the threshold less one.
- Hunger: 100 / (Except_4 x 60) HGP a second, Except_4 = 5 on every growth row (MEASURED): 1 % every
  5 minutes; 0x30C9 type 4 at each 10 % mark; HGP 0 puts the pet away (slot 219: INFERRED).
- Regeneration 1.6 % of max HP every 4 s. An ability pet's rent is checked every 30 s.
- Consumables, each naming its pet: COS HP potions (3/3/1/4) by the user's potion formula; the HGP
  potion (3/3/1/9) +Param1 x 100, refused at 99 %; revival (3/3/1/6) alive with full HP and HGP 3000 if
  below; the clock (3/3/13/12) extends an ability pet's rent from max(end, now) by Param1 minutes.
- An out pet's item cannot be sold (0x18b7), traded (0x18b6) or stored (0x18b2).

### OURS, disclosed

- **Visibility**: a COS is delivered with its owner -- spawned right after the owner's spawn, despawned
  with it, its messages to whoever holds the owner -- where retail files it in its own message block.
- The server's tick (100 ms), the corpse (5 s), a leash that puts a pet 400 behind back at its follow
  point beside its owner (round 796: retail's FOLLOW has no distance cap and no teleport, READ).
- Monsters do not target a COS: a pet's blows are booked to its owner, whom the monster answers.
- A logout keeps every COS summoned and brings it back at the next entry, a ride remounted (retail's
  normal-logout reason is OPEN; reason 4 deletes a ride).
- Not modelled, so not refused: the battle state, the quest block, the teleport state, PvP capes and
  murderers, job suits -- so a transport, which needs a trader's or thief's suit, is always refused
  0x1849 (retail's own rule).
- OpenSRO's own use-item message carries a pet consumable's target as option 0xC5 and a u32 (the COS
  uid, or the pet item's bag index for the revival and the clock); retail's 0x704C carries it after
  the type word.
- 0x3057's COS HP rides OpenSRO's head: owner kind 2, the uid, flag 1, u32 HP.
- The COS ids are 0x7e000000 + n.

### Round 796: what the client draws for a rider, a mount and a pet (READ, sro_client.exe)

- **Facing.** A COS model faces -Z like every monster's (MonsterMotion.MODEL_FRONT, round 637) and its
  skeleton is not turned under its body, so a heading h is rotation.y = h - PI. Round 795 used 0: every
  pet and mount ran backwards.
- **The rider's weapon and shield are not drawn.** `CharacterVisualChange::CObjItem::vslot_003`
  (0x4e8830) answers 0 (not shown) for an item in equip visual slot 6 or 7 (weapon +0x80, shield +0x8c)
  while `CObjCharacter::FUN_00a5be70` says the body has a mount (+0x34 -> `FUN_009ce930`, +0x2ac).
- **No buff is hidden by riding.** The riding state (12) does nothing: its table entry (initialiser
  0xd772a0) points at two bare `ret`s (0xa59ba0, 0xa59bb0) and clears states 2 and 13 (0x2004 at
  0xec61bc). What riding changes is where an effect sits, `IDecoSkill::FUN_00a4a680`:
  - no StartBone and no StartOffset (a "none" or "*" row): the **mount's** matrix, at the rider's own
    position -- the mount's feet, turned with it. The speed potions and scrolls and Grass Walk
    (`lightning_gyeonggong_keep_a/b.efp`, ACT_L, bone none, offset 0) are such rows;
  - a bone the rider's model has: on the rider (on the saddle);
  - a bone it lacks: looked up on the mount's model (the loop's `param_1 = FUN_009ce930()`);
  - an offset with no bone: the rider's own frame.
- **Plates.** `FUN_009cef40`: a CICMonster's or a CICCos's (0xeef6f0) name shows only while its rider
  link +0x2b0 (`FUN_009ce910`) is empty, so a ridden mount has no plate; CICCos slot 15 draws the owner
  line under the same test, 20.0 screen pixels above the name (`fsub 0xe1b830`). A ride (TypeID4 1)
  reads no name or owner at all (`CICCos::vslot_034`: only TypeID4 2, 3, 4 and 6 do). The rider's plate
  (`FUN_009d0a80`) is at the mount's +0x22c + 7.0 (0xda7c60), everyone else's at their own + 2.0.
  +0x22c follows +0x228, which CICCos slot 28 (0x9c7780) sets to 20.0 x FUN_009c7740 = 20.0 x
  [+0x728]+8 x scale, [+0x728] being the ref's skilleffect.txt `characterInfo` row
  (`FUN_009ca510` -> `FUN_00a95d30`) and +8 its Size (column 3) x 0.5 (`FUN_00a9ae80`, 0.5 at
  0xe1b7d0). The row is found by code, then by the ref's +0x5c, then the default -- the first row
  registered (`FUN_00a9ae30`: CHAR_CH_MAN_ADVENTURER, Size 2). So a tiger's rider's plate is at
  1.8 x 10 + 7 = 25, a horse's 32, Rudolph's (no row) 27. INFERRED: +0xc4 (scale) is 1.0.
- **The pet's name is plain.** `CICCos::vslot_034` converts the record's name (`FUN_004fc7f0`, ANSI to
  wide) and sets it; there is no "< %s >" anywhere in the client. A private server's "< Jeremy >" is
  its own.
- **Speed.** Riding, the rider's speeds are the mount's (s:0x4aa410, no multiplier, round 795): a buff
  started or ended while riding does not change them; the dismount's 0x30D0 gives the buffed foot speed.

### Round 796: FOLLOW's point and the arrival (READ, SR_GameServer.exe)

- `FUN_00549ac0`: the point is the owner's position plus the owner's side vector -- the facing
  (+0x24..) crossed with up, (-fz, 0, fx) times a sign -- at selfBC + leaderBC + rand()%10+1. The sign is
  -1 when a cross product of the pet->owner vector and the pet's own direction is under 0.0078125
  (0xade894); the side vector is then snapped to the nearest of 36 table directions (`FUN_0053dad0`:
  acos against (1, 0, 0) x 57.29578 / 10.0, rounded; the table at 0xce2030 is filled by 0x54ab10 at 5,
  15, ... 355 degrees). OpenSRO keeps the pet on the side it is on (INFERRED) and does not snap (OPEN).
- No branch of FOLLOW teleports a pet; the further test against 100.0 (0xb45af0) only chooses which
  point to run to.
- An owner's arrival (a teleport, a zone change) spawns its pets again with the summon's 20.0 hatch
  spread (s:0x4fbae0, INFERRED that the argument is a spread); round 795 put them on the owner.

### OPEN

The FOLLOW side's exact sign and its 36-direction snap (round 796); the code names 0x1869, 0x1896, 0x1897; slot 219's exact effect (hunger 0, rent end); where a pet's
corpse is cleared; the pet-bag extension's slot count; monster aggro on pets; the guild soldier; the
transport's trade goods and Sell All.
