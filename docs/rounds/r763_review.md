# Round 763 review: EquipFx's effect masters in Rust

An adversarial review of `cd452cb6` and `685942ff` (branch `worktree-agent-a8fedb344a96ccfe8`,
based on dev `b52bc9dc`), with crash safety as the focus. The reviewer fixed no code. Labels:
**READ** (the code; Godot 4.7.2-stable's source), **MEASURED** (this host, 16 cores, or the
builds made here), **PROBE** (a temporary test added to the crate, run and then reverted with
`git checkout`; nothing of it is committed).

## Verdict

**Ship, with M1 fixed first or straight after.** The Rust is free of `unsafe`. Everything
indexed from a template is validated before it is used. Every RenderingServer call is on the
main thread and is checked by the engine. With no library, or a library older than round 763,
the client falls back cleanly. No path from real or malformed `.efp` data to a panic was
found. The one serious problem is what a panic would do if one ever happened. A panic on a pool
thread freezes the game for good: there is no crash, no error, and quitting hangs too. A panic
on the main thread poisons that effect for the rest of the session. This is insurance against a
future bug, not a live crash, so it is Medium. The rest is Low or Info.

## Findings, most severe first

### M1 (Medium): a panic in the batch hangs the game, or poisons the effect for good

- **Where:** `native/src/core/efp_batch.rs:253-259` (the caller waits while `st.done < n`),
  `:128-172` (`step`), `:187-193` (`Helper::help`), and `native/src/core/pool.rs:131-133`
  (`worker` runs `j.help()` with no `catch_unwind`).
- **What happens:** a panic inside `Job::step` on a pool thread unwinds out of that thread. The
  effect it claimed never sets `fin` or `done`, so the main thread waits forever in `run`.
  gdext's `catch_unwind` covers only the `#[func]` boundary (godot-core 0.5.5 `private.rs:445`),
  not the pool threads.
  - The game freezes with no error and no crash dialog.
  - Quitting then hangs as well, because `on_stage_deinit(Scene)` joins the helpers
    (`gd.rs:46-49`) and the dead one's peers may be stuck in `admit`.
  - A panic on the main thread inside `run` is caught by gdext. But the effect's
    `Mutex<SimBox>` is left poisoned, so every later `lock().unwrap()` on it panics again
    (`gd_efp.rs:251, 316`, `efp_batch.rs:129, 215, 262`).
  - That repeats every frame. `run_batch` then assigns Nil to its typed `Dictionary`
    (`efp_sim_native.gd:432`), and `_step_masters` aborts before `step_post`. EquipFx's draws
    freeze, with script-error spam.
  - Any helper waiting in `admit` (`efp_batch.rs:122-124`) stays there for good. Under the
    shipped unbounded limit nothing waits; under a QA cap, threads would.
- **Evidence (PROBE):** a 16-sim batch, 3 helpers, sim 15 given an out-of-range child index
  (built directly, bypassing `unpack`):
  ```
  thread 'opensro-efp-2' panicked at src/core/efp_sim.rs:821:28
  trial 0: caller still waiting after 3 s
  REVIEW PROBE: hung 1, caller panics (caught) 0
  ```
- **How likely:** low. `unpack` (`gd_efp.rs:105-211`) checks every length, range, node index,
  command kind and life value, and nothing reachable from real data panics (see I4). But a
  freeze with no trace is the worst failure a client can have. It would come from the first
  logic bug or slice error that a later round adds to `efp_sim.rs` or `efp_out.rs`.
- **Fix:**
  - Wrap each `step(i)` in `catch_unwind(AssertUnwindSafe(..))`, both in `Helper::help` and in
    the caller's loop. On a panic, still set `fin[i]`, `done += 1` and `ver += 1`, set a
    `failed` flag, and call `notify_all`.
  - Have `SrEfpBatch.run` return `{"error": ...}`. GDScript then turns the native simulation off
    (`EfpSimNative._available = false`) and lets new masters fall back to `EfpSim`.
  - Lock the per-effect mutexes with `unwrap_or_else(PoisonError::into_inner)`, plus a "broken"
    flag that makes the effect a no-op. Do the same in `pool.rs` and in `JobState`.
  - Also wrap `worker`'s `j.help()`, so a pool thread never dies silently while `target` still
    counts it.

### L1 (Low): a sim listed twice in one batch can deadlock the ordered admission

