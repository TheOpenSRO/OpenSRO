# Item mall wire spec: adversarial verification (round 837)

The claims in `docs/protocol/item_mall_wire.md`, re-read on 2026-10-27 from the binaries and the
shard exports: `SR_GameServer.exe` (`/var/tmp/gs_dis.txt`, `/var/tmp/decomp_server`, `objdump` of a
local copy), `SR_ShardManager.exe` (`/var/tmp/decomp_shardmgr`, `objdump`), `sro_client.exe`
(`/var/tmp/sro_client.dis`, `/var/tmp/decomp_client`, local `objdump`), and the r837 shard exports
(`/opt/sro-files/db/csv/r837/export_r837/`, tables and 27 stored procedures). CT 104 was not
started. `s:` is a GameServer address, `c:` a client address, `sm:` a shard-manager address.

Verdicts:

- **CONFIRMED**: the code at the cited address says what the spec says.
- **CONFIRMED+**: right, but the code does more, and that matters.
- **UPGRADE**: the spec says INFERRED or OPEN; the reading below makes it READ.
- **WRONG**: the correct reading is given.
- **PARTLY**: right in substance, wrong or loose in a detail.
- **UNVERIFIABLE**: needs data that is not on the box (the account database, or shard tables
  outside the r837 export).

## WRONG items first

| # | Spec claim (section) | Correct reading | Evidence |
|---|---|---|---|
| W1 | §1: rent block "`u32 flags`; bit 0 adds `u16, u32, u32`, bit 1 adds `u16, u32`" | One `u16` is read when **either** bit is set. Then bit 0 adds `u32, u32` and bit 1 adds `u16, u32`. With bit 1 alone the block is `u32, u16, u16, u32` (12 bytes), not `u32, u16, u32`. The spec's prose matches the client only when bit 0 is set. `iteminfo.go`'s reader already does it right (2 + 8 + 6). | `c:0x8bb130`: reads u32; `if (f&1 \|\| f&2)` reads u16; `if (f&1)` reads u32, u32; `if (f&2)` reads u16, u32. |
| W2 | §2.2: "The URL in this binary was patched by the private server to `http://173.32.224.92:15000/` (MEASURED, `strings`)" | The text `BILLING_SERVER_URL "http://173.32.224.92:15000/"` lies in the **PE header slack** (file offset `0x2bf`, VA `0x4002bf`, after the section table, next to a `.newimp` section). It sits between the IPs `194.163.174.105` and `173.32.224.92173.32.109.83`. **No instruction references it** (no xref to `0x4002b0`–`0x4002fb`). Only `0x4002fc` (`173.32.109.83`) is used, as a patched format string at `s:0x9365b9`. The loader takes the URL from a runtime string. `s:0x6a1750` reads the billing object's `std::string` (`+8`) through the global `0xd6aa04` (object `0xd16c2c`, class `CCgiCallForMuiltiFarmMgr`). That string is copied from `CMainProcess+0x4247c` (`s:0x4036e2` → `0x6a1060`). Where `+0x4247c` comes from (the server's configuration) is OPEN. The header text is at best a patcher's note. **Which URL this server used is not established.** | `strings` offset `0x2bf`; `grep` of `gs_dis.txt` for `0x4002..`; `s:0x6a1765`–`0x6a17c1`, `s:0x4036cc`–`0x4036e2`, `s:0x6a0f30`. |
| W3 | §2.2: "A failed load only logs 'Silk Data Loading Failed [JID]' (`s:0x450350`)" | After the log, the job's failure callback calls the PC's vslot `0x5d4(job, 0)`. That dispatcher (`s:0x4e9440`) sends a 0 result to `AsyncQueryFailed s:0x4e9110`. Job type 9 has no case there (jump table `0x4e9400` → index 6 → `0x4e93b8`), so the code logs "AQ Failed! Log out!!" and calls `FUN_004df050(4)`: **the player is disconnected.** The same happens when the billing reply is bad (`-1`..`-5`, wrong MD5, not `1:`), because `DoWork s:0x450290` then returns 0. | `s:0x450350`–`0x450383` (push 0; vslot `0x5d4`); `s:0x4e945b`–`0x4e9473`; `s:0x4e93b8`–`0x4e93d3`. |
| W4 | §3.1: `shopGroupId` = "the id of the shop group holding the shop: `c:0x9262c0` finds the group in the client's group list" | `c:0x9262c0` takes **no shop argument**. It walks the group map (`refdata+0x380`, ordered by the u16 ID) and returns the **first group whose byte `+0x28` is 1**. The parser sets that byte only when the group has no NPC **and its code equals `GROUP_MALL` exactly**. The compare is `compare(0, size(), L"GROUP_MALL", 10)`, which is 0 only for a 10-character string, not a prefix test. So the u16 is `GROUP_MALL`'s ID (1051) whatever shop is bought from. The value 1051 stands; the mechanism does not. | `c:0x9262c0`–`0x926309` (`cmp byte [eax+0x28],1`); `c:0x9843ce`–`0x9843e6` (`push 0xa; push 0xde1224; push [ebp+0x14]` = the string's own size; `call 0x47ec20`); `c:0x47ec20` returns `(n != 10)` when the 10 characters match. |
| W5 | §3.2 step 6: "A good with a pet-inventory side (`s:0x4de0f0` / `MainProcess+0x42404`)…" | `s:0x4de0f0` tests that **the package has exactly one scrap row** (package `+0x154`/`+0x158` vector size == 1), not a pet inventory. The step is: one scrap row, and its item is stackable (item vslot `0x4c`). Then: **(a)** when the server flag `CMainProcess+0x42404` is set, a trade good (vslot `0x58`) needs `pc+0x1ce8` (INFERRED the trade transport, else **2**). The quantity is then cut to the trading limit, or the buy is refused `0x1893`. Any other item with vslot `0x41c` true gets **2**. **(b) Missed by the spec:** when the scrap row's Data is 0, the quantity must fit one stack. For an expendable (TID 3/3, not bionic), `quantity ≤ ref+0x198` (`s:0x728130`). For TID2 1 the check is `s:0x7283a0`. Otherwise the quantity must be 0. A failure is **2**. | `s:0x617b27`–`0x617cf6`; `s:0x4de0f0`; `s:0x728270`, `0x728130`. |
| W6 | §3.2 step 8: the order "gold → coins → honour → guild point 8 → **Silk**" | The real order in `CheckCurrencyRequirement s:0x617360` is gold (`0x180f`), then coins `0x40`/`0x80`/`0x100`/`0x200` (`0x184a`) and `0x400` (`0x184d`), all only for op `0x2b`, then honour `0x20` (`0x18d4`), then **silk** (bits 2/4/16), then **guild point 8 last** (`0x18c4` no guild or not master, `0x18c5` short). A good priced in both silk and guild points reports the silk shortage first. | `s:0x617360` decompile, silk block before the `(mask & 8)` block. |
| W7 | §3.4 step 4: "a stackable gets the quantity (`c:0x87e1c5`-)" | The client gives the request's quantity **only** when the package has one scrap row, the item is stackable and the row's Data is ≤ 0 (`c:0x87e192`–`0x87e1c3`). In every other case a stackable gets **the scrap row's Data** (`ebx` = scrap `+0x18`, `c:0x87e18f`, `0x87e209`–`0x87e214`) and a non-stackable gets 1. Example: `PACKAGE_10XPACK_ITEM_ETC_ARCHEMY_MAGICSTONE_ASTRAL_11` has one row with Data 20 (MEASURED), so each slot gets a stack of 20, not of the quantity. This matches the server's rule in §3.3. | `c:0x87e184`–`0x87e214`; `_RefScrapOfPackageItem.csv`. |

