# CIFMessageBox: retail's store, warehouse and confirm boxes

This is what round 631 and its review read from the client dump (`/var/tmp/decomp_client`,
`/var/tmp/sro_client.asm`) and from Media.pk2's `resinfo` layouts. It is the plan for replacing
this client's own boxes; see `docs/TODO.md`, "Store and warehouse confirm boxes". Everything
here is **READ** unless it is marked otherwise.

## Which `#ifdef` branch is live

- **The branch.** The layouts carry `#ifdef RENEWAL_SHOP_SYSTEM` / `#else` / `#endif` blocks.
  This document describes the **RENEWAL** branch, because that is the one the code uses.
- **Evidence from the code (READ).**
  - The binary loads the RENEWAL-only section MsgBoxStoreConfirm at 0x640300. It also loads
    MsgBoxInsertCouponNumber at 0x643c20; that section is guarded by `PROVIDE_ITEM_BY_COUPON`,
    so it is evidence for the coupon flag, not for RENEWAL.
  - `FUN_006b24c0(1)` loads `ifinventory.txt` "ConfirmBuy", whose only content is RENEWAL-only.
    It then passes `GetControl(400)` straight to `FUN_00ba03a0`, which reads `[this+0x3c]`
    without a null check. Under `#else` that would be a null dereference (INFERRED).
  - The live ConfirmBuy code (0x7c2a00..0x7c6250) fetches only controls 4, 7, 11, 40, 42, 50,
    51, 61, 62 and 400.
  - The one function that fills the `#else`-only controls 44 and 45 is `FUN_007c2a20`. It has no
    caller and no pointer anywhere in the exe, so it is dead code.
- **What is not proved (OPEN).** The resinfo parser (IFTVariable: `FUN_00b350f0`, `0xb37a30`,
  `0xb37610`) asks a hash map at 0xeed4e0 (`FUN_005004a0`) whether a name is defined. Nothing
  found fills that map, and the string "RENEWAL_SHOP_SYSTEM" is not in the exe. So the parser has
  not been shown to take the RENEWAL branch; only the code says it must. The live build being
  RENEWAL is therefore **INFERRED**.
  **Round 724:** the define list is data. `CGame` reads `config\define.txt` from Media.pk2 at
  start-up (`push 0xdd3d60` at `0x848210`), logs "`%s Value 0 => 1`" for each name and sets it
  through `0x6441b0`. That file defines `RENEWAL_SHOP_SYSTEM` and `RESTORE_SOLDITEM_INSHOP`, so the
  renewal branch, buy-back row included, is live (READ). That the parser consults this table is
  INFERRED strongly. See `docs/protocol/npc_gui.md` §0.

## The class

- **The layout file.** `CIFMessageBox::Create` (0x63e380) loads `resinfo\ifmessagebox.txt`. The
  frame is `interface\messagebox\msgbox2_window_`. ShowWindow is `vslot_023` (0x63b630).
- **The layout mode.** A byte at +0x7cc, set by 0x643c20, chooses which section is built:

  | Mode | Section | Mode | Section |
  |---|---|---|---|
  | 1 | MsgBoxINIF | 7 | MsgBoxInsertCouponNumber |
  | 2 | MsgBoxStore | 8 | MentorMatchRegister |
  | 3 | MsgBoxStoreMoney | 9 | MsgBoxSimple |
  | 4 | MsgBoxInsertMsg | 10 | MsgBoxTaxModify |
  | 5 | MsgBoxDivideCount | 11 | MsgBoxTaxLevy |
  | 6 | MsgBoxStoreConfirm | 12 / 13 | MsgBoxMakeItem / MsgBoxMakeItemCancel |