- **Where:** `efp_batch.rs:128-129` and `:94-125`.
- **What happens:** suppose the same `SrEfpSim` sits at indices j < i.
  1. The thread stepping i holds that sim's mutex and waits in `admit` for j.
  2. The thread that claimed j is blocked on the same mutex.
  3. The main thread then waits forever.
- **When:** only when a spawn is undecided, which means a binding limit (`OPENSRO_QA_EFP_CAP`).
  EquipFx lists each master once (one per `_kinds` key, `equip_fx.gd:653-659`), so this does not
  happen today.
- **Fix:** in `SrEfpBatch.run`, reject or deduplicate repeated sims (`Arc::ptr_eq`) and return
  `{}`.

### L2 (Low): pool helpers can be preempted while the main thread waits for them

- **What happens:** the pool's three helpers compete with Godot's WorkerThreadPool, which has
  `max_threads` = cores by default and stays busy while regions load. A helper that has claimed
  an effect and is then descheduled holds up the main thread until it runs again.
- **Evidence (PROBE, release build, 60 synthetic effects, 2,700 batches each):**

  | load | helpers | p50 ms | p99 ms | max ms |
  |---|---|---|---|---|
  | idle | 0 | 0.098 | 0.203 | 0.237 |
  | idle | 3 | 0.048 | 0.080 | 0.352 |
  | 16 spinning threads on 16 cores | 0 | 0.164 | 0.278 | 0.318 |
  | 16 spinning threads on 16 cores | 3 | 0.174 | 0.336 | **4.012** |

  This was Linux CFS. Windows schedules in coarser slices.
- **What the pool buys:** about 0.2 ms by the round's own numbers. The batch alone went
  0.536 to 0.313 ms at 74 effects (r763 section 3.1). In the swarm, the masters cost 0.55-0.56
  ms on 1 thread against 0.48-0.53 on 4 (r763 section 3.2: "One core is enough").
- **Fix (a judgement call):** default `DEFAULT_THREADS` to 2, or to 1 (the main thread alone).
  Alternatively, run inline when `n` is small or the previous batch took under about 0.3 ms.
  `OPENSRO_EFP_THREADS` stays as the knob.

### L3 (Low): malformed `.efp` emission counts can stall a step for seconds, but do not crash

- **Where:** `efp_sim.rs:827-830` (`for _ in 0..n { spawn }`), `:856-867` and `:871-874`.
- **What happens:** a corrupt node with huge `e_max` and `e_per` (say 1e9) makes `emit_spawns`
  return up to about 2^31.
  - Once `MAX_PARTICLES` is reached, each spawn is refused cheaply, but the loop still runs n
    times on every emission frame. That is about 1 s of CPU per step, up to 10 steps per
    advance.
  - The GDScript fallback has the same loop and is far slower.
  - The data comes from the user's own archives, so this is a soft hang, not a crash.
- **Fix:** once `can_spawn` refuses because of `list.len() >= MAX_PARTICLES`, fold the rest of
  the refusals: `dropped += rest; acc = max(acc - rest, 0.0)`. This gives the same state exactly,
  since integer subtraction from an f32-valued f64 is exact below 2^53. Make the same change in
  `efp_sim.gd` to keep parity.

### L4 (Low): `tt % interval` divides by zero if `interval_mul > 1`

- **Where:** `efp_sim.rs:558-564` and `:847-853`.
- **What happens:** `i32w(e_int * interval_mul)` can wrap to 0 (for example `e_int` = 2^30 with
  a multiplier of 4) and is then used as `interval`. `% 0` panics, which leads into M1.
- **When:** `EfpSim.interval_mul` is 0 in shipping (`efp_sim.gd:247`); only `efp_keep_test`
  sets it. The GDScript would raise a script error on the same input.
- **Fix:** `if interval <= 0 { continue / return 0 }` after the multiplied value is taken.

### L5 (Low): a mixed batch steps native sims from WorkerThreadPool threads

- **Where:** `efp_sim_batch.gd:220-223` and `efp_sim_native.gd:212-218, 398-405`.
- **What happens:** suppose one master's template is refused by the packer
  (`pack_template` / `SrEfpTemplate.build` returns an error), so `use_native_sim` keeps it as
  `EfpSim`. Then `all_native` is false and the whole list goes to the GDScript Job on
  WorkerThreadPool.
  - The native masters are then advanced through gdext calls from pool threads.
  - `EfpSimNative.live_native += r[1]`, a GDScript static, is updated from several threads at
    once, so updates are lost. That is harmless while uncapped, but the stat drifts.
  - The draws are rebuilt on the main thread, and the batch's speed-up is lost.