**Cross-spec (not edited here):** `item_mall_data.md` §1.2 says the client flags a group "when …
the code **starts with** `GROUP_MALL` (a 10-character compare)". Per W4 the compare is whole-string
equality, so of the six mall groups only `GROUP_MALL` (1051) gets `+0x28 = 1`. That spec's owner
should correct it.

## 1. The wire

| Claim | Verdict | Evidence |
|---|---|---|
| Strings are `u16 length` + bytes, no terminator | CONFIRMED | `c:0x78f480` (push 2, then the bytes); server `s:0x404b60` reads a u16 and clamps it to what is left in the buffer. |
| `0x7034` type `0x18` = `u8 0x18, u16 group, u8 shopIdx, u8 tab, u8 slot, str code, u16 qty, u64 points, u32 packageId` | CONFIRMED | Client serializer `c:0x792944`–`0x79299d`: `+0x12` (2), `+0x14` (1), `+2` (1), `+3` (1), `+0xf4` (str), `+6` (2), `+0xb0` (8), `+0xc` (4). Server parser case `0x18` `s:0x4d8d52`–`0x4d8dc3` reads the same order and widths (helpers `0x48bf40` u16, `0x404c80` u8, `0x404b60` str → `+0x11c`, `0x42f7b0` u64, `0x404e50` u32). |
| Built by `c:0x826460` | CONFIRMED | `c:0x82650c` op byte; the points branch sets flag `0x10` at `+0x88` (`c:0x82655d`). |
| Server chain: StorageOperation → parser `0x4d8bf0` → `0xcd3b58 + 0x18*8` = `0x526610` | CONFIRMED | Table filled at `s:0x50cee0` (`mov eax,0x526610; mov [0xcd3c18],eax`); op 8 (NPC buy) = `0x5266a0` at `0xcd3b98`. |
| `0x711a` = `u8 kind, u8 period`; the six senders | CONFIRMED | `c:0x7d40c0`, `0x7d4210`, `0x7d5ea0`, `0x7d6000`, `0x7eabe0`, `0x7ecb90` (`push 0x711a`). |
| `s:0x518cd0` relays `0x711a` as `0x711b` | CONFIRMED | `u32` (PC vslot 8), `u32` (`pc+8`), `u8 kind`, `u8 period` (`s:0x518d60`–`0x518d9a`). |
| `0x3153` = three u32 own/gift/points; sent by `0x4f0940` when flag = 1; client `0x882de0` → `0x778e50` → `+0x4ac/+0x4b0/+0x4b4` | CONFIRMED | `s:0x4f0952`/`0x4f0970`; client handler table `c:0x8707e7`. |
| `0x3154` = `u8 reason, u8 cashType, u32 offset` | CONFIRMED | `s:0x4f087f`–`0x4f08ad`; client `c:0x882e50` (table `c:0x870808`). |
| `0xB034` success layout `1, 0x18, u16, u8, u8, u8, u8 n, n×u8, u16 qty, n×rent` | CONFIRMED | `s:0x4e95fb` writes `1`; `0x4f76e0` writes the op, then `s:0x4f7cd9`–`0x4f7d6c` and `0x4f79d9` (u16 at `+6`); rent blocks `s:0x4e99f3`–`0x4e9a5d`. Client parser `c:0x87eb50` case `0x18` reads the same order. |
| Rent block per slot, `0` when the item has no rent object (`0x862960`) | CONFIRMED+ | `s:0x4e9a39` `GetItem(slot)`; `0x845b30` → the rent object `+0xd4` vslot `0x24`, else `0x862960` writes u32 0. **If `GetItem` returns null nothing is written** for that slot, which would desync the client. It cannot happen after a good placement. |
| Rent block bit layout | **WRONG, see W1** | |
| `0xB034` failure `{2, u16}` from `0x50f6cd` | CONFIRMED | `s:0x50f6df`–`0x50f6e7` (`push code; mov ecx,0xb034; call 0x4e7250`). |
| Client failure: `0x778190` message, then the mall window's `0x7d6de0` | CONFIRMED+ | `c:0x87f370`: `0x778190(1, code, 0xffdbc99b, 0, 1)`. Only if window `0xa7` exists: `0x7d6de0(1)` zeroes its "ItemMallDealing" counter `+0x7dc` and kills timer `0x96`. The COS inventory window (`0x7998b0`) is refreshed too. See also "Missed" M1 and M2. |
| `0xB11A` from `0x4186d0` (body copied) | CONFIRMED | `0x4186d0` checks `pc+8` ("PC is not same"), then `MsgBuf_ReadRemaining`. Client `0x8990c0` (table `c:0x8a408c`). |
| Bag slot = index + 13; `c:0x871940` case `0x18` → source `0xa7`, bag `0x46` for 13..111 | CONFIRMED | `c:0x871940` case `0x18`: `*src = 0xa7`; `0xc < slot < 0x70` → `0x46`. |
| Client handler bindings | CONFIRMED | `c:0x8705f8` (`0xb034` → `0x87f370`), `0x8707e7`, `0x870808`, `0x8a408c`. |