- **The purpose.** Set by 0x63ea80 (jump table 0x63ff38). It writes the **title** with SetText on
  the box itself (slot 0xb4), plus the button labels and captions.
  - The title is `UIIT_STT_CONFIRM_BOX` ("Confirmation window") for purposes 1-10, 14 and
    16-20.
  - Other purposes have their own titles: 11 `UIIT_STT_AGREEMENT_BOX`, 12
    `UIIT_STT_SILKMALL_BUY_CONFIRM`, 13 `UIIT_STT_SILKMALL_DO_ZZIM`, 15
    `UIIT_STT_SILKMALL_ZZIM_LUMP_BUY`, 21 `UIIT_STT_SILKMALL_PUT_ON_CLOSE_BUY`.

  Store and storage purposes:

  | Purpose | OK (+0x800) | Other |
  |---|---|---|
  | 1 | Buy | |
  | 2 | `UIIT_STT_SELL` "Sell" | |
  | 0x14 | "Buy back" | |
  | 5 / 0x10 | `UIIT_STT_DEPOSIT` "Deposit" | |
  | 6 / 0x11 | `UIIT_STT_WITHDRAW` "Take" | |
  | 3 / 0x12 (18) | "Deposit" | icon `interface\icon\moneyicon.ddj` on +0x814 (control 12); **NAME1** (+0x818, control 1, `FUN_0063e940`) captioned `UIIT_STT_DEPOSITMONEY` "Deposit" |
  | 4 / 0x13 (19) | "Take" | icon `moneyicon.ddj`; NAME1 captioned `UIIT_STT_WITHDRAWMONEY` "Taken" |
  | 7 | "Confirm" | |
  | 8 | `UIIT_CTL_CONFIRM` | icon `interface\minipopup\mini_gold_icon.ddj`, `UIIT_STT_AMOUNT_MONEY` "Amount" on +0x818, Cancel `UIIT_CTL_CANCEL` |
  | 9 | as 8 | as 8, without the Cancel label |

  - **Purpose 8 is exchange gold: INFERRED.** It is called from 0x6b2c30, which is reached by a
    jmp at 0x7b251d right after `CIFExchange::FUN_007b24d0`.
  - **Purpose 9 is drop gold: INFERRED.** It is called from 0x6b2620, reached from the inventory
    at 0x6b2e74 when the checks `0x799300` and `0x799320` are both false. Otherwise that path
    opens deposit money (0x6b2800).
- **The owner.** The inventory creates the box at inventory+0x390, 308x148 (`FUN_006af530`).
- **The owner's handler.** `FUN_006b4627` reads the count, or the 64-bit gold, at box+0x8b8. It
  sends an item move with `FUN_007950b0(src, slot, dst, …, count)` and a gold move with
  `FUN_00825f50(src, dst, amount)`.
- **Window ids** (`ginterface.txt`):

  | Id | Window |
  |---|---|
  | 0x0f | store |
  | 0x13 | storage |
  | 0x91 | guild storage |
  | 0x46 | inventory |
  | 0x1a | exchange |

## The box closes itself on OK and on Cancel

The box's message map is at `.rdata 0xd9b174`. Entries run from 0xeb5e48 and are 0x28 bytes
each; the ids are at +8/+0xc and the handler at +0x18. Every button below posts to its owner,
then calls its own ShowWindow(0):

| Buttons | Section | Handlers | Message |
|---|---|---|---|
| 215 / 216 | StoreMoney, Store | 0x63d7f0 / 0x63bc50 | 0x8074 |
| 83 / 84 | StoreConfirm | 0x63dcc0 / 0x63bfd0 | 0x8074 |
| 220 / 221 | DivideCount | 0x63d920 / 0x63be60 | 0x8076 |
| 252 / 253 | Simple | 0x644510 / 0x63bee0 | 0x8077 |

The DivideCount OK (220) reads the count before it hides.

So retail's gold box moves the amount **once** and is gone. That is why this client's gold
dialog now closes on Deposit and Withdraw (round 631 review).

## What retail does when the store or the warehouse closes: OPEN

No evidence was found that retail closes an open box when its window closes:
- The hide branch of `CIFStore::vslot_023` (0x6cff20) only zeroes +0x7c8 and calls 0x777e70,
  which resets the cursor.
- CIFStorageRoom, CIFInventory and CItemMallConfirmBuy have no ShowWindow override; slot 23 is
  the shared 0x652b70.
- A whole-asm scan for `[reg+0x390]` followed by a slot-0x5c call found nothing in store,
  storage or NPC code.
- ConfirmBuy is torn down only by `FUN_006b24c0(0)`, whose sole caller is the GInterface-wide
  reset `FUN_00787860`. That reset is reached from 0x788180 and 0x86dab0, whose triggers were not
  traced.

