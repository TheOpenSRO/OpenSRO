# Round 756 review: arriving players as CrowdGpu ghosts

This is an independent, adversarial review of `ce5ca744` on `worktree-agent-ad0994c00d104f6c0`,
based on dev `9a5732ed`. The round's notes are `docs/rounds/r756.md`.

- **Labels:** READ, MEASURED (on the render box: RX 7600, RADV, Forward+ through `xwl_run.sh`,
  1920 x 1080 for the crowd runs), COMPUTED, INFERRED, REASONED (from the code, not run).
- **No code was changed.** The probes below (an extended parity bench, a stale-twin probe, a ghost
  light probe and a buff-after-page hook in the lineup) were box-only copies in
  `/opt/opensro-client-r756rev*`. They were never committed and were deleted afterwards.
- **The other lane.** Round 757's reviewer shared the box. Every crowd number says whether
  another Godot overlapped the boot (`overlap`).

## Verdict

**Do not ship as it stands.** The idea works, and its headline holds on the box:

- a 1,000-body crowd is visible in 4.70 s against 12.93 s;
- a page of already-seen kinds is drawn in one frame;
- the ghost and the dressed body draw the same parts across 767 random real kits, with avatars,
  job suits and two light levels, and 0 mismatches.

Three problems break play in an ordinary crowd, and all three are local fixes:

- **F1:** every buff start on a ghost dresses it at once, outside any budget. The server sends one
  after every spawn, so a walk-up page of 260 buffed players takes 726 ms inside the buff
  handlers, and that frame takes 852 ms.
- **F2:** ghost parts are cached with their crowd twin material, and that twin outlives the twin
  `collect()` frees. Once a crowd outgrows its slot texture, a kind seen earlier is drawn from the
  old textures. The probe measured 7 of 7 parts stale.
- **F3:** a ghost that starts walking before its run loop is baked is also dressed at once. If a
  freshly arrived crowd of 1,000 starts walking 3 s after the spawn, all 667 ghosts are dressed in
  one 1.79 s call, in a 1,975 ms frame.

F4 (the late light at 3,000) and F6 (the plate height) are visible parity gaps. Fix F1-F3 and
re-run the gates; F4-F6 can follow in the same round.

## Findings, most severe first

### F1 (High): a buff start dresses a ghost synchronously, with no budget

**Where:**

- `World3D.gd:21988`: `_fx_owner_body` calls `_dress_ghost_now(owner_id)`.
- Reached from `_fx_on_buff_started` (`:22013`), every start.
- Reached from `_fx_resync_owner` (`:22053`), the zone change's `_fx_resync_all`.
- Reached from `_on_skill_cast` (`:10819`, `:10825`), for the caster and a character target.

**Why it is common (READ):**

- The server sends each arriving player's active buffs as `OpBuffStart` frames after the spawn
  (`server/internal/session/playerview.go:261`).
- For a group spawn, all of them follow the whole page in the same `SendFrames`
  (`playerview.go:338-361`).
- The client makes the page's ghosts when the bracket ends (`_on_user_group_end` ->
  `_pump_other_builds`, 50 ms of ghosts), then handles the buff frames.
- So every buffed player who just became a ghost is dressed on the spot, before any aura check.
  At 1.6-3.5 ms a body (r756.md), that is unbudgeted dressing.
