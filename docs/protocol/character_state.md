# The character state channel, and the battle stance's timer

Recovered 2026-09-19 (round 218) from `SR_GameServer.exe`'s decompiled dump on the render
box (`/var/tmp/decomp_server`). This is the server's own model of the per-character state
bytes it announces to every client in range -- life, motion, body, PvP, battle -- and the
one timer among them that srrevamp draws: how long a character keeps the battle stance.

## The channel

`CGObjPC::SetCharacterState(type, value)` (`0x4f0ad0`, vtable slot 171, named from
`IGObj::SetCharacterState`'s own assert) is a switch on the state TYPE:

| type | what it does | note |
|---|---|---|
| 2 | `chardata+0x06 = value` | |
| 3 | `chardata+0x07 = value` | |
| 6 | `chardata+0x08 = value` (32-bit) | |
| 7 | `GObjPC::FUN_004e2940(value)` -> `chardata+0x0c`, announce, `FUN_004fc880(2)`, `FUN_00656500` | PvP state |
| **8** | **`GObjPC::FUN_004e2910(value)` -> `chardata+0x0d`, announce; value 1 arms `pc+0x203c = 20`** | **battle state** |
| 9 | `chardata+0x0e = value` | |
| 10 | `FUN_004e0b20()` | |
| 11 | `FUN_004e0b50(value, 0xff, 0, 0)` | |
| 12 | `chardata+0x11 = value` | |
| 13 | `FUN_004e0c20()` | |
| 15 | speed re-publish when value is 1 or 2, then `FUN_004e0db0()` | |

Every announcing setter goes through `GObjPC::FUN_004a8340` (`0x4a8340`): opcode
**`0x30bf`**, the object id (`obj+8`), the type byte, the value byte -- and for type 4
with value 1 (body state: berserk) one more byte from `chardata+5`. The type numbers are
the public protocol's `ENTITY_UPDATE_STATE` numbering (7 = PvP, 8 = battle), which is
how the switch cases were named here; the switch itself is the binary's.

## The battle stance's timer

`GObjPC::FUN_004e2910` (`0x4e2910`):

```
if value == 1:      pc+0x203c = 0x14           ; arm: 20 ticks
if chardata+0xd != value:
    chardata+0xd = value
    announce(0x30bf, type 8, value)
```

`CGObjPC::vslot_415` (`0x52aa90`, the PC's periodic update; `pc+0x203c` is
`param_1[0x80f]`):

```
if 0 < pc[0x80f]:
    pc[0x80f] -= 1
    if pc[0x80f] == 0: GObjPC::FUN_004e2910(...)   ; back to peace
```

(The decompiler dropped the register argument of that call; the setter's `== 1` branch
is what re-arms, so the expiry call carries a value other than 1 -- peace.)

So **a character stays in battle stance for 20 ticks of the PC update after the last
thing that set it**, and every attack re-arms the 20 through the same setter.

## The tick's unit -- inferred, and shared with berserk

The same `vslot_415` advances the PC's timed-effect list with a constant delta:
`GObjPC::FUN_006560c0(pc+0x1dfc, 1.0f)` (and `pc+0x7390` likewise), the loop that calls
each effect's vslot 8 with the delta and drops the ones that return 0. That is the kind of
float countdown berserk's duration runs on (`internal/berserk`: 60.0, unit inferred). So
berserk's 60 and the stance's 20 count in the SAME unit, ticks of this update, and the
stance is exactly one third of an unbuffed berserk.

**The period of `vslot_415` is not read.** It is reached through `CGObjPC::vslot_416`
(`0x52d9b0`) and `FUN_00605010` (`0x605010`, referenced from no code -- a controller
vtable), the latter behind the world-context controllers' slot 11
(`CSiegeWorldContextController::vslot_011` calls slot 416); the scheduler that fires those
controllers was not located in this pass (the main loop's `CMainProcess::FUN_00414140`
keeps a 1000 ms accumulator, but what it drives per second was not tied to slot 415). A
one-second tick is the only reading under which berserk is a minute and dt = 1.0 is a
second; srrevamp ships both on that inference, labelled.

## What srrevamp does

The client holds `STAND_BATTLE` for `COMBAT_STANCE_SECONDS = 20` after its own last
attack or cast (`World3D.gd`). That is the server's rule applied client-side: srrevamp's
server does not yet carry a battle-state byte or announce `0x30bf`-style state changes,
so other players do not see a character's stance change. Closing that means a state
channel on the wire and the 20-tick countdown in the server's per-second character tick.
