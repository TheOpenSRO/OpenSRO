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
| `0x22` | 38 | range test, then → **BATTLE** | `EMOTION`, `HOMING`, `WANDER`, `WATCHOUT` |
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
| 6 | `+0x14` | u32 | the **detection distance** (world units): the target-acquisition radius is `BCRadius + this` (`ctx+0x15c`, round 257 below). Non-zero installs the acquire-a-target behaviour at context `+0xf8` (`AITactics_AcquireTarget`, `0x5478f0`; zero installs the no-op `FUN_00559000`), lets the AI-skill scan (`AI::CTactics::RegisterAISkill`, `0x53fa70`) raise the context's max skill range `+0x160`, and at `Init` seeds `+0x7c` from that range for an immobile monster (run speed `+0x170 <= 0`). `FUN_005473c0` (behaviour `+0xec`) credits an attacker of an immobile monster only when `Distance(self, attacker) <= +0x14` |
| 7 | `+0x18` | u8 | **aggression mode** 0/1/2 (above) |
| 8 | `+0x1c` | u32 | **aggressive chance, percent**, for mode 2 |
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
| 42 | `+0x90` | u32 | **flags**. Bit 2 (`0x4`), bit 7 (`0x80`) and bit 8 (`0x100`) pick the target-kind filter pair the acquire behaviour scans with ((2,1) default, (3,5) bit 2, (4,5) bit 7, (5,0x11) bit 8); bits 2/7 also swap the `+0x100` behaviour for `FUN_005481a0`/`FUN_00548270`, make the give-up check return 0, disable the `+0x10c` trigger, and shorten `Init`'s first action delay from `rand()%491+10` to `rand()%41+10` (unit unread -- `FUN_0053d600`) |
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
| 8 | `+0x1c` | u16 | **initial direction**: `Nest_Hatch` turns it into radians as `v / 65535.0 * 360.0 * (pi/180)` (`0xb45c28`, `0xb45c30`, `0xb45e00`) for a rarity-3 species; every other species gets `rand()/32767 * 2pi` |
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

**What this settles for srrevamp.** `respawnDelay = 10 s` in
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
table (`DwellRange`) and the leg constants; srrevamp's server does not move monsters yet.

## The roster's real walk and run speeds (round 362)

WANDER needs a speed and srrevamp carries none. These are the game's own, read
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
walked at the walk speed, and 1 the run clip at the run speed, is the **inference** srrevamp's
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

**What this means for srrevamp's move packet** (`docs/TODO.md`): there is a
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
installed only when `+0x14` is non-zero; run from WANDER, HOMING, WATCHOUT and
EMOTION while the aggression byte `+0x168` is 0 or 3):

	radius   = round(ctx+0x15c)
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

**What srrevamp can use.** `ai.DetectionRadius` and `ai.LevelScaledRadius`
carry the two rules with a test. The per-species `+0x14` distances are in no
archive this project holds: `_RefTactics` is a shard-database table, the
server package on the box has no shard backup (its `SR_GameRefData` folder is
the client-side text tables plus shop/teleport/quest files; its three
`SR_GameServer` minidumps are 2 MB thread-and-module dumps with no heap). So
when srrevamp's monsters learn to notice a player, the distance itself will be
disclosed per species, and the rule around it will not be.

## The aggro link: a party's hit pulls the neighbours in (round 258)

Being hit reaches a monster as **command 2** through its command source --
`AI::CTactics` IS the monster's command source (its vtable shares
`CCmdSrcNet::PostCommand` at slot 1; slot 7, `AI::CTactics::DispatchCommandToState`,
forwards a command to the current state's slot 5, `CAIState::DispatchCommand`,
`0x558bb0`, which maps command codes to vtable slots: `0->7 2->6 4->8 5->9 6->10
8->11 9->12 10->13 0xb->14 0xc->15 0xd->16 0xe->29 0xf->30 0x10->17 0x11->18`).
Command 2 lands in **slot 6, `CAIState::OnAttacked`** (`0x558ea0`, the base
used by IDLE, WANDER, FLEE and HOMING; BATTLE overrides it with the retarget
rule of behaviour `+0xfc`):

	raw = record.damage
	behaviour +0xf0 (record)                   ; the aggro link, below -- it decays record.damage
	record.damage = ftol(raw * 1.15)           ; 0xb46300, double, its only use: the victim itself
	                                           ; credits the attacker with 15 % MORE than the blow
	if behaviour +0xec (attacker accounting) == 0:
	    SetTarget(1) ; ChangeState(3)          ; edi = 3 -> BATTLE (asm: xor ebx,ebx ; lea edi,[ebx+3])

