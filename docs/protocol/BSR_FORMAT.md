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

Same general shape as `.bms`'s header (magic + an offset table + reserved fields), but 4 bytes
shorter before the name string.

**Correction (2026-09-08).** This document previously called the offset table "unconfirmed" and
said the field at 0x28 was a constant `152` that "did not hold for one real file", so neither
reader used it. Both statements were wrong, and for the same reason: **the table starts at 0x0C,
not 0x10.** Read off by one field, every entry lands on the wrong thing. Read correctly, all four
of the first entries are exact byte offsets to the count word that begins a section, in every
real file checked across all three categories — the table was trustworthy all along:

| File | 0x0C material | 0x10 mesh | 0x14 skeleton | 0x18 animation |
|---|---|---|---|---|
| `chinaquest_priest.bsr` (character) | 193 = 0xC1 | 246 = 0xF6 | 511 = 0x1FF | 400 = 0x190 |
| `mangnyang.bsr` (character) | 249 = 0xF9 | 341 = 0x155 | 1097 = 0x449 | 431 = 0x1AF |
| `cj_monstad_door01.bsr` (building) | 262 = 0x106 | 340 = 0x154 | 1524 | 1512 |
| `tre_bank02.bsr` (nature) | 235 = 0xEB | 290 = 0x122 | 465 = 0x1D1 | 407 = 0x197 |

The 0x28 field isn't a constant either: it is `name_end + 48`, tracking the name's length exactly
(`chinaquest_priest`, 17 chars → 137; `mangnyang`, 9 → 129; `tre_bank02`, 10 → 130). It points 4
bytes ahead of the bounding-box floats.

| Offset | Size | Field |
|-------:|-----:|-------|
| 0x00 | 12 | Magic, `"JMXVRES 0109"` — confirmed via the real client's validator |
| 0x0C | 4 | Offset of the **material** section |
| 0x10 | 4 | Offset of the **mesh** section |
| 0x14 | 4 | Offset of the **skeleton** section |
| 0x18 | 4 | Offset of the **animation** section |
| 0x1C | 4 | Offset of a further section, contents unconfirmed (a count + `"default"` string) |
| 0x20 | 4 | Offset of a further section, contents unconfirmed (a count + `"default"` string) |
| 0x24 | 4 | Offset of a further section, contents unconfirmed (reaches the `"ambient"` / `.efp` effect block) |
| 0x28 | 4 | Offset of the bounding-box block; equals `name_end + 48` in every file checked |
| 0x2C-0x3C | 16 | Reserved (observed 0) |
| 0x40 | 2 | **Object type** — `1` character, `2` building, `4` nature (see below) |
| 0x42 | 2 | Observed `2` in every file checked |
| 0x44 | 4 | Name length (`uint32`) |
| 0x48 | ... | Name string (ASCII, not null-terminated — length-prefixed) |

## Object type (0x40)

The low `uint16` at 0x40 is the game's own classification of the object, authored in the file.
It is what distinguishes the layouts below — the field order differences this document previously
attributed to a path-prefix convention (`res\bldg\...` vs `res\nature\...`) are really a
consequence of type:

| Value | Meaning | Observed in |
|---|---|---|
| 1 | Character — skinned, has a skeleton | `chinaquest_priest`, `chinasystem_bookmakergirl`, `mangnyang` |
| 2 | Building / static scenery | `cj_monstad_door01`, `cj_monstad_status_l` |
| 4 | Nature | `tre_maple01`, `tre_bank02` |

## Character layout (type 1)

NPCs, monsters and the player's own body are all type 1, and they are a genuinely different
layout rather than a reordering of the scenery one. Every section is reached through the header
table above; nothing needs to be scanned for. Each section begins with a `uint32` count, and its
entries abut one another exactly, so a section ends precisely where the header says the next one
begins — which is what makes this checkable rather than guessed, and is asserted by both readers.

| Section | Layout |
|---|---|
| Material (0x0C) | `uint32` count, then per entry: one `uint32` (unconfirmed — an index or flag, always small) followed by a length-prefixed `.bmt` path |
| Mesh (0x10) | `uint32` count, then that many length-prefixed `.bms` paths back to back, no per-entry field |
| Animation (0x18) | two `uint32`s (observed `4096` then `0` in every file checked, meaning unconfirmed), then a `uint32` count, then that many length-prefixed `.ban` paths |
| Skeleton (0x14) | `uint32` count, then that many length-prefixed `.bsk` paths — always exactly 1 in every real file checked |

Worked example, `chinaquest_priest.bsr` (717 bytes), every offset verified to chain:

```
0xC1  count 1                            material section
0xC5  uint32 0
0xC9  prim\mtrl\npc\china\chinaquest_priest.bmt      ends 0xF6
0xF6  count 3                            mesh section (== header 0x10)
0xFA  ..._al.bms      ends 0x12A
0x12A ..._part1.bms   ends 0x15D
0x15D ..._part2.bms   ends 0x190
0x190 4096, 0, count 2                   animation section (== header 0x18)
0x19C ..._basic.ban   ends 0x1CE
0x1CE ..._time.ban    ends 0x1FF
0x1FF count 1                            skeleton section (== header 0x14)
0x203 prim\skel\npc\china\chinaquest_priest.bsk
```

