# UI: what's left

The ordered list of client UI work, in the same spirit as [TODO.md](TODO.md): what is known, what
is not, and the next concrete step. Visual target is the reference set catalogued in
[reference/ui/README.md](reference/ui/README.md).

Read [HANDOFF_UI.md](HANDOFF_UI.md) first if you are new to this lane.

## The recipe (established — do not re-derive)

Every window in the real client is authored data, and building one is now mechanical:

1. **`resinfo\ginterface.txt` is the top-level window registry.** For a *HUD-anchored* window it
   gives the background artwork and the screen rect — `GDR_UNDERBAR` → `ub_window_01.ddj`,
   `112,684,800,52`; `GDR_MINIMAP` → `mm_window.ddj`, `892,6,140,184`; `GDR_PLAYER_MINI_INFO` →
   `ifcommon\window_all.ddj`, `4,7,212,70`.
2. **`resinfo\if<name>.txt` gives that window's children.** One file per panel, 248 in total.
3. **`Rect` is `x, y, width, height`**, and the art is authored **1:1** — confirmed by every
   authored size matching its texture's real dimensions (`ub_window_01` 800×52, `ub_deco_left`
   64×52, `ub_menu_button` 60×56, `ub_sp_bar` 144×8, `mm_window` 140×184). Do not stretch it.
4. **A zero-size rect means "use the artwork's own size"** — real layouts rely on this.
5. **`Color` is not a tint.** It is a per-control editor id: 64 distinct scattered values across
   ifunderbar's 76 controls, while `FontColor` — a field that really is a colour — is white on 74
   of the same 76. `FontColor` is the one to honour.
6. **Buttons come as `X.ddj` / `X_focus.ddj` / `X_press.ddj` / `X_disable.ddj`**, which maps
   straight onto `TextureButton`'s four texture slots.
7. **Panel windows are self-framed.** Inventory, Skill, Action and friends are *not* in the
   registry; their own layout file carries a `CIFFrame` / `CIFStretchWnd` whose `ddj` is an
   8-slice base ending in `_` (`interface\frame\mframe_wnd_`, `interface\messagebox\
   msgbox2_window_`), expanded as `_left_up`, `_mid_up`, `_right_up`, `_left_side`, `_right_side`,
   `_left_down`, `_mid_down`, `_right_down`. `UiBuilder._build_frame` already does this.
8. **Interface art is 16-bit ARGB1555**, decoded by `DdjReader` since the hundred-and-first round.

The network layer behind all of this is already implemented and unit-tested — `client/scripts/net/`
has `party`, `guild`, `quest`, `inventory`, `skill`, `shop`, `trade`, `friend`, `chat`, `combat`,
`equipment`, `duel`, each with its own `_test.gd`, reachable through the `NetClient` autoload. This
is presentation work on solved data; if you find yourself editing the protocol, look twice.

## Done

- **Every panel window is now built from its authored layout** — `HudWindow` reads a
  `resinfo\if*.txt`, sizes itself from the frame at the origin, expands the 8-slice border and
  adds a title bar, close button and drag. `HudPanels` owns thirteen of them, opens them on first
  use, and binds hotkeys plus the underbar's MENU. Six verified open together in one render:
  inventory 176×308, character 364×356, skill 364×333, quest 365×355, party 364×303,
  community 464×381 — every size straight out of the authored file.
- **Player mini info** — name, level, HP and MP bars, top-left at the registry's own `4,7`.
- **The debug UI it replaces is hidden** — the ten-tab panel, the character and help labels, and
  the zone label (the minimap carries the zone name and X/Y now).
- **Underbar** — full 800×52 background, SP gauge, numbered quickslots, page arrows, menu
  medallion, both end decorations. Verified in a render.
- **Minimap** — region art clipped to the frame's circular aperture with the client's own
  `mm_alpha.ddj` mask, compass frame, player heading arrow. Verified in a render.
- **`UiBuilder`** — buttons, statics, gauges, slots, 8-slice frames, text-table lookup, texture
  cache, and `window_def()` for the registry.

## Next up

