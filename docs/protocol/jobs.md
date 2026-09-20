# Jobs, trade routes and the flea market

The trader/hunter/thief system, its job guilds, the specialty goods they move,
and the player flea market. Implemented in `server/internal/jobs`.

49 codes match, across 22 server functions.

## Level 20 to take a job

Two unrelated functions enforce it, both through vtable slot 73 (`+0x124`, the
level getter) with the same comparison:

	FUN_005120f0 (join a job guild):      if (level < 0x14) -> 0x4819  JOBGUILD_JOIN_ERR_LEVEL
	GObjPC::SellItemAtSpecialtyShop:      if (level < 0x14) -> 0x184e  SPECIALTY_ERR_NOTTRADE

so **20** is the floor both for taking a job and for trading the goods a job
exists to move. Two independent readings of the same number.

## Three job kinds

The join handler reads one byte and accepts exactly three values:

	kind = ReadUInt8();
	if (kind == 1)      x = 0x14;
	else if (kind == 2) x = 0x15;
	else if (kind == 3) x = 0x16;
	else return 0x4828;

**Which kind is trader, hunter or thief -- READ (round 273).** The engine labels
them itself, twice and independently: `FUN_00466e70` switches on `GetJobType()`
(vtable slot 71) and `GObjPC::FUN_0060da10` on the job record's byte at `+0x1c`,
and both spell **1 "Trader", 2 "Robber", 3 "Hunter"** (0 "no job"; the second
prints "UNKNOWN" otherwise). `server/internal/jobs` now names them
`KindTrader`, `KindThief`, `KindHunter` (the old A/B/C remain as aliases) and
`Kind.Name()` returns the engine's words.

**A coincidence worth naming before it causes a bug:** kind 1 maps to `0x14`,
which is 20, and the minimum level is also 20. They are different things — an
identifier and a level — and they are equal by accident. The package has a test
whose only job is to say so.

## The flea market holds eight

`FUN_004734e0` refuses with `0x3c18` `FLEAMARKET_ERR_MARKET_FULL` when the entry
vector is that long:

	iVar2 = *(int *)(this + 0x198) - (int)begin;
	if (begin != NULL && iVar2 >> 2 == 8) -> 0x3c18

`>> 2` over a pointer difference counts 4-byte elements, so the vector holds
**eight** entries.

Its other refusals name the failure modes a hosted market has:
`FLEAMARKET_ERR_HOST_LEFT` (`0x3c15`), `FLEAMARKET_ERR_CLOSED_BY_HOST`
(`0x3c17`), `FLEAMARKET_ERR_INVALID_HOST_STATE`, `_IM_BUSY`,
`_CANT_OPEN_MARKET_IN_RIDESTATE`, `_INVENTORY_FULL`, `_NOT_ENOUGH_GOLD`.

The host-state check enumerates the states a host may be in:

	if (state != 5 && state != 4 && state != 6) -> INVALID_HOST_STATE

## Job items

`CGItemEquip::vslot_301` and `vslot_302` gate wearing a job suit. The refusals
enumerate the conditions:

| refusal | condition |
|---|---|
| `JOBITEM_WEAR_ERR_RIDE` | mounted |
| `JOBITEM_WEAR_ERR_PARTY` | in a party — tested twice, on `char[0x85e]` and on `char[0x734]` |
| `JOBITEM_WEAR_ERR_NOPOSITION` | no job position |
| `JOBITEM_WEAR_ERR_NOJOB` | no job |
| `JOBITEM_WEAR_ERR_NOALIAS` | no job alias set |
| `JOBITEM_WEAR_ERR_WEARLIMIT` | a wear limit |
| `STRGERR_CANT_DETACH_JOBITEM_IN_BATTLESTATE` | in combat |

**A job suit and a party are mutually exclusive**, which is the rule most likely
to surprise a reimplementation — and it is why `party.go`'s own match path
refuses with `JOBITEM_WEAR_ERR_PARTYMATCH`. The two systems check each other.

**None of the wear limits' numbers is recovered**; every branch above tests a
flag or a pointer rather than comparing a literal.

## Specialty goods

`GObjPC::SellItemAtSpecialtyShop` (736 bytes) and `GObjPC::FUN_00617f70`:

