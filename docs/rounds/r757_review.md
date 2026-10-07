# Round 757 review: the main thread in a 7,000-player crowd

This is an independent, adversarial review of `9e3ad7fe` and `55207efc` on
`worktree-agent-af1c7ac3c2f42da73`, based on dev `155822c1`. The review ran in a detached worktree
of `55207efc`. Boxes: `/opt/opensro-client-r757rev` (head), `/opt/opensro-client-r757revbase`
(clean `155822c1`, for the pictures) and a copy of the author's `r757base` (`155822c1` plus the
round's QA files, for the crowd split).

- **Labels:** READ, MEASURED, COMPUTED, INFERRED, REASONED (from the code, not run).
- **No code was changed.** Two probes were written as a scratch suite (a subclass of `World3D.gd`
  built the way `crowd_main_thread_test.gd` builds it), run on the box, and deleted.

## Verdict

**Do not ship as it stands. Ship after F1 and F2, which are both small and local.**

The speed-up is real. It reproduces on the box:

- at 1,000 standing, 17.8 ms p50 becomes 9.3;
- at 7,000 standing, 99-100 ms becomes 16.3;
- the perf gate at Jangan is SAME on all four numbers.

The skeleton change is safe. The plates match the `Label3D`s pixel for pixel at UI scale 1.0 and
2.0.

Two findings matter to players:

- **F1, the sound timing wheel.** It keeps advancing a far body's clip sounds after the body has
  been brought near. The mechanism is MEASURED. The consequence is INFERRED from `AnimSounds`' state
  rule: a far body that is hit or killed while walking or running replays its one-shot's sound keys
  at its old loop's footstep rate. For a death, that lasts as long as the corpse lies within
  hearing. This happens in any crowd of more than 16 (`CrowdGpu.near_count`).
- **F2, the minimap signs.** The new minimap signs are not where the old ones were (MEASURED). At
  UI scale 1.0 every sign is drawn blurred. At 2.0, signs move by one UI pixel. This affects every
  player, not only crowds.

