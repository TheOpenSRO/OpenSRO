# The stall network (round 840, lane N)

Retail's "Stall network" (`UIIT_STT_WARENETWORK_TITLE`): a window that searches the items other
players have put on sale in their stalls and buys one without walking to the stall. What the
original game has of it, what this client build left switched off, and what OpenSRO builds.
Player stalls themselves are `stall.md` (round 839, lane S); this file adds to it.

**Labels.** READ: read in the code -- `c:` sro_client.exe (`/var/tmp/decomp_client`, objdump of
`/opt/sro-files/client/sro_client.exe`), `s:` SR_GameServer.exe (`/var/tmp/decomp_server`,
`/var/tmp/srv.asm`), `sm:` SR_ShardManager.exe (`/var/tmp/decomp_shardmgr`) on the render box -- or
in the archive (Media.pk2, read on the box; nothing copied into the repo). MEASURED: counted on the
box. INFERRED: concluded, with the reason. OURS: OpenSRO's own choice. OPEN: not settled.

Code: `server/internal/session/stallnet.go` (the handlers, the search, the remote sale; the
network answers of 0x70BA in `stall.go`), `server/internal/stall` (the stall's network flag, the
listing's order number, the sale record's network columns), `server/cmd/partybot` (`-stall-net`,
`-net-search`, `-net-buy`); `client/scripts/net/stall_network_net.gd`,
`client/scripts/ui/hud/stall_network_controller.gd`, `stall_network_window.gd`,
`stall_network_box.gd`, `nif_page_manager.gd`, and the owner's side in `stall_controller.gd`.

## 0. What this build has, and what it switched off (READ)

The client carries the whole feature: the window class `CNIFStallNetwork` built from
`res_ui\stallnetwork.2dt`, its buy box `CNIFStallNetworkMsgBox` (`res_ui\nifstallnetworkmsgbox.2dt`),
three requests 0x7461..0x7463 with their answers 0xB461..0xB463 (registered at c:0x8948d8.. through
the second registrar FUN_00894ac0), the stall's network flag (CIFStall +0x864) and the network
fields of 0x70BA / 0xB0BA, the sale line of 0x30B7 kind 4 with the 1 % commission line, and every
text key (`UIIT_*WARENETWORK*`, `UIIT_CTL_WNETWORK_*`, `fmncategorytreedata.txt`). An older
`CIFStallNetwork` (`resinfo\ifstallnetwork.txt`, `ifstallnetworkslot.txt`) is still in the exe but
nothing opens it.

Three things are switched off in this build:

1. **The only way in is hidden.** The window opens from one place, FUN_00799020(1) (c:0x799020:
   loads `res_ui\stallnetwork.2dt` as window 0x96 and centres it), and its one caller with 1 is the
   underbar menu's item 120 (c:0x60ceeb; the menu's handler 0x60cd10, item id 120 decoded from its
   jump table 0x60cf98 / 0x60cf4c). The underbar's OnCreate hides item 120 with ShowWindow(edi = 0)
   unconditionally (c:0x60e2c0..0x60e2db). The hotkey captions `UIIT_STT_WARENETWORK_TITLE_SHOTCUT`
   "Stall network ( F )", `UIIT_STT_TOGGLE_CONTENTS_MENU_STORENET` and `UIIT_STT_INPUT_TTDESC_31` are
   in the text table but not in the exe (string search of both encodings, MEASURED) -- no key opens
   it.
