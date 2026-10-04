# Round 717 review: party members on the minimap and the world map

An independent adversarial review of `dev..worktree-agent-a6c666159dac41b64` (head `95647a4b`). It
was read against the client binary (`sro_client.exe`, md5 2a5794b72c90908d945be8b3f3f2edd4: the asm
`/var/tmp/sro_client.asm` and the decompile `/var/tmp/decomp_client`), Media.pk2, the lane's live
frames and log (`/var/tmp/r717/live/`), and the user's three screenshots
(`/root/opensro-handoff/party_refs/map_*.png`). No code was changed.

**Verdict.** The core is right:
- the 47 px switch, the fixed 47 px rim and the turn;
- the transposed texture and its `flip_h` + -90 degrees stand-in;
- the record/body position source, the region axes, and the world map's placement.

The live frames measure true against all of it. There is one layout departure: the dots draw under
the frame. One behaviour is missing: the job party's `*` in the hover name. One rounding rule is
mislabelled (truncation, not rounding). The rest are labels and 1 px details.

## Findings, most severe first

### 1. LAYOUT: minimap dots draw under the window's frame; the original draws them over it

- **Where:** `client/scripts/ui/hud/hud_minimap.gd:203-206` (`_party_root` inside `_map_clip`, which
  sits under `MinimapFrame`, `:225-235`). The arrows were moved over the frame (`:236-241`); the dots
  were not.
- **Evidence (READ and MEASURED):**
  - The dot and the arrow are two branches of one loop iteration in one function. `CIFMinimap::vslot_013`
    has the switch at `0x66450e` (dot at `0x664514..0x6646eb`, arrow at `0x6646f0..0x664ab7`). So the
    two have the same layering relative to the frame.
  - The lane established that the arrows draw over the ring, from the user's `map_JXHQtcH.png`, and
    this review confirms it by measurement:
    - The screenshot is an exact 2x nearest upscale (every pixel is a 2x2 block).
    - Template-matching `mm_window.ddj` places the aperture centre at 1x (78, 116).
    - The arrow's gem sits at (122, 125.5), so the arrow centre is about 46.5 px out (east-south-east).
    - `mm_window.ddj`'s alpha is opaque from **45.5 px** out at due east, but the whole arrow is
      visible in the screenshot, tip included, about 53 px out.
  - Supporting evidence (READ) that the frame is under the whole of vslot_013:
    - vslot_013 never binds `mm_window` (its texture binds in order are `+0x370` mask, the signs,
      `+0x3a4/+0x3a0`, `+0x36c/+0x39c`, `+0x3c0/+0x3c4`, `+0x374`).
    - The map tiles need the `mm_alpha` mask as stage 0 to round them off, which a frame drawn on
      top would make unnecessary.
    - Stage 1 is disabled before the signs (D3DTOP_DISABLE, after the tile loop), so no mark is
      masked or clipped.
  - Measured on `mm_window.ddj`: the opaque ring starts between **43.5 px** (due south) and
    **53.75 px** from the aperture centre, and at 45.5 / 49-50 px on most of the east and north
    sides. An 8x8 dot reaches 4 px past its offset, so any dot from about 40 px out is partly
    covered in OpenSRO. In the original it is drawn whole over the ring.
- **Fix:** draw the marks over the frame in vslot_013's order. Use one unclipped root above
  `MinimapFrame`, at `APERTURE_RECT.position`, holding the party dots, then the party arrows, then
  the player's arrow (which must stay over the dots). Keep the layout's buttons above it. The
  pre-existing NPC/monster/other-player signs (up to 44.5 + 4 = 48.5 px) have the same problem;
  that is not this round's code, but the same root would fix it.

### 2. DEPARTURE: the world-map hover name lacks the job party's `*`

- **Where:** `client/scripts/World3D.gd:2951` (`_party_marks_names[iw] = m.member_name`) and
  `hud_worldmap.gd:867` (`_party_label.text = names[hovered]`).
