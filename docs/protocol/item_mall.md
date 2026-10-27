# The item mall window: the client (round 837)

## Corrections from the review (item_mall_verify.md)

The verify pass re-read every claim below at its address. Where this list and the text further
down disagree, this list wins. Evidence is in `item_mall_verify.md` (W1–W14).

- **W1, §4b: the pets orbit with the drag; they do not turn in place.** `0x55f520` sets each
  model's yaw matrix: m00 = cos, m02 = sin, m20 = −sin, m22 = cos, which is RotationY(−angle).
  `0x55f470` then puts the model at its base position multiplied by that matrix
  (x' = cos·x − sin·z, z' = sin·x + cos·z), and the scale does not touch the translation. The
  body (base (0,0,0)) and the pets turn together like a turntable about the world origin. A pet
  added later takes `+0x394`, the angle of the last left release.
- **W2, §4a step 2, §4c step 4, Summary: both preview slots hold pets, and no ride can be tried
  on.** COS TypeID4 3 is the attack (growth) pet: all 9795 `COS_P_*` rows with 1/2/3/3; its items
  are the 3/2/1/1 flutes. TypeID4 4 is the pick (ability) pet: 26 rows, `COS_P_BROWNIE`,
  `COS_P_CAT`, …; its items are the 3/2/1/2 scrolls. `+0x85c` = attack pet at (−5.5, 0, −2.5),
  `+0x858` = pick pet at (4.5, 0, −2.5). Horses are 1/2/3/1 and are summoned by 3/3/3 items, so
  the try-on never shows them.
- **W3, §4a camera: the camera type's fixed rotation (type 2: RotX(π/2)) has no effect.** In
  perspective mode `0xbae580` writes `RotZ(+0x420)·RotX(+0x418)` over that buffer
  (`0xbae6db..0xbae6f0`). The view rotation is `RotZ·RotX·RotY(+0x41c)` (the thunks are
  RotationX `0xaa432a`, RotationY `0xaa43c6`, RotationZ `0xaa447d`). For the mall the camera is
  eye (0, 13, −35), at (0, 13, 0), up +Y, `LookAtLH`, **vertical** FOV 60°
  (`PerspectiveFovLH`), near 1, far 500.
- **W4, §6c: the u64 points field is always on the wire** (`0x792944..0x79299d`). The mode test
  only decides whether the value is copied into the struct (`0x826532..0x82656c`).
  `item_mall_wire.md` is right.
- **W5, §6d `0xB034` result 1:** after `n × u8 slot, u16 count` the client reads **a rent block
  for each item** (`0x8bb130` at `0x87e0dc`): u32 flags; bit 0 adds u16, u32, u32; bit 1 adds
  u16, u32. That the leading 0x18 comes first is READ (`0x87eb50`), not INFERRED.
- **W6, §6c: `0x7978a0` checks differently from the confirm box.** It refuses with `0x1807` when
  free slots < count, with no exception for stackable items. It refuses with `0x1880` only when
  silk + gift < price × count **and** point < the points to use.
- **W7, §4g: the Buying list has 11 rows**, not 12 (silksearch.2dt: 11 slot records, 402×24,
  y 367..597, step 23; window 462×527).
- **W8, §1b row 106: the search edit's FontColor is 222,217,162** (Color 143,110,60).
  247,202,1 is control 104's.
- **W9, Summary: `CIFNewItemMallShopSlot` is a `CIFWnd`** that contains the
  `CIFVScrollColumnView` (ID 301, 5,3,541,507).
- **W10, §2b and Summary: only the shop's first tab group is built** (`0x7e4b04`, back-edge
  `0x7e50e2`). The row test `0x7e3090` looks at all groups, so a shop whose goods sit only in a
  later group gets a row with no sub-tabs.
- **W11, §3d CMallItemData:** `+0x8` = the tab's index in the first group (empty tabs counted).
  `+0x9` = SlotIndex (READ). `+0x14` = **the mall shop group's u16** (`0x983ca0` is an identity
  function), not a tab word. `+0x18` = the refshoptab ID.
- **W12, §3b bit 16:** a stock row matches on (shop group word, package id), not (tab, package).
  **Any row with quantity 0, matching or not, sets "Sold out" and `+0x553`**
  (`0x7def72..0x7df030`).
- **W13, §3c: hover tests `+0x7c4`, the open Buying/Obtained list window**, not a mall box. The
  box busy byte `+0x7c8` is not tested on hover.
- **W14, §3a: every cell is filled and gets its background.** The `0x7df701` test checks a
  c_str pointer, which is never NULL.

