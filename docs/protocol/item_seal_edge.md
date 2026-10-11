# The seal star round an item slot (`icon_edge_rare.ddj`)

The user (2026-10-10): "Let's add "Seal of *" item icon effects. Basically it's a star the spins
around the item icon like this gif - https://i.imgur.com/UK9786Q.gif. Make sure you're replicating
the code as much as possible."

Then (round 766): "make it available everywhere".

Implemented in round 765 by `client/scripts/ui/item_seal_edge.gd` (`ItemSealEdge`), and put on every
slot in round 766. Every fact
below is READ from `sro_client.exe` (decomp dump `/var/tmp/decomp_client` on the render box, built
2026-10-10) or MEASURED from the archive; the one choice of ours is marked OURS.

## 1. The art: a 32-cell sprite sheet, not a moving sprite

- `CIFSlotWithHelp::vslot_010` (`0x66b460`, the slot's resource load) loads
  `icon\item\etc\icon_edge_rare.ddj` into `this+0x63c`. Its neighbours there are
  `icon_edge_nasrun.ddj` (+0x648), `pt_edge_effect.ddj` (+0x640), `int_effect*.ddj`,
  `icon_effect.ddj`, `cool_time_%d.ddj` and the item-number digits (ItemCountLabel).
- The file (Media.pk2) is a JMXVDDJ 1000 wrapping a **256 x 128 DXT3**, with no mips (MEASURED).
- The draw's UVs (§3) cut it into **8 columns x 4 rows of 32 x 32 cells**. Each cell is one
  position of the star, so the orbit is drawn into the art; the code only picks a cell.
- MEASURED (alpha centroid per cell, from the DXT3's explicit alpha, on the box): cell 0 sits at
  the top-left (7.5, 6.9). The star then runs down the left side (cell 9 at x 4.7, y 20.0) and
  along the bottom (cell 15 at 16.9, 26.9). It climbs the right side (cell 21 at 27.4, 15.9) and
  returns across the top (cell 28 at 15.2, 4.0). The cell's alpha sum is 10,000-12,000 down the
  left and bottom, and falls to 1,666-1,751 at the top-right (cells 24-26). That is the
  bright-left, faint-top-right look of the user's gif.

## 2. When a slot has it, and its phase

- **Start.** The slot's SetItem, `0x6871d0`, calls `0x666610` when both of these hold:
  - the item's ref passes `0x8ba600` (Rarity, ref `+0xa0`, is 2 or 6: the seal test the tooltip
    already uses, `ItemTooltipLines.is_seal`);
  - the item's `SOItem +0x28` is set, **or** the slot's kind (`0x666700`, `+0x36c`) is `0x45`,
    the store's buy-back row.
- **What `SOItem +0x28` is: the record holds an item.**
  - `SOItem::0x8be4f0(stream, flag)` sets it from its flag. Every caller whose argument the
    decompiler shows (19 of 28) passes 1. It is cleared when the stream's ref id is 0.
  - The store's goods setter, `0x6d1ff0`, sets it to 1 on the good's record before calling SetItem
    on it. The store's page fill (`CIFStore::vslot_023`, `0x6cff20`) draws a cell empty when it is
    0.
  - Round 765 read it as "read off a server message". The store shows it is wider: any filled item
    record.
- **`0x666610`:**
  - `this+0x668 = rand() & 0x1f` (the sign fix-up is dead: `rand()` is never negative), so each
    slot starts at a random phase, 0..31;
  - then `0xb93320(3, 0x28)`, which starts window timer 3 at 40 ms. `0xb93320` returns at once if
    timer 3 already exists, so a re-set re-rolls the phase but does not restart the timer.
- **Timer 3 is never stopped.** No caller passes 3 to the kill `0xb93170`.
- **The step**, `CIFSlotWithHelp::vslot_005` (`0x66bcf0`), case 3:
  `--this+0x668; if (< 1) this+0x668 = 0x20`.
  - Case `0x14` is the same counter with a wrap of `0xc` and an 80 ms timer, from `0x666640`
    (`icon_edge_nasrun`); it is not this effect.
- **The timer list**, `0xb933d0`: for each live timer, when `now - last >= interval` it calls
  `vslot_005(id)` once and sets `last = now`. `now` is `timeGetTime()` (`0xba9af0`).
  - A late tick is dropped, not caught up, so the real step is the first frame at least 40 ms
    after the last one.
  - MEASURED in our client at 60 Hz: 48-51 ms a step. The user's gif runs one lap in 43 frames
    totalling 1,440 ms, which is 45 ms a step; the original drifts with its frame rate the same way.

## 3. The draw

- **Order.** `CIFSlotWithHelp::vslot_013` (`0x685e50`) draws the slot base (`0x6550c0`, the
  icon), then `0x67cfb0` (the overlays, this one among them) unless `+0x64c` is set, then the
  count (`0x67bd70`).
- **The test.** `0x67cfb0` draws the edge when:
  - the slot holds an item (`+0x390`) whose `+0x28` is set;
  - the ref passes `0x8ba600`;
  - and `+0x668 > 0`.
  A kind-`0x45` slot repeats the same draw without the `+0x28` test.
- **The cell.** `i = 0x20 - counter` (0..31); column `i % 8`, row `i / 8`.
- **The UVs.** Doubles in `.rdata`: 32.0 (`0xd99a60`), 1/256 (`0xda3778`), 1/128 (`0xda3770`).
  - u: `col * 32 / 256` to `(col + 1) * 32 / 256`;
  - v: `row * 32 / 128` to `(row + 1) * 32 / 128`.
- **The quad.** It is drawn on the slot's own vertices (`this+0x24c`, 4 x XYZRHW|TEX1), as a
  2-triangle fan: `SetFVF(0x104)` (`0x470310`), `SetTexture`, `SetStreamSource`, then
  `DrawPrimitive(6, ...)`.
  - No render state is changed, so it blends with the UI's ordinary alpha.
  - Counter 0 (a phase of 0, before the first tick) draws nothing for one step.

## 4. In this client

- **Where it sits.** `ItemSealEdge` is a child of a slot's `ItemIcon`:
  - it fills the icon's rect (the slot's quad);
  - it draws after the icon and before the slot's `CountLabel` sibling (vslot_013's order);
  - it takes no input.