**The link itself**, `AITactics_ExtRoutine::LinkAggroToNearbyMonsters`
(`0x547570`, behaviour `+0xf0`, `AITactics_ExtRoutine.cpp` -- its CLAMP assert
cites line 0x662):

	attacker must be a PC; its party (pc+0x1cb8) must exist and have bit 0 of party+0x10
	AITactics_CollectNearbyMonsters(attacker)             ; the ten nearest monsters inside
	                                                      ; LevelScaledRadius(BCRadius + detection)
	n = party members within 1000.0 units of the attacker ; 0xb45c68, double; the attacker counts
	n = CLAMP(n, 0, gathered)
	for i in 0 .. n-1:
	    gathered[i].cmdsrc->slot7(0xe, record, 0)         ; command 0xe -> slot 29
	    record.damage = ftol(record.damage * g_MonsterAggroLinkDecreaseRatio)

so **as many neighbouring monsters as the party has members on the spot join
the fight, each credited with a smaller share of the blow than the last** (the
first link gets the raw damage, the second half of it, the third a quarter --
`ftol` at each step), while the victim itself books 1.15 x the raw blow.

*Corrected in round 537: those shares are HATE, not damage.* The attack record is `{attacker,
damage (+4), hate (+8), hatePercent (+0xc)}` (`AITactics_CreditAttacker`, `0x5473c0`, below). The
link zeroes the record's damage before its first forward (`mov [edi+0x4],ebx` with `ebx = 0` at
`0x547797`) and scales the hate after each one (`fild [esi+0x8]; fmul DWORD [0xc8252c]`, then
`_ftol2_sse` and `mov [esi+0x8],eax`, `0x54780c..0x54781a`). `OnAttacked` saves the hate before the
link (`mov eax,[esi+0x8]` at `0x558ea6`) and writes `ftol(hate x 1.15)` back over it afterwards
(`0x558ebd..0x558ecc`). So under a link the neighbours are credited 100/50/25 % of the record's
hate and the victim 115 % of it, and nobody books the blow's damage. The pseudocode above, which
says `record.damage`, is the round-258 reading.
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

`ai.ThreatTable` (`internal/ai/threat.go`) carries the credit, the drop, the
three rules and the interval with tests; nothing in srrevamp runs it yet.

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
	          weight = AI_AttackChance
	                 + max(0, ftol(skill.Range + ownerBC + targetBC - distance))
	and one is drawn at random in proportion (rand(); cumulative weights, 0x5632d0)
	the pick goes to slot 5, ArmNextAttack: +0x44 = the skill, +0x48 = ReuseDelay + rand % (J + 1)

So a monster with one attack skill (the whole Jangan roster: characterdata
column 83) always swings it; a monster with several prefers, in proportion to
`AI_AttackChance`, the ones whose reach covers the target by the most units;
and a tactics-bound skill fires on its HP threshold once or on its timer,
ahead of any draw. `ai.SkillWeight`, `ai.TriggerHPBelow/Periodic` carry the
rules with a test.

## HOMING: the way home (round 261)

