# Round 760 review: the client on Godot 4.7.2

An independent adversarial review of `efca7b14` (branch `worktree-agent-a8ac26415e51de746`: the
spike `083f1370`, round 759 `d2e61a2a` and dev `0dd4a583` merged). The question was what could break
play, crash, or ship wrong once this is every player's client. No code was changed.

Labels as in r760.md: **READ** (our code, or Godot's source at 4.7.2-stable / 4.2.2-stable),
**MEASURED** (the render box, 192.168.10.78, `RENDER_DIR=/opt/opensro-client-r760rev`,
`GODOT_LOCK=/var/tmp/r760rev/lock`), **INFERRED**.

## Verdict

**Ship it for Forward+ players once F1 is fixed, F2 is in the release notes, and F3's dry run is
done.** The Forward+ path is sound: the update from v0.1.513 works end to end, the gates pass and
the frame is twice as fast. The user's RTX 5080 test of a 4,000-player crowd is the first Windows
evidence, and it agrees. F1 is the one crash path the round left open for real players, and the fix
is about ten lines.

## Findings, most severe first

### F1 (High): an existing Compatibility install starts its first post-update session on the separate render thread

- **Where:** `client/scripts/setting/renderer_choice.gd:178-181`, the new "choice recorded before
  the thread key" block. It also covers Godot's own GL fall-back (r760 section 13, item 2).
- **Evidence (MEASURED, a real update).** The real v0.1.513 Linux release zip (4.2.2) was installed
  with the `override.cfg` that 4.2.2's RendererChoice writes (`renderer/rendering_method=
  "gl_compatibility"`, no thread key) and started on Xvfb, with `OPENSRO_QA_UPDATE_URL` pointing at a
  local release of this head (re-exported as `v0.1.514`). The update installed and relaunched, and
  the new client logged:
  `RENDERER: running=gl_compatibility ... chosen=gl_compatibility render_thread=separate -> recorded
  gl_compatibility for the next start`.
  So the session the updater relaunches into runs Compatibility on `thread_model=2`. The project
  setting is read in `Main::setup` before any script runs, so the record only helps the start after
  that one. Round 760 measured that configuration crashing 3 of 5 swarm boots at 3,000 players
  (`FATAL: Index p_index = 0 ...`, signal 4). The players who run Compatibility are the ones with
  the weakest GPUs, and the relaunch takes them straight into the game.
- **The same hole, other routes.**
  - Godot's `fallback_to_opengl3` (READ `display_server_windows.cpp` l. 8130-8143). On Windows this
    needs Vulkan device creation *and* the D3D12 fall-back (on by default, l. 8031-8053) to fail
    after our probe found a device. That is rare. On the Steam Machine's RADV it is effectively nil.
  - A GL start with the DLL quarantined by antivirus (no probe, so no `--render-thread safe`) and
    no Vulkan. This is plausible, and 4.2.2 used to stop there with an error instead.
- **Fix (cheap).** In `apply_at_boot` (Boot.gd:25 calls it before any world loads): when
  `applies_here()`, `running() == COMPATIBILITY` and `FrameSplit.render_threaded()`, record the
  choice as now and restart once. Use `OS.set_restart_on_exit(true, ["--rendering-driver",
  "opengl3", "--render-thread", "safe"] + OS.get_cmdline_args())` and `get_tree().quit()`, guarded
  by an env marker so it cannot loop. That closes the post-update session, both GL fall-backs and a
  read-only install folder in one place. To test it, run the box's update recipe below and expect
  `render_thread=main` in the relaunched client.

### F2 (Medium): 4.7.2 cannot start on Windows 7/8 or on x86-64 CPUs without SSE4.2, and the auto-updater will install it there anyway

- **Evidence (READ, 4.7.2-stable).**
  - `SConstruct` l. 796-805 builds x86_64 with `-msse4.2 -mpopcnt` (MSVC `/d2archSSE42`). Its
    comment: "CPUs released after 2009-2011 (Intel Nehalem, AMD Bulldozer)", so every AMD
    Phenom/Athlon II is out.
  - `platform/windows/detect.py` l. 421-422 sets `_WIN32_WINNT=0x0A00` (Windows 10).
  - Linux at least shows a dialog (`godot_linuxbsd.cpp` l. 76). Windows has no check, so the result
    is an illegal-instruction crash or a missing-entry-point error at load.
  - Round 754 noted this (section 9, risk 11). Round 760 does not mention it, and neither does the
    README.
- **Why it matters.** v0.1.513's updater (unchanged, and it is the code that runs the update)
  installs whatever `releases/latest` is, then relaunches. On such a machine the new exe never
  starts. `UpdateInstaller.cleanup()` only runs in the new client, so `OpenSRO.exe.old-update` /
  `.pck.old-update` / the DLL's aside stay on disk. The player is stranded until they rename them
  back by hand (`docs/NATIVE_ON_WINDOWS.md` has the steps).
- **Fix.**
  - At least: state the new floor (Windows 10+, a CPU with SSE4.2) in the tag message (the release
    body) and the README, with the rename-back recovery.
  - Better, if the user wants it: a bridging 4.2.2 release (v0.1.514) whose updater refuses an
    update whose tag message carries a marker when `OS.get_version()` < 10 on Windows, or when the
    CPU lacks SSE4.2 (the native library can answer with `is_x86_feature_detected!("sse4.2")`). Then
    ship 4.7.2 as the next tag. Players who skip the bridge are not covered.

### F3 (Low-Medium): CI and the release on 4.7.2 have never run on the runner

- **Evidence (READ).** r760 section 10: "The CI changes take effect when the branch is merged and
  pushed". Round 754 section 9 calls them "drafted, not enabled". The workflows themselves look
  right:
  - `setup-godot@v2` `version: 4.7.2` in all three jobs, with `include-templates` for the release;
  - `export_presets.cfg` uses 4.7's `s3tc_bptc` / `etc2_astc` keys;
  - the native job builds api-4-7 with `--locked`;
  - `check_release_zip.sh` checks the engine against the floor and the notices.
  
  The release path itself is the risk: a setup-godot asset URL, the template folder, or a
  first-import difference on the runner would surface at the tag.
- **Fix.** After merging to dev, run `release.yml` by `workflow_dispatch`. It keeps both zips 3
  days. Run `check_release_zip.sh` on the Windows one before pushing the tag.

### F4 (Low): PoolWait spins for ever on a task id that was already waited for

- **Where:** `client/scripts/pool_wait.gd:44-46` and `:53-55`.
- **Evidence (READ).** 4.7.2 `WorkerThreadPool::is_task_completed` returns `false` with "Invalid
  Task ID" for an unknown id (`worker_thread_pool.cpp` l. 393-398; groups l. 718-723). The plain
  `wait_for_task_completion` returned `ERR_INVALID_PARAMETER` at once (l. 403-409). A double wait
  used to cost one error line. Through PoolWait it is a main-thread hang with an error line every
  100 µs.
- **Every one of the 35 call sites** (scripts and tools) resets its id or erases its entry right
  after the wait, so this is latent, not live. I checked CharTables, ItemTableReader, SkillEffects,
  SkillAudio, TitleIntro, SkillBuffCatalog, MonsterDraw, MusicDirector, EfpEffect.wait_preloads,
  HudPanels, CharacterAppearance and ShutdownRelease.
- **Fix.** Bound the damage: after (say) 30 s of polling, log once and fall through to the plain
  wait, which returns at once for an unknown id. Or extend the lint to require the id's reset on the
  next line.

### F5 (Low, efficiency): PoolWait forces a full render-thread sync every 100 µs under the separate thread

- **Evidence (READ).** `RenderingServerDefault::sync()` with a render thread is
  `command_queue.sync()`, a `push_and_sync` that waits for the pump to drain the queue, a whole
  frame's draw included (`rendering_server_default.cpp` l. 435-441, `command_queue_mt.h` l.
  136-148, 216-224). The engine's own main-thread wait skips this when rendering is threaded:
  `ResourceLoader::_ensure_load_progress` returns early "Not needed" (`resource_loader.cpp` l.
  1157-1163). Round 760's probe also had the plain wait finish 2 of 2 on the separate thread.
- **Cost.** Wasted render-thread round trips only during blocking waits (entry, zone change,
  teardown). Not a correctness bug.
- **Fix (optional).** Under `FrameSplit.render_threaded()`, PoolWait can do the plain wait.

## The checks, one by one

1. **CI, release, native library, updater.**
   - Workflows: see F3.
   - `compatibility_minimum = 4.7` with godot-rust `api-4-7`. The release `.so` built here with zig
     at the 2.28 floor, `--locked`, and `check_native_library.sh` passed it.
   - `check_release_zip.sh`'s new engine/floor and notices checks are sound: they read
     `4.7.2.stable.official` from the exe and use `sort -V` against the floor.
   - **The update path (MEASURED, above).** The real v0.1.513 zip updated to this head:
     - the download was verified, and README, notices, launcher, `libopensro_native.so`, the exe
       and the `.pck` were installed;
     - the relaunch came up on 4.7.2 with `native readers ON` and printed the summary;
     - asides were removed;
     - `override.cfg` gained `driver/threads/thread_model=1` (for the *next* start, F1);
     - a 4.2.2-era `settings.cfg` was read back unchanged.
     
     A 4.2.2 exe with the new DLL cannot happen: a failed exe or `.pck` install rolls every file
     back (`update_installer.gd` l. 98-101). The old DLL with the new exe is api-4-2 on a 4.7 engine,
     which is forward-compatible.
2. **The separate render thread.**
   - Forward+ ships it. The Compatibility routes we control (launchers, native probe restart,
     Options, config.yaml, the boot-time thread key) are covered.
   - The route that is not covered is the first session after an update for Compatibility players,
     plus Godot's own GL fall-back: F1, with the guard.
   - Likelihood of Godot's fall-back: low on Windows (both Vulkan and D3D12 must fail after the
     probe), nil on the Steam Machine (RADV, the same driver family as the box's).
   - The D3D12 fall-back on Windows (Vulkan fails, D3D12 works) runs Forward+ on D3D12 with the
     separate thread. That was never run here; INFERRED to be rare.
3. **PoolWait.**
   - Re-entrancy: `flush_all` / `sync` run only RenderingServer commands that workers queued, the
     same ones the main thread's next RS call would run. No GDScript runs in them: the client uses
     no `call_on_render_thread` and does not wait inside the `frame_*` signals. So nothing re-enters
     game code mid-wait.
   - Coverage: the lint catches every `wait_for_task_completion` / `wait_for_group_task_completion`
     in `scripts/` and `tools/`. The 4 allowed bare waits (HeightBatch, EfpSimBatch) step data only.
     EfpSim's `step_sim` is pure, and EfpEffect's `_mutex` sections hold dictionary operations only,
     never an RS call.
   - The one other main-thread block, `ResourceLoader.load_threaded_get` (FrontEndBackdrop), is
     served by the engine itself (`resource_loader.cpp` l. 952-978).
   - The lint does not see Mutex waits or busy loops. None were found that hold across a synchronous
     RS call.
   - See F4 and F5.
4. **TextDecode.**
   - All 9 `get_string_from_utf16` occurrences outside suites are TextDecode's own call, the probe's
     negative, or comments. The lint holds this.
   - The other decoders cannot produce an out-of-range codepoint in 4.7.2:
     - UTF-8 maps invalid and >0x10FFFF to U+FFFD (`ustring.cpp` l. 1784-1906);
     - `get_string_from_ascii` widens bytes as Latin-1 up to the first NUL (`variant_call.cpp`
       l. 683-694);
     - the one `get_string_from_utf32` (`sound_table.gd:170`) writes bytes 0-255 only;
     - `String.chr` takes bytes.
   - Native: Rust hands back valid UTF-8 only, and `char::from_u32` failing is a Fallback to
     GDScript (`tables.rs` l. 369).
   - The safe-bytes logic is correct for BOM, byte swap and pairing.
5. **Workarounds.**
   - The RetailBloom anchor removal: the box test passed per r760.
   - The static-lambda lint: safe on 4.7.2.
   - The `rstrip(char(0))` removals keep 4.2.2's actual behaviour.
   - Kept, and still right: the const-array lint, the in-place attaching, the material-RID sort,
     `vk_fallback.rs`, WorldFog, and `KeyInput.line_edit_as_42`, which is on all 8 `LineEdit.new()`
     sites. The scene's LineEdits are the no-Media fallback UI.
   - The cloud dome's `far_clip_z` has one user and it is set (`World3D.gd:4275`).
   - `CrowdGpu.half_custom` asks the running method, so the launcher and fall-back starts are
     detected too.
6. **Settings migration.**
   - Everything in `user://` is ConfigFile text: `settings.cfg`, `quickslots.cfg`.
   - Key bindings are not stored (Keymap is fixed).
   - Shader and pipeline caches are keyed by the engine. The `user://` folder name ("OpenSRO") is
     unchanged.
   - Nothing is in a 4.2-only format. The `settings.cfg` read-back was MEASURED (above).
   - `npcpos.txt`'s `E` exponents now parse as floats (4.7.2's `is_valid_float`, mirrored in
     `tables.rs`). This is a small, correct data change, not a regression.

