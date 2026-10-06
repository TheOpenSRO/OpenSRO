# Round 748 review — crowd scale lane B (head `81a3b3f0`, base `daeb1b0c`)

Independent adversarial review. Thread safety was the brief's main risk; it is where the blocking
finding is. Labels as the project uses them: **READ** (engine or project source), **MEASURED**
(a run on the box), **INFERRED**, **OPEN**.

Box: CT 103 (RX 7600, RADV NAVI33, Forward+ on Vulkan through `xwl_run.sh`), Godot 4.2.2 official
binary, no native library (GDScript readers). Review copy `/opt/opensro-client-r748rev`, own lock
`/var/tmp/r748rev/lock`; renders under the shared `/var/tmp/godot-lock/lock`.

## Verdict

**Do not ship as is.** The template tasks crash the client by heap corruption (F1). The root cause
is found and the fix is one function: `_fallback_of` iterates a GDScript `const` Array on the worker
while the main thread iterates the same Array. In Godot 4.2.2, reading a read-only Array writes the
element into a slot that every reader shares. Swapping that one call for code without the
constant on the worker survived 2 x 300 s of the same stress. Without the swap, 18 of 19 Vulkan
runs of the unfixed path crashed: as shipped, or with an unrelated part bisected out.
Once F1 is fixed (and, ideally, F2 and F3), the round's results hold up:

- the perf gate is SAME;
- five 1000-body arrivals: worst 98.8-121.3 ms, 0-5 frames over 100;
- `check` and `tests` are green;
- the merge with round 747 is mechanical.

## Findings, most severe first

### F1 — CRASH — `_fallback_of` races on a read-only `const` Array between the template task and the main thread

- **Where:**
  - `client/scripts/ui/character_appearance.gd:763-770` (`const _FALLBACK_SUFFIXES`, and
    `for suffix in _FALLBACK_SUFFIXES` in `_fallback_of`).
  - It is called on the worker at `:1002` (`_prep_task`).
  - It is called on the main thread at `:602-603` (`build`), `:857` (`template_paths`) and
    `:922` (`_prepare`).

- **Mechanism (READ, Godot 4.2.2 source):**
  - GDScript `const` Arrays are read-only.
  - `Array::operator[]`, **including the const overload**, handles a read-only array by doing
    `*_p->read_only = _p->array[p_idx]; return *_p->read_only;` (`core/variant/array.cpp:84-98`).
    `_p->read_only` is **one Variant per array, shared by every reader**.
  - `Array::get` is that operator (`array.cpp:418-420`).
  - The VM's array loop calls it: `*iterator = array->get(0)` in `OPCODE_ITERATE_BEGIN_ARRAY` and
    `array->get(*idx)` in `OPCODE_ITERATE_ARRAY` (`modules/gdscript/gdscript_vm.cpp:2898`,
    `:3237`). So does `CONST[i]` (`VariantIndexedSetGet_Array::get`,
    `core/variant/variant_setget.cpp:624-634`).
  - So two threads looping over `_FALLBACK_SUFFIXES` both assign Strings into the same Variant.
    The String reference count is swapped without a lock, which gives double unrefs and reads of a
    buffer being freed.
  - Dictionaries are not affected on these paths. The VM's keyed get goes through the const
    `getptr`, which does not touch `read_only` (`variant_setget.cpp:985-993`,
    `dictionary.cpp:113-119`).

