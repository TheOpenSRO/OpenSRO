# Round 761 review: the pooled masters' ordered particle cap

A focused review of `d42cfec9` (branch `worktree-agent-a3310958b2477c181`, based on dev
`21fbab4d`): `client/scripts/efp/efp_sim_batch.gd` and `client/scripts/efp/efp_sim.gd`, the
ordered global cap for EquipFx's masters on WorkerThreadPool. The questions were deadlock and
livelock freedom, memory visibility without atomics, whether `growth_bounds` is sound against
`EfpSim.step`, and the two lints. No code was changed.

Labels: **READ** (our code at `d42cfec9`), **INFERRED**. Nothing was **MEASURED** in this
review. The optional headless `efp_cap_probe.gd` run with `max_threads=2` was not made, because
the box was not quiet: round 762's `crowd_run.sh` swarm boot held `/var/tmp/godot-lock/lock`
with a live Forward+ Godot (load average 3.3), and a probe beside it would have perturbed that
lane's timings (AGENTS.md: a speed number taken while another lane runs Godot is noise).
`/opt/opensro-client-r761rev` also does not exist yet.

## Verdict

**Ship.** No blocking finding. The ordered cap is deadlock-free by construction for any pool
size, including a pool that never runs a helper. Every shared read and write of the Job is under
its Mutex, or happens before the tasks are posted. `growth_bounds` is sound in both directions
against `step()` / `_flush_deaths()` / `emit_spawns()` / `_spawn()`, so a decision taken early
is the decision the main thread would take. Both lints pass for these files. The findings below
are a missed wake-up (performance only), a bug-detector that nobody sees, and coupling to
document.

## Findings, most severe first

### F1 (Low, performance): a waiting spawn does not wake on a published bound

- **Where:** `efp_sim_batch.gd:150` (`if done == seen: ... continue`), against the publication
  at `:116-119`.
- **Evidence (READ):** `admit` recomputes only when `done` changes, which happens only when an
  effect finishes. `_step` publishes `least[i]` / `most[i]` without touching `done`. Suppose
  effect i first evaluates while an earlier claimed effect j still holds `run()`'s defaults
  (`-c`, `MAX_PARTICLES - c`, at `:235-236`). For example, j's thread was descheduled between
  `_claim` and the publish. Then i sleeps until some effect finishes, even when j's real
  bounds, published a moment later, would have decided the spawn. Correctness and liveness are
  unaffected: a finish always comes, because the smallest unfinished effect never waits.
- **Fix:** keep a `ver` counter under the mutex. Bump it in both the publish block and the finish
  block, and compare `seen` against `ver` instead of `done`.

### F2 (Low, robustness): a bound miss is counted but silent

- **Where:** `efp_sim_batch.gd:126-127` (`misses += 1`). It is surfaced only through
  `EfpSimBatch.last` and the tests.
- **Evidence (READ):** a miss in the unsafe direction (a real change above the published `most`,
  or below `least`) gives a later effect's `admit` a wrong sure limit. That silently breaks
  equality with the main thread, and it can overshoot the cap by the miss. In a player's build
  nothing reports it: FrameSplit is off, and the suites use synthetic templates plus the probe's
  files. `growth_bounds` is sound today (see "growth_bounds" below). The risk is a later change
  to `emit_spawns` or to the death paths that is not mirrored in it.
- **Fix:** in `run()`, after `work_and_wait`, `push_warning` once per session when `j.misses > 0`
  (on the main thread, so it is cheap and safe).

### F3 (Info): growth_bounds mirrors three other functions; say so where they live

- **Where:** `efp_sim.gd:627-679` copies `emit_spawns`' timing tests (`:973-999`). It relies on
  `p.dying` being set only in `step()`'s aging (`:813-818`, where `_dying_n` / `Emitter.dying`
  are counted). It also relies on `clear()` never running inside `advance()`.
