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
- **5 and 6** — both written by `GObjPC_HandleShopMsg_046` from a switch on the
  **interaction id the client sends**, not on an NPC type byte (corrected round
  449; see "The interaction id is the client's" below).
  Readers requiring 5: `GObjPC_HandleEndInteractionMsg_04b`, `FUN_0051b370`.
  Requiring 6: `GObjPC_HandleCOSSellMsg_0c7`, `FUN_005243d0`, `FUN_00526ce0`.
  **`GObjPC::EndInteraction` (0x5107c0) was on the "requiring 5" list and does
  not belong there** — it accepts `5 || 6`, so it discriminates neither.
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


## `chardata + 2` is the motion state, and `SetLifeState` carries a timer (round 415)

**A new byte in the chardata map.** `IGObj::GetMotionState` (slot 63) reads
**`chardata + 2`** — `CGObjCOS_Summoned::GetMotionState` is the proof, its body
being `return *(*(obj + 0x30) + 2)`. The map so far:

| offset | what | recovered |
|---|---|---|
| `+0` | life state | round 411 |
| `+2` | **motion state** | **round 415** |
| `+4` | the concurrency lock | round 360 |
| `+6` | exclusive-interaction state | round 361 |
| `+7` | pending-invitation byte | party ladder |
| `+0x11` | `SetCharacterState` kind `0xc` | round 361 |

**`SetCharacterState` does not write it.** The kind→field table above covers
kinds 2, 3, 6–10, `0xb`–`0xd` and `0xf`, and none of them touches `+2`, so the
obvious hypothesis — that the motion state is one of the dispatcher's fields —
is dead. Checked before looking further, and cheap.

**Neither byte is persisted.** `_CHAR`'s bindings in `db_bind_offsets.tsv` start
at `0x18`; nothing binds offset 0 or 2. Life state and motion state are runtime
only, which agrees with the berserk finding that `_CHAR` carries no duration or
expiry column.

### `SetLifeState` singles out state 2 with a timer

Reading the setter in full (`0x484a20`, slot 124) turns up a third fact about
value 2 that is independent of everything in the section above. Its real
signature is `(char state, undefined4, float)`:

	if (state == 0)       t = 0.0;                     // reset
	else if (state == 2)  t = *(float *)(this + 0x3c) + t;   // ACCUMULATE
	*(float *)(this + 0x3c) = t;
	chardata[0] = state;

**Only state 2 accumulates**, state 0 resets, and every other state leaves the
float alone. So the engine attaches a duration to state 2 and to no other — the
shape of a transient state a character is expected to leave, which is what
`GObjPC::Revive` does. Most callers pass `0`, so they extend the timer by
nothing; `FUN_004181d0` passes a real value read from `*(record + 0x18) + 0x84`.

The middle argument is `0xff` at every call site and **this implementation
ignores it** — and `CGObjChar::Create` initialises `chardata + 2`, the motion
state, to that same `0xff`. Suggestive of a "leave the motion state alone"
sentinel, but the only implementation never reads the parameter, so it is
recorded as an observation and not as a finding.

### Still open: what writes the motion state

**The values are named as of round 426** — `WALK`, `RUN`, `SIT`,
`SKILL_ACTIONOFF`, `SKILL_KNOCKBACK`, `SKILL_PROTECTIONWALL`,
`CHANGEMOTION`; see the vocabulary section at the end of this file. What
follows is about the WRITER, which is still not found.

Comparisons exist against **2, 3, 4, 15, 16, 17, 18** (round 414), but a census
of writes to `chardata + 2` finds exactly **one** — `CGObjChar::Create` storing
`0xff`.

**Round 416 chased both leads and one of them produced a CONTROLLED negative.**
The local-pointer shape (`p = *(char **)(X + 0x30); … p[2] = v`) finds nothing —
but its control also fails: that shape does not find the *known* `chardata[0]`
writer either, so it proves nothing. The shape that does recover
`CGItemMonsterCapsule::SetLifeState` is a cast-agnostic double-deref,
`*(T *)(*(T **)(X + 0x30) + 2) = v`. **With a passing control, that shape finds
ZERO writes to `chardata + 2` in the whole server binary.**

