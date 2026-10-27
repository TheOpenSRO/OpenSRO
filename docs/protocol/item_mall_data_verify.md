# Item mall data spec: adversarial verification (round 837)

This review re-reads the claims in `docs/protocol/item_mall_data.md` on 2026-10-27.

**Sources.**
- `sro_client.exe` (`/var/tmp/sro_client.asm`, `/var/tmp/decomp_client`). The local copy and the box's copy have the same md5.
- `SR_GameServer.exe` (`/var/tmp/gs_dis.txt`, `/var/tmp/decomp_server`).
- The shard export `/opt/sro-files/db/csv/r837/export_r837/` (tables and `procs/*.sql`; the Korean comments were decoded from CP949). CT 104 was not started.
- Three copies of the tables:
  - **A**: extracted again from `/opt/sro-files/client/Media.pk2` for this review, rather than reusing `/var/tmp/r837data/`.
  - **B**: the y0gi vPLUS `SR_GameRefData`.
  - **C**: the shard CSVs.

The extracts, the counting scripts and the decoded badge icons are outside the repository, in the round's scratchpad: `r837/verify_data/` (data) and `r837/verify_scripts/` (scripts). No row of any table is quoted here beyond the worked examples the spec already gives.

`c:` is a client address and `s:` a server address.

Verdicts:

- **CONFIRMED**: the code at the address, the procedure or a recount says what the spec says.
- **CONFIRMED+**: right, and the review adds something that matters.
- **UPGRADED**: the spec had it as INFERRED or OPEN; it is now READ.
- **WRONG**: the correct reading is given.
- **PARTLY**: right in substance, wrong in a detail or a label.
- **NOT SUPPORTED**: an inference that the code does not back.
- **UNVERIFIABLE**: could not be checked with what is on the box.

## WRONG items first

