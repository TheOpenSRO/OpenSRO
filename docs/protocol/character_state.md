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

> **PARTLY SUPERSEDED (round 456).** Value **9 IS directly written** — once, by
> `OpenMarket_BeginSession` — and the census below missed it because it grepped
> decompiled C for a one-step `chardata + 6` store while that site writes in two
> steps (`iVar2 = in_EAX[0xc]; *(iVar2 + 6) = 9`). Value **7** survives the
> re-check and its negative is now much stronger. See "Value 9's writer, and a
> census redone with the right instrument" at the end of this file.

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

> **SUPERSEDED (round 499).** This section used to say "nothing to wire yet"
> because srrevamp had no player-to-player trade. It has one now
> (`internal/trade`, `internal/session/trade.go`), and the trade half of this
> state machine is wired. Stall and open market are still not built.

The trade's two modes are modelled on `trade.Hub`, not stored as a byte:

- **Mode 1 is `trade.Hub.Busy` without `Established`.** `CTradeMgr::OpenTradeSession`
  (`0x0047f620`) writes 1 to **both** parties, and its only caller is the
  trade-request handler `GObjPC_HandleTradeMsg_081` (`0x005154e0`). So a
  pending request holds its target as well as its sender, and `Busy` is true for
  both.
- **Mode 2 is `trade.Hub.Established`.** `CTradeMgr::EstablishTradeSession`
  (`0x0047f970`, called from `trs_wait_response::vslot_002` `0x0046cb30`) moves
  both parties to 2 when the target accepts.

Two gates read those modes:

- **The NPC-service gate.** `GObjPC_HandleShopMsg_046` (`0x00510250`) refuses
  with `0x1c0b` `UIIT_MSG_INTERACTION_FAIL_IM_BUSY` while the byte is non-zero.
  That handler opens every NPC service. srrevamp refuses these while `Busy`:
  - the shop buy and the shop sell;
  - the warehouse list, deposit, withdraw and gold requests;
  - a repair. Its result carries the code, `0x1c0b` (`session.interactionBusyCode`).

  The shop *list* is not refused, because it only prices goods.
- **The equip lock.** `CGObjPC::AttachEquipItem` (`0x00524cd0`) and
  `DetachEquipItem` (`0x005255e0`) return `0x1811` when the byte is 2 or 7.
  Their only route is op 0 of `CGObjPC::StorageOperation` (`0x0050f5c0`), and
  that function's own guard (`0x50f7cd`–`0x50f7e3`) runs first. At 2 or 7 it
  answers `0x1834` `UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED` for every op
  except 4, 5 and 0xd, so the engine's equip refusal is sent as `0x1834`
  (round 499, read on review). srrevamp refuses an equip or unequip while
  `Established`. A pending request (mode 1) passes both tests, so it does not
  lock equipment. The same guard also refuses an ordinary bag move during an
  accepted trade. srrevamp does not model that yet.

**The adaptation, disclosed.** The engine refuses once, when an NPC
interaction is *opened*. srrevamp has no interaction-open message, because its
shop, storage and repair opcodes are stateless placeholders
(`PROTOCOL_DECISION.md`). So it applies the same test to each operation
instead. The reverse direction is not modelled. In the engine, an open NPC
interaction (mode 5 or 6) also refuses a trade request, through
`GObjPC::FUN_004ea050`, which requires the byte to be 0. It refuses in two
places:

- **The requester.** `GObjPC_HandleTradeMsg_081` (`0x005154e0`) runs the check
  on the requester first and answers on its own path: `0x181d`, or `0x1833` at
  mode 2 or 7.
- **The target.** `CTradeMgr::OpenTradeSession` runs the check on the target and
  answers `0x181e` (`0x47f6e0`).

Neither route gives `0x1811` (`RE_COMPLETION.md`, round 499). srrevamp has no
open-interaction state that could hold that. The two refusal texts are
srrevamp's own wording, because the client has no message for either `0x1c0b`
or `0x1811`.

### The trade request reads the same byte (round 500)

The NPC half above is still not modelled. The **trade** half of those two
checks now is, because the trade modes are the ones srrevamp keeps. Read
from `GObjPC_HandleTradeMsg_081`, the request handler:

- **Mode 2 or 7 on the requester: `0x1833`.** srrevamp answers "already
  trading" when the requester is `trade.Hub.Established`.