## 2. Silk

| Claim | Verdict | Evidence |
|---|---|---|
| `pc[0x862..0x864]` = own, gift, points | CONFIRMED | `s:0x4f0959`–`0x4f096a` (`pc+0x2188/0x218c/0x2190`). |
| Names `Silk_Own`/`Silk_Gift`/`Mileage`, `EXPAND_DEVICE_*` 2/4/16 | CONFIRMED (MEASURED) | `_GET_REMAIN_SILK.sql`, `_UPDATE_COST.sql` comment. |
| Each clamped to 0 when negative | CONFIRMED+ | `s:0x4f0940`–`0x4f0950`. The clamped values are also **stored** (`0x4f0965`–`0x4f096a`), with flag 0 or 1. |
| Getters `0x778e20/30/40`; window `0x7dd3a0` uses them | CONFIRMED | |
| HTTP GET `%sbilling_silkdatacall.asp?JID=%d` | CONFIRMED | Format at `0xb08d60`, `s:0x6a17c1`. |
| Split at `:`, head must be `"1"` | CONFIRMED | `s:0x6a14e2` `push 0x3a`; `s:0x6a1506` `0xae051c` = "1". |
| Three integers, then the MD5 (INFERRED fourth field) | CONFIRMED (stays INFERRED) | `0x6a1450`: tokens 0 and 1 split at `,`; token 2 is **the whole remainder**, read with `atol`, which stops at the next `,`. `0x6a1750` splits a `,` again (`0x6a1330(0x2c, …)`) for the received MD5. |
| Error codes -1..-5 | CONFIRMED | `0x6a1750` switch. Any other negative value logs "invalid error code". |
| MD5 of `"%d.%d.%d.%d.%s"` with salt `SROG8Z_CDE1210598DK_AKD3HW1K04DL2-` must match | CONFIRMED | `0x6a1750`; compare and length check before writing the outputs. |
| Values → job `+0x2c/+0x30/+0x34` in that order | CONFIRMED | `0x6a1750`: first → `*param_5` (`esp+8` → `+0x2c`), second → `+0x30`, third → `+0x34` (`s:0x4502fd`–`0x450310`). |
| URL patched to `173.32.224.92:15000` | **WRONG, see W2** | |
| Case 9 `s:0x4e780e` → `0x4f0940(flag 1)` | CONFIRMED | eax=`+0x2c`, edx=`+0x30`, ecx=`+0x34`, push 1. |
| Posted from `vslot_391` (`0x4dffbe` → `0x4501a0`); INFERRED world entry | CONFIRMED (stays INFERRED) | `0x4501a0` → `0x450510`. **Also:** the job's Init `s:0x4501e0` first probes `<URL>billing_serverstate.asp` (`s:0x6a11e0`) and needs `atol(reply) == 1`. Otherwise the job is not posted (INFERRED: then no `0x3153` at entry). |
| A failed load only logs | **WRONG, see W3** | |
| `_GET_REMAIN_SILK` only forwards to `SRO_VT_ACCOUNT.._GETSILKDATAFORGAMESERVER` | CONFIRMED (MEASURED) | `_GET_REMAIN_SILK.sql`. |
| `0xAA00` → `0x414930` → `0x4f0750`: `u32 JID, u32 remain, u32 offset, u8 cashType, u8 reason` | CONFIRMED | `s:0x4148cf`; `0x414933` reads the u32 key and looks it up in `CMainProcess+0x2290` (INFERRED JID map). `0x4f0750` reads remain, offset, type, reason; its log strings name them. |
| `0x3154` sent, `balance[type] = remain`, then `0x3153` | CONFIRMED | `s:0x4f086c`–`0x4f08bd`, `0x4f08c8`, `0x4f08e3`. |
| Unknown type or reason only logs | CONFIRMED | Assert + log, return before any send. |
| Client strings by reason; `0xff` → TRADE_FAILURE; cash type unused | CONFIRMED+ | `c:0x882e50`. Reason values 6..0xfe show **nothing** (switch default). |
| The `0x3153` table (entry, after purchase, outside change, own deduction flag 0) | CONFIRMED+ | The post-purchase send (`s:0x4e9ae0`) only happens when the request mask `+0x88` has bit 2, 4 or `0x10`. **That mask is cleared and rebuilt from the database's result rows** (see §3.3 UPGRADE), so a purchase with no silk rows sends no `0x3153`. |
| `0x3153` reaches the client before `0xB034` (INFERRED) | **UPGRADE → READ** | `0x278` = `CGObjPC::AllocMsgForPeer s:0x4e0830`. `0x27c` = `CGObjPC::SendMsgToPeer s:0x4e0860`, which hands the message to the network object (`DAT_00c8258c` vslot `0x4c`) at once. `0x4e9ae0`'s `0x27c` (`s:0x4f09be`) runs before `0x4e9480`'s (`s:0x4e9a7c`) on the same peer. |

