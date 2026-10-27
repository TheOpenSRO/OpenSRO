# The exchange's three message boxes

Round 834. These are the three `CIFMessageBox`es that the exchange opens:

- **A.** The request popup the invitee sees (HUD request kind 7).
- **B.** The quantity box for offering a bag item (inventory purpose 7).
- **C.** The gold box (inventory purpose 8).

Everything here was read from `sro_client.exe` (vSRO 1.188), `/var/tmp/sro_client.dis` on the RE
box, and from `resinfo\ifmessagebox.txt` in Media.pk2. Each item is **READ** unless it is marked
**INFERRED**. Rects are x,y,w,h relative to the box. `c:` means a client address.

Background: `message_box.md` covers the class, modes and purposes, `exchange.md` §4 the flow,
`friends.md` the HUD request box, and `client/scripts/ui/hud/store_message_box.gd` the existing
builders.

## Common to all three

- **Title.** Every box is titled `UIIT_STT_CONFIRM_BOX` through vslot 0xb4 on the box. The
  title static `+0x7c8` sits at (10, 11), (w − 21) × 12, set by the relayout `c:0x63b420`.
- **Background tile.** `c:0x63b420` is also called at the end of `CIFMessageBox::Create`
  (`c:0x63e552`). It sizes the file's "Create" background `GDR_MSGBOX_BG` (16,40) to
  (w − 32) × (h − 56). For a 308×148 box that is **276×92**.
- **Frame.** `interface\messagebox\msgbox2_window_`, as in the existing builders.
- **Size and position.** None of the three calls SetSize (vslot 0x54), so each keeps its
  creation size of **308×148** (`0x134 × 0x94`). The store and warehouse purposes resize to
  327×175; these do not.

## A. The exchange request popup (HUD request kind 7)

**Creation** (`c:0x6ec5d0`, the HUD request queue):

- **Rect.** (pw/2 − 0x9a, ph/2 − 0x4a, 0x134, 0x94) = (pw/2 − 154, ph/2 − 74, 308, 148)
  (`c:0x6ec664..0x6ec691`). (pw, ph) is the parent's size from `c:0xb8f420`, and the halves
  truncate toward zero (`cdq; sub; sar`). That the parent spans the whole screen is INFERRED.
  Only kind 6 starts at height 0xa0 (`c:0x6ec682..0x6ec69b`).
- **Cascade.** When other request boxes are queued, the new box moves to the last box's
  (x + 20, y + 20) (`c:0x6ec72f..0x6ec761`, vslot 0x9c).
- **Content.** The box is created new each time (`c:0xba20b0`), with mode 1 = `MsgBoxINIF`
  (`c:0x6ec6f4`), so every control starts at its layout rect.
- **Name.** The requester's name is copied to the wstring `+0x81c` (buffer `+0x820`) by
  `c:0x63d780` at `c:0x6ec72a`.
- **Fill.** `c:0x644c90(kind 7, data)` fills the box (`c:0x6ec77b`).

**The kind-7 case** (`c:0x64602e..0x646181`, table `0x648758` entry 6) changes no position, size,
colour or alignment. It only sets these texts:

| Member | Control (MsgBoxINIF) | Rect | HAlign | Text |
|---|---|---|---|---|
| box | title | (10,11,287,12) | centre | `UIIT_STT_CONFIRM_BOX` |
| +0x840 | `GDR_MBIN_STATIC_MESSAGE1`, ID 1 | 0,52,300,12 | 1 (centre) | `UIIT_STT_PARTY_SOMEUSER` with %s = the requester's name (`+0x820`) |
| +0x844 | `GDR_MBIN_STATIC_MESSAGE2`, ID 2 | 6,70,300,12 | 1 | `UIIT_MSG_DEAL_ASK` |
| +0x848 / +0x84c / +0x850 | MESSAGE3 (6,66,288,12) / MESSAGE4 (6,66,288,12) / MESSAGE5 (6,154,294,12) | | 1 | not touched: empty, so nothing is drawn |
| +0x800 | `GDR_MBIN_BTN_OK`, ID 200 | 72,99,76,24 | 1 | `UIIT_STT_ACCEPT` (`c:0x646131`) |
| +0x804 | `GDR_MBIN_BTN_CANCEL`, ID 201 | 152,99,76,24 | 1 | `UIIT_STT_REFUSE` (`c:0x646167`) |
| +0x808 | `GDR_MBIN_BTN_CERTIFY`, ID 202 | 112,99,76,24 | | hidden by the tail |

