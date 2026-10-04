# Round 717: party members on the minimap and the world map

The user (2026-10-04, after v0.1.490): "showing party members on the minimap and map ... Basically
you can see a greenish big dot on the map. The minimap will show an arrow on the edge of the minimap
in the general direction of where each party member is to you. They get their own arrow. Then when
you're close enough you'll see that big green circle again but on the minimap." Their three
screenshots of the original are `/root/opensro-handoff/party_refs/map_*.png`.

Read from the client first (`docs/protocol/party_gui.md` section 9 has every address), then built.

## What the original does (READ unless marked)

- **Minimap** (`CIFMinimap::vslot_013` `0x662bd0`, the party loop `0x6643a0..0x664ad1`):
  - **Who:** every member but the player, **with the player's world id** (record `+0x68`
    against `player +0x20e4`), in a region the player can see (a field region from the field, or
    the player's own dungeon: `0x9d5520`).
  - **Position:** the spawned object's position when this client has one, else the record's
    `(x, 0, z)` in its region.
  - **Offset** in map pixels: `(dx, -dz) / 1920 x zoom`.
  - **Dot or arrow:**
    - under **47.0** px (`0xda0ef0`): the 8x8 `mm_sign_party.ddj` at the offset;
    - 47 or more: the 16x16 `mm_sign_partyarrow.ddj`, centred on a fixed 47 px rim along the
      offset, turned by `-(theta + pi)`.
    - In screen terms that turn is `atan2(oy, ox) - pi` (`0xb47c50` acos, `0xb44a10` cos, `0xb44b40`
      sin, all read in the x87 fallbacks).
  - **Per member and order:** each member has its own mark, redrawn every frame, after the other
    signs and before the player's own arrow.
- **World map** (`CNIFWorldMap::FUN_0061eec0`, the party loop `0x61f8c0..0x61ffce`):
  - **Who and position:** every member but the player (**no** world-id test), at the same position
    source.
  - **The dot:** the 16x16 `wmap_sign_party.ddj` centred on its map pixel, drawn before the
    player's marker.
  - **Hover:** while the mouse is inside the first member's dot inset by 2 px, the party manager's
    text for that member is drawn centred above it (that the text is the **name** is INFERRED).
- **Measured** (the DDS headers in Media.pk2): `mm_sign_party` 8x8, `mm_sign_partyarrow` 16x16,
  `wmap_sign_party` 16x16, each the size of its quad.

## What was built

- **`client/scripts/ui/hud/party_map_marks.gd`** (`PartyMapMarks`): the rules as pure functions.
  They cover the offset, dot or arrow, the rim centre, the turn, a record's region-local position,
  who each map draws, and the hover rectangle.
- **`hud_minimap.gd`**: `update_party(player_local, members_local)` places one pooled TextureRect
  per member, from two pools:
  - the dots in a `PartyMarks` root inside the map clip, between the other signs and the player's
    arrow;
  - the rim arrows in a `PartyArrows` root over the window's frame, unclipped and under its
    buttons.
  
  Every mark is mirrored (`flip_h`) and turned a further -90 degrees, which is the quad's
  transposed texture (see below). `party_marks_report()` serves the QA log and the tests. The old
  comment saying party signs were not drawn is corrected.
- **`hud_worldmap.gd`**:
  - a `PartyMarks` layer under the player's marker (kept there when the place labels are rebuilt);
  - `update_party(region_x, region_y, members_local, names)`, with pooled 16x16 dots placed by the
    player's own world-map rule (`party_world`);
  - the hover name, as a Label;
  - `party_dots_report()` and `party_hover_text()`.
- **`World3D.gd`**:
  - `_fill_party_marks` builds the three per-frame lists (minimap positions, world-map positions,
    names). It counts first, so the packed arrays change size only when the party does. Positions
    come from the spawned body (`_party_body_for_board`) or the record (`PartyMapMarks.record_local`).
  - `_refresh_minimap` passes the lists on.
  - Two QA party steps: `maplog` (both maps' marks in the log) and `wmap` (opens the world map).

## Two things the first live runs caught

- **The quads draw their texture transposed.** The first frame had the north-rim arrow pointing
  east. Each party quad's corners go top-left, top-right, bottom-right, bottom-left with texture
  coordinates (0,0), (0,1), (1,1), (1,0), so screen (x, y) samples texture (y, x) (READ: `fldz` /
  `fld1` at `0x664544` and `0x664720`, the world map's at `0x61f9ee`). The arrow's art points up
  (MEASURED), so it draws pointing west unturned, and the client's turn then sends every arrow
  outward, as in the user's `map_JXHQtcH.png`. A Control does the same with `flip_h` and a further
  -90 degrees (`PartyMapMarks.TRANSPOSE_TURN`); the test checks that an east member's tip points
  east.
- **The rim arrow was hidden.** Centred 47 px out in a 105 px aperture, it was cut by the map's
  rectangular clip and covered by the frame's ring. The user's screenshot shows the original's
  arrow over the ring, so the arrows now draw over the frame (INFERRED, see OURS).
- **Test placement, not a code bug:** the first run placed the bots with `/tp` offsets of 120 and
  100, taking them for the minimap's display units. `/tp` takes the server's world units (z
  mirrored), so the marks showed 10 px and 8.3 px south. The logged inputs matched them exactly.
  The bots were then placed 1200 east and 1000 north.

## OURS

- A dungeon record (`region & 0x8000`) is not marked: OpenSRO sends no dungeon positions.
- Without the player's own record in the party list, the minimap compares no world id.
- A world-map dot off the current map is clipped by the map area (the original's clipping was not
  traced).
- The hover name is a plain Label in the builder's font.
- The rim arrows draw over the window's frame, unclipped (INFERRED from the user's screenshot; where
  the original draws the frame was not traced).

## Tests

`client/scripts/ui/hud/party_map_marks_test.gd`:
- the offset and its axes;
- dot vs arrow at the 47 px edge (`>=`) and across zooms (600 units is an arrow at 256 px a region
  and a dot at 64);
- the rim centre and turn for east, north, west, south and north-east;
- that `atan2(oy, ox) - pi` equals the client's `-(theta + pi)` in every quadrant;
- record positions across regions;
- who is drawn (self, another world, a dungeon), and the world map having no world test;
- the hover inset;
- the world-map position;
- `HudMinimap.update_party`: one mark per member, the pooling, the marks under the player's arrow,
  a member leaving, and no party.

On the box: 0 failures.

On the box (`RENDER_DIR=/opt/opensro-client-r717`): `check` loads 602 scripts and 9 scenes, and the
full suite is 230 suites with 0 failing.

## Live

Run with the stock `qa_shot.sh --server` on the shared lock (`/var/tmp/r717/live.sh`), against a
server and partybot built from this branch:
- **Aria** is rendered and leads. She invites the partybots:
  - **Cara**, standing 2 east and 4 south of Aria;
  - **Dex**, who moves 1200 east;
  - **Eve**, who moves 1000 north.
- **Then:** `maplog` twice, `wmap`, and `maplog` twice more.

The log, identical at all four `maplog` steps:

```
QA PARTY: map inputs here r(96, 171) local (1636,1626) tile_px 160.0: ... Cara(r96/171 x1638 z1622 ...
  body(1638,1622)) Dex(r96/172 x916 z1626 ... body(2836,1626)) Eve(r97/171 x1636 z706 ... body(1636,2626))
QA PARTY: map marks minimap [dot@(0.2,0.3) arrow@(47.0,0.0)r-180 arrow@(0.0,-47.0)r-270]
  world map [(4027,549) (4047,549) (4027,532)] hover ''
```

- **Records and bodies agree.** Dex's record is in the next region y, at x 916, which is
  1920 + 916 - 1636 = 1200 east, the same as his body. Eve's record is one region x up at z 706:
  1920 + 706 - 1626 = 1000 north.
- **Frames:** `/var/tmp/r717/live/f00000470.png` shows the minimap; its crop is `mini_crop.png`.
  `f00000580.png` shows the world map; its crop is `wmap_crop.png`.
  - **Minimap:** Cara's dot is under the player's arrow. Dex's arrow sits on the east rim, over the
    ring and left of the E button, pointing east, as in the user's `map_JXHQtcH.png`. Eve's arrow
    sits on the north rim, pointing north.
  - **MEASURED on frame 470:** the east arrow's green gem centroid lies 46.5 px right of the
    aperture centre, and the north arrow's 45.5 px above it. The gem sits about 1 px toward each
    arrow's tail, so both arrow centres are at 47 px.
  - **World map:** three green dots. Cara's is under the player's marker, Dex's 20 px east and
    Eve's 17 px north, the "greenish big dot" of the user's `map_vxAS9rr.png`.
- **The hover name** was not exercised live, since the QA run has no mouse over a dot. The unit
  test covers the inset rule.

## Perf gate

`client/tools/perf_gate.sh --sites jangan --frames 12000`, the working tree against `dca31493`:

| jangan | base | head | |
|---|---|---|---|
| frame ms | 1.59 | 1.56 | SAME |
| entry ms | 10020 | 10020 | SAME |
| freeze ms | 3480 | 3470 | SAME |
| hitches | 4 | 5 | SAME |

The gate's view has no party, so it measures the no-party path: one `in_party` test a frame. In a
party the frame adds one counting pass and one filling pass over at most 7 members, and places
pooled marks. Nothing is allocated once the party is settled.

## Open

- **Dungeons.** A dungeon member (the original draws one in the player's own dungeon, and on the
  dungeon-floor world map) is not marked: OpenSRO sends no dungeon positions.
- **The hover text's writer** (the party manager's map `+0x28`) was not read, so "name" is
  INFERRED.
- **Where the original draws the minimap frame** relative to vslot_013 was not traced. That frame
  is what decides the arrows-over-the-ring layering, INFERRED here from the user's screenshot.
- **Academy marks** (`mm_sign_apprenticeship[arrow]`) follow the same rule from the academy list:
  not built, since there is no academy.

