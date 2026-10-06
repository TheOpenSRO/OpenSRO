# Round 739 review — crowd scale, lane B (per-body systems)

Reviewed: `727b32b3` + `4bb85814` on `worktree-agent-a78a375e4b4d6d787`, base `3fc71af2`, in a
detached worktree. Code read in full (`World3D.gd` diff, `other_crowd.gd`, `character_blobs.gd`,
the two new suites); the READ claims checked in the decompile and the disassembly on the box;
the gates re-run on the box; a scratch merge `dev + 739 + 738` built and tested. No code was
changed.

## Verdict

**Ship after F1 and F2 are fixed** (F1 is a merge fix, needed only when round 738 lands; F2 is a
few lines). B1, B2, B4 and B7 are correct as built; the fold is exact at one step a frame and
the READ values (ten, 300, 600) check out in the binary. Nothing here breaks the local player,
monsters, NPCs, the party or PvP. F3 to F9 can follow in a later round.

## Findings, most severe first

### F1 — REGRESSION (on merge with round 738): B3's hearing cut is unreachable once 738 lands

- **Where:** `client/scripts/World3D.gd:6367` (the `elif not _other_hearing.is_empty()` branch in
  `_tick_idle_animations`). In the merged tree it is at line 6431, after round 738's new first
  branch, `if info.size() == CrowdAnim.PLAYER_INFO_SIZE`.
- **Evidence:** round 738 gives every other player's skeleton a cull-cache entry
  (`MonsterCrowd.CullCache.info` -> `CrowdAnim.is_other_player`: a parent with a `character_id`
  meta, a six-field entry). Another player's skeleton then always takes 738's branch, which sets
  `pose` and leaves `audible` true ("its clock and its sounds run on"). B3's `elif` is never
  reached for a player, so past 600 their clip sounds are advanced again. **Measured:** a
  scratch merge (`dev`, then `4bb85814`, then `c2479f4d`; the one textual conflict was the QA
  file `qa_lineup.gd`, resolved by keeping both sides) passes `check` (657 scripts, ALL LOAD),
  but `tests` gives **ran 251 suite(s), 1 failing**:
  `crowd_arrival_test.gd: FAIL 700 from the listener its sounds are out of hearing`.