- **How the texts are written.** Each key is passed through swprintf with `"%s"` (`0xe18044`).
  MESSAGE1 then goes through the printf-style setter vslot 0xc4 with the name, so the name fills
  the `[%s]`. MESSAGE2 uses plain SetText (vslot 0xb4). Both buttons use vslot 0xc4 with `"%s"`.
- **REFUSE is on +0x804**, the Cancel button. Unlike the friend popup, kind 7 never writes
  `+0x808`.
- **Colours.** Kind 7 does not call `c:0x8b2b70`, so the layout's colours stand. The statics use
  FontColor 255,255,255,255 and the buttons 254,251,216 on `com_button.ddj`, with ClientRect
  0,6,0,0.
- **Unused controls.** `GDR_MBIN_STATIC_MESSAGE_PML` (ID 9, 6,82,300,60) is not bound and is
  empty.
- **Tail.** `jmp 0x64871b` (`c:0x646181`) runs `+0x808`->ShowWindow(0) and returns. It does not
  arm the timer `c:0x644650`, so **kind 7 has no box timeout**.
  - For reference, the timer rule: 10 s when the box's "simple_msgbox_type" map value is 4,
    15 s when it is 8, else 30 s (`c:0x6446e0` / `0x64475e` / `0x644765`, timer id 0xa).
- **Difference from `PartyInvitePopup` (kind 6).**
  - No SetSize: 308×148, not 300×176.
  - MESSAGE1 and MESSAGE2 stay at their layout rects, not (16,48) and (16,64).
  - No blackboxes, no MESSAGE5 line and no timer.
  - The buttons stay at y 99, not y 139.

## B. The item-offer quantity box (`c:0x6b1980`, purpose 7)

### Opening

`c:0x6b1980(slot)` runs these steps, in order:

1. Gate `c:0x777d70`. Then `c:0x6af530` destroys the previous inventory box and creates it new at
   308×148 at `inventory+0x390`.
2. **Mode 2 = `MsgBoxStore`** (`push 2`, `c:0x6b19c0`), not mode 6.
3. Bring to front (`c:0xb8f4f0`->vslot 0x50) and `c:0x79a620`.
4. Map `"DraggedItemIndex"` = the slot (`c:0x644410`, `c:0x6b1a06`). `+0x878` = item `+0x34`.
5. The price static `+0x880` (ID 2) is set to `"%d"` of 0 = "0" (`c:0x6b1a18..0x6b1a57`). The unit
   price `+0x870` is set to ref `+0xb0` and then cleared to 0 (`c:0x63bd30` twice).
6. **Purpose 7** (`c:0x6b1a87`).
7. NAME1 `+0x818` = the item's name: the textdata lookup `c:0x8c9bb0` of ref `+0x60`. That this is
   the NameStrID is INFERRED.
8. The icon `+0x814` = the path at ref `+0x15c` (`c:0x6b1aca..0x6b1b0f`). That this is the
   AssocFileIcon is INFERRED.
9. The count edit `+0x888` (ID 3):
   - style |= 1, then |= 2 (`c:0x635150`);
   - `c:0x634d20`, which is an empty `ret`;
   - `0x635030(1)`;
   - `0x634ff0(0)`: no minimum clamp (`+0x418` = 0);
   - `0x635000(1)`: maximum clamp on (`+0x419` = 1).
