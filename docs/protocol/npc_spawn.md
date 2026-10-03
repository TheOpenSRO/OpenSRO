# NPC spawn: how the original places and turns an NPC, and the messages that carry it (round 708)

READ from `SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/srv.asm` on the render box) and
`sro_client.exe` (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm`); constants read out of the PE
images' data. Labels: READ, MEASURED, INFERRED, OURS, OPEN, EXTERNAL (the user's shard database,
never committed).

In the original an NPC exists on a client only because the server spawned it. OpenSRO does the same
since round 708: `server/internal/npcspawn` builds the records, `server/internal/session/npcworld.go`
sends them, `client/scripts/net/npc_spawn.gd` reads them, and `World3D._place_npc_record` draws them.
The client no longer places NPCs from `npcpos.txt` (except under `OPENSRO_QA_LOCAL_NPCS`, QA only).

## The angle, end to end (READ)

| Step | Where | What |
|---|---|---|
| Nest row | `Nest_Hatch` 0x5607b0, 0x560a1b..0x560a3c (and 0x5609bf for a rarity-3 monster) | `movzx [nest+0x1c]` (`Tab_RefNest.wInitialDir`, u16), `fild`, `fdiv [0xb45c28]` (65535.0), `fmul [0xb45c30]` (360.0), `fmul [0xb45e00]` (0.01745329238474369), stored as a float: radians `a`. Every TypeID shape but the field monster's (1,2,1,x with rarity != 3) takes this branch, so every NPC does. |
| Hatch | `Nest_Hatch` 0x560c67..0x560c79 -> `GObjPC::FUN_005f6eb0` | `a` is the 7th stack argument (traced by the pushes); `FUN_005f6eb0` passes it on as the 7th argument of the game world's slot 6 (`[edx+0x18]` at 0x5f71a0, `fld [esp+0x60]` at 0x5f7175). |
| World | `CGameWorld` slot 6, `GObjPC::FUN_005eb9a0`, 0x5ebd53..0x5ebd8b | its 7th argument (`[esp+0xc4]`) goes in as the 14th argument of the object's slot 172, `CGObj::EnterWorld`. |
| Enter | `CGObj::EnterWorld` 0x485360, 0x48541b..0x48542a | `fld [ebp+0x3c]` -> slot 230 (`+0x398`) = SetHeading; then slot 226 (`+0x388`, 0x482420) = `SetLifeState(1)`. |
| Heading | `GObjPC::FUN_0048ba10` (CGObjMobile/CGObjNPC slot 230) | `+0x24 = cos a`, `+0x28 = 0`, `+0x2c = sin a` (`FUN_00489490`/`FUN_004894b0`); and `+0x164 = a` while `+0x154` (the mover's "has destination") is 0. |
| Spawn record | `CGObjMobile::vslot_293` 0x48b630 -> `FUN_00484fb0` -> `FUN_00487ce0` | `fld [esi+0x2c]; fld [esi+0x24]; call 0x9fc1aa` -- the CRT's `atan2` (its dispatch table at 0xc81760 names "atan2"), so `atan2(sin a, cos a) = a`; `FUN_00488050`: `+ 2 pi` (0xb45c18) when negative, then `round(a * 57.295780181884766 (0xb45c38) / 360.0 * 65535.0)` -> u16. The wire angle is `wInitialDir` again (to within the float rounding: `TestWireAngleRoundTrip`, within 1 on every u16). |
| Client | `FUN_009c3a70` (CIGIDObject slot 23, called first by `FUN_009d1300`) | reads the u16, `a / 65535.0 (0xdde7b0) * 360.0 (0xdde7a8) * 0.01745329238474369 (0xe1b8d8)`, then `FUN_009c40b0` adds pi/2 (0xe1b8f0) and takes 2 pi (0xd81930) off while >= 2 pi: the heading `h` at `+0x10c`. |
| Facing | `FUN_009ec850` (round 637) | `h` faces `(sin h, 0, -cos h)` region-local (x east, z north). With `h = a + pi/2` that is `(cos a, 0, sin a)` -- the server's own heading vector. The pi/2 exists to reconcile the server's frame with the client's. |

So: `wInitialDir` 0 faces east, 16384 north, 32768 west, 49152 south (`TestCardinalAngles`,
`npc_spawn_test.gd`). OpenSRO's holder: `rotation.y = -h` for a body whose front is its own -Z under
the region's terrain group (`NpcSpawnNet.holder_yaw`; `Basis(UP, a)` sends -Z to `(-sin a, 0,
-cos a)`).

**Position.** `Nest_Hatch` copies the nest slot's spot (`+0x10..+0x24`) into the position it passes
(`local_1c..local_8`, 0x560a40), `FUN_005f6eb0` offsets it within the nest's `nGenerateRadius`
(`FUN_00531240`), and `EnterWorld` resolves the cell and the height (`"CGObj::EnterWorld Failed!!!
at ResolveCellAndHeight()"`). MEASURED on the shard (EXTERNAL): every NPC nest that joins an npcpos row
has `nGenerateRadius` 0 and stands within 0.0002 units of the row, `fLocalPosY` equal to its Y. The
client stands the NPC on its own walkable graph as before, with the record's Y as the mover's height.

## The record (READ, both sides)

`CGObjNPC::vslot_294` 0x4c3cb0 writes it (flag 2) for `FUN_00533f70` (0x3015) and `FUN_00533910` (the
group spawn); the client reads it in `FUN_008a6bd0` then `CICNPC::vslot_025` 0x9d46c0, whose readers
are vslot 0x58 `FUN_009d1220` (nothing read), 0x5c `FUN_009d1300`, 0x88 `ICharactor::FUN_009d15a0`,
0x60 `FUN_009c1d10` and 0x70 `FUN_009c7780` (nothing read). The class: `IGIDObject::FUN_009c1fa0`
sends every TypeID (1,2,2,x) word through `FUN_0069a3f0` to the class link 0xef1ac4 -- NPCs (x = 0)
and the `STRUCTURE_GATE_PULLEY_*` rows (x = 1) alike.

| Bytes | Field | Server | Client | Value for an NPC |
|---|---|---|---|---|
| u32 | RefObjID | `[obj+0x34]` slot 10 (INFERRED: the client reads it first) | `FUN_008a6bd0` (-1 and -2 are other forms) | characterdata ID |
| u32 | unique id | `FUN_00484fb0`: `[obj+8]` | `FUN_009c3a70` -> `IGIDObject::FUN_009c3790` | OURS range `0x7f000000 + i` |
| u16 | region | `FUN_00487c80`/`ce0`: `+0x84` | `+0xfc` | the nest's |
| f32 x3 | x, y, z | `+0x88..` | `+0x100..+0x108` | the nest's local position |
| u16 | angle | `FUN_00488050` | `+0x10c` (+ pi/2) | wInitialDir |
| u8 | has destination | `FUN_0048be00`: `+0x154` | `FUN_008a5640(.., 1)`: +0 | 0 (`CGObjMobile::vslot_000` 0x48b450) |
| u8 | movement type | `+0x155` | +1 | 1 (vslot_000) |
| u8 | (no destination) source | `+0x168` | +0x14 | 0 (vslot_000) |
| u16 | (no destination) angle | `round(+0x164 ...)` | +0x10 | wInitialDir again |
| u8 x4 | stance | chardata `[0]..[3]` (`GObjPC::FUN_004a9b70`, 0x4a9be3..0x4a9c28) | `+0x271`, `+0x273`, `+0x272`, `+0x470` | 1 (life, READ: `SetLifeState(1)`), 0 (INFERRED: no writer on the NPC path), 0 (motion, READ: `SetMotionState(0)` in `CGObjChar::Create`), 0 (body mode, INFERRED) |
| f32 x3 | params 23, 24, 140 | `ParamKeeper_GetParamChecked` 0x17, 0x18, 0x8c | `+0x254`, `+0x258`, `+0x4e8` | 0, 0, 100: an NPC's stat initialisers (CGObjNPC vtable 0xaee43c slots 0x574/0x580) are 0x677a00 `return 1`, so the registry defaults stand (param_registry.md; INFERRED that none of param_writers.md's unresolved sites writes them for an NPC) |
| u8 | buff count | `FUN_0059cdc0` | `FUN_009d1300` | 0 |
| u8 | flags | `+0x1cac` | `+0x4fc` | bit 0 name (`SetCharName` 0x4c3f20), bit 1 interactions (`AddAvailableInteraction` 0x4c3f50); the client also knows bit 2 (u8 + u32), which no CGObjNPC writer sets |
| u16 + bytes | name | bit 0 | bit 0 (`FUN_004f7a70`) | not set for a town NPC (no caller found) |
| u8 + n x u8 | interactions | bit 1: the std::set at `+0x130`, size `+0x138` | bit 1: into the set at `+0x500` (asm 0x9d169a `lea ebx,[edi+0x500]`; the talk menu reads it, `FUN_00700440`) | see below |

