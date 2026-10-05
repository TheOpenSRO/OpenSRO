# Round 728 review: buy back, stack split, deposit fee, item count label

Reviewer: an independent adversarial pass over `dev..85067cf7` (worktree-agent-aadbf0ee0ec778c01).
No code was changed. Addresses are `c:` sro_client.exe and `gs:` SR_GameServer.exe, read from the
dumps on the render box (`/var/tmp/decomp_client`, `/var/tmp/decomp_server`, `srgs.asm`,
`sro_client.asm`).

## Verdict

The count label and the split box are well grounded, and the live run is real. But the retail
protocol for everything in this round exists and is now read:

- buy back has its own request, **0x7168**, and its own reply, **0xB168**;
- the bought-back item arrives as an **0xB034 move result of type 0x22**;
- the buy-back list is **never requested**. The client builds it from the trailing byte of every
  0xB034 sell result (type 9).

So the four invented messages `0x0118`–`0x011B` are a DEPARTURE. Several rules the round marks as
INFERRED or OURS are now READ, and three of them differ from what was built:

- the deposit fee is capped at 10,000,000;
- a bought-back item goes to the first empty slot and is never merged;
- some items are never booked for buy back.

## Findings, most severe first

### F1. DEPARTURE: the buy-back messages 0x0118–0x011B have retail equivalents

- **Where:** `server/internal/session/buyback.go:17-23` and `client/scripts/net/shop.gd:183-186`.
- **Evidence (READ):**
  - The client's buy-back confirm (`c:0x6b4610`, mode 6, purpose 0x14) calls `c:0x78ff90`. That
    function sends **0x7168** with a `u32`, the selected NPC's unique id (`c:0x778b80`), and a
    `u8 ReStoreIndex`. **No count is sent.**
  - The GameServer handles it at `gs:0x5118a0`:
    - `gs:0x511860` requires a live NPC interaction (`HasAvailableInteraction`); without one it
      answers 3;
    - `GObjPC::0x42aae0` then does the buy back.
    - **0xB168** (`u8 2`, `u16 code`, through `Msg_SendTwoFieldReply`) goes out **only on
      failure**.
  - On success the item arrives in an 0xB034 move record of **type 0x22** (`gs:0x42aae0` sets the record's type to 0x22,
      the book index at +0x10, the slot at +4, the count at +6).
      - The client's 0xB034 parser (`c:0x87f370` → `c:0x87eb50`, case `'"'`) reads, in order:
        - `u8` destination (+4);
        - `u8` book index (+0x10);
        - `u16` count (+6).
      - It then erases the list entry at that index (`c:0x784fe0`).
    - The list is **client-side**. On every 0xB034 type-9 (sell) result, `c:0x87f370` calls
      `c:0x78d900` with the result's trailing `u8` (+0x10) and the sold item and count. Unless
      that byte is 0xFF, `c:0x78d900`:
      - drops the front (oldest) entry when 5 are held (`4 < size`);
      - appends the sold item at the back.

      The server's sell (`gs:0x6194e0`) writes that byte as the return of `GObjPC::0x42af00`:
      the book's new size (1..5), or 0xFF when the item is not booked.
- **Fix:** if OpenSRO keeps its own shop protocol, record this as a DEPARTURE in `npc_gui.md` and
  `r728.md`, with the layouts below. To match retail, drop 0x0118/0x0119 (there is no list
  request) and carry the book byte on the sell result. Replace 0x011A/0x011B with 0x7168 and
  0xB168, plus the type-0x22 move result. See the table at the end.

### F2. BUG: the deposit fee has no 10,000,000 cap, which matters for 30 real items