- **Evidence (READ):** the hover text object is made when a member is added, in
  `CharacterDependentData::0x99a2e0`:
  - `0x99a4c5: cmp [this+0x2c],0`. That is the party manager's `+0x0c` (`0xeeebd8 + 0x2c`), the
    job-mode-party flag set by `0x986f60` as `vslot 43 (job byte +0x50d) != 4`. It is documented
    in `party_gui.md` section 3.
  - If the flag is set: `0x541380(out, "*" @0xd87b70, name)`.
  - Then `new 0x68` -> `0x8b4f30`, `0x8b3b90(text)`, and the insert into the map at `this+0x48`
    (`0x99a668`, `0x9999e0`). That map is the one the world map reads, as `ebp+0x28` with
    `ebp = 0x986f50() = 0xeeebd8+0x20`.
  - So in a job party the hover reads `*Name`.
- OpenSRO already models this flag: `PartyState.job_party` (`party_state.gd:212`), and the party
  pane draws `"*%s"` (`hud_party_pane.gd:300`, `:329`).
- **Fix:** pass the job-party prefix through. To keep the frame allocation-free, prefix only when
  the hover label's text changes, for example `update_party(..., job_party)`, with the label set to
  `"*" + name` on hover change only.

### 3. WRONG-LABEL: the hover text is the member's name, READ, not INFERRED

- **Where:**
  - `party_map_marks.gd:37`;
  - `docs/protocol/party_gui.md:685`;
  - `docs/rounds/party717.md:34`, `:169`.
- **Evidence (READ):**
  - The text set in `0x99a2e0` is `param_4`, the first string argument.
  - The same string goes through `0x4fc700` into the record's first field (`local_84`, record
    `+0x00`).
  - Its size word, record `+0x14`, is what the "Incorrect Party Player Info (Name Size == 0)"
    asserts test (`0x998cb0`, `puVar7[7]` = node `+0x1c` = record `+0x14`).
  - So the text is the name, with the `*` of finding 2.
- **Fix:** relabel as READ, citing `0x99a2e0` (`0x99a4c9`, `0x99a5ce..0x99a673`), and remove
  "the writer was not read" from Open.

### 4. WRONG-LABEL + MINOR (1 px): `0xb42d10` truncates; it does not round

- **Where:**
  - `hud_worldmap.gd:826-827` ("rounded as 0xb42d10 rounds");
  - `:859` (`.round()` on the dot);
  - `:870` (`.round()` on the label);
  - `party_map_marks.gd:33` ("each through 0xb42d10").
- **Evidence (READ):** `0xb42d10` is MSVC's `_ftol2`:
  - its SSE path is `cvttsd2si` (`0xb42d25`);
  - its x87 path is `fistp` plus the carry correction to truncation (`0xb42d55..0xb42db9`).
  - The corners are `trunc(X +- 8)` and `trunc(Y +- 8)` (`0x61fd66..0x61fde2`).
  - The label is drawn at `trunc(Xc - (w/2 truncated))` and `trunc(Yc - 8 - h)`, from the
    unrounded top (`0x61fd8e`, `0x61ff95..0x61ffb9`).
  - For screen coordinates (positive) that is a floor. `.round()` is 1 px right/down whenever the
    fraction is 0.5 or more.
- **Fix:** use `.floor()` (`hud_worldmap.gd:859`). For the label, floor `dot_centre_x - floor(w/2)`
  and `unrounded_top - h`. Correct both comments.

### 5. MINOR: the hover rectangle is 1 px too wide on the right and bottom

- **Where:** `party_map_marks.gd:117-119` and its test, `party_map_marks_test.gd:101`, which
  asserts the departure.
