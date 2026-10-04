# Round 719: a character pending deletion is one even translucent sheet on the select screen, as the original draws it

The user (2026-10-04), on the native Linux build: "There also seems to be some rendering issues
when deleting a character that weren't there original. When they sit some parts of them become
transparent." Their two screenshots of our client show the select screen with a character pending
deletion, seated: arms, dress, face and a shoulder strap show the harbour through them, unevenly.
They run the native `opensro-linux.zip` (Godot Forward+ on Vulkan), the renderer the render box
uses, so the box reproduces it.

Labels: READ (the client exe, with addresses), MEASURED, INFERRED, OURS.

## What the original does (READ, sro_client.exe)

- **The pending alpha.** `FUN_0085def0` sets a pending character's target alpha to **0xcc**
  (`+0x298`; 0xff otherwise), fading over 1.0 s, as round 684 read. The per-frame update
  (`0x85dc8a..0x85dd17`) hands the current byte (`+0x29a`) to the model through its vtable `+0x14`:
  **`CCompoundObj` slot 5, `CCompChar::FUN_00c25590`, `+0x4c = alpha << 24`**.
- **How a model below 0xff is drawn.** The object draw (`0xbf10df..0xbf110b`, and four more call
  sites at `0xbf15d5`, `0xbf1c00`, `0xbf2d62`, `0xbf4213`) passes that colour and the layer's flag
  word (`material + 0x70`) to `CObjRendererVS::FUN_00c428c0` (`0xc428c0`, objdump):
  - at `0xff000000` it returns at once: no state is touched;
  - otherwise ALPHABLENDENABLE 1, SRCBLEND 5 (SRCALPHA), DESTBLEND 6 (INVSRCALPHA), TEXTUREFACTOR =
    the colour; with alpha testing on, ALPHAREF is scaled to `ref x a >> 8`;
  - stage 0 alpha: with flag `0x40000000`, ALPHAOP SELECTARG2 with ARG2 TFACTOR (the fade's alpha
    alone); without it, ALPHAOP MODULATE of TEXTURE and TFACTOR;
  - **ZWRITEENABLE is not touched**: the model keeps writing depth as every object does
    (`CObjRendererVS::vslot_034` sets it to 1 for the object pass). `FUN_00c429f0` turns blending
    back off after the draw.

  So the original draws a translucent character mesh by mesh in its own order with depth written:
  a near piece drawn first hides a far piece drawn later. It is not depth-sorted and has no prepass.
- **Not a render mode.** `appear_fade.md` said `FUN_00aac913` "picks a render mode" from the
  compound's `+0x4c` (0xff000000 -> 0x20, 0 -> 0x21). The code at `0xaacafd` compares a bitmap
  header's channel masks (`[ebp+0x4c]` with `[ebp+0x60]`/`[ebp+0x64]` beside it) to pick a texture
  format: D3DFMT 0x20 A8R8G8B8 / 0x21 X8R8G8B8. It has nothing to do with the model's alpha.
  Corrected in `appear_fade.md`.

## The cause in OpenSRO (MEASURED)

