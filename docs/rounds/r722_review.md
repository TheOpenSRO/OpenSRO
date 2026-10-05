# Round 722 review: TEXANI, the display-value blend, Donwhang's roof glow

This is an independent adversarial review of `dev..r722` (head `1a4f6990`, base `bfd6fb5e`).
It was checked against:
- the client binary, through the asm `/var/tmp/sro_client.asm`, the decompile
  `/var/tmp/decomp_client` and the exe's own bytes (`/root/sro_client.exe`: its IAT slots and
  strings);
- Data.pk2's `Shader\vss0.c`, `Shader\vss2.c` and `Shader\vertexshader0texani.c` (extracted with
  `server/cmd/pk2list` to the box's scratch, since deleted);
- Map.pk2's `.o2` placements (a throwaway Go probe over `internal/mapo` and `internal/objidx`);
- the lane's frames in `/var/tmp/r722/`;
- this review's own runs on the box: `remote_godot.sh tests` and `check`, the TEXANI census,
  three stock `qa_shot.sh` runs (Donwhang from four low cameras, Alexandria's library square, the
  Jangan spawn and gate), one Light Effect off run, and five perf gates.

No code was changed.

**Verdict.**
- The rate step, the frame-grid step and their maths are read right, down to the asm. The
  transpose the lane left INFERRED is READ (D3DXMatrixTranspose). Hotan's water is right.
- Two things are wrong:
  - **TEXANI mode 1 animates the second texture coordinate, not the first.** The client never loads
    the `vertexshader0texani.c` the lane read. It builds its object shaders from `vss0.c` /
    `vss2.c`, where mode 1 (`TEXANI1`) leaves `oT0` alone. Half the mods are mode 1, including
    Alexandria's library fountain and two waterfall groups, and OpenSRO slides their base texture.
  - **The display blend costs +1.5 ms a frame at 3840x2160 (SLOWER).** That is the cost round 705
    dropped the same screen read for. The lane's perf gate did not measure it: at the Jangan spawn
    the gate effects are off screen.
- Donwhang's roof glow is not hidden by the original's test from any low camera near the user's.
  The user's picture matches the ordinary depth-tested draw, which is what the original does with
  **Light Effect off**.

## Findings, most severe first

### 1. DEPARTURE / WRONG-LABEL: TEXANI mode 1 drives texture coordinate 1, and the cited shader is not the one the client loads

- **Where:**
  - `client/scripts/world/tex_ani.gd:24-32` (the shader claim) and `:47` (`SHADER_LINE`, applied
    for every mode);
  - `client/scripts/assets/object.gdshaderinc:108-117` and `client/scripts/assets/object_loader.gd:292-294, 369-370, 888-889, 1004`;
  - `client/scripts/bsr/bsr_reader.gd:390` (`texani_for` ignores `mode`);
  - `docs/rounds/r722.md:28-33` ("No other shader reads c23") and `:59-60`;
  - `docs/protocol/BSR_FORMAT.md:292`.
