# Trace: following another player (round 832)

Read on 2026-10-26 from `SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/gs_dis.txt`) and
`sro_client.exe` (`/var/tmp/decomp_client`, `/var/tmp/sro_client.dis`) on the render box. Labels:
READ (seen in code, addresses given), INFERRED (with why), OPEN, OURS.

## The wire (READ)

| Message | Layout | Where |
|---|---|---|
| 0x7074 trace | `01 03 01 <u32 target>`: start, kind 3, target type 1, the selection GI+0x628 | c:`0x793b00` case 1003 (`0x793c1d..0x793c62`) |
| 0x7074 cancel | `02` | c:`0x78f8d0` (the ground click), `0x78f7c0`, `0x887330` |
| 0x7074 clear-and-start | `03 <kind> ...`: `0x4ad320(0)`, then as `01` | s:`0x4acd23`; no client sender found |
| 0xB074 | `u8 result, u8 queue depth` + `u16 code` when result is 3 | s:`SendActionResult_B074 0x4ad270`; c:`0x880b60` |

Results: 1 taken, 2 ended, 3 refused. A kind above 5 is refused `0x4004`. The client stores the
depth in GI+0x620 (`0x778c30`) and shows a line only for result 3 (`0x778190(0x19, code)`, switch
`0x7baf0d`): `0x4001`/`0x4002` UIIT_SKILL_USE_FAIL_SEALED, `0x4005` UIIT_MSG_COS_BAN_FOLLOW_COS,
`0x4003`/`0x4004` nothing. The server never sends `0x4005` (no immediate `0x4005` in its code). So a
trace shows no message of any kind: no "Tracing ..." and no "Trace stopped" text exists.

## Where the client starts it (READ)

Only `0x793b00` case 1003 writes kind 3. It is reached from:

- the action window's Trace (`actionwnddata` 1003, `UIIT_CTL_AUTOTRACE_TT`, `icon_cha_follow.ddj`);
- a quick slot holding that action (`0x60b850`, `0x68cb90`);
- the right-click target menu's Trace button (`CNIFTargetMenu`, button 18, `0x60a3d0`).

Its gates are the UI gate `0x77c8e0(0)` (alchemy window 0xa8 existing, the exchange 0x1a shown, and
windows and modes OpenSRO does not build) and the busy test `0x77c9b0` (GI+0x620 >= 2). Nothing is
tested about the target: a monster, yourself, or no selection at all (id 0) is sent as it is.

The ground click `0x78f8d0` sends the cancel before its walk when GI+0x620 is non-zero and below 2.
It is also the walk to an NPC. No cancel is sent on Esc, on selecting something else, or before
another action; the server's Push replaces the trace.

## The server (READ)

The request is a kind-3 action on `CGCharAutoCommandActor` (pc+0x1bc0; `docs/protocol/auto_command.md`).
`Push` (`0x4ad630`) drops a front trace for any new action: `0x4b03f0(1)` stops its walk, then
`0x4af4a0` empties the queue, with no 0xB074. A kind-4 row whose Basic_Activity is not 2 runs at
once (`RunInstantSkill 0x4ad870`) and does not reach that test, so a buff leaves the trace running.

The actor ticks every 30 ms (`0x4ad7a0`). The trace handler `0x4ae3d0`:

- **phase 0**: `PrepareAction` (`0x4ad030` case 3). Then stop = own BCRadius + target BCRadius + 50.0
  (`.rdata 0xb46288`), and restart = the two radii + 80.0 (`0xb45c58`). BCRadius is IGObj slot 344,
  `CGObjChar::GetBCRadius`, characterdata column 50, which is 4 on every CHAR_ row. Both values are
  cut to u16 with the chop mode. Then phase 1.
- **phase 1**: `PrepareAction` again. When the walker pc+0x1bf4 (`CGCharAutoNavigator`) holds no
  target (pc+0x1bfc == 0), `GObjPC::MoveTowardObject(target, stop, restart)` (`0x4b0350`) arms it.
  It is refused under a `stns` stun (pc+0xc44) or when the target is gone, and the trace ends.
