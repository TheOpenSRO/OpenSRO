# Player spawn: the record of another player, and the messages that carry it (round 737)

READ from `SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/srgs.asm` on the render box) and
`sro_client.exe` (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm`). Labels: READ, MEASURED,
INFERRED, OURS, OPEN.

Since round 737 OpenSRO sends the other players the way the original does: as the spawn messages
`docs/protocol/npc_spawn.md` already describes for NPCs, with a PC's record.

- **Server:** `server/internal/pcspawn` writes the record. `server/internal/session/playerview.go`
  decides who gets which message, and `pcrecord.go` fills the record.
- **Client:** `client/scripts/net/user_spawn.gd` reads it, and `NetClient` routes it to `World3D`'s
  existing arrival path.

The interest area and the message rules are in `crowd_scale.md` (C1) and `docs/rounds/r737.md`.

## The writers and the readers (READ)

**The server's writers.** All of them take the stream in ESI:

| Function | Writes |
|---|---|
| `FUN_00409ae0` | u8 |
| `FUN_0048bee0` | u16 |
| `FUN_004958c0` | u32 |
| `FUN_004ac470` | f32 |
| `FUN_0042e7b0` | bytes |

A string is a u16 length (from `lstrlenA`) and then its bytes, with no NUL.

**The client's readers.** `MsgStreamBuffer::Read` is `0x4f7220(dst, n)`, and `0x4f7a70` reads a u16-length
string.

**The call order on the server** (mode 2 = the spawn record):

- `CGObjPC::vslot_294` `0x4e5a10` → `CGObjPC::vslot_293` `0x4e5b00`
- `0x4e5b00` → `GObjPC::FUN_004a9b70` (CGObjChar slot 293)
- `0x4a9b70` → `CGObjMobile::vslot_293` `0x48b630`
- `0x48b630` → `0x484fb0` / `0x487ce0` → `0x48be00`

**The call order on the client.** `FUN_008a6bd0` reads the RefObjID. It then calls the object's slot 25,
which for a CICUser is `GlobalDataManager::FUN_009de2f0` (vtable `0xde2e7c`). That function's readers are:

- slot 22 `0x9dbc30`;
- slot 23 `0x9ddc40` → `0x9d1300`.

Slots 24 `0x9dade0`, 28 `0x9c7780`, 27 `0x9dbcc0` and 16 `0x9db940` read nothing.

**Every field below is written in mode 2 and read by CICUser in the same order and width** (READ).

## The record

| # | Width | Field | Server | Client | OpenSRO writes |
|---|---|---|---|---|---|
| 1 | u32 | RefObjID | `CInstancePC::vslot_010` `0x8412b0`: instance `+0x28` | `0x8a6bd0` | the character's body (`modelOf`) |
| 2 | u8 | Scale (Height low nibble, Volume high) | instance `+0x64` | slot 22 → `+0x794` | the character's scale byte |
| 3 | u8 | HwanLevel | instance `+0xf2` | slot 22 → `0xef1bb8` | 0 (OURS: not modelled) |
| 4 | u8 | PVP cape | PC `+0x21ec` (`0x4e5a3d`) | slot 22 → `+0x824`; slot 25: 1..5 | 0 |
| 5 | u8 | AutoInvestExp | instance `+0xa8` (`0x4e5a4f`) | slot 22 → `0xef1bb9` | 0 |
| 6 | u8 | inventory size | storage capacity | read, dropped | 109 = `inventory.DefaultBagSlots` + 13 (OURS) |
| 7 | u8 | item count | equip slots 0..8 holding an item | loop | the worn count |
| 8 | u32 + u8 | each item: RefItemID, then the plus **for a TypeID 3/1 item** | `CInstanceItem::vslot_010` `0x42e230` mode 2 | `0x9de350` | slots 0..8 ascending, the effective plus (OptLevel + advanced elixir) |
| 9 | u8, u8 | the avatar list: size, count (then items) | the avatar storage | `0x9de3e2` | 5 (INFERRED), 0 |
| 10 | u8 | has mask | PC `+0x21a0` non-null (`GObjPC::FUN_004dd6b0`) | `0x9de4ba` | 0 |
| 11 | u32 | unique id | `0x484fb0`: obj `+8` | `0x9c3a70` | the character id's low 32 bits (OURS, round 710's rule) |
| 12 | u16 | region | `0x487ce0`: `+0x84` | `+0xfc` | `worldmap.FromWorld` in the zone's frame |
| 13 | f32 ×3 | x, y, z (region-local) | `0x487d90` | `+0x100..+0x108` | the same |
| 14 | u16 | angle | `0x488050` | `+0x10c` (+ pi/2) | `proto.EncodeMovementAngle(world.WireAngle(heading))` |
| 15 | u8 | has destination | `0x48be00`: mover `+0x154` | `0x8a5640(.., 1)` | 0 (OURS: positions are the client's) |
| 16 | u8 | run flag | mover `+0x155` | +1 | 1 (INFERRED: the mover's default) |
| 17 | u8, u16 | (no destination) source byte, angle | mover `+0x168`, `+0x164` | `+0x14`, `+0x10` | 0, the angle again |
| 18 | u8 ×4 | life, [1], motion, body mode | chardata `[0..3]` (`0x4a9b70`) | `+0x271`, `+0x273`, `+0x272`, `+0x470` | life from the hub; 0; `motions.state` (4 = SIT); 1 while berserk (round 651's value) |
| 19 | f32 ×3 | walk, run, param 140 | params 23, 24, 140 | `+0x254`, `+0x258`, `+0x4e8` | 16 (MEASURED: characterdata column 46); `buffBooks.RunSpeed`; 100 (READ, `0x4e3200`) |
| 20 | u8 | buff count | `0x59cdc0` | `0x9d1300` | 0. OpenSRO's buffs follow the spawn as its own `OpBuffStart` (a DEPARTURE in carrier only) |
| 21 | u16 + bytes | name | the char name when the job state is 4, else the job alias | `+0x110` | the character name |
| 22 | u8, u8 | job type, job level | `0x60e370` | `+0x7be`, `+0x7bf` | 0, 0 (OURS: no job system) |
| 23 | u8 | PvP state | chardata `+0xc` | `+0x50c` | 0 |
| 24 | u8 | ride state | chardata `+0xe` | `0x9ca2f0` | 0 (a 1 adds the ridden object's u32) |
| 25 | u8 | battle state | chardata `+0xd` | `+0x7bd` | 0 |
| 26 | u8 | teleport state | slot 72 (chardata `+0x10`) | `+0x7c0` | 0 |
| 27 | u8 | interact mode | chardata `+6` | `+0x471` | 0 (a 4, a stall's owner, adds the stall block) |
| 28 | u8 | trade rank | `0x60c330` | `+0x50e` | 0 |
| 29 | u16 + bytes | guild name | when a membership exists | `+0x7e4` | empty |
| 30 | guild block, **only while the job state is 4** | u32 guild id, u16 + bytes nickname, u32 ×3, u8 "no membership", u8 fortress role | `0x4e5d3b..0x4e5eb3` | `0x9ddf84..0x9de054` | the no-guild form: all zero |
| 31 | u8 | timer byte | `0x4e5f54..0x4e5fa3` | `0x9dafe0` → `+0x7bc` | 0 |
| 32 | u8 | world team byte | `0x669f00` / `0x645b70` | `+0x81d` | 0xff (READ for world 1) |

### Notes on the table

- **Rows 7 and 9:** the server writes the count byte only when the size is non-zero, but the client
  always reads it. A size of 0 is therefore never sent (`pcspawn.Append` refuses it).
- **Row 8:** every item in equip slots 0..8 is TypeID 3/1, because only equipment can be worn there.
  So every item OpenSRO lists carries its plus byte. The accessories (slots 9..12) are not in the
  record.
- **Row 21's and row 30's job state** comes from the suit in equip slot 8:
  - TypeID 3/1/7/1..3 gives its TypeID4;
  - anything else gives 4.

  The server (`0x4e124e`) and the client (`0x9db8b0`) agree on this rule. OpenSRO asks its item table
  (`session.SetSpawnItemRefs`), and the client asks World3D's (`NetClient.set_spawn_item_rows`).
- **0x3015** is the record plus a u8 spawn type (`FUN_00533f70`; the client's `FUN_009c2180` stores
  it at `+0xf4`):
  - READ: a walk's block crossing passes 4 (`0x485b36`). That the stack slot is that argument is
    INFERRED.
  - OPEN: the world entry's and the zone change's values. OpenSRO sends 4 for them too (OURS).
  - OpenSRO's client does not read it.
- **0x3016 and the type-2 group** carry u32 unique ids, the same for every class (READ:
  `FUN_00534050`, `FUN_00533b90`).
- **The group's data frames** carry 4,052 bytes each. This is READ: the message buffer's capacity of
  0x1000 (`0x471500` / `0x471580`), less the 6-byte header, less the `0x2209 {u32, u16}` envelope to a
  player, less the 0x20 that `FUN_00430a20` keeps back. That the AgentServer strips the envelope is
  INFERRED.
  - The client appends any amount (`0x833380`; pages of 4,096 with no cap).
  - The client asserts on a second 0x3017 before the 0x3018 (`0x8abfa0`), so groups must not
    interleave. OpenSRO sends each group in one `SendFrames` batch.

## Which class a record is

`FUN_008a6bd0` creates the object from its RefObjID's TypeID (READ).

OpenSRO's client reads each record as soon as its group ends, before it has characterdata. So it
takes the 52 creatable Figures' ids as the players: 1907-1932 and 14875-14900 (MEASURED,
`CharacterNet.gender_of_model`). This classification is OURS. Any other id is read as an NPC.

A player record waits for World3D's item table. Until World3D has handed that table over, any group
holding a player record waits in `NetClient._pending_spawns`. Every spawn message after it waits
too, in order.

## OPEN

- The 0x3015 spawn type for the world entry and the zone change.
- The meaning of chardata `[1]`, the timer byte's state kind 0xe, the stall's u32, and the three
  guild u32s' names.
- Whether manager `0xd6a9fc` ever holds world 1. If it did, the team byte would be its entry
  instead of 0xff.
