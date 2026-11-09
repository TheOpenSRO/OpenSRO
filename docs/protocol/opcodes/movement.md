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
- ~~`server/internal/proto/movement.go` still decodes the dungeon form as f32.~~ Fixed in round 749:
  `proto.Movement` carries three i32 for a dungeon and three signed i16 for a field destination.

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
  - ~~flag 1 snaps it to the source and clears its order;~~ **corrected in round 846:** flag 1 moves
    the mover's record to the source, re-places the drawn object only when it is more than 50.0
    from it, and clears the order only on the no-cell branch ("How an observer keeps up", below);
  - then a destination aims it when an order is in effect or it is more than 5 units off, with
    the catch-up factor (at most 3x) for a body drawn behind.

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

## How an observer keeps up, and every step reaches it (round 846)

The user: "if I take small steps it doesn't register on another client. It only registers when I
take a large step and it shows that I teleported away", "it only seems to happen at a higher
/speed". Labels: READ (`sro_client.exe` decompile and `.rdata`), MEASURED (the round's two-client
runs, `docs/WORLD_ISSUES.md`), INFERRED, OURS.

**The observer's reader (READ, `NetProcessInNavAndSkill::FUN_008a5750`, re-read this round).**

- An object with `+0x440` set is skipped. Otherwise the flag-1 source goes to `FUN_009e11e0(region,
  pos, 1)`, then a destination aims the mover (`FUN_009e0550`) when an order is in effect
  (`obj+0x714`) or the destination is more than 25.0 squared (`0xe1b8a0`) from the mover's record.
- **`FUN_009e11e0` does not move the drawn object.** It runs the collision query from the mover's
  record (`+0x4c`, `{cell, instance, region, x, y, z}`) to the source and copies the result into the
  record. Then `FUN_009e1050` measures the record against the object's own position (`obj+0x74`)
  with `FUN_009ecdb0` (x² + y² + z², then the CRT's root at `0xb42de0`, INFERRED from its shape) and
  only when that is **more than 50.0** (double `0xd8f0b0`) re-places the object through
  `GlobalDataManager::FUN_009e0d50`, which calls the object's vtable `+0x94` with the record. A
  body within 50 of the source stays where it is drawn. (The order flag `+0xac` is cleared only on
  the branch with no cell, `param_1[0x13] == 0`.)
- **`FUN_009e0550` sets a catch-up factor.** After storing the destination it measures two ground
  distances to it (`FUN_009ecc70`): from the mover's record (`+0x4c`), `r`, and from the object's
  position (`obj+0x74`), `d`. When `r < d` the mover's `+0x8c` becomes `d / r`, at most **3.0**
  (float `0xd8adc4`), and 3.0 (double `0xe1b808`) when `r` is 0; otherwise 1.0.
- The mover's tick `FUN_009e0e60` steps `speed * +0x8c * seconds` (when `obj+0x444` is 0; the
  speed slot `param_1[param_1[4] + 1]`), cut to the distance left.
- INFERRED: the factor makes a body drawn behind its mover walk on from where it is drawn and reach
  the destination when the mover does. Where `obj+0x74` follows the record each tick was not read.

**What OpenSRO did (MEASURED, base `857ec7be`, a prod-like lane server: no
`-trust-client-positions`, the navigation meshes; two real clients, 40 ms ± 20 ms each way):**

- **The mover's own walk stopped 2.39 short of its click** (`MOVE_TARGET_STOP_DISTANCE`, OURS since
  round 649 for every walk) while the server and every observer walked to the point. A 3-unit click
  moved the mover 0.6-0.8 and the observers 3.0-3.6; a click under 2.39 away moved nobody and sent
  nothing. Retail's mover lands on its destination (round 649, READ).
- **A click near the point still being walked to was walked here and never sent** (the server would
  refuse it, `0xb45b28`): the mover stood up to 5 from where the server and every observer had it,
  until its stop put it there in one jump. Retail's server refuses it and retail's client walks only
  on its echo, so nothing moves.
- **A click near the point just reached went out at once**, but this client's walk starts on the
  click and the server's one transit later, so the server's leg was still running: refused
  silently, no echo, the walk stopped a second later (`ECHO_TIMEOUT_MS`) and the stop was relayed
  as `0xB023` -- the observers saw no step and then a jump.
