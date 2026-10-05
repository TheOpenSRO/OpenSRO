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

- **READ (round 725's review): this is the table the layout parser's `#ifdef` consults.**
  - The parser's directive switch (`IFTVariable::FUN_00b37a30`, case 1 = `#ifdef`, from `0xb350f0`)
    asks `IFTVariable::FUN_005004a0`. That function looks the name up in the `std::map` at
    `0xeed4e0` (`mov ecx,0xeed4e0` at `0x500502`) and answers 0 for an absent name.
  - The `define.txt` loader writes that same map: `0x6441b0` with `ecx = [CGame]+0x660`, and
    `0xeece80 + 0x660 = 0xeed4e0` (`0x848355..0x8483ba`). The other callers of `0x6441b0` write
    other maps.
  - The parser knows only `#ifdef`, `#else` and `#endif`.
- **How the loader reads the file (READ):**
  - It splits each line on `=`, `"`, `,`, space and tab (`0x401070` with `0x3d`, `0x22`, `0x2c`,
    `0x20`, `0x09` at `0x8482e4..0x848341`).
  - The first token is a name.
  - It forces a value of 0, or no value, to 1. So every listed name is defined, including
    `NAME = 0`.
  - There is no comment handling: `// Define String` defines `//`.
  - `UiBuilder.parse_define_txt` does the same.
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
- **The scroll bar's length (READ, round 725):** `CIF_NPCTalk::Create` sets it to **320**
  (`push 0x140` at `0x6fa1c9` into `0x65a390` at `0x6fa1d6`, the setter the chat's 308 goes
  through), stored at `+0x7b4`. Its parts are `ifverticalscroll.txt`'s: thumb
  `com_scroll_button.ddj`, arrows `chattingwnd\chat_arrow_up/_down.ddj`, the up arrow at
  `(0,-16)` (READ, the layout).
- **The line pitch (READ, round 725):** 18. `CIF_NPCTalk::Create` calls `0x638c20(0x12)` on the
  text box (`push 0x12` at `0x6fa1e1`), the setter the chat's 14 goes through (`0x7abeb8`). Wrapped
  lines take the same pitch: `tcHCl0v.png`'s rows are 18 px apart, the greeting's wrapped lines
  (187, 205, 223) and the menu's (295, 313, 331, 349) alike (MEASURED). The same Create stores 100
  at `+0x3a0` (the chat's line cap) and 19 at `+0x3a4`. 343 / 18 rounds down to 19, so `+0x3a4` is
  INFERRED to be the number of lines shown.
- **MEASURED** on `tcHCl0v.png` (corrected in round 725): the window's frame runs from x 54 to 439
  and from y 109 to 559, which is **386x451, the registry's size exactly**. Round 724's "382" was
  read off the picture by eye. The talk box's frame is 11 px inside the window, and the first text
  row is 34 px right of the window's left edge and 73 px below its top. OpenSRO's round 725 render
  measures the same four numbers (`docs/rounds/r725.md`).

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
   - a store line can instead use `0xffff4a4a` (red) as its first colour, with the hover still
     `0xffff8a00`, in two branches of `FUN_006fb630` (round 725's review):
     - the NPC offers id 0x0f and `FUN_009870d0()+5 <= 2`, apparently a guild level of 2 or less;
     - the NPC offers id 0x19 and both `0x997ea0` and `0x997f00` fail.

     **OPEN, not modelled:** OpenSRO derives neither id client-side. Nothing has read what
     `0x997ea0` and `0x997f00` test, or what that guild-level field is (lane C). No Jangan NPC
     rendered offers either id.
   - **The wording of three lines differs between the box's archive and the user's client (OPEN
     9, round 725, relabelled by its review).**
     `textuisystem.txt` holds two rows for `UIIT_CTL_RECALL_POSITION`, `UIIT_CTL_TELEPORT_TARGET`
     and `UIIT_CTL_TELEPORT_RESULT`: rows 649-651, 16 columns, read "Designate this region as your
     return & recall point!", "Select a teleport area:" and "Teleport to [%s] for [%d] Gold.". Rows
     7577-7579, 19 columns, read "Designate as return/recall point", "Select teleport area" and
     "Teleport to [%s]area. [%d]gold". The user's original (`1llywhJ.png`, `hWWsCP0.png`) shows the
     later rows. `UiTextTable` keeps the first row of a key, which is the client's rule.
     - **The rule is READ** (round 634; confirmed by round 725's review).
       - `0x8cb266` is the only call to the `stdext::hash_map` insert `0x8ca120`.
       - On an equal key, the insert returns the existing entry and does not write.
       - Neither the service column nor the language column selects the later row.
     - **The box's `textuisystem.txt` is two whole tables, one after the other.**
       - Lines 1–6955 are a private server's reworded 16-column rows.
       - Lines 6956–13915 are the stock 19-column rows.
       - 5,181 keys appear twice, 404 of them with different English.
       
       The user's original shows the stock wording on all six duplicated keys checked (three here,
       three in the party window). So the user's install differs from the box's: either their
       `Media.pk2` lacks the prepended block, or `vsroplus_lib.dll` patches the loader.
     - **USER DECISION (2026-10-05): use the stock wording.** In a table joined this way the
       stock row wins (`UiTextTable.select_rows`, round 725). It is a departure from the binary's
       keep-first rule, which stays documented as READ. OpenSRO now shows "Designate as
       return/recall point", "Select teleport area" and "Teleport to [%s]area. [%d]gold".
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

- **The store line's text (READ, round 725):** `FUN_006fb630` walks the NPC's shops
  (`GlobalDataManager::FUN_00983cb0`) and inside each its tab groups (`FUN_00982760`), and for each
  writes "`%d. `" and the group's own name (`FUN_0093fa50(group)` → `+0x24` → `FUN_008c9bb0`). The
  name is `refshoptabgroup.txt` column 4 (`STORE_CH_POTION_GROUP1` → `SN_STORE_POTION_GROUP1`,
  MEASURED in the archive). A shop can have two tab groups (`STORE_WC_ARMOR`), so two lines.
- **Ids 2 and 10 have no registration in `CGObjNPCNPC::Create` (READ, round 725):** every
  `[vtable+0x164]` (AddAvailableInteraction) call in `0x4c6350..0x4c7900` pushes one of 3, 1, 4,
  0x20, 0xb, 0xf, 0x1e, 0xc, 0xd, 0xe, 0x18, 0x17, 0x19, 0x1b, 0x1f, 0x22, 0x23, 0x27, 0x29, 0x28,
  0x11, 0x12 -- never 2 or 10. So "Talk to this person." and "Withdrawing Skill" come from another
  registrar (OPEN 7); OpenSRO does not offer them until it is read (round 725).
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
    **Their whole rect (READ, round 725)** is `{16 + 56 i, 0x26, 0x38, 0x18}` = (16 + 56 i, 38,
    56x24). `CIFStoreForPackage::vslot_010` writes it at `0x6d2d69..0x6d2d7d` and passes it to
    gwnd `0xba20b0`.
    - The caption is white, READ. The create path (`0x6d2da4..0x6d2dfa`) sets only the font and
      the alignment, so the caption keeps the `CTextBoard` default `0xffffffff` (`0x655b50` →
      `0x8b4f30` → `0x8b46d0`).
    - MEASURED on `3Gw7Ene.png`, agreeing: the tab's top is 38 below the window's, and its caption
      is 255,255,255.
    - Round 724's build had the tab 2 px higher and its caption beige. Both values were ours, and
      both are now corrected.
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

**After round 725** (`docs/rounds/r725.md`):

- **Done:** rows 1, 2, 5, 6, 7 and 8.
- **Row 3, lane A's part:**
  - The menu comes from the id set, which is derived client-side (OURS).
  - Store lines are worded by their tab groups' `SN_STORE_*` names.
  - Talk (2) and Withdrawing Skill (10) are not offered (OPEN 7).
- **Row 4:** the tax line shows for Jangan and Hotan NPCs and gates at 0%. Which NPCs get it comes
  from their codenames (OURS), until lane C reads the message.
- **Row 13:** only the store and the NPC window take `config\define.txt`.
- **Gate greetings:** a gate's talk box now greets with its `npcchat.txt` row (`STORE_CH_GATE` →
  `STORE_CH_GATE_BS`), as `1llywhJ.png` does. `NpcServiceReader.parse_greetings` had dropped every
  owner that is not an `NPC_` code.

## 7. OPEN

1. Which message carries a fortress NPC's tax data (talk window `+0x800` fortress id, `+0x804` rate).
2. Which kinds the other six NPC-window closes in the click handler belong to (jump table of
   `FUN_007020c0`).
3. What `0x7046 {e,2}` ("Talk to this person") shows.
4. Whether closing the store or storage sends `0x704b`.
5. The Repair buttons' visibility rule.
6. The Escape order past its first entries (`FUN_0079d620`).
7. Server side: which NPCs offer which interaction ids. Round 454 found the registration for ids 7, 8
   and 9 only. Shops (1) follow `refshopgroup`, and the warehouse (3/4) the `_WAREHOUSE` NPCs.
   - **Id 2 (talk) comes from the quest classes.** This is round 725's review, in `srgs.asm`.
     - The quest classes push id 2 through the NPC's `[vtable+0x164]`:
       - `CQSP_ALL_POTION_3::vslot_017` at `0x88ea5b` (the herbalist's potion quest);
       - `CQNO_WC_PRIEST3_1::vslot_017` at `0x898557`;
       - `CQNO_WC_SOLDIER_SO_1` at `0x89a36b`.
     - So do `0x926ed0`, `0x927040`, `GObjPC::FUN_0092f740` and `0x931f30`.
     - The receiving NPC being the quest's talk NPC is INFERRED from the shape of the call.
     - So the server lists id 2 in `0xb045` while the NPC is the talk target of a quest the player
       can take or continue. That is lane C's to send from the quest state.
   - **Id 10's registrar is still OPEN** (withdrawing skill). No push of it was found next to a
     `+0x164` load.
8. ~~Whether the layout parser's `#ifdef` reads exactly the table `0x6441b0` fills.~~ **Closed, READ**
   (round 725's review, §0: both use the map at `0xeed4e0`).
9. ~~Which wording of the duplicated `textuisystem.txt` rows to show.~~ **Closed by a USER
   DECISION (2026-10-05): the stock wording.** The client keeps the first row (READ). OpenSRO lets
   the stock table's row win when the file is two joined tables (§1, the menu; round 725).
10. The title icon. The original draws one left of the Storage and Inventory titles (`MKtR5Kd.png`)
    but none on the store's (`3Gw7Ene.png`). `ginterface.txt` has no field for it, so its source in
    the code is unread and OpenSRO draws none.

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