- **Crash risk:** none found. The library is built with `experimental-threads` and each sim has
  its own mutex.
- **Testing:** this path has no test. All 74 real files packed, so it is not reached today.
- **Fix:** split the list. Send the native sims to `run_batch` and the rest to the Job, or make
  `use_native_sim` all-or-nothing per EquipFx.

### L6 (Low): the pool keeps the last job, and with it every sim of that batch, alive

- **Where:** `pool.rs:95`. `st.job` is never cleared.
- **What happens:** after a world exit, the last batch's `SimBox`es (particles, draw buffers)
  stay alive until the next threaded batch. This is a few MB at most.
- **Fix:** clear `st.job` once `taken == want`, or at the end of `run`.

### I1 (Info): uncapped growth already has a hard ceiling

- **The per-effect cap remains.** The user's decision removed the *global* cap (`UNBOUNDED` =
  2^30, `efp_sim_native.gd:57`). The per-effect `MAX_PARTICLES` = 300 still holds
  (`efp_sim.rs:31, 872`). The round's 74-file run counted 108 spawns refused by it.
- **Only EquipFx masters are native,** and there is one per distinct `.efp` path
  (`kind_key` = `efp.to_lower()`, `equip_fx.gd:411`), reaped when idle (`:1076-1082`).
  Thousands of players with effects do not mean thousands of native sims.
- **The resulting bound:**
  - Native particles are at most (distinct EquipFx files) x 300. For 74 files that is 22,200 in
    theory; 4,195 was measured.
  - A particle is about 330 bytes.
  - The arena holds the list plus dead ancestors, so at most the list times the tree depth.
  - A draw node's buffer is at most 512 x 80 bytes, because the instance count only doubles past
    300.
  - In the worst case that is about 10 MB. `Vec` growth stalls and allocation failure are not a
    concern.
- **No further ceiling is needed now.** If OPEN 6 lands (skills, auras and world effects made
  native, which makes the sim count per player), add a global native ceiling well above normal
  use, for example 20,000 particles (about 5x the 74-file measurement).
- **Wording:** the round's text should say "no global cap; the per-effect 300 remains".

### I2 (Info): Windows `sin`/`cos`, and the build

- **The two platforms use different maths (MEASURED, builds made here):**
  - Linux: the `.so` imports glibc's `sincos@GLIBC_2.2.5`. LLVM merges `sin` and `cos` into
    `sincos`; glibc's `sincos` gives the same results as its `sin` and `cos`. The parity runs
    agree.
  - Windows: the DLL (`x86_64-pc-windows-gnu`, as `release.yml:89` builds it) links
    mingw-w64's `sincos` statically. The disassembly shows x87 `fsincos`, with an `fprem1`
    reduction loop. It is neither msvcrt's `sin` nor the engine's.
- **Consequence:** last-place f64 differences in `cone` (`efp_sim.rs:987-993`) are possible
  against a Windows engine's GDScript `sin`/`cos`. Narrowed to f32, they would rarely show.
- **Why it does not matter:**
  - The particles are cosmetic and are never sent over the network.
  - The native simulation and the fallback never simulate the same master side by side.
  - x87 on huge or NaN arguments terminates (the loop is bounded) and gives NaN, not a trap.
- **Recommendation:** accept it, and state the parity claim as Linux-only (r763 OPEN 3 already
  does). Do not swap libm: that would break the Linux parity that is measured.
- **Build:**
  - The Windows build uses MinGW, not MSVC; CI has no MSVC leg.
  - The DLL builds here and imports only msvcrt, KERNEL32, ntdll, WS2_32, USERENV,
    bcryptprimitives and api-ms-win-core-synch. It contains `SrEfpBatch`.
  - With `panic = "unwind"` on windows-gnu, gdext's `catch_unwind` works.

### I3 (Info): the RenderingServer side is crash-safe

- **Rust slices:** `apply_draws` slices `buf[..cap * STRIDE]` (`gd_efp.rs:334`). `build_draws`
  always resizes each buffer to exactly `cap * STRIDE` (`efp_out.rs:155-165`), and `cap` changes
  nowhere else. `apply_draws` skips a node whose `told_cap != cap` (`:327-330`).