- **Evidence (READ):**
  - The exe holds no reference to `vertexshader0*.c` or `vertexshader2*.c`: 0 hits in its ASCII and
    UTF-16 strings. The object shader is assembled from `shader\vss0.c` and `shader\vss2.c`
    (`push 0xe0bc48` at `0xbf6a5a`, `push 0xe0bc38` at `0xbf6a8a`). The define names come from a
    list built at `0xbf6c3f..0xbf6d34`: `TEXTURE0`, `SPEC`, `MULTITEX`, `TEXANI0`, `TEXANI1`,
    `TEXANI1R`. They are consecutive 0x1c-byte strings, indices 0..5.
  - The renderer picks the UV variant from the draw flags (`0xbf0f70..0xbf0f93`, again at
    `0xbf19f2..0xbf1a1b`): 0x2000000 → 2 (`MULTITEX`), 0x8000000 → 3 (`TEXANI0`), 0x400000 → 4
    (`TEXANI1`). 0x200000 with 0x8000000 → 5 (`TEXANI1R`, `0xbf1943..0xbf1968`).
  - `CRTModTexAni::vslot_004` sets 0x400000 when data `+0x24` (mode) is 1, else 0x8000000
    (`0xc8299f..0xc829ad`).
  - `vss0.c` (and `vss2.c`'s `SKIN2` twins):
    ```
    #ifdef VS_UV_SKIN0_TEXANI0   m3x3 oT0.xyz, r1.xyz, c[VSC_TEXTUREANI_MATRIX]
    #ifdef VS_UV_SKIN0_TEXANI1   mov oT0.xy, v4.xy ; ... m3x3 oT1.xyz, r1.xyz, c[VSC_TEXTUREANI_MATRIX]
    #ifdef VS_UV_SKIN0_TEXANI1R  m3x3 oT0.xyz, ... ; mov oT1.xy, v4.xy
    ```
    So mode 0 animates texture stage 0, as built. Mode 1 keeps stage 0's coordinates as authored
    and animates stage 1's. `vertexshader0texani.c` happens to equal `TEXANI0`; it is a stale file
    in the archive.
- **MEASURED (census, this review's run, 370 mods in 359 files):** 186 are mode 1 (180 in the
  `ambient` set). Most are items (not bound, as the notes say). The placed map objects among them:
  - `alex_library_01`: region 91/49 at (105, 254), w1 1, so every material;
  - `dun_cen_s01..s03`: 126/211;
  - `waterfall-turtle01-3`, `01-4`, `02-3`: in the compounds at 98/169, beside Jangan's palace.

  Live (`/var/tmp/r722rev/lib.out`): `alex_library_fountain_water` scrolls v at −0.88/s (−0.293
  at tick 20). Between frames 20 and 30 of a still camera, 8.0 % of the fountain's pixels change by
  more than 8 a channel, against 0.0 % on the library's wall and 0.1 % on the paving. The gates
  (Hotan, the Constantinople fountain, `charge_gate`) are mode 0 and are drawn right.
- **Effect:** for mode-1 objects the original keeps the base texture still. Whatever moves sits on
  stage 1, and nothing moves at all when the material has no stage-1 texture. OpenSRO slides the
  base texture.
- **Fix:**
  - Carry `mode` into `TexAni`. For mode 1, do not touch `UV`.
  - Find what stage 1 holds for these materials. The MTRL mod's stage ops are the first place to
    look (`CRTModTexAni` slot 5, `0xc828c0`, calls `[0x1112fb0+0x20]->vt+0x2c(0)` for mode 0 only:
    not read). Then apply the rows to that lookup alone, or draw nothing until it is read.
  - Correct the three doc places to cite `vss0.c` / `vss2.c` and the define list.
  - The tex_ani_test shader check should assert that mode 1 leaves `UV` unchanged.

### 2. PERF (SLOWER, not recorded) / WRONG-LABEL: the screen read costs +1.5 ms a frame at 4K, and the gate never saw it

- **Where:**
  - `client/scripts/efp/efp_effect.gd:275-372` (`use_display_blend`, `display_shader`,
    `hint_screen_texture`);
  - `client/scripts/world/ambient_particles.gd:252`;
  - `docs/rounds/r722.md:163-165` ("Jangan's gate glows are on screen at the spawn, so the screen
    copy ... is in this measurement").
- **Evidence (MEASURED):**
  - The claim is wrong. With `OPENSRO_QA_AMBIENT=1` at the gate's own Jangan view (97/168,
    1002,1020, yaw 0), both Jangan effects log `screen off` (`cj_pal_potal_blue.efp[25]` at d469,
    `/var/tmp/r722rev/jg.out`). The lane's 720p table and this review's first 4K gate at the spawn
    (3.69 → 3.70 ms, SAME) both measure a frame with no display-blended draw in it.
  - The same gate, aimed at Samarkand's arch (`--env "OPENSRO_MAPM_PATH=107\\107.m
    OPENSRO_QA_AT=1918,30 OPENSRO_QA_YAW=0 OPENSRO_QA_PITCH=-8 OPENSRO_QA_DIST=40"`, the head log
    showing the plate on screen):