- **An observer took the source whenever its body was more than 32 from it** (the monsters'
  `RESYNC_DISTANCE`, OURS) and walked every leg at the bare run speed, so a body that fell behind (a
  raised `/speed` with real latency) was put forward on the next step instead of catching up.

**OpenSRO now (round 846):**

- `World3D._click_walk_stop`: a walk to a point ends **on** it (`CLICK_LAND_EPSILON` 0.01, a float
  tolerance); an attack's, a friendly cast's and a pick-up's approach keep the early stop (OURS).
- `World3D._move_click_refused`: a click within 5.0 (truncated as the wire carries it) of the point
  a walk is still going to is ignored, as the server refuses it (READ) -- not for an approach, whose
  point re-aims every tick.
- `MoveOrderSync.held` (OURS): a click within 5.0 of the point the server may still be walking to
  -- its echo's time plus the leg's length at the run speed, `confirm(free_ms)`; until the echo, the
  echo timeout -- is walked here at once and sent once the server's leg is over ("held"), whether
  or not the walk here has ended.
- `OtherWalk.RESYNC_DISTANCE` 50.0 and `OtherWalk.catch_up` (READ, above), for a body on foot and a
  rider; the factor is kept apart from the leg's speed, so a buff's new speed keeps it. OURS: the 50
  is measured on the ground, as the server's height for a player is a guess.
- Unchanged and READ: the server refuses a destination within 5.0 of the one it is walking to, and
  takes every other (`TestRound846EveryStepIsEchoedAtAnySpeed`); an observer is told a `/speed` by a
  token-less `OpBuffEnd` and a late one by the spawn record's run speed. ~~A stop (`0xB023`, an
  arrow key's release among them) snaps.~~ A stop within 50 is walked (below).

### The stop, and the Up key (round 846's follow-up)

**READ.**
- The 0xB023 reader `c:FUN_008a4f80` skips an object with `+0x440` set, then calls `FUN_009e00f0`
  and `FUN_009e11e0(region, point, 0)`.
  - `FUN_009e00f0` ends the movement (`+0x84`, `+0xac`, `+0x80` cleared). For a mover whose `+0xc`
    is 0 it also snaps the heading (`FUN_009e0050`) and points the travel direction
    (`FUN_009e0090`).
  - `FUN_009e11e0` is the same placement as 0xB021's source, so the drawn object is re-placed only
    when it is more than 50.0 from the point. **A stop does not snap a body within 50.**
- The drawn position is `obj+0x74`. `FUN_009c4610` builds the world position from `+0x7c..+0x88`.
  It is written only by vtable slot 37 (`FUN_009cf530`), called from the placement
  `FUN_009e0d50`, the skill step `FUN_009e0960` and a few UI paths. The mover tick `FUN_009e0e60`
  never calls it. How the drawn object follows the record during an ordinary walk was not found
  (OPEN).
- The Up key:
  - `FUN_009ebec0` -> `FUN_009ebd10` only builds and sends the heading form; nothing moves. The run
    starts on its echo (`FUN_008a5750` -> `FUN_009e08a0`).
  - The release, `FUN_009eb6e0`, only sends 0x7023 {angle}. The run ends on the server's 0xB023.
  - A press while the mover is still moving on a heading sends nothing (`FUN_009ebec0`'s window), so
    a press before the last release's stop arrives is dropped.

**OpenSRO now.**
- **Observers:** `World3D._other_stop_at` walks a body within 50 to a stop's point at
  `OtherWalk.CATCH_UP_MAX` times its speed, facing the message's angle. Beyond 50 the body is put
  there. The walk is OURS: retail's way of bringing the drawn object to the record was not read.
- **The mover:** `_own_arrow_stop` / `_own_settle` treat this player's own stop after an Up
  release the same way. A newer order supersedes the release's stop.
- **Riders:** a ridden COS's 0xB023 now ends its rider's leg (`_cos_move_stop`). It was dropped
  before.
- **OURS, kept:** the Up run starts on the press and ends on the release.
  - Either way the client's run and the server's differ by the network's jitter (MEASURED: 0-18
    units at /speed 1-10, 40 ms ± 20 ms).
  - An echo-started run reaches a wall one round trip after the server's run and the observers' runs
    started. The observers walk a straight line, so they ran that far past the wall: 50-90 units at
    /speed 10 (MEASURED).
  - An observer-side navmesh clip was tried and dropped: its probe met walls the mover's own carried
    footing did not.

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
- ~~The client's arrow-key handler `FUN_0077b070` (keys `0x26`, `0x25`, `0x27`) calls
  `FUN_009ebf40` with 1, 0x10 and 0x20.~~ **Corrected in round 808:** `FUN_0077b070` has no caller
  (dead code); the live handlers are the key-down `0x780610` and key-up `0x77d8d0`, and of the
  three commands **only 1 reaches the wire** (`FUN_009ebec0` writes 1). 0x10 and 0x20 are the
  client mover's own turn bits (`+0x88`); a turn reaches the server as `0x7024` (below, "The arrow
  keys"). The sky click sends 1 (forward).

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