**Why this mattered.** The scan-based reader below finds only the *first* `.bms` in a type-1 file,
so it reported the priest as one 25-vertex piece — a fragment, not a person — and exposed no
skeleton at all, which is what blocked NPCs from being built. With the section table read
correctly the priest is 3 pieces / 665 vertices, `chinasystem_bookmakergirl` is 4 / 747, and
`mangnyang` is 2 / 440 with 15 animations. Because these models are skinned, the mesh pieces are
meaningless without the skeleton: a type-1 object should be assembled through `CharacterAssembler`,
not placed as rigid scenery. Both readers therefore refuse to report a character with no skeleton
path, falling back to the scan instead of returning something that would render as disconnected
limbs at the origin.

Nature files (type 4) also carry a skeleton and animations — that is how trees sway — but their
mesh entries appear to carry a trailing `uint32` per piece that type 1 and type 2 do not
(`tre_bank02`: mesh 1 ends 0x15A, a `0` word, mesh 2 begins 0x15E). That extra field is observed,
not confirmed, so the readers still take the scan path for types 2 and 4 and this remains open —
see [../TODO.md](../TODO.md).

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

**Correction (2026-08-23, live-tested against real Jangan palace buildings)**: the sub-mesh count
is *not* always self-validating for a real, bigger multi-piece building — at least one real
Jangan building's declared count didn't exactly match how many further real length-prefixed path
strings were actually present afterward. The real cause isn't confirmed (most likely a real
trailing per-piece field this project's earlier, simpler 2-4-piece samples never had enough real
sub-mesh pieces to expose — see the "default"-block boilerplate above, which might not always sit
cleanly after the *last* sub-mesh path the way every earlier sample showed). Both readers
(`BsrReader`/`bsr`) now keep whatever real sub-mesh paths parse successfully and stop there rather
than discarding the whole real object (including its already-confirmed-real primary
`mesh_path`/`material_path`) over one bad trailing piece — see `docs/PROGRESS.md`'s 2026-08-23
"found real Jangan" entry.

**Further correction, same day**: a bad trailing sub-mesh read doesn't always fail outright — it
can succeed with a real but obviously-wrong value, since the read has simply spilled into the
file's own trailing boilerplate (the fixed 20-byte block + "default" string above) rather than
running past the end of the file. Two real shapes confirmed live: a real empty string
(`tre_bank02.bsr`, a real tree whose declared sub-mesh count included one more entry than real
sub-meshes existed) and a real single stray byte, `"6"` (`tre_maple01.bsr`, same shape). Both
readers now also stop the sub-mesh loop when a read succeeds but produces something that isn't a
plausible `.bms` path (reusing the same plausible-path-character check already used for locating
the mesh/material path strings), not just when the read fails structurally.

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

## SOLVED: `res\nature\...` (tree/grass) files use a genuinely different field order

Found while wiring up real `.mapo` object rendering (see `docs/protocol/MAPO_FORMAT.md`'s object
index section): real `res\bldg\...` (building) files — the category this format was originally
derived against, e.g. `cj_ferry_stone01.bsr` — parse correctly, sub-meshes and all. Real
`res\nature\...` files (e.g. `center_asia_plant01_01.bsr`, `oas_grs_weed04.bsr`) initially didn't:
the scanned-for "mesh path" came out pointing at a `.bmt` (material) file instead of a `.bms`, and
the "material path" that followed was a garbage 1-character string.

**Root cause, confirmed by hex-dumping a real `center_asia_plant01_01.bsr` byte-for-byte**:
nature-category files genuinely put these fields in the opposite order from building-category
ones. Building order: `[name][2 fields][padding][mesh path][bounding box + tail][material path]
[sub-mesh count + list]`. Nature order: `[name][2 fields][padding][bounding box + tail]
[material path][a "1" field][mesh path]` — bounding box and material path come *first*, with the
mesh path last, and there's no confirmed sub-mesh-list convention for this order. The original
reader assumed "whichever plausible path string is found first is the mesh path, the next one is
the material path" — correct for buildings, silently wrong for nature files, which put the
material path first.

**Fixed** by scanning independently for the first string ending in `.bms` (the mesh path) and the
first ending in `.bmt` (the material path), rather than assuming an order — this finds the right
field in either layout without needing to detect which category a file belongs to first. The
bounding box and sub-mesh list are still only attempted for the building order (mesh before
material); the nature order's bounding-box position isn't confirmed, so it's left unclaimed
(`HasBounds`/`has_bounds` false) rather than guessed at. Verified against a real
`center_asia_plant01_01.bsr` end-to-end: real mesh, real material, and (via `ObjectLoader`) a real
rendered, textured plant — see `docs/PROGRESS.md`.

