# `SetCharacterState`, and the interaction state at `chardata + 6`

Round 360 named `chardata + 4` (the character lock, `docs/protocol/char_lock.md`)
and left the byte beside it unread. This is that byte, plus the dispatcher that
owns it.

Recovered 2026-09-21 (round 361). Everything below is from the server dump.

## The dispatcher

`CGObjPC::SetCharacterState` (`0x004f0ad0`) is **vtable slot 171**, named in an
earlier pass from the base class's own assert (`IGObj::SetCharacterState`). It is
not a setter for one field — it is a switch on a **state-kind code**, and the
kind selects which field of the character record gets written:

| kind | what it writes |
|---|---|
| 2 | `chardata + 6` — the interaction state, below |
| 3 | `chardata + 7` — the pending-invitation byte (`docs/protocol/party.md`) |
| 6 | `chardata + 8`, as an `int` |
| 7 | `GObjPC::FUN_004e2940(value)` |
| 8 | `GObjPC::SetBattleState()` |
| 9 | `chardata + 0xe` |
| 10 | `FUN_004e0b20()` |
| 0xb | `FUN_004e0b50(value, 0xff, 0, 0)` |
| 0xc | `chardata + 0x11` |
| 0xd | `FUN_004e0c20()` |
| 0xf | falls through to the tail |
| anything else | `Assert_BreakIfDebugger` |

The tail, reached only by kind `0xf`, refreshes a float through vtable `0x4b0`
when the value is 1 or 2 and then calls `FUN_004e0db0`.

**Kind 3 is independent corroboration of rounds 356–359**: this dispatcher, read
without reference to the party work, writes the same `chardata + 7` that the
invitation state machine turned on.

## The kind-2 field: an exclusive-interaction state

`chardata + 6` is an enum, not a flag. Values 0, 1, 2, 4, 5, 6, 7 and 9 all
appear, and roughly forty sites read it — trade, stall, open market, storage,
shop, siege, guild summon, party, academy and item use all gate on it. It says
which mutually-exclusive activity currently owns the character.

| value | meaning | what settles it |
|---|---|---|
| 0 | idle — nothing has the character | `GObjPC_HandleShopMsg_046` refuses to open a shop unless it is 0; `TrainingCamp_CheckCanEnter` likewise |
| 1 | trade session **opened** | `CTradeMgr::OpenTradeSession` writes 1 to **both** parties; `CTradeMgr::EstablishTradeSession` requires 1 |
| 2 | trade **established** | `EstablishTradeSession` writes 2; `CTradeMgr::Exchange` requires **both** parties at 2; equip attach/detach refuse |
| 9 | open market / consignment | all six `COpenMarketMgr::On*Req` handlers require 9 |

Values **4, 5, 6 and 7 are read but NOT named.** What is known about each:

- **7** — refused alongside 2 by `GObjPC_StorageManipulator::AttachEquipItem` and
  `DetachEquipItem` (`== 2 || == 7`), and `CGItemEquip::vslot_301`/`vslot_302`
  gate on it. So it is a second state in which the character's items are
  committed elsewhere, like an open trade. Which one is unread.
- **5 and 6** — both written by `GObjPC_HandleShopMsg_046` from a switch on an
  NPC type byte: cases 2 and 10 give 5, case 12 and the default give 6, and case
  0x23 sets nothing. **That NPC type vocabulary is not grounded in this repo** —
  the `TypeID4` tables in `ITEM_FORMAT.md` are for items, not NPCs — so naming 5
  and 6 from it would be a guess. Readers requiring 5: `FUN_00510660`,
  `FUN_005107c0`, `FUN_0051b370`. Requiring 6: `FUN_00511f40`, `FUN_005243d0`,
  `FUN_00526ce0`.
- **4** — written by `FUN_00515e90` beside 2 and 0; `CGObjPC::vslot_293` refuses
  when it is not 4.

## The writers of 7 and 9 are not in the direct-write set

