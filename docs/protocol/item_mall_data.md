# Item mall: the data tables (round 837)

What the item mall's categories, tabs, goods, prices and flags are made of, from the archive the
client reads at run time down to the item a purchase creates. The window is `item_mall.md`, the wire
and the server's purchase path `item_mall_wire.md`; this file is the DATA. Labels: **READ** (seen in
a binary or a stored procedure; the address or the procedure is given; `c:` sro_client.exe,
`s:` SR_GameServer.exe), **MEASURED** (counted from the tables), **INFERRED** (the reason is given),
**OPEN**, **OURS**.

No row of any table is in this repository (`docs/LEGAL.md`). The numbers below are counts and a few
worked examples, quoted so the build can be checked against the player's own archive.

## Corrections from the review (item_mall_data_verify.md)

The review is `item_mall_data_verify.md`. Where this section and the body below disagree, this
section wins.

- **§1.2 (W1).** The client's `GROUP_MALL` test is an **exact** compare, not a prefix test
  (`c:0x9843ce..0x9843e6`, `basic_string::compare(0, size(), L"GROUP_MALL", 10)`). Only group 1051
  gets `+0x28 = 1`. The window finds its group as the first group with that flag (`c:0x9262c0`).
  That the server's `+0x28` is the NPC field is READ (`s:0x6a9fb0`).
- **§1.6 (W2).** The gaps in `MALL_CONSUME_SCROLL` (slots 0, 2, 3, 6) are **Service-1** rows of C
  that A's file lacks. They are not Service-0 rows. A is not a subset of C's live rows: C has 268
  Service-1 goods and 12 tabs more, 8 of those goods in the mall.
- **§1, row counts (W3).** B does have `gachaitemset` (26 rows), `gachanpcmap` (1) and the four
  `shop*data` files (57 / 64 / 161 / 1,392). A's `shopdata`, `shoptabdata` and `shopitemdata` are
  identical to B's and carry no copyright line.
- **§4, last paragraph (W4).** B's mall goods do use bit 16 (66 of 68 goods). No mall good of A or
  B uses bit 8, bit 32 or the token bits 64..1024.
- **§4, `0x4f0940` (W5).** It sends `0x3153` only when its argument is 1. The purchase deduction
  calls it with 0. `0x3153` is sent:
  - when the balances are loaded (`s:0x4e781d`);
  - after the purchase's database job (`s:0x4e9b6c`);
  - from the silk-update handler `s:0x4f0750`, after `0x3154`.
- **§4, the balances' source (W6).** The game server never calls `_GET_REMAIN_SILK`. It reads the
  three balances over HTTP through `billing_silkdatacall.asp` (`s:0x6a1750`, called by
  `AQ_GDBSelector`). Which balance is which is now READ from the purchase call instead: record
  `+0x98` is `@OwnSilkToPay`, `+0xa0` is `@GiftSilkToPay` and `+0xb0` is `@MileageToPay`. So
  `[0x862]` is own silk, `[0x863]` gift silk and `[0x864]` mileage. OPEN 6 is closed.
