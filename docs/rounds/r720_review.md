# Round 720 review: the teleport structures' glows and effects

This is an independent adversarial review of `dev..worktree-agent-a8d63e5fa3e4c3878` (head `27fa70f0`).
It was checked against:
- the client binary (`sro_client.exe`, md5 2a5794b72c90908d945be8b3f3f2edd4), through the asm
  `/var/tmp/sro_client.asm`, the decompile `/var/tmp/decomp_client` and the exe's own bytes (the
  doubles and floats);
- Data.pk2 (two probe scripts over every `.bsr` and over the gate models);
- the lane's frames (`/var/tmp/r720/live5/`);
- this review's own runs on the box: an instrumented copy (`/opt/opensro-client-r720rev`), two
  `qa_shot.sh` runs, `remote_godot.sh check` and `tests`, and one `perf_gate.sh --sites jangan
  --frames 12000`.

No code was changed. The instrumentation lived in the review's box copy and in one throwaway commit
(`099d8915`, never on a branch) that the perf gate shipped. Both are deleted.

**Verdict.** The reading of the particle mod, its placement and the glow pass's arithmetic is
right: the entry layout, mode 0 / mode 1, the rotation matrix, the 500 ms query, the bias of
(byte − 1.0), the trunc(ms × 1.5) fade, the ZENABLE-off draw and the (a × alpha) >> 8 scaling all
check out against the asm, the constants included. The effects draw where the lane says: the frames
gain light only, and only in a box around the gate.

Four things are wrong or missing:
- **The glow pass is the Light Effect video option.** It is not "always on". The setter the lane
  found "without a caller" is reached through a thunk from `SWorld::vslot_043` case 0xb, which this
  repo's own OPTION_VIDEO.md already names as Light Effect. Low and War presets turn it off, and the
  original then draws the glows as ordinary particles.
- **The occlusion ray answers "visible" for a point the original's query cannot see.** The test
  point is moved (byte − 1) toward the camera. When the camera is nearer than that, the point is
  behind the eye, D3D clips it, and the glow fades out. Constantinople's byte is 95, so the original
  hides that glow whenever the camera is within 94 units of it, which covers most of the square.
  The ray reports it visible.
- **"Ambient always plays" rests on the wrong evidence.** `FUN_00c7b540` tests a mod's dispatch word,
  not the set's kind, and the slot it calls on a particle mod is a bare `ret`. The set kind routes
  the runtime set into the palette's dedicated slot (`FxModManager` 0xc7fcea). Every particle slot is
  also gated by a LOD test the lane did not read.
- **Performance is recorded but not taken to the user.** The entry cost is the first effect's cold
  build plus a shader compile, about 240 ms in this review's instrumented run. Playing every
  object's `ambient` set, which is the faithful rule, doubles the Jangan frame time
  (1.53 → 2.97 ms, MEASURED).

## Findings, most severe first

### 1. BUG / WRONG-LABEL: the glow pass is the Light Effect option, not always on

- **Where:**
  - `client/scripts/world/ambient_particles.gd:23-27` (the claim) and `:157-162` (`make_glow`
    whenever `b50 != 0`);
  - `client/scripts/World3D.gd` `_ambient_step` (the pass runs whatever the option);
  - `docs/protocol/teleport_effects.md:57-58`;
  - `docs/rounds/r720.md:23`;
  - `docs/protocol/OPTION_VIDEO.md`, the Light Effect row ("kept, draws nothing").
