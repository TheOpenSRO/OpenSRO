# Round 719 review: the character pending deletion on the select screen

This is an independent adversarial review of `dev..worktree-agent-af2d19af7f353aa3c` (head `5947ff29`).
It was checked against these sources:
- the client binary (`sro_client.exe`, md5 2a5794b72c90908d945be8b3f3f2edd4), through the asm
  `/var/tmp/sro_client.asm` and the decompile `/var/tmp/decomp_client`;
- Data.pk2;
- Godot 4.2.2's Forward+ source (`render_forward_clustered.{h,cpp}`);
- the lane's frames (`/var/tmp/r719/`);
- the user's two screenshots;
- this review's own probe runs on the box (`/var/tmp/r719rev/`, client copy
  `/opt/opensro-client-r719rev`).

No code was changed. The two probe-only patches described under "Runs" were applied to the review's
own box copy and deleted with it.

**Verdict.** The diagnosis is right, and so is the core of the fix:
- the old drawing sent every mesh to Godot's transparent pass with no depth written;
- the depth pass plus colour pass makes the body one even sheet in linear light.

This review confirms both by a stricter measurement than the lane's. The READ claims about
`FUN_00c428c0` hold, including ZWRITE being left on.

Four problems:
- **The depth pass's priority (−100) is global.** It occludes every transparent surface drawn behind
  the pending body: the terrain's feathered overlays, the water and the shadow catcher. MEASURED.
- **The pending body stops casting a shadow under Shadow Detail "Detail".** The pair materials are
  alpha materials, and Godot gives those no shadow pass. READ, and measured below.
- **The measurement does not pin the hour.** The QA_Wei before/after rows compare two different hours,
  and the headline "four-fold" does not reproduce at another hour.
- **The OPEN weapon/hair item is built on a whole-texture average and mislabelled.** The flag word it
  says "was not read" is in the data, and this review read it.

## Findings, most severe first

### 1. BUG: the depth pass at priority −100 hides the transparent surfaces behind the pending body

- **Where:** `client/scripts/frontend/charselect_stage.gd:661` (`FADE_DEPTH_PRIORITY := -100`), used at
  `:728`.
- **Evidence (READ):**
  - Godot 4.2 sorts the transparent list by priority first, and by depth only within a priority
    (`render_forward_clustered.h:562-565`, `SortByReverseDepthAndPriority`; `world_fog.gd:69-73` says
    the same).
  - So every depth pass of the body is drawn before every other transparent surface in the scene:
    - the terrain's feathered overlays and the water (`WorldFog.UNDER_PASS_PRIORITY`, −3,
      `mapm_terrain_builder.gd:272`, `mapm_water.gd:310/328`);
    - the shadow catcher (`ShadowCatcher.PRIORITY`, −2, `blend_mul`);
    - every transparent object at 0.
  - Where those lie behind the body, they fail the depth test against the body's depth. They are then
    missing from what shows through her at 0xcc.
  - The original has no such step. It draws the model with ZWRITE on in its own order, and what is
    behind it was already drawn (its terrain and shadows are drawn first).
- **Evidence (MEASURED):**
  - This review's box copy of the probe adds one shot at alpha **1/255**, where the body's own colour
    adds at most 1/255 of `|O−B|`. It compares that shot with the background frame, inside the body's
    silhouette (QA_Aria, hour pinned to 0.5833, 13,958 body pixels).

    | drawing | median | p99 | max (RGB sum) | pixels off by more than the body allows |
    |---|---|---|---|---|
    | old (instance transparency) | 0 | 0 | 0 | 0 |
    | new (the pairs) | 2 | 59 | 110 | 3,551 (1,010 by more than 15) |

  - The new frame is *brighter* than the background there (about +9 per channel). That is the ground
    with its multiplying pass (the catcher / overlays) missing behind her. At 0xcc that background
    weighs 0.2, so P is off by up to about 22 (RGB sum) in those pixels.
  - It is worst over water (the harbour) and over Detail shadows. The probe's own "background did not
    move" filter would drop animated water pixels, so the lane's measurement could not see it.