2. **No stall is ever put on the network.** The owner's choice is a message box of type 1001: its
   answer handler c:0x6b9a20 (Yes: 0x70BA type 5 `{open 1, net 1}`, then +0x864 = the town test;
   No: `{open 1, net 0}`, +0x864 = 0) is in the exe, but nothing creates a type-1001 box: every
   setter of the box property "type" (c:0x644410 with the string 0xd8c45c, 23 sites) passes another
   value, and the question's text keys `UIIT_MSG_WARENETWORK_REGIST_01..03` ("Register items with
   stall network?" / "Items registered to the stall network can be sold easier," / "but 1% of the
   sold item will be paid as commission.") are not in the exe (MEASURED). The Start button itself
   (c:0x6b9940) always sends `{open 1, net 0}`. (Round 839's OPEN item 6.)
3. **This server answers nothing.** SR_GameServer.exe's handler table (base 0xcd3d08, 8 bytes an
   opcode: 0x70B1 -> 0xcd4290, 0x7470 -> 0xcd6088) has no entry written for 0x7461..0x7463
   (0xcd6010..0xcd6020; no store to them anywhere in srv.asm), and no binary of the server set
   (GameServer, ShardManager, AgentServer, GlobalManager) has 0x7461..0x7463 or 0xB461/0xB462 as an
   immediate (MEASURED). What is left in the GameServer is the sale's tail: AQ_ItemXChanger kind 2
   (vslot_007 s:0x43fe50 case 2 -> s:0x474430 -> s:0x473880) sends 0xB463 `{1}` to the buyer, may
   give ITEM_ETC_WARENETWORK_EVENT, and sends 0x30B7 kind 4; nothing sets kind 2 (the plain sale's
   `[stall+0x228] = 1`, s:0x472957, is the only store), so it is unreachable too. The shard manager
   and the game server both bind the table `_FleaMarketNetwork` (sm:0x645e50, s:0x854887): AbleOpen,
   CharID, Slot, TidGroupID, ItemClass, ItemCount, MakeZone, Cash (u64).

So the feature is real in this client's code and data, and dead in this build. **OpenSRO builds it,
and switches the three things on (OURS, disclosed):** the underbar's item 120 is shown, the Start
button asks the type-1001 question with the REGIST_01..03 text, and the server answers 0x7461..0x7463
by the rules below. Everything the client does with the answers is the client's own code.

## 1. The wire

| Opcode | Dir | Body | Client |
|---|---|---|---|
| 0x7461 | C->S | `u8 mode, u8 page, u32 group, u8 degree` | c:0x821ae0 (callers 0x6c4870 <- 0x6c9d70, 0x6c70d0) |
| 0xB461 | S->C | `{1, u8 n, u8 pages, n x record}` / `{2, u16 code}` | c:0x88dca0 |
| 0x7462 | C->S | empty | c:0x821bd0 (caller 0x799020(0)) |
| 0xB462 | S->C | `u8` (read and dropped) | c:0x88df60 |
| 0x7463 | C->S | `u32 owner, u8 slot, u64 price, u16 count, u8 level, u64 serial` | c:0x821c70 (callers 0x6c7c20, 0x6c8000) |
| 0xB463 | S->C | `{1}` / `{2, u16 code}` | c:0x88dec0; s:0x4738e9 sends `{1}` |
| 0x70BA | C->S | the stall's update; its trailing `u16 net` (below) | round 839 |
| 0xB0BA | S->C | its `u16` answers the network (below) | c:0x878230 |
| 0x30B7 | S->C | kind 4 `{4, u8 slot, str buyer, list}` -- a network sale | c:0x87a260; s:0x473a40.. |

Strings are `u16 length` + bytes; the list is round 839's (`stall.md` §2).

**0x7461 (READ).** `mode` 1 the first search since the window was opened (c:0x6c9f29, and the
process flag 0xeea828 is set), 2 a later search (c:0x6c9f1a), 3 a page of the last search
(c:0x6c71ca: the page's cache is empty and the page was never asked for). `page` 0-based
(+0x844; a search asks page 0). `group` the chosen type's TidGroupID ([node+0x54], the fifth column
of `fmncategorytreedata.txt`; on mode 3 the last search's, +0x848). `degree` the Degree combo's
index: 1..N for "N Degree" when the type has degrees, 0 when it has none (its only entry "None").

**0xB461 (READ c:0x88dca0, 0x6c98e0).** After `1`: `u8 n` -- the records in this answer --, `u8
pages` -- the result's page count (0: nothing found; the window is left as it was) --, then `n`
records, each:

| Field | Type | Client use |
|---|---|---|
| item | the item record (SOItem::FUN_008be4f0(stream, 1), as the stall list's) | icon, name (+0x218 from the ref's name key), the name red (0xffff4a4a) when 0x8bd0e0 says no -- round 829 read it as "can be repaired" |
| owner | u32 (rec+4) | echoed by 0x7463 |
| seller | str (rec+8) | the Seller box on a selection, the Whisper target |
| slot | u8 (rec+0x24) | echoed |
| count | u16 (rec+0x26) | the Quantity column, the buy box |
| level | u8 (rec+0x28) | the Level column |
| price | u64 (rec+0x30) | the Price column (`,` groups, coloured by amount 0x5d3df0), the buy box |
| serial | u64 (rec+0x38) | echoed |

The Number column is the client's own `page * 15 + i` (rec+0x40). INFERRED meanings: `owner` the
stall owner's unique id (the id 0x70B3 takes), `slot` the stall slot (`_FleaMarketNetwork.Slot`),
`level` the item's required level (the column caption UIIT_CTL_WARENETWORK_RESULT_LEVEL; the slot's
control `GDR_STALLNETWORK_SLOT_LEV` in the older layout); the buy echoes them so the server can tell
"the search result and current item data does not match". OURS: `serial` is the listing's own
number (`stall.Listing.Seq`, given when the item is listed), which tells a re-listing in the same
slot apart; the client only echoes it.