| size | frame ms base → head | entry | freeze | hitches |
|---|---|---|---|---|
| 3840 x 2160 | **4.70 → 6.15 (+1.5) SLOWER**; all six runs within 0.01 | 7938 → 8011 SAME | 2508 → 2538 SAME | 4 → 4 SAME |
| 1280 x 720 | 1.81 → 1.80 SAME (the frame is CPU-bound there) | 7927 → 7977 SAME | 2522 → 2547 SAME | 4 → 4 SAME |

  - Round 705 dropped the fog pass's identical screen read for +1.4 ms at 4K (WORLD_ISSUES, "First
    fix, exact, dropped for its cost"). This round brings that cost back whenever any gate effect is
    on screen. AGENTS.md: a slowdown is fixed in the round or recorded with the numbers and taken to
    the user. It was neither.
  - Note for gate users: a `--env OPENSRO_MAPM_PATH` path needs a doubled backslash, because
    `perf_gate.sh:317` passes `--env` through `xargs`. A single one loaded no terrain
    (`could not find terrain at 107107.m`) and produced a false SAME.
- **Fix:**
  - Record the table in the round and put the choice to the user. The choice is between the exact
    display blend at +1.5 ms at 4K, and round 705's fixed-reference blend (`WorldFog.BLEND_FORWARD`'s
    method: a colour and alpha whose linear blend lands on the display sum for a reference
    destination, no screen read).
  - Correct r722.md:163-165.
  - Add a gate site that frames a gate effect.

### 3. DEPARTURE (Donwhang, now measured): the original's test does not hide the roof glow from the user's camera; their picture matches Light Effect off

- **Where:** `docs/rounds/r722.md:141-145` (the OPEN), `docs/protocol/teleport_effects.md:157-159`.
- **Evidence (MEASURED, `/var/tmp/r722rev/dw.out`):**
  - The setup: four low cameras south of the bridge (player at local z 200, 240, 280, 330 on
    x 959, yaw 180, pitch 0..4, distance 25..30). The camera sits at world y 12..15, 220..361 from
    the roof glow. That brackets the user's view (`dw_00000150.png` frames the pavilion as their
    picture does, uncropped).
  - At every one, the roof glow (byte 49) is `a255 vis`. The low glow (41) is hidden by
    `W_CD_portal_04` (n.d −0.53).
  - Geometry: the test point is P = G + 48 x normalize(eye − G). The ray to G meets the bell 5 units
    in front of G (`ray hits ... W_CD_portal_bell01 at d356.2` of 361), so the bell lies within
    48 units of G and cannot hide P. P lies under the front lintel in open air.
  - The original's depth test of P therefore passes too. With Light Effect on, the original draws
    that glow with ZENABLE off over the bell, as ours does.
  - The user's picture shows something else: the bell clean in front, blue light flanking it, and a
    small sparkle at the bell's base. That is the ordinary branch: depth-tested, full alpha, the
    low glow's upper half showing above the floor.
  - This review rendered the lane's d1 view with `OPENSRO_QA_VIDEO=light_effect=0`
    (`/var/tmp/r722rev/dwoff/`). The bell is clean, blue light sits between the columns at its
    sides, and a sparkle shows at its base, as in the original.
  - A device without occlusion queries (`+0x1ac` = 0) takes the same branch.
  - Untraced alternative: the glow pass's place in the frame. `FUN_00c43100` is reached only through
    the vtables at `0xe0bcc0` / `0xe0d988`. If it drew before the pavilion, the bell would overdraw
    it.
- **Fix:**
  - Do not change the test. It agrees with the original's rule.
  - Ask the user whether Light Effect is ticked in their original client. If it is off, the look
    they want is our Light Effect off. Then decide whether OpenSRO's default preset (Middle, Light
    Effect 1, READ) should stay.
  - Replace the OPEN in r722.md with these measurements.

### 4. MINOR: Samarkand's arch matches Compatibility, but does not fill the arch as in the user's picture; the table cannot be reproduced

- **Where:** `docs/rounds/r722.md:79-89`.
- **Evidence (MEASURED, frame 35 of `/var/tmp/r722/a4|a5/sm_*`):**

| render | arch 585,100–695,180 | lower arch 580,180–700,245 |
|---|---|---|
| off (Forward+) | 164 248 244 | 91 102 104 |
| Forward+ before | 172 251 255 | 92 110 134 |
| **Forward+ after** | **204 253 255** | **99 119 138** |
| Compatibility | 207 254 255 | 99 124 141 |

  - The claim holds: Forward+ now lands within 3..5 of Compatibility.
  - The lane's numbers (164 210 205 off, ...) match no box tried here, and the notes do not give
    the crop. Record the box.
  - Compared with the original, the glow is a bright spot behind the crystal's tip. The basin, the
    minarets and the wall behind stay plainly visible through the arch. In the original the opening
    is washed white-blue down to the flowers.
  - Much of that is the sky. Ours is cyan (164,248,244 behind the arch), so the plates' blue
    (62,130,254 at a 200) saturates G and B at once and lifts only R. The original's sky is a hazy
    beige-pink, where the same addition reads blue-white. That is a time-of-day or sky difference,
    not the blend.