Since round 684 the select screen set `GeometryInstance3D.transparency` on every mesh of the body.
The bodies wear PlayerPortrait's materials (round 688): `render_mode unshaded, <cull>,
depth_draw_opaque` with no blend. Instance transparency sends each mesh to Godot's transparent
pass, where `depth_draw_opaque` writes **no depth**, and sorts the meshes by their centres. So the
body's pieces blend over each other in sorted order: a far piece drawn after a near one shows
through it, a two-sided cloth layer shows its back faces, and the background shows through
wherever the pieces stack up differently.

**MEASURED** with `OPENSRO_QA_PENDING_PROBE=1` (OURS, QA; `CharacterSelect._qa_pending_probe`). The
probe selects the pending character, so the camera flies to her as in the user's screenshot. It then
holds the pose and the camera and switches the bodies' shadows off, and saves one frame four ways:
hidden (bg1), at 255 (O), at 0xcc (P), hidden again (bg2). A pixel counts where the opaque body
differs from the background (|O-B| >= 90 summed over RGB) and the background did not move
(|bg1-bg2| <= 6). Its effective alpha is sum(P-B) / sum(O-B): one even sheet gives one value
everywhere. `OPENSRO_QA_SELECT_INSTANCE_FADE=1` draws the old way on the same build. Box, RX 7600,
Forward+, 1280x720:

| pending character | drawing | body px | p5 | median | p95 | in 0.65..0.95 | below 0.5 | above 1.05 |
|---|---|---|---|---|---|---|---|---|
| QA_Wei (man, seated) | before (instance transparency) | 19,461 | 0.337 | 0.772 | 1.213 | 73.2 % | 5.7 % | 9.5 % |
| QA_Wei | after (the pairs) | 21,407 | 0.667 | 0.763 | 0.978 | 89.6 % | 1.4 % | 2.8 % |
| QA_Aria (woman, dress, seated; `OPENSRO_QA_PENDING_NAME`) | before | 6,521 | 0.467 | 0.836 | 0.933 | 88.0 % | 5.3 % | 1.4 % |
| QA_Aria | after | 6,514 | 0.667 | 0.845 | 0.883 | 95.9 % | 1.2 % | 0.5 % |

"Below 0.5" is the background showing through a piece; "above 1.05" is a far piece blended over a
near one (darker or lighter than the opaque body). Both shrink about four-fold. The spread left
(p25..p75 about 0.72..0.86) is not the pieces: Forward+ blends in linear light and then tone-maps,
so the same alpha reads differently on light and dark texels in the display. The original blends
in display space, where 0xcc is 0.8 everywhere. That residual is the renderer's and is not changed
here. A first probe that did not hold the camera gave numbers that meant nothing (the camera was
still settling in SELECTED); it is not used.

## The fix (OURS on the READ above)

`CharSelectStage._apply_alpha`: below 255 every mesh of the body draws through a pair made from
its own material (`fade_code`, `_fade_pair`):

- a **depth pass**: the material's own shader with `blend_mix, depth_draw_always` and `ALPHA =
  0.0` at the end of `fragment()` (alpha test kept), at render priority `FADE_DEPTH_PRIORITY`
  (-100), so the whole body's depth is in before any of its colour;
- its **colour pass** as `next_pass`: the same shader with `blend_mix, depth_draw_never` and
  `ALPHA = select_fade` (or `ALPHA *= select_fade` for a layer that blends itself), the fade's
  alpha in the uniform.

So only the body's nearest surface is drawn, blended over what lies behind it: one even sheet. A
blended layer (hair cards and the like) gets the colour pass only, its own alpha times the fade (a
depth pass would let its clear texels hide what is behind them). A material that is not a
ShaderMaterial this can rewrite keeps instance transparency, as before. At 255 every mesh gets its
own material back. The pairs are made once per body.

How this differs from the original, named:
- **Draw order.** The original writes depth in its own mesh order, so where it happens to draw a
  far piece before a near one the far piece shows faintly through. The prepass shows only the
  nearest surface everywhere. OURS: Godot sorts transparent meshes by distance, so the original's
  order cannot be reproduced; the prepass gives the result the original gives wherever its order
  is near-first.
- **Texture alpha.** For a layer without flag `0x40000000` the original modulates the texture's
  alpha into the fade (READ above); OpenSRO's materials do not carry that flag word, and the
  opaque PlayerPortrait shader never used texture alpha, so the colour pass's alpha is the fade's
  alone for an opaque layer. MEASURED (`QA PENDING TEXTURE`, QA_Aria's 14 meshes): the clothes
  have no alpha; the skin and face textures average 0.991, 0.9 % of texels below 0.5. So the term
  changes nothing on the body or the dress. It would on the **weapon** (`sword_01`, mean 0.330, 77.1 %
  below 0.5: a gloss mask) and a little on the **hair** (0.781, 21.9 %). The original would draw a
  pending character's sword fainter than her body, unless its layer has flag `0x40000000`, which
  was not read. Not reproduced; OPEN.

It also works under the Compatibility renderer, which ignores instance transparency (round 676).

## Regressions checked

- **Only the select screen draws this way.** MEASURED by census: the select stage is the only
  writer of `GeometryInstance3D.transparency` on a body in `client/scripts` (the other `transparency`
  writes are material modes, plus `ground_probe.gd`'s own material). So in-game characters, sitting
  with N included, and the world's appear and disappear fades (AppearFade's own twins, round
  676/677) draw exactly as before. This round's diff touches only `CharacterSelect.gd`,
  `frontend/charselect_stage.gd`, a new test and docs.
- **The opaque characters on the select screen** keep their own materials. The probe's line per
  capture counts the pending body's meshes: at 255 `own=14 fade_pass=0`, at 0xcc `own=0
  fade_pass=14`, back to `own=14` at 255. Their meshes are never touched (`_apply_alpha` at 255 only
  gives back what it took).
- **The fade-in** (0 to 255 over 1.0 s on every list) runs through the same pairs and ends on the
  originals.
- **Compatibility renderer:** the pairs are ordinary materials, so the pending character is now
  translucent there too (instance transparency is ignored by Godot 4.2's GL Compatibility, round
  676). Not rendered under Compatibility this round.

## Tests

- `client/scripts/frontend/charselect_fade_test.gd` (new, 15 checks): `fade_code` on PlayerPortrait's
  real opaque and blended shaders. The depth pass keeps the layer's modes and alpha test, writes
  depth and no colour. The colour pass blends without depth and takes the fade, not the texture
  alpha, for an opaque layer. A blended layer gets no depth pass and multiplies its own alpha. A
  canvas shader, or one with no `render_mode`, is not rewritten. The line lands at the end of
  `fragment()`, not in a later function. 0 failures.
- Box (`RENDER_DIR=/opt/opensro-client-r719`, lane lock): `check` 605 scripts and 9 scenes, ALL LOAD.
  Full suite: 232 suites, 0 failing.
- Live, box, stock `qa_shot.sh --scene res://scenes/CharacterSelect.tscn` on the shared lock, no
  server (`OPENSRO_QA_FAKECHARS=3`): the table above. Frames: `/var/tmp/r719/{old,new,aold,anew}/`
  (bg1, opaque, pending, bg2 .png) and crops `/var/tmp/r719/aold_crop.png`, `anew_crop.png`.
