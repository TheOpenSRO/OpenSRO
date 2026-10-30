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
  - round 843 (lane S): the player stall's ten slots, owner and visitor (`StallWindowView._draw_slots`;
    `CIFStallSlot` c:0x6cada0 calls SetItem on the entry's record, +0x48, at c:0x6cb011; a
    visitor's records are read by `0x8be4f0(stream, 1)` at c:0x874208, so their `+0x28` is set),
    the stall network's rows (round 842), the exchange's two grids, the pet and transport bags
    (`HudCosWindow.refresh_inventory`; IFCOSInventory's SetItem at c:0x7a75b4) and the grant
    window's item (c:0x80a237). All go through `HudPanels._set_item_slot_fx`, which adds §6's
    effects from the item's record;
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
- **OURS: dimming.** The edge inherits the icon's `modulate`. The original draws the edge
  undimmed: the icon's draw (`0x655d50`) sets stage 0's alpha to MODULATE(TFACTOR, TEXTURE) with
  the slot's alpha in TFACTOR (`0x655ca0`) and puts it back to SELECTARG1(TEXTURE) when it ends
  (`0x6554c0`), before `0x67cfb0`'s overlays (READ). Round 843: the stall's visitor icons, at alpha
  0x80 while the stall is modified (c:0x6bad9a, `0x655460` writes the slot's alpha byte +0x12d),
  take it as `self_modulate`, so their star is undimmed as in the original.
- **Tests and probe.**
  - `item_seal_edge_test.gd` checks the step, cell, UV, phase and timer rules;
  - `inventory_pages_test.gd` checks the bag, the worn slots, the store's goods, the quick slots
    and the held icon;
  - `client/tools/seal_edge_frames.gd` draws a real seal item's 32 cells and a real-time run
    (§2's MEASURED step).

## 5. OPEN

- **Guild storage:** not built in this client (FEATURES "Guild storage: not yet"). It is
  `CIFStorageRoom`, kind `0x91`, the warehouse's class; when built it takes `_set_item_slot_fx`.
- ~~The exchange and stall slots~~: built (the exchange in round 834, the stall in round 843). The
  alchemy window's strengthening slots draw it since round 768 (`AlchemyWindow._refresh_slots`).
- **`+0x64c`**, the flag that skips the whole overlay pass: not read.

## 6. The slot's other per-item effects (round 843, lane S)

The user (2026-10-29): "make sure item icons show any effects in the stall, so if it's a seal weapon
show the spinning stars." Reading the whole of `0x67cfb0` for "any effects" found four more drawn from
the item itself, besides kind-bound overlays. Every fact READ unless marked;
`client/scripts/ui/item_state_edge.gd` (`ItemStateEdge`) builds them.

- **The sheets** (`vslot_010` 0x66b460): `icon\item\etc\icon_edge_nasrun.ddj` (+0x648; MEASURED
  512 x 32), `interface\pet\pt_edge_effect.ddj` (+0x640; MEASURED 288 x 32),
  `interface\pet\pt_life_effect.ddj` (+0x644; MEASURED 256 x 32). Each is one row of 32-wide cells.
- **The devil's spirit's edge.** SetItem: a 3/1/14 item (`0x55edf0`, Bionic 0) on any slot but the
  item mall's (kind `0xa7`) gets `0x666640`: `+0x668 = rand() % 12`, timer `0x14` at `0x50` ms; the
  step (`vslot_005` case `0x14`) `--c; if (c < 1) c = 12`. The draw: when the record's state (`+0x5c`,
  the period word's bit 31, set by the record reader, c:0x8be5e2..0x8be62f) is 1 (awake) and its time
  (`+0x60`, the word's low 31 bits x 1000 ms) is > 0, and `+0x668 > 0`: cell `(12 - c) & 15`, u
  `cell * 32 / 512` (1/512 at `0xda3768`) to `(cell + 1) * 32 / 512`, v 0..1. The counter is the seal
  star's `+0x668`; an item is never both.
- **The wash `0x80004b7e`.** Awake with no time left: the slot's wash colour (`0x652e00`, +0x1f8) is
  `0x80004b7e`; asleep, 0 (none). The base draw (`0x6550c0`) draws it after the icon through
  `0x654d10`: a flat quad, COLOROP SELECTARG1(TFACTOR), alpha 0x80 -- RGB (0x00, 0x4b, 0x7e) at half
  alpha. A pet's scroll gets it when dead (state 4, `0x667ac0`).
- **The summoned pet's edge.** SetItem runs `0x667ac0(state)` for every non-spirit item: state 2 (out)
  -> `0x666680(1)`: `+0x66c = rand() % 9`, timer 4 at `0x32` ms, step `--c; if (c < 1) c = 9`; any other
  state stops it (`+0x66c = 0`, timer 4 killed). The draw: state 2 and `+0x66c > 0`: u `(9 - c) * 32 /
  288` (288.0 at `0xda3780`) to `(10 - c) * 32 / 288`, v 0..1.
- **The life flash.** `0x6666d0`: `+0x670 = 8`, timer 5 at `0x50` ms, step `--c; if (c < 1) { c = 0;
  kill }`. Run by `0x667ac0` for state 3 over a record still at 4 (a revival), and by `0x6b4500` when
  0x3040 mask `0x80` brings more rent seconds than a record with some left (c:0x88c6dc..0x88c701).
  Drawn on the bag (kind `0x46`) or a quick slot over the bag (`0x0c` / `0x46`) only: u `(8 - c) * 32 /
  256` to `(9 - c) * 32 / 256`, v 0..1.
- **The order** in `0x67cfb0`: the pet edge, the seal star, the spirit's edge, [the kind-bound
  overlays], the life flash; the wash before them all (the icon's own draw). Every one needs a record
  (`+0x390`) whose `+0x28` is set.
- **The 0x3040 update** (c:0x88bf30): mask `0x40` runs the bag slot's `0x667ac0(new state)`
  (`0x6b4390`), then every quick slot over that bag slot (`0x60a940`). Mask 1 (a new RefItemID: the
  switchers) flashes the slot with `icon_mall_transgender.ddj` (`0x6665f0`; `RepairFlash.play_switch_on`,
  16 cells of 4 x 4, 50 ms, drawn 48 x 48 at (-8, -8); MEASURED 128 x 128; kinds `0x46` / `0x47` /
  `0x8c` only, the repair flash's own test).
- **Not item effects** (kind-bound, built elsewhere): the use cooldown (`skill_delay.ddj`), the worn-out
  marks (`icon_item_broken` / `icon_item_warning`, round 829's DurabilityMark), the repair flash (round
  829), `com_item_exchange.ddj` (+0x595), `int_effect.ddj` (+0x6b0).
- **None read the plus.** No test in `0x67cfb0` or SetItem reads OptLevel: there is no plus glow on an
  icon. One sheet serves every seal (Rarity 2 or 6): Star, Moon, Sun and Nova draw the same star.
- **Rentals:** a rent object (`+0x168`, `+0xc` set and `+0x10` 0 or 2) draws a half-black wash
  (`0x654d10(0x80000000)`) in the overlay pass. OpenSRO has no rentals (the server's rent word is 0),
  so it is not built.
- **In this client.** `HudPanels._set_item_slot_fx(icon, id, inst)` puts the star and these on a slot
  from its ItemInstance (`cos_state`, the spirit's period word in `durability`); an emptied slot loses
  them all (`_set_item_seal_edge(icon, -1)`). The quick slots: `HudUnderbar.set_slot_states` from
  `World3D._refresh_quickslot_states` (every bar change and bag list). 0x3040: `World3D._on_cos_item_state`
  redraws the bag (`HudPanels.bag_item_state_changed`) and the bar, and plays the life flash; mask 1:
  `HudPanels.flash_switched`. The held icon copies the slot's (`ItemStateEdge.copy_from`).
- **OURS.** The spirit's time is the record's as last read: the original counts `+0x60` down each
  second (`vslot_005` case 200, a 1000 ms timer SetItem starts) and turns the edge into the wash at 0 by itself; this client waits
  for the server's next record. A life flash still running when its item leaves the slot is not drawn
  (the original's draw needs a record) but its node lives out its 640 ms.
- **Tests.** `slot_fx843_test.gd` (the real Media.pk2): the rules, the four sheets' sizes, the
  stall's ten slots as owner and visitor (a list, a Modify, a sale, a close and a reopen; the visitor's
  dim not on the star), the exchange, the warehouse, the bag with 0x3040's changes and the life flash,
  the switch flash, the worn spirit, the quick slots and the held icon. `hud_cos_test.gd`: the pet bag.

## 7. Census: the windows with item slots (round 843)

READ: every window below holds `CIFSlotWithHelp`s filled through SetItem (`0x6871d0`; its callers
named), so each draws §3 and §6 for a record whose `+0x28` is set.

| Window | Original (READ) | Before round 843 | Now |
|---|---|---|---|
| Stall, owner | CIFStallSlot -> SetItem on the entry's record (c:0x6cb011) | nothing | star + §6 |
| Stall, visitor | the same; records read with flag 1 (c:0x874208) | nothing | star + §6, undimmed at alpha 0x80 |
| Stall network rows | c:0x6caa40 -> SetItem, flag 1 (c:0x6c993d) | star | star + §6 |
| Exchange, both grids | UI_EXCHANGE c:0x7b32a0 / 0x7b3380 / 0x7b3400 / 0x7b3ad0 | star | star + §6 |
| Warehouse | CIFStorageRoom (c:0x6cc868, 0x6ccbf0, 0x6ccf80) | star | star + §6 |
| Guild storage | CIFStorageRoom, kind 0x91 | not built | not built (OPEN) |
| NPC store goods | 0x6d1ff0 sets +0x28, then SetItem | star | star (goods carry no state) |
| Buy-back row | kind 0x45: the star without +0x28 | star | star; §6 OPEN (no record kept) |
| Item mall goods | c:0x7cf9a0 SetItem on a record from the ref (+0x28 0, `0x8bcbc0`); kind 0xa7 never starts the spirit's edge | nothing | nothing (match) |
| Bag | IFInventory c:0x6b6620 .. | star | star + §6 + 0x3040 + life flash + switch flash |
| Worn slots, avatar slots | c:0x6ae1b0 (also 0x3040's worn branch) | star | star + §6 + switch flash |
| Pet / transport bag | IFCOSInventory c:0x7a75b4, 0x7a7c10 | nothing | star + §6 |
| Alchemy | UI_ALCHEMYBOX c:0x579f70 .. | star | star + §6 |
| Grant (avatar options) | CIFGrantMagicAttributeWnd c:0x80a237 | star | star + §6 |
| Quick slots | the bag record (0x60c430 -> SetItem; 0x60a940 on 0x3040) | star | star + §6 |
| Held icon | the slot itself, drawn at the cursor | star | star + §6 (copied) |
| Store confirm boxes | CIFStatic, not slots | nothing | nothing (match) |
| Magic POP (gacha), round 843 lane P | the pane's cells: SetItem with the bag slot's own record (c:0x74928d), so the bag's effects; the card slot: the same record (c:0x749b8c); the prizes: a fresh record with +0x28 = 1 (c:0x748eb1), so a seal prize's star; kind 0x8c, so no life flash (the switch flash's kinds include 0x8c: c:0x747890 on the coupon's arrival); the chosen prize: the pet-edge sheet on +0x596 (c:0x67ea55) | nothing | star + §6 on the cells and the card slot, the star on seal prizes, the chosen prize's pet-edge marker, the cell's switch flash (magic_pop.md §3a) |
| Item chest | CIFItemMallStorageRoom (c:0x7d23d0); records not traced | no item icons here | OPEN |