F3 (the heights' pool wait) is INFERRED and should be measured or guarded before a low-core
release. The rest are Low or Info.

## Findings, most severe first

### F1 (High): a far body that is brought near stays on the sound wheel and keeps firing

**Where:**

- `client/scripts/World3D.gd:6928-6999` (`_sound_schedule`, `_crowd_sound_step`,
  `_crowd_sound_advance`);
- `client/scripts/world/crowd_gpu.gd:367-389` (`remove`);
- `World3D.gd:7134-7173` (`_crowd_wake`, `_crowd_on_exit`).

**The mechanism (READ, MEASURED):**

- The base walked `CrowdGpu.heard_bodies()` every frame, which holds only the current far bodies.
  The wheel instead holds `CrowdGpu.Body` objects.
- `CrowdGpu.remove()` (called by `_crowd_wake` and `_crowd_on_exit`) drops the body from
  `_bodies`. It never clears `heard` or `sound_due`, and the wheel's bucket keeps its reference.
- `_crowd_sound_step` advances any bucketed body whose `heard` is true and whose `sound_due` has
  passed. `_crowd_sound_advance` then schedules it again. So the stale `Body` fires the far path's
  `_anim_sounds.advance(b.skel, b.entry[1], …, loops=true)` at every key of its loop, for as long
  as its skeleton lives and the loop has keys.
- No path sets `heard` false on it again. The scan's `body_of(skel)` returns the new `Body`, or
  null, never this one.
- Each later near-to-far switch adds a fresh `Body` (`crowd_gpu.gd:334`), so the stale ones
  accumulate.

**The probe (MEASURED, box, the scratch suite):**

- Setup: a far, heard body, filed on the wheel, then `_crowd_wake(skel)`.
- Result: `crowd.has(skel)=false b.heard=true b.sound_due=10.5 heard_bodies=0`.
- Then 60 frames of `_crowd_sound_step`: **1 far-path advance for the woken (near) body**. The
  scratch suite stubs `_crowd_sound_advance` to stop after one. The real one reschedules.

**What it does in play (INFERRED from `anim_sounds.gd:250-260`):**

- `_play_once` wakes the body (`World3D.gd:6467`). For a hit, a death, a sit-down or a pick-up,
  the near tick then advances the one-shot: `(skel, oneshot, start, elapsed, loops=false)`.
- At its loop's next key, the stale `Body` advances `(skel, run_loop, …, loops=true)`.
  `AnimSounds` keeps one state per skeleton, so this overwrites it.
- On the next frame the near tick's anim differs from the stored one. For a one-shot that sets
  `prev = -1`, so **every one-shot key up to `elapsed` fires again**.
- A death is a hold with no resume (`_play_once`: `null if hold`). The loop entry the stale `Body`
  carries is never swapped again. So the death sounds would repeat at the run loop's key rate for
  as long as the corpse is within 600 and the body lives.
- A hit's moan repeats while the one-shot plays.
- Out of the 600 range, the near tick's `rest()` is undone by the stale advance, which writes the
  state again.
- For a loop alone (no one-shot), the near and stale advances share an anim and start, so nothing
  doubles. That case only costs CPU: one extra advance stream for each wake of a moving body, per
  footstep key, until the body stands on a loop with no keys.

**Fix:** in `CrowdGpu.remove()`, set `b.heard = false` and `b.sound_due = INF`, so the wheel drops
it when its bucket comes up. Alternatively, in the wheel, skip a body for which
`_crowd_gpu.body_of(b.skel) != b`.

**Test:** in `crowd_main_thread_test`'s wheel test, wake one scheduled body and check that it
never advances again.

### F2 (Medium, visual): every minimap sign is blurred at UI scale 1.0 and offset at 2.0

**Where:** `client/scripts/ui/hud/minimap_signs.gd:31-44` (the shader) and `:242-246`.

**The evidence (MEASURED):**

- Setup: base `155822c1` against head, `qa_shot.sh` at the Jangan spawn with 60 lineup players,
  `OPENSRO_QA_LOCAL_NPCS=1` and `OPENSRO_QA_MOBS=200`. Frame 419 of 420 (the bodies were dressed
  by frame 61) was taken at UI scale 1.0 and 2.0. The log's sign list is the same on both sides:
  66 drawn of 102 entities.
- Outside the minimap (x < 1100), the frames differ in 4 pixels above an 8 % fuzz at scale 1.0,
  and in 0 at scale 2.0.
- Every connected region of difference above a 12 % fuzz lies on the signs:
  - at scale 1.0, x 1202-1247, y 69-137, 493 pixels above 8/255;
  - at scale 2.0, x 1123-1175, y 138-270.
- Zoomed:
  - at 1.0, the base's signs are crisp and the head's are bilinear-smeared;
  - at 2.0, the head's signs sit about one UI pixel from the base's.

**The cause (READ, INFERRED):**

- The base's `TextureRect`s are Controls, which Godot snaps to whole pixels by default
  (`gui/common/snap_controls_to_pixels`, which `project.godot` does not override).
- The new shader adds `centre + off` (fractional) to `VERTEX` after any snapping. Each 8 x 8 quad
  therefore lands between pixels and is filtered (the default canvas filter, linear).
- The round's own note said "INFERRED same; no base minimap frame was taken".

**Fix:** round the sign's top-left in the shader:
`VERTEX = round(centre + off - sign_size * 0.5) + (VERTEX + sign_size * 0.5)`, passing
`sign_size` as a uniform, or `floor(x + 0.5)`. Then repeat this A/B.

### F3 (Medium, INFERRED): the walkers' heights wait behind the pool's queue on the main thread

**Where:** `client/scripts/world/height_batch.gd:70-71`, called from `World3D.gd:17559`.

**Why (READ, Godot 4.2.2 `core/object/worker_thread_pool.cpp`):**

- `_post_task` (l. 224-230) appends to one FIFO `task_queue`. High priority only exempts a task
  from the low-priority cap. It does not put the task first.
- `wait_for_group_task_completion` (l. 498-520) blocks on the group's semaphore. The calling thread
  does no work itself.
- The world's cell prepares are high-priority tasks of a terrain and objects parse each
  (`World3D.gd:5363`), as are the monster templates and the audio prefetch.

**The consequence:**

- On a machine whose pool is no bigger than the region streaming's burst, any frame with 8 or more
  points to resolve waits until a worker reaches the group. That is a frame with walkers near, or
  with landings pending.
- So the main thread waits through queued cell prepares exactly when the player crosses a region
  boundary in a crowd. This is a freeze that the inline code never had.
- The box (28 threads) and the user (32) are unlikely to see it, and the round's 3 x 300 s stress
  had no streaming. **Not measured.**

**Also:** `p_tasks = -1` posts one task per pool thread (28 on the box, 32 on the user's machine)
for as few as 8 points. The surplus tasks are no-ops that queue behind the same work. MEASURED
side effect: head runs end with `Pages in use exist at exit in PagedAllocator:
N16WorkerThreadPool4TaskE`, which no base run printed (the `qa_shot` and `crowd_run` logs). The
message comes at exit only.

**Fix:**

- pass `mini(n, 4)` (or similar) as the task count;
- do not block. Either apply the heights a frame later (`is_group_task_completed`), or run inline
  when the pool is busy.

**Measure:** a walking crowd while crossing a region boundary, with
`threading/worker_pool/max_threads=4` in an `override.cfg`.

### F4 (Low): V (hide other players) leaves their batched names up to 60 frames

**Where:** `World3D.gd:22656-22664` (`_show_bodies`), `:7929-7950` (`_plate_batch_step`).

- `_apply_key_holds` hides the bodies directly and never reports them through `_other_moved`. A
  batched plate therefore learns of the hide only from the spread re-read, over
  `MINIMAP_RESCAN_FRAMES`.
- The base's `Label3D` was the body's child, so it went with the body in the same frame.
- **MEASURED** (the scratch suite, 600 plates): every plate was hidden 60 frames after `V`, and was
  back 60 frames after release. That is 1 s at 60 fps, and about 3.7 s at the 16 fps a 7,000 crowd
  ran at before this round.
- The minimap is unaffected: its signs count with V held (`put_other(…, body.visible or
  _objects_hidden)`), as before.

**Fix:** call `_other_moved(body)` for a body whose `visible` `_show_bodies` changes (other
players' map only).

### F5 (Low, INFERRED): the far crowd's bounds can exclude a body that went far mid-cycle

**Where:** `World3D.gd:7047-7052` (`reset_aabb_to` from `_crowd_far_lo/hi`).

- The cycle's bounds are now the far bodies as they were scanned.
- `_crowd_switch_due` sends bodies far on every frame of the next cycle. A body scanned near, then
  switched far, is not in that cycle's `lo/hi`. At the cycle's end the groups' custom AABB is reset
  without it, and it may be smaller (the reset replaces any box at least 4x the new volume).
- `CrowdGpu.add` grew the box for it, but the reset undoes that. A standing body never grows it
  again.
- If the reset box is out of view while that body is in view, its instances are culled for up to
  a cycle. The base's `reset_aabb()` walked every current far body.

**Fix:** widen `_crowd_far_lo/hi` with the body's place in `_crowd_switch_due` after a successful
`add`.

### F6 (Info): `NamePlateBatch` details that differ from `Label3D`

All of these were REASONED against `label_3d.cpp`:

- **A glyph with no font** (`font_rid` invalid: a character no font has). `Label3D` draws its
  hex-code box (`label_3d.cpp:344-347`). The batch draws nothing (`name_plate_batch.gd:349`).
- **A font's `changed` signal.** `Label3D` reshapes on it. The batch reshapes only on
  `NamePlateBatch.generation` (`ClientSettings._refresh_text`) or on `add`. That covers the UI
  scale, the one known cache clear.
- **The anchor texture.** `_take_slot` drops `_anchor_tex` when the rows grow
  (`name_plate_batch.gd:266`). Until an anchor next changes, the materials keep the freed texture's
  RID. The only way to reach this is a growth while the new plate's owner is hidden (V held). Every
  plate is then already hidden, so nothing shows. Setting `_anchor_dirty = true` there closes it.
- **Overlap order** is disclosed in the round (slot order). Here it was 4 pixels in 1280 x 720 with
  60 plates.

### F7 (Info): the scan caps slow each crowd system's reaction past about 2,000 bodies

The caps are OURS and disclosed: CrowdGpu, 200 a frame; EquipFx, 200; the circles, 300. At 7,000:

- a new weapon's glow can take about 0.8 s to be chosen;
- the near/far choice is about 0.6 s old;
- the circles' ten are about 0.4 s old.

Up to about 2,000 bodies each is unchanged. Nothing here breaks play.

## What was checked, and how

### 1. `Skeleton3DBuilder.no_physics_step`

READ (`skeleton_3d.cpp` 4.2.2, l. 303-320 and 658-672):

- The internal physics step only resets `PhysicalBone3D`s that are not simulating, and only when
  `animate_physical_bones` is set.
- Posing, the skin update (`NOTIFICATION_UPDATE_SKELETON`, deferred), `bone_pose_changed` (which
  `BoneAttachment3D` listens to) and `pose_updated` do not run in it.
- There is no `PhysicalBone3D`, ragdoll or `physical_bones_start_simulation` anywhere in
  `client/scripts`.
- The only other `Skeleton3D.new()` is `_bare_skeleton`. A fresh skeleton does not physics-process
  on 4.2.2.

So this covers the local player, other players, NPCs, monsters, items and map objects. Death
one-shots are clip-driven (`_play_once`), so they are unaffected by this change, though not by F1.

### 2. `NamePlateBatch` against `Label3D`

- **Who uses it.** Only other players' plates (`_dress_other`). The local player, NPCs, monsters
  and ground items keep their `Label3D`s.
- **What other players' plates carry.** In base and head alike: the name in `NAME_PLATE_COLOUR`
  with the outline. There are no guild, title, party, PK or GM colours, no stall name and no
  target highlight on them. No code changes such a plate after it is made (`modulate` and `text`
  are written only in `_name_plate`). So there is nothing there for the batch to miss.
- **The rule.** Shown while the owner is strictly within `_name_plate_range` of the player (300,
  READ round 673), in the shader every frame. The debug slider reaches it. The "+0xf0" (hovered or
  selected) exception is not modelled in base either (`NamePlates`' header).
- **Hidden-UI mode (F10)** hides `ui_control` only. Plates were never part of it, so there is no
  change. **Z** is the ground items' names only (`KeyMap` slot 10).
- **The glyphs.**
  - REASONED: `_shape` and `_glyph` follow `Label3D::_shape` and `_generate_glyph_surfaces`
    call for call: the same TextServer queries, the centred offsets, and outline before text.
  - The material code was compared with `get_material_for_2d`'s flags.
  - The font is `ThemeDB.fallback_font`. The project sets no theme, so it is the font `Label3D`
    resolves.
- **DPI and font fidelity (MEASURED).** The same frame (see F2's setup) was taken at UI scale 1.0
  and 2.0. Outside the minimap, 4 and 0 pixels differ above an 8 % fuzz. At 1 % fuzz the counts
  are 202 and 88 out of 792,000. The plates are pixel-identical to the `Label3D`s at both scales.
- **A plate leaves with its body.** Checked through `tree_exiting`. No path takes an other
  player's holder out of the tree without freeing it (`remove_child` and `reparent` READ).
  `_replace_others_for_arrival` frees and clears.

### 3. `MinimapSigns`

- **The rule (READ).** The shader's `(entity - player) * tile_px / 1920`, dropped at `SIGN_RADIUS`,
  is the same as `sign_offset` and the old `>= SIGN_RADIUS` test.
- **The bookkeeping.** NPCs and monsters are still refilled every frame. Other players are keyed:
  dropped at once on `_on_entity_left`, cleared on arrival, and re-read over 60 frames.
- **The party's dots and edge arrows** (`update_party`, `_fill_party_marks`) are untouched.
- **The pictures:** see F2. The kinds, counts and positions agree. The pixels do not.

### 4. The event-driven loops

- **Every path that writes another player's position or yaw now calls `_other_moved` (READ).**
  - `_on_entity_moved`, including relocated;
  - the 0xB021 echo (`_start_other_leg`);
  - 0xB023 (`_on_entity_move_stop`);
  - `_on_skill_moved`;
  - `_on_skill_cast`'s turn;
  - the eased walk's snap and step;
  - round 749's legs, the pending landings included;
  - `_step_remote_turns`;
  - `_spawn_or_update_other`'s heading.

  Monsters reach `_other_moved` through `_step_remote_turns`, and every consumer ignores them.
- **Every write of `_other_body_targets` wakes its body.** The exception is the QA probe's, which
  the spread re-check covers (tested).
- **A body hidden by V is not reported:** F4.
- **The sounds:** F1. The bucket logic itself (late, re-filed and rewound) is right.
- **EquipFx.**
  - `Plane.is_point_over` is `is_position_in_frustum`'s own test.
  - The visibility test moved after the distance test (the same set).
  - REASONED: pruning to the 64th-nearest host distance keeps every weapon `_finish_cycle`'s
    greedy can choose. A weapon's hosts share one distance, and the 64th-nearest weapon distance is
    at least the 64th-nearest host distance.
  - A weapon change goes through `add_host` and `_drop` as before. Only the cycle's length grows
    past 2,000 hosts (F7).
- **The circles.** The pass is spread and `_best` is not aliased into `_chosen`. Freed nodes are
  skipped in `update`. At under 1,800 casters the cadence is unchanged.
- **CrowdGpu's choice.** It uses the flag as scanned (`was_far`): a one-cycle lag at worst. The
  bounds: F5.

### 5. `HeightBatch`

- **What a task reads (READ).**
  - `NavGraph.landing_height_at`: `objects_at`, `objects`, `_object_tiles`, `region.cells` and the
    placed objects' arrays, all through `NvmCollision.terrain_height`, `sample_height` and
    `solid_plane_height`.
  - None of these write, and no lazy cache is built.
  - The main thread blocks in the wait, so nothing commits or frees a region meanwhile.
  - Each task writes only its own index of `out`, sized before the post.
- **The result.** It is the same as `_moving_monster_hit_height`: the region search is the same
  bounds test on the same transform, and terrain is still the fallback. The only exception is a NaN
  landing height, which only an all-NaN `sample_height` could give, and which the base would have
  sent to the terrain ray.
- **The lints.** `const_array_lint_test` and `static_lambda_lint_test` pass. The scalar `const EPS`
  inside `_triangle_height` is not an Array.
- **The risk:** F3.

### 6. The merges

- **Dev (`6ec2af00`, round 758 included).** A scratch `git merge --no-commit 6ec2af00` into
  `55207efc` was **clean**: 6 files, no conflicts. Round 758 touched `character_appearance.gd`, but
  not `_bare_skeleton`.
- **Round 756 (`worktree-agent-ad0994c00d104f6c0`) is not committed.** Its branch is still at
  `9a5732ed`.
- **Round 756's working tree.** A snapshot of it was taken with `git diff` and committed in a
  scratch worktree. Merged with `55207efc`, it conflicts in 5 files, 11 hunks:
  - `World3D.gd`, 5: the scan reset, the sound step, the choice, the switch's hearing, and
    `_dress_other`'s plate;
  - `crowd_gpu.gd`, 2: `_grow_aabb` and the layout scratch;
  - `other_crowd.gd`, 1: `note_frame`;
  - `tools/README.md`, 1;
  - `crowd_run.sh`, 2.
- **Semantic hazards for whoever merges:**
  - Round 756's ghosts key their sounds by the holder (`b.ghost ? b.node : b.skel`). Round 757's
    `_crowd_sound_advance` uses `b.skel` only, and would mark a ghost INF.
  - The ghost dressing adds a plain swept `Label3D` plate (`node.add_child(_name_plate(...))`).
    That plate would not be batched.
  - Round 756 queues the AABB (`_aabb_dirty`) where round 757 writes it at once.
  - Round 756 adds the ghost ids to `_crowd_scan`. Round 757's packed scan stores a skeleton for
    each body, which a ghost has none of.

## Gates (MEASURED, render box)

- `remote_godot.sh check` (`RENDER_DIR=/opt/opensro-client-r757rev`): **checked 680 scripts and 9
  scenes, ALL LOAD.**
- `remote_godot.sh tests`: **ran 261 suite(s), 0 failing.**
- `PERF_LANE=r757rev perf_gate.sh --base 155822c1 --sites jangan --frames 40000`, exit 0. Overlapped
  runs were repeated by the gate.

  ```
  jangan  frame ms   base 1.56  head 1.56  (+0.0)  SAME
  jangan  entry ms   base 9185  head 9187  (+2.0)  SAME
  jangan  freeze ms  base 2874  head 2887  (+13.0)  SAME
  jangan  hitches    base 4  head 5  (+1.0)  SAME
  ```

- **`crowd_run.sh`**, 1920 x 1080 Forward+, RX 7600, standing (`base,base`). The 1,000 run used the
  round 736 lineup. The 7,000 run used rows of 100 at 4 x 5. Both used the round's QA build
  budget and hitch overrides. Figures are ms: frame / p50 / p95 for the settled second step; cores
  are `QA THREADS` main / others; GPU is the GFX share.

  | n | Base | Head | Base cores, GPU | Head cores, GPU | `!is_geometry_instance` |
  |---|---|---|---|---|---|
  | 1,000 | 18.02 / 17.82 / 21.38 | **9.44 / 9.33 / 12.17** | 0.98 / 0.12, 34 % | 0.98 / 0.17, 59 % | base 40, head 0 |
  | 7,000 | 102.89 / 100.14 / 122.63 (first step 103.12 / 98.97 / 124.11) | **16.68 / 16.32 / 19.62; 16.68 / 16.38 / 20.35** (a quiet boot; an overlapped one: 18.43 / 18.11 / 21.66) | 0.99 / 0.06, 17 % | 0.99 / 0.10-0.12, 76-80 % | base 40, head 0 |

  The headline numbers are confirmed: 1,000 from about 17.8 to 9.3, and 7,000 from about 99 to
  16.3.

- **Pictures:** `qa_shot.sh` with `QA_SHOT_REAP=0` under the shared lock. Head and base were each
  taken at UI scale 1.0 and 2.0 (F2 and section 2). The frames were deleted after measuring.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013CKe7wwBdSifh9pCEL11a8