- **W15 (round 837, the build's own check), §2a and §1d: HOT shop and Reserved ARE created.** The
  menu parser stores column 2 through `0x97f920`, which compares it with `"xxx"` (UTF-16 at
  `0xd81d38`) and stores an empty string when equal (`0x97f935..0x97f93f`, the empty literal
  `0xe17460`; the call at `0x97fc6a`). Row creation tests the code's length first
  (`0x7e522b cmp [esi+0x3d8],ebx`): length 0 → `+0x370 = 1`, the row is created without any
  `refshop` lookup. So HOT shop and Reserved show with this archive, as in the screenshots;
  only a non-empty code with no `refshop` row (`MALL_PACKAGE`, Bundle goods) or no goods (this
  archive's Alchemy) is hidden. `item_mall_data_verify.md` U5 had this right.

Settled OPEN / INFERRED items (details in the verify file):

- `0x8bf0d0` = the good holds 2 or more items (a bundle).
- `+0x7dc` = purchases awaiting a reply (`0x7d6d80` / `0x7d6da0` / `0x7d6de0`).
- `0x666c00` / `0x666c40` = COS 1/2/3/3 / 1/2/3/4.
- Worn avatars are not attached twice (`0x452230`, `0xa5e270`).
- STAND1: play(0, fade-in 0, events off, speed 1, weight 1). The clip's IsCyclic decides
  looping, and every try-on restarts it.
- `0x7121` is sent only when `shopitemstockquantity.txt` has rows for the mall's shop group
  (`0x8cb900` = manager `+0x3f8`). With this archive, F10 → OK opens the mall without it.
- The cell icon is `icon64\…` (`"icon64" + str.substr(4)`).
- The scrap count is the Data column (record `+0x20`).
- The request string is the package CodeName.
- `0xB11a`'s second byte is unused.
- The `0x8bb570` bits, as far as an avatar is concerned: a level requirement above the
  player's (bit 0x20) also refuses with "Cannot equip the selected item", besides gender (0x40)
  and race (0x200). **Attachments (3/1/13/3) and devil spirits cannot be tried on.**

Read on 2026-10-27 from `sro_client.exe` (local copy of the render box's
`/opt/sro-files/client/sro_client.exe`, md5 `2a5794b7…`; decompiled in `/var/tmp/decomp_client`,
disassembled with `objdump`) and from the box's archives (`/opt/sro-files/client/*.pk2`:
`resinfo\ginterface.txt`, `resinfo\ifnewitemmall*.txt`, `resinfo\ifnewitemslotpopupwnd.txt`,
`config\define.txt`, `server_dep\silkroad\textdata\mallitemmenulistdata.txt`, the `ref*shop*` /
`refpackageitem` / `refpricepolicyofitem` / `refscrapofpackageitem` tables and
`textuisystem.txt`). Every address is a client address. Labels: **READ** (seen in code, address
given), **MEASURED** (looked at the data or art), **INFERRED** (with why), **OPEN**, **OURS**.

Companion files: `item_mall_wire.md` (the messages and SR_GameServer's handlers) and
`item_mall_data.md` (the tables). This file is the client window. The house rule applies: Ghidra
files many of these functions under a `UI_SILKMALL::` namespace. That is a misfiled module name,
not proof that the function belongs to the mall.

**The archive is a private server's.** `/opt/sro-files/client` is a vPlus-patched distribution:
`sro_client.exe` imports `vsroplus_lib.dll` (`vPlusEntryPoint`, the `.newimp` section at
`0x116f000`), and Media.pk2 carries `VPLUS_*` text keys and extra shop tabs
(`MALL_VISUALS_*`, `MALL_WINGS`, …). The code facts below come from the exe and hold for any
data. The data facts (menu rows, tab names, texts) are this archive's and are marked so.

## Summary

- **The window is `CIFNewItemMall`** (`GDR_RENEWAL_ITEM_MALL`, ID 167, 800×600, frame
  `interface\frame\mall_wnd_`, title `UIIT_STT_SILKMALL` "Item Mall"). The registry picks it over
  the older `CIFItemMall` (ID 50) because `config\define.txt` defines `NEW_ITEMMALL` (READ,
  `ginterface.txt` `#ifdef NEW_ITEMMALL`; the define table is `npc_gui.md` §0). Its layout is
  `resinfo\ifnewitemmall.txt` (read by `CIFNewItemMall::Create`, `0x7d8ef0`).
- **The left column and the grid are one control**, `CIFNewItemMallShopSlot` (a
  `CIFVScrollColumnView`, ID 105, at 13,72, 551×513), with two columns: the menu (124 wide) and
  the goods (424 wide). The goods column shows **one view at a time**: the main page, one shop
  tab, a search result or the reserve list.
- **The menu rows come from `mallitemmenulistdata.txt`** (section `ITEMMALL_MENU_LIST`). A row
  is created only if its code names a `refshop` row whose tabs hold at least one good. Its
  sub-tabs are that shop's `refshoptab` rows, in the shop's tab order, each with at least one
  shown good.
- **The main page's sections come from the same file** (section `ITEMMALL_HOTITEM_LIST`): each
  row is a flag bit and a title. A good belongs to a section when its package's `SaleTag`
  (`refpackageitem` column 4) has that bit. A good is shown once on the main page, in the first
  section that lists it.
- **Badges are the `SaleTag` bits:** 1 → N (`mall_icon_new.ddj`), 2 → H
  (`mall_icon_limited.ddj`), 4 → S (`mall_icon_sale.ddj`, plus the old price and an arrow),
  8 → R (`mall_icon_popular.ddj`), 16 → D (`mall_icon_recommendation .ddj`, plus the stock
  left), 32 → D (plus the time left). MEASURED the letters from the art.
- **A cell** (`CIFNewItemMallShopItemSlot`, 199×81, two per row) shows the package icon, its
  name (right-aligned), the silk price, `" N"` + "Unit" and the badges. **Hovering a cell opens a
  four-button menu beside it**: Wear Item (try-on), Buy, Detail information (bundles only),
  Reserve / Delete.
- **Search** is a substring match (`std::wstring::find`, case as typed) on each shown good's
  package name; the hits fill a new view.
- **The "Chest" window in the third screenshot is not in the client.** No layout, no text key and
  no string in `sro_client.exe` (or its two siblings) refer to it; its art and texts are
  `vplus\…` and `VPLUS_UI_CHEST_*`, the vPlus DLL's. See "The Chest window".

- **F10 opens an "Enter Item Mall" warning box first** (kind 0x1e); OK sends `0x7121` and the
  window opens on `0xB121`, or opens at once when the client's check fails (1e).
- **The preview is a new copy of the player's body**, dressed from the Equipment window. Left drag
  turns it, right drag pans, the wheel zooms by 2. **Wear Item** puts an avatar (one per exact
  type) or a pet / ride beside it; other genders and races are refused with "Cannot equip the
  selected item". **Original** rebuilds it; **Buy** buys everything tried on, one `0x7034` per
  good. The try-on lives until the window closes (4).
- **Buying is `0x7034` type 0x18** {shop group, shop index, tab, slot, a string, count, points,
  package id}; `0xB034` puts the goods straight into the inventory; `0x3153` sets silk, gift silk
  and point (6). Buy Silk and Coupon open Internet Explorer on a text-table URL (4f). Buying list
  and Obtained list are silk histories (`silksearch.2dt`, `silkrecievelist.2dt`, `0x711a` /
  `0xB11a`); the Obtained list is disabled in retail (4g).

Sections 4 and 6 were read in parallel this round and merged here; each claim keeps its own
address.

## 1. The window

### 1a. Which class, which layout (READ)

| What | Value | Where |
|---|---|---|
| Registry entry | `GDR_RENEWAL_ITEM_MALL:CIFNewItemMall`, ID 167, Rect 0,0,800,600, DDJ `interface\frame\mall_wnd_`, Text `UIIT_STT_SILKMALL` | `ginterface.txt` section `NewItemMall`, inside `#ifdef NEW_ITEMMALL` |
| The other branch | `GDR_ITEM_MALL:CIFItemMall`, ID 50, frame `mframe_wnd_`, layouts `ifitemmall*.txt` | `#else` branch; not built with this archive's `define.txt` |
| Layout | `resinfo\ifnewitemmall.txt`, sections `Create` and `MyInfo` | `0x7d8f3b` pushes the path, `0x7d8f66` "Create", `0x7d8f8c` "MyInfo" |
| Message map | `.data 0xec03a0`, rows of 0x28 bytes, filled by `0xd72b00` | see 1c |

`CIFNewItemMall::Create` (`0x7d8ef0`) then builds, in order (READ):

- `+0x7cc` = `CIFNewItemMallShopSlot` (class `0xeec6a8`), ID 105 (0x69), rect **13,72,551,513**
  (`0x7d8fa1..0x7d8fc1`);
- `+0x838` = control 111, `+0x7d4` = control 100 (the cell menu, hidden), `+0x83c` = 103 and
  `+0x848` = 101 (the event pop-up, hidden), `+0x834` = 106 (the search edit), `+0x84c` = 104
  (MAIN PAGE);
- the main page (`0x7e4070(id of control 104)`, see 2c);
- `+0x850` = a `CIFRenderStatic` (class `0xee7a78`), ID 123 (0x7b): the avatar preview (section 4);
- `0x7d76e0(…)` reads `event\mall_notify.txt` and shows or hides the event pop-up (section 4);
- `0x7d6eb0(1)` / `0x7d6f50(0)`: the two list windows (section 4).

### 1b. The controls (READ, `ifnewitemmall.txt` and the other layouts)

| ID | Name | Class | Rect | Art / text | Role |
|---|---|---|---|---|---|
| 100 | `…_POPUP_MENU` | CIFNewItemSlotPopupWnd | 0,0,126,143 | frame `mall_sub_wnd04_` | the cell menu (3a) |
| 101 | `…_RIGHT_EVENT_POPUP_BTN` | CIFButton | 636,415 | `mall_avata_button.ddj`, `UIIT_STT_OFF` | closes the event pop-up |
| 103 | `…_RIGHT_EVENT_POPUP` | CIFStatic | 567,46,216,400 | – | the event picture |
| 104 | `…_MAIN_BTN` | CIFButton | 18,45 | `mall_mainpage.ddj` | MAIN PAGE |
| 106 | `…_SEARCH` | CIFEdit | 141,43,332,24 | `UIIT_STT_SILKMALL_SEARCH_DEFAULT` "Write Item name", colour 247,202,1 | search text |
| 107 | `…_SEARCH_BTN` | CIFButton | 475,43 | `mall_button.ddj`, `UIIT_CTL_PARTYMATCH_PSEARCH_FIND` "Search" | search |
| 108 | `…_SEARCH_BG` | CIFStatic | 141,43 | `mall_find_wnd.ddj` | edit background |
| 109 | `…_RIGHT_BTN02` | CIFButton | 676,377 | `mall_avata_button.ddj`, `UIIT_CTL_SILKMALL_INIT_ITEM` "Original" | try-on reset |
| 110 | `…_RIGHT_BTN01` | CIFButton | 571,377 | `mall_avata_button.ddj`, `UIIT_STT_BUY` "Buy" | buy what is worn |
| 111 | `…_RIGHT` | CIFStatic | 567,46,215,332 | – | the preview area |
| 112 | `…_RIGHT_BG` | CIFStatic | 564,42,224,372 | `mall_charac_frame.ddj` | preview frame |
| 130 | `…_RIGHT_BG_WND` | CIFStatic | 564,414,224,124 | `mall_charac_wnd.ddj` | under the buttons |
| 131 | `…_SILKBUYLIST_BTN03` | CIFButton | 571,416 | `mall_avata_button.ddj`, `UIIT_STT_SILKMALL_BUY_LIST` "Buying list" | |
| 132 | `…_SILKRECIEVELIST_BTN04` | CIFButton | 676,416 | same, `UIIT_STT_SILKMALL_RECEIVE_LIST` "Obtained list" | |
| 114 | `…_LEFT_FRAME` | CIFFrame | 15,42,124,542 | `mall_ava_wnd_` | left column frame |
| 115 | `…_LEFT_BG` | CIFStatic | 25,52,83,510 | `com_bg_tile_s.ddj` | |
| 116 | `…_MID_BG` | CIFStatic | 137,72,424,519 | `mall_back_wnd.ddj` | grid background |
| 117 | `…_SUB_FRAME` | CIFFrame | 11,39,779,550 | `mall_sub_wnd_` | |
| 118 / 119 | `…_SUB_BG` / `…_BG` | CIFStatic | 31,59,739,510 / 40,68,720,484 | `com_bg_tile_n` / `_m` | |
| 120 | `GDR_ITEM_MALL_MYINFO` (section `MyInfo`) | CIFNewItemMallMyInfo | 562,449,223,135 | `ifnewitemmallmyinfo.txt` | name, level, silk (section 4) |
| 105 | (code) | CIFNewItemMallShopSlot | 13,72,551,513 | scroll art `mall_scroll_up/down/bar.ddj` | menu + grid |
| 123 | (code) | CIFRenderStatic | from control 111 | – | 3-D preview |

`ifnewitemmallmyinfo.txt` (offsets inside 120): name 210 (7,9,106,15), level 209 (115,9,98,15),
silk 208 (115,29) with label 202 `UIIT_STT_SILKMALL_ITEM_SILK` and coin 205
`mall_silk_icon.ddj` (201,27); point 206 (115,50) with label 200 `UIIT_STT_SILKMALL_ITEM_POINT`
and a "P" (203, `UIIT_STT_SILKMALL_P_POINT`); gift silk 207 (115,69) with label 201
`UIIT_STT_SILKMALL_ITEM_GIFTSILK` and coin 204; Buy Silk 212 (3,92, `mall_big_button.ddj`,
`UIIT_STT_SILKMALL_BUY_SILK`) and Coupon 211 (114,92, `UIIT_STT_SILKMALL_COUPON_EXCHANGE`);
background 214 `mall_charac_textbox.ddj` (3,0,220,88).

### 1c. The window's message map (READ, `.data 0xec03a0`, filled at `0xd72b00`)

| Control / message | Handler | Does |
|---|---|---|
| 107 Search | `0x7d7410` | reads the edit (vslot `0xb8`) and runs the search (`ShopSlot 0x7e32d0`, section 5) |
| 104 MAIN PAGE | `0x7d6ea0` | `ShopSlot 0x7e3660`: collapse the menu, show the main page view |
| 109 Original | `0x7d8d30` | section 4 |
| 110 Buy | `0x7d7080` | section 4 |
| 101 Off | `0x7d6e60` | hides 103 and 101, shows the preview 123 |
| 131 Buying list | `0x7d7130` | section 4 |
| 132 Obtained list | `0x7d71b0` | section 4 |
| message 0x102 (WM_CHAR), type 0x10 | `0x7d7650` | Enter with the search edit focused → search. Esc with the edit focused → focus back to the game window (`SetFocus`, `0x7d767c`). Esc otherwise → vslot `0xac` (close the window) |

### 1d. Retail controls and the server's content in the screenshots

| In the screenshots | Retail? |
|---|---|
| Frame, title, MAIN PAGE, the search edit and button, the cells, the section bars, the preview, Buy / Original, Buying list / Obtained list, the info block, Buy Silk / Coupon | **retail controls** (1b) |
| Category names "Expendables", "Pet", "Premium", "Alchemy", "HOT shop", "Reserved" | retail text keys (`UIIT_STT_SILKMALL_CONSUMPTION` …) |
| "Dresses" | the server's text for `UIIT_STT_SILKMALL_AVATA` (this archive says "Visuals") |
| Sub-tabs "Job Suits", "Models", "Dyes", "Removers", "Title Scroll" | the server's `refshoptab` rows (not in this archive) |
| "Silk" / "Beta Silk" / "Gift Silk" | retail rows silk / point / gift silk (rows at y 29 / 50 / 69). The texts and the grey and green coins are the server's: this archive says "Premium Silk", "Honor Point" (with a "P", not a coin), "Gift Silk", and both retail coins are `mall_silk_icon.ddj` |
| The goods, prices, unit counts and badges | the server's data, drawn by the retail cell |
| "HOT shop" and "Reserved" rows | retail rows, but see 2a: with this archive's data the client does not create them |
| No "Bundle goods" row | consistent with 2a: `MALL_PACKAGE` has no `refshop` row |

### 1e. Opening and closing (READ)

- **F10** (VK 0x79): the key dispatcher `0x780610` → `0x7807aa` (byte table `0x780da8`, jump table
  `0x780d78`). If the mall is not open and no box of kind 0x1e is up (`0x6ec400(0x1e)`), it opens
  **box kind 0x1e** (`0x6ec5d0`, call at `0x7807ef`): built by `0x644c90` (jump index 29 →
  `0x647b74`), 400×210, "Enter Item Mall" (`UIIT_STT_SILKMALL_ENTER`) and the three lines
  `UIIT_STT_SILKMALL_WARNING_1..3` ("You can be attacked by monsters or / other players while
  using Item Mall. / It is recommended to use Item Mall in safe zones.").
- Its OK reaches `0x797d90` case 0x1e. A check (`0x8cb900` with the mall shop group's word, then
  `0x56bce0`, OPEN what it tests) decides: pass → send `0x7121 {u16 shop group word}`
  (`0x821d80`) and wait; fail → open at once (`0x79b580(1)`, `0x798771`).
- **`0xB121`** (`0x8a1360`): `u8 result`; on 1, `u16 key, u8 n, n × {u32, u16}`, each pair
  updating the u16 at `+0xc` of the stock table (manager `+0x404`, the one 3b's bit 16 reads;
  INFERRED stock counts); then `0x79b580(1)` (`0x8a1474`). Layout detail: `item_mall_wire.md`.
- **`0x79b580(bool)`**: open loads the ginterface section "NewItemMall" (`0x8b5580`), runs
  `0x79ac50(0xa7)`, shows window 0xa7 and logs "아이템몰을 열었다."; close plays
  `snd_window_close`, hides and unloads the section (`0x8b59f0`). Everything in the window,
  the try-on included, is rebuilt on each open.
- **Closing**: the X goes through the generic close `0x652c00` (mall test at `0x652c87`) →
  `0x79b580(0)`. The mall's close request (`vslot_043 0x7d7020`) is refused while a mall box is up
  (`+0x7c8`) or purchases are outstanding (`+0x7dc` > 0). If the Buying list has an inquiry
  pending it sends `0x711a {1, 0xff}` (`0x7eabe0`). It clears the player's list `+0x4c4`
  (`0x77e0a0`, OPEN what it holds). Esc closes too (1c).
- **The bottom bar's button**: control 9 of `res_ui\nifundermenubar.2dt`, art
  `ub_new_mall.ddj`, rect 859,459,32,32, tooltip `UIIT_STT_SILKMALL_SHORT_KEY` "Item Mall(F10)"
  (`0x60a6d5`). Its click handler is OPEN (INFERRED: the same box).
- **CIFMallNotifyWnd**'s "Shortcut To Item Mall" (`0x7d16c0`) calls `0x79b580(1)` directly: no
  warning box, no `0x7121` (the button-to-handler link INFERRED).
- A buy reply that arrives while the mall is closed opens it, is processed and closes it again
  (`0x87e00e` / `0x87e31a`).
- `UIIT_STT_SILKMALL_DONOT_USE_TELEPORT` ("Portal cannot be used during Item Mall trading") is
  not in the exe (ASCII or UTF-16); no setter traced (OPEN).
- OpenSRO today binds F10 to OURS "hide UI" (`client/scripts/ui/keymap.gd`); retail F10 is the
  path above.

## 2. The category tree, the main page and the scroll

### 2a. The menu rows (READ)

`mallitemmenulistdata.txt` is loaded as table 0x55 by the generic loader (`0x952890`, case 0x55;
the path pushed at `0x8459f0`). Two sections:

- `#section ITEMMALL_MENU_LIST` (global `0xeeea9c` = 1): one `CMallItemMenuListData` per row
  (`RefParse_mallitemmenulistdata 0x97fbe0`), stored in a map keyed by column 1 (data manager
  `+0x494`, `0x8cb8c0`). Column 0 is the service flag: a 0 row is skipped (`0x95739d`).

  | Column | Field | Example |
  |---|---|---|
  | 0 | service (0 = skipped) | 1 |
  | 1 | index, the map key (so the row order) | 1 |
  | 2 | `refshop` code (`+0x8`) | `MALL_CONSUME` |
  | 3 | text key (`+0x24`) | `UIIT_STT_SILKMALL_CONSUMPTION` |
  | 4 | row art (`+0x40`) | `interface\mall\mall_item_tab.ddj` |
  | 5 | icon (`+0x5c`) | `interface\mall\mall_consum_icon.ddj` |
  | 6..9 | four bytes `+0x78..+0x7b` | `0 1 1 1`. Unused by the window: the map has two readers, `0x7e5199` and `0x7e002a` (by index, `0x9372f0`), and no byte read at those offsets occurs in the mall code (`0x7d5000..0x7ee000`) |

- `#section ITEMMALL_HOTITEM_LIST` (global = 2): rows of {service, Korean name, key, flag, text
  key}; a map keyed by column 2 (`+0x4ac`, `0x8cb8e0`), value = {flag `+0`, text key `+4`}
  (`0x957444..0x9574c4`). This archive: key 1 → flag 16 "Limited Sales", key 2 → flag 1 "New
  item", key 3 → flag 2 "Best item", key 4 → flag 8 `UILM_STT_DIVISION_RECOMMENDATION`; the
  flag-4 (sale) and flag-32 (period) rows have service 0.

The rows are built by `ShopSlot 0x7e5160`, walking the menu map in key order (READ):

1. The row's code is looked up in `refshop` by code name (`0x926560`: the map at manager
   `+0x35c`, compared against the record's code at `+0xc`). **No `refshop` row → the row is not
   created.** An empty code → created. Found → created only if `0x7e3090` finds, among the
   shop's tab groups and tabs, a tab with at least one good.
   - This archive's HOT shop and Reserved rows have the code `xxx`, which names no `refshop` row,
     so **with this archive the client creates neither** (`0x7e5240..0x7e5287`). The screenshot
     server shows both; whether its data has a `refshop` row coded `xxx` or its client differs is
     OPEN. "Bundle goods" (`MALL_PACKAGE`) is hidden for the same reason, and the screenshot has
     no such row.
2. The row is a `CIFNewItemMallShopMainSlot` (class `0xeec688`), **116×32**
   (`ifnewitemmallshopmainslot.txt`: icon 601 at 7,6 20×20; title 600 at 32,10 77×16), filled by
   `0x7dfff0`: the title is the text key's string; the background and icon are columns 4 and 5.
   (A disabled form, `<name>_disable.ddj` and title colour index 3, exists in `0x7dfff0` but this
   path never passes the disabled flag.)
3. By its text key:
   - `UIIT_STT_SILKMALL_SHOPPING_BASKET_LIST` (Reserved): `0x7e13b0` adds two sub-entries,
     `UIIT_STT_SILKMALL_ZZIM_LUMP_BUY` "Buy All" (`+0x890`) and
     `UIIT_CTL_SILKMALL_DELETE_BASKET_ALL` "Empty" (`+0x894`); `0x7e3220` adds the reserve view.
   - `UIIT_STT_SILKMALL_HOT_STORE` (HOT shop): remembered (`+0x89c`), filled after the loop by
     `0x7e38f0`: one sub-entry per main-page list (2c), titled with the list's text, each with a
     view of that list's goods.
   - anything else: `0x7e4a90` builds the shop's sub-tabs and views (2b).

A row's look (READ): closed `mall_item_tab.ddj`, open `mall_item_tab_on.ddj` (`0x7dfd80`).

### 2b. A shop's sub-tabs and views (READ, `0x7e4a90`)

For each tab group of the shop (`0x9262c0` / `0x982760`), for each tab (`0x985a40` → `0x9849b0`):

- a view (`CIFSlotView`, class `0xee942c`, width 400, id `row<<16 | n`) is added to the goods
  column **hidden** (`0x7e4c56..0x7e4c7f`);
- each good of the tab, in the tab's goods vector, that passes the filter (`0x7e0510`, 3b) gets a
  `CMallItemData` and a cell, two per row (`+0x36c = 2`, `0x7e4f56`);
- each good is also appended to the main-page lists for each `SaleTag` bit it has (`0x7e4dc8..
  0x7e4e6a`: bit 1 → `+0x8bc`, 2 → `+0x8cc`, 4 → `+0x8dc`, 8 → `+0x8ec`, 16 and 32 → `+0x8fc`);
- if the tab showed at least one good, a sub-tab `CIFNewItemMallShopSubSlot` (class `0xeec6c8`,
  116×23) is added under the row, hidden, remembering its view (`+0x36c`). Its title (control
  700, placed at x+43, 93×15) is the tab's text key (`refshoptab` column 5, `+0x28`;
  `0x7e6330`). It has no background (`0x7e6377`: the flag is 0).

**Order.** Rows by column 1. Tabs by the shop's group and tab order (`item_mall_data.md`). Goods by
`refshopgoods` SlotIndex: the loader puts each good at `[vector + SlotIndex*4]`
(`0x985590`), and the builder walks the vector, skipping empty places (`0x7e4ce1`).

**Clicks.**

| Action | Code | Effect |
|---|---|---|
| Left release on a row | `ShopMainSlot vslot_017 0x7df8d0` (0x201 press, 0x202 release) → `0x7df890` posts 0x806c | `ShopSlot` map `0xec0a00`: `0x7e4a50` → `0x7e4660` |
| Open a closed row | `0x7e4660` | closes the other rows, opens this one, inserts its sub-tabs below it in the menu column. The goods column is not changed (the Reserved row also shows its reserve view and sets the mall's `+0x7c9`) |
| Click an open row | `0x7e4660` (`0x7df780` true) | collapses it |
| Left press on a sub-tab | `ShopSubSlot vslot_030 0x7e6260` → posts 0x806d | `0x7e4a70` → `0x7e4840`: the clicked sub-tab turns **yellow `0xffffff00` and bold**, the others white (`0x7e6140`); the goods column shows that tab's view (`0x7dbbf0(1, view)`) |
| "Buy All" sub-entry | `0x7e4840` (`+0x890`) | needs a non-empty reserve list (`0x778eb0`) and no open mall box: opens `CIFNewItemMallMessageBox` ID 306, 376×272 (`0x7da950`) |
| "Empty" sub-entry | `0x7e4840` (`+0x894`) | `0x77e0b0`, then `0x7e4590` |
| MAIN PAGE (104) | `0x7e3660` | collapses the menu, shows the main view |

Sub-tab clicks are refused while the mall's `+0x7dc` is set (`0x7e6271`); row clicks likewise
(`0x7df90a`).

### 2c. The main page (READ, `0x7e4070` → `0x7e3c00`)

- A view (`CIFSlotView`, width 400) holds one section per `ITEMMALL_HOTITEM_LIST` row, in key
  order. A section is made only if its list has at least one good that passes the filter and is
  not yet shown (`0x7e36a0`).
- Each section has a title bar `interface\mall\mall_menu_bar.ddj` (420×20, MEASURED) with the
  row's text (`0x62d090`, `0x7e3db3..0x7e3def`), then its cells, two per row.
- **A good is shown once:** the set at `+0x91c` keeps the package ids already placed; a good
  already in an earlier section is skipped (`0x7e3ea0..0x7e3ec2`). With this archive's keys the
  order is Limited Sales, New item, Best item, Recommend.
- The screenshot's "New item" then "Best item" fits: no good of that server has bit 16.

### 2d. The goods column and the scroll (READ / INFERRED)

`CIFNewItemMallShopSlot::vslot_010` (`0x7e5eb0`) makes the scroll view (class `0xee9450`
`CIFVScrollColumnView`, ID 301, rect 5,3,541,507 inside the slot) with
`mall_scroll_up.ddj`, `mall_scroll_down.ddj`, `mall_scroll_bar.ddj` (thumb 14×28,
`0x7e5f53`). It adds a column of width 124 holding the menu view (`CIFSlotView` ID 303) and a
column of width 424 for the goods (`0x7dc940(0x7c)`, `0x7dc940(0x1a8)`).

INFERRED from use: `0x7dbae0(col, view)` adds a view to a column and `0x7dbbf0(col, id)` shows that
view. Every tab view is created hidden and is shown only through `0x7dbbf0`; the main page, a
tab, a search result and the reserve list replace each other. There is **no paging**: one
vertical scroll bar. Whether the bar also scrolls the menu column is OPEN (the screenshots
show the bar beside the grid only).

## 3. A goods cell

### 3a. What a cell is (READ)

`CIFNewItemMallShopItemSlot` (class `0xeec668`), created **199×81** (`0x7e4f1d..0x7e4f28`), layout
`resinfo\ifnewitemmallshopitemslot.txt` sections `Create` and `NewShopSlotIconForPackage`
(`0x7de3b0`).

| ID | Control | Rect | Field | Content |
|---|---|---|---|---|
| 900 | CIFSlotWithHelpForPackage | 8,8,45,45 | `+0x548` | the package icon; help on hover (OPEN: the tooltip's lines) |
| 801 | CIFTextBox, right-aligned | 60,9,130,26 | `+0x558` | the name, wrapped; lines 0–2 white, line 3 `0xffb4b4b4` (`0x7de74e..0x7de778`) |
| 803 | CIFStatic, right | 59,42,50,12 | `+0x560` | the old price (sale only) |
| 802 | CIFStatic | 112,44 | `+0x568` | `mall_arrow.ddj` (sale only; hidden at create) |
| 805 | CIFStatic, right | 124,42,51,12 | `+0x55c` | the price |
| 806 | CIFStatic | 179,40 | – | `mall_silk_icon.ddj` (the gold coin, MEASURED 14×14) |
| 807 | CIFStatic, right | 107,63,83,12 | `+0x564` | `" N"` + "Unit", or the stock left, the time left, or "Sold out" |
| 1100+n | CIFStatic (class `0xee9720`) | x = 9 + 13n, y 60, 12×12 | `+0x56c+4n` | the badges, left to right in bit order |

The background is `mall_item_wnd.ddj` (200×84, MEASURED), and `mall_item_wnd_focus.ddj` while its
menu is open (`0x7de9d2`). A cell whose package has no icon path gets neither content nor
background (`0x7df701`).

Fill (`0x7df6c0` → `0x7df430`, then `0x7df690` = `0x7de530`, `0x7dea00`, `0x7de0d0`, `0x7df1f0`,
`0x7dec60`):

- **Name** (`0x7de530`): the package's name key (`refpackageitem` NameStrID, record `+0x4c`)
  through the text table.
- **Icon** (`0x7dea00`): the package's icon path (record `+0x84`); the code joins it with
  `icon64` (`0x7dea73`); exactly which file the slot draws is OPEN.
- **Price** (`0x7de0d0`): the package's price for payment-device bit 1 (`0x9809c0` copies the
  price block at record `+0xd0`; the cell reads its `+0x10`, i.e. slot 1). The block is filled
  from `refpricepolicyofitem` by `0x980d90`: for the first bit `i` (0..10) set in PaymentDevice,
  slot `i` = Cost; record `+0x130` = PreservedPrice. So the cell shows the **silk** cost
  (PaymentDevice 2): the confirm box labels price bit 0x2 "Premium Silk" (`0x7d9420`, 6b). READ in the confirm box: bit 0x2 is labelled "Premium Silk" (`0x7d9420`, 6b).
- **Unit** (`0x7df1f0`): `" %d"` then `UIIT_STT_UNIT` "Unit" (`"%s%s"`, `0x7df3e2`). The number
  is the first `refscrapofpackageitem` row's count field (`+0x18`, INFERRED the Data column);
  1 when that field is 0, and 1 when the item's ref object has bit 2 at `+0x2c8` (OPEN which
  flag). A bundle (2+ scrap rows) gets " 1" too (`0x7df35e`). Skipped when 807 already holds a
  stock or sold-out text.
- **Flags** (`0x7df430`): `+0x555` bundle (2+ scrap rows). `+0x551` "can be worn on the
  preview": the first item is an avatar item (packed type 3/1/13) whose fourth type id is not 3,
  or a COS item of type 3/2/1 whose COS passes `0x666c00` / `0x666c40` (section 4).

### 3b. The filter and the badges (READ)

**Filter** (`0x7e0510`): a good whose `SaleTag` has bit 32 is shown only between the begin and end
times of its `refshopitemstockperiod.txt` row (`0x937ec0`), compared with the client clock
(`0x834c70`) through `mktime`. Every other good is shown. This archive's file is empty, so bit-32
goods would be hidden (INFERRED: zero times).

**Badges** (`0x7dec60`, the `SaleTag` word, `refpackageitem` column 4 = record `+0x2c`):

| Bit | Art (MEASURED letter) | Also |
|---|---|---|
| 1 | `mall_icon_new.ddj` (blue N) | main-page list 1 |
| 2 | `mall_icon_limited.ddj` (red H) | list 2 |
| 4 | `mall_icon_sale.ddj` (green S) | shows the arrow 802, the old price 803 (record `+0x130`) and the price 805 |
| 8 | `mall_icon_popular.ddj` (magenta R) | list 8 |
| 16 | `mall_icon_recommendation .ddj` (purple D; the space is in the file name) | stock: the `shopitemstockquantity.txt` row for this tab and package (manager `+0x404`) → `" %d"` left, or `UIIT_STT_SILKMALL_ITEM_SOLDOUT` "Sold out" at 0 (`+0x553` = sold out) |
| 32 | the same D | period: `UIIT_STT_SILKMALL_ITEM_DATE` "[%d]day [%d]hour [%d]min" left (`0x7de250`, `0x7ddf70`: seconds / 86400, / 3600, / 60); "Sold out" when over |

The screenshot's N, H and R match bits 1, 2 and 8.

### 3c. Hover, press, and the cell menu (READ)

- **Hover** (message 0x4009, `vslot_019 0x7deb80`; 0x4009 is the hover message per
  `ext_quick_slot.md`): when no mall box is open (`+0x7c4` = 0) and the pointer is inside the
  cell (`0x7de110`), the menu (control 100) moves to the cell's position + (132, 56) and opens
  for this cell (`0x7de900`). Each tick the menu closes itself once the pointer is outside both
  the menu and its cell (`CIFNewItemSlotPopupWnd::vslot_012 0x7e6790`), resetting the cell's
  background.
- **Left press** (`vslot_030 0x7de170`): only on a bundle; opens the bundle's contents box
  (`CIFNewItemMallMessageBox` ID 1204, 375×355, `0x7dcb10`).
- **The menu** (`resinfo\ifnewitemslotpopupwnd.txt`; message map at `0xec0b08`, `0xd73090`):

  | ID | Text | Enabled when | Handler |
  |---|---|---|---|
  | 10 | `UIIT_STT_SILKMALL_PUT_ON` "Wear Item" | `+0x551` and not a bundle | `0x7df560`: the try-on (section 4) |
  | 11 | `UIIT_STT_SILKMALL_BUY` "Buy" | not sold out | `0x7ddb90`: `CNewItemMallConfirmBuy` ID 1200, 338×212 (`0x7e91c0`), section 6 |
  | 12 | `UIIT_STT_SILKMALL_ITEM_INFO` "Detail information" | a bundle | `0x7ddc40`: the contents box ID 1201, 375×355 |
  | 13 | `UIIT_STT_SILKMALL_DO_ZZIM` "Pre-select", or `UIIT_STT_SILKMALL_DEL` "Delete" in the reserve view | always | `0x7ddd00` / `0x7dddb0`: box ID 1202 / 1203, 396×252, `0x7da4b0(item, 1 / 0)` (`UIIT_MSG_SILKMALL_ZZIM_CONFIRM` / `_ZZIM_DELITE`) |

  Buttons at x 14, y 13 / 43 / 73 / 104, art `mall_coice_button.ddj`, on a 126×143 frame. Every
  box sets the mall's busy byte `+0x7c8`, which blocks the others.
- **The reserve list is the client's own**: player `+0x4b8`, added by `0x783b70`, removed by
  `0x784f70`; no message is sent (INFERRED from no sender on that path). Its "Buy All"
  (`0x7dabc0`) sends through `0x7978a0` (6c).

### 3d. How a cell maps to a purchase (READ / INFERRED)

Each cell holds a `CMallItemData` (0x1c bytes, ctor `0x97f9f0`, fill `0x97fa40`): `+0x4` the shop
id (`refshop` ID), `+0x8` a byte, `+0x9` a byte, `+0x10` the good (its package at good `+0x38`),
`+0x14` a word from the tab (`0x983ca0`), `+0x18` a dword. INFERRED: the second byte is the
good's SlotIndex (the builder's counter walks the SlotIndex vector, `0x7e4f84`), and the three
are what the client's own log line "SendNetMsgItemMall : ShopID(%d), Tab(%d), Index(%d)" prints.
The message is in section 6.

## 4. The right panel: the preview and the try-on

### 4a. The preview control and its model (READ)

| What | Value | Where |
|---|---|---|
| Control | `CIFRenderStatic` (class `0xee7a78`), ID 123, at mall `+0x850` | `0x7d911b..0x7d9133` |
| Rect | the rect of control 111 (`…_RIGHT`, 567,46,215,332), held at `+0x838` | `0x7d8fcb`, `0x7d90f3..0x7d9116` |
| Start | `0x5612f0` clears every model and resets the camera; `+0x1f0 = 1` turns the mouse on (off by default, ctor `0x560a50`); hidden until the event check (4e) | `0x7d9139..0x7d915a` |
| Backdrop | the layout's 112 `mall_charac_frame.ddj` (564,42,224,372) and 130 `mall_charac_wnd.ddj` under the buttons. The render clears only Z (`Clear(…, 2 = ZBUFFER, …)` at `0x560c30`), so the frame art shows behind the body | |
| `interface\mall\*_avatawindow.ddj` | not referenced by the exe; they are event pictures a `mall_notify.txt` names (4e) | string search and `0x7d76e0` |

**The build** (`0x7d8bf0`, from Create and from Original):

1. `pEquip` = the Equipment window's visual record (`CIFMainPopup` window 0x19, `+0x7c0`; asserts
   "pEquip", IFNewItemMall.cpp line 0x1e6 when missing).