- It never finishes on arrival. It returns 0 only through those two tests, and
  `CGCharAutoCommandActor::FinishFront` (`0x4ad390`) then pops it, stops the walk and sends
  0xB074 `{2, depth}`.

`PrepareAction` case 3 checks four things:

- the target resolves (`0x485d90`);
- it is a player (`CGObj::IsPC`, slot 7);
- its life state (slot 62) is neither 2 nor 3;
- `FUN_00430ce0` passes: the same world kind (bit 15 of the region word), and in the field each
  region byte within one of the tracer's.

### The walker (`0x4b0490`, READ)

At most every 100 ms (`GetTickCount() - +0x14 < 100` returns):

1. **End** when the target no longer resolves, the tracer's life state is 2, or the 3-D distance is
   over 1000.0 (`0xb45c68`, strict). Positions in different world kinds count as far apart. Ending
   (`0x4b03f0`) stops the tracer where it is. The trace is not ended: phase 1 arms the walker again.
2. r = own BCRadius, plus the target's when it is a character (slot 6 `CGObj::IsChar`).
3. If dist ≥ r − 4 or stop ≤ r:
   - dist ≤ restart: nothing is done.
   - The tracer is already walking and its heading is within 15° of the target direction
     (`0xb462b8` = 0.2617994 rad): nothing is done. The angle is a CRT call on the dot product of
     the walk direction (pc+0x24..0x2c) with the normalised 3-D delta, its y term multiplied by
     `0.0`. That the call is acos is INFERRED, since the result is compared with an angle.
   - Otherwise the destination is own + (dir.x, 0, dir.z) × (dist − stop). The walker posts a 0x7021
     destination (0x70C5 to the COS when riding, slot 336) into the player's own queue, then
     0x704f `[03]` (run) unless the motion state is already 3.
4. Otherwise, inside the other body, it posts a step straight back of r along −dir, with no run
   request.

### What else ends it (READ)

Each of these calls `0x4ad320(1)` (0xB074 `{2, 0}` when the queue held an action), directly or
through slot 348 `0x4aa340` / slot 426:

- the client's cancel;
- sitting down (`FUN_004b1480`, `0x4ad300(4)`), and opening a stall while seated;
- freezing, sleep and stun landing (`AbnormalState_Apply00` `0x4a4570`, `_Apply06` `0x4a49f0`,
  `_Apply14` `0x4a4ec0`);
- knockdown and knockback (`Combat_ResolveDamage` `0x59015c` / `0x5903a8`);
- a `stns` buff;
- a `pao` effect;
- death (`CGObjPC::vslot_306` `0x529b10` / `_307` `0x52cdb0`);
- logout (`0x50eff0` → `0x50ef70`);
- a trade being established (`EstablishTradeSession` `0x47f970`);
- the stall and open-market handlers;
- mounting a COS (`0x4ec640`);
- a warp or relocation (slot 222 `0x4df590`: revive, GM moves, recall, `0x705D`);
- the arena, flag-world and quest-event handlers;
- the PK flag's expiry on its relation list;
- the target using a `hide` skill (`ApplySkillParamsToChar` `0x59670c`), which stops its most recent
  follower (target+0x1c0c, written by `MoveTowardObject`).

A target that logs out, teleports or dies is not pushed to the tracer. The tracer's next tick fails
`PrepareAction`.

A click walk (0x7021, `GObjPC::FUN_004b0ea0`) does not touch the queue or the walker, and a trace is
not a "pending action" to it (vslot 360 `0x4ef880` asks action+0x20, which only the skill tick
writes). The click's own cancel ends the trace.

## The target menu (READ)

`res_ui\targetmenu.2dt`, `CNIFTargetMenu`, window 0xAE (174):

- a 102 × 142 `ub_new_wnd_` frame;
- a tile;
- the name box (8, `exc_box.ddj`);
- buttons 14 Whisper, 15 Exchange, 17 Add friend, 16 Invite party and 18 Trace, each 86 × 20 on
  `ub_new_menu_button.ddj`.