- **Fix (at merge):** move B3's test into 738's player branch, kept on the cache entry the way the
  monsters' rule keeps it: `audible = origin.distance_squared_to(listener) <=
  SoundTable.CULL_DISTANCE_SQ`, and on a change `info[2] = 0.0 if audible else 1.0`, with
  `_anim_sounds.rest(skeleton)` when it goes out. Then remove `_other_hearing` and its
  bookkeeping in `_dress_other`, `_redress_other`, `_on_entity_left` and
  `_replace_others_for_arrival`. Point the test's hearing case at the new branch.
  `crowd_arrival_test` already catches the regression.

### F2 — BUG: a seated arrival who walks off before being dressed is dressed seated, and stays seated

- **Where:** `World3D.gd:9229` `_set_other_gait` (an empty gait returns before it clears
  `_other_seated`). Also `_step_other_bodies` (`:15485`) and `_dress_other` (which reads
  `_other_seated`).
- **Evidence:** a seat comes from the list's Seated tail or the spawn record's motion byte. On
  dev, `NetClient._user_spawned` sets `snap.seated`, and `_seat_result_others` writes
  `_other_seated` for a body that is not dressed yet. The only thing that clears it when a
  sitter walks off is `_set_other_gait(id, true)`, and that does nothing while the body has no
  gait. The server sends no stand state when a sitter moves: `world.go:1730` discards
  `leftSit` from `motions.moved`, so no 0x30bf reaches `_apply_other_motion`. If the walk ends
  before the body is dressed (a crowd's queue takes 2 to 25 s, MEASURED in r739.md), the body
  is dressed on the sitting loop where it now stands. It stays seated until that player moves
  again. Before this round the body was drawn at once, and the first move stood it up.
- **Fix:** while a body is still queued, a non-relocating move clears its seat. In
  `_on_entity_moved` (or in `_step_other_bodies` when `at != target`), if
  `_other_build_args.has(id)`, run `_other_seated.erase(id)`. A crowd_arrival case: seated
  arrival, then a move, then a dress, then check it is on the stand loop.

### F3 — VISUAL: below 60 fps the circles (the player's included) trail their bodies

- **Where:** `World3D.gd:15156-15158` (`_update_blob_shadow` and `CharacterLight.step`, now in
  the once-a-frame block). Also `:15188` (the others' tick, later in the same step).
- **Evidence:** the once-a-frame block runs in the frame's **first** physics step. The base ran
  it every step.
  - **The local player:** it walks in every step before the block. At k steps a frame its
    circle is placed after the first and misses the other k - 1. At run speed 50 u/s (the
    constant's own doc) that is 0.83 units at 30 fps, 1.7 at 20, and 5.8 at k = 8. The circle is
    9 across (BCRadius 4 + 5).
  - **Monsters** (walked in `_step_heights` in every step): the same.
  - **Other players:** their circles are placed *before* the frame's walk tick, so they now
    trail by the whole previous tick (k steps) instead of one step.
  - At 60 fps and up (k = 1) nothing changes.
  - COMPUTED from the code order, not rendered: a movie-writer `qa_shot` runs one physics step
    a frame and cannot show it.
- **Fix:** run the once-a-frame work after the frame's physics: the circles, `CharacterLight`,
  and preferably `_step_other_bodies` itself, from `_process`. `StepGate` already accumulates
  the steps' delta, so `_process` can take it. Positions are then the frame's last, and the
  k - 1-step lag B1 adds to the others' walk (MINOR on its own) goes too.

### F4 — DEPARTURE (minor; the READ set is wider): Detail's ten are not only characters in the original

- **Where:** `client/scripts/world/character_blobs.gd` (`select_detail` over `GROUP`), and
  r739.md's B2 row ("Players, monsters and NPCs alike").
- **Evidence (READ, this review):**
  - `SWorld::vslot_025` (0xa17ab0) walks the map passed as its stack argument (`[esp+0x180]`,
    0xa17d24). Every call site passes `0xec24c0` (0x84ac59; 0x84c722 for vslot_024).
  - `CICPlayer::vslot_005` fills that map from the global GID-object list (`0xec4ae4`), keyed
    `round(|obj - player(+0x90)| x 10)`. The x 10 is the double at 0xe1b840, read from
    `sro_client.exe`: **10.0**. So key 3000 is 300 units (confirmed).
  - The other map, `0xec24e4`, is keyed by distance to `DAT_0110f7d0+0x340` (the camera) and goes
    to vslot 0x30.
  - The list is linked by the `CIGIDObject` constructor `FUN_009c2340` -> `FUN_009c1e30` (node at
    obj+0xdc), so **the local player is in it at key 0 and is one of the ten**. Answer to the
    round's OPEN: yes, as implemented.
  - Unlike Circle's vslot_024, **vslot_025 has no IsKindOf-CICharactor test**. An object counts
    when its vslot 0x50 answers non-zero (`CIGIDObject`'s is `FUN_009c1940`, `+0xbc != 0`) and
    it has a model at `+0x9c`. The count only rises when the draw's begin succeeds.
  - So `CIGIDObject` kinds other than characters (`CICCos`, `CICATStruct`, `CIParticleObj`;
    ground items if they derive from it) can take slots. Ours counts characters only.
- **Fix:** relabel the set "characters (OURS; the original's walk has no kind test, READ)", or
  add COS and other drawn GID objects when they exist here. Keep "ten, 300, the player
  included" as READ.

### F5 — MINOR: on dev, a group page is not queued whole; the budget goes to the first-listed

- **Where:** `World3D.gd:15580` (the inline `_pump_other_builds()` in `_spawn_or_update_other`)
  and `:21326`. On dev, `NetClient._apply_spawn_message` (`OP_GROUP_END`) emits `entity_entered`
  once per record. Dev's `_on_entity_entered` calls `_spawn_result_others([snapshot], ...)` for
  each one.
- **Evidence:** each record pumps on its own. So a 0x3017/0x3019/0x3018 page's first records
  are dressed in server order, first come, until the 25 ms budget is gone. Only the rest wait
  and go nearest-first. r739.md says so for one-by-one entries, but every player spawn on dev
  now comes that way. The task's "a page queued whole" does not hold.
- **Fix:** either wrap the group's emit loop in a begin/end pair (a signal or a flag World3D
  reads, setting `_other_build_defer`), or never pump inline and let the once-a-frame pump take
  arrivals. A lone arrival would then wait at most one frame.

### F6 — MINOR (claim precision): "a body at its target is no longer re-set" holds only at 3+ steps a frame

- **Where:** `World3D.gd:15495` (`if at == target`).
- **Evidence:** `Vector3.lerp` is float32 (`real_t`). COMPUTED with float32 rounding over 300
  random walks of up to 8 units within [0, 1920):
  - at one or two steps a frame (a = 0.25 or 0.4375) a walked body **never** reaches its target
    exactly. It stalls 1-2 ulp short (6e-5 to 1.2e-4 units), so `position` is still written
    every frame.
  - from three steps (a > 0.5) every walk converges exactly.

  So the skip helps where it was measured (1000 bodies, 8 steps) and on bodies that never moved,
  not after a walk at normal frame rates. There it costs nothing extra over the base.
- **Fix:** snap when within an epsilon: `if at.distance_squared_to(target) < 1e-6: position =
  target`, then skip. r739.md should say the skip assumes it.

### F7 — MINOR / VISUAL: an undressed body takes auras and berserk on its bare node

- **Where:** `World3D.gd:20176` `_fx_owner_body`; `_berserk_apply`; `_fx_resync_all` /
  `_replay_held_buffs` right after `_spawn_result_others` (`:6003`, `:1771`).
- **Evidence:** a queued body's node is in `_other_bodies`, so a buff start or a zone change's
  resync attaches its ACT_L effects to the bare node. A berserk start plays its burst there.
  For the wait (2 to 25 s in a crowd) a floating aura with no body is drawn at the node. The
  effects find the skeleton once it is dressed (`EfpEffect._skeleton` re-finds it), and
  `ensure_aura` keeps them, so nothing is lost or doubled. Only the wait looks wrong.
- **Fix:** have `_fx_owner_body` (and the berserk start) treat a body in `_other_build_args` as
  not drawn. `_dress_other` already resyncs both from `BuffRoster` / `body_modes`.

### F8 — MINOR: a re-sent spawn for a queued body does not update its queued items

- **Where:** `_spawn_or_update_other`, the `_other_bodies.has` branch.
- **Evidence:** `_other_equipped` takes the new items, but `_other_build_args[id]["equipped"]`
  keeps the first spawn's, which is what it is dressed in. A dressed body was not redressed by a
  re-sent spawn before this round either, so this is not a regression. The two maps just
  disagree for a queued body.
- **Fix:** in that branch, `if _other_build_args.has(id) and not equipped.is_empty():
  _other_build_args[id]["equipped"] = equipped`.

### F9 — MINOR: `_other_by_uid` still scans every body on a miss

- **Where:** `World3D.gd` `_other_by_uid`.
- **Evidence:** a uid that is not drawn (a 0x3038 for someone outside this client's view, which
  is ignored) falls through to the old full scan every time. B7 speeds up hits only.
  Consistency is fine:
  - on leave, `remove` only if the map still names this id;
  - on a zone change, `clear`;
  - on reconnect, a fresh World3D;
  - a stale entry is checked against `_other_bodies`.
- **Fix:** drop the fallback scan, or keep it for tests only (the fallback was added for
  `equip_arrival_test`, which puts a body into `_other_bodies` by hand; that test can call
  `_other_uids.add`).

## Checked and found correct

- **B1, the fold.**
  - k = 1: `lerp_factor(speed, delta, 1)` is `min(speed * delta, 1)` and `distance_before_last(d,
    .., 1)` is `d`, the old pass term for term.
  - k > 1: exact for the fixed physics delta.
  - Arrival: no overshoot (f <= 1).
  - Stop-to-idle: the same step's threshold (1.4) as before.
  - Run/stand only: there is no walk gait for others in either build.
  - Turns: `RemoteFacing.turn` is linear and clamped, so k steps of ms are one call of k x ms.
  - Teleports, `OpSkillMove` snaps and relocations set `position` and target together; the
    next tick skips them.
  - The tick runs on the frame's first physics step and covers the previous frame's leftover
    steps, so others draw k - 1 steps behind the old per-step loop (MINOR, folded into F3's fix).
- **B2:**
  - `set_casting` records only the meshes that were ON and gives back ON, so "exactly as built"
    holds.
  - A redress re-applies the state (`refresh_detail`): the old skeleton's meshes are already OFF
    and the new ones are collected.
  - Labels are skipped. EquipFx holders and fade warm-up quads are OFF by construction.
  - AppearFade swaps materials, not meshes. BerserkLook rescans when the skeleton changes.
  - The player is always chosen, so its own redress stays casting.
  - Switching Detail off disables the sun's shadow, so leftover OFF states are invisible.
    Switching back re-selects and adopts.
  - The 6-frame reselect and the 64-a-pass adoption are OURS and labelled.
- **B3 (on this branch):** the listener is the player; 600 is `SoundTable.CULL_DISTANCE_SQ`
  (round 664's READ). The local player's skeleton and NPCs' are never in `_other_hearing`, and
  hit/block sounds are not clip sounds, so neither the player's own nor a target's
  non-clip sounds are cut. A targeted player past 600 is silent, as the core's cull would make
  it in the original.
- **B4:** every `_other_bodies` user was checked for a dressed-body assumption. The gait,
  hit, cast and redress paths all go through `_other_gaits` lookups with an emptiness test, so
  there is no unchecked indexing.
  - Moves walk the bare node.
  - 0x3038/0x3039 reach `_redress_other`, which updates the queued items; the reglow branch
    returns false with no gait.
  - Leaving before the dress drops the body from the queue, the args and the uid map. The bare
    node fades out and is freed by `AppearFade.start_out` (no ghost, no leak). The name for the
    chat line comes from the node.
  - A queued body has no collider, so it cannot be clicked. A selection made by other means
    (the party window) works: the node carries `character_id`, `character_name` and `body`.
  - The party board finds and positions it.
  - Monster blows turn toward it and skip the hit clip.
  - A zone change clears the queue, the args, the uids and the hearing map.
- **Regressions:** none found in the local player's walk, camera, sit or equipment, in monsters
  or NPCs (they only share the once-a-frame circle placement, F3), in the party, or in PvP
  targeting. `_other_player_ground` reads the target, not the drawn node.

## Gates (this review)

- `remote_godot.sh check` (`RENDER_DIR=/opt/opensro-client-r739rev`): **checked 647 scripts and 9
  scenes, ALL LOAD**.
- `remote_godot.sh tests`: **ran 247 suite(s), 0 failing**.
- Scratch merge `dev + 739 + 738`: check 657 scripts ALL LOAD; **tests ran 251 suite(s), 1
  failing** (F1).
- `perf_gate.sh --base 3fc71af2 --head 4bb85814 --sites jangan --frames 40000` (1280 x 720,
  Forward+ on the RX 7600; the base's 3 cached runs confirmed by a fresh one at 1.47 ms), **exit 0,
  every number SAME**:

  ```
  jangan  frame ms   base 1.55  head 1.48  (-0.1)  SAME
  jangan  entry ms   base 10027.50  head 9601  (-426.5)  SAME
  jangan  freeze ms  base 3524.50  head 3390  (-134.5)  SAME
  jangan  hitches    base 4.50  head 4  (-0.5)  SAME
  ```
- **The 200-body before/after `qa_shot` was not taken.**
  - **Why:** the shared box lock (`/var/tmp/godot-lock/lock`) was held by another lane's hold
    loop (`/var/tmp/r741/held`), with two r738rev `qa_shot`s queued behind it, and another lane's
    perf gate kept a Godot running. A shot script was staged (`QA_SHOT_REAP=0`, waiting for no
    other Godot), but it was withdrawn rather than overlap or jump the queue.
  - **It would not have settled B1 anyway:** `qa_shot` renders through `--write-movie`, a fixed
    60 fps clock with one physics step a frame. At k = 1 the fold is the old pass term for term,
    so both sides draw identical positions by construction. F3's trailing circles also need
    k > 1, which the movie writer never runs.
  - **What B1 rests on:** measurement — the fold's algebra above, and the suites' 8-folded
    against 8-per-step checks (`other_crowd_test`, `crowd_arrival_test`, all passing).

## Merge with round 738

- **Textually clean on top of dev + 739.** `git merge-tree dev 4bb85814` conflicts only in
  `client/scripts/world/qa_lineup.gd`: round 741's `OPENSRO_QA_LINEUP_TURNS` against 739's kit
  cache, both kept. 738 then merges with no conflict.
- **Semantically one conflict:** F1. Fold B3 into 738's player branch as described.
- Otherwise the two do not interact:
  - 738's `CrowdAnim.is_other_player` keys on the holder's `character_id` meta, which 739 sets
    at arrival, before the dress, so it holds.
  - 738's skin changes sit inside `_build_assembled_character`, which `_dress_other` calls
    unchanged.
  - B2's `set_casting` walks whatever GeometryInstance3D nodes the new body has.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
