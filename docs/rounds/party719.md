# Round 719: a character pending deletion is one translucent sheet on the select screen (blended in Godot's linear buffer, not in the original's display values)

The user (2026-10-04), on the native Linux build: "There also seems to be some rendering issues
when deleting a character that weren't there original. When they sit some parts of them become
transparent." Their two screenshots of our client show the select screen with a character pending
deletion, seated: arms, dress, face and a shoulder strap show the harbour through them, unevenly.
They run the native `opensro-linux.zip` (Godot Forward+ on Vulkan), the renderer the render box
uses, so the box reproduces it.

Labels: READ (the client exe, with addresses), MEASURED, INFERRED, OURS, DEPARTURE.

## What the original does (READ, sro_client.exe)

- **The pending alpha.** `FUN_0085def0` sets a pending character's target alpha to **0xcc**
  (`+0x298`; 0xff otherwise), fading over 1.0 s (round 684). The per-frame update
  (`0x85dc8a..0x85dd17`) hands the current byte (`+0x29a`) to the model through its vtable `+0x14`:
  **`CCompoundObj` slot 5, `CCompChar::FUN_00c25590`, `+0x4c = alpha << 24`**.
- **How a model below 0xff is drawn: `CObjRendererVS::FUN_00c428c0`** (objdump), called by the
  object draws (`0xbf110b` and four more sites) with the colour (`[esi+0xc8]+0x40` when that
  object exists, else the compound's `+0x4c`) and the layer's flag word (`material + 0x70`):
  - at `0xff000000` it returns at once;
  - otherwise ALPHABLENDENABLE 1, SRCBLEND 5 (SRCALPHA), DESTBLEND 6 (INVSRCALPHA), TEXTUREFACTOR =
    the colour; with alpha testing on, ALPHAREF = `ref x a >> 8`;
  - stage 0 alpha: flag `0x40000000` gives ALPHAOP SELECTARG2 (ARG2 TFACTOR: the fade alone);
    without it, ALPHAOP MODULATE of TEXTURE and TFACTOR (texture alpha x fade);
  - **ZWRITEENABLE is not touched**: the body writes depth, mesh by mesh in its own order.
  - In `CObjRendererVS::FUN_00bf0e20` the object's mods (`FUN_00c451e0`), then the flag word's
    states, then the fade are set in that order, so the fade's blend and stage-0 alpha override an
    MTRL mod's own (round 719's review, finding 6).
- **Where `0x40000000` comes from** (the review, READ in Data.pk2 and the asm): no `.bmt` layer of
  `Prim\Mtrl\Item` or `Prim\Mtrl\Char` has it (3,263 layers). Its sources are runtime mods:
  `CRTModEnvMap::vslot_004` ORs `0x60000000` into every material of an env-mapped object, and
  `CRTModProgEquipPow::vslot_004` ORs `0xe21f0000` for enhanced gear. So a plain body or item layer
  is drawn at `tex.a x 0.8`, and an env-mapped or enhanced one at 0.8 exactly.
- **Not a render mode.** `appear_fade.md` said `FUN_00aac913` "picks a render mode" from the
  compound's `+0x4c`. The code at `0xaacafd` compares a bitmap header's channel masks to pick a
  texture format: there **0x20 = D3DFMT_A8B8G8R8, 0x21 = D3DFMT_X8B8G8R8** (B mask 0xff0000, G
  0xff00, R 0xff; A8R8G8B8 0x15 / X8R8G8B8 0x16 are the other branch, `0xaaca92`/`0xaaca7a`).
  Unrelated to the model's alpha; corrected in `appear_fade.md`.
- **The shadow of a character at 0xcc** is not read (`appear_fade.md`, OPEN).

## The cause (MEASURED)

Since round 684 the select screen set `GeometryInstance3D.transparency` on every mesh. The bodies
wear PlayerPortrait's materials (`unshaded, <cull>, depth_draw_opaque`, no blend). Instance
transparency sends each mesh to Godot's transparent pass, where `depth_draw_opaque` writes **no
depth**, sorted mesh by mesh: far pieces of the body blend over near ones and two-sided cloth shows
its back faces. Measured below as the linear-sheet residual of the "before" rows.

## The fix

`CharSelectStage._apply_alpha`: below 255 every mesh draws through a pair made from its own
material (`fade_code`, `_fade_pair`):
- a **depth pass** (the material's shader with `blend_mix, depth_draw_always`, `ALPHA = 0.0`, alpha
  test kept) at render priority **0**, so the terrain's overlays and water (-3) and the shadow
  catcher (-2) are drawn first and stay behind her;
