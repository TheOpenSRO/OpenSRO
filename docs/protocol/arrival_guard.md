# The arrival guard: held until the load is done, then untouchable

Round 786 (part). The user: "add an invulnerability of 5 seconds I think after you teleport. This
includes ANY form of teleportation. Also don't let the character spawn in the new location until
the loading is done." Then: take every rule from the original code and replicate it; "see how the
original game has the character appear. Before or after loading or something in between."

Every claim is labelled: **READ** (an address in `SR_GameServer.exe` or `sro_client.exe`, the
decompile and the asm on the render box: `/var/tmp/decomp_server`, `/var/tmp/srgs.asm`,
`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm`), **MEASURED**, **INFERRED** or **OURS**.

## The retail rules

- **The protection is 6.0 s, not 5.** `CGObjPC::vslot_391` (0x4df9e0) runs `SetBodyMode(2, 0, t, 0)`
  (0x4dfabc, 0x4dfaca) with `t` from the world's slot 28 (+0x70). The open world (`INS_DEFAULT`,
  matched at 0x5f5c55 -> `CGameWorld_Default`, constructor 0x5f0a20) answers through
  `CGameWorld`'s 0x5eb2d0: `fld [0xb45b78]` = **6.0f** (READ, the float read from the PE). The
  fortress-war world (`CGameWorld_Siege` 0x600c50) answers 11.0f (0xb45bb8); a
  `CDataDrivenGameWorld` its +0x5c (0x608330), 6.0 by default (0x608747) and overridden by the
  `_RefGame_World_Config` key `GAMEWORLD_ENTRY_UNTOUCHABLE_TIME` (0x60876c / 0x608783). With no
  world found, 6.0 (0x4dfab3). READ.
  - The client's own text for the refusal says 5: `UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_TEMPORARILY`
    = "Cannot attack or be attacked for 5 seconds during untouchable status." (MEASURED,
    textuisystem.txt on the box). That is authored text, not the timer; the server's timer is 6.0 s.
    The user's "5 seconds" matches the text. OpenSRO follows the code: 6.0 s.
  - The shard DB's one config row is `GROUP_TEMPLE_DEFAULT` = 15 (MEASURED, a private server's
    data; OpenSRO has no temple world).
- **Body mode 2** (chardata[3], `CGObjChar::SetBodyMode` 0x4a9fc0 `(mode, next_mode, seconds,
  flag)`): written at 0x4aa1b1, broadcast as 0x30BF kind 4 by `GObjPC::BroadcastStateChange`
  (0x4a8340, called at 0x4aa1a2) when it changes, and ended by an AJStateChanger job of kind 4
  (queued 0x4aa2bd..0x4aa2e4) whose `vslot_002` (0x405f70) calls `SetBodyMode(0, 0xff, 0, 0)` when
  the time is up (0x406087). READ. Watchers hear value 2 at the start and 0 at the end.
  - Modes: 0 normal, 1 berserk, 2 this protection, 3 GM invincible, 4 GM invisible (the GM handler
    0x520de0 names 3 and 4), 6/7 skill stealth (0x5966c1). READ. A debug table at 0xc64020 names
    2 `BODYMODE_INVINCIBLE` and 4 `BODYMODE_BERSERKER`, contradicting the handler (stale; READ).