`CAIState_HOMING::OnEnter` (`0x55a540`): a monster with neither a nest
(`ctx+0x30`) nor a saved location record (`+0x1bc`) asks `0x558af0` for its
spawn record and asserts out (-> state 0) when that has none. Then: a timer is
armed through the indexed setter (`0x53d600`, arguments `(2, 500)`), the dwell
is `AIState_DwellMs` (HOMING's 50 s), `MoveHome` starts the walk, the state's
`+0x1c` is set to **`round(detectionRadius / runSpeed x 1000)` ms** (the
`ctx+0x15c` radius over the owner's `+0x170`), the `0x704f` motion notice
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
| `+0xf8` | `FUN_00559000` (no-op) | `+0x14 != 0` -> `FUN_005478f0` (acquire a target); TacticsID 0x21/0x3f/0x71 -> `FUN_00547ad0` | `WANDER`, `HOMING`, `WATCHOUT` updates, `EMOTION::FUN_0055a8b0` |
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

## What this gives srrevamp

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
srrevamp's server moving monsters at all (`docs/TODO.md`).

*Corrected in round 537.* This paragraph said the roam radius is "200 units when nothing sets it".
`AI::CTactics::Attach` (`0x53f2a0`) does store 200.0 (`0xb45d68`, `fld` at `0x53f367`) when there is
no nest, no caller radius and the row's `+0x84` (column 38) is not positive -- but in exactly that
case `IsWithinRoamRadius` (`0x545f70`) answers "within" without measuring (`cmp [row+0x84],0; jg`
at `0x545fde`, then `mov al,1`), unless the owner's slot 242 or 243 answers non-zero (the (1,2,4,x)
TID shapes; slot 243 answering 1 makes `Attach` store 5.0 instead). So retail never applies the 200
to a roster monster. srrevamp's runtime uses 200 as its own roam radius (below), disclosed as such.
Round 537 built the roam radius and its HOMING exit; the give-up distance waits on the BATTLE chase.


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

## srrevamp's own monster protocol (placeholders)

Round 533 added two messages so the client can draw a monster the server moves. Both are
srrevamp's own, additive placeholders (`docs/protocol/PROTOCOL_DECISION.md`); no existing layout
changed. Client: `scripts/net/combat.gd` (`CombatNet.decode_monster_moved`,
`decode_monster_motion_list`), drawn by `scripts/world/monster_motion.gd` (`MonsterMotion`) and
`World3D._on_monster_moved` / `_on_monster_motion_list` / `_step_monster_bodies`. Since round 537
the server sends both, and only with its `-monster-ai` flag on, which is off by default ("srrevamp's
runtime", below). On 2026-09-23,
0x007C..0x007F appeared in no non-test file under `server/internal/session`,
`server/internal/proto` or `client/scripts/net`. Round 536 declared the two in
`server/internal/session/monstermove.go` (below). Round 540 gave the client two more, 0x007D and
0x007E, which no server sends yet ("The strike and spawn pushes", below); on 2026-09-24 neither
appeared in any non-test file under `server/`.

| op | dir | payload |
|---|---|---|
| `OpMonsterMoved 0x007c` | s→zone | s64 monster id, f32 x, f32 z (the server's position when it issued the move), f32 dest_x, f32 dest_z, f32 speed (world units per second), u8 mode (0 walk clip, 1 run clip) -- 29 bytes |
| `OpMonsterMotionList 0x007f` | s→requester | u16 n, then n entries of {s64 id, f32 dest_x, f32 dest_z, f32 speed, u8 mode} (21 bytes each); sent right after an `OpMonsterListResult`, ONE packet per list |
| `OpMonsterAttacked 0x007d` | s→zone, the attacker included | s64 monster id, s64 target character id, s32 damage (0 when blocked), u8 flags (bit 0 the monster's critical, bit 1 blocked, bit 2 the target died), s32 target HP after the blow (after a death, the HP it was put back on its feet with), s64 death exp lost -- 33 bytes; sent right AFTER the attacker's `OpAttackResult`, from the same goroutine |
| `OpMonsterSpawned 0x007e` | s→zone | one record in `OpMonsterListResult`'s own encoding (s64 id, u16-prefixed name, u16-prefixed code name, f32 x/y/z, u32 max HP, HP, level, rarity), then f32 heading (radians, srrevamp's world frame: from +x toward +z) |

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
  terrain-only ray every `HEIGHT_RESOLVE_STEP` units, at most `MAX_HEIGHT_RESOLVES_PER_FRAME`
  bodies a frame.
- An `OpMonsterMoved` for a monster the client has no body for asks for the list, at most once
  every `UNKNOWN_MOVE_PULL_SECONDS`. A motion-list entry re-aims a body only when its destination
  differs from the one it is walking to by more than `REAIM_EPSILON`; a body the list leaves out
  finishes its leg.

**Stand-ins, each disclosed at its constant:**

- **The f32 speed is srrevamp's own.** Retail `0x7021`/`0xB021` carry no speed
  (`docs/protocol/opcodes/movement.md`); the engine's mover reads it off the object (+0x174).
- **Mode 0/1 -> walk/run clip is an inference.** Grounded: `AITactics_Handler_110` (`0x5489b0`)
  picks 0 or 1, and the `0x704f` byte is `(mode == 1) + 2` (`0x54184d..0x541859`). Untraced: the
  mover's use of owner+0x155/+0x174. Unread: `GInterfaceSend::FUN_009d4a00` sends 2 when +0x25d is
  set, and what +0x25d means.
- **srrevamp's own numbers:** `RESYNC_DISTANCE` 32 (it must exceed Earth Ghost's 75 u/s run over a
  0.3 s round trip, 22.5), `HEIGHT_RESOLVE_STEP` 2, `MAX_HEIGHT_RESOLVES_PER_FRAME` 32,
  `UNKNOWN_MOVE_PULL_SECONDS` 5, `REAIM_EPSILON` 0.5.
- **The height along a leg** is the terrain-only ray, not the navmesh.
- **The resync position** follows a lead, not a reading: the `0xB021` reader
  `NetProcessInNavAndSkill::FUN_008a5750` / `FUN_008a5640` (`message_handlers.tsv`,
  `client_read_layouts.tsv`).

### The server half (round 536): the encoders, the mover, the motion API and the pure rules

**Inert when built.** Nothing called any of it in round 536: `OpMonsterListResult` and its handler
were unchanged (the list's round-trip and flow tests are the control), `combat.Hub`'s motion API had
no caller outside tests, and `server/internal/ai` was still parked. Round 537's tick calls it, behind
`-monster-ai` ("srrevamp's runtime", below). Every address below was re-read in
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
  `HasArrived`'s (`FUN_00430d40`) keeps it. srrevamp's monsters carry no height of their own, so
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
- the 30-unit blocked-probe reversal (srrevamp's server holds no collision world);
- the four IDLE-roll owner conditions;
- `MoveHome`'s slot-243 exact-home case;
- the mover's 0.01f component zeroing.

Headings stay in srrevamp's world frame; the tick that drives these rules carries that disclosure.

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

**The four `_CLON` species have no model.** `MOB_CH_BIGEYEGHOST_CLON` (Small-eyed Ghost),
`MOB_CH_GYO_CLON` (Old Weasel), `MOB_CH_WATERGHOST_CLON` (Water Ghost slave) and
`MOB_CH_TOMBSTONE_CLON` (Tomb Stone Ghost) carry `xxx` in every model column of their
characterdata rows (read on the box's `characterdata_5000.txt`: cols 52-56, counted from 0 as
col 50 BCRadius is), and their display
names resolve to no row that has one. World3D draws them as the labelled capsule, which has no
front. How the retail client draws a `_CLON` row is not established.

### The strike and spawn pushes (round 540: the client half)

Two more of srrevamp's own placeholders, in the table above. **No server sends either yet.** The
server half comes next, each push behind its own default-off flag, flipped only once a client that
draws them has been released. Client: `CombatNet.decode_monster_attacked` /
`decode_monster_spawned`, `NetClient`'s `monster_attacked` / `monster_spawned` signals,
`scripts/world/monster_strikes.gd` (`MonsterStrikes`), and `World3D._on_monster_attacked` /
`_on_monster_spawned`.

**What the strike push carries.** A counterattack is resolved in `performAttack`
(`server/internal/session/combat.go`, the branch after `combat.Hub.CounterattackReady`; rounds 254
and 505), and today it reaches only the attacker, in that attack's `OpAttackResult`. The push
repeats the same outcome to everyone in the zone: `PlayerDamageTaken` as the damage,
`MonsterCritical`, `PlayerBlocked` and `PlayerDied` as the flags, `PlayerHP` as the target HP and
`DeathExpLost`. So a push adds no new number. A counter that lands deals at least 1
(`combat.ResolveBlow` floors the blow at 1 in `MitigateDamage` and `ApplyLevelAdvantage`, and
`ApplyFloorBand` never takes it below 1). So a result reports a counter exactly when its damage is
above 0 or its block flag is set (`MonsterStrikes.result_countered`).

**The order the client relies on.** The server sends the attacker's result first, then the push to
the zone with the attacker included, both from the goroutine that ran `performAttack`. The
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

**The client does not know its own character id.** `OpEnterWorldResult`
(`server/internal/session/world.go`) carries a zone, a position, a gender, vitals and the others in
the zone, but no id, and giving it one would change a layout. So a push is taken as a blow on this
player only when it claims a wait: it repeats a counter this client's own result reported, and its
target is none of the other players the client has drawn (`World3D._other_bodies`). Every blow a
server can push today is such a counter. A monster striking on its own (mob-battle-chase) will need
the id, and that is filed in `docs/TODO.md`.

**How a blow is drawn** (`World3D._draw_monster_strike`):

- The monster is turned toward its target by its measured front (`MonsterMotion.facing_yaw`, the
  table above), and plays its attack clip (type 2, `TYPE_ATTACK`).
- At that clip's first hit event (`EVENT_HIT`: `mangnyang_attack01` at 651), the target plays its
  hit clip (type 3) and the red number rises over it.
  - The target is the player's own body, or another player's body in `_other_bodies`, played with
    that body's own gender and weapon group.
  - The event's millisecond unit is **inferred** from the key times, not read from the client's use
    of them (`docs/protocol/BSR_FORMAT.md`, "Events and walk points").
- A blocked blow is the swing alone, because it dealt nothing.
- A blow on a target this client has not drawn is the swing alone, unturned.
- For a blow on this player, the HUD's HP is set from the target HP, and a killing blow shows the
  death line on the combat status label. The result has already set both from the same numbers,
  so this changes nothing when the server sends both messages.
- Another player's body now changes its stand/run loop through `MonsterMotion.swap_loop`, so a
  gait change during that hit clip does not leave two animation entries on one skeleton.

**The spawn push** makes the body the way a listed one is made (`_spawn_or_update_monster`). It
then faces the body along the heading, when the body is standing and its model's front was
measured. `MonsterMotion.heading_dir` is (cos h, sin h) on (x, z). That is srrevamp's heading frame
(`server/internal/ai/wander.go`), and it is the unit heading the engine's SetHeading writes to
+0x24/+0x28/+0x2c as (cos a, 0, sin a): `GObjPC::FUN_00482440` (IGObj slot 230; the CGObjMobile
override `0x0048ba10` writes the same three), through `FUN_00489490` -> `0x009fc0b0` (the CRT's
cos; its x87 path runs `fcos` at `0x9fc11d`) and `FUN_004894b0` -> `0x009fbf80` (sin, `fsin` at
`0x9fbfed`). All of these were re-read on the RE box in round 540. The line
`World3D: monster %d spawned (push)` is printed for each push.

**Log lines for the live checks** (the server item runs them):

- Every push prints `World3D: monster %d strikes %d for %d (HP %d)`, followed by the flags and how
  it was taken: `own counter, drawn as the blow lands`, `own counter, already drawn from the
  result`, `on another player` or `target not drawn here`.
- Every counter a result drew because no push had come prints `World3D: monster %d counter from
  the result (no push)`.
- With the push on, the attacker's `strikes` lines should equal its counter results, **blocked ones
  included** (damage 0, bit 1), and there should be no `counter from the result` lines. With the
  push off, it is the reverse.

**Measured live (round 540, 2026-09-24, render box, hardware GL).** The server was built from the
tree at `e17cda3`, which sends no push. Both runs used `SRREVAMP_QA_ATTACK_FAST=1
SRREVAMP_QA_ATTACK_NAME=Mangyang SRREVAMP_QA_ATTACK_GOTO=1 qa_shot.sh --server --attack --frames
600`.

- **Run A, as it is (no push).** There were 38 counter results (took > 0; none blocked, since the
  QA player carries no shield). The log has 37 `counter from the result (no push)` lines, for the
  first 37 counters in order, and no `strikes` line. The 38th counter's result came at t=9.63, and
  its blow was due about 0.2 s of game time later; the run's last result came at t=9.73, and the
  run ended before the blow was due.
- **Run B, with `SRREVAMP_QA_MOB_STRIKE=1`.** There were 44 counter results and 44 stand-in
  pushes. The log has 44 `strikes` lines, all `own counter, drawn as the blow lands`, matching the
  results monster for monster and number for number. It has no `counter from the result` line,
  and 43 red numbers rose over the player. The 44th counter's result came at t=9.65, too late
  for its blow to land before the run ended.
- Neither run printed a SCRIPT ERROR. The frames were deleted.
- Not seen live: a blocked counter, and another player's body. The headless tests cover both.

**Stand-ins:**

- Both layouts are srrevamp's own.
- The pairing test (the numbers repeat, and the target is not another drawn player) stands in for
  the character id the client does not have.
- The target's number is drawn over its head at the height the player's own number uses.
- `SRREVAMP_QA_MOB_STRIKE=1` stands in for a server with the push. It sends each counter result's
  push through `NetClient._dispatch`, deferred to the end of the frame, with -1 for the target.

## srrevamp's runtime: the monster AI tick (round 537)

`server/internal/session/monsterai.go` runs the machine above over the live monsters. It runs only
when `cmd/server` is started with **`-monster-ai`** (env `SRREVAMP_MONSTER_AI`, parsed with
`strconv.ParseBool`; anything unparsable is off, with a WARN). **The default is off**, and off is
the kill switch: `RunMonsterAI` is never called, the runtime pointer stays nil, `noteStruck` does
nothing and `OpMonsterList` is answered with the one list result it always was, byte for byte. The
boot log says which: `monster AI off (-monster-ai / SRREVAMP_MONSTER_AI)` or
`monster AI on: tick 100ms (own design), roam radius 200 (own design)`. How an operator flips it is
in `deploy/README.md`, "Monster AI (off by default)".

**One tick, in this order:**

1. `combat.Hub.StepAll(dt)`, `dt` being the wall time since the last tick: the engine's mover with
   both clamps (round 536).
2. A brain per live monster, in monster-id order. A new one starts in SPAWN facing `Nest_Hatch`'s
   random heading (`ai.SpawnHeading`) and takes message `0x21`'s default, IDLE, at once. A brain
   whose monster is gone is dropped.
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
`SetTarget(1)` (`0x53ffe0`, at `0x558eed`), then `ChangeState(3)` (`lea edi,[ebx+3]` at `0x558f01`)
-- no aggression test and no range test. Trace lines, with `SRREVAMP_AI_TRACE` set:
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
  gives srrevamp", above). The real radius is the nest row's column 9 (`+0x20`), which is
  server-database only. srrevamp treats each placement as a nest.
- **No blocked probe.** A leg can cross walls and objects: `PickWanderLeg`'s 30-unit probe needs a
  collision world the server does not hold (mob-server-geometry-probe).
- **Not modelled:**
  - `PickWanderLeg`'s `ctx+0x14c` leader term;
  - the four IDLE-roll owner conditions;
  - WANDER's COS-not-mercenary refusal (no roster species is a COS);
  - HOMING's timer, re-aggro window and `+0x164` sign;
  - BATTLE's timers, clip, gathering and `OnLeave` override;
  - the acquire behaviour every `OnUpdate` calls (mob-acquire).
- **Headings stay in srrevamp's world frame.** The engine's frame differs by the z mirror. That
  changes no distribution: the hatch heading is uniform and the turns are symmetric.
- **HOMING walks one straight leg.** `AITactics_HomingStep`'s heading wobble is deferred
  (mob-homing-wobble), and its arrival is tested every tick.
- **Mode 0 is the walk speed and mode 1 the run speed.** This is inferred (round 363's note above);
  the 0/1 selection itself is read.
- **The interim hold** (mob-battle-chase replaces all of it with the chase and the engine's exits):
  - **The stop at the blow.** `noteStruck` stops a walking monster in the hub at the blow, and the
    next tick pushes the one stop. The engine's `BATTLE::OnEnter` issues no stop: its chase replaces
    the leg. The stop is at the blow, not at the tick, because the tick steps the mover before it
    drains the blows. Stopped only at the tick, a monster would first walk up to 0.1 s x its speed
    (0.8 units for a Mangyang, 2.2 while HOMING at 22), which carries one struck at the edge of the
    band out of reach. The keep-up's next repeat would then end the run (keepup.go), and the
    release would let the monster walk off after one hit. `BATTLE::OnEnter` also stops a monster
    still on a leg, which the blow's stop leaves as a no-op.
  - **The release.** The monster stays in BATTLE while any player in its zone has a keep-up on it
    (`keepUp.Target` for each player `world.Hub` puts in the zone), and goes to IDLE only once
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
      hold lasts one tick;
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
- **Not modelled on a blow:** the aggro link (behaviour `+0xf0`) and the attacker accounting's
  refusals (`CreditAttacker`, behaviour `+0xec`).
- **Target validity is srrevamp's own:** "in `world.Hub`, same zone". The engine's is
  `FUN_00540dc0` / `FUN_00540de0` (alive, life state 1).
- **The synchronous counterattack is unchanged.** A monster still strikes only when struck.
- **Zone-wide pushes, no interest management.** About 33 leg pushes a second per Jangan session at
  about 350 monsters. That is an ESTIMATE from the read dwell and roll numbers, not a measurement:
  an IDLE spell averages 4.0 s and is followed by a leg 76 times in 100, whose WANDER spell averages
  5.5 s, so a monster starts 0.76 legs per 4.0 + 0.76 x 5.5 = 8.2 s, about 0.093 a second. (One
  seeded Mangyang in `TestMonsterAIWandersAtWalkSpeedInsideTheRoamRadius` started 14 legs in
  120 s: 12 WANDER legs at the walk speed and 2 HOMING runs, the test's own log line "14 legs, 12
  of them walked". Its WANDER rate, 0.1 a second, is one seeded sample, not a check of the
  estimate.) Add one `OpMonsterMotionList` per list request, at 21 bytes per walking monster.
- **A stalled client.** The tick's sends block on it, as `RunRegen`'s already do:
  `gateway.Session.Send` has no write deadline. The kill switch is the mitigation.

**The live checks, before the flag is flipped on the public server.** Both run on the render box
with the server built to `SERVER_BIN=/var/tmp/<lane>/srrevamp-server`.

- **Time dilation, which every assertion here has to allow for.** `qa_shot.sh`'s movie writer steps
  the client 1/60 s per frame at about 0.33 s of wall time a frame, so the client runs about 20x
  slower than the wall-clock server. A client's view of a monster is therefore stale, and a check
  asserts **receipt** and the server's own trace, never the drawn position.
- **Run 1:**
  `SRREVAMP_MONSTER_AI=1 SRREVAMP_AI_TRACE=1 SRREVAMP_QA_MOB_LOG=1 client/tools/qa_shot.sh --server --frames 600 --out /var/tmp/mob_ai_tick`,
  from the default spot, with no GOTO and no `--attack`. `server.log` must have `IDLE->WANDER` and
  `leg to ... speed 8 mode 0` lines for Mangyang ids, and no leg starting beyond 324 of its home.
  The client log must have `monster <id> walk` for the same ids.
- **Run 2:** the same with `--attack`, `SRREVAMP_QA_ATTACK_NAME=Mangyang` and
  `SRREVAMP_QA_ATTACK_GOTO=1`. It must show:
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
with `SRREVAMP_MONSTER_AI=1 SRREVAMP_AI_TRACE=1 SRREVAMP_QA_MOB_LOG=1`, `--server --frames 600`,
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
`SRREVAMP_MONSTER_AI=1 SRREVAMP_AI_TRACE=1 SRREVAMP_QA_MOB_LOG=1 SRREVAMP_QA_ATTACK_NAME=Mangyang
SRREVAMP_QA_ATTACK_GOTO=1`, `--server --attack --frames 600`, from the default spot.

- **The first attempt never swung, and that was a QA bug.** It printed no `QA ATTACK` line and
  made 3 list requests in 600 frames. The QA setup block runs on the first physics frame. With no
  `SRREVAMP_QA_AT` to wait for, that frame came while `_ready` was still awaiting the QA sign-in,
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