- its **colour pass** as `next_pass`, at the source's priority **+ 1**: `blend_mix` (also over a
  mod's own blend, READ above), `depth_draw_never`, and the original's stage-0 alpha: `ALPHA =
  mix(1.0, t.a, select_use_tex) * select_fade` -- texture alpha x fade, or the fade alone for an
  object with an env-map mod (`SkinnedBsrAssembler.ENV_MAPPED_META`, set from the BSR's
  `env_map_flags`, carried by PlayerPortrait's copy). A blending layer that writes no depth gets the
  colour pass only; a blending mod that writes depth keeps a depth pass.
- a **shadows-only twin** of each faded mesh on its own materials, so the body keeps its shadow
  (OURS: as before this round, at full strength; the original's is not read).

At alpha >= 254.5 every mesh gets its own material back and its twin is freed.

**DEPARTURE: the blend is in Godot's linear buffer, the original's in display values.** The
original mixes `0.8 x O + 0.2 x B` in the D3D9 back buffer; Forward+ blends before its Filmic tone
map. Doing the original's arithmetic in the colour pass would need what lies behind her in display
values: `hint_screen_texture` is captured after the opaque pass (INFERRED from Godot 4.2's
documented behaviour, not read in its source), so the transparent water, overlays and shadow catcher
behind her would be missing from it -- finding 1's error again. Not done; measured below.

ProgEquipPow (enhanced gear) is not drawn by this client, so an enhanced item takes `tex.a x 0.8`
where the original takes 0.8: OPEN.

## Measurements (MEASURED)

`OPENSRO_QA_PENDING_PROBE=1` selects the pending character, holds pose and camera, and saves one
frame hidden (bg1), at 255 (O), at 0xcc (P), at 1/255 and hidden again (bg2).
`OPENSRO_QA_SELECT_INSTANCE_FADE=1` draws the old way on the same build. QA_Aria (woman, dress,
seated) pending, hour pinned (`OPENSRO_QA_TITLE_HOUR`), bloom off (`OPENSRO_QA_VIDEO=bloom=0`), box
RX 7600 Forward+ 1280x720. Body pixels: |O-B| >= 90 (RGB sum) with a still background. Residuals are
|P - prediction|, RGB sum. Script: `/var/tmp/r719/r719_alpha.py`.

| hour | drawing | one sheet (linear): median / p90 / p99 / >15 | original's mix 0.8 O + 0.2 B: median / p90 / p99 / >15 |
|---|---|---|---|
| 0.5833 | before | 1.4 / 33.7 / 181.5 / 19.4 % | 17.0 / 50.0 / 183.0 / 54.2 % |
| 0.5833 | after | **1.0 / 4.5 / 25.3 / 1.7 %** | 13.6 / 31.6 / 56.2 / 45.3 % |
| 0.75 | before | 1.3 / 32.6 / 173.7 / 18.0 % | 17.4 / 39.6 / 180.6 / 56.5 % |
| 0.75 | after | **1.0 / 4.6 / 23.5 / 1.7 %** | 14.6 / 29.2 / 50.2 / 48.2 % |
| 0.9583 | before | 1.5 / 17.7 / 118.4 / 12.0 % | 9.8 / 24.8 / 132.8 / 26.2 % |
| 0.9583 | after | **1.1 / 4.1 / 23.9 / 1.4 %** | 8.2 / 19.4 / 40.4 / 17.2 % |

- **One sheet.** After the fix the frame is one sheet blended in Godot's linear buffer to within 25
  levels (RGB sum) in 99 % of body pixels at every hour; before, 12-19 % of pixels were off by
  more than 15 (the pieces drawn over each other). The numbers no longer depend on the hour.
- **The original's own blend** (DEPARTURE): after the fix 17-48 % of body pixels are more than 15
  from `0.8 O + 0.2 B`, median 8-15; that is the linear-vs-display difference, largest at bright
  hours.
- **The 1/255 check** (the review's finding 1): at alpha 1/255, inside the body, no pixel is off the
  background by more than 15 at any hour (the review measured 1,010 with the depth pass at -100);
  257 / 151 / 29 pixels exceed the strict 1/255 allowance by a few levels, which the linear blend's
  dark-end gain explains.
- **The shadow** (`OPENSRO_QA_VIDEO=bloom=0,shadow_detail=2`, `OPENSRO_QA_PENDING_SHADOWS=1`, hour
  0.5833): at 0xcc no pixel the body changes at 255 is back at the bare ground (0, as before the
  round; the review measured 2,679 without the twins); 14 shadow twins. At 1/255 the shadow is
  still at full strength in both old and new (3,190 / 3,189 pixels off by more than 15): kept, not
  faded (OURS above).
- **Fade-in frame time** (`OPENSRO_QA_SELECT_FADEIN_FRAMES=1`, the longest wall-clock frame over the
  first 3.0 s after the scene is usable, movie-maker mode writing PNGs): before 188.8 / 192.4 /
  196.6 / 196.2 ms, after 193.0 / 190.3 / 195.2 / 187.3 ms. The pairs add no measurable hitch above
  the frame the scene already has at that point; the first "after" run (cold for the new shaders)
  is 4 ms above its "before".
- The first measurement of this round (before the review) did not pin the hour; its table and its
  "four-fold" claim are withdrawn.

## Texture alpha on the bodies tested (MEASURED, `QA PENDING TEXTURE`)

Over each texture image (not its UV surface): QA_Aria's clothes have no alpha; skin and face
average 0.991. The sword's texture (an atlas, `sword1_2_3.bmt`, layer flag `0x340`: 128 alpha test)
averages 0.330 over the whole image, and the hair (`0x341`: alpha-tested, two-sided, not blended)
0.781 -- those are mostly the cut-out areas, not what is drawn. The kept texels' alpha over the
UV surface was not measured; with the fix they draw at `tex.a x 0.8` as the original's do.

## Review fixes (independent review `ef5cab72`, `docs/rounds/party719_review.md`)

| # | finding | fix |
|---|---|---|
| 1 | depth pass at -100 hides the water, overlays and shadow catcher behind her | depth at 0, colour at source + 1; the probe's 1/255 shot checks it: 0 pixels off by more than 15 |
| 2 | no shadow from the pairs | shadows-only twin on the own materials (full strength, as before; OURS until the original's is read); measured with Shadow Detail on |
| 3 | measurement compared different hours | re-measured at three pinned hours, bloom off, against the linear-sheet prediction; old table and "four-fold" withdrawn |
| 4 | linear vs display blend | not feasible with the screen texture (it lacks the transparent background); labelled DEPARTURE with the numbers; the title corrected |
| 5 | texture alpha, flag 0x40000000 | colour alpha = `tex.a x fade`, the fade alone for an env-mapped object (READ rule); ProgEquipPow OPEN; hair/sword wording corrected |
| 6 | fade overrides a mod's blend | the colour pass is `blend_mix` whatever the layer's blend; a z-writing mod keeps a depth pass |
| 7 | D3DFMT names | A8B8G8R8 / X8B8G8R8 |
| 8 | stale header comment | points at `_apply_alpha`'s pairs |
| 9 | unfade relied on the lerp landing on 255 | unfade at alpha >= 254.5 |
| 10 | fade-in cost unmeasured | measured: no hitch above the existing ~190 ms frame; the depth pass keeps the full fragment (not shortened) |

## Regressions checked

- Only the select screen draws this way: it is the only writer of `GeometryInstance3D.transparency`
  on a body in `client/scripts`; in-game characters (sitting included) and the world's fades are not
  on this path. This round also adds one `set_meta` per body material built from a BSR with an
  env map (`SkinnedBsrAssembler`) and copies it in PlayerPortrait; nothing reads it but the select
  screen.
- The other characters keep their own materials; the pending body's meshes go `own=14 ->
  fade_pass=14 (+14 shadow twins) -> own=14`.

## Tests

- `charselect_fade_test.gd` (18 checks): both passes on PlayerPortrait's real shaders, the alpha
  rule, a blended layer, an additive mod mixed under the fade and keeping its depth, shaders not
  rewritten, the tail placement. 0 failures.
- Box (`RENDER_DIR=/opt/opensro-client-r719`, lane lock): `check` 605 scripts and 9 scenes ALL
  LOAD; full suite 232 suites, 0 failing.
- Perf gate (`--base dev --sites jangan --frames 12000`, base `f6989ea9`, 3 runs; rerun because
  `SkinnedBsrAssembler` and PlayerPortrait changed): frame 1.46 -> 1.48 ms, entry 9453 -> 9572 ms,
  freeze 3275.5 -> 3293 ms, hitches 4 -> 4, all SAME.

## QA hooks (OURS)

`OPENSRO_QA_PENDING_PROBE`, `OPENSRO_QA_PENDING_NAME`, `OPENSRO_QA_PENDING_SHADOWS`,
`OPENSRO_QA_SELECT_INSTANCE_FADE`, `OPENSRO_QA_SELECT_FADEIN_FRAMES`.

## Open

- The original's blend in display values (DEPARTURE above).
- The original's shadow of a character at 0xcc.
- ProgEquipPow's `0x40000000` for enhanced gear (this client draws no ProgEquipPow).
- The original's draw order within a body (the depth pass shows only the nearest surface).