- **Mode 1 on the requester: cancel and reopen, not a refusal.** At mode 1,
  081 does not answer `0x181d`. It looks up the requester's pending session
  (`param_1[0x730]`):
  - if the new target is already a party to it (`FUN_0047f5b0` returns 1),
    it drops the request with no reply;
  - otherwise it closes the old session through the cancel handler
    `GObjPC_HandleTradeMsg_084` (`0x005159c0`, `0x182c` to both parties) and
    goes on to the range check and a new session.

  `OpenTradeSession` writes 1 to **both** parties, so this applies to the
  target of a pending request as much as to its sender. A character is never
  in two trade sessions at once. `session.handleTradeRequest` does the same:
  `trade.Hub.PendingOf`, then `cancelPendingTrade`. `trade.Hub.Request`
  refuses a requester already in a request (`ErrRequestPending`) as defence
  in depth.
- **Any non-zero mode on the target: `0x181e`.** srrevamp answers "target is
  busy" when the target is `Busy` in any phase. That now includes being the
  *sender* of a pending request. Before round 500 only an incoming request or
  an open trade made a target busy.
- **The remaining conditions of `FUN_004ea050` are not modelled:** a dead
  character, GROUPMODE 1, and INTERACTMODE 4, 5, 6 or 9. On the requester they
  give `0x181d`, and on the target `0x181e`. srrevamp keeps none of those states
  for a trade request to read.

Between the mode checks and `OpenTradeSession`, 081 measures the pair and
refuses `4` (TOO_FAR) unless they are closer than 320.0 (`trade.RequestRange`).
The full ladder, and the codes that close a pending request later, are in
`error_codes.md`, "The trade request's codes (round 500)".


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
| **0x01** | `FUN_00511860`, `FUN_005266a0`, `FUN_005267f0` — the item-sale check, see below | 3 |
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

**Three of the five "variable" readers were resolved in round 453**, and the
variable turned out to be a small fixed mapping rather than an open value:
`0x14`, `0x15` and `0x16` are **the Trader, Thief and Hunter job guilds**. The
job handlers map a job kind to one of those three and gate on it; the full
argument, with three independent readers, is in `docs/protocol/jobs.md`. That
makes ids **0x14–0x1b one contiguous run of NPC roles** — three job guilds, then
the five fortress roles.

**Id 1 is the item-sale gate.** Its readers are not dispatch handlers but
entries in the storage operation table that `FUN_0050ce80` fills (alongside the
already-named `CGStorage::TradeOfferItem`). `FUN_005267f0` is a validator, and
the codes it returns are the client's own names: count below 1 →
`UIIT_MSG_STRGERR_SPECIFY_POSITIVE_NUMBER_ONLY`, a slot below the equipment
boundary → `UIIT_MSG_STRGERR_CANT_SELL_EQUIPED_ITEM`, an out-of-range slot →
`0x1806`, and a target that does not offer interaction 1 → code 3. **The sale
guard is what identifies it**; that it therefore names the shop role in general
is an inference and is not claimed here — the function serves two operation
codes (9 and 0x14) and only code 9 carries the sell check.

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

## An NPC interaction, end to end (round 454)

Rounds 449–453 recovered the pieces one at a time. This is the whole path, with
the address that does each step. Every arrow was read; none is assumed.

	refdata boolean column
	  -> CGameServer::RefTeleport_ExtractData (0x6a7be0) and friends insert an id
	     into the ASSOCIATED REF OBJECT's set at  record + 0x90       (load time)
	  -> CGObjNPCNPC::Create (0x4c6350) walks record+0x90, reads each node's
	     byte at +0xc, and copies it into the OBJECT's own set at  obj + 0x130
	  -> CGObjChar::PublishAvailableInteractions (0x4a95a0, vtable slot 227)
	     clears  char + 0x1c78 , refills it from obj+0x130, and APPENDS the count
	     and every id to the outgoing message
	  -> that message is the 0xb045 select-entity reply (its two callers,
	     FUN_0050faf0 at dispatch index 0x0c4 and GObjPC::FUN_0052b040, both
	     reply 0xb045).  THE CLIENT NOW KNOWS WHICH IDS THIS NPC OFFERS.
	  -> the client sends 0x7046 with {u32 entity, u8 interaction id}
	  -> GObjPC_HandleShopMsg_046 (0x510250) refuses 0x1c0b if INTERACTMODE is
	     already non-zero, then calls CGObjChar::HasAvailableInteraction
	     (0x50cd80) to check the id back against  char + 0x1c78 , refusing 5
	  -> its jump table sets INTERACTMODE: id 2 -> 5 and ShowFirstTalkMenu,
	     id 10 -> 5, id 12 -> 6, id 35 -> nothing, everything else -> 6
	  -> the service's own handler re-checks the id (41 such gates)
	  -> 0x704b -> GObjPC_HandleEndInteractionMsg_04b -> GObjPC::EndInteraction
	     resets INTERACTMODE to 0 and replies 0xb04b{1}, or refuses 0x1c0d