CGInterface::vslot_017 (`0x77c260`) handles the menu as follows:

- **Option gate**: everything below happens only while the option byte +0x1a is set. That option is
  "Activate action short cut" (UIIT_CTL_ACTION_LIST_ACTIVE), and its Default is off (`0x5fce10`).
  With the option off, a right click is camera only and selects nothing.
- **WM_RBUTTONDOWN**: destroys the menu and arms GI+0x82c.
- **Right drag**: a drag of more than 5 px disarms it.
- **WM_RBUTTONUP**: when armed and over a CICUser (`0x77b5e0`), selects that player (0x7045) and
  opens the menu with its top-left at the cursor. The position is not clamped.
- **WM_LBUTTONDOWN**: destroys the menu.

Every button hides the menu. Their checks and actions:

- **Common gate**: the first four need the selection to be another player; Trace has no check of
  its own.
- **Whisper**: puts `$name ` in the chat line.
- **Exchange**: refused with `0x5419` while the alchemy window is up; otherwise shows the asking
  line and sends 0x7081.
- **Add friend**: sends 0x7302 with the name.
- **Invite party**: sends 0x7060 out of a party; sends 0x7062 as leader or with anyone-invite;
  otherwise does nothing.

The name box gets the name from the target window's update that the 0xB045 select reply runs
(`0x699540` → `0x60a4b0`). The select request is not sent for a player already selected with the
target window up. The box stays empty then: INFERRED from those two READ steps.

## OpenSRO (OURS, disclosed)

- **The walking.** OpenSRO's server does not move players (`server/internal/session/keepup.go`),
  so the client runs the walker. `client/scripts/world/trace_follow.gd` (`TraceFollow.step`) is
  `0x4b0490` line by line. World3D `_step_trace` drives it every 100 ms against the target's drawn
  body. Its walks go out as the click walk's 0x7021, and its run as 0x704f `[03]`.
- **The trace's state.** The server holds the trace (`server/internal/session/trace.go`). It answers
  0x7074 as above, runs `PrepareAction` every 30 ms on its own state (the hub's entities, life
  states and region words), and ends the trace with 0xB074 `{2, 0}`.
- **Moves.** The client's walks must not end the trace, so moves call `moveCancelsActions` (the
  auto-attack and chains); every other `cancelActions` caller ends the trace too. Those callers
  are:
  - sitting;
  - death;
  - a zone change;
  - unstuck;
  - logout;
  - freezing, sleep or stun landing (round 832, `status.go`);
  - a trade (`trade.go`);
  - mounting (`cosride.go`).
- **Push.** The attack, a Basic_Activity 2 cast and a pick-up (OpenSRO's own requests) drop a
  running trace silently, as Push does. The client drops its copy at the same points.
- **IDs.** OpenSRO's monster ids overlap its character ids, so the client sends 0 for a selection
  that is no player. That id names no one, so the trace starts and ends at once, which is what
  IsPC does in retail.
- **Not modelled**, because OpenSRO lacks the system:
  - knockdown and knockback on players;
  - `stns`, `pao` and `hide`;
  - stalls;
  - arena and flag worlds;
  - the PK relation list;
  - the walker's refusal under a `stns` stun.
- **Auto-attack.** A trace pushed behind a running auto-attack ends that attack at once here. In
  retail the attack keeps its execute or keep-up phase and then ends itself at depth 2.
- **The option.** "Activate action short cut" is shown on the Option window's Extra tab
  (`ClientSettings.KEY_ACTION_SHORTCUT`, default off) until the Game tab is built.

## OPEN

- Whether `0x78ee20`'s pick can return the player's own body for the menu.
- Esc and the menu.
- The fresh-install value of option +0x1a.
- Whether the root frame draws its UIIT_CTL_AUTOTRACE_TT text. Ours does not.
- 0x7074 byte 3's client sender.
- The arrow keys' cancel `0x78f7c0`: its +0x65c bit 2 condition is unread, and it is not built.