2. The model slots `+0x854` (player), `+0x858` (pet), `+0x85c` (ride) are reset to −1.
3. `Render.0x561930(player RefObj ID, pEquip+0x36c)` makes a **new body from the player's own
   RefObj id** (`0x561780`: a PC (`CICUser 0xef1bc0`) or a COS (`0xeef6f0`); create `0xba36d0`,
   init `0x9c1840(refID)`, anim set from ref `+0x260`, ref `+0x124` through `0xa5b4b0(…,1)`,
   `0x9c4130(1)`, scale ref `+0x110` / 100), then dresses it with `0xa617d0(src, mode 0)`:
   - `0xa617d0` clears the target's four visual lists (`+0x148`, `+0x154`, `+0x160`, `+0x16c`) and
     both 9-slot arrays (`+0x38`, `+0xa4`). Mode 0: each avatar in the source's list `+0x160` goes
     on through `0xa60ef0` (AttachAvatarVisual); then for slots 8..0
     `InstallEquipVisual(slot, src[+0x38 + 12·slot].id, plus byte, 0)`. Mode 1 does the same from
     `+0x16c` / `+0xa4` (its caller is OPEN). Then the scale byte (`0xa5b960(src+0x30)`) and a
     rebuild (vslot `0x20`). The plus is copied, so the glow shows.