- Before round 756, the same buff found the body still queued: it returned null, and
  `_dress_other` resynced the aura (round 739's review, F7).

**Evidence (MEASURED):** a box-only hook in `QaLineup._spawn_page` sent one `OpBuffStart` per body
after each walk-up page, through `World3D._on_buff_started`, as the server orders them. The hook
used skill 0, so no aura is drawn: only the dressing is timed. The runs used
`crowd_run.sh 1000 base,move,base OPENSRO_QA_LINEUP_WALKUP=1.5 OPENSRO_QA_LINEUP_SPACING=16,24`.

| | page 4 (260 bodies, seen kinds) | worst frame | frames over 100 ms | bodies the pump dressed |
|---|---|---|---|---|
| ghosts, no buffs | 2 frames, 171 ms | 130.5 ms | 2 | 1,000 |
| **ghosts, buffs** | buff handlers **726 ms**; 2 frames, 941 ms | **851.7 ms** | **9** | 548 (452 dressed synchronously) |
| ghosts off (`OPENSRO_QA_GHOSTS=0`), buffs | 68 frames, 6,148 ms | 119.5 ms | 4 | 1,000 |

- These three boots had `overlap: 1`, because the gate below ran at the same time. A clean rerun is
  in "F1 rerun" below.
- Smaller pages behaved the same way: 30-40 buffed bodies took 86-126 ms in the handlers, with
  frames of 179-199 ms against 55-72 ms.
- A crowd in a town is mostly buffed, so this is the ordinary case, not an edge.

**Fix:**

- For a ghost, `_fx_owner_body` should return null without dressing it. That is the queued-body
  path: `_dress_other` resyncs the auras from the roster.
- Move that body to the front of the budgeted dressing queue, for example an id set that
  `BuildQueue.pump` sorts before everything else.
- Dress synchronously only where a one-shot must play this frame: `_play_other_cast_anim` and
  `_play_other_hit`, which already call `_dress_ghost_now` themselves.
- The aura then arrives with the dressing, a few frames later, instead of costing a freeze.

### F2 (High): cached ghost parts keep crowd twins that `collect()` has freed

**Where:**

- `crowd_gpu.gd:744-770` (`_lit_parts`) caches each recipe's parts per light level in
  `_recipe_lit`, together with their twin `ShaderMaterial` (`p["material"]`).
- `crowd_gpu.gd:688-702` (`_fade_part`) caches the fade twin in `_fade_parts`.
- `collect()` (`:1606-1630`) frees a group empty for 30 cycles, and with it its twin, from
  `_twins` and from `Layout.twins`. It does not free the twin from those two caches.
- Every later ghost of that kind and level is given the dropped twin again (`_add_part` makes a
  new group with it). That twin no longer receives:
  - the new `crowd_bodies` when the slot texture grows (`:925`);
  - `crowd_bones` when a clip page is added (`:950`);
  - `crowd_volume` when a Volume row is added (`:969`);
  - `crowd_range` on a sight-range change (`:822`).

**Why normal play reaches it:**

- A kind's unlit level (`-1`) group empties within frames, as soon as its ghosts are lit.
- Its fade groups empty 2 s after arrival.
- So about 30 cycles later both are collected, while `_recipe_lit[key|-1]` and `_fade_parts`
  still hold the twins.

**Evidence (MEASURED, `r756rev_stale.gd`, headless, real archives):**

- Steps: one ghost of Figure 1907 fades in; its fade ends; it leaves; `collect()` runs 31 times;
  257 more bodies take the slot capacity from 256 to 512; a second ghost of the same kind arrives.
- **7 of 7 parts sit on twins no longer in `_twins`, all 7 with the old `crowd_bodies`,** both
  while it fades and after (the shared group too).
- On screen (INFERRED, not rendered): that ghost reads a frozen texture sized for 256 slots from
  slot 257. It is drawn from stale or out-of-range body data, so misplaced, frozen or not drawn,
  and its fade-in does not show, until it is dressed. At 3,000 that wait is up to 134 s
  (MEASURED below).
- The trigger is the round's own case: walking up to a crowd bigger than any seen this session,
  after kinds seen earlier have been collected.

**A second effect (REASONED):**

- `_twin_users` counts by `twin_key` (`"%d|%s" % [lit id, layout]`), and the re-made live twin
  for the same material has the same key.
- When a group on the stale twin is collected, it decrements the live twin's count.
- That can erase the live twin from `_twins` while its groups still draw, so those groups go
  stale too.

**Fix:**

- Do not cache the twin. Keep (mesh, lit material, layers, sort, vol, centre) per recipe and
  level, and resolve the twin with `_twin(lit, l)` on each add (a dictionary lookup).
- Or have `collect()` drop the `_recipe_lit` and `_fade_parts` entries that name a twin it frees.
- Add a test: the stale probe's sequence, with `crowd_bodies` asserted to be the current texture.

### F3 (High): a ghost starting to walk with its run loop not baked is dressed at once

**Where:** `World3D.gd:9915-9921`, in `_set_ghost_gait`.

- When `set_clip` refuses (the loop is not baked; `set_clip` only queues the bake), the ghost is
  `_dress_ghost_now`-ed. That is unbudgeted, once for each ghost that starts moving.
- Nothing prebakes a ghost's run loop. Only `_crowd_went_far` (`:16946`) does, for a dressed far
  body, and the ghost itself waits only for its stand loop.
- So in a crowd that is walking while it arrives (a town), every ghost whose (layout, weapon
  group) run is not baked yet is dressed in the frame its first move lands.
- A server tick moves many bodies at once.

**Evidence (MEASURED):**

- A box-only hook (`OPENSRO_QA_REVIEW_RUNAT=<s>` in `QaLineup.step`) calls
  `World3D._set_other_gait(id, true)` for every lineup body at s seconds after the spawn: one
  server tick in which the whole crowd starts moving. It counts the ghosts before and after.
- The lineup's own `run` phase starts only after every body is dressed, so it cannot reach a
  ghost.

| `crowd_run.sh 1000 base` | ghosts before / after | the gait calls | worst frame / over 100 ms | visible |
|---|---|---|---|---|
| at 3 s (overlap 0) | 667 / **0**: every one dressed in the call | **1,787.8 ms** | **1,975.0** / 17 | 7.95 s |
| at 6 s (overlap 1) | 834 / 821 | 71.9 ms | 150.0 / 2 | 4.37 s |
| no hook (`n1000`, overlap 0) | | | 137.4 / 2 | 4.70 s |

- By 6 s the dressed far bodies' own prebakes (`_crowd_went_far`) have baked most run loops.
- Within the first seconds of an arrival, every ghost that moves costs a full dressing in the
  frame its move lands. That window is exactly a walk-up into a town crowd that is walking.

**Fix:**

- `_crowd_gpu.prebake(...)` the run loop in `_ghost_other`, with the layout from the recipe.
- When the loop is still not baked, keep the ghost on its current loop and let it slide; retry
  when `clip_generation` moves, or promote it in the budgeted queue.
- A gait change should never dress synchronously.

### F4 (Medium): at 3,000 most ghosts take their light while mostly opaque

**Where:** `World3D.gd:16870-16900`, `_light_ghosts`: 8 ms a frame, about 0.23 ms a body
(r756.md).

**Evidence (MEASURED):** a box-only counter in `_light_ghosts` recorded the ghost's own fade alpha
when its colour was applied.

| crowd | ghosts lit | at alpha > 0.25 | at alpha > 0.5 | mean alpha | colour read |
|---|---|---|---|---|---|
| 1,000 (overlap 1) | 944 | 0 | 0 | 0.00-0.08, max 0.18 | 0.40-0.66 |
| 3,000 (overlap 0) | 2,941 | 2,347 | 2,090 | 0.80 over the 2,595 of the large batch | 0.40-0.66 |

- At 1,000 the late light is invisible: alpha is at most 0.18 when the colour lands.
- At 3,000 the pass needs about 85 frames of a 100 ms crowd frame, so 2,090 bodies already more
  than half drawn change brightness in one step.
- The step is from the materials' own colour to as low as 0.40, which is darkening in shade.
- The user's rule is the original: a body is lit as it appears.

**Fix:**

- Start a ghost's fade when its colour is read (fade start = light time). The body is placed at
  once but becomes visible already lit.
- Or cache `CharacterLight.color_at` per navigation cell or ShadowMap texel block, so a page reads
  each spot once.

### F5 (Medium): `_recipe_lit` keeps every (kind, light level) material copy and twin for good

**Where:** `crowd_gpu.gd:744-770`.

- The cache is keyed by `recipe.key|round(light x 1024)` (`ObjectLight.VARIANT_STEPS` is 1024).
- `ghost_light` adds an entry whenever a ghost's colour changes, including through
  `CharacterLight.on_value` as it walks.
- Each entry holds the `ObjectLight.with_object_color` copy (`p["lit"]`) and its twin strongly.
  Nothing evicts them.
- This brings back the leak round 747's review fixed as F7 ("the twins held every level copy
  ObjectLight keeps only weakly"), now per kind as well.
- `_recipe_geo`, `_fade_parts`, `CharacterAppearance._far_recipes`, `_far_volume` and
  `World3D._ghost_clip_wait` also grow per kind, but their entries are small.
- No ghost is left undressed: every arrival stays in `_other_builds`, and a leave or a zone change
  clears `_ghost_ids`, `_other_ghosts` and `_ghost_light_due`.

**Fix:** the F2 change, which holds no twins, plus a bound on `_recipe_lit`: keep the last few
levels per recipe, or drop entries whose material copy is otherwise unused.

### F6 (Low-Medium): a ghost-arrived player's plate and click body ignore Height, permanently

**Where:**

- `World3D.gd:16837`: `var top := _skeleton_top(recipe.skeleton)`.
- `_skeleton_bounds` multiplies by `skeleton.scale.y`. The template's scale is 1.0, while the
  built skeleton carries the Height factor (0.94-1.06).
- `_dress_other` then skips the plate and click body for a handed-over ghost (`:17048-17054`), so
  the unscaled height stays for the body's whole life.

**Evidence (MEASURED, 200 random kits, the parity bench extended):** 159 of 200 tops differ by
more than 0.01, by up to 6.4%. For example, scale byte 16 builds to 16.957 while the ghost's top is
18.040. Scale byte 4 builds to 19.528 against 18.423, so that plate sits about 1.1 units into the
head.

**Fix:** `_skeleton_top(recipe.skeleton) * recipe.height`, or re-place the plate and click body at
hand-over.

### F7 (Low): a re-ghost into a refused kind keeps the old look until the background dressing

**Where:** `World3D.gd:16770-16775`.

- An equipment or plus change (0x3038 / 0x3039, `_redress_other` -> `_reghost_later`) into a kind
  `can_ghost` refuses (a blended part) clears `reghost` and leaves the ghost in its old equipment.
- It stays like that until the pump reaches it: one body a frame at 3,000, so minutes.

**Fix:** on that refusal, promote the body in the queue, or `_dress_ghost_now`.

### F8 (Low): switching A5 off dresses every ghost in one frame

**Where:** `World3D.gd:6759-6762`. At 3,000 ghosts that is seconds of freeze, from a settings
toggle during an arrival.

**Fix:** remove the ghosts and let the pump dress them, at its 90 ms aim, since nothing is drawn
for them then.

### F9 (Info)

- `add_ghost` (`crowd_gpu.gd:539`) lacks `add()`'s mirrored refusal (`:357-359`). It cannot be
  reached today, since holders only yaw.
- In `_ghost_other`, the return on `frames <= 1` (`World3D.gd:16788`) leaves a body that is neither
  a ghost nor refused. The dressing then aims at 33 ms while that body is invisible. This is rare.

## What was checked and held

### 1. Ghost against dressed body

- **Parts (MEASURED).** `arrival_bench`'s parity check was extended:
  - kits get a job suit a quarter of the time and 1-3 avatar items half the time (the round's
    kits had neither);
  - each kit is also compared after `CharacterLight.set_on` at 0.35 and 0.8, against
    `_lit_parts` at the same level;
  - each part is checked for a fade twin;
  - seeds 11, 12 and 13, with 300, 300 and 200 kits.

  Results:

  - **767 kits compared, 0 mismatched** (mesh, twin material, Volume row, centre, layers, sort).
  - **1,534 lit comparisons, 0 mismatched.**
  - 0 parts without a fade twin.
  - Every kind the far path refuses (`blended` 33-48, `material` 3) is refused by both.
  - Glow at +0-13, Volume, hidden body pieces, the `_r`/`_f` fallbacks and the default wear all
    match.
  - Blended parts stay near: refused by both.
  - Mirrored bodies: see F9.
- **Phase and pose at the hand-over (READ).**
  - `_ghost_handover` hands the ghost's own entry, the same array, to the skeleton.
  - `_write_clip` and `MonsterCrowd.pose_at` both use `clock + entry[3]`.
  - The holder's transform times `_ghost_local_for(height)` (a yaw of PI, then Height) equals the
    skeleton's transform under the holder. `build()` sets no position on the body skeleton.
- **Light at the hand-over (READ).**
  - `_dress_other` removes `META_VALUE` and calls `_light_character`, which sets the built meshes
    to the level where the body stands.
  - It does this before `CrowdGpu.add` reads them, so the far body takes the same lit materials
    the ghost had, once the ghost was lit.
  - The hand-over itself does not pop. The late first light (F4) does.

### 2. Every event on a ghost

| event | path | result |
|---|---|---|
| eased move, 0xB021 leg, 0xB023 stop, relocation, turn | `_step_other_bodies`, `_step_other_legs`, `_on_entity_move_stop`, `_on_entity_moved`, `_step_remote_turns` all call `_crowd_gpu.moved(holder)`; a ghost is in `_by_node` | follows (READ) |
| gait | `_set_other_gait` -> `_set_ghost_gait`, a texel write | ok when baked; **F3** when not |
| 0x3038 / 0x3039, plus | `_redress_other` / `_spawn_or_update_other` -> `_reghost_later` | redrawn in the new kind; **F7** |
| sit / stand | `_apply_other_motion` dresses first | ok |
| hit, cast | `_play_other_hit`, `_play_other_cast_anim`, `_on_skill_cast` dress | ok, but synchronous: **F1** for casts |
| buffs, auras | `_fx_owner_body` | **F1** |
| berserk | `_berserk_apply` dresses on any body mode, value 0 included | ok, rare |
| death | the client plays no death clip for another player (none to break) | n/a |
| leaving mid-fade | `_fade_out_body` -> `CrowdGpu.fade_out` from full, as `AppearFade.start_out`; the holder is freed by the out-cohort after 1.5 s; `tree_exiting` -> `_crowd_ghost_exit` | ok |
| zone change | `_replace_others_for_arrival` clears the queues and the light list; holders' exit removes the instances | ok |
| party, PvP, targeting | holder-based (`_select_character`, markers, `_target_exists`); no plate restyling exists | ok |
| Detail shadow | `CharacterBlobs.on_cast` -> `_crowd_wake_node` dresses (10 nearest) | ok |
| sounds | the holder is the key until hand-over, then the skeleton; the 600 rule includes ghosts | ok (round 756 alone) |

### 3. Plate and click body from frame 1

They are made in the same `_ghost_other` call that draws the ghost (READ), so a ghost is pickable
and named from its first frame. The height is wrong for most scale bytes (F6). As the round notes,
a kind whose templates are not made yet has nothing at all until they come. Retail has everything
after its stall.

### 4. Memory

No ghost goes undressed, and leave and zone change clean up (READ). The growth is F5.

## The merge with round 757 (`55207efc`)

`ce5ca744` merges cleanly onto dev `6ec2af00`. Adding `55207efc` leaves **10 conflict hunks in 5
files**:

| File | Hunk | Resolution |
|---|---|---|
| `World3D.gd` | `_crowd_gpu_step` scan reset | take 757's packed arrays; keep 756's `append_array(_ghost_ids.keys())` |
| `World3D.gd` | `_crowd_sound_step` | take 757's wheel; put the ghost key in `_crowd_sound_advance` (S1) |
| `World3D.gd` | `_crowd_choose` | take 757's; keep `_crowd_come = come` |
| `World3D.gd` | `_crowd_switch_due` | take 756's `_crowd_went_far` call; add 757's `_sound_schedule(fb)` inside it |
| `World3D.gd` | `_dress_other` plate | 757's batched block inside 756's `if ghost == null` |
| `crowd_gpu.gd` | `_grow_aabb` | 756's deferred `_aabb_dirty`, with 757's QA print in `_push_groups` |
| `crowd_gpu.gd` | `_layout_for` scratch | 757's `_bare_skeleton`; keep 756's `key_in` |
| `other_crowd.gd` | `note_frame` | keep both: `target_usec` from 757's `hitch_usec` when a refused body waits |
| `client/tools/README.md` | | keep both sections |
| `client/tools/crowd_run.sh` | | union of the two |

The semantic interactions, which the textual merge does not show:

- **S1 (High, blocker): ghosts fall silent.**
  - 757's `_crowd_sound_advance` (`55207efc` `World3D.gd:6989-7000`) returns early on
    `not is_instance_valid(b.skel)` and sets `sound_due = INF`. A ghost has no skeleton, so its
    clip sounds stop at the first advance.
  - 756's `sound_due` writes never call `_sound_schedule`: in `_ghost_other` twice, in the scan's
    hearing branch, in `_set_ghost_gait` and in `_crowd_went_far`. So under 757's wheel they wait
    for the ring re-check.
  - Fix: key on `b.node if b.ghost else b.skel`, and call `_sound_schedule(b)` after each write.
- **S2 (Medium-High): ghost plates bypass `NamePlateBatch`.**
  - `_ghost_other` makes a plain swept Label3D. `_dress_other` skips the plate on hand-over, so with
    ghosts on almost every other player keeps a Label3D for life.
  - This undoes 757's plate saving at 7,000. It still draws one plate with no duplicate.
  - Fix: one helper (757's batched plate with its Label3D fallback), called by both `_ghost_other`
    and `_dress_other`. The batch needs only the holder, not a skeleton.
- **S3 (Medium-High): ghosts can fall outside the shared bounds.**
  - 757's `_crowd_choose` re-measures the bounds from scanned dressed far bodies only
    (`reset_aabb_to(_crowd_far_lo, _crowd_far_hi)`). 756's ghost branch of the scan `continue`s
    before folding its position in.
  - Before 757, `reset_aabb()` walked every Body, ghosts included.
  - A standing ghost outside the shrunk box is never re-grown, so every ghost group can be culled
    until dressed (up to 134 s at 3,000).
  - Fix: fold ghost origins into `_crowd_far_lo` / `_crowd_far_hi`.
- **S4 (Medium): stale Bodies stay in the sound wheel.**
  - 757's wheel holds Body references, and `CrowdGpu.remove()` leaves `heard` and `sound_due` set.
  - A re-ghost (`remove` then `add_ghost` on the same holder) keeps the old Body advancing on the
    same registered holder key, so its footsteps play twice.
  - Round 756 alone is safe, because its heard list is rebuilt from `_bodies`.
  - Fix: `remove()` clears `heard` and sets `sound_due = INF`, or drops the Body from the wheel.
- **These compose correctly:**
  - 757's `_other_moved` funnel and awake set: every path that moves a ghost holder goes through
    it to `CrowdGpu.moved`, and a ghost is in `_by_node`.
  - HeightBatch walkers' heights: position-only.
  - `MinimapSigns`: keyed by holder. A sign shows up to a 60-frame re-read after the ghost, which
    is 757's own behaviour.
  - Skeleton physics off: ghosts use detached templates.
  - `_crowd_eligible`'s child count: a handed-over holder has plate, click body and skeleton.

**What the merged result must do:**

1. Resolve the hunks as in the table.
2. Fix S1-S4.
3. Carry the F1-F3 fixes.
4. Re-run `check` and `tests` (`crowd_ghost_test`, `crowd_main_thread_test`,
   `crowd_arrival_test`).
5. Re-run a 1,000 arrival. Count batched plates, not Label3Ds, and confirm far footsteps play once.

## Gates (on `ce5ca744`)

- `RENDER_DIR=/opt/opensro-client-r756rev GODOT_LOCK=/var/tmp/r756rev/lock remote_godot.sh check`:
  **checked 676 scripts and 9 scenes, ALL LOAD.**
- `remote_godot.sh tests`: **ran 260 suite(s), 0 failing.**
- `PERF_LANE=r756rev perf_gate.sh --base 9a5732ed --sites jangan --frames 40000` (1280 x 720, 3 runs a
  side, the overlapped ones repeated by the gate): **exit 0, every number SAME.** These views have no
  other players.

  ```
  jangan  frame ms   base 1.56  head 1.56  (+0.0)  SAME
  jangan  entry ms   base 9237  head 9236  (-1.0)  SAME
  jangan  freeze ms  base 2875  head 2850  (-25.0)  SAME
  jangan  hitches    base 5  head 5  (+0.0)  SAME
  ```
- **`crowd_run.sh` at 1,000** (`base,move,dest,base`, overlap 0 both):

  | | head | head, `OPENSRO_QA_GHOSTS=0` | r756.md |
  |---|---|---|---|
  | every body visible | **4.70 s, 90 frames**, worst 137.4, 2 over 100 | 12.93 s, 169 frames, worst 113.7, 2 over 100 | 4.20 s / 12.65 s |
  | every body dressed | 14.12 s | 12.93 s | 13.74 s / 12.89 s |
  | ghosts drawn | 958 (42 refused: blended) | - | |
  | standing p50 / p95 | 16.52 / 20.63; 16.95 / 22.02 | | 16.15 / 22.18 |
  | `dest` p50 / p95 | 51.20 / 58.89 | | 51.37 / 58.44 |

  The headline is confirmed: 4.7 s against 12.9 s visible. The worst frame during the arrival is
  higher (137 against 114 ms), within the spread of a cold arrival.
- **3,000** (the light probe boot, overlap 0): visible 4.84 s in 54 frames, worst 430.1 ms, 17 over
  100. Every body dressed after **133.8 s** (r756.md: 4.95 s and 136.4 s).


**F1 rerun** (the same hook, after the gate). The head boot still had `overlap: 1`, because round
757's reviewer was rendering; the ghosts-off boot had `overlap: 0`.

| | 260 buff starts after page 4 | page 4 worst frame | worst / over 100 ms, the whole arrival | bodies the pump dressed |
|---|---|---|---|---|
| ghosts | **703.4 ms** in the handlers | **842.7 ms** | 842.7 / 6 | 492 of 1,000 |
| ghosts off | 24.0 ms | 132.3 ms | 132.3 / 2 | 1,000 |

The handlers' time is wall clock around the calls themselves (`REVIEW BUFFS`), so CPU sharing
cannot account for a 29x difference. The first run gave 726.2 ms against 23.8 ms.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013CKe7wwBdSifh9pCEL11a8