**Superseded on the wire by round 749** (`docs/rounds/r749.md`): the sky click sends retail's
heading form of 0x7021 itself, once, and the window hears 0xB021's heading form; the run's end at a
wall is the client's stop report, relayed as 0xB023. The walk itself is unchanged: what follows
still describes the client's run.

Before round 749, OpenSRO's movement was client-authoritative positions (`OpMove`/`OpEntityMoved`),
not retail's 0x7021 requests that the server steps. So:

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

## The arrow keys: `0x7023`, `0x7024`, `0xB024` (round 808)

Labels as above; `c:` sro_client.exe, `s:` SR_GameServer.exe.

**Keys (READ).** The window's key-down handler `c:0x780610` switches on the virtual key: Up
(`0x26`) → `0x780690`, Left (`0x25`) → `0x7806e8`, Right (`0x27`) → `0x780721`. **Down (`0x28`)
has no case**; its key-up `0x9ebb90(2)` acts on no bit. Each case is gated by `FUN_0077c8e0() == 0`
(a window holding the keyboard, INFERRED the chat line) and `+0x3ce == 0` (the developer camera),
first calls `0x78f7c0` (sends `0x7074 [02]`, the action cancel, only in the attack state), then
`FUN_009ebf40(cmd)` with 1, 0x10 or 0x20. There is no test of the repeat bit, so each OS
key-repeat runs the case again. The key-up `c:0x77d8d0` clears the press's result and calls
`FUN_009ebb90(cmd)`.

**Up.** `FUN_009ebec0(facing, 0)` sends the heading form of `0x7021` with command 1 — unless the
body is already moving on a heading (state bit 9 and mover kind 2), so a held Up's repeats send
nothing. Its send `FUN_009ebd10` refuses while the record's `+0x48` block runs or the move gate
`FUN_009eb140` fails (`(+0x65c & 0x2476) != 0`: dead, acting, knocked down, **sitting**, picking up,
an emote). Up while seated therefore sends nothing and does not stand (the click's sit test,
`motion.md`, is never reached). Its release sends **`0x7023 {u16 angle of the facing}`**
(`FUN_009eb6e0`, the same refusals), moving or not.

**Left / Right.** `FUN_009e0930` sets the mover's turn bit; the mover tick turns the facing by
**`dt × π`** (`FUN_009e0c10`, double `0xd81948`): `+` for Left, else `−` for Right (Left wins). It
turns standing still, and a running body's path curves with it. No clip is played. During a click
walk (mover kind 1) the turn keys do nothing at all.

**The turn's send, `0x7024 {u16 angle}` (`FUN_009eb470(h, fine)`).** Sent only when
`|last_sent − h|` (unwrapped) is at least **π/4** (`fine` 0; double `0xde47f8`) or **1°** (`fine` 1;
float `0xde4800`):
- on each key-down of Left/Right, the OS repeats included: π/4;
- each frame of a heading run in effect while turning: π/4;
- on the turn key's release: 1° (and both turn bits clear, `FUN_009e0160(h, 0x30, 1)`);
- Up's 500 ms timer 7 while the run is plotted: 1°.