Two things were not read: the NPC-talk close path, and whether hiding a parent window hides the
box as a child. This client closes a window's boxes when the window closes. That behaviour is
**OURS**, chosen because a box left open acted on a stale bag slot (round 631 review).

## Which box each action opens

| Action | Retail path | Box |
|---|---|---|
| Buy, by dragging a good onto the bag | `CIFInventory::vslot_028` 0x6b5b80 → 0x6b2570 → 0x6b24c0(1) | `ifinventory.txt` "ConfirmBuy" = `CItemMallConfirmBuy`, ID 400, 95,111,327,155, frame msgbox2_window_. Its OK (0x7c4880) sends 0x0f→0x46. |
| Buy, by Ctrl+click on a store slot | `CIFSlotWithHelp::vslot_029` 0x680fa0 (store source 0xf → the bag, 0x6816a0..0x6816d6, with the specialty refusal `UIIT_MSG_COS_CANNOT_BUY_SPECIALTY_TO_INVENTORY`); ForPackage: 0x68a6c0 (`GetKeyState(VK_CONTROL)`, the store open, target the bag 0x46) | No box. The count is the item's max stack (ref +0x1c0), or 1. Both slot classes buy on Ctrl+click: round 631's row was right (round 726 review). |
| Sell, by dragging a bag item onto the store | `CIFStore::vslot_028` 0x6d1400 → 0x6b07d0 | Mode 6, purpose 2. A stack is prefilled with its size. |
| Sell, by Ctrl+click on a bag slot | `CIFSlotWithHelp::vslot_029` 0x680fa0, its bag branch: Ctrl, the store open, source the bag (0x46) | No box; the stack when `0x538410(ref)` holds, else 1 (0x6815e0..0x681608). **Refused** with `UIIT_MSG_STRGERR_CANT_QUICKSELL_CASHITEM` (0xda4060, through 0x7781b0) when `0x5dd660(ref)` holds -- not bionic, TypeID1 3, the CashItem bit (0x6813f3..0x681417) -- or ref +0xa0 is 2 or 6 (0x8ba600; that column is not mapped, OPEN). An item that passes both and cannot be bought back first gets `GInterface::0x788270` with `UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL`. |
| Deposit an item | `CIFStorageRoom::vslot_028` 0x6cd350 → 0x6b0e90 | Mode 6, purpose 5 (0x10 for the guild). The fill writes the item's reference +0xcc times max(1, count) through 0x64db50 with its grouping argument 0 (0x6b100c), so plain digits; `CIFMessageBox::vslot_012` (0x63d340) then rewrites it for purpose 5 as **max(1, fee)** (0x63d676..0x63d698). Which itemdata column +0xcc is, is not mapped. A non-stacking item hides the quantity group (`0x63bc80(3)`). |
| Withdraw an item, the fill | 0x6b15b0 | The price edit is "%d" of 0. |
| Withdraw an item | `CIFInventory::vslot_028` → 0x6b15b0 | Mode 6, purpose 6 (0x11 for the guild). |
| Deposit gold | 0x6b2800 | Mode 3, purpose 3 |
| Withdraw gold | 0x6b29f0, from 0x6cc050 | Mode 3, purpose 4 |
| Split a stack, by Shift+click | 0x6b3fa0, from 0x681903 | Mode 5, MsgBoxDivideCount |
| A generic question | `GInterface::0x788270` | Mode 9, MsgBoxSimple (below) |

## Layouts for the RENEWAL branch

Rects are x,y,w,h.

### MsgBoxStoreConfirm: sell, deposit, withdraw

`ifmessagebox.txt` lines 1141-1509. The section exists only under RENEWAL and has no `#else`.

