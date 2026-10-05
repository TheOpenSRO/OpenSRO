# NPC GUI: the talk window, the store, the storage, their confirm boxes, and how they chain

Round 724, a spec round: documentation only, no behaviour change. The user (2026-10-05): "Now let's fix
the NPC GUIs. This has also been a long standing problem. … when you open a window with an npc that
opens another window the previous one should usually close too … There might be exceptions to this but
reference of the game code. Make sure you make everything as accurate as possible including the
confirmation windows and make no mistakes."

**Sources.**
- The client exe `sro_client.exe` (`/opt/sro-files/client` on the render box), its decompile
  `/var/tmp/decomp_client` and asm `/var/tmp/sro_client.asm`. Decompile excerpts this round used are
  kept in `/var/tmp/r724/` on the box (code only, no game data).
- The archive Media.pk2: `config\define.txt`, `resinfo\ginterface.txt`, `if_npcwindow.txt`,
  `if_npctalk.txt`, `ifstore.txt`, `ifstorageroom.txt` and `ifmessagebox.txt`, plus
  `server_dep\silkroad\textdata\textuisystem.txt`. All were extracted transiently and deleted.
- Existing records this builds on:
  - `docs/protocol/message_box.md` (round 631: every store and storage box, read);
  - `docs/protocol/character_state.md` "An NPC interaction, end to end" (round 454: the interaction
    ids);
  - `docs/UI_TODO.md`, the registry frames and the NPC window notes.
- The user's screenshots, in `/root/opensro-handoff/npc_refs/`:
  - ours: `rb5gAPe.jpeg`;
  - the original: `tcHCl0v.png` (herbalist talk), `1llywhJ.png` and `hWWsCP0.png` (gate talk, and
    its list), `3Gw7Ene.png` (store and buy box), `MKtR5Kd.png` (storage and deposit box).

  They come from a private server's client, so they show the look, not numbers.

**Labels:** READ (from the exe or a layout, with the address or file), MEASURED, INFERRED, OPEN, OURS.
No game data is in this file. English strings are quoted short, as the other protocol docs do.

## 0. The `#ifdef` defines are data: `config\define.txt` (closes several OPEN items)

**READ.** At start-up `CGame` opens `config\define.txt` through the archive reader: `push 0xdd3d60`
("config\define.txt") at `0x848210`, then the reader's slots `+0x2c`/`+0x8c`/`+0x48`. For each name in
it, the client logs "`%s Value 0 => 1`" (format at `0xdd3d50`) and sets the name's value through
`0x6441b0`.

The file defines:

```
WHISPER_BLOCKING_SYSTEM, ITEM_MALL_ADD_TABS, HISTORY_FOR_BUYING_SILK, RENEWAL_SHOP_SYSTEM,
EUROPE_SYSTEM, RESTORE_SOLDITEM_INSHOP, APPLY_MENTOR_SYSTEM, APPLY_AVATAR_SYSTEM,
IMAGE_BASED_USER_VALIDATION, PET_SKILL_ITEM, APPLY_SIEGE_FORTRESS_SYSTEM, AVATAR_SPECIAL_ITEM,
APPLY_UI_4TH, GACHA_SECOND_VER, UI_UPDATE_2009_FIRST, APPLY_EXCHANGE_UPDATE_1TH, NEW_ITEMMALL,
TRIJOB_SYSTEM_IMPROVEMENT, CHATTING_BLOCKING_SYSTEM, SIEGE_FORTRESS_SYSTEM_IMPROVEMENT_1,
RENEWAL_NEWBIE_SUPPORT, ADD_HELPWND_EXTEND
```

- **INFERRED, strongly:** this is the defined-name table the layout parser's `#ifdef` consults. It is
  the only define list in the archive, and every symbol the layouts test is in it.
- **Correction:** `message_box.md` and `UI_TODO.md` said the `RENEWAL_SHOP_SYSTEM` and
  `RESTORE_SOLDITEM_INSHOP` branches are unreadable, and that the parser's define source was not
  found. It is this file. So:
  - the store is the **renewal** build with the **buy-back row** (`ginterface.txt` gives
    `GDR_STORE:CIFStoreForPackage` 254x370);
  - `EUROPE_SYSTEM`, `UI_UPDATE_2009_FIRST` and `APPLY_EXCHANGE_UPDATE_1TH` are live too.
