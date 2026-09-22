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
monster into IDLE) when the owner's HP is 0 or a monster's `IsNPC` object has no home
(slot 15); otherwise it clears the target and asks `CAIState_WANDER::PickWanderLeg`
(`0x545860`) for a leg:

	requires run speed > 1e-6 (0xb45c84) and the object's location record (+0x7c)
	distance  = 85 +- (rand % 40)                      ; 0xb46160 = 85.0 -> 46..124 units
	heading   = atan2(current direction) +- (45 + rand % 91) degrees   ; a 45..135 degree turn
	direction = (cos, 0, sin) of that heading (FUN_00489490 / FUN_004894b0)
	probe     = position + direction * 30              ; 0xb45e58 = 30.0
	world probe (DAT_00cc387c slot 12, flags (0|1, 1)) -> bit 0 or bit 28 set = blocked
	    -> direction *= -1.0 (0xb45e68): walk the other way

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
2-6 s, walks 46-124 units off its heading for 5-6 s, and repeats -- going HOMING (via
`0x26`) whenever `IsWithinRoamRadius` says it has strayed. `server/internal/ai` carries the
table (`DwellRange`) and the leg constants; srrevamp's server does not move monsters yet.

## The roster's real walk and run speeds (round 362)

WANDER needs a speed and srrevamp carries none. These are the game's own, read
from the retail `characterdata_5000.txt` on 2026-09-21.

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

**A trap this walked into, recorded because it nearly shipped.** Selecting the
row by `CodeName` finds the WRONG row: `characterdata_10000.txt` has a second
`MOB_CH_MANGNYANG` at level 90 with 676,983 HP, and its speeds (8/22) happen to
look plausible. **Code names are not unique across the characterdata files.**
Select by `RefObjID`. The level/HP control is what caught it -- col 57 came back
90 against the roster's 1.

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
destination is home displaced along the home-to-monster line by

	offset = rand % (1 + ftol(R / 3)) - R / 9        ; -3.0 at 0xb45e08, 3.0 at 0xb45ab8
	                                                 ; i.e. -R/9 .. +2R/9 units

unless the owner's slot 243 says otherwise (then exactly home), and the world's
move request (`DAT_00cc387c` slot 12) is issued -- flag 1 for a player or a
slot-11 object, 0 for a monster.

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