# Round 759 review: far batches per material, effect masters on the pool

The independent review of round 759 (`docs/rounds/r759.md`). Reviewed at HEAD `d2e61a2a`
(branch `worktree-agent-a6832f4cdc8413ea9`), base dev `2e646fb4`. The fix commits are
`f06f892a`, `b67ffb39`, `b7f64233` and `1cc2f223`; `abbc993b` and `0e9a565e` are QA tooling.
No code was changed by this review.

Labels as in the round: **READ** (our code, Godot 4.2.2-stable source), **MEASURED** (the render
box, RX 7600, Godot 4.2.2), **COMPUTED**, **INFERRED**, **OPEN**.

## Verdict

**Ship on the code review, with two conditions.**
- **F1** is either fixed or accepted as the shipped behaviour and written down.
- **The box's runtime gates** (perf gate, swarm before/after, pixel A/B, stress) are re-run before
  release. This review could not run them (Gates).

No crash path, stale-instance path or wrong-pixel path was found in the code:
- The threaded masters touch only data.
- Every instance write is pushed.
- The light texel and the glow rows reproduce `CharacterLight` and `EQUIP_GLOW` exactly by
  their code.

The one behavioural change found and measured is F1: in the swarm, the effect masters' particles
under the global cap are distributed differently from before.

## Findings, most severe first

### F1 (Medium): the pool's particle cap is a share of room / n every batch, not only when the cap binds

`client/scripts/efp/efp_sim_batch.gd:114` gives each sim in a threaded batch
`max(limit - live_total, 0) / n` particles of net growth, and `EfpSim.can_spawn`
(`client/scripts/efp/efp_sim.gd:877-878`) then refuses on `_live_delta < _allow` alone. That
limit applies on every batch, so the pool matches the main thread only while every sim's growth in
one advance fits room / n. In the swarm the round targets (33 masters), the cap binds all the
time, and the pool draws a different set of particles from the one the main thread drew.

The probe (`r759rev_cap_probe.gd`, not committed) was run headless on the box. It stepped the real
EquipFx files from Media.pk2's particle tables (74 distinct files; the first n here), keeping the
master's settings (kept, seeds 1000 + i). Each case ran 600 frames, once as before (each sim's
`advance` in turn) and once through `EfpSimBatch.run`, with the same seeds. MEASURED:

| sims, fps | old path: frames at the cap / mean particles / dropped | pool: frames at the cap / mean / dropped | frames where any sim's count differs |
|---|---|---|---|
| 8, 37 fps (room for all) | 0 / 452.4 / 0 | 0 / 452.4 / 0 | **0 of 600** |
| 33, 15 fps (the user's scene) | 276 / 1386.0 / 10,735 | 0 / 1357.8 / 10,405 | **600 of 600** (16,113 sim-frames) |
| 60, 30 fps | 398 / 1390.4 / 20,284 | 0 / 1341.1 / 18,676 | **599 of 600** (28,889 sim-frames) |

- **With room, the threaded step equals the main thread's.** That is the round's claim, and it
  holds.
- **When the cap binds, the distribution moves a lot.** Final counts, old path / pool:
  `system_raretype_a_step3` 87 / 32, `eternity_11_egya_glowset1_purple_shield` 35 / 6,
  `system_rarestaff_c` 34 / 10, `eternity_11_egya_sealhusk_purple_shield` 30 / 6,
  `eternity_11_nova_bow_03` 3 / 16, `system_rareshield_a` 27 / 40.
- **The share is not even.** Each sim may add only room / n in one advance, while its own deaths
  free room only for itself. So an effect that grows in bursts (a seal's step-3 sparks) loses
  particles to the effects that hold steady.
- **The remainder is lost.** The integer division never gives out `room % n`, so the pool never
  reaches the cap: 28-49 particles fewer than the old path (2.0-3.5 %).

Neither distribution is retail's, which has no cap (OURS since round 620). The old one was node
order, first come first served. So this is not a regression against retail, but it is a visible
change in exactly the scene the round fixes. The round's text ("when the cap binds, the room is
shared evenly") understates it, and the brief asked for the original's behaviour.

**Fix**, either of:
- (a) Keep the share, but hand out the remainder (`room / n + (1 if i < room % n else 0)`). Then,
  after the join, run a main-thread top-up pass in node order that lets the sims refused only by
  their share spawn into what is left. This restores the old distribution whenever only a few
  sims are short.
- (b) Make the shared budget a counter under the Job's Mutex, so a sim claims room as it spawns.
  This is first come, first served again, but the order between threads is not deterministic.

Then say in r759.md which distribution ships. Also extend `efp_sim_test._batch` with a binding
case that asserts the total reaches the cap.

### F2 (Low, latent): INSTANCE_CUSTOM.y is not exact under the Compatibility renderer

Godot 4.2.2's GLES3 stores a MultiMesh's colour and custom data as half floats (READ:
`drivers/gles3/storage/mesh_storage.cpp:1901-1907` `make_half_float`, and
`drivers/gles3/shaders/scene.glsl:388` `unpackHalf2x16(instance_color_custom_data.z/w)`). A half
float holds every integer only up to 2048. `CrowdGpu.pack_y` (`client/scripts/world/crowd_gpu.gd:1237`)
packs ((glow + 1) x 512 + (vol + 1)) x 2 + lit, so any glow row >= 1 puts y above 2048. Above
that the low bits round away: the lit bit from 2048, the Volume row's low bits from 4096.

Today no glow part is affected (COMPUTED):
- A glow part is a weapon or shield hung on a bone, so its Volume row is -1 (`crowd_gpu.gd:1501`).
- A glow part is never lit, because the glow shader has neither object meta, so `is_object_material`
  is false (READ `equip_glow.gd:95-99`, `object_light.gd` `is_object_material`).

So y = 1024 x (glow + 1), which is exact up to glow row 2046. But the first glow part that is
skinned to the body, or lit, would draw with the wrong Volume row under Compatibility, and only
there. (Also, before this round: the slot in INSTANCE_CUSTOM.x is wrong under Compatibility above
2,048 far bodies.)

**Fix:** assert the invariant (glow implies vol -1 and not lit) in `_add_part` or in a test, or move the
glow row to a channel of its own. Note in the round that CrowdGpu's custom data is exact only on
Forward+.

### F3 (Info): `efp_sim_batch.gd` is not in the const-array lint's WORKER_FILES

`client/scripts/assets/const_array_lint_test.gd:37-63` lists `efp_sim.gd`, `efp_reader.gd` and
`efp_effect.gd`, but not the new `efp_sim_batch.gd`, whose `Job.help` runs on the pool. It has no
`const` Array today (READ), so nothing is wrong now; a future constant there would not be caught.
**Fix:** add it to the list.

### F4 (Info): merging

- **dev:** `git log dev -1` is `2e646fb4`, the round's base, so the merge to dev is a fast-forward
  with no conflicts.
- **Round 760 has already merged this round:** `0c43de15` on `worktree-agent-a8ac26415e51de746`
  merges `d2e61a2a`. It resolved the three textual conflicts (`character_blobs.gd`, where both
  rounds made the same validity-first fix; `qa_crowd_probe.gd`'s doc blocks; `crowd_run.sh`'s
  banner grep). It also marked EfpSimBatch's two group waits `# pool-wait: resource-free`, which
  round 760's `pool_wait_lint_test` requires. Those marks are correct: a helper runs
  `EfpSim.advance` only, which makes no RenderingServer call (READ). Applied to the merged tree,
  the lint's rule leaves no bare wait.
- **Re-review if F1 is fixed:** a fix to F1 lands on both branches, so `efp_sim_batch.gd`
  conflicts again unless it is made on top of `0c43de15`, or merged into round 760 after.

## What was checked and holds

### 1. The threaded effect masters

- **What the worker touches** (READ):
  - `Job.help` runs `EfpEffect.step_sim`, which writes only the effect's own `_pending_steps` and
    `_pending_sim_usec`.
  - `EfpSim.advance` touches only its own particles, emitters, RNG and `_scratch`.
  - It reads the effect file's compiled Template, which is not written after `compile`. That
    Template is shared by no two masters, since `kind_key` is the file, so one master a file.
  - It reads EfpSim's static `interval_mul` and `threshold`, and EfpReader's pure helpers
    (`i32`, `ftol`, `f32`).
  - No Node, RenderingServer, Resource or `prof` access.
  - The MultiMesh writes (`_update_draws`, `_update_links`) and the placement (`_place`) stay in
    `step_pre` and `step_post` on the main thread.
- **The const-array race:**
  - The step reads no `const` Array: the `match` patterns are ints, and `KIND` and `OP_BASE` are
    used only at compile time.
  - `tp.schedule` and `scale_graph` are runtime containers, not read-only ones.
  - `const_array_lint_test` passes in the suite run.
- **The particle cap and determinism.**
  - The cap holds: the pool never exceeded 1,400.
  - The counts are handed back: `live_total` equals the sum after `end_deferred`.
  - With room, the pool equals the main thread (F1's table, 0 of 600 frames differ). Under the cap,
    see F1.
- **Behaviour against the old `_process`** (READ):
  - Masters are stepped while `Kind.active > 0`, as `_finish_cycle`'s `set_process` did, and
    `active` lasts the whole cycle.
  - The driver's `_process` has no early return before `_step_masters`.
  - A master that finished is still stepped each frame (before, the cycle's end turned it back
    on), and `effect_finished` is emitted each frame. No listener on masters, so it is harmless.
  - Masters now step after the holders are placed in the same frame (before, at priority 0,
    before the driver), so the frame drawn is the same.
- **Shutdown and zone change:**
  - `EfpSimBatch.run` is synchronous, so a step never outlives a frame.
  - A helper that starts late finds nothing to claim and touches only the Job.
  - `_pending` keeps the Job alive until the group is reaped.
  - `World3D._exit_tree` calls `reap_all`.
  - A zone change frees bodies between frames, never during a batch.
  - A GDScript error inside `step_sim` returns to `help`, which still counts the effect done, so
    the main thread's spin cannot hang on it.
- **Stress:** NOT RUN by this review (see Gates: the box's shared lock was held by round 760's queue for the whole window). The round's own live boots report 0 SCRIPT ERROR after the fix.

### 2. Light per body (`f06f892a`)

- **The rule matches CharacterLight's** (READ):
  - `lit_by_body` (`crowd_gpu.gd`) is `CharacterLight.set_on`'s rule: an object material as
    `material_override`, or as surface override 0 of a one-surface mesh.
  - The berserk meshes CharacterLight skips stay near: berserk keeps a body near.
  - `object_color_of` reads the level copy's own `object_color` (x; the copies are `Vector3.ONE * level`).
  - `object_color_at` is `with_object_color`'s branch exactly: the base's own value within half a
    step of 0.6, else round(v x 1024) / 1024.
- **A level change while far** reaches the texel:
  - Dressed bodies: through `on_changed` -> `_crowd_light_changed` -> `refresh`.
  - Ghosts: through `ghost_light`. A ghost switched between lit and unlit re-makes its parts.
- **A fading ghost:** its fade twin now comes from the base, not the level copy, and takes the
  level from the texel. `object.gdshaderinc` and an `OD0_LINE` mod shader both read `srr_cg_objc`.
- **Pixels:** NOT RUN by this review (see Gates: the box's shared lock was held by round 760's queue for the whole window). The round's own A/B (swarm 1,000, Forward+) reports far vs near d8 0.000 / dmax 1.

### 3. Glow per instance (`f06f892a`, `b67ffb39`)

- **The arithmetic** (READ): `srr_glow_row` is `srr_glow`'s, line for line: the triangle wave on
  `mod(t, 2p) / p`, the 8-bit TFACTOR, the scroll by `fract(speed x t)`, MODULATE / MODULATE2X,
  ADD / ADDSIGNED2X.
- **The values:** the row holds the material's values, with the shader defaults where the row
  sets none. `glow_period` is at least 1 ms (`row_params`), so no division by zero.
- **The option textures:**
  - The four slot samplers carry `glow_texture`'s hints.
  - Slot 0, and a fifth texture or later, fall back to the twin's own `glow_texture`, which is
    then in the twin's key.
- **The twin key:** it drops only the row's parameters (and `glow_texture` when slotted). It keeps
  `albedo_texture`, `alpha_scissor`, the cull, the shader and the render priority.
- **TexAni:** glow materials are never bound to TexAni (its only `bind` is ObjectLoader's), so the
  key is stable.
- **A fading body** draws the plain material, as AppearFade does near.
- **The plus change (0x3038) on a far body:** `_reglow_other` wakes the body (`_crowd_wake`), and
  the next cycle adds it far with the new rows. A ghost's plus change is `_redress_other`, which
  re-ghosts it.
- **Pixels:** NOT RUN by this review (see Gates: the box's shared lock was held by round 760's queue for the whole window).

### 4. Pushing dirty groups, and the collect cap

- **Every write to a group's buffer marks it dirty** (READ):
  - All writes are in `_add_part` and `_remove_part`; the fade weight is written only at add.
  - Each of them puts the group in `_dirty_groups`.
  - `collect` erases a freed group from `_dirty_groups`, so a freed RID is never pushed.
- **`_instances`** is kept by the same two functions.
- **`collect`** frees at most 128 groups a call. The rest keep their empty count and go on later
  calls. An empty group draws nothing.
- **Pixels after leaving and arriving again, and gear changes:** NOT RUN by this review (see Gates: the box's shared lock was held by round 760's queue for the whole window).

### 5. The bounds snap (`1cc2f223`)

- **The snapped box encloses the box it snaps** (READ): `snap_box` floors the low corner and ceils
  the high one to 64.
- **No path shrinks below the bodies:**
  - `_grow_aabb` grows the box and then snaps it.
  - `reset_aabb_to`'s keep-test compares the snapped box.
  - New groups get the current box.
- **So nothing at the edges can be culled that was not before.** NOT RUN by this review (see Gates: the box's shared lock was held by round 760's queue for the whole window).

## Gates

| gate | result |
|---|---|
| `remote_godot.sh check` (`RENDER_DIR=/opt/opensro-client-r759rev`, lane lock) | **checked 686 scripts and 9 scenes, ALL LOAD** (MEASURED) |
| `remote_godot.sh tests` (same) | **ran 263 suite(s), 0 failing** (MEASURED; includes `const_array_lint_test`, `efp_sim_test._batch`, `crowd_gpu_test`, `crowd_ghost_test`) |
| the cap probe (F1), headless, lane lock | MEASURED, F1's table |
| `perf_gate.sh --base 2e646fb4 --sites jangan --frames 40000` | **NOT RUN** |
| `crowd_run` `OPENSRO_QA_LINEUP=swarm` 7000, `abbc993b` vs `d2e61a2a` | **NOT RUN** |
| pixel A/B (swarm 1,000: natural light, `CHARLIGHT_VALUE=0.35`, after churn/redress/reglow; Compatibility) | **NOT RUN** |
| stress 3 x 300 s swarm (dest + churn + reglow + redress, one with `zone`) | **NOT RUN** |

**Why not run.**
- The renders queue on `/var/tmp/godot-lock/lock`, to be taken only when no other Godot runs.
- Round 760's lane kept the box busy back to back for the whole window (23:15 to 01:55
  UTC): its perf gates, swarm A/B and stress jobs.
- This review's lock holder never got the lock, and its two-hour job limit ran out.
- The one queued holder found waiting on the lock (its file was re-created at 23:32) was this
  review's own, and it was stopped.

The commands, ready to run, on the box from shipped copies (`remote_godot.sh check` first),
each under the shared lock:

```
flock /var/tmp/godot-lock/lock <dir>/tools/crowd_run.sh <dir> /var/tmp/r759rev/swarm7000.log 7000 base,dest0.02,base \
  OPENSRO_QA_LINEUP=swarm OPENSRO_QA_CROWD_DELAY=45 OPENSRO_QA_LINEUP_COLUMNS=100 OPENSRO_QA_LINEUP_SPACING=4,5 \
  OPENSRO_QA_OTHER_BUILD_BUDGET_MS=300 OPENSRO_QA_OTHER_BUILD_HITCH_MS=400 OPENSRO_QA_CROWD_PERSEC=1 OPENSRO_QA_CROWD_SECONDS=15
# A/B with churn: 1000, steps ab,dest0.05+churn0.05+redress0.02+reglow0.02,base,ab,base,ab, COLUMNS=40 SPACING=8,10,
#   SECONDS=20, OPENSRO_QA_CROWD_SHOTS=<dir>; then frame_ab.py on each ab_<n>_gpu.png / _near.png with the far box.
# stress: 3000 and 7000, steps dest0.02+churn0.01+reglow0.005(+redress0.005)(,zone), SECONDS=300, CROWD_TIMEOUT=2400.
```

## Probe

`r759rev_cap_probe.gd` (scratch, not committed): EfpSim templates from `EfpEffect.template_for`
over Media.pk2's itemrare / itemoptionefp rows, 600 frames old path vs `EfpSimBatch.run`, per-sim
counts compared each frame. Run headless on the box under the lane lock, Godot 4.2.2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013CKe7wwBdSifh9pCEL11a8