- **OURS:** `HudPanels.PANEL_DEFINES = {"store": []}` builds the store's non-renewal branch, the wrong
  one (see the gaps).

## 1. The NPC talk window

### Structure (READ)
- **`GDR_NPCWINDOW`** is a `CIF_NPCWindow : CIFMainFrame` registry window: `ginterface.txt` ID 30,
  `Rect 200,200,386,451`, frame `interface\frame\mframe_wnd_`, Style 64.
  - `CIF_NPCWindow::Create` (`0x704b40`) loads `if_npcwindow.txt`, whose only control is
    `GDR_NW_NPCTALK:CIF_NPCTalk`.
  - That control is ID 10, at `Rect 11,48,364,391`, using the 8-slice
    `interface\npc\npc_conversation_window_`.
  - The registry window's caption, drag strip and close button are CIFMainFrame's, as for the other
    registry windows (`0x816f80`; `UI_TODO.md` round 586): caption `(10,12,w-21,12)`, close
    `(w-26,10)`.
- **`CIF_NPCTalk::Create`** (`0x6fa110`) loads `if_npctalk.txt` (rects relative to the talk frame):

  | control | class | rect | art | role |
  |---|---|---|---|---|
  | `GDR_NPCTALK_BGTILE` | CIFNormalTile | 20,20,324,351 | `com_bg_tile_d.ddj` | the dark panel |
  | `GDR_NT_TALKBOX` | CIFTextBox | 23,23,302,343 | none | the text (FontIndex 0) |
  | `GDR_NPCTALK_SCROLL` | CIFVerticalScroll | 336,27,16,320 | none | the scroll bar |
  | `GDR_NPCTALK_QUESTBG` / `_QUESTBG_TITLE` | CIFStatic | -5,-10,374,400 / 16,31,333,28 | `gd_paper_02` / `qst_subwindow_title` | the quest parchment, hidden for a plain talk |

