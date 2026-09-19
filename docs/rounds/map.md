# Map lane round: the Alexandria "white ground" report, and the zone label that never moved (2026-09-19)

Reported from a real playtest: after the debug panel's **Alexandria** button (zone target
`90/48@663,526`), "the ground is all white" while buildings, sky and the character drew
normally, and the minimap still read **Jangan**. Both halves were measured on the render box
with the retail archives there; one reproduced and is fixed, the other did not reproduce and
now logs the numbers that would settle it.

## 1. The zone label / minimap name -- reproduced, cause read, fixed

**Measurement.** The label and the minimap's area name come from
`_update_zone_label_for_region` -> `RegioninfoNames.display_for_region`, which resolves a
region through `Data.pk2`'s `Shader\regioninfo.txt`. That file, extracted and counted, has
**15 zones** -- 장안/Jangan through 중앙아시아/Central Asia, the pre-Egypt world -- and **no row
for any Alexandria region**. `display_for_region` therefore returns `""` for 90/48 and the
function returns early, leaving `_current_zone_name` (and the minimap header fed from it every
tick) at whatever zone the player came from. Reproduced in one `qa_shot` run booting Jangan and
reloading for `90/48@663,526` through `SRREVAMP_QA_ZONE`: the frame at the Alexandria spot
(world X -16638, Y -332 -- the reporter's own screenshot reads X -16608, Y -337) still showed
**Jangan** over the minimap.

**The game's own table.** `Media.pk2`'s `server_dep\silkroad\textdata\textzonename.txt` is a
per-REGION zone-name table: 4,176 rows shaped `<service> <regionId> <korean> 0 0 0 0 0
<english> <...>`, keyed by the packed region id this project already uses everywhere
(`(x << 8) | y`: Jangan's 97/168 is 25000; 90/48 is 23088, whose row reads `Alexandria`). The
full `textdata\regioninfo.txt` (3,242 lines, 65 zones, `48 90 ALL` under `#TOWN Alexandria`)
agrees, but the per-region text is the simpler and more complete source and carries the real
localized names rather than this project's transliterations.

**Fix.** `TextZoneNameReader` (new, `client/scripts/regioninfo/`) parses that table with the
UI text tables' own language-column rule (`UiTextTable._pick_language_column`, column 8 with
its documented fallbacks); `World3D._zone_name_for_region` prefers it and falls back to the
15-zone Shader table, and `_update_zone_label_for_region` now also pushes the name straight to
the minimap. Headless test `text_zone_name_reader_test.gd` (synthetic rows, no game data)
covers the packing, the column fallback, service-0 and short rows. **Verified**: the same run
after the change loads `3460 regions` of names and the Alexandria frame's minimap reads
**Alexandria**.

## 2. The white ground -- NOT reproduced; the chain is measured intact

Every step the client takes to texture 90/48 was checked against the archives on the box:

| step | measured |
|---|---|
| region file class | `90\48.m` is 92,712 bytes -- the 7-byte-vertex class, same as `97\168.m` (so the per-vertex `TextureInfo` decode is the one Jangan uses) |
| texture ids in the row data | 90/48 uses **13 distinct ids** (263 `alex_stone00.ddj` on 7,984 of 10,404 vertices, then 380, 0, 262, 362 ...); 89/48 22 ids, 90/47 15, 91/48 14, 90/49 26 |
| `tile2d.ifo` entries | 719 entries, ids 0..718; **every id of every checked region has an entry** (0 missing) |
| files in `Map.pk2`'s `Tile2D\` | 725 files; **every referenced filename is present** (0 missing) |
| the `.ddj` files themselves | `alex_stone00/01`, `alex_grass_04`, `esteu_godgarden_*`: 20-byte DDJ header + DDS, **DXT1, 512x512, 10 mips -- byte-for-byte the same format as `c_marble_jang_02.ddj`**; a 256x256 one decodes the same way |
| brightness of the paving | decoded DXT1 top mip: `alex_stone00` mean sRGB (0.63, 0.58, 0.48), luma mostly in the 0.5-0.75 bins; Jangan's `c_marble_jang_02` (0.40, 0.38, 0.31). Brighter, nowhere near white |
| the client's own load | the new per-region line reads `ground textures for 90\48.m -- 13 ids, 13 resolved, 0 without a tile2d.ifo entry, 0 files missing or undecodable`, and likewise for all nine regions of the grid |
| the frame | the Alexandria spot renders the real paving (`alex_stone00`), not white, in both runs |

So with these archives and this code the ground is textured. What is left is on the reporting
machine: either its own `Map.pk2`/`Data.pk2` differ (an archive whose `Tile2D\` lacks the
`alex_*`/`esteu_*` files, or whose `tile2d.ifo` is shorter -- the untextured fallback draws a
flat material whose albedo is white when the zone's minimap image is also missing), or the
render differs (the Windows build on that GPU). The two are now distinguishable from the
client log written beside the executable: `World3D: ground textures for 90\48.m -- ...` says
how many ids resolved, and ends in `NOTHING resolved, the region draws the flat fallback`
when the archive is the cause. **Ask for that line** before doing anything else about it.

## 3. A log line that never printed

Every environment application raised `ERROR: unsupported format character`: the fog-planes
diagnostic used `%g`, which GDScript's `%` operator does not support, so the line documented
in `World3D.gd`'s QA block was silently lost on every zone. Now `%.5f`; the line prints
(`near 1697, far 2500` at Alexandria, `1897/2500` at Jangan).

## Files

- `client/scripts/regioninfo/text_zone_name_reader.gd` (new) and its `_test.gd` (new)
- `client/scripts/World3D.gd`: `_load_text_zone_names`, `_zone_name_for_region`,
  `_update_zone_label_for_region` (minimap push), the per-region ground-texture diagnostic in
  `_load_real_ground_textures`, the `%g` fix
- transient extracts under `/var/tmp/maplane` on the box were deleted; nothing from the
  archives is committed