10. The count, by the ref's type word: `(b&2)==0 && (b&0x1c)==0xc && (b&0x60)==0x60`, which is the
    stacking ETC test the sell fill also uses.
    - **ETC** (`c:0x6b1ba5..0x6b1c7a`): max = the slot's stack (`c:0x634f20(0x8ba460())`). Both
      sub-branches (on `0x5dd780(ref) && ref+0x2c8&2`) do the same thing:
      - text = `"%d"` of the stack;
      - `0x63bc80(2)` shows the edit and "Unit" (`+0x88c`, ID 4);
      - **SetFocus** (`c:0xb9d9f0`);
      - `+0x8b8` = the stack.
    - **Anything else** (`c:0x6b1c7c..0x6b1caf`): `+0x8b8` = 1 and the text is "1" (`0xd87bdc`).
      There is no SetFocus, no `0x63bc80` and no maximum set.
11. `c:0x648810`, not read.

### CIFEdit flags (READ, `c:0x6366a9..0x636728`, `c:0x635720`)

- `+0x419` set: a typed value above the maximum is rewritten as the maximum (`"%I64d"`).
- `+0x418` set: the same for the minimum.
- `0x635030(1)` sets `+0x41a` and gives the text object (`+0x84`) the colour 0xFF3B457A
  through `c:0x655290`.
- The next keystroke, when `+0x41a` is set, first empties the text (`c:0x635723..0x63573f`).
- So the prefill is drawn selected and is replaced by typing. That the colour is a selection
  highlight is INFERRED.
- The existing builder's "focus" reading of `0x635030(1)` is only half of this: the real focus
  is `c:0xb9d9f0`.

### Purpose 7 in `c:0x63ea80` (entry `0x63f0a2` → shared `0x63eb29..0x63eb8a`)

- **Prologue** (all purposes): `+0x818` (NAME1) and `+0x898` (ID 8, PRICET1) are shown. `+0x8ac` is
  hidden if it is bound. Mode 2 does not bind it.
- **Title.** `UIIT_STT_CONFIRM_BOX`.
- **Buttons.** OK `+0x800` is captioned **`UIIT_CTL_CONFIRM`** (`0xd89fc4`). Cancel `+0x804` is
  **`UIIT_CTL_CANCEL`**.
- **Hidden.** **`+0x87c`** (ID 9, `GDR_MBS_STATIC_NAME2`). Nothing is moved or resized.
- **The binder also hides** (mode 2, `c:0x63e700`) the RENEWAL mileage controls: ID 52 `+0x8a0`,
  ID 51 `+0x8b0` (also style 0x81) and ID 50 `+0x8a4`.
- **Runtime statics.** The binder also creates 10×2 empty runtime statics (IDs 180–199,
  (70, 100+16i, 100, 16) and (165, 100+16i, 40, 16), halign 2). They are textless, so their
  invisibility is INFERRED.
- **The price field.** The per-frame vslot 12 (`c:0x63d340`) writes `""` into the price static
  `+0x880` for purpose 7 (purpose table `0x63d768`: p7 → index 2 → `c:0x63d69a`). That
  overrides the fill's "0", so the field is **empty**. That vslot 12 runs every frame is
  INFERRED; without it the field shows "0".
- **Count tracking.** For modes 2, 3 and 6, the same vslot also parses the edit into `+0x8b8`, or
  0 when it is empty, and clamps it to the maximum.

### Layout (`MsgBoxStore`, binder `c:0x63e700`)

