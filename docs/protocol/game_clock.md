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

## What is NOT read

The mapping from this clock to the environment tables' normalised time-of-day axis
(`ENVIRONMENT_FORMAT.md`: keyframes at `t = 0 .. 1`). The only readers of the seconds
value found in this pass are the clock's own display path and an alchemy timer; the
sky/fog sampler's time source was not located, so whether a game day is one real day
(`t = seconds_of_day / 86400`) or compressed is **unknown**. Until it is read, srrevamp's
client keeps sampling the environment at a fixed `t = 0.5` (`ENVIRONMENT_REFERENCE_TIME`),
which is disclosed there.

*Next probe:* readers of `CGame+0x8f8` (elapsed ms) and callers of `FUN_00834c70` /
`FUN_00834d40` outside the UI (`0x65d9e0` is the one not yet read), or the `CWeather`
family's update, for a division whose divisor is the day length.

## What srrevamp does

Nothing yet. A `0x34be`-shaped time sync is an additive op away, but it has no consumer
until the environment mapping is read; adding it before then would be a number nobody uses.