**The ids are data, not code.** That is the round's finding. `teleportdata.txt`
columns 9 and 10 are booleans that register ids 7 and 9 on the gate object
(`docs/protocol/teleport_network.md`), and a second loader registers id 8 the
same way from a byte at its row's `+0x34`. So which services an NPC offers is a
table, and srrevamp can in principle read the same columns rather than hardcode
a list.

**The gap, stated plainly.** Only **three** registration sites are found, and
they account for ids **7, 8 and 9** only. Ids 1, 2, 0x0f and 0x14–0x1b — every
id whose *meaning* rounds 450–453 recovered — have **no located registration**.
The probe was a census of direct calls to the `set<byte>` insert helper
`0x486fe0`, and that probe would miss an inlined insert, which this binary
demonstrably does elsewhere (`CGObjNPCNPC::UseItem` inlines the matching *find*).
So the negative is weak and should not be read as "those ids are registered
nowhere". **Next probe:** find the insert by its shape rather than by the
helper's name — the tree-insert tail, or writes to `+0x94` in the same function
as a `lea reg,[... + 0x90]`.

**One discrepancy left open rather than papered over.** The id-8 registrar
(`0x6a7f70`) reads its record at `+0x30`, `+0x34` and `+0x38`, but its caller
`CGameServer::FUN_006b5200` is listed in `refdata_tables.md` as the inserter for
a table whose record is **0x1c bytes** — which those offsets overrun. The caller
allocates 0x1c and then passes the result of `FUN_0071fff0` on it, so either the
recorded size belongs to a handle rather than the record, or the table
attribution is wrong. **Id 8 is therefore not attributed to a table here.**

## The interaction-id vocabulary, from the NPCs themselves (round 455)

Round 454 left a weak negative: only three registration sites were found (ids 7,
8, 9 from refdata), and every id whose *meaning* rounds 450–453 recovered had no
located registration. **Both halves are now resolved.**

The shape-based probe round 454 called for was run first — a census of the
containers passed to the `set<byte>` **find** helper at all 39 of its sites,
which catches an inlined find-then-insert that a helper-name census would miss.
It returns 27 sites on `char+0x1c78`, 3 on `obj+0x130` and 3 on `record+0x90`,
**matching the helper-name census exactly**. So there are no hidden inserts, and
round 454's negative was right for a better reason.

The registrations are **virtual calls**. `CGObj::AddAvailableInteraction`
(`0x484e40`) is **vtable slot 89** (offset `0x164`) — computed from table
`0xaec0a4`, where the address sits at `0xaec208`, and checked against the same
table's slot 227 at `0xaec430` holding `0x4a95a0`, which is known independently.
Its body is two lines: ask slot `0x390`, and insert into `this+0x130` if that
answers 0.

**`CGObjNPCNPC::Create` calls slot 89 thirty-two times with literal ids, each
behind a comparison against the NPC's own CodeName.** That is the vocabulary:

| id | registered on |
|---:|---|
| **1** | `WAREHOUSE`, `NPC_*_HORSE`, `NPC_*_GUILD`, `NPC_*_FORTRESS_OFFICIAL`, `NPC_*_FORTRESS_BATTLEAIDE` — **five families** |
| **3** | `WAREHOUSE`, `NPC_SD_*_AREA_WAREHOUSE` |
| **4** | `NPC_*_SMITH`, `NPC_*_ARMOR`; also `NPC_*_FORTRESS_SMITH` |
| **0xb** | the `NPC_*_HORSE` block, beside id 1 |
| **0xc** | `NPC_TD_THIEF_BUY`, `NPC_*_SPECIAL*`, `NPC_SD_GUILD_AGENT*` |
| **0xd** | the `NPC_TD_THIEF_BUY` block, beside 0xc |
| **0xe** | `NPC_CH_GENARAL_SW`, `NPC_WC_GENARAL_SW`, `NPC_KT_MINISTER` |
| **0xf** | `NPC_*_GUILD`, `NPC_CH_GENARAL_SP` |
| **0x11** | the `NPC_SIEGE_DUNGEON_TELEPORT` block, beside 0x28 |
| **0x12** | `NPC_CH_GACHA_OPERATOR` |
| **0x14** | `NPC_*_MERCHANT`, `NPC_*_DOCTOR`, `NPC_KT_DESIGNER` |
| **0x15** | `NPC_TD_THIEF_SELL`, `NPC_SD_T_AREA_THIEF` |
| **0x16** | `NPC_*_HUNTER`, `NPC_*_GENARAL_SW`, `NPC_KT_MINISTER` |
| **0x17** | `NPC_*_FORTRESS_MANAGER*` |
| **0x18** | `NPC_*_FORTRESS_OFFICIAL` |
| **0x19** | `NPC_*_FORTRESS_BATTLEAIDE*` |
| **0x1a** | `NPC_*_FORTRESS_SMITH*` |
| **0x1b** | `NPC_*_FORTRESS_TRAINER*` |
| **0x1e** | `NPC_CH_SOLDIER_EM1`, `NPC_EU_ADVICE3` |
| **0x1f** | `STRUCTURE_GATE_PULLEY_{JA,BJ,HT}_0n` |
| **0x20** | `NPC_*_SMITH` |
| **0x23** | `NPC_OPEN_MARKET_JUEL` |
| **0x27** | `NPC_FWORLD_RECALL_PARTY` |
| **0x28** | `NPC_SIEGE_DUNGEON_TELEPORT` |
| **0x29** | `NPC_INS_EXIT_TELEPORT` |
| computed | `NPC_BATTLE_ARENA_MANAGER`, `NPC_BATTLE_ARENA_EXCHANGER` |