| # | Spec claim (section) | Correct reading | Evidence |
|---|---|---|---|
| W1 | §1.2: the mall-group flag is set "when the code **starts with** `GROUP_MALL` (a 10-character compare)" | **It is an exact match.** `0x47ec20` is `basic_string::compare(0, size(), L"GROUP_MALL", 10)`, so only `GROUP_MALL` (1051) gets `+0x28 = 1`, and none of the `GROUP_MALL_*` groups does. The flag is how the window finds its group: `c:0x9262c0` returns the first group with `+0x28 == 1`. That group's `+0x2c` is its list of mapped shops. | `c:0x9843ce..0x9843e6`: `push 0xa`, `push 0xde1224` (= `L"GROUP_MALL"`), `push [ebp+0x14]` (the code's length), `push 0`, `call 0x47ec20`, then `mov byte [edi+0x28],1` |
| W2 | §1.6: "A's `MALL_CONSUME_SCROLL` has 1, 4, 5, 7, 8, because **C's Service-0 rows** fill the rest" | **C's Service-1 rows fill the gaps.** C has Service-1 rows at slots 0, 2, 3 and 6 (two damage scrolls, two 1x-unit scrolls and `PACKAGE_REVX11_..._REVERSE_RETURN_SCROLL_SPECIAL`) that A's file lacks. C's only Service-0 row in that tab is at slot 4, beside A's Service-1 row there. More generally, A is **not** "C's Service-1 rows": C has 268 Service-1 goods and 12 Service-1 tabs that A lacks (the `STORE_KT_*_EU_TAB*` tabs, plus 4 scroll goods and 4 Alchemy goods in the mall) | recount of `_RefShopGoods.csv` against A's `refshopgoods.txt` |
| W3 | §1, row-count table: B is "-" for `gachaitemset` / `gachanpcmap` and for the four `shop*data` files | **B has all six.** `gachaitemset` has 26 rows and `gachanpcmap` 1. `shopdata` has 57 rows, `shopgroupdata` 64, `shoptabdata` 161 and `shopitemdata` 1,392. A's `shopdata`, `shoptabdata` and `shopitemdata` are **identical to B's** and carry no copyright line; only A's `shopgroupdata` (98 rows) has Pandora's line | recount; row-by-row compare |
| W4 | §4, end: "No mall good of A or B uses bits 8 through 1024" | **B's mall uses bit 16** (mileage): 66 of its 68 goods are `(2,4,16)`. The true statement is that no mall good uses bit 8, bit 32 or the token bits 64..1024 | recount of B's price rows joined to its 16 mall tabs |
| W5 | §4: `s:0x4f0940` "clamps each to 0 **and sends** `0x3153`" | It writes the three clamped balances to `+0x2188`, `+0x218c` and `+0x2190`. It **sends `0x3153` only when its argument is 1**. The purchase deduction calls it with 0. **When `0x3153` is sent:**<br>- when the balances are loaded: `AsyncQuerySucceeded` case 9, `s:0x4e781d`;<br>- after the purchase's database job: `s:0x4e9b6c`, which sets the balances from record `+0x98`, `+0xa0` and `+0xb0`;<br>- from the external silk-update handler `s:0x4f0750`, which first sends `0x3154 [u8 type][u8 reason][u32 remain]`. | `s:0x4f0940..0x4f0952` (clamps, then `cmp [esp+4],1`); deduction `s:0x618e4c`/`0x618e52` |
| W6 | §4: "The three silk balances come from `_GET_REMAIN_SILK (@JID, @Silk_Own, @Silk_Gift, @Mileage)`…". It also gives the procedure's argument order as evidence for which balance is which. | **The game server never calls `_GET_REMAIN_SILK`.** The name occurs nowhere in `SR_GameServer.exe`, in ASCII or UTF-16. `AQ_GDBSelector` (`s:0x4502dc..0x450310`) calls `s:0x6a1750`. That function fetches `"%sbilling_silkdatacall.asp?JID=%d"` over HTTP, reads three numbers, checks an MD5 over them, and stores them in that order at query `+0x2c`/`+0x30`/`+0x34`, which become `[0x862]`/`[0x863]`/`[0x864]`. The procedure's argument order is therefore no evidence. **The mapping is now READ another way:** the purchase call (`s:0x45e215..0x45e271`, format `{CALL _STRG_ADD_PACKAGEITEM_WITH_STOCKQUANTITY (…)}` at `0xae5540`) passes record `+0x98` as `@OwnSilkToPay`, `+0xa0` as `@GiftSilkToPay`, `+0xb0` as `@MileageToPay` and `+0x88` as `@PaymentDevice`. The deduction fills `+0x98` from `[0x862]` and `+0xa0` from `[0x863]`. So `[0x862]` is own silk, `[0x863]` gift silk and `[0x864]` mileage. **This closes OPEN 6.** | `decomp_server/funcs_007.c:38181` (the URL format); the call-site format string was re-read by this review. The argument-to-offset mapping is the server fork's reading of `0x45e215..`, spot-checked at the call site only. |
| W7 | §5, third ground: "A's live examples match the screenshot's badges" (Reverse Return Scroll, Instant Return Scroll, Global chatting and the Celestial Tiger under "Best item" with H; lotteries and the speed scroll N; Clock, Extension gear, Elite Starter Packages and Special Reverse Return Scroll R) | **The screenshots do not show A's data.** The A values the spec quotes are right (A's 13 non-zero SaleTags, recounted), but none of them appears in the screenshots.<br>- **New item** (`IBcFopf.png`): Title Color Scroll, Anonymous Global ×2, Inventory Expansion, Remote Storage and three Evil Thoughts. None of A's SaleTag-1 goods (three lotteries, `PACKAGE_DUX_ITEM_SPEED_105`) is among them. No package in A, B or C sells `ITEM_MALL_INVENTORY_ADDITION`.<br>- **Best item** (H): Reverse Return Scroll (Special) at 100 silk, 11 Unit. In A, `PACKAGE_REVX11_…` has SaleTag **8**, costs 75 and is listed in **no** tab. Pegasus has SaleTag 0 in A. The Clock of Reincarnation has SaleTag 8 in A. Premium GoldTime PLUS shows 500, where A has SaleTag 0 and 498.<br>- **Alchemy menu row:** the screenshot shows one. With A, the client would **hide** it, because all three of A's `MALL_ARCHEMY_*` tabs are empty and `0x7e3090` drops a shop with no good (see U5).<br>So the screenshot server's content is neither A nor C. The SaleTag meaning no longer rests on this ground (it is READ, U1). | screenshots `r837/refs/IBcFopf.png`, `u0s3YNP.png`; recount of A's `refpackageitem`, `refshopgoods`, `refpricepolicyofitem` |
| W8 | §5: "`mall_icon_recommendation` (sic, no extension)" | The name is **`interface\mall\mall_icon_recommendation .ddj`**, with a space before `.ddj`. The exe's string and the archive entry agree | `pk2list -filter "interface\mall\mall_"`; exe string `c:0xdcca7c` |
| W9 | §9: "**Every cash item's Price is 0** (MEASURED on the items above). So a silk good sold at one of A's NPC stores … sells for the formula's gold today" | It holds for the traced items, but **not in general.**<br>- 623 of A's 1,794 CashItem=1 items have itemdata Price ≠ 0, including the items of 138 of A's 220 mall goods (mostly Price 1).<br>- Of the 718 silk-priced NPC-store goods, 426 have Price 0 and sell at `shop.Price`'s formula.<br>- The other **292** sell at their itemdata Price (1, 200, 65, 35, … gold), because `shop.Price` returns `item.Price` when it is > 0 (`server/internal/shop/shop.go:81-86`).<br>Either way, none sells for silk. | recount of A's itemdata column 26 (Price) against column 7 (CashItem); `shop.go` |
| W10 | §4: "1,726 of its rows price **NPC equipment** in them" | 1,726 token rows is right. They price 1,630 equipment rows (3/1), 83 expendables (3/3) and 13 COS items (3/2). Only 1,236 of them belong to a package that some tab sells | recount |

## UPGRADED (INFERRED / OPEN → READ)