**What each purpose does to it** (READ round 726, 0x63ea80, jump table 0x63ff38 indexed by
purpose - 1: 2 → 0x63eb8f, 5 / 0x10 → 0x63ed1f, 6 / 0x11 → 0x63edaa, 0x14 → 0x63ec3f):
- every one resizes the box to **327x175** (`push 0xaf; push 0x147`, vslot 21 → 0x652970 SetSize
  and 0x63b420's frame re-layout) and titles it `UIIT_STT_CONFIRM_BOX`;
- OK is `UIIT_STT_SELL` (2), `UIIT_STT_RE_BUY_OBJECT` (0x14), `UIIT_STT_DEPOSIT` (5),
  `UIIT_STT_WITHDRAW` (6); Cancel is `UIIT_CTL_CANCEL` in all four;
- the spins (81 / 82) stay for sell and are hidden for buy back, deposit and withdraw;
- withdraw also hides the price label (86, +0x898) and the name edit (79, +0x818)
  (0x63ee85..0x63ee9f);
- 0x63bc80(2) shows the count edit and its label; (3) hides the group: 80 (+0x888), 78 (+0x88c),
  75 (+0x890) and 77 (+0x894). The deposit and withdraw fills call (3) for an item that does not
  stack; the sell fill does not (round 726 review);
- buy back, deposit and withdraw OR style **0x81** into the count edit (`0x635150(0x81)`: 0x63ed10,
  0x63ed90, 0x63ee1b). In CIFEdit's WM_CHAR (0x637290), 0x01 lets only the digits through and 0x80
  drops Backspace (0x63748c). Deposit's fill also leaves the edit unfocused (`0x635030(0)`); sell
  and withdraw focus it (`0x635030(1)`). Whether a deposit count can be changed is not settled.

**The price edit is rewritten by `CIFMessageBox::vslot_012` (0x63d340)** by purpose: for 1 and 2
through 0x63bd60, `P = ftol(count(+0x8b8) x unit(+0x870)); P - ftol(P x rate(+0xc98))`, the rate set
by the sell fill to the tax line's short / 100.0 when `0x703fc0()` holds (0x6b0871..0x6b0896; the
double at 0xe1b7d8 is 100.0); for 5, max(1, the fee); others keep the fill's text. None is grouped:
0x64db50 groups (0x8c1350) only on a non-zero fourth argument, and these push 0 (0x63d39e, 0x63d6e5).
That vslot 12 runs every frame is INFERRED; the formula is READ (round 726 review).

The sell fill (0x6b07d0) writes the unit price "%I64d" with no grouping into the price edit and,
for a stack (type test `(b&2)==0 && (b&0x1c)==0xc && (b&0x60)==0x60`), shows the count prefilled
with the stack size (FUN_008ba460).

| Id | Control | Rect | Notes |
|---|---|---|---|
| 70 | background | 16,40,295,106 | `com_bg_tile_b` |
| 72 / 73 | item window / icon | 21,48,48,48 / 28,55 | |
| 74, 75 / 76, 77 | blacksquares / tiles | | |
| 79 | name edit | 86,53,209,14 | |
| 78 | quantity label | 198,80,33,14 | `UIIT_STT_AMOUNT` "Quantity" |
| 80 | count edit | 237,80,36,12 | +0x888 |
| 81 / 82 | spin up / down | 278,74 / 278,85 | |
| 86 | price label | 50,100,53,16 | `UIIT_CTL_WARENETWORK_RESULT_PRICE` "Price" |
| 88 / 1 | price-field backing | 112,100,104,17 | blacksquare / tile_e |
| 85 | price edit | 112,102,104,17 | +0x880 |
| 87 | gold label | 222,100,15,16 | `UIIT_STT_GOLD` "Gold" |
| 83 | OK | 82,135 (size 0,0 in the file) | `com_button`, labelled by the purpose; +0x800 |
| 84 | Cancel | 170,135 (size 0,0 in the file) | `com_button`, `UIIS_CTL_CANCEL`; +0x804 |

The mapping of controls to members is at 0x640300.

### ConfirmBuy: `CItemMallConfirmBuy`, `ifitemmallconfirmbuy.txt`

**Present in both branches:**

| Id | Control | Rect |
|---|---|---|
| 5 | title, `UIIT_STT_CONFIRM_BOX` | 84,12,162,14 |
| 10 / 11 | icon window / icon | |
| 12, 17, 70, 75 | | |
| 21 | "Quantity" | |
| 40 | name | |
| 42 | count edit | |
| 50 / 51 | spins | |