- **Symptoms (MEASURED):**
  - `FATAL: Index p_index = 0 is out of bounds (size() = -1384395304)` from `cowdata.h:158`.
  - SIGSEGV, `corrupted double-linked list`, `malloc_consolidate(): invalid chunk size` and
    `free(): invalid pointer`.
  - In one run the crash handler hung after printing its banner.
  - All on the main thread, inside GDScript calls (the trace is the VM's recursion).
  - This is the same signature as the round's own `F200` crash, which r748.md section 3.1
    attributed to the duplicate's signal disconnects and to `EfpEffect._evict_kind`. The round's
    fixes for those did not remove this.

- **Reproduction:** `r748rev_stress.gd` (review-only, not committed; it is described in the stress
  section below) drives `prepare` / `poll_prepared` / `build` with random kits of the 52 Figures
  and the catalogue's items.

| Run (Forward+, RX 7600 unless headless) | Crash? |
|---|---|
| sync control: `build()` only, no tasks, 2 x 300 s (headless and Vulkan; 60,731 and 29,088 builds) | none |
| async, as shipped: `vkasync1`, `vkasync2` | **2/2 crashed**, within about 60 s |
| async, glow off (EfpEffect not involved) | crashed |
| async, no `build()` on the main thread (only `prepare` / `poll`) | crashed |
| async, no teardown / relog / `free_templates` churn | crashed |
| `PREP_MAX_RUNNING = 1` (one worker) | crashed |
| base `pk2_reader.gd` (lock held through decrypt) | crashed (`free(): invalid pointer`) |
| no shared canonical skin handed to the task | crashed |
| no clip pre-parse (`animation_for`) in the task | crashed |
| a Pk2Reader of the task's own | crashed |
| bodies only, no items on the worker, 240 s under continuous `free_templates` load | none |
| items only on new templates (in place) | crashed |
| items only on bare-skeleton copies | crashed (handler hung) |
| worker serialised against the whole main-thread section (prepare / poll / build), 5 runs | none; the unserialised control crashed 3 times in 4 |
| worker serialised against adoption (`_finish_prep`) only | 2/2 crashed |
| **as shipped, but the worker's `_fallback_of` replaced by `ends_with("_r.bsr") or ends_with("_f.bsr")`**, 2 x 300 s (258 tasks, 29 s of task time; and a run with `build()`) | **none** |

- **Fix:**
  - Do not iterate or index a `const` Array/Dictionary-of-Strings from more than one thread.
  - Here, write `_fallback_of` without the constant. For example:
    `var low := path.to_lower(); if low.ends_with("_r.bsr") or low.ends_with("_f.bsr"): return path.substr(0, path.length() - 6) + ".bsr"`.
    Or make it a `static var` (not read-only, so `get` returns the element itself).
  - Add a regression test: two `WorkerThreadPool` tasks plus the main thread calling `_fallback_of`
    for about 2 s. It should crash on the current code. Running this stress harness for a minute
    is the stronger check.
- **Same class elsewhere (pre-existing):** see F5.

### F2 — BUG — every template task for an existing template prints an engine ERROR (`set_name`)

- **Where:** `character_appearance.gd:953`, `s.name = src.name` in `_bare_skeleton`.
- **What happens:** a body template's skeleton is never named. `Skeleton3DBuilder.build_skeleton3d`
  makes `Skeleton3D.new()` and the round's template path never renames it. So
  `set_name(StringName())` fails `ERR_FAIL_COND(name.is_empty())` (`scene/main/node.cpp:1164`).
- **Evidence (MEASURED):**
  - `ERROR: Condition "name.is_empty()" is true. at: set_name (scene/main/node.cpp:1164)`, once
    per bare-skeleton task.
  - It is in each of this review's 1000-body and 200-body boots (1 per boot, the lineup's kinds
    being few).
  - The stress runs printed 24-100 of them before crashing.
  - It is absent from every sync-path run.
- **Impact:** harmless to the copy, which keeps an empty name. But it is a red `ERROR` in the
  players' logs for every new kit on a known body. Testers send those logs, and this one reads
  like corruption.
- **Fix:** skip the name (`_bare_skeleton` does not need it), or `if src.name != &"": s.name = src.name`.

### F3 — WRONG-LABEL (latent CRASH) — the PREDELETE comment's lifetime claim is false

- **Where:** `character_appearance.gd:237-238`, "A template task holds this object through its
  Callable, so none runs by now".
- **Why it is false (READ):** a method Callable stores the object's `ObjectID`, not a reference
  (`core/variant/callable.cpp:331-343`). `_prep_task.bind(...)` does not keep the RefCounted
  appearance alive.
- **Risk:** if the last reference goes while a task runs, PREDELETE frees `_prep_done` and the
  templates, and the worker goes on using `self` (`_data`, `_prep_lock`, `_prep_done`). That is a
  use-after-free. The task id is also never waited for.
- **Is it reachable today?** No. World3D creates `_appearance` once (`World3D.gd:8867`) and calls
  `wait_prepared(false)` in `_exit_tree` (`:6240`). The harness's relog path relied on the same
  order.
