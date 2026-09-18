# UI lane rounds (2026-09-18) — to be folded into WORLD_ISSUES.md by the coordinator

Two rounds, both measured. Numbering is left to the merge.

## Round: the client's UI font, the way the client picks it

**What was wrong.** `UiBuilder` mapped a control's `FontIndex` to *the index-th `.ttf` in
`fonts\` directory order* and used the recovered sizes `[9, 8, 12, 11, 15]` as pixel sizes.
The first was a guess, the second a unit error; together every window's text was a third too
small and set in a Korean face (TaeUtum) the client never uses for the English UI.

**How the client actually does it** (client binary, decompiled dump in `/var/tmp/decomp_client`,
disassembly via `tools/ghidra/Disasm.java` on `re_client`):

1. **Bundled fonts are installed, not drawn from directly.** `Game.cpp` walks `fonts\` in
   Media.pk2, extracts each file (`CreateFileA(..., GENERIC_WRITE, CREATE_ALWAYS,
   FILE_ATTRIBUTE_HIDDEN)`, asserts `"CreateFile(%s)"` at Game.cpp:0x3fa/0x405) and registers it
   with `AddFontResourceA` in `gfxmainframe::FUN_00ba60b0` (assert `"AddFontResource(%s)"`,
   gfxmainframe.cpp:0x1fb). So GDI can resolve the bundled families by name.
2. **One face for every FontIndex, by name, from the text table.** The font-table builder
   `FUN_00469350` registers the five indices with `GNFontChar::FUN_004927b0(index, size)`:
   `(0,9) (1,8) (2,12) (3,11) (4,15)`. The face travels in ESI — invisible in the decompile, plain
   in the disassembly: `004693eb MOV ESI,[ESP+0x34]` (the caller's 7th argument), `TEST ESI,ESI`,
   `JZ 0046941c` → `0046941c MOV ESI,0xe172d8` (the NULL fallback), then the calls. The 5th call at
   `00469445` (index 4) uses whichever face is current. The one caller (`funcs_010.c:47812`)
   builds that 7th argument from `FUN_008c9c30(L"UIC_STT_FONTNAME")` — a UI text-table lookup —
   converted to a `char*` by `FUN_004fc950`.
3. **The fallback literal** at `0xe172d8` is `b1 bc b8 b2 c3 bc 00` (DumpBytes.java) = CP949
   **"굴림체"** (GulimChe).
4. **Creation.** `GNFontChar::FUN_004927b0` → `FUN_00baa110(this, index, size, face, italic,
   bold, underline)` (assert `"CreateFont(%s)"`, sriflib/GNFontChar.cpp), which fills a `LOGFONTA`
   and calls `CreateFontIndirectA`:
   - `lfHeight = -MulDiv(size, 0x60, 0x48)` — **points at a hardcoded 96 dpi**; a negative
     lfHeight is the em height in pixels. Index 0 = 9pt = **12px**; the table is
     `[12, 11, 16, 15, 20]` (MulDiv rounds to nearest: 8pt → 10.67 → 11, 11pt → 14.67 → 15).
   - Four variants per index: `[0]` regular, `[1]` italic (`lfItalic=1`), `[2]` bold
     (`lfWeight=600`), `[3]` underline; the caller's flags `(0,1,0)` create regular + bold.
     Which controls draw with the bold variant is not recovered; none is applied.
   - `lfCharSet=1` (DEFAULT_CHARSET), `lfQuality=0` (DEFAULT_QUALITY).

**What the archive says** (`tools/dump_fonts.gd`, new, reads the player's own Media.pk2):

| Source | Family |
|---|---|
| `textuisystem.txt` `UIC_STT_FONTNAME`, English column | **Tahoma** |
| same row, Korean column | 굴림체 (= the binary's fallback) |
| a second, 16-column `UIC_STT_FONTNAME` row | Arial |
| `fonts\기본서체.ttf` ("basic typeface") | TaeUtum (400) |
| `fonts\영문서체.ttf` ("English typeface") | Arial Rounded MT Bold (700) |
| `fonts\채팅서체.ttf` ("chat typeface") | SeUtum (400) |
| `vplus\vfont.ttf` | Arial (400) |

Tahoma is not in the archive; it is a Windows system font, and the real client renders the
English UI in the system's copy.

**What is shipped.** `UiBuilder` now resolves the face as the client does: the text table's
`UIC_STT_FONTNAME` (falling back to the binary's 굴림체); a bundled file whose family is that
name; else the system's font of that name via `OS.get_system_font_path`, accepted **only if the
loaded file's own family name matches** (fontconfig returns a substitute — DejaVu Sans for
Tahoma on the render box — and a substitute must not pass as the real face); else — **disclosed,
ours** — Arial from `vplus\vfont.ttf`, chosen because it is the archive's other authored value
for this same key. Sizes are the em pixels above (`FONT_SIZES`), with the point table kept as
`FONT_POINT_SIZES`. One log line says what was resolved:
`UiBuilder: UI face 'Tahoma' (UIC_STT_FONTNAME) -> <source> (family '...'); sizes px [12, 11, 16, 15, 20]`.

**Rendering flags.** The reference screenshots' text is aliased: every glyph pixel of "Current
Exp." in `character.png` falls in one luminance bucket (`{12: 162}`), i.e. one text colour and no
edge ramp. The font is therefore set to `FONT_ANTIALIASING_NONE`; `HINTING_NORMAL`, no autohinter
and `SUBPIXEL_POSITIONING_DISABLED` are the Godot analogs of GDI's integer-pixel, native-hinted
rendering — the aliasing is measured, those three are the analog, not values read from the binary.

**Measured against the reference** (`docs/reference/ui/character.png`, which is a **1.066×**
crop: its frame is 388 px for an authored `GDR_PI_SUBFRAME` of 364×356, so reference pixels are
divided by 1.066):

| | reference (÷1.066) | ours, 1:1, Arial fallback |
|---|---|---|
| "Current Exp." cap height | 9 rows → 8.4 px | **9 rows** |
| descender rows below it | 2 | **2** |
| glyph luminance levels | 1 (`{12: 162}`) | **1** (`{12: 166}`) |
| "Phy. balance" width | 68 px → 63.8 px | 69 px (Arial is the wider face, +8%) |

Tahoma's own metrics predict the same: capHeight 1489/2048 × 12 = 8.7 px; the previous 9 px em
would have given 6.5 px. `GDR_PI_TEXT_HP_DAT` carries `FontIndex 1` (11 px) and the HP readout
now renders smaller than its row label, as in the reference.

**A second fix the measurement forced: no clipping.** The reference draws "Phy. balance" 63.8 px
wide and "Mag. balance" 65.7 px wide inside authored rects (`GDR_PI_TEXT_PHYBAL`, `_MAGBAL`) of
**58 px** — the client lets a static's text overrun its rect (UI_TODO rule 13 already recorded
`TEXT_HP_DAT` overrunning by 17). `_apply_font` had `clip_text = true`, which cut those to
"Phy. balan" / "Trader Gra"; it is now false and every label in the window renders whole.

**Not grounded / open.** The bold (600) variant's users; whether `lfQuality=0` on the original
machines produced aliased text by policy or by size (the reference shows aliased, which is what is
matched); the Tahoma path itself was verified by code path and the family guard, not by a render —
the render box has no Tahoma, so its frames show the Arial fallback (logged as such). On a
Windows machine with Tahoma installed the resolution takes the system-font branch.

Files: `client/scripts/ui/ui_builder.gd`, `client/scripts/ui/ui_builder_test.gd` (font table,
face fallback), `client/tools/dump_fonts.gd` (new).

## Round: the minimap's signs

`interface\minimap\` has one sign per kind of thing around the player. `HudMinimap.update_signs`
now draws `mm_sign_npc`, `mm_sign_monster` and `mm_sign_otherplayer` at the entities' real
positions, from the lists the client already has: the `Npc_*` holders under each loaded
`RealTerrain_*` group, `_monster_bodies`, `_other_bodies` (World3D passes positions only — the UI
seam stays "positions in, nothing out"). `mm_sign_questnpc` and `mm_sign_party` exist but nothing
the client receives yet says which NPC carries a quest or who is in the party, so they are not
drawn.

**Placement rule** (pure, tested): the tile is laid so the player sits at the aperture centre and
one region (1920 units) spans `256 × zoom` px with world X along u and world Z along v — the same
rule `update_player` positions the tile by (round 100) — so a sign lands on the map's own pixel
for that spot: `offset = (entity − player).xz / 1920 × map_size`. A sign whose centre falls
outside the 52.5 px aperture circle is hidden. Signs are pooled `TextureRect`s between the map and
the player arrow, sized by their own artwork.

**Measured.** At the Jangan spawn (97/168 local 1002,1020) with the in-memory server:
`HudMinimap: signs drawn 8 of 71 entities (npc 49, monster 22, other 0): npc@(-3,4) npc@(-3,4)
npc@(-3,39) npc@(13,22) npc@(-19,22) monster@(21,-21) monster@(22,-37) monster@(4,-21)`.
Pixel clusters in the frame (connected components inside the aperture): three red 12-px clusters
at x offsets 21, 22, 3 and two blue at −20, 13 — matching the three monsters and the two
south-west/south-east NPCs (a constant ≈9 px y shift between log and cluster centres is the
sign core's position in its 16-px art plus the HUD's top offset). The three signs not visible as
clusters are accounted for by the log: two NPCs share the spot (−3,4), under the player's own
16-px arrow, and one at (−3,39) sits under the frame's "S" marker. So: the client's art has
**monsters red and NPCs blue** — the file names decide, not a colour assumption (an earlier read
of the frame had that backwards).

Files: `client/scripts/ui/hud/hud_minimap.gd`, `client/scripts/ui/hud/hud_minimap_test.gd`
(offset rule, culling, no-artwork path), `client/scripts/World3D.gd` (three lines in the per-frame
minimap block plus two position helpers — nowhere near the player-pose code).
