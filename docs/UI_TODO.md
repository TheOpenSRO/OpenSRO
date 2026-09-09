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

- **Underbar** — full 800×52 background, SP gauge, numbered quickslots, page arrows, menu
  medallion, both end decorations. Verified in a render.
- **Minimap** — region art clipped to the frame's circular aperture with the client's own
  `mm_alpha.ddj` mask, compass frame, player heading arrow. Verified in a render.
- **`UiBuilder`** — buttons, statics, gauges, slots, 8-slice frames, text-table lookup, texture
  cache, and `window_def()` for the registry.

## Next up

### 1. Player mini info — the one that is always on screen
`GDR_PLAYER_MINI_INFO`, `resinfo\ifplayerminiinfo.txt`, 212×70 at the top-left, background
`ifcommon\window_all.ddj`. 53 controls, of which the ones that matter first are
`GDR_PMI_PICTURE` (portrait), `GDR_PMI_TXT_ID` (name), `GDR_PMI_TXT_LEVEL`,
`GDR_PMI_GAUGE_HP`/`GDR_PMI_TXT_HP` and `GDR_PMI_GAUGE_MP`/`GDR_PMI_TXT_MP`. The rest of the file
is the expandable character panel (`GDR_PMI_STA_CINFOBG` and the `GDR_PMI_TXT_*DAT` stat rows) and
the Hwan/jahwan decorations, which can come later.

Highest value in the lane: it is on screen permanently, it is what the reference shows first, and
it replaces the debug `Character:` label.

### 2. A generic window builder, before hand-writing any more panels
`HudMinimap` and `HudUnderbar` are bespoke classes because they have behaviour. The dozen panels
below do not need that. Add `UiBuilder.build_window(layout_path)` that reads a layout, builds its
frame, title and children, and returns a `Control` — then each panel is a table entry plus its own
data binding, not a new class.

Needed alongside it, once, shared by every panel: a title bar, a close button, drag-to-move,
show/hide, and stacking order.

**One honest gap**: nothing found so far links a registry entry to its `resinfo` file — the client
hardcodes that. Our mapping will be our own wiring, and should be commented as such rather than
presented as recovered data.

### 3. The panels, roughly in order of usefulness
Each is a layout file plus a binding to a `NetClient` system that already works. Retire the
matching tab from the debug `ActionTabs` as each lands.

| Panel | Layout | Backed by |
|---|---|---|
| Inventory | `ifinventory.txt` | `net/inventory.gd`, `net/equipment.gd` |
| Character | `ifplayerinfo.txt` | `net/character.gd` |
| Skill | `ifskill.txt` (+ `ifskill_group`, `_mastery`, `_slot`) | `net/skill.gd` |
| Chat | `ifchatmodule.txt`, `ifchatviewer.txt` | `net/chat.gd` |
| Quest | `ifquest.txt` (+ `ifquestslot`, `ifquestinfo`) | `net/quest.gd` |
| Party | `ifparty.txt`, `ifpartyslot.txt` | `net/party.gd` |
| Community (friends) | `ifcommunity.txt` | `net/friend.gd` |
| Guild | `ifguild.txt`, `ifguildmemberslot.txt` | `net/guild.gd` |
| Exchange / trade | `ifexchange.txt` | `net/trade.gd` |
| NPC shop | `if_npcwindow.txt`, `if_npctalk.txt` | `net/shop.gd` |
| Action / emotes | `ifaction.txt` | — no server side yet |
| Party Match | `ifpartymatch.txt` | — no server side yet |
| Academy | `ifapprenticeship.txt` | — no server side yet |
| Auto Potion | `ifautopotion.txt` | client-side only |
| System | Option / Help / Restart / Exit | client-side only |

### 4. The MENU popup and hotkeys
The reference's MENU button opens a list that is the real entry point to everything above, each
with its hotkey: Party (P), Party Match (E), Guild (U), Academy (L), Guardian Matching, Action (A),
Community (U), Quest (Q), Alchemy (Y), Craft, Collection book, Stall, Auto Potion (T),
System (Esc). Wire it once the panels exist, and bind the hotkeys at the same time.

### 5. Minimap text and signs
`GDR_MINIMAP_TEXT_POS_X` / `_POS_Y` / `_AREANAME` are already found and assigned in `HudMinimap`,
but have not been confirmed to render — check the font and colour before assuming they work. After
that, `interface\minimap\` has `mm_sign_npc`, `mm_sign_questnpc`, `mm_sign_monster`,
`mm_sign_otherplayer`, `mm_sign_party` and the quest/party arrows, which want the entity lists the
client already receives. Zoom in/out buttons are wired but untested.

### 6. World map
`GDR_WORLDMAP`, `ifworldmap.txt`, 652×424. The reference shows both a regional view with named
landmark icons and a continent view. `interface\worldmap\` holds **5,320** tiles — by far the
largest interface directory — so the art is all there. Landmark names come from
`textzonename.txt`, already parsed for the city coordinate work.

### 7. Retire the debug UI
The developer UI (chat box, Log Out, Change Zone, corner labels, ten-tab `ActionTabs`) still draws
over the real HUD and overlaps the underbar. It cannot simply be deleted — those tabs are the only
way to reach inventory, skills, shop, party, guild, trade and friends — so drop each tab as its
real window lands, and keep Change Zone somewhere until there is another way to travel.

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
