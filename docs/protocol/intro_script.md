# The title intro, the title screen and the front-end scenes

Recovered 2026-10-01 (round 678) from `sro_client.exe` on the render box (decompile
`/var/tmp/decomp_client`, asm `/var/tmp/sro_client.asm`, constants read out of the exe's own
sections) and measured on the real archives. Labels: **READ** (from the exe or a data file),
**MEASURED** (counted or run against the archives), **INFERRED** (reasoned, not observed),
**OURS** (this client's choice). The code is `client/scripts/frontend/`; the archive check is
`client/tools/check_intro_scripts.gd`. No retail script is in the repo: the tests use synthetic
snippets, and the real files are read at runtime from the player's own `Media.pk2`.

## Which intro

- **One per launch, from `Media.pk2 config\option.txt`** (READ): `IntroName = "script\intro\roc.txt"`
  is parsed by `CGame::FUN_008469c0` at 0x8475d3 into CGame+0x8b0; `IntroBGM = "maintheme_cut.ogg"`
  at 0x84762d. `//` lines are comments (the file comments out constantinople, china_wharf and egypt).
- Loaded once at startup: `Client_LoadAllRefData` 0x844cd0 -> `FUN_00840670` (0x84685b) -> the
  loader `UI_ALCHEMYBOX::FUN_0056cb10` on the intro object at the global 0xee7be8 (READ).
- With no file, the loader falls back to a hard-coded 14-key Constantinople path in region 0x694e
  (floats 0xd8acc8..0xd8ae1c, times 0..13); `CPSTitle::OnCreate`'s own default camera
  (0x86bd4c..: region 0x694e, target (1035.6, 126.8, 2134.7), pitch -0.334, yaw 5.894, roll 0.017,
  distance 10.0, the floats at 0xdd8d84..0xdd8d98 and 0xd81a88) is exactly constantinople.txt's
  last keyframe (READ; this client does not copy the hard-coded path -- with no script it keeps its
  2D still, OURS).
- **This client** (OURS): the operator's front-end theme decides (`FrontEndTheme`, below), else
  option.txt's IntroName, as retail.

### The archive's scripts (MEASURED, `check_intro_scripts.gd` on the box's vSRO Media.pk2)

| File | Keyframes | Length | Region (hi/lo) | Notes |
|---|---|---|---|---|
| roc.txt = egypt.txt = china_whatf.txt (byte-identical) | 21 | 40 s | 100/71 | the option.txt default; a ruined city, flies 4 regions south |
| constantinople.txt | 14 | 53 s | 105/78 | `AREA=EUROP_CONSTANTINOPLE` (crowd, OPEN) |
| china_wharf.txt | 8 | 35 s | 95/188 | z values carry a trailing `f` |
| rm.txt = rmzh.txt | 7 | 43 s | 101/189 | 8 [SCRIPT] lines: `S_SetWorldTime 22`, seven `roc_smoke.efp` (OPEN) |
| jupiter_login.txt | 7 | 27 s | 124/236 | |
| ruby_baghdad.txt | 6 | 33.5 s | 92/84 | 333 [SCRIPT] lines (crowds, riders, camera shake) -- OPEN |
| ruby_baghdad - kopie.txt | 6 | 33.5 s | 92/84 | 347 [SCRIPT] lines |

None shows Alexandria (an iSRO screenshot's obelisks and palms): `egypt.txt` is roc.txt in these
archives (MEASURED, same MD5), so that scene is not here to fly. Every path passes through every
one of its keyframes exactly (worst error 0.000000 units / rad, MEASURED) and clamps on its last.

## The file format (READ, `FUN_0056cb10`)

```
[CAMERA]
AREA=EUROP_CONSTANTINOPLE
<ignored> S_CameraInsert <t> <region lo> <region hi> <x> <y> <z> <pitch> <yaw> <roll> <distance>
...
[SCRIPT]
<t> S_<GScript command> <args...>
...
[END]
```

- UTF-16LE (every retail file starts `FF FE`), line by line, tokens split on tab and space (the
  tokenizer is set up with 0x09 and 0x20 at 0x56d45b..0x56d47f).
- The FIRST token of a line switches section by prefix: `[SCRIPT]` (`_wcsncmp`, 8 chars),
  `[CAMERA]` (8), `[END]` (5, back to none).
- In [CAMERA]: a first token starting `AREA=` (5) names a crowd area (`FUN_004779f0` /
  `FUN_0046ed50`; the title builds EUROP_CONSTANTINOPLE's crowd through `FUN_00520580` ->
  `FUN_0051dea0`, OPEN here). Otherwise the SECOND token must be exactly `S_CameraInsert`, and ten
  values follow: time (`_wtof`), the region word's low and high bytes (`thunk_FUN_00b43f75`, stored
  as bytes at keyframe +4 and +5), x, y, z, pitch, yaw, roll, distance (`_wtof`, keyframe +8..+0x20;
  the keyframe struct is `FUN_0056ad50`'s nine dwords). The first token of a keyframe line is never
  used. Any other [CAMERA] line (ruby_baghdad's `S_CameraShake`) is skipped.
- `_wtof` stops at the first non-number character: china_wharf's `484.136963f` reads 484.136963.
- In [SCRIPT]: each line's tokens go to the GScript interpreter (`FUN_004779a0`, `FUN_00477ca0`).
  This client keeps them as text and does not run them (OPEN: the GScript subset).
- Keyframes are appended in FILE order (`FUN_0056ca60`); each one's region goes to
  `FUN_0056c870`, which collects the regions to preload (below).
- Region word = hi << 8 | lo; lo is the X sector, hi the Z sector (the game's own
  "Region(rx=%d,rz=%d)" console line reads +0x7c and +0x7d, `FUN_00539c00`). This project writes it
  "hi/lo" (Jangan 97/168) and Map.pk2's path is `<hi>\<lo>.m`.
- **OURS:** an operator's own script may also be UTF-8 (with or without a BOM).
- **OURS (round 678's review):** sanity bounds, applied to every keyframe -- a value outside them, or
  not finite (`1e999` reads as inf), refuses the whole script and the title falls back: at most 1024
  keyframes, time 0..3600, |x|, |z| <= 61440 (32 regions), |y| <= 20000, |angles| <= 1000, distance
  0..100000. Retail checks none; its files sit far inside (MEASURED: <= 53 s, |x|,|z| <= 8320, y
  -434..2008, |angles| <= 14.9, distances 1..100, <= 21 keyframes). Without them a yaw of 1e17
  hung the title for good: retail's unwrap loop never changes a value that large.

### Preloading (READ, `FUN_0056c870`)

Per keyframe: its own region; then, independently (never the diagonal), the low byte shifted when
x >= 1920 or x <= 0 and the high byte when z >= 1920 or z <= 0, by `trunc(v / -1920.0)` (the double at
0xd8ac80, `fistp` under a truncating control word) and one more step down for v <= 0. roc's
keyframes are all "region 100/71" with x down to -1840 and z down to -7211, so retail preloads
100/71, 100/70, 99/71 .. 96/71 -- but the camera's target actually crosses 100/70 .. 96/70
(MEASURED), regions this set never names. This client streams a 3x3 window around the camera's
target instead (OURS, `World3D.title_begin`), which covers what the camera sees.

## The camera path (READ)

The title's path object (constructor 0x4e6c40; reset `FUN_004e6630`) holds five curves:

| Curve | At | Keys | Interpolator | Fix-up (+0xc) | Feeds camera |
|---|---|---|---|---|---|
| position | +0x4 | {x, y, z, t} | 0x4e0920 | none | +0x34c target |
| pitch | +0x38 | {v, t} | 0x4df7d0 | 0x4deee0 | +0x370 |
| yaw | +0x64 | {v, t} | 0x4df7d0 | 0x4deee0 | +0x374 |
| roll | +0x90 | {v, t} | 0x4df7d0 | 0x4deee0 | +0x378 |
| distance | +0xbc | {v, t} | 0x4df7d0 | none | +0x37c |

- **Adding** (`FUN_004e67b0`, called by `FUN_00869b50` per keyframe with its time, position and the
  four rotation values -- not its region): each key is inserted before the first key with
  `key.t - t > 0` (`FUN_004e6040`, `FUN_004e6170`), so keys sort by time and an equal time goes
  after. The path's length (+0xf0) is the LAST keyframe's time in file order (`FUN_00869b50`).
- **Sampling** at t (`FUN_004e55e0`, `FUN_004e5770`): the first key k with t <= key[k].t; k == 0
  gives key 0; none gives the last key; else segment i = k-1, u = (t - t_i) / (t_k - t_i), u = 0 for
  a span <= 1e-4 (the double at 0xe1b880).
- **Segment** i of n (`FUN_004e4530`, `FUN_004e4770`): p0 = key[i-1] (key 0 when i == 0), p1 =
  key[i], p2 = key[i+1], p3 = key[i+2] (key[i+1] when i == n-2).
- **The spline** (both interpolators, constants 2.0 0xe1b898, 5.0 0xd81950, 4.0 0xe1b860, 3.0
  0xe1b808, 0.5 0xe1b7d0): uniform Catmull-Rom,
  `0.5 * (2 p1 + (p2 - p0) u + (2 p0 - 5 p1 + 4 p2 - p3) u^2 + (-p0 + 3 p1 - 3 p2 + p3) u^3)`.
- **The angle fix-up** (0x4deee0), on copies of the four points: for each consecutive pair (a, b),
  d = b - a; if d > pi, `b -= 2 pi` while b > a; if d < -pi, `b += 2 pi` while b < a (pi 0xd81948,
  2 pi 0xd81930). Pitch, yaw and roll have it; distance does not. This client takes the same number
  of steps by arithmetic, `ceil(|d| / 2 pi)` (round 678's review: the loop never ends once
  `b - 2 pi == b`).
- **Playing** (`FUN_004e5bf0(dt)`): time += dt; past the length it wraps if +0xec is set, else it
  CLAMPS to the length. The title never sets +0xec (`FUN_004e6630` clears it), so the camera rests
  on the last keyframe. A non-zero region at +0xf4 would rebase the output into neighbouring regions
  (x or z >= 1920 -> +1, < 0 -> -1); the title never sets it, so positions stay relative to the
  camera's region.
- **The region** (`CPSTitle::OnCreate` 0x86bda0): `FUN_0056be40` hands back the LAST keyframe's
  region, position and rotation; `FUN_004fb510(region)` makes that region current (DAT_00eef68c)
  and gives it to SWorld (vslot_001), whose environment the sky then reads; the camera stands on the
  last keyframe until the path's first frame.
- **This client** (OURS): the backdrop's frame region is the last keyframe's, as retail's; while the
  world loads, the region window is pointed at where the path BEGINS (the last-keyframe pose would
  be covered by the loading still anyway).

## The camera (READ)

The camera is the struct at gfxmainframe+0x33c (`DAT_0110f7d0` points at gfxmainframe; ctor
`FUN_00bae0a0`): +0x10 target, +0x34 pitch, +0x38 yaw, +0x3c roll, +0x40 distance, +0x44 a flag
(1), +0x48 near 1.0, +0x4c far 500000, +0x50 fov 60.0. The in-game camera writes the same fields:
dragging changes pitch by the mouse's y and yaw by its x (`CGInterface::vslot_012` 0x77b140),
`FUN_0078dc50` puts the target at the player and the zoom in the distance -- so the four "rotation"
values are pitch, yaw, roll and the distance from the target to the eye. The dev console prints
them as `Region(rx,rz) Pos(x,y,z) Rot(pitch,yaw,roll,dist)` (`FUN_00539c00`) -- how the intro
lines were authored (INFERRED).

`CGFXVideo3d::FUN_00bae580` (flag set): `M = Rz(roll) * Rx(pitch) * Ry(yaw)` (D3DXMatrixMultiply at
0xbae6f0 and 0xbae70a; the d3dx RotationZ/X/Y generic bodies 0xaa449f, 0xaa434c, 0xaa4402, row
vectors), offset = (0, 0, distance) * M, up = (0, 1, 0) * M, **eye = target - offset**. So pitch > 0
looks down, yaw 0 looks along +z. `FUN_00bae810` builds the view with D3DXMatrixLookAt(eye, target,
up) and the projection with fovy = 60 * pi/180 (the vertical angle is INFERRED from the D3DX
argument order). The world's z -> -z mirror maps SRO +z to Godot -z (`IntroCameraPath.
camera_transform`, `World3D.title_world_from_local`).

## The title screen (READ)

`CPSTitle::OnCreate` (0x86b190), `CPSTitle::vslot_012` (each frame, 0x8691b0), layout
`resinfo\pstitle.txt`:

- **Time of day:** `rand() & 3` (0x86b278) picks 0.2083333, 0.5833333, 0.75 or 0.9583333 (the
  floats at 0xdd8ef4, 0xdd8ef0, 0xdd8eec, 0xdd8ee8 -- 5, 14, 18 and 23 o'clock over 24) for
  `SWorld::vslot_020` (0x9f6fb0), which stores SWorld+0x26a3: the day phase the environment graphs
  are read at (round 226's ENVIRONMENT_REFERENCE_TIME is that phase's in-game value, 0.5). Before it,
  `SWorld::vslot_043(0x17, 0)` (OPEN). The sun's direction from the phase (`SWorld::vslot_004`) is
  not applied here (OPEN).
- **Music:** IntroBGM pushed at level 0 (0x86be89; round 612).
- **The windows** (pstitle.txt's Title section, IDs): 1 `GDR_STA_SCREENUP` (blackbar_up_18.ddj),
  2 `GDR_STA_SCREENDOWN` (blackbar_down_copyright.ddj), 3/4 `GDR_STA_BSCREENUP/DOWN` (CIFFade, set to
  colour 0xff000000 alpha 255 at 0x86b763/0x86b78b), 5 `GDR_STA_TITLE` (text-connect.ddj), 7
  `GDR_STA_BIGLOGO` (logo-big.ddj), 8 `GDR_STA_LOGO` (logo.ddj), 9 `GDR_STA_LOGINWINDOW`, 11/12
  `GDR_BTN_OK/CANCEL` (button.ddj, texts UIO_CTL_CONNECT / UIO_CTL_EXIT). The Login section is loaded
  into window 9: ID/PW/Server labels (UIO_CTL_ID / UIO_CTL_PASSWORD / UIO_CTL_SELECT_SERVER, font
  index 2), the ID and password edits, the server static and its LIST button.
- **Scaling:** rects are in a 1600x1200 design space; `FUN_00849c70(window, 0)` scales windows 1, 2,
  3, 4, 5, 7, 8 and 13 by screen_w/1600 and screen_h/1200 (the floats at 0xed7cc8/0xed7ccc,
  0x842dd1..0x842de7) -- non-uniformly: on a wide screen the bands and logos stretch sideways, as
  retail's do. The login window and its buttons are not scaled.
- **Placement** (`FUN_00866760`): cx = width >> 1, mid = ((band 2 top - band 1 bottom) >> 1) + band
  1 bottom; the logo at (cx - w/2, mid + 6 - 0x78); window 9 at (cx - 0x90, mid + 6) with its art
  replaced by `interface\outer\login_window_europe.ddj`; Connect at (cx - 100, mid + 0x9c), Exit at
  (cx + 9, mid + 0x9c). The version: a window at (5, height - 0x19), 0x50 x 0x14, colour 0xffff8080,
  text `Ver %d.%03d` (0x86bc1d..0x86bc77).
- **The fly** (`FUN_00869b50`): windows 5, 8, 9, 11, 12 hidden; the big logo faded 0 -> 255 over 3.0 s
  starting 15.0 s in (`FUN_006526e0(0, 0xff, 3.0, -15.0)`, 0xd8adc4 / 0xdd81c8); the keyframes loaded.
- **Each frame:** the path advanced by the frame's time and copied to the camera while its length is
  non-zero; when its clock equals its length and the login is not up (+0xe4 == 0), `FUN_00865630`.
- **The login** (`FUN_00865630`): windows 3, 4 and 7 faded to 0 and 5 to 255 over 0.5 s (0xe1b7e0),
  then `CPSTitle::FUN_00864870` fades 8, 9, 11, 12 to 255 over 0.5 s (or the server window, by an
  account check); +0xe4 = 1. The camera keeps flying to its end.
- **The skip:** a left button press (`CPSTitle::vslot_017` 0x8658c0, message 0x201) or any key
  (`FUN_0086ae50`, its first test, for every key -- it then handles Tab and Enter) while +0xe4 == 0
  calls `FUN_00865630` early.
- **The fade** (CIFFade): `FUN_006526e0(from, to, duration, start)` -> `FUN_006552b0` stores them;
  each step (`FUN_006552f0`) alpha = from while elapsed <= 0, = to once elapsed >= duration, else
  `round(from (1 - u) + to u)`, u = elapsed / duration. That elapsed grows by the frame time is
  INFERRED.
- Which `#ifdef` branch pstitle's art takes: the undefined (`#else`) one, INFERRED from
  `FUN_00866760` replacing window 9's art by hand, which a build defining EUROPE_SYSTEM would not
  need.

## The operator's front-end theme (OURS)

One structure, the same on the wire, in the settings cache and in `custom/theme.json`:

```json
{"v":1,"intro":"","bgm":"","logo":"","copyright":"","band_top":"","band_bottom":"","charselect":null,"create":null}
```

- **Wire:** `OpFrontEndThemeRequest` 0x0005 (client -> server, no payload) and `OpFrontEndTheme`
  0x0006 (server -> client: u16 LE byte length + that much UTF-8 JSON). Answered before any login
  (`server/internal/session/frontendtheme.go`); the client asks at boot over its own short-lived TCP
  connection (`ThemeQuery`, 1.5 s deadline, a host name resolved without blocking, at most one frame
  read and it must be the answer), because retail picks its intro before any connection and this
  client connects only on Connect. The server answers once per connection and ends an
  unauthenticated asker's session after the answer (`gateway.ErrEndSession`); a repeat on a logged-in
  session gets nothing. Nothing is logged per request. The client caches the answer per server
  address.
- **Order, per field:** `SRREVAMP_LOGIN_*` preview variables > the server's fresh answer (else the
  answer cached from the last launch -- one layer, so a field the operator cleared stays cleared) >
  `custom/theme.json` > retail's defaults.
- **Names never leave their folders:** an intro is a bare name (`[A-Za-z0-9_-]{1,64}`, looked up as
  `custom/intro/<name>.txt` first, then `script\intro\<name>.txt`) or `script\intro\<name>.txt`;
  images are `<bare name>.png|.ddj` in `custom/frontend/`; music `<name>.ogg` in the
  archives. Anything else is refused and logged.
- **Fallbacks:** a custom script that does not parse (or breaks the bounds above) -> the archive's of
  that name -> option.txt's IntroName -> the 2D still; a logo or band image that is missing or
  unreadable -> the archive's art; music not in the archives -> IntroBGM (only `.ogg` names are
  accepted: those are the ones looked up in Music.pk2). Each with a log line. On the 2D still the
  archive's logo is not drawn (the still has its own); an operator's is.
- **No player switch.** Round 678's review added `[frontend] title_3d=false`; it was removed the same
  day at the user's request (the 3D title is not optional; a "clientless" mode comes later instead).
- `charselect` / `create` are reserved (null). Retail's select and create scenes are fixed (below),
  so making them choosable is OURS.

## The scenes after the title (READ; not built yet)

None is tied to the intro: all ten asm references to the intro object 0xee7be8 are in CPSTitle or
CGame helpers, and the select/create code uses hard-coded regions, cameras and placements.
`SWorld::vslot_020` (the day phase) is called by none of them, so the title's random hour carries over
(INFERRED).

- **Character select** (`CPSCharacterSelect`, OnCreate 0x85eb10, per frame 0x85ce30, layout
  `resinfo\pscharacterselect.txt`): region 0x6951 = **105/81**, the Constantinople harbour (its .o2
  holds `euro_constan_ship02/03`, `harbor\euro_esteuro_port01` and market dressing at y -27.6),
  SWorld vslot_001 then vslot_000 at local (920, 0, 920). Characters on a dock line from
  (95, -27.6, 654) yaw 3.20 to (29, -27.6, 644) yaw 3.35, four a page, slot k at k/5 of the way.
  Camera keys from hard-coded tables (static initialisers 0xd74a80, 0xd74b80): the list view dollies
  the target (60, -15, 700) -> (60, -15, 660) over 2 s at pitch 0.1, yaw 3.0, distance 30; Start zooms
  to the slot (distance 8, yaw 0.3925 - slot yaw).
- **Race select is the same process** on the same region: `res\interface\box.bsr` (box, compass,
  brush case, letter, parchment map) at (155, -20, 652) yaw 3.0, `interface_idol_europe.bsr`
  (157, -20, 654.4) yaw 3.31, `interface_idol_china.bsr` (156.2, -20, 651.6) yaw 3.03,
  `interface_lizard.bsr` (155.6, -20, 651.6) yaw 3.0; the camera flies four keys over 5 s to
  (165.2, -33.9, 640.3) pitch 0.62 yaw 2.53 and, on an idol, to Europe (168.5, -34.9, 639.1) or China
  (165.8, -35.1, 636.7). The Europe idol opens `CPSCharacterCreateEurope`, the China idol
  `CPSCharacterCreateChina`: China vs Europe is the player's pick per character. (`ifregionview.txt`
  is the in-game region-name banner, not this screen; `pscharacterselect_europe.txt` and
  `pstitle_europe.txt` are never named by the exe.)
- **Create, China** (OnCreate 0x84fbc0, layout `pscharactercreatechina.txt`): region 0x62a8 =
  **98/168**, the Jangan palace forecourt; the world camera's target (960.42, 50, 458.26), pitch 0,
  roll 0, distance 0.1, yaw = clock/30000 + 0.391 each frame (a slow turn on the spot; the clock
  being milliseconds is INFERRED). Sliders top to bottom: Figure, Height, Volume, **Protector,
  Weapon**.
- **Create, Europe** (OnCreate 0x853990, layout `pscharactercreate_europe.txt`): region 0x694f =
  **105/79**, Constantinople city; target (335, 140, 1460), the same turn. Sliders: Figure, Height,
  Volume, **Weapon, Protector**.
- Both draw the character in `CIFCharacterWnd` with its own camera (target (0.5, 9.8, 0), pitch 0.2,
  distance 28.5; zoom to 11 over 1 s).
- OPEN: the reference screenshots' drifting calligraphy behind the China character (no .efp is
  loaded by either create screen; China's `GDR_STA_BACKIMAGE` uses `back_image.ddj`, unverified) and
  the "horse" on the race-select table (no horse mesh among `Res\interface`).
