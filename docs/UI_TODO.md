# UI: what's left

The ordered list of client UI work, in the same spirit as [TODO.md](TODO.md): what is known, what
is not, and the next concrete step. Visual target is the reference set catalogued in
[reference/ui/README.md](reference/ui/README.md).

Read [HANDOFF_UI.md](HANDOFF_UI.md) first if you are new to this lane.

## The recipe (established — do not re-derive)

Every window in the real client is authored data, and building one is now mechanical:

1. **`resinfo\ginterface.txt` is the top-level window registry.** For a *HUD-anchored* window it
   gives the background artwork and the screen rect — `GDR_UNDERBAR` → `ub_window_01.ddj`,
   `112,684,800,52` (but its class `CIFUnderBar` draws nothing: the bar players see is the `.2dt`
   `CNIFUnderMenuBar`, round 598 -- check the class renders before building a registry entry);
   `GDR_MINIMAP` → `mm_window.ddj`, `892,6,140,184`; `GDR_PLAYER_MINI_INFO` →
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
7. **Some panel windows are self-framed.** Quest, guild, community, alchemy, the NPC talk box, the
   store and the teleport board are framed by this client from their own layout. That is not
   because the registry lacks them: GDR_COMMUNITY, GDR_ALCHEMYBOX, GDR_STORE and GDR_NPCWINDOW
   are in `ginterface.txt` and are not used, each for the reason round 586 records. Guild and the
   teleport board have no entry, and quest's class is a main-popup pane. Their own layout file
   carries a `CIFFrame` / `CIFStretchWnd` whose `ddj` is an
   8-slice base ending in `_` (`interface\frame\mframe_wnd_`, `interface\messagebox\
   msgbox2_window_`), expanded as `_left_up`, `_mid_up`, `_right_up`, `_left_side`, `_right_side`,
   `_left_down`, `_mid_down`, `_right_down`. `UiBuilder._build_frame` already does this.
   **Each piece is drawn at its own size**: corners at their own width and height, and each edge
   at its own thickness, tiled across the gap between the corners it meets (CNIFFrame's
   `FUN_00474d00` / `FUN_004736a0`, round 584). The pieces of one set are often not the same size:
   `sframe_wnd_` has a 36 top and 16 bottom, `mframe_wnd_` 68/48, and `game_window_` 42 corners
   with 8 edges. Never size one piece from another.
   **Inventory, equipment, character, skill, action, party and academy are not self-framed**
   (round 587): they are panes of the registry's `GDR_MAINPOPUP` (a CIFMainPopup, 388x408 on
   `mframe_wnd_`), each at its `ifmainpopup.txt` rect with its own layout at the pane's origin, and
   the keys select its tabs (`HudMainPopup`).
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
   **Caveat (round 586):** the exe never loads `ifalchemybox.txt` (the string is in neither
   encoding; its alchemy box reads `ifnewalchemybox.txt`), so these numbers stand only for the
   self-framed windows, until item 2 of the audit list reads theirs. A **registry-framed** window
   (a `CIFMainFrame` in `ginterface.txt`) takes CIFMainFrame's own chrome from `0x816f80`: caption
   `(10, 12, width-21, 12)` top-aligned, drag `(10, 0, width-21, 34)`, close `(width-26, 10)`.
   Its layout's origin is the window's (the factory adds the parent's position, `0xba223e`).
13. **A window is its frame plus any artwork hanging off it**, not the bounding box of every
   control. ifinventory's gold row sits 25 pixels below the frame; ifplayerinfo's `TEXT_HP_DAT` is
   a text field that overruns the right edge by 17 and must not widen the window.
   Art with a zero-size rect counts at its natural size (rule 4), which is how it is drawn. A
   control parked at `x = 9999` does not count: ifexchange has 13, and nothing else in the
   archive goes past x = 864 (`UiBuilder.is_parked`, round 584).
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
   `EXTRA_SECTIONS` lists only the ones that have been established. When the binary is silent,
   `sweep_section_overlap.gd` settles it from the geometry: sections that compose have controls
   that are **pairwise 0%** overlapping, and a section covering another's controls is an
   alternate. Validated against ifskill, where the binary gives the answer independently.
   (ifguild, the example this rule was found on, turned out never to be loaded: see rule 21.)
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
   the layout asked for, never `node.size`, which is already clamped. **Anything that builds a
   section calls `UiBuilder.settle_authored_rects(root)`**, which re-applies the rects for the
   first few frames in the tree (round 585). The HUD widgets that did not are why their labels
   stayed 23 tall. A Label still stops at its own font's line height.

21. **The newer windows are not `.txt` layouts at all.** 42 `res_ui\*.2dt` files in Media.pk2 build
   the client's `CNIF*` windows -- guild and community, quest list, enchant, world-map guide,
   option, the menu bar, open market, stall network. `TwoDtReader` / `TwoDtBuilder` read and build
   them (`docs/protocol/2DT_FORMAT.md`). Three differences from the `.txt` recipe matter:
   **children are added in file order** (back to front, the opposite of rule 9), **ids repeat
   within a file** so a control is found by its parent path (GetChild searches direct children
   only), and **the sample text in each record is never drawn**. Before building a window from a
   `.txt` layout, check the exe names that layout: `ifcommunity.txt`, `ifguild.txt`,
   `ifplayerinfo.txt` (the live one is `ifplayerinfo_trijob2.txt`), `ifteleportboard.txt`,
   `ifteleportareaslot.txt`, `ifunderbar.txt` and `iftargetwindowex.txt` are not in it.

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
- **Underbar** — *superseded (round 598, below)*: the 800×52 `ifunderbar.txt` bar is gone; the
  bar is the client's own `CNIFUnderMenuBar` from `nifundermenubar.2dt`.
- **Minimap** — region art clipped to the frame's circular aperture with the client's own
  `mm_alpha.ddj` mask, compass frame, player heading arrow. Verified in a render.
- **`UiBuilder`** — buttons, statics, gauges, slots, tiles, lattices, close buttons, 8-slice and
  6-piece frames, text-table lookup, texture cache, and `window_def()` for the registry.
- **Window interiors and item grids** (hundred-and-thirteenth round) — panels are no longer
  hollow and the inventory draws its real 4×8 grid of authored slots.
- **Frames and window sizes measured, not assumed** (round 584) -- every frame piece is drawn at
  its own texture's size and never clamped up to it. Windows count the art they draw and skip
  parked controls. Party and academy are now 364x363, alchemy 357x207, guild 594x314 and
  Exchange 245x352 (it was 10344 wide and centred off-screen at x=-4222).
- **One control of each authored alternate, settled HUD text, one underbar and minimap** (round
  585) -- the audit's section alternates, HUD settle and double setup, done. Each same-rect
  group's default was read from its class in the binary, as `docs/RE_COMPLETION.md` records.
  The equipment window opens on its worn slots, and its change buttons flip to the avatar slots.
  The academy's portrait, alchemy's Cancel and the chat's four other channel lists are hidden,
  and the chat reads `UI_UPDATE_2009_FIRST`. Every widget that builds a section settles through
  `UiBuilder.settle_authored_rects`. The underbar and minimap build once.
- **Registry windows open inside their registry frame** (round 586) -- the audit's outer
  registry frame, done. Storage (254x317), exchange (254x361), system (214x212), party match
  (785x480), auto potion (394x520) and help (420x452) draw their `mframe_wnd_` entry from
  `resinfo\ginterface.txt`, with the layout at the window's origin. Their caption, drag strip and
  close button are CIFMainFrame's, read from `0x816f80`: caption `(10, 12, width-21, 12)`,
  top-aligned; drag `(10, 0, width-21, 34)`; close `(width-26, 10)`. The world map shares the
  path (`HudWindow._add_registry_frame`, `HudPanels.REGISTRY_FRAMES`). System is restacked the
  way `CIFSystemWnd::Create` does it. Community, store and alchemy stay unframed, each for the
  reason `docs/RE_COMPLETION.md` records. **Still open from the same audit, in order:**
  1. ~~Community and guild are not the client's windows.~~ **Done (round 595, below).**
  2. The non-registry outer frame -- **done for seven of the eight classes (round 587).**
     CIFInventory, CIFEquipment, CIFPlayerInfo, CIFSkill, CIFAction, CIFParty and
     CIFApprenticeShip are panes of `GDR_MAINPOPUP` and now open inside it, with CIFMainFrame's
     chrome. CIFQuest is a pane too, but nothing reachable shows it (its tab button is hidden at
     create, and Q opens the `res_ui\questlist.2dt` window), so the quest panel keeps the
     `ifalchemybox.txt` chrome until that window is built. Still open from this item: guild's
     594-wide window blocks clicks over a see-through area below its 588-wide header and right of
     the 440-wide body (x 446 to 594, y 112 to 314) -- gone with that layout (round 595).
  3. Inventory docking -- **done (round 587).** `dock_companion` is gone. The bag and the
     equipment are the popup's inventory tab, at (13, 63) and (198, 41), with the popup's tile
     in the 9-pixel gap between them (`0x6a1f70`).

  Found on the way, not yet fixed:
  - The main popup has no fallback: an archive without `ifmainpopup.txt` or GDR_MAINPOPUP leaves
    all six of its panels unavailable (round 591). Its placement is clamped into the viewport, our
    deviation (round 591).
  - The paper doll keeps its chosen rect (40, 46, 98, 236) in the equipment pane. The client's
    model viewport is read, (2, 15, 176, 318) in the pane (`CIFEquipment::vslot_013`), but its
    camera is not (round 587).
  - A CIFSubFrame's own Text (the party's UIIT_STT_PARTY_INFO, the action subframes' titles) is not
    drawn, and `CIFCheckBox` has no builder (trijob2's two stat-row check boxes). Round 587.
  - The storage and bag gold amounts go into the "Gold" unit labels (`STA_GOLD`), not
    `STA_MONEY`.
  - `ClientRect` text insets are ignored.
  - ifexchange's `APPLY_EXCHANGE_UPDATE_1TH` / `UI_UPDATE_2009_FIRST` branches are evidenced but
    not selected.
  - A missing extra section builds "Create" twice (`LayoutDef.get_section`'s fallback).
  - The chat's channel lamps: `CIFChatViewer`'s Create shows lamp 20 and hides lamps 21, 22, 23
    and 31 (`0x7abfb0`..`0x7ac03c`); we still show all five (review of round 585).
  - `GDR_CHAT_INPUTBOX` is a LineEdit held 31 tall by the theme's minimum against its authored
    20, so it hangs past the chat's bottom (398). Predates round 585.
  - ~~HudTarget's `GDR_TW_CLOSE` is re-parented outside every settled root.~~ Settled since round
    588, which also builds the target window from `iftargetwindow.txt`, the layout
    `CIFTargetWindow::Create` loads (with UI_UPDATE_2009_FIRST: 236-wide pieces).
  - ~~The target window's rarity rule is contradicted by the asm (round 588).~~ Fixed in round 589:
    a monster (CICMonster) shows the special-mob window for rarity 0, 1 and 3-8 and no piece for 2,
    with the rank row and `Lv %d` filled (0x69b4c0), and placed where the client places it,
    ((screen width − piece width) >> 1, 7) (0x69a161, round 590); its close button, gauge and rank
    rows as the class code moves them (round 592). Still open: the party suffix and the party
    re-centring of the rank row, and `GDR_TWSM_TEXT_LEV`'s authored 168 width reaching x 273 in the
    236-wide piece (round 593).
  - The store's registry height (317 / 360 / 370) turns on `RENEWAL_SHOP_SYSTEM` and
    `RESTORE_SOLDITEM_INSHOP`, which are unreadable. With our `[]` choice, Repair sits at y
    332-356, below a 317 frame.
  - Alchemy is a `CIFAlchemyBox` (a `CIFWnd` on `alcm_window_1.ddj`, from
    `ifnewalchemybox.txt`) holding `CIFAlchemyProcess` at 0,150. That assembly is not built.
  - The NPC talk box (`CIF_NPCTalk : CIFFrame`) and `GDR_NPCWINDOW` (`CIF_NPCWindow :
    CIFMainFrame`, 386x451, `if_npcwindow.txt`) are separate classes, and how they compose is
    not read.
  - Registry screen positions (GDR_SYSTEM 300,200, GDR_EXCHANGE 200,200, ...) are not used;
    windows are still centred.
- **The Guild / Community window is the client's own** (round 595) -- `CNIFGuildWnd`, built from
  `res_ui\guild.2dt`, `guild_r.2dt`, `guild_w.2dt`, `cumunity_friend.2dt`, `cumunity_cut.2dt`
  and `cumunity_note.2dt` the way `0x5b57c0` and `0x58ec70` assemble them (`GuildWindow`): one
  621x434 CNIFMainFrame with CNIFMainFrame's chrome (`0x479a50`), the relations and war panes
  on the info pane at (11, 63), and the community window laid over the guild window, its tabs
  on the guild's (23/100/176, 41, 72x24). Caption `UIIT_STT_GUILDVIEW` / `UIIT_STT_COMMUNITY`.
  **U** opens the guild view (the retail default, `0x7778be` slot 6 -> `0x5b4980`); the
  underbar's community button the community view (`0x5b49c0`); both toggle. **G** keeps
  opening the guild view as this project's own binding (retail G reaches `0x793b00(0x64,
  0x3f0)`, not established). Tabs switch panes as `0x47a240` does, and the OnCreates' hides and
  checks are applied **in the client's order, last record first** (docs/RE_COMPLETION.md). On
  every show the window runs the client's show path (`0x5bb150`): the command buttons shown and
  disabled, the empty member rows cleared, the no-guild information (`UIIT_STT_NO_GUILD`), and
  the window centred on the screen (`0x798c50`; kept inside the view, ours). The friend list
  fills the friend rows and the count (": n / 20") the way `0x5a85c0` / `0x5a97b0` do, from
  creation on, and empty block rows are cleared (`0x586130`). The dead `ifcommunity.txt` /
  `ifguild.txt` builds are gone.
  **Correction to round 585:** the community's show routine does not select its first tab --
  `0x58ec40` tells the *guild* window to show or hide its own panes, and only the guild's tabs
  are re-checked; the community's tabs are set once, in its OnCreate. And U is the guild, not
  the community. Still open on this window: guild members, notice, points and the relations /
  war lists are not filled (guild_info is still requested on open and handled by World3D);
  the alliance pane's own refresh `0x57c6f0` (about 40 show/hide calls on the player's
  alliance state) is not run; the scroll bars, the letter pane's edit boxes and the grant
  window's check boxes are built without their classes' own art or behaviour; the style bits
  set on 66, 115, 121 and 400..403 are not applied; the draw loop, the alignment values and
  how an off-size static is drawn are not read; a guild member's information, rights (which
  command buttons the client enables) and member rows are not drawn -- a member now sees the
  guild's name and master (round 597), but not its level, member count over the cap, points or
  notice: guild_info carries the member list but no level (which the cap needs), points or
  notice. No test covers the letter pane's 900 move to (17, 32); it is applied but hidden. **Buttons with no
  behaviour yet** (built, drawn, inert; named by their art or caption, what each does is not
  read): guild view -- 86 (`gil_shape01`), 23 (`stl_condition`), 81 (`stl_edit_button`,
  disabled as the client disables it), 400..403 (the column buttons captioned Member / Level /
  Level / Donate GP), 250 (`com_donation_button`); community view -- 255
  (`gil_subj_button05`), 39 / 40 / 41 (captioned Whisper / Add friend / Delete friend), 62
  (captioned Friends list). By their text keys and art (all `com_mid_button02` unless named):
  war pane 548 -- 247 (`gil_subj_button06`, UIIT_STT_WARCONTRIBUTION_RANKING), 248
  (`gil_subj_button09`, UIIT_MSG_LETTERERR_GUILD), 63 (`gil_subj_button09`,
  UIIT_STT_WARCONTRIBUTION_POINT); relations, hostile pane 164 -> 2000 -- 52
  (UIIT_CTL_GUILDWAR_DECLAREWAR), 53 (UIIT_CTL_GUILDWAR_WARCONCLUSION), 60 (`gil_subj_button03`,
  UIIT_STT_LEVEL_LV), 56 (`gil_subj_button09`, UIIT_CTL_GUILD_NAME); relations, alliance pane
  164 -> 86 -- 51 / 52 / 53 (UIIT_STT_GUILD_RESPECT_ALLY_JOIN / _EXIT / _EXPULSION), 60, 56 (as
  in 2000); block pane 59 -- 255 (`gil_subj_button05`), 40 (UIIT_STT_BLOCKMAN_ENTRY), 41
  (UIIT_STT_BLOCKMAN_CANCEL); letter pane 700 -- 55 (UIIT_CTL_LETTER_SEND), 40
  (UIIT_STT_LETTER_READ), 41 (UIIT_CTL_LETTER_DELETE), 56 (UIIT_CTL_LETTERERR_GUILD), 57
  (UIIT_CTL_LETTERERR_UNION), 113 (`gil_subj_button09`, UIIT_STT_LETTER_ADDTIME), 114
  (`gil_subj_button13`, UIIT_STT_LETTER_SENDER); and, in the letter's hidden write frame 800 and
  multi-letter window 900, 100, 200, 118, 119, 120 and 115.
  The command buttons 37..41 are disabled as the client disables them for a player with no
  guild.
- **The teleport board** (round 578) — the Dimensional Teleporter, `resinfo\ifteleportboard.txt`,
  built by the recipe: `HudPanels.PANELS["teleport"]`, and its five `CIFTeleportAreaSlot` rows
  (`GDR_TB_TASLOT1..5`) filled from `resinfo\ifteleportareaslot.txt`'s own section (place, price,
  Move) the way CIFSkillBoard's rows are code-built (`TeleportBoard`), `GDR_TB_SPIN_PAGE` paging
  five at a time. Opened by a gate's 'Select teleport area' line; the destinations and fees come
  from the client's own teleportlink rows; the board and the talk box close on a zone change, not
  on walking away (the interaction range is unread). Not wired, disclosed: the window art
  (`tpt_window_zangan.ddj`, its use unread — the layout has no frame, so the board has no backdrop),
  the slot icons, the Move button's art (its layout names none). `docs/RE_COMPLETION.md` round 578.

### Tools for this lane
`client/tools/dump_layout.gd` prints one layout in declaration order with every rect, alignment
and font index. `dump_window_tree.gd` builds a real `HudWindow` and prints the resulting nodes
with their rects, textures and minimum sizes — use it instead of squinting at a render.
`grep_layouts.gd` searches all 248 layouts by control name, type or artwork path, which is how
the lattice pitch, the close-button convention and the tile fill were each settled.

## Next up

### 0. The other `.2dt` windows, in order
The reader and builder exist (rule 21); each of these is now a build from the client's own data,
like the guild window:

1. ~~**The underbar**~~ **Done (round 598).** `HudUnderbar` builds `CNIFUnderMenuBar` from
   `res_ui\nifundermenubar.2dt` (800x68, bottom-centred and flush, `0x7871dc`), with its
   OnCreate state (`0x60df30`, run after the menu buttons' own: OnCreates go in reverse file
   order), its readouts (`0x60b440`: level, EXP in tenths across ten gauges, SP), 51 quick slots
   (the "m" slot 0 on the middle button, four pages of ten on F1..F4 and the number keys), and
   its own menu 59 (items to panels as `0x60cd10` routes them, key-filled captions `0x60d5f0`,
   fitted and right-aligned `0x60afe0`). **One bar**: `CIFUnderBar` is still created from
   ginterface.txt but its Create loads nothing and its render and ShowWindow are empty
   (`0x68d980`, `0x68c850`); the `ifunderbar.txt` build is removed. The chat now sits on the bar
   at x 2 (`0x78726e`). Open: the slot arrow's flash, the server-side quick-slot save / restore,
   a new character's default slots, drag-off and slot-to-slot moves, the mall / academy
   matching / collection / stall items (no windows here), the key for command 0x58.
   `docs/RE_COMPLETION.md` has the record.
2. **Q -> `questlist.2dt`** (`CNIFQuest`, window 0x4c): Q reaches `0x7990e0`, which toggles it.
   We build `ifquest.txt`, a live layout but not the window Q opens.
3. **M -> `worldmapguide.2dt`** (`CNIFWorldMapGuide`, id 28): M reaches `0x79abe0`, which loads
   and centres it (`0x798c50`). We build `ifworldmap.txt`.
4. **Y -> `nifenchantwnd.2dt`** (`CNIFEnchantWnd` / `CNIFAlchemyWnd`, id 168): Y reaches
   `0x798e20`, which loads or destroys it. We build `ifalchemyprocess.txt`.
5. **The teleport board's live source**: `ifteleportboard.txt` and `ifteleportareaslot.txt` are
   not in the exe, and which window the client shows is **not established**.

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

- ~~**Which authored coordinate belongs at the screen centre vertically.**~~ Read (round 598):
  the bar is placed at `((W - 800) / 2, H - 68)` by `0x786f30`, and the chat at
  `(2, H - 68 - chat_h)`.
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