## SOLVED (the common case): real sub-mesh pieces carry the same name-matched material_name field character parts do

**Previously**: `ObjectLoader` had no confirmed way to know which `.bmt` layer belongs to which
mesh piece when a material has multiple layers and no name match is available — it fell back to
pairing layer `i` with mesh piece `i` only when the two counts happened to match, and layer 0
otherwise.

**Confirmed real, directly, on 4 real sub-mesh pieces**: pulled a real 27-piece building
(`bagh_city_palace.bsr`, `Res\Bldg\arabia\bagh_city\structure\`) and its real 28-layer material
(`bagh_city_palace.bmt` — one extra layer than pieces; not investigated further). Every real
layer's `layer_name` is literally a piece number (`Bagh_City_Palace_01`, `_04`, `_15`, `_27`, ...,
in a shuffled order that does **not** match mesh-piece order in the file). Parsed 4 of those real
piece `.bms` files directly (`_01`, `_04`, `_15`, `_27`) and found each one's own `material_name`
field (the same real per-mesh field `.bms` already carries for character body parts, see
`BMS_FORMAT.md`) exactly equals the matching real layer's `layer_name`, in all 4/4 checked. So the
same name-matching mechanism `CharacterAssembler` already used for character parts also applies to
`.bsr` sub-mesh pieces — this project's reader just wasn't using it there.

**Fixed**: `ObjectLoader.load_object` (`client/scripts/assets/object_loader.gd`) now looks up each
mesh piece's own real `material_name` against the material's real `layer_name`s first
(`_find_layer_by_name`), falling back to the old index-based heuristic only when no name matches —
which is now the honestly-still-unconfirmed remaining case, not the common one. Verified with a
dedicated synthetic test (`object_loader_test.gd`) using two pieces and two layers in deliberately
shuffled order (mirroring the real `bagh_city_palace` shape) — confirms each piece gets its real
name-matched layer, not whatever the old positional pairing would have picked.

## A deeper real mechanism also found, not yet mapped to byte offsets or implemented

The name-matching fix above resolves the common case (a mesh piece's own `.bms` carries a
`material_name`), but doesn't explain what happens when it doesn't — decompiling the real client
surfaced a second, deeper real mechanism for that case, described below.

**Investigated by decompiling the real client's actual `ResObject::Load`** (`sro_client.exe`),
traced from the known `FUN_00bed8d0`/`FUN_00bce3b0` entry points documented above, through the
real type-dispatch factory (`FUN_00be9250`, a switch on an object-type code — case 0 turned out to
be `ResChar` per a real `"D:\...\ResChar.cpp"` string, a different real class; the correct branch
for static scenery objects is one of cases 1/2/3/4/6/7, `FUN_00be8dc0`) down to the concrete
`ResObj` vtable's `Load` method, `FUN_00be41d0` — confirmed as the real target by a literal
`"D:\...\ResObject.cpp"` string and a `"m_PrimMeshGroups.size() == 0"` assertion message right
where the mesh-group list is read.

**The real mechanism, as decompiled**: for each of `m_PrimMeshGroups`'s real count of entries, the
loader reads one mesh-group's own path string, then a real `uint32` count, then that many further
`uint32` values — each one used as an index into a separate shared array (`param_1[0x5d]` in the
decompilation, plausibly the object's material/layer list) which gets copied into that mesh
group's *own* per-group index array. In plain terms: **each mesh piece carries an explicit,
file-encoded list of which material-layer indices apply to it** — not an implicit pairing inferred
from matching counts, and not always "layer 0" as this project's fallback currently assumes. This
directly answers the open question, in principle.

**Not yet done**: mapping this decompiled mechanism to concrete byte offsets in a real `.bsr` file
(i.e. hex-dumping a real multi-layer, multi-piece object and locating this count-prefixed index
list in the actual bytes, the same way every other field in this doc was pinned down). The
currently-documented flat struct above doesn't have a slot for it, and the real `Load` function
reads noticeably more real sections than that struct currently models (bounding-box-adjacent
fields, several tagged skip/seek points) — this pass found the *mechanism*, not (yet) its exact
place in the byte layout, so nothing here has been implemented or wired into `ObjectLoader` yet.
Flagged as a real, promising, correctly-scoped next step rather than guessed at further.

## Implementation notes

- `server/internal/bsr` (Go): parses name, mesh path, bounding box (best-effort, building-order
  only — see above), material path, and the sub-mesh path list. Rather than trust the header's
  offset table (shown above to be unreliable), it locates the mesh and material path strings by
  scanning forward for the first plausible length-prefixed ASCII path ending in the expected
  extension (`.bms`/`.bmt`) — the same technique used to cross-check every real file during RE,
  and the only approach confirmed to work correctly on both real field orders. Unit tested
  (`go test`) against synthetic fixtures for both orders (never real game data).
- `client/scripts/bsr/bsr_reader.gd` (GDScript): mirrors the Go implementation field-for-field,
  used at runtime by `ObjectLoader` to build real, textured `Node3D`/`MeshInstance3D` trees.