## 3. The buy request and the server

### 3.1 Fields and client pre-checks

| Claim | Verdict | Evidence |
|---|---|---|
| Op byte `c:0x82650c` | CONFIRMED | |
| `shopGroupId` mechanism | **WRONG, see W4** (value 1051 stands) | |
| Server log calls it `shopGroup_id` | CONFIRMED | `.rdata 0xaf7348`, `s:0x526651`. |
| `shopIndexInGroup` from `c:0x9379c0`; INFERRED same list order on both sides | CONFIRMED+ | `0x9379c0(shopId)` scans **all** groups in key order and returns the position inside the first group whose shop list contains the shop. The group sent is chosen independently (W4). With the shipped data only `GROUP_MALL` lists mall shops (`item_mall_data.md` §1.3), so the two agree. |
| `tab` `+2`; log "SendNetMsgItemMall…" at `c:0x826610` | CONFIRMED | String `0xdb9a88`. |
| `slot` `+3` | CONFIRMED | |
| Code name `+0xf4` client, `+0x11c` server; package record `+8+8` | CONFIRMED | `c:0x7e867c` (`0x9809b0` = record `+8`, then `+8`). The client converts the wide code name to a narrow string (`c:0x4fc950`/`0x410380`). |
| `quantity` u16 `+6` | CONFIRMED+ | The server tests it as **signed** i16 (`s:0x617ab6` `cmp word [edi+6],0; jle` → 2), so `0x8000`–`0xffff` are refused with 2. |
| `pointsToUse` `+0xb0`, only with mask bit `0x10`, clamped to `min(price × qty, entered)` at `c:0x7e8925`–`0x7e8991` | CONFIRMED | Those addresses are in `UI_SILKMALL::FUN_007e8900` (the points box), not the confirm function. The confirm passes `this+0x7f8/0x7fc` (`c:0x7e8768`). |
| `packageId` `+0xc` not read by the buy path (INFERRED) | CONFIRMED (stays INFERRED) | No read of request `+0xc` in `0x617a50`, `0x618fe0`, `0x6186d0`, `0x618930`. The DB call takes the package from the good. |
| New confirm sends the name; old `c:0x7c4880` sends `""` (`0xe16204`) | CONFIRMED | `c:0x7c4bec` `push 0xe16204; call 0x410380`. Both call `0x7999c0(1)` before sending (M1). |
| Empty name → `0x18ab` | CONFIRMED | `s:0x617b01`–`0x617b16`: request `+0x11c` against package `+0xc` (`0x425210`). |
| Client pre-checks: free slots ≥ qty (1 for stackable), else `0x1807`; own+gift+points ≥ price×qty, else `0x1880` | CONFIRMED+ | `c:0x7e8320`. For a **one-row** package the slot test runs per row: an expendable (not bionic, TID 3/3) with Data 0 needs 1, anything else needs qty. With **two or more rows** (`c:0x8bf0d0` = row count ≥ 2) it needs qty, not qty × rows. The silk test **always counts points**, even when the good has no mask bit `0x10`, but the server counts them only with that bit (M10). Quantity 0 closes the box with no message (`c:0x7e85c4`). |

### 3.2 The server's checks, in order

