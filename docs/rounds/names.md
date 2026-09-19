## Every item name comes from the object table -- the potion was resolved against the wrong file

"HP ?? ??" on a dropped potion's plate and "Looted 2x item #4" in the chat had
one cause each, and neither was the font.

**Measured against the archive (2026-09-19).** Item 4 is `ITEM_ETC_HP_POTION_01`
(the "item #4"). Its `itemdata_5000.txt` row, read out of the user's own
Media.pk2: column 3 is *literally* `HP ?? ??` -- the Korean was mangled to
question marks in the file itself, upstream of this project -- and column 5 is
`SN_ITEM_ETC_HP_POTION_01`. That key resolves in `textdata_object.txt` (one
3.5 MB file, not sharded): 16 columns, 0-based column 7 `0`, column 8
`HP Recovery Herb` -- the shape `UiTextTable`'s column rule already handles.
`textdata_object.txt` carries **9,315** `SN_ITEM_` keys; `textuisystem.txt`,
the UI-string catalog, carries **0**.

**The cause.** `World3D._item_display_name` -- the resolver the ground plates
were given -- called `display_name(_ui_text_table)`, and `_ui_text_table` is
`textuisystem.txt`. Nothing could ever resolve through it, so every name fell
to column 3, which for consumables is the mangled Korean. The HUD's tooltips
and buy/sell prompts resolve through their own parse of `textdata_object.txt`
(`_object_names` in HudPanels), which is why the same potion's tooltip read
correctly all along. The chat lines never resolved at all: `Looted %dx item
#%d`, the pick-up print, the trade summary and the three dev lists printed ids.

**What changed.**
- `ItemTableReader.Item.display_name` still resolves the `SN_` key through the
  table it is given, but falls back to column 3 **only when that text reads as
  English** (new `reads_as_english`: printable ASCII, at least one letter, no
  `?`); otherwise "". A player sees the client's own name or nothing -- never an
  id, never a row of question marks. A weapon's English column 3 still stands
  in when the key is unknown (Copper Sword).
- `World3D._object_names()` hands out the one parsed `textdata_object.txt`,
  sharing the variable the monster-model loader already filled
  (`_object_name_table`), so the 3.5 MB file is parsed once, not per caller.
  `_item_display_name` uses it. `_item_label_for_line` is the chat/log variant:
  display name, else the item's own code name (a fact from the table, English),
  else nothing -- the code name is for lines, never plates.
- Routed: the ground-item plate (`GroundItems.label_text`, which now omits the
  plate entirely when there is no name rather than showing an id), the pick-up
  result (now also a chat line, `Picked up 2x HP Recovery Herb.` -- the line
  itself is ours, the name is the client's), `Looted`, the trade summary, and
  the inventory/equipment/shop dev lists.
- Test: `item_table_reader_test.gd` gains the real shapes -- the potion row
  resolving through an object-table fixture, showing nothing through a
  UI-catalog fixture and with no table, the weapon's English column 3 standing
  in, and `reads_as_english` on English / `HP ?? ??` / Hangul / digits / blank.

**Verified.** `remote_godot.sh check`: 222 scripts ALL LOAD; the item test ALL
PASS. In-world (`--server`, in-memory server, Mangyang spawn, fast attacks,
`SRREVAMP_QA_PICKUP=1`): `ground item 2 (HP Recovery Herb x2) at ...`,
`picked up 2x HP Recovery Herb (ground item 2, item 4)`, `QA PICKUP: result 0
-> 2x HP Recovery Herb`, repeated for items 4 and 6; the frame shows the chat
lines "Picked up 52 gold." / "Picked up 2x HP Recovery Herb." and the plates
over the pile.

**Disclosed.** The `Picked up …` / `Looted …` wording is ours (the client's own
acquire message was not looked up); the English-ness test is our rule for when
column 3 may stand in. Not touched: the tooltip's durability line, the store's
repair controls, the character window, click/cursor/target code.
