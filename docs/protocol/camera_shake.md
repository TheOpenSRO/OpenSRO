# The camera shake (round 826)

What shakes the camera in the original client, and how. All READ from `sro_client.exe` (md5
2a5794b72c90908d945be8b3f3f2edd4; decomp `/var/tmp/decomp_client`, asm `/var/tmp/sro_client.asm`
on the RE box) unless marked. Labels: READ, MEASURED, INFERRED, OURS, OPEN. Client code:
`client/scripts/world/camera_shake.gd` (CameraShake), `SkillEffects` (the rows),
`World3D._on_skill_shake` / `_own_blow_shake`.

## The shake itself

- **One at a time.** `UI_SILKMALL::FUN_0078db50(mode, strength, length_ms, tick_ms)` on the game
  process object (`ds:0x110f80c`) stores `+0x408` mode, `+0x414` and `+0x420` strength (in force,
  at the start), `+0x40c` length, `+0x410` tick; kills and re-arms timer 4 (length) and timer 5
  (tick) with `FUN_00b93320` (period 0 becomes 1), zeroes the offsets `+0x418` / `+0x41c` and sets
  `+0x424` running. A second shake replaces the first.
- **Timers** (`FUN_00b93320` / `FUN_00b933d0`): an entry {id, period, last, count, flags 3} is
  appended to the list; once a frame each live entry whose `now - last >= period` fires and
  `last = now` (`DAT_0110f800`, the frame's ms). Timer 4 sits before timer 5, so a frame due for
  both ends the shake first.
- **The timer switch** (`0x789870`, `switch(id - 1)`):
  - case 3 (timer 4): both timers killed, `+0x418 = +0x420 = +0x41c = 0`, `+0x424 = 0`;
  - case 4 (timer 5): strength `-= round(start x since / length)` (`since = DAT_0110f800 -
    entry+0x10`, the x87 round-to-nearest-even), 0 becomes 1; then mode 0 draws both offsets,
    1 the height (`+0x41c`) only, 2 the side (`+0x418`) only, each
    `(rand() % (uint)(2 x strength) - strength) / 100.0` (`0xe1b7d8` = 100.0).
- **The camera** (`FUN_0078dc50`): the look-at point (`DAT_0110f7d0 + 0x34c/0x350/0x354`) is the
  player's `+0x90` x plus `+0x418`, the height expression plus `+0x41c`, and z; the eye orbits it.
  It returns early when `+0x3cd` or `+0x3ce` is set (what sets them: OPEN).

## Who starts one

| Caller | When | Strength / tick (length 500 ms, mode 0) |
|---|---|---|
| `IDecoSkill::FUN_00a51bc0` (0xa52e5f) | a skill effect row plays, its Script SCT_SHAKECAM0 / 1 / 2 / 3 (flags 0x8, 0x10, 0x80, 0x100) | 50/20, 200/25, 300/25, 400/25 |
| `IDecoSkill::FUN_00a4bf00` (0xa4bf4f) | the row's mover arrives (`FUN_00a4c380`), SCT_SHAKECAM_MOV0..3 (0x20, 0x40, 0x200, 0x400) | the same four |
| `FUN_00a49290` (0xa495b8) | a damage entry whose attacker is this player: a critical (the hit record's +0xa & 2), or any while berserk (`+0x2c2 == 1`) | critical 50/20, berserk 50/20, critical in berserk 200/25 |
| `FUN_00531a10` (0x531af2) | an `atstructeffect.txt` structure falls to a worse state, when its row's flag (+0x118 + state x 4) is set | 50/20 -- OPEN here: no fortress structures are drawn |
| `FUN_007adf70` (0x7ae0ce) | the chat command `/cs mode strength length tick` | its own numbers -- not built (a developer command) |

- **The SCT_ table** (READ, 0x00ec7378, (name, flag) pairs): none 0, SCT_ARROW 1, SCT_RUT 2,
  SCT_MOVER 4, SCT_SHAKECAM0 8, SCT_SHAKECAM1 0x10, SCT_SHAKECAM_MOV0 0x20, SCT_SHAKECAM_MOV1 0x40,
  SCT_SHAKECAM2 0x80, SCT_SHAKECAM3 0x100, SCT_SHAKECAM_MOV2 0x200, SCT_SHAKECAM_MOV3 0x400,
  SCT_MAT 0x800, SCT_CHAR_SCALE 0x1000, SCT_EFFECT_SCALE 0x2000. The row parser
  (`GlobalEffectManager::FUN_00a9d0f0`) keeps the flag at row +0x78.
- **The class test** before both skill shakes: `FUN_00b94b70(&DAT_00ef1bc0)` on the caster (the
  decoration's owner, `+0x58`; for a mover the object found again by `+0x170`, the caster's id)
  -- `GetRuntimeClass() == CICUser` exactly (`0xb94b30` is an equality). Another player's rows do
  not shake; this player's (CICPlayer), monsters', NPCs' and pets' do; a mover whose caster is gone
  does (a null object fails the test).
- **The row path** (`FUN_00a51bc0`): every row reaches the shake test after its effect is made,
  a row of no effect (a sound's, a none's) too, except an AT_STOP / AT_ONE_FOLLOW / AT_LOOP `.efp`
  row whose effect was not made (`FUN_00a51120` null: the file failed, or the Effect Quality
  option refused it -- `goto 0xa52eec`).
- **MEASURED (Media.pk2 skilleffect.txt):** 391 rows carry a shake: SHAKECAM1 163, SHAKECAM3 47,
  SHAKECAM2 33, SHAKECAM0 30, SHAKECAM_MOV0 66, MOV1 28, MOV2 23, MOV3 1 -- 383 on SHOT rows
  (269 `.efp`, 95 `.bsr`, 19 none) and 8 on S_RETURN (the GM bomb).

## AT_TARGET movers (found on the way)

`FUN_00a51bc0` case 3 (AT_TARGET): when the row's MovTypeSpeed second number (+0x12) is not 0,
CreateCnt movers go from the target's position (+0x80) plus StartOffset (row +0x40) to its
position plus TargetOffset (row +0x58) -- world axes, the target's turn not applied -- and the
group's hit goes with the first (`FUN_00a4d430`). MEASURED: 231 rows (the China force bolts that
fall onto a target). Before round 826 they were placed on the target at StartBone + StartOffset
and never fell; the speed is SkillEffects' INFERRED mover speed, as every other flight's.