- **Engine checks (READ, Godot 4.7.2):** a size mismatch or a freed RID only prints an error.
  - `multimesh_set_buffer`: RD `mesh_storage.cpp:2108-2109`, GLES3 `:2028, :2042`, and the
    interpolated path `servers/rendering/storage/mesh_storage.cpp:237`.
  - `multimesh_set_visible_instances`: RD `:2189-2190`.
- **Format:** the MultiMesh is TRANSFORM_3D with colours and custom data, 20 floats an instance
  (`efp_effect.gd:255-257`). It is made once and never reassigned; the holders share it
  (`equip_fx.gd:570`).
- **Growth:** growing resets the visible count, and Rust re-sends it (`shown = -2`,
  `gd_efp.rs:302`).
- **Threads:** every RenderingServer call is on the main thread. Pool threads touch only plain
  Rust data: the job holds `Arc<Mutex<SimBox>>`, never a `Gd`.
- **Lifetime:** an effect cannot be freed while a batch runs, because the batch is synchronous
  on the main thread, and Rust holds `Arc`s in any case. The RIDs live in `SrEfpSim` and go
  with the effect.

### I4 (Info): validation, overflow and `unsafe`

- **`unsafe`:** none in the new Rust.
- **`unpack` (`gd_efp.rs:105-211`)** checks:
  - every array length against `n`, `nf` and `nc`;
  - every start/end range (a negative i32 cast to `usize` fails the range check);
  - every child index `< n`;
  - the command kind in `0..=17`;
  - life in `0..=2`;
  - `schedule.len() == frames.max(0)`.
- **Other inputs:**
  - `growth_bounds` reads `fan`, `rate` and `kids` only when `fan.len() == tpls.len()`, and the
    packer emits all three together.
  - Link-naming spaces return early when `link == NONE` (`efp_sim.rs:1040`).
  - `ancestor` with a negative or huge level stops at the root.
  - NaN or infinite `delta` and `e_per` are handled.
- **Overflow:** the release profile has no `overflow-checks`, so overflow wraps instead of
  panicking, and the values are i32-bounded anyway.

### I5 (Info): the fallback is safe

- **No library, or a pre-763 one:** `ClassDB.class_exists` on the three names fails
  (`efp_sim_native.gd:93`), the status line says OFF, and EquipFx's masters stay `EfpSim`.
- **API mismatch:** an `efp_api` mismatch also turns it OFF.
- **Scripts:** no script names a native type. `NATIVE_API` is unchanged at 5.

### I6 (Info): threads and shutdown

- **One thread:** a single core, or `OPENSRO_EFP_THREADS=1`, gives `threads` = 1 and
  `helpers` = 0. No pool thread is started and the batch runs inline.
- **Limits:** the thread count is clamped to the cores, and `set_helpers` clamps to 0..256.
- **Shutdown:** the deinit join runs from `Main::cleanup`, not from `DllMain`, so Windows has
  no loader-lock issue. Quitting hangs only in M1's case.
- **Zone change:** nothing is needed. The pool persists, and `_exit_tree` clears the masters and
  gives `live_native` back.
- **Deadlock:** none without a panic or a duplicate sim. The caller always works on the job
  itself, and the first unfinished effect never waits.

## Gates (this review)

- `cargo test --locked --no-default-features` in `native/`: **55 passed, 0 failed**.
- `cargo clippy --locked --all-targets`, with and without default features: no errors and no
  correctness lints. The new modules add 5 style warnings: `should_implement_trait` for
  `gdmath.rs` `add`/`sub`/`mul`/`neg` (lines 26, 30, 35, 45), and
  `manual_is_multiple_of` at `efp_links.rs:129`.
- `native/build.sh linux` and `cargo build --release --target x86_64-pc-windows-gnu`: both
  built.
- **Box `tests` (with and without the library): NOT RUN.** `remote_godot.sh tests` failed
  before any suite ran: `flock: cannot open lock file /var/tmp/r763rev/lock: Permission denied`.
  - The cause: the reviewer had created `/var/tmp/r763rev` as root, and the lock is taken as
    `ghidra`.
  - Changing the directory's owner was refused by the permission system. The empty directory
    was removed again (`/opt/opensro-client-r763rev` remains, owned by ghidra).
  - The round's own gates report 270 suites with 0 failing, both ways.
  - To run them: create the lock directory as `ghidra`, then run
    `RENDER_DIR=/opt/opensro-client-r763rev GODOT_LOCK=/var/tmp/r763rev/lock client/tools/remote_godot.sh tests`,
    and the same with `NO_NATIVE=1`.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