## Gates (MEASURED, this head, 4.7.2)

- `remote_godot.sh check`: "checked 694 scripts and 9 scenes, ALL LOAD".
- `remote_godot.sh tests`: "ran 266 suite(s), 0 failing".
- `perf_gate.sh --base d2e61a2a --sites jangan --frames 40000`, base on 4.2.2, head on 4.7.2 (the
  base used 3 cached runs, checked fresh at 1.56 ms), rc 0:
  ```
  jangan  frame ms   base 1.56  head 0.75  (-0.8)  FASTER
  jangan  entry ms   base 9041.00  head 8419  (-622.0)  SAME
  jangan  freeze ms  base 2855.00  head 2651  (-204.0)  SAME
  jangan  hitches    base 5.00  head 5  (+0.0)  SAME
  ```
- The Linux export, built the release way: the release `.so` (zig, glibc 2.28), import,
  `check_scripts` ALL LOAD, `print_godot_licenses` ("GODOT ENGINE 4.7.2-stable (official)"),
  `--export-release Linux` on the 4.7.2 templates, `third_party_notice.sh`, the launcher. The
  in-client docs bundle was skipped. `check_release_zip.sh dist/opensro-linux.zip linux --run`:
  "engine: Godot 4.7.2; the library's floor: 4.7", `native readers ON` as shipped, `OFF` with the
  library renamed, **ok**.
- The update path: v0.1.513 (the GitHub release zip) to this head, on Xvfb: installed, relaunched,
  rc 0 (F1's log line is from this run).
- Not run: the Windows export (the user's own build covers it), `renderer_fallback_box_test.sh`,
  `retail_bloom_box_test.sh` and the crowd tables (r760's own numbers stand; this review read the
  code instead).
