# The game clock: server time, sent every ten minutes, advanced in real time

Recovered 2026-09-19 (round 224) from both binaries' decompiled dumps on the render box and
the client image's `.rdata`. This is the signal `World3D.gd`'s `ENVIRONMENT_REFERENCE_TIME`
note said did not exist: it does, and it is the server's own local wall-clock time.

## Server: the 600-second job

`CGObjChar::Create` registers a timer job on every character with interval **600.0 s**
(slot 367's thunk `0x4ac710`, constant at `0xb46198`; the timer vector and its one-second
ticking are in [character_state.md](character_state.md)). Its body,
`CGObjPC::vslot_367` -> `GObjPC::FUN_004f1560` (`0x4f1560`), packs the server's
`GetLocalTime()` (`FUN_004f9320`, `0x4f9320`) into one 32-bit word and sends it as opcode
**`0x34be`**:

```
bits  0.. 5  (year - 16) & 0x3f      (2026 -> 26; the client reads it as 2000 + v)
bits  6.. 9  month
bits 10..14  day of month
bits 15..19  hour
bits 20..25  minute
bits 26..31  second
```

So every connected character is re-synced to the server's local time every ten minutes.
(The same packing is presumably sent once at world entry; that site was not read.)

## Client: decode, set, advance

- The opcode table registers `0x34be -> FUN_0089a250` (`0x89a250`). It unpacks exactly the
  fields above into a `tm` (`tm_year = (v & 0x3f) + 100`, `tm_mon = ((v >> 6) & 0xf) - 1`,
  `tm_mday = (v >> 10) & 0x1f`, `tm_hour = (v >> 15) & 0x1f`, `tm_min = (v >> 20) & 0x3f`,
  `tm_sec = v >> 26`), runs `mktime`, and -- unless the clock is **locked** -- calls the
  setter.
- The clock object (`CGame`, fields `+0x8f8..+0x958`): `FUN_00834bf0` stores the `tm` at
  `+0x934`; `FUN_00834df0` seeds the millisecond clock `+0x918` as
  `((sec + (min + (hour + wday*24)*60)*60) * 1000` -- milliseconds since the start of the
  server-local **week**; `FUN_00834e60` re-syncs it, measuring drift against the locally
  advanced value and resetting the smoothing when the drift exceeds 2000 ms.
- `CGame::vslot_011` (the per-frame update) advances it with real elapsed milliseconds and
  publishes `+0x92c = ms * 0.001` (the double at `0xdd3020` is `0.001`; `0xe1b7c8` is `2^32`,
  the unsigned-wrap fix): **world time in seconds, advancing 1:1 with real time.**
  `FUN_00834c70` renders it back into a `tm` (splitting by 86400 / 3600 / 60) for display.
- The lock: `FUN_00834de0` returns the byte at `+0x931`, set by the scene command
  `S_SetWorldTime` (`Process_S_SetWorldTime`, `0x529580`) so a scripted scene can hold a
  fixed time; the debug console prints `ServerTime <asctime> [LOCKED]` / `[UNLOCKED]`
  (`FUN_00542580`).

## The sky's clock is not this one -- read (round 226)

`SWorld` (the render world; `SWorld::vslot_013` loads `environment.ifo`) keeps its own
day/night **phase** at `+0x26a3`:

- The constructor (`Map::FUN_00a2f370`, `0xa2f370`) sets it to **0.5** (`_DAT_00e1b7e0`)
  and clears the advance flag `[0xbc6]` (`+0x2f18`).
- The per-frame update `SWorld::vslot_004` advances it only when that flag is set:
  `phase += dt * 0.0005` (`_DAT_00de4f88`, a double; `dt` = `_DAT_0110f7fc`, the frame delta
  in seconds -- it is clamped to 3.0 while its sibling `_DAT_0110f7f8` is clamped to 3000).
  Past 1.0 it resets to 0 and bumps a day counter (a short wrapping after 30). So the
  engine's cycle, when enabled, is **2000 s** (33 min 20 s) per day. From the phase it
  derives a shifted phase (`+0x26a7 = phase - 0.25`, or `+ 0.75` below 0.25), a night flag
  (`0.5 < shifted`, `_DAT_00e1b7e0`), and the sun angle `(phase - 0.25) * 2pi`
  (`_DAT_00d81930`); `Map::FUN_00a207a0` draws the sun/shadow only for
  `0.25 <= phase <= 0.875` (`_DAT_00d9a2b8`, `_DAT_00de4d90`).
- **Nothing in this build sets the advance flag**, and the phase setter
  `SWorld::vslot_020(float)` has no caller that passes a time (the slot-0x50 calls found
  belong to other classes). The environment update `Map::FUN_00a1baf0` samples every graph
  with the RAW phase (`FUN_004e55e0(phase)`, the 16-byte-keyframe ColorGraph evaluator
  that compares the time against `key+0xc`).

So the retail client renders the environment at a **fixed phase of 0.5** -- midday -- and
the server clock above has nothing to do with the sky. OpenSRO's
`ENVIRONMENT_REFERENCE_TIME = 0.5` is the binary's own value, no longer a disclosed choice.
A live day/night cycle would be OpenSRO's design; the engine's machinery for one (the
rate, the shift, the sun angle) is recorded here for that day.

## What OpenSRO does

Nothing, and correctly so: the client samples the environment at the same fixed 0.5 the
retail client does. A `0x34be`-shaped time sync would feed only a `ServerTime` display.
