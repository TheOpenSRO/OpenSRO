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

## The tick's unit -- READ: one second (round 223)

The PC's periodic jobs are a **timer vector** on the character (`std::vector` of 0x18-byte
nodes at `this+0x18c`: `+0` elapsed, `+4` interval, `+0x10` callback), and the whole chain
from the wall clock to the stance counter is read:

1. `CGObjChar::Create` (`0x4a6f40`) registers the jobs through `GObjPC::FUN_004ab640`
   (`(this, ?, float interval, ..)`, asserting `interval > 0`), each with the vcall thunk of
   a vtable slot as its callback. The thunks sit at `0x4ac6b0..0x4ac71f`
   (`mov eax,[ecx]; jmp [eax+slot*4]`), and the intervals are the x87 loads just before
   each `mov eax, <thunk>`:

   | slot | thunk | interval | what |
   |---|---|---|---|
   | 364 | `0x4ac6b0` | **`fld1` = 1.0** (three registration sites, `0x4a7031/0x4a70c0/0x4a7136`) | `controller->slot11(pc)` -> `CGObjPC::vslot_415` |
   | 362 | `0x4ac6f0` | 4.0 (`0xb45dc0`) | HP/MP regeneration (`internal/mana`) |
   | 365 | `0x4ac6d0` | 10.0 (`0xb45b44`) | |
   | 368 | `0x4ac6c0` | 30.0 (`0xb45b48`) | |
   | 366 | `0x4ac700` | 60.0 (`0xb461bc`) | |
   | 367 | `0x4ac710` | 600.0 (`0xb46198`) | |

2. The ticker is `GObjPC::FUN_004ab690(float dt)`: for each node,
   `elapsed += dt; if elapsed >= interval { elapsed -= interval; callback() }`. It is called
   from `CGObjChar::Update(dt)` (`0x4a88f0`, vtable slot 211 = offset `0x34c`).
3. Slot `0x34c` is what the main loop's fixed step `CMainProcess::FUN_00413b30` calls on
   every object, passing `_DAT_00d6a8ec` -- the delta accumulated in
   `CMainProcess::FUN_00413840` from `dt = (GetTickCount() - last) / 1000` (the constant
   at `0xb45c68` is 1000: the same accumulator is multiplied by it to hand milliseconds to
   `FUN_0041bfa0`). **The delta is in seconds; the intervals are in seconds.**

So `CGObjPC::vslot_415` runs once per second, the battle stance reverts **20 s** after the
last blow, berserk's 60.0 is **60 s**, and regeneration ticks every **4 s** -- all read.

A correction to rounds 220 and 222: they called slot 364 "dead in this build" because
nothing referenced `0x4ac6b2`. That is the thunk's `jmp`; its entry is two bytes earlier
at `0x4ac6b0`, and that address is referenced three times, as the callback of the 1-second
timer. The vcall-thunk search must take the entry, not the jump.

## What srrevamp does

The client holds `STAND_BATTLE` for `COMBAT_STANCE_SECONDS = 20` after its own last
attack or cast (`World3D.gd`) -- the server's 20 one-second ticks. That is the server's rule applied client-side: srrevamp's
server does not yet carry a battle-state byte or announce `0x30bf`-style state changes,
so other players do not see a character's stance change. Closing that means a state
channel on the wire and the 20-tick countdown in the server's per-second character tick.
