# Sitting and standing: `0x704f` / `0x30bf`, and the regeneration they drive

Recovered in round 605. Labels: **read** = from the binary at the cited address;
**measured** = counted in the archive or a dump; **inferred** = a conclusion from
read or measured facts, with its basis; **ours** = srrevamp's own choice.

Sources: `SR_GameServer.exe` (`/var/tmp/SR_GameServer.exe`, dump
`/var/tmp/decomp_server`, asm `/var/tmp/srv.asm`), `sro_client.exe`
(`/opt/sro-files/client/sro_client.exe`), `Data.pk2`. Evidence kept on the render
box in `/var/tmp/rkeymap/` (`30bf.asm`, `regen.asm`, `sit_bodies.txt`) and
`/var/tmp/rsit/` (`move.asm`, `vt.py`, `fnof.py`).

## The exchange

	request   0x704f   u8          4 = sit/stand toggle (client, N key)
	success   0x30bf   u32 id, u8 kind = 1, u8 value     broadcast, the requester included
	refusal   none                                        the handler just returns

### Request (read)

- **Client.** N calls `0x793b00(0x64, 1000)` → `0x9d4a20` on the local player,
  which sends `0x704f [04]` from `0x81e750(4)` unless client state 2 is active
  (bit 2 of `+0x65c`) or the player has a stall (`+0x78c`). The client animates
  nothing on the key.
- **Server registration.** `FUN_004b0b70` fills the handler table at `0xccf110`
  (8-byte entries, `0x800` of them). The store at `0x4b0ccd` puts the thunk
  `0x4b23f0` (`jmp [eax+0x5f4]`) at `0xccf388` = index `0x04f`. `CGObjPC`'s vtable
  (`0x00af59fc`) holds `0x4b1450` at `+0x5f4`. **So `0x704f` → `0x4b1450`**,
  which reads one u8 (`0x404f80`) and calls `GObjPC::FUN_004b1480(value)`.
  (Round-605 correction of the keymap research's "registration not traced".)

### `FUN_004b1480`, the motion request (read, `0x4b1480..0x4b1602`)

1. Refused when slot `0x5a0()` (`CGObjPC::vslot_360`, `0x4ef880`) is non-zero,
   when a running action at `+0xc20` has kind 1, or when the motion state is
   `0x12` (CHANGEMOTION).
2. A request of 4 is also refused unless `IsPC()` (slot `0x1c`) and
   `chardata+0xe != 1`.
3. Request 4 from WALK or RUN first calls slot `0x4b0` (inferred: stop moving),
   then the state is read again.
4. **Toggle.** 4 while SIT becomes 0; 4 while STAND stays 4; 4 from anything else
   is refused (the switch's case 4 needs STAND). Any other request equal to the
   state is refused.
5. Switch on the resolved value (index table `0x4b161c`, jumps `0x4b1608`):

| value | needs | does |
|---|---|---|
| 0 | state SIT | `SetMotionState(0x12, 0, 1.5)` |
| 2, 3 | state STAND, WALK or RUN | slot `0x4bc(value != 2)` (walk/run mode) |
| 4 | state STAND | `SetMotionState(0x12, 4, 1.5)` |
| `0xc` | — | `SetMotionState(0xc, 0xff, 0.0)` |
| other | — | assert |

6. Then `0x30bf {id, 1, value}` through `GObjPC::BroadcastStateChange`
   (`0x4a8340`, `mov ebx,0x1` at `0x4b15e6`). **Kind 1 is therefore the motion
   state**, which character_state.md left open in round 446.

`1.5` is `.rdata 0x00b45c10` (float). **The transition's unit is seconds**: the
`AJStateChanger` record is counted down by the update's `dt` (`0x405f79`:
`fld [edi+0x10]; fsub [esp+0x28]`), the same delta round 223 read as seconds.

### `SetMotionState`, slot 343 (`0x4a9d00`, read)

- `(state, nextKind, duration)`, `ret 0xc`. Returns at once when the state is
  unchanged and `nextKind == 0xff`.
- STAND may be replaced by a status's own state (`0x4aab60`: 0xa, 9, or
  0x13/0x15 from three status tests).