| # | Spec claim | Now READ | Evidence |
|---|---|---|---|
| U1 | §5 / OPEN 1: SaleTag is the hot-list mask (INFERRED); the code that tests it was not found; which badge each bit draws was OPEN | **READ.**<br>- **Badges** (`FUN_007dec60`): the u16 is read at `c:0x7decaf` as `[pkg+8+0x24]`; `0x9809b0` is `lea eax,[ecx+8]`, so this is `+0x2c`.<br>- **List filling** (`FUN_007e4a90`, `0x7e4dc8..0x7e4e59`): every good of every drawn tab goes into a list per bit (1, 2, 4, 8, 0x10). Bit 0x20 shares the 0x10 list. `FUN_007e5160` keys the lists by bit at UI `+0x8a4`.<br>- **Main page** (`FUN_007e3c00`, `0x7e3cca`): walks the Service-1 hot-list rows in key order and looks up each list by the row's bit. | the badge table is below the main tables |
| U2 | §5: "Which bit draws which icon, and whether H is 'popular' (bit 2), is OPEN" | Each bit is tested at the address shown, and the letters come from decoding the five `.ddj` files.<br>- **1** (`0x7decdf`): `mall_icon_new.ddj`, blue **N**.<br>- **2** (`0x7ded57`): `mall_icon_limited.ddj`, red **H**.<br>- **4** (`0x7dedcc`): `mall_icon_sale.ddj`, green **S**.<br>- **8** (`0x7deeb4`): `mall_icon_popular.ddj`, magenta **R**.<br>- **0x10** (stock) and **0x20** (period): `mall_icon_recommendation .ddj`, purple **D**.<br>**The file names do not match the letters**: "limited" draws H for Best, and "popular" draws R for Recommend. The spec's INFERRED "H = bit 2" stands. | `c:0x7dec60`; icons decoded in `r837/verify_data/icons/` |
| U3 | §5: "HOT shop … lists the SaleTag-marked goods" (INFERRED from shop `xxx`) | The window recognises it by its **text key** `UIIT_STT_SILKMALL_HOT_STORE` (`c:0x7e53f8`), and Reserved by `UIIT_STT_SILKMALL_SHOPPING_BASKET_LIST`. Its page (`FUN_007e38f0`) shows sections for bits 1, 2, 4, 8 and 0x10, with hard-coded headings (`0x7e5e13..0x7e5e5b`). So the HOT shop shows a **Sale** section even though the hot list's Sale row has Service 0 | `c:0x7e38f0`, `0x7e53f8` |
| U4 | §3 col 0: "Service: 0 skips the row" (INFERRED) | READ for both sections: `c:0x95738a` parses the first token and `0x95739d` skips the row when it is 0 | |
| U5 | §3 / OPEN 2: why "Bundle goods" is missing | READ (`c:0x7e5201..0x7e5287`). The menu parser stores column 2 through `0x97f920`, which turns `xxx` (`0xd81d38`) into an **empty** string (`c:0x97fc66`). A row with an empty code **is created**: that covers HOT shop and Reserved. A row with a code is created only if `0x926560` finds that `refshop` code and `0x7e3090` finds a tab with at least one good.<br>- `MALL_PACKAGE` has no `refshop` row, so Bundle goods is hidden.<br>- With A, **Alchemy is hidden too** (no goods). | `c:0x7e522b` (`cmp [esi+0x3d8],ebx`: code length 0 → `+0x370 = 1`) |
| U6 | §1.2: "That `+0x28` is the NPC field is INFERRED" | READ. `RefShopGroup_ExtractData` (`s:0x6a9fb0`) sets `+0x28 = 0` when the NPC column is the 3-character placeholder. Otherwise it stores the NPC's ref id, and it stops with "can't find assoc NPC with this shop" when the NPC does not exist. `FUN_00411b30` creates a silk shop for every group with `+0x28 == 0` | server fork; the constant was not dumped (presumably `xxx`) |
| U7 | §1.6 / OPEN 11: the `"MALL_"` assert's record (INFERRED to be the tab) | READ: the tab. `RefShopGoods_ExtractData` looks the tab up at `s:0x6a9b60`. `s:0x6a9cd5` then searches the tab's CodeName128 (`+0xc`) for `"MALL_"` anywhere in it. A miss only raises a debug assert, so A's 741 cash goods in `STORE_*` tabs load anyway | server fork |
| U8 | §1.7 / OPEN 4: ExpandTerm meaning; `FUN_00425260` | `RefPackageItem_ExtractData` (`s:0x6a94a0`) compares the string with **`EXPAND_TERM_ALL`** and **`EXPAND_TERM_ONE`**, and asserts "insert a PricePolicyConditionLevel" only when it matches neither. At purchase (`s:0x617950`), `ALL` passes only when the request's price covers **every** payment device the package has. `ONE` asserts in debug and then passes when any device is set. Only `ALL` occurs in A, B and C | server fork |
| U9 | §4: "That the window shows the same number is INFERRED" | READ: the cell's price (`FUN_007de0d0`, `c:0x7de0f4`) is always **bit 2's** Cost, at slot 1 of the price block. Bit 4's and bit 16's Costs are never drawn in the cell | client fork |
| U10 | §1.9 / OPEN 5: PreviousCost drawn? "never filled" | `c:0x980d90` copies each row's PreviousCost to package `+0x130`, and the **last row wins**. The cell draws `+0x130` next to the bit-2 Cost **only for SaleTag bit 4** (`0x7dedd4..0x7dee3e`). Whether it is struck through is not verified. No good of A has bit 4, so nothing is drawn | client fork |
| U11 | OPEN 10: are `CShopData`/`CShopGroupData`/`CShopTabData`/`CShopItemData` filled? | The loader has parse cases for them (types 0xe..0x11), but **none of the 90 load calls passes those types**, so they are never filled. Caveat: each type id was read from the constant pushed at the call site | client fork |
| U12 | OPEN 8: `shopIndex_InGroup` | **Half settled.** The index is into a per-group list built at boot by `FUN_004119e0`: one shop per `_RefMappingShopGroup` row, in the order the rows were loaded. The lookup is `s:0x523740` → `0x5236f0`, which returns 0 when the index is out of range. The SQL's row order was not read, so whether it matches the client's file order (alphabetical in A, B and C) stays OPEN | server fork |
| U13 | §6 "N Unit" = scrap Data | READ (`FUN_007df1f0`): `" %d"` (`0xdccaac`) + `UIIT_STT_UNIT`, using the first scrap row's Data (`+0x20`). The count is 1 when Data is 0, when the good holds several items, or when an item-ref flag forces it. A stock-limited good shows its stock count instead | client fork |

