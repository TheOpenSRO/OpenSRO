extends SceneTree

## Exercises ItemTableReader against synthetic rows shaped like the real
## tables (never real game data):
##   godot4 --headless --path client --script res://scripts/npc/item_table_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A real itemdata row is ~160 columns and carries three resource paths --
## two `.bsr` models and one `.ddj` icon -- which is why the icon is found
## by extension rather than by index.
func _row(id: String, item_name: String, icon: String, icon_col: int) -> String:
	var cols := PackedStringArray()
	cols.resize(160)
	cols.fill("0")
	cols[0] = "1"
	cols[ItemTableReader.COL_ID] = id
	cols[ItemTableReader.COL_NAME] = item_name
	cols[52] = "item\\china\\man_item\\clothes_01_ba.bsr"
	cols[53] = "item\\etc\\drop_ch_equip_rare.bsr"
	if icon != "":
		cols[icon_col] = icon
	return "\t".join(cols)

func _init() -> void:
	var text := "\t".join(PackedStringArray(["//", "a comment row"])) + "\n" \
		+ _row("4842", "Cotton Suit", "item\\china\\man_item\\clothes_01_ba.ddj", 54) + "\n" \
		+ _row("4734", "Cotton Hat", "item\\china\\man_item\\clothes_01_ha.ddj", 61) + "\n" \
		+ _row("9999", "", "", 54) + "\n"
	var items := ItemTableReader.parse(text.to_utf16_buffer())

	_check(items.size() == 2, "two items parsed, the comment and the empty row skipped (got %d)" % items.size())

	var suit: ItemTableReader.Item = items.get(4842)
	_check(suit != null, "item 4842 present")
	if suit != null:
		_check(suit.item_name == "Cotton Suit", "name round-trips (got %s)" % suit.item_name)
		# The icon path in the table is relative; the file lives under icon\.
		_check(suit.icon_path == "icon\\item\\china\\man_item\\clothes_01_ba.ddj",
			"icon path is prefixed with icon\\ (got %s)" % suit.icon_path)

	# The icon column moves between parts, so it is found by extension. The
	# two .bsr paths in the same row must not be mistaken for it.
	var hat: ItemTableReader.Item = items.get(4734)
	_check(hat != null and hat.icon_path.ends_with("clothes_01_ha.ddj"),
		"an icon in a different column is still found (got %s)" % (hat.icon_path if hat != null else "-"))
	_check(hat != null and not hat.icon_path.ends_with(".bsr"),
		"a model path is not mistaken for the icon")

	# The server's own starting kit ids must be resolvable, or a new
	# character's inventory shows five unnamed rows.
	var kit_rows := PackedStringArray()
	for pair in [["4734", "Cotton Hat"], ["4842", "Cotton Suit"], ["4806", "Cotton Talisman"],
			["4878", "Cotton Trousers"], ["4950", "Cotton Shoes"]]:
		kit_rows.append(_row(pair[0], pair[1], "item\\china\\man_item\\x.ddj", 54))
	var kit_items := ItemTableReader.parse(("\n".join(kit_rows) + "\n").to_utf16_buffer())
	_check(kit_items.size() == 5, "the five starting-kit ids all parse (got %d)" % kit_items.size())

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
