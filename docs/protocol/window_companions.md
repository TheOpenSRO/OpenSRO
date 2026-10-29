# The windows that open alongside an operation (round 841, lane W)

The census of every place sro_client.exe opens the **inventory** (the main popup's inventory tab) or
the **COS window** (the pet / transport window, whose Inventory page is the pet or transport bag)
as a side effect of something else, and every place that closes or restores them. Labels: **READ**
(sro_client.exe, `c:` addresses, the box's decomp dump `/var/tmp/decomp_client` and linear
`/var/tmp/sro_client.asm`), **MEASURED** (a live run), **INFERRED**, **OURS** (this client's own
choice), **OPEN**.

## 0. How the census was taken (READ)

- **The inventory.** The main popup is CGInterface `+0x728` (GDR_MAINPOPUP, ID 0x19). Its inventory
  tab is selected only by `0x6a1f70(0x46)` (CIFMainPopup's tab selector, round 587). Every call of
  `0x6a1f70` was listed from the asm (31 sites): 0x46 is pushed only by
  - `0x79af20` (below),
  - the I key's toggle `0x79b020`,
  - the equipment toggle `0x79ad70`,
  - the store / storage open `0x79dbd0` (two sites),
  - the exchange open `0x79df10`,
  - CIFMainPopup's own tab buttons (`0x6a2500`, hidden at create, round 587).

  The popup is shown only through its slot 23 (`+0x5c`): every reader of `+0x728` was listed (the key
  toggles 0x79ace0..0x79b0b0, 0x79af20 / 0x79af70 / 0x79afd0, Escape 0x79d620, 0x79dbd0, 0x79df10,
  0x7992c0, CGInterface::Create, 0x78d050), and every caller of the getter `0x798d00` that calls
  `+0x5c` within the next instructions (six: the skill and character tabs only). No caller of
  `0x798d00` or reader of `+0x728` writes the visible flag directly (`0xb8f500`). No absolute
  pointer to 0x79af20, 0x79b020, 0x79ad70, 0x79bcd0, 0x79dbd0, 0x79df10 or 0x7a0980 exists in the
  image (a byte search of the exe), so the direct calls are all of them.
- **The COS window.** GDR_COS_WND (ID 0x78) is created, shown and destroyed only by `0x79bcd0(show,
  cos, page)`. Its seven callers: `0x7a0980` case 0 (three sites, all opens; page 1 for a pick pet
  `0x99dd80` or a transport `0x99dda0`, else page 0) and four that close (0, 0, 0). `0x7a0980(0)` is
  the COS manager's command 0 on the current COS: **a toggle** -- the window closed when it exists
  (`0x799350` = window 0x78, c:0x7a0a45..0x7a0a5d), else opened.
- **The interaction lock.** CGInterface `+0x4fc` is a set the 0xB046 handler (`c:0x888e30`) fills:
  the opened id, and 0xd / 0xb when the talk NPC has them (`0x787bd0`, its debug line "Lock : %d");
  `0x77e6f0` empties it. `0x676390(id)` is its membership test.

## 1. The census

"Before" is OpenSRO at dev ff0ec68e (v0.1.604); "now" is this round.

| # | Trigger | Window | The original (READ) | OpenSRO before | OpenSRO now |
|---|---|---|---|---|---|
| 1 | The store opened, lock 1 (0xB046 {1, 1}: every NPC store, the stable's with 0xb) | inventory | `0x79dbd0(0, 1)`: the popup **hidden first** (`0x7992c0`, c:0x79dc1c, silent), then `0x676390(1)`: ShowWindow(1), `0x6a1f70(0x46)` (c:0x79dc89), raised; the store shown, titled by the NPC, moved to its own position (`0xb8f460` -> `+0x9c`), raised last; the helper on the store (snd_window_open) | opened beside the store (side by side, OURS) | unchanged |
| 2 | The store opened, lock 0xc (0xB046 {1, 0xc}: the specialty traders' stores, NPC_TD_THIEF_BUY) | **the transport's COS window**, not the inventory | `0x79dbd0(0, 1)`: the popup hidden (`0x7992c0`) and **not shown again**; `0x676390(0xc)` -> `0x811130(1)` on GDR_COS_MANAGER (0x27): the current COS when it is a transport (`+0x14` == 1), else, with two or more out, the first transport in summon order made current (`0x810fd0`); then `0x811310(0, 0xff)` -> `0x7a0980(0)`: the COS window **toggled** -- opened on its Inventory page (`0x79bcd0(1, cos, 1)`: the saved position, else centred), or closed (position saved) when it was open. No transport: nothing opens. Then the store as in row 1 | opened the inventory (wrong) | built: the bag hidden, the transport made current, its window toggled (`HudCos.specialty_store_opened`) |
| 3 | The storage (0xB046 {1, 3}) | inventory | `0x79dbd0(5, 1)`: the popup hidden, then ShowWindow(1), `0x6a1f70(0x46)` (c:0x79dd2d), raised; the storage (0x13) shown, moved to its own position, raised; the helper on it | opened beside it | unchanged |
| 4 | The exchange opens (0x3085 c:0x880330, 0xB081 c:0x8803f0) | inventory | `0x79df10(1)`: the exchange shown; ShowWindow(1), `0x6a1f70(0x46)` (c:0x79df51), raised; the exchange raised and put at its own position; `CIFExchange::vslot_023` destroys the alchemy window first (round 834) | opened | unchanged |
| 5 | The exchange ends (0x3087 c:0x88be20, Storage_OnItemExchangeResult c:0x8808c8) | -- | `0x79df10(0)`: the exchange hidden; **the inventory stays** | stayed | unchanged |
| 6 | The alchemy window (Y, the underbar's item 114: `0x798e20(1)` -> `nifenchantwnd.2dt`) | inventory | its OnCreate `FUN_00592540` ends in `0x79af20` (c:0x592635). Its close `0x798e20(0)` destroys only itself | opened | unchanged (now through `inventory_companion`) |
| 7 | The grant window (0xB046 {1, 0x20}, the blacksmith's avatar line) | inventory | `0x79d4a0(1)`, then `0x79af20` (c:0x888fff): the helper on the popup sounds snd_window_open. Its close `0x79d4a0(0)` leaves the inventory | opened, **silently** | opened with the helper's snd_window_open |
| 8 | **The stall window shown**: the owner's 0xB0B1 {1} (c:0x872040) and a visitor's 0xB0B3 {1} (c:0x873ff0) | inventory | `CIFStall::vslot_023(1)` (c:0x6b9730): the alchemy window destroyed if it exists (`0x799580` = the .2dt window 0xa8 -> `0x798e20(0)`), then `0x79af20` (c:0x6b9780) -- the popup raised over the stall (the stall's own show, CIFWnd `0x652b70`, raises nothing) | **not opened** | built (`HudPanels.open_stall_window`) |
| 9 | The stall window hidden (0xB0B2, 0xB0B5, 0x30B9, the X, Escape) | -- | `CIFStall::vslot_023(0)`: `0x6b3f40(1)` on the inventory pane (every bag cell enabled again); **the inventory stays** | stayed (the bag redrawn) | unchanged |
| 10 | Gori's exchange (talk item 0x28, interaction 0x12, a 3/3/14/2 coupon in the bag) | inventory | `CIF_NPCTalk::FUN_007020c0` case 0x28: `0x745ab0` (the bag holds a coupon), then `0x79af20` (c:0x703336), then 0x7119 | **not opened** | built (`World3D._gacha_exchange`) |
| 11 | The fortress smith's repair (talk item 0x36, interaction 0x1a NPC_*_FORTRESS_SMITH, choice 2) | inventory | `IF_NPCTalk::FUN_006ff8d0`: the store closed if it exists (`0x7997d0` -> `0x79ce40(0, 0)`), `0x79af20` (c:0x6fff15), then the repairable worn and bag items counted (`0x6abd50`, `0x6b6050`): none -> UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR, else the repair box (`0x77f0a0` kind 0xc) | no fortresses | **OPEN** (no fortress system) |
| 12 | The guild storage (0xB250 {1}, Guild_OnWarehouseUseResult c:0x88f630) | inventory | `0x79bf40(1)` (GDR_GUILDSTORAGEROOM 0x91), `0x6aefa0` on the inventory pane, `0x79af20` (c:0x88f6b1), `+0x7b6` set, the NPC kept at the window's `+0x7c8` | no guild storage | **OPEN** (FEATURES "Guild storage: Not yet") |
| 13 | CIFAlchemyBox::Create (GDR_ALCHEMYBOX, ID 0x2c, `ifnewalchemybox.txt`) | inventory | ends in `0x79af20` (c:0x722ba8) unconditionally | -- | none: INFERRED unreachable -- its section "AlchemyBox" is in no string of the image except as the tail of the class name "CIFAlchemyBox" (`0xdb2834`, pushed only by the class factory's registration c:0xd6f676), and no code creates window 0x2c (its getter `0x799590` only reads) |
| 14 | The I key, the underbar's inventory item | inventory | `0x79b020` (callers: the key dispatcher c:0x78084f, the underbar menu c:0x60cd69): a toggle | built | unchanged |
| 15 | The equipment toggle `0x79ad70` | inventory | no caller | -- | -- |
| 16 | The pet / transport status icon, its menu, a COS command on a quick slot, the COS key | COS window | `0x7a0980(0)` (c:0x7a8b3b CIFCOSStatus::vslot_033, c:0x7a25ab, c:0x60bb25 / c:0x68ce09 / c:0x68217d, c:0x7808ca): the toggle -- a player's own command, not an operation's companion | built (round 795) | unchanged |
| 17 | The specialty store closed (`0x79dbd0(0, 0)` -> `0x6d4670`) | -- | with lock 0xc or 0xd held: the transport's Sell All refreshed (`0x79f870` / `0x7a7970`); **the COS window stays** | stayed | unchanged |
| 18 | Every other window: the stall network (`0x799020`), the item mall (0x32 / 0xa7), Magic POP (`0x79c060`), the open market (`0x799170`), the trade info window (`0x79e510`), party matching, auto potion, the quest windows, item use | -- | none of them reaches any opener above (the enumeration in section 0 is every path) | -- | -- |

## 2. Placement, the player's state, Escape (READ unless marked)

- **Where.** The original never places the inventory relative to the operation's window: the tab
  selector puts the popup at x = screen width - 388 - 0x50, keeping its y (262, or where the player
  dragged it), every time a tab is selected -- an I press included (round 587). The operation's
  window is put back at its own position (`0xb8f460` -> `+0x9c`). The COS window opens at its
  saved position, else centred (`0x79ac50`).
  - OURS, kept from rounds 513 / 593: the store and the storage sit left of the centre with the bag
    right of it.
  - OURS, new: at the specialty store the transport's window takes the bag's place right of the
    centre while it has no saved position. The original's centre would sit under this client's
    store. A position the player saved (any close saves it) is used as the original does.
- **Opened only if closed?** `0x79af20` always shows and raises the popup; it selects the inventory
  tab only when the inventory pane is not already showing. The helper sounds snd_window_open even
  when the popup was up. The COS window's command 0 is a toggle. The specialty store's pre-hide
  hides a bag the player had open.
- **The tab and page.** ShowWindow(1) re-selects the popup's current tab, then the inventory tab is
  selected (a skill tab, say, gives way to it). The bag's own page is not touched.
- **No pet.** Only a transport (kind 1) is considered (`0x811130(1)`). A pick pet's bag is never
  opened by an operation. With no transport out nothing opens; OpenSRO's server refuses the
  specialty store without one anyway (MEASURED, round 801: "NPC open refused, code 0x4").
- **Keyboard focus.** None of these paths touches the focus. A text line keeps the keyboard
  (MEASURED in `window_companions_test.gd`).
- **Escape** (`0x79d620`, the part that matters here): the storage under `+0x7b4`, the guild
  storage, the NPC window, **GDR_STALL** (its vslot_043, the X: the owner's 0x70B2, a visitor's
  0x70B5), GDR_EXCHANGE, GDR_COMMUNITY, the alchemy window, **the main popup**, **the COS window**
  (`0x799140(0x78)` -> `0x79bcd0(0, 0, 0)`), then the rest.
  - Before this round OpenSRO's Escape only hid a stall window, which left the stall open on the
    server.
  - The COS window was not in OpenSRO's Escape list.
  - Both are fixed: the stall's X sits between the NPC window and the exchange, and the COS window
    closes once none of HudPanels' windows is left (OURS: after this client's own topmost rule).

## 3. OPEN

- Rows 11 and 12: the fortress smith's repair and the guild storage, for want of the systems.
- The COS window's own open and close sounds (`0x79bcd0` ends in the helper 0x79a7e0): this client's
  COS window is silent (round 795), for the status icon too.
- The stall window shown while the alchemy window exists cannot happen through OpenSRO's own paths:
  the Stall action and a click on a booth both refuse while it is open ("Cannot enter a shop while
  conducting alchemy."). The close in row 8 is built and unit-tested, not seen live.
- A side finding, not in this round's scope: the talk box's link takes no click whose press comes
  in the same frame as the hover it starts. The hover re-renders the label, which the press then
  misses (MEASURED with pushed input at the blacksmith's first line). A hand moves before it
  clicks, so the QA step `talkline` hovers first.

## 4. Where it is built

- `client/scripts/ui/hud/hud_panels.gd`: `inventory_companion` (0x79af20); `open_shop`'s lock
  branch; `open_stall_window`; `_escape_close`; `hud_cos`, `specialty_lock`; `qa_talk_line_point`.
- `client/scripts/ui/hud/hud_cos.gd`: `specialty_store_opened` (0x811130 / 0x7a0980(0));
  `escape_close_window`.
- `client/scripts/ui/hud/hud_cos_window.gd`: `open_for`'s placement with no saved position.
- `client/scripts/world/specialty_flow.gd`: the lock (`store_npc != 0`).
- `client/scripts/World3D.gd`: Gori's exchange; the wiring; the QA steps `npcclick:<code>` and
  `talkline:<n>`.
- Tests: `client/scripts/ui/hud/window_companions_test.gd`.
