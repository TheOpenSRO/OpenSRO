# Review of round 747 (A5: far other players drawn as GPU instances, CrowdGpu)

Independent adversarial review. Branch `worktree-agent-a47fd3096adf8795d`, head `0b2cd15e`, diff
against dev `daeb1b0c`. Reviewed in a detached worktree. Godot ran only on the render box
(`RENDER_DIR=/opt/opensro-client-r747rev`, own lock `/var/tmp/r747rev/lock` for headless work; the
shared lock `/var/tmp/godot-lock/lock` for the perf gate, the crowd boots and the GPU timing, with
no other lane's Godot alive: both crowd boots report `overlap: 0`). Labels: **READ** (our code, or
Godot 4.2.2 at `4.2.2-stable`), **MEASURED** (the box: RX 7600, RADV, Forward+ through
`xwl_run.sh`, the retail archives), **INFERRED** (from code, not run), **OPEN**.

The review's probes were scratch scripts copied into the review's box copy only, never committed,
and removed afterwards; the crowd boots ran on that copy with two counters added to it
(`QaCrowdProbe`: frames over 40 ms; `AnimSounds`: dispatch count), restored afterwards.

## Verdict

**Ship after finding 1, which is a one-line fix.** The far path draws what the near path draws:
the round's arithmetic and pixel parity holds up, the headline numbers reproduce (1000 standing
**90.3-92.0 -> 17.1-18.1 ms**, draws **8,551 -> 1,119**), and the perf gate is SAME on all four
numbers. Clicking, name plates, the target ring, Circle's blobs, Detail's casters, one-shots,
death, sitting, redress, reglow, departure and zone change all go through paths that either never
touched the skeleton (the holder carries them) or wake the body first.

What does not hold is the audio around the hand-off. **Finding 1 is a regression, not the
labelled departure:** a far body that is woken for a hit, a death, a sit-down or a pick-up loses
that clip's first-frame sound. That covers every hit moan in the archive. Finding 2 puts numbers
on the labelled departure and proposes a cheap fix. Finding 3 is a main-thread cost measured at
about 12 ms an upload. The rest are small and cheap.

## Gates

- `remote_godot.sh check`: **`checked 664 scripts and 9 scenes` / `ALL LOAD`**.
- `remote_godot.sh tests`: **`ran 253 suite(s), 0 failing`**.
- `perf_gate.sh --base daeb1b0c --head 0b2cd15e --sites jangan --frames 40000`: **exit 0, SAME on
  all four numbers**. Three runs a side; the gate repeated three runs that the review's own
  headless probes overlapped, and kept only the clean ones.

  ```
  jangan  frame ms   base 1.50  head 1.50  (+0.0)  SAME
  jangan  entry ms   base 9272  head 9160  (-112.0)  SAME
  jangan  freeze ms  base 2893  head 2872  (-21.0)  SAME
  jangan  hitches    base 4  head 4  (+0.0)  SAME
  ```

- **Crowd, 1000 bodies** (`crowd_run.sh`, r736's lineup, 1920 x 1080, Middle; steps
  `base,base,move,run,net,base`, `OPENSRO_QA_CROWD_DELAY=10`; A5 off is the same build with
  `OPENSRO_QA_CROWD_GPU=0`; MEASURED, `overlap: 0` both):

  | step | A5 off p50 / p95 | A5 on p50 / p95 | draws off / on |
  |---|---|---|---|
  | base (standing) | 90.31 / 94.39, 90.80 / 94.20 | **17.95 / 22.98, 17.09 / 21.40** | 8,552 / 1,122 |
  | move | 103.54 / 181.52 | 22.59 / **56.44** | 8,549 / 1,142 |
  | run (in place) | 93.02 / 100.06 | 17.32 / 21.57 | 8,551 / 1,147 |
  | net | 119.86 / 126.01 | 31.34 / **39.88** | 8,558 / 1,165 |
  | base (after walking) | 92.01 / 95.55 | 18.05 / 23.00 | 8,558 / **1,188** |

  These agree with r747.md section 5 within the spread. The on boot reports `far=980 groups=326
  instances=7832 ... refused={}`, `gpu_ms` 1.1, `sound_ms` 0.15 (4.93 off). The switching window
  (bodies 410 -> 980 far) ran at 57-86 ms a frame, against about 90 ms a frame for the same window
  with A5 off. Its one large frame, 266 ms, falls where the off boot has a 306 ms frame, so no
  hitch can be pinned on A5.

