# Movement — `0x7021`

The client's movement request, and the message the **server's own monster AI composes** to move a
monster. Facts only, per this directory's policy.

Recovered 2026-09-21 (round 364), from both binaries independently.

## Why this opcode matters more than its size suggests

Player movement and monster movement are **one path, not two**. `SR_GameServer.exe`'s wander
state hands its chosen destination to a routine that builds a `0x7021` message and sends it —
the same opcode `sro_client.exe` sends when a player clicks the ground
(`docs/protocol/client_senders.tsv` recorded the client half in round 336, before this round knew
what it carried). So implementing `0x7021` implements both.

## Payload

The destination is serialised by the same routine in each binary — `0x0048bad0` in the server,
`0x009ebbf0` in the client. The two are structurally identical; the **client's is what supplies
the field widths**, because its append helper takes an explicit byte count where the server's
does not.

| field | width | when |
|---|---:|---|
| `kind` | u8 | always |
| *extra* | u8 | only when the caller asks for it — the monster AI does not |
| **if `kind == 0`** — a heading, no destination | | |
| *(unnamed, offset `+0x14`)* | u8 | |
| `angle` | u16 | |
| **if `kind != 0`** — a destination | | |
| `region` | u16 | |
| `x`, `y`, `z` | ~~f32 ×3~~ **i32 ×3** (round 737) | when `region & 0x8000` |
| `x`, `y`, `z` | ~~u16 ×3~~ **i16 ×3**, raw region-local units (round 737) | otherwise |

`kind == 0xff` trips the server's own assert.

**Round 737's corrections** (READ, `docs/rounds/r737.md` has the addresses):

- **A dungeon destination is three i32, not three f32.**
  - The server's reader `0x48bc20` stores them as ints.
  - The server uses them with `fild` (`0x4b1109`, `0x48c362`).
  - The client fills them with ftol (`0x9ec0ca` -> `0xb42d10`, `cvttsd2si`) and reads them back
    with `fild` (`0x8a58ef`).
- **A field destination is three signed i16 of the raw local coordinates, truncated.**
  - The client's click builds it with `ftol` (`0x9ec080`); nothing scales it by 10.
  - The 0xB021 reader sign-extends it (`0x8a5640`).
  - Only 0xB021's *source* position is scaled by 10 (below).
- `server/internal/proto/movement.go` still decodes the dungeon form as f32. Nothing sends that form
  to it yet. This is OPEN, for the C3 work.

The region-or-float split is the position encoding this project already recovered elsewhere:
region span 1920, local coordinates `[0, 1920)`, and the high bit marking a world/dungeon
coordinate rather than a region-local one.

## The angle

	angle = round( radians × 57.295780181884766 / 360 × 65535 )    truncated to 16 bits

**A full turn maps to 65535, not 65536.** That is the constant the binaries hold, not a
simplification.

The three constants were read out of the PE images as IEEE doubles — not inferred from the shape
of the expression:

| | server `.rdata` | client `.rdata` | bytes | value |
|---|---|---|---|---|
| degrees per radian | `0x00b45c38` | `0x00dde8f0` | `00000020dca54c40` | 57.295780181884766 |
| | `0x00b45c30` | `0x00dde7a8` | `0000000000807640` | 360.0 |
| | `0x00b45c28` | `0x00dde7b0` | `00000000e0ffef40` | 65535.0 |

**The two binaries hold byte-identical constants** at unrelated addresses. Two independently
compiled executables agreeing to the last bit is the control on this formula.

57.295780181884766 is not 180/π (57.295779513082320) — it is the **float32** of 180/π widened to
double. The engine's degree conversion therefore carries float32 precision, and a reimplementation
that uses a full-precision 180/π will disagree in the low bits of the encoded angle.

## Controls

The same read was pointed at four constants whose values this project had already recorded from
the decompiled AI, as a check that the address→value mapping was right before the three unknown
ones were believed:

| address | expected (already recorded) | read |
|---|---|---|
| `0x00b46160` | 85.0, the wander leg's base distance | 85.0 ✓ |
| `0x00b45e58` | 30.0, the wander probe distance | 30.0 ✓ |
| `0x00b45e68` | −1.0, the reverse-direction multiplier | −1.0 ✓ |
| `0x00b45c84` | 1e-6, the speed epsilon | 1e-6 ✓ (as f32) |