### Badge table (U1, U2), as the build should use it

| SaleTag bit | main-page list (hot-list row) | badge file | letter |
|---|---|---|---|
| 1 | New item (key 2) | `mall_icon_new.ddj` | N |
| 2 | Best item (key 3) | `mall_icon_limited.ddj` | H |
| 4 | Sale item (key 5, Service 0: not on the main page; in the HOT shop) | `mall_icon_sale.ddj` | S, and the PreviousCost and arrow |
| 8 | Recommend (key 4) | `mall_icon_popular.ddj` | R |
| 16 | Limited Sales (key 1): stock quantity | `mall_icon_recommendation .ddj` | D, and the stock left or "Sold out" |
| 32 | (key 6, Service 0) shares the 16 list: sale period | `mall_icon_recommendation .ddj` | D, and the time left; hidden outside the period |

## 0. Sources

| Claim | Verdict | Evidence |
|---|---|---|
| A ends every listed shop table with `//Copyright ® Pandora Online 2019` | CONFIRMED | One trailing `//` line in refshop, refshopgroup, refshoptab, refshoptabgroup, refshopgoods, both mappings, refpackageitem, refscrapofpackageitem, refpricepolicyofitem, shopgroupdata and gachaitemset. **Not** in `mallitemmenulistdata`, `shopdata`, `shoptabdata` or `shopitemdata` (W3) |
| "Its shop content is that private server's" (labelled MEASURED) | PARTLY (label) | The marker is MEASURED; that the content is Pandora's is INFERRED from it |
| Client is vSRO 1.188 with `vsroplus_lib.dll` | CONFIRMED (the DLL is in the client directory) | |
| B has no copyright line, about a third of A's rows (4,938 vs 14,918) | CONFIRMED | |
| B's `refpricepolicyofitem.txt` has 13 columns, without PreviousCost | CONFIRMED | Every row has 13 fields; Cost at index 4 |
| C: every row of A is in C except 510 scrap rows naming the `_RARE` twin | CONFIRMED | All 510 differ only in column 3, and C's value is A's + `_RARE` |
| C: `_RefPricePolicyOfItem`, `_RefPackageItem`, `_RefShop` identical to A's Service-1 rows | CONFIRMED+ | Also identical: `_RefShopGroup` (111), `_RefMappingShopGroup` (110), `_RefGachaItemSet` (14). C has more Service-1 rows in the mapping-with-tab (+4), tab group (+4), tab (+12) and goods (+268) tables (W2) |
| C's procedures are "Joymax code" | PARTLY (label) | The notes `by kkongs`, `by novice 2010-01-15` and the Korean comments are present. "Joymax" is INFERRED from them |
| Country 15 on every row; `_RefShopObject` = `15, SILKROAD_VIETNAM` | CONFIRMED | |

## 1. Tables