- Stores the state at `chardata+2` (`mov [edx+2],bl`).
- **For a PC (slot `0x1c`) it writes the base slot of params 25 `hprg` and 26
  `mprg`**, `ParamKeeper_SetParam(slot 0, ctx 2, value)` with the param id in
  EDI: **8.0** (`.rdata 0x00b45e14`) when the new state is SIT, **0.8**
  (`.rdata 0x00b45b94`) for every other state.
- With `nextKind != 0xff` and `duration > 0` it queues an `AJStateChanger`
  record `{+0xc = 1, +0xd = nextKind, +0x10 = duration}`. When the duration runs
  out, the record's case 1 (`0x405fe6`) calls `SetMotionState(nextKind, 0xff,
  0.0)`. That call does **not** broadcast: observers learn only from the one
  `0x30bf` sent at the request.

### Every other writer that matters (read)

| where | what |
|---|---|
| `CGObjChar::vslot_000` `0x4a6fd3` | sets `chardata+2 = 0xff`, then `SetMotionState(STAND, 0xff, 0)`: every character starts STAND with `hprg`/`mprg` 0.8 |
| `GObjPC::Revive` `0x4df427` | `SetMotionState(STAND, 0xff, 0)` |
| the movement handler `0x4b0ea0` `0x4b11b6` | `SetMotionState(2 + run, 0xff, 0)`: WALK or RUN at once |
| `Combat_ApplyActionEffects` `0x593aec` | `FUN_004b1480(0)` on a target in SIT, when the per-target record's `+0x10` is 0 and status bit `0x40` is clear (neither read) |
| `FleaMarket_HandleOpenStall` `0x51605b` | `FUN_004b1480(4)` while sitting, i.e. stand |

### Moving while sitting (read, round 605)

The movement request `0x7021` is index `0x021`: the same registration stores the
thunk `0x4b23e0` (`jmp [eax+0x5e4]`) at `0xccf218`, and `CGObjPC`'s `+0x5e4` is
`0x4b0ea0`. Its motion gate refuses states **8, 0x10 and 0x12 only**
(`0x4b0f59`, `0x4b0f6e`, `0x4b0f83`). **A move while SIT is accepted** and the
handler sets WALK or RUN directly, with no transition and no `0x30bf`. A move in
the 1.5 s transition is refused. The keymap research left this "not read".

### Skills while seated (read; corrected in round 605's follow-up)

`FUN_0058d8f0`, the skill-use gate, answers `0x3009` for the caster's motion
state in two branches, **each only for particular skills**:

- `0x58de46..0x58ded4`: the skill's `msch` (`+0x4a4`) has value[0] == 1
  (`mov ecx,[esi+0x4a4]; cmp [ecx],1; jne 0x58dee3`); then refused when slot
  `0x540` answers non-zero, when `0x406750(1)` does (neither read), or in SIT.
- `0x58e0a0..0x58e0ed`: the caster `IsPC` and the skill carries `ao` (`+0x274`)
  or `pw` (`+0x2b4`) (`58e0ad` / `58e0b6`, `je 0x58e10d`); then refused in SIT,
  `0x12`, 8, `0xf` or `0x11`.

**Measured** over the 33,660 skill rows (`export-refdata -mode skills`, the new
`SitGate` column): 58 carry `ao` or `pw` -- 28 `SKILL_CH_COLD_BINGBYEOK_*`, 27
`SKILL_CH_FIRE_HWABYEOK_*` (the walls) and 3 `SKILL_FORT_REPAIR_KIT_*` -- and one
has a kind-1 `msch`, `SKILL_ETC_TRANS_MONSTER_01`. **Every other skill is cast
from the seat**, and nothing in a cast stands the caster up: the only callers of
`FUN_004b1480` are `0x4b1468` (the `0x704f` handler), `0x51605f` (stall),
`0x51b5a9` (open market) and `0x593af0` (a blow on a target).

**The plain attack** is a skill in retail (`SKILL_PUNCH_01`,
`SKILL_CH_SWORD_BASE_01`, ...): none of the 1,273 `*_BASE_*` / `PUNCH` rows
carries `ao`, `pw` or `msch` (measured), so a seated swing is not refused and
the attacker stays seated. What the retail CLIENT does when its seated player
clicks a monster (whether it sends at all, what it plays) is not read.

The client name of `0x3009` is not in `docs/protocol/error_codes.md`.

## The regeneration tick (read)

`CGObjPC::vslot_362` (`0x004e2990`), on a timer the constructor registers
(`0x4a6dd3`: interval `.rdata 0x00b45dc0` = 4.0, callback thunk `0x4ac6f0`).
The timer record starts at 0 elapsed (`0x4ab640`); the list tick (`0x4ab690`)
adds `dt`, fires once when `interval <= elapsed` and subtracts the interval.
**So the first tick is 4 s after the character is made, and sitting does not
re-arm it** (`SetMotionState` touches no timer).

	if (GetLifeState() != 1) return;                                   0x4e29a9
	if (charData->PKPenaltyPoint > 0 && byte[[+0x128]+0x10]+2 == 0) {  0x4e29b4
	    drain trunc(MaxHP * 0.02) through slot 0x4fc; return;           0.02 = double 0xb45ec8
	}
	if (status & 0x20) return;                                          zombie, 0x4e2a37
	if (MaxHP == CurHP && MaxMP == CurMP) return;                       0x4e2a7e
	if (GetMotionState() != STAND && != SIT) return;                    0x4e2a8a..0x4e2aa8
	hp = 0;
	if (this[0xa2d]) {                                                  1 from the constructor; a timed HP effect clears it
	    hp  = ftol(float(MaxHP) * EvaluateParam(25) / 100.0);           100.0 = double 0xb45af0
	    hp  = max(hp, 1);                                               0x4e2afb
	    cap = ftol(float(MaxHP) * 0.5);                                 0.5 = double 0xb45c50
	    hp  = clamp(hp, 0, cap);                                        CLAMP(), GObjPC.cpp line 0xdf9
	}
	mp: the same with this[0xa2c], MaxMP and EvaluateParam(26)          line 0xe02
	ApplyHPMPDelta(hp, mp, 0x10);                                       0x4a86a0: x (1 - param143/100), x (1 - param144/100)

### The pool is the maximum (read, round 605)

The value multiplied is vtable slot `0x110` (`0x114` for MP). In `CGObjPC`'s
vtable those hold **`0x4a6830` = `ftol(EvaluateParam(3))`** and `0x4a6850` =
`ftol(EvaluateParam(4))` -- params 3 `hp` and 4 `mp`, the computed maxima --
while the current HP is slot `0x108` = `0x4aa5e0`, which reads the stored value
through charData's own vtable (`+0x38`). The pool is therefore **MaxHP / MaxMP**,
agreeing with `igobj_vtable.md`'s slot 68 and its three other witnesses.

### Worked

| MaxHP | standing (0.8) | sitting (8.0) |
|---:|---:|---:|
| 200 | 1 (1.6 truncated) | 16 |
| 1000 | 8 | 80 |
| 5000 | 40 | 400 |

The cap at half the maximum binds only on a pool of 1. The rate is the float32
`0.800000011920929`; for every pool from 1 to 2,000,000 its truncation equals
float64 0.8's (measured), so the float is fidelity, not a visible difference.

### What this corrects

- **2026-09-16 (RE_COMPLETION "passive regeneration exists")** read slot `0x110`
  as the CURRENT pool and shipped "4% of current" as own design. The slot is the
  maximum.
- The same note, and `mana.go`, said `hprg`/`mprg` "are not a resting rate: all
  seven writes come from skill effects and every one targets slot 1 or slot 3,
  never slot 0". `SetMotionState` writes slot 0 of both on every motion change,
  and `param_writers.md` (2026-09-18) had already listed `GObjPC::FUN_004a9d00`
  as a writer of params 25 and 26. The old census counted skill-effect writes
  only; it measured those correctly, and what it concluded from them was wrong.
- **"No passive regeneration"** (before 2026-09-16) enumerated the HP/MP pool
  writers and found none driven by a clock. The writers were right; the clock is
  the timer callback one indirection out, which the 2026-09-16 note found.

## Sit clips (measured, `Data.pk2`)

The client never names a sit clip: its sit entry (`0xa5a270`) plays action type
**14** (loop) through vtable `+0xbc` with `(0xe, 200, 0, 0, 1.0, 1.0)` and, when
the previous state mask had bit 3 (standing), type **13** with `(0xd, 0, 200, 0,
1.0, 1.0)`; its stand entry (`0xa5a160`) plays type **15** when the previous mask
had bit 6 (sitting), then enters state 8 (unread). The type is resolved in the
body `.bsr`'s animation group, falling back to `default`. srrevamp's two bodies:

| body | 13 sit down | 14 loop | 15 stand up |
|---|---|---|---|
| `chinaman_fighter` | `man\chinaman_a_sitground` 1666 ms | `man\chinaman_a_sitbreath` 2666 ms, cyclic | `man\chinaman_a_sitstand` 1600 ms |
| `chinawoman_fighter` | `woman\chinawoman_a_sitground` 1666 ms | `woman\chinawoman_a_sitbreath` 2666 ms, cyclic | `woman\chinawoman_a_sitstand` 1833 ms |

Other bodies use other sets (`chinaman_fighter_a_*`, `chinaman_merchant_a_*`,
`chinawoman_merchant_a_*`, `chinawoman_kangsi_a_*`, ...); `sit_bodies.txt` has
every body.

## srrevamp

- **Server** (`server/internal/session/motion.go`, `regen.go`,
  `server/internal/mana`): `0x704f` toggles through the 1.5 s CHANGEMOTION, the
  resolved value is broadcast as `0x30bf {id, 1, value}` to the zone; the regen
  tick is the read formula on each character's own 4 s timer, from world entry.
  A move in the transition is dropped; a move while seated stands at once. A
  landed blow stands a sitter. A cast is refused to a seated caster only for the
  59 skills the gate names (`refdata.Skill.SitGate`, from the exporter's
  `SitGate` column); a plain swing, a duel swing and every other cast are not.
  A player entering a zone is sent `0x30bf {id, 1, 4}` for each seated
  character already there. The regen tick runs under the kill lock and skips a
  character alive at HP 0.
- **Ours, disclosed:** the server has no WALK/RUN state (the client streams
  positions), so an accepted move less than 0.5 s old counts as walking; the
  0x30bf id is the character id in the u32; a dead character's request is
  dropped; the unread request gates (slot `0x5a0`, `+0xc20`, `chardata+0xe`)
  are not modelled; "a blow that landed damage" stands in for the unread
  `+0x10` and status-`0x40` tests; a zone change stands the character
  (inferred from re-creation, not read); the refusal text for `0x3009`; the
  `0x30bf` sent to a newcomer for each sitter (the retail spawn packet's
  motion field was not read) and the client's 1 s window in which such a
  sitter takes the loop without the sit-down clip; a character alive at HP 0
  (being killed, or an HP-cost caster) regenerates nothing, because
  srrevamp's blow and death are not one step as the engine's are; the gate's
  KNOCKDOWN, SKILL_ACTIONOFF and SKILL_PROTECTIONWALL states do not exist here.
- **Not modelled:** the PK-penalty drain, zombie, the timed-effect switch, skill
  buffs on params 25/26, params 143/144, the stall's stand-up (no stalls).
- **Client** (`client/scripts/World3D.gd`, `world/sit_state.gd`): N sends
  `0x704f [04]`; `0x30bf` kind 1 plays 13 then 14, or 15, from the body's own
  `.bsr`, for this player and others; movement input is held for the
  transition; a move while seated sends the position at once so the server
  stands the character too; the own-id learning window closes when an
  unanswered request expires.
