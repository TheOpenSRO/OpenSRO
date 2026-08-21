# BSR resource format (JMXVRES)

`.bsr` is a lightweight "static object" descriptor: a header, a name, a reference to a primary
`.bms` (mesh) + `.bmt` (material) pair, a bounding box, and a count-prefixed list of further
`.bms` paths for objects assembled from multiple pieces (e.g. a building made of separate
wall/column/stair/tile meshes). See [BMS_FORMAT.md](BMS_FORMAT.md) for the mesh format itself.

Confirmed two ways: empirically against real extracted `.bsr` files (the same black-box technique
used for pk2/bms/ddj), and by decompiling the real runtime loader in `sro_client.exe` — traced
through `FUN_00bed8d0` (identified via a literal path string reading `...SimpleViewer\objengine\
ResourceMgr.cpp`, error message `"ResObj Data Loading Failed [%s]"`) down to `FUN_00bce3b0`
(`ResObject.cpp`), which validates the magic byte-for-byte: bytes 4-7 must equal `"RES "`, bytes
8-11 must equal `"0109"`. No decompiler output is stored in this repo — only the resulting facts.

## Header (fixed 0x44 = 68 bytes before the name string's length field)

Same general shape as `.bms`'s header (magic + an unconfirmed `uint32` + a `hdr[0..5]` offset
table + reserved fields), but 4 bytes shorter before the name string. The `hdr[]` offset table's
exact semantics aren't confirmed for `.bsr` — one field that looked like a pointer to the mesh
path in several real files turned out to be a fixed constant that didn't hold for every file
checked, so our reader doesn't rely on it (see "Implementation notes" below).

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 12 | Magic, `"JMXVRES 0109"` — confirmed via the real client's validator |
| 0x0C | 4 | Unconfirmed |
| 0x10 | 4 | `hdr[0]`, unconfirmed |
| 0x14 | 4 | `hdr[1]`, unconfirmed |
| 0x18 | 4 | `hdr[2]`, unconfirmed |
| 0x1C | 4 | `hdr[3]`, unconfirmed |
| 0x20 | 4 | `hdr[4]`, unconfirmed |
| 0x24 | 4 | `hdr[5]`, unconfirmed |
| 0x28 | 4 | Observed constant `152` across every real file checked — despite looking exactly like a byte offset to the mesh path string in most of them, it did **not** hold for one real file, so it isn't trustworthy as a pointer |
| 0x2C-0x40 | 20 | Reserved (observed 0) |
| 0x40 | 4 | Two `uint16` fields, both observed as `2` |
| 0x44 | 4 | Name length (`uint32`) |
| 0x48 | ... | Name string (ASCII, not null-terminated — length-prefixed) |

## After the name

| Field | Encoding |
|---|---|
| (2 unconfirmed `uint32` fields, observed values 10 and 2) | |
| (reserved padding, observed ~40 zero bytes in well-formed files) | |
| Mesh path | `uint32` length + ASCII bytes |
| Bounding box + tail | 6× `float32` (min xyz, max xyz), then `float32` ×6 sentinel padding (`FLT_MAX`/`-FLT_MAX`, an "uninitialized" idiom) and 3× `uint32` (observed `0, 1, 0`) — 60 bytes total, confirmed in 2 of 3 real files; one had 4 extra leading zero bytes and effectively no mesh path (see below) |
| Material path | `uint32` length + ASCII bytes |
| Sub-mesh count | `uint32` |
| Sub-mesh paths | that many `uint32`-length-prefixed ASCII paths, back-to-back, no gaps |

The sub-mesh count is self-validating: in every real file checked, it exactly matched the number
of further `.bms` paths actually present before the file's trailing boilerplate. A fixed 20-byte
block (byte-identical in every file checked: `0010000000000000000000000000000001000000`) followed
by a length-prefixed string `"default"` appears at the very end of every file checked — likely a
default material/group name — but its exact role isn't confirmed.

## Sub-mesh pieces need no separate transform

Confirmed against two real sub-mesh pieces of the same `.bsr` object (`asiaminor_theater02_
brokenwall01.bms` and `asiaminor_theater02_column01.bms`, pulled from a full unpacked client data
tree, not a pk2): each piece's own bounding box is already large-scale and independently
positioned (e.g. `x:[-1024, 761], z:[-1720, 271]` vs. `x:[-1397, 1446], z:[-1427, 304]`) — not
centered at the origin. Each `.bms` piece carries its own absolute position baked directly into
its vertex data. There is no missing per-part transform to find in `.bsr`; placing every piece at
`Vector3.ZERO` relative to the object root, exactly what `ObjectLoader` already does, is correct.

## A known edge case

One of the three real files checked (`asiaminor_theate06r_brokenwall01.bsr`, notably a
typo'd/oddly-named file whose *material* path referenced a different object, `theater04`, not
`theater06`) appears to have an **empty mesh path** — the byte sequence right after the two
unconfirmed header ints is a much longer run of zero padding (76 bytes instead of ~40) leading
straight into the bounding-box block and then the material path, with no mesh path string at all
in between. This looks like a stray/incomplete authoring artifact rather than the norm, but it
means the format can have a legitimately-empty mesh path that our reader doesn't yet handle — it
fails with a clear error on that file rather than silently returning wrong data, which is the
correct failure mode until this is understood better.

## A real, unresolved gap: the `res\nature\...` (tree/grass) category doesn't parse correctly

Found while wiring up real `.mapo` object rendering (see `docs/protocol/MAPO_FORMAT.md`'s object
index section): real `res\bldg\...` (building) files — the category this format was originally
derived against, e.g. `cj_ferry_stone01.bsr` — parse correctly, sub-meshes and all. Real
`res\nature\...` files (e.g. `euro_esteuro_tree07_l03.bsr`, `oas_grs_weed04.bsr`) do not: the
scanned-for "mesh path" comes out pointing at a `.bmt` (material) file instead of a `.bms`, and
the "material path" that follows is a garbage 1-character string. Checked on two different real
nature-category files with the same result, so this looks like a real, systematic difference in
how this category's `.bsr` files are laid out, not a one-off bad file — but the actual layout
difference hasn't been found yet. Not yet root-caused or fixed; `ObjectLoader`/`World3D.gd` skip
these gracefully (a real printed reason, not a fabricated placeholder) rather than rendering wrong
data.

## Implementation notes

- `server/internal/bsr` (Go): parses name, mesh path, bounding box (best-effort — skipped rather
  than guessed at if the gap between mesh and material paths is too short to plausibly contain
  one), material path, and the sub-mesh path list. Rather than trust the header's offset table
  (shown above to be unreliable), it locates the mesh and material path strings by scanning
  forward for the first plausible length-prefixed ASCII path — the same technique used to
  cross-check every real file during RE, and the only approach that worked correctly on all of
  them (building-category files, at least — see the real gap above). Unit tested (`go test`)
  against a synthetic fixture (never real game data).
- `client/scripts/bsr/bsr_reader.gd` (GDScript): mirrors the Go implementation field-for-field,
  used at runtime by `ObjectLoader` to build real, textured `Node3D`/`MeshInstance3D` trees.