### Why this is trusted: ten independent agreements

The attribution method is a heuristic — the codename strings compared between
one registration and the next. What makes it safe is that **ten of these ids
were already named from the reader side, by unrelated evidence, and every one
agrees**:

| id | named earlier as | codename here |
|---:|---|---|
| 0x0f | guild (`CGuildManager::HandleCreateGuild`) | `NPC_*_GUILD` |
| 0x14 | Trader job guild | `NPC_*_MERCHANT` |
| 0x15 | Thief job guild | `NPC_*_THIEF*` |
| 0x16 | Hunter job guild | `NPC_*_HUNTER` |
| 0x17 | fortress administration, tax | `FORTRESS_MANAGER` |
| 0x18 | siege registration | `FORTRESS_OFFICIAL` |
| 0x19 | fortress structures | `FORTRESS_BATTLEAIDE` |
| 0x1a | siege item forge | `FORTRESS_SMITH` |
| 0x1f | `QUERY_SIEGE_STRUCT_UPDATE` | `STRUCTURE_GATE_PULLEY_*` |
| 0x0c | the "Trader Registered, TradeRisk" path (round 449) | `THIEF_BUY`, `*_SPECIAL*` |

Ids 0x15 and 0x16 are the strongest: the codenames literally read `THIEF` and
`HUNTER`, matching names derived in round 453 from a completely different route.

### Three earlier items closed or corrected

- **Id 0x28 is named.** Round 452 could not reach it — its handler issues no
  database query. It is `NPC_SIEGE_DUNGEON_TELEPORT`, which fits a handler that
  reads a `u32`, requires the player alive, and ends in a slot call.
- **Round 452's "forge instance 1" is corrected.** 0x1a and 0x1b run the same
  forge code with selector 0 and 1, and round 452 declined to say what the two
  instances were. They are different NPCs: **0x1a is the fortress SMITH, 0x1b the
  fortress TRAINER.**
- **Round 450's declined data point is vindicated.** That round saw the client's
  `0x7046` sender pass id **3** from an `IFStorageRoom` context and refused to
  use it as evidence. Id 3 is `WAREHOUSE`.

### What id 1 actually is

Round 453 read id 1 as the item-sale gate and deliberately stopped short of
calling it "the shop NPC". That caution was right: id 1 is registered on
**five unrelated families** — warehouse, stable, guild hall and two fortress
NPCs. It is not a role but a **shared capability**, which is exactly why its
readers are storage-table entries rather than a dispatch handler.

### A lead on the INTERACTMODE 9 gap

Round 361 recorded that **nothing directly writes INTERACTMODE 9** (open market)
although six handlers require it. Id **0x23** is `NPC_OPEN_MARKET_JUEL`, and
`case 0x23` of the `0x046` switch is the one arm that **returns without setting
any mode**. The open-market NPC therefore takes its own path to mode 9. That is
a lead, not a finding — the path was not traced.

## Value 9's writer, and a census redone with the right instrument (round 456)

Round 361 recorded that "every direct assignment to `chardata + 6` in the dump
writes 0, 1, 2, 4, 5 or 6 — **nothing writes 7 or 9**", and carried that as a
gap for ninety-five rounds. **Half of it was a probe defect.**

Redone at instruction level — every direct byte store to `[reg+0x6]`, which no
decompiler shape can hide:

| value | sites |
|---:|---:|
| 0 | 13 |
| 1 | 9 |
| 2 | 4 |
| 4 | 1 |
| 5 | 2 |
| 6 | 2 |
| **9** | **1** |
| 7 | **0** |

**Value 9 is written**, at `0x51b5bd`. The old census missed it because that
site stores in two steps — `iVar2 = in_EAX[0xc];` then `*(iVar2 + 6) = 9` —
while the grep looked for a one-step `chardata + 6` form.

**`OpenMarket_BeginSession` (`0x51b580`) is that writer**, and three independent
things identify it:

- it is reached **only** from `GObjPC_HandleShopMsg_046`'s `case 0x23`, which is
  the one arm of that switch that returns **without setting a mode itself**;
- interaction id `0x23` is registered on **`NPC_OPEN_MARKET_JUEL`** (round 455);
- mode 9 is required by all six `COpenMarketMgr::On*Req` handlers (round 361).

So the lead round 455 left — "the open-market NPC takes its own path to mode 9"
— is now the finding, with the path named.

### Value 7 survives, and the obvious escape route is closed too

7 is written by **no** direct store, now confirmed at instruction level. The
natural next hypothesis is the dispatcher: `CGObjPC::SetCharacterState`'s
**kind 2** arm writes `chardata+6` from its value argument (`0x4f0b16`), so any
value could arrive that way. **It does not.** A census of all 98 call sites of
slot 171 by *(kind, value)* finds only kinds `0x0d` and `0x0f` passed as
literals — **kind 2 is never used** — plus four sites passing both from
registers.

**A probe defect caught before it was published.** The first run of that census
reported "kind 2, ×2" and would have closed the question wrongly. `SetCharacterState`
is `ret 0x8` and its written value comes from `[esp+0x14]`, which is **arg2** —
so the *kind* is the last push, not the first, and the two sites are really
`(kind 0x0f, value 2)`. Reading the callee's own frame is what fixed it.

**What remains for 7** are the register-sourced writers. Round 457 read all
three and **two are false positives** — the census matched any struct with a
byte at offset 6, not only chardata:

	AJStateChanger::vslot_002  +0xbc   GENUINE -- round 361's candidate
	CGObjPC::FUN_004de300      +0xd9   CGObjPC's own constructor, a different field
	FUN_0050fda0               +0x18   a copy constructor, copying byte 6 of another struct

So exactly one genuine indirect writer exists, and round 457 traced it.

## Value 7: read everywhere, written nowhere (round 457)

Round 456 left value 7 as the last unnamed INTERACTMODE. It is now audited from
both ends, and the result is a shape worth recording rather than a name.

### The reads are real, checked at instruction level

Round 361 said `AttachEquipItem` and `DetachEquipItem` refuse on `== 2 || == 7`.
That reading survives the strongest check available:

	524d0c:  mov eax,DWORD PTR [esi+0x30]   ; the chardata pointer
	524d0f:  mov al,BYTE PTR [eax+0x6]      ; INTERACTMODE
	524d12:  cmp al,0x2
	524d1a:  cmp al,0x7

Ten `cmp al,0x7` sites across the two functions, every one reading
`chardata + 6`. Two of them lead to `Assert_BreakIfDebugger` — a debug tripwire
— and the rest jump to the real refusal. **7 is a genuinely tested state.**

### No literal path writes it

Four routes exist into `chardata + 6`, and **7 uses none of them**:

| route | result for 7 |
|---|---|
| a direct byte store `mov BYTE PTR [reg+0x6], imm` | **0 sites** (round 456's census) |
| `CGObjPC::SetCharacterState` kind 2 | **kind 2 is never passed as a literal** at any of slot 171's 98 sites |
| an `AJStateChanger` job with kind 2 | **no `mov BYTE PTR [reg+0xd],0x7` exists anywhere in the binary** |
| the remaining register-sourced writers | two of the three were false positives (see above) |

**What this does NOT license.** It does not say value 7 is dead. A computed or
copied value can still reach the byte, and this project has a standing rule
against exactly that inference — "nothing writes param N, so it is zero" is an
invalid recovery. What is established is narrower and still useful: **no code
path in this binary sets INTERACTMODE to 7 from a constant**, so if 7 occurs it
is carried in from data or copied from another character's state.

### A bonus: `AJStateChanger` is the deferred `SetCharacterState`

Reading the job body settled something else. `AJStateChanger::vslot_002` counts
down a float at `+0x10` and, on expiry, switches on `+0xc` and applies `+0xd` —
and **its kind vocabulary is `SetCharacterState`'s**, which independently
corroborates round 361's kind table from a second function:

| kind | `SetCharacterState` writes | `AJStateChanger` writes |
|---:|---|---|
| 0 | — | vtable `0x1f0` = `SetLifeState` (round 411) |
| 2 | `chardata + 6` | `chardata + 6` |
| 3 | `chardata + 7` | `chardata + 7` |
| 6 | `chardata + 8` | clears bits in `chardata + 8` |

So the engine has an immediate state change and a **delayed** one sharing one
kind enum. Kind 0 landing on `SetLifeState`, named in round 411 by a completely
separate route, is the check that this is the same vocabulary and not a
coincidence.

## Two interaction-set readers the census missed, and one confirmation (round 470)

Round 450 censused the readers of the interaction set by counting **direct
calls** to `CGObjChar::HasAvailableInteraction` — 41 of them. That round flagged
the risk that an *inlined* check would be missed, and two are:

	004c95d3   id 0x1f   GObjPC::FUN_004c95c0
	0051bc09   id 0x27   GObjPC_HandlePartyRecallMsg_519

Both inline the whole check — `mov BYTE PTR [esp+N],<id>`, `lea esi,[reg+0x1c78]`
for the container, `lea edi,[esp+N]` for the key, then the find helper — so no
call to the named function appears at all.

**One of them independently confirms round 455.** That round attributed ids to
NPCs by a *heuristic*: the codename strings compared between one registration
and the next. Id `0x1f` came out as `STRUCTURE_GATE_PULLEY_*`. The inlined
reader for `0x1f` sits in `GObjPC::FUN_004c95c0` — the function whose own log
string is **"Siege Fortress Pulley CodeName is not registered!!"** (round 451).
A registration-side heuristic and a reader-side instruction agreeing on the same
id is the check that heuristic needed.

**The other gives id `0x27` a reader**, where round 455 had only a registration:
the party-recall handler at dispatch index `0x519`, refusing
`UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_PARTY`, against an NPC registered as
`NPC_FWORLD_RECALL_PARTY`.

## The client's first talk menu (round 513)

The rounds above read the interaction set from the **server** side: which ids an
NPC is registered with, and which handlers read them. This section reads the
**client** side: how `sro_client.exe` turns the NPC's interaction set (talk object
`+0x7c0`, the set the 0xb045 reply handler also reads, round 512) into the numbered lines of
the first talk menu. Read from the client dump (`/var/tmp/decomp_client`),
checked instruction by instruction in `sro_client.asm`, and with the string
addresses read out of `.rdata` in `/opt/sro-files/client/sro_client.exe`.