- **Fix:**
  - Put the depth passes after everything that has to be under them, and the colour passes after the
    depth passes. For example: depth pass at priority 0, and every colour pass (including a
    `next_pass` chain) at `src.render_priority + 1`. Everything at −3..−1 is then drawn first.
  - Transparent objects at 0 behind the body then sort by depth with the depth passes (back to front).
  - The remaining cost: a transparent object at 0 *in front of* the body is drawn before the body's
    colour. On this screen nothing transparent stands between the camera and a character.
  - Add the alpha-1/255 shot to the probe as a check: it must equal the background within the body's
    allowance.

### 2. REGRESSION: the pending (and fading-in) body casts no shadow under Shadow Detail "Detail"

- **Where:** the same pair materials (`charselect_stage.gd:710-731`, `fade_code` `:768`).
- **Evidence (READ):**
  - Godot 4.2 Forward+, `_geometry_instance_add_surface_with_material`
    (`render_forward_clustered.cpp:3647-3657`). A material whose shader writes ALPHA, or blends, gets
    `FLAG_PASS_ALPHA` only. `FLAG_PASS_SHADOW` is added only when it is opaque, or uses
    `depth_prepass_alpha` / alpha antialiasing. Both of the round's passes write ALPHA with
    `blend_mix`, so neither is in the shadow pass.
  - Instance transparency, used before, does not touch the surface flags. It only forces the colour
    pass to the alpha list (`fade_alpha < 0.999`, `:1043-1053`), so before this round the pending
    body's opaque materials kept casting.
  - The select screen's shadows are the sun's shadow map caught by the terrain's catcher, under
    Detail (`World3D.gd:483`, `shadow_catcher.gd`). The user's own screenshot (`bug2_FtMRFdi.jpeg`)
    shows the characters' shadows, so the user plays with Detail.
  - So from this round the pending character's shadow disappears for them. Every character's shadow
    also disappears for the 1.0 s fade-in of every list, since that runs through the pairs too.
