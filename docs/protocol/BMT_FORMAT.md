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
| Flags | `uint32` bitmask. Recorded here until 2026-09-08 as "unconfirmed meaning (observed values 64, 321, 832, 833 — not obviously a flags bitmask or a length)". Written in hex those are `0x040`, `0x141`, `0x340`, `0x341`, which is plainly a mask: bit 6 set in every real value seen, bits 8/9 varying, and **bit 0 varying independently of both**. See "Bit 0: the alpha layer flag" below. Bits 6, 8 and 9 remain unidentified |
| Texture path | `uint32` length + ASCII bytes — **usually a bare filename** (e.g. `"avatar_m_zombie.ddj"`), resolved against whatever directory the `.bmt` itself lives in. **Correction (2026-08-23, live-tested against real Jangan palace materials)**: at least one real layer carries a real **full path** instead (`"prim\mtrl\bldg\china\dunhuang\buildings\naru_obj.ddj"`, pointing at a real directory completely unrelated to the `.bmt` referencing it) — a bare-filename texture path never contains a `\` or `/`, so that's the real, reliable way to tell the two cases apart before resolving. Some layers have no texture (`length` reads as a small value pointing at unrelated data, or the layer is otherwise a pure color/tint layer) — treat a texture-read failure on validation as "no texture" rather than a hard error only when it's clearly not a real string |

Real layers were seen to share the exact same default color set (`ambient=diffuse=(0.588, 0.588,
0.588, 1.0)`, `specular=(0.9, 0.9, 0.9, 1.0)`, `emissive=(0,0,0,1.0)`) across most layers checked
— evidently a shared engine default rather than per-layer authored data, at least for these
particular avatar/flag materials.

**They are not always equal, and which one lights the surface matters** (2026-09-11). The five
fields are a `D3DMATERIAL9` in its own order — ambient, diffuse, specular, emissive, power — and
the fixed-function pipeline multiplies the ambient light by the ambient colour and only the
directional light by the diffuse. Measured with `client/tools/dump_bmt.gd`: every layer of
Jangan's `cj_armo.bmt` has ambient 0.59 and diffuse 0.59, 0.47 or 0.50, while **24 of the 40
layers of Alexandria's `alex_minga02.bmt` have diffuse `(0.14, 0.14, 0.14)` against ambient
`(0.59, 0.59, 0.59)`** (specular 0.39). The client used to set a material's albedo from the
diffuse, which never showed on Jangan's near-equal layers and drew every Alexandria house black; it
now uses the ambient, which is the term a mostly-ambient scene is lit by. The remaining
approximation is stated in `ObjectLoader.build_godot_material`: a `StandardMaterial3D` scales the
sun by the same colour, so a sunlit face of such a layer is brighter here than in the original by
diffuse/ambient until a shader splits the two terms.

**The exact byte length of the gap between one layer's texture filename and the next layer's name
length isn't confirmed.** It doesn't appear to be a fixed, 4-byte-aligned count in every real file
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

## The flag word, READ in the client (round 626)

> **Corrects "Bit 0: the alpha layer flag" below.** The client's per-material state setter was
> found, and it does not read bit 0 as alpha. The correlation below was real but pointed at the
> wrong bit: every alpha layer it lists is `0x341`, which has bit 9 set as well as bit 0.

`CObjRendererVS::FUN_00c42a60(flags)` sets a layer's render states before its triangles are drawn,
and `FUN_00c42b40(flags)` undoes them after. Every object draw path in `CObjRendererVS`
(`FUN_00bf0890`, `FUN_00bf0e20`, `FUN_00bf1250`, `FUN_00bf1840`, `FUN_00bf29a0`, `FUN_00bf2360`,
`FUN_00bf3e00`) passes it the layer's flag word — `*(material + 0x70)`: the runtime material holds
the layer at `+0x10` (its `D3DMATERIAL9` goes to `SetMaterial`, device vtable `+0xc4`), so `+0x70`
is the layer's `+0x60`, the word `PrimMtrlSet::WriteLayer` saves — OR'd with the object's own
flags (`0x1000` by default, set in `CObjRendererVS::vslot_024`). What it does, bit by bit:

| Bit | Mask | Render state (FUN_00c42a60) | Undone to (FUN_00c42b40) |
|---|---|---|---|
| 0 | `0x001` | `D3DRS_CULLMODE` = NONE — **two-sided** | CCW (back faces culled) |
| 2 | `0x004` | `D3DRS_SPECULARENABLE` = TRUE | FALSE |
| 3 | `0x008` | when `FUN_00bc0fd0()`: `D3DRS_LIGHTING` = FALSE, stage-0 `COLOROP` = MODULATE | TRUE, MODULATE2X |
| 9 | `0x200` | unless the object sets `0x20000000`: `D3DRS_ALPHATESTENABLE` = TRUE, `D3DRS_ALPHAREF` = `0x80` | FALSE, `0x80` |
| 12 | `0x1000` | stage-0 `COLOROP` = MODULATE2X | — |
| 28 | `0x10000000` | (caller) skip the setter and `SetMaterial` entirely | |

The compare is `D3DRS_ALPHAFUNC` = 7, GREATEREQUAL (`FUN_00c42860`). **No material bit turns
alpha blending on**: `FUN_00c428c0` enables SRCALPHA/INVSRCALPHA blending only for an object-level
fade colour, and returns at once for an opaque `0xff000000`. Bits 6 and 8 (set in most real words)
are not read by the setter. Two of the seven draw paths (`FUN_00bf0890`, `FUN_00bf2360`) clear bit
0 before the call; which path draws a worn item was not traced. This is the rule `object_loader.gd`'s
scenery materials should move to (the foliage lane, round 625, owns that file's alpha rules).

**Items are the case that separates the bits.** `spear_11` is `0x0141` — bit 0 without bit 9 — so
the client never alpha-tests it, while the old rule cut it at 0.5 into the see-through spear of the
v0.1.457 report. And an item's texture alpha is a graded gloss mask, not a cutout (`blade_14` below):
MEASURED at every triangle's UV centroid (`client/tools/probe_equipment.gd`), the share of the
surface whose alpha is below `0x80` is **81.4%** for the starting sword `sword_01` (`sword1_2_3`,
`0x0340`), **89.1%** for `heavy_11_la` (`0x0341`), **82.5%** for `heavy_11_ha` (`0x0340`) — an
alpha test on that alpha would erase the item. So on a worn item the test cannot be seeing texture
alpha (INFERRED); which stage-0 alpha the item path feeds it is OPEN (the renderer's default,
restored by `FUN_00c429f0`, is `ALPHAOP` SELECTARG1). `SkinnedBsrAssembler.equipment_material`
therefore draws an item layer solid, two-sided when bit 0 is set.

### The seven bytes after the texture path (round 626, READ and MEASURED)

The "gap between one layer's texture filename and the next layer's name" below is a fixed tail:
`CPrimMtrl::FUN_00bf9270` reads the layer (colours into `D3DMATERIAL9` order — the file's first
colour block becomes Ambient, its second Diffuse — then power, the flag word at `+0x60`), and
`FUN_00bf91b0` reads the texture record: the path, then a `uint32` (`+0x1c`) and three bytes
(`+0x20`, `+0x21`, `+0x22`). The third byte is the "path is already a full path" flag:
`CPrimMtrl::FUN_00bf9090` joins the path to the `.bmt`'s own directory only when it is 0. MEASURED
on `heavy_11.bmt`: six layers, each followed by exactly 7 bytes, landing exactly on the file's end
(694); the `uint32` is `1.0f` in all six, the bytes `[32, 8, 0]` on the four layers with bit 9 and
`[24, 0, 0]` on the two without; the third is 0 on all six bare filenames. The first two bytes'
meaning is not read.

## Bit 0: the alpha layer flag

> **Superseded by "The flag word, READ in the client" above**: bit 0 is two-sided culling, bit 9
> is the alpha test. Kept as the record of the correlation.

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