| ID | Control | Member | Rect | Notes |
|---|---|---|---|---|
| 10 | `GDR_MBS_STATIC_ICONWND` | | 18,44,48,48 | `msgbox_itemwindow.ddj` |
| 12 | `GDR_MBS_STATIC_ICON` | +0x814 | 25,51,32,32 | the item icon |
| 1 | `GDR_MBS_STATIC_NAME1` | +0x818 | 73,44,212,48 | `msgbox_iteminfo.ddj`, CR 0,7,0,29, HA 1; the item name |
| 9 | `GDR_MBS_STATIC_NAME2` | +0x87c | 73,53,212,28 | hidden |
| 8 | `GDR_MBS_STATIC_PRICET1` | +0x898 | 77,71,43,12 | `UIIT_STT_PRICE`, shown |
| 2 | `GDR_MBS_STATIC_PRICE` | +0x880 | 127,68,121,17 | HA 1, VA 1; empty (see above) |
| 7 | `GDR_MBS_STATIC_PRICET2` | +0x89c | 255,71,23,12 | `UIIT_STT_GOLD`, shown (nothing hides it) |
| 3 | `GDR_MBS_EDIT_AMOUNT` | +0x888 | 20,102,42,24 | `msgbox_quantity.ddj`, CR 7,5,7,5, HA 2; **not** stripped or moved |
| 4 | `GDR_MBS_STATIC_AMOUNT` | +0x88c | 64,108,12,12 | `UIIT_STT_UNIT`, HA 0; shown for ETC (`0x63bc80(2)`), otherwise its layout default (INFERRED visible) |
| 215 | `GDR_MBS_BTN_OK` | +0x800 | 123,124,76,22 | "Confirm" |
| 216 | `GDR_MBS_BTN_CANCEL` | +0x804 | 203,124,76,22 | "Cancel" |
| 50/51/52 | mileage static, edit and button | | | hidden |

### OK

1. Button 215 runs `c:0x63d7f0`. If `+0x7fc == 2` (ETC), it parses the edit into `+0x8b8`. The flag
   is 0 when the edit is empty, else 1. It posts 0x8074(box, flag).
2. The inventory handler (`c:0x6b4627`, mode switch `c:0x6b468b`; mode 2 → `c:0x6b4c66`) requires
   flag == 1 **and** `+0x8b8 > 0`. Otherwise it calls `c:0x674b00`, which restores alpha 0xff, and
   sends nothing.
3. Purpose 7 (`c:0x6b4fd0..0x6b504e`) picks the count:
   - for an item passing `0x5dd780(ref) && ref+0x2c8&2`, the slot's **whole stack** (`0x8ba460`);
   - otherwise `+0x8b8`.
4. It calls `0x7950b0(0x46, slot, 0x1a, −1, count, 0)`.
5. The box is destroyed (`c:0x6aef20` at `c:0x6b5060`) on every path.

Per `exchange.md` §4, that move sends `0x7034 [4][slot]` with no count. So **the count is shown but
not sent**: it only gates. An empty edit or 0 sends nothing.

### Placement

`c:0x6af530` → `c:0x798b70` centres the 308×148 box: (sw/2 − 154, sh/2 − 74). Purpose 7 does not
resize it, so the box is exactly centred.

## C. The gold box (`c:0x6b2c30`, purpose 8)

### Opening

`c:0x6b2c30` runs these steps, in order:

1. Gate `c:0x777d70`, then `c:0x6af530` (308×148, centred as in B).
2. **Mode 3 = `MsgBoxStoreMoney`** (`c:0x6b2c67`).
3. Bring to front and `c:0x79a620`. `(box+0x84)`->vslot 0x24(0xff) sets alpha; the deposit opener
   does the same.
4. **Purpose 8** (`c:0x6b2cab`).
5. `0x63bc80(2)` shows the edit and "Unit". Then **"Unit" `+0x88c` (ID 4) is hidden**
   (`c:0x6b2cbf..0x6b2cd2`).
6. **SetFocus**(edit) (`c:0xb9d9f0`, `c:0x6b2ce0`).
7. **The edit's text is `"%d"` of 1 = "1"** (`push 1` at `c:0x6b2ce5`). The deposit opener
   `c:0x6b28c8` pushes 0 and shows "0".