- **Title:** the NPC's name. INFERRED from the screenshots; the store takes the same string
  (`0x704050` → the NPC's ref name, `+0x60`, READ).
- **MEASURED** on `tcHCl0v.png`: the window is 382 px wide, against the registry's 386. That matches
  at a screenshot scale of about 1.

### The text, in order (READ: the builder `FUN_00700440`, line adder `FUN_006fcd60`)
1. **The greeting.** From the NPC's chat record (`FUN_00938000` → `+0x20`, `+0x3c`), drawn in
   `0xffffffff`, white (`FUN_006fb530` → `FUN_0064f8a0(…,0xffffffff,…)`).
2. **The tax line.** It is added only when the NPC belongs to a fortress (object `+0x18c` set and the
   talk window's `+0x800` non-zero).
   - Text: `SN_FORTRESS_SHOP_TAX`, "The current tax rate of %s is %d%%.", with the fortress name
     (`FUN_009274c0(+0x800)`) and the rate, the s16 at `+0x804`.
   - Colour: `0xffd6ff7e` (214,255,126), the green in `tcHCl0v.png`.
   - A blank line follows (`DAT_00e19330`).
   - **OPEN:** which server message fills `+0x800`/`+0x804`.
3. **The menu.** One line per offered service, numbered "`%d. `" from 1 (`_swprintf_s(L"%d. ")`):
   - colour triple `0xffefdaa4`, `0xffff8a00`, `0xffff8a00`: beige (239,218,164) normally, and
     orange (255,138,0) for the other two states (INFERRED: hover and press);
   - **no underline** (none is set; MEASURED: the original screenshots show none);
   - a store line can instead use `0xffff4a4a` (red) as its first colour, in a branch of
     `FUN_006fb630` (INFERRED: unusable).
4. **The end line,** always last: kind 0, `UIIT_STT_NPC_CHATTING_WND_TALKEND` "End conversation.". It
   is `…_TALKEND2` when interaction 0x1f is offered.

### Which lines: the NPC's interaction-id set (READ)
The menu is built from the talk window's id set at `+0x7c0`/`+0x7c4` (`FUN_00534ef0` lookups). The
original server sends that set in the **`0xb045` select reply**: `CGObjChar::PublishAvailableInteractions`
`0x4a95a0`, see `character_state.md`. So **which lines an NPC shows is server data.**

Ids → line kinds → text keys, in the builder's order:

| interaction id(s) | kind | text key | English |
|---|---|---|---|
| 0x13 | (message only) | `UIIT_MSG_XMAS_EVENT_SO-OK` | |
| 2 | 4 | `UIIT_STT_NPC_CHATTING_WND_TALKSTART` | "Talk to this person." |
| 1 (with 0xf/3/0x18/0x19 gates) | 1 | each shop group's own name, `SN_STORE_*_GROUPn` (`FUN_006fb630`) | e.g. `SN_STORE_POTION_GROUP1` "Purchase/ Sell recovery liquid medicine" |
| 4 and 3 | 3 | `UIIT_STT_NPC_CHATTING_WND_STOREHOUSE` | the warehouse |
| 4 and 3 (more) | 0x2d / 0x2e | `UIIT_STT_TC_OPEN` / `UIIT_STT_TC_HONOR_RANKING` | 0x2d only if `+0x868 > 0x3b` |
| 0x20 | 0x2f | `UIIT_STT_AVATAR_MAGICOPTION_ENCHANT_MAGIC_PARAM` | |
| 5 and 7 | 9 | `UIIT_CTL_RECALL_POSITION` | "Designate as return/recall point" |
| 9 | 0x10 | `UIIT_CTL_TELEPORT_TO_RESURRECT_POS` | |
| 8 | 10 | `UIIT_CTL_TELEPORT_TARGET` | "Select teleport area"; the job-gate tax lines `UIIT_PAG_COMPANY_*` " %d%%" too |
| 6 | 0xb | (no text) | |
| 0x1e / 0xf / … | 0x17, 0x14, 0x18, 0x1d, … | the guild lines (`UIIT_CTL_GUILD_*`) | |
| 0x13 | 0x15 | `UIIT_MSG_XMAS_EVENT_CHANGE` | |
| 10 | 0x16 | `UIIT_MSG_CIRCULATION_WITHDRAW_SKILL` | "Withdrawing Skill" |
| 0x14 / 0x16 / 0x15 | job menus (`IF_NPCTalk::FUN_006fdeb0` 1/3/2) | `UIIT_STT_NPC_CHATTING_TRADERMENU_*` etc. | |
| 0x11, 0x12, 0x23, 0xc, 0x1c, 0x27, 0x29 | 0x27, 0x28, 0x3f, 0x39, 0x2a, 0x3d, 0x3e | gacha, open market, special price, …, dungeon exit | |
| always | 0 | `UIIT_STT_NPC_CHATTING_WND_TALKEND` | "End conversation." |

- The herbalist's lines in `tcHCl0v.png` (Talk / Purchase-Sell / Withdrawing Skill / End) are ids
  {2, 1, 10}.
- The gate's lines in `1llywhJ.png` are ids {5|7, 8}.
- Both match this order.

### Clicking a line (READ: `CIF_NPCTalk::FUN_007020c0`, switch on the line's kind)
- **kind 0, end:** `0x78fc20` sends **`0x704b`** (end interaction) and closes.
- **kind 1, store:**
  - the talk's parent `CIF_NPCWindow` runs its close slot (vtable `+0xac` = `vslot_043`, `0x7040b0`);
  - that close sends `0x704b` while the talk box is shown and no `0x7046` request is in flight
    (`0x841780` is the "may send" gate), then hides (`0x652c00`);
  - **only if the close succeeded**, the click sends **`0x7046 {u32 entity, u8 1}`** (`0x702316`..
    `0x702323`).
  - So the talk window is gone before the store opens.
- **kind 3, warehouse:** the parent is hidden (`+0x5c` ShowWindow with 0, `0x702438`), then
  `0x7046` is sent with id 3 (`local_306 = 3`; 0 in another branch).
- **kind 4, talk:** `0x7046` with id 2. The talk window stays.
  - id 2 sets INTERACTMODE 5 and the server's ShowFirstTalkMenu (`character_state.md`).
  - **OPEN:** what the reply shows.
- **kind 9, recall:** message box kind 5 over the talk window, which stays (round 686,
  `open_recall_designate_prompt`).
- **kind 10, teleport list:** the destination lines replace the menu in the same window, which stays
  (round 603, `UI_TELEPORT::FUN_006fd3e0`), as in `hWWsCP0.png`.
- **More `+0xac` closes** (the NPC window closes first) sit at `0x7029aa`, `0x7034f5`, `0x7036d7`,
  `0x7038e4`, `0x703a33` and `0x703aa7`. **OPEN:** which kinds they belong to (map them with the
  switch's jump table).

### Closing the NPC window
- **The close button and the end line:** `vslot_043` as above (READ).
- **Hiding the NPC window** (`CIF_NPCWindow::vslot_023` with 0, `0x704100`) also closes:
  - the tax window `GDR_TAX_MANAGEMENT` (300);
  - the fortress windows `GDR_FORTRESS_MAP` (301), `_BUSINESS` (302), `_WAR_APPLY_WND` (303) and
    `_MAKEITEM_WND` (304);
  - the trade info `GDR_TRADE_INFO_WND` (159);
  - the `.2dt` windows 0xb9 and 0xba;
  - window 0xd6.
  
  It does **not** close the store (15) or the storage (19), which is why the store survives the talk
  window's close (READ: the getters `0x7997d0`…`0x799930` push those ids).
- **Escape** closes windows one at a time in `FUN_0079d620`'s order (window 0x62 first, the NPC
  window later through `+0xac`) (READ; the full order is OPEN).

## 2. The store

**READ.** `GDR_STORE:CIFStoreForPackage`, `ginterface.txt` ID 15, `Rect 0,0,254,370`, frame
`mframe_wnd_`, Style 64, under `RENEWAL_SHOP_SYSTEM` + `RESTORE_SOLDITEM_INSHOP` (§0).
- **Opening it:**
  - the `0xb046` reply handler (`FUN_00888e30`) case 1 calls `FUN_00778810` → store `0x6d4750`, then
    `FUN_0079dbd0(0, 1)`;
  - that **hides and re-shows `GDR_MAINPOPUP` on its inventory pane** (`0x7992c0`, then `+0x5c(1)` and
    `0x6a1f70(0x46)`, under the check `0x676390`);
  - it sets the store's **title to the NPC's name** (`0x704050` → `0x6d2a90`) and shows the store
    (`+0x5c(1)`);
  - `0x777ec0(0x95)` sets the normal cursor.
  - So **the store opens the inventory beside it** (READ), as ours already does.
- **Layout** (`ifstore.txt`, the renewal + restore branch; rects x,y,w,h):

  | control | rect | art / text |
  |---|---|---|
  | `GDR_STORAGE_BGTILE` | 25,250,204,13 | `com_bg_tile_c` |
  | `GDR_STORE_FRAME` (CIFFrame) | 9,60,236,219 | `int_window_` |
  | `GDR_STORE_STRETCH` | 18,68,218,182 | `com_lattice_outline_` |
  | `GDR_STORE_LAT` (CIFLattice, 6x5) | 21,71,216,180 | `com_lattice_` |
  | `GDR_STORE_SLOT_100..129` | | `CIFSlotWithHelpForPackage` |
  | `GDR_STORE_SPIN_PAGE` | 102,254,50,16 | |
  | `GDR_STORE_DETAIL_BGTILE` | 40,279,174,54 | `com_bg_tile_a` |
  | `GDR_STORE_STRETCH_REDEEM` | 57,285,188,40 | `com_redeem_window.ddj` |
  | `GDR_STORE_ICON_SLOT_01..05` | x 61/96/131/166/201, y 289, 32x32 | CIFSlotWithHelp, the 5 buy-back slots |
  | `GDR_STORE_CHARGY_STATIC` | 7,300,43,16, HAlign 2 | `UIIT_STT_RE_BUY_OBJECT` "Buy back" |
  | `GDR_STORE_BTN_REPAIR` / `_REPAIRALL` | 86,332 / 166,332, 76x24 | `UIIT_CTL_REPAIR` / `UIIT_CTL_REPAIR_ALL` |

  - The tabs are built in code (`com_short_tab_*`, x from 16 step 56; `reference_shop_system`).
  - **INFERRED from `3Gw7Ene.png`:** Repair is hidden for a non-smith store (the herbalist shows no
    Repair). **OPEN:** the code that hides it.
- **Not part of the store:** the small two-column box at the left of `3Gw7Ene.png`. No window is
  registered with the store; INFERRED to be the private server's own add-on.

## 3. The storage (warehouse)

**READ.** `GDR_STORAGEROOM:CIFStorageRoom`, ID 19, `Rect 0,0,254,317`, frame `mframe_wnd_`, registry
**Text `UIIT_STT_STORAGEROOM`**. The title is "Storage", not the NPC's name; MEASURED, "Storage" in
`MKtR5Kd.png`.
- `ifstorageroom.txt`:
  - `GDR_STORAGE_BG_CTRL` (CIFSubFrame, `sframe_wnd_`, 9,38,236,241) with its caption
    `UIIT_STT_DEPOSITTEDITEM` "Deposit Items";
  - the lattice and slots as the store's;
  - `GDR_STORAGE_SPIN_PAGE` 102,254;
  - the gold row at 9,283,236,24: `GDR_STORAGE_TXT_MONEY_TITLE` "Total Gold" (`str_slot_01`),
    `GDR_STORAGE_BTN_MONEY` (`com_moneybutton`, 78,286), `GDR_STORAGE_STA_MONEY` (ClientRect
    95,7,44,6, HAlign 2) and `GDR_STORAGE_STA_GOLD` "Gold".
- **Opening it:** `0xb046` case 3 → `FUN_0079dbd0(5, 1)` (READ). The guild storage is
  `GDR_GUILDSTORAGEROOM` (ID 145), the same class, titled `UIIT_STT_GUILD_WAREHOUSE`.

## 4. The confirm boxes

`message_box.md` (round 631) is the full record. Its branch caveat is now settled by §0. In short:

| action (retail trigger) | box | section / class | title | OK caption | price field |
|---|---|---|---|---|---|
| buy (drag a good onto the bag; Ctrl+click buys with no box) | `CItemMallConfirmBuy`, `ifinventory.txt` "ConfirmBuy", ID 400, 327x155, `msgbox2_window_` | | "Confirmation window" | Buy | price x count, "Gold" |
| sell (drag onto the store) | `CIFMessageBox` mode 6 | MsgBoxStoreConfirm | `UIIT_STT_CONFIRM_BOX` | `UIIT_STT_SELL` "Sell" | |
| buy back | mode 6, purpose 0x14 | MsgBoxStoreConfirm | "Confirmation window" | "Buy back" | |
| deposit an item | mode 6, purpose 5 (0x10 guild) | MsgBoxStoreConfirm | "Confirmation window" | `UIIT_STT_DEPOSIT` "Deposit" | a fee (`price*n/2` INFERRED) |
| withdraw an item | mode 6, purpose 6 (0x11) | MsgBoxStoreConfirm | "Confirmation window" | `UIIT_STT_WITHDRAW` "Take" | |
| deposit / withdraw gold | mode 3, purpose 3 / 4 (0x12 / 0x13) | MsgBoxStoreMoney | "Confirmation window" | "Deposit" / "Take" | the amount; icon `moneyicon.ddj` |
| split a stack (Shift+click) | mode 5 | MsgBoxDivideCount | | `UIIT_CTL_CONFIRM` | |

**MsgBoxStoreConfirm** (READ, `ifmessagebox.txt`; rects in the box):
- background `com_bg_tile_b` 16,40,295,106;
- item window `msgbox_itemwindow` 21,48 (48x48), icon 28,55;
- name: black square 82,48,217,20, edit 86,53,209,14, centred;
- "Quantity" (`UIIT_STT_AMOUNT`) at 198,80, in a black square 233,76,44,20; the count edit 237,80,36,12
  (HAlign 2); spin up `server_up.ddj` 278,74 and down `server_down.ddj` 278,85;
- price `UIIT_CTL_WARENETWORK_RESULT_PRICE` at 50,100 (HAlign 2); its edit 112,102,104,17 in a black
  square; "Gold" at 222,100;
- buttons at 82,135 (OK) and 170,135 (`UIIS_CTL_CANCEL`), text colour (255,255,245,218).

This matches `3Gw7Ene.png`'s and `MKtR5Kd.png`'s boxes.

- **The box closes itself** on OK and Cancel (READ, `message_box.md`).
- **What retail does with an open box when its window closes** stays OPEN.

## 5. Window chaining, summary

| from | action | result | label |
|---|---|---|---|
| talk | a store line | NPC window closes (and `0x704b` while the talk box was up), then `0x7046 {e,1}`; on `0xb046` the store opens, titled with the NPC's name, with the inventory pane beside it | READ |
| talk | the warehouse line | NPC window hidden, `0x7046 {e,3}`; the storage opens on the reply | READ |
| talk | Talk to this person | `0x7046 {e,2}`; the talk window stays | READ (what it shows: OPEN) |
| talk | recall point | message box kind 5 over the talk window, which stays | READ |
| talk | Select teleport area | the destination list replaces the menu in place | READ |
| talk | six more kinds (§1) | NPC window closes first | READ (kinds OPEN) |
| NPC window | hidden | closes the tax, fortress and trade-info windows, not the store or storage | READ |
| store / storage | close | **OPEN.** `CIFStore::vslot_023`'s hide branch only resets `+0x7c8` and the cursor (`message_box.md`); whether it sends `0x704b` was not read | |

## 6. OpenSRO today, and the gaps

From `rb5gAPe.jpeg`, `hud_panels.gd` and `npc_service_reader.gd`:

| # | gap | fix (lane) |
|---|---|---|
| 1 | The talk window is self-framed from `if_npctalk.txt` alone. It lacks the `GDR_NPCWINDOW` registry frame (386x451, `mframe_wnd_`, caption, close), the `CIF_NPCTalk` 8-slice `npc_conversation_window_` frame at 11,48 and the scroll bar; the title floats | A |
| 2 | The text is a RichTextLabel with menu links: underlined, all white, no green tax line, no beige or orange states | A |
| 3 | The menu lines come from our own heuristics (`NpcServiceReader.talk_menu_lines`: "1. Buy / 2. End conversation."), not the interaction-id set. The store line is "Buy", not the shop group's own `SN_STORE_*` name. "Talk to this person" and "Withdrawing Skill" are missing | A (ids derived client-side for now, OURS), C (from `0xb045`) |
| 4 | No tax line (needs the fortress name and rate from the server) | C (OPEN which message) |
| 5 | The talk window stays open when the store or storage opens | A |
| 6 | The store builds the non-renewal branch (`PANEL_DEFINES "store": []`): no buy-back row, the wrong height. The store is not in its `GDR_STORE` registry frame (254x370), so it has no frame and the title floats | A |
| 7 | The stray "Gold: …" label under the store (`_build_shop_purse` / `_update_shop_purse`, OURS) | A (remove) |
| 8 | The storage is titled with the NPC's name; the original's is `UIIT_STT_STORAGEROOM` "Storage" | A |
| 9 | Our confirm boxes are our own panels (BuyConfirm, SellConfirm, DepositConfirm, WithdrawConfirm, GoldDialog), not `CIFMessageBox` / `CItemMallConfirmBuy` with their art, title, Quantity spin and captions. The party lane built `MsgBoxINIF` from `ifmessagebox.txt`, so a message-box builder exists to extend | B |
| 10 | Buy: ours opens a box on click. Retail buys by dragging a good onto the bag (ConfirmBuy), or by Ctrl+click with no box. Sell: by dragging onto the store (mode 6, purpose 2), or Ctrl+click with no box | B |
| 11 | Repair buttons: shown for smiths only in ours (`_show_repair_buttons`); retail's rule is OPEN | A (keep, labelled) |
| 12 | Protocol: ours uses its own opcodes (`OpShopList 0x0052`/`0x0053`, OpShopBuy/Sell, OpStorage* `0x0056`-`0x005d`, our NPC talk is client-only). The original uses select `0x7045`/`0xb045` (with the interaction ids), open `0x7046`/`0xb046`, end `0x704b`/`0xb04b`, and moves items with the item-move request (`FUN_007950b0`, store window `0x0f` → inventory `0x46`) | C |
| 13 | Other windows built from layouts with `#ifdef`s use hand-picked defines (`HudChat.LAYOUT_DEFINES`, `PANEL_DEFINES`) instead of `config\define.txt` | A (store/NPC/message box now; global as a follow-up) |

## 7. OPEN

1. Which message carries a fortress NPC's tax data (talk window `+0x800` fortress id, `+0x804` rate).
2. Which kinds the other six NPC-window closes in the click handler belong to (jump table of
   `FUN_007020c0`).
3. What `0x7046 {e,2}` ("Talk to this person") shows.
4. Whether closing the store or storage sends `0x704b`.
5. The Repair buttons' visibility rule.
6. The Escape order past its first entries (`FUN_0079d620`).
7. Server side: which NPCs offer which interaction ids. Round 454 found the registration for ids 7, 8
   and 9 only. Shops (1) follow `refshopgroup`, the warehouse (3/4) the `_WAREHOUSE` NPCs, talk (2)
   and withdraw skill (10) are OPEN.
8. Whether the layout parser's `#ifdef` reads exactly the table `0x6441b0` fills (INFERRED strongly,
   §0).

## Implementation lanes

Three lanes. A and B can run in parallel; C is protocol and goes after A, or in parallel if staffed
with care over `hud_panels.gd`.

**Lane A: the NPC window, store and storage frames, text and chaining (client).**
- **Files:**
  - a new `client/scripts/ui/hud/npc_window.gd` (the `GDR_NPCWINDOW` frame plus `CIF_NPCTalk`,
    composing `if_npcwindow.txt` and `if_npctalk.txt`, a real CIFTextBox text with per-line colours
    and a scroll bar);
  - the talk, store and storage functions of `hud_panels.gd` (`open_npc_talk`, `_fill_npc_talk`,
    `open_shop`, `open_storage`, `PANEL_DEFINES`, `REGISTRY_FRAMES`, removing `_build_shop_purse`);
  - a define-table reader for `config\define.txt` (UiBuilder), applied to these layouts;
  - `npc_service_reader.gd` for the id-ordered menu (ids derived client-side from its tables until
    lane C, OURS).
- **Acceptance:**
  - GD tests: the menu order from an id set (the herbalist {2,1,10} and gate {5,8} cases); line
    colours (white / green / beige, orange hover); the store branch has the buy-back controls; the
    registry frames' sizes; the talk window closes on a store or warehouse line and stays for
    talk, recall or teleport.
  - Live renders at Jangan's herbalist and the gate, matching `tcHCl0v.png`, `1llywhJ.png`,
    `hWWsCP0.png` and `3Gw7Ene.png`'s store, with the geometry MEASURED.
  - Real-input clicks on the menu lines.

**Lane B: the confirm boxes (client).**
- **Files:**
  - a new `client/scripts/ui/hud/message_box.gd` (`CIFMessageBox` modes 3, 5 and 6 plus
    `CItemMallConfirmBuy`), reusing the party lane's MsgBoxINIF builder;
  - only the confirm functions in `hud_panels.gd` (`_show_buy_confirm`, `_show_sell_confirm`,
    `_quantity_move_confirm`, `_open_gold_dialog`, `CONFIRM_BOXES`);
  - the retail triggers: drag to buy and sell, Ctrl+click with no box, Shift+click split.
- **Acceptance:**
  - GD tests: the title and OK caption per purpose; Quantity spin bounds (1..max stack, or the stack
    size); price = unit x count; the box closes on OK and Cancel.
  - Live renders against the buy box in `3Gw7Ene.png` and the deposit box in `MKtR5Kd.png`, MEASURED.

**Lane C: the retail NPC protocol (server + client).**
- **Messages:** `0x7045`/`0xb045` with the interaction-id list (`character_state.md` round 454),
  `0x7046`/`0xb046`, `0x704b`/`0xb04b`.
- **Item moves:** shop buy, sell and buy-back and storage deposit and withdraw move on the retail
  item-move request (`FUN_007950b0`).
- **Gold:** gold moves on `FUN_00825f50`.
- **The tax line's data,** once OPEN 1 is read.
- **Retire** OpenSRO's `0x0052`-`0x005d` NPC opcodes.
- **Server data:** which NPC offers which ids (OPEN 7).
- **Acceptance:** golden bytes both ways, and a live buy/sell/deposit through the real windows with
  the server.