| refusal | meaning |
|---|---|
| `STRGERR_ONLY_TRADER_CAN_BUY_SPECIALTY` | only a job character may buy |
| `SPECIALTY_ERR_NOTSELL` / `_NOTTRADE` | the goods or the character cannot trade |
| `SPECIALTY_ERR_TRADESHOP` | wrong shop |
| `SPECIALTY_ERR_QUEST_NOTCOMPLETE` | a prerequisite quest |
| `STRGERR_CANT_DEAL_SPECIALTY_SINCE_TOO_FAR_FROM…` | a distance limit |
| `STRGERR_DONT_HAVE_ANY_TRADECART_TO_PICK_SPECIALTY` | goods need a cart |

**The distance limit's value is not recovered** — the check is a helper call,
not a literal comparison, which is the same shape the academy's 24-hour windows
have and is recorded the same way.

The cart requirement ties this system to `docs/protocol/pets.md`:
`CGObjCOS_Cart` is one of the six COS classes, and
`STRGERR_YOU_CANT_ACTIVATE_CART` is in the COS summon path. A trade run needs a
summoned cart, and the two systems meet there.

## The database surface

	_InsertCharTrijobSafeTradeData   3      _OpenMarket_Insert     17
	_DeleteCharTrijobSafeTradeData   1      _OpenMarket_Purchase    9
	                                        _OpenMarket_Cancle      6
	                                        _OpenMarket_Update      5
	                                        _OpenMarket_Receipt     3

`_OpenMarket_Cancle` is the engine's typo and is quoted as spelled.
`CInstanceCharTrijob` is the class; `trs_sm_partyjob` is a stored-procedure
wrapper in the same family.

## Not recovered

- ~~Which of the three kinds is which job.~~ **Recovered in round 273** and
  used again in round 295: **1 Trader, 2 Robber, 3 Hunter**, from two
  independent labellers (`JobTypeName` on `GetJobType()`, and
  `GObjPC::JobRecordKindName` on the job record's `+0x1c`). This bullet was
  stale; see "Three job kinds" above.
- Every numeric limit except the level and the market's eight slots: the
  distance, the wear limits and the trade-route reward rates are all behind
  helpers.
- The `_REFTREATITEMOFSHOP`, `_REFPRICEPOLICYOFITEM` and specialty-related
  reference tables, which are in the catalogue and unread.

## The job experience curve is leveldata's columns 6, 7 and 8 (round 295)

A `TrijobMgr` function (`0x0060dd90`) indexes the per-level table by the **job
level** (the job record's byte at `+0x1d`, minus one) and selects a column by
the **job kind** at `+0x1c` -- the same byte `GObjPC::JobRecordKindName` reads:

	kind 1 (Trader) -> the level row's +0x20   = leveldata column 6
	kind 2 (Robber) -> +0x24                   = column 7
	kind 3 (Hunter) -> +0x28                   = column 8
	anything else   -> Assert_BreakIfDebugger()

The column offsets follow the level record's packing, which four independent
readers pin (`docs/LEVELING.md`). So each job kind has its own per-level column
in the same `leveldata.txt` the character curve comes from, and the function
that reads it is the one maintaining the job record's running total at `+0x20`.

srrevamp models job kinds but not job levels, so this is recorded rather than
wired.

## The reward statement is issued for two kinds only (round 297)

`ExecAddTrijobReward` builds `EXEC _AddTrijobReward %d, %d`, and its first
argument is **not** the job kind. It is a remap of the job record's kind byte
at `+0x1c`:

	kind 1 (Trader) -> 3
	kind 2 (Robber) -> 2
	anything else   -> Assert_BreakIfDebugger(); return 0

That last branch is the same one a formatting failure lands on, so a kind
outside {1, 2} reaching this function is treated as a programming error. **The
statement is therefore only ever issued for Trader and Robber, never for
Hunter (3).** Why Trader maps to 3 rather than 1 is not read -- the procedure's
first parameter is evidently its own code space, not the kind enum.

The second argument is the async-query object's `+0`.

`ExecDeleteOldTrijobData` issues `EXEC _DeleteOldTrijobData %d` with its one
argument taken from the object's `+0x18`, **not a literal** -- so whatever age
threshold it deletes by is data, and there is no constant here to recover.