4. `0x5602c0(idx, 0)` plays action 0 (STAND1, `BSR_FORMAT.md`; `0x9cfb40` → model vslot `0xc`).
   INFERRED that it loops.
5. `0x561250` computes the pan box (4b).
6. Camera: look-at `+0x3f4` = (0, 13.0, 0) (`0x7d8c86`, float `0xd8acc8`); `0x55efd0({0, 2π, 0},
   35.0)`: angles `+0x418..+0x420` = (0, 2π, 0), distance `+0x424` = 35; far `+0x430` = 500.0
   (`0x7d8cd8`).
7. `0x5603b0(idx, 0)`: world matrix = identity (table `0xeafb20[0]`).
8. The five worn avatar slots (`pEquip+0x5f8 + i·0x1d0`, i < 5) that are occupied go through the
   try-on path `0x7d8bd0(slot, 0)` (4c), so they enter the try list (but not the buy list: the
   goods argument is 0). Whether they are thus attached twice is OPEN.

**Camera** (the camera object at render `+0x3e4`; ctor `0xbae0a0`; matrices `0xbae810` /
`0xbae580`): an orbit, eye = target − R(angles)·(0, 0, distance), R from `+0x418`, `+0x41c`,
`+0x420` (camera type 2 adds a fixed π/2, `0xe096d4`). Perspective (`+0x428` = 1), FOV `+0x434` =
60°, near 1.0, far 500, aspect = viewport w/h, viewport = the control rect (`0x6531a0`). Which axis
each D3DX thunk (`0xaa432a`, `0xaa43c6`, `0xaa447d`) turns is OPEN; a front view of the whole body
is INFERRED from the screenshot.