## Findings, most severe first

### 1. REGRESSION (audio): a woken far body's one-shot loses its first-frame sound, including every hit moan

**Where:** `client/scripts/World3D.gd` l. 6802 (`_anim_sounds.rest(skel)` when a body goes far),
l. 6361 (`_play_once` -> `_crowd_wake`), l. 6835-6848 (`_crowd_wake`, which does not undo the
rest); `client/scripts/audio_anim/anim_sounds.gd` l. 178-205 (`advance`: a rested body's first
advance takes `prev = clip_ms`).

**Evidence:**

- **The mechanism (READ).** A body that goes far is rested, so `_state[id] = null`. When a hit,
  death, sit-down or pick-up wakes it, the first `advance` it gets is the one-shot's. That advance
  takes the "back from rest" branch, `prev = clip_ms`, so nothing at or before the first tick's
  clip time fires. A near body's state is live, so the same one-shot takes `prev = -1` and fires
  from 0. r747.md says a woken body "resume[s] silently, as a body coming back into hearing does".
  But the rest rule exists to stop a body firing what it missed while away. This one-shot starts
  at the moment of waking.
- **Demonstrated (MEASURED)** with `anim_sounds_test.gd`'s own fixture, in a scratch copy:
  a body advanced on its run loop, rested, then given the die clip (`voc_death` at 0 ms) fires
  `[]` with its first tick at 0 ms or at 16.7 ms. The same body, never rested, fires
  `MOB_MANGNYANG:voc_death`.
- **What is lost (MEASURED, every player-character `.bsr` in Data.pk2, 174 files, tracks with a
  key at or before 17 ms, the first tick):**

  | clip | first-frame tracks / all tracks |
  |---|---|
  | hit 3, hard hit 9 | **voc_moan 86/86 and 67/67** |
  | die 4 | 119/164 (voc_death 68/68) |
  | sit down 13 | voc_emo 66/66 |
  | pick up 38 | snd_pickup 66/66 |
  | attacks 2, 5, 16, 17 | 34/867, 81/878, 43/556, 42/578 |
  | skill clips 26-43 | 0-100 % by type (e.g. 28: 264/470, 40: 179/278, 41: 144/144) |

  So within 600 of the listener, beyond the 16 bodies nearest the camera, no other player moans
  when hit. Many deaths and sit-downs are silent too. Before the round every one of them played.

**Fix:** in `_crowd_wake`, give the body a live sound state when it is in hearing. One way is an
`AnimSounds.wake(skel)` that erases `_state[id]`; the next one-shot then takes `prev = -1`. Finding
2's fix removes the cause altogether, since a far body in hearing is then never rested.

### 2. DEPARTURE (quantified, as asked): what the 16 nearest rule silences, and a cheap way back to the READ 600 rule

**Where:** `World3D.gd` l. 6797-6802 (`_crowd_switch_due` rests every body it sends far);
`crowd_gpu.gd` l. 47-55 (`near_count` 16).

**What is lost (MEASURED track data as above; per body):**

- **Running (type 7):** 676 tracks over 419 sets, mean clip 857 ms. That is about **1.9 footstep
  requests a second** per running far body. Walking (type 1) is about 1.3 a second.
- **Standing (type 0):** 53 of 264 stand sets carry a `snd_stand`/`snd_stand1` at the loop's
  start, mean clip 3.5 s. That is about 0.06 a second averaged over standing bodies.
- **Sitting (14):** no tracks, so nothing is lost.
- **Attacks and skills** are one-shots, so they wake the body and play, except for their
  first-frame tracks (finding 1).
- **In numbers:**
  - A town with 60 players in hearing: 44 are past the nearest 16, so about **84 footstep
    requests a second** are lost while they run, and about 2.5 a second while they stand.
  - r736's lineup of 1000: about **1,860 a second** while they run.
- **Against the caps** (`SoundTable.VOICES_PER_SOUND` 4 with a random busy voice restarted, READ
  FUN_00c1db70; `AudioService.MAX_EFFECT_VOICES` 32, OURS):
  - A dense crowd saturates the voices either way, so there the change is the rate of restarts
    rather than silence.
  - A sparse one loses discrete, audible steps.

  The review could not count audible voices in the lineup. The instrumented `QaCrowdProbe` boots
  dispatched 0 tracks in 6 s of `run` with A5 **off** too: the QA lineup bodies do not exercise
  the clip-sound path. That gap in QA tooling is OPEN.