So a spin in place reaches the server in 45° steps at the key repeats and exactly at the release
(the user's "the server picks it up only a fraction of the time, or when it stops").

**The block.** `FUN_009eb130` sets `+0x48 = 500` from the attack/skill sender (`0x791f96`,
`0x7920c5`) and near `0x81c5b0`; the record's update counts it down. INFERRED: no `0x7021` /
`0x7023` / `0x7024` for 500 ms after an action request.

**Riding.** The two go out as `0x70C5 {u32 COS uid, u8 3 | 4, u16 angle}` (READ client side).

**The server.** Handler index `0x023` → `CGObjPC +0x5ec` = `GObjPC::FUN_004b12a0`: the angle, then
the slot-300 stop `FUN_004a9430(angle, 1)` (the `0xB023` above, the mover included). Index `0x024`
→ `+0x5f0` = `GObjPC::FUN_004b1360`: the current mover's `vslot_005(angle)` (the heading mover sets
the angle and keeps its forward bit, so a run bends and goes on), then **`0xB024 {u32 uid, u16
angle as received}`** to the 3 × 3, the mover included. Both are dropped when `CGObjPC::vslot_336`
(`+0x1d18`) answers (OPEN what state that is).

**Seated** (round 808's follow-up; the user: "A seated character in the original game spins with
the arrow keys"): the mover tick turns on the turn bits whatever the motion state, so the seated
body spins; every `0x7024` is refused by the move gate (the sit bit is in `0x2476`), so only this
client sees it until the next move. OpenSRO does the same.

**The client's `0xB024`** (`c:0x8a4ec0`): ignored for its own player; otherwise the body (or its
mount's mover) turns toward it at 3π rad/s and its travel direction points along it.

**OpenSRO.** Client: `KeyInput`'s arrow path → `World3D._on_arrow_key` (the press, each repeat, the
release), `_step_arrow_keys` (the turn and the run's sends), `_on_entity_turned`; `DestMoveNet`
`encode_angle` / `encode_cos_angle` / `decode_turn`. Server: `session/destmove.go`
`handleMovementStopRequest` / `handleMovementTurnRequest` (the ridden forms through
`coscommand.go`), `world.Hub.Turn`. OURS: the action cancel is local (no `0x7074 [02]` sender);
the run's 500 ms re-plot is only its 1° re-send; the
keys are let go when the window loses the focus or a text line takes the keyboard; the server's
60 s heading-run limit (round 749) still ends a straight held-Up run, a turn re-arms it.

## 0xB023, the stop (round 749)

READ this round from both decompiles on the box (`/var/tmp/decomp_server`, `/var/tmp/decomp_client`):

- **The composer** is the CGObjChar slot-300 stop, `GObjPC::FUN_004a9430(angle, send)`: when `send`
  is not 0 it begins `FUN_00430a00(0xb023)`, appends the object's uid (`param_1 + 2`, obj `+8`),
  calls `FUN_00487c80` (the angle through `FUN_00488050`, then the region and position at obj
  `+0x84`) and sends through `FUN_00484d90`, the 3 x 3 send 0xB021 uses. After it, a character
  whose motion state is WALK (2) or RUN (3) is set to STAND (vtable `+0x55c(0, 0xff, 0)`). The
  stop is called through vtable `+0x4b0` from about 40 places (skills, attacks, the sit); the arrival
  passes `send` 0, so an arrival sends nothing (as above).
- **The client** registers `0xb023 -> NetProcessInNavAndSkill::FUN_008a4f80` beside `0xb021 ->
  FUN_008a5750` (`funcs_010.c`, the dispatch table's `FUN_0086f740` calls). The reader takes 4 bytes
  (uid), 2 (region) and 0xe (x, y, z f32 and the u16 angle), ignores a dead object, turns the angle
  into a heading (`FUN_009c40b0`) and snaps the object there (`FUN_009e00f0`, `FUN_009e11e0`).

So: `u32 uid | u16 region | f32 x | f32 y | f32 z | u16 angle`, 20 bytes, region-local.

## Collision per kind of mover (round 851)

The user: "match the exact behavior of pets following you. Especially trade transports. Trade
transports aren't supposed to be able to go through walls and can [get] stuck ... on walls or even
trees. Reference the movement/collision info though for kind of mount and match it exactly".
Labels: READ (`s:` SR_GameServer.exe, `c:` sro_client.exe, objdump of the PE and the decomp dumps
on the render box), MEASURED, INFERRED, OURS, OPEN.

**The server's step (READ).** Every mobile object steps through one path:

- `CGObjMobile::Update` (`s:0x48b8c0`) asks its mover for the step (`CGObjMoverByDest::vslot_003`
  `s:0x48c4e0`, or `CGObjMoverByCmd` for a heading) and passes it to vtable slot 305 (`+0x4c4`).
- Slot 305 is `s:0x48b920` for a monster, an NPC and every CGObjChar kind; a PC's is `s:0x4ef300`,
  which steps only while the PC does not ride (slot `+0x540`, `s:0x4ddca0`: `+0x1d18` names a COS
  whose `+0x30` byte `+0xe` is 1); a COS's is `s:0x4d2b20`, which steps the COS and then puts its
  rider on it (`+0x1cd8`, the rider's slot `+0x620`). **So a ridden horse or transport is the
  mover, walked as a COS.**
- `s:0x48b920` -> slot 231 (`s:0x48b660`) -> `s:0x485740`, which asks the collision query
  `CRegionManagerBody::vslot_012` (`[0xcc387c]` slot 12, `s:0x98b300`) with the mover's position
  record (`+0x7c`), the proposed record and **two inputs taken from the mover**:
  - a flag: 1 when IGObj slot 7 (`CGObj::IsPC`, `s:0x482560`) or slot 11 (`CGObj::IsCOS`,
    `s:0x4827b0`) is true, else 0 (`s:0x48580c..0x485872`);
  - the object's `+0x38` (`s:0x485862`). `CGObj::vslot_000` sets it to 1 (`s:0x48492a`). A scan of
    every store to `+0x38` through a register in the binary (953 dword, 1,322 byte/word sites, mapped
    to their functions) found no other writer on a game object (MEASURED). Every other caller of
    slot 12 (the monster AI's probes, the skills' moves) passes 1 there itself.
- A refused step (`0x10000000`) leaves the mover where it was; bit 0 ends the movement after the
  step (above, "The stop at a wall"). A blocking edge is its flag byte `& 3` (edge slot 4,
  `s:0x9a7810`) whatever moves.

**What the two inputs change (READ).**

- `+0x38` reaches the object walk (`CRTNavMeshObj::vslot_002`, `s:0x9b5a80`) as its second
  argument: an outline edge with bit 0 stops a mover entering from outside only when it is exactly
  1 (`s:0x9b51e9`), and one with `0x02`/`0x10` stops a mover leaving only when it is not 0
  (`s:0x9b55ac`, the client's `param_6`, round 644). It is 1 on every object, so **object walls --
  buildings, town walls, lamps, tree trunks -- block every mover alike.**
- The flag never reaches the object walk (`s:0x9b5a80` does not read its first argument). In the
  terrain walk (`CRTNavMeshTerrain::vslot_002`, `s:0x9a0710`) it gates three re-checks of the cell's
  objects (`FUN_009a05a0`, which runs the object entry test `s:0x9a0030` with `+0x38` = 1): after an
  object stopped the step (`s:0x9a0a43`; without the flag the object's stop is taken as it is, with
  it the terrain is walked up to it and a hit refuses the step), at a cell crossing (`s:0x9a0bd2`)
  and at a region crossing (`s:0x9a0eb8`). The terrain wall's own stop re-checks for every mover
  (`s:0x9a0c7e..0x9a0cf8`, round 653).
- **Nothing else of the mover reaches the walk**: no radius, no BCRadius, no characterdata column,
  no model's collision mesh, no object-type test that lets one kind pass where another cannot.

**So (READ):** a player on foot, a horse, a trade transport and a pet -- ridden or following -- are
stopped by exactly the same edges at exactly the same points, with no slide. Monsters and NPCs
differ only in the flag's three re-checks; INFERRED to change a stop only where a terrain wall and
an object wall fall within one step of each other (OPEN against the original running; OpenSRO walks
every kind with the same walk).

**Why a transport sticks (INFERRED from the READ rules).** Not its collision: a following COS walks
a straight leg toward its owner's side (`cosai.go`'s FOLLOW, READ round 796) and its mover stops at
the first trunk or wall on that line; nothing walks it round. The rider, and a player on foot, stop
at the same trunk when they walk into it, and steer round it.

**The client (READ).** The mover's tick runs the same query on every step it draws (`c:0x9e0fca`):
the flag is 1 for the own player (IsKindOf CICPlayer `0xef1b44`, `c:0x9e0f45`) and for a CICCos
(`0xeef6f0`) whose owner (`+0x2b0` -> `FUN_00517250`) is the player (`c:0x9e0fb6..0x9e0fc3`), 0 for
everything else; the second argument is always 1 (round 644). So riding a transport into a wall the
own client stops at the wall itself, as the server does (its 0xB023 lands on the same point), and an
observer's client walks the transport into the wall and stops it there too.

**MEASURED, the data (`server/cmd/navcensus`, the user's archives on the render box, 97/168, 98/168
and 96/168):** every one of the 214 objects the three regions' `.nvm` lists has a navigation mesh in
the export (the `.nvm` lists only collision objects). 18 tree kinds, 91 placements; 89 of them are of
the 17 kinds whose outline edges block from outside (flag 3), e.g. `tre_smalltree01` (5 edges,
outline radius 4.5), `tre_pine03` (6, 5.6), `tre_tree01` (5, 4.8); `tre_gagi01`'s 50 outline edges
are all open (2 placements: a tree a mover walks onto). Probe walks fired through each placement's
origin from 8 directions: 1,378 of 1,712 blocked (trees: 550 of 728), every probe through
`tre_smalltree01`, `tre_pine03`, `tre_tree01`, every lamp and building (a probe that passes a big
tree misses a trunk off its origin; `tre_gagi01`'s walks, 14 of 16 blocked although none of its
outline edges blocks from outside, were not traced to the edge that stops them, OPEN). The server's walk meets them (round 812 parity, 395 of 400
of the client's own walks within 0.05).

**OpenSRO (round 851).**

- `session.MoverKind` / `Collider` (the two READ inputs) and `navWalkKind` / `moverLeg`: every kind
  walks the no-slide `navWalk`. A COS's leg ends at the first wall or tree (`cosLegEnd`, called where
  `cosRuntime.tick` starts a leg): the COS walks there and stands; a wall within 0.5 ahead leaves it
  standing (OURS, `navMinLeg`, as a monster's leg).
- OURS: the leg's 0xB021 names the stop (as a monster's leg does since round 812), not the
  destination and a later 0xB023 as retail's server sends.
- The client walks a COS's drawn leg on its navigation graph and stops it at a wall (`CosWalk`,
  `World3D._cos_step`; READ `c:0x9e0fca`), as it walks its own player. Other players' bodies still
  walk straight (`OtherWalk`, OURS, round 846): a wall reaches an observer as the mover's 0xB023.

**Round 852: every body an observer draws (READ, sro_client.exe).** The mover tick `FUN_009e0e60`
runs for every character that does not ride (`FUN_009d1d60`, CICharactor slot 9) and asks the query
at c:0x9e0fca with flag 1 for the own player and own COS, 0 for every other body. The client's query
(`CRegionManagerBody::vslot_012` c:0x412660) hands both arguments to the navmesh walk
(c:0x41290a..0x41291c); the terrain walk (`CRTNavMeshTerrain::vslot_002` c:0x4047a0) tests the flag's
bit 0 at three places only (c:0x404ab9, c:0x404c30, c:0x404f20 -- the cell-object re-checks, as the
server's) and passes it down unread elsewhere. So another player on foot, its ridden horse or
transport (the rider's body walks the mount's legs), a following COS and a monster are stopped at the
same edges as the own player, and drawn there. OpenSRO: `BodyWalk` (`client/scripts/world/
body_walk.gd`, round 851's `CosWalk` made general) -- each leg walked once on the graph when it starts
(`BodyWalk.plan`, `World3D._plan_body_leg`): clear, the straight step; walled, it ends at the walk's
stop; a heading run, a leg off its region or with no graph yet, and a terrain wall's send-back are
walked a frame at a time (`BodyWalk.step`). OURS: the one walk for the frame-by-frame one (MEASURED,
`tools/walk_probe.gd --bench-legs=3000` on 97/168: 397 of 400 walled legs' stops within 0.01 of the
frame-by-frame walk's, the worst 0.052; a plan 140 us at the median, a frame step 97 us); a frame's
plans capped at 1.5 ms (`BODY_PLAN_BUDGET_USEC`, the rest planned on later frames); the flag's three
re-checks not modelled.

## Where a mover stands, and how it was let into a rock (round 857)

The user: "I can sometimes clip into buildings and other parts of the map and then I can't escape",
with Pain stuck riding at Tarim Ferry. Labels as above.

**The position record (READ, `CRegionManagerBody::vslot_012` c:0x412660, s:0x98b300).** A mover's
record is `{+0 cell, +4 object instance (0: the terrain), +8 u16 region, +0xc x, +0x10 y, +0x14 z}`
(+0x18 a seventh word the client copies along, c:0x9e1244). The walk starts from the record's own
cell and object (`local_70 + 4`, the mesh's resolver; an object's cell through `+0xb0`) and hands the
next record back with the cell and object it ended in: **the footing is carried in the record from
step to step**, never re-derived from the height while walking.

**The point resolve (READ, c:0x403dd0 `CRTNavMeshTerrain::vslot_003`; the server's s:0x99fd90 is the
same).** `CRegionManagerBody::vslot_011` (c:0x412530, s:0x98b1d0) normalises the region and asks
the region's mesh for a record at `{x, y, z}`: the terrain cell first (`FUN_00403f30`, the terrain
height), then every object the terrain cell lists (`FUN_00403d10`: the point in the object's frame,
its cell under it and that cell's height), each taken only when `|h - y|` is **strictly less** than
the best so far (`fabs`/`fcomp`/`test ah,5`/`jp` at c:0x403e8c..0x403eaf). So a mover named at the
ground's height is on the ground, one named at a deck's height on the deck. A terrain cell flagged
blocked (`FUN_00403940` bit 0) is no record (`+0 = 0`). No reach above the height, no "highest".

**Who resolves (READ, c:0x9e11e0, the placement of a server-named point).** With a record already
(`+0x4c != 0`) the client WALKS its record to the named point (slot 12, flag 1 for the own player or
own COS, `+0x38` 1); `param_3 == 0` (0xB021's source, 0xB023): a refused or blocked walk falls back
to the point resolve (slot 11) at the named point; `param_3 != 0`: a refused walk leaves the mover,
a blocked one stands it at the wall. Without a record it is resolved directly (`FUN_009e0d50`).

**How OpenSRO let movers in (MEASURED).** OpenSRO's settle (`NavGraph.surface_at`, the server's
`Graph.SurfaceAt`) took the first object cell under the point over the terrain however far below it
lay, and the server re-settled every leg (each 0x7021 is one `World.Walk` from the stored point)
and the client re-settled after a correction, a teleport or a region change. A wall stop is
`ContactPush` (0.01) short of the crossing; a long cell's 0.0001 barycentric tolerance
(`triangleHeight`) reaches 0.01 past its edge when its altitude is over 100. So a walk into a
footprint buried under the ground stopped on the ground, and the next leg started ON the footprint:
every outline edge 0x03, so every way out blocked (0x02, s:0x9b55ac) and every way in open.
- Pain (prod DB, read only): saved at 90/143 local (806.875, 474.141), y -73.165 -- 0.01 north of
  outline edge 5 of `oas_tarim_rock_l_03` (object 3, at (835.14, -72.97, 349.54), yaw -0.9425, 24
  flat cells at -73.17, every outline edge 0x03), on its cell 4, 9.1 under the terrain (-64.05). His
  readout X:1621 Y:-350 is 90/143 local x 850..860, z 340..350: the rock's east lobe by edge 16,
  from inside (`server/cmd/navstuck`).
- The census (`navstuck -census`, the user's export, all 6,178 regions): 46,614 placements with a
  mesh, 44,575 with outline edges blocking both ways (1,707 kinds; 21,918 mostly 1 or more under
  the terrain: trees, rocks, cliffs, walls, Baghdad and Petra pieces); walks at each from 16
  directions: 506,174 wall stops, **32,977 of them settled inside by the old settle (24,089 on a
  footprint under the ground, 8,888 on one above it, e.g. Jangan's cj_luxury, floor 9.06 over the
  ground), at 9,649 placements**; 2,746 by the new, 2,742 of them stops whose own height is off the
  ground (the walk was already on that object, entered through an open edge) and 4 on an object
  flush with the ground.

**The heading run (MEASURED, round 812's list).** The server ran a heading run (sky click, arrow
keys) as a straight line until 0x7023 or 60 s; the original steps it through the same collision
query as every mover (READ above, "Collision per kind of mover"). Round 857 walks it (OURS: two
seconds of run ahead at a time, the 250 ms mover pass walking on; `world.Hub.WalkHeadingRuns`) and
ends it at the first wall with a 0xB023, as a walled 0x7021 leg.

**A claim past a wall (OURS).** The stop report (round 749, OURS) was taken within the slack and the
banked second wherever it lay; a claim the server's own walk from where it has the character cannot
reach (a wall more than 0.5 short of it) is now corrected (`world.Bound.Unreached`).

## Where the walk is in time (round 878)

The user: "I get teleported back to where I was, seems like server lag". Labels as above.

**READ.**
- The heading run's server step, `CGObjMoverByCmd::vslot_003` (`s:0x48c1b0`) ->
  `FUN_0048bff0` (`s:0x48bff0`): while the command's bit 0 holds (`+0xc == 1`), the step is
  `|speed (+0x174) x elapsed|`, capped at **160.0** (`0xb45ea8`, f32), along the run's direction
  (`+0x24`, `+0x2c`), each component under 0.01 (`0xb45df8`) zeroed. So the original's run is
  stepped every tick at its time's length and through the collision query (above, "Collision per
  kind of mover"); nothing of it waits.
- The client's mover steps by the frame's elapsed time (`c:FUN_009e0e60`, above): a stalled frame is
  one longer step, and the mover is where its time has it.

**What OpenSRO did (MEASURED, round 878's lane runs, prod's flags).**
- The server walked a heading run two seconds ahead at a time (round 857, OURS), and when one of
  those walks met a wall it kept the run's clear stretch at the walk's START: the run stood there
  until its time reached the wall, then jumped to it. The client's run went on, so the server was up
  to a whole walk behind (2 s of run: 100 units at 50, 258 at the user's 129). A stop at that wall
  was then refused and the player corrected back; a click meanwhile started its leg from the held
  point.
- The client walked in Godot's physics ticks, at most 8 a frame; a longer frame's remaining time was
  dropped (a 724 ms frame ran 6 ticks: 0.6 s, 30 units, lost), while the server's leg ran on.

**OpenSRO now.** `world.Hub.walkRuns` counts a walled walk's stretch as clear up to the wall
(`Mover.clear = wallAt`); `WalkClock` (client) walks the time a stalled frame dropped. The server
logs every correction, refusal and wall stop of a move at INFO (`session/movelog.go`).

## Not read

- ~~What the `+0x14` byte in the heading form is~~: the movement command (round 653, "The heading
  move", above).
- ~~When a sender picks `kind == 0`~~: the client's world click when the pick finds nothing within
  1000 units, and the arrow keys (round 653, above). The monster AI always supplies a destination —
  `AITactics_MoveAlongDirection`'s name describes how it *derives* the point (position + direction
  × distance), not the wire form it sends.
- ~~**The server mover's step cap** (`0xb45ea8`, `FUN_0048bff0`)~~: read in round 878 (below,
  "Where the walk is in time"). Whether the server sends a stop of its own when its navmesh ends a
  heading move is still not read.
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
- [x] Wiring (round 749, `docs/rounds/r749.md`): a player's walk is this message now. The client
      sends one 0x7021 per click (`DestMoveNet`, `MoveOrderSync`); the server answers 0xB021 to the
      3 x 3, the mover included (`session/destmove.go`), keeps the leg (`world.Mover`) and tells a
      stop with 0xB023. Monsters still move by OpenSRO's own OpMonsterMoved (round 533).
