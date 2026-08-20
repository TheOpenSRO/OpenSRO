# BMS mesh format (JMXVBMS)

`.bms` is the triangle-mesh geometry format, referenced by `.bsr` "static object" resource files
— see [BSR_FORMAT.md](BSR_FORMAT.md). Reverse-engineered the same way as the pk2 fix in
[PK2_FORMAT.md](PK2_FORMAT.md): decompiling the real loader in `sro_client.exe` to confirm field
offsets, then cross-checking the result against real extracted files until the numbers made sense
(sane unit normals, UVs in `[0,1]`, a bounding box matching the actual vertex extents). No
decompiler output is stored in this repo — only the resulting facts about the container format.

Implemented in `server/internal/bms` (Go) and `client/scripts/bms/bms_reader.gd` (GDScript),
matching field-for-field; the GDScript side also builds a real Godot `ArrayMesh` for rendering
(`BmsReader.to_array_mesh()`), used by `client/tools/render_asset.gd`.

### Header (fixed 0x48 = 72 bytes, version `"0110"`)

| Offset | Size | Field                                                        |
|-------:|-----:|-----------------------------------------------------------------|
| 0x00   | 12   | Magic, `"JMXVBMS 0110"` (no separate version field — it's part of the magic string) |
| 0x0C   | 4    | Unconfirmed (observed value matching file-relative byte offset of something near the name string; not needed to parse) |
| 0x10   | 4    | `hdr[0]`: offset of a 4-byte zero field immediately before the index section (unconfirmed purpose beyond that) |
| 0x14   | 4    | `hdr[1]`: **offset of the index section** (triangle count + index array) |
| 0x18   | 4    | `hdr[2]`: offset of a single unconfirmed float (observed 0) |
| 0x1C   | 4    | `hdr[3]`: offset of a single unconfirmed float (observed 0) |
| 0x20   | 4    | `hdr[4]`: **offset of the bounding box** (6 floats: min xyz, max xyz) |
| 0x24   | 4    | `hdr[5]`: offset of 2 trailing unconfirmed floats (observed 0, 0) at/near EOF |
| 0x28   | 8    | Reserved (observed 0 across all 18 real meshes checked in `Particles.pk2`, **and** across 4 real character meshes checked from `Prim/Mesh/Char/Europe/man/` — `europeman_devil_hair.bms`, `europeman_devil_face.bms`, `europeman_barbarian_face.bms`, `europeman_knight_hair.bms` — so whatever distinguishes a skinned/character mesh from a static one, it isn't here; see the vertex-record note below for where a real per-vertex difference *was* found) |
| 0x30   | 4    | Unconfirmed offset-shaped field (observed pointing near EOF; not used by our reader) |
| 0x34   | 8    | Reserved (observed 0) |
| 0x3C   | 4    | Flag/count of unconfirmed meaning (observed constant 1) |
| 0x40   | 8    | Reserved (observed 0) |

The header's own pointer table (`hdr[1]` for indices, `hdr[4]` for the bounding box) is what our
reader uses to locate those two sections — not offset arithmetic from the vertex count — since
several header fields above aren't understood yet and might change the layout for meshes we
haven't seen (skinned meshes, multiple sub-groups, etc).

### Name and vertex/index data (starting at 0x48)

| Field | Encoding |
|---|---|
| Mesh name | `uint32` length + that many ASCII bytes |
| Material name | `uint32` length + that many ASCII bytes |
| (unconfirmed `uint32`, observed constant 1) | |
| Vertex count | `uint32` |
| Vertex array | `vertex count` × 44-byte records, immediately following |
| *(gap, located via `hdr[1]`)* | |
| Triangle count | `uint32`, at file offset `hdr[1]` |
| Index array | `triangle count` × 6 bytes (3× `uint16`), immediately following |
| Bounding box | 6× `float32` (min xyz, max xyz), at file offset `hdr[4]` |

### Vertex record (44 bytes)

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 4 | Position X (`float32`) |
| 0x04 | 4 | Position Y |
| 0x08 | 4 | Position Z |
| 0x0C | 4 | Normal X (`float32`) |
| 0x10 | 4 | Normal Y |
| 0x14 | 4 | Normal Z |
| 0x18 | 4 | UV.u (`float32`) |
| 0x1C | 4 | UV.v |
| 0x20 | 12 | Unconfirmed as a whole, but its internal structure is now well confirmed across 4 real character meshes (`europeman_devil_hair.bms`, `europeman_devil_face.bms`, `europeman_barbarian_face.bms`, `europeman_knight_hair.bms`) — see "The 12 trailing vertex bytes" below. The first 4 bytes (0x20-0x23) are 0 on every vertex checked, in every file. |

Position/Normal/UV were confirmed two ways: by decompiling the real vertex-array loader
(`sro_client.exe`, reached via the same `JMXVBMS 0110` magic-construction code as the `.bsr`
loader) which reads a `count`-prefixed array of 44-byte (`0x2C`) records, and by extracting a real
`.bms` file and finding the position/normal/UV values sane (a flat "Rectangle01" ground mesh: all
normals `(0,1,0)`, all UVs in `[0,1]`, and a bounding box that exactly matches the extracted
vertex position range).

## The 12 trailing vertex bytes: two real vertex classes found

Investigated whether real character meshes (hair/face pieces — the only skinned-looking meshes
available in this environment; no full skinned body mesh was found, only equippable-armor-style
static pieces) populate the header's reserved 0x28 field or otherwise carry visible skinning data
(bone indices/weights). They don't populate the header field (see above), but pulling and
byte-inspecting 4 real files (`europeman_devil_hair.bms`, 147 verts; `europeman_devil_face.bms`,
166 verts; `europeman_barbarian_face.bms`, 181 verts; `europeman_knight_hair.bms`, 312 verts —
all via `server/internal/bms`, which parses every one of them without error) found a real,
consistent pattern in the previously-opaque 12 trailing vertex bytes: **every vertex falls into
exactly one of two classes**, split roughly 60/40 in every file checked:

- **Class A** (the majority): bytes 0x24-0x27 read as `FFFFFFFF`, bytes 0x28-0x2B read as `0`.
  This is the "opaque white color" pattern noted in the previous version of this doc.
- **Class B**: bytes 0x24-0x25 are a **`uint16`** whose value, across every vertex in every file
  checked, always falls inside `[0, vertex count)` for that same mesh — i.e. it looks like an
  index back into this mesh's own vertex array, not a color or a bone index. (Confirmed as a
  16-bit field rather than an 8-bit one on `europeman_knight_hair.bms`, whose 312 vertices exceed
  a single byte's range: the class-B values there go up to `0x0123` = 291, spanning both bytes.)
  Bytes 0x26-0x27 are always 0. Bytes 0x28-0x2B read as the constant `2`.

Plausible reading: bytes 0x24-0x2B are one `uint32` "linked vertex index" field (`0xFFFFFFFF` =
"none") followed by one `uint32` "vertex flags" field (`0` = plain, `2` = has a link) — consistent
with something like a hair-strand physics anchor/pair reference, not skinning (there's no
accompanying weight float, and the index values are too large and too varied to be per-vertex
bone indices for any plausible bone count). **Not confirmed via decompilation**, so not promoted
to typed struct fields yet — `Vertex.Extra` stays raw bytes in both readers, per this project's
policy of not mislabeling a field before its semantics are nailed down (see `.bsk`'s transform
bytes for the same policy applied elsewhere).

## Implementation notes

- `server/internal/bms` (Go): reference parser, unit tested (`go test`) against a synthetic
  fixture built to the layout above (never real game data, same policy as `server/internal/pk2`).
- No GDScript reader yet — this is prep work for the eventual 3D rendering pass, not wired into
  the client.
- Open items before this is "done" for rendering purposes: confirm the 12 unconfirmed trailing
  bytes per vertex record. `.bsr` and `.ddj` are now both solved — see
  [BSR_FORMAT.md](BSR_FORMAT.md) and [DDJ_FORMAT.md](DDJ_FORMAT.md).