A refusal `{2, code}` shows category 10 (c:0x7b8b40); 0x3c49 also clears the window's flags and
closes it (c:0x88de71: 0x6bc890(0), 0x6bc6a0(0), 0x799020(0)).

**0xB463 (READ c:0x88dec0).** `{1}`: the window (if open) drops the bought row from its page cache
and puts the item into the client's own bag copy (0x6c89f0 -> 0x6b7770(-1, item)); with the window
closed, 0x6bc950 does the bag part only. `{2, code}`: category 0x1b for codes 1..5, else 10. Either
way window 0xb2 is refreshed (0x469020(0xb2) -> 0x5a2e90).

## 2. The codes (READ c:0x7b8b40 case 10, the jump table 0x7bb9f4 / 0x7bb998)

| Code | Text key | English (first row) | Where (OURS unless marked) |
|---|---|---|---|
| 0x3c41, 0x3c42, 0x3c43 | UIIT_MSG_WARENETWORK_ERROR_FAIL (and a system line) | Registraion of item on stall network has failed. | 0x3c42 the client's own (an item with no group, c:0x938370) |
| 0x3c44, 0x3c45, 0x3c47, 0x3c48 | -- (nothing shown) | | 0x3c48 a close reason of the network sale's DB job (s:0x43ffd2, s:0x472db2) |
| 0x3c46 | UIIT_MSG_WARENETWORK_SCAN_FAIL (box) | Searching has failed because too many users are in use. | a search sooner than 10 s after the last |
| 0x3c49 | UIIT_MSG_WARENETWORK_USE_CITY (box) | Stall network can only be used in town. | 0x7461 / 0x7463 outside a town; the client's own at the open (c:0x7990a5) |
| 0x3c4a | UIIT_MSG_WARENETWORK_USE_CITY | (same) | 0xB0BA type 5's network answer: the owner is not in a town |
| 0x3c4c | (case of its own, c:0x7b8bd9) | | not sent |
| 0x3c4f, 0x3c50, 0x3c51 | UIIT_MSG_WARENETWORK_BUY_ERROR | Purchase has failed because search result and current item data does not match. | the stall gone / not open / off the network; the slot's item or count changed; the price changed |
| 0x3c52 | UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD | Cannot buy due to insufficient gold | the buyer's gold below the price |
| 0x3c53 | UIIT_MSG_FLEAMARKET_ERR_INVENTORY_FULL | Cannot buy due to insufficient space in your inventory. | no free bag slot |