**0x3015 single spawn** = the record + u8 (the block's spawn type, read by `FUN_009c2180` into
`+0xf4`). **0x3016 single despawn** = u32 unique id.

**The group** (READ: server `FUN_00533e70`, `push 0x3017` 0x533ede, `push 0x3019` 0x533f23 via
`FUN_00430a20`, `push 0x3018` 0x533f3e; client 0x3017 `FUN_008ac0e0`, 0x3019 `FUN_008ac170` ->
`FUN_00833380`, 0x3018 `FUN_008ac3d0` -> `FUN_008a6d20`):

- 0x3017: u8 type (1 spawn, 2 despawn; 0 asserts "byListSub"), u16 count. The client resets its
  buffer and keeps these three bytes.
- 0x3019 x n: the records (type 1) or u32 unique ids (type 2), cut into frames; the client appends
  each frame's bytes. Retail fills what its message buffer has left less 0x20; OpenSRO cuts at 4,064
  (OURS).
- 0x3018: empty; the client reads the buffer: count records with no trailing byte, or count ids
  each despawned through 0x3016's handler.

**Which group, when.** `CMsgBlock` slot 2 0x534340 (an object put in a block) sends, for the block
and each of its 8 neighbours, `FUN_00533e70(1)` -- that block's objects as a group spawn, to the
object if it is a player -- and `FUN_00533f70` (0x3015) of the object to the block's players. Slot 3
0x5344b0 (taken out) sends `FUN_00533e70(2)` -- the block's objects as a group despawn -- and 0x3016.
One group per block. Around a world entry OpenSRO forgets the session's window twice -- before
`hub.Enter` and again after `OpEnterWorldResult` is sent -- so a tick that lands between the two
(and spawns the window before the result, which clears the client's roster) is followed by the whole
window again after it; the client keeps an identical record in place (round 708's review). OpenSRO sends one group per gained / lost block from the player's 3 x 3 window
(round 664's blocks), on the area-of-interest tick; its NPCs are all in the world before any player,
so it never needs a 0x3015 for them. Monsters and players still ride OpenSRO's own messages, so its
groups carry NPCs only, where retail's carry every object of the block (a departure, OURS).

## The interaction list (READ, three parts INFERRED)

`CGObjNPCNPC::Create` 0x4c6350 tests the code name with the CRT's `strstr` (`FUN_009dddc0`) against
fixed lists and adds ids through slot 89 (setting flag bit 1); `npcspawn.Interactions` holds the
lists. Before them it copies the reference object's list at ref+0x90 into the set without the flag
-- the 7 and 9 `RefTeleport_ExtractData` 0x6a7be0 adds from the associated teleport row's two flags.
READ (confirmed in the review): the set's order on the wire is ascending -- `0x4c3cb0` starts at the
header's `_Left` (the smallest node), reads each value at node+0xc and steps with the in-order
successor `FUN_004885c0`, MSVC's `std::set<u8>` iteration. INFERRED: 0x11
is added when a reference map (`FUN_004ccb70`) names the NPC -- taken to be refshopgroup's
RefNPCCodeName (`-npcs-csv`'s Shop column) -- and only while a world-config byte (+0x42404) is 0,
taken as 0.

## OpenSRO's additions (OURS)

- **OpNpcFacingUnknown 0x00B6**: u16 n, n x u32 unique id -- sent just before a group that holds NPCs
  with no nest angle (an npcpos row with no nest of its own in the database even after the second
  pass, or a server with no database). Their record's angle is 0; the client faces them by `NpcFacing` (open space on the
  navigation graph, the pre-708 stand-in). Retail has no such NPC.
- **Unique ids** `0x7f000000 + i` in placement order (region, x, z, id): a range of their own,
  since OpenSRO's monsters and characters number from their own counters.
- **No `-npcs-csv`**: the server still spawns every npcpos row the monster table does not name
  (MEASURED: 257 of 12,367 rows, exactly the TypeID (1,2,2,x) rows) with flags 0.
- **QA**: `OPENSRO_QA_LOCAL_NPCS=1` (qa_shot.sh without a server-side npcpos, perf_gate.sh) feeds
  records built from the archive's npcpos.txt to the same handler, no angle.

## OPEN

- Town teleport gates are also server-sent objects in retail (`CITeleportGate`, class link 0xef1dac,
  through the same `FUN_008a6bd0`), but with their own body reader (CITeleportGate slot 25, not read
  here) and from teleportbuilding, not npcpos. They stay client-bound (`_bind_region_gates`); filed
  in docs/TODO.md.
- The npcpos NPC rows with no nest at their spot in the shard (EXTERNAL, MEASURED round 708 and its
  review): 29 at JoinTolerance. Every one has its `Tab_RefTactics` row (Jangan's
  `NPC_CH_SOLDIER_EM1` "Soldier Choiyoung [Teleport]" is tactics 1027, beside `_EM2`'s 1028 whose
  nest is 51); four have own-species nests elsewhere -- `NPC_CH_EVENT_KISAENG1` (nest 21022, its own
  region 26265, 58 units off), `NPC_BATTLE_ARENA_MANAGER` (nest 29729, the same region, 178 off),
  `NPC_CH_GACHA_MACHINE` and `_OPERATOR` (nests only in other regions); the other 25 have none. The
  nest ids around `_EM2`'s run 44, 45, 46, then 51: 47-50 are missing, which fits the shard having
  deleted the soldiers' nests (INFERRED).
- **The second pass (OURS, INFERRED):** a row with no nest at its spot takes the nearest unclaimed
  nest of its own species in its own region within `npcspawn.NearRadius` = 200 units, since the
  original's NPCs ARE its nests (npcpos is the client's table). On this shard that places exactly the
  two above (KISAENG1 at 58, ARENA_MANAGER at 178); no other row has an own-species nest in its
  region at any distance. 230 rows are placed from a nest, 27 at their npcpos position.
- **Where the NPC list comes from (OURS):** OpenSRO's server spawns the npcpos NPC rows, where the
  original spawns its nests. The difference shows on this shard: six custom world-1 nests in
  Donwhang (`NPC_TITLES`, `AVATARS`, `GOLDMINER`, `QUESTS`, `EGY`, a second `NPC_CH_SPECIAL`) have
  no npcpos row and are not spawned.
- **Retail has no "no angle" form** (read in the review): instance NPCs from `_RefGameWorldNPC`
  hatch with angle 0 (`FUN_00609970`), and the teleportdata row for `GATE_NPC_CH_SOLDIER_EM1` holds
  only an arrival point, no facing. OpNpcFacingUnknown and its stand-in are OpenSRO's alone.