8. `0x635030(1)` (select), style |= 1 and |= 2, **no minimum** (`0x634ff0(0)`), **maximum clamp on**
   (`0x635000(1)`).
9. Maximum = **min(gold, 1,000,000,000)**: the inventory's 64-bit `+0x378/+0x37c` against
   `0x3b9aca00`, signed compare (`c:0x6b2d78..0x6b2da7`).
10. The icon `+0x814` = **`icon\mini_gold_icon.ddj`** (`0xda76f8`, `c:0x6b2dc9`), which overrides
    the purpose's icon.

### Purpose 8 in `c:0x63ea80` (`0x63f0da..0x63f234`)

- **Prologue.** Shows NAME1 and `+0x898`. Hides `+0x8ac` (ID 11, `GDR_MBS_EDIT_PRICE`), which
  mode 3 binds.
- **Title.** `UIIT_STT_CONFIRM_BOX`.
- **Icon.** `+0x814` texture = `interface\minipopup\mini_gold_icon.ddj`, which the opener then
  replaces.
- **NAME1** `+0x818` (ID 1) = **`UIIT_STT_AMOUNT_MONEY`**.
- **Buttons.** OK `+0x800` = **`UIIT_CTL_CONFIRM`**. Cancel `+0x804` = **`UIIT_CTL_CANCEL`**.
- **The edit `+0x888` (ID 3).** Its texture is set to `""` (the art is stripped), it is moved to
  box (x + 0x79, y + 0x42) = **(121, 66)** and sized **121×24**.
- **Hidden.** `+0x898` (ID 8, PRICET1) and `+0x87c` (ID 9, NAME2). **ID 2 (`+0x880`, PRICE) is
  not hidden**, unlike purpose 3. That static is empty and has no art, so nothing changes on
  screen.
- **Tail.** `c:0x63ff1c`.
- **Purpose 9 corrects `message_box.md`.** Purpose 9 (`0x63f239`) sets the title, icon and NAME1
  as purpose 8 does. It then pushes `UIIT_CTL_CONFIRM` and jumps into purpose 3's path at
  `0x63ef30`, so it also sets Cancel to `UIIT_CTL_CANCEL`, strips and moves the edit, and hides
  8, 9 **and 2**. That table's "9: as 8, without the Cancel label" is wrong.

### Layout (`MsgBoxStoreMoney`, binder `c:0x63e940`)

| ID | Control | Member | Rect | State |
|---|---|---|---|---|
| 10 | ICONWND | | 18,44,48,48 | `msgbox_itemwindow.ddj` |
| 12 | ICON | +0x814 | 25,51,32,32 | gold icon |
| 1 | NAME1 | +0x818 | 73,44,212,48 | `msgbox_iteminfo.ddj`, CR 0,7,0,29, HA 1, "Amount" |
| 9 | NAME2 | +0x87c | 73,53,212,28 | hidden |
| 8 | PRICET1 | +0x898 | 77,71,43,12 | hidden |
| 2 | PRICE | +0x880 | 127,71,121,12 | shown, empty |
| 7 | PRICET2 | (unbound) | 255,72,23,12 | `UIIT_STT_GOLD`, shown |
| 3 | EDIT_AMOUNT | +0x888 | moved to 121,66,121,24 | art stripped, CR 7,5,7,5, HA 2, "1" |
| 4 | STATIC_AMOUNT | +0x88c | 64,108,12,12 | hidden by the opener |
| 11 | EDIT_PRICE | +0x8ac | 127,68,121,18 | hidden by the prologue |
| 215 / 216 | OK / Cancel | +0x800 / +0x804 | 123,101,76,24 / 203,101,76,24 | "Confirm" / "Cancel" |

### OK

1. `c:0x63d7f0` (`+0x7fc == 2`) parses the edit as an int64 into `+0x8b8` and posts 0x8074 with flag
   0 if the edit is empty.
2. The handler's mode-3 branch (`c:0x6b4a03`) requires flag == 1 and `+0x8b8 > 0`, signed 64-bit.
   Otherwise it calls `c:0x674b00` and **sends nothing**.