Stated because it is a gap and not an oversight. Every direct assignment to
`chardata + 6` in the dump writes 0, 1, 2, 4, 5 or 6 — **nothing writes 7 or 9**,
yet six open-market handlers require 9 and four gates test 7.

The candidate path is `AJStateChanger::vslot_002` (`0x00405f70`), which writes
the byte from a *job* field rather than a literal:

	*(undefined1 *)(*(int *)(*(int *)(param_1 + 8) + 0x30) + 6)
	  = *(undefined1 *)(param_1 + 0xd);

So 7 and 9 most likely arrive through that asynchronous state-change job, whose
`+0xd` is filled by whoever queues it. **This is a lead, not a finding** — the
queuing sites were not traced.

## Also seen, not pursued

The slot-171 call sites are dominated by a large **`QNO_*` family** — scripted
quest objects with `OnEnterWorld`, `OnLeaveWorld`, `OnDead` and `OnUpdate`
handlers, already carrying the binary's own names (`QNO_CA_GORIA_7`,
`QNO_EU_IVY_3`, `QNO_TQ_BAEKRYOUNG_17`, …). They call kinds `0xd` and `0xf`, not
kind 2. That family belongs to the quest epic
(`docs/protocol/quest_*`), and is recorded here only so the next round does not
rediscover it.

## For srrevamp

**Nothing to wire yet.** srrevamp has no player-to-player trade, no stall and no
open market, so it has no second activity that could own a character. The value
of this round is that ~40 gates which read an unexplained byte now read a named
one, and that when trade is built, this is the state machine it has to match:
`OpenTradeSession` writes 1 to both sides, `EstablishTradeSession` moves both to
2, and equipment changes are refused from 2 onward.


## The life state, and the siege revive countdown (round 411)

`IGObj::GetLifeState` is **vtable slot 62** (`+0xf8`) and reads **`chardata[0]`**
— `CGObjCOS_Summoned::GetLifeState` is the whole proof: its body is
`return **(obj + 0x30)`, and `+0x30` is the chardata pointer. The setter is slot
**124** (`+0x1f0`), `SetLifeState`, and it is the **only** writer of that byte in
the binary.

**53 call sites pass a literal through the setter**, which gives the enum's shape
without guessing:

| value | sites | who writes it |
|---:|---:|---|
| 0 | 1 | `CGObjChar::Create` — the initial value |
| 1 | 2 | `GObjPC::Revive` (`0x4df290`) and `GObjPC::FUN_00482420` |
| 2 | 7 | `CGObjCOS_Pet::Create`, two `CGObjCOS_Mercenary` slots, three `GObjPC` paths |
| 3 | 42 | `CGObjMob::Update`, `REH_OnTrapped`, `CGSkillObject::Update`, `CGObjSiegeObject::Update`, ~30 `QNO_*::OnDead::Handle` quest handlers, `CGObjPC::DeleteMobForCatchQuest`, `CGObjCOS_*::vslot_401` |

**THE CLASS IN THE LEFT-HAND COLUMN IS THE CALLER, NOT THE RECEIVER, AND ROUND
412 NEARLY DREW A CONCLUSION FROM IT.** `CGObjPC::DeleteMobForCatchQuest` sets
state 3 on **the mob it deletes**, not on the PC; the `QNO_*::OnDead::Handle`
cluster sets it on the quest mob. A virtual call decompiles as
`(**(code **)(*X + 0x1f0))(3, …)` and gives `X`, not `X`'s class, so a census of
*which functions* write a value says nothing about *whose* life state is
written. Any argument of the form "only mobs write 3, so 3 is a mob state" is
unsound on this evidence, in both directions.

**1 is ALIVE**, and that is the engine's own word rather than an inference: the
"must be alive" guards answer `GUILDERR_IM_DEAD` and `0x6807` on
`GetLifeState() != 1`.

