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

`CAIState_WANDER::OnEnter` (`0x00559df0`) is the clearest refuser — it returns
`-1` when the owner's HP has reached zero.

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
| 6 | `+0x14` | u32 | a **distance** (world units). Non-zero installs the acquire-a-target behaviour at context `+0xf8` (`FUN_005478f0`; zero installs the no-op `FUN_00559000`), lets the AI-skill scan (`AI::CTactics::FUN_0053fa70`) raise the context's max skill range `+0x160`, and at `Init` seeds `+0x7c` from that range for an immobile monster (run speed `+0x170 <= 0`). `FUN_005473c0` (behaviour `+0xec`) credits an attacker of an immobile monster only when `Distance(self, attacker) <= +0x14` |
| 7 | `+0x18` | u8 | **aggression mode** 0/1/2 (above) |
| 8 | `+0x1c` | u32 | **aggressive chance, percent**, for mode 2 |
| 9 | `+0x20` | u8 | **retarget-on-hit rule**, `AITactics_Handler_0fc`: 1 -> `SetTarget(1)` when the attacker is not the current target; 2 -> the same test against `FUN_00545680(attacker)`'s object (its owner, by shape; unread); 0 -> keep the target |
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
| 3 | `+0x20` | u8 | no reader found |
| 4 | `+0x24` | u32 | no reader found |
| 5 | `+0x28` | u32 | no reader found |

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
| `+0x110` | `AITactics_Handler_110` | -- | no state calls it through the context (the `Unique_Summon` AI skills reach the same address another way; unread) |
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
all: the roam radius (200 units when nothing sets it, x1.5 under rule 1) with
its HOMING exit, and the give-up distance with its IDLE exit. Both wait on
srrevamp's server moving monsters at all (`docs/TODO.md`).