3. Purpose 8 (`c:0x6b4b1a..0x6b4b3c`) calls `0x825f50(0x46, 0x1a, amount64)`, with
   ecx = `0xeecbf4`. That sends `0x7034 [0xd][u64]` (`exchange.md`).
4. The box is destroyed (`c:0x6aef20`).

## What a builder adds to `store_message_box.gd`

### `EXCHANGE_ITEM` versus `DEPOSIT`

They share almost nothing. DEPOSIT is mode 6 `MsgBoxStoreConfirm` at 327×175. EXCHANGE_ITEM is:

- **Section and size.** `MsgBoxStore` (mode 2) at 308×148, built on `_message_box_base(308×148)`
  with the BG at 276×92.
- **Controls.** The `GDR_MBS_*` names in B's table; there are no `GDR_MBS_CONFIRM_*` nodes and no
  spin buttons.
- **Captions.** OK = `UIIT_CTL_CONFIRM`, Cancel = `UIIT_CTL_CANCEL`.
- **Hidden.** NAME2, `GDR_MBS_BTN_MILEAGEINPUT`, `GDR_MBS_EDIT_MILEAGE` and
  `GDR_MBS_STATIC_MILEAGE`.
- **Price.** The price static is empty; "Price" and "Gold" stay visible. There is no fee.
- **The edit.** It keeps its `msgbox_quantity.ddj` art at 20,102,42,24, right-aligned, with
  "Unit" visible.
- **Count for ETC.** Prefill = max = the stack, min unclamped, focused and selected.
- **Count otherwise.** "1", selected and not focused.
- **OK.** Emit the count, but the caller sends `0x7034 [4][slot]` only when the edit is
  non-empty and the count is above 0. The box closes either way.
- **Position.** `screen_position` is unchanged, because the box is created at 308×148.

### `EXCHANGE_GOLD` versus `GOLD_DEPOSIT`

They share the same section, size, position, icon override, edit strip, move and size (121,66,121,24),
hidden IDs 8, 9 and 4 (11 by the prologue), cap `min(gold, 1e9)`, no minimum, focus and close on
OK. They differ in:

| | GOLD_DEPOSIT (purpose 3, `c:0x6b2800`) | EXCHANGE_GOLD (purpose 8, `c:0x6b2c30`) |
|---|---|---|
| NAME1 | `UIIT_STT_DEPOSITMONEY` | `UIIT_STT_AMOUNT_MONEY` |
| OK caption | `UIIT_STT_DEPOSIT` | `UIIT_CTL_CONFIRM` |
| Prefill | "0" | **"1"** |
| ID 2 (PRICE) | hidden | left shown; it is empty, so there is no visible difference |
| Cap source | the balance | the inventory's gold, `+0x378` |
| OK sends | `0x825f50(0x46, 0x13, amount)` (`c:0x6b4a51`) | `0x825f50(0x46, 0x1a, amount)`; nothing when it is 0 or empty |

The builder's `min_count` is 0 for both. Keep the min-0 behaviour, but a confirmed 0 must not be
sent.

## D. The dim overlay: offered bag slots and confirmed gold

Both effects come from one primitive, `CIFWnd 0x654d10(argb)`. It draws an **untextured quad over
the window's own rect, on top of what the window has drawn so far**.

### The primitive, `c:0x654d10`

1. **The quad.** Its rect is (x, y) to (x + w × `+0x1fc`, y + h × `+0x200`), from `c:0xb8f420`.
   That the two scale floats are 1.0 for these windows is INFERRED.
2. **The window alpha.** The argb's top byte is written into the window's alpha byte `+0x12d` for
   the duration of the call (`c:0x654d91..0x654dad`). The old value is restored at
   `c:0x655014..0x655019`.
