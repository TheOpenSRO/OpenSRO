# Night lights: what the original turns on at night (round 806)

Labels: **READ** (sro_client.exe: the box's decompile `/var/tmp/decomp_client` and
`/var/tmp/sro_client.asm`; Data.pk2's `Shader\vss0.c` / `vss2.c`), **MEASURED** (the archives on the
render box, `client/tools/night_census.gd`), **OURS**, **OPEN**.

The client keeps one **night flag**: the effect manager's `+0x1a8` (the object at `0x1112fb0`;
getter `0xbc0fd0`, setter `0xbc0fe0`). Two things read it: **night-only particle effects** (a `.bsr`
particle entry whose byte `+0x51` has bit 0) are drawn only while it is set, and **night-lit
layers** (a `.bmt` layer whose flag word has bit `0x8`) are drawn by their own texture colour,
unlit, while it is set. Nothing else in the renderer reads it (READ: the getter's twelve call
sites, all below). The sound manager gets its own copy of the same test (game_clock.md).

## When: the exact times (READ)

`SWorld::vslot_004` (0xa2cf60) runs every world frame. With no test before it -- no dungeon, zone
or option check (READ, the decompile's lines 42-137) -- it takes the day phase `+0x26a3` (set every
frame from the game clock by `FUN_0084ac90`, game_clock.md), and:

```
0xa2d17c  fld 0.25 (float 0xd9a2b8); fcomp phase      shifted = phase < 0.25 ? phase + 0.75 (double 0xda34b0)
0xa2d195  ...                                                            : phase - 0.25 (double 0xd83070)
0xa2d1a3  fstp [+0x26a7]                              stored as a float
0xa2d1ae  fld 0.5 (float 0xe1b7e0); fcomp shifted     night = 0.5 < shifted
0xa2d1c6  call 0xbbdbf0 -> jmp 0xbc0fe0               [0x1112fb0 + 0x1a8] = night
```

So the flag is set for a phase **below 0.25 or above 0.75**; at 0.25 and 0.75 exactly it is day.
Through the clock's map (game_clock.md: clock 04:00-20:00 inclusive is the sky's 06:00-18:00)
and its float arithmetic, evaluated for every second of a clock day (MEASURED,
`game_clock_test.gd`):

| Game clock | Night flag | Sky phase |
|---|---|---|
| 00:00:00 - 03:59:59 | **on** | 0.0 - 0.24998 |
| **04:00:00** - 20:00:00 | off | 0.25 - 0.75 |
| **20:00:01** - 23:59:59 | **on** | 0.75002 - 0.99998 |

It agrees with the sound's night (clock hour < 4 or > 20) at every second. In real time (READ: one
game second is 20 ms, a game day 28 min 48 s; the server's clock starts at day 0, 00:00 when the
server starts unless `-world-clock-start` says otherwise): within each 28 min 48 s cycle from the
start, **night from 0:00 to 4:48.000, day from 4:48.000 to 24:00.020, night again from 24:00.020 to
28:48** -- 19 min 12.02 s of day and 9 min 35.98 s of night. A GM's `/hour` (0x3027) moves the
clock and the flag with it.

The front end has no clock: `CPSTitle::OnCreate` picks one of four fixed phases (title_intro.gd):
0.2083 (5 o'clock) and 0.9583 (23 o'clock) are night, 0.5833 and 0.75 (exactly) are day. In a
dungeon the flag follows the clock as in the field (no dungeon test).

## What it does to particle effects (READ)

`CRTModParticle::FUN_00c81450`, a particle mod's per-frame update and draw:

```
0xc81493  test byte [esi+0x91], 1        the entry's byte +0x51 (the mod's copy at +0x91)
0xc8149a  je 0xc814b9                     not night-only: on as always
0xc814a1  call 0xbc0fd0                   the night flag
0xc814a8  je 0xc814fc                     day: return -- nothing placed, stepped or drawn
0xc814aa  cmp [esi+0x54], 0 / call 0xc81350(1)   night and no effect yet: create it now
0xc814bf  call 0xc81190; call 0xc80ff0    place it; step it (by the frame's own time, 0xbc1100)
```

- By day a night-only effect is **not drawn and not stepped**. It is not destroyed: the step hands
  the effect the frame's own time (`0xbc1100`, the manager's frame delta), so the next night it
  **goes on from where it stood**, not caught up.
- It is **created on the first night frame** its object is updated, so it starts empty and fills.
- The glow pass (`FUN_00c43100`) skips it by day too (0xc431f7, 0xc43586), so its glow alpha
  starts again from 0 and fades in (AmbientParticles.step_alpha).

MEASURED: every one of the 385 night-only entries is in an `ambient` set (the set an object plays
with no clip, AmbientParticles): no item, character, quest mark or action set carries one.

## What it does to a layer with flag word bit 0x8 (READ)

Every draw path of `CObjRendererVS` -- `FUN_00bf0e20` (0xbf0fa0), `FUN_00bf1250` (light-mapped,
0xbf144b), `FUN_00bf1840` (0xbf1a2b), `FUN_00bf29a0` (skinned, 0xbf2c03) and `FUN_00bf3e00`
(0xbf40ad) -- does:

```
0xbf0f98  mov ebx, [esi+0x14]              the renderer's light mode (0: the world's light)
0xbf0fa0  call 0xbc0fd0 / test [flags], 8  night and the layer's flag word has 0x8:
0xbf0fb0  mov ebx, 2                       light mode 2
0xbf0fbb  call 0xbf05e0(0, ebx, uv)        pick the vertex shader
```