### 1. Fill the panels with their authored presentation
The windows are real; their *contents* are a plain list laid over the frame. Each one wants its
authored presentation instead:

- **Inventory** — *icons done* (hundred-and-eleventh round): the authored slot grid is filled from
  `itemdata*.txt`, 11,772 items resolvable by id, 32×32 icons matching the grid pitch exactly.
  Still wanted: the gold readout, and drag between slots.
- **Character** — bind the `GDR_PMI_TXT_*DAT` stat rows in `ifplayerinfo.txt` to the character
  data the server already sends.
- **Party / Community / Guild** — the row controls exist (`CIFPartySlot` builds as a slot); they
  need one row per member with name, level and HP.
- **Skill / Quest** — mastery tabs and quest rows.

### 2. Vitals, and the rest of the live data
`HudPlayerInfo.set_hp`/`set_mp` exist and are called with a placeholder 200/200, because the
server does not report vitals to the client yet. Wire it once it does — and until then the
placeholder is a full bar rather than an empty one, since an empty HP bar reads as "you are dead".

### 3. What is left of the old debug UI
The chat box and the Change Zone box are still on screen. Chat needs its authored window
(`ifchatmodule.txt`, `ifchatviewer.txt`); the zone box has to stay until there is another way to
travel.

### 4. Panels with no server behind them
`action`, `partymatch`, `academy`, `autopotion` and `alchemy` open and draw, but there is nothing
to fill them with — no server side exists. Either build it (server lane, see
[HANDOFF_OPENSRO.md](HANDOFF_OPENSRO.md)) or make them client-side where they legitimately are
(Auto Potion is a client setting; System is Option/Help/Restart/Exit).

### 5. Minimap signs
The zone name and X/Y readout now render (they were silently built as plain Controls rather than
Labels, which the empty-CIFStatic fix cured). `interface\minimap\` has `mm_sign_npc`, `mm_sign_questnpc`, `mm_sign_monster`,
`mm_sign_otherplayer`, `mm_sign_party` and the quest/party arrows, which want the entity lists the
client already receives. Zoom in/out buttons are wired but untested.

### 6. World map
`GDR_WORLDMAP`, `ifworldmap.txt`, 652×424. The reference shows both a regional view with named
landmark icons and a continent view. `interface\worldmap\` holds **5,320** tiles — by far the
largest interface directory — so the art is all there. Landmark names come from
`textzonename.txt`, already parsed for the city coordinate work.

## Cross-cutting, worth doing early

- **A `Theme` built at runtime from `Media.pk2`.** 8,538 files under `interface\`, with the
  `_focus`/`_press` convention mapping onto `StyleBoxTexture`. Every panel then inherits the real
  look instead of styling each one.
- **Fonts.** The reference's text is a small bitmap-ish face; Godot's default is visibly wrong at
  these sizes. `Media.pk2` has `vplus\vfont.ttf`, and `FontIndex` appears on every control, so
  there is probably an authored font table — **not yet investigated**.
- **Localised strings.** `UiTextTable` reads `textuisystem.txt` (3.5 MB); button and title text in
  the layouts is given as `SN_` keys, so resolve through it rather than hardcoding English.
- **Scaling.** The layouts are authored for a 1024×768 default at 1:1 pixel size. Decide what
  happens on a larger window — the real client anchors and does not scale — and do it once,
  centrally.

## Unknowns, flagged rather than guessed

- **Which authored coordinate belongs at the screen centre vertically.** The underbar sits flush
  to the bottom by choice, not by recovery: `GDR_UNDERBAR`'s `y=684` implies a 32px gap at 768
  tall, but the same file puts `GDR_CHAT_BOARD`'s bottom at 944 — past the bottom of a 768-tall
  screen — so those defaults are not all screen-relative. Horizontal centring *is* authored
  (`112 = (1024-800)/2`).
- **The registry-to-layout-file mapping** (see item 2).
- **`FontIndex`** — an index into something not yet found.
- **`UV_LT`/`UV_RT`/`UV_LB`/`UV_RB`** on every control. Parsed, unused; presumably atlas
  sub-rects, all `0,0`–`1,1` in the files read so far.