- **Fix:**
  - Correct the comment.
  - Make PREDELETE wait: `for path in _prep_tasks: if int(_prep_tasks[path]) >= 0: WorkerThreadPool.wait_for_task_completion(...)`.
    That is safe there: the object is still whole during PREDELETE.
  - Or keep the appearance alive for the task: a RefCounted passed as a bound *argument* is held
    by the Callable's binds.

### F4 — BUG (minor) — a task that produces no result strands its waiting bodies

- **Where:** `character_appearance.gd:1086`. When `r == null` (a script error in the task, so
  `_prep_done` is never written), `_finish_prep` returns without bumping `prep_generation`.
- **Effect:** World3D caches a kind's "not ready" per generation (`_other_template_ready`,
  `World3D.gd:15892`). Bodies of that kind stay queued until some unrelated adoption bumps the
  generation, and in a quiet zone that may never happen.
- **Second case, same effect:** a body waiting on a glow `.efp` whose preloaded template is evicted
  before `poll_prepared` sees it.
  - Preloaded templates have no LRU stamp (`_used` is 0), so they are the first evicted once
    `_templates` passes 256 (`efp_effect.gd:1493`).
  - `_efp_waiting` never sees `has_template`, and nothing bumps the generation.
  - INFERRED; it needs a long session with more than 256 effect files.
- **Fix:** bump `prep_generation` on every `_finish_prep`, including a null result. In
  `poll_prepared`, drop an `_efp_waiting` entry that is neither loaded nor preloading, so the next
  ask re-preloads it.

### F5 — CRASH-risk / BUG (pre-existing, widened by this round) — the same read-only `const` race elsewhere on worker paths

- **`SkinnedBsrAssembler.IDLE_ANIMATION_HINTS` (Strings)**
  - Iterated in `idle_animation_path` (`skinned_bsr_assembler.gd:84-88`).
  - Reached from `assemble_from_archive(..., with_animation = true)` on the monster-template
    tasks (round 661) and on the main thread, when a `.bsr` has no type-0 stand entry.
  - Same heap race as F1, on a rarer path. Not new in 748.
- **`BmsReader.VERTEX_REC_SIZE_CANDIDATES` (`[44, 52]`)**
  - Iterated in every `.bms` parse (`bms_reader.gd:848`).
  - Runs on the cell prepare, monster template, EfpEffect preload and, since this round,
    character-template tasks, and on the main thread.
  - The elements are ints, so the heap is not at risk. But one thread can read the other's
    candidate from the shared slot. A parse can then try 52 twice and never 44, and drop a mesh
    piece. INFERRED from the mechanism; not observed.
  - This round adds more concurrent BMS parsing: the item tasks and more preloads.
- **Fix:** as F1. Replace these loops with literals or `static var`s, and grep for
  `for .* in [A-Z_]+:` and `[A-Z_]+\[` in any script a task runs.

### F6 — VISUAL (minor) — the local player's weapon glow can trail the weapon by one frame

- **Where:** `World3D.gd:15180-15183`. The player's pose is now applied in `_process`.
  `EquipFx._process` places a shared master's holder from `get_bone_global_pose`
  (`equip_fx.gd:412`).
- **Why it lags:**
  - The EquipFx driver is a child of the root viewport (`equip_fx.gd:174`).
  - It is created by the first glowing weapon, which is the character-select stage's, in the
    normal flow.
  - `change_scene_to_file` appends World3D after it, so the driver's `_process` runs first and
    reads the previous frame's player pose.
  - Before this round the pose was applied in the physics step, ahead of every `_process`.
- **Effect:** INFERRED from the 4.2 process order (priority, then tree order), not rendered:
  - a one-frame lag of the player's glow behind a fast swing;
  - it applies only to non-world-axis kinds (world-axis ones use the per-weapon `follow_host`
    path under the skeleton, which runs after World3D);
  - other players and NPCs are not affected (posed in the physics step).
  - `SkillEffects.tick` (physics) also reads the player's bones up to one frame older at low
    fps. That was one step older before, so the change is small.
- **No timing change otherwise:** clip time, clip choice and clip sounds stay in the step, so
  attack-hit timing and footsteps are unchanged (READ, `World3D.gd:15527-15545`).
- **Fix:** apply `_player_pose_due` at the start of `_process` with `process_priority` lower
  than the driver's. Or have the driver run at a positive `process_priority`, after World3D.

### F7 — WRONG-LABEL — "every master of a file has the same template and seed"