| Claim | Verdict | Evidence |
|---|---|---|
| Step 1 StorageOperation: vslot `0xf8` = 2 lets only `0x18`/`0x17` through (else 2); INTERACTMODE 4 → `0x1834`; 2 or 7 → `0x1834`; chardata `+0x13` → `0x180e` | CONFIRMED+ | `s:0x50f67c`–`0x50f69d`, `0x50f7b8`–`0x50f7e8`, `0x50f84f`–`0x50f865`. Before refusing `0x180e`, the server **clears** the `+0x13` state with `0x4e0c60(pc, 0)`. |
| Step 2: silk-shop map by group, shop by index (`0x523740` → `0x5236f0`); missing → 2 + log | CONFIRMED | `s:0x52662a`–`0x526663`. |
| Map filled from groups with record `+0x28 == 0` (`0x411b30`); INFERRED `+0x28` = the NPC | CONFIRMED (stays INFERRED) | Keyed by the group's u16 at `+8` (`0x411bc0`). Every NPC-less group is registered, not only 1051. |
| Step 3 shop access `0x617a30` → `0x61a860` → `0x61be20` → 2; INFERRED `_RefAccessPermissionOfShop` | CONFIRMED | The list is at the shop record (`[shop+8]`)`+0xb8` (`s:0x617a3e`). |
| Step 4 tab ≥ count → `0x1806`; qty ≤ 0 → 2; no good → `0x1809` | CONFIRMED | `s:0x617a8d`–`0x617aeb` (also 2 when the PC or the inventory is null). |
| Step 5 code name ≠ → `0x18ab` | CONFIRMED | |
| Step 6 "pet-inventory side" | **WRONG, see W5** | |
| Step 7 `n = 0x4de170` < 6 else 2; free < n → `0x1807`; stock `+0x18`/`+0x5a` < n → `0x18cf`; sale window `+0x1c` → `0x18aa` | CONFIRMED+ | `s:0x617cfc`–`0x617e42`. `0x4de170` returns **1** for a one-row expendable (not bionic, 3/3) with Data 0, else **qty clamped to 1..5**. So `n < 6` always holds and the "else 2" branch is dead (`cmp bl,5; ja`). The stock is compared with **n**, not with the quantity. The sale window fails when "now < start" or "end ≤ now". |
| Step 8 order | **WRONG, see W6** | |
| Price: `0x867480` per PaymentDevice bit (package `+0x48`); bit 0 via the shop (vslot `0xc`); bit index 4 (`0x10`) priced 0; other bits `CPackageItem::FUN_00865df0`, INFERRED cost × qty | CONFIRMED / **UPGRADE → READ** | `0x865df0` → `0x865d90`: `(i16)qty × package[+0x50 + 8·bit]` (u64, `_allmul` at `0x865dd7`). The gold price adds the fortress tax and is floored at 1 (`s:0x617000`). Note: "bit 4 (points)" means bit **index** 4 = mask `0x10`, while "bits 2, 4, 16" are mask values. |
| Silk rules: price = silk (bit 2) else gift (bit 4); available = own·b2 + gift·b4 + points·b16 < price → `0x1880`; points < 0, > balance, > price → 2; rest by bit; both bits = gift first, a shortfall is 2 | CONFIRMED | `s:0x617360` silk block. A shortfall of 2 is reachable: available counts all the points, but `rest` only drops by `pointsToUse`. |
| Step 9 items, then payment | CONFIRMED+ | Between the currency check and the items, two more checks the spec misses (M6, M7). They run in `0x617950` and `0x617e90`. |
| `0x1811` → log "will be disconnected" (`0x50f701`) | CONFIRMED+ | Then `0x4df050(4)` at `s:0x50f717`: the player **is** disconnected, after `0xB034 {2, 0x1811}`. |

### 3.3 Success, the database, rent

