# The animation mixer: how the client moves from one clip to the next

Recovered in round 808. Labels: **READ** = from `sro_client.exe` at the cited address (read from the
disassembly: Ghidra loses the x87 stack in nearly every function below); **MEASURED** = counted in
`Data.pk2`; **INFERRED** = a conclusion from read facts, with its basis; **OURS** = OpenSRO's own
choice. The research notes are in round 808's WORLD_ISSUES entry.

## Why it matters

The client never swaps a body's pose in one frame. A click behind a standing player starts the run
from its first frame, fading it in over 100 ms while the stand fades out over 200 ms; the arrival
lets the run go on cycling while it fades out over 200 ms. That is the "step" a player sees when
the character turns round and stops. There is no turn-in-place clip: types 24/25
(`chinaman_a_standroll`, 1000 ms, cyclic, in every body: MEASURED, 108 entries) are never played by
any character play call (all 37 `+0xbc` / `+0xc0` sites in `0x9b0000..0xa60000` scanned), nor is
type 23 (walk backward).

## The play call

Character vtable `+0xbc` = `0x9cfb40`, `play(type, A, B, C, speed, weight)`: it forwards the call to
`+0x9c` slot 3 of up to two linked objects (`0x9ce930`, `0x9ce910`; INFERRED a ride's partner,
OPEN), then calls its own (`0xa5b6d0` → `CCObjAnimation::FUN_00a5b550`):

- the entry by type in the group, then in `default` (`body_animations.gd`);
- `weight` clamped to 1.0;
- the clip's own `.ban` IsCyclic word decides the list, not the caller (`CCompChar +0x70` →
  `0xc52a10`);
- **loop**: `+0x74(clip, weight, A = fade-in ms, speed, C)` → `AniMixer::FUN_00c55360`; B unused;
- **one-shot**: `+0x78(clip, A = fade-in ms, B = fade-out ms, speed, C)` → `AniMixer::FUN_00c554e0`;
- `C` switches the clip's key events on (footsteps, hits; `0xc73020` returns early when 0).

`stop(type, ms)` = `+0xc0` → `0x9cfc10` → `+0x9c` slot 5: the clip's weight to 0 over `ms`, then it
is dropped.

## The rules

- **A loop played starts over** — t = 0, weight 0 — even when the same clip is on the list
  (`CRTAnimation::vslot_001` `0xc74170`, `0xc731a0`).
- **A loop's frame** (`CRTAniCyclic::vslot_002` `0xc74790`): `step = round(speed × dt_ms + carry)`;
  `t += step`, wrapped at the length; while `rem > step`, `w += (target − w) × step / rem` and
  `rem −= step`; then `w = target`, and a clip whose target is 0 is dropped.
- **A one-shot** (`CRTAniOneShot::vslot_002` `0xc749a0`; A at `+0x94`, B at `+0x98`, `0xc732b0`):
  fade in `w = 1 − rem / A` (A = 0: weight 1 at once); play to the end; **hold the last frame and
  fade out**, `w = rem / B`; dropped at 0. A stop fades it at its current weight's rate
  (`0xc73310`).
- **The mix, per bone** (`AniMixer::FUN_00c54200`, `CRTBone::vslot_002` `0xc48e30`, `vslot_005`
  `0xc48ef0`): within a list a normalised weighted average (the first sample copied, then each
  next `t = w / (acc + w)`, slerp / lerp, `acc += w`); the one-shots committed first at
  `min(acc, 1)`, the loops into what is left, `w2 = min(acc, 1 − committed)`, as
  `lerp(one-shots, loops, w2 / (committed + w2))`. A one-shot at weight 1 hides every loop; a lone
  clip shows fully whatever its weight; with nothing playing the bones keep their last pose.

## The character states that play

The state table at `0xec5fb8`, `0x28` bytes a state (enter, update, event, exit; u16 needs,
forbids, clears); enter `0x9c9920`, leave `0x9c8810`; the live mask `+0x65c`.

| state | plays | fades (in / out, ms) |
|---|---|---|
| 3 STAND `0xa5a160` | from SIT: 15 (stand up) one-shot; then enters 8 | 0 / 200 |
| 6 SIT `0xa5a270` | 14 loop; from STAND also 13 (sit down) one-shot over it | 200; 0 / 200 |
| 6's exit `0xa59440` | stops 14 | 200 |
| 7 FIDGET `0xa59460` | one of 122, 61, 81 at random (missing: 122; missing: nothing) | 400 / 400; its end stops it over 200 (`0xa59560`) |
| 8 IDLE `0xa59640` → `0xa592f0` | 6 (battle stance) while `+0x4e0 > 0`, else 0 | 200 |
| 8's exit `0xa59660` | stops the idle, enters 9 | 200 |
| 9 MOVE `0xa59680` | walk 1, run 7; speed `min(mover +0x8c, 1.3)` | walk 200, run **100** |
| 9's exit `0xa5a6b0` | stops the gait, enters 8 | 200 |
| 10 PICKUP `0xa59a00` | 38 | 200 / 200 |
| 11 HIT `0xa59b10` | 3 (64 from a knockdown) | 0 / 200 |
| 13 EMOTE `0xa59bc0` | `0x32 + n` | 200 / 200 |
| 1 DEAD `0xa59cc0` | 36 loop, then 4 one-shot from standing | 200; 0 / 200 |

