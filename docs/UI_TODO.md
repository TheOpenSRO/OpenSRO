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
9. **A section lists its controls front to back.** The window's own frame is always the *last*
   entry (`GDR_PI_SUBFRAME`, `GDR_INVENTORY_FRAME`), so children go into the Godot tree
   **reversed**. Built in file order, every window covers its own contents.

   *How far this is verified*: the behaviour is — built in file order the frames and background
   tiles covered their own windows, and reversed the result matches the reference screenshots.
   The data agrees: the frame is last in every layout that has one. The client-side mechanism is
   **deduced, not read**: the control the factory builds is appended to its list with a
   `_Buynode(head, head->prev, value)`, which is a push_back in parse order, so for a
   last-declared frame to end up behind everything the renderer must walk that list backwards.
   The iteration itself has not been found.
10. **`CIFNormalTile` is what fills a window's body** — 253 across the archive, the fourth most
   common control type. No 8-slice frame set has a centre piece (checked three times, and
   `CNIFFrame` in the client loads exactly eight suffixes), so a window with no tiles is meant to
   be see-through. Do not invent a fill colour; two rounds were spent on that.
11. **A `CIFLattice` cell is one piece of its own artwork, 36×36 for `com_lattice_`.** Supported
   by a negative check in the client as well as by the data: **no `36`/`0x24` appears anywhere in
   the lattice class's own functions**, which is what you would expect if the pitch comes from the
   piece at runtime and not what you would expect if it were a constant. Its `ddj`
   is a base with a trailing underscore that expands to only **four** names — `left_up`,
   `right_up`, `left_down`, `right_down` — which are not corners but one cell each, differing in
   which shared separators they carry. All 14 lattices in the archive divide by 36 exactly and
   none divides by 32: inventory 4×8, storage and stalls 6×5, exchange 6×2, action bar 9×2 and
   4×2, pet bag 7×4.
12. **Window chrome comes from `ifalchemybox.txt`**, the one layout that spells it all out: a
   42-pixel title strip inset 10 a side (`CIFDragableArea 10,0,355,42`), a centred 12-tall caption
   at y=18, and a 16×16 `CIFCloseButton` 26 in from the right edge. A `CIFCloseButton` with no
   artwork uses `interface\ifcommon\com_windowclose.ddj`, which the client hardcodes.
13. **A window is its frame plus any artwork hanging off it**, not the bounding box of every
   control. ifinventory's gold row sits 25 pixels below the frame; ifplayerinfo's `TEXT_HP_DAT` is
   a text field that overruns the right edge by 17 and must not widen the window.
14. **A `ddj` ending in `_` is an 8-slice base, whatever the control type is called.** (This is
   *our* dispatch strategy, not a claim about the client — there, each class calls its own piece
   loader. What is read from the client is how many pieces each of those loaders takes: eight for
   a frame, six for a stretch window, four for a lattice.) 496
   controls across the archive name one, spread over 220 type names -- `CIFSkillBoard`,
   `CIFCommunity`, `CIFBarWnd`, `CIFJobRankSlot` and two hundred more. Dispatch on the suffix,
   not on a list of type names. `CIFLattice` is the exception: its base expands to four *cell*
   pieces, not eight frame ones.
15. **A layout can hold several sections, and "Create" is only the chrome.** ifskill has three,
   ifguild has ten. Which compose is per window: the skill window's `MainSkillWnd` and
   `Withdrawal` are **alternates**, picked by `m_bySkillWndType` in the client (type 1 loads
   Withdrawal, types 2 and 3 load MainSkillWnd -- one function, one branch). `HudPanels`'
   `EXTRA_SECTIONS` lists only the ones that have been established. When the binary is silent --
   it has no string for any of ifguild's -- `sweep_section_overlap.gd` settles it from the
   geometry: sections that compose have controls that are **pairwise 0%** overlapping, and a
   section covering another's controls is an alternate. Validated against ifskill, where the
   binary gives the answer independently.
16. **`resinfo\base.txt` is a designer's prototype, not a runtime file.** It holds five window
   recipes (Type1..Type5) -- a `CIFFrame` plus a `CIFNormalTile` inset exactly 16 pixels inside
   it, optionally with `com_blacksquare_` panels over a `com_bg_tile_e` backing -- and it looks
   exactly like the missing rule for filling a window body. It is not: the string `base.txt`
   appears nowhere in the client binary, and every section header in the archive ends in the same
   `"0"`, so nothing selects a recipe. Checked so nobody chases it twice.
17. **A list row draws itself as a horizontal bar.** The client sets
   `interface\ifcommon\com_bar01_` on an unselected row and `com_bar01select_` on the selected
   one — six classes do — and that is what fills a list body. ifpartymatch draws a
   `com_blacksquare_` border around its list with **no** fill behind it while declaring
   `com_bg_tile_e` behind each small input box in the same section: the big one is empty because
   the rows fill it.