So `chardata + 2` is initialised to `0xff` by `CGObjChar::Create` and never
directly written again by any code this project can pattern-match. **That is not
the same as "never written"** — the invalid recovery this repo has recorded is
exactly "nothing writes it, so it is zero". What it does mean is that the writer
is not a plain field store: a bulk copy, a packet `memcpy`, or a path the
decompiler renders differently. The DB is ruled out (`_CHAR` binds nothing below
`0x18`).

**And only the TYPED comparisons are sound.** The second lead — that slot 63
spans hierarchies — is real: the quest classes' slot-63 implementations are
quest event handlers taking two arguments and returning void, not
`GetMotionState` at all. A census matching `(**(code **)(*X + 0xfc))()` on *any*
receiver therefore pools unrelated interfaces. Measured: **0 of the comparison
sites sit inside a quest class**, so round 414's numbers were not in fact
contaminated — but the enclosing function's class is not the receiver's class,
so that measurement bounds the risk without eliminating it. The values
`{2, 3, 4, 15, 16, 18}` from the typed sites, where the receiver is the calling
method's own `this` on a `CGObj`-derived class, are the part that is safe.

## The body-mode enum, read off the engine's own name table (round 425)

`IGObj::GetBodyMode` is vtable slot 64 (`+0x100`) and `IGObj::SetBodyMode` slot
198. The values were known only as bare numbers — "body mode 1 is Hwan; modes 0,
2 and 4 also appear at those call sites". **The engine names them itself.**

`FUN_00567190` formats one with `(&PTR_s_BODYMODE_NORMAL_00c64020)[mode & 0xff]`,
a string-pointer table. Read out of the PE:

| value | name |
|---:|---|
| 0 | `BODYMODE_NORMAL` |
| 1 | `BODYMODE_HWAN` |
| 2 | `BODYMODE_INVINCIBLE` |
| 3 | `BODYMODE_INVISIBLE` |
| 4 | `BODYMODE_BERSERKER` |

**The control is that index 1 is `BODYMODE_HWAN`**, which this project had already
established from a different direction, so the index really is the body-mode
value and not some other ordering.

**Modes 5, 6 and 7 are NULL in that table** — a genuine three-slot gap, after
which the array continues with a different enum entirely (`MSG_PROCSTATE_*`,
`PvPSTATE_NEUTRAL` / `_ASSAULTER` / `_MURDERER`, `BATTLESTATE_IN_PEACE` /
`_IN_BATTLE`). So the array is a shared debug-name region holding several
vocabularies back to back, and body modes 6 and 7 — which `FUN_00540de0` tests —
**exist in code and are unnamed by the engine**.

### What it settles in the AI target filter

Round 424 read `FUN_00540de0` as refusing a candidate whose `GetBodyMode()` is in
2..4, and 6 or 7 unless tactics flag bit 9 is set. In plain language that is:
**a monster will not target anything that is invincible, invisible or berserk**,
and flag bit 9 lets it target the two unnamed modes. That reading is now from the
engine's own strings rather than from the shape of the comparison.

### A naming trap: srrevamp's "berserk" is HWAN, not BERSERKER

`server/internal/berserk` keys on `GetBodyMode() == 1`, and that is **correct** —
in this game the berserk mechanic is Hwan (`RemainHwanCount`, `HwanLevel`,
`GObjPC::HwanGainChance`). `BODYMODE_BERSERKER` is a *separate* mode at value 4
and is not what srrevamp's berserk uses. Nobody should "fix" the 1 to a 4.

## The engine names all of these itself (round 426)

`FUN_00567190` is a **character-state diagnostic dump**, and it formats each
state by indexing a string-pointer table with that state's value. Reading those
tables out of the PE gives the engine's own vocabulary for eight enums at once —
and, because each index expression names the field it reads, the chardata offsets
with them.

### The vocabularies

