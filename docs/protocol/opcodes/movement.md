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

## Not read

- **What the `+0x14` byte in the heading form is.** Its width is settled at one byte; its meaning
  is not, and no name is proposed for it.
- **When a sender picks `kind == 0`** (heading) over a destination. The monster AI always supplies
  a destination.
- **What the optional `extra` byte at `+1` carries**, and which callers pass non-zero. The monster
  AI passes zero, so it is absent from every message the AI sends.

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
- [ ] The server's reply opcode, if any. `0xB021` would be the conventional
      pairing but **nothing was read to confirm it**, so it is not in `opcodes.go`
- [ ] Wiring: nothing calls this yet. It is the target format for `docs/TODO.md`'s
      move packet, and monster movement additionally needs the server to step
      positions on a tick and push them (round 362)