- **Where:** `equip_fx.gd:238-243` (`kind_key`'s doc), repeated in `r748.md` section 3.2.
- **Why it is wrong (READ):**
  - `EfpEffect.create` builds the sim with `seed_value = 0` (`efp_effect.gd:210`).
  - `EfpSim._init` then calls `_rng.randomize()` (`efp_sim.gd:494-497`).
  - So each per-scale master had its own random particle stream.
- **What changes:** a file's weapons at different row scales now share one stream, uniformly
  scaled. Before, they had independent ones.
- **Is it a regression?** No. The particles are the same kind at the same scale on each weapon
  (holder scale checked: `holder_transform(..., h.scale)` per host, and own effects use
  `effect_scale = h.scale`). But it is a visible change in a crowd: identical sparks on every
  enchanted weapon of a file. It should be disclosed as OURS, not described as "what is drawn
  does not change".

### F8 — MINOR — a pluses-only update to a queued body keeps a stale kind key

- **Where:** `World3D.gd:15807-15821`. `_spawn_or_update_other` with `pluses` and an empty
  `equipped` updates `_other_pluses` but does not erase `args["kind"]`. The same holds for the
  in-place `pluses[slot] = plus` path at `:16155-16163` when the body is still queued.
- **Effect:** readiness is judged for the old plus's `.efp` files. The dressing then decodes the
  new ones on the main thread. This is a hitch only, not a wrong look.
- **Fix:** erase `"kind"` whenever `_other_pluses` changes for a queued id.

### F9 — MINOR — the headless test runner exercises a renderer whose RID owners are not thread-safe

- **What (READ):** the dummy renderer's `mesh_owner`, `multimesh_owner`, `shader_owner` and
  `texture_owner` are not thread-safe (`servers/rendering/dummy/storage/mesh_storage.h:51,57`,
  `material_storage.h:50`, `texture_storage.h:46`). RD and GLES3 use `RID_Owner<..., true>`.
- **Where it bites:** `character_template_async_test.gd`'s stand-ins create `BoxMesh` /
  `MeshInstance3D` on pool threads in that renderer. So can any headless QA run of the world
  (monster templates, cell prepares).
- **Effect:** a possible flaky crash of `remote_godot.sh tests`. It is not a player risk, since
  players run Vulkan or GL. The headless stress crashed 2 of 2 runs, which is not usable as
  evidence on its own; F1 was confirmed under Vulkan.
- **Fix:** build the test's meshes on the main thread inside the stand-ins (a stand-in can return
  plain data), or keep this in mind when a headless suite flakes.

### Checked and found correct

- **Off-thread Node / Resource use** (READ, Godot 4.2.2):
  - Nodes outside the tree may be built on a pool thread: `ERR_THREAD_GUARD` passes when
    `!data.inside_tree` (`node.h:546-556`).
  - Only Node3D getters carry `ERR_READ_THREAD_GUARD` (`node_3d.cpp`). That is why
    `Node.duplicate()` failed, and the round found it.
  - Every guard compiles out of the release template the players run
    (`--export-release`, `release.yml:110,130`).
- **Off-thread RenderingServer use** (READ):
  - Writes from a non-server thread are queued (`server_wrap_mt_common.h:245-254`) and RIDs are
    allocated through thread-safe owners (`RID_Owner<..., true>` for mesh / material / texture /
    instance in RD and GLES3).
  - `ImageTexture` creation off-thread is supported in the default thread model. `project.godot`
    sets no `rendering/driver/threads/thread_model`, so it is "Safe".
- **Shared resources and signals:**
  - No worker-made item shares a mesh or material with a main-thread node.
  - The shared canonical Skin is only reference-counted on the worker (`MeshInstance3D::set_skin`
    connects nothing, `mesh_instance_3d.cpp:193-200`).
  - `ShaderMaterial::set_shader` connects only in the editor (`material.cpp:383-404`).
  - `_bare_skeleton` (bones only) does remove the round's original signal-map race.
- **`Pk2Reader`:** the decrypt outside the lock is safe. `Blowfish` is stateless per call, and
  `_dir_cache` / `_file` are always under `_lock`. MEASURED: restoring the base reader did not
  stop F1.
- **EfpEffect locks:** `_textures` / `_meshes` / `_templates` / `_preloading` writes are under
  `_mutex`. Unlocked reads are main-thread-only against main-thread writes.