| base | enum | values |
|---|---|---|
| `0xc63f80` | **LIFESTATE** | 0 `EMBRYO`, 1 `ALIVE`, 2 `DEAD`, 3 `GONE` |
| `0xc63f90` | **MOTIONSTATE** | 0 `STAND`, 1 `SKILL`, 2 `WALK`, 3 `RUN`, 4 `SIT`, 5 `JUMP`, 6 `SWIM`, 7 `RIDE`, 8 `KNOCKDOWN`, 9 `STUN`, 10 `FROZEN`, 11 `HIT`, 12 `REQ_HELP`, 13 `PAO`, 14 `COUNTERATTACK`, 15 `SKILL_ACTIONOFF`, 16 `SKILL_KNOCKBACK`, 17 `SKILL_PROTECTIONWALL`, 18 `CHANGEMOTION` |
| `0xc63fe4` | **INTERACTMODE** | 0 `NONE`, 1 `HANDSHAKING`, 2 `P2P`, 3 `MARKET_OWNER`, 4 `P2N_TALK`, 5 `P2N_DEAL`, 6 `OBJ_INTERACTMODE_OPNMKT_DEAL` |
| `0xc6400c` | **GROUPMODE** | 0 `SOLO`, 1 `PARTY_SETUP`, 2 `PARTY`, 3 `SOLOPARTY_SETUP`, 4 `SOLOPARTY` |
| `0xc64020` | **BODYMODE** | round 425's five |
| `0xc64040` | **MSG_PROCSTATE** | 0 `NORMAL`, 1 `BLOCKED`, 2 `OVERLAPPED` |
| `0xc6404c` | **PvPSTATE** | 0 `NEUTRAL`, 1 `ASSAULTER`, 2 `MURDERER` |
| `0xc64058` | **BATTLESTATE** | 0 `IN_PEACE`, 1 `IN_BATTLE` |

### The chardata offsets, from the index expressions

	chardata + 4    MSG_PROCSTATE
	chardata + 6    INTERACTMODE
	chardata + 7    GROUPMODE
	chardata + 0xc  PvPSTATE
	chardata + 0xd  BATTLESTATE

`+0` and `+2` are read through `GetLifeState` / `GetMotionState` rather than
directly here.

### What it confirms, and what it corrects

**LIFESTATE is a clean confirmation of rounds 411–413.** Those rounds proved from
typed use-sites that 1 is alive and 2 is dead, and explicitly labelled the claim
about 3 as weaker evidence — "consistent with removal-from-the-world, and it is
stated as such". The engine's word for 3 is **`GONE`**. Value 0, which
`CGObjChar::Create` writes, is `EMBRYO`: an object not yet born. The use-site
method got every answer right, including the one it declined to assert.

**MOTIONSTATE answers rounds 414–416.** Those rounds censused comparisons against
2, 3, 4, 15, 16, 17 and 18 and could not say what they meant. They are `WALK`,
`RUN`, `SIT`, `SKILL_ACTIONOFF`, `SKILL_KNOCKBACK`, `SKILL_PROTECTIONWALL` and
`CHANGEMOTION`. Round 416's controlled negative — that nothing writes
`chardata + 2` as a plain field store — is untouched by this; the values are
named, the writer is still not found.

**INTERACTMODE names the values this file already recovered by behaviour**: 0
idle is `NONE`, 1 "trade session opened" is `HANDSHAKING`, 2 "trade established"
is `P2P`. **One tension, recorded rather than smoothed:** this file also records
value **9** as the open-market state, from six `COpenMarketMgr::On*Req` handlers
requiring it, and index 9 of the table is **NULL** — the open-market name sits at
index 6. Both can be true if the debug table simply has no name at 9; nothing
here overturns the use-site evidence for 9, and nothing explains the gap.

**GROUPMODE refines round 361's reading of `chardata + 7`.** That round called it
"the pending-invitation byte". It is the party-membership mode, of which
`PARTY_SETUP` — an invitation outstanding — is one value of five.

## Body modes 6 and 7: a third independent appearance (round 442)

Round 425 read the engine's own body-mode name table and found indices 5, 6 and
7 **NULL** — modes that exist in code and that the engine does not name. They
have now surfaced three times, in three unrelated places:

| round | where | what it does |
|---|---|---|
| 424 | `FUN_00540de0`, AI target validation | refuses a candidate in body mode 6 or 7 **unless** tactics flag bit 9 is set |
| 425 | the `BODYMODE_*` string table at `0xc64020` | indices 5, 6, 7 are NULL — no name |
| 442 | `GObjPC_HandleBerserkMsg_0a7` (`0x515b30`) | refuses berserk with result code **5** when `GetBodyMode()` reads 6 or 7 |

So they are a real pair, checked by both the AI and the berserk path, and
deliberately unnamed in the debug table. **What they are is still unread** — but
three separate refusals agreeing that 6 and 7 are a special state is worth more
than any one of them, and it rules out the reading that they are stale or
unreachable values.

## One opcode carries every state change: `0x30bf` (round 444)

`GObjPC::BroadcastStateChange` (`0x4a8340`, 166 bytes) sends opcode **`0x30bf`**,
and **seven callers reach it, every one a state setter**:

	CGObjChar::SetLifeState        GObjPC::SetBattleState   (SetCharacterState case 8)
	CGObjChar::SetBodyMode         FUN_004e0b50             (SetCharacterState kind 0xb)
	GObjPC::FUN_004b1480           GObjPC::FUN_004e2940     (SetCharacterState kind 7)
	GObjPC::FUN_004d2bf0

So **life state, body mode and battle state all reach observers through one
message**, and the kind byte in it is the same state-kind vocabulary the
`SetCharacterState` dispatcher switches on.

**The payload**, read from the sender:

	guard    obj+0x188 != 0        -- no broadcast otherwise
	field 1  obj+8                 -- the object id
	field 2  u8  kind              -- in EBX; the vocabulary is below
	field 3  u8  value
	         ... when kind == 4 and value == 1, a further byte from chardata+5

`obj+0x188` was on this project's unnamed list; it is the broadcast guard.
**`chardata+5` is new to the map above** and is written into this message only
on that one branch.

### Why berserk has no success reply

Round 443 found that `GObjPC_HandleBerserkMsg_0a7`'s success path never calls the
refusal helper, and left "what the client learns on success" open. It learns it
here: the success path falls through to `SetBodyMode`, which broadcasts `0x30bf`.
**Success is observed, not replied** — which is why looking for a point-to-point
success reply found nothing.

The berserk exchange is therefore:

	request   0x70a7   u8, 1 = activate
	refusal   0xb0a7   u8 = 2, u16 = code in {1, 3, 4, 5}
	success   0x30bf   broadcast {objectId, kind, value}

**Still not enough to wire.** Which kind value means body mode is not pinned —
it arrives in `EBX` and Ghidra leaves it unresolved, so it needs the registers
read per caller, the same discipline round 441 applied to the reply opcode.

## The `0x30bf` kind vocabulary, read per call site (round 445)

Round 444 left "which kind value means body mode" open — it arrives in `EBX`,
which Ghidra leaves unresolved. Disassembling each of the seven callers at its
`call 0x4a8340`:

| caller | EBX | kind |
|---|---:|---|
| `CGObjChar::SetLifeState` | `xor ebx,ebx` → 0 | **life state** |
| `GObjPC::FUN_004b1480` | 1 | — |
| `GObjPC::FUN_004d2bf0` | 1 | — |
| `CGObjChar::SetBodyMode` | **4** | **body mode** |
| `GObjPC::FUN_004e2940` | 7 | `SetCharacterState` kind 7 |
| `GObjPC::SetBattleState` | 8 | `SetCharacterState` case 8 |
| `FUN_004e0b50` | `0xb` | `SetCharacterState` kind `0xb` |

**Three of them confirm the mapping independently.** The `SetCharacterState`
kind→field table at the top of this file was recovered in round 361 from the
dispatcher itself, and it records kind 7 as `GObjPC::FUN_004e2940`, case 8 as
`GObjPC::SetBattleState` and kind `0xb` as `FUN_004e0b50`. Those three agree
exactly with the registers read here. **So the broadcast's kind byte is the same
state-kind vocabulary the dispatcher switches on**, and kinds **0** (life state)
and **4** (body mode) are new entries in it.

**And kind 4 explains the broadcaster's one special branch.** It appends the
extra `chardata+5` byte when `kind == 4 && value == 1` — body mode set to
`BODYMODE_HWAN`. The special case *is* berserk.

