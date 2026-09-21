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

So the extra byte marks **a movement embedded in an action message**, not a standalone move. What
the action kinds are, and what the byte then carries, is still unread.

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