- `FUN_00bf05e0` keys the shader on (skin, light, uv, fog), and **light mode 2 forces fog index
  4**. The define lists are built at 0xbf6b79..0xbf6e2d: light `DIRECT` (0), `PLIGHT` (1),
  `NOLIGHT` (2) (strings 0xe0bc20, 0xe0bc18, 0xe0bc10); fog `LINEAR`, `LINEAR+HEIGHT`, `EXP`,
  `EXP+HEIGHT`, `NO` (0xe0bbcc, 0xe0bbbc, 0xe0bbb8, 0xe0bbac, 0xe0bba8). In `vss0.c` / `vss2.c`,
  `VS_LIGHT_SKIN0_NOLIGHT` is `mov oD0, c[VSC_UTIL].x` -- **oD0 = 1.0** -- and `VS_FOG_SKIN0_NO`
  `mov oFog, 1.0`.
- `FUN_00c42a60` (the flag word's states, 0xc42aef) then sets, for night and 0x8, D3DRS_LIGHTING
  FALSE and **stage 0 COLOROP 4 (MODULATE)**, after `0x1000`'s MODULATE2X; `FUN_00c42b40`
  (0xc42b9f) restores LIGHTING TRUE and COLOROP 5. `0xc6c740` is the same pair for another
  renderer (it also sets ALPHAFUNC 7; reached through two thunks at 0xd4e5f4 / 0xd4e6c4, its
  class not named).
- So at night such a layer is **its texture at its own colour**: `saturate(texture x 1)` instead
  of `saturate(2 x texture x oD0)`. A light-mapped one (stage 0 already MODULATE) is
  `saturate(2 x saturate(texture) x lightmap)`. Its vertex colour, the world's light and the
  zone's environment keys no longer reach it.
- **Fog: unchanged in the field.** The landscape step (`Map::FUN_00a26f60`, 0xa276bc..0xa27735)
  sets, when the current region id (world `+0x237e`) has bit 15 clear -- every field region --
  D3DRS_FOGVERTEXMODE (0x8c) NONE and D3DRS_FOGTABLEMODE (0x23) LINEAR: per-pixel table fog,
  which ignores the vertex shader's oFog. So a night-lit layer is fogged as any object in the
  field. In a dungeon (bit 15 set) the order is reversed -- vertex fog LINEAR, table fog NONE --
  and the shader's `NO` leaves night-lit layers unfogged; OpenSRO draws no dungeon fog (WorldFog),
  so there is nothing to exempt.
- The bit is tested on the flag word after the object's mods have edited it (`FUN_00c451e0`); an
  MTRL mod only ORs `0x10000000` in, so the light mode holds with one.

## Census (MEASURED, round 806)

`client/tools/night_census.gd` over all 8,539 `.bsr` of Data.pk2, every `.dof`, and the map's
75,564 placements (`server/cmd/mapobjcensus -ownerframe -dumpplaces`; a `.cpd` compound counts for
its pieces); region names from Media.pk2's `refregion.txt` (AreaName, else ContinentName).

- **304 models** carry something night-only: **385 night-only particle entries** and **359
  night-lit meshes** (a mesh whose material layer has 0x8).
- **185 of them are placed in the field, 1,557 times**: 72 models (609 placements) with night-only
  effects, 134 (1,008) with night-lit layers, 21 with both.
- The effects (all `map\`): `cj_pal_lamp_light` (162 entries), `frame2` (78, a flame),
  `frame` (32), the `cj_pal_lamp_orange*` / `_red*` / `_blue` lantern glows, `light` (19),
  `alex_paros_01` / `_02` / `_02_glow` (Alexandria's lighthouse beam and its fires),
  `w_cd_potal_blue_g` (two blue glows on Hotan's `oas_hot_accessory`), `frame4`.
- The layer flag words seen: 0x148, 0x149, 0x348, 0x349 (MEASURED). One lamp layer of the 359 has
  an MTRL mod (`thief_vill_bigtent_winlight_02`) that neither blends nor tests, so it is drawn by
  the object shader like the rest.

By area (placements; a region with no refregion name is counted by its continent):

| Area | Night placements |
|---|---|
| Constantinople | 380 |
| Baghdad | 348 |
| ARABIA_DUNGEON | 265 |
| Jangan | 121 |
| Alexandria | 107 |
| Jangan fortress | 79 |
| West China field | 63 |
| GOD_TOGUI | 26 |
| Arabia field | 26 |
| China field | 25 |
| no refregion row | 17 |
| Europe field | 13 |
| GOD_WRECK_IN | 13 |
| GOD_WRECK_OUT | 13 |
| Hotan | 12 |
| Thief Village | 9 |
| Dunhuang | 7 |
| Hotan fortress | 7 |
| Oasis Kingdom field | 6 |
| JUPITER | 5 |
| Pharaoh tomb (novice) | 4 |
| Pharaoh tomb (master) | 4 |
| Pharaoh tomb (expert) | 4 |
| ARABIA_PETRA | 2 |
| Samarkand | 1 |

Every placed model (placements, then by area):

| Model (`res\...`) | Placed | What turns on at night | Where |
|---|---|---|---|
| `bldg\europe\constantinople\euro_constan_streetlight04.bsr` | 189 | effects: `cj_pal_lamp_orange.efp` | Constantinople 189 |
| `bldg\china\dunhuang\ravine\w_cd_ravi_house_01.bsr` | 85 | lit layers: `W_CD_ravi_house_winlight` | West China field 58, GOD_TOGUI 26, Dunhuang 1 |
| `bldg\europe\constantinople\euro_constan_streetlight02_01.bsr` | 60 | effects: `cj_pal_lamp_light.efp` | Constantinople 59, Europe field 1 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_01.bsr` | 46 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha` | Baghdad 23, ARABIA_DUNGEON 23 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_06.bsr` | 44 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha` | Baghdad 22, ARABIA_DUNGEON 22 |
| `artifact\china\jangan\cj_lamp01.bsr` | 40 | effects: `cj_pal_lamp_orange_s.efp` | China field 20, Jangan 20 |
| `bldg\europe\constantinople\euro_constan_streetlight01.bsr` | 37 | effects: `cj_pal_lamp_light.efp` | Constantinople 35, Europe field 2 |
| `etc\halloween\halloween_streetlight01.bsr` | 36 | lit layers: `halloween_display01_01`, `halloween_lamp` | Baghdad 36 |
| `artifact\china\jangan\cj_pal_lamp.bsr` | 35 | effects: `cj_pal_lamp_orange.efp` | Jangan 35 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_08.bsr` | 32 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 16, ARABIA_DUNGEON 16 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_03.bsr` | 30 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 15, ARABIA_DUNGEON 15 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_03.bsr` | 30 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha` | Baghdad 15, ARABIA_DUNGEON 15 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_07.bsr` | 30 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha` | Baghdad 15, ARABIA_DUNGEON 15 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_02.bsr` | 26 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 13, ARABIA_DUNGEON 13 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_04.bsr` | 26 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha` | Baghdad 13, ARABIA_DUNGEON 13 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_05.bsr` | 24 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha`, `bagh_mingal05_win05_alpha` | Baghdad 12, ARABIA_DUNGEON 12 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_01.bsr` | 22 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 11, ARABIA_DUNGEON 11 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_02.bsr` | 22 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha` | Baghdad 11, ARABIA_DUNGEON 11 |
| `bldg\north africa\alexandria\alex_minga08.bsr` | 22 | lit layers: `alex_minga01_window_alpha` | Alexandria 22 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_07.bsr` | 20 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 10, ARABIA_DUNGEON 10 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_09.bsr` | 20 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 10, ARABIA_DUNGEON 10 |
| `etc\halloween\halloween_pu04.bsr` | 20 | lit layers: `Halloween_PU_03` | Baghdad 19, Jangan 1 |
| `etc\halloween\halloween_pu03.bsr` | 19 | lit layers: `Halloween_PU_03`, `Halloween_PU_04` | Baghdad 17, Jangan 2 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_04.bsr` | 18 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 9, ARABIA_DUNGEON 9 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_10.bsr` | 18 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 9, ARABIA_DUNGEON 9 |
| `bldg\north africa\alexandria\alex_minga04.bsr` | 17 | lit layers: `alex_minga01_window_alpha` | Alexandria 17 |
| `bldg\arabia\bagh_city\etc\bagh_build_deco02.bsr` | 16 | effects: `cj_pal_lamp_orange.efp` | Baghdad 8, ARABIA_DUNGEON 8 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_06.bsr` | 16 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 8, ARABIA_DUNGEON 8 |
| `bldg\north africa\alexandria\alex_minga02.bsr` | 16 | lit layers: `alex_minga02_window_alpha` | Alexandria 16 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_05.bsr` | 14 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 7, ARABIA_DUNGEON 7 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_11.bsr` | 14 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 7, ARABIA_DUNGEON 7 |
| `bldg\arabia\bagh_mong\bagh_mong_tent_cargo01.bsr` | 13 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `Bagh_Mong_Tent_tentlight_alpha` | Arabia field 13 |
| `bldg\europe\constantinople\minga\euro_constan_house03_h01.bsr` | 13 | lit layers: `euro_est euro_constan_house03_winlight` | Constantinople 10, no refregion row 3 |
| `artifact\china\jangan\cj_field_lamp.bsr` | 12 | effects: `cj_pal_lamp_orange.efp` | Jangan 10, Jangan fortress 2 |
| `bldg\arabia\bagh_city\minga\bagh_minga_h_12.bsr` | 12 | lit layers: `Bagh_mingaH01_win01`, `Bagh_mingaH01_win02_alpha` | Baghdad 6, ARABIA_DUNGEON 6 |
| `bldg\china\jangan02\cj_adult04_light01.bsr` | 12 | effects: `cj_pal_lamp_red_b.efp` | Jangan fortress 8, Jangan 4 |
| `bldg\china\jangan02\cj_pub01_light01.bsr` | 12 | effects: `cj_pal_lamp_red.efp` | Jangan fortress 8, Jangan 4 |
| `bldg\europe\constantinople\minga\euro_constan_house02_h02.bsr` | 12 | lit layers: `euro_est euro_est euro_constan_house03_winlight` | Constantinople 10, no refregion row 2 |
| `bldg\europe\constantinople\minga\euro_est euro_constan_house02_h02.bsr` | 12 | lit layers: `euro_est euro_constan_house02_h02_winlight` | Constantinople 12 |
| `bldg\north africa\alexandria\alex_minga01.bsr` | 12 | lit layers: `alex_minga01_window_alpha` | Alexandria 12 |
| `bldg\arabia\bagh_mong\bagh_mong_tent_btent.bsr` | 11 | lit layers: `Bagh_Mong_Tent_tentlight_alpha` | Arabia field 11 |
| `bldg\europe\constantinople\minga\euro_est euro_constan_house01_h01.bsr` | 11 | lit layers: `euro_est euro_constan_house01_h01_winlight` | Constantinople 11 |
| `bldg\europe\constantinople\euro_constan_streetlight03.bsr` | 10 | effects: `cj_pal_lamp_orange_s.efp` | Constantinople 10 |
| `bldg\china\jangan02\cj_pub01_light02.bsr` | 9 | effects: `cj_pal_lamp_red.efp` | Jangan fortress 6, Jangan 3 |
| `bldg\north africa\alexandria\alex_minga03.bsr` | 9 | lit layers: `alex_minga01_window_alpha` | Alexandria 9 |
| `bldg\north africa\alexandria\alex_minga05.bsr` | 9 | lit layers: `alex_minga01_window_alpha` | Alexandria 9 |
| `bldg\arabia\bagh_city\etc\bagh_build_deco04_01.bsr` | 8 | effects: `cj_pal_lamp_orange.efp` | Baghdad 4, ARABIA_DUNGEON 4 |
| `bldg\arabia\bagh_city\etc\bagh_build_deco05.bsr` | 8 | effects: `cj_pal_lamp_orange.efp`; lit layers: `Bagh_build_deco5_win02_alpha` | Baghdad 4, ARABIA_DUNGEON 4 |
| `bldg\china\minga\cj_private07.bsr` | 8 | lit layers: `CJ_minga070_winlight` | Jangan fortress 8 |
| `bldg\europe\constantinople\minga\euro_constan_house01_h01.bsr` | 8 | lit layers: `euro_est euro_est euro_constan_house03_winlight` | Constantinople 6, no refregion row 2 |
| `bldg\europe\constantinople\minga\euro_constan_house03_h02.bsr` | 8 | lit layers: `euro_est euro_constan_house03_winlight` | Constantinople 8 |
| `bldg\china\jangan01\cj_streetstall.bsr` | 7 | effects: `light.efp` | Jangan fortress 4, Jangan 3 |
| `bldg\north africa\alexandria\alex_minga06.bsr` | 7 | lit layers: `alex_minga01_window_alpha` | Alexandria 7 |
| `bldg\arabia\bagh_city\system\bagh_storage.bsr` | 6 | effects: `cj_pal_lamp_orange.efp` | Baghdad 3, ARABIA_DUNGEON 3 |
| `bldg\china\jangan01\cj_luxu_light.bsr` | 6 | effects: `cj_pal_lamp_red_b.efp` | Jangan fortress 4, Jangan 2 |
| `bldg\china\jangan02\cj_adult02.bsr` | 6 | lit layers: `CJ_adult02_light` | Jangan fortress 4, Jangan 2 |
| `bldg\china\jangan02\cj_adult03.bsr` | 6 | lit layers: `CJ_adult03_light` | Jangan fortress 4, Jangan 2 |
| `bldg\china\jangan02\cj_adultenter.bsr` | 6 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `cj_adultenter_column_light`, `cj_adultenter_toy_light` | Jangan fortress 4, Jangan 2 |
| `bldg\china\jangan02\cj_pub01_light03.bsr` | 6 | effects: `cj_pal_lamp_red.efp` | Jangan fortress 4, Jangan 2 |
| `bldg\china\jangan02\cj_pub03_light.bsr` | 6 | effects: `cj_pal_lamp_red.efp` | Jangan 6 |
| `bldg\china\minga\cj_private05.bsr` | 6 | lit layers: `CJ_private050_winlight` | Jangan fortress 6 |
| `bldg\common\thief-vill\thief_vill_mtent_01.bsr` | 6 | lit layers: `thief_vill_bigtent_winlight_01`, `thief_vill_mtent_winlight_01` | Thief Village 6 |
| `etc\halloween\halloween_wagon.bsr` | 6 | lit layers: `Halloween_PU_02`, `Halloween_PU_03`, `Halloween_PU_04`, `Halloween_PU_05` | Baghdad 6 |
| `bldg\china\jangan01\cj_resta01_light_n.bsr` | 5 | effects: `light.efp` | Jangan fortress 4, Jangan 1 |
| `bldg\china\jangan02\cj_pub01.bsr` | 5 | lit layers: `Cj_pub01_win_light` | Jangan fortress 4, Jangan 1 |
| `bldg\china\minga\cj_private06.bsr` | 5 | lit layers: `CJ_private06_winlight` | Jangan fortress 5 |
| `bldg\europe\constantinople\minga\euro_est euro_constan_house01_h02.bsr` | 5 | lit layers: `euro_est euro_constan_house01_h02_winlight` | Constantinople 5 |
| `bldg\north africa\alexandria\alex_warehouse.bsr` | 5 | lit layers: `alex_warehouse_window_alpha` | Alexandria 5 |
| `bldg\oasis\tarim\blackrobber\oas_tarim_rob_smallfire01.bsr` | 5 | effects: `frame2.efp` | West China field 5 |
| `etc\obt\obt_event_dunhuangdoor.bsr` | 5 | lit layers: `Sum_event_01` | Baghdad 5 |
| `bldg\arabia\bagh_city\etc\bagh_build_deco04.bsr` | 4 | effects: `cj_pal_lamp_orange.efp` | Baghdad 2, ARABIA_DUNGEON 2 |
| `bldg\arabia\bagh_city\system\bagh_defense.bsr` | 4 | effects: `cj_pal_lamp_light.efp` | Baghdad 2, ARABIA_DUNGEON 2 |
| `bldg\arabia\bagh_city\system\bagh_potion.bsr` | 4 | effects: `cj_pal_lamp_orange02_b.efp`, `cj_pal_lamp_orange_s.efp`; lit layers: `bagh_potion_light01_alpha` | Baghdad 2, ARABIA_DUNGEON 2 |
| `bldg\arabia\bagh_city\system\bagh_variety.bsr` | 4 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `bagh_variety_light_alpha` | Baghdad 2, ARABIA_DUNGEON 2 |
| `bldg\arabia\bagh_city\system\bagh_weapon.bsr` | 4 | effects: `cj_pal_lamp_orange.efp`; lit layers: `bagh_city_weapon_light_alpha` | Baghdad 2, ARABIA_DUNGEON 2 |
| `bldg\china\jangan01\cj_jang_gaobj01.bsr` | 4 | effects: `cj_pal_lamp_red.efp` | Jangan 4 |
| `bldg\europe\constantinople\minga\euro_constan_house01_h02.bsr` | 4 | lit layers: `euro_est euro_est euro_constan_house03_winlight` | Constantinople 4 |
| `bldg\europe\constantinople\minga\euro_constan_house02_h01.bsr` | 4 | lit layers: `euro_est euro_est euro_constan_house03_winlight` | Constantinople 4 |
| `bldg\europe\constantinople\minga\euro_est euro_constan_house03_h01.bsr` | 4 | lit layers: `euro_est euro_constan_house03_h01_winlight` | Constantinople 4 |
| `bldg\europe\east eurpoe\goldfld\euro_est euro_goldh09_01.bsr` | 4 | lit layers: `Euro_Est Euro_Goldh09_03_winlight` | Europe field 4 |
| `bldg\guild\hotang\bridge\fortress_hotan_brid03_02.bsr` | 4 | effects: `cj_pal_lamp_light.efp` | no refregion row 2, Hotan fortress 2 |
| `bldg\china\jangan01\cj_resta01.bsr` | 3 | effects: `cj_pal_lamp_light.efp` | Jangan fortress 2, Jangan 1 |
| `bldg\china\jangan02\cj_adult04.bsr` | 3 | lit layers: `CJ_adult04_light` | Jangan fortress 2, Jangan 1 |
| `bldg\europe\east eurpoe\goldfld\euro_esteuro_goldh01.bsr` | 3 | lit layers: `Euro_EstEuro_Goldh01_05_winlight` | Europe field 3 |
| `bldg\oasis\hotang\castle\oas_hot_b1_bridge.bsr` | 3 | effects: `cj_pal_lamp_light.efp` | Oasis Kingdom field 2, Hotan 1 |
| `bldg\oasis\hotang\small_ferry\oas_hot_simplst_01.bsr` | 3 | effects: `cj_pal_lamp_light.efp` | Oasis Kingdom field 3 |
| `dun\asiam\r2_cv\st_anubis.bsr` | 3 | effects: `frame2.efp` | Pharaoh tomb (novice) 1, Pharaoh tomb (master) 1, Pharaoh tomb (expert) 1 |
| `dun\asiam\r2_cv\st_center.bsr` | 3 | effects: `frame2.efp` | Pharaoh tomb (novice) 1, Pharaoh tomb (master) 1, Pharaoh tomb (expert) 1 |
| `dun\asiam\r2_cv\st_combat.bsr` | 3 | effects: `frame2.efp` | Pharaoh tomb (novice) 1, Pharaoh tomb (master) 1, Pharaoh tomb (expert) 1 |
| `dun\asiam\r2_cv\st_up_battle.bsr` | 3 | effects: `frame2.efp` | Pharaoh tomb (novice) 1, Pharaoh tomb (master) 1, Pharaoh tomb (expert) 1 |
| `dun\jupiter\field\jupi_tent_02.bsr` | 3 | lit layers: `jupi_tent01_Light_alpha` | JUPITER 3 |
| `bldg\arabia\bagh_city\etc\bagh_build_deco05_01.bsr` | 2 | effects: `cj_pal_lamp_orange.efp`; lit layers: `Bagh_build_deco5_win02_alpha` | Baghdad 1, ARABIA_DUNGEON 1 |
| `bldg\arabia\bagh_city\minga\bagh_minga_l_08.bsr` | 2 | lit layers: `bagh_mingal01_win01_alpha`, `bagh_mingal01_win02_alpha`, `bagh_mingal01_win03_alpha`, `bagh_mingal01_win04_alpha` | Baghdad 1, ARABIA_DUNGEON 1 |
| `bldg\arabia\bagh_city\system\bagh_special.bsr` | 2 | effects: `cj_pal_lamp_orange_s.efp` | Baghdad 1, ARABIA_DUNGEON 1 |
| `bldg\arabia\bagh_city\system\bagh_stable.bsr` | 2 | effects: `cj_pal_lamp_orange.efp`; lit layers: `bagh_stable_wall09_win`, `bagh_stable_win01_alpha`, `bagh_stable_win02_alpha`, `bagh_stable_win03_alpha`, `bagh_stable_win04_alpha` | Baghdad 1, ARABIA_DUNGEON 1 |
| `bldg\china\cj_thiefvill\cj_thiefvill_front_01.bsr` | 2 | effects: `frame.efp` | China field 2 |
| `bldg\china\cj_thiefvill\cj_thiefvill_right_01.bsr` | 2 | effects: `frame.efp` | China field 2 |
| `bldg\china\jangan01\cj_jang_gate_door.bsr` | 2 | lit layers: `cj_jang_gate04` | Jangan 2 |
| `bldg\common\thief-vill\thief_vill_bigtent_01.bsr` | 2 | lit layers: `thief_vill_bigtent_winlight_01`, `thief_vill_bigtent_winlight_02` | Thief Village 2 |
| `bldg\europe\constantinople\euro_esteuro_castle_f01.bsr` | 2 | lit layers: `euro_esteuro_cons_rose02`, `euro_esteuro_cons_rose03` | Constantinople 2 |
| `bldg\europe\constantinople\minga\euro_costan_nobility02.bsr` | 2 | lit layers: `euro_est euro_constan_house25_winlight` | Constantinople 2 |
| `bldg\europe\constantinople\minga\euro_est euro_constan_house03_h02.bsr` | 2 | lit layers: `euro_est euro_constan_house03_h02_winlight` | Constantinople 2 |
| `bldg\europe\east eurpoe\goldfld\euro_est euro_goldh10_01.bsr` | 2 | lit layers: `Euro_Est Euro_Goldh10_03_winlight` | Europe field 2 |
| `bldg\guild\hotang\bridge\fortress_hotan_brid00_01.bsr` | 2 | effects: `cj_pal_lamp_light.efp` | no refregion row 1, Hotan fortress 1 |
| `bldg\guild\hotang\bridge\fortress_hotan_brid00_02.bsr` | 2 | effects: `cj_pal_lamp_light.efp` | no refregion row 1, Hotan fortress 1 |
| `bldg\guild\hotang\bridge\fortress_hotan_brid00_03.bsr` | 2 | effects: `cj_pal_lamp_light.efp` | no refregion row 1, Hotan fortress 1 |
| `bldg\guild\hotang\part\fortress_hotan_part01.bsr` | 2 | effects: `cj_pal_lamp_light.efp` | no refregion row 1, Hotan fortress 1 |
| `bldg\guild\hotang\part\fortress_hotan_part02.bsr` | 2 | effects: `cj_pal_lamp_light.efp` | no refregion row 1, Hotan fortress 1 |
| `bldg\north africa\alexandria\alex_defense.bsr` | 2 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `alex_special_tentlight01_alpha` | Alexandria 2 |
| `bldg\north africa\alexandria\alex_paros.bsr` | 2 | effects: `alex_paros_01.efp`, `alex_paros_02.efp`, `alex_paros_02_glow.efp` | no refregion row 1, Alexandria 1 |
| `bldg\north africa\alexandria\alex_potion.bsr` | 2 | effects: `cj_pal_lamp_orange02_s.efp`, `cj_pal_lamp_orange_s.efp`; lit layers: `alex_special_tentlight01_alpha` | Alexandria 2 |
| `bldg\north africa\alexandria\alex_variety.bsr` | 2 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `alex_variety_tentlight01_alpha` | Alexandria 2 |
| `bldg\north africa\alexandria\alex_weapon.bsr` | 2 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `alex_special_tentlight01_alpha` | Alexandria 2 |
| `bldg\oasis\hotang\hot_army\oas_hot_armysub03.bsr` | 2 | effects: `frame2.efp` | Hotan 1, Oasis Kingdom field 1 |
| `dun\jupiter\field\jupi_tent_01.bsr` | 2 | lit layers: `jupi_tent01_Light_alpha` | JUPITER 2 |
| `etc\halloween\halloween_display04.bsr` | 2 | lit layers: `halloween_display01_01` | Jangan 2 |
| `etc\obt\obt_event_hotandecob.bsr` | 2 | lit layers: `Sum_event_01` | Hotan 2 |
| `etc\summer_event\sum_event_hotandecob.bsr` | 2 | lit layers: `Sum_event_01` | Hotan 2 |
| `bldg\arabia\bagh_field\farm\bagh_field_house.bsr` | 1 | effects: `cj_pal_lamp_orange02_s.efp` | Arabia field 1 |
| `bldg\arabia\bagh_field\farm\bagh_field_stable.bsr` | 1 | effects: `cj_pal_lamp_orange02_b.efp` | Arabia field 1 |
| `bldg\arabia\bagh_petra\bagh_petra_jini.bsr` | 1 | lit layers: `Bagh_Petra_jini06` | ARABIA_PETRA 1 |
| `bldg\arabia\bagh_petra\bagh_petra_jini_lamp.bsr` | 1 | lit layers: `Bagh_Petra_jini04`, `Bagh_Petra_jini05`, `Bagh_Petra_jini_lamp` | ARABIA_PETRA 1 |
| `bldg\central asia\samarkand\samarkand_special_01.bsr` | 1 | lit layers: `SamarKand_buil_42_winlight` | Samarkand 1 |
| `bldg\china\cj_ferry\cj_ferry01.bsr` | 1 | lit layers: `CJ_ferry01_winlight` | China field 1 |
| `bldg\china\cj_ferry\cj_ferry_02.bsr` | 1 | lit layers: `CJ_ferry_02_winlight` | no refregion row 1 |
| `bldg\china\cj_ferry\cj_ferry_buil.bsr` | 1 | lit layers: `CJ_ferry_winlight` | no refregion row 1 |
| `bldg\china\dunhuang\buildings\w_cd_armo.bsr` | 1 | lit layers: `w_cd_armo-winlight` | Dunhuang 1 |
| `bldg\china\dunhuang\buildings\w_cd_etc.bsr` | 1 | effects: `cj_pal_lamp_orange.efp`; lit layers: `W_CD_etc_winlight` | Dunhuang 1 |
| `bldg\china\dunhuang\buildings\w_cd_inn.bsr` | 1 | lit layers: `w_cd_inn_winlight` | Dunhuang 1 |
| `bldg\china\dunhuang\buildings\w_cd_luxu.bsr` | 1 | effects: `cj_pal_lamp_blue.efp`, `light.efp`; lit layers: `w_cd_luxu_ornament02`, `w_cd_luxu_winlight` | Dunhuang 1 |
| `bldg\china\dunhuang\buildings\w_cd_weapon.bsr` | 1 | effects: `cj_pal_lamp_orange02_b.efp`, `frame.efp`, `frame2.efp`; lit layers: `w_cd_weap_winlight` | Dunhuang 1 |
| `bldg\china\dunhuang\minga\w_cd_minga05.bsr` | 1 | lit layers: `w_cd_minga_winlight` | Dunhuang 1 |
| `bldg\china\jangan01\cj_acce.bsr` | 1 | effects: `light.efp`; lit layers: `CJ_acce_winlight` | Jangan 1 |
| `bldg\china\jangan01\cj_armo.bsr` | 1 | effects: `cj_pal_lamp_light.efp`, `cj_pal_lamp_orange_s.efp` | Jangan 1 |
| `bldg\china\jangan01\cj_etc.bsr` | 1 | effects: `cj_pal_lamp_light.efp`; lit layers: `CJ_etc_winlight` | Jangan 1 |
| `bldg\china\jangan01\cj_luxury.bsr` | 1 | lit layers: `CJ_luxu_winlight`, `CJ_luxu_winlight02` | Jangan 1 |
| `bldg\china\jangan01\cj_stab.bsr` | 1 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `CJ_stab_winlight` | Jangan 1 |
| `bldg\china\jangan01\monsterstadium\cj_monstad_door01.bsr` | 1 | effects: `frame.efp` | Jangan 1 |
| `bldg\china\jangan02\cj_pub03.bsr` | 1 | lit layers: `CJ_adult03_winlight` | Jangan 1 |
| `bldg\china\jangan02\cj_pub05.bsr` | 1 | lit layers: `CJ_pub05_winlight` | Jangan 1 |
| `bldg\common\thief-vill\thief_vill_bonfire_01.bsr` | 1 | effects: `frame4.efp` | Thief Village 1 |
| `bldg\europe\constantinople\euro_constan_armor.bsr` | 1 | lit layers: `Euro_Constan_armor_winlight` | Constantinople 1 |
| `bldg\europe\constantinople\euro_constan_inn01.bsr` | 1 | effects: `light.efp`; lit layers: `Euro_Constan_inn01_light01`, `Euro_Constan_inn01_light02` | Constantinople 1 |
| `bldg\europe\constantinople\euro_constan_potion01.bsr` | 1 | lit layers: `Euro_Constan_potion01_light` | Constantinople 1 |
| `bldg\europe\constantinople\euro_constan_special.bsr` | 1 | effects: `light.efp`; lit layers: `Euro_Constan_special_window01`, `Euro_Constan_special_window02` | Constantinople 1 |
| `bldg\europe\constantinople\euro_constan_stable.bsr` | 1 | lit layers: `Euro_Constan_stable_wall01_winligh`, `Euro_Constan_stable_wall02_winlight` | Constantinople 1 |
| `bldg\europe\constantinople\minga\euro_costan_nobility01.bsr` | 1 | lit layers: `euro_est euro_constan_house25_winlight` | Constantinople 1 |
| `bldg\europe\constantinople\minga\euro_est euro_constan_house02_h01.bsr` | 1 | lit layers: `euro_est euro_constan_house02_h01_winlight` | Constantinople 1 |
| `bldg\europe\east eurpoe\goldfld\euro_esteuro_goldh02.bsr` | 1 | lit layers: `Euro_EstEuro_Goldh01_05_winlight` | Europe field 1 |
| `bldg\north africa\alexandria\alex_special.bsr` | 1 | effects: `cj_pal_lamp_orange_s.efp`; lit layers: `alex_special_tentlight01_alpha` | Alexandria 1 |
| `bldg\oasis\hotang\castle\oas_hot_b2_bridge.bsr` | 1 | effects: `cj_pal_lamp_light.efp` | Hotan 1 |
| `bldg\oasis\hotang\castle\oas_hot_c1_castle.bsr` | 1 | effects: `cj_pal_lamp_orange_b.efp` | Hotan 1 |
| `bldg\oasis\hotang\castle\oas_hot_c2_castle.bsr` | 1 | effects: `cj_pal_lamp_orange02_b.efp`, `cj_pal_lamp_orange_b.efp` | Hotan 1 |
| `bldg\oasis\hotang\castle\oas_hot_c3_castle.bsr` | 1 | effects: `cj_pal_lamp_orange_b.efp` | Hotan 1 |
| `bldg\oasis\hotang\hot_army\oas_hot_armysub02.bsr` | 1 | effects: `frame2.efp` | Hotan 1 |
| `bldg\oasis\hotang\oas_hot_accessory.bsr` | 1 | effects: `w_cd_potal_blue_g.efp` | Hotan 1 |
| `dun\property\wreck\ship\wreck_bship_in_01.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha`, `Wreck_Bship_in_object03_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_bship_in_02.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha`, `Wreck_Bship_in_object03_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_bship_in_03.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha`, `Wreck_Bship_in_object03_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_bship_out_01.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha`, `Wreck_Bship_in_object03_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_bship_out_02.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha`, `Wreck_Bship_in_object03_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_bship_out_03.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha`, `Wreck_Bship_in_object03_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_in_01.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_02.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_03.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_04.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_05.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_06.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_07.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_08.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_09.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_in_10.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_IN 1 |
| `dun\property\wreck\ship\wreck_sship_out_01.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_02.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_03.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_04.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_05.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_06.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_07.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_08.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_09.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `dun\property\wreck\ship\wreck_sship_out_10.bsr` | 1 | lit layers: `Wreck_Bship_in_Light02_alpha` | GOD_WRECK_OUT 1 |
| `etc\halloween\halloween_display03.bsr` | 1 | lit layers: `halloween_display01_01` | Jangan 1 |
| `etc\obt\obt_event_jangdoor.bsr` | 1 | lit layers: `Sum_event_01` | Jangan 1 |
| `etc\summer_event\sum_event_jangdoor.bsr` | 1 | lit layers: `Sum_event_01` | Jangan 1 |

**Dungeons** (`.dof` rooms and objects, MEASURED with DofReader; `Dungeon\wchina\dunhwang_cv1.dof`
does not parse, and the served `dunhwang_cv.dof` names no night model):

| Dungeon | Night models |
|---|---|
| `Dungeon\china\jinsi_floor03.dof` (Qin-Shi tomb, floor 3) | its rooms `jinsi_floor3_r01`..`r07` and `t01`..`t10`: lit layers `Jinsi_floor3_crystal01` / `02` (the crystals) |
| `Dungeon\china\jinsi_floor06.dof` (floor 6) | `jinsi_floor6_jewel`, `jewel02`, `room01`, `room01_huk`, `room01_su`, `room02`: lit layers `Jinsi_floor6_B01_04` |
| `Dungeon\demon\death\demon_p_altar_death.dof` | `demon_p_altar_fire_d` x160: lit layers |
| `Dungeon\demon\fire\demon_tower_fire.dof` | `demon_tower_gate_ain_fire` x38: lit layers |
| `Dungeon\demon\ice\demon_tower_ice.dof` | `demon_tower_gate_ain_ice` x26: lit layers |
| `Dungeon\demon\poison\demon_altar_poison.dof` | `demon_p_altar_fire` x162: lit layers |

The flag is the clock's in a dungeon too (no test, above): the tomb's crystals are drawn by their
own colour only between 20:00:01 and 03:59:59.

**Not placed by the map** (119 models): the event sets that come and go (`etc\summer_event` 18,
`etc\obt` 12, `bldg\common\event-xmas` 15 -- the Christmas tree's candles, balls and stars --
`etc\halloween` 5, `etc\object_festival_summer`), unplaced variants of placed buildings
(`bldg\china` 8, `bldg\oasis` 3, `bldg\europe` 2, `bldg\guild` 1, `bldg\arabia` 1,
`etc\guardpost\level_small_guardpost`), the dungeon models above, and four that are not
buildings at all:

- **the gold on the ground**: `item\etc\drop_ch_money_small` / `_normal` / `_large` (flag word
  0x348) and `drop_ch_money_ing` (0x349) -- a dropped gold pile is drawn by its own colour at night;
- `mob\china\yeoha_muhan` (layer `Yeoha`, 0x349) -- a monster;
- `cos\t_horse2_2011` (layer `t_horse`, 0x349) -- a transport's horse.

## What OpenSRO does (round 806)

- **The flag** (`GameClock.is_night_phase`): the READ test on the same float phase the sky uses;
  `World3D._night_tick` evaluates it every frame -- in the field, in dungeons and on the front end
  (its fixed hour) -- and on a change sets `EfpEffect.set_night` and the shader global `srr_night`,
  logging `World3D: night flag ON|off at day phase ... (clock hh:mm:ss)`. With no clock (an older
  server, `-world-clock` off) the phase is the fixed 0.5: day.
- **Night-only effects** (`AmbientParticles.attach` marks them, `EfpEffect.night_only`): an object
  whose ambient entries are all night-only is built at the first night frame it is in range
  (`WorldAmbientFx.Host.night_only`, `night_changed`), as the original creates the effect; one with
  day entries too is built with them, its night effects held until night (OURS: the same picture --
  a held effect is not stepped, so it too starts empty). By day a night-only effect is hidden, not
  stepped (`step_pre` refuses; `WorldAmbientFx` and the dungeons' batch leave it out) and skipped by
  the glow pass; at night shown and stepped from where it stood.
- **Night-lit layers** (`ObjectLoader.LAYER_FLAG_NIGHT_LIT`, the material uniform `night_lit`,
  `object.gdshaderinc`'s `SRR_NIGHT_LIT`): at night oD0 = 1 and stage 0 MODULATE, in every
  object shader variant (solid, alpha-tested, two-sided, light-mapped, MULTITEX, the fade twins)
  and for characters, which build their materials through the same code. Fogged as any object
  (READ above). OURS Night Darkness does not reach them: they ignore the light it scales.
- The world's ambient effects are not decided or built while a loading drain runs (OURS; behind
  the loading screen nothing is seen), so the night's builds start with the first frame of play.
- QA: `OPENSRO_QA_NIGHT=on|off` forces the flag; `OPENSRO_QA_WORLD_FX_DETAIL=1` prints each
  effect's `night-only` flag.

## Range, fog and walls (round 807, OURS)

The user (2026-10-21), after round 806: the effects "pop out of view too early", should stay "visible a
little past the fog but hide it behind the fog", "show through walls and other objects ... go away after
a bit", and "if the fog is disabled have the effects render out as far as the landscape lets you"; then
"some of these effects including animated waterfalls can be seen even when behind the fog". Each is a
departure from the original, on purpose:

- **Range.** The original plays a lists[2] object's effects within 480 units and one of the 3 x 3
  sectors around the camera, a lists[1] object's within the object range (view distance - 480; READ,
  `WorldAmbientFx`). The lamps and burners are lists[2], so they stopped at 480 while the fog starts
  at 784..1897 (Hotan..Jangan at the default sight range). Now every placed object's effects play
  while the object's **view depth** less its radius is below `WorldAmbientFx.fx_reach`: the fog's
  end + 100 (`FOG_MARGIN`) with the fog on, the camera's far plane (where the landscape ends) with
  "Fog (temporary)" off (`World3D._apply_fx_reach`, re-set with the fog and the far plane). View
  depth, as the fog and the far plane measure it, so an effect at the screen's edge stops no earlier
  than the fog hides it. Animated map objects still hide at the object range (READ,
  `MapAnimation`), and their effects with them.
- **Fog.** The original draws particles with FOGENABLE 0. Every effect now fades by the world's fog
  as the surfaces around it do (`WorldFog.SHADER_FN`, the same planes or the dungeon's EXP fog):
  Godot's effect shaders scale the source alpha (blend_mix and blend_add both weigh the source by
  it); the display pass (`EfpDisplayPass`) fades each draw at its vertices toward the source its
  Direct3D blend pair leaves the screen unchanged with (`fog_fade_mode`: the alpha; colour and alpha
  for a ONE source; white for a multiply; alpha 1 for BOTHINVSRCALPHA). Fully fogged, an effect adds
  nothing.
- **Walls.** The original draws a glow with ZENABLE off and asks an occlusion query for one point
  every 500 ms, fading by 1.5 alpha a ms (READ, `AmbientParticles`): a lamp that went behind a wall
  showed through it for up to 500 + 170 ms, and one turned to restarted from the last query's answer.
  The same point -- the effect's place moved toward the eye by (byte - 1) -- is now also tested
  against the scene's depth every frame on the GPU (`EfpEffect.glow_anchor`, its glow shader;
  `EfpDisplayPass`'s fragment shader), and the glow is not drawn while the depth there is nearer.
  Off the screen the point decides nothing (the fade does, as before). The CPU ray and the fade still
  set the alpha.
- QA: `OPENSRO_QA_GLOW=noquery` takes every glow as visible to the 500 ms test (each frame as the one
  after a turn), `noquery,nogpu` also drops the GPU test (as before round 807);
  `OPENSRO_QA_FX_FOG=off` draws the pass's effects unfogged.

Not reproduced: the MTRL-mod shader's night lighting (no night-lit layer reaches it, MEASURED); the
far crowd's GPU twins (a far other player's parts; no worn item carries the bit, MEASURED).