| Claim | Verdict | Evidence |
|---|---|---|
| Encoding: UTF-16LE with BOM, CRLF, tabs, "each row ending in a tab"; empty = BOM only; B without the trailing tab | PARTLY | Right for most tables. Exceptions in A: 719 `refpackageitem` rows and 997 `refpricepolicyofitem` rows end in **two** tabs, and `mallitemmenulistdata` rows end in **no** tab. A reader must ignore any number of trailing empty fields |
| Each client parser reads one token fewer than the file has columns (16/17, 13/14, 12/13) | CONFIRMED | client fork; the loader reads column 0 |
| Every row count in the §1 table (A, B, C all/Service 1) | CONFIRMED except B's "-" cells (W3) | recount: 93/57/107/93, 111/58/124/111, 110/57/123/110, 114/64/133/118, 113/66/128/117, 298/162/325/310, 2,778/1,425/3,302/3,046, 3,130/964/3,130, 3,130/964/3,130, 5,041/1,121/5,041; stock, period and rent tables 0; policy tables 0 in A and B, 1 Service-0 row in C; gacha 14/1/6 and C 52/14; shop*data 57/98/161/1,392 |
| C keeps 14 Service-0 `_RefShop` rows, all `STORE_*` | CONFIRMED | |
| §1.1 MALL shop ids 965/994/996/1002/1003; no `MALL_PACKAGE`/`MALL_EVENT` shop; params -1/`xxx` | CONFIRMED | A and B |
| §1.2 group ids 977/1006/1008/1014/1015/1051, NPC `xxx`; A also has `GROUP_STORE_SD_ACCESSORY` without an NPC | CONFIRMED | |
| §1.2 client parser: Country +0, u16 ID +4, code +8, NPC → +0x24 | CONFIRMED | `c:0x9842e0`. The NPC test is an exact compare with `xxx` |
| §1.2 the `GROUP_MALL` prefix test | **WRONG, W1** | |
| §1.2 server registers groups without an NPC at boot; "Silkmall is successfully initialized"; the `s:0x526610` log | CONFIRMED (`+0x28` meaning upgraded, U6) | server fork |
| §1.3 only `GROUP_MALL` maps the mall shops, alphabetically; `GROUP_MALL_*` unmapped; each `MALL_X` → `MALL_X_GROUP1` | CONFIRMED | A, B (and C) |
| §1.4 tab group ids 1056..1060 and name keys; "Visuals" in A's English | CONFIRMED | `UIIT_STT_SILKMALL_AVATA`: the 16-column row reads "Visuals" and the 19-column row "Avatar"; the client keeps the first row (`exchange_verify.md` W8) |
| §1.5 / §1.6 column lists and types | CONFIRMED | `_schema.tsv` |
| §1.6 client parser offsets (+4, +8, +0xc, +0x10 byte) | CONFIRMED+ | `c:0x983b70`. The loader (case 0x28, `c:0x954259`) does not keep the row: `0x985590` stores the good at `[tab+0x4c vector + SlotIndex*4]` |
| §1.6 SlotIndex < 240 (`s:0x720a81`) | CONFIRMED | server fork |
| §1.6 (tab, slot) unique; max slot 190 (A) and 35 (B) | CONFIRMED | |
| §1.6 scroll-tab gaps filled by C's Service-0 rows | **WRONG, W2** | |
| §1.6 `RefShopGoods_ExtractData` CAN_SELL and `"MALL_"` asserts | CONFIRMED (record upgraded, U7) | |
| §1.6 A has 741 cash goods in non-mall tabs; B has none | CONFIRMED | 189 / 183 / 147 in `STORE_AVATARS_TAB1..3`, 91 in `STORE_TITLES_TAB1`, … |
| A's goods params: -1/`xxx` on every row | PARTLY | 905 of A's rows have `xxx ` with a trailing space |
| §1.7 package parser offsets (+8, +0xc, +0x10, u16 +0x2c, +0x30, +0x4c, +0x68, +0x84) | CONFIRMED | `c:0x9811f0` |
| §1.7 SaleTag counts A 0×3,117, 8×5, 1×4, 2×4; B all 0; ExpandTerm always `EXPAND_TERM_ALL`; 295 upper-case `XXX` descs | CONFIRMED | 12 of the 13 non-zero SaleTags are in a mall tab; `PACKAGE_REVX11_…` (8) is in no A tab |
| §1.7 server reads SaleTag at +0x28, then ExpandTerm | CONFIRMED (ExpandTerm upgraded, U8) | |
| §1.8 scrap columns; one scrap row per package (3,130/964/3,130); Index unique; mall OptLevel 0 and MagParamNum 0 | CONFIRMED | |
| §1.8 `c:0x9824e0` parse; `c:0x8bf3a0` builds the displayed item from OptLevel + MagParams | CONFIRMED+ | Offsets: item +0x10, OptLevel +0x14, Variance +0x18, Data +0x20, MagParamNum +0x24, MagParams +0x28... A row with an unknown item code is dropped. The display builder **does not use Variance**. |
| §1.9 price parser offsets (+8, +0xc, +0x10, PreviousCost +0x18 as 64-bit, Cost +0x20) | CONFIRMED | `c:0x981ba0`. PreviousCost is read as int and sign-extended |
| §1.9 one bit per row; (package, device) unique; every mall package priced; PreviousCost 0 on every A row | CONFIRMED | |
| §1.9 server parser: PaymentDevice +8, Cost +0x14, PreviousCost skipped | CONFIRMED+ | `RefPricePolicyOfItem_ExtractData s:0x6a8b80`. The server loads these rows from the database, so B's 13-column text file never reaches it |
| §1.11 stock, period and rent tables: columns and procedure behaviour | CONFIRMED | `_STRG_ADD_PACKAGEITEM_WITH_STOCKQUANTITY`, `_Rent_Info_Manager`, `_DelExpiredRentItemInStorage` (see M6 for details the spec omits); `s:0x83a3d0` `DB_Load_RefRentItem` |
| §1.12 policy tables unused | CONFIRMED (data) | |
| §1.13 legacy files not loaded; no string in the exe; RTTI classes | CONFIRMED (OPEN 10 settled, U11) | Neither ASCII nor UTF-16 occurs |
| §1.13 `_RefShopItemGroup` 108 rows, the tab-group shape | CONFIRMED | Columns Service, GroupID, CodeName128, StrID128_Group |
| §1.14 gacha columns; A 14/1/6 rows; `ITEM_MALL_GACHA_CARD` named at `s:` funcs_005 77650 | CONFIRMED | The card is named in `GObjPC::SellItemAtSpecialtyShop` (`s:0x6182a0`) |