- **Evidence (READ):**
  - After the truncation, every corner gets `-0.5` (`0x61fe11..0x61fe88`).
  - The test is `mx >= v0.x + 2` (`0x61fecb..0x61fef1`) and `v2.x - 2 >= mx`
    (`0x61ff1b..0x61ff2d`, `test ah,5; jnp`), and the same for y.
  - With `v0.x = L - 0.5` and `v2.x = L + 15.5`, an integer mouse hits for `L+2 <= mx <= L+13`.
    The code gives `L+2..L+14`. The test's `(114, 114)` on a quad at 100 is outside in the
    original.
- **Fix:** keep the inset start, and end at `r.end - 1` for integer mouse positions. Correct the
  test.

### 6. WRONG-LABEL: "the first member only" for the hover

- **Where:**
  - `docs/protocol/party_gui.md:681` ("for the first member only");
  - `party_map_marks.gd:34` ("the first member's quad");
  - `docs/rounds/party717.md:33`.
- **Evidence (READ):**
  - Every member's quad is tested (`0x61fec0: cmp byte [esp+0x43],0; jne` skips only once a hit
    has set the flag at `0x61ff53`).
  - So the rule is "the first member whose quad holds the mouse". The code
    (`hud_worldmap.gd:861-862`) does exactly that; only the prose is wrong.
- **Fix:** reword all three.

### 7. WRONG-LABEL: how the world map places a field member