**Under RENEWAL:**
- The background (id 4) is 16,40,295,106.
- Buy (61) and Cancel (62) are `0,0,0,0`: the code places them.

**`#else` only, and so not in the live build:**
- 44 / 45: price / total;
- 22-27, 43, 60: the silk-mall rows;
- 14-16 and 72-74.

In the `#else` branch, 61/62 sit at 104,200 / 203,200 and the background is 16,40,295,186.

**How the code lays it out.** `FUN_007c3f70`, called from `CItemMallConfirmBuy::Create` →
0x7c5650 at 0x7c5c68:
1. It reads the window's rect (x, y, w, h) and background 4's rect (via 0xb8f420, +0x40..+0x4c).
2. For each price-type flag that is set (bits 0x1-0x400), it adds one `CIFItemMallConfirmSlot`
   row through `gwnd::FUN_00ba20b0`. A row's rect starts at `{0, 80, 327, 22}`; y moves +20
   before the first row and +22 before each later row. Each row adds 22 (20 for flag 0x4) to
   both the window's and background 4's height.
3. It resizes the window and background 4 with slot 0x54 (SetSize). The row's own controls come
   from `resinfo\ifitemmallconfirmslot.txt` (the string at 0xdc92f8, loaded at 0x7c1f30): a
   label (4) at 50,2,53,16, the edit (3) at 112,2,102,16 and a second label (5) at 222,2,15,16 --
   for the gold row `UIIT_CTL_WARENETWORK_RESULT_PRICE` / "%I64d" of count x unit / `UIIT_STT_GOLD`.
   One gold row makes the store's buy box **327x177** (background 295x128), the row at y 100.
4. It moves **Buy (61, 0x3d) to (X+82, Y+H-40)** and **Cancel (62, 0x3e) to (X+170, Y+H-40)**
   with slot 0x98 (MoveWindow, absolute coordinates; CIFButton vtable 0xd9ec0c → 0x6529a0 →
   0xb90cf0). Asm 0x7c47ef..0x7c4871.

The x offsets 82 and 170 are the same as StoreConfirm's OK and Cancel.

### MsgBoxStoreMoney: gold

Unconditional (no `#ifdef`).

| Id | Control | Rect | Notes |
|---|---|---|---|
| 10 / 12 | icon window / icon | 18,44,48,48 / 25,51,32,32 | |
| 1 | NAME1 | 73,44,212,48 | `msgbox_iteminfo.ddj` |
| 9 | NAME2 | | |
| 2 | price static | | |
| 3 | amount edit | 20,102,42,20 | `msgbox_quantity.ddj` |
| 4 | "Unit" | | |
| 8 | price label | | |
| 11 | price edit | | |
| 7 | gold label | | |
| 215 | OK | 123,101,76,24 | |
| 216 | Cancel | 203,101 | |

For the gold purposes, 0x63ef90..0x63f00a changes the box:
- the icon becomes `moneyicon.ddj` (not in Media.pk2), which both openers then replace with
  `icon\mini_gold_icon.ddj` (deposit 0x6b299c..0x6b29d5, withdraw 0x6b2b68; `push 0xda76f8`);
- NAME1 gets the caption;
- the amount edit loses its texture, moves by (+0x79, +0x42) and is resized to 121x24;
- ids 8, 9 and 2 are hidden.

Both openers (deposit 0x6b2800, withdraw 0x6b29f0) then (READ, round 726 review):
- hide "Unit" (4, +0x88c) right after `0x63bc80(2)` (0x6b28a8..0x6b28b3);
- prefill the amount "0" (`push 0; push "%d"`, 0x6b28c8), enforce no minimum (`0x634ff0(0)`) and a
  maximum (`0x635000(1)`) of min(the carried gold (inventory +0x378/+0x37c) or the stored gold
  (the storage +0x7c0/+0x7c4), 1,000,000,000) (0x6b295b..0x6b298a, 0x6b2bb6..0x6b2bf5,
  `0x634f20`);
- focus the amount (`0x635030(1)`).

### MsgBoxSimple: the generic question

Unconditional.

