# BMT material format (JMXVBMT)

`.bmt` is the material format referenced by `.bsr` objects and `.bms` meshes by filename — see
[BSR_FORMAT.md](BSR_FORMAT.md) and [BMS_FORMAT.md](BMS_FORMAT.md). It defines one or more
"layers", each with ambient/diffuse/specular/emissive colors and (usually) a reference to a
`.ddj` texture by bare filename.

Two real on-disk variants exist, both confirmed empirically (byte-level, black-box), and both
decompressing to (or directly containing) something with a `JMXVBMT 0102` magic. No decompiler
output is stored in this repo — only the resulting facts about the container format.

- **Compressed variant**: the whole file (after a 4-byte header) is a standard **zlib stream**.
  Confirmed against 4 real files found not in any pk2 archive available in this client build, but
  in a loose, unpacked server patch-data tree
  (`.../SMC_Independent/.../patch_upload_temp/data/Prim/mtrl/avatar/*.bmt`).
- **Uncompressed variant**: the raw `JMXVBMT 0102` magic sits directly at byte 0, no zlib wrapper
  at all. Confirmed across 3 real files from a live client `Data` tree, not a staging tree
  (`Prim/Mtrl/Char/China/man/{chinaman_warrior,chinaman_bogy,chinaman_monk}.bmt`) — real
  character body/hair material files, referenced by real `.bms` body-part meshes' own
  `material_name` field (see [BMS_FORMAT.md](BMS_FORMAT.md)). Both readers detect this by checking
  for the magic string directly at byte 0 before falling back to the compressed-variant parse.

## File layout

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 4 | `uint32`: decompressed size of everything after this field |
| 0x04 | ... | A zlib stream (standard `zlib.NewReader`-compatible), decompressing to exactly the byte count above |

## Decompressed layout

| Field | Encoding |
|---|---|
| Magic | `"JMXVBMT 0102"` (12 bytes) |
| Layer count | `uint32` |
| Layers | that many layer records, back-to-back (see below) |

## Layer record

