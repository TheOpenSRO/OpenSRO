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
| 0x28   | 4    | **Offset of the collision section** — the mesh's own navigation mesh (see [Collision section](#collision-section-the-objects-own-navigation-mesh) below). `0` when the mesh has none, which is the common case (3,534 of 4,000 real meshes sampled). Previously documented here as "reserved, observed 0", which it was in the only samples then to hand — particle and character meshes, neither of which a character stands on |
| 0x2C   | 4    | Reserved (observed 0 in all 507 real meshes with a collision section) |
| 0x30   | 4    | Unconfirmed offset-shaped field (observed pointing near EOF; not used by our reader) |
| 0x34   | 4    | Reserved (observed 0) |
| 0x38   | 4    | **Collision section record-size bitfield** (see below). `0` in 449 of 507 real meshes with a collision section; observed values `0, 4, 5, 6, 7, 8, 14` |
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
| (unconfirmed `uint32`, observed values 12/92/5/0 — not a reliable per-file signal for anything, see below) | |
| Vertex count | `uint32` |
| Vertex array | `vertex count` × a real per-file record size (44 or 52 bytes — see "Two real vertex record sizes" below), immediately following |
| *(gap, located via `hdr[1]`)* | |
| Triangle count | `uint32`, at file offset `hdr[1]` |
| Index array | `triangle count` × 6 bytes (3× `uint16`), immediately following |
| Bounding box | 6× `float32` (min xyz, max xyz), at file offset `hdr[4]` |

## Two real vertex record sizes (found 2026-08-23, live-testing real Jangan palace buildings)