**In the file:**
- text: id 251, a CIFTextBox at 0,52,240,14;
- OK: id 252 at 72,99,76,24, `UIIT_CTL_YES`;
- Cancel: id 253 at 152,99,76,24, `UIIT_CTL_NO`;
- background: `com_bg_tile_b`, 16,40,284,122 (from "Create").

**In the code (READ).**
1. `GInterface::FUN_00788270` creates the box at `{0,0,0x118,0x90}` (280x144; 0x7882e3).
2. It then calls `FUN_00643e50(0x168, 0x97)`, which resizes the box to **360x151** (SetSize,
   0x643e87..0x643e9a).
3. That function stores the style byte at +0x908 (0x643e94). The style picks the buttons:
   - **0:** OK centred at `x+w/2-38`, `UIIT_CTL_CONFIRM`, Cancel hidden;
   - **1:** OK = `UIIT_CTL_YES` at centre-81, Cancel = `UIIT_CTL_NO` at centre+5;
   - **2:** Cancel centred, `UIIT_CTL_CANCEL`, OK hidden.
4. The text box (+0x90c) goes to `(x+30, y+65)`, size `(w-60, h-122)`.

### MsgBoxDivideCount: splitting a stack

Unconditional.
- OK: id 220 at 71,143;
- Cancel: id 221 at 151,143;
- divide edit: id 17 at 223,102,42,24;
- statics: ids 13-16 ("Seperating the current item.", "Retained number", "Distributed number").

`resinfo\ifconfirmbox.txt` is **not** a confirm box: it is the global-authentication captcha.

### Where the boxes appear (READ, round 726)

- **The inventory's boxes** (sell, buy back, deposit, withdraw, gold) are new each time: every
  open destroys the last (`FUN_006aef20`: 0xba0e40 on +0x390) and creates it again at
  `{0,0,308,148}` (`FUN_006af530`), whose call to `FUN_00798b70` (0x6af59a) moves it to
  `(screenW/2 - 308/2, screenH/2 - 148/2)` -- integer halves; 0x798b70 reads the screen from
  `FUN_004f9cd0` +0x24/+0x28 and the box's (x, y, w, h) from +0x40 (0xb8f420; SetSize 0xb91a40
  writes w, h to +0x48/+0x4c). The purpose's resize keeps that corner, so a 327x175 box sits 9
  right and 13 down of true centre: at 1280x720, (486, 286).
- **ConfirmBuy** centres itself at its final size: `0x7c5650` adds the rows (0x7c3f70 at 0x7c5c63)
  and then calls 0x798b70 (0x7c5d3c). At 1280x720 a one-row box is at (477, 272).
- 3Gw7Ene.png's and MKtR5Kd.png's boxes are elsewhere (a 1353x823 capture puts them at about
  (343, 148) and (388, 426), not the (513, 323) and (522, 337) 0x798b70 gives on that size); the boxes are frames the
  player can move, and a box moved by the player is the likely reason. INFERRED: not measured.
- **Modality: OPEN.** `0x63b5b0` stores the owner at +0x7c0 and registers the box in the global
  window list at 0x110f618 (0xba03a0, undone at destruction by 0xb912c0); what that list does to
  input was not read.

## Text (`textuisystem`)

The English column was taken as the first Latin column, not checked against a header.

| Token | Text |
|---|---|
| `UIIT_STT_CONFIRM_BOX` | Confirmation window |
| `UIIT_STT_SELL` | Sell |
| `UIIT_STT_RE_BUY_OBJECT` | (buy back; text not checked) |
| `UIIT_CTL_CANCEL` / `UIIS_CTL_CANCEL` | Cancel |
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

## Open

- Which mouse event `vslot_029` is. Only the Ctrl, Shift and Alt checks are read.
- Who fills the resinfo define map at 0xeed4e0. The branch above is taken from the code.
- The 64-bit amount fields are only partly traced.
- Which itemdata column the deposit fee's reference +0xcc is (the rule itself is READ above).
- The box's modality (above).
- The triggers of the GInterface-wide reset (0x788180, 0x86dab0).
- The NPC-talk close path.
- The MsgBoxStore + purpose 1 path at 0x6b0b10 has no caller found by a byte scan, so it is
  dead in this build (INFERRED).