That last row also settles the **widths**: the epsilon is a float32 and reads as garbage
(−6.47e15) when taken as a double, while the three angle constants read as garbage (1.08e-19, 0.0,
0.0) when taken as float32 and as exact round numbers when taken as doubles. The discrimination is
"meaningful versus garbage", cross-checked against four independently known values.

## The response — `0xB021` (round 366)

Round 365 deliberately left this out: `0xB021` is the conventional pairing for a `0x7021` request,
and conventional is not evidence. It is now read from the binary.

`GObjPC::FUN_004b0ea0` begins a message with `0xB021` through `FUN_00430a00`, which writes the
MsgBuf opcode field at `+0x1050` — the argument is dropped by the decompiler but is the literal at
the call site. It then appends one leading field and **the same movement destination this page
specifies**, through the `0x0048bad0` serialiser with the optional extra byte absent.

~~**Not read:** whether `0xB021` is a per-request acknowledgement, a broadcast to observers, or
both; and what the one leading field before the destination is.~~ Read in round 737: both (the mover and the 3 x 3), and the field is the u32 unique id (next section).

**`0x3021` is not a server opcode.** It appears in the client and **never in the server**, so
whatever it is, it is not the movement broadcast.

## 0xB021 in full, its recipients, and the server's gates (round 737)

