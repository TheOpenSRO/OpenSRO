# The Option window's Video tab

Round 694. What `sro_client.exe` offers on the Video tab of its Option window, what each
setting does in that client, and what each does in srrevamp. Code: `client/scripts/setting/
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

## The record (READ)

`CGame+0x570` (`FUN_00835240`): a selector byte, then two records of 0x2c bytes -- one per
Graphic tab. In record r (base `+r*0x2c`): bytes 4+i are entry i in force, bytes 0x14+i the
player's own ("User") copy, 0x24 the Graphic Quality, 0x25 the brightness, 0x28 / 0x2c the
resolution. `Setting\SROptionSet.dat` (loader `0x502680`): u32 13, then tags -- tag i (1..15)
two bytes (in force, user) for entry i-1, 501 quality, 502 brightness, 503 / 504 width /
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
shipped client draws Middle -- with Water Reflection **off**: round 628 read tag 5 = 1 and missed
the re-application.

## What each does in the original (READ) and here

`CGame::FUN_00835000` copies the record in and passes each byte to `SWorld::vslot_043(case,
value)` (`0xa194a0`), which also stores it at `SWorld+0x2e50 + case*4` (getter `vslot_044`).

| Setting | Original (READ unless marked) | srrevamp |
|---|---|---|
| Resolution | the device mode | the window's size (OURS list of usual sizes up to the screen); unavailable in full screen, where Godot keeps the desktop's size |
| Window Mode | device full screen / window (`opt+9`, `0x5fdae0`) | `Window.mode` full screen / windowed, live |
| View | camera mode 0/1/2 (`UI_CHANGED::FUN_00780420`) | `World3D.set_camera_view` (round 639's three views), saved as [ui] camera_view |
| Set Brightness | case 0: gamma ramp `65535 * pow(i/255 * B, A)`, (A, B) = (1.4, 0.8) (1.2, 0.9) (1, 1) (0.8, 1.2) (0.6, 1.4); full screen only | the same curve as a full-screen canvas pass over the finished frame (OURS: in a window too); none at Normal |
| Graphic Quality | the presets above | the same presets; any hand-set row switches to User (INFERRED) |
| Shadow Detail | case 2: Detail builds a 96 x 96 target and 32 x 32 shadow textures per character; Circle (TTDESC_04 "circles") | Nothing: no blob, no sun shadow map; Circle: the blob (`SkyBox\shadowsphere.ddj`); Detail: blob and the DirectionalLight3D's shadow (OURS) |
| Background Sight Range | case 8: far plane 1500/2500/3500/4500/5500; view distance `min(0.8 far, 2500)` = 1200/2000/2500/2500/2500 scales the fog planes and is the map-object range + 480; world+0x23db = 800..2048 (reader not found) | map-object animation range = view - 480 (READ rule); fog density x 2500/view and camera far x min(1, far/3500) (OURS); 3 = as before |
| Character Sight Range | case 9: stored only; no reader found (asm `+0x2e74` has one writer; 17 getter calls carry other cases; no record-offset reader) | OURS: other characters' meshes drawn to 600 / 1200 from the camera at 1 / 2; unlimited at 3..5 (as before) |
| Water Reflection | case 6: builds / frees the reflection target and two 512 x 512 textures | round 628's pass; from the next login (a region's water is built for one mode) |
| Water Detail | case 7: stored only; no reader found | OURS: the reflection target's rows 256 / 512 (READ size) / 1024, live |
| Metallic Sheen | case 0xc -> object renderer +0x194; forced off below shader model 3 (`CGame::FUN_00834fb0`) | kept, draws nothing: no environment-map sheen here |
| Light Effect | case 0xb -> object renderer +0x1a4 (Sun / Torch, TTDESC_10) | kept, draws nothing: no torch or sun light effect here |
| Texture Filtering | byte 0xc; no reader found; TTDESC_15 "compensates rough outlines" | INFERRED anti-aliasing: MSAA 2x on the 3D view (OURS level) |
| Texture Detail | case 5: `IDirect3DBaseTexture9::SetLOD(2 - v)` on every texture (vtable +0x2c) | `Viewport.texture_mipmap_bias` 2 / 1 / 0 (INFERRED equivalent look, not the memory saving) |
| Lens Flare | case 0xd: `SWorld::vslot_005` draws `Map::FUN_00a21280` while +0x2e84 is set | the sun glow sprite (`SkyBox\glow.ddj`, INFERRED to be the flare's piece) |
| Bloom Effect | case 1: screen-size and 512 x 512 render targets (a glow pass; look not read) | Godot glow (Forward+ only); the user's "glow" toggle is this row |
| Dynamic Animation | case 0xe -> renderer +0x19c, re-inits the animated objects; TTDESC_14 fabrics and hair | kept, draws nothing: no cloth or hair motion here |
| Effect Quality | `IDecoSkill::FUN_00a50dc0(q, owner)`: 0 none, 2 all, 1 only owners passing two unread tests | `SkillEffects.quality`: 1 shows effects the player casts, takes or carries (INFERRED) |
| Display Friendly/Enemy | 0 lets `GlobalDataManager::FUN_009dae90/9db750` swap a large-battle outfit tint; 1 (General) never | kept, draws nothing: no battle outfits here |
| SSAO | (none in the exe) | OURS: Godot SSAO, Forward+ only, default off |
| Renderer | (none) | OURS: Forward+ / Compatibility at the next start, through round 693's RendererChoice when the build has it |

## This client's defaults (OURS)

Graphic 1, **User control** with the values that draw what the client drew before round 694:
Detail shadows, sight 3 / 3, reflection on, water Middle, texture High, filtering off, lens
on, bloom off, effects all on, SSAO off; Normal brightness; a window. Retail's default is
Middle (above); one choice in the Graphic Quality row. Default (the button) restores these.

## Storage (OURS)

`user://settings.cfg`: `[video]` profile (1 / 2), fullscreen, resolution ("WxH", "" = as
started); `[video_graphic1]` and `[video_graphic2]`: quality, brightness and every row by name
(the User values). `[world] water_reflection` (round 628) seeds Water Reflection and is kept in
step. QA: `SRREVAMP_QA_VIDEO="quality=0,shadow_detail=2,..."` sets rows for one run, unsaved.