**Light** (ctor `0x560a50`, reset `0x5612f0`): one directional `D3DLIGHT9` (`+0x538`), diffuse
0.7/0.7/0.7, specular 1.0, ambient 0.3, range 10000, its direction copied from the camera's
(`+0x40c`) on every update (vslot_012 `0x560fc0`): a headlight. Render states (`0x560c30`): Z on,
alpha blend off, lighting on.

### 4b. The mouse on the preview (READ, `CIFRenderStatic`, only while `+0x1f0` ≠ 0)

| Input | Effect | Where |
|---|---|---|
| Left press (0x201) | unless a right drag holds the capture: start angle `+0x3cc` = `+0x394`, remember x / y, capture | `0x560720` case 1 |
| Left drag | angle = start + 2π·dx / control width, wrapped (`0x55e780`), applied to **every model** as its own yaw (`0x55f520`: `+0xc` and a Y rotation). The models turn in place: no orbit, no pitch, no limit. Pet and ride turn about their own origins | `0x5608c4..0x560988` |
| Left release | keep the angle in `+0x394`, release | case 2 |
| Right press (0x204) / drag | **pan** the look-at point: x = x0 − dx·dist·2 / width, y = y0 + dy·dist·2 / height (dist = `+0x424`), z unchanged; clamped (`0x55e5b0`) to x in [min(0, model min x) .. max(0, model max x)], y in [min(0, pos.y + aabb.min y · 0.5) .. max(0, entity `+0x22c`)]. The box is the player model's, made once per build (`0x561250` / `0x55f1c0`) | `0x56099c..0x560a12` |
| Right release (0x205) | release | |
| Wheel (vslot_036 `0x55ee20`) | delta > 0: distance + 2.0 (`0xd86ecc`), else − 2.0 (`0xd89ca8`); clamped to [s + near, s + 40] (`0x55e6a0`; s = max of the box's Δx, Δz; 40 = `+0x398`). The look-at point slides toward the pointer's ray by the same ratio | |

Reset: Original rebuilds (target and distance back to (0,13,0) and 35; new models start at yaw 0,
`0x55f100`). The stored drag angle `+0x394` is reset only by the ctor, so the first drag after
Original resumes from the old angle (INFERRED: its only writers are `0x560815` and the ctor).

### 4c. The try-on (READ)

**Trigger: only the "Wear Item" button** (`UIIT_STT_SILKMALL_PUT_ON`), in the cell menu (ID 10,
3c) or in the bundle box (ID 1703 → `0x7d9cd0` → the same `0x7df560`). No click or double click on
a cell tries anything on.

**What can be worn:** the cell's `+0x551` (3a): avatar items (3/1/13) except type-4 3, and the COS
items 3/2/1 whose COS passes `0x666c00` / `0x666c40` (meaning OPEN). A bundle never (`+0x555`).

**The gate** (`0x7df560`): nothing while the mall is busy (`+0x7c8`), a purchase is pending
(`+0x7dc`, INFERRED meaning) or the good's `0x8bf0d0` is set (OPEN). The first item, if it is
equipment (3/1), must pass the full can-equip test `0x8bb570(-1)`; otherwise the system line
`UIIT_MSG_STRGERR_EQUIPITEM` "Cannot equip the selected item" (`0x7781b0(5, …)`) and nothing more.
Then `mall.0x7d8bd0(item, cell+0x540)`.

`0x8bb570`'s tests that matter here: bit 0x40 gender (item ref `+0x1c4` = the player's, or 2 =
both); bit 0x200 race (ref `+0x9c` = the player's, or 3 = both); 0x08 ref `+0x1c8` ≤ the player's
word at `+0x21f`; 0x10 ref `+0x1cc` ≤ the word at `+0x87e`; 0x20 / 0x100 mastery and skill
tables; 0x80 dual slots. The meanings of 0x08, 0x10, 0x20, 0x100, 0x400, 0x800 are OPEN. **An
item for the other gender or race is refused with that line.**

**Putting it on** (`0x7d8bd0` = `0x7d88c0(item)` then `0x7d8720(goods)`):

1. The **try list** (`+0x810` / `+0x814`, ref ids): an entry with the same TypeID1..4 is taken off
   first (`0x7d8500(ref, 0)`), so **one per exact type**: one hat, one dress, one attachment …
2. The new ref id (`item+0x34`) is pushed.
3. If `0x8bb570(-1)` passes: `Render.0x560030(+0x854, refID, 1)`: an avatar (3/1/13) or devil
   spirit (3/1/14) by AttachAvatarVisual (`0x9daf80` → `0xa60ef0`); anything else by
   `InstallEquipVisual(ResolveVisualSlotForItem(TID), refID, plus 0, 0)` (`0x9daf70`); then a
   rebuild and action `+0x5a0` (0) again.
4. Else, a COS item 3/2/1 whose COS is 1/2/3/x: type-4 3 (`0x1800`) → model slot `+0x85c` at
   (−5.5, 0, −2.5); type-4 4 (`0x2000`) → `+0x858` at (4.5, 0, −2.5) (floats `0xdcc198`,
   `0xdcc190`, `0xdcc194`). Each is made once (`0x561780`) and swapped by the next
   (`0x561170`), takes the preview's yaw (`0x55fe70`) and plays action 0. INFERRED: 3 = a ride,
   4 = a pet, standing beside the player.
5. Anything else is pushed and draws nothing.

**The buy list** (`0x7d8720`, `+0x81c` / `+0x820`, count `+0x824`): a goods whose first item has
the same type as the new one is removed (`0x7d8140(pkg, 0)`), then the new goods is appended.

**Taking off** (`0x7d8500(ref, reapply)`): equipment by `Render.0x55ff20` (the slot cleared, or the
avatar detached by `0x9daf90`), then the entry is removed; with reapply, the player's own worn
avatar of that type goes back on. A COS model is deleted (`0x561480`) and its slot reset to −1.

**Lifetime:** the window section is loaded on open (`0x79b580` → `0x8b5580` "NewItemMall", window
0xa7) and destroyed on close (`0x8b59f0`), so **the try-on ends with the window**. It survives
category, tab, search and main-page changes: the reset (`0x7d8d30`) is called only by Original
and by `0x7d8d60`, the rebuild after a timed good sells out (`0x7de250` → `0x7de355`).

### 4d. Original and Buy (READ)

- **Original (109, `0x7d8d30`)**, only with no mall box open (`+0x7c8` = 0): `0x7d8480` clears the
  try list and `0x561040` deletes every model; `0x7d8840` clears the buy list; `0x7d8bf0`
  rebuilds as equipped (4a). The pet and the ride go.
- **Buy (110, `0x7d7080`)** needs no pending purchase (`+0x7dc` = 0), a non-empty buy list
  (`+0x824`) and no mall box. It opens `CIFNewItemMallMessageBox` (class `0xeec628`), ID 122,
  368×348, centred, at `+0x7d8`, filled by `0x7db490(&list)` from the `AllBuy` section of
  `ifnewitemmallmessagebox.txt`: title `UIIT_STT_SILKMALL_PUT_ON_CLOSE_BUY` "Buy Item Worn",
  prompt 1814 `UIIT_MSG_AVATAR_SILKMALL_LUMP_BUY` "Buy all equipped items?", list 1801 (one row
  per goods) with slider 1800, total 1810 with unit `UIIT_STT_ROLL_OF_CLOTH`, the inventory space
  1809, a point edit 1808 with button 1804. Busy set.
- The box's Buy (1818 → `0x7d9d70`) runs `mall.0x7d7d80`, then closes the box; Cancel (1817 →
  `0x7d9db0`) closes it. `0x7d7d80` sets lump mode (`+0x7e8`) and sends the list **one good per
  message**, the next on each purchase reply (section 6).
