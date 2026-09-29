# CIFMessageBox: retail's store, warehouse and confirm boxes

Round 631 read this from the client dump (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm`)
and from Media.pk2's `resinfo` layouts. It is the plan for replacing this client's own boxes;
see `docs/TODO.md`, "Store and warehouse confirm boxes". Everything here is **READ** unless it
says otherwise.

## The class

- **The window.** `CIFMessageBox::Create` (0x63e380) loads `resinfo\ifmessagebox.txt`. The frame
  is `interface\messagebox\msgbox2_window_`.
- **Show and hide.** ShowWindow is `vslot_023` (0x63b630). This client's box sounds already
  follow it (`SOUND_FORMAT.md`).
- **Layout mode** (byte +0x7cc, set by 0x643c20). It chooses which section of the file is built:

  | Mode | Section | Mode | Section |
  |---|---|---|---|
  | 1 | MsgBoxINIF | 7 | MsgBoxInsertCouponNumber |
  | 2 | MsgBoxStore | 8 | MentorMatchRegister |
  | 3 | MsgBoxStoreMoney | 9 | MsgBoxSimple |
  | 4 | MsgBoxInsertMsg | 10 | TaxModify |
  | 5 | MsgBoxDivideCount | 11 | TaxLevy |
  | 6 | MsgBoxStoreConfirm | 12, 13 | MakeItem |

- **Purpose** (set by 0x63ea80, jump table 0x63ff38). It sets the title and the buttons:

  | Purpose | Title or caption | OK | Other |
  |---|---|---|---|
  | 1 | `UIIT_STT_CONFIRM_BOX` | Buy | |
  | 2 | `UIIT_STT_CONFIRM_BOX` | Sell | |
  | 0x14 | | Buy back | |
  | 5 / 0x10 | | `UIIT_STT_DEPOSIT` "Deposit" | |
  | 6 / 0x11 | | `UIIT_STT_WITHDRAW` "Take" | |
  | 3 / 0x12 | `UIIT_STT_DEPOSITMONEY` | Deposit | moneyicon |
  | 4 / 0x13 | `UIIT_STT_WITHDRAWMONEY` | Take | moneyicon |
  | 7 | | Confirm | |
  | 8 / 9 | | | `mini_gold_icon`, "Amount": exchange gold / drop gold |

- **The owner.** The inventory creates the box at inventory+0x390, 308x148 (`FUN_006af530`).
- **OK.** `FUN_006b4627` handles OK. It reads the count, or the 64-bit gold, at box+0x8b8. Then it
  calls `FUN_007950b0(src, slot, dst, …, count)` for an item or `FUN_00825f50(src, dst, amount)`
  for gold.
- **Window ids** (`ginterface.txt`):

  | Id | Window |
  |---|---|
  | 0x0f | store |
  | 0x13 | storage |
  | 0x91 | guild storage |
  | 0x46 | inventory |
  | 0x1a | exchange |

## Which box each action opens

| Action | Retail path | Box |
|---|---|---|
| Buy (drag a good onto the bag) | `CIFInventory::vslot_028` 0x6b5b80 → 0x6b2570 → 0x6b24c0(1) | `ifinventory.txt` "ConfirmBuy" = `CItemMallConfirmBuy`, ID 400, rect 95,111,327,155. Its OK (0x7c4880) sends 0x0f→0x46. |
| Buy (Ctrl+click a store slot) | `CIFSlotWithHelp::vslot_029` 0x680fa0 (and the ForPackage one, 0x68a6c0) | No box. The count is the item's max stack, or 1. |
| Sell (drag a bag item onto the store) | `CIFStore::vslot_028` 0x6d1400 → 0x6b07d0 | Mode 6, purpose 2. A stack's count is prefilled with the stack size. |
| Sell (Ctrl+click) | | No box. An item that cannot be bought back gets `GInterface::0x788270` with `UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL`. |
| Deposit an item | `CIFStorageRoom::vslot_028` 0x6cd350 → 0x6b0e90 | Mode 6, purpose 5 (0x10 for the guild). The price field shows a fee; the `price*n/2` rule is INFERRED. |
| Withdraw an item | `CIFInventory::vslot_028` → 0x6b15b0 | Mode 6, purpose 6 (0x11 for the guild). |
| Deposit gold | 0x6b2800 | Mode 3, purpose 3 |
| Withdraw gold | 0x6b29f0, reached from 0x6cc050 | Mode 3, purpose 4 |
| Split a stack (Shift+click) | 0x6b3fa0, from 0x681903 | Mode 5, MsgBoxDivideCount |
| A generic question | `GInterface::0x788270` | Mode 9, MsgBoxSimple, 280x144. The style byte +0x908 picks the buttons: 0 Confirm, 1 Yes/No, 2 Cancel. |

## Layouts, from `resinfo\ifmessagebox.txt`

Rects are x,y,w,h.

**MsgBoxStoreConfirm**, used by sell, deposit and withdraw:

| Id | Control | Rect | Notes |
|---|---|---|---|
| 70 | background | 16,40,295,106 | `com_bg_tile_b` |
| 72 / 73 | item window / icon | 21,48,48,48 / 28,55,32,32 | |
| 79 | name edit | 86,53,209,14 | |
| 78 | "Quantity" | 198,80,33,14 | |
| 80 | count edit | 237,80,36,12 | box+0x888 |
| 81 / 82 | spin up / down | 278,74,22,12 / 278,85 | `server_up.ddj` / `server_down.ddj` |
| 86 | "Price" | 50,100 | |
| 85 | price edit | 112,102,104,17 | box+0x880 |
| 87 | "Gold" | 222,100 | |
| 83 | OK | 82,135 | box+0x800 |
| 84 | Cancel | 170,135 | box+0x804 |

**MsgBoxStoreMoney**, used for gold:

| Id | Control | Rect | Notes |
|---|---|---|---|
| 10 / 12 | icon window / icon | 18,44,48,48 / 25,51,32,32 | |
| 1 | NAME1 | 73,44,212,48 | `msgbox_iteminfo.ddj` |
| 9 | NAME2 | | `msgbox_iteminfo_2.ddj` |
| 2 | price static | | |
| 3 | amount edit | 20,102,42,20 | `msgbox_quantity.ddj` |
| 4 | "Unit" | | |
| 8 | "Price" | | |
| 11 | price edit | | |
| 7 | "Gold" | | |
| 215 | OK | 123,101,76,24 | `com_button.ddj` |
| 216 | Cancel | 203,101 | `com_button.ddj` |

The gold purposes change it (0x63ef90..0x63f00a):
- the icon becomes `moneyicon.ddj`;
- NAME1 gets the caption;
- the amount edit loses its texture, moves by (+0x79, +0x42) and becomes 121x24;
- ids 8, 9 and 2 are hidden.

**MsgBoxSimple**:
- text: id 251, a CIFTextBox at 0,52,240,14;
- buttons: id 252 at 72,99,76,24 and id 253 at 152,99,76,24;
- background: `com_bg_tile_b`, 16,40,284,122 (from "Create").

**MsgBoxDivideCount**:
- buttons: OK id 220 (71,143) and Cancel id 221 (151,143);
- divide edit: id 17, 223,102,42,24;
- statics: ids 13-16 ("Seperating the current item.", "Retained number", "Distributed
  number").

**`ifitemmallconfirmbuy.txt`** (CItemMallConfirmBuy):

| Id | Control | Rect |
|---|---|---|
| 5 | title, `UIIT_STT_CONFIRM_BOX` | 84,12,162,14 |
| 10 / 11 | icon window / icon | 21,48,48,48 / 28,55,32,32 |
| 40 | name | 86,53,209,14 |
| 21 | "Quantity" | 198,80 |
| 42 | count edit | 237,80,36,12 |
| 50 / 51 | spins | 278,74 / 278,85 |
| 44 | price | 96,140,179,14 |
| 45 | total | 96,167 |
| 61 | Buy | 104,200 |
| 62 | Cancel | 203,200 |

The silk-mall rows (ids 25, 27, 43, 60) are also there. Whether an NPC store hides them is
**OPEN**.

`resinfo\ifconfirmbox.txt` is **not** a confirm box. It is the global-authentication captcha
(`UIIT_PAG_GLOBAL_AUTHENTICATION`).

## Text, from `textuisystem`

The English column was taken as the first Latin column, not checked against a header.

| Token | Text |
|---|---|
| `UIIT_STT_CONFIRM_BOX` | Confirmation window |
| `UIIT_STT_BUY` | Buy |
| `UIIT_STT_SELL` | Sell |
| `UIIT_CTL_CANCEL` | Cancel |
| `UIIT_CTL_CONFIRM` | Confirm |
| `UIIT_CTL_YES` / `UIIT_CTL_NO` | Yes / No |
| `UIIT_STT_DEPOSIT` | Deposit |
| `UIIT_STT_WITHDRAW` | Take |
| `UIIT_STT_DEPOSITMONEY` | Deposit |
| `UIIT_STT_WITHDRAWMONEY` | Taken |
| `UIIT_STT_AMOUNT` | Quantity |
| `UIIT_STT_GOLD` | Gold |
| `UIIT_STT_UNIT` | Unit |
| `UIIT_STT_AMOUNT_MONEY` | Amount |
| `UIIT_STT_RE_BUY_OBJECT` | Buy back |

## Open

- Which mouse event `vslot_029` is. Only the Ctrl, Shift and Alt checks are read.
- Which store class is live under `RENEWAL_SHOP_SYSTEM`. Both route drops the same way.
- The 64-bit amount fields are only partly traced.
- `0x643e50`'s geometry arguments (0x168, 0x97).
- The MsgBoxStore + purpose 1 path at 0x6b0b10 has no caller found by a byte scan, so it is dead
  in this build. That is INFERRED.
