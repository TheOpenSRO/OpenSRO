# Inventory lane: the gold row, and dragging in the bag

A round written for `docs/WORLD_ISSUES.md` (the coordinator numbers and merges it).
Everything below was checked against the server's own answers in a `qa_shot.sh --server`
render, not read off a picture; the frames are only the confirmation that the window drew
what the log says.

## The gold readout was already wired — the TODO line was stale

`HudPanels._apply_stats` writes `GDR_INVENTORY_STA_GOLD` from `OpCharacterStats`'s `gold`, and
`_populate("inventory")` requests those stats on open. The render log shows the row and its
source agreeing: `inventory gold readout 1,000 (server gold 1000)` — 1000 being
`character.StartingGold` (own design, disclosed in its comment). One log line was added so a
render can hold the row against the server value; nothing else changed for gold.

## Drag-and-drop between bag slots: `OpInventoryMove` (0x0032 / 0x0033)

There was no way to rearrange the bag: `inventory.Store` had `List`/`AddItem`/`RemoveItem` only
and `InventoryNet` only `OP_LIST`. Added:

- **`inventory.Store.MoveItem(ctx, characterID, from, to)`** on both stores, one rule:
  `from` must hold something (`ErrSlotEmpty`), both indices in range (`ErrInvalidSlot`), a
  self-move is a no-op; then `to` empty → move; `to` holds the **same item with stack room** →
  merge what fits (up to MaxStack), remainder stays; anything else (a different item, or a full
  or non-stackable same item) → swap. Quantities are conserved in every branch. `SQLStore` does
  it in one transaction; a swap deletes and re-inserts the two rows because `(character_id,
  slot)` is the primary key. `move_test.go` runs the seven cases against **both** stores (7/7
  mem, 7/7 sql).
- **Wire**: `InventoryMoveRequest` = name + two s64 slot indices (the `UseItemRequest` shape
  with a second index). The reply is an `InventoryListResult` on `OpInventoryMoveResult` —
  the whole bag as it stands, or the refusal — the same reuse the storage list already makes,
  so the client redraws from the answer instead of assuming the move happened.
- **Client**: `InventoryNet.OP_MOVE`/`encode_move_request` (byte-layout test in
  `inventory_test.gd`), `NetClient.move_item` + `inventory_move_result`. The drag is done by
  hand in `HudPanels` (the cells are plain Controls from `UiBuilder`, so Godot's
  `_get_drag_data` route was not available): a press on a filled cell arms it, 4 px of motion
  starts it (a copy of the icon follows the mouse), the release is resolved against the
  lattice cells' own rects (slot = child index, the same indexing `_fill_inventory_grid` draws
  by) or the docked doll's `GDR_EQUIPMENT_SLOT_*` rects; Escape cancels. Nothing is sent
  until a drop lands somewhere that means something. When a vendor window is open a click
  still sells/deposits, as before.

**Verified** (`SRREVAMP_QA_MOVE="0,9"`, the new hook): a fresh character's bag is empty (its
kit is equipped straight out of it), so the hook first **unequips the boots** (real
`OP_UNEQUIP`; they land in the lowest free slot, 0), lists, moves, lists again:

```
QA MOVE before: {0:3645 x1}
QA MOVE after:  {9:3645 x1} (asked 0 -> 9)
```

Both lines are the server's list. The frame shows the boots icon in the third row, second
column — slot 9 of the 4×8 lattice — and the gold row at 1,000.

## Dragging onto the paper doll equips — and it exposed an old ambiguity

Dropping a bag stack on a worn slot sends `OpEquip(slot, from)`; the server's rules decide.
The QA hook then "drops" the moved slot on the doll's boots rect **through the same hit-test a
real drag uses** (`_drop_bag_item` at the slot control's centre, `(796, 371)` in the frame):

```
QA MOVE equip-drop: dropping bag slot 9 at (796, 371) (the doll's boots rect)
QA MOVE equip-drop: bag {} (dropped slot 9 on the doll's boots rect)
```

The bag came back empty and the final frame shows the boots icon in the doll's boots slot again.

Two things this run found on the way, both fixed:

1. **The box's in-memory server refused the equip until it had reference data.**
   `equipRefusal` deliberately refuses an item its tables do not know (the documented
   potion-equip incident), and no `items.csv` sat beside the pk2s. That is the server being
   right. For the run, `itemdata_*.txt` were extracted with `pk2list -extract`, turned into
   `items.csv` with `export-refdata` (16,819 rows; item 3645's type ids `3,1,1,6` = clothes
   `FA`, boots), passed as `SRREVAMP_ITEMS_CSV`, and deleted afterwards.
2. **A successful equip/unequip answered `EquipmentResult{}`** — on the wire identical to
   "wearing nothing" — and the client's shared `equipment_result` handler redrew the paper
   doll bare from it while the body stayed dressed (seen in a frame: every worn-slot icon
   blank after the equip). `handleEquip`/`handleUnequip` now answer with the worn list via
   `sendWornList`, the same way the move op answers with the bag; and the client no longer
   redraws the doll from an *error* result either (it logs the refusal and keeps the last
   known equipment). No opcode or payload shape changed — an ack simply carries the list.

## Not done / flagged

- The authored grid is 4×8 (32 cells) while `SlotsPerCharacter` is 50: a stack the server puts
  past slot 31 has no cell to draw in, and no drag can reach it. Pre-existing; not touched.
- The drag is client-authored behaviour (threshold, ghost icon, Escape); nothing about how the
  original's drag looks was recovered, and none is claimed.
- The QA sequence runs before the QA harness opens the panel, so the doll-drop waits for the
  window (polls up to ~20 s) rather than assuming it exists.