- **Equipment changes mid-build:**
  - 0x3038 and spawn updates erase `kind` (`World3D.gd:15820`, `:16213`), so the next pump
    re-prepares the new kit.
  - Leave mid-build: `_on_entity_left` drops the queued id. A finished task is adopted harmlessly.
  - Teardown: `_exit_tree` → `wait_prepared(false)` (`World3D.gd:6237-6240`).
- **`swap_loop` hint:** checked against the entry's skeleton before use, with the scan as the
  fallback (`monster_motion.gd:219-236`).
- **Staggered `CharacterLight`:** a first visit (`had == false`) and a body that moved are still
  read at once (`character_light.gd:96-109`). Only the mesh rescan is staggered, as before (1 in
  8). No added lag walking under shadows.
- **Fades once a frame:** the alpha drawn is the last step's either way. A fade started in
  `_dress_other` (in `_process`, after the fade step) starts next frame.

## Stress tests

Review-only scripts, kept out of the repo: `r748rev_stress.gd`, `stress_vk.sh` and
`crowd_stress.sh`.

**The harness, per frame:**
- 1-6 random `(body, kit)` arrivals among the 52 Figures, with weapons and shields at +0-13;
- `prepare` on everything pending, `build()` of up to 4 ready ones into the tree;
- 30 % of live bodies freed, half with `queue_free`, half with `free()`;
- 5 % equipment changes on waiting bodies, 3 % leaving before they are dressed;
- 0.4 % `wait_prepared(false)` (a world teardown), 0.2 % `free_templates()`, 0.2 % a relog (new
  appearance).

**Harness results:** every crash and bisect is in F1's table. In total:
- unfixed path (as shipped, or with an unrelated part bisected out): 19 Vulkan runs, 18 crashed;
  2 headless runs, 2 crashed;
- runs where the worker's `_fallback_of` can never overlap the main thread's: 0 crashes. These are
  bodies only (2 runs), the fixed fallback (2) and the worker serialised against the main thread's
  appearance work (5);
- the sync controls: 0 crashes in 2 x 300 s.

**World boots** (`crowd_run.sh`, Forward+ 1920 x 1080, the shipped head, under the shared lock):

| Boot | n | Steps | Overlap | Arrival worst / p50 / over 100 | Pump's longest | Crash? | Errors (minus the missing native library) |
|---|---|---|---|---|---|---|---|
| 1 | 1000 | base | 0 | 101.8 / 91.0 / 2 | 34.1 | no | 1 x F2 `set_name`; axe fallback, gacha .bsr, exit-time leaks (pre-existing) |
| 2 | 1000 | base | 1 | 99.2 / 90.9 / 0 | 29.0 | no | same |
| 3 | 1000 | base | 0 | 98.8 / 90.9 / 0 | 28.4 | no | same |
| 4 | 1000 | base | 1 | 102.1 / 91.1 / 5 | 30.9 | no | same |
| 5 | 1000 | base | 0 | 121.3 / 90.8 / 1 | 27.4 | no | same |
| 6 | 200 | move, gone, base, move, gone, base | 1 | 59.6 / 19.8 / 0 | 38.9 | no | + about 95,700 `!is_inside_tree()` from `get_global_transform` during the QA `gone` step |
| 7 | 200 | same | 0 | 54.2 / 17.0 / 0 | 35.5 | no | same |
| 8 | 200 | same | 0 | 50.2 / 18.1 / 0 | 27.1 | no | same |

**Notes on the boots:**
- The boots did not crash. F1 needs a new template task to overlap a main-thread `_fallback_of`
  (a `prepare`, `template_paths` or `build` of a kit with a `_r` / `_f` model). The lineup has
  few kinds, so it rarely overlaps. A live zone does: every arrival list and every equipment
  change of a new kit.
- The `!is_inside_tree()` flood is the QA `gone` step reading bodies it removed from the tree. It
  appears in both 200 boots and was not attributed to this round: no 748 path reads
  `global_transform` without an `is_inside_tree` check. It was not compared with the base. OPEN,
  QA-only.
- **Not done:** a zone change or reconnect in the middle of an arrival in the world. No QA hook
  fires during the lineup's arrival: `OPENSRO_QA_ZONE` fires at the first region, and
  `OPENSRO_QA_RECONNECT=<tick>` cannot be aimed at the arrival. The harness covers the same code
  (`wait_prepared(false)` with tasks in flight: 36-51 teardowns and 19-24 relogs a run, with no
  hang or crash once F1 was removed).