- **Evidence (READ):** all three hold today. `p.dying` has one writer. `clear()` / `restart()`
  are called only from the main thread outside the batch: `EfpEffect.stop`, `_exit_tree`,
  `step_post`, and EquipFx `:319`. Nothing outside `efp_sim.gd` edits a sim's particles or
  emitters (the one hit is `equip_fx_turn_test.gd:173`, a test). But `emit_spawns`' doc names
  only `efp_keep_test` as its check, not `growth_bounds`.
- **Fix:** one line at `emit_spawns` and at the `p.dying = true` site: "mirrored in
  growth_bounds; efp_sim_batch_test._bounds holds them together".

### F4 (Info, not this round): `reap_all`'s plain wait

`efp_sim_batch.gd:265` is unchanged since round 760 and is marked `pool-wait: resource-free`. The
helper itself is data-only. The wait completes once the pool schedules any helper not yet
started, which at World exit (`World3D.gd:6404`) comes after the skill-table, name-key and
template waits through PoolWait. No new exposure in round 761.

## Deadlock and livelock (READ)

- **Claim order.** `_claim` (`:98-106`) hands out indexes 0, 1, 2, ... under the mutex, so the
  claimed set is always a prefix. A thread steps one effect at a time and can block only in
  `admit` (`:144-173`), which depends only on effects with lower indexes. Those are all claimed,
  and each is held by a thread that is running it or is itself waiting on still-lower indexes.
  The wait graph points strictly downward, so it has no cycle.
- **The smallest unfinished effect m never waits.** All j < m are finished. `_step`'s prefix walk
  (`:128-130`, under the mutex, run by whichever of them finished last) has set
  `prefix_n == m`, so `range(prefix_n, m)` is empty, `lo == hi == prefix_base == base_m`, and
  `sure = (limit - base_m, limit - base_m)` decides every d. A waiter that went to sleep before m
  became smallest re-evaluates, because the finish that made it smallest bumped `done` after its
  `seen` was read under the same lock.
- **A starved or small pool (`max_threads` 1-4).** If no helper ever starts, the main thread
  claims 0..n-1 in turn, each finished before the next is claimed, so every `admit` is exact and
  returns on its first look. With one pool thread, the other `helpers - 1` tasks run after the
  first returns, find `next == n` and return at once. A helper that starts after the batch only
  touches `_claim`. `_pending` keeps the Job alive for it, since a Callable holds an ObjectID,
  not a reference. Nothing a helper runs yields back to the pool: no pool wait, no
  RenderingServer call, so no cooperative re-entry. The waits are `OS.delay_usec` sleeps, which
  give up the core.
- **Main-thread waits.** The main thread waits in two places, `admit` (when it steps an effect)
  and `work_and_wait`'s tail (`:191-197`). Both are mutex-polled sleeps on helpers that run
  `EfpSim.advance` only (`efp_effect.gd:840-843`). They are not WorkerThreadPool waits, so the
  PoolWait lint does not apply, and they cannot meet a queued RenderingServer call. The two
  WorkerThreadPool waits in the file (`:257` on completed groups, `:265`) carry `pool-wait:`
  reasons.
- **Shutdown or zone change mid-batch** cannot happen: `run` is synchronous on the main thread,
  and every `end_deferred` runs before it returns (`:242-243`). The World's exit runs on the main
  thread between frames and calls `reap_all`.
- **A script error in a helper** would print, return from the erroring function and let `_step`
  carry on. The mutex-held sections index only within `[0, n)`.

## Memory visibility (READ)

- Written before `add_group_task`, read-only afterwards, and published by the pool's own
  posting synchronisation: `limits`, `n`, `delta`, `effects`, the initial `least` / `most` /
  `fin` / `change` / `prefix_base`, and every sim's `begin_deferred` state. `limits[i]` at
  `:145` is the only Job read outside the lock, and it is one of these.
- Under `mutex`: every write of `least`, `most`, `fin`, `change`, `prefix_n`, `prefix_base`,
  `done`, `by_helpers`, `misses`, `waits`, `wait_usec`, `bounds_usec`, `sim_usec`, and every
  read of them in `admit` and `work_and_wait`. The Packed arrays are written in place through
  the member. Even if a copy-on-write happened, it would happen under the lock.