3. **No texture.** The texture is set to none (`SetTexture(0, 0)`, `c:0x654e13..0x654e41`).
4. **Texture factor.** `c:0x655ca0` sets `D3DRS_TEXTUREFACTOR` (0x3c) to (window alpha << 24) |
   (argb & 0xffffff) (`c:0x655d21..0x655d3b`). The alpha comes from `(+0x84)`->vslot 0x20; that
   this returns `+0x12d` is INFERRED, strongly, from the save and restore around the call.
5. **Stage 0 states:**
   - COLOROP = SELECTARG1, COLORARG1 = TFACTOR;
   - ALPHAOP = MODULATE, ALPHAARG1 = TFACTOR, ALPHAARG2 = DIFFUSE (`c:0x654e4f..0x654f0f`).
6. **The draw.** A two-triangle fan with FVF 0x104 (XYZRHW | TEX1, so no diffuse, which D3D reads
   as opaque white) (`c:0x654f7c`).

**Result for `0x80000000`:** a black quad at alpha 0x80/255 = 0.502 over the rect. Under the UI's
SRCALPHA / INVSRCALPHA blend (INFERRED; the blend state is not set here), each pixel becomes
**0.498 × what was under it**: the window's content darkened to about half. It is not a vertex
colour multiplied into the icon. It is an overlay quad.

### Q1. The offered bag slot (`0x6b3f00(slot − 13, 0)`)

- **The flag.** `c:0x6b3f00` indexes the inventory's slot list `+0x3b0` and calls
  `c:0x666810`, which writes the byte `slot+0x574` = the argument (0 = disabled).
- **The render.** `CIFSlotWithHelp`'s render (`c:0x685e50`) runs in this order:
  1. the base static draw `c:0x6550c0`, which draws the slot's art and icon (INFERRED that the
     icon is part of the base draw);
  2. then, unless `+0x64c` is set, `c:0x67cfb0`.
- **The dim.** `c:0x67cfb0` starts with `if (+0x574 == 0) 0x654d10(0x80000000)`
  (`c:0x67cfb7..0x67cfc7`). So the **whole slot rect, icon included, is darkened to about 50 %**.
- **Drawn after the dim** (at `c:0x67d0bb` onward):
  - the blue exchange tile (`+0x595`, `c:0x67cfcc..0x67d0b9`);
  - the item's extras, such as text and marks.

  Being drawn later, these are **not** dimmed (INFERRED from the order; what each extra is was
  not read).
- **A separate dim.** `c:0x67d0f7` applies the same `0x654d10(0x80000000)` for an item whose
  `0x8ba900()` is 0 or 2, when `0x8ba8a0()` is non-zero. That is a different condition, not the
  exchange one (not read).

### Q2. `_MYMONEY` / `_OTHERMONEY` greyed on confirm

- **The setter.** `c:0x7b2700` (own) and `c:0x7b2670` (opponent) call `c:0x64d840(0x80000000)` on
  CIFExchange `+0x33bc` / `+0x33b8`. That setter is `mov [ecx+0x36c], arg` and nothing else.
- **The class** is the static class whose constructor is `c:0x64d600` (vtable `0xd9e0fc`). The
  constructor zeroes `+0x36c` and gives the text object `+0x90` its colour slot 3 = 0xFFB4B4B4
  (`c:0x8b2ba0`). Its render is `c:0x64d940`:
  1. the base draw `c:0x6550c0`;
  2. if there is text (`+0xd8`), the text at (`+0x370`, `+0x374`) (`c:0x8b48b0`);
  3. then, **if `+0x36c` != 0, `0x654d10(+0x36c)`** (`c:0x64d991..0x64d99e`).
- **So `+0x36c` is a dim colour, not a text colour.** The same black-at-0x80 quad covers the
  static's whole rect, text and background alike. The text keeps its magnitude colour from
  `inventory_window.md` and is drawn at about **half brightness**: white "100" becomes about
  (127, 127, 127), which is the grey in the screenshot.