## 2–3. Join chain and menu file

| Claim | Verdict | Evidence |
|---|---|---|
| Every mall good of A and B resolves through every link | CONFIRMED | 0 missing package, scrap, price or itemdata row |
| Menu rows 1..9 as listed; flags `0 1 1 1`, Avatar/Pet `1 1 1 1`, Reserved `0 1 1 0`, Event Service 0 | CONFIRMED | Row 9's key is `UIIT_STT_SILKMALL_SPECIAL_COAST` ("Event"); the spec gives only the English |
| Menu parser offsets (+4, +8, +0x24, +0x40, +0x5c, bytes +0x78..+0x7b) | CONFIRMED | `c:0x97fbe0` (`+0x78` at `0x97fd09`) |
| Column 6 = the preview try-on flag (INFERRED from the pattern) | **NOT SUPPORTED** | No read of `+0x78..+0x7b` occurs anywhere in the mall UI (client fork; `item_mall.md` agrees). The "can be worn on the preview" flag is computed from the item's type (`c:0x7df430`, `+0x551`) |
| Hot list: {Service, Korean, order (key), bit, key}; six rows as tabled | CONFIRMED | Stored {bit `+0`, key `+4`} in the map at manager `+0x4ac`, keyed by order |
| B: 16 tabs, 68 goods, per-tab counts | CONFIRMED | |
| A: 36 tabs, 220 goods; renumbering; added tabs and ids; ten empty tabs | CONFIRMED | |
| "The screenshot's category list … is these rows minus Bundle goods" | PARTLY | It is the list the screenshot shows. **With A, the client would also drop Alchemy** (U5); see W7 |

## 4. Payment devices

