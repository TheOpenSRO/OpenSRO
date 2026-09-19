## The target window from its own layout: a 4-pixel gauge in a 196x51 frame, not a red block under a stretched one

The report: "the healthbar for it is a fuggin mess". The screenshot showed the
frame with a fat red rectangle and a "100%" label sitting under it. That
window was `World3D._build_target_window`: `interface\targetwindow\tw_type1.ddj`
(200x72) stretched to 320x115, and a `ColorRect` plus a percent `Label` at
rects "eyeballed from the art and tuned by rendering" -- its own comment said
so. None of it was the client's.

**What the archive authors** (`tools/dump_layout.gd`, `list_archive_dir.gd`):

- `ginterface.txt` registers `GDR_TARGETWINDOW` (`CIFTargetWindow`) at
  **(442, 10)**, rect 10x10 -- "the art's own size".
- `iftargetwindowex.txt` is the container: a 16x16 close button at (176, 9)
  and one sub-window per target kind, each an atlas piece of
  `interface\ifcommon\window_all.ddj` at its own size -- `GDR_TW_COMMONENEMY`
  **196x51** at uv (0.5303, 0)..(0.7217, 0.0996) = pixels (543, 0) on the
  1024x512 sheet, `GDR_TW_SPECIALMOBWND` 196x78, `_PLAYERWND` 196x36,
  `_JOB_PLAYERWND` 196x58. The older `iftargetwindow.txt` lists the same
  pieces plus 236-wide twins, a buff viewer and a fortress window; both agree
  on the common-enemy piece. So the frame is that piece, not `tw_type1.ddj`
  (which nothing in either layout names; the `tw_type1..4` frames stay
  unaccounted for).
- `iftw_commonenemy.txt`, a normal monster's inside, is three controls: the
  gem `GDR_TWCE_GEM` at **(8, 5) 20x20**, the HP gauge
  `GDR_TWCE_GAUGE_HPGAUGE` (`CIFGauge`, `interface\targetwindow\tw_hp.ddj`) at
  **(14, 37) 168x4**, and the name `GDR_TWCE_TEXT_ID` at (34, 10) 137x12,
  centred, font index 0. **No level text and no rank icon.** Those are the
  special-mob layout's (`iftw_specialmob.txt`: `_LEVEL` (10, 56) 30x16, the
  rank icon `_ICON` (65, 54) 16x16, `_TEXT_LEV` (85, 56) 168x12, plus the
  same gem, gauge and name).
- `interface\targetwindow\` holds the gauge art (`tw_hp.ddj`, `tw_mp.ddj`,
  `tw_hp_npc.ddj`), the level gems (`tw_gem_weak1/2, normal, strong1/2,
  animal, npc, player, wanted_rank`), the rank icons and the job marks.

**What the client binary does with it** (sro_client.exe dump on the RE box):

- `CIFTargetWindowCommonEnemy::Create` (`0x0069aaa0`) loads its "Create"
  section by name -- these sub-windows are layout-driven, not code-drawn.
- `CIFTargetWindow` (`0x00699540`; the dump mis-files it under `UI_SILKMALL`)
  switches on the target's rarity (`+0x1eb`): 0 takes the common-enemy window,
  the rest the special one with `Client_TargetWindow_RankIcon`. (It also
  scales a special mob's *displayed* max HP by rarity -- champion x2, elite
  x4, giant x20, titan x100 -- a client display rule, noted for the server
  lane, not applied here: srrevamp shows the server's number.)
- The gem and the name colour come from one classifier,
  `FUN_007780c0(targetLevel)` (`0x007780c0`): `d = targetLevel - playerLevel`
  (the player's level byte at `DAT_00eef5ec+0x868`); `d < -6` -> class 0,
  `< -3` -> 1, `< 1` -> 2, `<= 5` -> 3, else 4, and the switch at
  `0x006996f0`..`0x699749` pairs them: weak2 `0xff87d2ff`, weak1 `0xffa5e0ce`,
  normal white, strong1 `0xffffb387`, strong2 `0xffff8787`.
- A gauge, `CNIFGauge::vslot_013` (`0x00498960`) -> `FUN_0046d6f0(ratio)`
  (`0x0046d6f0`): `+0x264 = ratio * fullWidth` and `+0x27c = ratio * fullU`
  -- the drawn width **and** the texture's U extent scale together, so the
  fill is clipped from the left, never squashed. (It also draws a second,
  dimmer ratio when two differ -- a damage ghost -- not built here.) Godot's
  `TextureProgressBar`, which `UiBuilder._build_gauge` already makes of a
  `CIFGauge`, clips the same way.

**Shipped.** `client/scripts/ui/hud/hud_target.gd` (new, `HudTarget`): the
container's close button and the common/special pieces from
`iftargetwindowex.txt`, each piece's own inner layout from `iftw_*.txt`
through `UiBuilder.build_section`, the gem slot given a `TextureRect` at its
authored rect (an art-less static builds as a Label), the gauge fed
`hp/max` from the server's snapshot, the name coloured and the gem chosen by
the recovered classifier from the player's own level (`_on_world_stats` now
hands it over; unknown level -> the neutral class, not a guess), the rank
icon only on the special window. `World3D.gd` keeps `_build_target_window`
/ `_show_target` / `_set_target_hp` / `_clear_target` as thin wrappers so no
caller moved; the hand-built constants and nodes are gone. Placement: the
registry's (442, 10) kept as an offset from the 1024-wide layout's centre
line (identical at 1024; the real client's left-vs-centre anchoring is not
recovered and is stated in the code). `hud_target_test.gd` covers the
classifier's boundaries, the rank switch and the no-archive path.

**Measured.** `--server --attack` at region 96/168 local (1089, 600), current
server binary: the log prints `gauge (14, 37) size (168, 4)` -- the authored
rect to the pixel -- and `fill 100.0% (249/249)` falling to `97.6% (243/249)`
with the server's own numbers over four hits. On frame 210 the red fill
spans x = 584..748 (window at 570 + authored 14; 165 px = 168 x 0.976) over
rows y = 47..50 (10 + 37, four rows; row 48 is the art's own highlight). The
crop (`scratchpad/target/target_crop_x4.png`) is the real window: the 196x51
piece 1:1, the red strong2 gem and salmon name for a monster far above a
level-1 player, the thin gauge in its slot, the close button.

**Stated, not claimed.** The special-mob window's two level texts are built
but left empty: which of `_LEVEL` / `_TEXT_LEV` carries the number and which
a word (`UIIT_STT_MOB_STRONG` sits in that code) is unread. The common
window's own layout shows no level; the level is what the gem says. The
atlas region for the 196x78 special piece comes out 77.9999 rows and is
drawn a sub-pixel stretched -- `UiBuilder.load_texture_region` keeps float
regions; rounding them is a nit for that file's owner. `tw_type1..4.ddj`
are real art nothing in these layouts uses.