| Field | Encoding |
|---|---|
| Name | `uint32` length + ASCII bytes (e.g. `"avatar_m_zombie"`, or a generic `"Material #88"` — some layers are unnamed/default) |
| Ambient | 4× `float32` (RGBA) |
| Diffuse | 4× `float32` (RGBA) |
| Specular | 4× `float32` (RGBA) |
| Emissive | 4× `float32` (RGBA) |
| Power | `float32`, unconfirmed meaning (observed constant `0.0` in every real layer checked — plausibly specular power/shininess, never actually populated in these samples) |
| Flags | `uint32` bitmask — **the layer's render-state word, READ in round 625** (see "The flag word, READ" below): `0x200` = alpha test (ALPHAREF 0x80, GREATEREQUAL), `0x1` = two-sided (cull none), `0x4` = specular on, `0x8` = lighting off. Values seen across the map's trees and the item, character, monster and NPC trees of Data.pk2: `0x0340`, `0x0341`, `0x0140`, `0x0141`, `0x0040`, `0x0041`, `0x0345`, `0x2345`, `0x2145`, `0x2341` |
| Texture trailer | **READ (round 625)**, `CPrimMtrl::FUN_00bf91b0`, which reads the texture path and then, unconditionally: a `uint32` (into the runtime material's **+0x90** — the layer struct's +0x80, the struct sitting at material +0x10; meaning not read) and three bytes (runtime +0x94..+0x96). The third byte non-zero means the path is a full archive path used as is; zero means a name beside the `.bmt` (`CPrimMtrl::FUN_00bf9090`). **These seven bytes are the "gap" this document used to call unknown** (next row's note); the readers now step over exactly seven and scan only if that does not land on a name |
| Texture path | `uint32` length + ASCII bytes — **usually a bare filename** (e.g. `"avatar_m_zombie.ddj"`), resolved against whatever directory the `.bmt` itself lives in. **Correction (2026-08-23, live-tested against real Jangan palace materials)**: at least one real layer carries a real **full path** instead (`"prim\mtrl\bldg\china\dunhuang\buildings\naru_obj.ddj"`, pointing at a real directory completely unrelated to the `.bmt` referencing it) — a bare-filename texture path never contains a `\` or `/`, so that's the real, reliable way to tell the two cases apart before resolving. Some layers have no texture (`length` reads as a small value pointing at unrelated data, or the layer is otherwise a pure color/tint layer) — treat a texture-read failure on validation as "no texture" rather than a hard error only when it's clearly not a real string |

Real layers were seen to share the exact same default color set (`ambient=diffuse=(0.588, 0.588,
0.588, 1.0)`, `specular=(0.9, 0.9, 0.9, 1.0)`, `emissive=(0,0,0,1.0)`) across most layers checked
— evidently a shared engine default rather than per-layer authored data, at least for these
particular avatar/flag materials.

**They are not always equal, and which one lights the surface matters** (2026-09-11). Measured
with `client/tools/dump_bmt.gd`: every layer of Jangan's `cj_armo.bmt` has first colour 0.59 and
second 0.59, 0.47 or 0.50, while **24 of the 40 layers of Alexandria's `alex_minga02.bmt` have a
second colour `(0.14, 0.14, 0.14)` against a first `(0.59, 0.59, 0.59)`**. From 2026-09-11 to round
705 the client drew a layer's albedo from the first colour (BmtReader `ambient`), lit by Godot's sun.

**Round 706 (READ, sro_client.exe): the object shader uses the SECOND colour, and only it.**
`CPrimMtrl::vslot_001` hands `this + 0x10` to `FUN_00bf9270`, which stores the file's first colour
at the record's +0x10 and the second at its +0 -- the record is a `D3DMATERIAL9` (Diffuse, Ambient,
Specular, Emissive, Power) and the file's order is Ambient, Diffuse, Specular, Emissive, Power, so
BmtReader's names are right -- then Power at +0x40 and the flag word at +0x60 (the material's
+0x70, where the draw reads it). The object renderer uploads `c11 = material+0x10 (the record's
Diffuse = the file's SECOND colour) x the light's diffuse` (`CObjRendererVS::FUN_00bf0e20`) and
`c10 = the drawn object's colour (0.6, CCompoundObj) x the light's ambient` (`vslot_024` /
`vslot_038`): the first colour (D3DMATERIAL9.Ambient) is in no object lighting. An Alexandria wall
whose second colour is 0.14 is therefore lit as `0.6 x La + N.L x 0.14 x Ld` -- the ambient term
does not depend on the material, so it does not go black. `ObjectLight` has the whole formula and
its addresses; object.gdshader / foliage.gdshaderinc and the MTRL mod shader evaluate it per vertex.
Specular and Power are not used by the object vertex shaders (no oD1).

**Settled in round 625: the gap is seven bytes** (the texture trailer above, READ). What follows is
the earlier record, kept for the staging-tree caveat. **The exact byte length of the gap between one
layer's texture filename and the next layer's name length isn't confirmed.** It doesn't appear to be a fixed, 4-byte-aligned count in every real file
checked. One real file's last declared layer also had a texture-length field pointing past the
end of the file — plausibly because that sample came from a `patch_upload_temp` (staging) tree
and was itself an incomplete/in-progress export, not necessarily a real format edge case. Rather
than guess at a fixed trailer size, our reader scans forward for the next plausible
length-prefixed ASCII name (the same technique used for `.bsr`'s mesh/material path list) to find
each subsequent layer, and stops gracefully (returning whatever layers parsed successfully) if it
can't — a caller can compare the parsed layer count against the file's declared count to notice.

## Implementation notes

- `server/internal/bmt` (Go): parses the zlib wrapper (via the standard `compress/zlib` package)
  and every layer's confirmed fields; unit tested (`go test`) against a synthetic fixture (never
  real game data, same policy as the other formats).
- `client/scripts/bmt/bmt_reader.gd` (GDScript): the client-side mirror. Notably, it does **not**
  use Godot's built-in `PackedByteArray.decompress(..., FileAccess.COMPRESSION_DEFLATE)` — that
  was confirmed to fail (return 0 bytes) on a real `.bmt` file's zlib stream that a standard zlib
  implementation decodes correctly, evidently a correctness gap in the engine's bundled
  decompressor for some class of otherwise-valid DEFLATE streams. Instead,
  `client/scripts/bmt/inflate.gd` is a from-scratch, standalone RFC 1951 (DEFLATE) decoder
  (stored/fixed-Huffman/dynamic-Huffman blocks), verified against streams produced by Python's
  zlib (an independent, known-correct implementation) and against the real `.bmt` file that
  exposed the engine bug in the first place.
- `client/scripts/assets/object_loader.gd` resolves a material's texture-referencing layer
  against a real `.ddj` file (via `DdjReader`) and applies it as a Godot `StandardMaterial3D`'s
  albedo texture on the corresponding mesh piece — verified end-to-end in
  `object_loader_test.gd` against a full synthetic pk2 archive containing a real
  pk2→bsr→bms→bmt→ddj chain.
- A real `.bms` body-part mesh's `material_name` field (e.g. `"chinaman_body"`, baked into
  `man_thigh.bms`) is the same string as the real `layer_name` of a layer inside a real
  character `.bmt` (confirmed directly: `chinaman_warrior.bmt`'s first layer is named
  `"chinaman_body"` and references `chinaman_warrior_body.ddj`) — `World3D.gd` uses this real
  name match (not an index-based guess) to resolve each assembled body part's own real texture.
  See `docs/PROGRESS.md` for the real screenshot this produced.

## The flag word, READ (round 625)

The reader and the render path are both in `sro_client.exe`:

- `CPrimMtrl::vslot_001` (0x00bf93d0) calls `FUN_00bf9270(stream, material + 0x10)`, which reads
  the name, the four colour blocks (file order ambient, diffuse, specular, emissive into member
  +0x10, +0x00, +0x20, +0x30), Power into +0x40 and **the flag word into member +0x60**, i.e. the
  runtime material's **+0x70**; then `FUN_00bf91b0` reads the texture path and its trailer.
- Every draw path of `CObjRendererVS` — `FUN_00bf0e20`, `FUN_00bf1250`, `FUN_00bf1840`,
  `FUN_00bf29a0`, `FUN_00bf3e00`, and the fixed-function fallbacks `FUN_00bf0890` /
  `FUN_00bf2360`, which clear bit 0 first — takes `material + 0x70 | renderer + 0xd4`, lets the
  object's runtime mods edit it (`FUN_00c451e0`), and unless `0x10000000` is set hands it to
  `FUN_00c42a60` before the draw and `FUN_00c42b40` after it:

| Bit | `FUN_00c42a60` sets | `FUN_00c42b40` restores |
|---|---|---|
| `0x1` | `D3DRS_CULLMODE` = `D3DCULL_NONE` | `D3DCULL_CCW` |
| `0x4` | `D3DRS_SPECULARENABLE` = TRUE | FALSE |
| `0x200`, unless `0x20000000` | `D3DRS_ALPHATESTENABLE` = TRUE, `D3DRS_ALPHAREF` = `0x80` | FALSE, `0x80` |
| `0x8` (when `FUN_00bc0fd0()`, the night flag) | `D3DRS_LIGHTING` = FALSE, stage-0 COLOROP 4 (the draw also takes the vertex shader's NOLIGHT, oD0 = 1: [night_lights.md](night_lights.md), round 806) | TRUE, COLOROP 5 |
| `0x1000` (renderer-set) | stage-0 COLOROP = 5 (MODULATE2X) | — |

- The renderer's begin (`FUN_00c42860`, `CObjRendererVS` slot 3) sets `D3DRS_ALPHAREF 0x80` and
  **`D3DRS_ALPHAFUNC` = 7, `D3DCMP_GREATEREQUAL`**: a texel is kept when its alpha byte is 128 or
  more.
- **What alpha is tested (world objects, READ):** the same begin sets texture stage 0
  `D3DTSS_ALPHAARG1` = `D3DTA_TEXTURE`, and `FUN_00c429f0` leaves stage 0 `ALPHAOP` =
  `SELECTARG1` after any object fade. So the alpha test compares the **texture's** alpha. Only the
  fade path, `FUN_00c428c0`, mixes in the texture factor.
- **The flag word never blends.** `D3DRS_ALPHABLENDENABLE` comes only from an **MTRL mod** (below)
  or from `FUN_00c428c0` for an object's own fade colour (SRCALPHA / INVSRCALPHA with a texture
  factor). A layer without `0x200` and without an MTRL mod is drawn opaque whatever its texture's
  alpha holds. (Round 625 first wrote "no per-material blend exists"; that is true of the flag word
  only. Corrected in its review follow-up.)
- **Environment-map mods override the test, for the whole object.** `CRTModEnvMap::vslot_004`
  (0x00c83690) ORs `0x60000000` into the flags (the `0x20000000` above) and sets its own test:
  `ALPHATESTENABLE` = (header word 5, +0x1c, `& 2`), and when on, `ALPHAFUNC` GREATEREQUAL with
  `ALPHAREF` **1**. **Both happen before it compares its header's material index (word 3, +0x14)**
  (asm 0xc836a5, compare at 0xc83715); the compare gates only the reflection texture. It runs:
  - for header word 1 = 2, on every material's draw (`FUN_00c451e0` → `FUN_00c7b540`);
  - for word 1 = 1, once per object with index −1 and the renderer's own flag word
    (`CObjRendererVS::vslot_038` → `FUN_00c45110` → `FUN_00c7b4e0`).

  Either way it governs every material of the object. The round-625 reading ("applied to the
  material whose index equals word 3") was wrong. Its measured victims were the 0x341 layers of
  `bagh_masin_lf` (`_03`/`_04`, 88 % and 68 % of their UV surface below 128), cut at 128 where
  the client cuts at 1, and `fort_stone_ct05`.
- **BUMPENV (0x40001) is not an env map here.** `CRTModBumpEnv::vslot_004` (0x00c83c30) sets
  texture stages only, never the flags or the alpha test.
- **MTRL mods (kind 0) set a material's states themselves.** READ, `CRTModMtrl::vslot_004`
  (0x00c821f0), for the material its header names (word 1 = 2) or for every material (word 1 = 1,
  material 0xFFFFFFFF, applied once per object as above). The body is read by
  `ModDataMtrl::vslot_004` (0xc626c0), and its last 36 bytes are:

  | Offset | Size | Meaning | What the client sets |
  |---|---|---|---|
  | +0x50 | u32 | alpha test | `ALPHATESTENABLE`, with `ALPHAREF` = byte +0x68 and `ALPHAFUNC` = byte +0x69 |
  | +0x54 | u32 | blend | `ALPHABLENDENABLE`, with `SRCBLEND` = +0x60, `DESTBLEND` = +0x61, and stage 0 `COLOROP`/`ARG1`/`ARG2`/`ALPHAOP`/`ARG1`/`ARG2` = +0x62..+0x67 |
  | +0x58 | u32 | z-write off | `ZWRITEENABLE` FALSE |
  | +0x5c | u32 | texture factor | `TEXTUREFACTOR` = the mod's colour |
  | +0x60 | 16 bytes | the bytes above, two unread, a u32 unread | |
  | +0x70 | u32 | 1 = cull none | `CULLMODE` NONE |

  It also ORs `0x10000000`, so the flag word's own states (`FUN_00c42a60`) are not set at all.
  Header flag bit 2 (`& 4`) of the mod adds specular, and the mod's animated colour replaces the
  layer's (both OPEN here). The water objects (`dun_cen_water01`..`06`,
  `air_garden8_water01/02`, `air_garden40_water_ani01/02` and the `gngwc_` copies, the turtle
  waterfalls) are all SRCALPHA/ONE or SRCALPHA/INVSRCALPHA MTRL mods over 0x340 layers whose
  texture alpha is 38–100 % below 128. Under the flag word alone they vanished.
- **Two passes (`.bsr` header 0x2C bit 1).** `CObjRendererVS::vslot_038` draws such an object with
  `FUN_00bf5780`: every material with `CULLMODE` CW (back faces), then CCW (front faces), in place
  of `FUN_00bf5700`'s single pass (`euro_esteuro_fountain01`, `alex_potion`).
- **ProgEquipPow.** `CRTModProgEquipPow::vslot_004` ORs `0xe21f0000` (so `0x10000000` too: no
  material state at all). It is attached only for enhanced gear (`FUN_00a5f3e0` → the compound's
  slot 50 → `CCompChar::FUN_00c350a0`, gated on a per-slot byte).

`client/scripts/assets/object_loader.gd` (`layer_draw_rule`) implements this:
- `0x200` → the foliage shader's scissor at 128/255;
- `0x1` → two-sided;
- the object's env-map mod → its own reference (1/255 or none) on every material;
- an MTRL mod → its own test (any D3DCMPFUNC, compared exactly on the mip-0 alpha byte), blend,
  z-write, cull and stage-0 ops, in a shader built per combination (see "The MTRL mod shader"
  below);
- two-pass → back faces then front faces when blended, and two-sided otherwise. The front pass
  is drawn by a twin MeshInstance3D (`ObjectLoader.add_front_pass`) at priority 0 with a
  `sorting_offset` of 0.01. A `next_pass` alone is not ordered (Godot 4.2's transparent sort is
  not stable), and a higher `render_priority` is global: it drew the front faces over every
  nearer transparent surface (MEASURED, rounds 623-628 integration review).

### The MTRL mod shader (round 625-626 material review follow-up)

- **Stage 0.** When the mod blends, all six stage bytes are applied as the client sets them
  (READ, `CRTModMtrl::vslot_004`); 0 is `D3DTA_DIFFUSE`, not "unset". The ops the census uses
  are all evaluated as d3d9 defines them: colour 2, 4, 5, 6, 7, 8, 9 (ADDSIGNED2X) and 20
  (MODULATEINVALPHA_ADDCOLOR), alpha 2-7 and 15 (BLENDTEXTUREALPHAPM). Any other op is drawn as
  MODULATE (OURS; `ObjectLoader.stage_ops_handled` reports it). The D3DTA modifiers 0x20
  ALPHAREPLICATE and 0x10 COMPLEMENT are applied, though no census mod sets either. A mod that only tests
  leaves the renderer's own stage 0 in place: MODULATE2X of TEXTURE and DIFFUSE (READ: the
  renderer seeds flag `0x1000`, which `FUN_00c42a60` makes COLOROP 5).
- **Stage 1 (round 786).** A MULTITEX mod on the same material adds texture stage 1 over stage
  0's result: `lerp(stage 0, texture, texture alpha)` (op 1, BLENDTEXTUREALPHA) or by the mod's
  TEXTUREFACTOR alpha (op 0, BLENDFACTORALPHA), unlit, the alpha left as stage 0 made it; a mode-1
  TEXANI scrolls its coordinates. READ in BSR_FORMAT.md ("MULTITEX / MULTITEXREV"). Every MULTITEX
  material placed in the world is under an MTRL mod (MEASURED), so the mod shader carries the stage
  (`multitex_op`, -1 for none); object.gdshaderinc has a `MULTITEX` variant for the rest.
- **DIFFUSE is the lit vertex colour** (READ, `Shader\vertexshader0.c`):
  `oD0 = saturate(N.L) * c11 + c10`. The registers are:
  - `c11` (`VSC_DLIGHT_DIFFUSE`) = the material's D3DMATERIAL9 Diffuse (the layer's second colour,
    round 706 above) × the light's Diffuse (READ: `CObjRendererVS::FUN_00bf0e20` and siblings
    upload material+0x10.. × `DAT_01112e18..20`, w = 1.0). `DAT_01112e18..` is the D3DLIGHT9
    Diffuse and `..e28..` its Ambient, copied by `CObjRendererVS::vslot_025` beside `SetLight(0)`.
  - `c10` (`VSC_DLIGHT_AMBIENT`) = the object's own colour (+0x14..+0x1c) × the light's Ambient,
    w = 1.0 (READ, round 705: `vslot_024` 0xbf1df8..0xbf1e37, uploaded at 0xbf1f4e..0xbf1f60).
  - `c9` = the light's direction × -1 in object space (unnormalised).

  Since round 706 the shader computes it per vertex (`ObjectLight.OD0_LINE`), unshaded, and the
  stage result is evaluated whole. Until then it split the result into the part that multiplies
  DIFFUSE (ALBEDO, lit by Godot's lights) and the part that does not (EMISSION), with the lit
  coefficient anchored to the old flag-word path (L × first colour / 2, OURS).
- **The tone map** is undone on an opaque or `mix` mod's colour (as on every object since round 706,
  `ObjectLight`), not on an `add` or `mul` blend's, whose source is a factor (OURS).
- **The alpha test** compares the alpha byte with the ref byte by the mod's own D3DCMPFUNC
  (NEVER, LESS, EQUAL, LESSEQUAL, GREATER, NOTEQUAL, GREATEREQUAL). It reads mip 0, as the
  foliage shader does (OURS: the client tests filtered alpha, and mipmapped alpha dissolves a
  canopy with distance); the blend uses the filtered alpha.
- **The blend pairs.** Godot 4.2's GL Compatibility blends are mix (SRC_ALPHA / 1−SRC_ALPHA), add
  (SRC_ALPHA / ONE) and mul (DST_COLOR / ZERO) (`rasterizer_scene_gles3.cpp`). Every one of the
  18 D3DBLEND pairs in the census is drawn through them by choosing the colour and alpha the
  shader writes (`ObjectLoader.BLEND_EMULATION`). Each is labelled:
  - **exact**: 5/6, 5/2, 2/2, 9/1, 1/3, 12/2, 13/6;
  - **given**: 3/6 and 3/14 (the SRCCOLOR sources) are exact only for an unlit stage result: a
    lit one is squared before Godot's light, so it is drawn light × L², not (light × L)².
    `D3DRS_BLENDFACTOR` = white, its D3D default, is also needed for 5/14, 3/14 and
    15/15. The client sets it only in `Map::FUN_00a1d790`, and whether that value is live for
    objects is OPEN. Destination alpha = 1 (a back buffer without alpha, INFERRED) makes 5/7
    and 2/11 given too;
  - **ours**, with the dropped term named:
    - 5/13: BOTHINVSRCALPHA as a destination factor, which D3D leaves undefined;
    - 3/3: `src·src` dropped;
    - 2/4, 5/5, 5/4, 2/3, 10/2, 2/9: a destination- or colour-weighted term drawn as plain
      add.

Items take no rule of their own: their own ENVMAP mods spare their graded alpha (round 626, READ).

**The item census behind that (round 626, MEASURED, `client/tools/census_item_envmap.gd`).**
Across the item table's 1,421 item `.bsr` files: 602 have an ENVMAP flag word of 1 (no test:
solid), 465 of 3 (test at 1: only alpha-0 texels cut), 3 others, and 351 none. Every one checked
is in the `ambient` set with header word 1 = 1 and material `0xFFFFFFFF`: run once per part, as
above. Of 2,890 bit-9 layers on item models, 2,535 are under a mod; the 355 left to their own
test at `0x80` are the 1-bit DXT1 hats, Santa hats, mittens and flags. Examples: `sword_01`
0x0340 + env 1 → solid; `spear_11` 0x0141 + env 1 → solid, two-sided; `heavy_11_la` 0x0341 + env
3 → cut at alpha 0; `clothes_04_ha`'s card 0x0341, no mod → cut at 128. Stage-0 alpha is the
texture's (`FUN_00c42860` sets `ALPHAARG1` = TEXTURE), so without the mod the gloss alpha would be
cut.

## Bit 0: the alpha layer flag (superseded by the READ above)

**Superseded in round 625: bit 0 is cull-none, and the alpha test is bit 9 (`0x200`).** Every
alpha layer in the table below has both; the correlation was real and the reading of it was not.
It broke on 0x340 layers — alpha-tested one-sided cards (pine and bamboo needles, 44 tree models)
drawn as solid slabs — and on 0x141 (two-sided, untested). The original text follows.

**Bit 0 of a layer's flag word means the layer's texture alpha is a cutout mask to be honoured.**

It separates real alpha layers from real solid ones with no exceptions across every real material
checked:

| Layer | Flags | Measured alpha |
|---|---|---|
| `tre_willow02_leaf01` / `_leaf02` | `0x341` | 79% of texels below opaque |
| `c_swamp_tree02_01` / `_02` | `0x341` | 75.5% |
| `tre_tree02_01` (leaf card) | `0x341` | 68,299 texels fully transparent |
| `tre_dry02` | `0x341` | 39,749 fully transparent |
| `CJ_w_alpha` (a city gate's alpha mesh) | `0x341` | — |
| `CJ_pal_bigdoor_roof02_al` / `roof03_al` | `0x341` | — |
| `tre_willow02_will01` (branches) | `0x340` | solid |
| `tre_tree02_02` / `_03` (bark) | `0x140` | solid |
| `blade_14` | `0x340` | 97.8% non-opaque, but **all graded** — a gloss ramp, not a mask |
| `CJ_w_wall01`..`05`, `CJ_w_stair`, `CJ_pal_bigdoor_wall01` | `0x140` | solid |

Two things corroborate it independently of the pixels. The **authored naming convention**: every
real layer whose name ends in `_al` — the artists' own abbreviation for alpha — has bit 0 set, and
no solid layer does. And the flag **draws a line the pixels cannot**: `blade_14` is 97.8%
non-opaque yet is not an alpha layer, because that alpha is a graded gloss ramp rather than a
cutout mask, and no threshold on "how transparent is this texture" can tell those apart.

### The character materials say the same thing (2026-09-20, round 280)

Every layer in the table above is scenery. Characters are an entirely separate material family,
authored by different people for a different pipeline, and they agree:

| Material | Layer | Flags | |
|---|---|---|---|
| `chinaman_fighter.bmt` | `chinaman_body` | `0x0340` | solid |
| `chinaman_fighter.bmt` | `chinaman_hair` | **`0x0341`** | the hair cutout |

`chinaman_adventurer.bmt` has the same two-layer shape. So bit 0 separates body from hair in
exactly the way it separates bark from leaf, in a family nobody had checked when the rule was
written.

The hair texture backs it up as a measurement rather than an impression:
`chinaman_fighter_hair.ddj` is **DXT1**, and decoding it through this project's own reader leaves
**6.52 % of its 32,768 texels non-opaque** -- a real cutout mask, not a gloss ramp.

That last number also disproved a hypothesis worth recording: DXT1 is often said to lose its
1-bit alpha when handed to an engine as BC1, which would have made the flag moot. It does not --
measured, not assumed.

**Not yet confirmed against the client binary.** The evidence is now a perfect correlation across
~25 scenery layers in four unrelated materials plus the character family, and the naming
convention. Reading the flag out of the real material loader would still settle it, and is worth
doing: the writers are all located (see below), the reader is not.

### What the client binary confirms

The material **writer** was located in `sro_client.exe` and settles the record layout from the
engine's own side. `FUN_00bf8ad0` (asserting against
`D:\Project\SilkroadOnline\TOOLS & PLUGINS\SimpleViewer\objengine\PrimMtrlSet.cpp`) writes the
magic as three integers — `0x56584d4a` `0x20544d42` `0x32303130`, i.e. `JMXV`, `BMT `, `0102`,
the usual never-stored-as-text convention — then the layer count, then calls `FUN_00bf8970` once
per layer.

That per-layer serializer writes, in order: the length-prefixed name, four 16-byte colour blocks
(from struct dwords 4–7, then 0–3, then 8–11, then 12–15), then **one dword from struct offset
0x40** (Power), then **one dword from struct offset 0x60** (the flag word), then the texture path.

So the flag word is confirmed to be **a real, distinct field of its own** — not padding, not a
length, and not part of the neighbouring float — and it sits at a fixed place in the runtime
material structure. That is what the binary establishes.

**Bit 0's meaning is still inferred**, from the correlation and naming convention above rather
than from code. The runtime render path sets its states numerically, with no alpha-test strings
anywhere in the binary to anchor a search, so confirming it means finding where the dword at
material+0x60 is tested. Not yet done.

## A retexture is a new .bmt naming a new .ddj (round 789, MEASURED)

Retail's own colour variants are made this way: `avatar_m_knight_3.bmt` is `avatar_m_knight.bmt`
with the texture `avatar_m_knight.ddj` (a bare name) replaced by
`prim\mtrl\item\etc\avatar_m_knight_3.ddj` (a full path), and nothing else changed but the
texture trailer: `20 08 00` after the bare name, `00 00 01` after the full path. The third byte
is the full-path flag (READ above); the first two are OPEN. `server/cmd/retexture` renames a
texture path and keeps every other byte, and refuses a rename between a bare name and a full path
rather than guess those two bytes: a copy keeps its base's form.