| Claim | Verdict | Evidence |
|---|---|---|
| Bit names 1..16 from `_UPDATE_COST`'s `#define` comment; 32 = the honour-point branch; 64..1024 from the CORE procedure's token block | CONFIRMED | procedures |
| `CheckCurrencyRequirement s:0x617360`: each bit's test and refusal (`0x180f`, `0x1880`, `0x18c4`/`0x18c5`, `0x18d4`, `0x184a`, `0x184d`) | CONFIRMED | server fork; token kinds 6..10 at `s:0x4f1a30` |
| PC offsets `+0x2188`/`+0x218c`/`+0x2190` = `[0x862..0x864]` | CONFIRMED | `s:0x4f0959` (`lea ebx,[esi+0x2188]`) |
| `0x4f0940` sends `0x3153` | **WRONG in part, W5** | |
| Balances from `_GET_REMAIN_SILK` | **WRONG, W6** (mapping now READ) | |
| Client stores them at `+0x4ac/+0x4b0/+0x4b4` | CONFIRMED | `c:0x8707e7` registers `0x882de0` → `0x778e50` |
| `FUN_006a99c0`: lowest set bit, OR, Cost at `+0x8+i*8` | CONFIRMED | The client mirrors it (`c:0x980d90`: mask at package `+0xd0`, Cost at `+0xd8+i*8`; a second points-type price is dropped) |
| "A package payable several ways is several rows. The engine sums the amounts." | PARTLY | The silk family is one price, bit 2's (else bit 4's), drawn from own + gift + mileage. The price builder `s:0x867480` forces bit 16's amount to 0 (`s:0x8674e5`), which is why B's bit-4 and bit-16 rows can be 0. Gold (1), guild points (8), honour (32) and tokens are each charged in their own currency, so a `(1,8)` package (A's 20 guild soldier scrolls: 100,000 gold + 5,000 GP) costs both |
| Silk test and deduction order (mileage `+0xb0` first; 4 only → gift; 2 only → own; both → gift then own) | CONFIRMED+ | `FUN_00618930`. Mileage is taken only when bit 16 is set. The amounts go to record `+0x98` (own) and `+0xa0` (gift) |
| `_ConsumeSilkByGameServer` and rows 255/254/253 | CONFIRMED+ | Row 252 carries guild or honour points |
| Measured combinations: A 20 kinds (1,215 / 826 / 272 / 205 …); A mall (2,4) 194, (2) 26; B mall (2,4,16) 66, (1,2,4) 1, (2,4) 1; A's silk rows equal; B's bit 4 and 16 rows Cost 0 | CONFIRMED | recount. All 205 of A's (2,4) packages carry equal costs |
| 1,726 token rows "price NPC equipment" | **PARTLY, W10** | |
| "No mall good uses bits 8 through 1024" | **WRONG, W4** | |

## 5–6. SaleTag and purchases

| Claim | Verdict | Evidence |
|---|---|---|
| SaleTag = the hot-list mask | **UPGRADED, U1/U2** | |
| Third ground: A's examples match the screenshot | **WRONG, W7** | |
| Badge file list | CONFIRMED except the name, **W8** | `mall_new.ddj` and `mall_hot.ddj` exist too; which code draws them was not traced |
| B's main-page lists would be empty | CONFIRMED | All 964 B packages have SaleTag 0 |
| Operations 8/19/24/43, else -1 | CONFIRMED | `_STRG_ADD_PACKAGEITEM_CORE` |
| `_GetNeededSlotCountByBuyPackageItem`: 255 / 1 / Count clamped 1..5; -3 when slots are short | CONFIRMED | Not reversed |
| Per-type dispatch; TypeID1 ≠ 3 → -4 | CONFIRMED+ | CORE lines 245–300. The `3/3/11/1-2` test means **B's mall Alchemy goods (3/3/11/7 magic stones) take the plain `_STRG_ADD_EXPENDABLE_NoTX` path**. A TypeID2 other than 1, 2 or 3 creates nothing and returns -5 |
| Quantity: a single 3/3 with Data 0 → one stack of Count; Data N → N | CONFIRMED+ | With Data N > 0 and Count > 1 the buyer gets Count separate stacks of N (at most 5). The CORE quantity rule does not test Bionic; the slot-count procedure does |
| Payment after the items; tokens slot by slot; manual rollback; stock procedure | CONFIRMED | Tokens needed = Cost × Count |
| B's Reverse Return Scroll Data 11 and the skill edit potion 5; "the screenshot shows 11 Unit and 5 Unit" | PARTLY | The Data values are right in A, B and C. The screenshot's 11 Unit is on **Reverse Return Scroll (Special)**, not the plain scroll |
| Rentals: every rent and period table is empty | CONFIRMED | |
| Periods: devil's spirit Param1 2,419,200; every devil's-spirit scrap row Data 0; gold time 1D 86,400 and 4W 2,419,200; premium 2,419,200 | CONFIRMED | 26 devil's-spirit scrap rows in A, all Data 0 |

## 7. Goods traced end to end (this review's own traces)

Each trace was walked through refshop → mapping → tab group → tab → goods → package → scrap → the source's **own** itemdata → price, with a separate script (`verify_scripts/trace.py`). Every value the spec quotes matched.

| Shop | Good (source) | Result |
|---|---|---|
| Consume | Reverse Return Scroll, B: tab 2398 slot 5, package 25221, item 3795 (3/3/3/3, cash, MaxStack 50), Data 11, silk 14 / gift 0 / mileage 0 | matches |
| Consume | Reverse Return Scroll, A: tab id 2 slot 4, SaleTag 2, silk 45 / gift 45 | matches |
| Consume | Storage expansion, A: `MALL_CONSUME_ETC` slot 0, 51742 → 24366 (3/3/13/17, Param1 30, Param2 1), 150 / 150 | matches |
| Consume | Gold Time ticket 4W, B: `MALL_CONSUME_SPECIAL` slot 5, 25201 → 3884 (3/3/13/4, 2,419,200, Param4 and Param5 100/100), silk 130; not in A | matches |
| Avatar | Bandit's tiger hat, B: `MALL_AVATAR_HAT` slot 0, 25242 → 3837 (3/1/13/1, CanTrade 0, CanBuy 0), silk 29 | matches |
| Pet | Three Footed Crow, B: `MALL_PET_A_GROWTH` slot 0, 25271 → 22716 (3/2/1/1), 130; Squirrel A: `MALL_PET_B_SILK` slot 6, 25264 → 9263 (3/2/1/2), 88 / 88 | matches |
| Pet | Clock of Reincarnation, A: `MALL_PET_E_STORES` slot 0, 25262 → 8985 (3/3/13/12), SaleTag 8, 99 / 99 | (extra trace) |
| Premium | Premium Gold Time, B: `MALL_PREMIUM_PREMIUM` slot 0, 25324 → 9277 (3/3/13/14, 2,419,200), rows (2: 380, 4: 0), no bit 16; GoldTime PLUS A: slot 1, 68132 → 35567, 498 / 498 | matches |
| Premium | Devil's Spirit A grade (M), A: `MALL_PREMIUM_NASRUN` slot 0, 51716 → 24405 (3/1/14/1), Data 0, 300 / 300 | matches. The spec files it under "Avatar", but it sits in the Premium shop. A's Avatar shop sells only from `MALL_AVATAR_BOOTH` and `MALL_VISUALS_*` |
| Alchemy | (not traced by the spec) B: `MALL_ARCHEMY_ASTRAL` slot 0, 25327 → 6883 `ITEM_ETC_ARCHEMY_MAGICSTONE_ASTRAL_01` (3/3/11/7), silk 2 / gift 0 / mileage 0. A has no Alchemy good | traced |

The spec says B's items were taken from A's itemdata. Comparing B's own `ItemData_*.txt` for its 68 mall items, the only differences are **MaxStack** on 24 items: A raises the 16 magic stones from 1 to 500 and the 8 HP/MP superset bags from 1,000 to 10,000. MaxStack is the client's quantity cap in the buy box.

`ITEM_MALL_INVENTORY_ADDITION` (24365) is in no package of A, B or C: CONFIRMED.

## 8–9. OpenSRO today

| Claim | Verdict | Evidence |
|---|---|---|
| `ShopReader` keys groups by `r[4].begins_with("NPC_")`, so it skips every mall group | CONFIRMED | `client/scripts/npc/shop_reader.gd:66` |
| `specialty/shops.go` and `export-refdata -mode specialty` walk the same chain | CONFIRMED | |
| `shop.Price` uses itemdata Price, else the formula | CONFIRMED | `shop.go:81` |
| Every cash item's Price is 0 → formula gold | **WRONG, W9** | |
| No silk balance, no `0x3153`, no price policy anywhere | CONFIRMED | No match in `server/` or `client/` |
| `composite.go` line 102: UIU1 3/3/13/4 not modelled | CONFIRMED | `internal/session/composite.go:100-104` |
| §8 TypeIDs (Clock 3/3/13/12, growth potion 3/3/13/15, skin 3/3/13/9, gender 3/3/13/8, stall deco 3/3/3/4, global chat 3/3/3/5, skill edit 3/3/13/0, gacha card 3/3/14/1, extension gear 3/3/13/16) | CONFIRMED | A's itemdata. Avatars measured 3/1/13/1..3; no `ITEM_MALL_*` avatar with TID4 4 was seen |
| **`clientdata.go` maps `_REFSHOP`/`_REFSHOPGROUP`/`_REFSHOPTAB` to the legacy `shop*data` files; they should be `refshop`/`refshopgroup`/`refshoptab`** | CONFIRMED+ | `server/internal/persistence/clientdata.go:59,61,63`. The client loads the `ref*` files and never the `shop*data` ones (load list, no string in the exe). A's `refshop`, `refshopgroup` and `refshoptab` match C's Service-1 rows (93/93, 111/111, and all 298 tab rows). **Additions:**<br>- The map has **no runtime consumer**; only `clientdata_test.go` reads it. The error is in documentation and has no effect at run time.<br>- `TestHandResolvedFilenames` **pins** `"_REFSHOP": "shopdata"` (`clientdata_test.go:121`), and the comment at `clientdata.go:25-26` repeats it, so the fix must change both.<br>- `ServerOnlyOtherTables` lists **`_RefRentItem`** as having no client file, but `refrentitem.txt` is in Media.pk2 (2 bytes, empty) and the client loads it. Moving it would change the test's count of 51. |

## Missed by the spec

**Data.**
1. **A is not a subset of C's live rows.** C has 268 Service-1 goods and 12 tabs that A's client file lacks, 8 of them in the mall: scroll slots 0, 2, 3 and 6, and two goods each in `MALL_ARCHEMY_ASTRAL` and `_ATHANASIA`. A server that loaded C would list goods the client cannot show. Both sides must load the same archive (the spec's own rule); this proves it matters.
2. **The screenshots come from neither A nor C** (W7). Retail-exact building must take the content from the player's archive and never from the screenshots.
3. **With A, the client hides the Alchemy category.** Its three tabs are empty, and `0x7e3090` drops a shop with no good. It shows HOT shop and Reserved, because `xxx` is stored as an empty code (U5).
4. **The HOT shop page shows a Sale (bit 4) section** that the main page does not (U3).
5. **A's itemdata raises MaxStack** for magic stones (1 → 500) and HP/MP superset bags (1,000 → 10,000) against B. That changes the buy box's quantity cap.
6. Trailing tabs vary (one or two per row in A, none in the menu file), so a reader must ignore trailing empty fields.

**Server and procedures.**

7. **The balances come from a billing web call, not the database** (W6). `0x3153` has three send sites, and `0x3154` is the per-currency update (W5).
8. **Token bits need operation 43.** Any other operation with a token bit, or operation 43 without one, is refused with 2.
9. **ExpandTerm** (U8): `ALL` requires the request to cover every device the package lists.
10. **The stock procedure is used only when the purchase has a stock record** (`s:0x45e1ec`). Under it, a good with no stock row cannot be bought, and -202 means the shop group is unknown.
11. **`_UPDATE_COST` details:**
    - guild points (8) win over honour points (32), because the test is if / else-if;
    - gold is **set** to the server-computed `@RemainGold`, not subtracted;
    - the return codes run -2001..-2007.
12. **Rent expiry details:** it also requires `nCanDelete = 1`, and storage type 3 (the old chest) is refused.

**Client.**

13. **PreviousCost is used**, for SaleTag bit 4 only, and the last price row's value wins (U10).
14. **The mall window finds its group by the exact-match flag** (W1). An archive that renamed `GROUP_MALL` would have no mall.

**Sibling document.**

15. **`item_mall.md` §2a** says "with this archive the client creates neither" HOT shop nor Reserved. **That is wrong.** The menu parser stores the code through `0x97f920` (`c:0x97fc66`), which empties `xxx`, and an empty code is created (`c:0x7e522b`). That document is in progress and was not edited; its owner should take this.

## Counts

- **WRONG:** 10 (W1–W10). Two change what the build does: W1 (exact match) and W6 (where the balances come from). W2, W7 and W9 change conclusions drawn from the data. W3, W4, W5, W8 and W10 are precision fixes.
- **UPGRADED:** 13 (U1–U13). OPEN 1, 2, 4, 6, 10 and 11 are closed; OPEN 5 and 8 are partly closed.
- **NOT SUPPORTED:** 1 (menu column 6 as the try-on flag).
- **PARTLY:** 8 (label or detail).
- **CONFIRMED / CONFIRMED+:** 77 table rows.
- **UNVERIFIABLE:** 2.
  - Whether the server reads SaleTag anywhere: a search found no read of `+0x28` outside the parser, but a search miss is not proof.
  - Whether PreviousCost is drawn struck through.