- After each bought good in lump mode the reply code (`0x87e2a3..0x87e2d5`) runs
  `0x7d8140(pkg, 1)` (drop it from the list, send the next) and `0x7d8500(ref, 1)` (take it off
  the preview; the player's real avatar of that type comes back).

### 4e. The event picture (controls 103 and 101; READ, `0x7d76e0`)

`0x7d76e0` reads `event\mall_notify.txt` (`Mall_Open`, `Mall_BeginTime`, `Mall_EndTime`,
`Mall_FrontImg`; the image path kept at `+0x7ec`/`+0x7f0`). When open and inside its dates, 103
(216×400 at 567,46, over the preview) shows `Mall_FrontImg` and the "Off" button 101 shows; the
preview stays hidden until "Off" (`0x7d6e60`). Otherwise both are hidden and the preview shows.
This archive's file has `Mall_Open "0"` (MEASURED). `Mall_ButtonImg`, `Mall_ButtonPosition`,
`Mall_ButtonString`, `Mall_MainTabIndex`, `Mall_SubTabIndex` are not read here; their reader is
OPEN (CIFMallNotifyWnd or CIFMallEventPopup).

### 4f. The info block (READ, `CIFNewItemMallMyInfo`, Create `0x7dd710`)

| Control | Shows | Source |
|---|---|---|
| 210 name | the player's name | `0x9d6580` on `[0xeef5ec]` |
| 209 level | "Lv. %d" of the byte at `+0x868` | |
| 208 silk | player `+0x4ac` | `0x3153` (6d) |
| 207 gift silk | player `+0x4b0` | `0x3153` |
| 206 point | player `+0x4b4` | `0x3153` |

With `0x4f9ca0()+0x160 == 4` the point row and controls 200 / 203 / 204 are hidden (INFERRED a
service code); 213 (`mall_moneybutton.ddj`) is always hidden.

**Buy Silk (212, `0x7dd4f0`) and Coupon (211, `0x7dd590`)**:
`ShellExecuteW("open", "IEXPLORE.EXE", "http://" + text)` with the text of
`UIIT_STT_SILKMALL_BUY_SILK_LINK` / `UIIT_STT_SILKMALL_COUPON_EXCHANGE_LINK`: an outside Internet
Explorer, no embedded browser. A button whose link text is shorter than 5 characters is
disabled. This archive: Buy Silk "SRO.com", Coupon empty, so Coupon is disabled. The `_02`,
`_03`, `_04` keys are never read.

### 4g. Buying list and Obtained list: silk histories, not carts (READ)

Both are `HISTORY_FOR_BUYING_SILK` windows (2DT, `2DT_FORMAT.md`), loaded with the mall
(`0x7d6eb0(1)`, `0x7d6f50(0)` in Create).

- **Buying list** (131): window 0x26 from **`res_ui\silksearch.2dt`** (`0x7d6ec3..0x7d6ee2`),
  loaded hidden. A period combo, an Inquiry button, 12 rows (No. / amount / date), a total line,
  a scroll bar. Inquiry (`0x7ecb90`) shows "Inquiry is in process. Please wait." and sends
  **`0x711a {u8 1, u8 period}`**, period 1..4 (INFERRED 1 day / 7 days / 1 month / 3 months).
- **Obtained list** (132): window 0x53 from **`res_ui\silkrecievelist.2dt`**, tabs "Gift Silk"
  and a received tab, rows of `ifsilkrecievelistslot.txt` (No. 10, amount 11, date 12). With
  argument 0 in Create the window is not loaded and **button 132 is disabled**
  (`0x7d6f26..0x7d6f3c`), so in retail the Obtained list is off (the screenshot's button is the
  dimmer one). Its own Inquiry and tab handlers only re-filter rows already received.
- **`0xB11a`** (`0x8990c0`): `u8 kind, u8 ?, u8 result`; non-zero result stops. Then
  `u16 n, n × {u32 amount, u32 date}`. Kind 1 fills the Buying list (row i+1, amounts summed into
  the total); other kinds the Obtained list. n = 0 → "No history is available."

## 5. Search (READ, `0x7e32d0`)

- Runs on the Search button or Enter in the edit (1c), and only when the text is not empty.
- Collapses the menu, removes the last search view (`+0x3ac`), makes a new `CIFSlotView` (ID
  0x1ffffff, width 400) in the goods column.
- Walks every good built for the shops (the map at `+0x3f8`); a good that passes the filter
  (3b) and whose package name (NameStrID through the text table) **contains** the text
  (`std::wstring::find`, `0x4ee310`, no case folding) gets a cell, two per row. There is no
  de-duplication here: a good listed in two tabs is shown twice (INFERRED from the absence of
  the `+0x91c` test).
- Shows that view (`0x7dbbf0`).
- Whether the edit clears "Write Item name" on focus is OPEN (`0x635030(1)` and `0x635150(2)` set
  on it at create).
- `res_ui\silksearch.2dt` is **not** the search: it is opened by `0x7d6eb0` (section 4).

## 6. The purchase flow (READ unless marked)

### 6a. From the cell to the box

Buy in the cell menu (11, `0x7ddb90`), with no mall box up and nothing being bought: a
`CNewItemMallConfirmBuy` (class `0xeec708`), ID 1200, 338×212, bound by `0x7e91c0(item)`; busy
`+0x7c8` = 1; `+0x7c9` = 1 when the cell is in the reserve view. The bundle box's Buy (1702 →
`0x7d9d00`) is the same handler. Its size matches `ifnewitemmallshopitemslot.txt` section `ConfirmBuy`
(`CNewItemMallConfirmBuy`, ID 1000, 338×212, frame `mall_ms_wnd_`, title `UIIT_STT_SILKMALL_BUY`);
the controls are `ifnewitemmallconfirmbuy.txt`'s: Buy 61, Cancel 62 (`mall_coice_button.ddj`),
quantity edit 42 (`mall_box_02.ddj`) with spin up 50 / down 51, icon 11 in frame 10
(`mall_icon_frame.ddj`), name 40, "Quantity" 21. Which code loads that file for the box is not
traced here (OPEN).