READ from both binaries in round 737. The addresses are in `docs/rounds/r737.md`, where the plan to
move OpenSRO onto this message (crowd_scale.md's C3) is written up.

**The handler.** `GObjPC::FUN_004b0ea0` *is* the 0x7021 handler. It is entry 0x21 of the per-object
table at `0xccf110` (thunk `0x4b23e0` -> vtable `+0x5e4`, slot 377). The request is parsed by
`0x48bc20`.

**What it refuses**, silently (no reply on any path):

- a stunned PC (`+0xc44`);
- a PC that slot `0x540` answers 1 for (`+0x1d18` set with ride state 1);
- an interaction state other than 0 or 1 (a running trade);
- a kind other than 0 or 1;
- a motion state of 8, 0x10 or 0x12 (CHANGEMOTION and two others, INFERRED knockdown and knockback);
- a pending action (slot `0x5a0`);
- the abnormal-state bits `0xc1` or `0x4000`;
- a dead character (slot 301);
- a destination outside the 3 x 3 regions around the mover (`FUN_0048c2d0`: each region byte
  within ±1);
- while moving, a destination within 5.0 (`0xb45b28`) of the one already set.

The server checks **no navmesh, no speed and no distance** beyond the region rule. Collision is the
walk's, per step.

**What an accepted move does:**

1. It clears `chardata+0x13` (`FUN_004e0c60`).
2. It ends the buffs flagged to end on a move, sending 0xB072 for each.
3. It sends 0xB021.
4. It copies the position (`0x4a6940`).
5. It sets the motion state to WALK or RUN (`2 + (+0x155 != 0)`).

**The payload** (asm `0x4b0ff8..0x4b1197`; client reader `0x8a5750`):

| field | width | source |
|---|---|---|
| unique id | u32 | `obj+8` |
| movement | the destination serialiser `0x48bad0(0)`, no extra byte | kind, then (1) u16 region + i16 ×3 (i32 ×3 in a dungeon), or (0) the command byte + u16 angle |
| flag | u8 | 1 for the heading form always. For a destination: 1 when `acos(dot(heading, normalize(dest))) > pi/4` (`0xb460e0`). INFERRED: that test normalises the destination's absolute coordinates, an original defect, so 1 is always safe to send |
| (flag 1) source region | u16 | `obj+0x84` |
| (flag 1) source x | u16 `ftol(x * 10.0)` (`0xb45c60`), or i32 when the region has bit 15 | `obj+0x88` |
| (flag 1) source y | f32 | `obj+0x8c` |
| (flag 1) source z | as x | `obj+0x90` |

The client picks the x/z width by its *own* player's region bit (`[0xeef5ec]+0x7c`), and divides by
10.0 (`0xe1b840`).

**Who receives it:** `0x484d90` -> `CMsgBlockObject::FUN_00534150`. That is every PC in the mover's
block and its 8 neighbours, **the mover included** (`0x5342a0` adds every PC in the block's list,
with no exclusion).

**No position stream.**

- The server steps the mover itself:
  - `CGObjMoverByDest::vslot_003` `0x48c4e0` moves it by `min(|speed x dt|, 160.0)` (`0xb45ea8`,
    the cap that was not read before), cut to what is left;
  - it refiles the mover in its message block as it walks (`0x4858e0` -> `0x485bb0`).
- **Nothing is sent per step, and nothing on arrival.** The stop `FUN_004a9430(angle, 0)` sends no
  message.
- **A blocked or refused step sends 0xB023 to the 3 x 3, the mover included**:
  `u32 uid, u16 region, f32 x, f32 y, f32 z, u16 angle` (`0x487c80`; the client's `0x8a4f80` snaps
  the object there).
- Observers walk the destination themselves.

**The client's click** (`0x9ec570` -> `0x9ec240` -> `0x9ec080`):

- It sends `01 | region u16 | x i16 | y i16 | z i16`, 9 bytes, once per accepted click.
- There is no periodic send for a destination walk.
- The heading run alone sends 0x7024 {u16 angle} whenever its heading moves 1° or more (`0x9e0d50`
  -> `0x9eb470`).
- The client treats its own 0xB021 like anyone else's:
  - flag 1 snaps it to the source and clears its order;
  - then a destination more than 5 units off aims it.

## The optional extra byte has exactly one emitter (round 366)

Every call to the destination serialiser in the server passes `0` — the monster AI, the
`0xB021` responder, the flag/battle-arena handlers — **except `CGObjMobile::vslot_292`**
(vtable slot 292; a COMDAT twin at `0x0048b570` and `0x004a9c60`). That function writes a one-byte
**action kind** and, only when the kind is `3`, appends the movement with the extra byte present.

**Round 367 followed that one call site up and it terminates.** Slot 292 has exactly one caller,
`CMainProcess::FUN_00437e80`, and that function composes **`0x7005`** — `AGENT_GAME_LOGOUT_REQ`
(`observed_opcodes.md`). So the chain is closed and short:

	CharDataSavingCompleted -> FUN_00437e80 -> builds 0x7005
	    appends an id, then a state byte from an object's +0x50
	    (4 is forced when there is no object, or the flag argument is 0)
	    any other value -> CGObjMobile::vslot_292
	        re-emits the byte, and WHEN IT IS 3 appends the movement
	        destination with the extra byte present

**The optional extra byte is therefore emitted in exactly one message in the entire server: the
logout request.** A character logging out while in motion reports where they were headed.

What the state byte's values mean is **not claimed**. The only fact is that `3` is the value that
carries a movement destination; reading that as "moving" is the natural inference and is left as
one.

## A use-site that corroborates the interaction state

`FUN_004b0ea0`'s first gate reads `chardata + 6` — the exclusive-interaction state of
`docs/protocol/character_state.md` — and proceeds only when it is **0 or 1**.

That is round 361's 1-versus-2 distinction confirmed from a function with nothing to do with
trade: a character may move while a trade session is merely **opened** (1), and may not once it is
**established** (2). The movement gate and the trade code agree without sharing any code.

### A misreading this page nearly carried

The same function compares a value against `8`, `0x10` and `0x12`, and a filtered grep makes those
look like three more `chardata + 6` states. **They are not.** `cVar6` is reassigned between the
two blocks — the later comparisons are against the return of **vtable slot `0xfc`**, a different
getter whose identity is unread. Reading the whole body is what caught it; the grep alone would
have added three invented values to the state vocabulary.

## How the client turns a moved object (round 637)

Read from `sro_client.exe` (`docs/WORLD_ISSUES.md`, 637th round, has the full trace). OpenSRO's
`World3D` follows it in `client/scripts/world/remote_facing.gd`.

- **The reader.** `NetProcessInNavAndSkill::FUN_008a5750` is `0xB021`'s client reader.
  - The object id is followed by the movement (`FUN_008a5640`, this page's layout).
  - Then comes a one-byte flag. When it is 1, a source position follows. It is a u16 region, then
    an x, a 4-byte y and a z. The x and z are 2 bytes each, or 4 bytes each when the LOCAL player's
    region (`[0xeef5ec]+0x7c`) has its high bit set. The decompile divides both by 10.0
    (`0xe1b840`). `FUN_009e11e0` places the object there.
  - The component types were not settled from the disassembly; this is the decompile's reading.
  - A destination goes to the mover's `FUN_009e0550`. That happens when `obj+0x714 != 0`, or when
    the destination is more than 25.0 in squared distance (`0xe1b8a0`, `FUN_009ed1e0`) from the
    mover's CURRENT POSITION. That position is `obj+0x6bc/+0x6c0` = mover `+0x54/+0x58`; the
    mover is at `obj+0x668`.
  - `obj+0x714` is mover `+0xac`, the **movement order in effect**:
    - `FUN_009e0550`, `FUN_009e04b0` and `FUN_009e08a0` set it;
    - these clear it: the stop/position message (`FUN_008a4f80` -> `FUN_009e00f0`),
      `FUN_009e0150`, `FUN_009e11e0` and the skill-driven step `FUN_009e0960`;
    - the ordinary tick's arrival does NOT clear it. `FUN_009e0e60` clears `+0x84` only.

    So a still object that never had an order ignores a destination within 5 units of where it
    stands. Once it has had an order, every destination aims it.
- **The wire angle.** `FUN_008a5640` turns the u16 into radians (`/65535 * 360 * (pi/180)`).
  `FUN_009c40b0` then adds pi/2 (`0xe1b8f0`) and wraps into `[0, 2 pi)` to make the object's
  heading `h` (`+0x8c`). The spawn reader `FUN_009c3a70` does the same.
  - `h` faces `(sin h, 0, -cos h)` region-local (`0x9ec850`).
  - So a wire angle `a` faces `(cos a, sin a)`, measured from east toward north.
- **The aim.** `FUN_009e0550`:
  - takes the vector from the object (`+0x74`) to the destination, with y zeroed (`FUN_009ecc70`);
  - makes a heading of it (`FUN_009ed130`): `acos(-z/len)`, or `2 pi` minus that when `x < 0`;
    it keeps the current heading when `len <= 1e-6`;
  - calls `FUN_009e02f0(heading, 0)`.
- **The turn** (`FUN_009e02f0`):
  - The travel direction points at the target at once.
  - The facing turns the shorter way by `elapsed_ms * 9.42477798461914 / 1000` (`0xde3128`,
    `0xd83268`): **3 pi rad/s**.
  - Each frame, the mover's tick (`FUN_009e0e60` -> `FUN_009e0c10`) calls the turn again with the
    object clock's milliseconds since the last call. This continues until the step would pass the
    target, which then becomes the heading.
  - The heading-only form (`FUN_009e08a0`) turns the same way.
  - Nothing turns an object that has stopped.
- **Which paths snap and which turn** (round 637's review follow-up):
  - **Spawn.** `FUN_009d17e0` stores the spawn's angle (`+0x10c`, from `FUN_009c3a70`) with a bare
    `FUN_009c4260`, a SNAP. `FUN_009ca320` then aims the object only if it spawned moving: a
    destination -> `FUN_009e0550`, a heading -> `FUN_009e08a0`.
    - A new mover starts with no turn: its initialiser `0x9e0cd0` zeroes `+0xa4`.
  - **The stop/position message.** `FUN_008a4f80` -> `FUN_009e00f0` -> `FUN_009e0050` SNAPS the
    heading to the message's angle and ENDS the turn (`+0x88` bit 0 and `+0xa4` cleared). It also
    clears the order (`+0xac`) and `+0x84`.
  - **The angle-only message.** `FUN_008a4ec0` (object id, u16 angle, not for the local player)
    TURNS at 3 pi through `FUN_009e02f0(h, 0)`, unless mover `+0x94` is set. Either way it points
    the travel direction along `h` (`FUN_009e0090`).
  - **The byte-angle message.** `FUN_008a78b0` (object id, u8 angle over `0xd83108`) SNAPS with a
    bare `FUN_009c4260` and sets state 10.
  - **The skill action reader.** `FUN_00a54be0` SNAPS the caster with a bare `FUN_009c4260`,
    either to the message's angle (flag bit 0 clear) or toward a position (flag bit 8). The bare
    call does NOT end a turn in progress; the tick goes on turning toward `+0xa8`.
- **The local player's click** (`UI_SILKMALL::FUN_009ec240` -> `FUN_009eb2a0`; a return of 1
  sends the move):
  - **With no order in effect,** a click closer than 5 units (squared 25.0, 3-D, `FUN_009ed1e0`)
    is not sent.
  - **With an order in effect,** the move is not sent when all three of these hold:
    - the click is 100 or more units away (squared 10000.0, `0xd82efc`);
    - the order's destination (`obj+0x684/+0x688`) is also 100 or more away;
    - the angle between the two ground vectors (`FUN_0045c590`, y zeroed) is 0.0872664600610733
      (`0xdb9828`, 5 degrees) or less.

    Instead `FUN_009e04b0` re-aims the local mover at once, SNAPPING the heading through
    `FUN_009e0050`, and sets the caller's `+0x2c`.
  - **Every other click** is sent. Its echo (`0xB021` -> `FUN_008a5750` -> `FUN_009e0550`) turns
    the player at 3 pi, as it turns anyone else.
- **OpenSRO's protocol** (OURS) does not match retail's here:
  - `OpEntityEntered` carries the heading as this page's u16 wire angle, AFTER the snapshot (older
    clients stop at the gender and ignore it).
  - `OpMove`/`OpEntityMoved` carry a trailing relocated flag, so a placement is relayed as one and
    turns nobody.
  - The lists (`EnterWorldResult` and `ChangeZoneResult` others) carry the headings in a tail
    after `Seated`, which is then always written. The tail is a u16 count equal to the list's and
    a u16 wire angle per other. `EnterWorldResult` then adds the entering character's own. Older
    decoders stop at `Seated`.
  - The heading is saved with `-persist-position`'s position (`character.HeadingStore`). `_CHAR`
    declares no heading column; retail's persistence of facing is not read.

## How the client steps a mover and stops it at its destination (round 649)

Read from `sro_client.exe`'s decompile on the RE box (`/var/tmp/decomp_client`). OpenSRO's
`World3D._step_click_walk` follows it through `client/scripts/world/click_walk.gd`.

- **The tick.** `FUN_009e0e60` (the mover, `this` = `obj+0x668`) runs every frame. With no
  movement in effect (`+0x84 == 0`) it only turns (`FUN_009e0c10`, above). Otherwise it turns,
  then steps.
- **The step's length** is `speed * seconds`:
  - `speed` is the object's `+0x444` when that is non-zero. Otherwise it is the speed slot the
    mover's `+0x10` picks, times the mover's `+0x8c`.
  - `seconds` is the frame's elapsed time, the global `0x0110f7fc`.
- **The destination test.** When the mover walks to a destination (`+0x80 == 1`), the tick
  measures the ground distance from the mover's record at `+0x4c` to the destination record at
  `+0x30` with `FUN_009ecc70`. That helper reads a region word at `+8` of each record and the x
  and z at `+0xc` and `+0x14`, and adjusts for the region difference. The record's full layout
  was not settled: the step also writes `+0x4c..+0x54`. If that distance is **no more than the step**, then:
  - the step is **cut to the distance**, so the mover lands on the destination;
  - the movement ends (`+0x84 = 0`);
  - and `+0x80` is cleared unless an order is in effect (`+0xac`).
- **The move.** The new position is the old one (`+0x58..+0x60`) plus the travel direction
  (`+0x74..+0x7c`) times the step. It is taken only if the collision query (`[0x111a02c]` vtable `+0x30`) does not
  return bit `0x10000000`. That bit, and the failure path, end the movement. Bit 0 also ends it
  after the move is taken.
- **So a retail mover never passes its destination, at any speed.** OpenSRO's walk before round
  649 did pass it. It took a full step every tick until it stood within its own stop distance of
  2.39 units (OURS). With a step longer than 4.78 units (a run speed over about 287 at 60 ticks a
  second), it could jump across that band on every tick and never stop. Round 649 measured this
  live and adopted the cut. The early stop is kept, because the attack approach is built on it.
- **The same cut on the server** (SR_GameServer.exe): `CGObjMoverByDest::vslot_003` (`0x48c4e0`)
  also replaces a step longer than what is left with `dest - position`. OpenSRO already draws
  monster legs that way (`client/scripts/world/monster_motion.gd`, `MonsterMotion.step`, READ).
- **A refused step ends the move** (round 649's follow-up). This is the failure path above:
  bit `0x10000000`. OpenSRO's walk now ends a click walk whose step the navigation graph blocks
  dead (`ClickWalk.blocked_ends`), instead of holding its order with the run animation playing.
  - ~~OURS: OpenSRO's graph slides along a wall. "Dead" means a blocked step that covers no more
    than 1 % of what was asked.~~ Superseded by round 653's follow-up. Retail's query does not
    slide (see "The stop at a wall" below). Every OpenSRO order now walks with the no-slide walk
    and ends at its first blocked step (`ClickWalk.blocked_ends`).
  - An attack's or friendly cast's approach ends at the wall like any walk. Its pending action is
    kept, and `World3D._step_move_order` re-issues it on the next tick. This follows retail's
    attack tick, which re-issues `MoveTowardObject` on every pass while out of reach
    (`docs/protocol/auto_command.md`, phase 1, READ).
- **Not read:** what the collision query tests, which of its bits mean what beyond the two above,
  and whether a server-driven mover uses this same tick.

## The heading move: a click on the sky (round 653)

Read from `sro_client.exe`'s decompile (`/var/tmp/decomp_client`), its disassembly
(`/var/tmp/sro_client.asm`) and its PE image; the server half from `SR_GameServer.exe`'s decompile.
OpenSRO follows it in `client/scripts/world/sky_run.gd` (`SkyRun`) and `World3D._move_by_pick_ray`.

### The click

- **The world click** is `UI_SILKMALL::FUN_0078f8d0`. For a click that is not on an object it:
  - builds the pick ray with `FUN_00a5ade0`: the camera's position, and the camera ray through the
    cursor times **5000.0** (`0xde5188`) added to it;
  - takes the direction as the difference of the two (`0x78fa2e..0x78fa69`);
  - calls the world pick, `SWorld::vslot_034` (`0xa01310`; `DAT_01101950`'s vtable `0xde4fb4`,
    slot 34, offset `0x88`), with the player's position record, the ray's origin and direction, and
    two out-parameters (region, point).
- **The pick's reach is 1000 units.** `vslot_034` normalises the direction (`FUN_00410cd0`) and
  multiplies it by the double at `0xd83268`, **1000.0** (asm `0xa01333..0xa01368`). It tests the
  terrain blocks (up to 10, `+0x2783`) and then the objects (`[0x111a02c]` vtable `+0x3c`) against
  the segment origin → origin + direction × 1000. It returns 1 only when something was hit (the best
  distance stays below its start value `0xe1b85c`, 1e38).
- **A hit** walks to the point (`FUN_009ec570` → the destination form, as before).
- **No hit**, whether sky or ground more than 1000 units from the camera, sends the **heading form**:
  - the direction's y is zeroed (`fldz` into it at `0x78fb07`), the vector is normalised
    (`FUN_00410cd0`), and `FUN_009ed130` makes a heading of it. This is the same helper as a
    destination's aim, so a vertical ray keeps the current heading;
  - `FUN_009ebec0(h, 1)` sends it:
    - kind 0;
    - the record's `+0x14` byte = **1** (`local_4 = 1`);
    - the angle `FUN_009c4060(h)` = h − π/2 (`0xe1b8f0`), with 2π (`0xd81930`) added while negative;
    - then `FUN_009ebd10` → `0x7021`, with no extra byte.
  - `FUN_009ebd10` sends `0x70c5` instead, with an object id first, when `FUN_00b94b90(0xef1b44)`
    is false. What that flag is was not read.
- **The no-resend window.** The heading is NOT sent when all three of these hold:
  - bit 9 of the player's state word `+0x65c` is set;
  - `+0x6e8` is not 1;
  - `|+0x8c − h|` is 0.0872664600610733 (`0xdb9828`, 5°) or less.

  The difference is raw: `fsub`, then `fmul −1.0` (`0xe1b8e8`) when negative, with no wrap. Bit 9
  is state 9 of the object's state machine. `FUN_009c9920(9, 0)` sets it on every `0xB021` echo
  (`FUN_008a5750`), of either form. That it means "moving" is INFERRED.
  - **`+0x6e8` is the mover's `+0x80`**, the move kind: the mover sits at `obj+0x668`, and
    `+0x80` is 1 for a walk to a point and 2 for a heading. This is round 653's review, READ.
  - `FUN_009ebec0` returns early only when it is 2. So the window keeps only a **heading run**. A
    sky click within 5° of the facing during a ground walk starts a run.
- After sending, `FUN_00777b90` → `FUN_00b93320(7, 500)`; what that does was not read.

### The `+0x14` byte is the movement command (READ, the server's mover)

The heading form's byte was "not read" above. It is now:

- `CGObjMoverByCmd::vslot_004` (server `0x48c140`) copies the form in. When the byte's **bit 0** is
  set, it sets the mover's stepping flag `+0xc`.
- `vslot_003` (`0x48c1b0`) steps while `+0xc == 1`, through `CGObjMoverByDest::FUN_0048bff0`. That
  step is the object's heading vector (`+0x24`, `+0x2c`) times `|speed × dt|`, capped at the float at
  `0xb45ea8`, which was not read. It has no distance and no end of its own.
- `vslot_010` (`0x48c1e0`) turns the heading by `dt × π` (`0xb45c20`) one way for **0x10** and the
  other way for **0x20**, wrapped by 2π (`0xb45c18`).
- `vslot_005` keeps the low nibble (it ends a turn); `vslot_006` clears it and `+0xc` (it ends the
  step).
- The client's arrow-key handler `FUN_0077b070` (keys `0x26`, `0x25`, `0x27`) calls
  `FUN_009ebf40` with 1, 0x10 and 0x20. The sky click sends 1 (forward).

`proto.MovementCommandForward` names bit 0.

### The run

- The echo's heading form reaches the local mover as `FUN_009e08a0` (from `FUN_008a5750` when the
  kind is 0). It sets:
  - `+0x80 = 2` (no destination);
  - `+0x84 = 1` (moving);
  - `+0xac = 1` (an order);
  - the travel direction at once (`FUN_009e0090`);
  - the facing turned toward it at 3π rad/s (`FUN_009e02f0`).
- The mover's tick `FUN_009e0e60` tests a destination only when `+0x80 == 1`. So a heading move
  steps `speed × seconds` along the travel direction on every frame, with nothing to arrive at.
  Round 649's cut to the distance left does not apply to it.

### The stop at a wall

- The tick hands the proposed step to the collision query, `CRegionManagerBody::vslot_012`
  (`0x412660`; the object at `0x115b0c8`, vtable `0xe16184`, slot 12). The call passes the mover's
  record at `+0x4c` and a proposed record `{0, 0, region, x, y, z}` built on the stack.
- On success the tick copies the whole proposed record back into `+0x4c..+0x60` (asm
  `0x9e0fff..0x9e1027`). So the position is **whatever the query left in the record**. The
  decompile's reading of `+0x4c` as the step's delta is wrong: a `pop ebp` right after the call
  misled it.
- `vslot_012` walks the navmesh cell by cell (up to 7 hops) through each cell's resolver. For the
  terrain this is `CRTNavMeshTerrain::vslot_002`, `0x4047a0`. At an edge whose vslot `+0x10` says
  blocking, the resolver sets the point to the crossing, moved toward the cell's centre by at most
  0.2 (`FUN_004472d0`, `0xe1b850`), and **returns 1**.
- Bit 0 ends the movement after the step is taken (`+0x84 = 0`, `+0x80 = 0`). The body therefore
  **stops at the wall**. There is no component along the wall in that branch, so it does not
  slide. This is the same terrain walk `NavGraph.step_tracked`'s no-slide mode already follows
  (rounds 616–618).
- Bit `0x10000000` (a refused step) also ends the movement, with the body where it was.
- The tick does not clear `+0xac` (the order) on either path.
- **What plays:** the movement ends, so the body is no longer moving. Nothing in the tick plays a
  collision animation. That it stands with its ordinary stand is INFERRED from the mover's state
  alone.
- **What the server is told:** nothing in the client's tick sends anything at the stop. The server
  runs its own mover (`CGObjMoverByCmd`). Whether it sends its own stop to the watchers when its
  navmesh refuses a step was not read.

### OpenSRO (OURS framing, READ form)

OpenSRO's movement is client-authoritative positions (`OpMove`/`OpEntityMoved`), not retail's
0x7021 requests that the server steps. So:

- **The run is the client's.** A sky click (no pick hit within 1000) starts a heading run
  (`World3D._start_heading_run`). `_step_click_walk` steps it at the full run speed (`/speed`
  included). `_move_on_nav_graph` walks it with the no-slide walk and ends it at the first blocked
  step (`SkyRun.blocked_ends`). The body then plays its stand, as after any walk.
- **The wire.** Each `OpMove` sent while the run is in effect sets bit 1 of the trailing flags byte.
  Retail's heading form follows it: kind 0, command 1, then the u16 angle, as
  `proto.DecodeMovement` reads it. An older server reads bit 0 alone.
- **The relay.** The server faces the character the run's heading (`world.Hub.MoveHeading`,
  `world.HeadingFromWire`) and relays the same form in `OpEntityMoved`. A watcher's client turns the
  body to the heading at 3π rad/s (`_on_entity_moved`), rather than toward the next position.