18. **Not every base ending in `_` is an 8-slice.** `com_bar01_`, `com_bar01select_` and
   `com_bar02_` expand to `left` / `mid` / `right` — a horizontal 3-slice, 4×24 caps around a
   24×24 middle. Ask the archive for `left_up.ddj`; its absence is the signal.
19. **A slot's shape says whether it is an item square or a list row**, and the archive is
   unambiguous: every slot naming no artwork is either exactly 1.0 wide-to-tall (335 of them) or
   at least 3.5 (58 of them), with nothing in between. `sweep_slot_shapes.gd` prints it.
20. **Godot clamps `Control.size` up to the minimum size, and will fight the layout.** A
   `TextureRect`'s minimum is its texture (use `EXPAND_IGNORE_SIZE`); a `Label`'s is computed from
   the theme's *default* font until its theme cache refreshes a frame later (re-apply the rect);
   a `Button` with text has one from its own label (use a `TextureButton`). `UiBuilder` records
   each authored rect in metadata and `apply_authored_rects` restores it — and it must record what
   the layout asked for, never `node.size`, which is already clamped.

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
- **`UiBuilder`** — buttons, statics, gauges, slots, tiles, lattices, close buttons, 8-slice and
  6-piece frames, text-table lookup, texture cache, and `window_def()` for the registry.
- **Window interiors and item grids** (hundred-and-thirteenth round) — panels are no longer
  hollow and the inventory draws its real 4×8 grid of authored slots.

### Tools for this lane
`client/tools/dump_layout.gd` prints one layout in declaration order with every rect, alignment
and font index. `dump_window_tree.gd` builds a real `HudWindow` and prints the resulting nodes
with their rects, textures and minimum sizes — use it instead of squinting at a render.
`grep_layouts.gd` searches all 248 layouts by control name, type or artwork path, which is how
the lattice pitch, the close-button convention and the tile fill were each settled.

## Next up

### 1. Fill the panels with their authored presentation
The windows are real; their *contents* are a plain list laid over the frame. Each one wants its
authored presentation instead:

- **Inventory** — *done* (icons: hundred-and-eleventh round; gold + drag: `docs/rounds/
  inventory.md`): the authored slot grid is filled from `itemdata*.txt`, 11,772 items resolvable
  by id. Note the grid is **4×8 at a 36-pixel pitch**, not 32, so a 32×32 icon sits inside a
  36-pixel cell. The authored gold row (`GDR_INVENTORY_STA_GOLD`) shows the server's balance
  (`OpCharacterStats`, requested on open). Dragging a stack onto another cell is `OpInventoryMove`
  — the server decides move / merge / swap and answers with the whole bag; dragging onto a worn
  slot of the docked doll is `OpEquip`. A successful equip/unequip now answers with the worn
  list rather than an empty ack (which read as "wearing nothing" and blanked the doll).