### 6b. The box: price rows and quantity

One row per bit of the package's price block (setup `0x7e7c30`, labels `0x7d9420`), 30 px apart;
the box grows to fit:

| Bit | Price field | Label / unit | Shows |
|---|---|---|---|
| 0x1 | `+0x08` | "Price" / "Gold" | price × count |
| 0x2 | `+0x10` | "Premium Silk" / "Silk" | price × count − points used |
| 0x4 | `+0x18` | "Gift Silk" | price × count |
| 0x8 | `+0x20` | "Guild point (GP)" / "GP" | price × count |
| always | – | "Remained space" / "Slot" | free inventory slots |
| 0x10 | `+0x28` | "Honor Point" / "P", with a point button opening `CItemMallUsePoint` (ID 400) | points used |
| 0x20 | `+0x30` | TC honor point / "P" | price × count |

Quantity (`0x7e8b20` / `0x7e8d10`): starts at 1; 0 aborts. A multi-item package is capped at 5
(INFERRED that `0x8bf0d0` means multi-item), a single stackable expendable at its MaxStack (ref
`+0x1c0`), anything else at 5. There is no gift option in this box (the main-page text says gifts
are "Currently not in service"; no gift sender was found, INFERRED).

### 6c. Buy in the box (`0x7e8320`) and the request

1. Too few free slots → error 0x1807 ("The inventory is full"); a stackable item needs 1 slot,
   others one per unit.
2. Silk price × count against silk + gift silk + point together; too little → 0x1880
   ("insufficient silks") and the box closes.
3. The count becomes the dealing counter (`0x7d6d80`); the request goes out through
   `0x826460`.

**`0x7034` type 0x18** (serializer `0x7923a0`, `0x792944..0x79299d`):