- **What it does.** `GObjPC::FUN_005291d0` (the attack check, `this` the attacker) refuses with
  0x3020 when the attacker is in mode 2 (0x529240), when the target is in mode 2, 3 or 4
  (0x529254, 0x529268, 0x52927c), and for a pet whose owner is (0x52931a..). Players' skills and
  attacks reach it through `Skill_CheckUseConditions` (0x58e13e -> 0x58cc70 -> +0x624 at
  0x58cf14); `PrepareAction` (0x4ad08a), the area-skill filters (0x5a1b16, 0x5a1b31) and
  `CGSkillObject::Update` (0x48d54d) too. It runs before the PK rules (0x5293a0), so it covers
  monsters, players and PvP. READ.
  - **Monsters:** the AI's target validator `FUN_00540de0` returns null for a target not alive
    (life state 1, 0x540dfd) or in body mode 2-4 (0x540e2f, 0x540e33); its callers include the
    target resolve, the nearest select, the aggro link (0x5477ea) and `CAIState_BATTLE::OnUpdate`
    (0x55a0dc), which also re-runs CanAttack on its target every update (0x55a0f6) and posts event
    0x23 when it fails. So a monster neither acquires nor keeps a protected player. READ.
  - **Berserk** is refused with its error 4 in mode 2 (0x515b69). READ.
- **Nothing ends it early.** All 28 call sites of the SetBodyMode slot (+0x318) were checked and no
  other write to chardata+3 exists (a pattern scan): none is on a move, an attack, a cast, an item
  use or a pick-up. An attack in mode 2 is refused, not allowed-and-ending. The only replacements
  are the timer, the GM mode commands (0x520de0, 0x4fd840) and a stealth skill (6/7, 0x5966c1;
  whether a mode-2 player can cast one is OPEN, and the client refuses every skill then). READ.