**Proposed fix (OURS, not built):** drive far bodies' sound tracks from the clip time on the CPU,
without posing.

- **Where:** once a frame, in `_crowd_gpu_step` after the flush.
- **Which bodies:** each far body within `SoundTable.CULL_DISTANCE` of the listener.
- **The call:** `_anim_sounds.advance(skel, e[1], float(e[5]), _loop_ms(e[1], _idle_anim_time +
  float(e[3])), true)` with `e = _crowd_gpu.entry_of(skel)`.
- **Resting:** only as the body leaves hearing, by the same rule as the tick's `info[1]`, and
  never on going far.
- **Position:** the sound plays at `owner.node`, the holder, which is already right for a far body
  (READ, `anim_sounds.gd` l. 245-249).
- **The voice caps** stay as they are.
- **Keep the cost low:** advancing all of them naively costs about what A5 saved here,
  `sound_ms` 4.93 at 1000 with A5 off (MEASURED). So:
  - skip clips whose sound set is empty, cached per clip object (every sitting loop and about
    80 % of stand sets, MEASURED above);
  - keep each far body's next track time in clip ms, and call `advance` only on the frame the
    clock passes it.

  A standing crowd then costs one float compare a body; a running one costs about 2 advances a
  body a second (INFERRED: well under 1 ms at 1000).

### 3. PERF: every bone-texture upload costs about 12 ms of main thread at the size the catalogue needs

**Where:** `crowd_gpu.gd` l. 537-554 (`_upload`: `l.data.to_byte_array()`, `Image.create_from_data`,
`ImageTexture.update`, whole texture), l. 82-87 (`MAX_ROWS` 16384, `UPLOAD_FRAMES` 15).

**Evidence (MEASURED):**

- **Size.**
  - **Census:** every Figure (13 a race and sex) with every weapon of its race and sex, 364 bodies.
    The loops a far body can play (stand, run, sitting) need **6,156 rows** on `europeman_skel`
    (44 bones) and **4,976** on `europewoman_skel` (46 bones). Both races share these two
    skeletons, so the two layouts are by sex.
  - **The texture:** both grow to the 8192-row cap, 132-138 texels wide, 16.5-17.2 MB each.
  - **The lineup** reached 7,152 rows over both layouts.
- **Cost:** a scratch probe timed `_upload`'s three steps at 138 texels wide on the box
  (Forward+). At 8192 rows: `to_byte_array` 7.9-9.1 ms, `create_from_data` 0.0,
  `update` 1.9-3.3 ms. At 16384 rows: 18-19 ms and 4-7 ms.
- **When it is paid:** an upload happens every 15 frames while a clip bakes, and once when it
  finishes. In play that means every time the crowd meets a clip not yet baked: a new weapon
  group, a first sitter.
- **On a weaker CPU** the 12 ms is about 25-35 ms (INFERRED, 2-3x).

**Fix:**

- Keep the layout store as a `PackedByteArray` written with `encode_float`. That removes the
  8-9 ms copy, leaving about 3 ms.
- Or page the rows into fixed textures of about 1024 rows, as several samplers or a
  `Texture2DArray`. An upload is then 2 MB.

### 4. VISUAL (minor): a hit effect on a far body is drawn where the body went far, for up to a cycle

**Where:** `World3D.gd` l. 20889-20901 (`_draw_wall_blow` -> `_play_hit_efp_on`, no wake at all),
l. 20599-20601 (the DefenseEfp is attached before `_play_other_hit` wakes the body);
`efp/efp_effect.gd` l. 740-760 (`_place`: `skel.global_transform * ...`).

**Evidence (READ):**

- While far, the skeleton is `top_level`, so its global transform stays where the body was when
  it went far (crowd_gpu.gd l. 296). `SkillEffects.attach` -> `follow_host` places the effect from
  that skeleton.
- A walking far body's wall-blow or DefenseEfp is therefore drawn at the old spot. It stays there
  until `_crowd_eligible`'s "effect" brings the body back, up to two cycles (about 20 frames).
  Then it jumps (`ANCHOR_JUMP`).
- A standing body is drawn in the right place.

Every other effect host found goes through `_fx_owner_body`, which wakes the body. That covers
other players' casts as caster or target, and auras.

