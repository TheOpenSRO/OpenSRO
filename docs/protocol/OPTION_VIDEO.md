# The Option window's Video tab

Round 694. What `sro_client.exe` offers on the Video tab of its Option window, what each
setting does in that client, and what each does in OpenSRO. Code: `client/scripts/setting/
video_options.gd` (the data), `client/scripts/ui/hud/option_video_page.gd` (the tab),
`World3D.apply_video_options` (the world). Labels: **READ** (the exe; addresses are its own),
**MEASURED** (the archive or a run), **INFERRED**, **OURS**.

## The window (READ, MEASURED)

The System window's Option button opens `res_ui\optionwnd.2dt` (CNIFOption, round 615). Its
pane 78 is the Video tab (MEASURED: 208 records in the box's Media.pk2). The page builder is
`0x5fef70`; it fetches its controls by GetChild chains and fills them:

| Control | Path | Class field | What |
|---|---|---|---|
| Resolution | 78 -> 14 -> 15 | +0x79c | combo; label 162 `UIIT_STT_RESOLUTION` |
| Set Brightness | 78 -> 462 -> 15 | +0x7a0 | combo; label 163 `UIIT_STT_LUMINOSITY` |
| list scroll bar | 78 -> 465 | +0x7a4 | CNIFVerticalScroll |
| Window screen / Full screen | 78 -> 204 / 203 | +0x7a8 / +0x7ac | check boxes; labels 202 / 201 |
| Free / Third Person / Quarter Angle | 78 -> 207 / 208 / 209 | +0x7b0..+0x7b8 | check boxes; labels 210..212 |
| Graphic 1 / Graphic 2 | 78 -> 24 / 25 | | tabs, group 11 (`UIIT_STT_GRAPHIC_QUALITY_CONTROL1/2`) |
| the list | 78 -> 215, 218, ..., 248 | +0x10d4 vector | twelve CNIFVideoOptionSlot, two a line; label 216, combo 217 |

The list holds fifteen rows -- entries 0..13 and 15; the slot loop steps over 14 -- each with a
label, a tooltip and its choices pushed in this order (string pushes in `0x5fef70`):

| Entry | Label (English text) | Tooltip | Choices |
|---|---|---|---|
| 0 | `UILM_TEXT_GRAPHIC_QUALITY` Graphic Quality | TTDESC_03 | Low, Middle, High, Large scale battle, User control |
| 1 | `UIIT_STT_SHADOW_DETAIL` Shadow Detail | TTDESC_04 | Nothing, Circle, Detail |
| 2 | `UIIT_STT_SCENERY_SIGHT_RANGE` Background Sight Range | TTDESC_05 | 1..5 |
| 3 | `UIIT_STT_CHAR_SIGHT_RANGE` Character Sight Range | TTDESC_06 | 1..5 |
| 4 | `UIIT_STT_WATER_REFLECTION` Water Reflection | TTDESC_07 | Off, On |
| 5 | `UIIT_STT_WATER_DETAIL` Water Detail | TTDESC_08 | Low, Middle, High |
| 6 | `UIIT_STT_METAL_DETAIL` Metallic Sheen | TTDESC_09 | Off, On |
| 7 | `UIIT_STT_LIGHT_EFFECT` Light Effect | TTDESC_10 | Off, On |
| 8 | `UIIT_STT_FILTERING` Texture Filtering | TTDESC_15 | Off, On |
| 9 | `UIIT_STT_TEXTER_DETAIL` Texture Detail | TTDESC_11 | Low, Middle, High |
| 10 | `UIIT_STT_LENS_FLAIR` Lens Flare | TTDESC_12 | Off, On |
| 11 | `UIIT_STT_BLOOM_EFFECT` Bloom Effect | TTDESC_13 | Off, On |
| 12 | `UIIT_STT_DYNAMIC_ANIMATION` Dynamic Animation | TTDESC_14 | Off, On |
| 13 | `UIIT_STT_EFFECT_QUALITY` Effect Quality | TTDESC_16 | Turn Off All Effects, See Hit Effects, See All Effects |
| 15 | `UIIT_STT_OPTIMIZE_A_E_EXPRESSION` Display Friendly/Enemy | TTDESC_17 | Friend/Enemy Dress, General |

Brightness lists Very Dark, Dark, Normal, Light, Very bright. Resolution lists every adapter
mode wider than 799 and taller than 599 in formats 0x14..0x16 (D3DFMT R8G8B8 / A8R8G8B8 /
X8R8G8B8), as `%d x %d`; a 1280 x 1024 mode becomes the Default's choice. The English texts are
the box archive's `textuisystem.txt` column 8 (MEASURED). The tooltips say what each does
(MEASURED, the same column): e.g. TTDESC_15 "Compensates rough outlines to produce more
natural-looking objects", TTDESC_14 "a technique of expressing better animation of fabrics,
texture, and hair", TTDESC_17 "When a large-scale combat outfit is worn, the combat outfit of
nearby players are unified to improve performance".

## The combo box (READ, round 696)

Every Video-tab combo is a CNIFComboBox (MEASURED: the file's 14 CNIFComboBox records are all
under pane 78 -- Resolution and Set Brightness at 156 x 18, the twelve rows' 217 at 150 x 20; no
other Option tab has one). Its create (`vslot_010`, `0x486d30`, asm `0x486d6e..0x486ee1`) takes
its own client rect (`0xb8f420`, {x, y, w, h}) and makes three children:

| Child | Rect | What |
|---|---|---|
| 1 (+0x384) | {W-20, 0, 20, H} | button, `interface\ifcommon\com_qst_downarrow_button.ddj` (20 x 20, MEASURED) |
| 2 (+0x388) | {0, 0, W-20, H} | CNIFStretchWnd, base `interface\ifcommon\com_blacksquare_` (`0x49b040`: the four corners, `left_side` twice, `right_side` twice); +0x1c4 = 0xff000000 |
| 3 (+0x38c) | {5, 0, W-30, H} | CNIFStatic, text "" -- the value |

CNIFStretchWnd's draw (`0x49aeb0`) fills its rect with the +0x1c4 colour when it is non-zero
(`0x46d2a0`: a quad over the window rect in that colour) and then draws its frame pieces, so
child 2 is the **black value box**. Round 694 read it as the list's frame and drew no field (the
user's report, 2026-10-02: "the drop downs need a black box in them"). The pieces are 4 x 4 each
(MEASURED): a near-black top-left edge (0x080808..0x100c10) and a grey bottom-right one (0x6a656a,
0x7b797b) -- a sunken field. The six-piece class's UVs (`0x49a140` / `0x49a7d0`) were not read; the
reference picture (the user's, at 2x) has continuous one-pixel top and bottom edges in exactly the
side pieces' outer-column colours, so the top and bottom are drawn as `left_side` / `right_side`
transposed (MEASURED against the picture, not read): the bottom row then matches it pixel for
pixel (0x7b797b); the top row is 0x080808 with every fourth pixel 0x000400 against the picture's
0x080808 throughout, so the top's exact source is not established (within 8 levels). The arrow is drawn at its button's rect: an
18-tall combo draws the 20 x 20 texture 18 tall (MEASURED, 36 picture pixels at 2x).

Measured against the reference (the user's picture, 1384 x 1004, the window at 2x): the row
field spans 260 x 40 picture pixels = 130 x 20, its arrow 40 = 20; the Resolution field 272 x 36 =
136 x 18, its arrow 40 x 36 = 20 x 18 -- every number the READ rects give. The value text is
centred in {5, 0, W-30, H}, white (MEASURED in the picture).

## The open list (READ, round 697; corrected and rebuilt in round 700)

The combo's open function (`0x486f50`) creates a **CNIFPopupListCtrl** (runtime class 0x115e2c0,
"CNIFPopupListCtrl"; base CNIFPopup 0x115e2e0; base CNIFStretchWnd 0x115e2a0 -- the class names
are the descriptors' init strings) as the combo's child. MEASURED below is the user's 2x screenshot
of the original with Graphic Quality open (664 x 382, every value doubled exactly):

| What | Value | Where |
|---|---|---|
| y | **20** below the combo's top (the constant 0x14, not the combo's height) | READ `0x486fc1..0x486fdf`; MEASURED: the list's top frame row 40 px under the field's top row (y 152 vs 112) |
| x, width | **the value field's: x 0, W - 20** | MEASURED: the list's frame columns are the field's (x 348 and 606), and beside it the arrow's column shows the row art undimmed. Round 697 read the rect as `{0, 20, W, 0}`, the combo's full width -- the picture says otherwise; the W the open function passes was not re-read |
| frame | the six `interface\ifcommon\com_blacksquare_` pieces, as the value field | `0x486f8a`, `0x49b040`; the user, 2026-10-03: the white and black border look right |
| fill (+0x1c4) | the combo's +0x380: **0x80000000** by the constructor (`0x486af3`), **0xb4000000** for every Option-window combo | `0x487050`; `0x5ff1f6` (Brightness), `0x5ff532` (Resolution), `0x6f7200` (each video row); MEASURED: row art of 0x27 reads 0x0b under it (0x27 x 75 / 255) |
| rows | the item count for every Option combo (no scroll bar) | `0x5ff1d2`, `0x5ff50e`, `0x6f71fb` |
| list | a CNIFListCtrl at {4, 4}, sized W-8 x H-8 | `0x49b820`, `0x49b920` |
| height | rows x line + 8 | `0x48707f..0x48708e`; MEASURED 146 = 2 x (5 x 13 + 8) |
| line | **the font's size in points + 4 = 13** | `0x49b88b..0x49b896`: `[FUN_00ba5460(0) + 4] + 4`, where +4 of the font object is the size GNFontChar registered (`0x4927f9` -> `0xbaa110`'s `param_1[1]`, the value it MulDiv's into the LOGFONT), 9 for index 0 (FUN_00469350); MEASURED: baselines 26 px apart at 2x |
| text | from the line's top by the font's cell | MEASURED: cap tops 3 below each line top, baselines 12 (GDI's cell origin) |
| item text | normal **0xffffffff**, hover **0xffffff80**, pressed 0xff8080ff | `0x4845a0` -> `0x475d10` with the list's +0x368 / +0x370 / +0x36c |
| hover bar | on (+0x362 = 1), **0xff8080ff** (+0x3a0), an untextured quad from the line's top, the item text's height | `0x49b820`; `CNIFListCtrl::vslot_013 0x483460`: the bar's height is the text extent's +0x50 high word unless +0x360 is set; draw `0x483a70` |
| alignment | the combo's own (+0x88 forwarded): 1 = centred at (width - text width) / 2, 2 = right | `0x4870a1`; `vslot_013 0x483460`; the Option window sets 1 on Resolution and Brightness (`0x5ff1ec`, `0x5ff528`); MEASURED: every Graphic Quality item is centred on the field's centre (x 478 at 2x), so the video rows are centred too (where they get it was not read) |
| scroll bar | a CNIFVerticalScroll (child 5), shown only with more items than rows | `0x49bba0` |

So the "transparent black" the user remembers is 0xb4000000: black at 180/255.

**Round 697's PopupMenu, and why it went (round 700).** Round 697 styled the OptionButton's own
PopupMenu with these values. The user's screenshot of it on Windows (v0.1.483) showed an opaque
grey list: a PopupMenu is a Window whose viewport Godot 4.2.2 does not make transparent (no
FLAG_TRANSPARENT / transparent_bg in `popup.cpp` or `popup_menu.cpp`), so the translucent fill was
drawn over an opaque clear colour. It also left-aligned the items and spaced them by Godot's line
height for a 12 px font plus 4 -- 18 units, against retail's 13 (the line was read as "font height
+ 4" and the font's height taken as Godot's). And it spanned the arrow.

**ComboList** (`client/scripts/ui/hud/combo_list.gd`) replaces it: a Control on a CanvasLayer (layer
120) above the game, in the game's own window, so the rows below show through. It draws the frame
and fill (`OptionVideoPage.popup_panel`), the hover bar and the items centred on 13-unit lines,
at the field's x and width, 20 below the combo's top, scaled with the combo. A left press on the
combo opens it (the OptionButton stays for the value text and the item API; its press is
accepted in the `gui_input` signal so its PopupMenu never opens). OURS: a click outside closes it
and is eaten; Up / Down / the wheel move the bar, Enter / Space pick, Escape closes; a list that
would run off the bottom of the window is moved up to fit; no pressed colour.

## The record (READ)

`CGame+0x570` (`FUN_00835240`): a selector byte, then two records of 0x2c bytes -- one per
Graphic tab. In record r (base `+r*0x2c`): bytes 4+i are entry i in force, bytes 0x14+i the
player's own ("User") copy, 0x24 the Graphic Quality, 0x25 the brightness, 0x28 / 0x2c the
resolution. `Setting\SROptionSet.dat` (loader `0x502680`): u32 13, then tags -- tag i (1..15)
two bytes (in force, user) for entry i (the jump table at 0x5031ac: tag 1 reads bytes +5 / +0x15,
tag 2 +6 / +0x16, tag 3 +7 / +0x17 -- byte 4+i; the decompiler's normalised `case 5: +8` is
wrong), 501 quality, 502 brightness, 503 / 504 width /
height, +100 for record 1, 9999 the selector.

**Presets** (`0x5015a0`, the quality's table; User restores the second copy):

| | Shadow | Bg | Char | Refl | Water | Metal | Light | Filter | Texture | Lens | Bloom | Dyn | Effect | F/E |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Low | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 |
| Middle | 1 | 2 | 2 | 0 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 0 |
| High | 2 | 4 | 4 | 1 | 2 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 2 | 0 |
| Large scale battle | 0 | 2 | 4 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 1 | 0 |

After loading the file, every record whose quality is not User gets its preset again
(`0x503180..0x503192`). **The defaults:** the record constructor `0x5f75e0` sets Middle, Normal,
1024 x 768; the Video tab's Default (`0x5fc340`) sets Middle, Normal, the 1280 x 1024 mode,
**full screen** and the Free view. **The shipped file** (MEASURED, `/opt/sro-files/client/setting/
SROptionSet.dat`): selector 0; record 0 Middle, Normal, 1280 x 1024; record 1 Low. So the
shipped client draws Middle -- with Water Reflection **off**. Its tag 4 (Water Reflection) is 0
already; the tag 5 = 1 round 628 read is Water Detail (Middle), and that round also missed
the re-application.

## What each does in the original (READ) and here

`CGame::FUN_00835000` copies the record in and passes each byte to `SWorld::vslot_043(case,
value)` (`0xa194a0`), which also stores it at `SWorld+0x2e50 + case*4` (getter `vslot_044`).

| Setting | Original (READ unless marked) | OpenSRO |
|---|---|---|
| Resolution | the device mode; in a window also the window: `FUN_00835510` adds WS_CAPTION / WS_SYSMENU (0xC80000), AdjustWindowRect's the client size into a frame and MoveWindow's it centred at ((SM_CXFULLSCREEN - w) / 2, (SM_CYFULLSCREEN - h) / 2) | the OS window's client size (OURS list of usual sizes up to the screen): a maximised window is restored first, the size is cut to the usable area less the frame, the frame centred there, and the node's size checked against the OS window's (round 696, below); listed and applied only at a size whose view (window / UI scale) is at least retail's 800 x 600 minimum (round 696 review); unavailable in full screen, where Godot keeps the desktop's size |
| Window Mode | device full screen / window (`opt+9`, `0x5fdae0`) | `Window.mode` full screen / windowed, live |
| View | camera mode 0/1/2 (`UI_CHANGED::FUN_00780420`) | `World3D.set_camera_view` (round 639's three views), saved as [ui] camera_view |
| Set Brightness | case 0: gamma ramp `65535 * pow(i/255 * B, A)`, (A, B) = (1.4, 0.8) (1.2, 0.9) (1, 1) (0.8, 1.2) (0.6, 1.4); full screen only | the same curve as a full-screen canvas pass over the finished frame (OURS: in a window too); none at Normal |
| Graphic Quality | the presets above | the same presets; any hand-set row switches to User (INFERRED) |
| Shadow Detail | case 2: Detail builds a 96 x 96 target and 32 x 32 shadow textures per character; `SWorld::vslot_024` (0xa182f0, round 702) draws by the value: 1 Circle -- `skybox\shadowsphere.ddj` under the first ten CICharactors (players, monsters, NPCs) of the world's object map, keyed by `(int)(|object - player| x 10)` (CICPlayer::vslot_005 0x9d6f19..0x9d6fad), no distance limit, size BCRadius + 5 = the diameter (D3DXMatrixOrthoLH 0x9f4462), TFACTOR 0xa8000000 (0x9f44cd); 2 Detail -- the projected per-character shadows (`Map::FUN_009f35f0`, up to ten, key <= 3000 = 300 units from the player; the ground keeps 1 - 150/255 of its colour under a solid silhouette, fading over the 17 units below, FUN_009f2f80) and **no circle**; 0 neither | Nothing: no circle, no sun shadow map; Circle: the circles (`CharacterBlobs`: every character kind, the ten nearest the player, BCRadius + 5, alpha 0xa8; on a placed floor the circle stays on the floor -- OURS, the original's lies on the terrain under it, consistent with the user's ring-on-floors decision of 2026-10-03); Detail: no circle, and the DirectionalLight3D's shadow map reaching 400 from the camera (READ 300 from the player + the camera's 90), cast by characters only (terrain and placed objects cast none, as the original's scenery: its shadows are baked), received by the shaded placed objects natively and by the terrain through `ShadowCatcher` (a multiplying next pass, k = the READ 0.412 decoded; Forward+ only). Nothing changes with the zoom |
| Background Sight Range | case 8: far plane 1500/2500/3500/4500/5500; view distance `min(0.8 far, 2500)` = 1200/2000/2500/2500/2500 scales the fog planes and is the map-object range + 480; world+0x23db = 800..2048 (reader not found) | map-object animation range = view - 480 (READ rule); the fog planes = the zone's channels 10 / 11 x view (READ rule, round 702: `WorldFog`) -- Jangan (Env7, 0.759 / 1.000) 911..1200 at 1, 1518..2000 at 2, 1897..2500 at 3 to 5 (round 705, MEASURED in the log); camera far x min(1, far/3500) (OURS); 3 = as before |
| Character Sight Range | case 9: stored only; no reader found (asm `+0x2e74` has one writer; 17 getter calls carry other cases; no record-offset reader) | OURS: other players' and monsters' meshes drawn to 600 / 1200 from the camera at 1 / 2; unlimited at 3..5 (as before). NPCs are built into their region's group here and are not reached; the original's rule (no reader found) is unknown |
| Water Reflection | case 6: builds / frees the reflection target and two 512 x 512 textures | round 628's pass; from the next login (a region's water is built for one mode) |
| Water Detail | case 7: stored only; no reader found | OURS: the reflection target's rows 256 / 512 (READ size) / 1024, live |
| Metallic Sheen | case 0xc -> object renderer +0x194; forced off below shader model 3 (`CGame::FUN_00834fb0`) | kept, draws nothing: no environment-map sheen here |
| Light Effect | case 0xb -> object renderer +0x1a4 (Sun / Torch, TTDESC_10) | **The glow pass** (round 720 and its review, READ): `+0x1a4` is the effect manager's (`0x1112fb0 + 0x1a4`, set through the thunk `0xbbdad0` -> `0xbc1230`), the gate `CRTModParticle::FUN_00c81450` and `FUN_00c43100` test. On, a particle entry with a glow byte is drawn by the occlusion-tested glow pass (depth test off, fading in and out); off, as an ordinary depth-tested particle at full alpha. Live (`AmbientParticles.set_light_effect`). Only the teleport structures' ambient effects are played so far (teleport_effects.md); the sun/torch half is not done |
| Texture Filtering | byte 0xc; no reader found; TTDESC_15 "compensates rough outlines" | INFERRED anti-aliasing: MSAA 2x on the 3D view (OURS level); Forward+ only -- greyed under Compatibility (MEASURED below). Under Forward+ the change on screen is small (the review: barely visible) |
| Texture Detail | case 5: `IDirect3DBaseTexture9::SetLOD(2 - v)` on every texture (vtable +0x2c) | `Viewport.texture_mipmap_bias` 2 / 1 / 0 (INFERRED equivalent look, not the memory saving); Forward+ only -- greyed under Compatibility (MEASURED below). **Little effect in the world yet:** the bias reaches only mipmapped textures, and the terrain's are built without mipmaps (the review, `mapm_terrain_builder.gd`); docs/TODO.md |
| Lens Flare | case 0xd: `SWorld::vslot_005` draws `Map::FUN_00a21280` while +0x2e84 is set | the sun glow sprite (`SkyBox\glow.ddj`, INFERRED to be the flare's piece) |
| Bloom Effect | case 1: screen-size and 512 x 512 render targets; the pass `Map::FUN_00a1d790` (READ in full, round 702 review: below). Also the objects' light (round 706): world+0x2e54 stays set while the screen target world+0x27c3 exists (`Map::FUN_009fb180` clears it otherwise), and with it the light's diffuse is environment channel 2 x 0.8 instead of x 0.6 (0xa1d19b..0xa1d20b) | `RetailBloom`, the original's formula, both renderers; the user's "glow" toggle is this row; `ObjectLight.diffuse_scale` follows it |
| Dynamic Animation | case 0xe -> renderer +0x19c, re-inits the animated objects; TTDESC_14 fabrics and hair | kept, draws nothing: no cloth or hair motion here |
| Effect Quality | `IDecoSkill::FUN_00a50dc0(q, owner)`: 0 none, 2 all, 1 only owners passing two unread tests | `SkillEffects.quality`: 1 shows effects the player casts, takes or carries (INFERRED) |
| Display Friendly/Enemy | 0 lets `GlobalDataManager::FUN_009dae90/9db750` swap a large-battle outfit tint; 1 (General) never | kept, draws nothing: no battle outfits here |
| SSAO | (none in the exe) | OURS: Godot SSAO, Forward+ only, default off; radius 16, intensity 4, light affect 1 (OURS). **A light effect only:** the terrain is unshaded and the object mods write EMISSION, which SSAO does not darken (measured below) |
| Fog (temporary) | (none: the original always fogs -- `Map::FUN_00a26f60` turns FOGENABLE on and sets linear fog between the zone's planes, `WorldFog`'s header) | OURS, TEMPORARY (round 702, the user's request: "make a temporary toggle in the video settings so I can compare and make a decision"): On (default) draws the original's linear fog at its own planes and colour; Off draws none. No preset names it; saved as `fog_temporary`. Since round 705 Forward+ mixes a half-fogged pixel in display values, as Direct3D 9 and Compatibility do (it mixed in linear light: lighter) -- exact for a destination shown at 0.2 and at full fog, within 17/255 elsewhere (OURS method; the exact mix's screen read cost +1.4 ms at 4K) |
| Renderer | (none) | OURS: Forward+ / Compatibility at the next start, through round 693's RendererChoice when the build has it |

## Applied at start-up (round 702)

Until round 702 the saved record never reached the world when it started: `apply_video_options`
compared each row with the record in force, and on the first call that record was the one being
applied (`video_options()` had just made it so), so no row "changed" and nothing was set. Every
start therefore drew the scene's own settings whatever the window said -- the sun's shadow map on
(in Circle too, which is why the shadows changed with the zoom: Godot's shadow distance is 100 from
the camera), no glow (Bloom on in Middle), no MSAA (Filtering on), no mipmap bias (Texture Detail
Middle) -- until a row was changed in the window; even then only the changed row was applied. The
first call now applies every row. So a default record now draws, from the first frame: Circle (no
sun shadow map, the round shadows), the bloom (RetailBloom since the review), MSAA 2x (Forward+) and mipmap bias 1.

**Bloom is the original's own (round 702 review).** Turning the Bloom row's Godot glow on from
start-up made the picture brighter and flatter (MEASURED: +10-12 luma on the spawn's ground, contrast
relative to brightness -15 %): round 693's glow values (intensity 0.8, bloom 0.2, threshold 0.85)
were a guess. The original's bloom, READ in full (`Map::FUN_00a1d790`; constants from the world's
constructor `Map::FUN_00a2f370`):

1. **Downsample:** the screen (target +0x27c3) into a 512 x 512 target (+0x27c7), bilinear,
   MODULATE(TEXTURE, TFACTOR) with TFACTOR RGB 0x80: x 128/255.
2. **Horizontal blur** into a target cleared to 0 (+0x27cb), blend SRCALPHA / ONE: colour
   SUBTRACT(TEXTURE, TFACTOR 0x28) -- the threshold, 40/255, clamped at 0, in this pass only --
   and each tap's alpha its weight: centre 0x50, +-1 0x46, +-2 0x32 (/255; the table at +0x68e3
   holds five values, three are used per side), at +-2.6 and +-5.2 texels of 512 (2 x 13 x i / 10,
   step +0x690b = 13).
3. **Vertical blur** back into +0x27c7: the same weights and offsets in y, no threshold.
4. **Composite:** the plain screen first, then the blur with SRCBLEND = BLENDFACTOR 0xc0c0c0
   (+0x690d) and DESTBLEND = SRCALPHA, alpha the TFACTOR's 0xc6 (+0x690c):
   `out = clamp(S x 198/255 + Blur x 192/255)`, in display values, before the interface.

A flat field below 0.5 comes out darker and above 0.5 brighter: it raises contrast. `RetailBloom`
draws it as one canvas pass on layer -1 (above the 3D view, under every interface layer and the
brightness pass), Godot's glow always off. Under Forward+ the pass is a 514 x 514-vertex grid, one
vertex per texel of the 512 x 512 target: each vertex computes retail's three passes for its texel
(81 screen samples: the downsample at the texel centres, the horizontal taps between texels with the
threshold, the vertical taps), the fragments interpolate across the grid (linear within each
half-cell where retail magnifies bilinearly -- OURS), and the composite is the blend itself
(premultiplied alpha), as retail's is. Under Compatibility GLES3's canvas reads the screen only in a
fragment stage (READ, Godot 4.2.2 canvas.glsl), so there (round 707) a full-screen rect evaluates the
same pipeline at each pixel's point of the 512 target: the 25 taps, each a bilinear sample of the
screen there (filtered in the shader from texelFetch), thresholded per tap, the rows clamped, the same
blend (OURS method: retail mixes two 512 texels' samples between texels and magnifies its target,
this samples the screen at the tap and evaluates every pixel). **And Compatibility needs a 3D anchor
(round 707):** a 3D pass reading the depth texture (WorldFog's) makes Godot 4.2.2 create the back
buffer with no colour texture, and every canvas screen read was black -- the whole frame (0, 0, 0),
from round 702 to 706 (MEASURED; READ, gles3 `copy_scene_to_backbuffer`). A 3D material that reads
the screen and covers no pixel makes the 3D pass create the colour texture (RetailBloom's header).
MEASURED (`tools/measure_retail_bloom.gd`, the CPU running retail's whole 512 pipeline on the same
frame, 4000 pixels x 3 channels; the scene now has a depth-reading 3D pass, as the world): Forward+
mean 0.24 / 0.30 of 255, p99 0.56 / 1.43, max 1.5 / 5.8 at 1280 x 720 / 3840 x 2160 (round 702);
Compatibility (round 707) mean 0.95 / 1.54 / 2.13, p99 6.6 / 9.5 / 13.2, max 13.7 / 15.5 / 24.5 at
1280 x 720 / 1920 x 1080 / 3840 x 2160, on smooth ramps mean 0.28 / 0.32 and p99 1.1 / 2.9 at 720 /
2160 -- the rest is fine detail, where per-pixel taps part from retail's sparse 512 samples (round
702's mip path: mean 1.6, p99 7.7, max 11.9 at 1280 x 720, and black in the game); a white bar's
added light falls off with no echo peak in either. `tools/retail_bloom_box_test.sh` checks
Compatibility on the box. **Overlays
come after it** (`OverlayView`): name plates, damage numbers, party marks and name boxes render in
their own transparent viewport over the bloom, as retail draws its 2D text over the finished frame;
the lens-flare sun sprite and the character-select characters are still bloomed (OURS,
docs/TODO.md).

## This client's default: Middle (the user's decision, 2026-10-02)

The user chose "Original's Middle": every record with no saved section -- a new install and a
settings file from before round 694 alike -- is retail's **Middle** (READ above): Circle
shadows, sight 3 / 3, Water Reflection **off**, Middle water, Metallic Sheen / Light Effect /
Filtering / Lens Flare / **Bloom on**, Middle textures, Dynamic Animation on, every effect;
Normal brightness; SSAO (OURS) off. Under Compatibility, Filtering and Texture Detail draw
nothing (greyed); the Bloom row draws RetailBloom in both renderers since the round 702 review. The window mode was not part
of the choice: it stays a window unless saved otherwise, and Default (the button) restores
Middle, Normal and the Free view without touching it (retail's Default also picks full screen).

A settings file from before round 694 that stores `[world] water_reflection` keeps that choice:
`false` is Middle as it is; `true` is User control with Middle's other rows and the reflection
on (as a hand-set row in the window would be). No key: Middle's value, off.

Round 694 first shipped "User control with the look before this round" as the default; the
user's decision replaced it.

## Storage (OURS)

`user://settings.cfg`: `[video]` profile (1 / 2), fullscreen, resolution ("WxH", "" = as
started); `[video_graphic1]` and `[video_graphic2]`: quality, brightness and every row by name
(the User values). `[world] water_reflection` (round 628) still wins over the Middle default for a record with no section of its own, and is kept in
step. QA: `OPENSRO_QA_VIDEO="quality=0,shadow_detail=2,..."` sets rows for one run, unsaved.

## Measured (round 694, the box)

- **MSAA and the mip bias under each renderer** (a synthetic scene: a rotated white box, a
  mipmapped 2-px checker plane; `msaa_3d` 2x, then `texture_mipmap_bias` 2): Compatibility
  (GL 4.6, RX 7600) -- edge pixels 12555 and checker contrast 0.2943 in all four states,
  pixel-identical; Forward+ (Vulkan, RADV) -- edge pixels 12455 -> 12727 with MSAA, contrast
  0.3557 -> 0.2573 with bias 2. So both rows are Forward+'s, like SSAO (glow was too until the round 702 review; the Bloom row is RetailBloom now, both renderers).
- **Each row at the Jangan spawn** (one boot, `OPENSRO_QA_VIDEO_STEPS`, 1280x720, offline,
  pixels differing by more than 2 % from the first default frame; same-settings frames differ
  by 128k-201k from animation alone): Shadow Nothing 743k, Circle 692k (the sun's shadow map
  gone), Very Dark mean grey 0.594 and Very bright 0.815 against 0.681, Background Sight 1
  473k; Texture Detail Low, Filtering On and Lens Flare Off within the same-settings spread
  (Lens: the sun was not in view). Frame time (another lane's Godot running throughout):
  default 14.2 ms, High 14.3 / 14.7, Middle 14.0, Large scale battle 14.0, Low 5.6 / 5.7,
  Background Sight 1 alone 6.1 -- the far plane is what costs.
- **SSAO under Forward+** (round 694 review; Jangan spawn, yaw 180, pitch -10, distance 40; pixels
  darkened by more than 8 luma, between later steps of one boot): Godot's defaults (radius 1,
  intensity 2, light affect 0) 9.9k against 11.4k between two frames with SSAO on -- nothing; light
  affect 1 and AO channel 1 alone, the same; radius 16, intensity 4, light affect 1 (shipped)
  19.5k against 11-12k, dluma -0.55, about +0.1 ms (1.99-2.01 -> 2.04-2.08 ms a frame). The terrain
  (unshaded) and the object mods (EMISSION) are not darkened by SSAO at all; a real effect needs
  those shaders to take light or an AO term.