- **Confidence.** That `+0x33b8` / `+0x33bc` are instances of this class is INFERRED, strongly:
  the setter is that class's method and the render reads the field.

## E. Where the exchange's own messages go (Q3)

There are three outputs:

| Output | Function | What it is |
|---|---|---|
| Big notice | `c:0x77b580` | GInterface child 0x23 `GDR_WARNING_WND` (CIFNotify, `0x7b3eb0`). Skipped when the string is empty. |
| System line | `c:0x7781b0(type, text)` | Child 0x44 `GDR_SYSTEM_MESSAGE_VIEW`, gated by `0x7b85f0(type)`. |
| Exchange log | `c:0x64f8a0` on CIFExchange `+0x3730` | Bound at `c:0x7b29e1`: control 304 `GDR_EXCHANGE_TEXT_BOX` (CIFTextBox, `Rect 9999,342,337,87` under `UI_UPDATE_2009_FIRST`), off screen, so never seen. |

- **The system-line gate.** `0x7b85f0`'s type 0 is always true (table `0x7b8650` → `0x7b8600`).
- **The system-line colour.** **0xFFBACFF2 for type 6, 0xFFDBC99B for every other type**
  (`c:0x7781d4..0x7781e3`).

Every exchange call below passes **type 0**, so its system line is 0xFFDBC99B:

| Message | Where | Big notice | System line | Log (off screen) |
|---|---|---|---|---|
| UIIT_MSG_EXCHANGE_START (%s = name, `0x7b31a0`) | show, `c:0x7b3839..0x7b38d6` | no | yes, type 0 (`ebx` = 0 from `c:0x7b37d2`, call `c:0x7b389a`) | yes, 0xFFFFB541 |
| UIIT_MSG_EXCHANGE_DECEPTION_COMPARE, or `_NAME_WARNING` when not normal state | show, untrusted, `c:0x7b394c..0x7b39f7` | **yes** (`c:0x7b397f`) | yes, type 0 (`c:0x7b399a`) | yes, 0xFFFF4A4A |
| UIIT_MSG_EXCHANGE_DECEPTION_REAFFIRM | `c:0x7b3480`, first confirm | **yes** (`c:0x7b35bd`) | yes, type 0 (`c:0x7b35d8`) | yes, 0xFFFFB541; then `0x81d9a0` sends 0x7082 |
| UIIT_MSG_EXCHANGE_AGREEMENT_WAIT | `c:0x7b3480`, approve | no | **no** | **only here**, 0xFFFFB541 (`c:0x7b3675`); then `0x81da40` sends 0x7083 |
| UIIT_MSG_STGRERR_ITEM_EXCHANGE_SUCCEED | `0x3087`, `c:0x88beb1..0x88bed8` | **yes, only there** (`0x77b580`) | no | no |
| UIIT_MSG_EXCHANGE_END (%s = name) | `0x3087`, `c:0x88be59..0x88beec` | no | **yes, type 0, only there** (`ebx` = 0 from `c:0x88bbc1`) | no |

- **AGREEMENT_WAIT is effectively invisible in retail:** it reaches only the parked text box.
- At completion the window is already hidden (`0x79df10(0)`, `c:0x88be20`). After the two
  messages, `0x7b2530(0)` clears CIFExchange `+0x3734`, the flag that `0x7b2540` tests at the
  show (`c:0x7b37cd`).
- **The untrusted branch also** shows `+0x33d4` and gives it the warning text (`0x653dc0`), and
  shows `+0x33d0` with `0x654730(0)` (`c:0x7b399f..0x7b39d4`). What those two controls are was
  not read here; `exchange.md` §4 has the red effect.

## Not read

- `c:0x648810` (the last call of the item fill).
- `c:0x5dd780`.
- What `+0x7fc` is on a fresh box before `0x63bc80`, which matters for a non-ETC item's OK.
- Which kind-7 button maps to which answer in `c:0x797d90`. `exchange.md` has the send.