- A sim's own state (`_live_delta`, `particles`, `emitters`, `_acc`) is touched by one thread
  per batch. The hand-offs are ordered by the mutex: a helper's unlock after `done += 1`, then
  the main thread's locked read of `done` before `end_deferred`, then the next frame's posting.
- The shared statics `interval_mul`, `threshold`, `cap_total` and `live_total` are not written
  during a batch. A deferred sim never reads or writes `live_total` (`_live_add`, `can_spawn`'s
  deferred branch). Templates are read-only.

No data race found.

## growth_bounds against the step (READ)

The cap logic needs `least <= change <= most`, where change = `_live_delta` = the change in
`particles.size()`. `_live_add` is called only by `_spawn` (+1) and `_on_death` (-1) during an
advance.

- **steps:** the same `maxf(delta, 0)` accumulation and loop as `advance()`. `step_sim` passes
  the batch's delta unchanged.
- **least:** with one step, only the flush at its start kills, and it kills exactly the
  `p.dying` particles. Their count is `_dying_n`, incremented only at `:815-818` and reset only
  in `_flush_deaths` and `clear()`. A death queued in the step goes at the next one. With more
  steps, `-c` is the floor, since the final count is at least 0.
- **most, the first step:**
  - Emitters whose owner is dying are dropped by the flush and skipped.
  - The owner's age is unchanged until the aging after emission, because no command writes
    `age`.
  - The `i32` and interval tests match `emit_spawns`.
  - With `ftol` truncating, the per-emitter count `ftol(nxt) - ftol(acc')` is at most
    `e_max - trunc(max(acc - e.dying, 0))`. The flush's give-backs are exact in double, because
    an f32 value minus an integer below 2^24 stays exact. The count is also at most
    `ftol(e_per) + 2`.
  - `threshold` only halves the cap, so `e_max` still bounds it.
  - Non-firing cases (`e_per <= 0`, `e_max <= 0`, NaN or inf) give 0, or `FAN_MAX` for the
    out-of-range values.
  - Newborns' child emitters fire in the same frame through the growing emission loop. Their
    count is bounded by `kids` (preorder holds: `_compile_node` appends a child after its parent,
    `:513`).
- **most, the later steps:** every surviving emitter adds up to `fan`, and every particle
  spawned so far adds up to `fan_child`. Net change = spawns - deaths, with deaths at least
  `_dying_n`. The `MAX_PARTICLES - c` ceiling holds because `can_spawn` refuses at
  `MAX_PARTICLES` first.
- **admit's composition:** `lo` adds `least`. `hi = min(hi + most_j, max(hi, limit_j))` is
  sound, because a spawn of j is taken only when `base_j + d < limit_j`, so j can lift
  live_total to its limit but not past it. A take below `limit - hi` is therefore a main-thread
  take, and a refusal at or above `limit - lo` a main-thread refusal. The cached
  `_sure_below` / `_sure_from` stay valid for the whole advance, because `base_i` is fixed.

## Lints (READ, the lints' logic run in Python over the `d42cfec9` tree; Godot was not run)

- **PoolWait lint:** 0 bare `wait_for_task_completion(` / `wait_for_group_task_completion(` in
  `scripts/` and `tools/` (non-suite).
- **const-array lint:** `efp_sim.gd` and `efp_sim_batch.gd` declare no `const` Array or
  Array-holding Dictionary (the new `FAN_MAX` is an int). Across all non-suite scripts, nothing
  reads `efp_reader.gd`'s `VALUE_TYPES` / `CONTROLLERS` or `efp_effect.gd`'s `LINK_MODES` element
  by element. Both files are in `WORKER_FILES`.
- The commit reports both suites passing on the box (r761.md section 4.4). Not re-run here.

## Not covered

- No run with a small pool. Deadlock freedom at `max_threads` 1-2 is argued above, not
  measured. `efp_sim_batch_test` uses the project's default pool (the box's 28 threads), because
  `project.godot` sets no `max_threads`. One headless `efp_sim_batch_test` with `override.cfg`
  `threading/worker_pool/max_threads=1` and then `=2` on a quiet box would close it cheaply.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