### The chain

	FUN_00701540 (0x701540)
	  FUN_006fb530(this+0x7d4)
	  n = FUN_00700440()          -- every numbered line but the last
	  FUN_007001a0(n)             -- the end line

- **`FUN_006fcd60(n, item, sub)` writes one line.** It formats `"%d. "`
  (`.rdata 0xdace24`, pushed at `0x6fcdd5`) with the running number `n`. It then
  appends the text of one string id, chosen by a two-level switch on `item`: a
  byte index table at `0x6fd394` (`0x6fce4d` `movzx ecx,byte [ebp+0x6fd394]`),
  then the dword jump table at `0x6fd2d8` (`0x6fce54` `jmp [ecx*4+0x6fd2d8]`).
  It returns `n + 1`. Most cases name a
  `UIIT_*` or `SN_*` token, resolved through `textuisystem.txt`. Cases 5-8 use
  raw Korean literals (round 512). Case 1 runs `FUN_006fb630`, which writes its
  own `"%d. "` line per store. `sub` picks the job-guild variant in cases
  0x1e-0x24.
- **Item 0 is the end line.** Case 0 looks id `0x1f` up in the talk object's set
  (`0x6fce7e`). If the NPC has it, the text is `UIIT_STT_NPC_CHATTING_WND_TALKEND2`
  (`.rdata 0xdadd70`, `0x6fce9c`). Otherwise it is
  `UIIT_STT_NPC_CHATTING_WND_TALKEND` (`.rdata 0xdadd28`, `0x6fcea6`). Id `0x1f`
  is registered only on `STRUCTURE_GATE_PULLEY_*` (the vocabulary table above), so
  every ordinary NPC gets TALKEND.
- **`FUN_007001a0` emits item 0 only when the talk object's `+0x7f1` byte is
  set** (`0x7001a3` `cmp byte [esi+0x7f1],0`, then `0x7001b0`-`0x7001b5`
  `push 0; push 0; push n; call 0x6fcd60`), and clears it after. In
  `FUN_00700440` the one write of 1 is at `0x70150e`, and it happens when id 2 is
  **absent** from a second set, at `[0x110f80c]+0x4fc` (`0x7014c7`-`0x70150c`).
  The owner of that set is not named.
- **Item 3 is the storage line.** Case 3 names
  `UIIT_STT_NPC_CHATTING_WND_STOREHOUSE` (`.rdata 0xdadcd8`, `0x6fced4`).

### Interaction id to menu item, in `FUN_00700440`'s order

Every lookup is the set's `find` (`0x534ef0`) with the id stored as a byte just
before the call. The address in each row is that byte store (row 1 gives the
call instead). A present id is the
`cmp [eax+0x4],end` membership test that follows.