- **Evidence (READ):**
  - `0xbc1230` writes `[ecx+0x1a4]`.
  - It is reached through the thunk `0xbbdad0` (`mov ecx,0x1112fb0 ; jmp 0xbc1230`), called from
    `SWorld::vslot_043` at `0xa19810`. The decompile shows it as `case 0xb: Map::FUN_00bbdad0(param_3)`.
  - OPTION_VIDEO.md (round 694, READ) maps case 0xb to the Light Effect row: "object renderer
    +0x1a4 (Sun / Torch, TTDESC_10)".
  - `0x1112fb0 + 0x1a4` is `DAT_01113154`, the very word `CRTModParticle::FUN_00c81450` (`0xc814df`)
    and `FUN_00c43100` (`0xc431e3`) test.
  - With it 0, `FUN_00c81450` takes the ordinary branch (`0xc814fe`: `vt+4` on the effect, drawn
    with the scene, depth-tested, full alpha), and nothing reaches the glow list.
  - `VideoOptions.PRESETS` (READ, 0x5015a0) has Light Effect 0 in Low and War, 1 in Middle and High.
  - The lane searched for direct calls of `0xbc1230`. This is the thunk trap the memory notes warn
    about.
- **Effect:** under Low or War, or with Light Effect Off, OpenSRO still runs the occlusion pass and
  draws every glow through walls. The original draws them as plain particles.
- **Fix:**
  - Gate the glow behaviour on `video_options().value(VideoOptions.LIGHT_EFFECT) == 1`.
  - Off: keep the effect's ordinary materials (no `make_glow`, or switch back to the source
    materials), alpha 255, no ray.
  - On: as now. React to the option live from `apply_video_options`, as the Lens Flare row does
    (World3D.gd:508).
  - Correct the three docs. OPTION_VIDEO.md's Light Effect row should say what it now drives.

### 2. DEPARTURE: a test point behind the camera (or off screen) counts as visible

- **Where:** `client/scripts/world/ambient_particles.gd:119-123` (`query_point`), `:178-185`
  (`update`), `:198-206` (`occluder`).
- **Evidence:**
  - READ: `FUN_00c43100` `0xc43212..0xc432f7` takes the eye from the inverted view matrix
    (`DAT_0111316c+0x30`). It forms `pos + (byte − 1.0) × normalize(eye − pos)`, with the 1.0 the
    double at `0xe1b7f0` (read from the exe: 1.0). It normalises in place through `0x410cd0`.
  - READ: `CVisibleChecker::vslot_002` (`0xc80d20`) sets the world transform to identity
    (`SetTransform(0x100)`), ZENABLE 1, ZWRITEENABLE 1 and COLORWRITEENABLE 0. It draws one
    `D3DPT_POINTLIST` point (FVF 0x42) between `Issue(BEGIN)` and `Issue(END)`, spins on `GetData`,
    and writes 1.0 when the pixel count is > 0, else 0.0.
  - D3D9 clips a point whose centre lies outside the view volume (D3DRS_CLIPPING defaults to TRUE).
    No `SetRenderState(0x88, …)` call was found (`push 0x88` is never followed by a call to the
    render-state wrapper `0x471360`). That is a negative from one pattern, so it is labelled
    INFERRED.
  - So when `byte − 1` exceeds the eye's distance from the effect, the point lies behind the eye.
    The query then counts 0 pixels and the glow fades out.
- **Effect:**
  - OpenSRO's camera arm runs 20..90 units (`CAMERA_ZOOM_MIN`/`MAX`).
  - Constantinople's `euro_constan_center` has byte 95. The original hides it whenever the camera is
    within 94 units, so it appears only from afar. OpenSRO's ray, cast from the eye to a point
    behind it, meets nothing and keeps it at 255.
  - Jangan's (25 / 13) and Donwhang's (41 / 49) do the same at close zoom.
  - The lane's frames do not show it, because every viewpoint was 350+ units out (Constantinople's
    shots stand at 698,537 and 698,1237, with the row at 700,886).
  - A point outside the viewport's sides is likewise 0 pixels in the original and ray-tested here.
- **Fix:**
  - In `update`, the glow is not visible when the test point is behind the camera, nearer than the
    near plane or beyond the far plane, or outside the frustum: `camera.is_position_behind(p)` /
    `not camera.is_position_in_frustum(p)`. Then cast the ray.
  - Add a test with the camera nearer than `byte − 1`.

### 3. WRONG-LABEL: "a placed object always plays its `ambient` set" cites the wrong mechanism, and skips a gate