Text keys with no code in this client: UIIT_MSG_WARENETWORK_DIFF_WORK ("You cannot purchase items in
current state."), UIIT_MSG_WARENETWORK_EVENT, UIIT_MSG_WARENETWORK_REGIST_01..03 (MEASURED absent).
UIIT_MSG_WARENETWORK_ERROR_TRIANGLE ("Job items cannot be equipped/unequipped during the use of stall
network.") is pushed by another category (c:0x7b94f2), OPEN.

## 3. The window (READ, `res_ui\stallnetwork.2dt` and c:)

**The file (MEASURED, 148 records).** Root id 150 `CNIFStallNetwork`, 662 x 561, `mframe_wnd_`,
caption UIIT_STT_WARENETWORK_TITLE. Inside: the frame `int_window_` (10, 39) 643 x 511 on
`com_bg_tile_b`; the search box `frameg_wnd_` 5 at (16, 45) 632 x 40 with the captions Class (9),
Type (11), Degree (12) and the three combos 6 (104, 56) 160 x 20, 7 (349, 56) 120 x 20, 8 (550, 56)
90 x 20; Search 4 (534, 88) 112 x 24 `com_mid_button02`; "Seller" 13 (26, 96) and its box 14
(67, 96) 97 x 22; the list's black square 15 (19, 118) 627 x 374; the column buttons on
`stl_barwindow_button` -- Number 1397 (21, 121) 43, Level 1398 (64, 121) 85, Item 46 (149, 121) 86
(`com_bar02_left`), Name 1393 (235, 121) 200, Quantity 1394 (433, 121) 85, Price 1395 (518, 121) 126;
fifteen `CNIFStallNetworkSlot` rows 120, 129, .. 234 at (21, 143 + 23 k) 622 x 24, each `com_bar01_left`
121 with Number 122, Level 123, the icon 124 (`CIFSlotWithHelpEx` 16 x 16), Name 125, Quantity 126,
Price 127; the page manager 16 (280, 500) 91 x 17; Amount 19 and the gold box 20/21/22 at (30..215,
514); Whisper 17 (417, 516) and Purchase 18 (534, 516), 112 x 24.

**Its message map (READ 0xeb87e0, the handlers written by c:0xd6c950):** OnCreate 0x6c5140; combo 6
changed 0x6c4830, combo 7 0x6c2050, combo 8 0x6bc660; the page manager's 0x8071 0x6c70d0; a row
(0x78 for any of the fifteen, c:0x6bc5a0) 0x6c20d0; Purchase 0x6c83b0; Search 0x6c9d70; Whisper
0x6bf560; the five column buttons 0x6c71f0 (sort).

- **OnCreate** (c:0x6c5140): the combos' first entries "Choose" (UIIT_CTL_WARENETWORK_SCAN_SELECT)
  in Class and "None" (UIIT_CTL_WARENETWORK_SCAN_END) in Type and Degree, twelve lines each; Search's
  tooltip UIIT_MSG_WARENETWORK_SCAN_TOOLTIP; the class list from `fmncategorytreedata.txt`
  (0x6c41f0, 0x6becb0); Purchase off while the player's own stall window (GDR_STALL, 33) exists;
  Whisper off; the Seller caption 13 hidden; the page manager 4 buttons a group; the buy box loaded
  (window 300) and hidden.
- **The tree** (`server_dep\silkroad\textdata\fmncategorytreedata.txt`, MEASURED 72 rows: Service,
  key, text key, parent key, TidGroupID, degrees): a row whose parent is `xxx` is a class (15), the
  others its types (57) with their group and their degree count (11 for weapons, armour and
  accessories, 5 for socket stones, 0 otherwise). The captions are the rows' UIIT_CTL_WK_* keys.
- **Class changed** (0x6c4830): the type list refilled (0x6c43f0), Degree back to "None". **Type
  changed** (0x6c2050 -> 0x6c1ed0): with degrees, Degree is "Choose" + "1 Degree" .. "N Degree"
  (`%d %s`, UIIT_STT_CLASS); without, "None".
- **Search** (0x6c9d70): needs a type, and a degree when the type has degrees; then Search off for
  10000 ms (timer 1, vslot_005 turns it back on), every page cache cleared, page 0, and 0x7461 mode 1
  the first time (0xeea828 set) or 2.
- **The answer** (0xB461): the page caches resized to `pages`, the page manager set (current page,
  `pages`; the last group of four shows only what is left), the page's records stored and shown (rows
  0..14, 0x6caa40).
- **A row** (0x6c20d0, 0x6cb110): selected on `com_bar01select_left.ddj` (others `com_bar01_left`),
  Whisper on, the Seller caption shown and the box filled with the seller's name.
- **A page** (0x6c70d0): ignored while an answer is awaited (+0x84c); a page never asked for and
  empty sends mode 3, else the cache is shown.
- **Purchase** (0x6c83b0): with a row selected, its record copied to 0xeea850 and the buy box shown
  (0x6bf370: the icon, the name, the count, the price `%I64d`). Buy (4) -> 0x6c7c20: 0x7463 with the
  record's owner, slot, price, count, level and serial. Cancel (7) hides it.
- **Whisper** (0x6bf560): the whisper line opened to the seller.
- **Columns** (0x6c71f0 -> 0x6c6f70(key)): the shown page sorted by that column.
- **Close** (vslot_043 c:0x6bc6b0 -> 0x799020(0)): 0x7462 when 0xeea828 is set (the flag cleared),
  the window destroyed (0x468c50).

**The page manager** (`CNIFPageManager`, READ c:0x485690, 0x485ee0, 0x4866c0, 0x485940, 0x485b60,
0x4863a0): prev / next on `interface\mall\mall_page_prev.ddj` / `_next.ddj`, shown only when there
is a group before / after; four page buttons 20 wide, `%d`, the current one 0xffff9951 and bold, the
others 0xffffffff; prev 13 left of the first button, next 17 right of the last; prev / next move a
whole group of four (to its last / first page) and send 0x8071 (page index, page count).

**The buy box** (`res_ui\nifstallnetworkmsgbox.2dt`, MEASURED 18 records): root 300 454 x 192
`msgbox2_window_` "Confirm" (UIIT_STT_CONFIRM_BOX); the item window 50 `msgbox_itemwindow.ddj` with
the icon 27; the name 20 (275 wide, centred) in `frame_msg_` 14; the count 21 and "Amount"
(UIIT_STT_AMOUNT) 12; the price 22 (right) and "Gold" (UIIT_STT_GOLD) 13; Buy 4
(UIIT_STT_BUY) and Cancel 7 (UIIT_CTL_CANCEL), `com_button` 76 x 24.

## 4. The owner's side (READ unless marked)

- **0x70BA's `u16 net`** (c:0x6b99a0, 0x6b4bb6, 0x6b5ed1, 0x6b9940, 0x6b9a20): 0 while the stall is
  not on the network (+0x864 clear); while it is: price 4, add 2, remove 5; the state toggle: open
  `{1, net 1}` (the type-1001 Yes) and back to modify `{0, net 3}`.
- **0xB0BA's answer u16** (c:0x878230): type 1 accepts 0 and 4, type 2 0 and 2, type 3 0 and 5 --
  anything else is shown as a category-10 code; type 5: 1 prints UIIT_MSG_WARENETWORK_REGIST_SUCCESS
  "Registering of stall items at stall network is successful." in the system lines, 0, 2 and 3
  nothing, 0x3c4a (to the owner) the USE_CITY box. So the server echoes the request's value when
  the network took the change, or answers a code.
- **0x30B7 kind 4** (c:0x87a260; s:0x473a40..0x473ab6): as kind 3 -- the slot, the buyer's name, the
  list -- plus, to every participant, UIIT_MSG_WARENETWORK_BUY_SUCCESS "[buyer] has purchased [item]
  through stall network." and, to the owner, UIIT_MSG_WARENETWORK_CHARGE "[%s]gold has been paid as
  commission." with the commission = ftol(price x 0.01f) (the float 0.01 at 0xe1b820, read as a
  double: 0.009999999776482582), at least 1 and at most 100,000 (c:0x87a4bf..0x87a4ec); no line for
  price 0.
