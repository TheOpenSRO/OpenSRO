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
| `x`, `y`, `z` | f32 ×3 | when `region & 0x8000` |
| `x`, `y`, `z` | u16 ×3 | otherwise |

`kind == 0xff` trips the server's own assert.

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

**Not read:** whether `0xB021` is a per-request acknowledgement, a broadcast to observers, or
both; and what the one leading field before the destination is.

**`0x3021` is not a server opcode.** It appears in the client and **never in the server**, so
whatever it is, it is not the movement broadcast.

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

Read from `sro_client.exe` (`docs/WORLD_ISSUES.md`, 637th round, has the full trace). srrevamp's
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
- **srrevamp's protocol** (OURS) does not match retail's here:
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

Read from `sro_client.exe`'s decompile on the RE box (`/var/tmp/decomp_client`). srrevamp's
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
- **So a retail mover never passes its destination, at any speed.** srrevamp's walk before round
  649 did pass it. It took a full step every tick until it stood within its own stop distance of
  2.39 units (OURS). With a step longer than 4.78 units (a run speed over about 287 at 60 ticks a
  second), it could jump across that band on every tick and never stop. Round 649 measured this
  live and adopted the cut. The early stop is kept, because the attack approach is built on it.
- **The same cut on the server** (SR_GameServer.exe): `CGObjMoverByDest::vslot_003` (`0x48c4e0`)
  also replaces a step longer than what is left with `dest - position`. srrevamp already draws
  monster legs that way (`client/scripts/world/monster_motion.gd`, `MonsterMotion.step`, READ).
- **A refused step ends the move** (round 649's follow-up). This is the failure path above:
  bit `0x10000000`. srrevamp's walk now ends a click walk whose step the navigation graph blocks
  dead (`ClickWalk.blocked_ends`), instead of holding its order with the run animation playing.
  - OURS: srrevamp's graph slides along a wall (`NavGraph.step_tracked`). "Dead" therefore means
    a blocked step that covers no more than 1 % of what was asked. Whether retail's query slides
    was not read.
  - An attack's or friendly cast's approach is left walking. The retail attack tick re-issues
    `MoveTowardObject` on every pass while out of reach (`docs/protocol/auto_command.md`,
    phase 1, READ).
- **Not read:** what the collision query tests, which of its bits mean what beyond the two above,
  and whether a server-driven mover uses this same tick.

## Not read

- **What the `+0x14` byte in the heading form is.** Its width is settled at one byte; its meaning
  is not, and no name is proposed for it.
- **When a sender picks `kind == 0`** (heading) over a destination. The monster AI always supplies
  a destination — `AITactics_MoveAlongDirection`'s name describes how it *derives* the point
  (position + direction × distance), not the wire form it sends.
- **What the optional `extra` byte at `+1` carries.** Which caller emits it is now known; what it
  means is not.
- **Vtable slot `0xfc`**, whose 8 / 0x10 / 0x12 returns block movement.

## For srrevamp

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
- [ ] The `+0x14` byte's meaning (its width is settled at one byte)
- [ ] What the optional `extra` byte at `+1` carries, and which callers pass non-zero
- [ ] When a sender picks the heading form over a destination
- [x] The server's response opcode — **`0xB021`, read from the binary** in round 366 and now in
      `opcodes.go` as `OpMovementResponse`. Whether it is an ack, a broadcast or both is not read
- [x] Which caller emits the optional extra byte — `CGObjMobile::vslot_292`, action kind 3
- [ ] Wiring: nothing calls this yet. It is the target format for `docs/TODO.md`'s
      move packet, and monster movement additionally needs the server to step
      positions on a tick and push them (round 362)