- **Not covered by the lane:**
  - The lane's probe switches every body's shadow off (`CharacterSelect.gd:1570-1572`).
  - The QA runs ran at `shadow_detail=1` (the log's video line), where no shadow is drawn at all.
- **What the original does with the shadow at 0xcc is not read** (`appear_fade.md`, "Whether the
  shadow ... take the compound's alpha", still OPEN). So either outcome is a choice. But this one
  changed without being named, and it is the user's visible configuration.
- **MEASURED:** with Shadow Detail on, 2,679 pixels of the body's shadow at 255 are back to the bare ground at 0xcc (new), against 0 (old). See "Runs".
- **Fix:**
  - Keep the shadow: set `depth_prepass_alpha` on the depth pass instead of `depth_draw_always`. That
    puts it in the depth and shadow passes. Check that it still writes depth for the colour pass.
  - Or give each faded mesh a shadow-only twin (`SHADOW_CASTING_SETTING_SHADOWS_ONLY` with the
    original material).
  - Either way, record which of the two the round means, until the original's shadow at 0xcc is read.

### 3. WRONG-LABEL (measurement): the before/after table compares different hours, and its headline does not reproduce

- **Where:** `docs/rounds/party719.md:48-70`.
- **Evidence (MEASURED, from the lane's own logs):**
  - The lane's four runs did not pin the select screen's random hour.
  - QA_Wei's "before" ran at phase **0.2083** and its "after" at **0.75**: a different sun, sky and
    background. The QA_Aria pair happened to share 0.9583.
  - `OPENSRO_QA_TITLE_HOUR` pins it (`title_intro.gd:304-310`). Pinned to 0.9583, this review's rerun
    reproduces the lane's QA_Aria "after" numbers exactly: median 0.845, p5 0.667, p95 0.883.
  - The same build at **0.75**, unpinned stock `qa_shot.sh` (`/var/tmp/r719rev/anew`), gives a
    different distribution for QA_Aria "after":

    | QA_Aria "after" | median | p5 | p95 | below 0.5 | above 1.05 |
    |---|---|---|---|---|---|
    | lane, hour 0.9583 | 0.845 | 0.667 | 0.883 | 1.2 % | 0.5 % |
    | this review, hour 0.75 | 0.922 | 0.565 | 1.065 | 4.2 % | 5.4 % |

    At 0.75, "after" sits at the lane's own "before" levels. So "both shrink about four-fold" is a
    property of the hour, not of the fix.
  - The metric mixes two effects:
    - the piece-order error the fix removes;
    - the linear-light blend the fix leaves (finding 4).
  - A metric that separates them compares P with what a single sheet blended in Godot's linear buffer
    would give, `T(0.8·T⁻¹(O) + 0.2·T⁻¹(B))`, with T the Filmic + sRGB chain the stage already
    inverts. Residual |P − prediction|, summed RGB:

    | run | hour | median | p90 | p99 | share > 15 |
    |---|---|---|---|---|---|
    | QA_Aria before (lane frames) | 0.9583 | 4.6 | 22.3 | 111.2 | 13.6 % |
    | QA_Aria after (lane frames) | 0.9583 | **2.3** | **6.1** | **11.9** | **0.3 %** |
    | QA_Aria after (this review) | 0.75 | 6.1 | 14.3 | 23.1 | 8.4 % |
    | QA_Aria before, 0.5833 (this review) | 0.5833 | 8.9 | 34.4 | 148.8 | 32.4 % |
    | QA_Aria after, 0.5833 (this review) | 0.5833 | 5.0 | 15.6 | 30.4 | 11.0 % |
    | QA_Wei after (lane frames) | 0.75 | 13.7 | 40.3 | 65.3 | 45.1 % |

  - **What this shows:**
    - The fix does make the body one sheet. At 0.9583 the "after" frame is that sheet to within 12
      levels in 99 % of pixels.
    - At brighter hours a residual remains that the sheet does not explain:
      - QA_Wei's after frame is darker than the prediction across the whole body, by about 15 per
        channel. Its error map is smooth.
      - That is what a screen-reading post pass (the retail bloom was on, `bloom=1`) or the depth
        pass's missing under-passes (finding 1) would give.
      - Not separated here: UNVERIFIED which.
  - **Smaller method issues:**
    - The signed RGB sum as denominator is unstable where channels move in opposite directions
      (2,565 of QA_Wei's 21,407 pixels). A per-pixel least-squares alpha is steadier.
    - The UI dialog over the body's lower part is inside the mask.
- **Fix:**
  - Re-measure with `OPENSRO_QA_TITLE_HOUR` pinned, and bloom off (`OPENSRO_QA_VIDEO="bloom=0"`), or
    both hours.
  - Report the residual against the linear-sheet prediction.
  - Replace the QA_Wei before/after rows.
  - Drop "four-fold".

### 4. DEPARTURE (labelled OPEN, but larger than the notes make it): the blend is in linear light, the original's in display values

- **Where:** `charselect_stage.gd:768-823` (the colour pass is a plain `blend_mix`); notes `:66-70`,
  `:164`.
- **Evidence (READ + MEASURED):**
  - `FUN_00c428c0` blends SRCALPHA/INVSRCALPHA in the D3D9 back buffer, in display values: 0xcc is
    0.8 everywhere.
  - Forward+ blends in its linear HDR buffer before the Filmic tone map.
  - Against the original's own arithmetic, `0.8·O + 0.2·B` in display values, the "after" frames are
    off by:

    | QA_Aria "after" | median (RGB sum) | p90 | share of body pixels > 15 |
    |---|---|---|---|
    | hour 0.9583 | 8.0 | 21.5 | 21 % |
    | hour 0.75 | 21.4 | 45.2 | 65 % |
    | hour 0.5833 | 20.8 | 47.0 | 64 % |

  - At bright hours that is more than the piece-order error the round fixed (finding 3's table).
  - The notes call the round "as the original draws it" and file this as a residual. It is the larger
    remaining difference from the original, not a residual.
- **Fix:**
  - Retitle the notes' claim.
  - The fog pass met the same problem (`world_fog.gd`, BLEND_FORWARD). Here the background is behind
    an opaque scene, so the colour pass can do the original's arithmetic exactly:
    1. read the screen behind it (`hint_screen_texture`, which Forward+ copies after the opaque
       pass);
    2. tone-map both colours to display values;
    3. mix them at 0.8;
    4. write the result back through the inverse with ALPHA 1, keeping the depth pass.
  - Filed as OPEN with these numbers if not done now.

### 5. WRONG-LABEL: the OPEN weapon/hair texture-alpha item rests on a whole-texture average, and the "unread" flag is in the data

- **Where:**
  - `docs/rounds/party719.md:95-104` and `:162`;
  - the probe `charselect_stage.gd:552-588` (`qa_texture_alpha_report`, samples the whole image every
    4 texels).
- **Evidence (READ, Data.pk2 with the repo's Go `bmt` and `pk2` readers; throwaway tool, not
  committed):**
  - **The atlas, not a gloss mask.** QA_Aria's weapon is `Res\Item\China\Weapon\sword_01.bsr`. Its
    material is `prim\mtrl\item\china\weapon\sword1_2_3.bmt`: one atlas shared by three swords. Its
    layer's flag word is **0x340**, which includes **0x200**, the 128 alpha test (BMT_FORMAT.md).
    - At full alpha the original keeps only texels of alpha ≥ 128, and so does this client.
    - So "mean 0.330, 77.1 % below 0.5" is mostly the atlas's empty area and the cut-out, not "a gloss
      mask" on the drawn blade.
    - The hair (`chinawoman_fighter.bmt`, layer `chinawoman_hair`) is **0x341**: alpha-tested and
      two-sided, not blended. Its 21.9 % is likewise the cut area.
    - The number that matters is the alpha of the **kept** texels over the UV-covered area. In the
      original a kept texel blends at `tex.a × 0.8` (0.4..0.8). This was not measured.
  - **The flag "not read".** `0x40000000` (stage-0 alpha = the fade alone) is in **none** of the 3,263
    layers of the 1,488 `Prim\Mtrl\Item` and `Prim\Mtrl\Char` `.bmt` files. Census: 0x341 1,165,
    0x340 877, 0x140 626, 0x141 359, 0x2345 109, 0x40 40, 0x345 27. Its only sources are runtime mods:
    - `CRTModEnvMap::vslot_004` ORs **0x60000000** (`funcs_020.c:38533`). It does this for every
      material of an env-mapped object, whatever the alpha. Only the reflection itself is gated on
      0xff000000. 12 China weapon/shield files carry one (BSR_FORMAT.md).
    - `CRTModProgEquipPow::vslot_004` ORs **0xe21f0000** (`funcs_020.c:39787`) for enhanced gear.
  - So the original draws a plain item or body layer at `tex.a × 0.8`, and an env-mapped or enhanced
    item at 0.8 exactly (what this client does for all).
  - "Hair cards and the like" (notes `:85`) is the wrong example: no hair layer here blends. The only
    blended character layers are MTRL-mod ones.
- **Fix:**
  - Rewrite the OPEN item with the flag sources above.
  - Measure the kept-texel alpha over the UV surface (the census tools' method, BMT_FORMAT.md
    "of their UV surface") before calling its size.
  - It is reproducible with data the client already has: the layer's flag word (`BmtReader.Layer`)
    and `env_map_flags`. Use `ALPHA = tex.a * select_fade` for a layer without an env map or
    ProgEquipPow, and `select_fade` alone otherwise. That is the original's MODULATE/SELECTARG2 rule,
    READ.

### 6. DEPARTURE (READ, unlabelled): under the fade the original overrides an MTRL mod's own blend; the pair keeps it

- **Where:** `fade_code`, colour pass of a layer that blends (`charselect_stage.gd:793-818`).
- **Evidence (READ):**
  - In `CObjRendererVS::FUN_00bf0e20` the order is:
    1. the object's mods, `FUN_00c451e0` (line 65 of the decompile; `CRTModMtrl::vslot_004` sets its
       own SRCBLEND/DESTBLEND, stage ops and TFACTOR);
    2. the flag word's states (line 95);
    3. the fade, `FUN_00c428c0` (line 135).
  - Below 0xff000000 the fade sets SRCBLEND 5, DESTBLEND 6, TEXTUREFACTOR and stage-0 ALPHAOP/ARGs
    over whatever the mod set.
  - So at 0xcc an additive (SRCALPHA/ONE) mod layer is drawn SRCALPHA/INVSRCALPHA, with its TFACTOR
    replaced by the fade colour.
  - The pair keeps the mod's `blend_add` and multiplies its alpha.
  - A blending mod that writes depth also loses its depth write: `depth_draw_never` replaces its
    `depth_draw_always`.
- **Fix:**
  - For a blending layer the colour pass should use `blend_mix` with the alpha rule of finding 5,
    whatever the mod's own blend.
  - Keep a z-writing mod's depth.
  - Affects only gear with MTRL mods on this screen.

### 7. WRONG-LABEL: the D3DFMT names in the `0xaac913` correction

- **Where:** `docs/rounds/party719.md:35`.
- **Evidence (READ, asm `0xaaca2f..0xaacbc9`):**
  - The masks compared at `0xaacada..0xaacb1c` are the other channel order: B mask (edx) 0xff0000,
    G 0xff00, R 0xff.
  - That gives **0x20 = D3DFMT_A8B8G8R8** and **0x21 = D3DFMT_X8B8G8R8**.
  - A8R8G8B8 (0x15) and X8R8G8B8 (0x16) are set by the branch above (`0xaaca92`, `0xaaca7a`), where
    the edx mask is 0xff.
- **The substance is right:**
  - it is a texture-format pick from a bitmap header's channel masks, not the model's alpha;
  - `appear_fade.md`'s corrected text (which gives no format names) is right;
  - the new pointer to `FUN_00c428c0` is right. The draw takes the colour from `[esi+0xc8]+0x40` when
    that object exists, else from the compound's `+0x4c` (`0xbf10df..0xbf10fb`).
- **Fix:** name the formats A8B8G8R8 / X8B8G8R8.

### 8. MINOR: stale header comment

- **Where:** `charselect_stage.gd:19-21`. It still says "The models' opacity is
  GeometryInstance3D.transparency on each mesh instance, never the materials".
- **Fix:** point it at `_apply_alpha`'s pairs (the shared materials are still never modified; copies
  are).

### 9. MINOR: restoring to full alpha relies on the lerp landing exactly on 255

- **Where:** `charselect_stage.gd:649` (`if a >= 1.0`).
- **Evidence:**
  - `_tick` ends a fade at `lerpf(from, 255, 1.0)` = `from + (255 − from)`.
  - That is exact for `from ≥ 127.5` (Sterbenz), which covers every real case: 204 → 255, and 0 →
    255 exactly.
  - A restore that started from a fractional alpha below 127.5 (a delete/restore inside the first
    half-second of the list's fade-in) could end one ulp short. The body would then stay on the
    translucent pair (no shadow, finding 2) at alpha 0.99999.
- **Fix:** unfade when `d.alpha_target >= 255` and the fade is finished, or compare
  `a >= 254.5 / 255`.

### 10. PERF (unmeasured): new shaders on every list's fade-in; the depth pass runs the full fragment

- **Where:** `fade_shader` and `_fade_pair`.
- **Evidence:**
  - Every body goes through the pairs on every `set_characters`, because the fade-in starts at 0. The
    first list compiles two new spatial shaders per distinct source shader.
  - The depth pass keeps the whole fragment: texture, lighting and the per-channel Newton inverse tone
    map (`UNDO_TONEMAP`) for ALPHA 0.
  - The perf gate the lane ran measures only the world, which this round cannot touch. The select
    screen's first-list frame times were not measured.
- **Fix:**
  - Log the select screen's longest frame on first entry, before and after.
  - Give the depth pass a minimal fragment: the texture sample and the discard only.

## What was verified and holds

- **0xcc:**
  - `FUN_0085def0` sets `+0x298` to 0xcc when `+0x1e8` (deleting) is set, else 0xff,
    with a 1.0 s fade (`+0x29c = 1.0f`).
  - `FUN_0085f840` (the delete/restore reply) sets 0xcc or 0xff the same way.
  - There is no other value by selection state. Selected or not, the pending character is 0xcc.
- **The update hands the byte to the model:**
  - the per-frame update `0x85dc8a..0x85dd17` skips a byte of 0 and otherwise calls vtable `+0x14`;
  - `CCompChar::FUN_00c25590` stores `byte << 24` at `+0x4c`.
- **`FUN_00c428c0` (objdump):**
  - at 0xff000000 it returns at once;
  - otherwise ALPHABLENDENABLE (0x1b) 1;
  - when ALPHATESTENABLE (0x0f) is on, ALPHAREF (0x18) = `ref × a >> 8`;
  - TEXTUREFACTOR (0x3c) = the colour, SRCBLEND (0x13) 5, DESTBLEND (0x14) 6;
  - stage 0 (`SetTextureStageState`, vtable `+0x10c`): ALPHAOP 3 (SELECTARG2) with flag 0x40000000,
    else 4 (MODULATE); ALPHAARG1 2 (TEXTURE); ALPHAARG2 3 (TFACTOR);
  - **no ZWRITEENABLE (0x0e)**.
- **ZWRITE stays on through the draw:**
  - none of the five draw functions that call it (`bf0e20`, `bf1250`, `bf1840`, `bf29a0`, `bf3e00`)
    writes 0x0e;
  - `CObjRendererVS::vslot_034` sets 0x0e = 1 and ZENABLE 1;
  - `FUN_00c429f0` restores blending (0x1b = 0) and stage-0 ALPHAOP 2 / ALPHAARG2 0;
  - the only writers of ZWRITE 0 near objects are an MTRL mod's own (`CRTModMtrl::vslot_004`, its
    +0x58), `CObjRendererVS::vslot_033` (a no-Z overlay pass) and effects/map code.
- **The ALPHAREF scaling keeps the 128 cut-out under MODULATE:** `tex.a × 0.8 ≥ 128 × 0.8`.
- **The cause:** instance transparency forces the alpha list with the materials' `depth_draw_opaque`
  (no depth in the transparent pass): READ in Godot, and the lane's measurement.
- **The census:**
  - The select stage is the only writer of `GeometryInstance3D.transparency` in `client/scripts`.
    The other `.transparency =` writes are `BaseMaterial3D` modes: terrain, water, blobs, effects,
    AppearFade's twins, `ground_probe`.
  - AppearFade (the world's appear/disappear) uses its own material twins. No stealth or invisibility
    code sets instance transparency.
  - In-game characters are untouched.
- **Material handling:**
  - Two-sided cloth: the depth pass keeps `cull_disabled`, so only the nearest face is coloured.
  - Alpha-tested layers: the `discard` is kept in both passes.
  - Blended layers: colour only, `ALPHA *= select_fade`.
  - A shader `fade_code` cannot rewrite keeps instance transparency.
  - `material_override` and per-surface overrides are both restored at 255, to the exact previous
    override, so a null override comes back null.
- **Switching back and forth and delete/restore:**
  - pairs are made once per Drawn, keyed by source material;
  - the fade uniform is set on every colour pass each `_apply_alpha`;
  - the probe's own report shows `own=14 → fade_pass=14 → own=14`.
- **No leak:**
  - pair materials live on the Drawn and go with `clear_characters`;
  - the static shader cache is keyed by source shader;
  - the source shaders are themselves static caches (`_undo_shaders`, PlayerPortrait's `_shaders`),
    so the cache is bounded.
- **The new test** (`charselect_fade_test.gd`, 15 checks) passes in the full suite.

## Runs (box, RX 7600, Forward+ on Vulkan, 1280x720, `/var/tmp/r719rev/`)

| run | hour | what | result |
|---|---|---|---|
| `anew` | 0.75 (unpinned) | stock `qa_shot.sh`, QA_Aria pending, the lane's probe | finding 3's 0.75 rows |
| `sh_new`, `sh_old` | 0.9583 | probe with body shadows left on (box-copy patch) | reproduces the lane's QA_Aria numbers exactly; shadow_detail=1, so no shadow at all |
| `h1_new`, `h1_old` | 0.5833 | plus an alpha-1/255 shot (box-copy patch) | finding 1's table; finding 3 and 4's 0.5833 rows |
| `sd_new`, `sd_old` | 0.5833 | same, `OPENSRO_QA_VIDEO="shadow_detail=2"` | finding 2, below |

**Finding 2, MEASURED (`sd_*`, Shadow Detail on, QA_Aria, hour 0.5833).** At 255 the body and
its shadow change 17,534 pixels against the background, about 3,576 more than the same view without
shadows (`h1_*`, 13,958).

| drawing | pixels changed at 255 that are back to the background at 0xcc | at alpha 1/255 |
|---|---|---|
| old (instance transparency) | 0: the shadow stays | 5,942 pixels still darker by about 40 a channel: the shadow stays even on an invisible body |
| new (the pairs) | **2,679: the shadow is gone** | the shadow is gone |

So before this round the pending character kept a full-strength shadow, and after it she has none.
Neither is READ against the original.

Every run used `QA_SHOT_REAP=0` on the shared lock, launched only with no other Godot on the box.
The analysis scripts are `ana.py` (the lane's metric plus least squares), `pred.py` (the linear-sheet
and display-blend predictions) and `dep.py` (the 1/255 shot).

## Tests

- `RENDER_DIR=/opt/opensro-client-r719rev GODOT_LOCK=/var/tmp/r719rev/lock remote_godot.sh tests`:
  **232 suites, 0 failing**.
- `... check`: **605 scripts and 9 scenes, ALL LOAD**.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Y12ecfRLgyrW8rPt8BVTF9