**2 IS NOT SIMPLY "DEAD", AND THIS ROUND DID NOT SETTLE IT.** The siege path
below made that reading tempting — a PC in state 2 counts down and is then
revived — but `CGObjCOS_Pet::Create` also leaves a newly created pet in state 2,
and a pet is not born dead. Meanwhile **3** is the value 42 sites write from
`Update` and `OnTrapped` paths, which is where a death would be set. So the
open question in `SYSTEMS.md`'s Party row — *what value 2 of the `0xf8`
life-state getter is* — is **narrowed, not closed**.

**Round 412 narrowed it again and still could not close it.** What that round
did settle is structural:

- `SetLifeState` takes **three** arguments, not one: every PC/COS site passes
  `(state, 0xff, 0)`, and `FUN_004181d0` passes a third value read from
  `*(record + 0x18) + 0x84`, so the third parameter carries something real.
- **Slot 219** (`+0x36c`, `0x490210`) is a base one-liner whose entire body is
  `SetLifeState(2, 0xff, 0)`, serving `CGObj`, `CGObjMobile`, `CGSkillObject`
  and `CGItem`. Four callers: `CGObjCOS_GoldPet::Update`,
  `CGObjCOS_SilkPet::vslot_368` and two `GObjPC::` functions.
- **Slots 306 and 307** are implemented per class — `CGObjPC` (`0x529b10`),
  `CGObjCOS_Pet`/`GoldPet`/`SilkPet` (`0x529f70`, `0x52d120`) and
  `CGObjCOS_Mercenary` (`0x529ed0`, `0x52d080`) — and the pet and mercenary
  versions set state 2.
- The pet contradiction from round 411 **dissolves**: `CGObjCOS_Pet::Create`
  sets 2 only when the bit at `record+0x38` is **clear**, so a pet is not born
  in state 2 — it is restored into it when its persisted record says it is not
  alive.

The best positive argument for 2 remains indirect: `GObjPC::Revive` sets 1 and
clears the death **cause**, and the one observed precondition for reaching it is
life state 2. That is consistent with 2 being "dead but revivable" and 3 being
"removed from the world" — the `Delete*` and quest-cleanup names fit — but
**consistency is not a use-site**, and typing the receiver of each `SetLifeState`
call is the work that would settle it.

### The siege revive

`CWorldContextController::UpdatePC` (`0x605010`) is slot 11 of the
world-context-controller hierarchy and its entire body is
`pc->PeriodicUpdate()`. One implementation serves slot 11 of five vtables —
default, flag, instance, battle-arena and data-driven worlds — so it is the base
that all inherit. **`CSiegeWorldContextController` overrides the same slot**
(`0x6055f0`) to call `CGObjPC::PeriodicUpdateInSiege` (`0x52d9b0`) instead,
which is the only caller of that function. That override is what establishes
slot 11's contract as *tick this PC*: it is read from the caller, not from any
one implementation's name.

`PeriodicUpdateInSiege` runs the ordinary `PeriodicUpdate` first, then — guarded
by `SiegeFortressMgr::IsWarPeriodActive()` — decrements a counter at `pc[0x735]`
for a PC whose life state reads 2. At zero it calls **`GObjPC::Revive`**
(`0x4df290`), which passes 1 through the `SetLifeState` slot and clears the death
**cause** byte at `+0x72d` together with `+0x28a` and `+0x738`, and records
`GameEventLog` `0x15` kind 2.

So during a fortress war a fallen player is put back on their feet on a timer,
rather than having to walk back. The countdown's **unit and starting value are
not read** — `pc[0x735]` is decremented once per one-second tick, so the unit is
seconds, but nothing here says what it is initialised to.


## Life-state 2 is the character's DEAD state, closed with a typed receiver (round 413)

Rounds 411 and 412 could not close this because every census grouped by the
*calling* function's class, and a virtual call gives the receiver expression,
not its type. The subset where the receiver IS typed is the one that settles it:
**a class-qualified method calling `GetLifeState` on its own `param_1`.** There
are **28** such comparisons in the server dump.

