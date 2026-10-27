# Item mall: the wire and the server (round 837)

Read on 2026-10-27 from `SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/gs_dis.txt`, and
`objdump` of a local copy), the shard manager's decompile (`/var/tmp/decomp_shardmgr`),
`sro_client.exe` (`/var/tmp/decomp_client`, `/var/tmp/sro_client.dis`, local `objdump`) and the
shard backup `SRO_VT_SHARD.bak` (restored in CT 104; stored procedures and a few rows; the account
database `SRO_VT_ACCOUNT` is not in the backup). `s:` is a GameServer address, `c:` a client
address, `sm:` a shard-manager address. Labels: **READ** (seen in code; the address is given),
**MEASURED** (read out of the backup's rows), **INFERRED** (the reason is given), **OPEN**, **OURS**.

Companions: the window is `item_mall.md` (another agent), the tables are `item_mall_data.md` (shop
group 1051, payment-device bits, packages, scrap rows, stock and rent tables). Reused, not
re-derived: the `0x7034`/`0xB034` envelope and the move serializer (`held_icon.md`,
`server/internal/session/itemop.go`), the item record and its rent block (`iteminfo.go`,
`item_tooltip.md`), INTERACTMODE (`character_state.md`), error names (`error_codes.md`).

## Corrections from the review (item_mall_wire_verify.md, READ)

The second reading (`item_mall_wire_verify.md`) found seven claims wrong. Build from these:

- **W1** (§1, rent block): if **either** bit 0 or bit 1 is set, one `u16` is read first. Then bit 0
  adds `u32, u32` and bit 1 adds `u16, u32` (`c:0x8bb130`). With bit 1 alone the block is
  `u32, u16, u16, u32`. `iteminfo.go` already reads it this way.
- **W2** (§2.2): the `BILLING_SERVER_URL "http://173.32.224.92:15000/"` text sits in the PE header
  slack (file offset `0x2bf`), and **no code references it**. The loader reads its URL from a runtime
  string. That string is copied from `CMainProcess+0x4247c` into the billing object at `0xd16c2c`
  (`s:0x4036e2`; read at `s:0x6a1765`). Its configuration source is OPEN. Which URL this server
  used is not established.
- **W3** (§2.2): a failed silk load does **not** only log. `s:0x450350` logs and then reports
  failure (`vslot 0x5d4(job, 0)` → `AsyncQueryFailed s:0x4e9110`). Job type 9 falls to the default
  there: "AQ Failed! Log out!!" and `FUN_004df050(4)`, so **the player is disconnected**. A bad
  billing reply (error code, MD5 mismatch, not `1:`) ends the same way. Each load first probes
  `<URL>billing_serverstate.asp`, which must answer `1` (`s:0x6a11e0`).
- **W4** (§3.1, `shopGroupId`): `c:0x9262c0` takes no shop. It returns the first group, in ID order,
  whose byte `+0x28` is 1. The parser sets that byte only for an NPC-less group whose code **equals**
  `GROUP_MALL`: a whole-string compare (`c:0x9843ce`–`0x9843e6`), not a prefix test. The value is
  1051 for every good. The reply's group id is **ignored** by the client. `c:0x87f733` re-finds the
  shop with `0x937af0(npc 0, index)`.
- **W5** (§3.2 step 6): `s:0x4de0f0` means "the package has exactly one scrap row", not a pet
  inventory. For such a package whose item is stackable:
  - **(a)** With `CMainProcess+0x42404` set, a trade good is cut to the trading limit or refused
    `0x1893`. Another item with vslot `0x41c` is refused 2.
  - **(b)** When the row's Data is 0, **the quantity must fit one stack**. For an expendable 3/3
    that means `qty ≤ ref+0x198` (`s:0x728130`), else **2**.
- **W6** (§3.2 step 8): the order is gold, coins, honour, **silk**, then **guild points last**
  (`0x18c4`/`0x18c5` after the silk block in `s:0x617360`).
- **W7** (§3.4 step 4): the client gives the request's quantity to a stackable only for a one-row
  package with Data 0. Otherwise a stackable gets the scrap row's **Data** (`c:0x87e18f`–`0x87e214`),
  for example 20 per slot for `PACKAGE_10XPACK_…ASTRAL_11`. This is the same rule as the server's
  §3.3.

Also from the review, now **READ** (were INFERRED or OPEN):

- **Message order.** `0x3153` goes before `0xB034`: `SendMsgToPeer s:0x4e0860` sends at once.
- **OPEN 5.** The database's cost rows (Type 1) fill the request by the row's payment bit k:
  `RefItemSerial64` goes to `+0x90 + 8k`, so 2 → own, 4 → gift, 16 → points
  (`s:0x4e858b`–`0x4e85b5`). The request mask `+0x88` is zeroed first and rebuilt from those rows.
- **OPEN 9.** The price is `(i16)qty × package[+0x50 + 8·bit]` (`s:0x865d90`).
- **OPEN 3.** `0x18ab` shows **nothing** (category-1 table `0x7bb6d4`, default `0x7b913a`). The same
  holds for 2, 5, `0x1806`, `0x1809`, `0x1811` and `0x1842`.
- **History cancel.** A history request with period `0xff` cancels: `sm:0x413fc2` turns it into op
  `0xff`, and `sm:0x41d160` erases the pending entry.

Missed by the spec, and needed by an implementation (details in the verify doc):

- The client stays "dealing" until a `0xB034` arrives. The item-op lock and timer 10 run 3000 ms,
  and the window's counter `+0x7dc` blocks closing it. **Answer every request.**
- The server makes at most 5 items per scrap row but charges `cost × qty`.
- Between the currency check and the items, two more refusals of **2** run:
  - the ExpandTerm mask check;
  - the package's own condition list.
- Each item can fail `0x180b` or `0x1842` in the placement loop.

**The short version.** The mall has exactly two requests: `0x7034` type `0x18` buys one good,
`0x711a` asks for the silk history. The balances arrive in `0x3153` (three u32: own silk, gift
silk, silk points), pushed at world entry, after every purchase and after any outside change
(`0x3154` names that change). A purchase goes **straight into the bag**, never anywhere else; the
client builds the items itself from its own package tables, and the reply only says which bag
slots were filled, plus one rent block per slot. There is no server-side "obtained" list, no gift
and no coupon message, and no item chest.

## 1. The wire (READ)

All little-endian. Strings are `u16 length` + that many bytes, no terminator (`c:0x78f480` writes
`[str+0x14]` as the length, then the bytes).

### Client to server

| Opcode | Layout | Sent by | Server handler |
|---|---|---|---|
| `0x7034` type `0x18` buy | `u8 0x18, u16 shopGroupId, u8 shopIndexInGroup, u8 tab, u8 slot, str packageCodeName, u16 quantity, u64 pointsToUse, u32 packageId` | `c:0x826460` (built), serializer `c:0x7923a0` case 0x18, request branch `c:0x79294e`-`0x79299d` | `s:CGObjPC::StorageOperation 0x50f5c0` → parser `s:0x4d8bf0` case 0x18 → op table `0xcd3b58 + 0x18*8` = `s:0x526610` |
| `0x711a` silk history | `u8 kind, u8 period` | `c:0x7d40c0`, `0x7d4210`, `0x7d5ea0`, `0x7d6000`, `0x7eabe0`, `0x7ecb90` | `s:GObjPC_HandleItemMallMsg_11a 0x518cd0` (relays it; §5) |

### Server to client

| Opcode | Layout | Sent by | Client handler |
|---|---|---|---|
| `0x3153` balances | `u32 ownSilk, u32 giftSilk, u32 silkPoint` | `s:CGObjPC::FUN_004f0940` (only when its stack flag is 1, `s:0x4f0952`) | `c:0x882de0` → `c:0x778e50` stores CGInterface `+0x4ac`, `+0x4b0`, `+0x4b4` |
| `0x3154` silk changed | `u8 reason, u8 cashType, u32 offset` | `s:CGObjPC::FUN_004f0750` (`s:0x4f0874`) | `c:0x882e50` (system-line text; §2.3) |
| `0xB034` buy result, success | `u8 1, u8 0x18, u16 shopGroupId, u8 shopIndexInGroup, u8 tab, u8 slot, u8 n, n × u8 bagSlot, u16 quantity, n × rent block` | `s:GObjPC::FUN_004e9480` (`s:0x4e95fb` serializer `s:0x4f76e0` reply branch, `s:0x4e99f3`-`0x4e9a5d` rent blocks) | `c:NetProcessInInner::FUN_0087f370` → parse `c:0x87eb50` case 0x18 → place `c:0x87ba20` (source window `0xa7`) → rent block `c:0x8bb130` |
| `0xB034` failure | `u8 2, u16 code` | `s:Msg_SendTwoFieldReply` from `s:0x50f6cd` | `c:0x87f370` (`c:0x778190` message, then the mall window's `c:0x7d6de0`) |
| `0xB11A` silk history | `u8 kind, u8 period, u8 result` and, when result is 0, `u16 n, n × {u32 silkOffset, u32 date}` | `s:CMainProcess::MsgHandler_b11b 0x4186d0` (copies the shard manager's body unchanged, `s:0x418787`) | `c:0x8990c0` |

The bag slot is the bag index + 13 (the 13 worn slots first; `c:0x871940` case 0x18 takes 13..111
as the bag). The rent block is the item record's own first field: `u32 flags`; bit 0 adds
`u16, u32, u32`, bit 1 adds `u16, u32`; `0` when the item has no rent object (`s:0x862960` writes the
zero, `c:0x8bb130` reads it; `iteminfo.go`).

## 2. Silk (READ unless marked)

### 2.1 The three balances

The GameServer keeps three ints on the player: `pc[0x862]` own silk, `pc[0x863]` gift silk,
`pc[0x864]` silk points (`s:0x4f0959`-`0x4f096a`). The names come from the shard procedures, which
call them `Silk_Own`, `Silk_Gift` and `Mileage` (`_GET_REMAIN_SILK`, `_STRG_BUY_CASHITEM_EXP`,
`_UPDATE_COST`, MEASURED), and from `_UPDATE_COST`'s own comment: `EXPAND_DEVICE_SILKPRICE 2`,
`EXPAND_DEVICE_GIFTSILKPRICE 4`, `EXPAND_DEVICE_MILEAGE 16`. `0x3153` sends them in that order,
each clamped to 0 when negative (`s:0x4f0940`-`0x4f0950`).

Which label the window puts on which value ("Silk", "Beta Silk", "Gift Silk" in the screenshots) is
the window's (`item_mall.md`). The window reads the three getters `c:0x778e20` (`+0x4ac`, own),
`c:0x778e30` (`+0x4b0`, gift), `c:0x778e40` (`+0x4b4`, points); one of the windows that shows them
is `c:0x7dd3a0`.

### 2.2 Where the server gets them

From the **billing web server, not the shard database**. `AQ_GDBSelector` (async job type 9) runs
`s:0x6a1750`: an HTTP GET of `<BILLING_SERVER_URL>billing_silkdatacall.asp?JID=<jid>`
(`s:0x6a17c1`, the format string at `0xb08d60`). The reply text is split at `:` (`s:0x6a14e2`);
the part before it must be the literal `"1"` (`s:0x6a1506`, string at `0xae051c`); the rest is
split at `,` into three integers (`s:0x6a1450`) and then the MD5 (`s:0x6a1750`, a further `,`
split; INFERRED the fourth field). A leading `-` is an error code (-1 DB connection, -2 JID missing, -3 query,
-4 no such user, -5 MD5). The server then hashes `"%d.%d.%d.%d.%s"` = JID, the three values and the
salt `SROG8Z_CDE1210598DK_AKD3HW1K04DL2-` and requires the reply's MD5 to match. The three values
are own, gift, points in that order (`s:0x4502e5`-`0x450310`: the first goes to job `+0x2c`, the
second `+0x30`, the third `+0x34`). The URL in this binary was patched by the private server to
`http://173.32.224.92:15000/` (MEASURED, `strings`). So a reply looks like
`1:<own>,<gift>,<points>,<md5>`.

The job completes in `GObjPC::CGObjPC___AsyncQuerySucceeded` case 9 (`s:0x4e780e`), which calls
`FUN_004f0940` with the flag 1: **`0x3153` is sent**. It is posted from `CGObjPC::vslot_391`
(`s:0x4dffbe` → `s:0x4501a0`), the function that places the player into its game world: INFERRED
world entry. A failed load only logs "Silk Data Loading Failed [JID]" (`s:0x450350`).

The shard's own `_GET_REMAIN_SILK` (JID → own, gift, mileage) only forwards to
`SRO_VT_ACCOUNT.dbo._GETSILKDATAFORGAMESERVER`, which is not in the backup; this GameServer never
names it (no string). INFERRED: it is what the billing page runs.

### 2.3 Changes from outside the game (`0x3154`)

Message `0xAA00` into the GameServer (`s:CMainProcess` dispatch, `s:0x414930`): `u32 JID, u32 remain,
u32 offset, u8 cashType (0 own, 1 gift, 2 point), u8 reason (0..5)` (`s:0x4f0750`; any other type or
reason only logs "Silk is updated by unknown cashtype/reason"). The server sends the client
`0x3154 {reason, cashType, offset}` (`s:0x4f086c`-`0x4f08bd`), sets `balance[cashType] = remain`
(`s:0x4f08c8`) and then sends `0x3153` (`s:0x4f08e3`). Who sends `0xAA00` (the billing side, through
the shard manager) is OPEN.

The client prints the offset into one system-line string by reason (`c:0x882e50`): 0
`UIIT_STT_SILK_BUY_RESULT`, 1 `UIIT_STT_SILK_BUY_CANCLE`, 2 `UIIT_STT_SILK_BUY_RECEIVE`, 3
`UIIT_STT_SILK_SEND_RESULT`, 4 `UIIT_STT_SILK_POINT_BUY_RECEIVE`, 5 `UIIT_STT_SILK_POINT_USE_RECEIVE`;
`0xff` shows `UIIT_MSG_STRGERR_TRADE_FAILURE`; the cash type byte is read and not used.

### 2.4 When `0x3153` is sent

| When | Where |
|---|---|
| world entry (the billing load) | `s:0x4e781d`, flag 1 |
| after a purchase's database job succeeds, with the balances the database returned | `s:GObjPC::FUN_004e9ae0` (`s:0x4e9b6c`), flag 1; reached from `s:0x4e9480` case 0x18 |
| after an outside change | `s:0x4f08e3`, flag 1 |
| the purchase's own in-memory deduction | `s:0x618e52`, **flag 0: no message** |

Ordering after a purchase: `s:0x4e9480` opens the `0xB034` message (vslot `0x278`), serializes it,
then for type 0x18 calls `FUN_004e9ae0`, which opens, fills and sends `0x3153` (`0x278`/`0x27c`)
before `0xB034` is sent at the end (`s:0x4e9a7c`, vslot `0x27c`). INFERRED (from the nesting, `0x278`
building and `0x27c` sending as everywhere else): **`0x3153` reaches the client before `0xB034`**.

## 3. The buy request: `0x7034` type `0x18`

### 3.1 The fields

| Field | Struct (client / server) | What it is |
|---|---|---|
| `u8 0x18` | +0 | the op (`c:0x82650c`) |
| `u16 shopGroupId` | +0x12 | the id of the shop group holding the shop: `c:0x9262c0` finds the group in the client's group list (refdata `+0x380`) and `+4` of it is the u16 (`c:0x8264d5`-`0x826507`). The server's log calls it `shopGroup_id` (`s:0x526651`). It is 1051 (`GROUP_MALL`) for every mall good (`item_mall_data.md` §1.2) |
| `u8 shopIndexInGroup` | +0x14 | the shop's position in that group's shop list (`c:0x9379c0`; the server's log: `shopIndex_InGroup`). INFERRED: both sides build the list in the mapping table's order, so they must load the same `refmappingshopgroup` rows |
| `u8 tab` | +2 | the tab within the shop (`c:0x7e8651`, the log string "SendNetMsgItemMall : ShopID(%d), Tab(%d), Index(%d)", pushed at `c:0x826610`) |
| `u8 slot` | +3 | the good's index in the tab |
| `str packageCodeName` | +0xf4 client, **+0x11c server** | the good's package `CodeName128` (`c:0x7e867c`: package record `+8+8`, the parser `c:0x9811f0` stores CodeName at record `+0x10`). The server **requires it to equal the good's package code name** (§3.2 step 5) |
| `u16 quantity` | +6 | how many |
| `u64 pointsToUse` | +0xb0 | silk points to spend on this purchase. Set only when the good's price mask has bit 0x10, and clamped to `min(price × quantity, entered)` (`c:0x7e8925`-`0x7e8991`) |
| `u32 packageId` | +0xc | the good's package ID (record `+0xc`, the parser's key, `c:0x9811f0`). The server's buy path does not read it (no use found; INFERRED unused) |

Two confirm boxes build this request: `NewItemMallConfirmBuy` (`c:0x7e8320` → `c:0x7e8797`) sends
the code name; the older `ItemMallConfirmBuy` (`c:0x7c4880` → `c:0x7c4c4a`) sends `""`
(`c:0xe16204` is an empty string). With an empty name the server answers `0x18ab` (step 5), so only
the new window can buy on this server (INFERRED; the screenshots show the new window).

What the client checks first, with no message sent (READ, `c:0x7e8320`): free bag slots
(`c:0x6b6230`) at least the quantity, or 1 for a stackable good, else `0x1807`
INVENTORY_FULL; and own + gift + points (the three getters summed, `c:0x7e837b`-`0x7e839a`) at least
`price × quantity`, else `0x1880` NOT_ENOUGH_SILK_TO_BUY_ITEM. Each shows through `c:0x778190`.

### 3.2 The server's checks, in order

`s:CGObjPC::StorageOperation 0x50f5c0`, then `s:0x526610`, then the shared buy core `s:0x618fe0`
(the NPC store's buy uses the same core, `s:0x5266a0`). Every refusal is `0xB034 {2, code}`.

1. **StorageOperation** (`s:0x50f5c0`): a character whose vslot `0xf8` is 2 may still send 0x18 and
   0x17 (every other op answers 2; what state 2 is, OPEN). INTERACTMODE (chardata +6) 4
   P2N_TALK → `0x1834` STORAGE_OPERATION_BLOCKED; 2 (P2P) or 7 → `0x1834`. Chardata `+0x13` set →
   `0x180e` (OPEN what it is).
2. **The shop** (`s:0x526610`): the silk-shop map (`DAT_00d6a9e4`) looked up by shopGroupId, the shop
   by shopIndexInGroup (`s:0x523740` → `s:0x5236f0`). Missing → **2** and the log "SilkShop was
   not registered...". The map is filled at start-up from the shop groups whose record `+0x28` is
   0 (`s:0x411b30`); the mall groups have NPC `xxx` (MEASURED), so INFERRED `+0x28` is the NPC.
3. **Shop access** (`s:0x617a30` → `s:0x61a860`): every condition in the shop's list must pass
   (`s:0x61be20`), else **2**. INFERRED: `_RefAccessPermissionOfShop`.
4. **Validation** (`s:GObjPC::FUN_00617a50`): tab ≥ the shop's tab count → `0x1806`; quantity ≤ 0
   → **2**; no good at that slot (`s:0x616780`) → `0x1809`.
5. Op 0x18 only: the request's code name ≠ the good's package code name (`s:0x617afc`-`0x617b16`,
   string compare `s:0x425210`) → **`0x18ab`**. The client has no text for `0x18ab`
   (`error_codes.md`; what it shows, OPEN).
6. A good with a pet-inventory side (`s:0x4de0f0` / `MainProcess+0x42404`) can cut the quantity to
   what the trading limit allows, or refuse `0x1893` MAX_TRADING_LIMIT_EXCEEDED (`s:0x617b2e`-).
7. Slots: `n = s:0x4de170` (slots this purchase needs) must be < 6, else **2**; free bag slots
   (`CGStorage::FindTotalEmptySlot`) < n → `0x1807`; a stock record with less than n left
   (`+0x18`, `+0x5a`) → `0x18cf` SILKMALL_SOLDOUT_ITEM; a sale period (`+0x1c`) outside its window →
   `0x18aa` SILKMALL_SOLDOUT_ITEM.
8. **Currency** (`s:CheckCurrencyRequirement 0x617360` via `s:0x617950`): the price comes from
   `s:0x617000` → `CShopApp` `s:0x867480`, one entry per bit of the package's PaymentDevice mask
   (package `+0x48`): bit 0 gold through the shop's own price, bit 4 (points) priced 0, every other
   bit `CPackageItem::FUN_00865df0(quantity)` (INFERRED cost × quantity; not read inside). Then:
   gold short → `0x180f`; coins 0x40..0x400 only for op 0x2b; honour 0x20 short → `0x18d4`; guild
   point 8 → `0x18c4` / `0x18c5`. **Silk** (bits 2, 4, 16):
   - `price` = the silk price when bit 2 is set, else the gift-silk price (bit 4);
   - `available` = own (if bit 2) + gift (if bit 4) + points (if bit 16); `available < price` →
     `0x1880`;
   - `pointsToUse` negative, above the point balance (0 when bit 16 is clear), or above `price` →
     **2**;
   - `rest = price − pointsToUse`: bit 4 alone → rest > gift → `0x1880`; bit 2 alone → rest > own →
     `0x1880`; both → gift pays first and own the remainder (a shortfall is **2** here).
9. Then the items (`s:0x618fe0`) and the payment (`s:0x6186d0`); §3.3.

`0x1811` from any of these makes StorageOperation log "posting AsyncQuery failed. will be
disconnected" (`s:0x50f701`).

### 3.3 What success does

In memory, before the database (`s:0x618fe0`):

- For each item of the package (its scrap rows, `s:0x616660`), `n` times: first empty bag slot from
  13 (`CGStorage::FindFirstEmptySlot(0xd)`), create the item (vslot `0x360`), stack count =
  the scrap row's Data (`item ref +0x38`), or the request's quantity when that Data is 0, or 1 for
  a non-stackable item (`s:0x6190c0`-`0x6190dd`), and put it there (`s:0x618580`). The slots go into
  the request's list (`+0x68`). Any failure removes every item placed so far (`s:0x619358`-).
- **Destination: the bag only.** `s:0x526610` passes the player's inventory (`pc+0x1c10`) and first
  slot 13; there is no avatar-inventory, warehouse or other target. A dress bought in the mall
  lands in the bag (the client agrees: `c:0x871940` case 0x18 maps source `0xa7` to the bag `0x46`
  only).
- **Payment** (`s:0x618930`): gold through vslot `0x16c`; guild points, honour, coins likewise; silk
  as §3.2 step 8: the deducted own / gift amounts go into the request (`+0x98`, `+0xa0`), the
  points into `+0xb0`, and the balances are updated in memory with **no message** (`s:0x618e52`).
- A good with a stock record: the stock is decremented (`s:0x4de120`) and `0x3167` goes to the
  shard manager (`s:0x6188b4`; INFERRED a stock sync; its layout OPEN).

The database job: `AQ_StorageUpdaterForPacakageItem` (the class's own spelling) runs
`{CALL _STRG_ADD_PACKAGEITEM (Operation, CharID, PaymentDevice, RefPackageItemID, Count, RemainGold,
OwnSilkToPay, GiftSilkToPay, OptionalPointToPay, MileageToPay, CreaterName)}` or its
`_WITH_STOCKQUANTITY` form (`0x6e55a0`, `0x6e5540`). What it does (MEASURED, the procedure text in
the backup, `_STRG_ADD_PACKAGEITEM_CORE`):

- Operation 24 (= 0x18) works on `_Inventory` from slot 13 up to `_Char.InventorySize`.
- Slots needed (`_GetNeededSlotCountByBuyPackageItem`): a package with one scrap row whose item is
  an expendable (TypeID 3/3, Bionic 0) with Data 0 needs **1 slot, and the stack is the Count**;
  anything else needs Count slots, clamped to 1..5. Short → -3.
- Per scrap row, that many items, each into `_Find_First_Empty_Slotindex_Inventory`; the creating
  procedure by type (alchemy stone, magic item, specialty, expendable, equipment).
- `_UPDATE_COST` then calls `SRO_VT_ACCOUNT.DBO._ConsumeSilkByGameServer @JID, @OwnSilkToPay OUTPUT,
  @GiftSilkToPay OUTPUT, @MileageToPay OUTPUT, ...` (the OUTPUTs are the balances left) and records
  them as result rows slot 255 / 254 / 253 (type 2 / 4 / 16). Any failure rolls the items back.
- The rows of `_ResultOfPackageItemToMappingWithServerSide` are returned to the GameServer.

On success (`AsyncQuerySucceeded` job type 0x12 → `s:0x4e9480`): `0xB034` (§1) and, for 0x18,
`0x3153` with the balances from the database (`s:0x4e9ae0`). Which result row fills which of
`+0x98` / `+0xa0` / `+0xb0` is INFERRED from the slot numbers (255 own, 254 gift, 253 points; not
read). **On failure the player is logged out**: `s:0x4e9110` case 0x12 logs "AQ Failed! Log out!!"
and calls `FUN_004df050(4)`; no `0xB034` is sent.

Rent: each placed item's rent object, if any, is written as its rent block in the reply. The
GameServer builds rent info with `_Rent_Info_Manager` (`s:0x45ea30`), from `_RefRentItem`, which
is **empty** in the backup (MEASURED, also `_RentItemInfo`). Time-limited items carry their period
in the record's durability word instead (`iteminfo.go`, `avatar.PeriodWord`); where retail sets the
start of that period for a mall item, see `item_mall_data.md` §6 (OPEN here).

### 3.4 How the client applies the reply (READ, `c:0x87f370`)

1. Byte 1 (success) → `c:0x87eb50` parses the record (§1); the slot list into `+0x68..+0x6c`.
2. Type 0x18 → the good is found again from `shopGroupId` / index / tab / slot
   (`c:0x937af0`, `c:0x982750`, `UI_SILKMALL::FUN_007e28e0`).
3. One scrap item (`c:0x8bf0d0`): if it is an expendable (TID bits `0x1c == 0xc`, `0x60 == 0x60`)
   with Data 0, the **first slot only** gets one stack of `quantity`; otherwise each of
   `quantity` slots gets one item. Several scrap items: the slots are taken `quantity` at a time, scrap
   item `k` filling slots `k×quantity .. k×quantity+quantity−1` (`c:0x87fa13`-`0x87fa7a`). INFERRED: this is the
   order the server's loop (scrap item outer, count inner) produced the slots in.
4. Each placement (`c:0x87ba20`, source `0xa7`, `c:0x87dff9`-) creates the item from the client's
   own package tables (`c:0x6b35c0` the k-th scrap item) and reads **that slot's rent block** from
   the message (`c:0x87e0dc` → `c:0x8bb130`); a stackable gets the quantity (`c:0x87e1c5`-), then it
   plays `snd_equip`. The item's DB id and serial never reach the client.
5. Byte 2 → `u16 code` → `c:0x778190`, then the mall window is told (`c:0x7d6de0`).

### 3.5 An example (fields READ, values MEASURED or marked)

Buy one `PACKAGE_MALL_ITEM_ETC_ARCHEMY_MAGICSTONE_ASTRAL_11` (package ID 85592; one scrap row
`ITEM_ETC_ARCHEMY_MAGICSTONE_ASTRAL_11`, Data 0; price rows PaymentDevice 2 cost 30 and
PaymentDevice 4 cost 30: all MEASURED in the backup) from shop `MALL_ARCHEMY`, tab
`MALL_ARCHEMY_ASTRAL`, goods SlotIndex 0, group `GROUP_MALL` 1051. ILLUSTRATIVE, not measured: shop
index 0 and tab index 0 (their positions in the client's lists; `item_mall_data.md` gives the file
order), balances own 939 / gift 3731 / points 0 as in the screenshot, first free bag slot 13.

```
C->S 0x7034  18 1b 04 00 00 00 32 00
             50 41 43 4b 41 47 45 5f 4d 41 4c 4c 5f 49 54 45 4d 5f 45 54 43 5f 41 52 43 48 45 4d
             59 5f 4d 41 47 49 43 53 54 4f 4e 45 5f 41 53 54 52 41 4c 5f 31 31
             01 00  00 00 00 00 00 00 00 00  58 4e 01 00
             (type, group 1051, shop 0, tab 0, slot 0, name (50), qty 1, points 0, package 85592)
S->C 0x3153  ab 03 00 00  75 0e 00 00  00 00 00 00
             (own 939, gift 3701: bits 2 and 4 are both set, so the 30 came out of gift silk)
S->C 0xB034  01 18 1b 04 00 00 00 01 0d 01 00 00 00 00 00
             (ok, 0x18, group, shop, tab, slot, n = 1, bag slot 13, qty 1, rent block 0)
```

The client then makes one Astral stone stack of 1 in bag slot 13 (index 0).

## 4. The obtained and buying lists; the item chest

**No server-side list of purchases or of received items exists.** The only list messages are the
silk history (§5). Evidence: the mall windows send only `0x711a` and `0x7034` (the client's sender
census, `client_senders.tsv`: the mall code's only sends are those two); the buy writes straight
into the bag (§3.3); and the shard has no table for pending items: the only "chest" tables are
`_Chest` (UserJID, Slot, ItemID: the **account warehouse**, which the server loads with `SELECT IT.*
FROM _Chest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 WHERE C.UserJID=%d ...`, MEASURED in its strings) and `_GuildChest`; the only table with a sender
column is `_Memo` (MEASURED, a column search for From/Sender/Take/Receive/Gift).

The "Buying list" / "Obtained list" buttons and their contents are the window's (`item_mall.md`);
the lumped buy (`UIIT_MSG_QUESTION_SILKMALL_ZZIM_LUMP_BUY`) has no message of its own, so INFERRED it
sends one `0x7034` type 0x18 per good.

**The item chest in `LShp7DJ.png` (Chest / Take Log, From, Date, Take, Take All) is not in retail
vSRO 1.188's server.** The trace: a mall purchase has exactly one destination, the bag slots of
`pc+0x1c10` from 13 (`s:0x526683`-`0x52668e`); when they are short the buy is refused `0x1807`
before anything is made (`s:0x617a50` step 7, and `-3` in the procedure), with no second container
to fall back to; no GameServer handler takes a "take" or "list" request for such a container (every
mall message is §1); and no shard table could hold it. The one way retail puts bought items
anywhere else is the web shop's `_ADD_ITEM_EXTERN_CHEST(_FAST)` procedure (account name, code name,
data, plus), which writes **into the account warehouse `_Chest`** at its first empty slot, refusing
"chest Full" (MEASURED, procedure text); the game learns of it only by loading the warehouse. So
the Chest window is a private server's addition. If OpenSRO builds one, it is OURS: new messages
under OpenSRO's own range (list, take one, take all, the take log), the purchase choosing the chest
only when the bag is short.

## 5. The silk history (`0x711a` / `0xB11A`)

| | |
|---|---|
| Request | `u8 kind, u8 period` (READ: `c:0x7d40c0` sends `{1, combo+1}`, `c:0x7d5ea0` `{this+0x433, combo+1}`, both only for combo index 0..3, after showing `UIIT_MSG_SILK_INQUIRY_WAIT`) |
| Close | the mall's close (vslot 43: `CIFItemMall::vslot_043 c:0x7bd530` → `{2, 0xff}`; `CIFNewItemMall::vslot_043 c:0x7d7020` → `{1, 0xff}` when the list's pending flag `+0x7bc` is set). INFERRED **0xff cancels** the pending inquiry: the shard manager runs a query for op 0 and calls `sm:0x41d160` (remove the pending job) for op 0xff (`sm:0x41ce10`) |
| GameServer | `s:0x518cd0` reads the two bytes and sends `0x711b` to the shard manager (`DAT_00c8258c`): `u32, u32, u8 kind, u8 period` (`payload_layouts.tsv`) |
| Shard manager | `sm:0x413ec0` handles `0x711b`, turns it into its job `_HISTORY_FOR_BUYING_SILK_DATA` (`sm:0x41df30`, internal `0x791f`), and the answer comes back to the GameServer as `0xB11B {u32 player id, u32 check (must equal pc+8), body}` (`s:0x4186d0`), whose body goes to the client as `0xB11A` |
| Query | INFERRED (same two numbers, same ranges): `_GetSilkHistory @UserJID, @ReqType = kind, @ReqPeriod = period` (MEASURED text): `SELECT SILK_OFFSET, REGDATE FROM SRO_VT_ACCOUNT.DBO.SK_SILKBUYLIST`; kind 1 = Silk_Type 0 with Silk_Reason 0 or 1, kind 2 = Silk_Type 0 reason 3, kind 3 = Silk_Type 1 reason 2; period 1 a day, 2 a week, 3 a month, 4 three months |
| Reply | `u8 kind, u8 period, u8 result`; result 0: `u16 n`, n × `{u32 silkOffset, u32 date}`. The client puts kind 1 in one list (`c:0x7d6e30`, rows `c:0x7ec5b0`) and other kinds in another (`c:0x7d6e20`, `c:0x7ec750`), shows an empty-list line when n is 0 (`c:0x7ea6c0` / `0x7ea700`) and sums the offsets (`c:0x7ec630`). A non-zero result does nothing. How `date` is encoded is OPEN |

## 6. Other mall functions

- **Opening the mall** asks the server nothing: the open path (`UI_SILKMALL::FUN_007d7130`) sends
  no message, and the balances are already known from `0x3153` (READ: no send in it; census above).
- **Search, categories, preview ("Original")**: client-side only (no message in the census).
- **Buy Silk, Coupon**: no message (census). Their keys are `UIIT_STT_SILKMALL_BUY_SILK_LINK` and
  `UIIT_STT_SILKMALL_COUPON_EXCHANGE_LINK`; INFERRED they open web pages (the window agent's).
- **Gift**: the request has **no recipient field** (§3.1), so the game wire cannot gift.
  `UIIT_STT_SILKMALL_PRESENT` and `0x1881` NOT_ENOUGH_SILK_TO_GIFT exist in the client; where a gift
  would be sent is OPEN (INFERRED the web shop).
- **Packages vs single items**: every good is a package; a "single item" is a package with one scrap
  row (§3.3).
- **Avatar dresses**: into the bag like everything else (§3.3), then worn by the usual bag →
  avatar move `0x7034` type 0x24.
- **Gold-priced goods in the mall window**: when the confirm box's other currency button is
  checked (`c:0x7e8545` false, `c:0x7e8844` true), `NewItemMallConfirmBuy` checks gold
  (`0x180f`) and calls the plain move sender `c:0x7950b0` with source window `0x0f` (the NPC
  store) instead (`c:0x7e88c7`-`0x7e88f6`). What that request looks like and whether the server
  accepts it without an NPC is OPEN.

## 7. OpenSRO today (OURS)

OpenSRO's server has no mall: no silk balances, no `0x3153`, and NPC purchases ride OpenSRO's own
messages (`itemop.go`: only types 0, 2, 9, 0x22, 0x23, 0x24 are on the retail wire; any other type is
refused `0x1811`). To serve the retail client the server needs: the three balances per account
(OURS storage: retail keeps them in the account database behind a billing page), `0x3153` at world
entry and after each change, the type-0x18 handler with §3.2's checks and §3.3's placement and
payment, the `0xB034` reply with one rent block per slot, and `0x711a` answered from a silk log of
its own. The DB-failure logout is retail's; an in-process store can simply refuse with **2**
(OURS, if chosen).

## OPEN

1. Who sends `0xAA00` (the outside silk change), and the MD5 field's exact position in the
   billing reply.
2. The `0xB11A` date word's encoding.
3. What the client shows for `0x18ab` (no case in its error table).
4. StorageOperation's state 2 (vslot `0xf8`) that still allows op 0x18, and chardata `+0x13`
   (`0x180e`).
5. Which `_ResultOfPackageItemToMappingWithServerSide` row fills which of request `+0x98` / `+0xa0`
   / `+0xb0` after the database (INFERRED 255 own, 254 gift, 253 points).
6. `0x3167`'s layout (the stock sync to the shard manager).
7. The gold-currency path of the confirm box (§6) and a gift's route.
8. Where retail starts a mall item's period (time-limited goods); `_RefRentItem` is empty here.
9. `CPackageItem::FUN_00865df0` (the per-currency cost × quantity) is INFERRED, not read inside.

## OpenSRO (round 837)

What the server builds from this spec (`server/internal/mall`, `server/internal/session/mall.go`,
`server/internal/account/silk.go`, `server/internal/gm/silk.go`). Labels as above.

**The catalogue** (`mall.Build`, `export-refdata -mode mall` → `-mall-csv` / `OPENSRO_MALL_CSV`).
Every shop group whose NPC column is `xxx` is registered (`s:0x411b30`, U6), keyed by its ID; its
shops are `refmappingshopgroup`'s rows in file order (the client's `c:0x9379c0` list; the server's
SQL load order is OPEN, U12). A shop's tabs are its **first** tab group's `refshoptab` rows in file
order, **empty tabs counted**. That is the request's tab byte, READ: the confirm box reads it from
`CMallItemData +0x8` (`c:0x7e8651`: `0x97fa70` returns item+4, the byte at +4 of that), which the
builder fills from a counter zeroed at `c:0x7e4b0c` and stepped once per tab of the first group at
`c:0x7e50ea` (item_mall_verify.md W10, W11). The slot byte is the good's SlotIndex (`+0x9`,
`c:0x7e8663`). Which tabs the server's shop counts for `0x1806` is OPEN; every mall shop has one tab
group (MEASURED), so the two agree. Service-0 rows are skipped; a scrap row naming no itemdata row is
dropped (as `c:0x9824e0`); a 13-column price file (no PreviousCost) is read with Cost at column 4.
On the player's archive (Media.pk2, MEASURED 2026-10-27, outputs in `/var/tmp/r837mall` on the box):
7 NPC-less groups, 6 shops, 39 tabs, 233 goods; `GROUP_MALL` 1051 holds the 5 mall shops
(`MALL_ARCHEMY` 0, `MALL_AVATAR` 1, `MALL_CONSUME` 2, `MALL_PET` 3, `MALL_PREMIUM` 4) with 36 tabs and
220 goods; `GROUP_STORE_SD_ACCESSORY` 2630 is registered too (3 tabs, 13 goods), as retail would.

**The buy** (`mall.Check`, `session.mallBuy`): §3.2 in its corrected order. StorageOperation: the
established exchange (INTERACTMODE 2) → `0x1834`; OpenSRO has no mode 4 or 7, and an open NPC talk is
mode 5/6, which op `0x18` passes. Then the shop (2), the tab (`0x1806`), the quantity as an i16 (2),
the good (`0x1809`), the code name (`0x18ab`), the one-stack rule (W5 b: 2), the slots `n` (`0x4de170`),
the currencies (gold `0x180f`; any token bit 2; honour `0x18d4`; silk `0x1880` / 2; guild points last,
`0x18c4`), ExpandTerm (2). The access, condition, stock and period tables are empty in every source
and are not exported. OURS: a package with no scrap row and a per-unit quantity above 5 (M4) are
refused 2; honour and guild-point prices are refused (no such balances are wired); a store failure is
refused 2 instead of the logout. The purchase is one transaction: the checks on fresh balances, the
gold, the silk (`SpendSilk`, gift first then own, points as asked), the items, the purchase log.
Items: per scrap row (outer) `n` times (inner), each in the next empty bag slot from index 0, stack =
Data, or the quantity for Data 0, or 1 for a non-stackable (`s:0x6190c0`); the instance is OpenSRO's
fresh one with the row's plus and blue options (OURS: the row's Variance replaces the roll when not 0,
a non-stackable's Data replaces the durability word when not 0). Reply: `0x3153` (the balances after),
then `0xB034 {1, 0x18, group, shop, tab, slot, n, n × slot+13, qty, n × u32 0}`.

**Silk** (OURS storage): `accounts.silk_own`, `silk_gift`, `silk_point` (and `silk_seeded`), per
account. `0x3153` at world entry (after the friend list) and after each silk-priced purchase.
`-starting-silk` / `OPENSRO_STARTING_SILK` (default 0): own silk given once per account at its first
balance read. GM `/silk <amount> [own|gift|point]` (floor 0) sends `0x3154 {reason, cashType,
offset}` then `0x3153`; reason 2 (`SILK_BUY_RECEIVE`) for an addition, 1 (`SILK_BUY_CANCLE`) for a
subtraction (OURS), offset = the amount that moved.

**0x7121** → `0xB121 {1, u16 group (echoed), u8 0}`: no stock rows (OURS key; the client sends
`0x7121` only when its stock table has rows, so with this archive it is never sent).

**0x711a** → `0xB11A`. Kind 1 lists the account's purchases in the period (the silk each took,
own + gift + points), kinds 2 and 3 answer `n = 0`, kind ≥ 4 or a period outside 1..4 answers result 1
(OURS), period `0xff` no reply. Period 1 = 24 h, 2 = 7 days, 3 = one month, 4 = three months
(INFERRED, `_GetSilkHistory`). **The date word is READ** (closes OPEN 2): the row drawer `c:0x7ea310`
prints `"%4d/%02d/%02d %02d:%02d"` (`c:0xdcbf78`) from bits 0..5 year − 2000, 6..9 month, 10..14
day, 15..19 hour, 20..25 minute; bits 26..31 are not read and are written 0; OpenSRO writes local
time (OURS). Contradiction noted, not resolved: `_GetSilkHistory`'s kind 1 selects `Silk_Type 0` with
`Silk_Reason` 0 or 1, the reasons the client names `SILK_BUY_RESULT` / `SILK_BUY_CANCLE`, so retail's
Buying list is probably the silk the account **bought** (top-ups), not item purchases (INFERRED).
OpenSRO has no silk purchase and lists its item purchases there (OURS).

### The item chest (OURS)

Not retail (§4). A purchase whose items do not all fit the bag's empty slots goes, whole, to the
buyer **character's** chest: the silk is charged, the reply is `0xB034 {1, 0x18, group, shop, tab,
slot, n = 0, qty}` (no slot list, no rent blocks), then one `0x00D6` per item. Messages:

| Opcode | Dir | Layout |
|---|---|---|
| `0x00D0` | C→S | `{}` list the chest |
| `0x00D1` | S→C | `u16 n, n × {u32 entryId, u32 refItemId, u32 quantity, str from, u32 unixDate}` |
| `0x00D2` | C→S | `u32 entryId` (0 = take all) |
| `0x00D3` | S→C | `u8 result, u16 value`: result 1, value = items taken; result 2, value = code (`0x1807` bag full, `0x1809` no such entry, `0x1834` in an exchange, `0x1811` store failure); then a fresh `0x00D1` |
| `0x00D4` | C→S | `{}` the take log |
| `0x00D5` | S→C | `u16 n, n × {u32 refItemId, u32 quantity, str from, u32 unixDate, u32 takenDate}` (the last 7 days, newest first) |
| `0x00D6` | S→C | `u32 refItemId, u32 quantity`: an item entered the chest |

Strings are `u16 length` + bytes; dates Unix seconds. "From" is `Item Mall`. One entry per item made.
A take places into the first empty bag slots; take-all stops when the bag fills (`{1, taken}` if any
was taken, `{2, 0x1807}` if none). The taken items are bag rows the client reads with
`OpInventoryList` (`0x0031`). Tables: `mall_purchases`, `mall_chest`, `mall_chest_log` (pruned hourly
to 7 days).

QA: `partybot -gm-lines "/silk 1000" -mall-buy "1051,2,1,4,PACKAGE_ITEM_MALL_REVERSE_RETURN_SCROLL,2"
-mall-chest all -mall-history 1,1` logs `0x3153`, `0x3154`, `0xB034`, `0x00D1`/`0x00D3`/`0x00D5`/`0x00D6`
and `0xB11A`.