- **Where:** `docs/protocol/party_gui.md:675` ("otherwise a field member is placed through the
  map's own transform (`0x60fbd0` / `0x60fa90`)").
- **Evidence (READ):**
  - With the player in the field (`0x61fa72..0x61fa88`, `je 0x61fd4e`), a field member goes to
    the player's marker pixel (`+0x97ac`, `+0x97b0`) plus `(pos - +0x97bc.., less 0.5)`, divided
    by the map scale (`+0x97f8`/`+0x97fc` times `[0xe1b840]`, `0x61f94d..0x61f9b7`), with y
    subtracted.
  - `0x60fbd0`/`0x60fa90` are used only when the player is in a dungeon (`0x61fa8e..`) or the
    member is (`0x61fa44..0x61fa5e`).
- The code (`party_world` -> `pixel_for_world`, the marker's own rule) is equivalent while the
  marker uses the same transform, so this is a doc fix.

### 8. WRONG-LABEL: the minimap's world-id stand-in is not labelled OURS

- **Where:** `client/scripts/World3D.gd:2924-2927` (the comment says the test is record `+0x68`
  against the player's `+0x20e4`).
- **Evidence:**
  - `0x9d4d90` is `mov eax,[ecx+0x20e4]` (READ): the player object's own world id.
  - The code compares against the player's **own party record**'s world id, a stand-in (OpenSRO's
    client keeps no other copy of it). It is right while the server keeps the record current.
- **Fix:** say so, as OURS.

### 9. MINOR: the draw-order prose omits the quest marks

- **Where:**
  - `party_map_marks.gd:26-28`;
  - `docs/protocol/party_gui.md` section 9 ("before the player's own arrow (`+0x374`, the loop's
    last draw)");
  - `docs/rounds/party717.md:27`.
- **Evidence (READ):**
  - After the party loop, vslot_013 draws the quest marks: `+0x3c0` `mm_sign_questarrow` and
    `+0x3c4` `mm_sign_questnpc` (`0x664ae6..`, Create's `push 0xda0cf4`/`0xda0d20`).
  - Only then does it draw the player's arrow.
- OpenSRO draws no quest marks, so nothing renders wrong.
- **Fix:** add them to the order so a later quest-mark round places them between the party and the
  player's arrow.

### 10. MINOR: the hover label sits over every dot

- **Where:** `hud_worldmap.gd:849` (`move_child(dot, count - 2)` keeps the label last).
- **Evidence (READ):** the original draws the text inside the loop, right after the hovered
  member's quad (`0x61ffc1`). So later members' dots (and the player's marker) draw over it.
- **Fix:** optional. Order the label right after the hovered dot.

### 11. WRONG-LABEL (an understatement): "under its buttons" is READ

- **Where:** `hud_minimap.gd:107-113`, and `party_gui.md` section 9's last OURS bullet.
- **Evidence (READ):**
  - The window's render is `0xb8f210`: slot 13 (`+0x34`, vslot_013), then slot 14 (`+0x38`,
    `0xba0300`, which renders the child list `+0x78`), then slot 15. The compass and zoom buttons
    are children (`resinfo\ifminimap.txt`), so they draw over every mark: READ.
  - Only the frame's place stays INFERRED. Finding 1's evidence (the mask, no frame bind in
    vslot_013, the screenshot) can be cited for it.

### 12. MINOR: wrong section reference

- **Where:** `party_map_marks.gd:6` says "party_gui.md section 8"; the reading is section 9.

### 13. MINOR (tests): two checks cannot fail for the reason they name

- `party_map_marks_test.gd:133-136`: mirroring `(0, -1)` with `flip_h` leaves it unchanged. So the
  "tip points east" check passes with or without `flip_h`, and cannot catch a dropped mirror. (The
  arrow art is left-right symmetric, MEASURED, so the mirror is invisible today.) An asymmetric
  probe (a point off the axis) would test the transpose.
- Nothing tests `HudWorldmap.update_party`: the pooling, the dot under the marker, the hover
  choice, or the label position.

## Verified (no finding)

- **Constants** (objdump of the exe):

  | address | value |
  |---|---|
  | `0xe1b800` | 1920.0 |
  | `0xda0ef0` | 47.0f |
  | `0xda0ee8` | 47.0 |
  | `0xe1b860` | 4.0 |
  | `0xd99a70` | -8.0 |
  | `0xd89240` | 8.0 |
  | `0xd81948` | pi |
  | `0xe1b8e8` | -1.0 |
  | `0xe1b7d0` | 0.5 |
  | `0xe1b898` | 2.0 |

  The math helpers:
  - `0xb47c50` contains `fsqrt` + `fpatan` (acos);
  - `0xb44a10` contains `fcos`/`fsin`;
  - `0xb44b40` contains `fsin`;
  - `0xb42de0` is `fsqrt`.
- **Textures:**
  - The strings `0xda0e70`, `0xda0dac` and `0xd9978c` feed `+0x36c`, `+0x39c` (CIFMinimap) and
    `+0x7ec` (CNIFWorldMap, `0x616382`).
  - Media.pk2, extracted and decoded:

    | texture | size | format |
    |---|---|---|
    | `mm_sign_party` | 8x8 | A1R5G5B5 |
    | `mm_sign_partyarrow` | 16x16 | A1R5G5B5 |
    | `wmap_sign_party` | 16x16 | A1R5G5B5 |

  - `mm_sign_partyarrow`'s art points up, and its gem centre is 1.5 px toward the tail.
  - `wmap_sign_party_02.ddj` exists in the archive, but the exe does not reference it.
- **The switch:**
  - The length is `sqrt(px^2 + pz^2)` in map pixels at the drawn zoom `+0x3fc`, not a world
    distance.
  - `fcomp` against 47.0 then `test ah,0x41; jne` takes the arrow for `dist >= 47`.
- **The arrow:**
  - It is centred at `offset x 47/dist` (`0x664728`), a fixed 47 px rim at every zoom.
  - The turn is `-(acos(px/d) [negated when dz < 0, 0x6647a0 jnp] + pi)` through `0x8b5c50`, a
    y-down rotation, which equals `atan2(oy, ox) - pi`.
  - Its corners are (-8,-8), (8,-8), (8,8), (-8,8) into v0..v3.
- **The transpose:**
  - The UVs are (0,0), (0,1), (1,1), (1,0) on the TL, TR, BR, BL corners, for the minimap dot
    (`0x664544`), the minimap arrow (`0x664732`) and the world-map dot (`0x61f9ee`). The player's
    arrow uses (0,0), (1,0), (1,1), (0,1): the contrast confirms the party quads are deliberately
    transposed.
  - `R(-90) . FlipH` equals the transpose, so `flip_h` with `rotation = turn - 90 deg` is exact.
  - Traced for the north-east case: the tip points north-east.
- **Who:**
  - The minimap has the world-id test (`0x6643ca..0x6643d8`) and the region test `0x9d5520`.
  - The world map compares only the member id (`0x61f8db..0x61f8e4`).
  - The minimap's party loop has no option gate (`0x663ab6..0x664387`).
- **Where:** the spawned object (`0x9c35e0`, `+0x90..+0x98`), else the record's `(x, 0, z)`
  through `0x9ecfd0`, on both maps.
- **Per frame:** vslot_013 is the window's draw. There is no throttle; the world map draws its
  dots every frame while open.
- **Transforms:**
  - `record_local`: the low byte steps world X and the high byte world Z. The live log's records
    equal the bodies across both axes (Dex 1920 + 916 - 1636 = 1200 east; Eve 1920 + 706 - 1626
    = 1000 north).
  - The minimap offset is `(dx, -dz)/1920 x S`. The minimap does not rotate: the tiles are
    axis-aligned with only scroll offsets `+0x404`/`+0x408`.
  - `party_world` is the player marker's own rule, fed with the same region pair.
  - Region crossings stay consistent, because `_fill_party_marks` runs after `_minimap_region`
    and `_minimap_group` update, in the same call.
- **Frames:**
  - **`f00000470.png`:** template-matching `mm_window` puts the window at x 1151 (READ placement,
    `width - 0x81`) and the aperture centre at index (1217, 109).
    - The north arrow's gem is at (1217.5, 64), so the arrow centre is 47.0 px north.
    - The east arrow's gem is at (1263, 109.5), so the arrow centre is 47.5 px east.
    - Both tips point outward (their white tip pixels are on the far side of the gem).
  - **`f00000580.png`:** the green rings are centred at (763.5, 357.5) and (783.5, 374.5).
    - Their difference, (20, 17), equals the logged canvas difference.
    - Cara's dot is under the marker.
    - The scale is 60 units/px, consistent for 1200 and 1000.
  - **Against the user's shots:**
    - `map_JXHQtcH.png` has its rim arrow at about 46.5 px, pointing outward, over the ring.
    - `map_yu1cjfM.png`'s dot is 6 px of green at 1:1.
    - `map_vxAS9rr.png`'s world-map dot is a green ring of 8 px at 1:1.
    - All three match the build, apart from finding 1's layering near the rim.
- **Regressions:**
  - With no party, both maps resize the lists to 0 once and hide the pools.
  - The sign roots, the teleport and NPC marks, and the player's arrow are untouched.
  - The world map keeps the party layer then the marker last, after place labels are rebuilt.
- **Perf:** a settled party allocates nothing a frame.
  - `party.member()` is a scan of at most 8.
  - `_party_body_for_board` is a dictionary lookup with a 250 ms miss throttle.
  - The name is assigned only on change.
  - The pools grow only.
  - The lane's gate (jangan, no party) is SAME on all four numbers.
- **Branch:** dev's newer `07ff0ce4` (AGENTS.md) makes the two-dot diff show AGENTS.md reverted.
  The three-dot diff (`dev...95647a4b`) has no AGENTS.md change, so a merge keeps dev's text.

## Tests (this review, on the box, `RENDER_DIR=/opt/opensro-client-r717rev`)

- `tests`: **230 suites, 0 failing.**
- `check`: **602 scripts and 9 scenes, ALL LOAD.** The only errors are the absent native library
  (`native_bin`), which falls back as designed.
- `party_map_marks_test.gd` on its own: 41 `ok`, 0 failures.

The review's scratch (`/var/tmp/r717rev`, `/opt/opensro-client-r717rev`, and the extracted Media.pk2
files) was deleted afterwards.