- **Character** — *done for every row the server can state* (2026-09-19): the title's level,
  Current/Next Exp. as the client's own absolute `%I64d`s (`CURXP2`/`NEXTXP2`; next = leveldata's
  exp to advance from this level), Stat Point (`STAT2`) with the two `com_plus_button`s spending
  the pool through `OpSpendStatPoints` (the engine's `GObjPC_SpendStatPoints` rule: refused unless
  the spend fits the pool, else plain increments), Str/Int, HP/MP over the authored `chr_hp`/`chr_mp`
  gauges, `Phy. atk`/`Mag. atk` as the "%d ~ %d" ranges from `combat.WeaponRange` (the physical
  half reinforced by Str, the magical by Int — the parameter graph), `Phy. def.`/`Mag. def.` as
  the armour sums. The old `Phy. atk` was a single ROLL of the range on every request. Left as the
  layout drew them, each with a stated reason (see `HudPanels._fill_character_window`):
  **Phy./Mag. balance** — the client shows a stored byte (`CICPlayer+0x20d8`) whose source is
  unread and this server computes no balance; **Hit rate / Parry ratio** — engine params 11/9,
  a base of 10.0 plus each worn item's own *per-instance* rate (needs the item variance this server
  does not carry), and params the engine never reads (RE_COMPLETION, "Attack rate and parry are
  DEAD params"); **Trader/Hunter/Thief grades** and **Honor point** — no job or honour system here.
- **Party / Community / Guild** — the row controls exist (`CIFPartySlot` builds as a slot); they
  need one row per member with name, level and HP.
- **Skill** — *done (window + economy + per-skill learning, v0.1.121)*: the real `CIFSkillBoard`
  rebuilt from the client's own resinfo and a decompile of `CIFSkillBoard`/`CIFSkillGroup`/
  `CIFSkillSlot` — Weapon/Force tabs, the mastery tabs (Bicheon/Heuksal/Pacheon…), and per mastery
  a scrolling grid of one row per skill group (`skillgroup.txt`), each holding that group's skills
  as cells (`skilldata_*.txt`, via `SkillDataReader`). Cell metrics are the client's own (8 columns
  pitched 36px from x=37). The window is server-driven (`set_skill_state`): a mastery's LEVEL UP
  button spends skill points (total capped at a flat 330, round 483; greyed with the real cost,
  leveldata column 2, when the points fall short, round 516); each skill cell renders
  learned (colored icon + `skl_level_tab` badge with the trained level) / learnable-next (icon +
  `skl_button_add` "+" → learns the next level) / locked (`skl_mastery_disable`) / empty
  (`skl_mastery_nothing`), at the grounded `ifskill_slot.txt` rects (icon 0,0,32,32; "+"
  0,32,32,20; badge at 19,17). SP is earned per kill (disclosed `SPFor` placeholder).
  **End-to-end as of v0.1.126:** casting a learned skill plays its real cast animation (the `.ban`
  clip named after the skill's `Basic_Code`), the server casts real skills on their real
  `ReuseDelay` cooldown, a learned skill goes on the hotbar
  (click it → underbar quickslot; the quickslot casts), and each skill lands its own hit effect
  (`skilleffect.txt` → the skill's hit `.efp`, layers recovered generically at runtime). The ONE
  substantive item left is **real skill damage** — a cast deals a plain attack (disclosed) because
  the `_RefSkill` Param damage grammar isn't decoded; it needs a dedicated Ghidra dig (all data
  shortcuts are dead ends — see the skilldata-columns memory). Minor polish: the mirage
  weapon-trail texture, cast-time effects, skill sounds, and grounding real per-mob SP/EXP.
  Ghidra decompile helpers are in `client/tools/ghidra/` (GhidraMCP is broken on Ghidra 12.1.3).
- **Quest** — quest rows.

### 2. Vitals, and the rest of the live data
`HudPlayerInfo.set_hp`/`set_mp` exist and are called with a placeholder 200/200, because the
server does not report vitals to the client yet. Wire it once it does — and until then the
placeholder is a full bar rather than an empty one, since an empty HP bar reads as "you are dead".

### 3. What is left of the old debug UI
*Chat is done.* `HudChat` builds `ifchatviewer.txt` bottom-left where `GDR_CHAT_BOARD` puts it --
the three-band `chat_window.ddj` background sliced by UV, the channel lamps, the whisper and hide
buttons, a scrollback over `GDR_LIST_CHATTING` and a real input line over `GDR_CHAT_INPUTBOX` --
and the developer ChatPanel is retired. Verified end to end: a message typed by the QA run went to
the server and came back into the window.

Still there: the Change Zone box, which has to stay until there is another way to travel. The
four other chat channels (party, guild, alliance, apprentice) are built but not fed -- the server
has one chat stream, so filtering them would only produce four empty tabs.

### 4. Panels with no server behind them
`action`, `partymatch`, `academy`, `autopotion` and `alchemy` open and draw, but there is nothing
to fill them with — no server side exists. Either build it (server lane, see
[HANDOFF_OPENSRO.md](HANDOFF_OPENSRO.md)) or make them client-side where they legitimately are
(Auto Potion is a client setting; System is Option/Help/Restart/Exit).

### 5. Minimap signs — *done for NPCs, monsters and other players*
The zone name and X/Y readout render (they were silently built as plain Controls rather than
Labels, which the empty-CIFStatic fix cured). `HudMinimap.update_signs` draws `mm_sign_npc`,
`mm_sign_monster` and `mm_sign_otherplayer` at the entities' real positions from the lists the
client already has (NPC holders per loaded region, monster and other-player bodies), on the same
tile rule that places the player (1920 units per `256 × zoom` px, world X along u, Z along v),
hidden outside the 52.5 px aperture. The client's art has **monsters red, NPCs blue**. Measured at
the Jangan spawn: `signs drawn 8 of 71 entities`, every one accounted for in the frame or under
the arrow / frame marker (see the UI rounds). Still open: `mm_sign_questnpc` and `mm_sign_party`
(nothing received yet says which NPC carries a quest or who is in the party) and the quest/party
arrows. Zoom in/out buttons are wired but untested.

### 6. World map
`GDR_WORLDMAP`, `ifworldmap.txt`, 652×424. The reference shows both a regional view with named
landmark icons and a continent view. `interface\worldmap\` holds **5,320** tiles — by far the
largest interface directory — so the art is all there. Landmark names come from
`textzonename.txt`, already parsed for the city coordinate work. **Which tile goes where, and
where a position lands on it, is now recovered** — see the end of this file and
`docs/protocol/WORLDMAP_FORMAT.md`.

## Cross-cutting, worth doing early

- **A `Theme` built at runtime from `Media.pk2`.** 8,538 files under `interface\`, with the
  `_focus`/`_press` convention mapping onto `StyleBoxTexture`. Every panel then inherits the real
  look instead of styling each one.
- **Fonts — done, recovered from the client.** There is no per-index font table: the client
  picks **one face by name** from the UI text table (`UIC_STT_FONTNAME` = **Tahoma** in the
  English column, 굴림체 in the Korean; the binary's NULL fallback at `0xe172d8` is 굴림체) and
  builds all five `FontIndex` entries from it at `(0,9) (1,8) (2,12) (3,11) (4,15)` **points**,
  `lfHeight = -MulDiv(pt, 96, 72)` → em pixels **12, 11, 16, 15, 20** (`FUN_00469350`,
  `GNFontChar::FUN_004927b0`, `FUN_00baa110`). The bundled `fonts\` files (TaeUtum, SeUtum, Arial
  Rounded MT Bold) and `vplus\vfont.ttf` (Arial) are installed with `AddFontResourceA` but none is
  Tahoma, a Windows system font. `UiBuilder` resolves in that order — text-table name → bundled
  family → the system's font of that name (family-checked, so fontconfig's DejaVu substitute is
  refused) → *disclosed* Arial from `vplus\vfont.ttf`. Reference text is aliased (one luminance
  level), so the face renders without antialiasing. Measured against `character.png` (a 1.066×
  crop): cap 9 rows / 2 descender rows / one luminance level, identical. The client also does
  **not clip** a static's text to its rect ("Phy. balance" is 63.8 px in a 58 px rect), so
  `clip_text` is off. Open: which controls use the bold (600) variant. `tools/dump_fonts.gd`
  prints the archive's answer; details in the UI rounds.
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

### The world map — the table is decoded, the window is not built
`GDR_WORLDMAP` is a `CIFWorldMap` at `100,100,652,424` on `mframe_wnd_`, and `ifworldmap.txt`
carries only three buttons: the map itself is the control's own drawing.

**`worldmap_mapinfo.txt` is now read, both sections**, from the client's own two row parsers
rather than off the header — see `docs/protocol/WORLDMAP_FORMAT.md` and
`client/scripts/worldmap/worldmap_info_reader.gd`. What that gives:

- the world map is `interface\worldmap\map\map_world_<A>x<B>.ddj`, A ascending 46…174 by 4 and
  B descending 113…73 by 4 — **363 tiles, all present in a real archive**, 33 × 128 by 11 × 128
  = the 4224 × 1408 the table declares
- `left`/`right` are region **y** and `top`/`bottom` are region **x**, settled three ways over
  (the client's transform, Jangan's own row, and the scale coming out round)
- the world-space box and the scale: **6.0 units per pixel** on the world map, **0.75** on a
  city map, so a player marker is `pixel_for_world()` and nothing more
- 33 local maps besides — cities, fortresses, the arenas, Jupiter — each with its own box, and
  25 dungeon floors, every tile of every one of them present

**The window is built** -- `client/scripts/ui/hud/hud_worldmap.gd`, opened from the minimap's
own `GDR_MINIMAP_BTN_TOG_MAP`, so no hotkey had to be invented for it. It shows the map for
wherever the player is standing and switches to the whole world on the layout's own
`GDR_WM_BTN_TO_WMAP`; the marker is `interface\minimap\mm_sign_character.ddj`, which is one of
the seven textures the client's own world map loads. Tiles are built only as they come into view.
`client/tools/qa_shot.sh --worldmap [world|both]` renders it.

**Still to do on it**:

- `GDR_WM_BTN_WNDSIZE`, left inert. The archive has a 268-wide and a 652-wide window bottom
  (`wmap_window_small_bottom` / `wmap_window_big_bottom`), so it plainly toggles two widths, but
  nothing authored says the small window's height or which controls move.
- `GDR_WM_BTN_AUTO_MOVE`, left inert: it needs a path to an arbitrary world point.
- The **other signs**. The client's world map loads `wmap_sign_party`,
  `wmap_sign_apprenticeship`, `wmap_sign_questnpc` and `wmap_sign_huntingpoint` beside the
  player marker, and each wants a list the client already receives.
- The four `wmap_window_edge_N` pieces, 4x4 apiece, which the client loads for the map area.
  Whether they are four corners or four tiled edges is **not established**, so they are not drawn.
- `wmap_sign_location.ddj` (432x36) and the `city_*.ddj` plates. The window draws its own town
  labels now -- one per local map, on the client's `wmap_name_side` + `wmap_name_middle`
  three-slice (8x24 caps, a 4x24 tiling middle), at the middle of the box that map's row gives,
  and clicking one opens that map. **The middle of the box is ours**; what is authored is the box.
  Where the client puts its own location signs is not established.