Three of them are `CGObjPC` on its own `this`:

| method | test | what it gates |
|---|---|---|
| `CGObjPC::PeriodicUpdateInSiege` | `== 2` | the countdown that ends in `GObjPC::Revive` |
| `CGObjPC::PeriodicUpdate` | `!= 2` | the PK-penalty work reading `charData+0xb4` (`PKPenaltyPoint`) |
| `CGObjPC::PeriodicUpdate` | `!= 2` (skip) | a `SetCharacterState(0xf)` branch that runs **only** in state 2 |

Put together with `GObjPC::Revive` — which sets **1** and clears the death
**cause** byte at `+0x72d` — the argument no longer needs an inference about who
the receiver is: **a PC in state 2 is one the engine revives into state 1, whose
PK-penalty processing is suspended, and who takes a state-2-only branch of the
one-second tick.** For a character, that is dead.

**The enum is shared by every `CGObj`-derived class, so "2" is better read as
NOT-ALIVE-BUT-PRESENT.** `CGItem::Update`, `CGObjSiegeStruct::vslot_306/307` and
`CGObjSiegeObject::vslot_306` all test their own `this` against 2 — an item and
a fortress building are not "dead" in the character sense. For a character the
two readings coincide.

**3 is not a character state on this evidence.** Of 162 `GetLifeState`
comparisons, 37 test against 3 and **none of those has a typed receiver**; the
writers of 3 set it on *other* objects (`CGObjPC::DeleteMobForCatchQuest` sets
it on the mob it deletes, ~30 `QNO_*::OnDead::Handle` on the quest mob). That is
consistent with removal-from-the-world and inconsistent with nothing — it is
weaker evidence than the above and is stated as such.

~~**Values 4 and 6 exist and are unread**: 7 comparisons against 4 … so the enum
is wider than 0..3.~~ **WRONG, retracted in round 414 — they are not life
states at all.** The probe that produced them scanned forward from the
`GetLifeState` call for a comparison of the assigned variable and **crossed a
reassignment**. In `CGObjMob::vslot_362` the decompiled C reads:

	cVar1 = (**(code **)(*param_1 + 0xf8))();      // GetLifeState
	if (cVar1 == '\x01') {                         // alive -- a REAL test
	  cVar1 = (**(code **)(*param_1 + 0xfc))();    // REASSIGNED: GetMotionState
	  if ((cVar1 != '\0') && (… cVar1 != '\x04')) // the "4" belongs to slot 63

Re-run with a guard that stops at any reassignment of the variable, the life
state is compared against **{1, 2, 3} and nothing else**, across 204 sites.

**The corrected figures strengthen the finding above rather than weakening it:**

| | comparisons | typed (receiver is the method's own `this`) |
|---|---:|---:|
| value 1 | 104 | 11 |
| value 2 | 62 | **20** |
| value 3 | 38 | **0** |

Twenty typed tests against 2 and **none at all** against 3. The three
load-bearing `CGObjPC` sites were each read out of their function bodies in
rounds 411 and 413 rather than taken from the probe, which is why the conclusion
survived its own tooling being wrong.

**The lesson is general**: decompiled C reuses one variable for many virtual-call
results, so a forward scan for a comparison MUST stop at reassignment. Without
that guard, every neighbouring getter's vocabulary leaks into the one being
measured.

### What that closes in the party ladder

`CParty::CheckTargetAvailable` (`0x514010`) — step 7 of the invite ladder —
accepts life state **1 or 2** and refuses with a bare `3` otherwise, while
`GObjPC::TrainingCamp_CheckCanEnter` refuses whenever the state is not 1. The
open question was *why the invite path accepts two states where the academy
accepts one*. The answer: **the party path accepts a dead character and the
academy does not.** You can be invited to a party while dead; you cannot be
enrolled in a training camp.