- **The stop** is the last position, sent plain. The watcher's body settles on it and stands.
- OURS: while a run is in effect, `_move_target` is the pick's reach along the heading, for the
  ground click's own filter. What retail's destination record holds during a heading move was not
  read.
- OURS: with no navigation graph under the player (the physics fallback), an order that meets
  a physics wall (`is_on_wall`) ends too.
- **Every order stops at the wall** (round 653's follow-up), as this reading says retail's mover
  does for any movement kind. This covers a click walk, a pick-up walk and an attack's or friendly
  cast's approach. A walk at an angle into a door frame now stops at the frame, where it used to
  slide into the doorway.
  - A blocked approach keeps its pending action and is re-issued every tick.
  - OURS: while its point stays within 0.5 of the one the wall stopped, it stands at the wall
    facing the target instead of stepping into the wall again. Each no-slide stop nudges the body
    up to 0.2 toward its cell's centre, and at 60 re-issues a second that crept it along the wall
    by 22.7 units in 2 s (MEASURED, `click_walk_test.gd`).
  - Only the QA walk (`OPENSRO_QA_WALK`, no order) still slides.

## Not read

- ~~What the `+0x14` byte in the heading form is~~: the movement command (round 653, "The heading
  move", above).
- ~~When a sender picks `kind == 0`~~: the client's world click when the pick finds nothing within
  1000 units, and the arrow keys (round 653, above). The monster AI always supplies a destination —
  `AITactics_MoveAlongDirection`'s name describes how it *derives* the point (position + direction
  × distance), not the wire form it sends.
- **The server mover's step cap** (`0xb45ea8`, `FUN_0048bff0`), and whether the server sends a stop
  of its own when its navmesh ends a heading move.
- **Bit 9 of `+0x65c`** (state 9), which gates the sky click's no-resend window. That it means
  "moving" is INFERRED. `+0x6e8` is read: the move kind (round 653's review).
- **What the optional `extra` byte at `+1` carries.** Which caller emits it is now known; what it
  means is not.
- **Vtable slot `0xfc`**, whose 8 / 0x10 / 0x12 returns block movement.

## For OpenSRO

This is a **destination format, not reference material**: `PROTOCOL_DECISION.md` (2026-08-22) sets
the goal as a real wire-level reimplementation, with the own-designed opcodes in
`server/internal/session` named as placeholder scaffolding. `docs/TODO.md`'s outstanding "move
packet the client interpolates" is this opcode.

It does **not** unblock monster movement on its own. That still needs the server to step a
monster's position on a tick and the client to receive it; today the client asks for monsters only
on events, so movement with no push would make them jump rather than walk (round 362).

## Status / next steps

- [x] Opcode confirmed from both binaries (server composes it, client sends it)
- [x] Payload layout confirmed, with field widths from the client's twin serialiser
- [x] Angle formula confirmed, constants read from both PE images and byte-identical
- [x] **Implemented** — `server/internal/proto/movement.go`, `OpMovementRequest`.
      `EncodeMovementAngle`, `Movement.Encode`, `DecodeMovement`. The first real
      payload layout encoded in that package rather than only documented.
      Tested byte-for-byte against the layout table above, and both key
      constants are mutation-checked: replacing 65535 with 65536 makes a full
      turn wrap to 0 and fails, and substituting full-precision 180/π fails.
- [x] The `+0x14` byte's meaning: the movement command, bit 0 forward, 0x10/0x20 turn (round 653)
- [ ] What the optional `extra` byte at `+1` carries, and which callers pass non-zero
- [x] When a sender picks the heading form over a destination: the sky click, the arrow keys (round 653)
- [x] The server's response opcode — **`0xB021`, read from the binary** in round 366 and now in
      `opcodes.go` as `OpMovementResponse`. Round 737: both, to the mover and its 3 x 3 blocks, with the u32 unique id first (0xB021 in full, above)
- [x] Which caller emits the optional extra byte — `CGObjMobile::vslot_292`, action kind 3
- [ ] Wiring: nothing calls this yet. It is the target format for `docs/TODO.md`'s
      move packet, and monster movement additionally needs the server to step
      positions on a tick and push them (round 362)