## Merge with round 747 (`0b2cd15e`)

`git merge 0b2cd15e` onto `81a3b3f0` in a scratch worktree (not pushed): **4 conflicting hunks
in `World3D.gd`, 2 in `qa_crowd_probe.gd`**. Everything else merged automatically: `equip_fx.gd`,
`character_light.gd`, `crowd_scale.md`, `tools/README.md`.

**Resolved as follows, then checked on the box (`/opt/opensro-client-r748merge`, since deleted):**
- `check`: **checked 666 scripts and 9 scenes, ALL LOAD**;
- `tests`: **ran 254 suite(s), 0 failing**.

| Conflict | Resolution |
|---|---|
| `_set_other_gait`: 748's hinted `MonsterMotion.swap_loop` against 747's `_swap_other_loop` (far bodies swap on the GPU) | 747's call, with the hint threaded through: `_swap_other_loop(skel, anim, hint: Array = [])` passes `hint` to `swap_loop` |
| `_process` head: 748's fades / pose / FrameSplit against 747's `t0` | both, 748's block first |
| `_process` tail: 748's `w_pump` against 747's `_crowd_gpu_step()` | both, the pump then the crowd step |
| `_dress_other`: `_animated.size()` against 747's `_animated_total()` | 747's, plus 748's `dt.mark("clip")` |
| `qa_crowd_probe.gd` vars and the report line | both var sets; the report prints 747's `gpu_line` and then 748's split line |

**Semantic interactions:**

- **The async template adoption against CrowdGpu's twins — compatible:**
  - `CrowdGpu._layout_for` and the part scan take a body only if its meshes' skin has a
    `canonical_base` (747 `crowd_gpu.gd:686-700`, `:854-860`).
  - 748 puts every adopted template on its layout's shared, marked skin (`share_template`) and
    moves the task's items onto it (`_reskin`, including front-pass twins, which copy `mi.skin`).
  - The task's items for an existing template are made on the shared skin itself.
  - So far and near bodies see the same skins as on the synchronous path.
- **The dressing queue against the near/far choice:** a body waiting for its templates is still
  in `_other_build_args`, which `_crowd_eligible` reports as `"dressing"`. It cannot go to the
  GPU before it is dressed.
- **The swap hint against 747's `_animated` rebuilds:**
  - `_crowd_switch_due` replaces `_animated` (`_animated = kept`) and `_crowd_wake` appends
    entries.
  - Every such rebuild invalidates the hints. They are checked, so the result is correct, but
    each walker's first swap after a near/far cycle scans again.
  - At 1000 walking that gives back part of the `w_others` gain (14.4 → 7.3 ms) once a cycle.
    MEASURE after the merge, or keep the hint keyed by skeleton inside 747's rebuild.
- **The player pose in `_process` against `_crowd_gpu_step`:** independent. The player is never
  far, and the fades are stepped before the crowd step reads `fading(node)`.
- **EquipFx:** 747's `far_frame` placement and `own and _far(h.skel) == null` use `h.key`, which
  is now file-only. That is fine: `own` is a property of the file.
- **F1 is not touched by the merge:** 747 does not call `_fallback_of`.

## Gates

- **Box `check`** (`RENDER_DIR=/opt/opensro-client-r748rev`, own lock, on `81a3b3f0`): **checked
  663 scripts and 9 scenes, ALL LOAD.**
- **Box `tests`:** **ran 253 suite(s), 0 failing.**
- **`perf_gate.sh --base daeb1b0c --head 81a3b3f0 --sites jangan --frames 40000`**
  (`PERF_LANE=r748rev`, 1280 x 720; runs that another render overlapped were repeated by the
  gate; the base used its 3 cached runs, confirmed by a fresh check at 1.51 ms): **exit 0, SAME.**

  ```
  jangan  frame ms   base 1.50  head 1.50  (+0.0)  SAME
  jangan  entry ms   base 9283.50  head 9091  (-192.5)  SAME
  jangan  freeze ms  base 2891.00  head 2861  (-30.0)  SAME
  jangan  hitches    base 4.50  head 5  (+0.5)  SAME
  ```

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
