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

## Bit 0: the alpha layer flag

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

**Not yet confirmed against the client binary.** The evidence is a perfect correlation across ~25
real layers in four unrelated real materials, plus the naming convention. Reading the flag out of
the real material loader would settle it, and is worth doing.