| Claim | Verdict | Evidence |
|---|---|---|
| Placement loop: per scrap item, n times: `FindFirstEmptySlot(0xd)`, create (vslot `0x360`), stack = Data / qty / 1, place (`0x618580`), slots into `+0x68`, rollback (`0x619358`) | CONFIRMED+ / PARTLY | `s:0x618fe0`. The spec says "item ref `+0x38`". The field is the scrap row's Data: the template's `+0x34` points to the scrap row and Data is its `+0x38`. **Missed:** each item first passes `0x6182a0` (`CanStoreThisItem` → `0x180b`, and further refusals, M8). A rent-limited item can fail `0x1842`. An empty slot not found here gives `0x1807` after an assert (M9). |
| Destination: the bag only | CONFIRMED | `s:0x526683`–`0x52668e` (`pc+0x1c10`, 13). |
| Payment `0x618930`: deducted own/gift → `+0x98`/`+0xa0`, points `+0xb0`; balances updated with flag 0 | CONFIRMED | Own → `+0x98` with mask bit 2, gift → `+0xa0` with bit 4; `s:0x618e44`–`0x618e52` (push 0). |
| Stock decrement `0x4de120`; `0x3167` to the shard manager (layout OPEN) | CONFIRMED | `s:0x6186d0` (sent only when `0x616fe0()` is 0). Layout stays OPEN. |
| `AQ_StorageUpdaterForPacakageItem` runs `_STRG_ADD_PACKAGEITEM(…)` or `_WITH_STOCKQUANTITY` | CONFIRMED+ | `s:0x45e080`. The stock form has **12** fields: `@RefShopGroupID` is its 4th parameter (MEASURED, procedure text and the format string). The job is posted from StorageOperation's success branch (`0x50fa50`). On a post failure → `{2, 0x1811}` + disconnect. On success, **nothing is sent until the database answers**. |
| Procedure facts (op 24 = bag 13..InventorySize; slot count rule, clamp 1..5, -3; per-row creation; `_UPDATE_COST` → `_ConsumeSilkByGameServer` and rows 255/254/253) | CONFIRMED (MEASURED) | `_STRG_ADD_PACKAGEITEM_CORE.sql` lines 83–146, 227–243, 535; `_GetNeededSlotCountByBuyPackageItem.sql`; `_UPDATE_COST.sql` lines 109–125 (rows `(op, CharID, 255, @OwnSilkToPay, 2, 0, 1, 0)`, …). That the OUTPUTs are remaining balances stays INFERRED (the account procedure is not in the backup). |
| Success → `0xB034` and `0x3153` from the database's balances | CONFIRMED | `0x4e9480` case `0x18` → `0x4e9ae0` (eax=`+0x98`, edx=`+0xa0`, ecx=`+0xb0`). |
| Which row fills `+0x98`/`+0xa0`/`+0xb0` (INFERRED from the slot numbers; OPEN 5) | **UPGRADE → READ (OPEN 5 closed)** | Rows are 27-byte records (`s:0x45e4c0`). Type (`+0x19`) 1 = cost rows, kept in vector `+0x38`; 0 = item rows (SubType 1 → `+0x28`, 2 → `+0x48`); 2 = error rows (`+1` → job `+0x68`). In `AsyncQuerySucceeded` case `0x12` the request mask `+0x88` is **zeroed**. Then for each cost row the lowest set bit k of `RefItemDBID` (row `+0xd`) is found, and `RefItemSerial64` (row `+5`) is stored at request `+0x90 + 8k` with bit k set (`s:0x4e858b`–`0x4e85b5` → `0x4b2bd0`). So the **row's payment bit** decides, not the slot: 2 → `+0x98` own, 4 → `+0xa0` gift, 16 → `+0xb0` points. |
| Database failure → logout, no `0xB034` | CONFIRMED+ | `0x4e9110` case `0x12` → `0x4e93b8`. For op `0x18` every procedure failure ends here: no item rows → `DoWork` fails at line `0xb8e` (`s:0x45e73c`) → `vslot_008` → failed. The error-row reply path (`s:0x4e8706`–`0x4e8822`) is not reached by op `0x18`. It sends `{2, low byte of the error}` for the other package ops. |
| Rent via `_Rent_Info_Manager` (`0x45ea30`); `_RefRentItem` and `_RentItemInfo` empty | CONFIRMED | Format string at `0x45ea30`. Both CSVs are header-only in the r837 export (MEASURED). |

### 3.4 How the client applies the reply