- **§5, third ground (W7).** The screenshots do **not** show A's data.
  - Their New list has none of A's SaleTag-1 goods.
  - Their Best list has goods that A marks 8 or 0, or lists in no tab.
  - Their prices differ (500 against A's 498).
  - They sell an Inventory Expansion, which no package in A, B or C contains.
  - With A, the client would hide the Alchemy row, because all its tabs are empty.
- **§5, SaleTag (now READ, not INFERRED).**
  - Badges come from `c:0x7dec60`, which reads `+0x2c` at `0x7decaf`:
    - bit 1: `mall_icon_new.ddj`, N;
    - bit 2: `mall_icon_limited.ddj`, H;
    - bit 4: `mall_icon_sale.ddj`, S, with PreviousCost;
    - bit 8: `mall_icon_popular.ddj`, R;
    - bits 16 and 32: `mall_icon_recommendation .ddj`, D.
  - The lists are filled at `c:0x7e4dc8..0x7e4e59`, and the main page reads them in hot-list order
    (`c:0x7e3c00`).
  - The HOT shop is recognised by its text key and shows the bit 1, 2, 4, 8 and 16 sections
    (`c:0x7e38f0`).
  - A menu row whose code is `xxx` is stored empty and is always drawn. A row with a code is drawn
    only when the shop exists and has a good (`c:0x7e5201..0x7e5287`).
  - Menu column 6 is read by no code, so it is not shown to be the try-on flag.
- **§5 (W8).** The file is `mall_icon_recommendation .ddj`, with a space before the extension.
- **§9 (W9).** Not every cash item has Price 0: 623 of A's 1,794 do. Of the 718 silk-priced
  NPC-store goods, 426 sell at the formula and 292 at their itemdata Price (`shop.Price` returns
  `item.Price` when it is > 0).
- **§4 (W10).** The 1,726 token rows are 1,630 equipment, 83 expendables and 13 COS. Only 1,236 of
  them belong to a package that some tab sells.
- **Other upgrades.**
  - The window always shows bit 2's Cost, and draws PreviousCost only for SaleTag bit 4.
  - ExpandTerm takes `EXPAND_TERM_ALL` or `EXPAND_TERM_ONE` (`s:0x6a94a0`, `s:0x617950`).
  - The `"MALL_"` assert tests the tab's code (`s:0x6a9cd5`).
  - The `CShop*Data` classes are never filled.
  - The price builder forces bit 16's amount to 0 (`s:0x8674e5`).
  - Token bits require operation 43.
- **§9, `clientdata.go`.** The bug stands. The map has no runtime consumer, though: only
  `clientdata_test.go` reads it. Its `TestHandResolvedFilenames` pins `"_REFSHOP": "shopdata"`, so
  the fix must change the test as well. `_RefRentItem` is also listed as server-only, but
  `refrentitem.txt` is in Media.pk2 (empty) and the client loads it.

## 0. Sources, and what "retail" can mean here

Three copies of the shop tables were read. None of them is an untouched retail vSRO 1.188 archive.

| | what | where (outside the repo) | label |
|---|---|---|---|
| **A** | the player's archive: `Media.pk2` in `/opt/sro-files/client`, the archive OpenSRO reads at run time. Its client is vSRO 1.188 with `vsroplus_lib.dll`. **Every shop table in it ends in the line `//Copyright ® Pandora Online 2019`** (`refshop`, `refshopgroup`, `refshoptab`, `refshoptabgroup`, `refshopgoods`, `refmappingshop*`, `refpackageitem`, `refscrapofpackageitem`, `refpricepolicyofitem`, `shopgroupdata`, `gachaitemset`). Its shop content is that private server's | extracts in `/var/tmp/r837data/` on the render box | MEASURED |
| **B** | the y0gi vPLUS server package's own copies, `/opt/sro-files/server/y0gi_Easy_vPLUS/SMC_Independent/SMC_Independent/SR_GameRefData/*.txt`. It has no copyright line and about a third of A's rows. It is the closest thing to stock data on the box. Its `refpricepolicyofitem.txt` has 13 columns, without PreviousCost; its other shop files have A's column count | on the box | MEASURED; "closest to stock" INFERRED (smaller, no private marker, retail-style tab ids) |
| **C** | `SRO_VT_SHARD.bak`, restored in CT 104 `mssql-temp` (`deploy/README.md`, "External shard DB") and exported this round. Every row of A is in C, except that 510 of A's scrap rows name an item whose `_RARE` twin C names. `_RefPricePolicyOfItem`, `_RefPackageItem` and `_RefShop` are identical to A's Service-1 rows, and C has more rows in the rest (table in §1). So it is the same private server's database. **Its value here is the column names and types, and its stored procedures.** The procedures are Joymax code: Korean comments, `상점개편` ("shop revamp") headers, `by kkongs` / `by novice 2010-01-15` notes | `/opt/sro-files/db/csv/r837/export_r837/` on the box (CSV per table, `_schema.tsv`, `procs/*.sql`) | MEASURED |

The engine's STRUCTURE (columns, joins, the payment-device bits, the purchase procedure) is the same
in all three and is what OpenSRO builds. The CONTENT (which goods, which prices) is whatever the
player's archive says. For OpenSRO the client and the server must both read the player's A. B's
numbers are quoted where an example should not depend on Pandora's edits.

Country is 15 on every row in all three. `_RefShopObject` has one row: `15, SILKROAD_VIETNAM` (READ C).

## 1. The tables

All files are under `server_dep\silkroad\textdata\` in Media.pk2. Their encoding is MEASURED on A:
UTF-16LE with a BOM (`ff fe`), CRLF line ends and tab-separated fields, each row ending in a tab. An
empty table is the 2-byte BOM only. B's copies are UTF-16LE too, without the trailing tab.
**Column 0 is Service**: a client file carries only Service-1 rows, and C keeps Service-0 rows that
A lacks (for example 14 of `_RefShop`'s 107 rows, all `STORE_*`).

The client's loader reads column 0 itself and then calls a per-file parser for the rest. Each
parser reads one token fewer than its file has columns: `refpackageitem` 16 of 17, `refpricepolicyofitem`
13 of 14, `refshopgoods` 12 of 13 (READ the parsers, MEASURED the files). So the offsets quoted below
start at column 1.

Row counts (MEASURED; A and B are rows excluding the copyright line):

| file (DB table) | A | B | C (all / Service 1) | client loads it (READ: the load list at `c:` funcs_010 47643..47787) |
|---|---|---|---|---|
| `mallitemmenulistdata.txt` (client only) | 9 menu + 6 hot rows | - | - | yes |
| `refshop.txt` (`_RefShop`) | 93 | 57 | 107 / 93 | yes |
| `refshopgroup.txt` (`_RefShopGroup`) | 111 | 58 | 124 / 111 | yes |
| `refmappingshopgroup.txt` (`_RefMappingShopGroup`) | 110 | 57 | 123 / 110 | yes |
| `refmappingshopwithtab.txt` (`_RefMappingShopWithTab`) | 114 | 64 | 133 / 118 | yes |
| `refshoptabgroup.txt` (`_RefShopTabGroup`) | 113 | 66 | 128 / 117 | yes |
| `refshoptab.txt` (`_RefShopTab`) | 298 | 162 | 325 / 310 | yes |
| `refshopgoods.txt` (`_RefShopGoods`) | 2,778 | 1,425 | 3,302 / 3,046 | yes |
| `refpackageitem.txt` (`_RefPackageItem`) | 3,130 | 964 | 3,130 / 3,130 | yes |
| `refscrapofpackageitem.txt` (`_RefScrapOfPackageItem`) | 3,130 | 964 | 3,130 / 3,130 (510 rows name the `_RARE` twin of A's item, e.g. A `ITEM_EU_EARRING_03_A`, C `..._A_RARE`) | yes |
| `refpricepolicyofitem.txt` (`_RefPricePolicyOfItem`) | 5,041 | 1,121 | 5,041 / 5,041 | yes |
| `refshopitemstockperiod.txt` (`_RefShopItemStockPeriod`) | 0 | 0 | 0 | yes |
| `shopitemstockquantity.txt` (`_ShopItemStockQuantity`) | 0 | - | 0 | yes |
| `refrentitem.txt` (`_RefRentItem`) | 0 | - | 0 | yes |
| `refaccesspermissionofshop`, `reftreatitemofshop`, `refconditiontosellpackageitem`, `refrewardpolicytosellpackageitem` (and the three `*scrapitem` policy files) | 0 each | 0 | 1 each, Service 0, all `xxx` / 0 | yes |
| `gachaitemset.txt` (`_RefGachaItemSet`), `gachanpcmap.txt`, `refgachatreeforclientuidata.txt` | 14, 1, 6 | - | 52 / 14 | yes |
| `shopdata.txt`, `shopgroupdata.txt`, `shoptabdata.txt`, `shopitemdata.txt` | 57, 98, 161, 1,392 | - | - | **no** (§1.13) |

### 1.1 `refshop.txt` = `_RefShop` (12 columns)

| # | DB column | type | meaning | label |
|---|---|---|---|---|
| 0 | Service | tinyint | 1 live | READ C |
| 1 | Country | int | 15 | READ C, MEASURED |
| 2 | ID | int | | READ C |
| 3 | CodeName128 | varchar(129) | `MALL_CONSUME`, `STORE_CH_SMITH`, ... | READ C |
| 4..11 | Param1..4, Param1..4_Desc128 | int / varchar | -1 / `xxx` on every row of A and B | READ C, MEASURED |

The mall's shops are the five `MALL_*` rows: `MALL_CONSUME` 965, `MALL_AVATAR` 994, `MALL_PET` 996,
`MALL_PREMIUM` 1002, `MALL_ARCHEMY` 1003. These ids are the same in A and B (MEASURED). There is no
`MALL_PACKAGE` or `MALL_EVENT` shop row in either source, although the menu names both (§3).

### 1.2 `refshopgroup.txt` = `_RefShopGroup` (13 columns)

Service, Country, **ID smallint**, CodeName128, **RefNPCCodeName** (`xxx` = no NPC), then Param1..4
with their descs (-1 / `xxx` throughout, MEASURED). (READ C)

Mall rows, the same in A and B: `GROUP_MALL_CONSUME` 977, `GROUP_MALL_AVATAR` 1006, `GROUP_MALL_PET` 1008,
`GROUP_MALL_PREMIUM` 1014, `GROUP_MALL_ARCHEMY` 1015 and **`GROUP_MALL` 1051**, all with NPC `xxx`.
A also has `GROUP_STORE_SD_ACCESSORY` with no NPC (MEASURED).

The client's parser `GlobalDataManager::RefParse_refshopgroup` (`c:0x9842e0`) stores Country at +0,
the u16 ID at +4 (the record's key) and the code at +8. When the NPC column is not `xxx` it resolves
the NPC's object id into +0x24. **When there is no NPC and the code starts with `GROUP_MALL`
(a 10-character compare), it sets the byte at +0x28 to 1.** That is the client's mall-group flag.
(READ)

The server registers every group whose NPC field is empty as a standalone shop at boot:
`CMainProcess::FUN_00411b30` / `FUN_00411bc0`, logged "Silkmall is successfully initialized" (READ).
A purchase that names an unregistered one logs "SilkShop was not registered. You can't buy any cash
item. shopGroup_id(%d), shopIndex_InGroup(%d)" (`s:0x526610`, READ). So the mall purchase names a
**shop group id** (1051 for `GROUP_MALL`) and an **index of the shop inside that group**. That `+0x28`
is the NPC field is INFERRED from its use as the "no NPC" test. The wire is `item_mall_wire.md`.

### 1.3 `refmappingshopgroup.txt` / `refmappingshopwithtab.txt` (4 columns each)

`_RefMappingShopGroup`: Service, Country, RefShopGroupCodeName, RefShopCodeName.
`_RefMappingShopWithTab`: Service, Country, RefShopCodeName, RefTabGroupCodeName. (READ C)

Only `GROUP_MALL` maps to the mall shops, in file order `MALL_ARCHEMY`, `MALL_AVATAR`, `MALL_CONSUME`,
`MALL_PET`, `MALL_PREMIUM`. That order is alphabetical in A, B and C. The five `GROUP_MALL_*`
groups have no mapping row in any source (MEASURED). Each `MALL_X` maps to exactly one tab group,
`MALL_X_GROUP1` (MEASURED).

### 1.4 `refshoptabgroup.txt` = `_RefShopTabGroup` (5 columns)

Service, Country, ID, CodeName128, **StrID128_Group** (the group's name key). Mall rows, the same in
A and B: `MALL_CONSUME_GROUP1` 1056 `UIIT_STT_SILKMALL_CONSUMPTION` "Expendables", `MALL_AVATAR_GROUP1`
1057 `..._AVATA` ("Visuals" in A's English column), `MALL_PET_GROUP1` 1058 "Pet",
`MALL_PREMIUM_GROUP1` 1059 "Premium" and `MALL_ARCHEMY_GROUP1` 1060 "Alchemy". (READ C, MEASURED)

### 1.5 `refshoptab.txt` = `_RefShopTab` (6 columns)

Service, Country, ID, CodeName128, **RefTabGroupCodeName**, **StrID128_Tab** (the tab's name key).
(READ C) The mall's tabs are listed in §3.

### 1.6 `refshopgoods.txt` = `_RefShopGoods` (13 columns)

| # | DB column | type | label |
|---|---|---|---|
| 0, 1 | Service, Country | | READ C |
| 2 | RefTabCodeName | varchar | READ C |
| 3 | RefPackageItemCodeName | varchar | READ C |
| 4 | **SlotIndex** | tinyint, `< 240` (`MAX_ITEM_PER_SHOP_TAB`, `shop.go`) | READ C, READ `s:0x720a81` |
| 5..12 | Param1..4 + descs | -1 / `xxx` on every row (MEASURED A, B) | READ C |

The client's `RefParse_refshopgoods` (`c:0x983b70`) stores Country at +4, the tab code resolved to the
tab's id at +8, the package resolved to its id at +0xc (the key) and the slot as a byte at +0x10. It
skips the four params. (READ)
(tab, slot) is unique in A and B; the largest slot is 190 in A and 35 in B (MEASURED). Slots have gaps:
A's `MALL_CONSUME_SCROLL` has 1, 4, 5, 7, 8, because C's Service-0 rows fill the rest (MEASURED).

The server's `RefShopGoods_ExtractData` (`s:0x6a9ab0`) asserts that every item in the good's
package carries `OBJ_INTERACT_FLAG_CAN_SELL`. For a non-bionic TypeID1-3 item whose TID word has
bit 0 set (CashItem), it also asserts that the string `"MALL_"` occurs in the code at `+0xc` of the
record it looked up (`FUN_00401d90(...,"MALL_",5) == -1` -> assert). (READ) That this record is the
goods' tab, so that a cash item may only be listed in a `MALL_*` tab, is INFERRED. A breaks the rule:
741 cash-item goods sit in non-mall tabs (`STORE_AVATARS_TAB1..3`, `STORE_TITLES_TAB1`, ...;
MEASURED). Every one of B's cash goods is in a mall tab.

### 1.7 `refpackageitem.txt` = `_RefPackageItem` (17 columns): the GOOD

| # | DB column | type | A / B values | client (`c:0x9811f0`) | label |
|---|---|---|---|---|---|
| 0 | Service | tinyint | 1 | (loader) | READ C |
| 1 | Country | int | 15 | +8 | READ |
| 2 | ID | int | e.g. 25221 | +0xc, the key | READ |
| 3 | CodeName128 | varchar | `PACKAGE_ITEM_MALL_REVERSE_RETURN_SCROLL` | +0x10 | READ |
| 4 | **SaleTag** | smallint | A: 0 x3,117, 8 x5, 1 x4, 2 x4; B: all 0 | u16 at +0x2c | READ C/c, MEASURED; meaning §5 |
| 5 | **ExpandTerm** | varchar(65) | `EXPAND_TERM_ALL` on every row of A, B, C | +0x30 | READ C, MEASURED; meaning OPEN |
| 6 | NameStrID | varchar | `SN_ITEM_MALL_REVERSE_RETURN_SCROLL` | +0x4c | READ |
| 7 | DescStrID | varchar | `..._TT_DESC` | +0x68 | READ |
| 8 | AssocFileIcon | varchar | `item\etc\mall_reverse_return_scroll.ddj` | +0x84 | READ |
| 9..16 | Param1..4 + descs | int / varchar | -1 / `xxx` (295 descs are upper-case `XXX` in A) | skipped | READ, MEASURED |

The good's name, tooltip and icon in the mall come from the package row, not from the item
(INFERRED: the client keeps them on the package record; the window agent confirms what it draws).
On the server, `RefPackageItem_ExtractData` (`s:0x6a94a0`) reads SaleTag at +0x28 and then the
ExpandTerm string. When `FUN_00425260()` is true it asserts "insert a PricePolicyConditionLevel %s"
(READ). What that test is, and whether any ExpandTerm other than `EXPAND_TERM_ALL` is legal, is
OPEN. No row in any source has another value.

### 1.8 `refscrapofpackageitem.txt` = `_RefScrapOfPackageItem` (29 columns): what a good gives

| # | DB column | type | label |
|---|---|---|---|
| 0, 1 | Service, Country | | READ C |
| 2 | RefPackageItemCodeName | varchar | READ C |
| 3 | RefItemCodeName | varchar, an itemdata code name | READ C |
| 4 | OptLevel | tinyint, the plus | READ C |
| 5 | Variance | bigint, white stats | READ C |
| 6 | **Data** | int: the stack count of an expendable, else the instance's Data word (§6) | READ C + procedure |
| 7 | MagParamNum | tinyint | READ C |
| 8..19 | MagParam1..12 | bigint, blue options | READ C |
| 20..27 | Param1..4 + descs | -1 / `xxx` (MEASURED) | READ C |
| 28 | Index | int, unique per row (MEASURED) | READ C |

**Every package has exactly one scrap row in A, B and C** (3,130 / 964 / 3,130; MEASURED), so no good
is a multi-item bundle in this data. The engine supports bundles: `_GetScrapItemCount` counts the
rows, and the purchase loops over them (§6). The client parses the row at `c:0x9824e0`; `c:0x8bf3a0`
builds the store's displayed item from OptLevel and MagParam1..12 (READ, `npc_shop_def.gd`).
Mall goods carry OptLevel 0 and MagParamNum 0 on every row of A and B (MEASURED).

### 1.9 `refpricepolicyofitem.txt` = `_RefPricePolicyOfItem` (14 columns): the price

| # | DB column | type | client (`c:0x981ba0`) | label |
|---|---|---|---|---|
| 0, 1 | Service, Country | | +8 Country | READ |
| 2 | RefPackageItemCodeName | varchar | resolved to the package id, +0xc (key) | READ |
| 3 | **PaymentDevice** | int, ONE bit per row (§4) | +0x10 | READ |
| 4 | **PreviousCost** | int | +0x18 (as 64-bit) | READ |
| 5 | **Cost** | int | +0x20 (64-bit) | READ |
| 6..13 | Param1..4 + descs | -1 or 0 / `xxx` | skipped | READ, MEASURED |

One row per (package, device). (package, device) is unique in A and B, and every mall package has
at least one row (MEASURED). **PreviousCost is 0 on every row of A, and B's file has no such
column** (MEASURED). The price a sale would strike through is therefore never filled (INFERRED from
the column name and the hot list's unused "sale" bit, §5).
B's 13-column file has Cost at index 4. The server's parser reads PaymentDevice into +8 and Cost into
+0x14, skipping PreviousCost (READ round 531, `character_state.md`), so the server reads the
14-column layout.

### 1.10 `mallitemmenulistdata.txt` (client only): §3

### 1.11 Stock, period and rent tables: all empty

| table | columns (C) | rows | what uses it (READ) |
|---|---|---|---|
| `_RefShopItemStockPeriod` | Service, Country, ID, RefShopGroupCodeName, RefPackageItemCodeName, StockOpeningDate smalldatetime, StockExpireDate smalldatetime, PeriodDevice tinyint | 0 in A, B, C | client parser `RefParse_refshopitemstockperiod` (case 0x56 of the loader) |
| `_ShopItemStockQuantity` | Service, Country, RefShopGroupCodeName, RefPackageItemCodeName, ConstStockQuantity smallint, StockQuantity smallint | 0 | `_STRG_ADD_PACKAGEITEM_WITH_STOCKQUANTITY`: decrements StockQuantity by the slots the purchase needs and refuses with `0x80010002` `STRGERR_NOT_ENOUGH_STOCKQUANTITY_ITEM` when short |
| `_RefRentItem` | service, RentCodeName, RefItemID, CanDelete, CnaRecharge (sic), RentType, StartTime, EndTime, TimeCnt, Time1..5 | 0 | `DB_Load_RefRentItem` (`s:0x83a3d0`); "Can't find RentTime(%s) within _RefRentItem" (`s:` funcs_007 41891, the monster-drop loader) |
| `_RentItemInfo` (runtime) | nItemDBID, nRentType, nCanDelete, nCanRecharge, PeriodBeginTime, PeriodEndTime, MeterRateTime, nPackingState, nPackingTime | 0 | `_Rent_Info_Manager` (job 0 insert, 1 update), called by `AQ_StorageUpdaterForPacakageItem::DoWork_AddRentInfo`; `_DelExpiredRentItemInStorage` deletes rent type 1 or 3 items past PeriodEndTime, and type 2 past MeterRateTime, in the bag, chest, COS bag, guild chest and avatar slots |

### 1.12 The policy tables

`_RefAccessPermissionOfShop` (RefShopCodeName, AcceptOrReject, FourCC, Param1..4),
`_RefTreatItemOfShop` (RefShopCodeName, Cash, TypeID1..4, RefItemCodeName, AcceptOrReject, FourCC, ...),
`_RefConditionToSellPackageItem` and `_RefRewardPolicyToSellPackageItem` (RefPackageItemCodeName,
AcceptOrReject, FourCC, Param1..4). Each has one Service-0 placeholder row in C, and their files are
empty in A and B. Nothing in this data uses them. (READ C, MEASURED)

### 1.13 The legacy tables the client does not load

`shopdata.txt` (18 columns, e.g. `1 1 MALL_CONSUME xxx 0 -268435455 642 643 644 645 646 0...`),
`shopgroupdata.txt` (`MALL_CONSUME_GROUP1 UIIT_STT_SILKMALL_CONSUMPTION`), `shoptabdata.txt` (tab ids
642.. with `MALL_AVATAR_FIREWORK` and `MALL_PET_SUMMON` / `MALL_PET_CONSUME`) and `shopitemdata.txt`
(tab id, item id, ...) are the pre-revamp shop format. No string `shopdata`, `shopitemdata`,
`shoptabdata` or `shopgroupdata` occurs in `sro_client.exe` (ASCII or UTF-16), and none is in the
client's load list. The classes `CShopData`, `CShopGroupData`, `CShopTabData` and `CShopItemData`
still exist (`c:0x95ec20..0x95f210`, RTTI). (READ) Whether anything fills those classes is OPEN.
Do not build from these four files. C's `_RefShopItemGroup` (108 rows, a copy of the tab groups) is
the same legacy shape.

### 1.14 Gacha (the Magic POP card)

`_RefGachaItemSet`: Service, Set_ID, RefItemID, Ratio smallint, Count smallint, GachaID, Visible,
param1..4 (READ C). A has 14 Service-1 rows. `gachanpcmap.txt` has one row and
`refgachatreeforclientuidata.txt` six. The mall sells `ITEM_MALL_GACHA_CARD` (§7). The server names
the card at `s:` funcs_005 77650 (READ). The draw is not mapped here (OPEN, out of scope).

## 2. The join chain

```
mallitemmenulistdata ITEMMALL_MENU_LIST   col 2 shop code (MALL_CONSUME ...)          [category]
  refshop                CodeName128 = MALL_CONSUME          (id 965)
  refmappingshopgroup    GROUP_MALL -> MALL_CONSUME           (server: group 1051, index in group)
  refmappingshopwithtab  MALL_CONSUME -> MALL_CONSUME_GROUP1
  refshoptabgroup        MALL_CONSUME_GROUP1, name UIIT_STT_SILKMALL_CONSUMPTION
  refshoptab             RefTabGroupCodeName = MALL_CONSUME_GROUP1 -> MALL_CONSUME_SCROLL,
                         name UIIT_STT_SILKMALL_SCROLL ("Order")                       [sub-tab]
  refshopgoods           RefTabCodeName = MALL_CONSUME_SCROLL, SlotIndex, RefPackageItemCodeName
  refpackageitem         the good: id, SaleTag, name / desc / icon
  refscrapofpackageitem  the item(s) it gives: code, OptLevel, Variance, Data, MagParams
  itemdata_*             the item: id, TypeID, CashItem, MaxStack, Params
  refpricepolicyofitem   one row per payment device: Cost (and PreviousCost)
```

Every link is a code name, except the menu's link to the shop, which is the shop's code, and the
server's purchase, which names the group id and the shop's index (READ, §1.2). The client resolves
the codes to ids as it parses (READ, §1.6, §1.9). All of A's and B's mall goods resolve through
every link: no missing package, scrap or price row (MEASURED).

## 3. `mallitemmenulistdata.txt`: the categories and the main page's lists

Two sections, each headed by a `#section` line (READ `c:` funcs_013 14220..14320; MEASURED A):

**`ITEMMALL_MENU_LIST`**: the left-hand categories. The client parses each row with
`RefParse_mallitemmenulistdata` (`c:0x97fbe0`) after the loader has read and tested column 0.

| col | A's first row | stored | meaning | label |
|---|---|---|---|---|
| 0 | `1` | (loader) | Service: 0 skips the row (`MALL_EVENT`) | INFERRED (the loader skips when it is 0; the column count fits) |
| 1 | `1` | +4, the key | the category's number 1..9 | READ (key), INFERRED (order) |
| 2 | `MALL_CONSUME` | +8 | the refshop code, or `xxx` for a category that is not a shop | READ, MEASURED |
| 3 | `UIIT_STT_SILKMALL_CONSUMPTION` | +0x24 | the label's text key | READ |
| 4 | `interface\mall\mall_item_tab.ddj` | +0x40 | the button art | READ |
| 5 | `interface\mall\mall_consum_icon.ddj` | +0x5c | the icon | READ |
| 6..9 | `0 1 1 1` | bytes +0x78..+0x7b | flags | READ (storage); meaning OPEN |

A's rows: 1 `MALL_CONSUME` Expendables (flags 0 1 1 1); 2 `MALL_AVATAR` (1 1 1 1); 3 `MALL_PET` Pet
(1 1 1 1); 4 `MALL_PREMIUM` Premium; 5 `MALL_ARCHEMY` Alchemy; 6 `xxx` `UIIT_STT_SILKMALL_HOT_STORE`
"HOT shop"; 7 `MALL_PACKAGE` "Bundle goods" (no such shop); 8 `xxx`
`UIIT_STT_SILKMALL_SHOPPING_BASKET_LIST` "Reserved" (0 1 1 **0**); 9 `MALL_EVENT` "Event", Service 0.
Column 6 is 1 only for Avatar and Pet, the two categories whose goods can be tried on the preview
model. That this is what column 6 means is INFERRED from the pattern alone, and stays OPEN.
The screenshot's category list (Expendables, Dresses, Pet, Premium, Alchemy, HOT shop, Reserved) is
these rows minus Bundle goods, with the private server's own text for row 2. Why Bundle goods is
missing (no shop row, or a flag) is OPEN for the window agent.

**`ITEMMALL_HOTITEM_LIST`**: the main page's lists. Each row is column 0 Service, then a Korean
label the client discards, the list's order (the key, u16), the **bit** it selects, and the
heading's text key (READ: the case-2 branch, `FUN_008cc270` / `FUN_0092aab0` store {order, bit, key}).

| Service | Korean | order | bit | key | English (A) |
|---|---|---|---|---|---|
| 1 | 최신상품 newest | 2 | **1** | `UIIT_STT_SILKMALL_UPDATE_ITEM` | New item |
| 1 | 인기상품 popular | 3 | **2** | `UIIT_STT_SILKMALL_BESTSELLER_ITEM` | Best item |
| 0 | 할인상품 discounted | 5 | **4** | `UIIT_STT_SILKMALL_SALE_ITEM` | Sale item |
| 1 | 추천상품 recommended | 4 | **8** | `UILM_STT_DIVISION_RECOMMENDATION` | Recommend |
| 1 | 수량제상품 limited quantity | 1 | **16** | `UIIT_STT_SILKMALL_POPUP_ADVERTISING` | Limited Sales |
| 0 | 기간제상품 limited period | 6 | **32** | `UIIT_STT_SILKMALL_POPUP_ADVERTISING` | Limited Sales |

### The mall's tabs (MEASURED; table order, which is how the client's tab list is stored; the drawn order is the window agent's)

B (stock-like), 16 tabs, 68 goods:

| category | tab (id) | name key -> English | goods |
|---|---|---|---|
| Expendables | `MALL_CONSUME_SPECIAL` (2397) | `UIIT_STT_SILKMALL_SPECIAL` Special | 7 |
| | `MALL_CONSUME_SCROLL` (2398) | `..._SCROLL` Order | 6 |
| | `MALL_CONSUME_POTION` (2399) | `..._POTION` Potion | 8 |
| | `MALL_CONSUME_COMMUNITY` (2400) | `..._COMMUNITY` Community | 1 |
| | `MALL_CONSUME_ETC` (2401) | `..._ETC` Others | 6 |
| Avatar | `MALL_AVATAR_BOOTH` (2480) | `..._BOOTH` Stall | 4 |
| | `MALL_AVATAR_HAT` (2481) | `..._HAT` Hat | 10 |
| | `MALL_AVATAR_FIREWORK` (2482) | `..._FIREWORK` Cracker | 0 |
| Pet | `MALL_PET_A_GROWTH` .. `MALL_PET_E_STORES` (2571..2575) | `SN_TAB_PET_GROWTH` Growth Pet, `SN_TAB_PET_SILK` Ability Pet, `SN_TAB_VEHICLE` Vehicle, `SN_TAB_CART` Trans, `SN_TAB_PET_STORES` Pet Items | 2, 4, 1, 1, 1 |
| Premium | `MALL_PREMIUM_PREMIUM` (2490) | `..._PREMIUM_PREMIUM` Premium | 1 |
| Alchemy | `MALL_ARCHEMY_ASTRAL` (2491), `MALL_ARCHEMY_ATHANASIA` (2492) | Astral, Immortal | 8, 8 |

A (the player's archive), 36 tabs, 220 goods. It renumbers the stock tabs (1..5, 84, 85, 94..96,
175..179) and adds its own: Expendables gains `MALL_PREMIUM_SILKSCROLLS` (223), `MALL_SCROLLS` (234),
`MALL_MODELSWITCHER` (235), `MALL_WINGS` (245), `MALL_LOTTERY` (295) and `MALL_TYPESWITCHER` (316).
Avatar gains `MALL_AVATAR_DRESS` (191), `_ATTACH` (192), `_BALLOON` (193) and `MALL_VISUALS_*`
(308..315). Pet gains `MALL_PET_FELLOW` (222). Premium gains `MALL_PREMIUM_NASRUN` (194) and
`_NASRUN_ETC` (195). Alchemy gains `MALL_ARCHEMY_ETC` (217). Ten of A's tabs list no good: all three
Alchemy tabs, Avatar's Hat, Dress, Attachment, Balloon and Dwelling, `MALL_WINGS` and `MALL_PET_A_GROWTH`. A's avatar dresses are
sold at an NPC store (`STORE_AVATARS_TAB1`), not in the mall.

## 4. Payment devices: which currency a price row is in

`PaymentDevice` is a bit mask, and each row of the price table carries one bit. Every name below is
READ:

| bit | name (the procedures' own) | balance it draws on | server test, `GObjPC::CheckCurrencyRequirement` `s:0x617360` | refusal |
|---|---|---|---|---|
| 1 | `EXPAND_DEVICE_GOLDPRICE` | the character's gold | gold < amount | `0x180f` NOT_ENOUGH_GOLD |
| 2 | `EXPAND_DEVICE_SILKPRICE` | **own silk**: `Silk_Own`, PC `+0x2188` (`[0x862]`) | silk test, below | `0x1880` NOT_ENOUGH_SILK_TO_BUY_ITEM |
| 4 | `EXPAND_DEVICE_GIFTSILKPRICE` | **gift silk**: `Silk_Gift`, PC `+0x218c` (`[0x863]`) | silk test | `0x1880` |
| 8 | `EXPAND_DEVICE_GUILDPOINT` | the guild's GatheredSP (master only) | no guild or not master; then points | `0x18c4`; `0x18c5` |
| 16 | `EXPAND_DEVICE_MILEAGE` | **mileage**: `Mileage`, PC `+0x2190` (`[0x864]`) | adds to the silk total | (`0x1880`) |
| 32 | (honour point) | `_TrainingCampMember.HonorPoint` (`FUN_004ea600`, the academy member's points) | points < amount | `0x18d4` TC_LACK_HONOR_POINT |
| 64 | `PAYMENT_DEVICE_TOKEN_BRASS` | `ITEM_ETC_SD_TOKEN_01` in the bag | the stacks' summed count | `0x184a` NOT_ENOUGH_COIN |
| 128 | `PAYMENT_DEVICE_TOKEN_STEEL` | `ITEM_ETC_SD_TOKEN_02` | same | `0x184a` |
| 256 | `PAYMENT_DEVICE_TOKEN_SILVER` | `ITEM_ETC_SD_TOKEN_03` | same | `0x184a` |
| 512 | `PAYMENT_DEVICE_TOKEN_GOLD` | `ITEM_ETC_SD_TOKEN_04` | same | `0x184a` |
| 1024 | `PAYMENT_DEVICE_TOKEN_MEDAL` | `ITEM_ETC_ARENA_COIN` | same | `0x184d` ARENA_NOT_ENOUGH_COIN |

Where each piece was read:

- **Bits 1..16** are named in the comment of `_UPDATE_COST`: `#define EXPAND_DEVICE_GOLDPRICE 1 ...
  EXPAND_DEVICE_MILEAGE 16`. Bit 32 is the procedure's `honorpoint` branch.
- **Bits 64..1024** are named in `_STRG_ADD_PACKAGEITEM_CORE`'s token block (`<< TokenType >>`, 황동
  brass / 강철 steel / 진은 silver / 황금 gold / 코인 medal), with the same code names. The server
  agrees: `GObjPC::FUN_004f1a30` (`s:0x4f1a30`) maps kinds 6..10 to exactly those five code names,
  and the currency test calls it with kind 6 for bit 0x40, up to kind 10 for bit 0x400.
- **The three silk balances** come from `_GET_REMAIN_SILK (@JID, @Silk_Own, @Silk_Gift, @Mileage)`,
  which calls `SRO_VT_ACCOUNT.._GETSILKDATAFORGAMESERVER` (the account DB, not in this backup). The
  server keeps them at `[0x862]`, `[0x863]` and `[0x864]` (`CGObjPC::FUN_004f0940` `s:0x4f0940`,
  which clamps each to 0 and sends **`0x3153 {u32 [0x862], u32 [0x863], u32 [0x864]}`**). The client
  stores them at `+0x4ac`, `+0x4b0` and `+0x4b4` (`c:0x882de0` -> `c:0x778e50`).
  That `[0x862]` is own, `[0x863]` gift and `[0x864]` mileage is INFERRED. Three facts agree: the
  procedure's argument order, the bit order (2, 4 and 16 test `[0x862]`, `[0x863]` and `[0x864]`),
  and the format string `"%d/%d,%d"` the server prints them with. The binder of `AQ_GDBSelector`'s
  result was not traced (OPEN).

**How a package's rows combine** (READ round 531, `character_state.md`, "PaymentDevice 8 is flag 8"):
the server's `ReferenceData::FUN_006a99c0` takes each row's lowest set bit `i`, ORs `1 << i` into the
package's price record and stores the row's Cost at `+0x8 + i*8`. A package payable several ways is
therefore several rows. The engine sums the amounts.

**The silk test** (`s:0x617360`, READ): when bit 2 or bit 4 is set, the price is bit 2's amount, or
bit 4's when bit 2 is absent. The money available is `[0x862]` if bit 2 + `[0x863]` if bit 4 +
`[0x864]` if bit 16. The purchase record's `+0xb0` is the part the buyer pays in mileage. The
deduction (`s:` funcs_005 78090..78200, the block ending at `LAB_00618dad` before
`CGObjPC::FUN_004f0940(0)`, READ): mileage takes `+0xb0` first, and then:

- with bit 4 only, gift silk pays the rest;
- with bit 2 only, own silk pays it;
- with **both**, gift silk pays as much as it can and own silk the remainder.

`_UPDATE_COST` then calls `SRO_VT_ACCOUNT.._ConsumeSilkByGameServer (@JID, @OwnSilkToPay,
@GiftSilkToPay, @MileageToPay, 0, @CharID, @PackageItemID, 0)` and writes rows 255 / 254 / 253 (own,
gift, mileage) to `_ResultOfPackageItemToMappingWithServerSide` for the server to apply (READ).
Which client field carries the mileage part is OPEN (`item_mall_wire.md`;
`resinfo\ifitemmallusepoint.txt` is its window).

**What the data does with it** (MEASURED):

| | A (all 5,041 rows) | A's mall goods (220) | B's mall goods (68) |
|---|---|---|---|
| combinations | (1) 1,215; (2) 826; (1,256,512,1024) 272; (2,4) 205; ... 20 kinds | **(2,4) 194; (2) 26** | **(2,4,16) 66**; (1,2,4) 1; (2,4) 1 |
| silk rows | bit 2 and bit 4 carry the **same** cost | same | **bit 2 carries the price; bits 4 and 16 carry Cost 0** |

So B's pattern is "the price in silk, payable from own + gift + mileage", with bits 4 and 16 marking
the extra balances. A's pattern is "the same price from own or gift silk, no mileage". The server charges bit 2's
Cost in both (READ, the silk test above). That the window shows the same number is INFERRED; the
window agent reads it. The tokens (64..1024) are A's own use: 1,726 of its rows price NPC
equipment in them (MEASURED). No mall good of A or B uses bits 8 through 1024.
The screenshot's "Silk / Beta Silk / Gift Silk" panel is the private server's labels for the three
`0x3153` balances. Its order and words are not evidence for which balance is which.

## 5. "New", "Best", "Hot" and "R": the SaleTag column

**`_RefPackageItem.SaleTag` is the mask the main page's hot lists select by.** That much is INFERRED,
on three grounds:

- its values are bits of `ITEMMALL_HOTITEM_LIST` (§3): A uses 1 (new), 2 (best) and 8 (recommend),
  and only Service-1 bits occur;
- the client stores it as a u16 on every package (`c:0x9811f0` -> +0x2c, READ);
- A's live examples match the screenshot's badges: Reverse Return Scroll, Instant Return Scroll,
  Global chatting and the Celestial Tiger have SaleTag 2 and appear under "Best item" with an H;
  the lotteries and the speed scroll have 1 (N, new); the Clock of Reincarnation, Extension gear,
  Elite Starter Packages and Special Reverse Return Scroll have 8 (R, recommend).

The code that tests `+0x2c` against the list's bit is not found yet (OPEN, `item_mall.md`). B's 964
packages all have SaleTag 0, so B's main page lists would be empty.

The badges are art in `interface\mall\`: `mall_icon_new.ddj`, `mall_icon_popular.ddj`,
`mall_icon_sale.ddj`, `mall_icon_recommendation` (sic, no extension) and `mall_icon_limited.ddj`, plus
`mall_new.ddj` and `mall_hot.ddj` (MEASURED: the archive listing). Which bit draws which icon, and
whether H is "popular" (bit 2), is OPEN for the window agent.
**"HOT shop"** (menu row 6, shop `xxx`) has no shop of its own. That it lists the SaleTag-marked goods
is INFERRED from the shop column being `xxx`; the window agent reads which bits it takes.

"N Unit" under a price is the good's quantity (§6). It is not a flag.

## 6. What a purchase creates, rentals and periods

From the purchase procedure `_STRG_ADD_PACKAGEITEM_CORE` (C), called through `_STRG_ADD_PACKAGEITEM`
(11 arguments, caller `AQ_StorageUpdaterForPacakageItem`, `persistence/catalogue.go`).
`_STRG_ADD_CASH_PACKAGEITEM` is the same with no payment arguments. Each step is READ:

- **Operations:** `SP_BUY_ITEM 8`, `SP_BUY_ITEM_COS 19` (into a pet's bag), `SP_BUY_CASH_ITEM 24`,
  `SP_BUY_ITEM_WITH_TOKEN 43`. Any other is refused (-1).
- **Room:** the slots needed come from `_GetNeededSlotCountByBuyPackageItem(package, Count)`. A
  package with no scrap row needs 255, which always refuses. A single-scrap, non-bionic 3/3 item with
  scrap `Data = 0` needs 1. Anything else needs `Count` clamped to 1..5. With fewer empty bag slots
  (13 <= slot < InventorySize) the procedure returns -3.
- **The items:** for each scrap row, `PackageItemCount` times, the procedure takes the first empty
  slot and creates the item from the scrap row's **OptLevel, Variance, Data and MagParamNum /
  MagParam1..12**, by type:
  - 3/2 and 3/3 go to `_STRG_ADD_EXPENDABLE_NoTX` with Data;
  - alchemy stones 3/3/11/1-2 go to `_STRG_ADD_ALCHEMYSTONE_NoTX`;
  - the gacha card 3/3/14/2 goes to `_STRG_ADD_ITEM_MAGIC_NoTX`;
  - specialty goods 3/3/8 go to `_STRG_ADD_SPECIALTY_NoTX` with the buyer's name;
  - equipment 3/1 goes to `_STRG_ADD_EQUIP_NORMAL_NoTX`, or `_ITEM_MAGIC_NoTX` when MagParamNum > 0.

  A TypeID1 that is not 3 is refused (-4).
- **The quantity:** "if the package holds one item, it is an expendable and its quantity (Data) is
  not set, set the quantity from the passed value". So a single 3/3 item with scrap `Data = 0`
  becomes ONE stack of `Count`. Scrap `Data = N > 0` gives N, which is the "N Unit" the window shows.
  B's Reverse Return Scroll has Data 11 and the skill edit potion 5; the screenshot shows
  "11 Unit" and "5 Unit".
- **The payment, after the items:** `_UPDATE_COST` takes silk, gift silk and mileage through the
  account DB (bits 2, 4, 16), sets the gold (bit 1), and takes guild points (bit 8) or honour points
  (bit 32) as `@OffsetOptionalPoint`. Tokens (op 43) are spent from the bag's token stacks first,
  slot by slot (`_STRG_DEL_ITEM 15` or `Data -= cost`). A failed payment rolls the items back by hand.
- **Stock:** `_STRG_ADD_PACKAGEITEM_WITH_STOCKQUANTITY` names the shop group and runs the stock
  check first (§1.11).

**Rentals:** every rent and period table is empty in A, B and C (§1.11, MEASURED), so **no mall good in
this data is a rental**. Rent rows would come from `_RefRentItem`, keyed by RentCodeName / RefItemID,
and `_Rent_Info_Manager` writes `_RentItemInfo` for an instance (READ). How a package selects a
rent row is OPEN; rent codes appear on drops and quest rewards (`RentItemCodeName`). The item record
already has a place for rent: its first u32, 0 when there is no rent object
(`iteminfo.go`, `c:0x8bb130`).

**Periods that are not rentals.** A TypeID3 14 item carries its period in the instance (the "period
word", `iteminfo.go`). For the devil's spirit (3/1/14/1) it is the Data word, 0 until it is first
awakened (`avatars.md`). Its itemdata Param1 is 2,419,200 s, 28 days (MEASURED, `ITEM_MALL_AVATAR_M_NASRUN`
24405). Every devil's-spirit scrap row has Data 0 (MEASURED), so a bought spirit is not yet awake.
Tickets and premium items carry their duration in itemdata Param1 (gold time 1D 86,400, 4W
2,419,200; premium gold time 2,419,200; MEASURED) and start it on use, not on purchase (INFERRED:
nothing in the purchase procedure reads them).

## 7. Goods traced end to end

Each line: tab, slot, package (id, SaleTag), item (id, TypeID, CashItem, scrap Data), price rows
(device = Cost). All MEASURED. The item columns (TypeID, CashItem, Params, CanTrade) are A's itemdata for
both sources; B's server package has its own `ItemData_*.txt`, not compared this round.

| good | B (stock-like) | A (player's archive) |
|---|---|---|
| **Reverse Return Scroll** | `MALL_CONSUME_SCROLL` slot 5, `PACKAGE_ITEM_MALL_REVERSE_RETURN_SCROLL` (25221, 0) -> `ITEM_MALL_REVERSE_RETURN_SCROLL` (**3795**, 3/3/3/3, cash 1, Data 11, MaxStack 50) | slot 4, same package (25221, **SaleTag 2**) -> 3795, Data 11 |
| | silk 14, gift 0, mileage 0: **14 silk for 11 scrolls** | silk 45, gift 45 |
| **Premium Gold Time** | `MALL_PREMIUM_PREMIUM` slot 0, `PACKAGE_ITEM_MALL_PREMIUM_GOLDTIME` (25324) -> `ITEM_MALL_PREMIUM_GOLDTIME` (9277, 3/3/13/14, Param1 2,419,200; composite params `[UIU1:ITEM_PRE_GOLTAM_4W]`, `[USU1:SKILL_MALL_PRE_APRU_4W_01]`, `[UIL1:...RESURRECTION_100P / REVERSE_RETURN / RETURN_SCROLL_HIGH_SPEED]`, `[BFI1:...BOOTH_MOB_MANGYANG]`, `[UQL1:QSP_ALL_POTION_3]`) | not sold; slot 1 sells `PACKAGE_ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS` (68132) -> 35567 "Premium GoldTime PLUS" |
| | silk 380, gift 0 | silk 498, gift 498 |
| **Gold Time ticket** | `MALL_CONSUME_SPECIAL` slot 5, `PACKAGE_ITEM_MALL_GOLD_TIME_SERVICE_TICKET_4W` (25201) -> 3884 (3/3/13/4, Param1 2,419,200, Param4/5 100/100) | not sold |
| | silk 130 | |
| **Avatar** | `MALL_AVATAR_HAT` slot 0, `PACKAGE_ITEM_MALL_MABT_CH_M_BANDIT_TIGER_HA` (25242) -> 3837 "Bandit's tiger hat (Man)" (3/1/13/1, CanTrade 0, CanBuy 0) | `MALL_PREMIUM_NASRUN` slot 0, `PACKAGE_ITEM_MALL_AVATAR_M_NASRUN` -> 24405 "Devil's Spirit A grade(M)" (3/1/14/1, Data 0) |
| | silk 29 | silk 300, gift 300 |
| **Pet** | `MALL_PET_A_GROWTH` slot 0, `PACKAGE_ITEM_COS_P_RAVEN_SCROLL` (25271) -> 22716 "Three Footed Crow Summon Scroll" (3/2/1/1) | `MALL_PET_B_SILK` slot 6, `PACKAGE_ITEM_COS_P_SEOWON_SCROLL` -> 9263 "Squirrel Summon Scroll" (3/2/1/2) |
| | silk 130 | silk 88, gift 88 (B: 88) |
| **Storage expansion** | not sold | `MALL_CONSUME_ETC` slot 0, `PACKAGE_ITEM_MALL_WAREHOUSE_ADDITION` (51742) -> 24366 (3/3/13/17, Param1 30, Param2 1) |
| | | silk 150, gift 150 |
| **Inventory expansion** | not sold | not sold: no package names `ITEM_MALL_INVENTORY_ADDITION` (24365) in A, B or C |

## 8. Goods that need the server to do more than add an item

These are flags for the wire and server lane (`item_mall_wire.md`). Each item's TypeID is MEASURED, and the
OpenSRO state is READ from the code.

| goods | TypeID | why | OpenSRO today |
|---|---|---|---|
| any mall good | | price in silk (own / gift / mileage), §4; the silk balances and `0x3153` | **no silk balance anywhere** |
| devil's spirit (Nasrun) | 3/1/14/1 | period word, awakening, extension gear 3/3/13/16 | built (`avatars.md`, `avataruse.go`) |
| avatars | 3/1/13/1..4 | avatar storage; B's hats are CanTrade 0 | built (`avatars.md`) |
| pet summon scrolls | 3/2/1/1 growth, 3/2/1/2 ability; 3/3/3/2 ride / transport scrolls | COS creation on use | built (`pets.md`, rounds 795..797) |
| Clock of Reincarnation, pet growth potion | 3/3/13/12, 3/3/13/15 | pet revival / growth | see `pets.md` |
| premium and composite items | 3/3/13/14 (Premium Gold Time, starter packages, silk scrolls) | the composite FourCC list in Param2..4 (`UIU1`, `UIL1`, `USU1`, `BFI1`, `UQL1`) | partly: `session/composite.go`; a `UIU1` premium-time row (3/3/13/4, job `FUN_0049a400`) is not modelled (`composite.go` line 102) |
| gold / silver time tickets | 3/3/13/4 | a timed job (Param1 seconds, Param4/5 percent) | not modelled (same note) |
| inventory / storage expansion | 3/3/13/17 | `ExpandInventory` on use (+32 bag / +30 storage) | built (`useitem.go`, `inventory.go`) |
| Reverse Return Scroll | 3/3/3/3 | its own cast and destination list | built (`reverse_return_scroll.md`) |
| global chatting | 3/3/3/5 | the global chat | built (`chat`) |
| Magic POP card | 3/3/14/1 (`ITEM_MALL_GACHA_CARD`) | the gacha draw (`_RefGachaItemSet`) | not built |
| character skin change, gender switch tools | 3/3/13/9, 3/3/13/8 | appearance or gender change | OPEN in OpenSRO (not traced) |
| skill edit (restoration) potion | 3/3/13/0 | the server names it (`s:` funcs_003 12063) | OPEN |
| stall decoration | 3/3/3/4 | the stall's look | OPEN |
| A only: name change, stat / skill reset, removers, switchers, lotteries, `ITEM_VSROEDITORCOM_VISUAL_*` | various, some with CashItem 0 | the private server's own items | out of scope (OURS if ever built) |

Expendable mall potions (3/3/1/1-2) and arrows/bolts (3/3/4/x) need nothing special beyond the
quantity rule in §6.

## 9. What OpenSRO reads today, and what is missing (READ the code)

Read today:

- `client/scripts/npc/shop_reader.gd` (`ShopReader`) walks `refshopgroup` -> `refmappingshopgroup` ->
  `refmappingshopwithtab` -> `refshoptabgroup` -> `refshoptab` -> `refshopgoods` (tab, package, slot) ->
  `refscrapofpackageitem` (package -> item code) for NPC stores. It keys groups by NPC
  (`r[4].begins_with("NPC_")`), so it **skips every mall group**.
- `server/internal/specialty/shops.go` and `export-refdata -mode specialty` walk the same chain for
  specialty NPCs only.
- `server/internal/testnpc`, `session/npcshopdef.go` and `client/scripts/net/npc_shop_def.gd` are OURS:
  the Test Items NPC.
- `server/internal/shop` prices every good by itemdata `Price` (column 26), falling back to a formula
  when it is 0. **Every cash item's Price is 0** (MEASURED on the items above). So a silk good sold
  at one of A's NPC stores (718 silk-priced goods outside the mall, e.g. `STORE_AVATARS_TAB1..3`)
  sells for the formula's gold today.
- `refdata.Item` carries CashItem (`refdata/sqlstore.go`, round 768).
- `persistence/catalogue.go` lists the table and procedure names only.

Missing:

- `refpackageitem` (SaleTag, ExpandTerm, the good's name / icon) and `refpricepolicyofitem` (all
  devices, PreviousCost). `character_state.md` already records "OpenSRO imports no price policy".
- `mallitemmenulistdata` (both sections).
- The scrap row's Data / OptLevel / Variance / MagParams applied to a bought item. `testnpc` applies
  its own.
- Silk balances (own, gift, mileage), `0x3153`, the payment split, token payments, guild-point and
  honour-point payments.
- Stock, period and rent tables. They are empty in this data, so the build can skip them, but an
  archive could fill them.

**A correction for `server/internal/persistence/clientdata.go`.** It maps `_REFSHOP` -> `shopdata`,
`_REFSHOPGROUP` -> `shopgroupdata` and `_REFSHOPTAB` -> `shoptabdata`. The client loads `refshop.txt`,
`refshopgroup.txt` and `refshoptab.txt` (READ, the load list), and C's `_RefShop`, `_RefShopGroup`
and `_RefShopTab` Service-1 rows match those files: 93 / 93 and 111 / 111 identical rows, and every
one of the 298 `refshoptab.txt` rows is in `_RefShopTab` (MEASURED). The `shop*data` files are the
legacy format (§1.13). The map should read `refshop`, `refshopgroup` and `refshoptab`. That is a
code change for the build lane; this round made none.

## OPEN

1. The client code that tests a package's SaleTag (+0x2c) against the hot list's bit, and which badge
   icon each bit draws (H = bit 2 is INFERRED). This is for `item_mall.md`.
2. `mallitemmenulistdata` columns 6..9 (the four flag bytes), and why "Bundle goods" (`MALL_PACKAGE`,
   no shop row) is not drawn.
3. The tabs' drawn order: the table order is MEASURED, the window's is not read.
4. `ExpandTerm`: what `RefPackageItem_ExtractData`'s `FUN_00425260` tests before
   "insert a PricePolicyConditionLevel"; only `EXPAND_TERM_ALL` occurs.
5. `PreviousCost`: whether the client draws it as a struck-through old price. It is 0 everywhere.
6. The binder that puts `_GET_REMAIN_SILK`'s Silk_Own / Silk_Gift / Mileage into `[0x862..0x864]`.
   The mapping is INFERRED from order and bits.
7. Which request field carries the mileage part (`+0xb0` of the purchase record); `item_mall_wire.md`.
8. The server's `shopIndex_InGroup` for `GROUP_MALL`: is it the `refmappingshopgroup` row order
   (ARCHEMY, AVATAR, CONSUME, PET, PREMIUM) or another order? `item_mall_wire.md`.
9. How a package would select a `_RefRentItem` row (all rent tables are empty here).
10. Whether `CShopData` / `CShopGroupData` / `CShopTabData` / `CShopItemData` are filled from anywhere.
11. The record `RefShopGoods_ExtractData` reads at `+0xc` for its `"MALL_"` assert: INFERRED to be the
    goods' tab.
12. Retail content: no untouched retail vSRO 1.188 `Media.pk2` is on the box. B is "closest to stock"
    by inference only, so B's prices are not to be quoted as retail fact.