**Fix:** `_crowd_wake_node(body)` at the top of `_play_hit_efp_on`, or in `SkillEffects.attach`
through a hook as `CharacterBlobs.on_cast` does.

### 5. VISUAL (minor): two moves are not reported, so a far body lags its plate by up to 15 frames

**Where:** `World3D.gd` l. 21536-21543 (`_on_skill_moved`: `body.position = to`, another player's
Ghost Walk landing), l. 10619 (the cast start's facing snap, `body.rotation.y = ...`).

**Evidence (READ):** neither calls `_crowd_gpu.moved(body)`. A far body is re-read only by the
ring, `REFRESH_FRAMES` 15, about 250 ms at 60 fps. The name plate, the click body and the ring are
on the holder and move at once. The facing snap is usually followed by `_play_other_cast_anim`,
which wakes the body; a skill with no cast clip does not.

**Fix:** report both with `_crowd_gpu.moved(body)`, as the round did for the other writers.

### 6. BUG (minor): a body chosen far is switched up to a cycle later without re-checking eligibility

**Where:** `World3D.gd` l. 6767-6799 (`_crowd_switch_due` calls `_crowd_gpu.add` for ids chosen at
the last `_crowd_choose`).

**Evidence (READ):**

- Eligibility is taken during the scan, which is spread over 10 frames, and the switch is
  budgeted. A body can become a Detail caster, berserk or an effect carrier after it was scanned
  and still be sent far.
- `CharacterBlobs.on_cast` wakes a far body, but this one was still near when it was chosen, so
  the wake did nothing.
- It then draws far without its Detail shadow (instances cast none), or with its berserk twin
  frozen, until the next cycle wakes it.

**Fix:** `if _crowd_eligible(id, node, skel) != "": continue` before `add`.

### 7. PERF / MINOR: groups and twins are never released, and the twins pin ObjectLight's weakly held level copies

**Where:** `crowd_gpu.gd` l. 978-1014 (groups are made, never freed), l. 1066-1068 (`_twins`,
`l.twins`, `_twin_sources[key] = src`); `assets/object_light.gd` l. 242-260, 281
(`with_object_color` keeps its copies by `weakref` and prunes the dead ones; `VARIANT_STEPS`
1024).

**Evidence:**

- **READ:** nothing frees a group or a twin before `PREDELETE`. `_twin_sources` holds every level
  copy a far body ever wore, which defeats `_prune_variants`.
- **MEASURED:** the crowd boot went from 326 to 376 to 399 groups and twins over its two walking
  steps, the bodies moving within 8 units. Back standing, it drew **1,188** calls against 1,119
  before. Empty groups cost no draw (READ, `render_forward_clustered.cpp:313`, `instance_count ==
  0` skipped), so the extra draws are today's level diversity. The leak is memory, plus
  `_push_groups`' per-frame loop over every group ever made.
- **INFERRED:** a session in a busy town grows these without bound. The light levels split a
  walking crowd's groups well past the lineup's 326.

**Fix:** drop a group that has been empty for N cycles (`free_rid` its instance and MultiMesh),
together with its twin and source entry; hold sources weakly.

### 8. VISUAL (latent): translucent far parts sort as one object at the crowd's centre

**Where:** `crowd_gpu.gd` l. 994 (`instance_set_pivot_data(g.inst, sort, true)`) with the one
custom AABB for every group (l. 587-614).

**Evidence:**

- **READ:** a transparent instance is sorted by its AABB's centre (`use_aabb_center`). Every far
  group has the same AABB, so blended far parts sort against each other only by
  `sorting_offset`. Against the world's other blended surfaces, the whole crowd sorts as one
  point.
- **Two-pass items:** `ObjectLoader.add_front_pass` twins with +0.01 would draw every far body's
  back pass, then every front pass.
- **MEASURED, the reassuring half:**
  - Across the 364 catalogue builds above, plus every armour set of one Figure a race and sex,
    **no part is blended**: 1,076 alpha-tested one-sided, 497 two-sided, 884 solid and 494 glow
    surfaces.
  - So r747.md's "not sorted between far bodies" is not visible with the starter kit.
- **OPEN:** higher-degree armour, avatars and job suits were not in the census.

**Fix, should any be blended:** refuse a body with a blended part in `_parts_of` (it stays near).
That keeps the look exact.

### 9. MINOR (latent): a mirrored body would draw with the wrong winding

**Where:** `crowd_gpu_vertex.gdshaderinc` (the body transform goes into `VERTEX`; the instance
transform is the identity).

**Evidence (READ):** Godot flips a mirrored instance's cull from its transform's determinant.
Here `MODEL_MATRIX` is the identity, so it never would. No other player in the world is mirrored:
only the select screen, the portrait and the doll roots are, and none uses CrowdGpu.

**Fix:** refuse in `add` when `b.xf.basis.determinant() < 0`.

### 10. WRONG-LABEL (minor): "nearest in view", and "about 6 ms"

**Where:** `crowd_gpu.gd` l. 40 ("the K nearest in view stay near"), l. 56-58 (`NEAR_HYSTERESIS`,
"nearest in view"); `World3D.gd` l. 6610-6612 ("nearest the camera in view"). The code and r747.md
are "in view or not".

`crowd_gpu.gd` l. 53-54 says 16 against 64 is "about 6 ms". r747.md measured 23.06 / 22.50
against 17.84 / 18.05, which is about 5.

r747.md section 2's "the number decides only who is heard and posed" misses finding 1.

**Fix:** correct the comments.

### 11. OPEN: the weaker GPU (Intel HD 630, 720p Low) and Compatibility on Mesa Intel

Nothing in the round or its tests ran on Intel. The Compatibility check was radeonsi only.

**What is known:**

- **Texture sizes are safe.**
  - **Bones:** 138 x 8192 at most for the whole catalogue (finding 3), against `MAX_ROWS` 16384,
    the GL and Vulkan limit the HD 630 reports.
  - **Bodies:** 1024 texels wide; 4 rows at 1000 bodies, 32 rows (512 KB) at 5000.
  - **Volume:** a row per variant in use.
- **VRAM:** about 34 MB of bone textures at full catalogue diversity, plus MultiMesh buffers at
  64 B an instance (0.5 MB at 1000, about 2.5 MB at 5000). The CPU holds a copy of each, plus a
  transient copy at each upload.

**The open risk** is the vertex cost on a GT2:

- every far vertex fetches 16 RGBA32F texels every frame, 28 for a Volume variant;
- Forward+ runs the vertex shader twice (the depth prepass), where Godot's compute skin runs once
  per pose change.

At 1000 that is tens of millions of fetches a frame (INFERRED). It needs a measurement on the
device. A shipped way to turn A5 off for a GPU class is also needed: today only the QA variable
`OPENSRO_QA_CROWD_GPU=0` does it.

## Checked and fine

**Visual parity:**

- **Lighting:** the twin is the same object shader. `MODEL_NORMAL_MATRIX` is the identity, and
  `NORMAL` is already in world space. CharacterLight levels are separate twins.
- **Fog** is the opaque fog pass on depth.
- **Glow tiers:** the same `srr_glow_clock`.
- **Volume and Height:** the probe and test arithmetic, 8e-6.
- **Colour variants and kit:** `refused={}` at 1000.
- **Shadows:**
  - Middle/Low draw Circle (1), and the blobs follow the holder, so far bodies keep their circle.
  - The sun shadow is on only at Detail (READ, `World3D.gd` l. 483).
- **The hand-off:** the same frame index (`frame_of` == `CrowdAnim.frame_index`). The wake poses
  at once. The transform is written in the same `_process` as the walk and turns.

**Behaviour:**

- **Clicking, name plates, the ring:** the click body, the plate and `_marker_target_position`
  are all on the holder.
- **PvP:** this client's own blows resolve against monsters only. Others' casts on a far player
  wake it through `_fx_owner_body`.
- **One-shots:** the wake is synchronous inside `_play_once`, 0 frames.
- **Death:** a held one-shot is not a loop, so the body stays near.
- **Sitting:** a baked loop on the GPU; the sit-down wakes the body.
- **Equipment and reglow:** the redress wakes the old skeleton, and 0x3038 wakes before the
  reglow.
- **Departure:** the body is woken before its fade.
- **Zone change:** `queue_free` -> `tree_exiting` -> `remove`.

**Regressions:**

- The local player, NPCs and monsters never enter CrowdGpu (only `_other_gaits`). The perf gate is
  SAME.
- The object shader change is under `#ifdef CROWD_GPU`, and `object_light_test` passes.
- The select screen and the portrait do not use World3D's crowd.
- Round 738's sound-tag fix holds: a far entry keeps the body's own clip object, while
  `Layout.clips` is keyed by the shared `Frames`.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