- **The client** (READ, `sro_client.exe`):
  - 0x30BF kind 4 (jump table 0x8a842c [4] -> 0x8a8226) calls SetBodyMode `0x9cf880(value, 0,
    extra)`, which stores the mode at +0x2c2. Mode 2 changes **nothing on the body** (no alpha,
    effect or colour); mode 4 sets the model's alpha to 0x50; mode 1 the berserk look.
  - For this player and any non-zero value (`test bl,bl` at 0x8a826f) the screen flashes:
    0xa42d20 with (255, 255, 255, 128), 0.2 s up and 0.5 s back.
  - Every skill is refused in mode 2 (`FUN_0081ba10`, own +0x2c2 == 2 at 0x81ba58) and a normal
    attack on a player or a state-5 target (0x791fda), each with category 4 code 0x3020 ->
    `UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_TEMPORARILY` outside a fortress (0x7b99f3); nothing is
    sent. A normal attack on a monster is not checked on the client (the server refuses it).
  - Selecting a mode-2 player is allowed (the picker 0x77ca86 skips modes 4, 6, 7 only). No client
    timer ends mode 2.
  - The text table names an effect `SYSTEM_UNTOUCHABLE` (0xec7438, id 0x80000018 ->
    `system\system_untouchable.efp`, MEASURED), but no code site plays that id (no `18 00 00 80`
    in the asm, none of the effect factory's call sites). Who plays it is OPEN; OpenSRO plays none.

## The timeline of a teleport

Server (SR_GameServer.exe), a gate as the example:

| # | Step | Where |
|---|---|---|
| S1 | 0x705A reaches `GObjPC::HandleTeleportUse`: checks, fee, the destination read (0x4e0a40 -> 0x407760), internal 0x7ce6 posted | 0x513590, 0x5139c9 (READ) |
| S2 | `FUN_004f2b50` performs the warp through vtable +0x378 | 0x4f32a9 / 0x4f367e / 0x4f37b2 (READ) |
| S3 | `CGObjPC::vslot_222` stores the destination and calls `FUN_004df050`: trade and party clean-up, **life state 3 (GONE)**, then the save request (`FUN_004e0050` -> account +0x2c) | 0x4df590, 0x4df22c (READ) |
| S4 | The others' despawn (0x3016 / the block removal 0x5344b0) | INFERRED here, before S5; the instruction is OPEN |
| S5 | The save completes (`AQ_CharDataSaver`) and `CMainProcess::CharDataSavingCompleted` sends **0x34B5** with the arrival region | 0x4413f3 / 0x441453, 0x437de0 (READ; the link from S3 INFERRED) |
| S6 | The client's **0x34B6** -> `FUN_00402e60` -> 0x437e80: 0x7005, the lobby entry destroyed and remade; the character data sent; the entry waits in state 2 | READ |
| S7 | The client's **0x3012** -> `Game__EnterWorld` (0x403350, requires state 2) -> `CGame::EnterWorld` (0x417240) | READ |
| S8 | `CGObjChar::EnterWorld` -> `CGObj::EnterWorld` (0x485360) at 0x417574: MoveTo (0x485740 -> 0x4858e0) puts the PC into its block; the block insert (0x534340) sends the watchers **0x3015** (`FUN_00533f70`) with the body-mode byte as it is then (chardata[3], 0x4a9b70) | READ (the insert being synchronous: INFERRED) |
| S9 | `vslot_391` at 0x417600: `SetBodyMode(2, 0, 6.0, 0)` -> **0x30BF kind 4 = 2** to the block | READ |
| S10 | 6.0 s later the job sets mode 0 -> **0x30BF kind 4 = 0** | 0x406087 (READ) |
| S11 | A client that never sends 0x3012: `CLobby_RemoveStalePlayers` (0x437a50, on the main tick 0x414140) adds the elapsed time to every state-2 entry and deletes one past **300.0 s** (0xb45c40, the test at 0x4370e0), logging "StalePlayer clear!"; it is never put into the world | READ (when the count starts: INFERRED) |

So other players first see the character **at its 0x3012** -- not at the teleport, not at the
0x34B6 -- as a spawn carrying the mode it had (0, INFERRED), followed at once by body mode 2.
Someone who walks into view during the six seconds is spawned with mode 2 in the record
(INFERRED: the record reads the live byte). The single spawn ends with a u8 spawn type
(0x533f70; 5 and 6 add a u32); whether it carries the entry reason (`FUN_00437110`: 1 a login,
2/3 a warp) is OPEN. No teleport-in effect is sent (READ: none on this path).

Client (sro_client.exe):

| # | Step | Where |
|---|---|---|
| C1 | 0x34B5 -> `FUN_0086e100`: **0x34B6 sent at once** (an acknowledgement, before any loading), then `OnResetClient` (0x86dab0): 0x77b540, the zone reset 0x787860, the loading screen `FUN_0084b6e0(region)`, 0x8ac070 | READ |
| C2 | **The screen goes up** in 0x84b6e0, which sets CPSMission +0xe4 = 1 (loading) and +0xe5 = 0 (not ready) (0x84be02, 0x84be08). On the way every object is deleted with no fade, the old own player included (`FUN_009c2c20(1)`, call at 0x84b75e) -- **no own player exists** from here | READ |
| C3 | 0x34A5 (`FUN_008a6580`), 0x3013 (`FUN_008a8c00`, buffered), 0x34A6 (`FUN_008abba0` -> `FUN_008ab0e0`): SWorld's load mode on (`vslot_017` +0x68cf = 1 at 0x8ab23e; read as synchronous loading: INFERRED); the own `CICPlayer` created (0x9c1ce0) and read (vslot 0x64 at 0x8ab267 -> `CICPlayer::vslot_025` 0x9d9a80 -> `vslot_027` 0x9d53d0) | READ |
| C4 | `vslot_027`: `CGWorld::FUN_00aa2190(region, 1)` loads the arrival region and its 3x3 neighbours, then the position is set (+0x8c..+0x98) and `FUN_009dbcc0` -> `FUN_009d17e0`: the 2.0 s appear fade (0xd86ecc) | READ (whether the fade is visible after a long load is OPEN: dt is clamped to 3.0 s, 0xd8adc4) |
| C5 | `FUN_0084ab50` (0x8ab272) sets **+0xe5 = 1**. All of C3-C5 runs inside one packet handler; no frame is drawn during the region load | READ (no frame: INFERRED) |
| C6 | The next CPSMission tick (`vslot_012` 0x84c300 -> `FUN_0084c060`): the gauge; return while +0xe5 == 0 (**the only gate: no timer, no minimum time**); **the screen's windows 0x64-0x66 removed** (0x84c0e5..0x84c11b); **0x3012 sent** (0x84c1b1..0x84c208; 0x3014 instead when `DAT_00eed578`+0x160 == 4, OPEN); 0x750e; +0xe4 cleared, a 1000 ms timer 0xd on the own player (what it does: OPEN), the in-world UI (0x786f30), +0xe0 = 2 | READ |

So the own character is built behind the screen and is first drawn in the tick that removes the
screen and sends 0x3012 (READ order; "never drawn before" INFERRED). The client has no loading
timeout (READ: only +0xe5 gates the step).

## Which paths re-enter

Every warp goes through vtable +0x378 (`vslot_222`) and so through S3-S10 (READ, the call sites):
the gate and NPC teleports (`FUN_004f2b50`), the return and reverse return scrolls (the expendable
use -> 0x4a00c0 / 0x4a0380 -> `FUN_004e0b50` -> AJStateChanger kind 0xb -> +0x378 at 0x4062d8),
the death "return to point" (`Revive` 0x4df560), **the GM warps** (`DispatchCommand` case 0x10
"MoveTo" 0x51e4ec, case 8 "MoveToPlayer" 0x51e853, cases 0x1b-0x1e, `OnCommandMoveToNpc`
0x5207f1), the fortress dungeon (0x630a97), the siege (0x601170 / 0x601400), the Forgotten World
tickets (`CWicket` 0x60268b / 0x602788), the battle arena (0x662be5), the Roc events and the quest
instances. **The first login** takes the same 0x3012 -> `CGame::EnterWorld` -> `vslot_391` path,
so it also gets 6 s of mode 2. **A revive in place** sets `SetBodyMode(2, 0, t, 0)` itself
(0x4df496; t 6.0, or 11.0 in a siege world, 0x4df463..0x4df474). READ.

Not a re-entry: **Ghost Walk and the other `tele`/`tel2`/`tel3` movement skills** --
`FUN_005862e0` -> EngageSkill -> `CGObjPC::vslot_305` (0x4ef300) -> 0x48b920 -> MoveTo (+0x39c),
no +0x378, no life-state change, no SetBodyMode. READ. They get no protection.

**GMs** arrive in mode 4 (invisible, no timer) instead of 2 when vtable +0x53c answers non-zero
(`vslot_335` 0x4e5950, the account's privilege byte +0x3d). READ; that +0x53c means "is a GM" is
INFERRED.

## OpenSRO

| Path | Handler (server/internal/session) | Through |
|---|---|---|
| World entry (login) | `enterOwned` (OpEnterWorld, Start 0x7001) | `hub.EnterHeld` + `holdArrival` "enter world" |
| Gate / NPC teleport | `teleporter.use` (OpTeleportUse) | `warpVia` "gate teleport" |
| Walk-in portal, dungeon (instance) entry and exit | `teleporter.walkIn` (walkin.go) | `warpVia` "walk-in teleport" |
| Return scroll | `ScrollCaster.complete` -> `warpHome` | `warpVia` "return scroll" |
| Reverse return scroll (recall point, death point, map point) | `ScrollCaster.complete` | `warpVia` "reverse return scroll" |
| Death: resurrect at the return point (option 1) | `ReviveHandler` -> `returnToPoint` -> `warpHome` | `warpVia` "death: return point" |
| Death with `-player-dead-state` off (the instant respawn) | `returnAfterKill` -> `warpHome` | `warpVia` "death: respawn after a kill" |
| The developer panel's zone box and town buttons (OpChangeZone, a GM account only since round 854; anyone else is refused and stays put) | `handleChangeZone` | `warpVia` "zone change" |
| GM `/tp x z`, GM `/goto <monster>`, GM `/goto <zone>` (round 854: the server's warp, guard or not) | `GMCommandHandler` | `warpVia` "gm /tp", "gm /goto" (the server warps; the reply carries no move) |
| `/unstuck` (OURS command) | `handleUnstuck` | `warpVia` "/unstuck" |
| Revive in place (option 2) | `ReviveHandler` | `startProtection` (no hold: not a re-entry, as retail) |
| Ghost Walk / blink skills | `moveBySkill` | none (READ: not a re-entry) |
| Job, guild, quest, fortress, event, arena warps | -- | none exist in OpenSRO (the server has the open world only: `inOpenWorld` refuses the other worlds' points) |

`TestRound786EveryRelocationGoesThroughWarpVia` pins this census: it parses the package and fails
when a `hub.Enter`/`ChangeZone`/`Relocate` or a warp appears anywhere else.

- **The hold (OURS mechanism for S3-S8).** `world.Entity.Held`: a held character is in every hub
  index but the message blocks, so no window holds it, no crossing spawns it, `Sees` is false, the
  monster AI skips it. The warp sends the mover its `OpChangeZoneResult` and the old window its
  0x3016 at once (S4), and nothing to the new window. On 0x3012 (`OpReadyToPlay`, retail's
  opcode, empty) `releaseArrival` files it in its block, sends the spawns both ways
  (`arrivePlayer`, S8) and then body mode 2 (`startProtection`, S9). OpenSRO's arrival message is
  its own `OpChangeZoneResult` / `OpEnterWorldResult`, not 0x34B5 and the character data (the
  protocol's shape is kept); 0x34B6 has no counterpart.
- **The timeout (READ value, OURS mechanism):** 300 s, then the session is closed and the
  disconnect takes the character out; it is never shown. `arrivalHoldTimeout`.
- **The protection:** 6.0 s (`ProtectionAfterArrival`), body mode 2 broadcast at the release and 0
  at its end, 2 in a spawn record during it. An attack (OpAttack), a skill (OpUseSkill) and a duel
  blow are refused (`untouchableRefusal`, shown by the client as the archive's
  `UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_TEMPORARILY`), whichever side is protected; a berserk is
  refused; monsters skip the player when acquiring, release it in BATTLE ("target untouchable"),
  and a swing already handed to a strike worker lands nothing. Nothing ends it early.
- **The client:** the report (`ArrivalGuard.ReadyReport`) is armed by the world entry and by each
  zone change's result and sent from `World3D._drain_initial_load`'s end -- the cells built, the
  screen lifted, as C6 orders it. NetClient keeps the own body mode; in mode 2 it refuses skills
  and duel blows itself (C, 0x81ba58 / 0x791fda); the own screen flashes on any non-zero mode; no
  look on the body.
- **`-arrival-guard`** (default on) turns all of it off for an older client.

## Differences from the request (flagged)

- 6.0 s, not 5 s (READ above; the 5 is the authored text's).
- Nothing the player does ends it; the protected player cannot attack or cast instead.
- Ghost Walk and the other skill teleports get no protection (retail's are not re-entries).
- A client that never reports is disconnected after 300 s, not shown.

## OPEN / OURS

- GMs: retail arrives a GM in mode 4 (invisible, untimed; INFERRED that +0x53c is the GM test).
  OpenSRO gives a GM the same mode 2 (OURS): it has no GM invisibility to leave.
- Damage over time from a state applied before the teleport is not stopped during the hold or the
  protection: what retail's states do while the PC is out of the world, and whether a DoT tick goes
  through the attack check, was not read (OPEN).
- The monster AOI (the monsters a held client is sent) is not held: retail sends them after
  EnterWorld too (INFERRED); OpenSRO's client takes them during its load as before (OURS).
- The 0x3015 spawn type byte's link to the entry reason; the `SYSTEM_UNTOUCHABLE` effect's player;
  the 1000 ms timer 0xd after the load; 0x3014 for mode 4 of `DAT_00eed578` (OPEN).
- The siege world's 11 s and a data-driven world's own time: no such world in OpenSRO.