The constants are pushed immediates at those sites (`0xc8` = 200, `0x64` = 100, `0x190` = 400).

**The battle stance** (`+0x4e0`, ms): its one setter `0x9c7570` arms **5000** from the attack
state's enter for a player (`0xa5a025`) and from a blow landing on a player character
(`FUN_00a49290` `0xa4966b`, behind `FUN_00504ed0`'s TypeID test); the character tick counts it
down by frame ms (`0x9d1f64`) and at 0 re-enters 8, so the stance crossfades back to the stand
over 200 ms. The server's 20 s BattleState does not drive it.

**The fidget timer** (`+0x510`, the tick `0x9d1ef8..0x9d1f4e`): counts down by frame ms while the
mask holds only alive / stand / idle and the stance is 0, else is reset to **15000**; at 0 it enters
7 and re-arms to **10000 + rand() % 5000**. Player bodies carry only type 61 (MEASURED, all 56;
`chinaman_merchant_standcity02` 2333 ms, the spear group's 3000 ms, ...), so one draw in three plays
it; NPC bodies carry type 122 (128 entries, MEASURED: `..._time` clips).

**The gait's clip rate** is not scaled by the run speed; `mover +0x8c` is a catch-up factor (1.1
behind by more than 5 units along the travel, 0.9 ahead; `0x9e06a0..0x9e07ab`), capped at 1.3.

## OpenSRO

- `client/scripts/assets/clip_mixer.gd` (`ClipMixer`): the two lists, the loop and one-shot rules
  and the per-bone mix, exactly as above (the clock keeps the fraction instead of rounding);
  `ClipMixer.Fade` + `blend_from` for a body in the shared clip tick: the outgoing clip (a loop
  still cycling, a one-shot going on to and holding its last frame) blended over the pose the
  entry wrote, by the same weights; `over` for a one-shot fading in over its loop.
- The local player (`World3D._mix_player`): every action's loop and one-shot go through one mixer
  with the table's fades; the battle stance is the client's 5 s; the fidget (`_step_player_fidget`).
- Other players, monsters, NPCs, pets (`MonsterMotion.swap_loop` with `World3D._pose_fades`): a new
  loop from its first frame with the crossfade; a one-shot's hand-back over 200 ms; the fidget
  (`_step_body_fidgets`); other players' 5 s stance on their swing, cast or a blow
  (`_arm_other_stance`).
- OURS: a body in the clip tick blends its change only within `MonsterCrowd.POSE_FULL` (300) of the
  camera -- the bodies posed every frame -- and a farther one swaps at once (the crowd gate measured
  +0.3 ms a frame over 2,500 monsters when every change blended; +0.1 with this, in the box's noise);
  the die clip is held (OpenSRO's death pose) where the client fades it into loop 36; a
  repeating decoration clip is a one-shot that wraps; a GPU-drawn far body (round 747's crowd)
  swaps its loop at once; a rider and a ridden pet do not fidget; the fidget countdown of the
  bodies in the clip tick is stepped every 0.25 s; a skill's own fades (state 2, `+0x9c` slots
  0x84/0x88) are not read, and its clips take 0 in / 200 out.
## Footprints (round 808's follow-up)

The user: "the snow vs sand plays a different audio noise so there must be something there to tell them
apart" -- there is, and it is the same value: the footstep sounds' material (the high 16 bits of the
ground query, the tile2d type: 1 SAND, 9 SNOW; `AnimSounds.MATERIALS`, `navmesh\tile2d.ifo` -- MEASURED:
22 sand and 22 snow tile textures, OAHO / OAKK / the Taklamakan ruins, and 1,613 regions with some).

- **When (READ).** State 9's event handler `0xa5a3f0` on a footstep key (type 2) with the body's cell
  known: material 1 lays `effect\footstep_sand.ddj`, 9 `effect\footstep_snow.ddj` (Media.pk2); the
  key's second parameter picks the toe, 0 `Bip01 L Toe0`, else `Bip01 R Toe0`. State 9's exit `0xa5a6b0`
  lays both at a stop, for a player character only. The handler itself has no player test (OPEN:
  its `+0x2c2 != 4` exclusion).
- **What (READ).** `SWorld::vslot_026` (`0x9f2c20`, the world `0x1101950`'s vtable `0xde4fb4 + 0x68`):
  (texture, 20000 ms, the toe, 2.0, 3.5, heading ± 0.0785 rad, 0xffffffff, 0); `Map::FUN_009f6040`
  projects a 2.0 (across, along (cos a, sin a); `0xb44a10` cos, `0xb44b40` sin) × 3.5 (along the facing)
  rectangle onto the ground within ±50 (`0xd851a0`), u across and v heel to toe.
- **How it draws (READ, `Map::FUN_00a1fdb0`).** SRCALPHA / INVSRCALPHA; texture × a factor whose RGB the
  footprint flag (+0x4c, set by the caller) replaces with the object ambient (world +0x6853.., channel 3)
  and whose alpha is full until the last 1020 ms, then linear to 0.
- **OpenSRO** (`client/scripts/world/footprints.gd`, `AnimSounds.footstep`, `World3D._on_footstep` /
  `_footprints_at_stop`). OURS: a 3 × 4 grid on the terrain's height lifted 0.1 and depth-tested (the client
  clips the ground's triangles and draws with depth off before the objects); a body's keys are read only
  within the sounds' 600 of the listener; at most 400 prints at once.
