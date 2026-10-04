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

Measured with `OPENSRO_QA_PENDING_PROBE` (below): (TO FILL)

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
  alone for an opaque layer. (TO FILL: measured texture alpha of the bodies tested.)

It also works under the Compatibility renderer, which ignores instance transparency (round 676).

## Regressions checked

(TO FILL)

## Tests

(TO FILL)
