extends SceneTree

## Exercises NpcTableReader against synthetic tables (never real game data),
## shaped like the real ones:
##   godot4 --headless --path client --script res://scripts/npc/npc_table_reader_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	# npcpos.txt: npc id, region id, X, Y, Z. Region 25257 is 98/169 and
	# 25001 is 97/169 under the (x << 8) | y key this project uses
	# everywhere else.
	var positions := "\t".join(["2023", "25257", "659.73999", "0.0", "981.13"]) + "\n" \
		+ "\t".join(["2015", "25001", "183.8", "-35.990002", "913.08002"]) + "\n" \
		+ "// a comment row the real files carry\n" \
		+ "\t".join(["short", "row"]) + "\n"
	var spawns := NpcTableReader.parse_positions(positions.to_utf16_buffer())
	_check(spawns.size() == 2, "two spawns parsed, comment and short row skipped (got %d)" % spawns.size())
	if spawns.size() == 2:
		_check(spawns[0].npc_id == 2023, "npc id (got %d)" % spawns[0].npc_id)
		_check(spawns[0].region_x == 98 and spawns[0].region_y == 169,
			"25257 decodes to region 98/169 (got %d/%d)" % [spawns[0].region_x, spawns[0].region_y])
		_check(spawns[1].region_x == 97 and spawns[1].region_y == 169,
			"25001 decodes to region 97/169 (got %d/%d)" % [spawns[1].region_x, spawns[1].region_y])
		_check(is_equal_approx(spawns[0].local_position.x, 659.73999)
			and is_equal_approx(spawns[0].local_position.z, 981.13),
			"local position round-trips (got %s)" % spawns[0].local_position)
		# The middle column is height, not a second horizontal axis -- the
		# same X/Y/Z order the rest of this project's region-local data uses.
		_check(is_equal_approx(spawns[1].local_position.y, -35.990002),
			"the middle column is height (got %f)" % spawns[1].local_position.y)

	# characterdata: wide rows where the .bsr path is not at a fixed index,
	# which is why it is found by content.
	var wide := PackedStringArray()
	wide.resize(104)
	wide.fill("0")
	wide[0] = "1"
	wide[1] = "2023"
	wide[2] = "NPC_CH_PRIEST"
	wide[52] = "npc\\npc\\chinaquest_priest.bsr"
	var narrow := PackedStringArray()
	narrow.resize(60)
	narrow.fill("0")
	narrow[0] = "1"
	narrow[1] = "2015"
	narrow[2] = "NPC_CH_TICKET"
	# Deliberately a different column, to prove the index isn't assumed.
	narrow[31] = "npc\\npc\\chinasystem_bookmakergirl.bsr"

	var models := NpcTableReader.parse_models(("\t".join(wide) + "\n").to_utf16_buffer())
	models = NpcTableReader.parse_models(("\t".join(narrow) + "\n").to_utf16_buffer(), models)
	_check(models.size() == 2, "two models parsed (got %d)" % models.size())
	_check(models.get(2023, "") == "npc\\npc\\chinaquest_priest.bsr",
		"model path found at column 52 (got %s)" % models.get(2023, ""))
	_check(models.get(2015, "") == "npc\\npc\\chinasystem_bookmakergirl.bsr",
		"model path found at a different column too (got %s)" % models.get(2015, ""))

	# A row with no model at all must not invent one.
	var modelless := PackedStringArray()
	modelless.resize(20)
	modelless.fill("0")
	modelless[1] = "9999"
	var none := NpcTableReader.parse_models(("\t".join(modelless) + "\n").to_utf16_buffer())
	_check(none.is_empty(), "a row with no .bsr yields no entry (got %d)" % none.size())

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