- Perf gate (`perf_gate.sh --base dev --sites jangan --frames 12000`, base `f6989ea9`, 3 runs each,
  RX 7600 Forward+). The change is select-screen only and the gate's views are in the world, so
  this is the record that the world is untouched:

  | jangan | base | head | verdict |
  |---|---|---|---|
  | frame ms | 1.46 | 1.47 | SAME |
  | entry ms | 9429 | 9453 | SAME |
  | freeze ms | 3273 | 3273 | SAME |
  | hitches | 4 | 4 | SAME |

  The first two attempts never measured: lane 718's `qa_shot.sh` killed the base run mid-way (its
  reap stops every Godot on the box), and a wait-for-idle loop timed out while other lanes kept
  rendering.

## QA hooks added (OURS)

- `OPENSRO_QA_PENDING_PROBE=1`: the measurement above (CharacterSelect).
- `OPENSRO_QA_PENDING_NAME=<name>`: that fake character is the pending one.
- `OPENSRO_QA_SELECT_INSTANCE_FADE=1`: the drawing before this round, on one build.

## Open

- The texture-alpha term on layers without flag `0x40000000` (the weapon, the hair), above.
- The original's draw order within a body (the prepass shows only the nearest surface everywhere).
- Tone-mapped blending (the residual spread above).