| order | id looked up | if present | text |
|---:|---|---|---|
| 1 | 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1f, 0x28 | `FUN_00700200` (`0x70074f`): `IF_NPCTalk::FUN_006fe030` items 0x33, 0x34, 0x32, 0x36, 0x37, 0x35, 0x42 | a second item switch, not read here |
| 2 | 0xc (`0x700770`) | a line with no number, behind two tests | `UIIT_MSG_SAFETRADE_PROGRESS_NUMBER` |
| 3 | 0x13 (`0x7008cb`) | the text passed to `FUN_006fb530`, with no number | `UIIT_MSG_XMAS_EVENT_SO-OK` |
| 4 | 2 (`0x700920`) | item 4 | `UIIT_STT_NPC_CHATTING_WND_TALKSTART` |
| 5 | 1 (`0x700982`) | item 1 (`0x700afe`). With 0xf also present, only if `FUN_009870e0()` answers nonzero (`0x7009fc`). With 3 also present, only if `FUN_00989d20(...)` does (`0x700a71`) | `FUN_006fb630`'s per-store lines |
| 6 | 4 (`0x700b12`) | nothing: no membership branch (round 512) | — |
| 7 | 3 (`0x700b48`) | item 3 (`0x700b7a`); item 0x2d if `FUN_00987130()+0x20` is 0 and the byte at `[0xeef5ec]+0x868` is at least 0x3c (`0x700b86`-`0x700b9d`); then item 0x2e always (`0x700bb4`) | `..._WND_STOREHOUSE`; `UIIT_STT_TC_OPEN`; `UIIT_STT_TC_HONOR_RANKING` |
| 8 | 0x20 (`0x700bd2`) | item 0x2f | `UIIT_STT_AVATAR_MAGICOPTION_ENCHANT_MAGIC_PARAM` |
| 9 | 5 (`0x700c15`) | nothing: no membership branch | — |
| 10 | 7 (`0x700c57`) | item 9 | `UIIT_CTL_RECALL_POSITION` |
| 11 | 9 (`0x700ca7`) | item 0x10 | `UIIT_CTL_TELEPORT_TO_RESURRECT_POS` |
| 12 | 8 (`0x700cfb`) | lines with no number for the desert-gate company shares (`UIIT_PAG_COMPANY_*`), then item 0xa | `UIIT_CTL_TELEPORT_TARGET` |
| 13 | 6 (`0x700fa2`) | item 0xb | no token of its own (case 0xb shares case 1's tail) |
| 14 | 0x1e (`0x700ff6`) | `UI_ITEM::FUN_006f98d0`, behind the class test `FUN_00b94b90(0xef1ac4)` | not read here |
| 15 | 0xf (`0x70105e`) | `FUN_009870e0()` 0: item 0x12. Otherwise, by `FUN_00989ce0(...)`: items 0x17, 0x14, 0x18, 0x1b, or item 0x1c alone; then 0x19 or 0x1a (by `FUN_0099da70`), 0x1d, 0x43 | `UIIT_CTL_GUILD_CREATE`; `UIIT_MSG_GUILD_LEVEL_UP`, `UIIT_CTL_GUILD_BREAK`, `UIIT_CTL_MASTERLEAVE`, `UIIT_CTL_GUILD_COMPENSATION` / `UIIT_CTL_GUILD_SECESSION`; `UIIT_CTL_MASTERRELEASE` / `UIIT_CTL_MRELEASE_VOTE`, `UIIT_CTL_GUILD_WAREHOUSE`, `UIIT_STT_GUILD_GP_HISTORY` |
| 16 | 0x13 (`0x701182`) | item 0x15 | `UIIT_MSG_XMAS_EVENT_CHANGE` |
| 17 | 0xa (`0x7011c8`) | item 0x16 | `UIIT_MSG_CIRCULATION_WITHDRAW_SKILL` |
| 18 | 0x14, 0x16, 0x15 | `IF_NPCTalk::FUN_006fdeb0(n, 1 / 3 / 2)` | not read here |
| 19 | 0x11 (`0x7012da`) | item 0x27 | `SN_TALK_CH_GACHA_MACHINE_2` |
| 20 | 0x12 (`0x701320`) | item 0x28 | `SN_TALK_CH_GACHA_OPERATOR_2` |
| 21 | 0x23 (`0x701366`) | item 0x3f | `SN_NPC_OPEN_MARKET_START` |
| 22 | 0xc (`0x7013ac`) | item 0x39 | `UIIT_PAG_SPECIAL_PRICE_CONDITION_INFO` |
| 23 | 0x1c (`0x7013f2`) | item 0x2a, behind `FUN_00b94b90(0xef1dac)` | none (0x2a is outside the switch and does not advance `n`) |
| 24 | 0x27 (`0x70144a`) | item 0x3d | `UIIT_PAG_PARTY_SUMMON` |
| 25 | 0x29 (`0x701490`) | item 0x3e | `UIIT_STT_DUNGEON_EXIT` |
| 26 | 2, in `[0x110f80c]+0x4fc` (`0x7014e5`) | absent: set `+0x7f1`, so the end line follows | — |

The functions named `FUN_*` in the conditions are unnamed tests. The order
column matters, because the numbers are assigned in this order. A warehouse
keeper (server ids 1 and 3) therefore gets item 1 only if `FUN_00989d20`
answers nonzero and `FUN_006fb630` finds a store. It then gets the storage line,
`TC_OPEN` behind its gate, `TC_HONOR_RANKING`, and the end line.

### The text: two layouts of `textuisystem.txt`

The player's archive on the render box holds each of these tokens **twice**. It
has an earlier 16-column row with the English at `[8]`, and a later 19-column
row with `0` at `[8]` and the English at `[9]` (read with
`client/tools/dump_text_table.gd`):

| token | 16-column row, `[8]` | 19-column row, `[9]` |
|---|---|---|
| `UIIT_STT_NPC_CHATTING_WND_STOREHOUSE` | Deposit items/gold into storage. | Deposit into storage. |
| `UIIT_STT_NPC_CHATTING_WND_TALKEND` | End conversation. | End conversation. |
| `UIIT_STT_NPC_CHATTING_WND_TALKEND2` | End. | End. |

`UiTextTable` keeps the later row (`client/scripts/ui/ui_text_table.gd`, which
picks `[9]` when `[8]` is `0`). So the storage line reads "Deposit into
storage.". Which layout the real client reads was not established.

### What srrevamp does with it

`NpcServiceReader` carries the storage line's token (`STOREHOUSE_STRID`) and
the end line's (`TALKEND_STRID`). `NpcServiceReader.talk_menu_lines`, which
`HudPanels.open_npc_talk` calls with its `_resolve_ui`, resolves both through
the player's text table. It falls back to the English label when the archive
has no text, and numbers the lines `"%d. "` as `FUN_006fcd60` does. It prints
one `NPCTALK` log line per menu line.

**Most town warehouse keepers get three lines in srrevamp, not two.** The player's
`refshopgroup.txt` lists 8 of the 9 warehouse keepers `npcpos.txt` spawns as running a
store. `NPC_WC_WAREHOUSE_M` is the exception: it spawns beside `NPC_WC_WAREHOUSE_W`,
but WC's second HONOR row names `_W` again, so `_M` runs no store and gets two lines
(storage, end). Measured
with `client/tools/dump_text_table.gd` on the render box's `Media.pk2`
(`--file=server_dep/silkroad/textdata/refshopgroup.txt --grep=WAREHOUSE`), there
are 9 rows. Col 3 is `GROUP_STORE_*_HONOR` and col 4 the keeper:
`NPC_CH_WAREHOUSE_M`, `NPC_CH_WAREHOUSE_W`, `NPC_WC_WAREHOUSE_W` (twice),
`NPC_KT_WAREHOUSE`, `NPC_EU_WAREHOUSE`, `NPC_CA_WAREHOUSE`,
`NPC_SD_M_AREA_WAREHOUSE` and `NPC_SD_T_AREA_WAREHOUSE2`. The extracted copy
`/var/tmp/tables/refshopgroup.txt` agrees. `NpcServiceReader.parse_shop_npcs`
therefore puts each keeper in the shop set, and `services_for` returns
`[shop, storage]` in that order. At `NPC_CH_WAREHOUSE_M` the menu is:

	1. Buy                     (srrevamp's own label, no strid)
	2. Deposit into storage.   (STOREHOUSE, the later 19-column row)
	3. End conversation.       (TALKEND)

`npc_service_reader_test.gd` check (h) asserts that composition and those three
numbered lines, using a synthetic text table. No running client has printed
the `NPCTALK` lines yet.

**Not modelled:**
- the lines with no number (rows 2, 3 and 12);
- item 1's per-store lines. srrevamp's "Buy" is its own label. It stands where
  the real client puts `FUN_006fb630`'s lines, and at a keeper (ids 1 and 3) the
  real client shows those only if `FUN_00989d20` answers nonzero (call at
  `0x700a71`);
- `TC_OPEN` and `TC_HONOR_RANKING` after the storage line;
- the `+0x7f1` gate on the end line, which srrevamp always shows;
- `TALKEND2`, which only a siege pulley gets.

So srrevamp's numbers do not match the real client's for a keeper whenever the
real client shows its end line (the `+0x7f1` gate). By the table above, every item but 0x2a advances
`n`, including 0x2e, and the real client puts `TC_HONOR_RANKING` (and `TC_OPEN`
when shown) between the storage line and the end line. With no store line, its
storage line is 1 (srrevamp: 2). With one or more store lines, its end line is 4
or higher (srrevamp: 3). This comes from the table's order. It was not
measured on a running real client.
