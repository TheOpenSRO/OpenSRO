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
consecutive getters at vtable offsets `0x64` through `0x98`, **slots 25 through
38**, on the object the job holds at **`+8`** (`piVar2 = *(int **)(param_1 + 8)`).

**Not on the job.** This page said "on the job object" until round 274, and its
own slot count disproves it: `CTimedJob` is a **fifteen**-slot base, so it cannot
have a slot 38. The three common-data carriers have **39** slots each, which is
exactly enough, and the lookup helpers reach the category and id through the same
`+8` pointer. The getters belong to `ITimedJobCommonData`.

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
| 8 | `Tick(elapsedSeconds) -> keep?` — the countdown **and** the expiry test |
| 10 | `Release` — slot 9, then back to the chunk allocator |
| 12 | `Apply` — run over every job on demand, not on the tick |
| 25–38 | the fourteen column getters |

Slots 11 and 13 in the base point at functions shared across hundreds of
vtables (the 3-byte `return 0` and the 1-byte `ret`), so **nothing should be
read into them** — see `docs/RE_LOOP.md` on folding.

## How a job fires — READ (round 274, 2026-09-20)

A character's manager is **embedded in `GObjPC` at `+0x1dfc`** — the call site
passes `param_1 + 0x77f` on an `int *`, which is that byte offset, and it is the
same list the academy's checks walk. The pet's sits at `+0x1ce4` of its owner.

	CGObjPC::vslot_415            the PC's periodic update, ONE SECOND (round 223)
	  -> 0x6560c0(pc+0x1dfc, 0x3f800000)      CTimedJobManagerForPC::UpdateAndReapJobs
	       for each job:  keep = job->slot8(1.0f)
	       keep == 0   ->  manager->slot4(job) ; unlink ; job->slot10()

`0x3f800000` is `1.0f`, so **slot 8 takes the elapsed time in seconds and answers
whether the job lives**. Slot 10 calls slot 9 and returns the object to the chunk
allocator, decrementing the live counter at `0xd15c70`. Slot 12 is *not* on this
path: `0x656060` calls it on every job with no argument and no removal, from
`CGObjPC::vslot_391` and `GObjPC::FUN_004fbae0`.

### Two expiry styles, chosen by the job's own id

`CTJ_PenaltyKeeper::Tick` (`0x652080`) switches on the carrier's id (slot 27):

| id | how it expires |
|---:|---|
| 0 | a **countdown in the record**: the dword slot 28 returns and slot 13 writes is set to `round(remaining - elapsed)` while `elapsed < remaining`. At zero it asks the job's slot 17 whether penalty points remain and, if they do, **re-arms for `0x2a300` = 172,800 s = 48 hours**; otherwise it writes 0 and expires. The field is read **unsigned** — the `+ 2^32` fixup at `0xb45ba4` on a negative int |
| 1–5, 7–10 | an **absolute `__time32_t`**. `Create` stores `_time32(NULL) + span` through that same slot-13 setter (`0x975490` adds, `0x64a6f0` extracts, `+0x34` writes), and the tick compares it with the clock **only every ten seconds** |

The ten seconds are real and they are a float pair: the job accumulates the
elapsed time at `+0xc`, compares it with `10.0f` at `0xb45b44` (`fcomp`,
`fnstsw`, `test ah,0x1` — so the check runs at `>= 10.0`) and then **subtracts**
the `10.0` *double* at `0xb45c60` rather than resetting. The poll is periodic and
does not drift, and **a timestamp job can outlive its expiry by up to ten
seconds** — `timedjob.PollAccumulator`.

### Why the checks show no arithmetic

`GObjPC::HasTimedJob` (`0x411440`) and `GObjPC::FindTimedJob` (`0x4114d0`) walk
the list matching the carrier's **category** (slot 26, `+0x68`) and **id** (slot
27, `+0x6c`) against their two arguments, and nothing else. The presence of the
entry *is* the penalty; the clock work happens on the tick, not at the check.
That is why `academy.md` could find no literal at the invite and entry checks and
had to go to `Create` for the durations.

## Why this matters to srrevamp

srrevamp already has things this mechanism exists to hold and implements them
ad hoc: the death penalty, berserk's duration, skill cooldowns. The engine has
one machine for all of them, with one table, one manager per owner kind, and a
one-second sweep that is both the countdown and the test.

That is a design fact worth having before building a third ad-hoc timer.

## Not recovered

- **Which getter supplies which column.** The column NAMES are now in hand —
  `_TIMEDJOB` introduces `Category`, `JobID`, `TimeToKeep`, `Data3`…`Data8` and
  `JID` to the binary's schema pool (`docs/protocol/db_columns.md`), and
  `TimeToKeep` is the obvious candidate for the single `%I64d`. What is still
  unread is the mapping from those names to the fourteen getters at slots
  25..38, which needs the twelve kinds' overrides read.

  **Four of the fourteen are now grounded by use rather than by position**
  (round 274): slot 26 is the category and slot 27 the id that
  `GObjPC::HasTimedJob` matches on, and slot 28 -- record **field 4** -- is the
  dword the tick reads and slot 13 writes. Which means the expiry the RUNTIME
  uses is a 32-bit `__time32_t` in field 4, and is **not** the single `%I64d`
  column at field 13; whatever that wide column carries, the tick never reads
  it. `TimeToKeep` as the name for the `%I64d` was and remains a candidate.

  `_TIMEDJOBFORPET` introduces **no** names of its own, reusing `_TIMEDJOB`'s
  entirely — which is consistent with the pet record being the character record
  minus one field rather than a different shape.
- **The other eleven kinds' `Tick` bodies.** Slot 8 is read for
  `CTJ_PenaltyKeeper` (both styles) and `CTJ_CoolTimeKeeper` (which delegates to
  its target's slot 28); `CTJ_PremiumKeeper::vslot_008` is 2,874 bytes and
  unread.
- **What slot 17 counts** at the end of the penalty-points countdown. It gates
  the 48-hour re-arm, so it is "points still owed", but it is not read.
- **The `_TIMEDJOB` and `_TIMEDJOBFORPET` column layouts**, beyond their arity.