## `AJStateChanger`'s record, and what kind 1 is not (round 446)

Chasing the one unidentified `0x30bf` kind — **1**, passed by `FUN_004b1480` and
`FUN_004d2bf0` — leads to a shared setter and a timed-state record.

**Both kind-1 broadcasters call vtable slot 343** (`0x4a9d00`, 228 bytes, shared
by `CGObjPC`, `CGObjChar`, `CGObjMob` and `CGObjCOS`), which sits in a **run of
state setters**:

	0x4a9c80  CGObjChar::SetLifeState     slot 124
	0x4a9d00  FUN_004a9d00                slot 343   <- this one
	0x4a9df0  CGObjChar::SetLocked        slot 342
	0x4a9fc0  CGObjChar::SetBodyMode      slot 198

It writes **ParamKeeper param 2** and, when handed a kind other than `0xff` and
a positive duration, schedules a timed change:

	if (kind != 0xff && duration > 0.0) {
	    assert(kind <= 0x14);
	    rec = AJStateChanger::FUN_00405f10(this);
	    *(float *)(rec + 0x10) = duration;
	    *(u8    *)(rec + 0x0c) = 1;
	    *(u8    *)(rec + 0x0d) = kind;
	    *(u32   *)(rec + 0x14) = 0;
	    *(u32   *)(rec + 0x18) = 0;
	    FUN_004066a0(rec);
	}

**`AJStateChanger` was already on record as the module handed a duration** —
`RE_COMPLETION.md` notes its per-tick behaviour and that "the tick's delta unit
was never actually read". **The record layout above is new**: an active flag at
`+0xc`, the kind at `+0xd` with the engine asserting it is at most `0x14`, and
the float duration at `+0x10`.

**That is the same signature `SetBodyMode(1, 0, duration, 0)` uses**, so this is
how a timed body mode — berserk's 60 s among them — is held in memory. It is
also why `internal/berserk` dropping the active window on logout is faithful:
the duration lives in an `AJStateChanger` record, not in `_CHAR`.