- **Where:**
  - `docs/protocol/teleport_effects.md:15-18`;
  - `docs/rounds/r720.md:12-13`;
  - `client/scripts/world/ambient_particles.gd:11-14`.
- **Evidence (READ):**
  - `ModPalette::FUN_00c0b060` does set the set object's `+0x18` to 2 for the name `ambient` and 0
    otherwise (`0xc0b0ca..0xc0b0e1`).
  - `FUN_004722d0` is `compare(0, size(), "ambient", 7)`: equal only for exactly `ambient`, and
    case-sensitive (`0x4722d0..0x47233b`).
  - But `FUN_00c7b540` compares a mod's ModData `+0x0c`, the IModData dispatch word (rtmod `+4` =
    the ModData, from `0xc43770`). It does not compare the set's kind.
  - The slot it calls, `vt+0x10`, is `0xc45610` in `CRTModParticle`'s vtable (`0xe0e524`): a bare
    `ret 0xc`. Kind 2 instead routes the runtime set to the palette's own slot: `FxModManager::FUN_00c7fa40`
    at `0xc7fcea` (`cmp [edi+0x18],2` → `mov [ecx+0x5c],esi`), which `0xc7c060` returns and
    `CCompChar::FUN_00c46ab0` (`0xc46b26`) collects.
  - The effect only draws while `+0xb0` or `+0xb4` is set (`0xc81472`). `+0xb4` is vslot_001's fifth
    argument (`0xc77c1c` → `0xc81510`, which also starts it through `0xc81350(1)`). Which value the
    ambient path passes was not traced.
  - Every `CRTModParticle` slot first runs `0xc43780`, which returns 1 only when the mod's `+0x3c`
    is at least the host's `+0x7c`. The constructor `0xc77a00` stores 0.9 there (the float at
    `0xde3148`); the base value is 0.5 (`0xe1b7e0`).
  - The host's `+0x7c` is written by `0xc25620`: clamp to 0..1, and ×4.0 (`0xe1b860`) into `+0x80`.
    It is slot 2 of `CCompChar`, `CCompBldg`, `CCompSimple` and `CCompoundObj` (vtables
    `0xe0cd3c` / `0xe0ce8c` / `0xe0cfd4` / `0xe0d4f4`).
  - The only caller found passes the game-object LOD ("LOD Level Change", `GlobalDataManager::FUN_009c4aa0`).
  - So a placed building most likely keeps its default LOD and passes the test. That is INFERRED,
    not READ.
