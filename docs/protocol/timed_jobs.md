# Timed jobs

The engine's general mechanism for **"this expires at a time"**. It is not one
feature — it is the machinery twelve different features are built on, and
knowing that is most of what this page is for.

Implemented in `server/internal/timedjob`.

## What it is, from the class names

`CTimedJob` is a fifteen-slot base with **three pure virtuals** (slots 8, 10 and
12), and twelve concrete kinds derive from it:

| class | slots | what expires |
|---|---|---|
| `CTJ_PenaltyKeeper` | 19 | a penalty period |
| `CTJ_PremiumKeeper` | 16 | a premium subscription |
| `CTJ_CoolTimeKeeper` | 16 | a cooldown |
| `CTJ_CompositeItemKeeper` | 16 | a composed item |
| `CTJ_CharParamKeeper` | 16 | a character parameter |
| `CTJ_CompositeItemKeeperForPet` | 16 | the pet version of the above |
| `CTJ_SkillKeeper` | 15 | a skill |
| `CTJ_NoneSkillExpDateJob` | 15 | |
| `CTJ_SpecialTradeKeeper` | 15 | a trade-route state |
| `CTJ_OpenMarketTicketKeeper` | 15 | a market ticket |
| `CTJ_EnterWorldGroupKeeper` | 15 | a world-entry grouping |
| `CTJ_SkillKeeperForPet` | 15 | the pet version |

Three managers (`CTimedJobManager`, `…ForPC`, `…ForPet`, ten slots each) and
three 39-slot data carriers (`ITimedJobCommonData`, `CInstanceTimedJob`,
`CInstanceTimedJobForPet`) complete the family.

**`CTJ_CharParamKeeper` is the one worth noticing**: a timed job can hold a
ParamKeeper parameter, so a temporary stat is the same mechanism as a premium
period. Anything in `docs/protocol/param_registry.md` can be made to expire.

## The persisted record

Vtable slot 6 (`FUN_00650980`) is what writes a job to the database. It builds

	{?=CALL _ADDTIMEDJOB (%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%I64d,%d)}

— **fourteen columns, the thirteenth 64-bit** — and fills it by calling fourteen
consecutive getters on the job object, vtable offsets `0x64` through `0x98`,
which are **slots 25 through 38**.

### The mapping confirms itself

Arguments are pushed right-to-left, so the first getter evaluated (slot 38)
supplies the last argument and slot 25 supplies the first. That direction is not
assumed:

- Argument 13 is the only `%I64d`.
- Slot 37 (`+0x94`) is the only getter whose result the decompiler types as
  64-bit (`undefined8 uVar7`).
- 13 counted from slot 25 lands on slot 37.

**The one wide column and the one wide getter land on each other**, which fixes
the direction and the offset in one step. A 64-bit column in a table about
expiry is a timestamp.

### The pet record is the character record minus its first field

`FUN_0065fc60` builds

	{?=CALL _ADDTIMEDJOBFORPET (%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%I64d)}

from offsets `0x68` through `0x94` — slots **26** through **37**. Thirteen
getters, starting one slot later and ending on the same one.

So the pet row is the character row with **field 1 removed and nothing added**,
and the `%I64d` is last rather than second-to-last because the column that went
is the trailing `%d`, not the wide one. Field 1 is therefore something a pet
does not have and a character does — the obvious candidate is a character id,
and it is left as a candidate rather than a claim.

## The interface

| slot | what |
|---|---|
| 0 | destructor |
| 3 | `Create` — the engine's own name, from `CTJ_OpenMarketTicketKeeper::Create` |
| 6 | persist: builds and runs the `_ADDTIMEDJOB` call |
| 8, 10, 12 | `__purecall` — three methods every kind must implement |
| 25–38 | the fourteen column getters |

Slots 11 and 13 in the base point at functions shared across hundreds of
vtables (the 3-byte `return 0` and the 1-byte `ret`), so **nothing should be
read into them** — see `docs/RE_LOOP.md` on folding.

## Why this matters to srrevamp

srrevamp already has things this mechanism exists to hold and implements them
ad hoc: the death penalty, berserk's duration, skill cooldowns. The engine has
one machine for all of them, with one table, one manager per owner kind, and one
64-bit expiry column.

That is a design fact worth having before building a third ad-hoc timer.

## Not recovered

- **Which getter supplies which column.** The column NAMES are now in hand —
  `_TIMEDJOB` introduces `Category`, `JobID`, `TimeToKeep`, `Data3`…`Data8` and
  `JID` to the binary's schema pool (`docs/protocol/db_columns.md`), and
  `TimeToKeep` is the obvious candidate for the single `%I64d`. What is still
  unread is the mapping from those names to the fourteen getters at slots
  25..38, which needs the twelve kinds' overrides read.

  `_TIMEDJOBFORPET` introduces **no** names of its own, reusing `_TIMEDJOB`'s
  entirely — which is consistent with the pet record being the character record
  minus one field rather than a different shape.
- **What the three pure virtuals do.**
- **How a job fires.** The managers presumably poll, and nothing here says at
  what interval or through what.
- **The `_TIMEDJOB` and `_TIMEDJOBFORPET` column layouts**, beyond their arity.
