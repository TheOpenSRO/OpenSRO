# Round 726 review: the store and warehouse confirm boxes, the retail gestures

An independent adversarial review of `dev..worktree-agent-a9952b63c56bdc666` (head `3c43c4a0`), lane B of
the NPC GUI epic. Evidence is from `sro_client.exe` (`/var/tmp/sro_client.asm` and
`/var/tmp/decomp_client` on the render box), Media.pk2's `resinfo\ifmessagebox.txt` (RENEWAL branch),
the Media.pk2 listing, and the lane's own run-3 frames and `QA BOX` log (`/var/tmp/r726/live/run3`)
measured against `3Gw7Ene.png` and `MKtR5Kd.png`. No code was changed.

## Findings, most severe first

### 1. DEPARTURE + WRONG-LABEL: the gold boxes have the gold icon, `icon\mini_gold_icon.ddj`
- **Where:** `client/scripts/ui/hud/store_message_box.gd:241-242`; `docs/rounds/r726.md`, "The money icon".
- **Evidence:** the purpose (0x63eedd) does put `interface\icon\moneyicon.ddj` on the icon (+0x814).
  But both openers then replace it:
  - deposit 0x6b2800: 0x6b299c..0x6b29d5, `push 0x17; push 0xda76f8` = `"icon\mini_gold_icon.ddj"`,
    then `0x425ae0` and the icon's +0x84 vslot 0x34 (the same setter the purpose used);
  - withdraw 0x6b29f0 does the same.

  `icon\mini_gold_icon.ddj` **is** in Media.pk2 (`media_list.txt`: 2196 bytes, also under
  `icon\etc\icon\`). The original's gold box therefore shows the gold coin. Ours shows nothing: frame
  12's icon rect (25,51,32,32) has no pixel above luma 60. The lane's claim that "the original's would
  be empty with these archives" reads only the purpose and misses the opener.
- **Fix:** after `_build_store_money`, load `icon\mini_gold_icon.ddj` into `GDR_MBS_STATIC_ICON`.
  Correct the r726 note and `message_box.md`'s gold rows.

### 2. LAYOUT: the gold box shows "Unit", which the original hides
- **Where:** `store_message_box.gd:245-248` (the hidden list).
- **Evidence:**
  - Mode 3's member map is 0x63e940, read as push id, call, and the next `mov [esi+X],eax`:
    12 → +0x814, 215 → +0x800, 216 → +0x804, 1 → +0x818, 9 → +0x87c, 2 → +0x880, 3 → +0x888,
    **4 → +0x88c**, 8 → +0x898, 11 → +0x8ac. This confirms the lane's 8, 9 and 2 for the purpose's
    hides.
  - Both gold openers then call `0x63bc80(2)` (which shows +0x888 and +0x88c) and, right after it,
    hide +0x88c: 0x6b28a8 `mov ecx,[ecx+0x88c]`, 0x6b28b3 `push 0`, vslot 0x5c.
  - ID 4 is `GDR_MBS_STATIC_AMOUNT`, `UIIT_STT_UNIT`, at 64,108.
  - Ours draws it. The lane's log has `QA BOX GoldDialog GDR_MBS_STATIC_AMOUNT at 64,108 ... 'Unit'`,
    and frame 12 has text pixels at box (65..85, 110..118), left of the buttons.
- **Fix:** add `GDR_MBS_STATIC_AMOUNT` to the gold box's hidden list.

### 3. DEPARTURE: the gold amount opens at "0", not 1, with no minimum and a 1,000,000,000 cap
- **Where:** `hud_panels.gd` `_open_gold_box` (`"count": 1, "max": maxi(1, balance)`), and
  `StoreMessageBox.build`/`set_count` (held to 1..max). The lane listed this as OURS / OPEN 7.
- **Evidence (READ, 0x6b2800):**
  - The prefill is 0x6b28c8 `push 0x0; push 0xe18b1c` (`"%d"`), `swprintf`, then the edit's SetText
    (vslot 0xb4): the amount opens at **0**.
  - The minimum is not enforced: `0x634ff0(0)` sets edit +0x418 = 0.
  - The maximum is enforced: `0x635000(1)` sets +0x419.
  - The deposit's maximum is `min(carried gold (inventory +0x378/+0x37c), 0x3b9aca00)`
    (0x6b295b..0x6b298a, then `0x634f20`).
  - 0x6b29f0 has the same prefill sequence.
- **Fix:** open at 0, let 0 stand in the edit (the send already refuses amounts of 0 or less), and cap
  the deposit at min(carried, 1,000,000,000). Move the item from OURS to READ.

### 4. DEPARTURE: deposit and withdraw hide the quantity group for an item that does not stack
- **Where:** `store_message_box.gd` `_build_store_confirm` (the count group is always shown);
  `hud_panels.gd` `_confirm_deposit` / `_confirm_withdraw`.
- **Evidence:**
  - The deposit fill 0x6b0e90 runs the stack test `(b&2)==0 && (b&0x1c)==0xc && (b&0x60)==0x60`. A
    stack gets `0x63bc80(2)`; otherwise it gets `0x8ba490(1)` and **`0x63bc80(3)`**.
  - The withdraw fill 0x6b15b0 has the same branch.
  - `0x63bc80(3)` hides +0x888 (80, the count edit), +0x88c (78, "Quantity"), +0x890 (75, its black
    square) and +0x894 (77, its tile). The map is 0x640300, re-read this review: 73 → +0x814,
    83 → +0x800, 84 → +0x804, 79 → +0x818, 85 → +0x880, 80 → +0x888, 78 → +0x88c, 75 → +0x890,
    77 → +0x894, 86 → +0x898.
  - Ours shows "Quantity 1" for a single weapon. The lane's own test (`store_message_box_test.gd:102`,
    a 1-of-1 "Premium Silver Time") does not check this.
  - The sell fill 0x6b07d0 does **not** call `0x63bc80(3)` in its else-branch, so a non-stacking sell
    keeps the group. That part is right.
- **Fix:** pass `stackable` and, for DEPOSIT/WITHDRAW when it is false, hide
  `GDR_MBS_CONFIRM_EDIT_COUNT`, `GDR_MBS_CONFIRM_STA_COUNT`, `GDR_MBS_CONFIRM_BUY_BLACKSQUARE_6` and
  `GDR_MBS_CONFIRM_EDIT_BG6`. Add a test.

### 5. DEPARTURE: the original has one inventory box at a time; ours can stack several
- **Where:** `hud_panels.gd` `_open_store_box`, which replaces only a box of the same name on the same
  host.
- **Evidence:**
  - Every inventory box is `CIFInventory` +0x390.
  - `0x6af530` begins with `0x6aef20`, which destroys the one there (`0xba0e40`).
  - The sell, deposit and withdraw fills and both gold openers all call it.
  - Ours keeps "DepositConfirm", "WithdrawConfirm" and "GoldDialog" as separate children of the
    warehouse. A deposit box and a gold box can both be open; so can a sell box on the store and a
    gold box on the warehouse.
  - `CItemMallConfirmBuy` is a different object (the inventory's "ConfirmBuy", ID 400), so the buy box
    staying separate is right.
- **Fix:** before opening any of SellConfirm, DepositConfirm, WithdrawConfirm or GoldDialog, close all
  four on both hosts.

### 6. DEPARTURE: Ctrl+click refuses to quick-sell cash items
- **Where:** `hud_panels.gd` `_ctrl_sell` / `_on_inventory_cell_input`.
- **Evidence:**
  - The bag branch of `CIFSlotWithHelp::vslot_029` checks two things:
    - 0x6813f3..0x681417: `0x5dd660(ref)`, true when `(b&2)==0 && (b&0x1c)==0xc && (b&1)`;
    - `0x8ba600`: ref +0xa0 is 2 or 6.
  - If either holds, it shows `UIIT_MSG_STRGERR_CANT_QUICKSELL_CASHITEM` (0xda4060, via `0x7781b0`)
    and sells nothing.
  - The buy-back question (0x67cf30 / 0x676100 lookup, then `0x788270` titled
    `UIIT_STT_CONFIRM_BOX`) applies only to the items that pass both tests.
  - Ours sells everything. The lane's note records only the question.
- **Fix:** apply the type-bit test now (`ItemTableReader` has the type bytes). File ref +0xa0 ∈ {2, 6}
  as OPEN until its column is mapped. Name the refusal in `message_box.md`.

### 7. DEPARTURE (small): the deposit box never shows a price below 1
- **Where:** `hud_panels.gd` `_confirm_deposit` (`"fixed_price": 0`).
- **Evidence:** `CIFMessageBox::vslot_012` (0x63d340) rewrites the price edit by purpose. For purpose
  5 it writes `max(1, +0x868)` (0x63d676..0x63d698). The deposit box therefore cannot read 0, and the
  user's `MKtR5Kd.png` shows "1". Withdraw (purpose 6) falls to the default, so its fill's "%d" 0
  stands: ours is right there.
- **Fix:** show 1 for a zero fee, the floor the original applies, or the real fee once +0xcc is
  mapped. Keep the "OpenSRO charges nothing" note.

### 8. WRONG-LABEL: the store prices are not thousands-grouped
- **Where:**
  - `docs/protocol/message_box.md:134` ("formatted by 0x64db50 (`_i64tow`, then 0x8c1350's thousands
    grouping)");
  - `docs/protocol/npc_gui.md` §4 ("grouped");
  - `docs/rounds/r726.md`'s deposit row.
- **Evidence:**
  - 0x64db50 groups only when its fourth argument is non-zero (`if (param_4 != 0) FUN_008c1350(..., 3)`).
  - The deposit fill pushes 0 (0x6b100c), and so does the update (0x63d39e `xor edi,edi`, 0x63d6e5
    `push edi`).
  - Every store price is plain digits. The code's ungrouped `str()` is right; the docs are wrong.
- **Fix:** correct the three docs.

### 9. WRONG-LABEL + DEPARTURE: the sell price is count x unit less the store tax, not "the unit price"
- **Where:**
  - `docs/rounds/r726.md` table ("the unit price, "%I64d" (0x6b07d0)");
  - `npc_gui.md` §4 and `message_box.md`'s sell fill paragraph;
  - code `StoreMessageBox.price_text`.
- **Evidence:**
  - The fill writes the unit price once, but `CIFMessageBox::vslot_012`, for purposes 1 and 2, rewrites
    the price edit (ungrouped, finding 8) with `0x63bd60`:
    `P = ftol(count(+0x8b8) * unit(+0x870)); P - ftol(P * rate(+0xc98))`.
  - The rate is set by the sell fill when `0x703fc0()` is non-zero:
    `(short)[0x6f7460()+0xc] / 100.0` (0x6b0871..0x6b0896; the double at 0xe1b7d8 is 100.0).
  - The count is read from the edit and held to the edit's max when +0x419 is set.
  - Ours shows count x unit. That is right when the rate is 0, but there is no tax term.
  - That slot 12 runs every frame is INFERRED (`CGInterface::vslot_012` is the per-frame update,
    `chat.md`). The formula is READ.
- **Fix:** correct the docs to the formula. Add the tax term when lane C reads the tax line's data
  (`npc_gui.md` OPEN 1), or record it there as OPEN now.

### 10. WRONG-LABEL: round 631's Ctrl+click buy address was not swapped
- **Where:** `message_box.md:131` ("Round 726 corrects round 631, which gave the sell slot's address
  here"); `r726.md`, "The gestures".
- **Evidence:** `CIFSlotWithHelp::vslot_029` 0x680fa0 also buys. With the store as the source (0xf),
  it moves to the bag with count ref +0x1c0, through the same 0x7950b0 call (0x6816a0..0x6816d6), and
  it gives the specialty refusal `UIIT_MSG_COS_CANNOT_BUY_SPECIALTY_TO_INVENTORY` (0xda3fa8). Both slot
  classes buy on Ctrl+click; round 631's "0x680fa0 (ForPackage: 0x68a6c0)" was right. The code's
  behaviour is unaffected.
- **Also read:** the Ctrl+sell count is the stack when `0x538410(ref)` is true and 1 otherwise
  (0x6815e0..0x681608). That is effectively the whole stack, as the lane says.
- **Fix:** restore round 631's row and add the bag branch.

### 11. MINOR (unrecorded READ): the purposes restyle the count edit
- **Evidence:**
  - Buy back, deposit and withdraw OR style **0x81** into the count edit (`0x635150(0x81)`:
    0x63ed10, 0x63ed90, 0x63ee1b). In CIFEdit's WM_CHAR (0x637290), 0x01 lets only the digits 0-9
    through, and 0x80 drops Backspace (0x63748c).
  - Deposit's fill also sets 0x23 and leaves the edit unfocused (`0x635030(0)`). Sell and withdraw
    focus it (`0x635030(1)`).
  - Whether the deposit count can really be edited is therefore not settled. The lane's comment says
    "the count is typed" (`hud_panels.gd` `_confirm_deposit`).
- **Fix:** record it in `message_box.md` and do not assert that the count can be typed.

### 12. MINOR: an open box acts on a slot whose item can change under it
- **Where:** `hud_panels.gd` `_confirm_sell` / `_confirm_deposit` / `_confirm_withdraw`.
- **Evidence:** the boxes are not modal (OURS). With a sell box open on bag slot 5, a Ctrl+click on
  slot 5 sells the stack, and a later move can fill the slot. The box's Sell then sends `_do_sell(5, q)`
  for whatever is there. Round 631 closed this hole for a hidden window but not for a changed slot.
- **Fix:** on OK, check that the slot still holds the box's item id and at least `q`; otherwise close
  the box. Finding 5's single-box rule narrows the exposure.

### 13. MINOR: stale comments name the removed gold dialog
- **Where:** `hud_panels.gd:1311-1313` (`_talk_prompt`: "the dark, gold-edged box of the warehouse gold
  dialog (_open_gold_dialog)") and `:1366-1368` (the guild name prompt "laid out like the warehouse
  gold dialog").
- **Fix:** describe those panels on their own terms.

### 14. MINOR: buy-box branches not modelled
- **Evidence:** CItemMallConfirmBuy caps the count at **5** instead of +0x1c0 when `0x8bf0d0` holds
  (0x7c5776..0x7c5797, 0x7c5aa2..0x7c5ab7).
- **Fix:** record it as OPEN with the unread predicate.

### 15. MINOR (1 px): the static labels sit one pixel high
- **Evidence:** in the measured frames, "Quantity", "Price", "Gold", the item name and the title end
  one row higher than the reference's (finding table below).
- **Fix:** none needed; noted for the next LAYOUT pass.

## Measured (pixels; ImageMagick grey dump, text = luma > 170, box-relative)

| band | `3Gw7Ene.png` @ (343,148) | ours `01_buy_box.png` @ (477,272) | `MKtR5Kd.png` @ (388,426) | ours `08_deposit_box.png` @ (486,286) |
|---|---|---|---|---|
| left frame edge, row h/2 | 8 107 66 58 1 | 8 106 65 57 0 | 8 99 58 58 1 | 8 98 57 57 0 |
| title y | 14-23 | 14-22 | 13-22 | 13-21 |
| "Quantity" x / y | 191-235 / 83-93 | 193-235 / 82-92 | 191-235 / 83-93 | 193-235 / 82-92 |
| "Price" x / y | 77-101 / 105-113 | 76-101 / 104-112 | 77-101 / 103-111 | 76-101 / 102-110 |
| "Gold" x / y | 217-239 / 104-113 | 217-240 / 104-112 | 217-239 / 102-111 | 217-240 / 102-110 |
| OK / Cancel text | 83-156, 171-244 / 138-159 | same | 83-156, 171-244 / 136-157 | same |

The frames are identical (327x177 and 327x175, the same edge profiles), and the text agrees to 1 px.
The lane's size and offset claims hold. Gold box, frame 12 @ (486,286): the "Deposit" caption is
centred at x 159-199; the icon is empty (finding 1); "Unit" is drawn (finding 2).

## Verified as claimed

- **The purpose switch (0x63eb8f..0x63f00a):**
  - all four mode-6 purposes resize to 327x175 (`push 0xaf; push 0x147`, vslot 0x54);
  - the title is `UIIT_STT_CONFIRM_BOX` (0xd89140);
  - OK is `UIIT_STT_SELL` (0xd9b820), `RE_BUY_OBJECT` (0xd9b7f0), `DEPOSIT` (0xd9b7cc) or `WITHDRAW`
    (0xd9b7a8);
  - Cancel is `UIIT_CTL_CANCEL` (0xd9b83c);
  - the spins (0x51/0x52) are hidden for 0x14, 5 and 6 and kept for sell;
  - withdraw hides +0x898 (86) and +0x818 (79);
  - gold: NAME1 `UIIT_STT_DEPOSITMONEY`, the edit art set to "" (0xe16204), moved to (+0x79, +0x42)
    and sized 0x79x0x18, with 8, 9 and 2 hidden.
- **Placement:** `0x6af530` creates at 0x134x0x94 and calls `0x798b70`, which is
  `W/2 - w/2, H/2 - h/2` from the rect at `0xb8f420`. ConfirmBuy adds its rows (0x7c5c63) before
  centring (0x7c5d3c). Its buttons go to x+0x52 / x+0xaa, y+h-0x28 (0x7c4833..0x7c486e).
- **Ctrl+click buy (ForPackage, 0x68a6c0):** `GetKeyState(VK_CONTROL)`, the store open, slot kind 0xf,
  count ref +0x1c0.
- **Ctrl+click sell:** source 0x46, the whole stack.
- **The buy price:** "%I64d" in `CIFItemMallConfirmSlot::0x7c1a80`.
- **Code:** no dead references to the removed paths. `qa_open_gold_dialog`, `CONFIRM_BOXES` and the
  tests all resolve. The party invitation box (round 711) and the shared builders are untouched; the
  diff adds only `StoreMessageBox` and its fixture. The fixture carries rects and keys, not art, as
  `underbar_fixture.gd` does. Picking up and dropping in the bag outside the store is unchanged: Ctrl
  is excluded from `HeldIcon.is_pick_click`, and the Ctrl branches are gated on the store being shown
  and on nothing held.
- **Tests** (`RENDER_DIR=/opt/opensro-client-r726rev`, `GODOT_LOCK=/var/tmp/r726rev/lock`, this head):
  - `remote_godot.sh check`: 616 scripts and 9 scenes, ALL LOAD (the lane reported 617; the
    difference is not explained by the diff);
  - `remote_godot.sh tests`: 236 suites, 0 failing.
  - The suites pass with findings 1-4 in place. The deposit test
    (`store_message_box_test.gd:102`) uses a non-stacking item and does not check that its count
    group is hidden.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