Every real sample this project had checked before now (small character hair/face/body-part
meshes, real 2-3-piece scenery props) used a real 44-byte vertex record. **Live-testing real,
larger Jangan palace buildings surfaced giant, wildly misplaced dark triangles in the rendered
scene** — pulling one real culprit directly (`cj_pal_bigdoor_roof01.bms`, 676 vertices) and
decoding it at the documented 44-byte stride produced real `NaN` values and normals hundreds of
units long (impossible for a real unit normal) starting at vertex 1. The file's own header
(`hdr[1]`, the real index-section offset) doesn't divide evenly by 44 either: `(hdr[1] - vertex
array start) / vertex_count` computes to a real, non-integer 52.1 for this file.

**Re-decoding the same real file at a 52-byte stride** (8 bytes more per vertex — position+normal+uv
unchanged, 20 trailing bytes instead of 12) makes all 676 real vertices decode with a real
unit-length normal and zero `NaN`s, and the resulting mesh's own computed vertex bounding box
lands **exactly** on the file's own separately-stored, real declared bounding box (`hdr[4]`) — about
as strong a confirmation as this project's black-box technique can produce.

**No real per-file flag reliably distinguishes the two sizes.** The "unconfirmed `uint32` before
vertex count" field (previously documented as "observed constant 1") is not constant at all once
building meshes are checked: real values seen are 12, 5, 0 on real 52-byte files and 92, 0 on real
44-byte files — 0 appears on both, ruling it out as a flag. Both readers (`BmsReader`/`bms`)
instead pick whichever real candidate size (44 or 52 — the only two sizes confirmed so far) makes
every real vertex's normal come out unit-length, the same self-validating technique this project
already uses for `.m`'s own two real per-vertex sizes (see `MAPM_FORMAT.md`). `Vertex.Extra` is
correspondingly now a variable-length real trailing-byte slice (12 or 20 bytes) rather than a fixed
array, since its real length depends on the detected size.

This was found precisely *because* this project's earlier real samples were all small,
simple objects (2-4 sub-mesh pieces, character attachments) — real complex, multi-hundred-vertex
building meshes exercise a code path those samples never did. See `docs/PROGRESS.md`'s 2026-08-23
"found real Jangan" follow-up entry for the full account, including the giant-black-triangle
symptom this fixes.

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

## Per-vertex skinning: a bone palette and two weighted influences

**Corrected 2026-09-09.** The section below concluded that `.bms` carries no skinning and that
characters are rigid multi-part assemblies. **That is wrong**, and the reasoning shows exactly how:
it accounted for every byte of the 44-byte vertex record, found no room for weights, and stopped.
The weights are real — they are simply **not in the vertex record**. They are in their own section,
and header word 0 (`0x10`) points at it.

That header word was being read (`hdr[0]`) and never used.

### Layout

At `hdr[0]`: a `uint32` bone count, then that many length-prefixed bone names — the **palette**.
Immediately after it, one 6-byte record per vertex, running up to the index section at `hdr[1]`:

| Size | Field |
|---|---|
| `uint8` | bone 0 — index into the palette |
| `uint16` | weight 0 — `65535` is full weight |
| `uint8` | bone 1 — `0xFF` means "no second influence" |
| `uint16` | weight 1 |

Two influences per vertex, maximum.

### How it was confirmed

Not by pattern-matching a plausible layout — by measuring every byte position across a real file's
vertices. In `chinaquest_priest_part1.bms` (280 vertices, a 20-bone palette):

```
byte 0: range 0..19   in-palette 280/280   <- always a valid bone index
byte 1: range 83..255  0xFF in 209
byte 2: range 85..255  0xFF in 209
byte 3: range 0..255   in-palette 71       <- the second bone, when there is one
byte 4: range 0..253   zero in 209
byte 5: range 0..127   zero in 209
```

Byte 0 is a valid palette index for **every** vertex, with a palette of exactly 20. And decoding
the pairs as 16-bit weights gives the property nothing else would: **they sum to full scale**. A
vertex bound to one bone reads `65535 + 0`; a 50/50 blend reads `32765 + 32765`. Across
`mangnyang_part1.bms`, **0 of 263** vertices have an out-of-palette index and **0 of 263** have
weights that miss full scale, worst error `0.00056`.

The semantics are right too, which is the check that no accident passes:

```
Bip01 L Forearm 0.579  +  Bip01 L Hand      0.420     (a wrist)
Bip01 R Clavicle 0.500 +  Bip01 R UpperArm  0.500     (a shoulder)
```

A few percent of vertices are **not** normalised on disk — 8 of 280 in the priest, worst 33% off —
so both readers normalise rather than trust, because an unnormalised weight stretches its vertex.

### What this changes

Characters are properly skinned, not rigid assemblies. The consequence was visible: with rigid
attachment, every mesh piece hangs off a single bone, so animating a humanoid swung its whole dress
or torso and tore the model apart — measured as a pair of renders, the same NPC a spike with
animation on and correct with it off. With real skinning the same NPC stands in her red dress
holding a fan, animated.

`SkinnedBsrAssembler` now builds a real `Skin` (bound by name, bind pose = the inverse of each
bone's global rest, since `.bms` vertices are baked in absolute bind-pose space) and falls back to
rigid attachment only for meshes that genuinely carry no skin — scenery, which is most of the
archive.

## Superseded: "no per-vertex skinning data exists" (kept for the reasoning)

Settled definitively by finding and inspecting real **body-part** meshes (`man_pelvis.bms`,
`man_thigh.bms`, `man_calf.bms`, `man_torso_upper.bms`, `man_torso_lower.bms`, `man_arm_upper.bms`,
`man_arm_lower.bms` — a real China-man character, as opposed to the hair/face attachment pieces
checked earlier) alongside a real matching human skeleton
(`Prim/Skel/Char/China/chinaman_skel.bsk`, 37 bones, standard 3ds Max Biped naming). The entire
44-byte vertex record is now fully accounted for (position 12 + normal 12 + UV 8 + the 12 trailing
bytes above = 44) and none of it is bone-weight data — there simply isn't room left for a
multi-bone weighted skin, and the 12 trailing bytes were already shown to be something else (see
above).

What real files do instead, confirmed by inspecting `man_thigh.bms` vertex-by-vertex: **each
paired body part is one `.bms` file containing both the left and right sides already baked in as
two mirrored, non-overlapping vertex/triangle ranges** — vertex 0 at `x=+0.872` and vertex 23 at
`x=-0.872` are exact mirrors (same y/z, negated x), with no per-vertex tag distinguishing which
side a vertex belongs to. The only signal splitting them is which side of `x=0` a triangle's
centroid falls on. Unpaired parts (pelvis, torso) are one piece with no split needed. Real body
part vertex positions are baked in absolute character-space coordinates, the same "no extra
transform needed" pattern already confirmed for `.bsr` sub-mesh pieces (see
[BSR_FORMAT.md](BSR_FORMAT.md)) — rigidly attaching each (possibly split) piece to its matching
bone, offset by that bone's own bind-pose position, reproduces the real character shape exactly
(verified visually — see `client/scripts/assets/character_assembler.gd` and
`client/tools/render_character.gd`). No file tying a specific mesh set to a specific skeleton was
found (same "no resource-ID mapping" gap as `.mapo` — see [MAPO_FORMAT.md](MAPO_FORMAT.md)), so
the body-part-name-to-bone-name mapping is an inferred, unconfirmed heuristic, not a decompiled
fact.

## Collision section: the object's own navigation mesh

**Recovered 2026-09-05.** A `.bms` may carry, at the offset in header field `0x28`, a complete
per-object navigation mesh — the real walkable surface the client uses for a placed object. It is
structurally the same thing a region's terrain `.nvm` carries (see [NVM_FORMAT.md](NVM_FORMAT.md)):
vertices, convex navigable cells, and edges that either bound the mesh or join two cells.

This matters because **the real client never collides a character against a building's render
geometry.** It walks this cell/edge graph and takes the character's height from the cell underfoot.
A staircase is climbed by walking up its navigation triangles, not by stepping onto its render
mesh — which is why colliding against render geometry made every real staircase unclimbable.

### Layout

Read in order from the offset in `0x28`. Every count is self-describing, and the section runs to
**exactly** the end of the file — the same self-checking property `.nvm` has, and the property that
made the record-size bitfield recoverable at all.

| Field | Encoding |
|---|---|
| Vertex count | `uint32` |
| Vertices | count × 13 bytes: `float32 x, y, z` then one flag byte (meaning not established; carried through unparsed) |
| Cell count | `uint32` |
| Cells | count × 8 bytes (9 if bit 1 set): `uint16 a, b, c` indices into the vertex array, then a `uint16` that is **0 in all 45,123 real cells measured**, then one padding byte when bit 1 is set |
| Outline edge count | `uint32` |
| Outline edges | count × 9 bytes (10 if bit 0 set) — see the edge record below |
| Internal edge count | `uint32` |
| Internal edges | count × 9 bytes (10 if bit 0 set) |
| Event count | `uint32`, **present only when bit 2 is set** |
| Events | count × (`uint32` length + that many bytes of name). Only real value seen: `"EVENT"`. What the client does with them isn't established |
| Grid origin | `float32 x, z` |
| Grid width, height | `uint32`, `uint32` |
| Grid total | `uint32`, always equal to width × height |
| Grid lists | width × height × (`uint32` count + that many `uint16` cell indices) — a spatial lookup acceleration structure |

An **edge record** is `uint16 v0, v1` (vertex indices), `uint16 cell_from`, `uint16 cell_to`, then
one flag byte, plus one padding byte when bit 0 is set. `cell_to` is `0xFFFF` for "no cell on this
side" — the same sentinel the terrain `.nvm` uses.

### The record-size bitfield at `0x38`

Three bits independently change the section's record sizes. Each was isolated by finding real files
that set it *without* the others, so these are separated meanings rather than a correlation:

| Bit | Value | Meaning |
|----:|------:|---|
| 0 | `0x1` | Edge records carry one extra trailing byte (10 instead of 9) |
| 1 | `0x2` | Cell records carry one extra trailing byte (9 instead of 8) |
| 2 | `0x4` | An event-name list follows the edge lists |

Bit 3 (`0x8`) occurs (in `flags` values 8 and 14) but changes none of the three record sizes; its
meaning is not established. Bits 1 and 2 appear together in the commonest non-zero value, `6`, and
`flags = 4` (bit 2 alone) and `flags = 5` (bits 0+2) are what prove they are independent.

### How this was confirmed

The layout was derived from real data by structural walk, then validated the way `.nvm` was: read
in order, does it land exactly on the file's end?

- **507 of 507** real collision sections found in a 4,395-file real sample of a real `Data.pk2`
  parse to **exactly** the end of the file, with zero leftover bytes, at the record sizes the
  bitfield selects. No file needed a special case.
- Zero of 45,123 real cells index a vertex outside their own vertex array.
- The independent GDScript implementation agrees with the analysis exactly (465/465 real
  `"0110"` meshes in a 4,000-file sample; the one file it declines is a real older
  `"JMXVBMS 0109"`, whose layout is not verified).

### Edge semantics

The blocking rule is the same real `(flags & 3)` test the client's own terrain traversal applies —
see [NVM_FORMAT.md](NVM_FORMAT.md)'s "Edge flag semantics: solved". That it holds for object
navigation meshes too is measured, across 78,130 real edges:

- All **20,892** outline edges carry `0xFFFF` on their far side; 93.5% carry flag 3 (blocking).
- All **57,238** internal edges join two real cells; 99.1% carry flag 4 (passable).

The **adjacency split is total; the flag split is not**. A real internal edge may block (0.9% do,
mostly flag 7 — a passable bit set alongside the blocking bits), and a real outline edge may not.
That is why `BmsCollision` tests the flags rather than trusting which list an edge came from.

## Implementation notes

- `server/internal/bms` (Go) and `client/scripts/bms/bms_reader.gd` (GDScript): both parse the
  confirmed layout above, unit tested against synthetic fixtures (never real game data, same
  policy as `server/internal/pk2`), and cross-checked against each other on real files. The
  collision section is parsed by the GDScript reader only (`BmsReader.parse_collision`) — it is
  client-side movement data, and the Go reader has no caller that needs it.
- `client/scripts/bms/bms_collision.gd` (`BmsCollision`) turns a parsed collision section into the
  object's walkable surface triangles and its blocking walls, and
  `ObjectLoader._add_object_navmesh_collision` attaches both as a single `ConcavePolygonShape3D`.
  An object that has a collision section uses it *instead of* a trimesh of its render geometry, so
  it is solid only where the real game says it is solid — a consequence worth knowing about is
  that a roof overhead no longer blocks anything, including the camera spring arm.
- `client/scripts/assets/character_assembler.gd` (`CharacterAssembler`) builds a real, rigidly-
  jointed character from real body-part meshes + a real skeleton, per the finding above — not
  smooth skinning (none exists to do), but a real recognizable human shape. See
  `docs/PROGRESS.md` for the real screenshot this produced.
- Each part's real texture is resolved by matching its own `material_name` field against a real
  `.bmt`'s layer names (e.g. `"chinaman_body"` in both `man_thigh.bms` and
  `chinaman_warrior.bmt`) — see [BMT_FORMAT.md](BMT_FORMAT.md) for the real name-matched pairing
  this uses instead of a guessed flat color.

## Two header sections still unread (hdr[2], hdr[3]), and one that is empty

**Audited 2026-09-09**, directly because of how the skinning was found: the tell there was *a
header word parsed into a variable and never used*. `BmsReader` reads `hdr[0..5]` and uses 0
(skin), 1 (indices) and 4 (bounding box). `client/tools/audit_unused_header_words.gd` reports what
the other three point at, over 1,200 real `.bms` files:

| Word | Offset | Finding |
|---|---|---|
| `hdr[2]` | 0x18 | Points into the file in all 1,200. **First word non-zero in 63** (5%). Decoded below: one 8-byte record per vertex. |
| `hdr[3]` | 0x1C | Same files carry data here too. Decoded below: a list of 12-byte links between vertices. |
| `hdr[5]` | 0x24 | First word is **0 in all 1,200** — an empty section everywhere. Nothing is being missed. |

`hdr[2]` is a count-prefixed list of **8-byte records**, from the arithmetic on three unrelated
files:

```
cj_table_01.bms              0x0c48 count  60, 480 bytes to hdr[3]  = 8.0 each
euro_esteuro_wood_bridge03   0x039c count  16, 128 bytes            = 8.0 each
euro_esteuro_ship01_01       0x2653 count 199, 1592 bytes           = 8.0 each
```

### hdr[2] decoded: one record per vertex, a float and a flag

**Swept over all 24,984 `.bms` files in a real Data.pk2**
(`client/tools/audit_bms_extra_sections.gd`). 801 carry an `hdr[2]` section, and in **every one
of the 801 the record count equals the mesh's own vertex count** — never the index count, the
triangle count, the bone count or the collision-cell count. So it is per-vertex data.

A record is a `float32` followed by a `uint32`:

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `float32`, 16 distinct values across the archive: **0.0, then 0.05 to 0.50 in steps of 0.05**, plus 1.0 |
| 0x04 | 4 | `uint32`, **only ever 0 or 1** |

The two agree exactly. Across 316,452 records, the flag is **1 in precisely the 292,980 records
whose float is 0.0** and **0 in precisely the 23,472 whose float is not**. That perfect
complementarity is the check that the record has been split in the right place: two fields
agreeing across three hundred thousand records is not an accident of alignment.

### What carries it

801 files, by leading name fragment: `avatar` 245, `clothes` 69, `cj` (Jangan scenery) 36,
`heavy` 28, `oas` 21, `thief` 17, `light` 17, `chinaetc` 14, `sd` 13, `spear` 11, **`cobweb` 10**.
Garments, armour, banners and cobwebs — things that hang.

### What it means: an inference, not a finding

A per-vertex amount that is zero for most vertices, rises through a hand-authored 0.05 ladder for
the rest, and carries a companion flag that says *which* — on dresses, robes, cobwebs and
banners — has the shape of **how far each vertex is free to move, with the attached ones pinned**.
That is the reading, and it is labelled as a reading.

It is **not** confirmed, and two attempts to confirm it failed:

- The client has a `SetOptimizeCloth` and a `UIIT_STT_OPTIMIZE_A_E_CLOTHES` option, which looks
  like the feature that would read this. It is not: its own classes are
  `CObjOptimizeCloth@CharacterVisualChange` and `Condition_OptimizeCloth@CharacterVisualChange`,
  and it is driven by `resinfo\optimize_clothes.txt` — a visual-quality option about *which*
  clothing is drawn, not about how it moves.
- The `.bms` loader itself cannot be found by string search: neither `JMXVBMS`, `JMXV` nor `.bms`
  appears as a string in the client, so the magic is compared inline and there is no anchor to
  start from.

**Also not decoded**: 450 files have an `hdr[2]` pointer whose declared count does not fit the
file at 8 bytes a record. They are skipped rather than read — one of them declares four billion
records, which exhausts memory if taken at face value.

### hdr[3] decoded: a list of links between vertices

A `uint32` count, then that many **12-byte records**:

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | `uint32` vertex index |
| 0x04 | 4 | `uint32` vertex index |
| 0x08 | 4 | `float32` distance |

**Verified across the same 801 files and 58,433 records: every index is inside the mesh's own
vertex count and every distance is positive** — not one violation. Two independent bounds checks
holding across fifty-eight thousand records is what says the 12-byte split is in the right place;
the count itself matches nothing (not the vertex, index, triangle or `hdr[2]` count), so the
arithmetic alone could not have found it.

The values read as one would expect a link list to: `avatar_m_angel_powers_dress_part2.bms` has
1,210 vertices and 78 links, joining vertices like (1194, 1199) at 1.20 apart and (1194, 81) at
1.56 — high indices near the hem paired with each other and with lower ones.

**The section does not end where the records do.** Every one of the 801 carries a trailer after
them: 380 bytes in the dress above, and 167 distinct lengths across the archive. Its contents are
small integers, all below that file's own link count (4, 36, 0, 33, 6, 39, 75, 34 … against 78
links), which reads as an ordering over the links rather than as more link data — but the length
is not a whole multiple of the link count and it does not parse as another count-prefixed block,
so **it is not decoded**. `BmsReader` reads the records and stops.

### Reading them

`BmsReader.ParsedMesh` carries `vertex_motion`, `vertex_pinned`, `vertex_links` and
`vertex_link_lengths`. Nothing renders with any of it. It is read because it is decoded: leaving a
known section unparsed is how this format's skinning stayed hidden for months, and a reader that
carries the data is a reader whose understanding can be tested. Both sections validate before they
are kept — a bad index leaves the whole list empty rather than half-read.
