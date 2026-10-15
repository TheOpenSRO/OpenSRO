# Monster AI

The state machine every non-player character runs. Recovered whole from
`SR_GameServer.exe`; implemented in `server/internal/ai`.

The engine's own name for the system is **tactics**. Its source file is
`D:\WORK2005\Source\SilkroadOnline\Server\SR_GameServer\AITactics_ExtRoutine.cpp`,
and one surviving log line names most of the vocabulary at once:

	CAIState::OnCSNM_Activate_AI( param : %d, param2 : %d, TacticsID : %d,
	                              AIStateID : %d, RefObjID : %d, pRefTactics : 0x%X )

So: a **tactics** (`TacticsID`) is bound to a monster type (`RefObjID`), and the
monster running it is in an **AI state** (`AIStateID`). Those are the engine's
words, not this project's.

## The sixteen states

Each state is a compiled C++ class deriving from `CAIState`, with its own
vtable. `CAIState::GetStateID` is **vtable slot 1**, and in the base it is
`__purecall` — so every concrete state is obliged to declare an id, and none can
inherit one by accident. Each override is a four- or five-byte function
returning a constant.

| id | class | getter | id | class | getter |
|---|---|---|---|---|---|
| 0 | `CAIState_SPAWN` | `0x0053dc40` | 8 | `CAIState_HOLDON` | `0x0053e390` |
| 1 | `CAIState_IDLE` | `0x00506380`† | 9 | `CAIState_FOLLOW` | `0x0053e470` |
| 2 | `CAIState_WANDER` | `0x0053de50` | 10 | `CAIState_WATCHOUT` | `0x0053e560` |
| 3 | `CAIState_BATTLE` | `0x0053df30` | 11 | `CAIState_PATROL` | `0x0053e660` |
| 4 | `CAIState_FLEE` | `0x0053e010` | 12 | `CAIState_AUTOCOMMAND` | `0x0053e900` |
| 5 | `CAIState_HOMING` | `0x0053e0f0` | 13 | `CAIState_PICKITEM` | `0x0053e820` |
| 6 | `CAIState_MOVING` | `0x0053e1d0` | 14 | `CAIState_PENDING` | `0x0053e740` |
| 7 | `CAIState_EMOTION` | `0x0053e2b0` | 15 | `CAIState_DEAD` | `0x0053e9e0` |

† **IDLE's getter is COMDAT-folded.** `0x00506380` is `mov ax,0x1; ret`, and
**nine** vtables in the image point at it — it is the compiler's single copy of
"return 1", not a function belonging to IDLE. The evidence for IDLE = 1 is the
**vtable slot**, read at `0x00af899c + 4`, not the function body. Naming that
address after IDLE would have been wrong, and the reference count is what
caught it.

Fifteen of the sixteen getters sit in one contiguous run of the image,
`0x0053dc40`–`0x0053e9e0`, **in id order**. IDLE is the one gap, and IDLE is the
one state whose getter was folded away. Those two facts are independent and they
agree.

`CAISTATE_CUSTOM_SPAWN_SUMMON_SHYTAN` is a seventeenth class but not a
seventeenth state: its slot 1 points at SPAWN's getter, so it reports id 0. It
is a boss-specific SPAWN variant, and it overrides exactly one other slot, 30.

### A third confirmation

`AI::CTactics::ChangeState` (`0x0053ff30`) opens with

	if (id < 0 || 0xf < id) Assert_BreakIfDebugger();

and then indexes a sixteen-element array. The bound, the class count and the
enum all say sixteen.

## The state interface — 48 vtable slots

`CAIState`'s vtable is exactly 48 entries; slot 48 is the null terminator.
Reconstructed from `.rdata` by walking each class's RTTI complete-object
locator, and diffed across all seventeen state vtables.

| slot | what it is | evidence |
|---|---|---|
| 0 | destructor | every class overrides it |
| 1 | `GetStateID` | `__purecall` in the base; all 17 override |
| 2 | `OnEnter(a, b) -> int` | **negative refuses the transition** |
| 3 | `OnUpdate() -> int` | negative means the dwell expired |
| 4 | `OnLeave()` | base is `return 0`; only BATTLE, FLEE, PICKITEM override |
| 5 | command dispatcher | a switch forwarding to slots 6–8 and up |
| 6–35 | the command / `OnCSNM_*` surface | 30 slots; only BATTLE and a few others override any |
| 36 | **message dispatcher** | the switch below |
| 37–47 | the eleven message handlers | one slot per message |

### The dwell timer lives in the base

`CAIState::OnEnter` (`0x00558b70`) is three statements:

	this->enteredAt (+0x10) = g_tickMs;     // DAT_00c82620
	this->timeout   (+0x14) = 0;

and `CAIState::OnUpdate` (`0x00558b90`) is one:

	if (timeout != 0 && timeout < (g_tickMs - enteredAt)) return -1;
	return 0;

So a state with no explicit timeout never expires, and every derived
`OnUpdate` that begins `if (CAIState::OnUpdate() < 0)` is asking "has my dwell
run out". **Slot 18 (`0x00559450`) and the head of slot 17 (`0x00559310`) both
set `timeout = (g_tickMs - enteredAt) + 3000`** — 3000 ms is a real literal,
present at both sites, and is the only dwell constant in the machine.

### Known object offsets

| offset | on | what | how known |
|---|---|---|---|
| `+0x04` | `CAIState` | the AI context | used as `this->ctx` everywhere |
| `+0x08` | `CAIState` | cached `AIStateID` | passed as `AIStateID` to the log line |
| `+0x10` | `CAIState` | entered-at tick | written by `OnEnter` |
| `+0x14` | `CAIState` | dwell timeout, ms | read by `OnUpdate` |
| `+0x2c` | AI context | `pRefTactics` | passed as `pRefTactics` to the log line |
| `+0x90` | AI context | the current `CAIState*` | `ChangeState` reads and writes it |
| `+0x00` | `CRefTactics` | `TacticsID` | `*pRefTactics` → the `TacticsID` argument |
| `+0x04` | `CRefTactics` | `RefObjID` | `pRefTactics[1]` → the `RefObjID` argument |

The last two are read straight off the format string's argument list, which is
the strongest kind of evidence this project gets: the engine labelling its own
fields.

## `ChangeState` — the transition, in order

`AI::CTactics::ChangeState` (`0x0053ff30`), state id in `EDI`:

1. **Bounds-assert** `0 <= id <= 0xf`.
2. **If the current state's `GetStateID()` is `0xf` (DEAD), return 0 now** —
   no leave, no enter, nothing touched. A dead monster cannot be transitioned.
3. Clear the context's `+0x148` byte flag.
4. Call the current state's **slot 4** (`OnLeave`).
5. `newState = states[id]`, store it at context `+0x90`.
6. Call the new state's **slot 2** (`OnEnter`). **If it returns negative**,
   take `states[1]` instead, store that, and call its `OnEnter` —
   **ignoring the return value the second time.**

Step 6 is the part worth keeping exactly: element 1 is IDLE, and the refusal
does not propagate. A state that refuses entry does not leave the monster where
it was; it drops the monster into IDLE.

`CAIState_WANDER::OnEnter` (`0x00559df0`) is the clearest refuser: it returns `-1` when the
owner's run speed (`+0x170`) is not above zero, and when the owner is a COS (`IsCOS`, slot 11) that
is not a mercenary (`IsMercenary`, slot 15). *Corrected in round 537:* this sentence said "when the
owner's HP has reached zero"; round 536 corrected the same reading in the round-251 section below
and missed this one (`0x559df0..0x559e30`, re-read 2026-09-24).

## The eleven messages

`CAIState::Dispatch` is **vtable slot 36** (`0x005597b0`), a switch over eleven
ids that forwards each to its own slot and asserts on anything else:

	case 0x21: return (*(vtable + 0x94))(a, b);   // slot 37
	case 0x22: return (*(vtable + 0x98))(a, b);   // slot 38
	...
	case 0x2b: return (*(vtable + 0xbc))(a, b);   // slot 47
	default:   Assert_BreakIfDebugger();

A sender always tests the result against **2**:

	if (Dispatch(0x22, 0, 0) == 2) return;

so 2 means "consumed, stop this tick" and 0 means "carry on".

| msg | slot | default handler does | senders |
|---|---|---|---|
| `0x21` | 37 | → IDLE | `SPAWN::OnUpdate` |
| `0x22` | 38 | range test, then → **BATTLE** | `IDLE` (round 552: `0x55a8b0` is slot 3 of IDLE's vtable `0xaf899c` as well as EMOTION's), `EMOTION`, `HOMING`, `WANDER`, `WATCHOUT` |
| `0x23` | 39 | → IDLE (folded) | `BATTLE::OnUpdate`, `FLEE::OnUpdate` |
| `0x24` | 40 | → IDLE (folded) | `FOLLOW`, `HOMING`, `MOVING` |
| `0x25` | 41 | → IDLE (folded) | `AUTOCOMMAND`, `HOMING`, `PICKITEM`, `WANDER` |
| `0x26` | 42 | → **HOMING** | `IDLE::OnEnter`, `WANDER::OnUpdate` |
| `0x27` | 43 | → IDLE (folded) | `BATTLE::OnUpdate`, when the tactics' reach behaviour (`+0x100`, below) returns 1 -- the id travels in a register, which is why the string census missed it (round 238) |
| `0x28` | 44 | restores a saved six-field location, then → IDLE | `WANDER` |
| `0x29` | 45 | clears the target; **no transition** | `BATTLE::OnUpdate` |
| `0x2a` | 46 | argument-dependent; → IDLE on argument 1 | `BATTLE`, `EMOTION`, `WANDER` |
| `0x2b` | 47 | → **FOLLOW** when the argument is 0 | `BATTLE`, `EMOTION`, `WANDER` |

**The engine does not name these messages.** There is no string, no log format,
and no enum text anywhere in the image. The names in `server/internal/ai`
(`MsgEnemyInRange`, `MsgReturnHome`, …) are **this project's**, chosen from the
one proven fact about each — the transition its default handler performs. The
ids, the slot mapping and the transitions are the engine's.

Two caveats that are easy to get wrong:

- **`0x5599a0` is folded 89 times across the image.** It is the compiler's
  single copy of `ChangeState(IDLE); return 2`, shared by slots 37, 39, 40, 41
  and 43 *and* by unrelated classes. "→ IDLE (folded)" above means only that the
  slot points at that shared body — it is not evidence about the message's
  meaning.
- Only **two** states override any message slot at all: IDLE overrides slot 41
  and BATTLE overrides slot 44. Everything else uses the base handler.

## The data side — four DB tables

The AI is configured from four tables, and they are **database tables, not
client textdata**. None of the four has a file counterpart in `Media.pk2`;
`docs/protocol/refdata_tables.md` catalogues them among the server's 85 loaders.

| table | loader | class |
|---|---|---|
| `TAB_REFTACTICS` | `0x008334e0` | `CRefTactics` |
| `TAB_REFNEST` | `0x00833750` | `CRefNest` |
| `TAB_REFHIVE` | `0x00833270` | `CRefHive` |
| `TAB_REFAISKILL` | `0x008339c0` | `CRefAISkill` |

Their relationships are stated by the engine's own assert strings:

	Invalid AIRefSkill is bound!! TacticsID[%d] SKILL[%s]
	Invalid Object Hatching Nest checked!! NESTID[%d] Hatching TacticsID[%d]
	Nest Region is invalid!!! NestID[%d] NestRegionID[%d]
	::SpwanNPCAt() can't find tactics!! [CodeName: %s]
	HIVE_MONSTER_SELECT
	NEST_MONSTER_SELECT

So: a **nest** lives in a region and hatches monsters under a **tactics**; a
**hive** groups nests; a tactics binds **AI skills** by codename; and spawning
an NPC fails if no tactics can be found for its codename. (`SpwanNPCAt` is the
engine's own typo.)

Two `CRefTactics` fields are readable from `AI::CTactics::Init`
(vtable slot 15, `0x0053f4d0`):

	mode = refTactics->+0x18;              // a byte, values 0, 1, 2
	if (mode == 2)
	    flag = (refTactics->+0x1c <= rand() % 100);

`+0x18` is a three-valued mode and `+0x1c` is the percentage it rolls against
when the mode is 2. The flag lands in the context byte `+0x168`, and what reads
it is now known (round 238, next section): the **acquire-a-target** behaviour
runs only while that byte is 0 (or 3), so mode 0 is *aggressive*, mode 1 is
*never aggressive*, and mode 2 is *aggressive with probability `+0x1c`/100*,
rolled once per spawn (`flag = pct <= rand()%100` is false -- aggressive -- on
the `pct` rolls out of 100 that fall below it).

Init also picks a random sign, `+1` or `-1`, into `this+0x59` from
`rand() & 0x80000001`.

The row layouts of all four tables are read below (tactics and nest in rounds
238-239, AI skill and hive in round 241).

## The `_RefTactics` row, read off its parser (round 238)

The server does not bind these tables by column name. Rows arrive as a byte
stream and each table has a positional parser; the tactics one is
`RefTactics_ExtractData` (`0x6aaab0`, was `CGameServer::FUN_006aaab0`), which
reads **43 columns** into a **0xbc-byte** record and then binds the row's AI
skills: an `equal_range` on the `_RefAISkill` multimap at `REFDATA_MGR+0x25c`
keyed by this TacticsID (`0x67ef90`, disassembly at `0x6ab085`), each hit's
code name looked up in `m_RefSkillByCodename` (`+0x894`, the real skill table by
`Basic_Code`) -- `Invalid AIRefSkill is bound!! TacticsID[%d] SKILL[%s]` rejects
the row on an unknown name. (Round 238 read the trailing string as that skill
list; it is not -- round 241.) `FUN_006e38f0` allocates the record, calls the parser, refuses a
duplicate `TacticsID` (`FUN_00501ac0`) and inserts it (`FUN_006e4c50`);
`FUN_006e0700` walks the row list; both hang off `CGameServer::FUN_006bd920`,
the 3.6 KB master reference load that calls one such list loader per table.

Column names are not in the binary (the DB serialises values only), so the
columns are numbered. Widths are what the parser reads: `u32` is a four-byte
field, `u8` one byte. "Read by" is a use-site in the AI code; a blank means the
three probes (direct `[0xb]+off`, `(+0x2c)+off` in any nesting, and aliased
locals) found no reader in the AI namespace.

| # | offset | width | read by / meaning |
|---|---|---|---|
| 1 | `+0x00` | u32 | **TacticsID** -- printed as `TacticsID[%d]` by the parser's own assert |
| 2 | `+0x04` | u32 | **RefObjID** -- the `RefObjID : %d` argument of the `OnCSNM_Activate_AI` log line |
| 3 | `+0x08` | u8 |  |
| 4 | `+0x0c` | u32 |  |
| 5 | `+0x10` | u8 |  |
| 6 | `+0x14` | u32 | the **detection distance** (world units): the target-acquisition radius is `BCRadius + this` (`ctx+0x15c`, round 257 below). Non-zero installs the acquire-a-target behaviour at context `+0xf8` (`AITactics_AcquireTarget`, `0x5478f0`; zero installs the no-op `FUN_00559000`), lets the AI-skill scan (`AI::CTactics::RegisterAISkill`, `0x53fa70`) raise the context's max skill range `+0x160`, and at `Init` seeds `+0x7c` from that range for an immobile monster (run speed `+0x170 <= 0`). `FUN_005473c0` (behaviour `+0xec`) credits an attacker of an immobile monster only when `Distance(self, attacker) <= +0x14`. **OpenSRO's stand-in: 100** for every species (`ai.TacticsDetectionDistance`, round 552; own design, a user decision) |
| 7 | `+0x18` | u8 | **aggression mode** 0/1/2 (above). **OpenSRO's stand-in: 0**, every species aggressive (`ai.TacticsAggressionMode`, round 552; own design, a user decision -- the `-monster-aggro` flag itself is the "none aggressive" setting) |
| 8 | `+0x1c` | u32 | **aggressive chance, percent**, for mode 2. OpenSRO's stand-in: 0, not read under mode 0 (`ai.TacticsAggressionPct`) |
| 9 | `+0x20` | u8 | **retarget rule** (round 259, "The threat table"): 0 keep the first attacker; 1 face the latest attacker; 2 by hate -- `AITactics_ResolveTarget`: the challenger overtakes on more hate or after two idle attack intervals, a third attacker only when it stands farther than the target (round 238 read `FUN_00545680` as an owner lookup; it is the hate resolver) |
| 10 | `+0x21` | u8 | `== 2` disables behaviour `+0x10c` (`FUN_00548950`), whose message builder `FUN_00541200` writes this byte, the object id, the TacticsID and slot 73's byte into a request. In this build the trigger also needs the HP bucket (`FUN_00541d70`: `GetCurHP/GetMaxHP` against 0.2/0.4/0.6/0.8) to be **negative**, which it never is -- `jge` at `0x54898d` -- so the request is dead |
| 11 | `+0x22` | u8 | read by `AI::CTactics::FUN_00540120` (unread) |
| 12 | `+0x23` | u8 |  |
| 13 | `+0x24` | u32 |  |
| 14 | `+0x28` | u8 |  |
| 15-22 | `+0x2c` .. `+0x48` | u32 x8 |  |
| 23 | `+0x4c` | u8 |  |
| 24-31 | `+0x50` .. `+0x6c` | u32 x8 |  |
| 32 | `+0x70` | u8 |  |
| 33 | `+0x74` | u32 |  |
| 34 | `+0x78` | u8 |  |
| 35 | `+0x79` | u8 | 0/1/2, the **chase rule's switch**: 0 and 2 disable the `+0x7c` tests in `FUN_005483c0`/`FUN_005484b0`/`FUN_00545e50`; 2 also takes its own branch in `BATTLE::OnUpdate` and in `BATTLE::OnMsg_0x28` (the target's position is looked up and handed to `FUN_00541110`). `Init` asserts `!(+0x80 == 2 && +0x79 == 1)`, and an immobile monster with `+0x14` set must have `+0x79 == 1` |
| 36 | `+0x7c` | u32 | **give-up distance** (world units), see below |
| 37 | `+0x80` | u8 | **roam-radius rule** in `IsWithinRoamRadius` (`0x545f70`): 0 -> the bound radius; 1 -> radius x **1.5** (double at `0xb45d78`); >= 2 -> always "within", so the monster never goes home |
| 38 | `+0x84` | u32 | **roam radius when spawned without a nest**: `AI::CTactics::Attach` (slot 12, `0x53f2a0`) stores context `+0x1cc` = the nest's own radius (`refNest+0x20`) when there is a nest, else the caller's radius when > 0, else **this column** when > 0, else **200.0** (`0xb45d68`); objects with TypeID (1,2,4,4) get 5.0. With no nest and this column < 1, `IsWithinRoamRadius` is always true |
| 39 | `+0x88` | u8 |  |
| 40 | `+0x89` | u8 | 0..3 in `FUN_00548120` (behaviour `+0x100`, the reach test `BATTLE::OnUpdate` runs first): 1 or 2 -> returns 1 at once; 3 -> returns 1 while the HP bucket is < 2 (HP under 40%); otherwise the `+0x7c` test decides |
| 41 | `+0x8c` | u32 |  |
| 42 | `+0x90` | u32 | **flags**. Bit 2 (`0x4`), bit 7 (`0x80`) and bit 8 (`0x100`) pick the target-kind filter pair the acquire behaviour scans with ((2,1) default, (3,5) bit 2, (4,5) bit 7, (5,0x11) bit 8 -- each pair is (selector, kind mask): the default is selector 2, the nearest, over kind mask 1, players; round 552 corrected a reading of it as kinds (1,2)); bits 2/7 also swap the `+0x100` behaviour for `FUN_005481a0`/`FUN_00548270`, make the give-up check return 0, disable the `+0x10c` trigger, and shorten `Init`'s scan timer (tactics timer 1, the acquire's cadence: base 1000 ms with spread `10 + |rand| % 491`, to base 200 with spread `10 + |rand| % 41`; the unit is milliseconds and the arming is `AITactics_ArmTimer` `0x53d600` -- read in round 552, "Target acquisition: the runtime"). OpenSRO's stand-in: 0 (`ai.TacticsFlags`) |
| 43 | string | 2-byte length + bytes | stored at record `+0x94`; no reader found (round 238 called it the skill list -- wrong, the skills come from `_RefAISkill` rows, below) |

**The give-up distance, `+0x7c`.** `BATTLE::OnUpdate` calls behaviour `+0x100`
(`FUN_00548120`) with the target: 0 means the target is still in reach
(`FUN_00545e50`: `+0x79` not 0/2, `+0x7c` non-zero, and
`Distance(self, target) < +0x7c` -- with a nest, `+0x7c` is first reduced by
how far the monster stands beyond 1.5x its nest radius), 1 means it is not,
and 1 sends message **`0x27`** -> IDLE. On 0 it calls behaviour `+0x104`
(`FUN_005483c0`, the disassembly at `0x54842a`: `fild [+0x7c]; fcompp`): a
target at **`Distance >= +0x7c` yields code 1 -> message `0x2a(1)` -> IDLE**;
nearer than that, and once 5000 ms have passed since context `+0xcc`, the code
is 3 when the distance is at least 100.0 (target moving, slot 304 == 1) or
150.0, else 2 -- messages `0x2a(2|3)`, which the base handler turns into a
`0x704f` notification when the target's motion state matches. Objects whose TID
has bit 15 set get `FUN_005484b0` instead: the same shape with `+0x7c + 100`
and 200.0/250.0. `Distance` is `GObj_DistanceBetween` (`0x53d7a0`): the
region-aware position difference (1920 units a region) through
`FUN_00430ba0`, then the square root.

**The roam radius.** `IDLE::OnEnter` and `WANDER::OnUpdate` both do, for a
monster that can move (`+0x170 > 0`): `if (!IsWithinRoamRadius()) Dispatch(0x26)`
-> HOMING. `IsWithinRoamRadius` measures from the six-field home location the
`Attach` call stored at context `+0x1b4` (the nest's position, or the spawn
argument) against the radius at `+0x1cc`, scaled by `+0x80` as above, and is
short-circuited to true by `+0x80 >= 2`, by "no nest and `+0x84 < 1`", and for
the two TID shapes (1,2,4,1) and (1,2,4,4) (object slots 242/243) the home
location is always used even when a nest exists.

## The `_RefNest` row and the hatch scheduler (round 239)

The nest table is numeric only, so its parser is not among the string-reader
callers; it was found by its cursor-advance shape. `RefNest_ExtractData`
(`0x6ab230`) reads **17 columns** into a **0x3c-byte** record whose constructor
(`RefNest_ParseAndInsert`, `0x6e3110`) zeroes everything except `+0x39 = 1`;
`Nest_FindByID` (`0x560250`) refuses a duplicate id. Column names are DB-only,
as for the tactics row; widths and offsets are the parser's.

| # | offset | width | read by / meaning |
|---|---|---|---|
| 1 | `+0x00` | u32 | **NestID** -- `NestID[%d]` in `Nest Region is invalid!!! NestID[%d] NestRegionID[%d]` (`AI::CNest::ValidateRegion`, `0x560e90`) |
| 2 | `+0x04` | u32 | **HiveID** -- `AIHive::Init` (`0x55e5b0`) asserts, for every nest id in the hive's list, that the nest row's `+0x04` equals the hive row's `+0x00` (round 241) |
| 3 | `+0x08` | u32 | **TacticsID** -- `AI::CNest::BindTactics` (`0x560570`) looks it up through the tactics map (`FUN_00501ac0`, the same lookup the tactics loader's duplicate check uses) and then the tactics' `RefObjID` through `FUN_004260b0` |
| 4 | `+0x0c` | u16 | **RegionID** -- `NestRegionID[%d]`; copied to the runtime nest's `+0x18` |
| 5-7 | `+0x10`, `+0x14`, `+0x18` | u32 x3 | the **position** (copied to the runtime nest's `+0x1c..+0x24`, validated with the region by `FUN_005380b0(world, 0, 0, region, x, y, z)`) |
| 8 | `+0x1c` | u16 | **initial direction**: `Nest_Hatch` turns it into radians as `v / 65535.0 * 360.0 * (pi/180)` (`0xb45c28`, `0xb45c30`, `0xb45e00`; the three doubles read back with `objdump -s` in round 547: `40efffe000000000`, `4076800000000000`, `3f91df46a0000000` -- the last is float32(pi/180) widened to a double, 0.01745329238474369, not the exact double pi/180 `3f91df46a2529d39`, so a heading recomputed bit-exactly must use the float; round 550) for every species but one kind: a species of the roster's TypeID shape (the four tests at `0x56098a..0x5609b4`, each `jne 0x560a1b`, which reads this word) whose rarity is not 3 (`cmp [edi+0x89],3` at `0x5609b6`, `jne 0x5609ee` at `0x5609bd`) gets `rand()/32767 * 2pi` instead. A rarity-3 species of that shape (`0x5609bf`) and every other shape (`0x560a1b`) take this word (`ai.SpawnHeading`). Round 547 corrected this cell, which read "for a rarity-3 species; every other species gets rand()" and had the rule backwards for the other shapes |
| 9 | `+0x20` | u32 | the **roam radius** handed to `AI::CTactics::Attach` when the monster has a nest (previous section) |
| 10 | `+0x24` | u32 | passed as a float into the spawn routine `GObjPC::FUN_005f6eb0` beside the direction (its use inside is not traced) |
| 11 | `+0x28` | u32 | **champion chance, percent**: `Nest_Hatch` rolls `rand() % 101 < +0x28` when the tactics row's `+0x8c` (tactics column 41) is non-zero; a second roll `rand() % 101 > GiantMonster_SpawnRatio` makes the hatch a **champion** (class 1, x2 HP), else a **giant** (class 4, x20 HP -- the rank table in `internal/combat/rarity.go`); the monster then runs under the tactics row `+0x8c` names (its own, with the class cleared, when that row does not exist). `GiantMonster_SpawnRatio` is the engine's own config key (`.rdata 0xae0a04`, read in `CMainProcess::FUN_00427050` as `atol(value)/100`, **default 14** when absent or zero), so with the default about 15 in 101 of the rolls come up giant |
| 12 | `+0x2c` | u32 | **hatch delay, minimum, seconds** |
| 13 | `+0x30` | u32 | **hatch delay, maximum, seconds** |
| 14 | `+0x34` | u32 | **alive cap**: the hatch pass requires `slot.alive < +0x34`; with column 16 zero it is also the finite budget of hatches (decremented per hatch) |
| 15 | `+0x38` | u8 | no reader found |
| 16 | `+0x39` | u8 | **respawns**: non-zero hatches forever; zero spends column 14 as a budget (`FUN_0055ea90`: `slot[6] != 0 \|\| 0 < slot[7]`) |
| 17 | `+0x3a` | u8 | must be **zero** for the scheduler to hatch the nest at all (`slot[5] = (+0x3a == 0)`) -- the non-zero nests are the trigger-driven ones (`CGameTriggerAction_MONSTER_ACTIVE_NEST` exists) |

**The delay, exactly.** `AI::CNest::RollHatchDelay` (`0x560e40`, disassembly:
`mov ecx,[eax+8]; mov eax,[ecx+0x2c]; mov ecx,[ecx+0x30]; jmp 0x560380`) hands
columns 12 and 13 to `NestSlot_RollHatchDelay` (`0x560380`):

	lo = col12 * 1000 ; hi = col13 * 1000           (milliseconds)
	interval = hi > lo ? lo + rand()/32767.0 * (hi - lo) : lo
	part = (int)(interval * slot.pct / 100.0)       ; slot.pct is a float the hive sets (AIHive::FUN_0055f190 -> 0x560e70)
	slot.base = interval - part ; slot.variance = part

so the delay is **uniform between the two columns, in seconds**, re-rolled at
every hatch. The per-nest slot (0x20 bytes, built by
`CMainProcess::BuildHiveNestSlots`, `0x54bbf0`) is `{stamp, base, alive, pct,
variance, col17==0, col16, col14}`, and the hive's pass `AIHive_HatchPass`
(`0x55ea90`) hatches one monster from a nest when

	slot.col17==0  &&  (slot.col16 != 0 || slot.budget > 0)
	&& stamp + base <= GetTickCount()  &&  alive < col14

The stamp is set by `Nest_Hatch` on success (with `alive++` and a fresh roll),
and by `AI::CNest::vslot_004` -- the alive-count decrement hook -- **only when
the nest was full** (`alive == col14`), so the timer runs from the first loss
out of a full nest, not from every death. A hatch whose placement fails with
out-flag 1 halves `base` with a floor of 1000 ms (`NestSlot_HalveHatchDelay`,
`0x560e10`) and retries sooner. `AIHive_HatchPass_TotalCapped` (`0x55ec10`) is
the same pass under a hive-wide count read from the hive row's `+0x08`.

**What this settles for OpenSRO.** `respawnDelay = 10 s` in
`server/cmd/server/main.go` is own design with a proven reason: the real delay
is a per-nest window `[col12, col13]` seconds in a table the project does not
hold (the client's `npcpos.txt` is the five-column projection id/region/x/y/z).
The mechanism -- a per-nest alive cap, the timer armed by the first death out of
a full nest, a uniform window re-rolled per hatch -- is the shape to implement
when the nest data exists; the numbers cannot be.

## The `_RefAISkill` and `_RefHive` rows (round 241)

**`_RefAISkill`** -- `RefAISkill_ExtractData` (`0x6ab4b0`), 5 columns into a
0x2c-byte record, inserted into a **multimap keyed by the first column**
(`REFDATA_MGR+0x25c`; the insert at `0x6b55fc` keys on `[record+0]`):

| # | offset | width | meaning |
|---|---|---|---|
| 1 | `+0x00` | u32 | **TacticsID** -- the multimap key the tactics parser's `equal_range` matches against its own TacticsID |
| 2 | `+0x04` | string (`std::string`, 0x1c bytes) | **skill `Basic_Code`** -- looked up in `m_RefSkillByCodename`, so a monster's AI skills are ordinary skilldata rows (the `MSKILL_*` ids characterdata column 83 already pointed at) |
| 3 | `+0x20` | u8 | **trigger type** (round 260, "The skill choice"): 0 = fire once when the owner's HP % has dropped to column 4 or below; 1 = fire every column-4 milliseconds |
| 4 | `+0x24` | u32 | the **HP-percent threshold** (type 0) or the **period in ms** (type 1) |
| 5 | `+0x28` | u32 | bit 0, type 1 only: **fire at once** the first time the trigger is evaluated instead of waiting a full period |

`m_RefSkillByCodename` itself is built by
`RefInstanceGenerator::BuildRefSkillByCodename` (`0x6f68f0`) from the
`CRefSkill` list at `+0x888`, asserting each `Basic_Code` is unique -- the
assert text names both the map and the field.

**`_RefHive`** -- `RefHive_ExtractData` (`0x6aa960`), 9 columns into a
0x30-byte record at `REFDATA_MGR+0x250`. `CMainProcess::CreateHivesForWorld`
(`0x54b8d0`) walks that container when a game world is built and constructs an
`AIHive` (0x38 bytes, vtable `0xaf9b80`) for every row whose `+0x1a` equals the
world id, first the rows with `+0x1c == 1`, then those with `+0x1c == 2`:

| # | offset | width | read by / meaning |
|---|---|---|---|
| 1 | `+0x00` | u32 | **HiveID** -- what a nest row's `+0x04` must equal (`AIHive::Init`) |
| 2 | `+0x04` | u8 | **mode**: `== 1` turns on the population scaling -- `AIHive::Init` divides the hive's total alive cap by column 4, and `AIHive_PopulationTick` (`0x55f0e0`) runs only then |
| 3 | `+0x08` | u32 | the hive-wide count `AIHive_HatchPass_TotalCapped` hatches up to |
| 4 | `+0x0c` | float | the **divisor** of the summed nest caps in mode 1 (`round(sum / +0x0c)` -> hive `+0x2c`) |
| 5 | `+0x10` | u32 | **rate**: `AIHive::AdjustHatchRateByPopulation` (`0x55f190`, `AIHive.cpp:0x23c`) sets every nest slot's percentage to `round(sample / hive+0x2c) * +0x10` |
| 6 | `+0x14` | u32 | **the cap on that percentage** (the `CLAMP()` upper bound) |
| 7 | `+0x18` | u8 | no reader found |
| 8 | `+0x1a` | u16 | **game-world id** the hive belongs to |
| 9 | `+0x1c` | u16 | **hatch kind** 1 or 2 -- the two construction passes |

The percentage a hive sets on its nests is what `NestSlot_RollHatchDelay`
splits the rolled interval by: the hatch fires after `interval * (1 - pct/100)`,
so a busier hive (a larger `sample`) hatches sooner, up to column 6. `sample` is
what `AI::CNest::ValidateRegion` returns for each nest -- a per-region word from
`FUN_005347c0` (region object `+0x28` table) averaged over two ticks; by the
shape a population count, **not read** as such.

## External shard DB (user-supplied, 2026-09-30; round 658)

**EXTERNAL.** Everything in this section comes from a private server's database
backup the user supplied (`SRO_VT_SHARD.bak`; the backup's own name for the
database is `__ETERNITY_SRO_VT_SHARD`, taken 2023-12-02). It is not retail and
not read from the executable. The CSVs live only on the render box
(`/opt/sro-files/db/csv/`); the restore and export recipe is in
`deploy/README.md`. Nothing from the DB is in this repo beyond the counts below.

**Structure: it matches the parsers above.** `Tab_RefTactics` has 43 columns,
`tab_refnest` 17 and `Tab_RefAISkill` 5, and every column's SQL width agrees with
the parser's read width (the tinyint/smallint/int/real/varchar positions line up
one for one). `tab_refhive` has **10** columns: the first 9 match
`RefHive_ExtractData`, and the 10th is `szDescString128`, which the parser does
not read. The DB's own column names agree with the meanings read from the code:
tactics 6 `nSightRange` (detection distance), 7/8 `btAggressType`/`AggressData`,
9 `btChangeTarget`, 10/11 `btHelpRequestTo`/`btHelpResponseTo`, 35/36
`btTraceBoundary`/`TraceData` (give-up), 37/38 `btHomingType`/`HomingData`, 41
`dwChampionTacticsID`, 42 `AdditionOptionFlag`; nest 9 `nRadius`, 10
`nGenerateRadius`, 11 `nChampionGenPercentage`, 12/13
`dwDelayTimeMin`/`dwDelayTimeMax`, 14 `dwMaxTotalCount`, 15-17
`btFlag`/`btRespawn`/`btType`; hive 2-9 `btKeepMonsterCountType`,
`dwOverwriteMaxTotalCount`, `fMonsterCountPerPC`, `dwSpawnSpeedIncreaseRate`,
`dwMaxIncreaseRate`, `btFlag`, `GameWorldID`, `HatchObjType`; AI skill 3-5
`ExcuteConditionType`/`ExcuteConditionData`/`Option`. Row counts: tactics 1,743,
nests 16,381, hives 1,170, AI skills 200.

**Monster stats match our client, but that is not evidence of retail.** All
7,604 monster rows (TypeID 1,2,1) of our `Media.pk2` characterdata equal the DB's
`_RefObjCommon`+`_RefObjChar` rows on all 104 characterdata columns. A negative
control (each row compared with the next id's DB row) matched 0 of 7,603. Our
`Media.pk2` itself, though, carries this shard's own objects:
`MOB_ETERNITY_DEADWARRIOR` (62584), `MOB_TQ_SNAKEMAN_ETERNITY` (62587), the seven
`_STR` twins of the field uniques (43969-43975) and the `ANTHEIA` monsters. So the
client and the DB share a lineage, and matching each other says nothing about
retail. Skills: 33,578 of our 33,698 skilldata rows are identical. The DB
disables 66 (`Service` 1 -> 0: EU warrior blocks/intercept and cleric
heal-shield/bless) and changes about 54 others' params (for example
`MSKILL_ARABIA_GEENIE` Param5 9040 -> 4520, `SKILL_LUCK` 3,600,000 -> 600,000).

**Nests against npcpos: the positions are ours, and 59% of the species are not.**
Every one of npcpos's 10,195 field monster rows has a nest at exactly its spot
(same region, x/z within 0.01). At 4,153 of them it is the same species. At 6,042
the species was replaced: 4,734 by the custom `MOB_ETERNITY_DEADWARRIOR`, done by
repointing 88 tactics rows' `dwObjID` (47 npcpos species have no tactics row left
at all), and 1,308 by Egypt `MOB_SD_*` species. The DB also adds 3,069 field nests
at no npcpos spot (3,045 of them DEADWARRIOR). Dungeon regions match 330 of
1,915 npcpos rows; the other 1,585 have no nest at their spot.

**The seven field uniques** each have one nest per npcpos spot (Tiger Girl 11,
Uruchi 11, Isyutaru 11, Yarkan 10, Shaitan 6, Cerberus 13, Ivy 8; all match
npcpos exactly). Each nest has cap 1, respawns, a 1,000 radius and champion 0%.
Each species' nests form one hive with `dwOverwriteMaxTotalCount` = **1**, the
total-1 rotation hive the hatch section inferred. Delays: **1,200-1,400 s** for
1954/1982/2002/5871/14936 and **2,100-2,200 s** for 3810/3875. The shard's own
`_UniqueKillList` (45,215 kills, Jan-Mar 2023) agrees: the 10th-percentile gap
between kills is 1,295-1,400 s and 2,244-2,372 s respectively. So these are the
delays the shard actually ran. They are not one-minute test timers, but no
second source says retail used the same values. The shard also runs a **second,
concurrent** `_STR` twin of every one of the seven, from its own total-1 hive on
the same spots. That is a mod.

**Distributions** (13,279 field world-1 monster nests): delay pairs `(1,3)`
8,351, `(2,3)` 3,633, `(8,12)` 429; 11,988 nests have a maximum of 3 s or less.
3,630 of the 3,633 `(2,3)` pairs are custom DEADWARRIOR nests; the 4,153 nests that
match npcpos exactly are `(1,3)` 3,513 and `(8,12)` 459. Champion percent: 10 on
10,200 nests, 0 on 3,077, 100 on one (`MOB_WC_HYEONGCHEON`, nest 2065). Tactics
column 41 is set on 239 of 1,743 rows and never names its own row. Aggression
mode: 0 on 9,099 nests and 1 on 4,180; **mode 2 appears nowhere**. Give-up
(`TraceData`): 500 on all but one. Detection: 100 (6,361), 200 (2,858), 130, 115,
and so on. Roam radius: 350/200 (the DEADWARRIOR nests), 700/600/500 elsewhere.
Hives: 74 use population scaling (`btKeepMonsterCountType` 1; rate 30, cap 80).
There are 518 nests with `btType` 1 (trigger-driven) and 1,683 with `btRespawn`
0. 145 nests have a NULL `fLocalPosY`.

**`_RefHWANLevel`** (256 rows): `SPDU` 200 on every level, and `DABR` 10/15/20/25/30/35
on levels 1-6, then 15 on levels 7-255. Level 0 has `SPDU` 200 and no `DABR`.
**World config**: the field world `INS_DEFAULT` (id 1) has config group `xxx`, so
none of the three keys is set for it. `PARTYMONSTER_SPAWN` is OFF in the Pharaoh,
God-temple and Arabia instance groups and ON in the Jupiter groups (Service 0).
`CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG` is ON in the instance groups. The
`PARTYMONSTER_SPAWN` gate is READ as instance-only: the stripping override
`0x609900` is `CDataDrivenGameWorld`'s slot 6, while `CGameWorld_Default`'s slot 6
is the unstripped base `0x5eb9a0`. `GiantMonster_SpawnRatio` is in no table of
this DB (it is a `LoadServerConfig` key), so the default of 14 stands.

**Trust.** The column layouts can be used as they are. The unique rotation
shape (total-1 hives, one nest per npcpos spot) and the unique delays are
consistent and corroborated by the shard's kill log. Present them as EXTERNAL
values, not retail. The general nest rows are usable only for the 4,153 spots
whose species matches npcpos, and their 1-3 s delays are unverified against
retail. The replaced species, the `_STR` twins, the custom nests and the
DEADWARRIOR tactics are this shard's mods and must not be imported. The drop
tables look like a custom economy: `_RefDropGold.DropProb` is 0.0001 on all 140
levels, the potion/scroll/ammo class-select tables are all zero, and custom
`ITEM_11_NORMAL`/`ITEM_11_NOVA` groups sit on 2,309 monsters. Do not use them
without the user's OK.

## WANDER's leg and every state's dwell time (round 251)

`CAIState_WANDER::OnEnter` (`0x559df0`) refuses (returns -1, so `ChangeState` drops the
monster into IDLE) when the owner's run speed (`+0x170`) is not above zero, or the owner is a COS
that is not a mercenary; otherwise it clears the target and asks `CAIState_WANDER::PickWanderLeg`
(`0x545860`) for a leg. (Round 251 read the two refusals as "HP is 0" and "an `IsNPC` object with no
home"; the correction and its addresses are below the block, from round 536, and round 537 carried
it into this sentence.)

	requires run speed > 1e-6 (0xb45c84) and the object's location record (+0x7c)
	distance  = 85 +- (rand % 40)                      ; 0xb46160 = 85.0 -> 46..124 units
	t         = +-(45 + rand % 91) degrees             ; x pi/180 (0xb45e00): 45..135 either side
	h         = atan2(dir.z, dir.x) + t                ; dir = the owner's heading, +0x24/+0x2c
	direction = normalize(dir + (cos h, 0, sin h))     ; FUN_00489490 / FUN_004894b0, FUN_004328c0
	            -> for a unit heading, a turn of t/2 = 22.5..67.5 degrees (round 535)
	if ctx+0x14c resolves to an object (FUN_00485d90):
	    direction = normalize(direction + unit vector toward it)   ; 0x5459f0..0x545a50
	probe     = position + direction * 30              ; 0xb45e58 = 30.0
	world probe (DAT_00cc387c slot 12, flags (0|1, 1)) -> bit 0 or bit 28 set = blocked
	    -> direction *= -1.0 (0xb45e68): walk the other way

**Corrected in round 536** (re-read in `/var/tmp/srv.asm`, 2026-09-24): `OnEnter`'s two refusals
are the owner's `+0x170 <= 0.0` (`fldz; fcomp [owner+0x170]; test ah,0x1` at
`0x559df0..0x559e09`) -- the **run speed**, the same field `AITactics_Handler_110` and HOMING's
re-aggro window read, not HP -- and an owner that is a COS (`IsCOS`, slot 11) but not a mercenary
(`IsMercenary`, slot 15; `0x559e15..0x559e30`).

**Corrected in round 535.** Round 251 recorded `heading = atan2(current direction) +- (45 +
rand % 91) degrees ; a 45..135 degree turn` and `direction = (cos, 0, sin) of that heading`. The
binary does not use `(cos h, 0, sin h)` as the leg. It adds it to the owner's direction and
normalizes the sum (`/var/tmp/srv.asm`, re-read 2026-09-24):

- `0x545911`/`0x545918` load the owner's `+0x2c` and `+0x24`, and `0x545974` calls `0x9fc1aa`,
  the CRT's `_CIatan2` (its dispatch table at `0xc81760` spells `atan2`), with `+0x2c` loaded
  first: `atan2(dir.z, dir.x)`. `t` is added at `0x545984`.
- `0x489490` -> `0x9fc0b0` (the CRT cosine; its x87 path runs `fcos`) and `0x4894b0` ->
  `0x9fbf80` (its x87 path runs `fsin`) put `cos h` in `[esp+0x24]` and `sin h` in `[esp+0x2c]`.
- `0x545981`/`0x545989` point `esi` at owner `+0x24`. `0x5459b3` `fld [esi]` + `fadd [esp+0x24]`,
  `0x5459c1` `[esi+4]` + 0.0 (`0xb45ab0`), `0x5459d2` `[esi+8]` + `[esp+0x2c]`, all written to the
  leg vector at `ebx`, and `0x5459eb` normalizes it (`FUN_004328c0`, which leaves a zero-length
  vector zero).

**What the owner's `+0x24` holds** (read in round 535). It is the unit heading
`(cos a, 0, sin a)`. Two probes looked for its writers: a direct-store scan of
`0x480000..0x49ffff` for `+0x2c`, and a scan of the whole server dump for functions storing all
of `+0x24`, `+0x28` and `+0x2c` (77 functions; a name filter kept 19, and the 13 of those in
GObj, AI-state, tactics and COS code were read). What writes a GObj's `+0x24`:

- **SetHeading**, vtable slot 230 (offset `0x398`): `0x482440` for `CGObj` and the `CGObjMobile`
  override `0x48ba10` that monsters inherit. Both write `+0x24 = cos a`, `+0x28 = 0`,
  `+0x2c = sin a`; the override also keeps `a` in `+0x164` unless `+0x154` is set.
- Slot 230's callers include **`CGObj::EnterWorld`** (`0x48541e`, the placement's angle argument)
  and **every destination move's start**: `CGObjMoverByDest::vslot_004` (`0x48c330`) calls its own
  slot 10 (`0x48c660`), which takes `FUN_00485c20`'s `atan2(dz, dx)` toward the destination and
  passes it to slot 230. The mover then steps along `+0x24`/`+0x2c` (`FUN_0048bff0`).
- **`CGObj::vslot_000`** (`0x4848e0`), the object's reset, zeroes `+0x24..+0x2c`. Its callers go
  through vtable slot 0 and were not traced, so "the reset always runs before `EnterWorld`" is
  not proven.

The other hits that were read store into other records: copies of a location record
(`CAIState_WATCHOUT::OnEnter` and `CAIState_PATROL::OnEnter` into their own state,
`GObjPC::FUN_0059b480`), a log entry (`CGObjCOS_Summoned::FUN_00568090`), a small tactics record
(`AI::CTactics::FUN_0055de20`), the tactics constructor filling its array of state pointers
(`AI::CTactics::CTactics`), and records whose `+0x24` is a short or whose `+0x2c` is a byte. The
filter's other six (terrain, main-process, training-camp and nav-mesh classes) were not read, nor
were the 58 it dropped.

So, unless the untraced reset runs after placement, a standing monster holds the heading of its
last move or of its placement, at unit length, and the leg bisects that heading and
`heading + t`: an effective turn of **t/2, 22.5..67.5 degrees** either side. For a zeroed
heading, `atan2(0, 0) = 0` and the leg would be the absolute heading `t` from `+x`.
`ai.WanderLegDirection` carries the rule with a test. What `ctx+0x14c` holds is unread.

`FUN_00540f70(distance)` then sets the destination `position + direction * distance` and the
walk begins. The leg's duration is the state's dwell: **`AIState_DwellMs`** (`0x545b70`,
formerly attributed to HOMING), called with the entering state's own id by IDLE, WANDER,
FLEE, HOMING and EMOTION:

| state (id) | dwell |
|---|---|
| IDLE (1) | `4000 +- rand % 2000` ms -> 2001..5999 |
| WANDER (2) | `5000 + rand % 1000` ms -> 5000..5999 |
| FLEE (4) | `3000 + |rand| % 2001` ms -> 3000..5000 |
| EMOTION (7) | `4000 +- rand % 1000` ms -> 3001..4999 |
| HOMING (5) and the rest | 50 000 ms |

WANDER stores 1000 ms instead when no leg could be picked. So an idle monster stands
2-6 s, walks 46-124 units at 22.5-67.5 degrees off its heading for 5-6 s, and repeats -- going
HOMING (via `0x26`) whenever `IsWithinRoamRadius` says it has strayed. `server/internal/ai` carries the
table (`DwellRange`) and the leg constants; OpenSRO's server does not move monsters yet.

## The roster's real walk and run speeds (round 362)

WANDER needs a speed and OpenSRO carries none. These are the game's own, read
from the retail `characterdata_5000.txt` on 2026-09-21.

*Carried since round 536*: `cmd/server`'s `monsterSpec.WalkSpeed`/`RunSpeed` hold the table below
and pass it through `combatSpeciesOf` to every spawn, the GM console's included
(`combat.Species`/`combat.Monster`). Re-read by `RefObjID` on 2026-09-23 with the Level, MaxHP and
BCRadius controls matching, and re-checked by `client/tools/verify_monster_specs.py` (cols 46/47
added to its `COL`): 77 verified, 0 mismatched -- 22 more fields than the 55 it verified before --
and a specs line with Mangyang's walk speed set to 9 comes back as 1 mismatch.

**The columns** are `Speed1` (col 46, walk) and `Speed2` (col 47, run) --
published as ParamKeeper params 23 and 24 from the common record's words at
`+0xe4`/`+0xe6` (`docs/protocol/param_registry.md`), where the mover's step
multiplies by seconds. So these are **world units per second**.

| species | `RefObjID` | walk (46) | run (47) |
|---|---:|---:|---:|
| Mangyang | 1933 | 8 | 22 |
| Small-eyed Ghost | 1934 | 14 | 55 |
| Big-eyed Ghost | 1935 | 14 | 55 |
| Old Weasel | 1936 | 12 | 55 |
| Weasel | 1937 | 12 | 55 |
| Water Ghost slave | 1938 | 15 | 55 |
| Water Ghost | 1939 | 15 | 55 |
| Tomb Stone Ghost | 1950 | 15 | 55 |
| Stone Ghost | 1941 | 14 | 55 |
| Yeoha | 1943 | 9 | 20 |
| Earth Ghost | 1963 | 11 | 75 |

**The control, run before the numbers were taken.** Two columns of each row are
values this project already holds independently: col 57 is the level and col 59
the max HP, both carried per species in `cmd/server`'s `monsterSpecs`. **All
eleven rows match on both.** Col 50 (BCRadius) matches its third. The column
indexing is therefore checked against three known fields before reading the two
unknown ones.

**A trap this walked into, recorded because it nearly shipped.** A search for
the Mangyang row by name found the WRONG row: `characterdata_10000.txt` has
`MOB_CH_STRONG_MANGNYANG` (RefObjID 9383) at level 90 with 676,983 HP, and its
speeds (8/22) happen to look plausible. The level/HP control is what caught it
-- col 57 came back 90 against the roster's 1. Select by `RefObjID`, or by the
exact code name.

*Corrected in round 523.* This paragraph first called that row "a second
`MOB_CH_MANGNYANG`" and said code names are not unique across the characterdata
files. Both were wrong. The row's code is `MOB_CH_STRONG_MANGNYANG`, a different
code. An exact code-name match cannot return it, so the search must have
matched loosely; how it matched was not recorded. A substring or suffix match on
`MANGNYANG` finds it, and one more row too, `MOB_EVE_STRONG_TQ_MANGNYANG`
(26927, `characterdata_30000.txt`). Over the six data files extracted on the
box (`characterdata_5000` .. `_30000`; the seventh file the client reads,
`characterdata.txt`, only lists file names), 13,291 rows carry 13,291 distinct
code names (round 519 counted this first, re-counted in round 523). An exact
code-name key is therefore safe, and the client's BCRadius map
(`NpcTableReader.parse_bc_radius_by_code`) relies on it.

### "Which speed does a WANDER leg step at" was the wrong question (round 363)

Round 362 left it open and said to settle it from the mover. Reading the AI
shows there is nothing to settle **in the AI**: no state reads a speed to
compute a step. Across every AI function, the walk and run fields appear only as
**immobility gates** -- `<= 0.0` in `AI::CTactics::Init`, `AITactics_CreditAttacker`
and five `FUN_0054xxxx` guards, `<= 1e-6` in `PickWanderLeg` and
`AITactics_Handler_110`. WANDER picks a **destination**, never a speed.

**A probe that looked right and was not**, recorded because it nearly became a
finding. Grepping `+0x16c`/`+0x170` inside the AI address range returns
`CAIState_PATROL::OnEnter` and `CAIState_MOVING::OnEnter` "reading walk speed" --
which would have settled the question as *walk*. Both are false hits: PATROL
copies `0x16c, 0x170, 0x174, 0x178, 0x17c, 0x180` as a **block** into its context
at `+0x38..+0x4c`, and `FUN_00549970` squares `0x16c` and `0x170` together with a
third field (`local_30 * local_30 + local_38 * local_38 + local_34 * local_34`)
-- they are **vector components**, not speeds. The offsets mean walk/run only
when reached through the owner pointer, `*(int *)(ctx + 4) + 0x16c`. Scoping the
grep by *address range* does not separate these; only the **base object** does.

*Superseded in round 537.* The question does have an answer, from the move's side rather than the
leg's. `AITactics_Handler_110` (`0x5489b0`) picks the move's clip byte, 0 or 1 -- WANDER and FLEE
0, every other state 1, and 0 or 1 outright when a speed is absent (round 536, "The server half") --
and `FUN_00541820`, which WANDER's `OnEnter` calls at `0x559e82` before the move, passes it on (the
behaviour-table row for `+0x110` below). That 0/1 selection is **read**. That 0 is the walk clip
walked at the walk speed, and 1 the run clip at the run speed, is the **inference** OpenSRO's
runtime carries (below), because the mover's use of the owner's `+0x155`/`+0x174` is untraced. So a
WANDER leg walks at the walk speed, and HOMING runs at the run speed, by inference.

## How the AI actually moves a monster (round 363)

`FUN_00540f70`, the destination setter `PickWanderLeg` hands its leg to, ends by
composing a message with opcode **`0x7021`** and sending it:

	uVar1 = (**(code **)(*unaff_ESI + 0x14))(0x7021);   // new message, opcode 0x7021
	GObjPC::FUN_0048bad0(0);                            // append the destination
	(**(code **)(*unaff_ESI + 4))(uVar1);               // send

**`0x7021` is the client's own movement request** -- `docs/protocol/client_senders.tsv`
records the client sending it from `FUN_009ebd10`. So a monster moves by issuing
the same message a player's client issues, and player and monster movement share
one path rather than having two.

**The payload**, read from `GObjPC::FUN_0048bad0` (`0x0048bad0`), where the
argument decides only whether a second byte is included -- the AI passes `0`, so
it omits it:

	u8  kind                       ; asserts if 0xff
	[u8 extra]                     ; only when the caller passes non-zero
	if kind == 0:                  ; directional: no destination, a heading
	    u8  <field at +0x14>
	    u16 angle                  ; round(rad * 57.295780181884766 / 360 * 65535)
	else:                          ; a destination
	    u16 region
	    if region & 0x8000:  f32 x, f32 y, f32 z     ; world/dungeon coords
	    else:                u16 x, u16 y, u16 z     ; region-local

The region-or-float split is the same encoding this project already recovered
for positions elsewhere (region span 1920, local `[0, 1920)`).

**Completed in round 364** -- the field widths come from the CLIENT's twin of
this routine (`0x009ebbf0`), whose append helper takes an explicit byte count
where the server's does not, and the three angle constants were read out of both
PE images as doubles and are **byte-identical across the two binaries**. A full
turn maps to **65535**. The full spec, with its controls, is now
`docs/protocol/opcodes/movement.md`.

**What this means for OpenSRO's move packet** (`docs/TODO.md`): there is a
retail shape to mirror, and the speed belongs to whatever consumes `0x7021`, not
to the state machine. The walk/run table above is still the data that consumer
will need.

## Target acquisition: the detection radius and the nearest-player rule (round 257)

**The radius.** `AI::CTactics::BindSkillsAndRanges` (`0x53f780`, the pass that
picks the AI-skill selector class by TacticsID and registers the monster's ten
skills) ends, at `0x53fa23..0x53fa4f`, with:

	ctx+0x158 = float(owner.GetBCRadius())          ; slot 344, characterdata col 50
	ctx+0x15c = float(BCRadius) + int(row+0x14)     ; fild ; fiadd DWORD [row+0x14] ; fstp

so **`_RefTactics` column 6 (`+0x14`) is the detection DISTANCE, and the
detection radius is `BCRadius + that`**. (Ghidra rendered the store as
`= 0`; the disassembly is what settled it -- the decompile of this function
also stops early at a misread noreturn.) Earlier in the same pass,
`ctx+0x160 = round(param 33) + old(+0x158)` (the `mov eax,0x21` before
`ParamKeeper_GetParamChecked` is param 33, the attack range of round 247),
and `AI::CTactics::RegisterAISkill` (`0x53fa70`) then raises `ctx+0x24` to the
largest skill `Range` (`CRefSkill+0x92`) and, only when `+0x14` is non-zero,
`ctx+0x160` too.

**The scan.** `AITactics_AcquireTarget` (`0x5478f0`, behaviour `+0xf8`,
installed only when `+0x14` is non-zero; run from IDLE, WANDER, HOMING, WATCHOUT and
EMOTION while the aggression byte `+0x168` is 0 or 3 -- IDLE added in round 552: `0x55a8b0` is
slot 3 of IDLE's vtable `0xaf899c` as well as EMOTION's `0xaf8e4c`; and paced by tactics timer 1,
"Target acquisition: the runtime (round 552)"):

	radius   = trunc(ctx+0x15c)              ; RC=chop: `or eax,0xc00` 0x547989, `fistp` 0x54799a
	                                         ; (round 552 corrected this line's "round")
	kinds, selector = (1, 2)                 ; players, "nearest"
	              | (5, 3) when row+0x90 has bit 2
	              | (5, 4) when it has bit 7
	              | (0x11, 5) when it has bit 8
	AITactics_ScanForTargets(ctx, kinds, selector, &list, &radius)   ; 0x5405b0
	first (or CTactics::FUN_005436f0's pick) -> AI::CTactics::SetTarget -> return 2

`ScanForTargets` asks the owner for the regions within the radius (slot 5),
walks their player list (kind bit 1) and object list (bits 2..5), and hands
each object that is not the owner to the selector at `ctx+0x128 + selector*4`
-- a second table of eight, filled by the constructor `AI::CTactics::CTactics`
(`0x53ea60`): `[0] 0x546330 [1] 0x546460 [2] 0x5464e0 [3] 0x546790 [4]
0x546a30 [5] 0x547070 [6] 0x546ca0 [7] 0x546e60`. Selector 2
(`AITactics_Select_Nearest`) keeps a candidate that passes the kind mask
(`GObj_MatchesKindMask`, `0x540b90`: 1 = slot 7 `IsPC`, 2 = slot 10 `IsMonster`,
4 = slot 11 **`IsCOS`**, 8 = slot 18 **`IsItem`** — both named in
`docs/protocol/igobj_vtable.md` and left as bare slot numbers here until
round 422 — and 0x10 = slots 242/243/245, which are still unnamed), whose region-aware
distance (`GObj_DistanceBetween`) is **at most the radius**, and that is
**nearer than the best so far** -- the nearest player wins. A player candidate
first detours through `GObjPC::FUN_004fc160(pc+0x1ce8)`, the player's summoned
objects (a monster may pick a pet instead; the branch is unread beyond its
shape). **There is no level term in acquisition.**

**The level term is at BATTLE entry.** `CAIState_BATTLE::OnEnter` calls
`AITactics_CollectNearbyMonsters` (`0x540580`) with the new target:

	r = AITactics_LevelScaledRadius(ctx+0x15c, target)      ; 0x541e00
	AITactics_GatherObjectsWithin(&r, ctx, ctx+0x80)         ; 0x540860, kind mask 2

which gathers the **ten nearest MONSTERS** within `r` (a `MOB_AUTOMOB` never
counts) into the vector at `ctx+0x80`. The scaling, by `monster level -
target level` and with doubles (`fmul QWORD` at `0x541e62/73/84/95`):

| difference | factor | .rdata |
|---|---|---|
| >= 4 | **1.4** | `0xb45c08` |
| 1 .. 3 | **1.2** | `0xb45c00` |
| -3 .. 0 | 1.0 | -- |
| -6 .. -4 | **0.8** | `0xb45bf0` |
| <= -7 | **0.6** | `0xb45bf8` |

What the gathered list drives was unread when this was written; round 258
(next section) read it: it is the **aggro link**, the engine's own name.
`AI::CTactics::FUN_00540500` builds the same list for an explicit target from
`FUN_0053fe30`.

*Read closer in round 553, when the link was wired.* `r` is an **int**: the base is the float at
`ctx+0x15c` (`fld DWORD` `0x541e00`), the product is stored back as a float (`fstp DWORD [esp+0x4]`
`0x541e9b`; the -3..0 band jumps past the multiply and the store, `0x541e8f` -> `0x541e9f`) and then
chopped (`fnstcw; or eax,0xc00; fldcw; fistp QWORD` `0x541ea4..0x541ebe`) into the caller's
out-parameter (`mov [ebx],edx` `0x541ec2`); the two levels are bytes off vtable slot 73 (`movzx`
at `0x541e47`/`0x541e54`). And the four doubles are **float literals widened**, read off `.rdata`
with `objdump -s`: `0xb45c08` is `0x3ff6666660000000` = 1.4f = 1.39999997615814, `0xb45c00`
`0x3ff3333340000000` = 1.2f, `0xb45bf0` `0x3fe99999a0000000` = 0.8f, `0xb45bf8`
`0x3fe3333340000000` = 0.6f. So 106 x 1.2 is 127 (127.2 chopped), 108 x 1.2 is 129 (129.6, not the
130 rounding would give), and 110 x 1.4f is 154: the exact product 153.9999974 is rounded to 154.0
by the float store before the chop. `GatherObjectsWithin` compares the float distance from the
OWNER (`GObj_DistanceBetween` at `0x540a8d`, the owner in eax and the candidate in ecx) **at most**
the radius widened to a float (`fStack_48 <= fStack_58`), the owner skipped, sorts nearest first and
pops at most ten. `ai.LevelScaledRadius` returns that int since round 553, through the same float
store, and `ai.GatherWithin` is the gather.

**What OpenSRO can use.** `ai.DetectionRadius` and `ai.LevelScaledRadius`
carry the two rules with a test. The per-species `+0x14` distances are in no
archive this project holds: `_RefTactics` is a shard-database table, the
server package on the box has no shard backup (its `SR_GameRefData` folder is
the client-side text tables plus shop/teleport/quest files; its three
`SR_GameServer` minidumps are 2 MB thread-and-module dumps with no heap). So
when OpenSRO's monsters learn to notice a player, the distance itself will be
disclosed per species, and the rule around it will not be. *Round 552 built it
that way*: the scan runs in the runtime behind `-monster-aggro` with one disclosed distance for
every species (`ai.TacticsDetectionDistance`, 100), and the rest -- the radius, the nearest rule,
the cadence, the aggression roll, the truncations -- is the binary's ("Target acquisition: the
runtime (round 552)", below). *Round 553 built the aggro link on the level-scaled gather* ("The
aggro link: the runtime (round 553)", below), riding `-monster-battle`.

## The aggro link: a party's hit pulls the neighbours in (round 258)

Being hit reaches a monster as **command 2** through its command source --
`AI::CTactics` IS the monster's command source (its vtable shares
`CCmdSrcNet::PostCommand` at slot 1; slot 7, `AI::CTactics::DispatchCommandToState`,
forwards a command to the current state's slot 5, `CAIState::DispatchCommand`,
`0x558bb0`, which maps command codes to vtable slots: `0->7 2->6 4->8 5->9 6->10
8->11 9->12 10->13 0xb->14 0xc->15 0xd->16 0xe->29 0xf->30 0x10->17 0x11->18`).
Command 2 lands in **slot 6, `CAIState::OnAttacked`** (`0x558ea0`, the base
used by IDLE, WANDER, FLEE and HOMING; BATTLE overrides it with the retarget
rule of behaviour `+0xfc`). The attack record is `{attacker, damage (+4), hate (+8), hatePercent
(+0xc)}` (`AITactics_CreditAttacker`, `0x5473c0`, next section: `+4` goes to the seat's damage, `+8`
and `+0xc` to its hate). *The two blocks below were rewritten in place in round 553: round 258's
said `damage` where the binary reads the HATE, which round 537 had corrected only in a note under
them.*

	saved = record.hate                        ; mov eax,[esi+0x8] 0x558ea6
	behaviour +0xf0 (record)                   ; the aggro link, below: zeroes record.damage, decays record.hate
	record.hate = ftol(saved * 1.15f)          ; 0xb46300 = 0x3ff2666660000000, the float 1.15f widened
	                                           ; (1.14999997615814), its only use; _ftol2_sse on the extended
	                                           ; product with no float store, so 20 hate books 22, not 23:
	                                           ; the victim credits the attacker 15 % MORE than the record
	if behaviour +0xec (attacker accounting) == 0:
	    SetTarget(1) ; ChangeState(3)          ; edi = 3 -> BATTLE (asm: xor ebx,ebx ; lea edi,[ebx+3])

**The link itself**, `AITactics_ExtRoutine::LinkAggroToNearbyMonsters`
(`0x547570`, behaviour `+0xf0`, `AITactics_ExtRoutine.cpp` -- its CLAMP assert
cites line 0x662), re-read whole in round 553:

	if record == null or record.hate == 0: return 1        ; a blow with no hate links nothing
	attacker = resolve(record.attacker); must be a PC       ; FUN_00485d90, vtable slot 7; else return 1
	party = pc+0x1cb8; none -> return 0                     ; piVar4[0x72e]
	(party+0x10 & 1) == 0 -> return 0                       ; not exp-sharing
	AITactics_CollectNearbyMonsters(attacker)               ; the ten nearest OTHER monsters within
	                                                        ; LevelScaledRadius(ctx+0x15c, attacker) -- an
	                                                        ; int, 0x541e00 -- of the VICTIM (0x540860)
	n = 0
	for each member of the party's list (party+0x18):
	    if member == attacker: n++                          ; 0x5476f6, without measuring
	    else if member resolves (FUN_00485dc0)
	         and 0x430ce0(member.pos, attacker.pos)         ; same or adjacent region, or both in a dungeon
	         and |member - attacker| <= 1000.0: n++         ; 0xb45c68; fcomp; fnstsw; test ah,0x41; jp
	                                                        ; 0x5476e9..0x5476f4: INCLUSIVE
	n = CLAMP(n, 0, gathered.size())                        ; 0x54782b..0x547839, 0x547778..0x54778c
	record.damage = 0                                       ; mov [edi+0x4],ebx (ebx = 0) 0x547797
	if gathered is empty or n <= 0: return 0                ; 0x5426e0 on ctx+0x80 (add esi,0x80 0x54771f), 0x5477a7
	for i in 0 .. n-1:
	    if record.hate < 1: record.hate = 1                 ; 0x5477b2..0x5477b8
	    m = gathered[i]
	    if ValidTargetOrNull(m) and m.cmdsrc:               ; 0x540dc0 at 0x5477ea; +0x188
	        m.cmdsrc->slot7(0xe, record, 0)                 ; command 0xe -> slot 29 (0x547805..0x54780a)
	        record.hate = ftol(record.hate * ratio)         ; fild [esi+0x8]; fmul DWORD [0xc8252c];
	                                                        ; _ftol2_sse; mov [esi+0x8],eax  0x54780c..0x54781a
	return 0

so **as many neighbouring monsters as the party has members on the spot join
the fight, each forwarded a smaller share of the record's HATE than the last** (the first link the
raw hate, the second half of it, the third a quarter -- `ftol` at each step, and never below 1),
while the victim itself books 1.15f x the raw hate and nobody books the blow's damage. The region
test `0x430ce0` compares the two positions' 16-bit region ids: bit 15 of both equal, both set (a
dungeon) passing outright, else the x and y bytes each within 1 -- which 1000 units already implies
at the 1920-unit region span. What hate a plain blow's record carries is unread.

*The correction's history.* Round 537 found the `+4`/`+8` split in `CreditAttacker` and recorded
the shares as hate in a note; round 553 folded that note into the blocks, which until then still
read `record.damage`.
Command 0xe lands in **slot 29, `CAIState::OnAggroLinked`** (`0x559bb0`): the
attacker accounting, `SetTarget(1)`, `ChangeState(3)` -- the same entry into
BATTLE as a direct hit, but WITHOUT running the link again, so a link never
cascades. BATTLE's own slot 29 (`0x55a320`) only credits the attacker, and
goes to IDLE (`edi = 1`) if the accounting refuses.

`g_MonsterAggroLinkDecreaseRatio` (`0xc8252c`) is the server config key
**`MONSTER_AGGRO_LINK_DECREASE_RATIO`** (a percentage, /100), default **0.5**
(`0xb45b68`, `fld DWORD`), read by `CMainProcess::FUN_00427050` with the other
knobs -- the block `internal/rates` already mirrors. The same pass shows two
more keys that block did not list: `PCSpeedRatio` (`0xc8253c`, default 1.0, cap
3.0; `GObjPC_InitStats` multiplies the speed params by it when it is not 1),
and `HwanGainFactor`, which is **loaded and never read** -- its pre-config value
is 100.0 (`0xb45e10`), the clamp turns that into 10.0, and no instruction
outside the loader touches `0xc82528`. A knob with no consumer.

A solo player never links anything: with no party the routine returns 0 before
gathering. Bit 0 of the party's `+0x10` is the **experience-sharing** flag
(`party.md`: the join-time cap test names it through the client's
`MEMBER_FULL_EXP_SHARED_PARTY` refusal), so the link fires only for a member of
an exp-sharing party; the berserk party share tests the same bit.
## The threat table: whom a monster fights when several things hit it (round 259)

**Two seats.** The context keeps exactly two attackers -- the TARGET at
`+0xbc..+0xcc` and one CHALLENGER at `+0xd0..+0xe0`, each `{id, damage, hate,
hits (byte +0xd), lastHitTick}` -- and the total damage taken at `+0xb0`. A
third attacker is not tracked. `SetTarget(0)` and the leave paths zero all
ten words.

**The credit**, `AITactics_CreditAttacker` (`0x5473c0`, behaviour `+0xec`),
takes the attack record `{attacker, damage, hate, hatePercent}`:

	guard: an immobile monster (owner IsMonster, slot 75 == 3, walk and run speed <= 0)
	       credits only an attacker within row+0x14; otherwise it zeroes the attacker's
	       hate and returns 1
	total (+0xb0) += damage
	seat = target if empty or the attacker         -> code 0
	     | challenger if empty or the attacker     -> code 1
	     | none                                    -> code 2, nothing booked
	seat.hits++ ; seat.id = attacker ; seat.damage += damage
	seat.hate = clamp(seat.hate + seat.hate*hatePercent/100 + hate, 0, INT_MAX)
	seat.lastHit = g_tickMs
	return 1 when code == 0 and seat.hate < 1     ; the target is DROPPED

so a blow that empties the target's hate (a hate-reducing skill: the `tant`/
`tnt2`/`dtnt` params are where such values come from) makes BATTLE's
`OnAttacked` go to IDLE. The record's hate is what `OnAttacked` sets to
`raw * 1.15` for the victim and what the aggro link halves per neighbour.

**The choice**, `AITactics_Handler_0fc` (`0x548090`, behaviour `+0xfc`,
BATTLE's slot 6): credit first; a refusal returns 1 (-> IDLE). Then the
tactics row's `+0x20` (column 9) decides:

| rule | behaviour |
|---|---|
| 0 | keep the first attacker |
| 1 | `SetTarget(attacker)` whenever it is not the target -- the seat keeps its damage, hate and hit count; only the id and tick change |
| 2 | `AITactics_ResolveTarget(code, attacker)` (`0x545680`), below |

`ResolveTarget` by the credit code: **0** -- the target hit us, nothing
changes. **1** -- the challenger hit us: an invalid target is replaced by the
challenger outright (the seat copied down, the challenger cleared); otherwise
the seats SWAP (`0x545580`) when `target.hate < challenger.hate` **or**
`g_tickMs - target.lastHit >= 2 x the attack interval` (selector `+0x48`).
**2** -- an untracked third attacker: with a valid target, `d_candidate` and
`d_target` (`GObj_DistanceBetween`) are compared at `0x545720` and the target
is KEPT when `d_candidate <= d_target` (`fcomp; test ah,0x41; jne keep`);
a **farther** attacker takes the seat -- the old target is copied into the
challenger seat (`0x545550`) and the newcomer starts a fresh seat with one hit.

**The attack interval.** `AI::CAISkill_Basic::ArmNextAttack` (`0x5619e0`):
`+0x44 = the chosen skill; +0x48 = skill.ReuseDelay + rand % (J + 1)`, with
`J = clamp(previous +0x48 / 5, 500, 2000)` ms -- so a Mangyang (ReuseDelay
3000) swings every 3000..3600 ms once running, and round 254's "cadence is the
ReuseDelay" is the floor of that window. The idle test above doubles this
interval.

*Corrected in round 545.* The window does not pace the swings. `+0x48` is armed on tactics timer 5
(`BATTLE::OnEnter` at `0x55a018`, `Handler_0e8`'s re-arm at `0x547342`), and timer 5 is a
first-table timer, which every arming marks fired (`ArmTimer` `0x53d6c7`), so the next `TimerDue(5)`
answers at once whatever the period; the readers of `+0x48` found are those two armings and the
idle window above. The cadence between swings is the action machine's cooldown, round 254's
`ReuseDelay` -- 3000 ms for a Mangyang, not 3000..3600. The reading is in "The pure BATTLE rules
and the timer read (round 545)", below.

`ai.ThreatTable` (`internal/ai/threat.go`) carries the credit, the drop, the
three rules and the interval with tests; nothing in OpenSRO runs it yet.

## The skill choice: triggers first, then a weighted draw (round 260)

The selector object at `ctx+0x9c` is an `AI::CAISkill_Basic` (vtable
`0xaf9d24`; the `Unique_Summon_A/B/C` classes at `0xaf9d5c/0xaf9d94/0xaf9dcc`
override slots 2, 3, 6, 7, 8 and 12 for the unique-monster tactics ids). Two
lists live on it: the **attack list** (`+0x18/+0x1c`, plain skill pointers) and
the **trigger list** (`+0x8/+0xc`, 24-byte entries `{?, skill, aiSkillRow,
enabled, lastFired, phased}`).

**Registration** -- `AI::CTactics::RegisterAISkill` passes each of the owner's
skills with `AI::CTactics::FindAISkillRow(skillId)` (`0x6ab1d0`, a map at
`+0xb0` of the object in EAX) to slot 3, `CAISkill_Basic::RegisterSkill`
(`0x5614d0`): a skill WITH a `_RefAISkill` row becomes a trigger entry; one
without goes to the attack list, through three branches on `AI_SkillType`
(`CRefSkill+0x166`, skilldata column 67: `'D'`, `'S'`, other) that all end in
the same push (`GObjPC::FUN_004ab760`; the branch's effect is unread).

**The pick** -- slot 7, `CAISkill_Basic::PickSkill` (`0x561b00`), called by
BATTLE's attack step with the target:

	slot 12 CheckTriggers (0x561a50): the first ENABLED trigger entry whose condition holds
	        is chosen at once -- TriggerHolds (0x561180) by the row's +0x20:
	          type 0  HPBelow (0x5611d0): owner CurHP*100/MaxHP (slots 66/68) <= row+0x24
	                  -> fire, and DISABLE the entry (one shot per life)
	          type 1  Periodic (0x561210): first evaluation arms lastFired = now (or fires at once
	                  when row+0x28 bit 0), later ones phase-align once and fire when
	                  now - lastFired >= row+0x24
	otherwise, over the attack list, every skill with AI_AttackChance (CRefSkill+0x164,
	column 66) != 0 gets
	          margin = skill.Range + ownerBC + targetBC - distance        ; floats
	          weight = AI_AttackChance + (margin > 0 ? ftol(margin x 5.0 / 10.0) : 0)
	and one is drawn: r = |rand()| % (total + 1), the first entry whose cumulative weight
	is >= r (0x561ce9..0x561d61); the pick goes to slot 5, ArmNextAttack: +0x44 = the skill,
	+0x48 = ReuseDelay + rand % (J + 1)

**Corrected in round 554** (re-read in `srv.asm` and `.rdata`): the reach term is HALF the
margin in whole units, not the whole margin this section recorded. Between the compare and the
`ftol` sit `fmul QWORD [0xb45b00]; fdiv QWORD [0xb45c60]` (`0x561c93..0x561c9f`), and
`objdump -s` reads `0xb45b00` as `0x4014000000000000` = 5.0 and `0xb45c60` as
`0x4024000000000000` = 10.0; the decompile drops both, since they act on the FPU stack between
the compare and the call (the trap of round 535's `ftol2` pop). The margin is computed in floats
(`fstp DWORD` at `0x561c72` and `0x561c7e`; the distance is the float `GObj_DistanceBetween`
stored at `0x561bae`) and added only when above 0 (`fcom; fnstsw; test ah,0x41; jne`
`0x561c88..0x561c91`). The draw's modulus is total + 1 and its compare inclusive (`cdq; xor; sub;
add ecx,1; div ecx` `0x561cf2..0x561cfc`, `cmp [esi],eax; jae` `0x561d2e`), so `r` runs
0..total and the first entry takes one outcome more than its weight. And `0x5632d0`, which this
section called the draw, is the `invalid vector<T> subscript` throw the bounds checks at
`0x561d19`/`0x561d24`/`0x561d56` jump to -- the draw is inline in `PickSkill`. `ai.SkillWeight`,
`ai.PickSkill` carry the corrected rules with a test.

So a monster with one attack skill always swings it; a monster with several prefers, in
proportion to `AI_AttackChance`, the ones whose reach covers the target by the most units; and a
tactics-bound skill fires on its HP threshold once or on its timer, ahead of any draw. **Four
roster species carry two** (round 554 -- this paragraph said "the whole Jangan roster" has one:
characterdata col 84 is 161 for Mangyang, 167 for Water Ghost slave, 169 for Water Ghost and 177
for Yeoha, the other seven read 0 there, and no roster species names a third), drawn by the
runtime since that round: "The second attack skill: the runtime (round 554)", below.
`ai.TriggerHPBelow/Periodic` carry the trigger rules with a test.

## HOMING: the way home (round 261)

`CAIState_HOMING::OnEnter` (`0x55a540`): a monster with neither a nest
(`ctx+0x30`) nor a saved location record (`+0x1bc`) asks `0x558af0` for its
spawn record and asserts out (-> state 0) when that has none. Then: a timer is
armed through the indexed setter (`0x53d600`, arguments `(2, 500)`), the dwell
is `AIState_DwellMs` (HOMING's 50 s), `MoveHome` starts the walk, the state's
`+0x1c` is set to **`trunc(detectionRadius / runSpeed x 1000)` ms** (the
`ctx+0x15c` radius over the owner's `+0x170`; `0x55a60e..0x55a63e`: `fld; fdiv; fmul QWORD
0xb45c68` under the control word as found, then `or eax,0xc00; fldcw; fistp QWORD` -- RC=chop for
the conversion alone; round 552 corrected this line's "round", and `ai.HomingReaggroDelayMs`, which
added 0.5), the `0x704f` motion notice
goes out, `+0x164` gets a random sign, and `SetTarget(0)` forgets the fight.

**`MoveHome`** (`0x545c50`): home is the nest's position record (`nest+0x10`)
when there is a nest, else the context's own spawn record (`ctx+0x1b4`). With
`R` = the nest's radius (`nest+0x20`) or the roam radius (`ctx+0x1cc`), the
destination is home moved toward the monster, along `normalize(monster - home)`, by

	offset = rand % (1 + trunc(R / 3)) + R / 3       ; -3.0 at 0xb45e08, 3.0 at 0xb45ab8
	                                                 ; i.e. R/3 .. R/3 + trunc(R/3) units
	                                                 ; (66.7 .. 132.7 for R = 200)

unless the owner's slot 243 (`+0x3cc`) answers non-zero (then exactly home), and the world's
move request (`DAT_00cc387c` slot 12) is issued -- flag 1 for a player or a
slot-11 object, 0 for a monster.

**Corrected in round 535.** Round 261 recorded `offset = rand % (1 + ftol(R / 3)) - R / 9`, i.e.
`-R/9 .. +2R/9`. That came from the decompiler's `extraout_ST0 / 3.0`, which assumed
`_ftol2_sse` (`0x9fbb40`) leaves its argument on the x87 stack. It pops it: the SSE2 path stores
it with `fstp QWORD [esp]` (`0x9fbb52`) before `cvttsd2si`, and the x87 path from `0x9fbb7f`
consumes `st0` as well. The stack walk at `0x545cff..0x545d70` (re-read 2026-09-24):

	545cff  fld   [esp+0x10]        ; st0 = R (stored as a float at 0x545cf6)
	545d05  fld   QWORD 0xb45e08    ; -3.0 ; st0 = -3, st1 = R
	545d0b  fdivr st, st(1)         ; st0 = R / -3, st1 = R
	545d0d  call  0x9fbb40          ; eax = trunc(-R/3), pops ; st0 = R
	545d12  ecx = 1 - eax           ; 1 + trunc(R/3) ; idiv: edx = rand % ecx
	545d30  fild  rem               ; st0 = rem, st1 = R
	545d38  fxch  st(1)             ; st0 = R, st1 = rem
	545d3c  fdiv  QWORD 0xb45ab8    ; 3.0 ; st0 = R/3
	545d68  fstp  [esp+0x10]        ; R/3 as a float ; st0 = rem
	545d6c  fadd  [esp+0x10]        ; st0 = rem + R/3
	545d70  fstp  [esp+0x10]        ; the stack is empty

That is the only reading that leaves the stack balanced. The direction is `FUN_00430ad0` with
`esi` = the monster's position (`MoveHome`'s `ecx`, the owner's `+0x7c` record, passed at
`0x55a5fc..0x55a5ff`) and `edi` = home (`0x545ccd`/`0x545cd1`), which returns
`esi - edi` across regions, then `FUN_004328c0` normalizes it. `0x545d7a..0x545dc8` add
`dir * offset` to the home record's x, y and z. `ai.HomingScatterRange` carries the corrected band.

**The step**, behaviour `+0x118` (`AITactics_HomingStep`, `0x5496c0`), each
time timer 0 of the context's table (`ctx+0x34`) is due: **arrived** when the
owner stands within **5.0** units of the destination (`AITactics_HasArrived`,
`0x541f60`, `fcomp DWORD 0xb45b28`) -> return 2 -> message `0x24` -> IDLE.
Otherwise, with `d_pos` = |owner - spawn| and `d_dest` = |destination - spawn|:
when `d_dest <= d_pos` (the destination lies inward) the step continues --
while `d_pos` is still beyond the roam radius (`ctx+0x1cc`) the direction gets
a wobble, `dir = normalise(dir + heading x k)`, `k = (rand % 101 + 50) / 100`
= **0.50..1.50** (`fmul QWORD 0xb46068` = 0.01), then a blocked probe
(`0x541890`, mode 3) and `AITactics_MoveAlongDirection` for the remaining
distance; when the destination would be **farther** from the spawn than the
monster already is, the step returns 2 as well -> IDLE.

**Re-aggro on the way.** `HOMING::OnUpdate` (`0x55a690`): the 50 s dwell ->
message `0x25` -> IDLE; otherwise, once the state's slot 48
(`ReaggroWindowPassed`, `0x55a720`: `now - enteredAt > +0x1c`) is true, the
acquire behaviour runs and a hit scan (-> message `0x22`) can send the monster
straight back to BATTLE -- so a monster ignores players for the time it would
take to run its own detection radius, then notices them again. `ai.Homing*`
carries the constants with a test.

## The behaviour table at context `+0xe8`

`AI::CTactics::vslot_017` (`0x53fc00`) fills sixteen function pointers at
`this+0xe8 .. +0x124`; the states call them instead of reading the row. The
defaults and the tactics-driven overrides:

| slot | default | overridden by | called from |
|---|---|---|---|
| `+0xe8` | `AITactics_Handler_0e8` | -- | `BATTLE::OnUpdate` |
| `+0xec` | `FUN_005473c0` (attacker accounting) | -- | `Handler_0fc`, `BATTLE::vslot_029`, `FUN_00558ea0`, `FUN_00559bb0` |
| `+0xf0` | `AITactics_ExtRoutine::FUN_00547570` | -- | `FUN_00558ea0` |
| `+0xf4` | `FUN_00547860` | -- | |
| `+0xf8` | `FUN_00559000` (no-op) | `+0x14 != 0` -> `FUN_005478f0` (acquire a target); TacticsID 0x21/0x3f/0x71 -> `FUN_00547ad0` | `IDLE`, `WANDER`, `HOMING`, `WATCHOUT` updates, `EMOTION::FUN_0055a8b0` (which is IDLE's slot 3 too: vtable `0xaf899c`, round 552) |
| `+0xfc` | `AITactics_Handler_0fc` (on hit: retarget by `+0x20`) | -- | `BATTLE::vslot_006` |
| `+0x100` | `FUN_00548120` (reach test) | flags bit 2 -> `FUN_005481a0`; bit 7 -> `FUN_00548270`; TacticsID 0x21/0x3f/0x71 -> `FUN_00548340` | `BATTLE::OnUpdate` |
| `+0x104` | `FUN_005483c0` (give-up check) | TID bit 15 -> `FUN_005484b0` | `BATTLE::OnUpdate` |
| `+0x108` | `FUN_005485b0` | -- | `BATTLE::OnUpdate`, `WANDER::OnUpdate`, `EMOTION::FUN_0055a8b0` |
| `+0x10c` | `FUN_00548950` (the dead request) | -- | `BATTLE::OnUpdate` |
| `+0x110` | `AITactics_Handler_110` | -- | `FUN_00541820` (loads `[ctx+0x110]` at `0x541821`, calls it at `0x541838`), called from the `OnEnter` of WANDER (`0x559e82`), BATTLE (`0x55a04a`), FLEE (`0x55a491`), HOMING (`0x55a64a`) and PICKITEM (`0x55abd6`), and from `AITactics_Handler_0fc` (`0x5480a1`), `FUN_00549ac0` (`0x549de7`) and `FUN_00549f80` (`0x54a141`). The `Unique_Summon` AI skills reach the same address another way (not followed). *Corrected in round 537*: this cell said no state calls it through the context |
| `+0x114` | `FUN_00548be0` | TID bit 15 -> `FUN_00549460` | `BATTLE::OnUpdate` |
| `+0x118` | `FUN_005496c0` | TID bit 15 -> `FUN_00549970` | `HOMING::OnUpdate` |
| `+0x11c` | `FUN_00549ac0` | -- | `FOLLOW::OnUpdate` |
| `+0x120` | `FUN_0054a440` | -- | `FLEE::OnUpdate` |
| `+0x124` | `FUN_0054a570` | TID bit 15 -> `FUN_00559000` | no caller found through the context |

So a tactics row shapes a monster through three fields of this table
(`+0x14`, `+0x90`, and the three special TacticsIDs) plus the per-call reads
above; everything else in the row is data the states have not been seen to
touch, and stays unlabelled until a reader is found.

## What this gives OpenSRO

The server has monster spawns and a combat loop but no AI: monsters do not
wander, chase, give up, or go home. This is the machine that does all four, and
it is now specified precisely enough to implement — sixteen states, a
transition rule with a real fallback, a message interface with proven default
transitions, and one real timing constant.

`server/internal/ai` implements the enum, the message mapping and `ChangeState`
including the two behaviours most likely to be "tidied away" by someone who has
not read the binary: DEAD refusing every transition silently, and the IDLE
fallback ignoring its own `OnEnter` result.

**Not implemented:** the state bodies. Specifying the machine does not specify
what WANDER picks for a destination or how BATTLE chooses a skill; those are
`AI::CTactics`' own 19 slots and the `AI::CAISkill` hierarchy. The row layout
above gives the rules that are now implementable without a tactics table at
all: the roam radius (x1.5 under rule 1) with
its HOMING exit, and the give-up distance with its IDLE exit. Both wait on
OpenSRO's server moving monsters at all (`docs/TODO.md`).

*Corrected in round 537.* This paragraph said the roam radius is "200 units when nothing sets it".
`AI::CTactics::Attach` (`0x53f2a0`) does store 200.0 (`0xb45d68`, `fld` at `0x53f367`) when there is
no nest, no caller radius and the row's `+0x84` (column 38) is not positive -- but in exactly that
case `IsWithinRoamRadius` (`0x545f70`) answers "within" without measuring (`cmp [row+0x84],0; jg`
at `0x545fde`, then `mov al,1`), unless the owner's slot 242 or 243 answers non-zero (the (1,2,4,x)
TID shapes; slot 243 answering 1 makes `Attach` store 5.0 instead). So retail never applies the 200
to a roster monster. OpenSRO's runtime uses 200 as its own roam radius (below), disclosed as such.
Round 537 built the roam radius and its HOMING exit; the give-up distance waits on the BATTLE chase.
Round 545 built its two rules as pure functions (`ai.TargetWithinChaseRange`, `ai.GiveUpCode`), and
round 546 runs them in the runtime's BATTLE tick behind `-monster-battle` ("BATTLE's chase and the
monster's own swing (round 546)", below).


## Flag bits 2 and 7 also switch the give-up check OFF (round 421)

The table above attributes `_RefTactics` column 42 (`+0x90`) bits 2 (`0x4`) and
7 (`0x80`) to the **acquire** behaviour, where they pick the target-kind filter
pair. They have a second use-site, and it is a behavioural one:
`AITactics_BattleGiveUpCheck` (`0x5483c0`) opens with

	uVar3 = *(uint *)(*(int *)(param_1 + 0x2c) + 0x90);      // the flag word
	if (((uVar3 & 4) != 0) || ((char)uVar3 < '\0')          // bit 2 or bit 7
	    || (cVar2 = refTactics->+0x79, cVar2 == '\0') || (cVar2 == '\x02'))
	  return 0;

so **a monster whose tactics flags carry bit 2 or bit 7 never runs the give-up
test at all** — the `+0x7c` distance comparison below it is unreachable for that
species. The `+0x79` half of the same guard is already recorded on column 35;
the flag-bit half was not. `AITactics_BattleGiveUpCheck_TID8000` (`0x5484b0`),
the TID-bit-15 variant, has the same opening.

Stated as mechanism, not motive: the bits that choose a non-default target-kind
filter are the same bits that suppress giving up, but nothing here says *why*,
and this round did not read the acquire side to find out.

**Why it was missed.** The bit-7 test does not contain `& 0x80`. MSVC compiles a
sign-bit check to `test al,al; js`, which Ghidra renders `(char)uVar3 < '\0'` —
so a census of flag bits built by grepping `& 0x` sees bits 2, 8 and 15 in these
functions and silently drops bit 7. A sweep of that idiom across the server dump
finds **19 sites**; the four in AI tactics are all this same `+0x90` word, and
the rest are the DB-backup scope mask (round 420), one currency check that also
tests `& 0x80` explicitly, navmesh code and CRT routines.

**No recorded table was found to be WRONG by that sweep** — column 42 already
lists bit 7 correctly. The blind spot cost a missing use-site, not a wrong
entry.

## What the acquire filter actually selects, and a motive refuted (round 422)

Round 421 found that flag bits 2 and 7 suppress the give-up check and recorded it
as mechanism without motive. Reading the acquire side resolves the mechanism and
**refutes the obvious motive.**

With the kind mask resolved to names, the three non-default filters read:

| flag bit | kinds | = | selector |
|---|---|---|---|
| 2 (`0x4`) | 5 | `IsPC` \| `IsCOS` | 3 (`0x546790`) |
| 7 (`0x80`) | 5 | `IsPC` \| `IsCOS` | 4 (`0x546a30`) |
| 8 (`0x100`) | `0x11` | `IsPC` \| slots 242/243/245 | 5 (`0x547070`) |
| *(none)* | 1 | `IsPC` | 2, `AITactics_Select_Nearest` |

So bits 2 and 7 add **summoned creatures** — pets, mercenaries, carts — to what
the monster scans for, differing only in which of the eight selectors picks the
winner. Selectors 3 and 4 end in the same shape as selector 2: a distance
compared against the best so far, then `*param_4 = ROUND(dist)` and the
candidate registered.

**THE MOTIVE I EXPECTED IS WRONG.** The natural story for suppressing give-up is
"this species hunts objects rather than players, and an object does not run
away". That is not what the filters say: **all three still include `IsPC`**
(bit 1 of the kind mask). And bit 8 changes the target kinds just as much yet
does **not** suppress the give-up check — so the suppression is specific to bits
2 and 7 and is not explained by "has a non-default filter". Why those two bits
and not bit 8 remains unread.

**The `0x10` blank is filled (round 423).** Slots 242, 243 and 245 are
`CGObj::IsCOSGuardKind1`, `CGObj::IsCOSGuardKind4` and
`CGObj::IsFortressWarMonster` — TypeID predicates over the `(1,2,4,*)`
family whose rows are, per prefix and 100 %% pure, `COS_GUARD_*` (TypeID4 1
and 4) and `MOB_FW_*` (TypeID4 3). They sit in a contiguous run with slot
**244**, which is already `CGObj::IsFortressFlag`.

So **flag bit 8 is the siege filter**: a species carrying it scans for
players *plus guild guards and fortress-war monsters*. That also sharpens
round 422's open question — bit 8 changes the target kinds and does **not**
suppress the give-up check, while bits 2 and 7, which add only `IsCOS`, do.

## Bits 2 and 7 are one flag, and the engine asserts it (round 424)

Rounds 421–423 left the question of why bits 2 and 7 suppress the give-up check
while bit 8 does not. A sweep of every read of `refTactics->+0x90` — 14 sites —
answers it: **bits 2 and 7 are not two independent flags but a pair.**

	AI::CTactics::FUN_00540d20   (flags & 0x84) == 0
	FUN_00547c70                 (flags & 0x84) != 0

Both test them as the single mask `0x84`. And `AITactics_TargetOutOfReach`
(`0x548120`), the first test `CAIState_BATTLE::OnUpdate` runs, opens with **two
asserts**:

	if ((flags & 4)    != 0) CGameServer::Assert_BreakIfDebugger();
	if ((flags & 0x80) != 0) CGameServer::Assert_BreakIfDebugger();

They decompile as two tests because they are two `assert()` calls in the source,
not because the bits differ. **So the engine itself states the invariant: a
species carrying either bit must never reach the chase / out-of-reach test.**
The give-up suppression round 421 found is that same invariant enforced from the
other side — such a species does not use the chase machinery at all. Bit 8 does
not participate because it only swaps the target-kind filter; it leaves the
chase model alone.

**A number trap.** Column 38 sits at *offset* `+0x84` (the roam radius) and this
bit pair is *mask* `0x84`. Same number, unrelated meanings — do not join them.

## Flag bit 9 (`0x200`) was missing from column 42 (round 424)

The column-42 note lists bits 2, 7 and 8. **Bit 9 is also live**, at two sites:
`GObjPC::FUN_005299e0` and `FUN_00540de0`. The second is a target-validation
filter and shows what the bit buys:

	candidate must be non-null, slot 0x18 non-zero, and GetLifeState() == 1   ; alive
	if not IsCOS and not slot 0x30:
	    m = GetBodyMode()                      ; slot 64
	    if 1 < m < 5                      -> reject
	    if (m == 6 || m == 7) and !(flags & 0x200) -> reject

So **bit 9 admits targets whose body mode is 6 or 7**, which are otherwise
refused; body modes 2–4 are refused regardless. **Round 425 named them** from
the engine's own string table: 2 is `BODYMODE_INVINCIBLE`, 3 is
`BODYMODE_INVISIBLE`, 4 is `BODYMODE_BERSERKER` — so a monster will not
target anything invincible, invisible or berserk. Modes 6 and 7 are **null
in that table**, i.e. they exist in code and the engine does not name them;
see `docs/protocol/character_state.md`. The alive test is round 413's life-state value 1, reached
independently.

**Why the bit was missed:** the note was built from the acquire path, where only
2, 7 and 8 appear. Bit 9 is only tested in the validation filter and in a
`GObjPC` function that reaches the tactics row through `param_1[0x62]` rather
than the AI context, so a sweep anchored on the AI module does not see it.

## OpenSRO's own monster protocol (placeholders)

Round 533 added two messages so the client can draw a monster the server moves. Both are
OpenSRO's own, additive placeholders (`docs/protocol/PROTOCOL_DECISION.md`); no existing layout
changed. Client: `scripts/net/combat.gd` (`CombatNet.decode_monster_moved`,
`decode_monster_motion_list`), drawn by `scripts/world/monster_motion.gd` (`MonsterMotion`) and
`World3D._on_monster_moved` / `_on_monster_motion_list` / `_step_monster_bodies`. Since round 537
the server sends both, and only with its `-monster-ai` flag on, which is off by default ("OpenSRO's
runtime", below). On 2026-09-23,
0x007C..0x007F appeared in no non-test file under `server/internal/session`,
`server/internal/proto` or `client/scripts/net`. Round 536 declared the two in
`server/internal/session/monstermove.go` (below). Round 540 gave the client two more, 0x007D and
0x007E ("The strike and spawn pushes", below); until round 541 neither appeared in any non-test
file under `server/` (grep, 2026-09-24). Round 541 declared 0x007D in
`server/internal/session/monsterstrike.go` and sends it only with its `-monster-strike-push` flag
on, which is off by default ("The strike push's server half", below). Round 542 declared 0x007E in
`server/internal/session/combat.go` and sends it only with its own `-monster-spawn-push` flag on,
which is off by default too ("The spawn push's server half", below). Round 548 gave the client
`OpRevive 0x0028` and `OpReviveResult 0x0029` ("The player's dead state: the client half", below);
on 2026-09-24 neither appeared in any non-test file under `server/internal` or
`client/scripts/net` before it, and `server/` still has neither -- the server half (behind
`-player-dead-state`, off by default) declares the same numbers next.

| op | dir | payload |
|---|---|---|
| `OpMonsterMoved 0x007c` | s→zone | s64 monster id, f32 x, f32 z (the server's position when it issued the move), f32 dest_x, f32 dest_z, f32 speed (world units per second), u8 mode (0 walk clip, 1 run clip) -- 29 bytes |
| `OpMonsterMotionList 0x007f` | s→requester | u16 n, then n entries of {s64 id, f32 dest_x, f32 dest_z, f32 speed, u8 mode} (21 bytes each); sent right after an `OpMonsterListResult`, ONE packet per list |
| `OpMonsterAttacked 0x007d` | s→zone, the attacker included | s64 monster id, s64 target character id, s32 damage (0 when blocked), u8 flags (bit 0 the monster's critical, bit 1 blocked, bit 2 the target died), s32 target HP after the blow (after a death, the HP it was put back on its feet with -- or 0 under `-player-dead-state`, round 549), s64 death exp lost -- 33 bytes; sent right AFTER the attacker's `OpAttackResult`, from the same goroutine, and after the zone's `OpMonsterDamaged` for the same swing; only with `-monster-strike-push` on (round 541). With `-monster-battle` on as well (round 546) the same message carries the monster's OWN swing, from the AI tick's strike worker, with no `OpAttackResult` before it; the layout is unchanged. Suffixes: the 13-byte wall block (round 640), then **u32 skill id** (round 785: the attack skill the monster swung -- retail's 0xB070 names it; the wall block is then always written, zeros for no wall) |
| `OpMonsterSpawned 0x007e` | s→zone | one record in `OpMonsterListResult`'s own encoding (s64 id, u16-prefixed name, u16-prefixed code name, f32 x/y/z, u32 max HP, HP, level, rarity), then f32 heading (radians, OpenSRO's world frame: from +x toward +z); sent when a monster appears -- a roster respawn or a GM `/spawn` -- only with `-monster-spawn-push` on (round 542) |
| `OpRevive 0x0028` | c→s | one u8 option since round 665, retail's own byte: 1 the return point, 2 the present point (level 10 or under). Sent by the dead window's two buttons (`HudPanels.show_revive_prompt` -> `World3D._on_revive_requested(option)` -> `NetClient.revive(option)`) and by `OPENSRO_QA_REVIVE_AFTER` with `OPENSRO_QA_REVIVE_OPTION`. An empty request (a client before round 665) is option 2 at level 10 or under and option 1 above it. The retail request is **0x3053** {u8} (the client's `FUN_00797d90`, `push 0x3053` at `0x797e30`; round 665 -- the 0x7053 written here before was the `0x7000 \| op` precedent, never a read). `character_state.md`, "The resurrect choices (round 665)" |
| `OpReviveResult 0x0029` | s→requester | u16-prefixed error string (empty on success), then s32 HP and s32 MP -- HP `1 + trunc(0.4 x MaxHP)`, the retail handler's additive arithmetic from 0 (round 550, `session.reviveHPDelta`), MP `character.RespawnMP` (0.4 of the maximum, a disclosed stand-in for the same additive rule); the decoder takes a refusal with or without the tail. Sent only with `-player-dead-state` on (the server half), and only after an `OpRevive`: round 665 removed the auto-revive fallback. For option 1 it follows the `OpChangeZoneResult` to the return point and carries the load path's HP `trunc(0.4 x MaxHP)` |

Fixtures, pinned by `client/scripts/net/combat_test.gd`:

- `OpMonsterMoved`, monster 7 from (100, -200) to (140, -200) at 8, mode 0:
  `07 00 00 00 00 00 00 00 00 00 c8 42 00 00 48 c3 00 00 0c 43 00 00 48 c3 00 00 00 41 00`.
- `OpMonsterMotionList`, the same leg as its one entry:
  `01 00 07 00 00 00 00 00 00 00 00 00 0c 43 00 00 48 c3 00 00 00 41 00`.
- `OpMonsterAttacked`, monster 7 strikes character 42 for 200, critical and killing (flags 0x05),
  76 HP after the respawn, 25900 exp lost (fixture numbers, no species' own):
  `07 00 00 00 00 00 00 00 2a 00 00 00 00 00 00 00 c8 00 00 00 05 4c 00 00 00 2c 65 00 00 00 00 00 00`.
- `OpMonsterSpawned`, monster 31 "Mob" / `MOB_TEST` (a fixture species) at (100, 0, -200), 100/100
  HP, level 1, rarity 0, heading pi/2 (f32 `0x3fc90fdb`, facing +z):
  `1f 00 00 00 00 00 00 00 03 00 4d 6f 62 08 00 4d 4f 42 5f 54 45 53 54 00 00 c8 42 00 00 00 00 00 00 48 c3 64 00 00 00 64 00 00 00 01 00 00 00 00 00 00 00 db 0f c9 3f`.
  `combat_test.gd` also rebuilds it from the list's own record builder plus the heading.
- `OpReviveResult`, revived at 80 HP and 40 MP (fixture numbers: 40 % of a 200/100 character):
  `00 00 50 00 00 00 28 00 00 00`; refused with "not dead": `08 00 6e 6f 74 20 64 65 61 64`.
  Pinned by `client/scripts/net/world_test.gd`, which also pins `OpRevive` as empty.

**The stop.** `dest == (x, z)` means stop at (x, z). The server sends it with the leg's own speed,
or the species' walk speed (characterdata col 46) when the monster was not moving, and the mode
unchanged. The client glides from where it draws the body to (x, z) at that speed -- or places it
there at once when that is more than `RESYNC_DISTANCE` away, or when the speed is 0 -- without
turning the body, and ends in the stand clip.

**How the client draws a leg** (`MonsterMotion`):

- The step is the engine's mover. `CGObjMoverByDest::FUN_0048bff0` (SR_GameServer.exe) returns the
  owner's unit direction (+0x24/+0x2c) times min(|speed(+0x174) x dt|, cap), with the cap the
  .rdata float at `0xb45ea8` = `0x43200000` = 160.0f. Its caller `CGObjMoverByDest::vslot_003`
  (`0x48c4e0`) computes dest - position with `FUN_00430ad0` (called at `0x48c5a9`; the body is
  `(dest + region offset) - pos` with y = 0), compares the two lengths (`fcompp` at `0x48c622`)
  and replaces the step with dest - position when the step is longer (`0x48c62b..0x48c63c`). So a
  body never overshoots. Both re-read on the RE box on 2026-09-24. The mover's zeroing of a
  component under 0.01f (`0xb45df8`) is not modelled.
- A leg starts from where the body is DRAWN, not from (x, z), unless the two are more than
  `RESYNC_DISTANCE` apart. A list refresh keeps a walking body where it is drawn on the same
  terms (`MonsterMotion.reconcile`); before round 533 every refresh put the body at the list's
  position, which teleports a walking body back by its lag.
- The clip is the model's own: type 1 walk (mode 0) or 7 run (mode 1) from its `default` group,
  and its idle once it arrives (`docs/protocol/BSR_FORMAT.md`). A model with no such clip keeps
  the loop it has.
- The body turns to face its destination by its MEASURED front (below). The height comes from the
  region's walkable graph -- `NavGraph.landing_height_at`, the path an NPC is placed by, through
  `World3D._moving_monster_height_at` since round 557; the terrain-only ray where no loaded region
  covers the body, and alone before that round -- every `HEIGHT_RESOLVE_STEP` units, at most
  `MAX_HEIGHT_RESOLVES_PER_FRAME` bodies a frame. A list refresh mid-leg resolves a walking body
  the same way.
- An `OpMonsterMoved` for a monster the client has no body for asks for the list, at most once
  every `UNKNOWN_MOVE_PULL_SECONDS`. A motion-list entry re-aims a body only when its destination
  differs from the one it is walking to by more than `REAIM_EPSILON`; a body the list leaves out
  finishes its leg.

**Stand-ins, each disclosed at its constant:**

- **The f32 speed is OpenSRO's own.** Retail `0x7021`/`0xB021` carry no speed
  (`docs/protocol/opcodes/movement.md`); the engine's mover reads it off the object (+0x174).
- **Mode 0/1 -> walk/run clip is an inference.** Grounded: `AITactics_Handler_110` (`0x5489b0`)
  picks 0 or 1, and the `0x704f` byte is `(mode == 1) + 2` (`0x54184d..0x541859`). Untraced: the
  mover's use of owner+0x155/+0x174. Unread: `GInterfaceSend::FUN_009d4a00` sends 2 when +0x25d is
  set, and what +0x25d means.
- **OpenSRO's own numbers:** `RESYNC_DISTANCE` 32 (it must exceed Earth Ghost's 75 u/s run over a
  0.3 s round trip, 22.5), `HEIGHT_RESOLVE_STEP` 2, `MAX_HEIGHT_RESOLVES_PER_FRAME` 32,
  `UNKNOWN_MOVE_PULL_SECONDS` 5, `REAIM_EPSILON` 0.5.
- **The height along a leg** was the terrain-only ray, not the navmesh, until round 557. It is now
  the region's walkable graph's landing height (`World3D._moving_monster_height_at`: the highest
  walkable surface, so a body under an overpass is drawn on top of it, as an NPC is), with the ray
  where no loaded region covers the body. Measured on the render box in `docs/WORLD_ISSUES.md`'s
  557th round, with the cost of a resolve and the QA-frame trap that hid the plaza in the first run.
- **The resync position** follows a lead, not a reading: the `0xB021` reader
  `NetProcessInNavAndSkill::FUN_008a5750` / `FUN_008a5640` (`message_handlers.tsv`,
  `client_read_layouts.tsv`).

### The server half (round 536): the encoders, the mover, the motion API and the pure rules

**Inert when built.** Nothing called any of it in round 536: `OpMonsterListResult` and its handler
were unchanged (the list's round-trip and flow tests are the control), `combat.Hub`'s motion API had
no caller outside tests, and `server/internal/ai` was still parked. Round 537's tick calls it, behind
`-monster-ai` ("OpenSRO's runtime", below). Every address below was re-read in
`/var/tmp/srv.asm` and `/var/tmp/decomp_server` on 2026-09-24.

**The wire.** `server/internal/session/monstermove.go` declares `OpMonsterMoved 0x007c` and
`OpMonsterMotionList 0x007f` with the `MonsterMoved` and `MonsterMotionList` encoders and decoders.
`monstermove_test.go` pins both encoders to the client's two fixtures above, byte for byte, and
refuses a 28-byte `MonsterMoved` as the client does.

**The mover** is two functions, and `combat.MoverStep` is both:

- `CGObjMoverByDest::FUN_0048bff0` builds the step: the owner's unit heading (`+0x24`/`+0x2c`)
  times `min(|speed(+0x174) x dt|, 160.0f)`, with the cap the float at `0xb45ea8` (`00 00 20 43`)
  and y = 0. It zeroes a component under 0.01f (`0xb45df8`), which is not modelled.
- Its caller `CGObjMoverByDest::vslot_003` (`0x48c4e0`) calls it at `0x48c547`, then takes
  dest - position with `FUN_00430ad0` at `0x48c5a9` (`(dest + region delta x 1920) - pos`, y = 0).
  It takes both lengths through `0x405250` (a float square root: `0x9fc1c0`, whose x87 path
  runs `fsqrt` at `0x9fc1fc`), leaving `st0` = |step| and `st1` = |dest - position|
  at `0x48c622` `fcompp`. `test ah,0x41; jne 0x48c63f` keeps the step when it is shorter or equal,
  and `0x48c62b..0x48c63c` copy dest - position over it when it is longer.

So a monster never walks past its destination. A step that reaches or passes it lands on it, and
`combat.Hub.StepAll` clears `Moving` there. `TestStepAllNeverOvershoots` is the negative case:
3 units short at 22 u/s over 0.2 s, the step with only its 160 cap ends 1.4 units beyond.
`MoverStep` takes the heading as the direction toward the destination, which is what the move's
start sets (`0x48c330` -> slot 10, `0x48c660`, `SetHeading` toward the destination).

**The hub's motion API** (`server/internal/combat/motion.go`). A spawn now carries its walk and
run speed, its home (the spawn point) and a leg: a destination, a speed, a mode and `Moving`.

- `SetMotion` starts a leg and returns the copy whose position is the push's origin.
- `StopMotion` puts the destination on the monster and keeps the speed and mode for the stop push.
- `StepAll(dt)` advances every moving monster under the hub's lock, the same lock `ApplyDamage`
  deletes a killed monster under, so a monster killed mid-leg is neither stepped nor brought back.
- `All` returns copies.

**The IDLE roll** is `CAIState_IDLE::OnMsg_0x25` (`0x559cf0`), IDLE's override of slot 41, the
handler for message `0x25`:

- the threshold is `ebx = 0x19` (`0x559d01`);
- it draws `r = |rand()| % 100 + 1` (`0x559da3..0x559dba`);
- `r < ebx` stays IDLE (`ChangeState(1)`: `edi = 0x64 - 0x63` at `0x559dc3`), and anything else
  goes to WANDER (`ChangeState(2)` at `0x559dd7`).

That is WANDER for 76 of the 100 values. Four owner conditions raise the threshold to `0x65`,
which means always IDLE:

- `IsMercenary` (slot 15) answers 1;
- the TypeID word (`FUN_00485c90`) has bit 1 set and fields 1, 2, 3, 8: `(w & 0x1c) == 4`,
  `(w & 0x60) == 0x40`, `(w & 0x780) == 0x180`, `(w & 0xf800) == 0x4000`;
- `IsAttackableCOS` (slot 16) answers non-zero and the owner's `+0x1cd8` record has `+0x1d18` set;
- slot 243 (`+0x3cc`) answers non-zero.

Every roster species is TypeID (1,2,1,1) (characterdata cols 9..12, read on the box): a plain
monster, the shape `Nest_Hatch` tests with `(w & 0x780) == 0x80`. So the threshold is 25, and the
four conditions are not modelled. `ai.IdleNext`, `ai.IdleStayThreshold`.

**The clip byte** comes from `AITactics_Handler_110` (`0x5489b0..0x548a20`), and `ai.MotionMode`
carries it:

- run (`+0x170`) `<= 1e-6` (`0xb45c84`) gives 0;
- else walk (`+0x16c`) `<= 1e-6` gives 1;
- else the current state decides: WANDER gives 0, FLEE gives 0, and every other state gives 1.

FLEE takes the HP-bucket branch (`AITactics_HPBucket` `0x541d70`). A bucket of 3 or more writes 0;
below 3 it writes nothing. The only caller, `FUN_00541820`, zeroes the byte before the call
(`mov byte [esp+0xa],0` at `0x541833`), so FLEE gives 0 either way. That caller then sends `0x704f`
with `(mode == 1) + 2` when the byte differs from the owner's `+0x155`.

**The strict comparisons.**

- `AITactics_IsWithinRoamRadius` (`0x545f70`): `fcomp` at `0x5460ae`, then `test ah,0x5; jnp`.
  A monster is within only while dist < radius, so one exactly on the radius has strayed. Rule 1
  multiplies the radius by 1.5 (`0xb45d78`), and any rule other than 0 or 1 is always within.
- `AITactics_HasArrived` (`0x541f60`): `fcomp DWORD 0xb45b28` (5.0f) at `0x541fb2`, then
  `test ah,0x5; jp`. Arrived only while dist < 5.0.
- The two measure differently. `IsWithinRoamRadius`'s difference (`FUN_00430ad0`) zeroes y, and
  `HasArrived`'s (`FUN_00430d40`) keeps it. OpenSRO's monsters carry no height of their own, so
  `ai.HasArrived` compares on the ground plane.
- `ai.WithinRoamRadius` and `ai.HasArrived` carry them.

**BATTLE draws no dwell.** `CAIState_BATTLE::OnEnter` (`0x559fb0`) calls only the base
`CAIState::OnEnter` (`0x558b70`: `+0x14 = 0`) and never `AIState_DwellMs`. The base `OnUpdate`
(`0x558b90`) expires a state only when `+0x14 != 0`, and strictly after it
(`timeout < now - enteredAt`). Slot 17 (`0x559310`) and `CAIState::ExtendDwell` (slot 18,
`0x559450`) also write `+0x14`, and BATTLE inherits both; their callers were not traced.
`ai.BattleDwellMs`, `ai.DwellExpired`.

**The rest of the pure rules.**

- **`ai.PickWanderLeg`** makes `PickWanderLeg`'s four `rand()` draws in the engine's order (sign,
  `% 40`, `% 91`, sign). It walks the round-535 bisector for 46..124 units and returns the leg's
  heading.
- **`ai.HomeDestination`** is `MoveHome` with the round-535 band. A monster standing on its home
  gets home.
- **`ai.SpawnHeading`** is `Nest_Hatch`'s `rand() / 32767 * 2pi`.
- C `rand()` is drawn as `rng.Intn(32768)`, and the sign idiom (`rand() & 0x80000001`, then
  `neg/sbb/and 2/add -1`) gives +1 for an odd draw.

**Not modelled, disclosed:**

- `PickWanderLeg`'s `ctx+0x14c` term (unread; for a nest monster it is not verified to be empty);
- the 30-unit blocked-probe reversal (OpenSRO's server holds no collision world);
- the four IDLE-roll owner conditions;
- `MoveHome`'s slot-243 exact-home case;
- the mover's 0.01f component zeroing.

Headings stay in OpenSRO's world frame; the tick that drives these rules carries that disclosure.

### Which way each roster model faces (round 533, measured)

`client/tools/probe_monster_front.gd`, run on the render box against its own archives, assembles
each roster species the way World3D does (by code, then by the display name the server sends) and
reads, in the space its skeleton is placed in, the mean toe-minus-foot bone vector and the
head-minus-pelvis offset, at the bind pose and at the walk clip's first frame. A reading names an
axis when its larger component is at least twice the smaller and at least 0.5 long; weaker
readings abstain. **The control** is the player's body, `CHAR_CH_MAN_FIGHTER`, whose front World3D
already turns by PI because it is local -Z: it reads -Z (feet at bind (0.00, -1.23)), so the probe
counts.

| model (the species drawn with it) | feet, bind | head, bind | feet, walk t=0 | head, walk t=0 | front |
|---|---|---|---|---|---|
| `mob\china\mangnyang.bsr` (Mangyang) | (0.00, -1.75) | (0.00, -2.93) | (0.42, -0.38) abstains | (-0.13, -2.14) | **-Z** |
| `mob\china\bigeyeghost.bsr` (Big-eyed Ghost) | (0.00, -1.51) | (0.00, -4.24) | (0.11, -0.50) | (0.04, -6.04) | **-Z** |
| `mob\china\gyo.bsr` (Weasel) | (0.00, -0.96) | (0.00, -8.15) | (0.11, -1.03) | (-0.71, -11.84) | **-Z** |
| `mob\china\waterghost.bsr` (Water Ghost) | (0.00, -0.46) abstains | (0.00, -3.33) | (0.10, 0.37) abstains | (0.12, -4.00) | **-Z** |
| `mob\china\stoneghost.bsr` (Stone Ghost) | (-0.04, -1.91) | (0.00, -10.00) | (-0.14, -1.65) | (0.50, -10.02) | **-Z** |
| `mob\china\yeoha.bsr` (Yeoha) | (0.00, -2.49) | (0.00, -8.81) | (0.23, -2.35) | (0.23, -9.03) | **-Z** |
| `mob\wchina\earthghost.bsr` (Earth Ghost) | (0.00, -1.28) | (0.00, -0.37) abstains | (0.07, -0.41) abstains | (0.21, -1.97) | **-Z** |

So a moving body is turned by `rotation.y = atan2(dir.x, dir.z) - PI` for a world-space path
`dir` -- the player's convention, whose skeleton carries the PI turn instead
(`MonsterMotion.facing_yaw`). The table is keyed by MODEL in `MonsterMotion.FRONT_BY_MODEL`; a
model not in it is left unturned and logged "facing unmeasured".

**Superseded in round 673: every drawn model turns.** The table left every species round 660 put on
the map unturned -- round 673's live chase beside Donwhang measured the Gun Powder ghosts
(`mob\wchina\gunpowderghost.bsr`, not in the table) facing one fixed way on all 14 legs, 2 to 179
degrees off their path, while the Earth Ghosts beside them kept within 0.5. The probe's census of
all 155 models the `MOB_` rows draw (`probe_monster_front.gd --all=1`): 117 read -Z, 36 name no
axis (no toe/head/pelvis bones, or readings that disagree), 2 read +Z on one weak reading (the event
Jinn pets: a head offset of 0.51 against the 0.5 floor), none +-X. So `MonsterMotion.MODEL_FRONT` is
-Z for every model (MEASURED for 117; INFERRED for the rest from the client turning every object by
one heading with no per-model front, FUN_009ec850). The capsule (no model) is still left unturned.

**The four `_CLON` species have no model.** `MOB_CH_BIGEYEGHOST_CLON` (Small-eyed Ghost),
`MOB_CH_GYO_CLON` (Old Weasel), `MOB_CH_WATERGHOST_CLON` (Water Ghost slave) and
`MOB_CH_TOMBSTONE_CLON` (Tomb Stone Ghost) carry `xxx` in every model column of their
characterdata rows (read on the box's `characterdata_5000.txt`: cols 52-56, counted from 0 as
col 50 BCRadius is), and their display
names resolve to no row that has one. World3D draws them as the labelled capsule, which has no
front. How the retail client draws a `_CLON` row is not established.

### The strike and spawn pushes (round 540: the client half)

Two more of OpenSRO's own placeholders, in the table above. Round 540 built the client half.
**Round 541 built the strike push's server half** ("The strike push's server half (round 541)",
below), behind `-monster-strike-push`, which is off by default. **Round 542 built the spawn push's
server half** ("The spawn push's server half (round 542)", below), behind `-monster-spawn-push`,
also off by default. Each push has its own default-off flag, flipped only once a client that draws
it has been released. Client: `CombatNet.decode_monster_attacked` /
`decode_monster_spawned`, `NetClient`'s `monster_attacked` / `monster_spawned` signals,
`scripts/world/monster_strikes.gd` (`MonsterStrikes`), and `World3D._on_monster_attacked` /
`_on_monster_spawned`.

**What the strike push carries.** A counterattack is resolved in `performAttack`
(`server/internal/session/combat.go`, the branch after `combat.Hub.CounterattackReady`; rounds 254
and 505; since round 541 that branch calls `monsterStrike`, its old body moved unchanged). Without
the push it reaches only the attacker, in that attack's `OpAttackResult`. The push
repeats the same outcome to everyone in the zone: `PlayerDamageTaken` as the damage,
`MonsterCritical`, `PlayerBlocked` and `PlayerDied` as the flags, `PlayerHP` as the target HP and
`DeathExpLost`. So a push adds no new number. A counter that lands deals at least 1
(`combat.ResolveBlow` floors the blow at 1 in `MitigateDamage` and `ApplyLevelAdvantage`, and
`ApplyFloorBand` never takes it below 1). So a result reports a counter exactly when its damage is
above 0 or its block flag is set (`MonsterStrikes.result_countered`).

**The order the client relies on.** The server sends the attacker's result first, then the push to
the zone with the attacker included, both from the goroutine that ran `performAttack`. (Round
541's server sends the zone's `OpMonsterDamaged` between the two, but that goes to everyone except
the attacker, so the attacker still gets the push right after its result.) The
attacker's client draws the counter when its own blow lands (`lands_after`, the swing's hit
event), which is when the pre-540 client drew it too:

- A result that reports a counter starts a **wait** (`MonsterStrikes.expect`), which holds the
  counter's numbers.
- A push that repeats those numbers for that monster (`MonsterStrikes.repeats`: damage, target
  HP, critical, block, death) **claims** the oldest unclaimed wait (`MonsterStrikes.claim`).
  Nothing is drawn when the push arrives.
- When the blow lands (`World3D._settle_counter`), a claimed wait is drawn **from the push**. An
  unclaimed one is drawn **from the result**, as before round 540, and stays marked drawn. A push
  that comes after that is swallowed, not drawn again.
- So a counter is drawn once against a server that sends the push, and once against one that
  does not. `monster_strikes_test.gd` runs all three orders.
- A new counter on the same monster drops the waits the result already drew. Their pushes would
  have followed their own results, at least one attack earlier.
- A monster that dies, leaves the list or is left behind by a zone change takes its waits with
  it.

**The client is not told its own character id when it enters the world.** `OpEnterWorldResult`
(`server/internal/session/world.go`) carries a zone, a position, a gender, vitals and the others in
the zone, but no id, and giving it one would change a layout. A party reply does carry one per
member (`PartyResult` / `PartyMemberSnapshot.CharacterID`, `server/internal/session/party.go`,
which `PartyNet` decodes), so the id can be learned by name once such a reply has arrived -- but
only then, and a character outside a party never gets one (`OpPartyInfo` answers it an empty
roster). Round 540 wrote "the client has no way to know its own id", which overstated it
(corrected in round 544); pairing was chosen so a blow is recognised from the first swing, party or
no party. So a push is taken as a blow on this
player only when it claims a wait: it repeats a counter this client's own result reported, and its
target is none of the other players the client has drawn (`World3D._other_bodies`). Every blow a
server could push until round 546 is such a counter. A monster striking on its own (round 546, below) sends none, and the client takes such a push as its own by elimination (`MonsterStrikes.is_own_unpaired`); round 540 wrote here that it would need the id from
the start, which `docs/TODO.md` now files as the follow-up that would make the pairing exact.

**How a blow is drawn** (`World3D._draw_monster_strike`):

- The monster is turned toward its target by its measured front (`MonsterMotion.facing_yaw`, the
  table above), and plays its attack clip (type 2, `TYPE_ATTACK`). A body walking a leg is not
  turned (round 544): the leg faced it at its start and nothing re-faces it mid-leg, so a turn
  would have it walk sideways to its stop.
- At that clip's first hit event (`EVENT_HIT`: `mangnyang_attack01` at 651), the target plays its
  hit clip (type 3) and the red number rises over it.
  - The target is the player's own body, or another player's body in `_other_bodies`, played with
    that body's own gender and weapon group.
  - The event's millisecond unit is **inferred** from the key times, not read from the client's use
    of them (`docs/protocol/BSR_FORMAT.md`, "Events and walk points").
- A blocked blow is the swing alone, because it dealt nothing.
- A blow on a target this client has not drawn is the swing alone, unturned.
- For a blow on this player whose push claimed a wait still open (`CLAIM_HELD`), the HUD's HP is
  set from the target HP, and a killing blow shows the death line on the combat status label. The
  result has already set both from the same numbers, so this changes nothing when the server
  sends both messages. A late push (`CLAIM_DRAWN`) sets neither: its counter was drawn from the
  result, and a newer result -- a kill's level-up heal, the next counter -- may have moved the HP
  since; until round 544 it repainted that stale HP until the next result.
- Another player's body now changes its stand/run loop through `MonsterMotion.swap_loop`, so a
  gait change during that hit clip does not leave two animation entries on one skeleton.

**The spawn push** makes the body the way a listed one is made (`_spawn_or_update_monster`). It
then faces the body along the heading, when the body is standing and its model's front was
measured. `MonsterMotion.heading_dir` is (cos h, sin h) on (x, z). That is OpenSRO's heading frame
(`server/internal/ai/wander.go`), and it is the unit heading the engine's SetHeading writes to
+0x24/+0x28/+0x2c as (cos a, 0, sin a): `GObjPC::FUN_00482440` (IGObj slot 230; the CGObjMobile
override `0x0048ba10` writes the same three), through `FUN_00489490` -> `0x009fc0b0` (the CRT's
cos; its x87 path runs `fcos` at `0x9fc11d`) and `FUN_004894b0` -> `0x009fbf80` (sin, `fsin` at
`0x9fbfed`). All of these were re-read on the RE box in round 540. The line
`World3D: monster %d spawned (push)` is printed for each push.

**Log lines for the live checks** (the server item's check, measured in round 543; see "The strike
push's server half (round 541)"):

- Every push prints `World3D: monster %d strikes %d for %d (HP %d)`, followed by the flags and how
  it was taken: `own counter, drawn as the blow lands`, `own counter, already drawn from the
  result`, `on another player` or `target not drawn here`.
- Every counter a result drew because no push had come prints `World3D: monster %d counter from
  the result (no push)`.
- With the push on, the attacker's `strikes` lines should equal its counter results, **blocked ones
  included** (damage 0, bit 1), and there should be no `counter from the result` lines. With the
  push off, it is the reverse.

**Measured live (round 540, 2026-09-24, render box, hardware GL).** The server was built from the
tree at `e17cda3`, which sends no push. Both runs used `OPENSRO_QA_ATTACK_FAST=1
OPENSRO_QA_ATTACK_NAME=Mangyang OPENSRO_QA_ATTACK_GOTO=1 qa_shot.sh --server --attack --frames
600`.

- **Run A, as it is (no push).** There were 38 counter results (took > 0; none blocked, since the
  QA player carries no shield). The log has 37 `counter from the result (no push)` lines, for the
  first 37 counters in order, and no `strikes` line. The 38th counter's result came at t=9.63, and
  its blow was due about 0.2 s of game time later; the run's last result came at t=9.73, and the
  run ended before the blow was due.
- **Run B, with `OPENSRO_QA_MOB_STRIKE=1`.** There were 44 counter results and 44 stand-in
  pushes. The log has 44 `strikes` lines, all `own counter, drawn as the blow lands`, matching the
  results monster for monster and number for number. It has no `counter from the result` line,
  and 43 red numbers rose over the player. The 44th counter's result came at t=9.65, too late
  for its blow to land before the run ended.
- Neither run printed a SCRIPT ERROR. The frames were deleted.
- Not seen live: a blocked counter, and another player's body. The headless tests cover both.

**Stand-ins:**

- Both layouts are OpenSRO's own.
- The pairing test (the numbers repeat, and the target is not another drawn player) stands in for
  the character id the client is not told when it enters the world.
- The target's number is drawn over its head at the height the player's own number uses.
- `OPENSRO_QA_MOB_STRIKE=1` stands in for a server with the push. It sends each counter result's
  push through `NetClient._dispatch`, deferred to the end of the frame, with -1 for the target.

### The strike push's server half (round 541)

`server/internal/session/monsterstrike.go` sends `OpMonsterAttacked`. It is sent only when
`cmd/server` runs with **`-monster-strike-push`** (env `OPENSRO_MONSTER_STRIKE_PUSH`, read like
`OPENSRO_MONSTER_AI`: a value that does not parse leaves it off with a WARN), which is **off by
default**. With it off nothing is sent, and the wire is what it was before round 541. It does not
depend on `-monster-ai`. The boot log says which: `monster strike push on: ...` or
`monster strike push off (-monster-strike-push / OPENSRO_MONSTER_STRIKE_PUSH)`.

- **The counter did not change.** `performAttack`'s counter branch moved unchanged into
  `monsterStrike`. The function returns the outcome (damage, critical, blocked, died, HP, death exp
  lost) instead of writing it into the result. `performAttack` copies the outcome into
  `OpAttackResult` field for field, so the result is the same as before.
- **The push** is built from that same outcome (`monsterStrikeOutcome.message`), with the
  attacker's character id as the target. `pushMonsterStrike` sends it to the attacker's session and
  to the sessions the swing's `OpMonsterDamaged` just went to: the one zone snapshot `performAttack`
  took for the swing (round 544; round 541 took a second snapshot for the push, so a session
  entering or leaving the zone between the two could get one message without the other).
- **The order.** `performAttack` sends the push last. It comes after the attacker's
  `OpAttackResult`, and after the zone's `OpMonsterDamaged` for the same swing, which goes to
  everyone except the attacker. It is sent from the goroutine that ran the swing: a session reader
  for a click or a cast, the keep-up goroutine for a repeat. So the attacker gets the push right
  after its result, and the other players get the swing's damage before the monster's reply.
- **When nothing is sent.** A kill has no counter, and neither does a blow inside the monster's
  ReuseDelay, so neither sends a push.
- **No motion wire lock.** `monsterAI.wireLock` makes sure a monster list reaches a client before
  any motion push that is newer than it. The strike push carries no position, so it does not take
  that lock. `gateway.Session.Send` is already safe to call from several goroutines.
- **The fixture** above is pinned on both sides: by `TestMonsterAttackedMatchesTheClientFixture`
  in Go, and by `combat_test.gd` in the client.

**Tests** (`server/internal/session/monsterstrike_test.go`, over TCP, in-memory stores; Aria and
Bram in jangan, Cyra moved to donwhang):

- `TestMonsterCounterReachesTheZone`. **This is the red.** With the flag on, Aria hits a Mangyang
  whose counter is ready. Bram, in the same zone, receives exactly one `OpMonsterAttacked`, after
  that swing's `OpMonsterDamaged`. Aria receives exactly one, as the very next packet after her
  result. Both are equal to the counter her result reports. With only the push call removed from
  `performAttack`, Bram receives nothing and the test fails. Two controls pass before and after: Cyra, in donwhang, receives
  none, and a second blow inside the Mangyang's 3000 ms ReuseDelay draws no counter and sends
  nothing to anyone.
- `TestMonsterStrikePushCarriesTheFlags`. A killing critical on Aria (level 11) reaches Bram with
  flags 0x05, her respawn HP and the 25900 experience it cost her, as her result reports them.
  Bram's shield, which always blocks, blocks a counter, and Aria receives that push with bit 1 set
  and 0 damage, on Bram.
- `TestMonsterStrikePushOffIsTheOldWire`. This is the default-off control. Aria gets her result
  and nothing after it. Bram gets only `OpMonsterDamaged`, and Cyra gets nothing.
- The six counter-driven tests in `combat_test.go` read through `readReply`, which skips
  0x007C..0x007F, and their numbers are unchanged. Without `readReply`, `TestCombatFullFlow` and
  `TestCombatArmorMitigation` fail with the push on, because their second attack reads the first
  counter's push as its result. Since round 544 they, and the three other counter-driven tests
  (`TestHwanIsEarnedOnTheKillingBlow`, `TestAttackResultNeverReportsZeroHealthForALivingPlayer`,
  `TestSkillFullFlow`, whose readers took one packet per request until then), run at the top
  level with the flag at its default, off, and again with it on under
  `TestCounterTestsHoldWithTheStrikePushOn`.
- `TestStrikePushRecipientsAreTheDamagedRecipientsPlusTheAttacker` (round 544): called with the
  zone's server-side sessions, the push reaches the attacker and the swing's `others` exactly once
  each and nobody else, and nothing with the flag off.

**The live check** (run in round 543, below; round 541's session was not allowed to write to the
render box). Use a server built from the tree, with the flag on in qa_shot's environment. qa_shot
passes its environment to the server it starts:
`OPENSRO_MONSTER_STRIKE_PUSH=1 OPENSRO_QA_ATTACK_FAST=1 OPENSRO_QA_ATTACK_NAME=Mangyang
OPENSRO_QA_ATTACK_GOTO=1 qa_shot.sh --server --attack --frames 600`, with
`SERVER_BIN=<that build>`. Expect:

- one `World3D: monster %d strikes %d for %d (HP %d)` line for **every** counter result, blocked
  ones included;
- no `counter from the result (no push)` line;
- no SCRIPT ERROR;
- and the server log saying `monster strike push on`.

**Measured (round 543, 2026-09-24): passed.** Server built from `97b4a94` (round 541), client at
`cea193a` (round 542), the command above with `SERVER_BIN=/var/tmp/mobai/srrevamp-server-541`,
600 frames. The server log says `monster strike push on`. The client log has 138 `attack hit`
lines, of which 45 report a counter (`took N` with N > 0; no blocked counter occurred in the run),
and exactly 45 `World3D: monster %d strikes %d for %d (HP %d)` lines, whose damage sequence equals
the counters' `took` sequence in order (13, 13, 12, 12, ...). There is no `counter from the result
(no push)` line and no `SCRIPT ERROR`. Not exercised by this run: a blocked counter (the QA
character carries no shield), and an observer's screen (one client). The frames were deleted from
`/var/tmp`; the logs were kept off the box.

**Stand-ins:** none new. Every number is the counter's own, and the layout is OpenSRO's own and
additive.

### The spawn push's server half (round 542)

`session.BroadcastMonsterSpawned` (`server/internal/session/combat.go`) sends `OpMonsterSpawned`. It
sends only when `cmd/server` runs with **`-monster-spawn-push`** (env `OPENSRO_MONSTER_SPAWN_PUSH`,
read like `OPENSRO_MONSTER_AI`: a value that does not parse leaves it off with a WARN), which is
**off by default**. With it off nothing is sent, and the wire is what it was before round 542. It
does not depend on `-monster-ai` or `-monster-strike-push`. The boot log says which:
`monster spawn push on: ...` or `monster spawn push off (-monster-spawn-push / OPENSRO_MONSTER_SPAWN_PUSH)`.

- **Who sends it.** `cmd/server`'s `maintainMonster` hands its first spawn and every respawn to a
  `spawned` callback, and `main` passes `BroadcastMonsterSpawned`. The GM console sends one for each
  monster a `/spawn` makes (`gm.Result.SpawnedMonsterIDs`, `session/gm.go`), to the whole zone, the
  GM included, right after the GM's own reply. Until this round a GM `/spawn` reached the other
  players only on their next monster list (`docs/TODO.md`, the tester tools' item (3)).
- **The record** is the list's own. `BroadcastMonsterSpawned` reads the monster through
  `combat.Hub.Get` when it sends, not off the live record `SpawnSpecies` returned, whose position
  and HP change under the hub's lock. It encodes it with `monsterSnapshotOf`, the function
  `handleMonsterList` now uses for every list record. A monster that is already gone sends nothing.
- **The heading is rolled at the spawn.** `combat.Hub.SpawnSpecies` draws `Monster.Heading` from the
  hub's roll (`SetSpawnHeadingRoll`), under the hub's lock, and it never changes after that. Before
  the first spawn, `cmd/server` installs `ai.SpawnHeading` over an rng of its own. That is
  `Nest_Hatch`'s heading for every species of the roster's TypeID shape whose rarity is not 3
  (`0x5609ee..0x560a15`, re-read on the RE box in round 542):
  - `call 0x9dd338` (the CRT's `rand()`);
  - `fdiv` by the double at `0xb45af8`, `0x40dfffc000000000` = 32767.0, then a round to a float;
  - `fmul` by the double at `0xb45c18`, `0x401921fb60000000` = 6.2831854820251465, which is 2pi
    rounded to a float and widened back;
  - `fadd` of the double at `0xb45ab0`, 0.0;
  - `fstp` to a float at `0x560a15`.

  So the heading lies in [0, 2pi], and it is 2pi itself when `rand()` returns 32767.
- **The brain adopts it.** The monster AI's `newBrain` starts from `Monster.Heading` instead of
  drawing `ai.SpawnHeading` from its own rng, so the pushed heading and the brain's first heading are
  the same number. The brain's rng draws one value fewer per monster, which changes the sequences the
  seeded AI tests replay; they all still pass.
- **The frame** is OpenSRO's world frame, radians from +x toward +z (`internal/ai/wander.go`), never
  an engine angle. The client faces the body along (cos h, sin h) (`MonsterMotion.heading_dir`, "The
  strike and spawn pushes" above).
- **The pattern** is the ground-item spawn push (`OpGroundItemSpawned 0x006c`,
  `docs/protocol/ground_items.md`): one packet to every session in the zone, and a failed write is
  left to that session's own reader.
- **No motion wire lock.** `monsterAI.wireLock` makes sure a list reaches a client before any leg
  that is newer than it. A respawn's push goes out from the goroutine that spawned it, and its
  brain's first leg waits out at least one IDLE dwell (`ai.DwellMs`, 2001 ms or more). A push that
  did arrive after a leg would find the body walking. The client leaves a walking body where it is
  drawn (unless it is past `RESYNC_DISTANCE`) and does not turn it (`World3D._on_monster_spawned`).

**Tests** (over TCP, in-memory stores; Aria and Bram in jangan, Cyra moved to donwhang, the strike
push's zone):

- `TestMonsterSpawnedMatchesTheClientFixture`: the encoder gives the client's 55-byte fixture above,
  and its record is byte for byte an `OpMonsterListResult` record. It round-trips, and 54 or 40
  bytes are refused. `TestMonsterSpawnedOpcode`: 0x007E collides with no other session opcode.
- `TestMonsterRespawnReachesTheZone`. **This is the red.** With the flag on, a Mangyang spawned in
  jangan and handed to `BroadcastMonsterSpawned`, the way `maintainMonster` hands every spawn,
  reaches Bram and Aria before their next list: exactly one push each, with the new id, the list's
  own record for it and the heading the hub's Nest_Hatch roll drew, in [0, 2pi]. With only the send
  removed, Bram receives 0 and the test fails. Two controls pass before and after: Cyra, in
  donwhang, receives none, and a monster killed before its push is due sends nothing to anyone.
- `TestGMSpawnReachesTheZone` (`session/gm_test.go`), **the GM red**. Aria, a GM, runs
  `/spawn Mangyang 3`. Her reply comes first, then three pushes in spawn order, each with its hatch
  heading and an id the reply names. Bram receives the same three. With only the GM handler's
  broadcast loop removed, the test fails ("Aria ... received 0 OpMonsterSpawned, want 3"). The
  control: Cyra receives none.
- `TestMonsterSpawnPushOffIsTheOldWire`, the default-off control: nobody receives anything.
- `TestMonsterAIBrainStartsFromTheSpawnHeading`: a hub whose roll answers 1.25 gives a brain that
  faces 1.25 after its first tick. With `newBrain` drawing its own again, it faced 4.87 and the test
  failed.
- `TestSpawnSpeciesRollsTheHatchHeading` (`internal/combat`): one roll per spawn, kept by `Get`'s
  copy; a hub with no roll hatches at 0. `TestSpawnAndKill` (`internal/gm`): `SpawnedMonsterIDs`
  names the monsters a `/spawn` made, in order, and a refused `/spawn` names none.
- `TestMaintainMonsterReportsEverySpawn` (`cmd/server`): `maintainMonster` reports its first spawn,
  and after that monster's death the respawn, with ids the hub holds. It waits out the 10 s
  `respawnDelay`, so it runs for about 12 s.

**The live check has not been run yet.** This session was not allowed to write to the render box.
Run it before the flag is turned on for the public server, with a server built from the tree and
the flag on in qa_shot's environment:
`OPENSRO_MONSTER_SPAWN_PUSH=1 OPENSRO_QA_ATTACK_FAST=1 OPENSRO_QA_ATTACK_NAME=Mangyang
OPENSRO_QA_ATTACK_GOTO=1 qa_shot.sh --server --attack --frames 600`, with `SERVER_BIN=<that build>`.
The client runs about 20x slower than the server (the time dilation under "The live checks",
below), so a kill early in the run leaves time for its 10 s respawn. Expect:

- the server log saying `monster spawn push on`;
- for each jangan respawn after the client connected (a `monster spawned` server line), one client
  line `World3D: monster <id> spawned (push) ...` for that id. A respawn takes a fresh id from the
  hub's counter (`nextID`), so no list before its spawn can have carried it; the line carries
  `(already drawn)` only when a list reply built after the spawn reached the client before the push
  did (the two go out on different goroutines with no wire lock between them), and that is no
  failure: the body is drawn once either way. What is guaranteed is one push per respawn, with its
  new id. (Round 544 corrected round 542's reasoning here, which expected no `(already drawn)`
  because "the kill had removed that id from the last list".)
- no SCRIPT ERROR.

**Stand-ins:**

- The layout is OpenSRO's own and additive.
- `respawnDelay` stays 10 s, under its existing disclosure (`cmd/server/main.go`; "The `_RefNest`
  row", above).
- A rarity-3 species of the roster's TypeID shape, and a species of any other shape, would face its
  nest row's own direction (row 8, `wInitialDir`), which is in the server database only. Every
  roster species is that shape and none is rarity 3 (`ai.SpawnHeading`), so every monster takes
  the random heading. (Round 547 corrected this line, which named only rarity 3.)
- The push is zone-wide, with no interest management, like every push here.
- A client that stops reading its socket stalls the goroutine that sends to it, because
  `gateway.Session.Send` has no write deadline: that species' `maintainMonster`, or the GM's
  reader. The ground-item pushes, regen and the AI tick already stall the same way. The kill switch
  is the mitigation.

## OpenSRO's runtime: the monster AI tick (round 537)

`server/internal/session/monsterai.go` runs the machine above over the live monsters. It runs only
when `cmd/server` is started with **`-monster-ai`** (env `OPENSRO_MONSTER_AI`, parsed with
`strconv.ParseBool`; anything unparsable is off, with a WARN). **The default is off**, and off is
the kill switch: `RunMonsterAI` is never called, the runtime pointer stays nil, `noteStruck` does
nothing and `OpMonsterList` is answered with the one list result it always was, byte for byte. The
boot log says which: `monster AI off (-monster-ai / OPENSRO_MONSTER_AI)` or
`monster AI on: tick 100ms (own design), roam radius 200 (own design)`. How an operator flips it is
in `deploy/README.md`, "Monster AI (off by default)".

**One tick, in this order:**

1. `combat.Hub.StepAll(dt)`, `dt` being the wall time since the last tick: the engine's mover with
   both clamps (round 536).
2. A brain per live monster, in monster-id order. A new one starts in SPAWN facing the heading its
   monster hatched with (`combat.Monster.Heading`: `Nest_Hatch`'s random heading, `ai.SpawnHeading`,
   rolled by the hub at the spawn since round 542, so the spawn push and the brain carry the same
   one) and takes message `0x21`'s default, IDLE, at once. A brain whose monster is gone is
   dropped.
3. The blows since the last tick (below).
4. Each brain's `OnUpdate`, once.
5. The pushes the pass collected, sent after it and outside every lock.

**The states it runs.** Each is `ai.Machine.ChangeState`, so a refused entry falls back to IDLE
(`0x53ff30`), and each entry sets `enteredAt` and a zero timeout first (`CAIState::OnEnter`,
`0x558b70`).

| state | on entry | on each tick |
|---|---|---|
| IDLE | dwell `ai.DwellMs` (`0x545b70`: 4000 +- rand % 2000, sign first); target cleared; for a monster whose run speed is above 0, the roam check, and `0x26` -> HOMING when it has strayed (`0x559c80`). **No stop:** a leg under way goes on. | at the dwell's end, IDLE's own `0x25` handler rolls another IDLE or WANDER (`0x559cf0`, `ai.IdleNext`: WANDER for 76 of 100) |
| WANDER | refused when the run speed is not above 0; target cleared; `ai.PickWanderLeg`; dwell 5000..5999 ms, or 1000 ms with no leg; the leg starts in the clip `ai.MotionMode` picks (`0x559df0`) | the dwell's end -> `0x25` -> IDLE, **the leg not stopped**; else, with a run speed, the roam check -> `0x26` -> HOMING (`0x559eb0`) |
| HOMING | dwell 50 000 ms (the default arm); `ai.HomeDestination` (`MoveHome` `0x545c50`, R/3 .. R/3 + trunc(R/3) toward the monster); the leg in `MotionMode`'s clip, 1 for HOMING; target cleared (`0x55a540`) | the dwell's end -> `0x25` -> IDLE; `ai.HasArrived` (under 5.0) -> `0x24` -> IDLE (`0x55a690`, `AITactics_HomingStep` `0x5496c0`) |
| BATTLE | no timeout: `BATTLE::OnEnter` (`0x559fb0`) calls only the base `OnEnter` and never `AIState_DwellMs`, and the base `OnUpdate` (`0x558b90`) expires only a non-zero one, so a fight never times out | on every tick that drained no blow on it (its entry drains one): the target must be in the world and in the zone, else `0x23` -> IDLE; and the interim release (below) |

**A blow.** `performAttack` calls `noteStruck` right after the damage lands, for a monster that
survives it: a click, a keep-up repeat and a cast all come through there. The tick drains the
blows and, for a monster not already in BATTLE, does what `CAIState::OnAttacked` (`0x558ea0`) does:
`SetTarget(1)` (`0x53ffe0`: `push 1` at `0x558eed`, the call at `0x558eef`), then `ChangeState(3)` (`lea edi,[ebx+3]` at `0x558f01`)
-- no aggression test and no range test. Trace lines, with `OPENSRO_AI_TRACE` set:
`ai: monster %d %s->%s`, `ai: monster %d leg to (%.0f,%.0f) speed %.0f mode %d`,
`ai: monster %d struck by %d, holding`, `ai: monster %d released (%s)`, and from the keep-up,
`ai: keep-up of %d on monster %d ended out of reach`.

**The wire.** Every leg, and every stop, is an `OpMonsterMoved` pushed to every session in the
monster's zone. With the runtime on, `handleMonsterList` sends its unchanged `OpMonsterListResult`
and then ONE `OpMonsterMotionList` with the legs of the listed monsters still walking (n may be 0).
Both replies are built and written under the requesting session's **wire lock**, the same lock the
tick takes to push to that session. Without it a push for a newer leg could reach the client ahead
of a list built before that leg began: the client would take the list's older destination last,
re-aim (it differs by more than `REAIM_EPSILON`) and walk the body there until the monster's next
leg. The lock is per session, so a stalled client holds up only its own replies and the tick.

**The stand-ins, each marked OWN DESIGN at its line in `monsterai.go`:**

- **The flag** is off by default.
- **The tick period, 100 ms.** The engine's AI period is unread. The one period read on this path
  is `CGObjChar::Update`'s 30 ms floor for an actor. A dwell ends within one tick of its time.
- **SPAWN leaves on the first tick.** `SPAWN::OnUpdate`'s timing is unread.
- **The roam radius, 200, for every placement, rule 0.** This is a user decision. It is the number
  `AI::CTactics::Attach` stores for a nestless monster (`0xb45d68`), but in that case `0x545f70`
  answers "within" without measuring, so retail never applies it (the correction in "What this
  gives OpenSRO", above). The real radius is the nest row's column 9 (`+0x20`), which is
  server-database only. OpenSRO treats each placement as a nest.
- **No blocked probe.** A leg can cross walls and objects: `PickWanderLeg`'s 30-unit probe needs a
  collision world the server does not hold (mob-server-geometry-probe).
- **Not modelled:**
  - `PickWanderLeg`'s `ctx+0x14c` leader term;
  - the four IDLE-roll owner conditions;
  - WANDER's COS-not-mercenary refusal (no roster species is a COS);
  - HOMING's timer and `+0x164` sign (its re-aggro window is modelled since round 552, behind
    `-monster-aggro`);
  - BATTLE's timers, clip and gathering; of its `OnLeave` override (`ResetThreat`) only the
    selector's `+0x44` clear is modelled (`leaveBattle`, round 555), not the threat seats;
  - the acquire behaviour every `OnUpdate` calls -- modelled since round 552, behind
    `-monster-aggro` ("Target acquisition: the runtime (round 552)", below); with that flag off it
    is still not run.
- **Headings stay in OpenSRO's world frame.** The engine's frame differs by the z mirror. That
  changes no distribution: the hatch heading is uniform and the turns are symmetric.
- **HOMING walks one straight leg.** `AITactics_HomingStep`'s heading wobble is deferred
  (mob-homing-wobble), and its arrival is tested every tick.
- **Mode 0 is the walk speed and mode 1 the run speed.** This is inferred (round 363's note above);
  the 0/1 selection itself is read.
- **The interim hold** (with `-monster-battle` OFF, the default; on, round 546's chase and the engine's exits replace all of it -- "BATTLE's chase and the monster's own swing (round 546)", below):
  - **The stop at the blow.** `noteStruck` stops a walking monster in the hub at the blow, and the
    next tick pushes the one stop. The engine's `BATTLE::OnEnter` issues no stop: its chase replaces
    the leg. The stop is at the blow, not at the tick, because the tick steps the mover before it
    drains the blows. Stopped only at the tick, a monster would first walk up to 0.1 s x its speed
    (0.8 units for a Mangyang, 2.2 while HOMING at 22), which carries one struck at the edge of the
    band out of reach. The keep-up's next repeat would then end the run (keepup.go), and the
    release would let the monster walk off after one hit. `BATTLE::OnEnter` also stops a monster
    still on a leg, which the blow's stop leaves as a no-op.
  - **The release.** The monster stays in BATTLE while any player in its zone has a keep-up on it
    (`keepUp.Target` for each player `world.Hub` puts in the zone -- gathered once per tick into a
    monster-and-zone set on the first release test, round 544), and goes to IDLE only once
    `MonsterHoldReleaseTicks` (2) ticks in a row have found none, with no blow drained in between.
    *Changed in round 539* (round 537's review). Round 537 looked only at the first attacker's
    keep-up and released on the first tick that found it gone. That lost a monster two ways:
    - **The gaps.** An OpAttack notes its blow inside `performAttack` but arms the keep-up only
      after `performAttack` returns, past the weapon wear, the counterattack and the reply. A cast
      cancels the keep-up before its blow and re-arms it only at the hand-off. A tick in either gap
      released the monster, and IDLE's roam check sent one strayed past the radius home at its run
      speed until the next blow. Now an OpAttack's gap must outlast two tick periods from the blow,
      and a cast's must outlast one period from its Cancel to its blow (the drained blow restarts
      the count) or two from its blow to the re-arm.
    - **Two players.** When the first attacker's keep-up ended, the monster was released although
      a second player's was still on it.

    A keep-up whose attacker is in another zone does not hold the monster; that keep-up ends at
    its next swing anyway (`armKeepUp`'s zone test). What the release still means, disclosed:
    - a cast cancels the keep-up (`useSkillHandler`), and only a hand-off skill
      (`AutoAttackType` 1, no chain) arms it again, so a monster hit only by other casts idles and
      wanders between them;
    - a deployment with no base-attack row (no skill reference data) never arms a keep-up, so the
      hold ends two ticks after the blow's: the tick that drains the blow enters BATTLE and skips
      the release test, and `MonsterHoldReleaseTicks` (2) ticks in a row must then find no keep-up
      (round 544 corrected round 539's "the hold lasts one tick");
    - a keep-up that ends out of reach releases the monster, and the trace line names it.
  - **A blow on a monster already in BATTLE is ignored**, except that it restarts the release
    count. This is the rule-0 stand-in for `BATTLE::OnAttacked` (`0x55a2e0` -> behaviour `+0xfc`):
    the first attacker is kept as the target. So when that player leaves the zone or the world,
    the monster goes by the `0x23` exit even while a second player's keep-up is on it. The second
    player's next blow holds it again; in between, IDLE's roam check sends a monster strayed past
    the radius home. The engine's retarget is the threat table's (mob-threat-retarget).
  - **A drift the stop at the blow leaves open.** The OpAttack handler measures the reach
    (`firstSwingInReach`) without the runtime's lock, and `noteStruck` stops the monster only after
    `performAttack`'s `ApplyDamage`. A tick whose `StepAll` lands between the two still moves the
    monster up to 0.1 s x its speed before the stop, so one struck at the very edge of the band can
    still leave it. The window is the handler's own work between the two calls, not a tick.
    Closing it would mean stopping the monster at the reach test, before the swing is known to be
    ready or to land, so monsters would stop for clicks that deal nothing. Disclosed, not closed
    (round 539).
- **Not modelled on a blow:** the attacker accounting's refusals (`CreditAttacker`, behaviour
  `+0xec`). The aggro link (behaviour `+0xf0`) is modelled since round 553 with `-monster-battle` on
  ("The aggro link: the runtime (round 553)", below); with that flag off it is still not run.
- **Target validity is OpenSRO's own:** "in `world.Hub`, same zone". The engine's is
  `AITactics_ValidTargetOrNull` / `AITactics_IsValidTarget` (`0x540dc0` / `0x540de0`: alive, life
  state 1, the body-mode refusals; named in round 545), and its exit is `0x23` (round 545 settled
  the branch).
- **The synchronous counterattack is unchanged with `-monster-battle` off.** A monster then strikes only when struck. With the flag on it swings on its own (round 546) and `performAttack` makes no counter.
- **Zone-wide pushes, no interest management.** About 33 leg pushes a second per Jangan session at
  about 350 monsters. That is an ESTIMATE from the read dwell and roll numbers, not a measurement:
  an IDLE spell averages 4.0 s and is followed by a leg 76 times in 100, whose WANDER spell averages
  5.5 s, so a monster starts 0.76 legs per 4.0 + 0.76 x 5.5 = 8.2 s, about 0.093 a second. (One
  seeded Mangyang in `TestMonsterAIWandersAtWalkSpeedInsideTheRoamRadius` started 14 legs in
  120 s: 12 WANDER legs at the walk speed and 2 HOMING runs, the test's own log line "14 legs, 12
  of them walked". Its WANDER rate, 0.1 a second, is one seeded sample, not a check of the
  estimate.) Add one `OpMonsterMotionList` per list request, at 21 bytes per walking monster.
- **A stalled client.** The tick's sends block on it, as `RunRegen`'s already do:
  `gateway.Session.Send` has no write deadline. With `-monster-battle` on the pass's swings wait
  behind those sends too (round 547's step 6; noted in round 550), so a stalled session delays the
  blows as well as the tick. The kill switch is the mitigation.

**The live checks, before the flag is flipped on the public server.** Both run on the render box
with the server built to `SERVER_BIN=/var/tmp/<lane>/opensro-server`.

- **Time dilation, which every assertion here has to allow for.** `qa_shot.sh`'s movie writer steps
  the client 1/60 s per frame at about 0.33 s of wall time a frame, so the client runs about 20x
  slower than the wall-clock server. A client's view of a monster is therefore stale, and a check
  asserts **receipt** and the server's own trace, never the drawn position.
- **Run 1:**
  `OPENSRO_MONSTER_AI=1 OPENSRO_AI_TRACE=1 OPENSRO_QA_MOB_LOG=1 client/tools/qa_shot.sh --server --frames 600 --out /var/tmp/mob_ai_tick`,
  from the default spot, with no GOTO and no `--attack`. `server.log` must have `IDLE->WANDER` and
  `leg to ... speed 8 mode 0` lines for Mangyang ids, and no leg starting beyond 324 of its home.
  The client log must have `monster <id> walk` for the same ids.
- **Run 2:** the same with `--attack`, `OPENSRO_QA_ATTACK_NAME=Mangyang` and
  `OPENSRO_QA_ATTACK_GOTO=1`. It must show:
  - at least one `struck by` line and at least one kill, or the run FAILS -- without a strike, the
    rest holds vacuously;
  - after `struck by` for id N, no `leg to` for N until `released`;
  - no struck monster `released` before it dies;
  - no `ended out of reach` line while that keep-up runs.

  GOTO must teleport from a fresh snapshot (in the callback of a `list_monsters()` it requests) or
  to a monster the client shows standing. Round 537's GOTO teleported beside the displayed body,
  which the dilation makes stale, so most first swings would have been refused as too far away.
  *Done in round 539:* with a server, every QA swing asks for the list, and the reply stands the
  player 8 units along +x from the position the server listed -- read before
  `_sync_monster_bodies` rewrites a walking monster's listed position into its drawn one -- and
  swings from there (`World3D._qa_goto_from_list`, the pure choice in `QaAttackGoto`). A player
  already on that spot is not moved again, because the OpMove would end the keep-up holding the
  monster.

**Run 1, measured (round 538, 2026-09-24, server and client at `743f231`).** Server built from the
tree (`GOOS=linux go build ./cmd/server`) and run as `SERVER_BIN=/var/tmp/mobai/srrevamp-server`,
with `OPENSRO_MONSTER_AI=1 OPENSRO_AI_TRACE=1 OPENSRO_QA_MOB_LOG=1`, `--server --frames 600`,
from the default spot. **Passed**:
- `server.log`: 551 `IDLE->WANDER` lines and 669 `leg to` lines over the run. The four Mangyang ids
  (4, 7, 10, 14; the in-memory server's own-design anchors, not npcpos) walked 22, 22, 19 and 23
  legs at `speed 8 mode 0`, and ran home at `speed 22 mode 1` 4-5 times each.
- The client log drew the same ids: `monster <id> walk` 22, 22, 19 and 23 times -- one drawn walk
  per server leg.
- No drawn leg started farther than 271.2 units from that monster's first drawn start (a proxy
  for its home, since the spawn log carries no position), under the 324 bound.
- The one id with legs and no drawing, 15, is the Earth Ghost in `donwhang`; the client stood in
  `jangan`, and the pushes are zone-scoped, so that is the expected silence.
- The client log shows `yaw 0.00 (facing unmeasured)` for the species whose model front round 533
  did not measure -- the disclosed behaviour, not a failure.

**Run 2, measured (round 539, 2026-09-24, server and client at round 539's tree).** Server built
from the tree and run as `SERVER_BIN=/var/tmp/mobai539/srrevamp-server`, with
`OPENSRO_MONSTER_AI=1 OPENSRO_AI_TRACE=1 OPENSRO_QA_MOB_LOG=1 OPENSRO_QA_ATTACK_NAME=Mangyang
OPENSRO_QA_ATTACK_GOTO=1`, `--server --attack --frames 600`, from the default spot.

- **The first attempt never swung, and that was a QA bug.** It printed no `QA ATTACK` line and
  made 3 list requests in 600 frames. The QA setup block runs on the first physics frame. With no
  `OPENSRO_QA_AT` to wait for, that frame came while `_ready` was still awaiting the QA sign-in,
  so the block found no connection and never armed the attack. Round 539 arms it when a QA server
  is configured and swings only once connected. The re-run logs `QA ATTACK: armed at tick 0
  (connected: false)`, which confirms that ordering.
- **The re-run passed every assertion.**
  - `server.log` has 9 `struck by` lines for 9 Mangyang ids (11, 25, 26, 27, 2, 29, 30, 31, 32;
    25-32 are respawns). The client log has 9 kills, `monster <id> killed by own blow`, one for
    each struck id. Each fell to the click plus two keep-up repeats.
  - No struck id has a `leg to` line after its `struck by`.
  - There is no `released` line at all, so no struck monster was released before it died.
  - There is no `ended out of reach` line.
  - Over the run, the AI started 682 legs (558 `IDLE->WANDER`).
- **The GOTO did what it was for.** Every one of the 9 first swings landed, and no swing was
  refused as too far away. Three targets were walking when struck (`WANDER->BATTLE`: 25, 27, 31).
  Two of those were drawn 20.7 and 24.7 units from where the server listed them, where round 537's
  GOTO would have put the player out of reach. Each stop push put the monster within 0.8 units of
  its listed position: the list-to-blow drift was at most one tick's walk.
- This run cannot see the three races the round-539 hold release closes: no cast, no second
  player, and no release. The Go tests hold those.

## The pure BATTLE rules and the timer read (round 545)

`server/internal/ai/battle.go` carries the two distance rules BATTLE runs on its target, the four
`_RefTactics` stand-ins they read, and the period of the give-up timer; this section holds the
reading behind them and the timer read that settles how a monster's swings are spaced. **Inert
when built** (round 545: nothing called `ai.TargetWithinChaseRange` or `ai.GiveUpCode`, and round
539's interim hold stood in `session/monsterai.go`); **run since round 546** by `battleTick` behind
`-monster-battle` (the next section). Every address below was re-read in `/var/tmp/srv.asm` and
`/var/tmp/decomp_server` on 2026-09-24; the new names are in `recovered_names.tsv` under this round.

**The order `CAIState_BATTLE::OnUpdate` (`0x55a090`) runs its tests in**, which the chase item
keeps:

1. the base `OnUpdate` (`0x558b90`, at `0x55a09e`): a non-zero timeout expired -> return (BATTLE's
   is zero, `ai.BattleDwellMs`);
2. `CAIState_BATTLE::AttackTimerGate` (`0x542670`, at `0x55a0ae`; the timer read, below) answering
   0 -> return, the tick skipped;
3. the target: `ctx+0xbc` resolved to its object (`0x55a0cd`), then `AITactics_ValidTargetOrNull`
   (`0x540dc0`, at `0x55a0dc`; it wraps `AITactics_IsValidTarget` `0x540de0`, round 424's filter:
   alive with life state 1, and the body-mode refusals), `ctx+0xa4` non-zero (`0x55a0e8`) and the
   owner's slot 393 (`+0x624`, `0x55a0f6..0x55a104`) answering non-zero for it -- any failing sends
   message **`0x23`** (`0x55a116`, the folded IDLE) and returns on 2. **This settles the stand-in
   round 537 left open**: a vanished target leaves BATTLE by `0x23`;
4. behaviour `+0x10c` (`0x55a132`, the dead request trigger of column 10) and `+0x108`
   (`0x55a144`), whose non-zero answer sends `0x2b` (FOLLOW) with its byte;
5. **the reach test**, behaviour `+0x100` = `AITactics_TargetOutOfReach` (`0x548120`, at
   `0x55a175`): 1 -> message **`0x27`** (`push 0x27` at `0x55a187`, dispatched at `0x55a22c`) ->
   IDLE; 0 -> on; any other value -> return (`cmp al,1; jne` at `0x55a17b`);
6. **the give-up check**, behaviour `+0x104` = `AITactics_BattleGiveUpCheck` (`0x5483c0`, at
   `0x55a1a2`): an answer of 2 sends message **`0x2a`** with the code byte it wrote (`0x55a1b9`),
   and the base handler `CAIState::OnMsg_0x2a` (`0x559ad0`) makes code 1 -> IDLE and codes 2 and 3
   a `0x704f` notice;
7. **the swing**, behaviour `+0xe8` = `AITactics_Handler_0e8` (`0x5472a0`, at `0x55a1d0`): 0
   (swung) or 2 (the timer refused) -> return; 1 (no skill picked, or the action machine refused)
   -> the `+0x79 == 2` branch (`0x55a1dd`, the target's position handed to `FUN_00541110`) or
   behaviour `+0x114` (`0x55a217`) -> `0x29`.

So the reach test always runs before the give-up check, and the target's validity before both.

**The reach test.** `AITactics_TargetOutOfReach` (`0x548120`) asserts flag bits 2 and 7 are clear
(round 424), measures `GObj_DistanceBetween(self, target)` (`0x53d7a0`, at `0x54814c`), and
switches on column 40 (`mov al,[edx+0x89]` `0x548158`): 0 -> the chase-range test (`test al,al;
jbe 0x548182`); 1 or 2 -> out of reach at once (`cmp al,2; jbe 0x548179`, `mov eax,1`); 3 -> out
while `AITactics_HPBucket` (`0x541d70`, at `0x54816a`) answers under 2, HP under 40 % (`cmp eax,2;
setge al`); anything else -> the chase-range test. The chase-range test is
`AITactics_IsTargetWithinChaseRange` (`0x545e50`, at `0x54818d`), negated (`neg al; sbb eax,eax;
add eax,1`). In the engine's order it answers:

| test | answer | where |
|---|---|---|
| column 35 (`+0x79`) is 0 or 2 | within | `cmp byte [eax+0x79],0` `0x545e5c`, `cmp ..,2` `0x545e6f`, both `je 0x545f5a` = `mov al,1` |
| column 36 (`+0x7c`, `fild` at `0x545e60`) is 0 | within | `fucom` against 0.0 at `0x545e7f`; `test ah,0x44; jnp 0x545f58` (C3 alone, equal, jumps) |
| no nest (`ctx+0x30 == 0`, `0x545e8e`) | within iff **dist < +0x7c, strict** | `fld [ebp+8]` the distance; `fcompp` `0x545e97`; `test ah,0x5; jnp 0x545f5a`: C0 alone jumps to `mov al,1`; an equal distance sets C3 only, even parity, falls to `xor al,al` at `0x545ea4` |
| a nest | within iff **dist <= +0x7c - excess, inclusive**, `excess = max(0, |monster - nest position| - 1.5 x nest radius)` | `Location_Copy` (`0x4115d0`) of `ctx+0x1b4` at `0x545eba`; `Location_SameOrAdjacentRegion` (`0x430ce0`) at `0x545ecc`, 0 -> out (`je 0x545ea4`); difference `0x545eef`, length `0x545ef7`; `fld [ebx+0x1cc]; fmul QWORD 0xb45d78` (1.5, the double `WithinRoamRadius` reads under rule 1) `0x545efc..0x545f02`; `fsub` `0x545f0c`; `fcom` against 0.0 `0x545f1a`, `test ah,0x41; jne 0x545f2f` keeps the raw `+0x7c` when the excess is not positive; `fsubr [esp+0xc]` `0x545f25`; `fld [ebp+8]; fld [esp+0xc]; fcompp` `0x545f38` with the threshold in st(0); `test ah,0x1; jne 0x545f4e`: only threshold < dist reaches `xor eax,eax`, equal reaches `mov eax,1` at `0x545f41` |

`ai.ChaseRange` is the nest path's reduction and `ai.TargetWithinChaseRange` the four answers, with
the path as an argument. The position the nest path measures from is `ctx+0x1b4` and the radius
`ctx+0x1cc`, which on this path are the nest's own (column 38's note: `Attach` stores
`refNest+0x20` there when there is a nest); OpenSRO treats each placement as a nest whose
position is the spawn point and whose radius is `MonsterRoamRadius` (own design), so the chase
item passes those. The strict/inclusive split is measured at the two `fcompp`s, not read off the
decompile, whose `local_34 < param_1` on the nest path is the `return 0` arm of the same test.

**The give-up check.** `AITactics_BattleGiveUpCheck` (`0x5483c0`), in order: flag bits 2 or 7
(`test cl,4` `0x5483cc`; `test cl,cl; js` `0x5483d7`; round 421) -> 0; column 35 of 0 or 2
(`mov al,[eax+0x79]` `0x5483db`; `test al,al; je` `0x5483de`; `cmp al,2; je` `0x5483e2`) -> 0;
**tactics timer 6 not due** (`mov ecx,6` `0x5483f0`, `AITactics_TimerDue` `0x5483f5`, `test eax,eax;
jg` `0x5483fa`) -> 0; a null target -> 2 with the code byte untouched (`0x54840c`); else the code
byte is set to 0xff, the distance measured (`0x54841a`) and compared with the **raw** `+0x7c`
(`fild [eax+0x7c]` `0x54842a`, `fcompp` `0x54842d` with `+0x7c` in st(0), `test ah,0x41; jp
0x548444`): C0 alone (`+0x7c` below the distance) or C3 alone (equal) is odd parity and falls to
**code 1** (`mov byte [edi],1` `0x548436`, `mov eax,2` `0x54843b`) -- so code 1 at **dist >=
+0x7c**. Nearer, and only once 5000 ms have passed since the last swing (`ctx+0xcc`: `sub ecx,
[esi+0xcc]; cmp ecx,0x1388; jb` `0x54844a..0x548456`, else 0), the code is 3 at dist >= 100.0 (the
float at `0xb45e10`, read: `00 00 c8 42`) for a target whose slot 304 (`[edx+0x4c0]` `0x54845a`)
answers 1, else at >= 150.0 (`0xb45f04`, read: `00 00 16 43`), and 2 below either. `ai.GiveUpCode`
carries the switch guard and code 1, and returns 0 elsewhere: the timer is the caller's
(`ai.GiveUpCheckPeriodMs`), the flag word OpenSRO does not hold, and codes 2 and 3 are notices,
not transitions.

**Why code 1 is all but unreachable under the stand-ins**, and the chase item still runs it. The
reach test runs first. With no nest, within is `dist < +0x7c` and code 1 is `dist >= +0x7c`: never
both. With a nest, within is `dist <= +0x7c - excess` and code 1 is `dist >= +0x7c`: both only at
`dist == +0x7c` with a zero excess, the monster inside 1.5 x its radius -- there the inclusive reach
test keeps the target and the give-up sends the monster to IDLE by `0x2a(1)` instead of `0x27`,
the same state. Anywhere the reduction bites, `dist > threshold` exits by `0x27` first.
`TestGiveUpCodeIsReachableOnlyAtTheOneEquality` sweeps both paths in quarter units and finds exactly
that. The plan's "unreachable" is corrected to this.

**The stand-ins**, each OWN DESIGN and each a constant in `battle.go` with its column:

| stand-in | value | column | why this value |
|---|---|---|---|
| `TacticsChaseSwitch` | 1 | 35 (`+0x79`) | the one value under which either distance test does anything; `Init` (`0x53f4d0`) asserts an immobile monster with a detection distance has 1 |
| `TacticsGiveUpDistance` | 400 | 36 (`+0x7c`) | twice `MonsterRoamRadius`'s own-design 200: a chase can run to the far edge of the roam circle and as far again. No value for the column was read anywhere |
| `TacticsReachRule` | 0 | 40 (`+0x89`) | the one value under which a monster chases at all |
| `TacticsRetargetRule` | 0, `RetargetKeepFirst` | 9 (`+0x20`) | the interim hold's behaviour since round 537; mob-threat-retarget revisits it |

All four columns are server-database only (the `_RefTactics` row above). The roam radius (200) and
"each placement is a nest" are round 537's stand-ins, unchanged. **BATTLE's entry stop stays own
design**: `CAIState_BATTLE::OnEnter` (`0x559fb0..0x55a08b`) issues no stop -- it arms tactics timers
3 and 4 with 100 (`push 0x64; push 3` `0x559fcf`, `push 4` `0x559fe8`) and 5 with the selector's
`+0x48` (`0x55a001..0x55a018`, below), rolls the `+0x164` sign (`0x55a01d..0x55a03d`), calls
`FUN_00541820` (the `0x704f` run mode), resolves the target, runs
`AITactics_CollectNearbyMonsters`, stamps `+0xb8` and tail-calls slot 11 (`0x541810`). In the
engine the leg is replaced by the chase's own move or the swing; the interim hold's stop at the blow
(round 539) is the stand-in with `-monster-battle` off; on, round 546's chase replaces the leg and `noteStruck` issues no stop.

**The timer read.** The tactics timer table is a `CAITimeManager` at `ctx+0x34`
(`CAITimeManager::InitTables` `0x53d4b0`, called by `AI::CTactics::Attach` at `0x53f377` with
`ctx+0x34` pushed): a first table of **9** twelve-byte entries (`mov dword [this+4],9` at
`0x53d4bb`; the vector at `+0xc/+0x10/+0x14`, each entry's first byte its index 0..8) and a second
of 3 (`+0x1c/+0x20/+0x24`). An entry is `{index byte, fired byte, last (+4), period (+8)}`.

- `AITactics_ArmTimer` (`0x53d600`; index in ECX, base in EAX, spread / time / one-shot flag on the
  stack) splits on the index at `cmp ecx,[ebx+4]; jle` (`0x53d60d`): an index up to the first
  table's count takes the first-table path. Both paths compute `period = base + |rand| % spread + 1`
  when the spread is non-zero (`0x53d69f..0x53d6ad`), at least 1 (`0x53d6b1..0x53d6b9`), and store
  it at `+8` (`0x53d6d0`). **The first-table path then sets `last = 0` (`mov dword [esi+4],0`
  `0x53d6c0`) and `fired = 1` (`mov byte [esi+1],1` `0x53d6c7`)**; the second-table path instead
  sets `last = time + rand % period` (`0x53d65e..0x53d66b`), a random phase, and no fired byte.
- `AITactics_TimerDue` (`0x53d6e0`; index in ECX, now in EDI) consumes the one-shot at `+0x28` first
  (`0x53d6e1..0x53d70b`), then the indexed entry: **fired -> due** (`cmp byte [esi+eax*4+1],1; je
  0x53d765` at `0x53d751`); else due iff `now - period >= last` (`sub edx,[ecx+8]; cmp edx,[ecx+4];
  jb not-due` `0x53d75d..0x53d763`, unsigned). Due consumes: `last = now` (`0x53d765`), `fired = 0`
  (`0x53d769`), return 1.

So **arming a first-table timer makes it due at once**, whatever its period; the period applies
only from a consumption to the next arming. The indices BATTLE uses -- 3, 4, 5 and the give-up
check's 6 -- are all first-table (one arming in the image uses a second-table index, 10, with the
one-shot flag -- `push 0xa` at `0x558fd6`, `mov al,1` at `0x558fd9`, `call 0x540d00` at `0x558fdd`
-- in `FUN_00558f70`, which is CAIState vtable slot 8, `0xaf86d4+0x20` = `0xaf86f4` reading `70 8f
55 00`, and BATTLE's own vtable carries it unchanged at `0xaf8b2c+0x20` = `0xaf8b4c`; so it IS
reachable from BATTLE, and round 545's "not on BATTLE's path" here was not established -- what
calls slot 8 is not traced; round 547). From that:

- **The first swing is immediate.** `BATTLE::OnEnter` arms timer 5 through the context wrapper
  `AITactics_ArmContextTimer` (`0x540d00`, `add ebx,0x34` then `ArmTimer`) with base = the
  selector's `+0x48` (`FUN_00540d80` at `0x55a001` reads `[ctx+0x9c]+0x48`; `mov ecx,[esp+0x14];
  push ecx` `0x55a006`; `push 5` `0x55a011`; call `0x55a018`) and spread 0 (`xor edx,edx`), and
  `Handler_0e8`'s first act is `TimerDue(5)` (`mov ecx,5` `0x5472af`, call `0x5472b6`; not due ->
  return 2 at `0x5472c1`), which the fired byte answers.
- **The re-arm at `0x547342` also fires at once**, so `ArmNextAttack`'s interval never delays a
  swing. `Handler_0e8`, once the timer answers: the armed skill (`GetArmedSkill`, slot 4, `0x5472d6`)
  or `PickSkill` (slot 7, `0x5472f6`); none -> return 1 **without re-arming** (`0x547302`); else
  `AISkill_SetHoldByteFromSkill` (`0x561890`, at `0x547315`: the selector's `+0x4c` = the skill's
  `+0x578 != 0`), the swing reach (`0x541dc0`), then **`ArmTimer(5, base = +0x48, spread 0)`**
  (`mov eax,[edx+0x48]` `0x547335`, `push 0; push now; push 0; mov ecx,5` `0x547338..0x54733d`, call
  `0x547342`) -- first table, fired -- then Execute (slot 8, `0x54735d`): refused -> 
  `AITactics_ExpireAttackTimer` (`0x5455f0`, at `0x547365`: entry 5's `last = 0`, `mov [esi+0x40],0`
  `0x545617`) and return 1; done -> `ctx+0xcc = now` (`0x547381`), face the target, return 0. The
  next tick's `TimerDue(5)` finds the fired byte from the re-arm either way.
- **`AttackTimerGate`** (`0x542670`), the test at the top of every BATTLE tick: only when the
  selector's `+0x4c` has bit 0 (`mov al,[eax+0x4c]; test al,1` `0x542677`) does it wait on
  `TimerDue(5)` (`0x542694`; not due -> return 0, the tick skipped) -- and when that answers it
  re-arms timer 5 with base 0 (period 1: `xor eax,eax; lea ecx,[eax+5]` `0x5426ac..0x5426b3`) and
  clears the byte (`AISkill_SetHoldByte` `0x5618b0` at `0x5426c5`, with the byte xor 1). After a
  swing the fired byte is already set, so this gate never skips a tick either. What the skill's
  `+0x578` is was not read.
- **The one case the period applies**: a `PickSkill` that returns nothing consumes the timer and
  does not re-arm, so the next attempt waits `+0x48` (or the 1 ms the gate left). Every roster
  species has an attack skill (round 260: a monster with one always swings it), so it does not
  arise in OpenSRO.
- **The give-up check runs on the first tick and then every 1500 ms.** `Init` arms timer 6 once with
  base `0x5dc` and spread 0 (`push 0` `0x53f6ea`, `mov eax,0x5dc` `0x53f6ec`, `mov ecx,6` `0x53f6f1`,
  call `0x53f6f6`); no other `call 0x53d600` in the image uses index 6. `ai.GiveUpCheckPeriodMs`.
  (Init's other armings: 0 with 300 at `0x53f6dc`, 7 with 30 at `0x53f70d`, and 1 -- the acquire
  scan -- with base 1000 and spread `|rand| % 491 + 10`, or 200 and `% 41 + 10` under flag bits 2/7,
  at `0x53f765`; column 42's "first action delay" is that timer.)
- **The selector's initial `+0x48` is 0.** `Init` -> `AI::CTactics::BindSkillsAndRanges`
  (`0x53f780`) calls the selector's slot 1 (`mov ecx,[ebx+0x9c]; mov edx,[ecx]; call [edx+4]`
  `0x53f8d5..0x53f8e0`) = `AI::CAISkill::vslot_001` (`0x561400`; the Basic vtables at `0xaf9d24` and
  `0xaf9dcc` carry slot 1 as `0x5619c0`, a `jmp 0x561400` thunk -- the same code, round 547), whose first call is slot 2 =
  `AI::CAISkill_Basic::ResetArmed` (`0x5619d0`) -> `AI::CAISkill::ResetArmed` (`0x5614c0`: `xor eax,
  eax; mov [ecx+0x44],eax; mov [ecx+0x48],eax; mov [ecx+0x4c],al`). So a monster's first
  `BATTLE::OnEnter` arms timer 5 with base 0 (period 1, fired), and `ArmNextAttack`'s first `J` is
  `clamp(0, 500, 2000) = 500`: the first interval is `ReuseDelay + rand % 501`.

**What this corrects.** Round 259 read `ArmNextAttack`'s window as the swing cadence ("a Mangyang
swings every 3000..3600 ms once running"). The interval's readers found are the threat table's idle
window (2 x `+0x48`, `ResolveTarget`), `BATTLE::OnEnter`'s arming and `Handler_0e8`'s re-arm, and
the two armings fire at once; **the cadence between swings is the action machine's cooldown**,
round 254's `ReuseDelay` (3000 ms for a Mangyang, `combat.Hub.CounterattackReady`'s number). The
round-259 paragraph carries the correction in place, and `ai.AttackIntervalRange` is the idle
window only. Round 261 recorded `AITactics_ArmTimer`'s shape and left each index's meaning unread;
indices 5 (the swing) and 6 (the give-up check) are read above.

**A blow, the citations corrected.** `CAIState::OnAttacked` (`0x558ea0`, the base slot 6 that IDLE,
WANDER, FLEE and HOMING use): the aggro link (`+0xf0`), the record's hate, the accounting (`+0xec`),
then `SetTarget(1)` (`push 1; call 0x53ffe0` at `0x558eed`) and `ChangeState(3)` (`xor ebx,ebx; lea
edi,[ebx+3]` from `0x558efd`) -- no aggression test and no range test. BATTLE's own slot 6 is
`CAIState_BATTLE::OnAttacked` (`0x55a2e0`), which calls behaviour `+0xfc` = `AITactics_Handler_0fc`
(`0x548090`) -- the plan's "BATTLE's slot 6 is `Handler_0fc`" was that one step short -- and goes
to IDLE only when the accounting refuses. `CAIState_IDLE::OnEnter` (`0x559c80`): the dwell,
`SetTarget(0)`, then the roam check -> `0x26` for a monster with a run speed.

**Not modelled, and disclosed:** the flag-word guards (no roster flags; rounds 421/424);
`Location_SameOrAdjacentRegion` on the nest path (a monster a region from its nest is past any chase
the stand-ins allow); give-up codes 2 and 3; the `+0x4c` hold byte's meaning; the TID-bit-15 variant
`AITactics_BattleGiveUpCheck_TID8000` (`0x5484b0`: `+0x7c + 100`, 200.0/250.0); reach rule 3's HP
bucket; the target's slot 304.

## BATTLE's chase and the monster's own swing (round 546)

`session/monsterai.go`'s `battleTick` runs the engine's BATTLE tick behind **`-monster-battle`**
(env `OPENSRO_MONSTER_BATTLE`, parsed like `-monster-ai`'s; **off by default**; `cmd/server`
forces it off with a WARN, never an exit, unless `-monster-ai` and `-monster-strike-push` are both
on -- the chase runs in the AI tick, and a swing nobody is told about would be silent HP loss).
Off, round 539's interim hold and `performAttack`'s synchronous counter are exactly what they were,
byte for byte on the wire. On, a struck monster fights on its own and `performAttack` makes no
counter (its `OpAttackResult` carries none; `PlayerHP` stays the seeded truth). The boot log says
which: `monster battle on: ...`, `monster battle off (...)`, or `monster battle forced off why=...`.
How an operator flips it is in `deploy/README.md`, "Monster battle (off by default)".

**One BATTLE tick, on every tick, in `CAIState_BATTLE::OnUpdate`'s order (`0x55a090`, round 545;
re-read in `srv.asm` for this round):**

1. **The target must be valid** (`AITactics_ValidTargetOrNull` `0x540dc0` at `0x55a0dc`), else
   message `0x23` -> IDLE (`0x55a116`). OpenSRO's validity is its own, disclosed: in `world.Hub`,
   in this zone, and not killed by this monster's last swing. The engine's `IsValidTarget`
   (`0x540de0`) wants life state 1, which a kill leaves; OpenSRO puts a dead player back on its
   feet at once (`monsterStrike`'s `RespawnHP`), so the strike worker reports the kill and the
   next tick takes the same exit. The `+0x10c`/`+0x108` calls between 1 and 2
   (`0x55a12e..0x55a15e`, message `0x2b`, the follow-owner path) are not modelled: no roster
   species has an owner.
2. **The reach test**, behaviour `+0x100` at `0x55a175` (`AITactics_TargetOutOfReach` `0x548120`,
   reach rule 0: `IsTargetWithinChaseRange` `0x545e50` negated): out -> `0x27` -> IDLE
   (`0x55a187`). Every placement is a nest whose position is the spawn point and whose radius is
   the roam radius (200, own design), so it is the nest path: within iff the distance is at most
   `ai.ChaseRange(400, 200, distance from home)` -- the give-up distance less the excess beyond
   1.5 x 200, inclusive (`ai.TargetWithinChaseRange`).
3. **The give-up check**, behaviour `+0x104` at `0x55a1a2` (`AITactics_BattleGiveUpCheck`
   `0x5483c0`), only when tactics timer 6 is due -- the first time it is asked, then every
   `ai.GiveUpCheckPeriodMs` (1500) after each consumption, kept per brain from its creation as
   `Init` arms it once (`0x53f6f6`): code 1 (`ai.GiveUpCode`: dist >= the raw 400) -> `0x2a` ->
   IDLE (`0x55a1b9`; `CAIState::OnMsg_0x2a` `0x559ad0` turns a 1 into `ChangeState(1)`).
4. **The swing**, behaviour `+0xe8` at `0x55a1d0` (`AITactics_Handler_0e8` `0x5472a0`):
   - **The band**, with the monster as the caster: `combat.ApproachBand(monster BCRadius, player
     BCRadius 4, its attack skill's Range)` -- `Tick_Attack` `0x4ad8e0` / `Tick_UseSkill` `0x4ae590`
     (rounds 247/256/488), the Range being skilldata column 21 by characterdata column 83
     (`combat.Monster.AttackRange`, round 254). A Mangyang's is exactly 10, the rule's own hole, so
     stop = reach = 6 + 4 = 10 and it is in reach at `int(dist) <= 12` (`combat.InReach`).
   - **Out of the band: the chase.** `MoveTowardObject` to `round(stop)` (`auto_command.md`, phase
     1; rounds 254/256 for BATTLE's use of it): the destination is that many units from the target
     on the line back to the monster, in the clip `Handler_110` gives BATTLE -- 1, the run clip
     (`FUN_00541820` at `BATTLE::OnEnter` `0x55a04a`, `ai.MotionMode`) -- at the run speed (the
     mode-to-speed inference above), pushed as an `OpMonsterMoved`. The leg is re-issued when the
     monster is standing, or when the target has moved `ChaseReaimDistance` (1 unit, own design)
     since the last aim.
   - **In the band: the stop and the swing.** A monster still on a leg is stopped with one stop
     push. The first swing is immediate: `BATTLE::OnEnter` arms timer 5 fired (`0x55a018`, round
     545's timer read), and so does every re-arm after a swing (`0x547342`), so what spaces the
     swings is the attack skill's ReuseDelay through the action machine (round 254; skilldata
     column 14, `combat.Monster.AttackReuseMs`: 3000 ms for a Mangyang) -- kept per brain as the
     time of the last swing, across BATTLE entries, as a cooldown is. A species with no known
     ReuseDelay has no skill row to fire and swings not at all (disclosed; every roster species
     has one).
   - **The blow** is the counter's own: `monsterStrike` (`session/monsterstrike.go`, rounds 254 and
     505, unchanged) on the target's level read at the time, run OFF the tick on one strike worker
     per monster (a goroutine fed by a one-deep channel: while one swing runs and one waits, a
     further swing is dropped with a trace line -- own design; a real 3 s gap never fills it), and
     pushed to the zone as an `OpMonsterAttacked` through the runtime's push (the zone broadcast
     under each session's wire lock). A kill is reported to the tick for step 1. The blow resolves
     at the swing's start; the client delays only the drawing, to its clip's hit event.
     - **The hand-off comes after the pass's pushes** (round 547; the tick's step 6): a stop the
       same pass queued -- the in-band stop of a monster still on a leg -- is on every session's
       wire before the blow. Until round 547 the worker was handed the swing during the pass, under
       the runtime's lock, and could push the blow before the stop was flushed; a client then drew
       the first swing on a still-walking body, which its walking-body rule leaves unturned until
       the stop lands.
     - **The worker's window**, disclosed: a swing already handed over still resolves
       (`chars.ApplyDamage` on the row) if the target changed zone or the monster died in the
       milliseconds between the tick's validity test and `monsterStrike` -- the same class of
       window as the flag-off counter's. A swing whose target another kill emptied inside that
       window lands nothing and pushes nothing (round 550), decided since round 551 under the
       character's kill lock (`session.killLock`, `fallen`): a blow whose damage leaves the pool
       at 0 reads her back under the lock, and only the one that finds her alive (not in life
       state 2) and still at 0 is the kill, so ONE of two racing kills charges the death penalty
       (`TestTwoKillsChargeOneDeathPenalty`, `TestTwoSwingsOnACharacterAliveAtZeroChargeOnePenalty`,
       deterministic interleavings) and a character a cast has left ALIVE at 0 -- an HP-cost
       skill's caster, the engine's gate passing on HP == cost (`skill_use_gate.md`, row 14) --
       still dies to the next blow (`TestSwingOnACharacterAliveAtZeroKills`). Round 550 had the
       store's transition flag decide (died only for the blow that took the pool from above 0 to
       0), which could not tell her from a character another blow was killing that instant and
       left her unkillable; before round 550 both racing blows read died=true and both charged
       the penalty. Since the hand-off
       waits behind step 5, the pass's swings also wait on a session whose socket has stalled
       (`gateway.Session.Send` has no write deadline): the tick already did, so this is no new
       exposure, only the same one a swing later.
     - **A panic inside a worker's blow** -- a store's own -- is logged at ERROR (`ai: strike
       panicked, swing dropped`, with the stack) and the swing dropped; the worker serves the next
       (round 547). A goroutine's panic is the process's, so before that one bad store write would
       have taken the server down. The recover covers the push too, so `broadcast` releases each
       session's wire lock by defer (round 550): a panic inside `Session.Send` swallowed with the
       lock held would have blocked the next tick's push to that session, and its monster list,
       for ever (`TestPanickingPushLeavesTheWireLockFree`). A runtime built without a logger
       (only a test's) logs the panic through slog's default instead of dropping it.
     - **No swing without every store**: the runtime swings only when it holds the character,
       equipment and item stores (`MonsterAIConfig`); the blow reads all three, and
       `defenderDefence`'s `eq.Get` has no nil guard. `cmd/server` passes all of them.

**A blow with the flag on.** `noteStruck` records the blow and issues NO stop: `BATTLE::OnEnter`
(`0x559fb0..0x55a08b`) issues none, and the tick's chase replaces a leg under way or stops it in the
band. A monster struck while walking away walks on for at most one tick before the chase turns it
toward its attacker at its run speed. `enterBattle` stops nothing either. Under retarget rule 0
(`ai.TacticsRetargetRule`, the stand-in) a blow on a monster already in BATTLE is ignored: the
first attacker stays the target until it leaves, dies or is out of reach, and **a second attacker
is never answered** -- disclosed; today, with the flag off, every striker is (the counter).

**The exits leave the leg alone.** IDLE's `OnEnter` (`0x559c80`) does not stop a leg, so a monster
released mid-chase runs to its last aim point; its roam check then sends one strayed past the
radius home (HOMING, a new leg), which is how a chase that gave up "walks home".

**Trace lines** (`OPENSRO_AI_TRACE`): `ai: monster %d struck by %d, engaging`, `ai: monster %d
BATTLE chase to (%.0f,%.0f) speed %.0f mode %d`, `ai: monster %d swings at %d`, `ai: monster %d
strike %d for %d (HP %d)[ blocked][ killed]`, `ai: monster %d swing at %d dropped: ...`, and
`ai: monster %d released (target gone | target killed | out of reach: ... | give-up: ...)`.

**The client half** (`World3D._on_monster_attacked`, `MonsterStrikes.is_own_unpaired`, this round).
A monster's own swing sends no `OpAttackResult` for the target's client to pair the push with
(round 540's `MonsterStrikes`). The client is not told its own character id, and this round kept
every layout as it was, so such a push is recognised **by elimination**: the server tells a client
of every other player in its zone (the enter-world result's others, then an entered notice for
each arrival, each drawn into `_other_bodies` before any blow on them can arrive), so a push whose
target is drawn nowhere is a blow on this player -- drawn at once, the monster turned to the
player, the player's hit reaction and number at the clip's hit event, the HUD's HP and the death
line from the push (`_show_own_strike`). The one hole is a push for a player who has just LEFT the
zone crossing that player's left notice (the strike worker sends off the tick; the notice comes
from the world handler): for `MonsterStrikes.LEFT_GRACE_MS` (10 s, own design) after a left notice
such a push is drawn as the swing alone. Disclosed: the retail client is told its id when it
spawns; a message carrying it here is a protocol addition this round did not make
(`docs/TODO.md`). An older client that carries round 540 draws a blow on itself as the swing alone
(no hit reaction, number or HP repaint); one older than round 540 shows no monster blow at all.

**The stand-ins, each OWN DESIGN at its line:** the four `_RefTactics` columns (round 545:
switch 1, give-up 400, reach rule 0, retarget rule 0); target validity (above); the 1-unit re-aim
threshold; the one-deep strike queue; no swing for a species with no ReuseDelay; the run speed for
mode 1 (the inference); the client's elimination and its 10 s grace; and, as before, the tick
period, the roam radius and the nest reading of each placement. Not modelled: the `0x2b` path,
the failed-swing tail (`0x55a1d2..0x55a22e`: `Handler_0e8` returning 1 -- no skill pick -- then,
with the tactics row's `+0x79` == 2 (`0x55a1dd`), two record copies into `call 0x541110` at
`0x55a200`, else behaviour `+0x114` at `0x55a217`, whose non-zero answer is dispatched as message
`0x29` at `0x55a220..0x55a22c`; round 545's reading item 7, named here in round 547 -- the runtime
makes no swing at all for a species with no skill row, above, and every roster species has one),
`BATTLE::OnEnter`'s timers 3/4, gathering and slot-11 call, `BATTLE::OnLeave` (its `ResetThreat`'s
threat seats; the armed pick's clear IS modelled since round 555, `leaveBattle`), the aggro link
(modelled in round 553, "The aggro link: the runtime (round 553)", below), the
attacker accounting, the threat table's retarget rules (mob-threat-retarget), and every
"not modelled" item of round 545's section.

**The live check** (`OPENSRO_QA_ATTACK_RETREAT`, a client QA hook added this round: once the
first blow lands, the player walks that many units straight back from the target and stops the QA
attack loop, so the server has to chase). On the render box, with the server built from the tree:

```
OPENSRO_MONSTER_AI=1 OPENSRO_MONSTER_STRIKE_PUSH=1 OPENSRO_MONSTER_BATTLE=1 OPENSRO_AI_TRACE=1 \
OPENSRO_QA_ATTACK_NAME=Mangyang OPENSRO_QA_ATTACK_GOTO=1 OPENSRO_QA_ATTACK_RETREAT=60 \
SERVER_BIN=/var/tmp/<lane>/opensro-server client/tools/qa_shot.sh --server --attack \
  --frames 600 --out /var/tmp/<run>
```

from the default spot: the round-539 GOTO stands the player 8 units from where the server lists the
Mangyang -- in both bands, so the first blow lands and the monster's first swing is immediate --
and the retreat then walks the player 60 units away, ending the keep-up (the OpMove) and leaving
the monster's target out of its band, so it has to chase. It must show, in `server.log`, `monster
battle on`, a `struck by ... engaging` line, then `BATTLE chase ... speed 22 mode 1` and `strike`
lines for the same id; in the client log, `QA ATTACK: retreating`, then `monster <id> run` and
`monster <id> strikes <player id> ... own blow, no result to pair with`; and no attack result line
reporting `took N` with N > 0 (the result carries no counter).

*Why not `--region '96\168.m' --at 1030,600`, 60 units west of the placement row (1089.65,
600.09), as the plan had it.* Tried first (this round): the client stood where it was asked
(`QA 60 local 1029, -52, 551` in its log) and the nearest Mangyang was 1995 units away
(`QA ATTACK: monster 3 at 1995`), because under `--region` the client's world frame is the LOADED
region's while the in-memory server lists monsters in the zone frame, centred on the town's region
97/168 (`worldmap.ToZoneWorld`); the two differ by one region in z. The QA teleport is not a
position in the server's frame. GOTO stands the player at the server's own numbers, which is why
round 539 built it.

**Measured (round 546, 2026-09-24, server and client at this round's tree).** Server built from
the tree (`GOOS=linux go build ./cmd/server`) and run as `SERVER_BIN=/var/tmp/mobchase546/srrevamp-server`
with the three flags and `OPENSRO_AI_TRACE=1`, `--server --attack --frames 600` from the default
spot with `OPENSRO_QA_ATTACK_NAME=Mangyang OPENSRO_QA_ATTACK_GOTO=1 OPENSRO_QA_ATTACK_RETREAT=60`.
**Passed:**

- `server.log` boots `monster battle on: ...` (no `forced off`; the two WARN lines are the
  in-memory notice and the client's disconnect at exit). The GOTO stood the player 8.0 from
  Mangyang 4 where the server listed it (`QA ATTACK: moved next to monster 4 as listed at
  -340.7,2335.2`); the first swing landed (`attack hit for 20 (34 left), took 0 (HP 200)`), the
  server drained it (`ai: monster 4 struck by 1, engaging`) and, in the band from the start, swung
  at once (`swings at 1` and `strike 1 for 13 (HP 187)` on the same tick as the entry,
  19:21:33.449); the client drew it as its own (`monster 4 strikes 1 for 13 (HP 187) -- own blow,
  no result to pair with (the monster's own swing), drawn at once`).
- The retreat (`QA ATTACK: retreating 60 from monster 4 to -272.7,-31.7,2335.2; no more swings`)
  set off **19 `BATTLE chase to (...) speed 22 mode 1` legs**, the first 5.1 s after the first
  strike (19:21:38.550, the retreat's first OpMove under the dilation), each re-aimed 2-3 units
  further as the player's position arrived, and no `leg to` for id 4 in between (its 17 `leg to`
  lines are its WANDER and HOMING legs before and after the fight).
- **21 strikes on player 1, 3.0-3.1 s apart** (the ReuseDelay to within one tick: 3.1 3.1 3.0
  3.0 3.1 3.0 3.0 3.1 3.1 3.1 3.1 3.0 3.1 3.0 3.0 3.1 3.0 3.1 3.0 3.1), 11-13 damage each and one
  critical for 22, taking the fresh character from 200 to 0. The 21st killed: `strike 1 for 11 (HP
  80) killed`, HP 80 being 40 % of 200 (`character.RespawnFraction`), then `released (target
  killed)` on the next tick and no swing after it. The client drew all 21 as its own and the last
  with `, died`.
- No attack result reported a counter: 0 lines with `took N` for N > 0 (the two results say
  `took 0`; the second, `attack hit for 18 (16 left)`, is the keep-up's one repeat before the
  retreat's OpMove ended it). No `dropped` swing, no `released` before the kill.
- Not measured in this run: the client's `monster 4 run` lines are printed only under
  `OPENSRO_QA_MOB_LOG=1`, which this run did not set; a second run of the same command with it set (Mangyang 1, GOTO at `230.8,2410.1`, the retreat to `298.8,2409.7`) drew **23 `monster 1 run from (...) to (...) at 22.0/s` legs** after the retreat -- the chase legs, each 2-5 units on toward the player as the retreat's OpMoves arrived, with a `stop ... at 22.0/s` where the band was reached -- and 19 `own blow` strikes, again with no `took N` result. The `walk ... at 8.0/s` lines before the fight are its WANDER legs.
- Time dilation applies as in the round-538/539 runs: the client saw the fight 20x slower, so its
  drawn positions were not asserted; every assertion above is a server trace line or a client
  receipt line.

Frames deleted after the run (`/var/tmp/mob_chase546*`).

## The player's dead state: the client half (round 548)

Until this round a monster's killing blow put the player back on its feet in the same call
(`session/monsterstrike.go`: `RespawnHP` at `character.RespawnFraction`, the respawned HP reported in
the result and the push), so a player was never dead on the wire. The dead state proper -- the
server's life state 2 on a monster kill, HP left at 0, moves and blows refused, a revive on request
-- is the plan's `mob-player-dead-state`, split in two with the client half first: this client is
released (tagged) before the server half's `-player-dead-state` flag is ever flipped, because a
client without it would see HP 0 and no button. **Nothing changes against today's server**: every
kill it reports carries the respawned HP, above 0, and it never sends `OpReviveResult`.

**Grounding, re-read on the RE box for this round (2026-09-24).**

- **Life state 1 is ALIVE and 2 is the character's DEAD state**: `docs/protocol/character_state.md`,
  "The life state, and the siege revive countdown (round 411)" through "Life-state 2 is the
  character's DEAD state, closed with a typed receiver (round 413)". The "must be alive" guards
  answer `GUILDERR_IM_DEAD` and `0x6807` on `GetLifeState() != 1`.
- **`GObjPC::Revive` (`0x4df290`)**, both paths read: with param 1 it passes `1` through the
  `SetLifeState` slot (`(+0x1f0)(1, 0xff, 0)`), then `(+0x55c)(0, 0xff, 0)`, `(+0x318)(2, 0, x, 0)`
  (`IGObj::SetBodyMode`, `igobj_vtable.md` slot 198) and `ApplyHPMPDelta(this, 1, 0, 8)` -- one HP,
  so the pools are filled by the caller -- and, on either path, clears `+0x28a`, `+0x738` and the
  death cause byte `+0x72d`. With param 0 it does NOT pass 1 through `SetLifeState`: it computes a
  location through `CGObjPC::FUN_004e08a0` and calls slot `0x378` with it -- the return-point path,
  unread beyond that.
- **The retail resurrect request, `GObjPC_HandleResurrectMsg_053` (`0x50fee0`,
  `server_handlers.tsv`; its layout was "unread" in the plan)**: after the buffer-empty test it reads
  ONE u8 option (`handler_payloads.tsv` had the width) and acts only while `GetLifeState() == 2`
  (`cmp al,0x2` at `0x510077`). During an active war period a `FUN_005f88f0` world whose siege
  countdown `[this+0x1cd4]` (`pc[0x735]`, round 411) is above `0xa5` is turned away. Then three
  branches. (1) Death cause `[this+0x1cb4] == 2` (`cmp BYTE [esi+0x1cb4],0x2` at `0x5100d6`;
  `leveldata.DeathCause`, whose 2 is `DeathCauseNoPenalty` and whose 3 is a monster's kill):
  `Revive(1)` (`push 0x1; call 0x4df290` at `0x5100e3`), then `ApplyHPMPDelta(GetParam(3) x 0.4,
  GetParam(4) x 0.4, 8)` -- `fmul QWORD PTR ds:0xb460f0` at `0x5100fa` and `0x510130`, and
  **`0xb460f0` reads `00 00 00 a0 99 99 d9 3f`** (`objdump -s`), the very constant
  `character.RespawnFraction` cites from the create/load path (`0x4e1141`/`0x4e1190`). Round 550
  corrects the label this section gave it: that is `0x3FD99999A0000000` = 0.4000000059604645,
  the FLOAT 0.4 widened to a double, not the exact double 0.4 (`...999A`); for a pool it changes
  no integer (`character.RespawnFraction`'s comment). (2) Option
  2: the same, only while `IGObj::GetMaxLevel` (vtable `+0x128`) is at most 10 (`cmp al,0xa` at
  `0x51017f`) -- reviving where one fell is a low-level privilege. (3) Option 1: `Revive(0)` (the
  return-point path) and `GameEventLog_Record(0x15, 2, 0)`. So the retail request is "return" (1)
  or "revive here" (2), and a monster-killed character above max level 10 has only the return.
- **A dead player is no AI target**: `FUN_00540de0` (round 424) returns no target unless
  `(**(*target + 0xf8))() == 1`, i.e. `GetLifeState() == 1`, before its body-mode tests. That is the
  server half's rule; the client relies on it only in that no further blow is drawn over a held
  die pose.
- **0x0028/0x0029 were free**: before this round neither appeared in any non-test file under
  `server/internal` or `client/scripts/net` (grep, 2026-09-24), and `server/` still has neither.
  0x0026/0x0027 are zone change; 0x0030 opens the inventory group.

**How the client learns it died** (`MonsterStrikes.leaves_dead(died, hp_after)`): a kill whose
report carries HP 0. Both reports are read through it -- the attacker's own `OpAttackResult`
(`player_died`, `player_hp`) in `World3D._on_attack_result`, and the zone's `OpMonsterAttacked`
(`target_died`, `target_hp`) in `_show_own_strike`, which is the only report of the monster's own
swing under `-monster-battle`. The HP discriminates because every server before the dead state
respawned the player in the same call and reported the respawned HP -- 0.4 of the maximum, above 0
for every shipped maximum -- while the server half leaves it at 0 and makes no `RespawnHP`. No new
field or flag was needed, so no layout changed. (The client is still not told its own character id,
round 540/544; a blow on itself is recognised by the pairing and by elimination as before.)

**What the client does** (`World3D`, "The player's dead state (round 548)"):

- **The pose.** When the killing blow lands -- on the counter's own timing, `_play_player_struck`
  from `_draw_counter_from_result` or `_draw_monster_strike` -- the body plays the die clip (type 4
  of the weapon group's table, `_a_diehardhit` by the body's own hints) and HOLDS its last frame
  (`_player_one_shot_hold`; `Skeleton3DBuilder.apply_ban_pose_at` pins a non-looping clip on its
  last keyframe once `seconds` reaches the duration) until the revive releases it to the stand loop.
- **The input lock** (`_player_dead`): WASD and the arrows, click-to-move and left-button steering
  and the QA walk (`_physics_process`, the same gate as typing; gravity, streaming and the position
  send still run); every world click -- pick-up, attack, talk, walk (`_dispatch_left_click` returns
  `"dead"`); every attack, click or quickslot cast or QA loop (`_attack_monster`); a quickslot item
  (`_on_quickslot_activated`, with `DEAD_INPUT_LINE` in chat). `_enter_dead_state` also ends the walk
  and attack under way and stops the QA attack loop.
- **[Superseded in round 665: retail's two-button dead window, `character_state.md`, "The resurrect
  choices (round 665)".]** **The Revive button** (`HudPanels.show_revive_prompt`, on the HUD itself so no window hides it):
  the death line and one button; the click emits `revive_requested`, and `World3D._on_revive_requested`
  sends `OpRevive` -- only while dead and connected.
- **`OpReviveResult`** (`_on_revive_result`): no error -> `_leave_dead_state` (the flag, the hold,
  the prompt), the HP painted from the result, the MP through the stats refresh (the scene keeps no
  MP maximum), "Revived." in chat; an error -> the server's string in chat, the state unchanged.
  [Round 665: no result arrives unasked any more -- the server's auto-revive fallback is gone.]
- **`OPENSRO_QA_REVIVE_AFTER=n`**: n physics frames after a kill left the player dead, send
  `OpRevive` as the button would; once per death.

**Stand-ins, each disclosed at its code:**

- **[Superseded in round 665: the request carries retail's option byte, and option 1 goes to a
  return point; the retail opcode is 0x3053.]** **The request carries no option and revives in place at any level.** Retail's 0x7053 carries
  the u8 above, and reviving in place is for a max level of 10 or under (or a no-penalty death);
  everyone else returns to a return point OpenSRO does not have. The option byte and the return
  point are a later round's, under `PROTOCOL_DECISION.md`.
- **[Superseded in round 665: the dialogue is read and its texts are retail's.]** **The button, its placement and its wording** are this project's: the retail resurrection
  dialogue was not read. `DEAD_INPUT_LINE` and "Revived." likewise.
- **The death clip's type** is the body table's type-4 entry; which clip the retail client plays
  at a death was not read.
- **[Removed in round 665.]** **The auto-revive fallback** (a disclosed 30 s in the plan) is the server half's; the client only
  takes its result.
- **The button needs the pk2 HUD.** It is wired when `_hud_panels` initialises (the archives
  present); without archives a dead player has `OPENSRO_QA_REVIVE_AFTER` (round 550's note; the
  server half's fallback is gone since round 665). Consistent with the client requiring archives.

**Not modelled:** ~~the return point (option 1)~~ (built in round 665, with a stand-in point), the
siege countdown gate, the cause-2 branch, the `+0x55c`/`+0x318`/`+0x378` calls inside `Revive`.

**Tests** (`client/tools/remote_godot.sh tests`): `world_test.gd` pins the pair as 0x0028/0x0029,
`OpRevive` as empty and `decode_revive_result` on the fixtures above (a revive, a refusal with and
without its tail, and three truncations); `monster_strikes_test.gd` pins `leaves_dead` (HP 0 dead;
the respawned HP not; no kill never), drives a bare World3D through the push path -- a kill at HP
76 leaves it alive with the death line, a kill at HP 0 leaves it dead with the walk, the steering
and the QA loop ended, a world click answering `"dead"`, an attack neither walked nor sent, a second
kill report harmless, a refused result still dead, a good result back with the hold released -- and
a bare HudPanels' prompt (shown with its Revive button, whose click emits `revive_requested` once;
a second show replaces the first; hide takes it down). **Negative, proved** with the five production
files stashed and the two suites run alone on the render box: `world_test.gd` fails to parse
(`Cannot find member "OP_REVIVE" in base "WorldNet"`, `Static function "decode_revive_result()" not
found`) and so does `monster_strikes_test.gd` (`Static function "leaves_dead()" not found in base
"MonsterStrikes"`, `Cannot find member "ReviveResult" in base "WorldNet"`); `remote_godot.sh tests`
counts a parse error as a failed suite. Not driven: the die clip on a real body and the prompt in a
running client (a render, once the server half exists to kill against).

## The player's dead state: the server half (round 549)

The server half of `mob-player-dead-state`, behind `cmd/server`'s `-player-dead-state`
(`OPENSRO_PLAYER_DEAD_STATE`), **off by default** (`server/README.md`; `deploy/README.md`, "Player
dead state (off by default)"). With it off nothing changes ON A KILL: a monster's kill respawns the
player in the same call at `character.RespawnFraction` and the kill's wire is what it was (the
flag-off kill tests of rounds 541 and 546 still pin the respawned HP); the one flag-independent
piece is the entry revive of a stored HP 0 (the last stand-in below; round 550 softened this
sentence, which said "byte for byte"). With it on, a monster's
killing blow -- the synchronous counter inside the attacker's `OpAttackResult` and the AI's own
swing under `-monster-battle` alike, both through `monsterStrike` -- leaves the character DEAD:

- **life state 2** (`world.LifeDead`) in `world.Hub`'s entity, with the time of death, set by
  `session.markDead` through `Hub.SetLifeState`, a compare-and-swap from 1 to 2. Which of two
  racing kills gets there is decided a step earlier, under the character's kill lock (round 551,
  `session.killLock`): a blow whose damage leaves the pool at 0 reads her back under the lock,
  and only the one that finds her alive and still at 0 is the kill -- the other lands nothing
  and pushes nothing -- so the death penalty is charged ONCE per kill, flag on or off, and a
  living character at 0 (an HP-cost cast's caster) still dies to the next blow. `revivePlayer`
  takes the same lock across its compare-and-swap and its pools, so no blow reads "alive at 0"
  between the two. Round 550 had the store decide (`character.Store.ApplyDamage`'s died, the
  transition from above 0 to 0), which left a character alive at 0 unkillable; until round 550 a
  character at 0 reported died=true to every further blow, and two strike workers passing
  `runStrike`'s dead check together each charged `leveldata.DeathPenaltyExp` before the second's
  compare-and-swap failed;
- **HP where `ApplyDamage` left it, 0**, and no `RespawnHP`: the result's `player_hp` and the push's
  `target_hp` carry 0, which is how round 548's client knows (`MonsterStrikes.leaves_dead`);
- **the potion queue emptied** (`PotionQueue.drop`), as `GObjPC::FUN_004e67b0` empties both lists
  (`0x4e67b7` -> `FUN_0049a4c0`); `potionQueueTick` also drops and lands nothing on a character in
  life state 2, the rule `ApplyHPMPDelta` applies (`cmp al,0x1` at `0x4a87e8` after the `+0xf8` call
  at `0x4a87e6`) -- so a drink racing the kill cannot heal the dead either;
- **the keep-up cancelled**, and a repeat already due ends on the attacker's life state
  (`armKeepUp`'s swing closure);
- **the experience penalty as before** (`leveldata.DeathPenaltyKilledByMonster`, unchanged).

**While dead, the server refuses** (each at the handler, each answering the request's own error
string `deadRefusal` = "you are dead", OpenSRO's wording):

| request | gate | grounding |
|---|---|---|
| `OpMove` | `handleMove`: neither stored nor relayed | own design (round 548's client stops sending; this holds an older client's walk) |
| `OpAttack` | `combatHandler`, before the reach test | own gate; the engine's action tick runs on a living PC |
| `OpUseSkill` | `useSkillHandler`, before the cooldown and costs | the self-heal's own `GetLifeState == 1` at `0x5942c0` (round 503) |
| `OpUseItem` | `UseItemHandler` (now given the world hub) | **read**: `Item_HandleUseItem` (`0x510980`) asks `GetLifeState` at `0x510c9c` and answers `0x1889` (`0x510cd0`) unless it is 1 (`cmp al,0x1` at `0x510ca6`) -- or 2 for one TID class, `(tid & 0xf800) == 0x3000` under `FUN_004929c0` (`cmp al,0x2` at `0x510cb6`), the kind usable while dead, not modelled |
| `OpPickUp` | `GroundItemHandler`, `ErrCannotPick` | own design: the retail pick-up handler (dispatch `0x034`) is a vtable thunk through slot `0x608`, not read |
| `OpDuelAttack` | `handleDuelAttack`: the attacker dead, or the opponent dead ("your opponent is dead") | own design; the opponent's side matters because a blow on a character a monster killed would report a second death and `ResetHP` a character in life state 2. A duel's own death path is unchanged (`ResetHP`, alive): the flag covers a monster's kill only |
| `OpTradeRequest` | `handleTradeRequest`, first | **read**: `GObjPC_HandleTradeMsg_081` (`0x5154e0`) asks the REQUESTER's `GetLifeState` once the target is found (`0x515607`) and answers `0x181d` unless it is 1 (`cmp al,0x1` at `0x515611`) |
| `OpTradeRespond` (accept) | `handleTradeRespond`; the pending request is cancelled for the requester; a decline goes through | own design: `GObjPC_HandleTradeMsg_084` not opened for a life-state test |
| `OpChangeZone` | `handleChangeZone` | own design: OpenSRO's warp has no retail message, and round 548's client keeps its dead state across a `ChangeZoneResult`, so a warp would put a held die pose at the new zone's spawn |
| GM `/tp`, `/goto` | `gm.Actor.Dead` -> "you are dead: revive first"; the other commands run (`/heal` fills the pools without reviving) | own design |
| `OpGuildCreate`, `OpGuildLevel` (level-up) | `handleGuildCreate` / `handleGuildLevel` (round 550): alive is the hub's life state, with HP > 0 kept as the stand-in for a character the hub does not hold; `0x4c07`'s message and code | **read**: `FUN_00514b20` (the founder's pre-check) and `CGuild::HandleLevelUp` (`0x5c63d0`: `mov edx,[eax+0xf8]` at `0x5c63e3`, `call edx` at `0x5c63eb`, `cmp al,0x1` at `0x5c63ed`, `mov ax,0x4c07` at `0x5c63f1`) ask `IGObj::GetLifeState` for 1 and answer `0x4c07` `GUILDERR_IM_DEAD` otherwise (`guild.md`). HP alone let a dead character healed by a GM found a guild |

**Left allowed while dead, one by one** (round 550; each is a request OpenSRO handles that the
engine's `0x4c07`/life-state guards were not found on, or whose retail handler was not read for
one). `OpGuildJoin`, `OpGuildLeave`, `OpGuildInfo`, `OpGuildPoints` (the read-back): not gated --
the functions returning `0x4c07` in `SR_GameServer.exe` are the founder's pre-check, the points
credit (`CGuildManager::RequestAddGuildPoints`), the level-up, the notice (`FUN_005c6480`, job
10), the alliance request and the point donation (`FUN_005c7880`, job `0x2a`), and the guild-named
functions calling the life-state slot add only the summon (`GObjPC_HandleGuildSummonReqMsg_031`)
and a ShardManager job reply; two probes, neither a proof for join or withdraw. Shop (buy, sell,
list), storage, repair: not gated; `GObjPC_HandleShopMsg_046` was read for INTERACTMODE (round
499), not for a life-state test. Party: not gated; retail's `CParty::CheckTargetAvailable`
(`0x514010`, round 413) accepts a dead TARGET, the requester's side not read. Learn-skill and
raise-mastery: not gated, handlers not read for a life-state test. Friend, chat, the lists: not
gated, own design.

**The monster AI treats a dead player as no target** -- the engine's own rule: `AITactics_IsValidTarget`
(`0x540de0`, round 424) returns no target unless `(**(*target + 0xf8))() == 1`, i.e. `GetLifeState()
== 1`, before its body-mode tests. `battleTick`'s validity test and the interim hold's now read the
life state (`world.LifeDead` -> the `0x23` exit, "target dead" in the trace, the interim hold's
line saying the same since round 550), and a swing already handed to a strike worker whose target
has died meanwhile is dropped (`runStrike`); one that passes that check, leaves the pool at 0 and
loses the kill under her kill lock (round 551, above) lands nothing -- either way the death
penalty is charged once. The round-547 `kills` record stays as the same exit one tick earlier.

**The revive.** `OpRevive 0x0028` (empty, round 548's request; any payload is ignored so an option
byte can be added later) -> `ReviveHandler` -> `revivePlayer`: only in life state 2 (the retail
handler's `cmp al,0x2` at `0x510077`; a living character is answered `"not dead"`). Since round
550 it takes the handler's own order and arithmetic: the compare-and-swap 2 -> 1 FIRST
(`GObjPC::Revive(1)` passes 1 through `SetLifeState` before any pool), so of the handler and the
fallback racing each other exactly one wins it and touches the pools and ONE result goes out --
and since round 551 the swap and the pools together under the character's kill lock
(`session.killLock`), so a blow never reads "alive at 0" between them; then
HP through `Store.Heal` by `reviveHPDelta` = `1 + trunc(0.4 x MaxHP)`, clamped at the maximum --
`Revive(1)`'s `ApplyHPMPDelta(this, 1, 0, 8)` and the handler's `ApplyHPMPDelta(trunc(GetParam(3)
x 0.4), trunc(GetParam(4) x 0.4), 8)` both ADD (`GObjPC::FUN_004a87d0`, `add edi,ebx` at
`0x4a8821`, then `SetHP`'s clamp at `GetMaxHP`), and the handler truncates (`fnstcw; or eax,0xc00;
fldcw; fistp`, rounding control 11: at `0x510102..0x510122` on its death-cause-2 path, and at
`0x5101a6` / `0x5101af` / `0x5101be` / `0x5101c6` on option 2's own -- round 551 named the two;
round 550 cited only the first); then the MP tracker to
`character.RespawnMP` (the stand-in below). Round 549 wrote the pools first and the state last,
which left a window (a blow finding HP above 0 in state 2) that ended with a character alive at 0
HP; and it set HP to `trunc(0.4 x MaxHP)`, one short of retail's 81 for a maximum of 200. The
reply is `OpReviveResult 0x0029` -- u16 error (empty) + s32 HP + s32 MP, the client's fixture
bytes `00 00 50 00 00 00 28 00 00 00` for 80/40 (a wire fixture; the numbers are the server's) --
followed by an `OpCharacterStatsResult` push so the MP bar moves without the client's round trip.
The character revives WHERE IT LIES. A store failure after the state changed puts the state back
with its time of death, and the auto-revive's WARN for a character whose revive keeps failing is
logged once per character (round 550), not every second.

**The retail handler, re-read for this round** (`GObjPC_HandleResurrectMsg_053`, `0x50fee0`; the
decompile and `srv.asm`): one u8 option; acts only in life state 2 (`cmp al,0x2` at `0x510077`);
refuses during a siege countdown above `0xa5`; then (a) death cause `[this+0x1cb4] == 2`
(`leveldata.DeathCauseNoPenalty`, NOT a monster's kill, which is 3) or (b) **option 2 with
`IGObj::GetMaxLevel` (`+0x128`) at most 10** (`cmp al,0xa; ja` at `0x51017f`) -> `GObjPC::Revive(1)`
(`push 0x1; call 0x4df290` at `0x5100e3` / `0x51018b`) and `ApplyHPMPDelta(GetParam(3) x 0.4,
GetParam(4) x 0.4, 8)` (`call 0x4a86a0` at `0x51015d`), the 0.4 being `fmul QWORD ds:0xb460f0` at
`0x5100fa` / `0x51019e` -- the constant `character.RespawnFraction` cites from the load path, the
float 0.4 widened to a double, each product truncated (round 550); (c) **option 1 ->
`Revive(0)`**, the return-point path, and `GameEventLog_Record(0x15, 2, 0)`.

**The return point, read this round and filed** (`recovered_names.tsv` row `004e08a0`,
`CGObjPC::ResolveRevivePoint`, the function round 548 called `CGObjPC::FUN_004e08a0`):
`GObjPC::Revive(0)` asks it for a region, a position and a world id and teleports through slot
`0x378`. Outside a fortress war it looks up **`_CHAR.AppointedTeleport`** (charData `+0xa4`,
`db_bind_offsets.tsv`) and takes that gate's position from `FUN_004e0a40`; an unknown gate logs
"someone designated unknown teleport gate: %d" and falls back to **`_CHAR.LatestRegion / PosX / PosY
/ PosZ / WorldID`** (`+0x94 / +0x98 / +0x9c / +0xa0 / +0xec`), which a siege world uses directly. So
retail's "return" is the character's appointed teleport gate (the town it last registered at),
with its last stored position as the fallback.

**Stand-ins, each disclosed at its line (`session/deadstate.go`'s header):**

- **[Superseded in round 665: both options are served -- option 1 to the return point (a stand-in point, the world entry's), option 2 in place at level 10 or under only.]** **Reviving in place at any level.** Grounded as retail's option 2 for a max level of 10 or under;
  above that retail offers only the return point, which OpenSRO cannot build: no
  `_CHAR.AppointedTeleport` and no teleport gates (a `LatestRegion`/`Pos`-shaped last position is
  kept on the row since round 573, under `-persist-position`, but it is where the character already
  stands). A character of level 11 or more therefore revives
  where it fell, a stand-in. No level test is made: both cases take the one in-place path, and
  `GetMaxLevel` is not modelled (OpenSRO's `Level` would equal it -- a death never costs a level,
  `GObjPC_OnDeath` leaves `CurLevel` alone -- but nothing reads it; round 550 corrected the prose
  that read as if a test existed). No wire field distinguishes them; the client message already
  says "in place at any level" (round 548).
- **The revived MP** (round 550). Retail ADDS `trunc(0.4 x MaxMP)` to the MP the character died
  with (`ApplyHPMPDelta` is additive on both pools; no MP write was found in `GObjPC_OnDeath`
  `0x4e6980` or `FUN_004e67b0` -- one probe over their decompiles for the MP slots and the
  setters, not a proof); OpenSRO SETS the tracker to `character.RespawnMP`. A stand-in.
  [Corrected round 607: this used to add that `mana.Tracker` regenerates by wall clock while dead.
  It no longer regenerates at all, and the regen tick's first test is the life state (read,
  `0x4e29a9`), so the MP a character died with is intact at the revive; SET instead of ADD is now
  the only difference, and it stays a stand-in.] The HP is exact:
  a dead character's HP is 0.
- **The flag-off instant respawn** keeps the load path's `trunc(0.4 x MaxHP)` (`RespawnHP`), not
  the handler's +1: that wire is what an older client's tests pin, and the compression of a death
  and a revive into one call is the stand-in there, not the number (round 550).
- **The empty request** against retail 0x7053's u8 option (round 548's contract).
- **[Removed in round 665: retail has no timed revive in the open world, and this one revived players among the monsters that had killed them -- `character_state.md`, "The resurrect choices (round 665)".]** **The auto-revive fallback, `AutoReviveAfter` = 30 s** (`RunAutoRevive`, a one-second pass): a
  session that never sends `OpRevive` -- a client older than round 548 -- is revived unasked and
  sent the same result and stats push. Own design and a user decision; the engine's nearest thing is
  the fortress-war countdown (`CGObjPC::PeriodicUpdateInSiege` -> `GObjPC::Revive`), a per-second
  countdown whose start value is unread and which runs only during a war.
- **The refusals** whose retail handlers were not read (the table above), and the wording.
- **Revive on entry.** A character logged out dead enters alive at `RespawnFraction`. The FRACTION
  is the load path's own rule (`GObjPC::FUN_004e1120` restores a stored zero pool to MaxHP x 0.4,
  the `fmul` at `0x4e1141`), and the rule is the load path's whatever the flag says, so
  `handleEnterWorld` applies it with the flag on or off: a character dead when the flag is turned
  off (or across a crash between a blow and the respawn) is not left alive at 0 HP, where regen
  gives nothing. The flag-off server never stores a zero otherwise, so its wire is unchanged. Doing
  it at entry rather than keeping the character dead across sessions is the stand-in.

**Not modelled:** the return point (option 1) and its option byte; the item kind usable while dead;
the siege countdown gate and the cause-2 branch; `Revive`'s `+0x55c` / `+0x318` (`SetBodyMode`) /
`+0x378` calls; life states 3, 4 and 6.

**Tests** (`cd server && go test -count=1 -p 1 ./...`): `session/monsterai_test.go`
`TestMonsterKillLeavesThePlayerDead` (THE RED: the push carries `TargetDied` with `TargetHP` 0, the
store reads 0, the hub reads life state 2 with a time of death, the queued potion is gone, the
monster goes to IDLE on the next tick and swings no more over 4 s, a potion step and regen leave 0,
`revivePlayer` gives `RespawnFraction` and life state 1, a second revive is `errNotDead`, and the
revived player is struck again) and `TestSwingOnAPlayerAlreadyDeadIsDropped` (two Mangyangs' first
swings, one blow; waited on through the workers' completion hook `monsterAI.strikeDone`, not a
sleep, since CI run 36061784919 failed it with two blows on round 549's tree -- round 550),
`TestTwoKillsChargeOneDeathPenalty` (round 550), and round 551's `TestSwingOnACharacterAliveAtZeroKills`
and `TestTwoSwingsOnACharacterAliveAtZeroChargeOnePenalty` (a pool at 0 with no death, as an
HP-cost cast leaves it: one killing blow, one penalty, the dead state or the respawn, flag on and
off); `session/skill_test.go` `TestCounterOnACasterAliveAtZeroKills` (the wire: a cast costing the
whole pool lands and leaves PlayerHP 0 alive, the next monster's counter is the death, flag on
and off); `session/duel_test.go` `TestDuelBlowOnAnOpponentAliveAtZeroEndsTheDuel`;
`session/monsterstrike_test.go`
`TestCounterKillLeavesThePlayerDeadUntilRevived` (the wire: result and both pushes at HP 0, the
dead swing refused with `deadRefusal`, the dead move not relayed nor stored, `OpRevive` ->
`OpReviveResult` at 40 % of each maximum then the stats push, the revived move relayed, a second
`OpRevive` "not dead", a fresh counter landing); `session/world_test.go`
`TestReviveResultMatchesTheClientFixture` (the pair's numbers, the client's bytes, round trips, a
truncation), `TestDeadCharacterCannotChangeZoneUntilRevived`, `TestAutoReviveFallbackFreesAnOlderClient`
(a second early: nothing; on time: the unasked result and push, life state 1; a later pass: nothing)
and `TestEnterWorldRevivesACharacterLoggedOutDead` (flag on: 40 %; flag off, the control: the stored
0 untouched); `session/useitem_test.go` `TestPotionQueueTickLandsNothingOnTheDead` and
`TestUseItemIsRefusedWhileDead` (refused and kept; revived, it lands); `session/regen_test.go`
`TestRegenTickLeavesTheDeadAtZero`; `gm/gm_test.go` `TestDeadActorCannotTeleport`;
`TestPlayerDeadStateOffByDefault`. **The flag-off control** is the existing pair
`TestMonsterBattleKillSendsItToIdle` / `TestMonsterStrikePushCarriesTheFlags`, which pin the
respawned HP in the push. **Negative, proved twice**: with the fifteen production files stashed the
new tests do not compile (`undefined: SetPlayerDeadState`, `world.Entity has no field Life`, ...);
with ONLY the kill branch of `monsterStrike` reverted, `TestMonsterKillLeavesThePlayerDead` fails
on `TargetHP:80 ... want 0`, `HP after the kill = 80, want 0`, `life 1` and the surviving potion
queue, and `TestCounterKillLeavesThePlayerDeadUntilRevived` on `PlayerHP 80, want 0`.

**[Superseded in round 665: its second half checked the removed auto-revive. Round 665's live
check (WORLD_ISSUES round 665, section 4) replaces it: a death in the densest window, option 1,
the arrival in Jangan alive.]** **Live check (not yet run).** On the render box, server built with `OPENSRO_PLAYER_DEAD_STATE=1`
(and the monster flags as wanted), a client carrying round 548: `OPENSRO_QA_COMMANDS='/spawn earth
ghost'` beside a fresh character, `--attack`, `OPENSRO_QA_REVIVE_AFTER=120`; assert in the client
log the death line at HP 0 with no `strikes <self>` line until "Revived.", then a swing that lands;
in the server log `auto-revive` absent (the request came first). A second run without
`OPENSRO_QA_REVIVE_AFTER` asserts `auto-revive character=... after=30s` and the client's "Revived."
without a click.

## Target acquisition: the runtime (round 552)

`session/monsterai.go`'s `acquire` runs the engine's acquire behaviour behind **`-monster-aggro`**
(env `OPENSRO_MONSTER_AGGRO`, parsed like `-monster-ai`'s; **off by default**; `cmd/server` forces
it off with a WARN, never an exit, unless `-monster-battle` is in effect -- so `-monster-ai` and
`-monster-strike-push` too -- and `-player-dead-state` is on: a noticed player is engaged by the
chase and the monster's own swings, and a monster that seeks players out kills ones who never
struck it, who must then stay dead). Off, nothing scans, the brains draw nothing new from the rng,
and the wire is what it was: a monster fights only when struck. On, a monster idle, wandering or,
past its blackout, running home notices the nearest living player inside its acquisition radius
and enters BATTLE against it as a blow would. The boot log says which: `monster aggro on: ...`,
`monster aggro off (...)`, or `monster aggro forced off why=...`. How an operator flips it is in
`deploy/README.md`, "Monster aggro (off by default)".

The rule itself is round 257's ("Target acquisition: the detection radius and the nearest-player
rule", above): radius = BCRadius + `_RefTactics` column 6, the nearest player, no level term. What
this round read, all of it re-read in `/var/tmp/srv.asm`, is the rest of what a scan needs:

**One scan, in `AITactics_AcquireTarget`'s order (`0x5478f0`, behaviour `+0xf8`, installed when
the row's `+0x14` is non-zero), followed by the `0x22` the calling state dispatches on its 2:**

1. An owner that is a COS never scans (slot 11 at `0x547923..0x54792b`); no roster species is one.
2. **Tactics timer 1 must be due** (`lea eax,[ctx+0x34]; mov ecx,0x1; call AITactics_TimerDue` at
   `0x547937..0x54793f`), and is consumed whenever it is, found or not. Its arming is below.
3. **The aggression byte `ctx+0x168` must be 0 or 3** (`test al,al; je` `0x54795e`, `cmp al,0x3;
   jne` `0x547962`). `AI::CTactics::Init` writes it once (`0x53f5be..0x53f5e1`): the row's mode as
   it is (`mov al,[row+0x18]`; `mov [ctx+0x168],al`), except that mode 2 rolls `rand % 100 >=
   pct` into it (`cdq; idiv 100`; `cmp edx,[row+0x1c]; setge cl`) -- a draw at or above the
   percent makes the byte 1, NOT aggressive. So mode 0 always scans, mode 1 never, mode 2 by its
   percent, and a byte of 3 would (nothing in the roster's reach writes one). `ai.Aggressive`.
4. **The scan**: the regions within **`trunc(ctx+0x15c)`** -- RC=chop, `or eax,0xc00` at
   `0x547989`, `fldcw`, `fistp QWORD` at `0x54799a` (round 257 wrote "round"; corrected in place
   above) -- for **players**, kind mask 1 with the nearest selector 2 (`mov byte [esp+0x18],0x1`
   `0x5479b9`, `mov byte [esp+0x14],0x2` `0x5479be`, the pair the row's flag word 0 leaves),
   through `AITactics_ScanForTargets` (`0x5405b0` at `0x547a07`). Its selector,
   `AITactics_Select_Nearest` (`0x5464e0`), for each candidate that passes the kind mask:
   - at most the radius away: `fild [radius]; fcomp st(1); test ah,0x5; jnp reject`
     (`0x54668d..0x5466a0`) rejects only when the radius is below the distance;
   - for a player, `AITactics_ValidTargetOrNull` (`0x540dc0`) in the PC branch, whose
     `AITactics_IsValidTarget` (`0x540de0`) wants **life state 1** -- so a player dead under
     `-player-dead-state` is no candidate; then the owner's slot 355 (`[eax+0x58c]`, not
     modelled) and the summoned-object detour (`GObjPC::FUN_004fc160`, unread beyond shape);
   - STRICTLY nearer than the pick so far, whose distance is stored TRUNCATED: `fnstcw; or
     eax,0xc00; fldcw; fistp QWORD` at `0x5466c8..0x5466e6` (the first pick) and
     `0x54673a..0x546758` (later ones); the compare `fild [best]; fcomp st(1); test ah,0x41; jne
     reject` at `0x546725..0x546738` rejects on best < dist or best == dist. A stored 0 -- a pick
     under one unit away -- reads as no pick yet (`mov eax,[edx]; cmp eax,ebx`, ebx = 0, at
     `0x546719..0x54671b`; round 555 corrected the mnemonic, which read `cmp [edx],ebx`), so any
     later candidate in range replaces it. `ai.Nearest` carries all three as read.
   - **Read closer in round 555, and NOT carried**: the PC branch (`0x546563..0x546675`) stores
     `ValidTargetOrNull`'s result back OVER the candidate (`mov [ebp+0x10],eax` `0x546590`; 0 at
     `0x5465a9` when the owner's slot 355 refuses it), lets a nearer valid summoned object of that
     player replace the candidate and its distance (`0x546646`, `0x546642`), reloads the result at
     `0x546675` and runs the radius and best-so-far compares on it with NO null test before the
     store (`mov [eax],esi` `0x546702`; `ScanForTargets` `0x5405b0` hands every player of the regions
     but the owner to the selector and goes on to the next). So a player the validity test rejects
     -- dead, under `-player-dead-state` -- is not skipped the way `acquire` skips one: it leaves a
     NULL pick at its own distance, which a later candidate must be strictly nearer than. `acquire`
     drops dead players before the scan, so a dead body nearer the monster than a living player
     never shadows the living one in OpenSRO; in the engine it would. Round 552's "one
     `ValidTargetOrNull` accepts" overstated the selector's fidelity by this much. Disclosed.
5. The pick -> `AI::CTactics::SetTarget` (`0x53ffe0` at `0x547a67`) -> return 2 -> the state
   dispatches `0x22`; `CAIState::OnMsg_0x22` (`0x559900`) asks `ValidTargetOrNull` again and then
   `AITactics_IsTargetWithinChaseRange` (`0x545e50`, `ai.TargetWithinChaseRange` with round 546's
   nest reading: every placement a nest at its spawn point with the 200 roam radius) before
   `ChangeState(3)`. A pick out of chase range stays the target and the state stays.

**Who runs it.** `CAIState_IDLE::OnUpdate` (`0x55a8b0` -- slot 3 of IDLE's vtable `0xaf899c`,
read off `.rdata`: `80dd5300 80635000 809c5500 b0a85500`, i.e. the destructor, `GetStateID`
`0x506380`, `OnEnter` `0x559c80`, `OnUpdate` `0x55a8b0`; EMOTION's vtable `0xaf8e4c` shares the
slot, which is why the decompile filed the function under EMOTION and round 257 listed only
WANDER, HOMING, WATCHOUT and EMOTION), past the expiry: `+0xf8`, and on its 2 `Dispatch(0x22)`;
`CAIState_WANDER::OnUpdate` (`0x559eb0`) between the expiry and the roam check;
`CAIState_HOMING::OnUpdate` (`0x55a690`) once slot 48, `ReaggroWindowPassed` (`0x55a720`: `now -
enteredAt > +0x1c`, STRICT), answers 1, before `HomingStep`. WATCHOUT and EMOTION the runtime does
not run.

**The cadence, read from the asm** (the decompile drops `ArmTimer`'s register arguments: the
index in ECX, the base in EAX, the spread on the stack). `Init` `0x53f712..0x53f765`:

	eax = [row+0x90]                        ; the flag word
	test al,4 -> fast ; test al,al; js -> fast   ; bits 2 and 7 (0x53f71b, 0x53f741..0x53f743)
	slow: spread = 10 + |rand| % 491, base = 1000   ; idiv 0x1eb 0x53f755, mov eax,0x3e8 0x53f757, add edx,0xa 0x53f75c
	fast: spread = 10 + |rand| % 41,  base = 200    ; idiv 0x29 0x53f738, mov eax,0xc8 0x53f73a
	push spread; mov ecx,1; call AITactics_ArmTimer ; 0x53f75f..0x53f765

`AITactics_ArmTimer` (`0x53d600`), on the first-table path index 1 takes (`cmp ecx,[ebx+4]; jle`
at `0x53d60d`; nine first-table entries):

	period = base + |rand| % spread + 1     ; div ebp 0x53d6ab, lea edi,[edx+edi*1+0x1] 0x53d6ad
	                                        ; (the second table's twin: 0x53d64e..0x53d650)
	entry.last = 0 ; entry.fired = 1        ; 0x53d6c0, 0x53d6c7 -- due the first time it is asked
	entry.period = period                   ; 0x53d6d0

so the period is **1001..1500 ms** (201..250 under bits 2/7), rolled once per spawn, and **the
first scan is immediate**. `AITactics_TimerDue` (`0x53d6e0`) answers due on the fired byte (`cmp
byte [..+1],1; je` `0x53d751`) and otherwise once `now - last >= period` (`sub edx,[ecx+8]; cmp
edx,[ecx+4]; jb not-due` `0x53d75d..0x53d763`), consuming it (`mov [ecx+4],edi` `0x53d765`). The
plan for this round first asserted the period lay in `[1011, 1501]`; the `+1` and the spread's
floor of 10 put it at `[1001, 1500]`, and `ai.ScanPeriodMs`'s test holds 20 000 draws to that,
with the low end under 1011 reached. `ai.ScanPeriodMs`.

**HOMING's blackout**, `CAIState_HOMING::OnEnter` `0x55a60e..0x55a63e`: `fld [ctx+0x15c]; fdiv
[owner+0x170]; fmul QWORD 0xb45c68` (1000.0) under the control word as found, then `or
eax,0xc00; fldcw; fistp QWORD` -> the state's `+0x1c` = **`trunc(radius / runSpeed x 1000)`**
ms. Round 261 wrote "round" and `ai.HomingReaggroDelayMs` added 0.5; both corrected (5 units at
3/s is 1666 ms, not 1667). Under the stand-in a Mangyang's is **4818 ms** (106 / 22 x 1000 =
4818.18; a value derived from the stand-in, not read).

**In the runtime** (`monsterai.go`): each brain gets its acquisition radius at creation
(`ai.DetectionRadius(BCRadius, ai.TacticsDetectionDistance)`: 104..111 for the roster) and, with
the flag on, Init's two rolls in Init's order -- the aggression verdict, then timer 1's period, the
timer starting due. `acquire` runs from IDLE (after the expiry), WANDER (after the expiry, before
the roam check) and HOMING (after the expiry, once `elapsed > +0x1c`, before the arrival test),
gathers `world.Hub`'s entities in the monster's zone in life state 1 as candidates in character-id
order, takes `ai.Nearest`'s pick, sets the target, tests `ai.TargetWithinChaseRange` and dispatches
`0x22` -> BATTLE, where round 546's `battleTick` chases and swings. The blackout is set at every
HOMING entry (`homingBlackoutMs`) whether or not the flag is on: it is arithmetic.

**Trace lines** (`OPENSRO_AI_TRACE`): `ai: monster %d noticed %d at %.0f, engaging`, `ai: monster
%d noticed %d at %.0f, out of chase range (%.0f from home)`, `ai: monster %d homing, noticing
nobody for %d ms`; then round 546's `BATTLE chase` and `strike` lines.

**The stand-ins, each OWN DESIGN at its line:**

- **The flag** is off by default, and `-monster-aggro` is the "no species aggressive" setting.
- **Column 6, the detection distance: 100 for every species** (`ai.TacticsDetectionDistance`). A
  user decision; the column is server-database only and no value for any species was read
  anywhere (round 257's search of the box). The roster's radii are therefore 104..111.
- **Column 7, the aggression mode: 0, every species aggressive** (`ai.TacticsAggressionMode`); a
  user decision. Column 8 is not read under it (`ai.TacticsAggressionPct`, 0).
- **Column 42, the flag word: 0** (`ai.TacticsFlags`): the slow timer and the (players, nearest)
  pair. A non-zero word would also need the wider kind masks, which the runtime does not carry.
- **Candidates are players only**, the world hub's entities in the zone -- OpenSRO has no
  regions -- in character-id order where the engine walks the region's player list. A pet is never
  a candidate: OpenSRO summons nothing.
- **The distance is the ground plane's**, as `battleTick`'s; `GObj_DistanceBetween` (`0x53d7a0`)
  sums three axes across regions, and OpenSRO's monsters carry no height.
- **The timer is not polled while the flag is off**, and the brains roll nothing for it then, so
  the flag-off runtime draws exactly what it drew before this round (seeded replays unchanged);
  nothing on the wire can tell.
- **Not modelled:** the selector's slot-355 test and summoned-object detour; the `+0x168` byte's
  other writers; WATCHOUT's and EMOTION's scans (states the runtime does not run); the flag word's
  wider kinds and fast timer (constants carried, never taken).

**Tests** (`session`): `TestMonsterNoticesAPlayerWalkingIntoRange` (THE RED: 3 s at 200 units
unnoticed; a walk to 50 units of the monster is noticed within 16 ticks, the target is she, the
next push is the chase leg -- mode 1 at 22, ending about 10 from her -- and the first blow lands),
`TestMonsterNoticesTheNearerOfTwoPlayers` (Aria, the lower id, at 80 and Bram at 50: Bram is the
target on the first tick -- the first scan is immediate -- and the chase leg ends at (40, 0)),
`TestMonsterAcquisitionRadiusIsInclusive` (110 unnoticed in 3 s -- a control -- and exactly 106
noticed within a scan period), `TestMonsterDoesNotNoticeADeadPlayer` (dead at 10 unnoticed in 3 s
-- a control -- and noticed within a scan period once revived),
`TestHomingMonsterNoticesNobodyInsideItsBlackout` (carried 300 units out, running home past Aria
at 150: inside 106 from about 2 s on, HOMING through the tick at 4800 ms -- a control -- and
BATTLE at 4900), `TestMonsterAggroOffLeavesPlayersUnnoticed` (the flag-off control: 6 s at 50
units, IDLE throughout, no blow), `TestMonsterAggroOffByDefault`; `ai`:
`TestScanPeriodRangesAsRead`, `TestAggressiveByMode`, `TestNearestPicksTheCloserAndTruncatesTheRadius`
(106.7 admits 106 and refuses 106.5; the truncated-best rule; the stored-0 rule),
`TestDetectionRadiusUnderTheStandIn`, and `TestHomingRules`' new 1666 and 4818 cases;
`cmd/server`: `TestMonsterAggroAllowed`. **Negatives, proved two ways**: with the four production
files stashed, the new tests do not compile; with only `acquire`'s body replaced by `return false`
the five positive halves fail as written ("not in BATTLE 1.6 s after Aria walked to 50 units",
"state IDLE after the first tick", "a player at exactly 106 units was not noticed", "revived at 10
units she was not noticed", "at 4900 ms, past the blackout, the state is HOMING") while the two
controls hold, and with only the helper's `+ 0.5` restored `TestHomingRules` fails on "1667 ms;
want 1666".

**The live check.** The plan's design -- stand an unarmed player about 50 units from a monster and
wait -- has no QA hook that can do it in the server's frame: `--say` is chat (`NetClient.say`), not
a GM command (`OpGMCommand 0x00F1`, which only the chat box's `forward_gm` sends), so `--say "/spawn
Mangyang"` spawns nothing (tried first this round: the server logged the session and no command);
`OPENSRO_QA_AT` converts a region-local spot relative to the LOADED region, not the zone frame
(round 546's finding); and the GOTO swings. What the existing hooks CAN do is make the monster's
re-engagement provably unstruck: the QA character attacks a **Yeoha** (249 HP, 67-79 a blow every
2500 ms: it kills a fresh 200-HP character in three blows, while she barely scratches it) from the
GOTO's 8 units, dies to it, lies dead at ~8 units -- and is not noticed, since a dead player is no
candidate -- until `OPENSRO_QA_REVIVE_AFTER` sends `OpRevive`; the QA attack loop has stopped for
good at the death (`World3D._enter_dead_state`), so from the revive on the only way the Yeoha can
re-engage her is the scan. On the render box, with the server built from the tree and all five
flags on:

```
OPENSRO_MONSTER_AI=1 OPENSRO_MONSTER_STRIKE_PUSH=1 OPENSRO_MONSTER_SPAWN_PUSH=1 \
OPENSRO_MONSTER_BATTLE=1 OPENSRO_PLAYER_DEAD_STATE=1 OPENSRO_MONSTER_AGGRO=1 \
OPENSRO_AI_TRACE=1 OPENSRO_QA_MOB_LOG=1 OPENSRO_QA_ATTACK_NAME=Yeoha OPENSRO_QA_ATTACK_GOTO=1 \
OPENSRO_QA_REVIVE_AFTER=60 SERVER_BIN=/var/tmp/<lane>/opensro-server \
client/tools/qa_shot.sh --server --attack --frames 600 --out /var/tmp/<run>
```

It must show, in `server.log`: `monster aggro on` (no `forced off`); for the Yeoha the first fight
(`struck by 1, engaging` or, should the scan beat the GOTO's swing, `noticed 1 at N, engaging`),
`strike 1 for ... killed`, `released (target dead)`; then NO `noticed` line for her while she is
dead; then, after the client's `QA REVIVE: sending OpRevive`, a `noticed 1 at N, engaging` line for
that id with NO `struck by` line between the release and it, followed by `strike 1 for ...` lines
(and `BATTLE chase ... speed 20 mode 1` if she lies outside its 22-unit band). In the client log:
`QA REVIVE: sending OpRevive ...`, "Revived.", then `monster <id> strikes 1 ... own blow`. Under
the movie writer's dilation (the client runs about 20x slower than the wall-clock server) every
assertion is a server trace line or a client receipt line, never a drawn position.

**Measured (round 552, 2026-09-25, server and client at this round's tree).** Server built from
the tree (`GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build ./cmd/server`) and run as
`SERVER_BIN=/var/tmp/mobaggro552/srrevamp-server` with the five flags, `OPENSRO_AI_TRACE=1` and
`OPENSRO_QA_MOB_LOG=1`, `--server --attack --frames 600` from the default spot with
`OPENSRO_QA_ATTACK_NAME=Yeoha OPENSRO_QA_ATTACK_GOTO=1 OPENSRO_QA_REVIVE_AFTER=60`. **Passed**, and
more cleanly than the design above needed, because the player never landed a blow at all:

- `server.log` boots `monster aggro on: ...` (no `forced off`; the two WARN lines are the in-memory
  notice and the client's disconnect at exit). **There is no `struck by` line in the whole run**:
  the QA attack loop armed at tick 0 and the client was still loading its world when the fight
  began, and after the first death the loop is off for good. Every engagement below is the scan's.
- The default spot is the zone frame's origin (`QA 60 local 960, 40, 960`: region 97/168's centre),
  and a Yeoha (id 9; BCRadius 11, so radius 111; walk 9, run 20; ReuseDelay 2500) wandering off its
  own-design anchor at (200, -220) came within it 25 s after the session connected:
  `ai: monster 9 noticed 1 at 104, engaging` (00:03:50.071), `IDLE->BATTLE` on the same tick, then
  `BATTLE chase to (14,-14) speed 20 mode 1` (the point 22 units from her: 11 + 4 + its range 7),
  and 4.1 s later -- about 80 units at 20 u/s -- `strike 1 for 77 (HP 123)`, `strike 1 for 77 (HP
  50)` and `strike 1 for 79 (HP 0) killed` **2.5 s apart** (the Yeoha's ReuseDelay to within a
  tick), `released (target killed)`, `BATTLE->IDLE`, and at once `homing, noticing nobody for 5550
  ms` -- trunc(111 / 20 x 1000), the blackout under the stand-in -- since the kill left it 275
  units from its anchor.
- The client drew all three as its own (`monster 9 strikes 1 for 77 (HP 123) -- own blow, no result
  to pair with`), the third `died`, and `left dead (HP 0) t=0.50 -- input locked until the revive`;
  60 physics frames later `QA REVIVE: sending OpRevive 60 frames after the death`, `revived (HP 81,
  MP 80)` (1 + trunc(0.4 x 200), round 550's arithmetic).
- **The second engagement is the unstruck re-acquisition the design asked for**: the Yeoha ran
  home, wandered, and 46 s after the revive came back within range -- `ai: monster 9 noticed 1 at
  100, engaging` (00:05:06.971), `BATTLE chase to (0,-20) speed 20 mode 1`, `strike 1 for 168 (HP
  0) killed` (a critical, the client's `CRIT`), `released (target killed)`, its blackout again --
  with no `struck by` and no player packet but the revive between the first release and it. The
  client drew it, died again (`left dead (HP 0) t=3.75`), and the QA revive brought her back once
  more (`revived (HP 81, MP 80)`); the run ended before a third pass.
- No other monster noticed anyone (the town spawn is beyond every other anchor's reach), and the
  monster 9 lines are the only `noticed` lines. 121 `homing, noticing nobody for N ms` lines over an
  earlier run of the same tree from the same spot (run 2, without the Yeoha's visit) carried the
  per-species truncations: 2000 (110/55), 1927 (106/55), 1890 (104/55), 1386 (104/75), 5550
  (111/20), 4818 (106/22).
- Not measured: the dead player lying inside a monster's radius (the Yeoha was 130+ units off while
  she was dead, so "not noticed while dead" was vacuous here); `TestMonsterDoesNotNoticeADeadPlayer`
  holds it. Time dilation applies as in the earlier runs: every assertion above is a server trace
  line or a client receipt line.

Frames deleted after the run (`/var/tmp/mob_aggro552b`); the server log is kept as
`/var/tmp/mobaggro552/run3/server.log`. A first attempt with `--say "/spawn Mangyang"` (run 2,
`/var/tmp/mobaggro552/run2/server.log`) spawned nothing, for the reason above, and is why the
paragraph before this one no longer proposes it.

## The aggro link: the runtime (round 553)

`session/monsterai.go`'s `linkAggro` runs `AITactics_ExtRoutine::LinkAggroToNearbyMonsters`
(`0x547570`, behaviour `+0xf0`) where `CAIState::OnAttacked` (`0x558ea0`) runs it -- at `0x558ebb`,
on a blow drained for a monster NOT already in BATTLE, before that monster's own `SetTarget` and
`ChangeState(3)` (`onStruck`) -- **with `-monster-battle` on**. It rides that flag and has none of
its own: a linked monster is engaged by the chase and the monster's own swings exactly as a struck
one is, and an older client draws its output -- legs as `OpMonsterMoved 0x007C`, blows as
`OpMonsterAttacked 0x007D` -- as it draws a struck monster's; under the interim hold a linked
monster would only stand where it was, the reason acquisition needs the flag too. With the flag
off nothing links and the wire is what it was. No opcode or layout changed.

**What it does.** A party member's first blow on a monster that is idle, wandering or running home
gathers the ten nearest OTHER monsters of its zone within its detection radius scaled by the level
gap -- `ai.LevelScaledRadius(BCRadius + 100, monster level - attacker level)`, an int: 106 for a
level-1 Mangyang under a level-1 player, 84 (84.8 chopped) under a level-5 one, 63 under a level-8
one -- counts the party members at most 1000 units from the attacker (the attacker included), and
puts that many of the gathered, nearest first, into BATTLE against the attacker. A solo player links
nothing. A second blow on a monster already fighting links nothing (BATTLE's slot 6 is
`CAIState_BATTLE::OnAttacked` `0x55a2e0`, which calls behaviour `+0xfc` = `AITactics_Handler_0fc`
`0x548090` and, on its non-zero answer -- the 1 `Handler_0fc` returns only when the `+0xec`
accounting refuses, the round-546 paragraph "The choice" above -- `ChangeState(1)`s to IDLE (`lea
edi,[ebx+1]; call 0x53ff30` `0x55a302..0x55a305`); no `+0xf0` call; round 555 corrected "slot 6 is
`Handler_0fc`", one step short, as the round-546 section already had it). A linked monster links nothing further
(`CAIState::OnAggroLinked` `0x559bb0` has no `+0xf0` call). A gathered monster already in BATTLE
keeps its target (`CAIState_BATTLE::OnAggroLinked` `0x55a320` credits it through `+0xec` and, when
the accounting refuses, `ChangeState(1)`s to IDLE -- `lea edi,[ebx+1]; call 0x53ff30`
`0x55a342..0x55a345` -- a branch the round-258 paragraph records and this section had compressed to
"only credits" until round 555; the refusal is not modelled, so here it keeps its target under rule
0) and still uses up its place among the n; so does a DEAD one, which the forward reaches and which
refuses the transition. Trace lines, with `OPENSRO_AI_TRACE` set: `ai: monster %d struck by %d
of a party: %d member(s) within 1000, %d neighbour(s) within %d, linking %d`, `ai: monster %d linked
to %d by the hit on monster %d, engaging`, and `... already in BATTLE, keeps its target`.

**Grounding, re-read for this round (2026-09-25: `/var/tmp/srv.asm`, the decomp dump, `objdump -s`
on `.rdata`; the corrected blocks are in "The aggro link: a party's hit pulls the neighbours in",
above):**

- `OnAttacked` `0x558ea0`: the hate saved (`0x558ea6`), `+0xf0` at `0x558ebb`, `ftol(hate x 1.15f)`
  written back (`0x558ebd..0x558ecc`), `+0xec` (`0x558ed2..0x558edd`), `SetTarget(1)` (`0x558eef`),
  `ChangeState(3)` (`0x558f01`).
- The link `0x547570`: the zero-hate and not-a-PC returns; the party and its `+0x10` bit 0; the
  member count with the attacker counted at `0x5476f6` and the **inclusive** 1000.0 (`fcomp QWORD
  0xb45c68; fnstsw ax; test ah,0x41; jp` `0x5476e9..0x5476f4`: the increment runs on "below" and
  on "equal"); the region test `0x430ce0` before it; CLAMP (`0x547778..0x54778c`,
  `0x54782b..0x547839`); the damage zeroed (`0x547797`); the emptiness test `0x5426e0` on `ctx+0x80`
  (`add esi,0x80` `0x54771f`); the hate floor (`0x5477b2..0x5477b8`); `ValidTargetOrNull` at
  `0x5477ea`; the forward `push 0; push esi; push 0xe; call edx` (`0x547805..0x54780a`); the decay
  (`0x54780c..0x54781a`).
- `CollectNearbyMonsters` `0x540580` -> `LevelScaledRadius` `0x541e00`: the levels off vtable slot 73
  (`call eax` at `0x541e43`/`0x541e52`, `movzx` bytes), the bands (`cmp esi,4 / 1 / -7 / -4`),
  `fmul QWORD` on the four doubles, **`fstp DWORD [esp+0x4]` `0x541e9b`** (the -3..0 band jumps
  past it, `0x541e8f` -> `0x541e9f`), then `fnstcw; or eax,0xc00; fldcw; fistp QWORD` and `mov
  [ebx],edx` (`0x541ea4..0x541ec2`): an INT out-parameter, chopped. The doubles, byte for byte:
  `0xb45c08` `0x3ff6666660000000` (the float 1.4f widened, 1.39999997615814), `0xb45c00`
  `0x3ff3333340000000` (1.2f), `0xb45bf0` `0x3fe99999a0000000` (0.8f), `0xb45bf8`
  `0x3fe3333340000000` (0.6f); `0xb45c68` the double 1000.0; `0xb45b68` the float 0.5; `0xb46300`
  `0x3ff2666660000000` (1.15f).
- `GatherObjectsWithin` `0x540860`: the owner's regions within the radius (slot 5), the owner
  skipped, kind mask 2, not `MOB_AUTOMOB`, the float distance from the OWNER
  (`GObj_DistanceBetween` at `0x540a8d`, the owner in eax and the candidate in ecx) **at most** the
  radius widened to a float (`fStack_48 <= fStack_58`), sorted, at most ten popped.
- `CAIState::OnAggroLinked` `0x559bb0` (credit, `SetTarget(1)`, `ChangeState`, no `+0xf0`),
  `CAIState_BATTLE::OnAggroLinked` `0x55a320` (credit, and IDLE on the accounting's refusal),
  `AITactics_CreditAttacker` `0x5473c0` (`param_2[1]` = `+4` into the total and the seat's damage,
  `param_2[2]`/`[3]` = `+8`/`+0xc` into its hate; returns 1 -- drop -- for a code-0 record whose
  hate lands below 1).

**Wired.** `ai/state.go`: `LevelScaledRadius` returns the chopped int through the float store
(until this round the float64 product); the four factors and the 1.15 are the widened floats
(`float64(float32(1.4))` and so on, bit-exact to `.rdata`); `GatherWithin` (new); `AggroLinkHate`
(was `AggroLinkDamage`; the floor at 1); `AggroLinkCount` unchanged; the header and the acquisition
comment. `session/monsterai.go`: `MonsterAIConfig.Parties`, `linkAggro`, its call in `onStruck`
under `a.battle`, the header. `cmd/server`: the party hub passed, the battle-on boot line.
`orphans_test.go`: `AggroLinkCount` and `LevelScaledRadius` removed (called now); `AggroLinkHate`
stays listed for mob-threat-retarget.

**Stand-ins, each disclosed at its line:**

- **Every blow carries hate.** The routine returns before gathering when the record's hate is 0,
  and OpenSRO's blows carry no hate value. What hate a plain blow's record holds is UNREAD. The
  stand-in is consistent with the model the runtime already rests on rather than a fresh inference
  (round 555): `CreditAttacker` `0x5473c0` returns 1 -- drop -- for a code-0 record whose hate
  lands below 1, and `CAIState::OnAttacked` only `SetTarget`s and `ChangeState(3)`s when `+0xec`
  returns 0, so a zero-hate first blow would not even engage its victim -- and round 546's BATTLE
  entry on every blow already assumes a blow engages. The magnitudes are mob-threat-retarget's, and
  no hate is forwarded (`ai.AggroLinkHate` is not called).
- **A party is two or more.** The engine tests only the party pointer, but never creates a party
  of one; OpenSRO's create path does (round 485's reading, `killExpFor`).
- **The zone for the region set** (the gather's regions; the member test's region adjacency, which
  1000 units already implies), **the ground plane** (the engine sums three axes; OpenSRO's
  monsters have no height; as `acquire` and `battleTick` measure), **ties by id** in the gather
  (the engine's container keeps the region walk's order).
- **The attacker's level is the world entity's cached level** (`world.Entity.Level`; round 555,
  which replaced this round's one `chars.GetByID` per link event under the tick's lock -- one slow
  store read stalled every monster's tick -- and `runStrike`'s one per swing). The cache is the
  row's at enter-world and moves with the row at the two places a level changes, the level-up in
  `performAttack` and gm's `/level`; nothing else moves a level. A character store is no longer
  needed for the link, only for the swing.
- **A monster hatched since the pass's step 2** has no brain yet and is skipped for that blow.
- **The attacker accounting's refusals** (`+0xec`) are still not modelled, on the victim or on a
  linked monster.

**Tests** (`cd server && go build ./... && go test -count=1 -p 1 ./...` green; re-run after the doc
edits): `session` -- `TestPartyHitLinksTheTwoNearestNeighbours` (THE RED: a party of two, Bram 500
off; exactly B and C, the two nearest to the VICTIM, in BATTLE on the tick that drains the blow,
B's push the chase toward Aria; D nearer to Aria but farther from A, E outside the radius, F inside
B's radius, all idle two ticks on: no cascade), `TestPartyOfThreeLinksThree`, the controls
`TestSoloHitLinksNothing`, `TestSecondHitOnABattlingMonsterLinksNothing` (a third mate joins between
the blows so a wrongful re-link would have a place for D) and `TestAggroLinkNeedsTheBattleOn` (the
flag-off control: the hold alone, no push), `TestPartyMateCountsAtAThousandUnitsNotBeyond` (1000
counts, 1001 does not), `TestAggroLinkRadiusScalesByTheLevelGap` (level 5 on level 1: 84 in, 85
out); `ai` -- `TestLevelScaledRadiusChops` (THE RED of the helper: 108 x 1.2 = 129.6 -> 129, where
rounding gives 130; 84.8 -> 84; 63.6 -> 63; and 110 x 1.4f -> 154 through the float store, where
chopping the exact product gives 153), `TestLevelRadiusFactorsAreTheRdataDoubles` (bit-exact),
`TestGatherWithin` (inclusive at the radius, nearest first, ties by id, the cap of ten),
`TestAggroLink` (the hate ladder 45, 22, 11, 5, 2, 1, 1 and the victim's 51 and 22).
**Negatives, proved three ways**: the three production files stashed (`ai/state.go`,
`session/monsterai.go`, `cmd/server/main.go`): `ai` and `session` fail to build (`undefined:
GatherWithin`, `undefined: AggroLinkHate`, `f.a.parties undefined`); with ONLY `LevelScaledRadius`
rounding instead of chopping, `TestLevelScaledRadiusChops` fails on `108 -> 130; want 129` (and 85,
64); with ONLY `linkAggro`'s body removed, every positive fails as written (`in BATTLE after the
blow: "A", want exactly A (struck), B and C (linked)`, ...) while the solo and flag-off controls
hold. Restored from kept copies, byte for byte (`cmp`).

**Live: not feasible.** `qa_shot.sh` drives one client and a party needs two, so there is no
render-box check for this round; the Go tests above are the evidence. When a second driven client
exists, the check is: two characters in a party, one strikes a Mangyang standing among others; the
server log shows `struck by ... of a party: 2 member(s) within 1000, K neighbour(s) within 106,
linking 2` and two `linked to ... engaging` lines, and both clients draw two more monsters running
at the attacker.

**Deploy.** Nothing to flip: the link rides `-monster-battle`, which is off by default
(`deploy/README.md`, "Monster battle (off by default)"). On a server with it on, the link is live
at once with no client change.

## The second attack skill: the runtime (round 554)

`mob-second-skill`. Four roster species carry two attack skills in the client's own tables, and
until this round every species swung its col-83 skill alone ("The skill choice", above, said the
whole roster had one). Now, **with `-monster-battle` on** (no flag of its own: the swing is that
flag's, and an older client draws the legs and blows as the same `OpMonsterMoved` /
`OpMonsterAttacked`), a monster in BATTLE draws each swing among its attack skills, walks to the
drawn skill's band, fires it and cools down for its ReuseDelay. **Flag off: nothing changes** --
the counter rolls the primary range as before. No opcode or layout changed.

**The data (RE box, `/var/tmp/tables`, 2026-09-25).** characterdata cols 83..92 by species -- the
ten dwords at `RefObjChar+0x260` that `AI::CTactics::BindSkillsAndRanges` (`0x53f780`) reads:
`mov eax,[edx+0x18]; add eax,0x260` at `0x53f954..0x53f95b`, ten iterations (`mov dword
[esp+0x14],0xa` at `0x53f941`), each dword resolved by `SkillBook::ResolveUsableSkillRef`
(`0x59d600`) and, when it resolves, registered by `RegisterAISkill` (`0x53fa70`), `add
[esp+0x10],4; sub [esp+0x14],1; jne` at `0x53f980..0x53f98a`. `+0x260` is col 83 by the anchor
`combat.Monster.Critical` records (`GObjMob_PublishStats`' run: `+0x230` = col 71, `+0x24c` = col
78), and the skill names agree (160 is MSKILL_CH_MANGNYANG_ATTACK01):

| species | col 83 | col 84 | cols 85..92 |
|---|---|---|---|
| Mangyang 1933 | 160 MSKILL_CH_MANGNYANG_ATTACK01 | 161 MSKILL_CH_MANGNYANG_ATTACK02 | 0 |
| Small-eyed Ghost 1934 | 162 MSKILL_CH_BIGEYEGHOST_CLON_ATTACK01 | 0 | 0 |
| Big-eyed Ghost 1935 | 163 MSKILL_CH_BIGEYEGHOST_ATTACK02 | 0 | 0 |
| Old Weasel 1936 | 164 MSKILL_CH_GYO_CLON_ATTACK01 | 0 | 0 |
| Weasel 1937 | 165 MSKILL_CH_GYO_ATTACK02 | 0 | 0 |
| Water Ghost slave 1938 | 166 MSKILL_CH_WATERGHOST_CLON_ATTACK01 | 167 MSKILL_CH_WATERGHOST_CLON_ATTACK03 | 0 |
| Water Ghost 1939 | 168 MSKILL_CH_WATERGHOST_ATTACK01 | 169 MSKILL_CH_WATERGHOST_ATTACK02 | 0 |
| Tomb Stone Ghost 1950 | 171 MSKILL_CH_TOMBSTONE_CLON_ATTACK01 | 0 | 0 |
| Stone Ghost 1941 | 172 MSKILL_CH_STONEGHOST_ATTACK01 | 0 | 0 |
| Yeoha 1943 | 176 MSKILL_CH_YEOHA_ATTACK01 | 177 MSKILL_CH_YEOHA_ATTACK03 | 0 |
| Earth Ghost 1963 | 210 MSKILL_WC_EARTHGHOST_ATTACK02 | 0 | 0 |

and the skilldata rows the draw and the swing read (col 14 ReuseDelay, 21 Range, 66
AI_AttackChance; col 67 AI_SkillType reads 80, 'P', on every one; the `att` block at col 69, its
five values `(type, percent, min, max, percent)` per `skill_params.md`):

| id | ReuseDelay | Range | AI_AttackChance | `att` |
|---|---|---|---|---|
| 160 | 3000 | 10 | 100 | 5, 200, 17, 19, 100 |
| 161 | 3000 | 10 | 100 | 5, 100, 17, 19, 100 |
| 166 | 2000 | 16 | 100 | 5, 133, 41, 47, 100 |
| 167 | 2500 | 16 | 100 | 5, 167, 41, 47, 100 |
| 168 | 2000 | 16 | 100 | 5, 133, 47, 54, 100 |
| 169 | 4000 | 16 | **10** | **9, 0, 0, 0, 100**, then `ps` 28787 (34, 100, 16) |
| 176 | 2500 | 7 | 100 | 5, 167, 67, 79, 100 |
| 177 | 2500 | **100** | 100 | 10, 167, 94, 105, 100 |

(The single-skill species' rows -- 162 2000/4/100, 163 1500/4/100, 164 2000/7/100, 165
2000/7/100, 171 2500/100/100, 172 2500/10/100, 210 2000/7/100 -- read the same numbers the roster
has carried since round 254, with chance 100 each.) 169 is a zero-damage `att` block beside a
`ps` param (`0x7073`, a three-value run per `skill_params.md`'s table; what it does is not read
here): a status skill. The `att` percent (value [1]: 200 on 160 against 100 on 161) is not applied
to a monster's blow, as it never has been -- deferred to mob-monster-att-percent, which must be
read before any damage scaling.

**The engine, re-read for this round** (the weight and the draw are corrected in place in "The
skill choice", above). `AITactics_Handler_0e8` (`0x5472a0`, BATTLE's swing step): the selector's
current pick first (slot 4, the `+0x44` that `ArmNextAttack` fills), and only when it is empty
`PickSkill` (slot 7); with no pick it returns 1 (no swing); otherwise Execute (slot 8) runs the
skill through the action machine, whose approach is to THAT skill's band (rounds 254/256). So
the pick precedes the walk, and the band follows the pick. `PickSkill` `0x561b00`: weight = chance
+ trunc(margin x 5.0 / 10.0) for a float margin above 0 (`.rdata` `0xb45b00` = 5.0, `0xb45c60` =
10.0, `objdump -s`), r = |rand()| % (total + 1), the first cumulative weight >= r; `0x5632d0` is
the vector-subscript throw, not the draw. `ArmNextAttack` `0x5619e0`: `+0x44` = the skill, `+0x48`
= its ReuseDelay (`+0x7c`) + rand % (J + 1), the idle window (round 545: never the cadence).

**Wired.** `combat.MonsterSkill` {ID, ReuseMs, Range, AttMin, AttMax, Chance}, `combat.Species.Skills`
and `combat.Monster.Skills` (copied at the spawn); `cmd/server`'s roster carries every species'
list, col 83 first, through `combatSpeciesOf` (GM spawns too), `monsterSpec.Skills`.
`ai.SkillWeight` corrected (half the margin, floats), `ai.AttackSkill`, `ai.PickSkill` (the draw;
`pickByWeight` the pure rule). `session/monsterai.go`: the brain's `armed` / `hasArmed` /
`swungReuseMs`, `armSkill`, `battleTick`'s step 4 -- the armed skill's Range sets the band, the
skill fired sets the cooldown, the strike job carries the skill. `session/monsterstrike.go`:
`monsterStrike` takes the skill and rolls its `att` block; a block whose max is 0 lands an
explicit 0 and skips the pipeline (whose floor band and level term each raise a 0 to 1); no skill
named -- `performAttack`'s counter, a monster spawned without a list -- is the primary range as
before. `client/tools/verify_monster_specs.py` re-derives the whole list (`Skills=`, `--specs -`
from stdin so nothing is written on the RE box); `cmd/server`'s `TestWriteMonsterSpecsForVerifier`
writes its input from the live roster. Run 2026-09-25 against `/var/tmp/tables`: **103 verified, 0
mismatched, 0 unresolved**; the control with Yeoha's second skill dropped from the spec reports
`spec has 1 [176], cols 83..92 name 2 [176, 177]` (1 mismatched), and the control with 177's range
altered to 99 reports `skill[1] spec=(177, 2500, 99, ...) table=(177, 2500, 100, ...)` (1
mismatched).

**The stand-ins, each OWN DESIGN at its line:**

- **one cooldown per monster**, the ReuseDelay of the skill last fired (`swungReuseMs`): whether
  the engine's action machine keeps a per-skill re-use timer for a monster -- so that the OTHER
  skill could fire inside the first's delay -- is not read;
- **the draw's moment**: the first BATTLE tick that finds nothing armed -- the entry tick, and
  the tick after each swing -- at that tick's distance. **Every entry draws afresh (round 555):**
  `CAIState_BATTLE::OnLeave` (`0x55a240`) calls only `AI::CTactics::ResetThreat` (`0x53fb20`, at
  `0x55a243`), which zeroes the selector's `+0x44` -- `xor eax,eax` `0x53fb28`, `mov
  ecx,[edi+0x9c]; mov [ecx+0x44],eax` `0x53fb78..0x53fb7e` -- with the two threat seats
  `+0xbc..+0xe0`, the `+0xac` byte and `+0xa4`/`+0xa8` -- and, first, `call 0x540cb0` at `0x53fb23`
  (`FUN_00540cb0`: hands `+0xa4` to `FUN_0055de60` when it is non-zero, then zeroes
  `+0xa4`/`+0xa8` itself; omitted here until round 564; the `+0x44` clear is unaffected) -- (its
  other callers: `Init` at `0x53f4e7` and the unnamed `FUN_00559140` at `0x55915a`). `leaveBattle` clears the brain's pick on every
  exit from BATTLE, the `0x23`/`0x27`/`0x2a` releases among them; until round 555 a pick armed but
  not fired -- a Yeoha that drew its range-7 176 at 60 units and lost its target on the way in --
  survived the exit and was swung in the next fight without a draw, so this bullet was true only of
  a monster that had never armed one. When the engine clears `+0x44` between two swings of ONE
  fight (at Execute, or at the action's end) is still not read, only that `Handler_0e8` reads the
  armed pick before it asks for a new one; the rest of `ResetThreat` has no counterpart in a brain
  (the threat table is mob-threat-retarget's; the target, one of the seats, is zeroed by IDLE's
  `OnEnter` through `SetTarget(0)`), and the cooldown is the action machine's and persists;
- **the `att` percent unapplied** (mob-monster-att-percent);
- **a zero-`att` skill lands 0**, pushed as a 0-damage `OpMonsterAttacked` (unblocked, no
  critical, the target's HP as found); OpenSRO has no status system for its `ps` param, and the
  client may draw the 0;
- **no `_RefAISkill` triggers**: the rows are server-database only, so every skill is an
  attack-list skill (mob-ai-skill-triggers);
- the failed-swing tail (no pick) is not modelled, as in round 546 -- no roster skill has chance
  0, so no roster monster reaches it. A monster that did (a list in which no skill has an
  `AI_AttackChance`) stands in BATTLE, neither chasing nor swinging, until the give-up check or the
  target's exit releases it (`battleTick` returns before the chase when `armSkill` answers false;
  noted in round 555).

**Trace line** (`OPENSRO_AI_TRACE`), for a species with more than one skill only: `ai: monster %d
arms skill %d (range %d) at %.0f`.

**Tests** (`cd server && go build ./... && go test -count=1 -p 1 ./...` green; re-run after the doc
edits): `session` -- `TestYeohaDrawsItsLongSkillAndSwingsFromAfar` (THE RED: seed 2 draws 177 at
60 units, weight 127 against 100; no chase leg, the blow at once for at least 94),
`TestYeohaDrawsItsShortSkillAndChasesToItsBand` (seed 1 draws 176: the leg to round(stop) of the
range-7 band at the run speed 20, no blow until in reach, then at least 67),
`TestWaterGhostZeroDamageSkillLandsNothing` (seed 21 draws 169 in the band: a pushed blow of 0 on
a monster whose flat Attack is 15, Aria untouched, the next swing on the 40th tick -- 169's 4000
ms -- and not the 39th), `TestMonsterStrikeRollsTheNamedSkill` (169 lands 0, 168 at least 47, no
skill the primary range, a monster with no range at all its flat Attack -- the hazard's control),
`TestBattleOffDrawsNoSkill` (the flag-off control: the hold, nothing armed, no run to the band, no
blow); `ai` -- `TestSkillChoice` (corrected: 30 + 3 for a 7.5 margin; the Yeoha at 60: 100 and
127), `TestPickByWeight` (r = 0..100 -> the first, 101..227 -> the second, 228 wraps; zero
weights skipped; -1 with none), `TestPickSkillDraws` (20,000 seeded draws split 101/228 : 127/228
to +-3 %; a Chance-0 skill never drawn; a single skill always -- the CONTROL); `cmd/server` --
`TestRosterSkillsAreReal` (every species' list against the tables' rows, the four two-skill
species counted), `TestRosterSkillsLeadWithThePrimary` (`Skills[0]` equals the primary fields),
`TestGMSpawnCarriesSkills`, `TestWriteMonsterSpecsForVerifier`; `combat` --
`TestGetReturnsLiveMonster` now compares with `reflect.DeepEqual` (a slice field). **Negatives,
proved four ways, each file restored and compared byte for byte**: (A) round 260's whole margin
put back in `SkillWeight` -- `TestSkillChoice` fails `weight 37; want 30 + 3` and
`TestPickSkillDraws` fails `ATTACK01 drawn 7754 of 20000, want about 101/228` (38.8 % under
100 : 155); (B) the draw neutralised to the col-83 skill -- the Yeoha long-skill test fails `armed
skill 176, want ATTACK03 177` and the Water Ghost test `armed skill 168, want ATTACK02 169`; (C)
the explicit zero removed from `monsterStrike` -- both zero tests fail with `Damage:18` (the flat
15 through the level term); (D) every production file stashed to BASE -- `ai`, `session` and
`cmd/server` fail to build (`undefined: combat.MonsterSkill`, `spec.Skills undefined`, ...).
Client untouched (`remote_godot.sh tests` not needed).

**Live check: not run.** The Go tests are the evidence. The optional run is round 546's command
with `OPENSRO_QA_ATTACK_NAME=Yeoha OPENSRO_QA_ATTACK_GOTO=1 OPENSRO_QA_ATTACK_RETREAT=60` and
`OPENSRO_AI_TRACE=1`: after the retreat a Yeoha that logs `arms skill 177 (range 100)` must
`strike` with no `BATTLE chase` leg before it, and one that logs `arms skill 176 (range 7)` must
chase to 22 first; every `strike` after an `arms skill 177` line is for 94 or more on an
unarmoured character.

**Deploy note.** Nothing to flip. The draw is live wherever `-monster-battle` is on; that flag's
own conditions (`deploy/README.md`, "Monster battle (off by default)") are unchanged.

## The area of interest, the paged list and the sleep (round 656)

Round 657 places every npcpos field row (about 10,200 monsters) under `-single-frame`, whose one
bucket is the whole world. Before this round every monster message went to every player in the
bucket and the list was one frame. Round 656 built what follows as OURS; **round 664 READ
retail's visibility rule** and the cell and the window are now retail's (the next section).
The rule for which objects retail runs is still UNREAD, so the sleep stays OURS. The code:
`server/internal/session/aoi.go`, `monsterlist.go`, `monsterai.go`;
`server/internal/combat/cells.go`.

**Cells.** `combat.Hub` files each live monster under `(zone, cx, cz)`, where `cx =
floor((x + 960) / 320)` and the same for z: one cell per retail message block (`combat.CellSpan`
= 1920 / 6 = 320, READ, next section), so the region lines (960 + 1920k, `worldmap.ToWorld`)
are cell lines and every cell line is a multiple of 320. (Round 656's cell was a whole region,
`floor((x + 960) / 1920)`.) A cell's numbers are relative to the frame, not the region's own x/y.
The spawn files a monster, a step that carries one over a line re-files it and reports a
`CellChange`, and a kill removes it. `InZone` reads the zone's cells. Only monsters on a leg are
stepped (a moving set).

**The window.** A player sees the monsters of the cells within `AOIRadius` = **1** of its view
cell, on both axes: the 3 x 3 message blocks around its own, a 960 x 960 square -- 320 to 640
units on each side of the player (READ, round 664; round 656's OURS window was 2 region cells,
5 x 5 regions, the client's `REGION_LOAD_RADIUS`). The runtime moves each player's **view** to
the cell it stands in every `AOITick` (100 ms, OURS, the AI tick) and on each list request.
With the runtime off (unit tests) the view is the cell the player stands in, read at each send.

| Message | Who gets it |
|---|---|
| `OpMonsterListResult` 0x0066 | the requester: the window's monsters, in id order, paged |
| `OpMonsterMotionList` 0x007F | the requester: the listed monsters' legs, at most 1,560 a frame |
| `OpMonsterSpawned` 0x007E (respawn, `/spawn`) | players whose window holds the monster's cell |
| `OpMonsterMoved` 0x007C, `OpMonsterAttacked` 0x007D | the same, by the monster's cell at the push |
| `OpMonsterDamaged` 0x0062, `OpMonsterDied` 0x0063 | the same, the attacker excluded as before |
| `OpMonsterSpawned` + `OpMonsterMoved` (enter) | a player whose window gained the monster |
| `OpMonsterLeft` **0x00B5** (leave) | a player whose window lost the monster |

**The paged list.** A frame's payload is at most `proto.MaxPayload` = 32,767 bytes (the Size
field's low 15 bits). A list that fits is sent exactly as before. A bigger one is sent as `pages`
frames, each an ordinary `OpMonsterListResult` with its share of the records followed by a
4-byte trailer:

```
u16 error_len (0) | u16 count | count records | u16 page | u16 pages
```

Pages go only to a client that asks for them. The `OpMonsterList` request carries one optional
byte (round 656's review):

```
OpMonsterList 0x0065 (client -> server):  [u8 flags]    bit 0 (0x01) = gathers a paged list
```

A request without the byte (every client before round 656: the payload was empty) is answered in
the old form: one frame, no trailer. When the window holds more than a frame's worth, it holds the
monsters nearest the player that fit (`monsterListNearestThatFit`). The rest of that window reach
such a client only as enter messages or not at all, which is degraded but never a closed session.
The client (`CombatNet.encode_monster_list`, `NetClient`, round 656) sends 0x01, collects pages
0..pages-1, and emits `monster_list_result` once, with every page's records. The list and its motion list are
written under the session's monster wire lock, as before.

**Enter and leave.** When a view moves within a zone, the player is sent the difference between
the old window and the new one: each monster of the cells it gained, as an `OpMonsterSpawned`
(the list record plus the monster's current facing, `combat.Hub.Facing`) followed by an
`OpMonsterMoved` from where it stands when it is walking; and one or more `OpMonsterLeft` naming
the monsters of the cells it lost:

```
OpMonsterLeft 0x00B5:  u16 n | n x s64 id        (at most 4,095 ids a frame)
```

A monster the AI's step carries over a region line enters or leaves the same way, for each player
whose window holds one of its two cells and not the other. The step and the computation of what
its crossings owe run as one step under the area of interest's read lock (`monsterAOI.step`,
round 656's review). A view that moved between the two had read the monster's new cell in its own
difference and then found no crossing to answer for, which lost an enter or a leave. A zone change moves the view without
messages: the client drops every body and asks for the new zone's list itself.

Enter and leave are **checked at the send**, under the session's monster wire lock: an enter goes
only for a monster that is alive and in the view's window at that moment (with the hub's record at
that moment), and a leave only for one that is not. Death, damage and the request paths' other
monster messages take the same lock (`sendMonsterPush`), so a death sent after the check can
never be followed by an enter for the dead monster. A blow's recipients are the players watching
the monster before it AND those watching where it stands after (`damageMonsterWatched`; the GM
`/kill` likewise). Otherwise a view that moved off a monster in between, whose leave then no
longer found the dead monster in its cells, kept a ghost. The spawn push goes through the same
checked enter (round 656's review), so it is never delivered to a view that does not see its
cell. A push's cell is taken from the monster's float64 position, never the float32 copy on the
wire.

**Legs and blows are checked too** (round 656's second review). The real client answers an
`OpMonsterMoved` for a body it does not have by asking for the whole list, at most every 5 s
(`World3D._on_monster_moved`). So the AI's pushes (legs, stops, blows) go to a watcher only if, at
the send and under its wire lock, the monster is alive, its cell is in the watcher's window, and
no enter for it is still owed (`mayShowLeg`). A view move marks the monsters it gains as
**pending** until their enter goes out, since the enter carries the leg. A list clears them.

**For every new monster-damage path (rounds 659, 660, ...):** call

```go
func damageMonsterWatched(hub *world.Hub, monsters *combat.Hub, id, attacker int64, amount int) (updated combat.Monster, died, ok bool, watchers []world.Entity, hits []combat.Hit)
```

(`server/internal/session/aoi.go`; round 657 added `attacker`, recorded through
`combat.Hub.ApplyDamageFrom` in the monster's damage list, and `hits`). Never call
`combat.Hub.ApplyDamage` or `ApplyDamageFrom` yourself. Send the damage or the
death to `watchers`, each with `sendMonsterPush` (under the monster wire lock). `watchers` are the
players watching the monster before the blow and after it, each once.
`TestMonsterDamageGoesThroughDamageMonsterWatched` fails on any call of the monster hub's
`ApplyDamage` or `ApplyDamageFrom` except the one inside `damageMonsterWatched` and the GM
`/kill` and `/damage` (`internal/gm/gm.go`). Every change -- a view moving, a monster
crossing a line, a list -- produces its own messages after it, so the client ends where the
server is whatever order two goroutines' messages reach the socket.

**The sleep** (`MonsterAIConfig.Sleep`, cmd/server's `-monster-sleep`, default on; OURS). A
monster whose cell is outside every player's window is neither stepped nor run. Its brain is made
the first time a player comes that near, and a brain whose cells are left behind keeps its state
and its leg and resumes when a player returns. A monster in BATTLE or HOMING never sleeps
(round 656's review): a chase or a run home is finished wherever it goes. With it off (the zero config: every test before
this round), every monster runs every tick.

*Round 666: the sleeping brain is dropped.* Until then a sleeping monster's whole brain stayed in
the runtime's map and every pass walked it, so a player who crossed the full map left one brain
per monster passed (66,000 measured by the release review, 13.2 ms a pass). Now a brain that falls
asleep is dropped and what it must keep is filed (`brainMemory`, `monsterai.go`): the state it
slept in (IDLE or WANDER -- BATTLE, HOMING and a monster its status holds are insistent and never
sleep), that state's entry time and dwell, the heading, the action machine's cooldown, tactics
timers 1 and 6, the aggression roll and a unique's damage total and triggers. The wake rebuilds
the brain from the monster (home, tactics, radii and detection are arithmetic over
`combat.Monster`) and resumes the machine in the filed state without an OnEnter
(`ai.Machine.Resume`, OURS), drawing nothing from the rng; a blow on a filed monster (a DoT
tick whose caster walked away) wakes it first (`wakeStruck`), so it engages as before. The strike worker is closed at the
sleep, and since the same round also when the monster leaves BATTLE; the next swing starts a new
one. Every rule here stays OURS.

**The respawn scheduler.** One goroutine checks every placement once a second, where there was
a goroutine and a ticker per placement (`maintainMonster`). The timing is the old loop's: the first
check after a death notes it, and the first check at least `respawnDelay` (10 s, disclosed OURS)
later hatches the placement again. Round 660 replaced the delay with the READ nest rules (next
section).

**The send deadline.** `gateway.Session.Send` gives up after `gateway.SendTimeout` (10 s, OURS;
2 s as first built, raised by the review so a client busy loading a region is not dropped).
A Send blocks only once the kernel socket buffers are full, which only happens with a peer that
has stopped reading. On the timeout the connection is closed, so the read loop ends and
OnDisconnect runs, and every later Send returns `ErrSendStalled` at once.

The deadline bounds one write, not a session. A peer that reads slowly but steadily finishes every
write inside it, while every writer that fans out to it waits on it write after write: the AI
tick, the respawn scheduler's spawn push, other players' blows. So each session also has a
**blocking budget** (`gateway.SendBlockBudget` = 10 s, draining 10 s per `SendBlockWindow` = 60 s;
OURS; 3 s per 30 s in round 656's second review, raised in its third so a client frozen by a
load is not closed. See WORLD_ISSUES round 656 §9 for the measurement). Every write's time on the socket adds to the session's debt,
the debt drains at 0.1 s a second, and each write's deadline is capped at what is left of the
budget. A session whose debt reaches the budget is closed. A reading client's writes take
microseconds, so only a peer that keeps the kernel buffers full runs its debt up.

**The send queue (round 662).** `Send` no longer writes: it encodes the frame (rolling byte and
checksum drawn in call order) into the session's outbound queue and returns, and the session's
own writer goroutine drains the queue to the socket, a frame per write (one write for the
lot wedged the real client over loopback: WORLD_ISSUES round 662 §4; a frame per write only
mitigates that, the client's reader is fixed in round 663). The deadline and the budget above are now
that writer's, so the AI tick, the respawn scheduler, other players' blows and every broadcast
never wait on a peer. Frames reach the wire in the order `Send` was called; the wire lock keeps
its meaning (a check and its send are one step, and queue order is wire order), and
`SendBatch` queues a multi-frame sequence -- the paged list with its motion pages, a monster's
enter with its leg -- so that no other frame comes between. A session is also closed when its
queue would pass `gateway.SendQueueLimit` (OURS, sized from a live measurement: WORLD_ISSUES
round 662). When a session ends, what is queued is written out for up to
`gateway.SendDrainTimeout` (2 s, OURS) before the connection closes, so a frame sent just before
a handler's error still arrives; the writer then exits and the queue is freed.

**Measured** (`BenchmarkMonsterAITick`, 12,000 monsters over a 40 x 30 grid of regions in one
bucket, players on real TCP; i7-13700K; the same file run against the base with a no-op setup):
see the round's WORLD_ISSUES entry for the table. The players never move in it, so it measures no
view moves or player-driven enters and leaves.

## What a player is sent: retail's message blocks (round 664)

READ from SR_GameServer.exe (the decompile in `/var/tmp/decomp_server`, objdump for the
constants), round 664. The chain, bottom up:

- **A field region holds 6 x 6 message blocks.** The `CRgnTerrain` constructor
  (`CMainProcess::FUN_0053a850` 0x53a850) builds `_eh_vector_constructor_iterator_(this + 0xb,
  0x98, 0x24, ..., CMsgBlockTerrain::FUN_005377b0)`: 0x24 = 36 `CMsgBlockTerrain` of 0x98 bytes
  at +0x2c. `CRgnTerrain::vslot_012` (0x53a820) indexes them `(x + z * 6) * 0x98 + 0x2c`.
- **A block is 320 units.** `CRgnTerrain::vslot_006` (0x53ad30) asserts a region-local position
  in [0, 1920) (the double 1920.0 at 0xb45ad0), divides both coordinates by the double at
  0xb45ae8 -- **320.0** (0x4074000000000000; `fdiv st(1),st` at 0x53ad90) -- truncates each
  (0x9fbb40), asserts each index 0..5 (0x53ada2..0x53adb0) and returns the block. Region-local
  x and z, so the blocks are aligned with the regions.
- **Each block is linked to its 8 neighbours, across region lines.** `CRgnTerrain::vslot_016`
  (0x53ab90) walks the 6 x 6 blocks and, for each, the 8 `(dx, dz)` pairs of the table at
  **0xc64090**: (-1,-1) (0,-1) (1,-1) (-1,0) (1,0) (-1,1) (0,1) (1,1) (read back with objdump:
  `ffffffff ffffffff 00000000 ffffffff 01000000 ffffffff ffffffff 00000000 01000000 00000000
  ffffffff 01000000 00000000 01000000 01000000 01000000`). `CRgnTerrain::FUN_0053ac20` finds the
  neighbour block: the neighbour region by `CRgnTerrain::FUN_00430900` (0x430900: (dx, dz) in
  [-1, 1] -> region link 0..8, 8 itself, asserting |d| <= 1) and the block `((i + 6) % 6, (j +
  6) % 6)` in it (its vslot 0x30). Each is added with `CMsgBlock` slot 5 (0x5336e0) to the
  block's neighbour list at +0x10. `CRgnTerrain::vslot_014`/`vslot_015` link the regions
  (`"LINK_REGION ERROR [(%d,%d) -> (%d,%d)]"`).
- **An object's messages go to its block and those 8.** Putting an object into a block,
  `CMsgBlock` slot 2 (0x534340), walks the block's neighbour list and then the block itself,
  and for each: if the object is a player, `FUN_00533e70(1)` sends it that block's objects (the
  group spawn: 0x3017 begin, the data frames, 0x3018 end, 0x533e70 -> 0x533910 / 0x533b90), and
  `FUN_00533f70` (0x533f70) announces the object's spawn **0x3015** to that block's players
  (`FUN_005341e0` -> `FUN_005342a0`, `CAgentMsg__AddtargetClient` per player). Taking it out,
  slot 3 (0x5344b0), sends **0x3016** (`FUN_00534050` 0x534050, the object's id) to the same
  nine blocks' players. With their third argument set, both slots walk instead a list looked
  up in a map at block+0x1c (`FUN_00666520`) -- INFERRED to be a move between two blocks, sent
  only to the blocks the two windows do not share; not traced further.

So: **a player holds the objects of the 3 x 3 blocks of 320 around the block it stands in** --
a 960-unit square, reaching 320 to 640 units from the player on each axis depending on where in
its block it stands. OpenSRO: `combat.CellSpan` = 320, `session.AOIRadius` = 1
(`TestAOIWindowIsRetailsMessageBlocks`).

Round 786 re-read the chain (the block division at 0x53ad30 with 320.0 at 0xb45ae8, the
neighbour table at 0xc64090, slot 2's neighbour loop at 0x5343b8..0x534419) and measured the
runtime against it on the full map (67,266 monsters, `partybot -mode latency`): every enter came
320-621 units ahead of a bot running at 105 units a second, 27-96 ms after its block crossing --
one `AOITick`. The late monsters of the user's report were the client's
(`docs/protocol/spawn_attack_latency.md`).

Not read, OPEN: whether any object kind is sent from farther (a unique, a structure); the
`CMsgBlockObject` blocks of the object regions (dungeons, `CRgnObject`), whose layout was not
followed; the rule for which objects the server RUNS (the sleep stays OURS).

**The client draws what it holds** (READ, sro_client.exe, round 664): the per-frame entity
list (`CEntityManagerClient::vslot_011` 0x9c4770) lists every object once a frame; the object
draw slot (`GlobalDataManager::FUN_009c4aa0` 0x9c4aa0) tests the view frustum (the view's
vslot 0x14) and, when graphics option 0x17 is on, passes a LOD factor -- the object's vslot 0x44
divided by the double **800.0** at 0xd83080 (`fdiv` at 0x9c4c05) -- to the model's draw
(vslot 8), with a GM log line `"[%s] LOD Level Change [scale : %f ] (%d) => (%d)"`. That is a
mesh LOD (the draw indexes `pFDB->Indices[iLOD]`), not an animation one; OpenSRO has no LOD
meshes (OPEN). No distance test on posing a character was found; OpenSRO's animation LOD
(`MonsterCrowd.pose_interval`) is OURS.

## Nests on the map (round 660)

Round 660 places every field monster row of npcpos as a NEST and runs the engine's hive pass over
them (`server/internal/nest`, cmd/server's `-full-map`). The numbers come from the user's shard DB
(`-nest-db-dir`, EXTERNAL: "External shard DB" above) where a row joins one; every other placement
is a stand-in nest (OURS). What was READ this round, beyond rounds 238-241:

**Aggression: column 7 = 0 is aggressive, 1 passive (re-read).** `AI::CTactics::Init` (0x53f4d0)
copies the row's `+0x18` into ctx+0x168 (mode 2 rolls it: `pct <= rand() % 100` makes it 1), and
`AITactics_AcquireTarget` (0x5478f0) scans only while that byte is 0 or 3 (`*(char *)(ctx + 0x168)
== '\0' || == '\x03'`, the decompile, and 0x547958..0x547964). So `btAggressType` 0 is
aggressive and 1 passive, as round 552 recorded. (The round-660 brief's planning notes read the
DB the other way round -- "~31 % aggressive (mode 1)"; the code settles it.) Of the 4,068 placed
matched nests (round 660's review: rarity 8 left out), 2,491 run an aggressive row and 1,577 a
passive one (EXTERNAL), and the pattern reads as
retail play does: Jangan's Mangyang nests run a passive row (their champion row is aggressive), and
across the map a base species' row is aggressive where its `_CLON` is passive (MEASURED, round
660's census). Passive does not mean harmless: `CAIState::OnAttacked` (0x558ea0) engages any
monster that is struck, with no aggression test.

**The hatch spot: `nGenerateRadius` is a scatter ring.** Nest_Hatch pushes the nest row's
column 10 as a float (`fild [esi+0x24]` at 0x560c51) and 0.0 (`fldz` 0x560c37) into the spawn
routine `GObjPC::FUN_005f6eb0`, whose first call (0x5f6f1b) is `GObjPC::FUN_00531240(radius, ?,
min)` on the nest's position:

    radius <= 1e-6 (float 0xb45c84 = 358637bd)  -> no offset
    r = max(radius, 1.0) ; third = r / 3.0         (QWORD 0xb45ab8 = 3.0)
    roll = rand() % 101
    base = roll < 70 ? 2*third : (roll > 89 ? 0 : third)   (`cmp edx,0x46`, `cmp edx,0x5a`)
    d = rand()/32767.0 * third + base ; d = max(d, min)    (QWORD 0xb45af8 = 32767.0)
    a = rand()/32767.0 * 2pi + 0.0                          (0xb45c18 = float32(2pi), 0xb45ab0 = 0.0)
    x += FUN_00489490(a) * d ; z += FUN_004894b0(a) * d

So 70 of 101 hatches land in the outer third of the circle. The two trig helpers are taken as cos
and sin (INFERRED; the spread is the same either way). `nest.HatchOffset`. The monster's HOME --
what the roam radius and HOMING measure from -- stays the nest's own position (Attach's ctx+0x1b4),
not the hatch spot (`combat.Hatch`).

**The field world clamps the class by level.** The spawn reaches `CGameWorld_Default` slot 6
(0x5eb9a0, the unstripped base the field world runs, round 658), which rewrites the class byte by
the species' level (refChar+0x198) before the object is made (asm 0x5eb9f3..0x5eba7e, a switch on
level/10 through the table 0x5ebf14 = 5eba3e/5eba48/5eba57/5eba6a, whose cases fall through):

    level <= 10 and rank 4 (giant) -> rank 1 (champion), party nibble kept   (`and bl,0xf1; or bl,1`)
    level 0-9  : party dropped
    level 0-19 : party dropped unless the rank is 0
    level 0-29 : party dropped unless the rank is 0 or 1
    level 0-39 : party dropped unless the rank is 0, 1, 4 or 6
    level 40+  : unchanged

`nest.ClampClassByLevel`. Nest_Hatch's own disarm (`nest+0x30 = 0`) reads its roll from before the
clamp.

**The party roll's species test.** `FUN_00561020` is the TID-word shape `(w & 2) && (w & 0x1c) == 4
&& (w & 0x60) == 0x40 && (w & 0x780) == 0x80 && (w & 0xf800) == 0x2000` -- TypeID (1,2,1,4): a
species whose TypeID4 is 4 never hatches as a party monster. 17 of the 249 field species are.

**Which pass a hive runs.** `AIHive::Init` (0x55e5b0, named `CMainProcess::Init` in the dump)
installs both passes and sets hive+0x30 = 1 when the row's `dwOverwriteMaxTotalCount` is non-zero
(0x55e73d): such a hive runs `AIHive_HatchPass_TotalCapped` (0x55ec10), which hatches while the
hive's alive count is under that cap, from its pinned nest (+0x3c) alone when one is pinned, else
from each nest in turn with only the timer and alive-cap tests (no col16/col17/budget test), and
stops as soon as the cap is reached. Every other hive runs the plain pass. On the shard, 10 hives
of the placed nests carry a cap (80-130); the unique rotation is the capped pass with a cap of 1 and
a pinned nest (round 661).

**Not modelled, disclosed.** The level > 110 refusal under `FUN_005f9930` (a config test); the
event-monster substitution list (`DAT_00d6a9b4`, `FUN_005f85a0`); the placement's navmesh query
(the spawn routine's `[cc387c]+0x30` call at 0x5f7068, whose bit 0 is Nest_Hatch's out-flag 1 and
halves the delay) -- OpenSRO has no server-side navigation mesh, so no placement fails, and
`nest.HalvedDelayMs` is exercised by a test only; the hive population rate (col 2 = 1, 2,355 of the
placed nests' hives: it only shortens a 1-3 s window, and its region sample is unread); column 39
`btAggressTypeOnHoming` (no reader found) and column 9's retarget rule (the threat table has no hate
values yet).

**What the runtime does** (`internal/nest`, `cmd/server/nest.go`). One goroutine runs the pass
every 250 ms (OURS; the engine's hive tick is unread): drain the hub's death log
(`combat.Hub.LogDeaths/DrainDeaths`) into `Scheduler.Died` (the first loss out of a full nest
stamps the timer), then `Scheduler.Pass` (one hatch per due nest), then the spawn push for each new
monster (through main's `spawned` hook, which also announces a unique hatched from a nest). A
matched row's slot is its nest: cap col 14, window cols 12/13 (1-3 s on 3,513 of the placed nests,
8-12 s on 459; `-nest-respawn` overrides every window), generate radius col 10, champion chance
col 11, tactics its row with the nest's col 9 as the roam radius, the champion row col 41. A row
whose nest the shard repointed to another species keeps the npcpos species and runs its own
tactics row when it has one (`DB.OwnTactics`: the lowest-id row that is no row's champion row;
OURS), else the stand-in behaviour -- and, by the user's decision in round 660's review ("Use the
DB nest numbers"), that nest's own cap, window, radius, generate radius and champion chance
(EXTERNAL), the champion roll gated by column 41 of the row the monster runs; the nest's hive cap
is not applied. The 6,041 such nests (MEASURED): caps summing to 37,360, windows of 1-3 s on
4,835, champion chance 10 % on 4,522. `-nest-swapped-stand-in` (OURS) falls back to the stand-in
nest: one monster, `respawnDelay` (10 s) at both ends, no scatter, roam radius
`MonsterRoamRadius`, no champion roll.

**The join, one row per nest** (round 660's review). Every (row, nest) pair within
`JoinTolerance` is ranked -- the row's own species first, then the nearest, then the row's and the
nest's order (OURS) -- and taken greedily, so no nest is claimed twice: the shard has co-located
nests (three at one point under SD_OSIRIS/MUMMY_RAGE/MUMMY_HUBRIS, two under SD_MONTKILLER and
SD_HIKE, two 0.713 from a MOB_KK_PLANAR row), and the first version let MONTKILLER and HIKE both
claim nest 29723. Rarity 8 is left out with rarity 3: both are unique-class (`combat.
RarityHPPercent`'s `case 3, 8`). The brain (`session/monsterai.go`) reads the row in
place of `internal/ai`'s stand-in constants: sight (col 6), aggression (7/8), the chase switch and
give-up distance (35/36), the roam rule (37), the reach rule (40, `ai.TargetOutOfReach`) and the
scan's fast-timer bits (42).

**The kill's party count** (`session/nestkill.go`). The engine hands its death command the count of
the killer's exp-sharing party members that are alive and within 1000.0 units (GObjPC::
FUN_005bca60; the double at 0xb45c68), and `FUN_00558f20` arms the nest when it is above 1. The
range is measured from the dead monster (INFERRED: the object FUN_005bca60 shares experience out
of). OpenSRO counts the members in the world, alive, in the monster's zone, on the ground plane.
**(round 709)** ~~INFERRED: the dead monster~~ READ: the range is measured from the **kill credit**
(the biggest hitter of the most-damaging group, `0x5bcacb`-`0x5bcb29`), same world, horizontal with
1920-unit region steps; only an exp-share kill arms (a free-for-all kill leaves the count at 0,
`0x529e0a`); instance worlds gate on `PARTYMONSTER_SPAWN`. OpenSRO's count still differs on all of
these (`docs/protocol/party_rules.md`, "Party monsters", gap 12).

**The wire: the party flag.** Retail sends one class byte, `rank | party << 4` (CICMonster::
vslot_025 0x9d3850: `and cl,0xf` to +0x7ac at 0x9d38e1, `shr al,4` to +0x7ad at 0x9d38e7).
OpenSRO's list record carries the rank in a u32 already, so the party flag rides in bit 8 of that
word (`session.MonsterRarityPartyBit`, OURS) -- in the list, the spawn push and the area of
interest's enter -- and only to a session whose list request set bit 1 of the capability byte
(`MonsterListFlagParty` 0x02). An older client is sent the rank alone.

**The client** (READ, sro_client.exe): the model scale starts at 1.0 (`fld1` 0x9d38c9) and a
switch on class - 1 (0x9d3995, table 0x9d3c70) multiplies it: champion 1.5 (0xd819ec), giant 3.0
(0xd8adc4), elite 1.7 (0xde2818); everything else keeps 1.0 (`MonsterDraw.class_scale`). The
overhead name's colour does not depend on the class (no colour write in 0x9d0a80 reads +0x7ac or
+0x7ad); class 7 alone prefixes UIIT_STT_MOB_STRONG ("Elite"). A party monster gets
`icon\item\etc\europe_partymob.ddj`, 16 x 16, 20 px left of its name box, top-aligned (vslot 15
0x9d3e70, the test at 0x9d3f2a; OpenSRO sizes it to its own plate's line height, OURS), and its
target window's rank row gets UIIT_STT_PARTYMOB_TARGET's text appended with no separator (0x69b834,
"Champion(Party)").

## The overhead name: shown within 300 of the player (round 673)

READ (sro_client.exe). CICharactor's name pass is `FUN_009d0a80`: it projects the head point
(position + height + 2.0, or a rider's + 7.0, 0xe1b898 / 0xda7c60 as doubles) through the scene's
camera (`DAT_0110f7ec` vslot 0x84), calls the object's vslot 15 with pass 4 (the screen-space
overlay; CICMonster's is 0x9d3e70, which adds the party mark) and draws the name with
`FUN_008b4d90(point, 0xff)` -- full alpha, no fade, in screen space over the scene. Its one distance
test, at 0x9d0ac3: unless the object's `+0xf0` is set, it returns when `300.0 <= object+0x24c`
(float 0xd85224 = 300.0). `+0x24c` is written at 0x9d6f7e by `CICPlayer::vslot_005` (0x9d6c80,
message 0xd) as it walks every object of the entity list (0xec4ae4, node - 0xdc): the square root of
the summed squared x, y, z differences between the LOCAL PLAYER's position (+0x90..+0x98, loaded at
0x9d6ea1) and the object's. The constructor (0x9c2340) starts it at 1000.0 (0xda95ec), so a new
object's name is hidden until measured. The same walk writes `+0xd0`, the distance from the point at
`[0x110f7d0]+0x340` (unread; the camera, INFERRED). The small over-head HP/MP gauge is vslot 38
(0x9d0da0), drawn only under option flags (FUN_00b94b90 on 0xeef6f0 / 0xef1a84 / 0xef1bc0) and
behind the same 300 test (`FUN_009cef40`).

NOT read: what `+0xf0` is; the pass's other early returns (a vcall at +0xb0 on FUN_009edd60's
object; the bits `+0xd4 & 2` and `+0x464 & 2`); the global byte 0xec4b58 the overlay pass is drawn
under. OpenSRO: `NamePlates` (client/scripts/world/name_plates.gd) shows a plate while its owner
is within 300 of the player, tested a sixth of the plates a frame (OURS); before round 673 the
plates hid at 80 from the CAMERA (OURS), which is why a monster's name came and went with the
camera's pitch and zoom.

## The unique rotation and the minions (round 661)

Labels as everywhere here: READ (SR_GameServer.exe: `/var/tmp/decomp_server`, `/var/tmp/srv.asm`
and `objdump -s` of the executable on the render box), MEASURED, INFERRED, OURS, and EXTERNAL for
the rows of the user's shard DB (the Eternity backup, round 658).

### The rotation (READ)

A unique's hive (EXTERNAL: one per field unique, `dwOverwriteMaxTotalCount` 1, one nest per npcpos
spot, cap 1, `btRespawn` 1, the window below) runs the capped pass (`AIHive_HatchPass_TotalCapped`
0x55ec10) with a pinned nest (hive `+0x3c`):

- **At build**, `CMainProcess::FUN_0055efe0` (asm 0x55efe0..0x55f077; stored by its caller 0x54bd7d
  at hive+0x3c): with the hive row's `+0x08` (col 3) equal to 1 and n nests, the only nest when n is
  1; for n >= 2 it throws `abs(rand()) % n` (0x55f041) and returns NULL -- `k == 0` jumps straight
  to `xor eax,eax; ret` (0x55f049), and the search loop re-enters at `add eax,1` (0x55f051), past the
  `cmp eax,edx; je` (0x55f04d), so it never matches and falls out at 0x55f05f. No pin: the capped
  pass hatches the first due nest in hive order, and every stamp is 0 at build (0x54bd2f), so the
  unique's first appearance is nests[0] (`nest.PinAtBuild`). *Round 661 first read this as
  `nests[abs(rand()) % n]`; corrected in its review.*
- **At a death out of the full hive**, `AI::CNest::FUN_0055eec0` (asm 0x55eec0..0x55efce): only for
  a capped hive (`+0x30 == 1`, which `AIHive::Init` sets for a non-zero col 3) whose alive count
  equals its total before the decrement:

		k = abs(rand()) % (n + 1)          ; div by n+1 (0x55eefd)
		if k >= n - 1: k = n - 1           ; `cmp edx,eax; jb` (0x55ef02)
		for i, nest in nests:
		    if i == k and row+0x08 == 1:
		        hive+0x3c = nest ; RollHatchDelay(slot)     ; 0x55ef77, 0x55ef7a: thrown, then overwritten
		    RearmHatchTimer(slot)          ; 0x560e50: stamp = now, base = RollHatchDelay

  so the unique moves to `nests[min(rand() % (n+1), n-1)]` -- the last nest twice as likely as any
  other, kept -- and EVERY nest of the hive, in any capped hive (not only a total-1 one), waits a
  fresh uniform window from the death (`nest.Repin`). `RollHatchDelay` throws a die only when the
  window's ends differ (`cmp esi,edi; ja` 0x560395).
- A nest row's direction faces a rank-3 hatch (Nest_Hatch 0x5609bf), and the unique hatches up to
  the nest's generate radius from it like any hatch (0x531240).

**Windows (EXTERNAL):** 1,200-1,400 s for 1954 TIGERWOMAN, 1982 URUCHI, 2002 ISYUTARU, 5871
KERBEROS and 14936 IVY; 2,100-2,200 s for 3810 BONELORD and 3875 TAHOMET. Spots (npcpos, READ;
every one joined to its own species' nest within 0.0002 units, MEASURED): 11, 11, 11, 10, 6, 13, 8.
The `_STR` twins' hives (43969-43975, EXTERNAL) stand on the same spots under custom species and
are never placed. `-unique-respawn` replaces the window (OURS, testing).

**The field world builds only its own hives.** `CMainProcess::CreateHivesForWorld` 0x54b8d0 builds a
world's hives from the rows whose GameWorldID (+0x1a) is that world's (READ, round 241). The field
world is `INS_DEFAULT`, id 1; the 90 field-coordinate npcpos rows of the Pharaoh temple -- the SD
elites and the fifteen bosses (SPHINX, SEKHMET, NEPHTHYS, HORUS and OSIRIS in three variants each:
fourteen of rarity 8, OSIRIS_3 of rarity 3) -- all join nests of hives in worlds 57/58/59, `INS_PHARAOH_NOVICE/EXPERT/
MASTER` (EXTERNAL, `_RefGame_World`), in separate region blocks (y 114-124, x 179-196), each boss one
nest of cap 1 on a 10,800 s window in an uncapped hive: no rotation. None of them hatches in the
field world. MOB_SD_APIS (rarity 8, region 74/73) has no nest of its own in the DB; the only nest
on its spot is the shard's custom DEADWARRIOR at cap 0 (EXTERNAL) -- its real nest is unknown, so it
is not placed. Rank 8 is not announced: both notice gates compare the rank with 3 (`cmp al,3` at
0x5f71d4, spawn, and 0x4c1ccb, kill).

### The selector (READ)

`AI::CTactics::BindSkillsAndRanges` picks the AI-skill selector by TacticsID (immediates, asm
0x53f7bd..0x53f8cf): 0x71, 0x9a, 0xb9 -> `CAISkill_Unique_Summon_B` (0x562330); 0x21, 0x3f, 0xe5,
0x67e8, 0x8084, 0x80e8, 0x814c, 0x81b0, 0x8214, 0x82dc -> `Summon_A` (0x561f20); 0x970e, 0x9722 ->
`Summon_C` (0x5626d0); any other keeps `CAISkill_Basic`. The shard's uniques run 33 TIGERWOMAN, 63
URUCHI, 229 KERBEROS, 26600 IVY (A) and 113 ISYUTARU, 154 BONELORD, 185 TAHOMET (B) -- exactly the
ids in the code (EXTERNAL rows, READ ids).

Registration, each of the owner's skill columns in order: a skill with a `_RefAISkill` row under
the tactics is a trigger (every selector's `param_3 != 0` branch); else a skill with an `ssou`
block goes to the summon store; else to the attack list.

- `Summon_A::RegisterSkill` 0x562060: slot by AI_AttackChance / 100.0 against 0.2/0.4/0.6/0.8
  (0xb45be8/be0/bd8/bd0): < 0.4 -> 3, < 0.6 -> 2, < 0.8 -> 1, else 0, into a vector of four
  (resized by 0x562e80); a taken slot keeps its first skill and the later one is dropped from both
  lists (`jne 0x56219c`). Cerberus's R1_00 and R2_20 are dropped (MEASURED).
- `Summon_B::RegisterSkill` 0x562470: every `ssou` skill appended to the list at `+0x5c`.

**The pick** (`Summon_A::PickSkill` 0x5621b0, `Summon_B::PickSkill` 0x562570, before the Basic
pick): the context's damage total `ctx+0xb0` (`AITactics_CreditAttacker` adds each blow's damage)
over MaxHP (slot 68, at least 1) times 100.0, as a float, `>= 10.0` (0xb45b44, `fcomp; test ah,5;
jp`). Then the HP bucket (`AITactics_HPBucket` 0x541d70 -> 0x541fd0: < 0.2 -> 0, < 0.4 -> 1, < 0.6
-> 2, < 0.8 -> 3, else 4):

- A (jump table 0x562310): bucket 4 -> slot 0, 3 -> 1, 2 -> 2, 0/1 -> 3; an empty slot falls to
  the Basic pick.
- B: `rand() % 1000 < 500` picks set offset 0, else 4 (0x56261f..0x56263a); jump table 0x5626b4:
  bucket 4 -> index 3, 3 -> off, 2 -> off+1, 0/1 -> off+2 -- the uniques' "R1"/"R2" skill names.

The armed skill is used like a swing; slot 6 (`FUN_00562540`, reached through the tactics' wrapper
0x540cf0 from the command handler 0x558f70) zeroes `ctx+0xb0` when the used skill has an `ssou`
block. **So a unique summons each time it loses another tenth of its MaxHP**, with the skill its HP
bucket names -- about nine times a kill (A: 90 and 80 % slot 0, 70 and 60 % slot 1, 50 and 40 % slot
2, below slot 3) -- not once per bucket as the brief had it.

**The triggers** (`_RefAISkill`, EXTERNAL rows; rules round 260): the only field unique with one is
Captain Ivy, `MSKILL_AM_IVY_ATTACK05` type 0 at 50 % -- fired once a life when her HP falls to half,
and never drawn otherwise.

### The executor (READ, FUN_00596e50)

Reached from EngageSkill when the caster is a monster and the skill's `+0x354` is set. `+0x354` is
the cursor the Param parser stores just past the `ssou` code word before returning (0x5890cb..
0x5890e5), so the tuples are the Param words after `ssou`: nine at most, 16 bytes each,
`{refObjID, class (low nibble), min, max}`. Per tuple with a non-zero id (the id must be a monster,
TypeID 1/2/1, else assert):

	radius = rand() / 32767.0 * float(2 pi) + 0.0         ; 0xb45af8, 0xb45c18, 0xb45ab0 -- thrown first
	n = min + abs(rand()) % (max - min + 1)               ; max < min asserts
	n > 50 -> log "Oooops!!!! Spawn Monster Count is over 50!!!!" and n = 50
	n < 1  -> nothing
	n times: spawn routine 0x5f6eb0 at the unique's position (its vslot 0x14), class, announce 1,
	         ring radius `radius`, minimum = unique slot 344 (0x560, BCRadius) + 30 + minion +0xee (BCRadius)
	         then the minion's command 0xb {2, unique id}

The spawn routine's 0x531240 gives each minion its own angle and, with the radius at most 2 pi,
the minimum as its distance: every minion stands exactly BC + 30 + BC from the unique. The spawn
routine goes through the world's slot 6 (0x5f6eb0 -> `[vt+0x18]`), the field world's class clamp
0x5eb9a0. Special cases by code name (MOB_RM_WINGTRIBEKNIGHT / MOB_RM_TAHOMET_ROC only log;
MOB_SD_HAROERIS / MOB_SD_SETH swap to their `_SUMMON`/`_DROP` rows) touch no field unique.

**The binding**, command 0xb -> `CAIState` slot 14 (0x5591b0, every state's): the object must answer
slot 62; `ctx+0x14c` = its id (the leader); kind 2 calls the tactics' slot 19; `ChangeState(1)` IDLE.
The leader biases a WANDER leg toward it (`PickWanderLeg`, 0x5459f0..0x545a50) and is tested by the
behaviours 0x5487b0/0x5488b0 (distance tests; not modelled). **Nothing removes a minion when its
unique dies:** the executor keeps no list, and the only sender of the unbinding command 0xc
(`CAIState` slot 15, 0x559260) is the pet path (0x4d2109; two probes -- the decompile's
`0x1c))(0xc,` pattern and an asm scan for `push 0xc` before a register call through `[..+0x1c]`).
A minion never respawns: it has no nest.

**The counts (MEASURED, re-verified).** The tuple layout is right: across the client's 292
`ssou` skills, 309 tuples carry real counts (the Qin Shi tomb guardians' `{id, 0, 3, 3}`, `{id, 1,
1, 1}`, ...). The seven field uniques' 130 tuples (123 once Summon_A's two dropped skills are left out) read 0..0 but two: Cerberus's Ladon (5866) 2..3 in
R1_80 and 1..2 (class 6) in R1_40. The executor spawns nothing for a 0..0 tuple -- `n = min +
abs(rand()) % (0 + 1) = 0` (0x597060..0x59707f), then `test esi,esi; jle 0x597844` skips the spawn
loop (0x59776b) -- after throwing its radius and count dice. OpenSRO does exactly that
(`nest.ExecuteSummon`): **only Cerberus summons**, its Ladons; the other six use their summon skills
and nothing appears. (Round 661's first commit gave 0..0 tuples a 2..3 stand-in; the review removed
it -- the "decision" behind it was a planner's proposal.) The DB's `_RefSkill` blocks are the client's word for word for every unique's
summon skill (286 of the 292 `ssou` skills identical; the six that differ are none of theirs), and
`_RefAISkill` carries no counts, so nothing replaces the stand-in.

### OpenSRO

`internal/nest` (`PinAtBuild`, `Repin`, the join's rotation spots and world filter, the summon
loaders and executor arithmetic), `internal/ai` (`HPBucket`, `SummonDue`, `SummonAIndex`,
`SummonBIndex`), `session/summon.go` (the damage total read off the HP, the pick before the draw,
the summon on the swing's cooldown with no reach, the minions pushed after the pass) and
`cmd/server/unique.go` (the selector's filing, the minion species with their own DB tactics).
Not modelled: the leader's behaviours and WANDER bias, `Summon_C`, the periodic trigger's
phase-alignment, the summon's cast push to the client.

## Towns: a monster that walks into one is removed (round 674)

The user (2026-10-01): "There should also be safe zones in towns but I had a mob follow me into town
and attack me. I think they usually disappear if they follow you into safe zone but check the game
logic." The game logic, READ from SR_GameServer.exe (`/var/tmp/decomp_server`, `srv.asm`), agrees
with the guess: the monster disappears.

### What a town is (READ)

- **`_RefRegion.IsBattleField`.** The row parser `0x6a2e40` (refdata_tables.md's `wbbbdddd` row,
  11 columns, 3 strings, record 0xb0) stores `wRegionID` at `+0`, steps over the X and Z bytes
  (cursor advanced, nothing stored), reads ContinentName and AreaName, then stores the **sixth
  column's byte at `+2`** (`*(byte*)(edi+2)`), Climate resolved into `+4`, MaxCapacity `+8`,
  AssocObjID `+0xc`, AssocServer `+0x10`. A field region (`CRgnTerrain`) keeps its row at
  `region+0x10` (`CMainProcess::FUN_0053b6f0` builds the regions from the rows;
  `FUN_0053b540`'s "Region has no assigned RefClimate! REGIONID[%d]" prints `*(short*)region[4]`,
  the row's id). Every town test in the binary reads `*(char*)(*(int*)(region+0x10)+2)`.
- **The towns are IsBattleField 0.** The client's `server_dep\silkroad\textdata\refregion.txt`
  (UTF-16, 21 columns, identical to the server package's `SR_GameRefData\refregion.txt` on the box,
  MEASURED by diff) has 3,194 rows, **103 with IsBattleField 0**: area names `Town_Jangan` (6:
  97/167-169, 98/167-169), `Town_Dunhwang` (4), `Town_Khotan` (7), `Town_Cons` (21), `Eu` (2, by
  Constantinople), `Town_Samarkand` (4), `Town_Thief` (1), `TOWN_ARABIA`/`TOWN_` (22), `town_Alex`
  (36). The id is `x << 8 | y`, `worldmap.RegionID`'s packing (25000 is 97/168, the Jangan square).
- **Not regioninfo.txt.** The game server parses the same `#TOWN`/`#FIELD` file the client uses
  (`RegionManagerBody::FUN_0098be30`, "regioninfo.txt", kind 2 for `#TOWN`), and
  `CRegionManagerBody` slot 23 (`0x98d040`) answers "is this position in a town" from it -- but no
  game code calls slot 23: the region manager's global (`DAT_00cc387c = &DAT_00d67c80`, vtable
  `0xb431fc`) is called through slots `0xc`-`0x7c` and never `0x5c`, in the decompile or the asm.
  The server's town is the `_RefRegion` byte.

### What a monster does there (READ)

- **`CGObjMob::SetCurRegion`** (vtable `0xaeddac` slot 235, `0x4c1270`, the whole function):
  `this[0x4a] = region; if (region == 0 || region.row[+2] == 0) this->SetLifeState(3, 0xff, 0)`.
  (`CGObjPC`'s slot 235, `0x4e6fe0`, stores the region and sends the player `0x3809`; no removal.)
- **Life state 3 is removal.** `CGObjChar::SetLifeState` (`0x4a9c80`) broadcasts only the 1<->2
  changes (`GObjPC::BroadcastStateChange`); for 3 it calls slot 4 of the object at `this+0x188`
  (unread) and stores the byte. The main loop (`CMainProcess::FUN_00413b30`) finds each character
  in state 3, calls its slot 390 and, for a non-player, `FUN_00417090`, which queues the object's
  deletion. The same state is how a monster's lifetime ends (`CGObjMob::Update` `0x4c1700`: the
  countdown at `+0x1ce0`, the timers at `+0x1cec`/`+0x1cf4`, the Pandora box). So: **no death, no
  experience, no drop, no corpse**. The players around it are told it left by the deletion's
  block removal (READ, round 677): `FUN_00417090` -> `FUN_00489fc0` -> slot 0x354
  (`CGObjMob::ReleaseAndClear` 0x4c0eb0) -> slot 0x358 (0x4c10b0 -> `CGObjChar::vslot_214` ->
  `CGObjMobile::vslot_214` -> `CGObj::vslot_214` 0x484a80) -> slot 0x364 (the leave-world,
  0x485150) -> slot 0x3b0(0, 0, 0) (CGObjMob's 0x4c1e00 -> 0x485bb0) -> the block's slot 3
  (0x5344b0) -> `FUN_00534050`: **`0x3016`**, the despawn, to the players of the nine blocks. The
  client answers a despawn with a 1.5 s fade-out (`CIDecoDisappear`, docs/protocol/appear_fade.md),
  which OpenSRO's client draws on `OpMonsterLeft` since round 677. A dead monster leaves the same
  way once its corpse's DecayTime has run (`CGObj::Update` 0x484d10 -> slot 218, SetLifeState(3)).
- **It runs on every region change.** Slot 235 has one call site, `0x485ad4` in `FUN_004858e0`,
  the object's move into a new cell: when the new region differs from `this[0x4a]` it calls the
  region-entry veto (slot 220), adds the object to the region, and then `SetCurRegion`.
  `FUN_004858e0`'s one caller is `FUN_00485740` (`0x4857f5`), whose one direct caller is the
  object's MoveTo, `0x48b660` (`0x48b69c`) -- CGObjMob's slot 231 -- which `CGObj::EnterWorld`
  calls too ("CGObj::EnterWorld Failed!!! at MoveTo()"). So a hatch placed in a town is removed
  at once, and a monster whose walk crosses into one is removed at the line.
- **Nothing vetoes the entry.** CGObjMob's slot 220 is `0x9856e0`, `mov eax,1; ret 8` (a shared
  stub). CGObjPC's (`0x4eb220`) is the thief's cart test (`0x0c01`
  ROBBER_CANT_ENTER_TOWN_WITH_CART when a job-2 character with a cart crosses from a battlefield
  region into a non-battlefield one).
- **Nothing else protects a player in town.** `CGObjMob`'s attack check (slot 394, `0x529110`)
  tests the target's kind, job state and fortress flags, no region; the AI's target validity
  (`0x540de0`) and the nearest selector (`0x5464e0`) test life state and distance, no region. So a
  monster on the field side of the line still picks and hits a player standing inside it, within
  its reach. The region byte guards only the PLAYER's attacks: `CGObjPC` slot 394 (`0x5293a0`)
  answers `0x3018` ITS_NOT_A_BATTLE_FIELD for a player-vs-player attack when either side's region
  is a town, and the skill gate's row 13 (`0x58e186`) refuses an offensive skill (`FUN_00589d20`)
  cast from a town (`0x3018`, or `0x3009` for a quest skill).
- **Spawning and wandering.** The nest's own region check (`AI::CNest::ValidateRegion`,
  `0x560e90`) only asks that the region exist; no hatch-time town filter exists. A wander leg is
  not bent away from a town either: any arrival is removed by the rule above. INFERRED: whether
  the nest's loss hook (`AI::CNest::OnHatchedRemoved`, `0x560d00`, caller not found) runs for a
  removal as for a death -- a nest that never learned of it would stop hatching at its cap.

### OpenSRO

- `internal/safezone` reads the CSV `export-refdata -mode regions` writes from refregion.txt
  (`RegionID,ContinentName,AreaName,IsBattleField`); cmd/server's `-regions-csv` installs it
  (`session.SetSafeRegions`). Without it nothing changes.
- The monster AI's pass (`session/monsterai.go` step 1b, `safezone.go`) checks each monster its
  step carried over a cell line -- a region line is always a cell line (combat.CellSpan = 1920/6)
  -- and each monster it meets for the first time (hatched, respawned or GM-spawned), and removes
  the ones standing in a town region (`combat.Hub.Remove`: no death, nothing credited, booked on the
  death log so the nest scheduler re-arms as for a loss -- INFERRED above). The players whose window
  holds it get `OpMonsterLeft` (round 656's message; the client drops the body), its states and
  blocking streak are forgotten, and the server logs `monster removed: it entered a town ...` (INFO for
  one that walked in, Debug plus a per-minute INFO count for one placed there -- OURS, round 674's review) with
  the monster, how (walked in / placed there), its state and target, the region and area.
- The region of a monster is `worldmap.FromWorld` in its bucket's frame (`entityFrame`). OURS: a
  region the CSV does not list is not a town (retail removes a monster with no region at all, but
  there it has no ground to stand on); a monster whose leg ends exactly ON a z region line is not
  checked until it next crosses a cell line (the cell index files the line on the field side).
- Not built: the player-side uses of the byte (PvP `0x3018`, offensive skills from a town, the
  thief's cart). The client draws nothing new: it drops the body on the `OpMonsterLeft` it
  already handles.