- **Where:** `server/internal/storage/storage.go:117-128` (`DepositFee`).
- **Evidence (READ):** the server's deposit is move type 2, `gs:0x524160`, from the type table
  filled at `gs:0x50ce9f`: `mov ds:0xcd3b68` = 0x524160 for type 2.
  - It sets the count to the **whole stack** (vfunc +0x4e8 written to the request's +6).
  - It charges `unit (gs:0x523650, ref +0xac) × stack`, clamped:
    - 0 or less becomes **1**;
    - **10,000,000 or more becomes 10,000,000** (`uVar6 = 10000000` at `gs:0x524300`).
  - It refuses with **0x180f** when the purse is short.
  - It moves the item (`gs:0x523f70`), and only on success takes the gold, reason 0x21.
- **Measured:** over every itemdata row with Service 1 (`/var/tmp/idparts/itemdata_*.txt`),
  **30 items** have KeepingFee × MaxStack ≥ 10,000,000. The largest is
  `ITEM_ETC_ARCHEMY_ATTRSTONE_ER_11`: fee 2,500 × stack 10,000 = 25,000,000. Ours charges
  25,000,000; retail charges 10,000,000.
- **Fix:** `fee = min(max(1, keepingFee × count), 10_000_000)`, with a test at the cap.

### F3. WRONG-LABEL: "the server charges exactly what the box shows"

- **Where:** `r728.md:99`, `storage.go:111-116`, `npc_gui.md:311`, `message_box.md:134`.
- **Evidence:**
  - The client's purpose-5 price (`c:0x63d340`, case 5) is `max(1, +0x868)` with no cap.
  - The server caps at 10,000,000 (F2).
  - The server also prices the **whole stack**, whatever count the box held. Retail's type-2
    request carries no count at all; see F7.

  So above the cap the original's box shows more than it charges.
- **Fix:** relabel as READ, server side, with the clamp and the whole-stack rule. Upgrade the
  KeepingFee column from INFERRED to READ (F11).

### F4. DEPARTURE: a bought-back item is merged instead of going to the first empty slot

- **Where:** `server/internal/shop/buyback.go:114` (`AddItemInstance` merges into a matching
  stack). The live table confirms it: "bag 0 x5000" after buying back 250.
- **Evidence (READ):** `gs:0x42aae0` does the following:
  - `CGStorage::FindFirstEmptySlot(0xd)`; with none it refuses with **0x1807**
    (`UIIT_MSG_STRGERR_INVENTORY_FULL`), before any gold moves;
  - it builds a new item;
  - `CGStorage::SetItem(thatSlot, item)`. It never merges.
- **Fix:** put the instance in the first empty bag slot as a separate stack, and refuse with the
  inventory-full reason when there is none. This closes the lane's OPEN 7.

### F5. DEPARTURE: every sale is booked, but retail never books some items

- **Where:** `server/internal/shop/shop.go:211`, and the comment at `shop/buyback.go:29-31` (OPEN 1).
- **Evidence (READ):** `gs:0x6194e0` books a sale only when both of these hold:
  - `FUN_00492690()` is 0. That is the item instance's `+0xd4 → +0x20`, meaning not read.
  - The item's TID is **not** in the static set `gs:0x61b820`. `RefObjItem::ExtractData`
    (`gs:0x6a3d50`) fills that set through `ReferenceData::0x6b2950`, which puts in every item
    that is any of:
    - TypeID 3/3/8 (type word `(w & 0x780) == 0x400` with expendable 3/3), unless bionic;
    - any 3/2/x (`(w & 0x60) == 0x40`);
    - 3/1/13 (`gs:0x488e40`);
    - a CodeName starting `ITEM_QNO`, `ITEM_QTUTORIAL`, `ITEM_QSP`, `ITEM_QCX`, `ITEM_ETC_E`,
      `SN_ITEM_EVENT`, or equal to `SN_ITEM_ETC_TAIWAN_50000_GOLD`.

  Items in the set are sold but not booked; the result byte is 0xFF.
- **Fix:** skip `recordSold` for that set (the rule above). The client's Ctrl+sell warning
  `UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL` can use the same rule. The client side of OPEN 1,
  `c:0x67b3d0`, was not compared.

### F6. WRONG-LABEL: "retail keeps the book in the DB"

- **Where:** `shop/buyback.go:24-26`, `r728.md:79` and `:143` (OPEN 2).
- **Evidence (READ):**
  - The book is a vector of 0xE8-byte entries on the PC object, appended by `gs:0x42af00` and read
    by `gs:0x42aae0`.
  - It is written to and read from a message stream only by `CGObjPC` vslot 292/291
    (`gs:0x4e6040` → `gs:0x42a9f0`, `gs:0x4e6130` → `gs:0x42aa80`), which cap it at 5 there as
    well.
  - `AQ_StorageUpdater::RestoreSoldItem` (`gs:0x45bb60`, the `_STRG_RESTORE_SOLDITEM_*`
    procedures) is called from `AddLinkedStorageItem` inside the **buy back** (`gs:0x42aae0`). It
    writes the restored item's row; it does not store the book.
  - Whether the vslot 291/292 stream crosses a logout was not read.
- **Fix:** relabel. "In memory on the PC, serialized by vslot 291/292; no DB table for the book".
  Ours, in memory per character, is then the closest match. That it survives a relog is OURS.

### F7. MINOR: the deposit takes a partial count; retail always moves the whole stack

- **Evidence (READ):**
  - `c:0x7950b0`, case 0x46 → 0x13, never sets the count field.
  - The serializer's type 2 (`c:0x7923a0`) writes only `u8 src`, `u8 dst` and `u32 NPC id`.
  - `gs:0x524160` overwrites the count with the stack.
- This predates round 728, but the fee now depends on it.
- **Fix:** deposit and price the whole stack, or record the departure.

### F8. LAYOUT: the split box's edit is about 11–15 px too wide

- **Measured** (`split_z4uFWIL.png` against the lane's `run2/03_split_typed.png`, the edit
  border's columns relative to the window's left frame):

  | | left | right | height |
  |---|---|---|---|
  | original | +223 | +261 | 20 |
  | ours | +222 | +275 | 20 |

- **The authored rect:** `GDR_MBDC_STATIC_DIVIDE_AMOUNT_EDIT` is `Rect=223,102,42,24`
  (`resinfo\ifmessagebox.txt:137`). So ours is about 53 px wide against 42 authored.
- **Likely cause** (not proven): Godot's LineEdit minimum width, which is its theme's
  `minimum_character_width`. The left edge, the height and the 300x183 window agree.
- **Fix:** hold the LineEdit to its authored width. For example, set
  `add_theme_constant_override("minimum_character_width", 0)` and `custom_minimum_size = rect.size`.

### F9. MINOR: split edge rules differ from the server's

- **Where:** `session/inventorymove.go:95`, `:125-136`.
- **Evidence (READ):** `gs:0x4b2450` handles bag to bag:
  - count < 1 → **0x1829**;
  - an empty source → 0x1809;
  - into an empty slot: a count equal to the stack moves it; **a count above the stack → 0x1814**;
    a smaller count → `CGStorage::SplitItemTo`;
  - onto an occupied slot it merges or swaps.

  Ours turns a count at or above the stack into a whole-stack `MoveItem`.
- **Fix:** refuse a count above the stack.

### F10. MINOR: buy-back refusals map to the wrong message, and there is no NPC gate

- **Where:** `client/scripts/ui/hud/hud_panels.gd:2474-2477`.
- **Evidence (READ):** `gs:0x42aae0` refuses with:
  - **0x18d3** for an index past the book (`UIIT_MSG_ERROR_RE_BUY_OBJECT_CANT`);
  - **0x180f** when gold is short;
  - **0x1807** when the bag is full;
  - 0x1842 when the item cannot be created;
  - 0x1811 when the DB post fails.

  Ours shows `RE_BUY_OBJECT_CANT` for a full bag.
- Retail also requires the NPC interaction (`gs:0x511860`). Ours, like OpenSRO's sell, checks
  nothing.
- **Fix:** add a full-bag reason that maps to `UIIT_MSG_STRGERR_INVENTORY_FULL`. The NPC gate is
  for whenever sell gets one.

### F11. WRONG-LABEL, upgrade: the facts the round marks INFERRED that are READ

- **KeepingFee is column 30. READ, on the server.** `RefObjCommon_ExtractData` (`gs:0x6a3090`)
  reads the six i32 after the Can* flags, columns 26..31, into these fields:

  | column | field | offset |
  |---|---|---|
  | 26 | Price | +0x9c |
  | 27 | CostRepair | +0xa4 |
  | 28 | CostRevive | +0xa8 |
  | 29 | CostBorrow | +0xa0 |
  | 30 | KeepingFee | **+0xac** |
  | 31 | SellPrice | **+0xb0** |

  Two cross-checks:
  - `item_requirements.md` has columns 32..39 at +0xb4/+0xb8;
  - the sell's buy-back floor uses +0xb0, the SellPrice.

  The deposit's unit fee is `gs:0x523650` → ref **+0xac**. The client's +0xcc was not
  separately mapped.
- **Buy-back order, newest at the left. READ.** `c:0x6d4360` walks the client's list with a
  reverse iterator (each step goes through the node's `_Prev`, starting from the head sentinel).
  It fills slots 0..4 from the back of the list, the newest first. The server's and the client's
  0-based index counts from the **oldest** (`gs:0x42af00` erases `begin()`).
- **The row's count gate. READ.** `c:0x680da0` lists kind **0x45**, the buy-back row, with the
  bag kinds under the same expendable test.
- **"The owner checks the flag". READ.** The split OK handler `c:0x6b62d0` sends only
  `if (param_3 == 1)`.
- **The buy-back price. READ.** The book stores `max(gold actually paid, SellPrice × count)`
  (`gs:0x6194e0`: `uVar7 = max(local_74, ref+0xb0 × count)` passed to `0x42af00`). With no tax
  that equals the lane's sell price × count.
- **The count fixed at the entry's.** That is retail's rule, not OURS: 0x7168 carries no count,
  and the server restores the stored item whole.

### F12. MINOR: `table_parity` does not compare the new column

- **Where:** `client/tools/table_parity.gd:367-371`.
- **Evidence:** `_canon_items` lists no `keeping_fee`. A native/GD disagreement on the column
  would pass the parity tool. The lane did not run the tool in this round.
- **Fix:** add `it.keeping_fee` to the canon list and run `table_parity` once.

### F13. MINOR: deploy notes missing for production

- **Where:** `deploy/README.md` (unchanged).
- **Evidence:** every earlier refdata column (rounds 607, 616, 632, 654, 659) has a "ROUND N
  NEEDS ..." entry; round 728 has none. Until production is re-imported, `keeping_fee` is 0 and
  every deposit costs **1 gold**. Before this round deposits were free, so that is a visible
  behaviour change.
- **What production needs:**
  1. Re-run `export-refdata -mode items` with the new binary; `items.csv` grows to **73 columns**,
     the new column 72 being KeepingFee.
  2. Run the new `import-refdata`. Its schema adds `items.keeping_fee BIGINT NOT NULL DEFAULT 0`.
  3. Restart the server.
  4. Check: `SELECT keeping_fee FROM items WHERE id = 8;` answers **11**
     (`ITEM_ETC_HP_POTION_05`, measured in the archive).
- **The client:** the release build compiles the native library, so it carries `keeping_fees`. An
  older library shows a fee of 1 while the server charges the real one.

## Verified (no finding)

- **The count label (READ and measured).**
  - The digit images, the `x0 - 2 + 4n` / pitch 5 / `y0 + 2` placement, and the 8x8 quads.
  - An ASCII dump of `qty_Pp886X3.png` rows 290-309 against the lane's `09_deposit_box.png` rows
    230-249: "5000" starts 2 px left of the icon frame and 1 px below its top row in both, with
    identical glyph rows.
- **The slot-clip change.** Every `_build_slot` child is FULL_RECT and the count writers all go
  through `_shows_count`. The quick-slot bar builds its own Label (`hud_underbar.gd:358`) and is
  unaffected. No overflow was found in the skill badge or the HWAN slots.
- **The split gesture.** `c:0x6818d0`: `push 0x10` (VK_SHIFT) / `GetKeyState` / `jns`, kind 0x46,
  then `0x6b3fa0`. Its rules:
  - stackable (`0x538410`) with a count of 2 or more;
  - the edit holds "1", no minimum, a maximum of the stack - 1;
  - OK goes to the first empty bag slot (`c:0x6b6280`), and nothing is sent without one;
  - no split from storage (bag kind only).
- **The bag split, server side.** It needs an empty destination and `0 < n < stack`, and keeps the
  instance. The SQL version is one transaction. Production uses `SQLStore`, which implements
  `Splitter`.
- **The 5-entry cap.** `gs:0x42af00` (`== 5` → erase the front) and `c:0x78d900` (`4 < size`).
- **The codecs.** The older 3-field `InventoryMoveRequest` still decodes.
- **The opcodes.** 0x0118–0x011B collide with nothing else in the tree.

## The retail layouts (READ)

`bag` slots on the wire are bag index + 13.

| Action | Request | Result |
|---|---|---|
| Split a stack | **0x7034**: `u8 0`, `u8 src bag+13`, `u8 dst (first empty) bag+13`, `u16 count` (`c:0x7923a0` case 0, called with 0 so no trailing list) | **0xB034**: `u8 1`, `u8 0`, `u8 src`, `u8 dst`, `u16 count`, then `u8 n` and n × (`u8`,`u8`,`u8`,`u16`) (`c:0x87eb50` case 0). Failure `u8 2`, `u16` (0x1829, 0x1814, 0x1809) |
| Sell (the book's source) | **0x7034**: `u8 9`, `u8 src bag+13`, `u16 count`, `u32 NPC id` | **0xB034**: `u8 1`, `u8 9`, `u8 src`, `u16 count`, `u32 NPC id`, **`u8 book size after the sale (1..5) or 0xFF = not booked`** |
| Buy-back list | **none**: the client keeps it from the sell results above (back = newest, at most 5) | — |
| Buy back | **0x7168**: `u32 NPC unique id`, `u8 index` (0 = oldest) | Success: **0xB034** `u8 1`, `u8 0x22`, `u8 dst bag+13`, `u8 index`, `u16 count`. Failure only: **0xB168** `u8 2`, `u16 code` (0x18d3, 0x180f, 0x1807, 0x1842, 0x1811) |
| Deposit | **0x7034**: `u8 2`, `u8 src bag+13`, `u8 dst warehouse slot`, `u32 NPC id` (no count) | 0xB034 `u8 1`, `u8 2`, …; failure 0x180f (gold), 3, 5, 0x1809, 0x1843 |

A `0x7034` of type 0x22 is refused by `StorageOperation` (`gs:0x50f5c0`, 0x1811). Type 0x22 is a
result only.

## Tests run by the reviewer

- `go build ./... && go test -count=1 -p 1 ./...` (server): PASS (66 packages ok, exit 0).
- `remote_godot.sh tests` (`RENDER_DIR=/opt/opensro-client-r728rev`,
  `GODOT_LOCK=/var/tmp/r728rev/lock`): **NOT COMPLETED**. It was run twice, and both times
  another lane's `qa_shot.sh` run (r729, `/var/tmp/r729/dist.sh`) killed the headless suites
  (`Killed` from `run_suites.sh`) and the ssh exited 255 with no summary. No suite reported a FAIL.
  The lane's own run (237 suites, 0 failing) stands unconfirmed by this review.
- `remote_godot.sh check`: 619 scripts and 9 scenes, ALL LOAD.
- Not run: `cargo test` (no toolchain here), `table_parity` (F12), `perf_gate` (no world drawing
  changed).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
