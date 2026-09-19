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

What the second pass (2026-09-19, round 219) did establish about the server's clock, so
the next attempt starts past it:

- The main loop (`CMainProcess::vslot_003`, `0x402870`) drains messages for up to 3000 ms,
  then computes `dt = (GetTickCount() - last) / const@0xb45c68` and calls
  `CMainProcess::FUN_00413840(dt)` while the server state is 4 or 5. Inside, dt is clamped
  to at most 1.0, accumulated at `this+0x40`, and when the accumulator reaches the period
  at `this+0x44` the fixed step `CMainProcess::FUN_00413b30` fires and
  `round(accumulated * const@0xb45c68)` is passed on as an integer. The same constant
  divides milliseconds into the delta and multiplies the delta back into milliseconds,
  so **it is 1000 and the loop's delta is in seconds** -- read from its two use-sites,
  not from the data.
- The period at `this+0x44` is initialised to 0 in `CMainProcess::FUN_00644380` and set
  elsewhere at runtime (not located); the fixed step iterates the object lists calling
  slots `0x618` and `0x34c` -- **not** `vslot_415`. So the PC's periodic update is on a
  third path, still unlocated: not the layer (`CGameWorldLayer`, all 578 functions
  checked for a slot-11 or slot-415 dispatch: none), not the fixed step.
- Controllers' slot 11 is the same "update this PC" for every world kind
  (`FUN_00605010` is reached as slot 11 of `CDefaultWorldContextController`,
  `CFlagWorldContextController`, `CInstanceWorldContextController`,
  `CBattleArenaContextController` and `CDataDrivenWCC_NormalizeA`; the siege one goes
  through `vslot_416`). Whoever calls `controller->slot11(pc)` is the scheduler wanted.

Third pass (round 220), byte-level on the image (`/var/tmp/SR_GameServer.exe`, whose code
layout matches the dump; MSVC here emits virtual calls as `mov r,[r+disp]; call r`, so a
`call [r+disp]` search finds almost nothing -- the pattern that works is the load):

- `[r+0x67c]` (slot 415) is loaded in exactly two places, `CGObjPC::vslot_416` (`0x52d9bb`)
  and `FUN_00605010` (`0x605016`); `[r+0x680]` (slot 416) in one,
  `CSiegeWorldContextController::vslot_011`. The dump and the image agree.
- `CGObjPC::vslot_364` (`0x4eb780`, slot 364 at `+0x5b0`) is the function that calls
  `(*(pc+0xd8))->slot11(pc)` -- but the ONLY `[r+0x5b0]` in the image is its own vcall
  thunk at `0x4ac6b2` (`jmp [eax+0x5b0]`, in the padding after `GObjPC::FUN_004ac630`),
  and nothing references that thunk or `0x4eb780` except the vtable entry at `0xaf5fac`.
  **Slot 364 is dead in this build.** The live path into `FUN_00605010` therefore loads
  the controller from somewhere other than `pc+0xd8` and calls it through a
  `mov r,[r+0x2c]; call r` sequence -- one of thousands; not yet isolated.
- The event system has per-second events (`ROCTOP_WORLD_EVENT_HANDLERS::OnTimer_Second`,
  `QNO_EU_HWAN_2_1::OnTimer_Second::Handle`; every `CEVENTHandler` implements one virtual,
  slot 1). If the default world's PC update is such a handler, the poster of the
  `Timer_Second` event is the scheduler, and its period is where that event is armed.

Fourth pass (round 221) closed the event-system lead: "OnTimer_Second" is an ORDINAL (a
world's second timer), not "per second". `CEVENTHandler` timers are armed with
`FUN_0063ccc0(ms, ms)` after construction and registered with `FUN_0063d070(world, ..)`
(`CGameWorld_RocTop::vslot_014`: 3600000/0, 300000/300000; quest scripts: 10000/0,
300000/0); nothing arms a 1000 ms timer anywhere, so the PC update is not an event
handler. The main loop's other consumer of the seconds-delta,
`CMainProcess::CLobby_RemoveStalePlayers`, is only that. The load-form scan of the image
finds 321 `mov r,[r+0x2c]; call r` sites, 175 outside quest scripts; many take their
receiver from the global at `0xcc387c` (a manager's slot 11, used by message handlers),
which is not a controller.

Fifth pass (round 222): two more facts and a park.

- **The world keeps its controller at `world+8`**: the world's vtable slot 1 is the setter
  `GObjPC::FUN_005eb2c0` (`*(this+8) = controller`, misattributed to GObjPC by the module
  pass; it sits in the CGameWorld unit), which is what the world-setup switch
  (`CMainProcess::FUN_005f5b60`) calls after choosing a controller by zone name
  (`INS_FORT_*` etc.).
- `CGObjPC::vslot_373`'s `param_2->slot11(pc)` is the AsyncQuery completion callback
  (its callers are `AQ_*::vslot_007/008`), another class's slot 11 -- not the tick.
- No function in the dump reads `world+8` (as `+ 8)` or `[2]`) and calls slot 11 on it,
  in one expression or within five lines, and no tiny getter returning `*(this+8)` exists
  in the world unit. So the live dispatch is not expressible as a pattern over the
  decompiled text; it needs a data-flow walk.

**PARKED (2026-09-19)** after five ticks: the unit is already labelled as an inference on
both values it affects (berserk 60, stance 20), both consistent only with a one-second
tick, and nothing srrevamp ships changes with the answer except the label. The route left
is a Ghidra data-flow pass: from the five controller vtables' slot-11 entries backwards is
impossible (virtual), so forwards from the stores into `world+8` -- Ghidra's
`ReferenceManager` on the field's readers with the receiver type resolved, or a
debugger-less trace of `CMainProcess::FUN_00413b30`'s callees three levels deep for a
`[reg+0x2c]` load whose object came from `[world+8]`.

## What srrevamp does

The client holds `STAND_BATTLE` for `COMBAT_STANCE_SECONDS = 20` after its own last
attack or cast (`World3D.gd`). That is the server's rule applied client-side: srrevamp's
server does not yet carry a battle-state byte or announce `0x30bf`-style state changes,
so other players do not see a character's stance change. Closing that means a state
channel on the wire and the 20-tick countdown in the server's per-second character tick.