- **Fix:** record the crop boxes. Say in the notes that the arch is not yet filled as in the
  original, and why. Do not tune the plates.

### 5. PERF (MINOR, reasoned): Compatibility pays for the screen copy it never reads

- **Where:** `client/scripts/efp/efp_effect.gd:328-338` (`DISPLAY_TAIL_TO`) and `:341-343`.
- **Evidence (INFERRED from Godot 4.2's shader compiler, not measured):**
  - The display branch is a runtime `if (!OUTPUT_IS_SRGB)`, but `srr_screen : hint_screen_texture`
    is declared and referenced in every renderer.
  - Godot marks `uses_screen_texture` at compile time from the reference. Compatibility then copies
    the back buffer, and builds its mips, on every frame an ambient effect draws.
  - The users who chose Compatibility are the low-end ones.
- **Fix:** give the display twin only under Forward+ (`use_display_blend` returns early when the
  rendering method is `gl_compatibility`). Then the Compatibility shader has no screen uniform.

### 6. MINOR: the texel read on the glow ray is untested, and stalls on its first use

- **Where:** `client/scripts/world/ambient_particles.gd:365-433`.
- **Evidence:**
  - No test calls `texel_kept`. The QA line `(passed X)` prints the same for a cut texel (0) and an
    unreadable hit (−1). The latter is round 720's pass-through, so the live logs cannot show the new
    path working.
  - `mesh.surface_get_arrays(0)` and `texture.get_image()` read GPU resources back synchronously on
    the main thread on first use. The caches are dropped whole at 257 meshes and 65 images.
  - The perf gate's freeze is unchanged, but its views fire no ray through foliage. The Jangan
    glow's leaf cards are 150 units from a camera the gate does not use.
- **Fix:**
  - Add a test: a quad with an alpha-cut texture, a ray through the cut half (0), through the kept
    half (1), and a no-UV mesh (−1).
  - Print the code in the QA line.
  - Keep the CPU-side arrays the loader already prepared instead of reading them back.

### 7. MINOR: notes on TEXANI data that the census shows

- **The frame grid is never played.** Its only user, `flame_adjutant`, is set 1 (not ambient),
  frames 0..0, grid 1x1. "The frame grid appears once" is true, but no placed data exercises the
  grid step. Only the synthetic tests do.
- **The Constantinople fountain's scale.** Its 2x2 part grows without wrap (READ: `vslot_007`
  `0xc82930` resets the frame and direction, never the matrix). After an hour m00 ≈ 73 and
  m11 ≈ 109, so its water tiles about 100 times denser.
- **Long-session precision.** The fastest scroll (`cj_wf_dr_01`, −2.78/s) reaches |v| ≈ 10^5 in
  10 hours, where float32's step is about 0.008 of a texture.
- Both match the read accumulator. The original's only difference is its LOD gate (`0xc43780`),
  which pauses the step for undrawn objects. Worth a line in the notes, nothing to fix.

## What was verified and holds

- **The rate step** (`0xc82830`): s = (int ms) / 1000.0 (the double at `0xd83268`), with
  m00/m01/m10/m11/m20/m21 (+0x48/+0x4c/+0x58/+0x5c/+0x68/+0x6c) += data +0x38/+0x3c/+0x48/+0x4c/+0x58/+0x5c
  x s. No wrap.
- **The grid step** (`0xc82640..0xc82820`):
  - the period is trunc(1000/fps) under a truncating control word; frames are trunc(acc/period),
    with the remainder kept;
  - start == end stops;
  - loop: frame += start − end − dir, then clamped to start;
  - ping-pong: near and far swapped when start is past end in the direction of travel; at the far
    end it either stops at start (no loop flag, reversed) or reflects to 2·far − frame, with a second
    reflection clamped to near;
  - `FUN_00c825f0`: m20 = (frame % cols)/cols, m21 = (frame / cols)/rows, by `idiv`.

  `TexAni.step_grid` matches each branch.