```
u8  0x18
u16 shopGroupWord   // first refshopgroup entry whose +0x28 byte is 1
u8  shopIndex       // the shop's place in its group's list (0x9379c0)
u8  tab
u8  slot
u16 len + chars     // a string from the package (INFERRED its CodeName)
u16 count
u64 pointsUsed      // left out in one mode, 0x667120()+0x10 == 3 (OPEN)
u32 packageId       // pkg+0xc (INFERRED the RefPackageItem ID)
```

The reply parser's request branch (`0x87eb50`) reads the same order. Both senders set a lock
(`0xee9b10` = 1), cleared by any `0xB034` (`0x87f3cf`). The second sender, `0x7978a0` (the
try-on Buy and the reserve Buy All), repeats checks 1 and 2 itself and on failure feeds a local
`B034 {2, 0x1807}` or `{2, 0x1880}` to its own handler. A lump buy is one request per good, the
next sent on each success (4d). The server side is `item_mall_wire.md`'s.

### 6d. Replies

- **`0xB034`** (`0x87f370`):
  - result 1: `u8 0x18, u16 shopGroupWord, u8 shopIndex, u8 tab, u8 slot, u8 n, n × u8
    inventory slot, u16 count`. The items are created in those slots (`0x6b7770`), the reserve
    list is refreshed if needed, a lump buy continues, the dealing counter drops (`0x7d6da0`),
    a sound plays. (That the 0x18 byte comes first is INFERRED.) **The goods go straight to the
    inventory**: the client has no other destination.
  - result 2: `u16 code`, shown by `0x778190`; the dealing counter is reset; "아이템 구입 실패"
    logged. Codes: 0x1807 inventory full, 0x1880 not enough silk, 0x1881 not enough silk to
    gift, 0x180f not enough gold.
- **`0x3153`** (`0x882de0`): `u32 silk, u32 gift silk, u32 point` → player `+0x4ac`, `+0x4b0`,
  `+0x4b4`; the info block refreshes.
- **`vslot_005(1)`** (`0x7d7230`): shows `UIIT_STT_SILKMALL_FAIL_ITEMBUY_LOGOUT` "Game will be
  closing because purchase of premium item has failed", then `0x778dc0(5000)` (INFERRED: quits
  after 5 s). Its trigger and timer 0x96 are OPEN.
- `UIIT_MSG_SILKMALL_SOLDOUT_ITEM` is used only by the old mall (`0x7b9218`).

## 7. What the client reads from textdata for the mall

| File | Read by | Fields the mall uses |
|---|---|---|
| `mallitemmenulistdata.txt` | table 0x55, `0x97fbe0` and `0x957444` | 2a |
| `refshop.txt` | table 0x23, `RefParse_refshop 0x983000` | ID `+0x8`, code `+0xc`; looked up by code (`0x926560`) |
| `refshopgroup.txt`, `refmappingshopgroup.txt`, `refshoptabgroup.txt`, `refmappingshopwithtab.txt` | tables 0x34, 0x35, 0x24, 0x26 | the shop → tab group → tab chain (`0x9262c0`, `0x982760`, `0x985a40`) |
| `refshoptab.txt` | table 0x25 | the tab's text key `+0x28` (column 5) |
| `refshopgoods.txt` | table 0x28, `0x983b70` | tab `+0x8`, package id `+0xc`, SlotIndex `+0x10` (u8) |
| `refpackageitem.txt` | table 0x27, `0x9811f0` | ID `+0xc`, code `+0x10`, **SaleTag `+0x2c`** (column 4), NameStrID `+0x4c`, DescStrID `+0x68`, icon `+0x84`; scrap rows at `+0xbc`; price block `+0xd0`; PreservedPrice `+0x130` |
| `refpricepolicyofitem.txt` | table 0x2a, `0x981ba0` | country `+0x8`, package id `+0xc`, PaymentDevice `+0x10`, PreservedPrice `+0x18`, Cost `+0x20` (int64); bound by `0x980d90` |
| `refscrapofpackageitem.txt` | table 0x29, `0x9824e0` | the package's items: the first item's type (wearable test) and count `+0x18` |
| `refshopitemstockperiod.txt` | table 0x56 | bit-32 goods' time window (empty here) |
| `shopitemstockquantity.txt` | (manager `+0x404`) | bit-16 goods' stock (empty here) |
| `event\mall_notify.txt` | `0x7d76e0` | the event pop-up (section 4) |

The join: menu row code → `refshop` (by code) → its tab groups and tabs → each tab's
`refshopgoods` (by SlotIndex) → `refpackageitem` (by code) → its `refpricepolicyofitem` row and
its `refscrapofpackageitem` rows → each item's `objcommon` record. Column-by-column detail is
`item_mall_data.md`'s.

## The Chest window (third screenshot): not retail

The screenshot's "Chest" window (tabs Chest / Take Log; columns No. / Item Name / Quantity /
From / Date; "Inventory Remaining 60"; a page control; Take All / Take) is **not in
`sro_client.exe`**. The evidence, beyond a string search:

- **No window class or layout.** The 249 `resinfo\*.txt` layouts in the archive (all extracted
  this round) contain no `UIIT_STT_BOX_*`, `VPLUS` or "chest" reference. `ginterface.txt` has no
  such window.
- **No text key in the exe.** The retail text table has an "Item Storage Box" family
  (`UIIT_STT_BOX_ITEMBOX_TOOLTIP` "Item Storage Box", `UIIT_STT_BOX_GOTO_LOG` "Take Log",
  `UIIT_STT_BOX_TAKE` / `_TAKE_ALL`, `UIIT_STT_BOX_REMAIN_INVEN` "Inventory Remaining",
  `UIIT_STT_BOX_TAKE_DATE`, `UIIT_STT_BOX_WEBMALL_TOOLTIP` "Web Silk Mall"), but no
  `UIIT_STT_BOX` string, ASCII or UTF-16, occurs in `sro_client.exe`, `sro_client_NODLL.exe` or
  `sro_client.bak`. The client looks texts up by key, so a window using them would carry the key.
  INFERRED: these rows belong to a later client and were merged into this table.
- **Its art and texts are vPlus's.** Media.pk2 has `vplus\iconpng\chesticon_{normal,focus,press,
  disabled}.ddj` and `vplus\menu\buttons\default_button_chest*.ddj`, and the text keys
  `VPLUS_UI_CHEST_*`, `VPLUS_UI_ITEM_STORAGE_BOX_*` ("Take Log", "Take", "Take All", "Inventory
  Remaining", "*Only logs from the last 7 days will appear."), `VPLUS_MSG_CHEST_ITEM_RECEIVED`
  "You have recieved item [%s] into your chest." and `VPLUS_MSG_CHEST_INVENTORY_FULL_ERROR`. The
  DLL (`vsroplus_lib.dll`, 13 MB) is packed: no readable strings.

So the chest, its minimap-side icon and its take flow are the vPlus add-on's. If OpenSRO builds
one, it is **OURS** (per the private-server rule: offer it as our own part). Which mall goods the
retail flow delivers to the inventory and what happens when it is full are section 6's and
`item_mall_wire.md`'s.

## OPEN

- **HOT shop and Reserved rows** (2a): this archive's code `xxx` hides them; the screenshot server
  shows them. Whether its `refshop` has an `xxx` row or its client differs.
- The goods column's scroll: whether the bar also moves the menu column (2d).
- The search edit and its default text on focus (5).
- The icon file the cell slot draws (`icon64` join, 3a) and the slot's hover help.
- Ref object `+0x2c8` bit 2 (unit count of 1, 3a); the scrap field `+0x18` = Data (INFERRED).
- `CMallItemData` `+0x8`, `+0x14`, `+0x18` (3d).
- The preview camera's rotation axes (4a); STAND1 looping (INFERRED).
- `0x666c00` / `0x666c40` (which COS items are previewable); `0x8bb570` bits 0x08, 0x10, 0x20,
  0x100, 0x400, 0x800; `0x8bf0d0`; `+0x7dc` (INFERRED pending purchases); mode 1 of `0xa617d0`;
  whether worn avatars are attached twice at build.
- The reader of `Mall_ButtonImg` / `Mall_ButtonPosition` / `Mall_ButtonString` /
  `Mall_MainTabIndex` / `Mall_SubTabIndex`.
- The bottom bar button's click handler; `0x56bce0` before `0x7121`; `0xB121`'s pairs; player
  list `+0x4c4`; `DONOT_USE_TELEPORT`'s user.
- The request string (CodeName or name); the `0x667120()+0x10 == 3` mode; `vslot_005(1)`'s caller
  and timer 0x96.
- `0xB11a`: its second byte, error codes, date encoding; who requests the Obtained list's rows;
  the period combo's order.
- `CItemMallUsePoint` (ID 400): its controls and flow.