- **The town test** (c:0x6b9a7d, 0x7990a5): the region manager's slot 23 (CRegionManagerBody
  c:0x414560): the position's `regioninfo.txt` claim is kind 2, `#TOWN`
  (`REGIONINFO_FORMAT.md`).

## 5. The server (INFERRED from the client and the tail that is left; OURS where marked)

- **Registration.** 0x70BA type 5 `{1, net 1}`: the stall opens; if the owner stands in a town it
  goes on the network and the answer's u16 is 1, else it opens without and the u16 is 0x3c4a.
  `{1, 0}` opens off the network. `{0, 3}` (modify) keeps the stall registered but out of the search
  until it opens again; the answer echoes 3. The edits while registered echo 4 / 2 / 5. A stall off
  the network answers 0 to all of them. OURS: an open with any other net, or a modify with any
  other net, takes the stall off the network; a request without its trailing u16 counts as 0. The registration ends with the stall. OURS: the town is the
  server's own (`_RefRegion.IsBattleField` = 0, `server/internal/safezone`), where the client reads
  `regioninfo.txt`'s `#TOWN`; with no region table loaded every place counts as a town.
- **What is searchable:** every open, registered stall's listings whose group (the type-2 u32,
  `_FleaMarketNetwork.TidGroupID`) is the request's and, when the request's degree is not 0, whose
  item's degree (FUN_004775a0, round 838's `itemDegree`) is that degree. The seller's own stall is
  left out (OURS). Order (OURS): newest listing first. 15 records a page (the window's fifteen rows);
  at most 255 pages.
- **The session.** Mode 1 enters the network, 0x7462 leaves it (0xB462 `{1}`); mode 1 and 2 take a
  new snapshot of the matches, mode 3 serves a page of the snapshot, each record re-read from the
  live stall (a listing gone since is left out of its page; OURS). A mode-3 page past the last is an
  empty `{1, 0, pages}`.
- **Refusals:** outside a town 0x3c49 (0x7461 and 0x7463); a new search (mode 1 or 2) sooner than
  10 s after the last 0x3c46 (OURS: the client's own interval, UIIT_MSG_WARENETWORK_SCAN_TOOLTIP);
  a malformed request 5.
- **The remote sale (0x7463).** In order: in a town (0x3c49); the stall world check -- alive, not
  in a stall, an exchange, an NPC talk or a pending party (0x3c16, OURS; an owner is refused here
  too); not the buyer's own id (5); the stall there, open and on the network (0x3c4f); a sale
  already running in it (2); the slot used and still the listing, count and serial searched
  (0x3c50); the price the same (0x3c51); then, in the one transaction round 839's sale uses, the
  buyer's gold (0x3c52), a free bag slot (0x3c53), the stack to the buyer's first free slot, the
  price from the buyer and the price less the commission to the owner, and the sale row. Then 0x304E
  gold to both, 0xB463 `{1}` to the buyer, 0x30B7 kind 4 to the stall's participants (the owner
  included; to the owner alone when the stall closed meanwhile), the slot cleared. As round 839: no
  0xB034; the clients refresh their bags (OURS). A transaction that fails answers `{2, 0x3c48}`
  and closes the stall with 0x3c48 (READ: retail's close reason for this job, s:0x43ffd2,
  s:0x472db2; OURS: nobody is disconnected, as round 839's 0x3c2f).
- **The commission** is the client's own figure (§4): ftol(price x 0.01f), 1..100,000, 0 for price 0;
  the owner's gold rises by price - commission. INFERRED from the client and REGIST_03's "1% of the
  sold item will be paid as commission".
- **The event** (READ s:0x473988..0x4739e4): when the buyer's gold change is -100,000 or less, each
  side gets ITEM_ETC_WARENETWORK_EVENT (ref 9311, 3/3/13/1) with `rand() % 1000 == 1`. OURS: added
  to the bag after the sale's own transaction and the bag list sent; nothing when the bag is full.
- **Persistence.** The registration is live state, like the stall it belongs to (a restart closes
  every stall). The sale is `stall_sales` with two columns more, `network` and `commission`, added by
  the package's idempotent DDL (`ALTER TABLE .. ADD COLUMN IF NOT EXISTS`). `_FleaMarketNetwork`
  (retail's persisted index, MakeZone for the shard's game servers) has no OpenSRO table: one
  process holds every stall.

## 6. OURS, disclosed

- The underbar menu's item 120 is shown and opens the window (retail hides it, §0). It shares 117's
  row in the file, so the menu grows one row (25) upwards, the items down to 117 move up a row and
  120 keeps the row; its caption is UIIT_STT_WARENETWORK_TITLE (the record's is empty). While the
  menu is open the bar is raised above its siblings (the system message window lay over the lower
  rows and took their clicks) and put back when it closes.
- The Start button of a stall asks the type-1001 question ("Register items with stall network?",
  REGIST_01..03, Yes / No) while the owner stands in a town; outside a town it opens the stall off the
  network as retail's Start does. The box is MsgBoxSimple's 360 x 151 made 26 taller, its buttons
  moved down with it, so the three lines clear them.
- Box codes (0x3c46, 0x3c49) go to an OK box (MsgBoxSimple style 0); retail's path for them
  (c:0x7b9ddd -> 0x77b580) was not read further.
- The server's rules in §5 marked OURS or INFERRED: there is no server code to read.

## 7. OPEN

1. What 0x3c41 / 0x3c43 / 0x3c44 / 0x3c45 / 0x3c47 / 0x3c4c meant to the original server.
2. UIIT_MSG_WARENETWORK_ERROR_TRIANGLE's category and code.
3. Whether the original listed a stall while it was being modified (AbleOpen).
4. `_FleaMarketNetwork.MakeZone`'s values.
5. The order the original server returned the matches in.