- **Where it shows** (round 766: every slot, at the user's request; each one READ):
  - through `HudPanels._set_item_seal_edge`:
    - the bag (kind `0x46`);
    - the worn slots (`0x47`/`0x4e`);
    - the warehouse (`0x13`/`0x91`);
    - the buy-back row (`0x45`);
    - the NPC store's goods (`0x0f`): `0x6d1ff0` sets the good's `+0x28`, then calls SetItem;
  - the quick slots (`HudUnderbar.set_slot_seals`, from `World3D._refresh_quickslot_seals` on
    every change to the bar). An item there is set from its bag record: `0x60c430` finds the bag
    item (`0x6b3e50`), checks its `+0x28`, and calls SetItem with it;
  - the held icon on the cursor (`HudPanels.pick_up_icon`):
    - the original holds the slot itself;
    - `CGame 0x8423d0` draws it at the cursor through its vslot 24, `0xb9d810`. That calls vslot
      16, `0xb9d7f0`, which calls vslot 13, `0x685e50`. Those are the slot vtable `0xda18e4`'s
      entries, read out of the exe;
    - so the star rides along, at the slot's own phase. Our held icon is a copy of the slot, so
      `ItemSealEdge.copy_phase` gives it the slot's counter and timer.
- **Where it does not show:** the store's confirm boxes. Their item pictures
  (`GDR_MBS_CONFIRM_BUY_ITEM_ICON`, `GDR_MBDC_STATIC_ICON`, `GDR_ITEMMALL_CONFIRM_BUY_ITEM_ICON`)
  are `CIFStatic`s in the client's own layouts, not slots, so they have no seal draw.
- **OURS: the phase on a refill.** The same item set again keeps its phase. HudPanels refills a
  whole window on any change, where the original's SetItem runs for one slot; re-rolling every
  seal slot each time would make every star jump at once.
- **OURS: hidden slots.** A hidden edge does not tick. The original's timer runs on, but nothing
  is drawn either way.
- **OURS: dimming.** The edge inherits the icon's `modulate`: the grey of a broken item (itself
  OURS). The original draws the edge undimmed.
- **Tests and probe.**
  - `item_seal_edge_test.gd` checks the step, cell, UV, phase and timer rules;
  - `inventory_pages_test.gd` checks the bag, the worn slots, the store's goods, the quick slots
    and the held icon;
  - `client/tools/seal_edge_frames.gd` draws a real seal item's 32 cells and a real-time run
    (§2's MEASURED step).

## 5. OPEN

- **The exchange, guild storage and stall slots:** not built in this client yet. Each is a
  `CIFSlotWithHelp`; SetItem's callers include `CIFStorageRoom` and `CIFStoreForPackage`. When
  those slots are built, they take the same `_set_item_seal_edge` call. The alchemy window's
  strengthening slots draw it since round 768 (`AlchemyWindow._refresh_slots`).
- **`+0x64c`**, the flag that skips the whole overlay pass: not read.