- **The upload is a transpose, READ.** `0xaa3afe` jumps through the IAT slot `0xec77b4`, which the
  file initialises to `0xaa3ac5`. That is D3DX's CPU dispatch: `call 0xaac587` patches the slot,
  then it re-jumps. The x87 body at `0xaa3b04` swaps +0x04/+0x10, +0x08/+0x20, +0x0c/+0x30,
  +0x18/+0x24 and +0x1c/+0x34: `D3DXMatrixTranspose`. So c23 = (m00, m10, m20) and
  c24 = (m01, m11, m21), as `TexAni.rows()` has it. The lane's INFERRED can be READ.
  `SetVertexShaderConstantF(23, …, 3)` is device vtable +0x178.
- **The dispatch.**
  - w1 2: `FUN_00c7b540` passes the material index.
  - w1 1: `FUN_00c7b4e0` passes 0xFFFFFFFF (`push 0xffffffff` at `0xc7b521`), which equals the
    mod's material word, so a w1-1 mod covers the whole object.
  - `texani_for`'s rule is right (READ, not only INFERRED as the comment says).
- **Hotan:** `oas_hot_portal` material 3, mode 0, v +0.48/s. **Constantinople's fountain:**
  material 6, mode 0. **`charge_gate`:** material 3, mode 0, v −0.7/s. **The census:** 359 files,
  as stated.
- **The display blend's arithmetic** is D3D's for each class it covers. SRCALPHA/ONE is
  d + s·a; ONE/ONE is d + s (a forced to 1); SRCALPHA/INVSRCALPHA is mix(d, s, a). In each, s is
  the stage output in display values and d is the screen's displayed value.
- **Scope:** `AmbientParticles.attach` is reached only from `_attach_gate_effects`, for objects
  within `GATE_EFFECT_RADIUS` of a teleport row. Only gate effects use it, as claimed.
- **Transparent surfaces behind an effect are not blanked.**
  - Derivation: an additive class writes `max(t − bg, 0)` with ALPHA 1 under `blend_add`, so the
    result is dst + something ≥ 0 and cannot darken what is drawn. A mixing class gives
    t + (1 − a)(dst − bg): a transparent layer under it keeps (1 − a) of its difference, as a
    correct mix does. The error is only that the amount is computed against the opaque `bg`.
  - Hotan has both classes: the blue plates are 5/2, and `pajang`'s meshes are 5/6 (`efpcensus
    -dumpone`).
  - The lane's frames (base `b6`, head `a7hotan`, frame 20) give pool means of 47 225 235 against
    47 225 235, and 22 217 243 against 23 222 243. Nothing darkens. The column the plates cover
    brightens (148 173 167 → 170 189 174).
- **`object_light_test` and the shared block:** the TEXANI uniforms sit outside the verbatim block.
  The suite passes.
- **The glow-ray texel read** maps the collider's `face_index` to the same triangle as the mesh's
  index list (`_piece_faces` → `MapmTerrainBuilder.surface_faces`, in order). Its threshold unit
  matches `alpha_scissor` (ref / 255).

## Tests and perf (this review's runs)

- `remote_godot.sh tests` (RENDER_DIR `/opt/opensro-client-r722rev`, lock `/var/tmp/r722rev/lock`):
  **234 suites, 0 failing**.
- `remote_godot.sh check`: **611 scripts and 9 scenes, ALL LOAD**.
- `perf_gate.sh --base bfd6fb5e --head 1a4f6990 --sites jangan,cross --frames 12000` (1280x720), all
  SAME. These views draw no gate effect (finding 2).

| site | frame ms | entry ms | freeze ms | hitches |
|---|---|---|---|---|
| jangan | 1.52 → 1.51 | 9477 → 9575 | 3338 → 3346 | 4 → 4 |
| cross | 1.66 → 1.69 | 10345 → 10257 | 3337 → 3355 | 4.5 → 3 |

- `--sites jangan --size 3840x2160`: 3.69 → 3.70 SAME. The effects are off screen.
- At Samarkand's arch: see finding 2. 3840x2160 is **+1.5 ms SLOWER**; 1280x720 is 1.81 → 1.80, SAME.

Box scratch (`/var/tmp/r722rev`, `/opt/opensro-client-r722rev`) and the worktree are removed. No
process was left running.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