| Claim | Verdict | Evidence |
|---|---|---|
| Byte 1 → `0x87eb50` parses the record; slot list into `+0x68..+0x6c` | CONFIRMED | |
| Type `0x18` → the good is found again from group / index / tab / slot (`0x937af0`, `0x982750`, `0x7e28e0`) | CONFIRMED+ | **The reply's group id is not used.** `c:0x87f733` calls `0x937af0(npcId = 0, index)`. That returns the `index`-th shop of the first group in key order whose NPC id (`+0x24`) is 0 and whose list is long enough. `0x7e28e0(shopId, tab, slot)` then finds the good. |
| One scrap item (`0x8bf0d0`): expendable with Data 0 → first slot gets the whole quantity; else one item per slot; several rows → `quantity` slots per row in order | CONFIRMED+ | `c:0x8bf0d0` is the "≥ 2 scrap rows" test. The expendable test also requires the **bionic bit (word bit 1) clear** (`c:0x87f869`–`0x87f881`, as the server's `0x4de170`). The multi-row loop uses the **reply's quantity** as the per-row count (M4). |
| Placement creates the item from the client's own tables, reads that slot's rent block, stackable gets the quantity | **WRONG in the count, see W7** | Rent block `c:0x87e0dc` → `0x8bb130` CONFIRMED. `0x7d6da0` (`c:0x87e2dc`) decrements the window's dealing counter per placed item (M1). |
| Byte 2 → u16 → `0x778190`, then `0x7d6de0` | CONFIRMED | |

### 3.5 The example

| Claim | Verdict | Evidence |
|---|---|---|
| Package 85592, one row Data 0, prices 2/30 and 4/30, shop `MALL_ARCHEMY`, tab `MALL_ARCHEMY_ASTRAL`, slot 0 | CONFIRMED (MEASURED) | `_RefPackageItem.csv` (85592, `EXPAND_TERM_ALL`), `_RefPricePolicyOfItem.csv`, `_RefScrapOfPackageItem.csv`, `_RefShopGoods.csv`. |
| Bytes of `0x7034`, `0x3153`, `0xB034` | CONFIRMED | 50-byte name, `58 4e 01 00` = 85592, `ab 03`/`75 0e` = 939/3701. Bits 2 and 4 are set, so gift pays first and 3731 − 30 = 3701. The order (`0x3153` first) is now READ. |

## 4. Lists and the item chest

| Claim | Verdict | Evidence |
|---|---|---|
| The mall sends only `0x711a` and `0x7034` | CONFIRMED (with a note) | Census: the only direct sends in the mall's own code are the six `0x711a` senders. The buys go through `0x826460` (new and old confirm) and `GInterfaceSend 0x7978a0` (old lump buy, `c:0x7bfe7b`). The other sender calls found in `0x7b0000`–`0x7f0000` belong to other windows (`CIFSkillWithdrawal`, `CIFDelayInfo`, whole-chat `0x7ef550`). |
| `_Chest` is the account warehouse, loaded by `SELECT IT.* FROM _Chest C JOIN _ITEMS …` | CONFIRMED | `strings` of the GameServer (also `SELECT SLOT FROM _CHEST …`, `LOADTARGET_CHEST Failed`). |
| Only `_Chest`/`_GuildChest`; only `_Memo` has a sender column | UNVERIFIABLE | Those tables are not in the r837 export, and CT 104 must stay stopped. |
| Lumped buy has no message of its own; INFERRED one `0x7034` per good | PARTLY UPGRADED | READ for the old window. `CIFItemMall c:0x7bfbd0` walks its list (`+0x9d4`) and sends one request per entry through `0x7978a0`. On a local failure it builds a **fake `0xB034 {2, 0x1807}` or `{2, 0x1880}`** and feeds it to its own handler (`c:0x7bfc5a`, `0x7bfd17`, `0xba8f70`). The new window's lump buy was not read. |
| Chest not retail: one destination, `0x1807` before anything is made, no take/list handler | CONFIRMED (server side) | §3.2/§3.3 above. "No handler" rests on the mall having only these two requests. |
| `_ADD_ITEM_EXTERN_CHEST(_FAST)` writes into `_Chest` | UNVERIFIABLE | Not among the 27 exported procedures. |

## 5. Silk history

| Claim | Verdict | Evidence |
|---|---|---|
| Request `{1, combo+1}` (`0x7d40c0`), `{this+0x433, combo+1}` (`0x7d5ea0`), combo 0..3, after INQUIRY_WAIT | CONFIRMED | `0x7ecb90` also sends `{1, combo+1}`. |
| Close: `{2, 0xff}` (`0x7bd530` → `0x7d6000`), `{1, 0xff}` (`0x7d7020` → `0x7eabe0`, when `+0x7bc`) | CONFIRMED | `c:0x7d6071`/`0x7d6076`; `c:0x7eac57`/`0x7eac5c`. |
| INFERRED 0xff cancels | **UPGRADE → READ** | `sm:0x413fc2`: the **period** byte = `0xff` → op byte `0xff` in `0x791f`, else 0. `sm:0x41ce10` op `0xff` → `0x41d160` finds the player's entry in the pending map (`+0x400e0`) and erases it. No query runs. Op 0 → `0x41c870`/`0x41d050` inserts a pending entry. |
| `0x711b` → SM `0x413ec0` → `0x791f`; job name `_HISTORY_FOR_BUYING_SILK_DATA` (`0x41df30`) | CONFIRMED | `0x41df30` only returns the name string. The `0xB11B` body is relayed by `sm:0x4140d0` from a `0xB91F`, so who builds it is outside these binaries. |
| `0xB11B {u32 id, u32 check, body}` | CONFIRMED | `s:0x4186d0`. |
| `_GetSilkHistory` kinds and periods | CONFIRMED (MEASURED); link stays INFERRED | `_GetSilkHistory.sql`. Kind 4+ raises an error and periods 5+ give an empty condition, so the query fails. |
| Reply parse and lists | CONFIRMED | `c:0x8990c0`. Kind ≠ 1 also calls `0x7ec7f0(kind)`. |

## 6. Other

| Claim | Verdict | Evidence |
|---|---|---|
| Opening the mall sends nothing (`0x7d7130`) | CONFIRMED+ | It does nothing while the dealing counter `+0x7dc` ≠ 0. |
| Gold path in the confirm box → `0x7950b0(0x0f, slot, 0x46, −1, qty, 0)` | CONFIRMED | `c:0x7e88c7`–`0x7e88f6`. Gold < price × qty → `0x180f` (`c:0x7e8895`). |
| `UIIT_STT_*` keys, gift has no recipient field | CONFIRMED | |

## Missed

What an implementation needs that the spec does not say:

- **M1. The client stays "dealing" until it gets a reply.** Before sending, both confirm boxes call
  `0x7999c0(1)` (`c:0x7e8728`, `c:0x7c4bde`). That sets the global item-op lock `DAT_00ee9b10` and
  starts timer 10 for 3000 ms. The new box also sets the window's "ItemMallDealing" counter `+0x7dc`
  to the quantity (`c:0x7d6d80`), and asserts if it is ≤ 0. Every `0xB034` clears the lock and the
  timer (`c:0x87f370` → `0x7999c0(0)`). A placed item decrements the counter (`0x7d6da0`, from
  `c:0x87e2dc`). A failure reply zeroes it (`0x7d6de0(1)`). While the counter is non-zero, the new
  window will not close (`c:0x7d7020` returns 0) and will not reopen (`c:0x7d7130`). **So the
  server must answer every type-0x18 request, success or `{2, code}`.** Retail never leaves one
  unanswered: it disconnects instead. What timer 10 or timer `0x96` does on expiry is OPEN.
- **M2. What the client shows for each code (OPEN 3 closed).** Codes go through `0x778190`, then
  `0x7b8b40` category 1. Below `0x180b` only `3` and `0x1807` have text. From `0x180b` to `0x18ff`
  the index table `0x7bb6d4` decides (READ, `c:0x7b8ce7`–`0x7b8cfe`). `0x18aa`/`0x18cf` show
  SOLDOUT, `0x1880` and `0x180f` have cases, and so do `0x1893`, `0x1834`, `0x180b`, `0x180e`,
  `0x18d4`, `0x18c4`, `0x18c5` and `0x184a`. **`0x18ab`, `0x1842`, `0x1811`, `2`, `5`, `0x1806` and
  `0x1809` show nothing** (default `0x7b913a`). The mall window is still told (`0x7d6de0`).
- **M3. The send order and timing are READ.** The server sends nothing at request time on success.
  After the database it sends `0x3153`, then `0xB034`, back to back.
- **M4. Quantities above 5.** The server creates at most `min(qty, 5)` items per scrap row
  (`0x4de170`), except a one-row expendable with Data 0. It still charges `cost × qty`
  (`0x865d90`), and the reply echoes `qty`. The client's reply loops use the echoed quantity as the
  per-row count (`c:0x87f370`, the single-row and multi-row branches), so with `qty > 5` the client
  walks past the slot list. OpenSRO should refuse such requests (OURS) or cap them. Whether the
  retail window caps the box at 5 is the window's (`item_mall.md`).
- **M5. Max-stack check** (W5 b). A one-row stackable with Data 0 must fit one stack
  (`ref+0x198`), else 2.
- **M6. `ExpandTerm`.** After the currency check, `0x617950` compares the package's `+0x2c` string.
  For `EXPAND_TERM_ALL` the mask of the computed prices must equal the package's PaymentDevice
  `+0x48`, else 2 (`s:0x6179e9`–`0x617a07`). `EXPAND_TERM_ONE` asserts and passes when any price
  was set; anything else is 2. This answers `item_mall_data.md`'s OPEN on ExpandTerm in part.
- **M7. Package sell conditions.** Next, `0x61a8e0` → `0x61ab80` runs the package's own condition
  list (package `+0x170`, through `0x61be20`). Any failure is 2. INFERRED
  `_RefConditionToSellPackageItem` (the export has one row).
- **M8. Per-item refusals in the placement loop** (`0x6182a0`, mis-named `SellItemAtSpecialtyShop` in
  the decompile). `CanStoreThisItem` false → `0x180b`. With the server flag `+0x42404` on, an item
  with vslot `0x41c` or code `ITEM_MALL_GACHA_CARD` → 2, then the trade-goods checks. A
  rent-limited item can fail `0x1842` (`s:0x619353`). Every failure rolls back the items placed so
  far.
- **M9. Multi-row packages.** Step 7 compares free slots with n, not n × rows. A multi-row package
  that does not fit fails inside the loop with `0x1807`, after an assert, and is rolled back
  (`s:0x61930c`). The procedure's own count has the same blind spot.
- **M10. Points in the client's silk sum.** The client counts points even for a good without bit
  `0x10` (`c:0x7e837b`–`0x7e839a`). The server ignores them, so such a buy passes the client and
  gets `0x1880`.
- **M11. The billing probe.** `<URL>billing_serverstate.asp` must answer `1` before every silk
  load (`s:0x45020a` → `0x6a11e0`). A bad billing answer disconnects the player (W3).
- **M12. Integrity checks.** After the op returns, StorageOperation runs `CheckEquipsetIntegrity`
  and `CheckAvatarsetIntegrity` (`s:0x50f89e`, `0x50f8b1`). A failure disconnects with no reply.
- **M13. Client and server disagree on one stack count.** For a multi-row package whose stackable
  row has Data 0, the server makes a stack of the quantity (`s:0x6190c0`). The client's
  multi-row branch takes Data, which is 0 (`c:0x87e1c5`–`0x87e214`). Whether retail data has such
  packages was not measured.

## Counts

- **Claims checked: 96** section rows. Seven of them point to the W table, so 89 are
  independent verdicts, plus the 7 W rows.
- **WRONG: 7** (W1–W7). W1, W5, W6 and W7 change what an implementation does. W2 and W3 change the
  silk-load story. W4 changes how the group id is chosen, not its value.
- **CONFIRMED: 64**, plus **17 CONFIRMED+** (right, with behaviour the spec leaves out).
- **UPGRADE (INFERRED/OPEN → READ): 4 rows**:
  - the `0x3153`-before-`0xB034` order;
  - the result-row mapping (OPEN 5);
  - cost × quantity (OPEN 9);
  - `0xff` cancels the history query.

  A fifth upgrade, what the client shows for `0x18ab` (OPEN 3), is in M2.
- **PARTLY: 2**:
  - the placement loop's "item ref `+0x38`" label;
  - the lump buy, which is READ for the old window only.
- **UNVERIFIABLE: 2**:
  - the `_GuildChest`/`_Memo` column search;
  - `_ADD_ITEM_EXTERN_CHEST`.
- **Cross-spec:** 1. `item_mall_data.md` §1.2's "starts with `GROUP_MALL`" is an exact match.