- **Effect:**
  - The conclusion (the gates' ambient effects play in the original) matches the user's screenshots,
    but the proof cited does not show it.
  - The gate the lane reports absent ("no option or distance gate") exists, and is only probably open
    for map objects.
  - The name rule is exact and case-sensitive. `ambient_entries` uses `to_lower().begins_with()`.
    MEASURED harmless today: across 8,539 `.bsr` the loose filter matches no set beyond the 1,300
    named exactly `ambient`.
- **Fix:**
  - Rewrite the mechanism paragraph with the addresses above, and label the LOD gate OPEN/INFERRED.
  - Make the filter exact (`set_name == "ambient"`).
  - Add an `Ambient` / `ambient2` negative to `_test_ambient_set`.

### 4. PERF: the entry cost is cold build work on the main thread; recorded, not fixed and not taken to the user

- **Where:**
  - `client/scripts/World3D.gd` `_attach_gate_effects` (called from `_try_spawn_region_npcs`, inside
    the cell's `npcs` stopwatch);
  - `client/scripts/world/ambient_particles.gd:139-164` (`attach`);
  - `client/scripts/efp/efp_effect.gd` `make_glow` / `glow_shader`.
- **Evidence (MEASURED):** an instrumented copy at Jangan's gate (`qa_shot.sh --region 97\168.m
  --radius 1 --at 1259,1258`, Forward+ on the RX 7600):
  - `cj_pal_potal_blue.efp`: `create 163273 us, attach 54 us, glow 75539 us`;
  - `w_cd_potal_blue_g.efp`: `create 1687 us, attach 59 us, glow 58 us`;
  - `gate total 240841 us`.
  - The first effect pays the cold path: the `.efp` decode and compile, the DDJ decodes on the main
    thread, and the EFP shader's first build. The glow shader's first build is 75 ms in that run.
    In the play-everywhere run below it was 1.2 ms, so that part varies with the shader cache. The
    second effect costs 1.8 ms.
  - The work lands in the entry's first frame, which is the "freeze" the gate reports (3.3–4.6 s).
    So at Jangan and cross it adds to loading, not to play.
  - A gate region streamed in during play (riding to Donwhang, a fortress, Hotan) pays the same cold
    path as an in-play hitch for every effect type, and every shader variant, not yet built.
  - This review did not re-run the lane's base/head gate. The lane's three-site table already shows
    the consistent +130..190 ms, and the instrumented run accounts for it.
- **Per frame:**
  - `AmbientParticles.update` cost a mean of 28.7 µs per physics tick with the two Jangan glows (120
    ticks), and 409 µs with 113 glows (play-everywhere run).
  - Part of that is `set_shader_parameter` on every glow material every tick, even at a steady 255.
  - The gate-only frame time is unchanged: the lane's gate shows 1.48 → 1.52 ms; this review's head
    runs gave 1.53 / 1.53 / 1.51.
- **Fix:**
  - (a) Queue `EfpEffect.preload_paths` for a region's ambient `.efp` paths on the region's prepare
    job. It already exists for skills: decode, images and meshes on a worker.
  - (b) Build the EFP shader variants and their glow twins once while the loading screen is up, so a
    streamed-in gate pays only the 1–2 ms warm attach.
  - (c) Set `glow_alpha` only when the alpha changes.
  - AGENTS.md requires either the fix or the numbers taken to the user. r720.md records it as a
    follow-up only, so one of the two is still owed.

### 5. DEPARTURE: the restart-at-0 rule cannot fire, and the pass runs for glows the original does not draw

- **Where:** `client/scripts/world/ambient_particles.gd:167-189`.
- **Evidence (READ):**
  - `FUN_00c81450` puts an effect on the glow list only while its object is drawn. That means the
    frustum, and the map-object range of BSR_FORMAT.md's "Cull and draw" row. `FUN_00c43100` steps
    and draws only that list, and clears it each frame.
  - So an effect whose object was off screen keeps its alpha frozen. On its return, `FUN_00c81080`
    snaps it to 0 if the first answer is "hidden" (`0xc810d5..0xc810e0`).
  - `update` processes every glow every tick and sets `seen_frame` for all of them. So
    `seen_frame == _frame − 1` is true after the first tick, and the restart only ever acts on tick 1.
  - The lane's notes list "the restart at 0" as implemented.
- **Effect:**
  - Small on screen.
  - The cost scales with every loaded glow rather than the drawn ones: 113 rays every 500 ms in the
    play-everywhere run.
- **Fix:**
  - Skip glows whose object is not visible: not `is_visible_in_tree()`, or outside the camera
    frustum by its AABB. They are not stepped, not tested and not counted as seen.
  - Then the restart rule works as READ.

### 6. DEPARTURE (latent): mode-0 entries and the night bit are not handled as the original handles them

- **Where:** `client/scripts/world/ambient_particles.gd:153-156`. `b51` is read but never used.
- **Evidence (READ):**
  - Mode 0 (`0xc818c0`): the host's `+0xf4` is tested (`0xc818e8`); when it is 0, or the bone is not
    found (`0xc2c820` returns 0 at `0xc81908`), the call returns 0.
  - `CRTModParticle::vslot_001` then frees that effect and **returns at once** (`0xc77b9f..0xc77bc4`).
    No later entry of the mod is built.
  - OpenSRO's `SkillEffects.attach` falls back to the host's origin, and keeps going.
  - Mode 0 also uses the bone's full matrix (`0xc811c5..0xc811e0`, `[bone+0x80]+0x40` × world).
    `EfpEffect._place` uses only the bone's origin.
  - The `+0x51` bit 0 gate: manager `+0x1a8` is written by `0xbc0fe0` through the thunk `0xbbdbf0`
    from `SWorld::vslot_004` at `0xa2d1c6`. It is set to 1 when the shifted day phase `+0x26a7` > 0.5
    (game_clock.md: the night flag) and to 0 otherwise.
  - At the binary's fixed phase 0.5 the shifted phase is 0.25, so those entries never draw in retail.
- **Effect:** none at the gates. The census has every gate entry mode 1 and none with `b51` set.
  Across the archive's ambient sets, though, 1,018 entries are mode 0 (MEASURED, this review's
  probe). Night-bit entries were not counted.
  Both differences go live the day the other 1,290 ambient sets are played.
- **Fix:**
  - Before the follow-up that plays them all: abort a mod's remaining entries on a failed mode-0 bone.
  - Place at the full bone transform.
  - Skip `b51 & 1` entries unless the night flag is set; it is never set at a fixed midday.

### 7. MINOR: an ambient effect the census missed: three gate models also animate a texture

- **Where:** `docs/protocol/teleport_effects.md`, the census table.
- **Evidence (MEASURED, probe over the gate models' mod sets):**
  - The `ambient` set of `oas_hot_portal` (Hotan), `euro_esteuro_fountain01` (Constantinople) and the
    guild `charge_gate` carries a TEXANI mod (0x10000) and an MTRL mod (0x0) beside the particle mod.
  - `pha_gate` carries an MTRL.
  - None carries a sound mod (0x50000).
  - BSR_FORMAT.md lists TEXANI as "READ in outline, not drawn".
- **Effect:** the user asked for every effect on the teleports. The animated texture (likely the
  Hotan portal's surface and the fountain's water) is part of the same `ambient` set and is not drawn.
- **Fix:** list it in the census as OPEN. `CRTModTexAni` is already read (frame step, UV offset)
  and could be done in a follow-up.

### 8. MINOR: the placement "measurement" is self-consistency

- **Where:** `docs/rounds/r720.md:86-89`.
- **Evidence:** `obj.global_transform.affine_inverse() * fx.placed_at()` returns `e.offset` because
  `_place` builds exactly `host.global_transform * Transform3D(follow_basis, offset)`. It shows that
  the node is where the code put it, not that the code matches the original.
- **What does match the original (READ):**
  - `FUN_00c81190` builds translate(s·ox, s²·oy, s·oz) × world, where s = host `vt+0x20`.
    `FUN_00c81820` (`0xc81872..0xc8187e`) had already multiplied oy by s.
  - With a rotation, R × (that matrix with its translation zeroed), and the translation put back
    (`0xc812be..0xc81310`).
  - For s = 1, which is the lane's premise and was not re-verified here, that is the code.
- **Fix:** relabel as "consistency check", and cite the READ formula as the evidence.

### 9. MINOR

- **Entry words resolved, cheap (READ):**
  - `+0x52` is never copied: vslot_001's descriptor takes `+0x3c..+0x51` only (`0xc77b40..0xc77b72`).
  - `+0x48` goes to the effect's `+0x88` (`0xc8169e`), which no `CRTModParticle` code reads.
  - `+0x4c` is the key under which `CRTModParticle::vslot_009` (`0xc778ee..0xc77914`) files each
    effect in a lookup map.
  - Close the three OPENs with these.
- **The extra mod-section parse:**
  - `BsrReader._parse` / `_pp_parse` now parse the mod section once more per file
    (`particle_mods`), beside `material_mods`, `env_map_materials` and `env_map_flags`. Each is a full
    `parse_sound_section`.
  - MEASURED: `particle_mods()` mean 46.9 µs per file over the 8,539 `.bsr`. It runs off the main
    thread for map objects ("0 templates built unprepared"), so this is negligible.
  - One parse returning all four would do.
- **The fade's frame-rate dependence:**
  - The original steps per rendered frame by trunc(int ms × 1.5). `fild DWORD` at `0xc81093`: the
    manager's `+0x1d8` is an integer ms.
  - The lane steps per physics tick by trunc(float ms × 1.5).
  - Both reach 255 in about 170 ms whatever the frame rate. The steps are 25 per tick here, against
    24/25 per frame at 60 fps there. Not a finding.
- **The colour-alpha scaling:**
  - `0xc8affd` is one case of `EFEffect::FUN_00c893f0`'s switch: the colour-track case.
  - The glow shader scales every particle's alpha.
  - Particles without a colour track would differ. This was not measured.

## The 30-unit association, and the faithful rule

The original has no association: `ModPalette` gives every placed object whose model has an `ambient`
set its effects. The faithful rule is therefore to play them all, and it drops `GATE_EFFECT_RADIUS`,
`META_GATE_EFFECTS` and the teleport-row loop.

This review measured that rule. It ran the lane's own `attach` on every object carrying ambient
entries (an env-gated hook in the throwaway build).

Census at Jangan's 5 × 5 window (MEASURED, the run's log):

| Region | Objects | Effects | Glows |
|---|---:|---:|---:|
| 97/168 | 25 | 36 | 25 |
| 97/167 | 30 | 37 | 35 |
| 98/167 | 29 | 29 | 28 |
| 98/168 | 20 | 20 | 20 |
| 97/169 | 7 | 11 | 5 |
| 95/170 | 1 | 2 | 0 |
| **Total** | **112** | **135** | **113** |

The effects are mostly the palace and street lamps (`cj_pal_lamp_orange` ×45, `_orange_s` ×27,
`_red` ×21, `light` ×10, …). Build cost:
- warm, ~0.2 ms an effect (97/169: 11 effects in 3.3 ms);
- cold, a new effect type costs 35–160 ms the first time (`frame2.efp` 35 ms, `yellow_flame.efp`
  42 ms, the first lamp 162 ms).

Perf gate, one build both ways (`--base 099d8915 --head 099d8915 --base-env
OPENSRO_R720REV_ALL=1 --sites jangan --frames 12000`; base = every ambient set, head = the lane's
gates only):

| number | every ambient set (3 runs) | gates only (3 runs) | median diff |
|---|---|---|---|
| frame ms | 2.98, 2.96, 2.97 | 1.53, 1.53, 1.51 | **+1.44 (+94 %)** |
| entry ms | 9760, 9836, 9799 | 9710, 9706, 9630 | +93 |
| freeze ms | 3497, 3525, 3536 | 3462, 3483, 3485 | +42 |
| hitches | 4, 5, 4 | 4, 4, 4 | 0 |

(The gate prints this as head FASTER by 1.4 ms, because the expensive setting was on its base side.)

**Recommendation.**
- Do not switch to play-everywhere inside this round. It roughly doubles the Jangan frame time.
- Keep the gate filter, labelled OURS as it is. The 30-unit radius is a fair stop-gap, given the
  lane's farthest gate object at 26.0. Whether any non-gate object within 30 of a row also carries
  ambient entries was not checked here. The QA log's per-gate lines would show it.
- Take the play-everywhere rule to the user as its own round, with this table. Its prerequisites:
  - findings 4(a)/(b), so the cold costs move off the main thread;
  - finding 5, so only drawn glows are stepped and tested;
  - finding 6, mode 0 and the night bit;
  - and a look at where the +1.45 ms a frame goes: 135 `EfpEffect` simulations, against 135 effects'
    unbatched draws with per-effect glow materials. Not split here.

## What was verified

- **Entry layout (READ, `0xc77b28..0xc77b72`, `0xc81670`):** mode +0x00, efp +0x04, bone +0x20,
  offset +0x3c, +0x48 → effect +0x88, +0x4c → +0x8c/+0xcc, +0x50 → +0x90 (the glow byte),
  +0x51 → +0x91, +0x53 → the rotation flag (+8), +0x54 the angles; the record stride is 0x60 (`0xc77c3c`).
- **Mode dispatch (READ, `0xc77b80`):** mode 0 → `0xc818c0`, the bone found by name; mode ≠ 0 →
  `0xc81820`, the offset to `+0x94`. The offset is unused for mode 0.
- **The rotation:** `FUN_00c67500`'s matrix and its Godot column form. The test's v × M check holds,
  and the y-only case equals D3DX's RotationY.
- **The glow constants from the exe's bytes:** 1.5 at `0xe1b7e8`, 1.0 at `0xe1b7f0`. The 500 ms
  cadence: `cmp 0x1f5`, then `% 500`.
- **The fade (READ, `0xc81080`):** trunc(int ms × 1.5); visible → min(255, a + d); hidden → 0 if
  the stamp ≠ frame − 1, else max(0, a − d).
- **The draw state:** ZENABLE off around the draw list, `FUN_00471360(7,0)` / `(7,1)`. The query's
  states as in finding 2. `+0x1ac` is the query's availability (`0xbc1240` from `0xc41c6f`).
- **The (a × alpha) >> 8 alpha:** `0xc8affd..0xc8b01e`, global `0xedbd40`.
- **ZENABLE off in ours:** the glow shader adds `depth_test_disabled`, so it draws through walls
  while visible, as the original does.
- **Pixels (MEASURED, frame 150, effects on − off, luma):**

  | Town | Brighter > 10 | Brighter > 40 | Darker > 10 |
  |---|---:|---:|---:|
  | Jangan | 29,627 | 11,025 | 0 |
  | Donwhang | 25,029 | 8,400 | 0 |
  | Alexandria N | 24,104 | 5,994 | 0 |
  | Constantinople | 20,793 | 2,943 | 0 |
  | Samarkand | 8,133 | 2,230 | 0 |

  The > 40 pixels fall in a box about 150 × 150 px near the frame's centre, where the gate is. No
  pixel got darker, so the idle animation does not contaminate the diff.
- **Nothing teleport-specific was missed in code:** `CITeleportGate` (`vslot_025` `0x9e9eb0`,
  `FUN_009ea6b0`) builds the name label and the pick box from BCRadius/BCHeight and creates no effect.
  `teleportbuilding.txt` names no model (AssocFileObj `xxx`). No gate model carries a sound mod.
  Finding 7 is the one miss: the TEXANI.
- **The effect's lifetime:** `SkillEffects.attach` parents the effect to its object, so a region
  streamed out frees its effects, and `update` drops them.
- **Skill effects:** `follow_basis` defaults to identity, and `_place` is otherwise unchanged. The
  glow shaders' cache keys (`glow|<id>`) cannot collide with `_shader`'s.
- **Tests:** `ambient_particles_test.gd` passes its 20 checks. Gaps:
  - no case for the Light Effect gate;
  - none for a camera nearer than the bias;
  - none for an inexact set name;
  - none for `update`'s cadence and restart.

## Runs (box)

- `remote_godot.sh check` (`RENDER_DIR=/opt/opensro-client-r720rev`, `GODOT_LOCK=/var/tmp/r720rev/lock`):
  608 scripts and 9 scenes, ALL LOAD.
- `remote_godot.sh tests`: 233 suites, 0 failing.
- Probes: `particle_mods()` over 8,539 `.bsr`, and the gate models' sets per list with their mod
  kinds.
- `qa_shot.sh` ×2 on the instrumented copy: the gate run (finding 4), and the play-everywhere census
  (radius 2 at the spawn).
- `perf_gate.sh` once, as above.
- Cleaned:
  - `/opt/opensro-client-r720rev`, `/var/tmp/r720rev`;
  - the gate's `/opt/opensro-client-perf-base-099d8915d290` and `/opt/opensro-client-perf-r720rev-head`;
  - the local worktree.
  - No process left.