**Kind 1 itself is still unidentified.** Slot 343 is shared and its callers pass
different value ranges (2 or 3 from the COS path, `0xc` and `0x12` from
`FUN_004b1480`'s switch), so the kind covers more than one thing and this round
did not settle it.

**And one hypothesis is refuted.** `FUN_004aa3c0`, on the kind-1 path, looked
like a candidate writer for `chardata+2` — the motion state, whose writer round
416 could not find under a *passing* control. It does not write it. **Round
416's controlled negative stands.**
## The interaction id is the client's, not an NPC type (round 449)

The earlier note above said INTERACTMODE 5 and 6 come from "a switch on an NPC
type byte", and concluded that naming them "would be a guess" because no NPC
type vocabulary is grounded here. **The premise was wrong, and it was wrong in
the decompiler's favour.** Ghidra rendered `GObjPC_HandleShopMsg_046`'s switch
over a stack slot it had not tied to the message read, so the two appeared to be
different values. They are one slot:

	510320:  lea  ecx,[esp+0x14]     ; \ the u8 the client sent, read into esp+0x14
	510325:  call 0x521750           ; /  (MsgBuf_ReadUInt8)
	...
	510565:  movzx eax,BYTE PTR [esp+0x14]   ; the switch reads that same slot
	51056a:  add  eax,0xfffffffe             ; ids are biased by 2
	51056d:  cmp  eax,0x21
	510570:  ja   0x510612                   ; -> default

So the discriminator is **an id the client chooses**. The jump table covers
**2 through 35**; ids outside that window are not rejected, they take the
`default` arm like any other unlisted id (round 450 — the first write of this
said "the valid range is 2 through 35", which confused the table's extent with
the id space, and id **40** is observed at a real call site). The handler
validates the id against the NPC first:
`CGObjChar::HasAvailableInteraction(npc, id)` (`0x50cd80`) is a set-membership
test on `obj+0x1c78..0x1c7c`, and 0x046 refuses with code 5 when it says no.
**That set is named by the engine itself** — `CGObjChar::SetAvailableInteractionPerGObj`
(`0x4a9550`) inserts into the same pair, and `IGObj`'s base stub logs
`## Illegal ##  IGObj::SetAvailableInteractionPerGObj Entered!`.

### The whole jump table, read out

`0x510624` holds five targets and `0x510638` a 34-entry index byte per id:

| interaction id | target | what it does |
|---|---|---|
| **2** | `0x510584` | INTERACTMODE := **5**, then `this->[0x28c]()` |
| **10** | `0x5105f1` | INTERACTMODE := **5**, then `npc->[0x144](0x12, 0, this)` |
| **12** | `0x5105ca` | bails if `npc+0x1cf0` is 0, else `GObjNPCNPC::FUN_004c8a60`, INTERACTMODE := **6** |
| **35** (`0x23`) | `0x510428` | returns, **setting no mode at all** |
| every other id (in the table or not) | `0x510612` | INTERACTMODE := **6** |

Each target was read from instructions, not from the decompile. So **mode 6 is
the default** — the generic case for any id without bespoke handling — and mode
5 is reached by exactly two ids.

**Interaction id 2 is the talk menu.** Offset `0x28c` is vtable slot 163, and
slot 163 is `CGObjPC::ShowFirstTalkMenu` — named independently from `IGObj`'s
own assert, and the dump's RTTI plate for that function states the offset
`0x28c` itself. That is a use-site, not a curve: id 2 opens the menu, sets mode
5, and the two handlers that require mode 5 are the menu's own follow-ups.

### The vocabulary, from the readers (round 450)

Round 449 said the ids could only be named from the *writer* side, and looked
for it through vtable slot 156. That was the wrong side. **The 41 direct callers
of `CGObjChar::HasAvailableInteraction` each push a literal id**, and most of
their enclosing functions already carry recovered names, so the reader side
names the ids by itself:

| id | required by | sites |
|---:|---|---:|
| **0x01** | `FUN_00511860`, `FUN_005266a0`, `FUN_005267f0` — all three still unnamed | 3 |
| **0x02** | inlined in `CGObjNPCNPC::UseItem` (`mov BYTE PTR [esp+0x13],0x2` then the find) | 1 |
| **0x0f** (15) | `CGuildManager::HandleCreateGuild` **and** `GObjPC_HandleGuildMsg_0f1` | 2 |
| **0x17** (23) | `SiegeFortress_DispatchCommand` | 13 |
| **0x18** (24) | `SiegeFortress_DispatchCommand` | 3 |
| **0x19** (25) | `SiegeFortress_DispatchCommand` | 5 |
| **0x1a** (26) | `SiegeFortress_DispatchCommand` | 4 |
| **0x1b** (27) | `SiegeFortress_DispatchCommand` | 4 |
| **0x1f** (31) | `SiegeFortress_DispatchCommand` | 1 |
| **0x28** (40) | `SiegeFortress_DispatchCommand` | 1 |
| variable | `GObjPC_HandleShopMsg_046`, `JobGuild_HandleWithdraw`, `CInstanceCharTrijob::HandleJoinJobGuild`, `GObjPC_HandleAliasMsg_0e3`, `FUN_00512e70` | 5 |

Read from instructions (`push <imm>; push <obj>; call 0x50cd80`), with the
argument order confirmed against the callee's own frame: `[ebp+8]` is the object
and `[ebp+0xc]` the byte, so the **last** push is the object and the immediate
is the id.

**Id 15 is the guild NPC on two independent named readers.** That is the only id
here with two sources, and it is the one to trust most. **Id 2 is the talk menu**
independently of all this (round 449).

**Ids 23–40 were named in round 452** by reading the switch, as planned. They
are all siege-fortress roles, and each one is settled by the
`AQ_Siege::QUERY_SIEGE_*` function its block issues — the binary's own names:

| id | role |
|---:|---|
| 0x17 (23) | fortress administration — tax accumulate/collect, hired NPC, tax ratio, dungeon create/enter |
| 0x18 (24) | siege registration — request and request-remove |
| 0x19 (25) | fortress structures — add, upgrade, repair |
| 0x1a (26) | siege item forge, instance 0 |
| 0x1b (27) | siege item forge, instance 1 |
| 0x1f (31) | structure update |
| 0x28 (40) | **still unnamed** — its handler issues no query |

The full sub-command table and the twin-diff that split 0x1a from 0x1b are in
`docs/protocol/siege.md`.

**A coincidence to name before it causes a bug**: id `0x0f` is required by
`GObjPC_HandleGuildMsg_0f1`, whose opcode index is `0x0f1`. They are an id and
an opcode, they are not related, and the digits line up by accident — the same
trap `jobs.md` records for job kind 1 mapping to `0x14` beside a minimum level
of 20.

### The set's real writer, and a function that is dead code

Round 449 reported "no call of slot 156 on an IGObj anywhere". **That negative
holds, and an instruction-level probe makes it much stronger than the
decompiled-C grep did**: the whole server contains **8** loads of `+0x270`, and
every one is an `or DWORD PTR [reg],imm` bitmask write on an unrelated object —
not one virtual call. Control: the same pattern finds **64** loads of `+0x144`,
a slot that is demonstrably called.

What round 449 did not check is whether slot 156's implementation is called at
all. It is not: **0 direct calls to `CGObjChar::SetAvailableInteractionPerGObj`
(`0x4a9550`)**, against a control of **41** direct calls to
`HasAvailableInteraction` in the same sweep. Reached neither virtually nor
directly, it is **dead code in this build** — which is why looking for the
vocabulary through it could never have worked.

**RETRACTED (round 451): the paragraph that stood here named
`CGObj::AddAvailableInteraction` as the live writer of this set, on the strength
of the shared insert helper `0x486fe0` being inlined into `CGObjNPCNPC::Create`
and `CGObjStruct::Create`.** That helper is a `set<byte>::insert` instantiation
shared by *several different sets*, and attributing its call sites to this one
was the COMDAT/shared-helper trap. Reading the container pointer pushed at each
of its 11 sites settles it:

| container | sites |
|---|---|
| `obj + 0x130` | `CGObj::AddAvailableInteraction`, `CGObjNPCNPC::Create`, `CGObjStruct::Create` |
| `obj + 0x90` | `CGameServer::RefTeleport_ExtractData` ×2, `CGameServer::FUN_006a7f70` |
| a stack local | `RefObjItem::ExtractData` ×3 |
| **`obj + 0x1c78`** | `CGObjChar::SetAvailableInteractionPerGObj`, `CGObjChar::PublishAvailableInteractions` |

Single inheritance throughout (`CGObjPC : CGObjChar : CGObjMobile : CGObj :
IGObj : CBase`) puts every base at offset 0, so `+0x130` and `+0x1c78` are
genuinely different fields and not one field seen through two base pointers.

### Two sets, and the one that reaches the client

**`obj + 0x130` is the object's OWN offer list** — what this NPC or structure
provides — and `CGObj::AddAvailableInteraction` is the engine's name for adding
to it. `CGObjNPCNPC::Create` fills it from the NPC's ref record: a list at
`record + 0x94`, one **byte at `node + 0xc`** per entry, each gated by a virtual
test at slot `0x390`. So the offer list **is** table-driven, which is the one
thing round 450 got right.

**`char + 0x1c78` is the per-character set the readers test**, and its name says
so — `SetAvailableInteractionPerGObj`, *per GObj*. Only two functions write it,
and one of those is dead code, so the live writer is
**`CGObjChar::PublishAvailableInteractions` (`0x4a95a0`), vtable slot 227**. In
one pass it clears `+0x1c78`, walks `+0x130`, inserts each id, **and appends the
count and every id to the outgoing message**.

Its two callers are `FUN_0050faf0` (dispatch index `0x0c4`) and
`GObjPC::FUN_0052b040`, and both reply **`0xb045`** — the select-entity reply.
**That is how the client learns which interaction ids an NPC offers**, and it
closes the loop: the client picks an id from this list, sends it with `0x7046`,
and the server checks it back against the same set with
`HasAvailableInteraction`.

It also sets `requester + 0x728` — **the exact flag `GObjPC::EndInteraction`
clears** (round 449), which is why ending an interaction that was only selected,
never opened, still succeeds instead of refusing `0x1c0d`.
