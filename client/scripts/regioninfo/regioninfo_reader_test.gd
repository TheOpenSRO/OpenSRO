extends SceneTree

## Exercises RegioninfoReader and RegioninfoNames against synthetic
## regioninfo-shaped buffers (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/regioninfo/regioninfo_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _bytes(text: String) -> PackedByteArray:
	return text.to_ascii_buffer()

## Joins fields with real tabs and terminates with CRLF, the way the real
## file does. A field may be a String or raw bytes (for a name, which is
## really EUC-KR and so cannot be expressed as ASCII).
func _line(fields: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for i in range(fields.size()):
		if i > 0:
			out.append(0x09)
		var f = fields[i]
		out.append_array(f if f is PackedByteArray else _bytes(f))
	out.append(0x0D)
	out.append(0x0A)
	return out

func _initialize() -> void:
	# Two high bytes standing in for a real EUC-KR name, plus a second,
	# longer one so the keys are clearly distinguishable.
	var name_a := PackedByteArray([0xc0, 0xe5])
	var name_b := PackedByteArray([0xb5, 0xb7, 0xc8, 0xb2])

	var data := PackedByteArray()
	data.append_array(_line(["\t", "", ""]))                      # padding line
	data.append_array(_line(["#TOWN", name_a, "", ""]))
	data.append_array(_line(["168", "98", "ALL", "", ""]))        # whole region
	data.append_array(_line(["169", "97", "RECT", "0", "220", "1920", "220"]))
	data.append_array(_line([]))
	data.append_array(_line(["#FIELD", name_b, ""]))
	data.append_array(_line(["169", "97", "RECT", "1720", "0", "1720", "1920"]))
	data.append_array(_line(["100", "100", "ALL"]))
	data.append_array(_line(["#BOGUS", name_a]))                  # unknown kind
	data.append_array(_line(["1", "2", "SOMETHINGELSE"]))         # unknown token

	var table := RegioninfoReader.parse(data)
	_check(table != null, "parses a real-shaped buffer")
	if table != null:
		_check(table.zones.size() == 2, "keeps only the real TOWN/FIELD sections (got %d)" % table.zones.size())
		_check(table.zones[0].kind == "TOWN", "reads the real section kind")
		_check(table.zones[1].kind == "FIELD", "reads a real FIELD section")
		_check(table.zones[0].name_key == "c0e5", "hex name key from the real raw bytes (got %s)" % table.zones[0].name_key)
		_check(table.zones[1].name_key == "b5b7c8b2", "hex name key for the longer name (got %s)" % table.zones[1].name_key)
		_check(table.zones[0].name_bytes == name_a, "keeps the real name bytes undecoded")

		# Column order really is <y> then <x>.
		var first: RegioninfoReader.Claim = table.zones[0].claims[0]
		_check(first.region_y == 168 and first.region_x == 98, "reads <y> then <x> (got x=%d y=%d)" % [first.region_x, first.region_y])
		_check(first.whole_region, "ALL is a whole-region claim")
		_check(first.rect.is_empty(), "an ALL claim carries no rect")

		var second: RegioninfoReader.Claim = table.zones[0].claims[1]
		_check(not second.whole_region, "RECT is a partial claim")
		_check(second.rect.size() == 4 and second.rect[0] == 0 and second.rect[3] == 220, "carries RECT's four real numbers unread")

		_check(table.zones[1].claims.size() == 2, "unknown tokens are skipped, real ones kept (got %d)" % table.zones[1].claims.size())

		_check(table.zone_indices_for(98, 168) == [0], "resolves a region claimed once")
		_check(table.zone_indices_for(97, 169).size() == 2, "a split region lists both real zones")
		_check(table.zone_indices_for(1, 1).is_empty(), "an unclaimed region lists nothing")

		_check(table.sole_zone_for(98, 168) == 0, "a whole-region claim resolves")
		_check(table.sole_zone_for(97, 169) == -1, "a region split between two zones stays ambiguous")
		_check(table.sole_zone_for(1, 1) == -1, "an unclaimed region stays ambiguous")

		# A region claimed once but only partially is still ambiguous --
		# the rest of it belongs to nobody we can name.
		var partial := PackedByteArray()
		partial.append_array(_line(["#TOWN", name_a]))
		partial.append_array(_line(["50", "60", "RECT", "0", "0", "10", "10"]))
		var partial_table := RegioninfoReader.parse(partial)
		_check(partial_table != null and partial_table.sole_zone_for(60, 50) == -1, "a lone RECT claim stays ambiguous")

	_check(RegioninfoReader.parse(PackedByteArray()) == null, "rejects an empty buffer")
	_check(RegioninfoReader.parse(_bytes("no sections here\r\n")) == null, "rejects a buffer with no real section")

	# --- names / overrides ---
	RegioninfoNames.clear_overrides()
	_check(RegioninfoNames.display_for("c0e5bec8") == "Jangan", "a real known key gets this project's own name")
	_check(RegioninfoNames.display_for("deadbeef") == "", "an unknown key resolves to nothing, not a guess")

	RegioninfoNames.set_override("c0e5bec8", "장안")
	_check(RegioninfoNames.display_for("c0e5bec8") == "장안", "an override wins over the default")
	RegioninfoNames.set_overrides({"deadbeef": "Somewhere", "b5b7c8b2": "Dunhuang"})
	_check(RegioninfoNames.display_for("deadbeef") == "Somewhere", "an override can name a key the defaults never had")
	_check(RegioninfoNames.display_for("b5b7c8b2") == "Dunhuang", "set_overrides merges rather than replaces")
	_check(RegioninfoNames.display_for("c0e5bec8") == "장안", "merging keeps earlier overrides")
	RegioninfoNames.clear_overrides()
	_check(RegioninfoNames.display_for("c0e5bec8") == "Jangan", "clearing restores the defaults")

	if table != null:
		RegioninfoNames.set_override("c0e5", "Test Town")
		_check(RegioninfoNames.display_for_region(table, 98, 168) == "Test Town", "resolves a region straight to a display name")
		_check(RegioninfoNames.display_for_region(table, 97, 169) == "", "a split region resolves to nothing")
		RegioninfoNames.clear_overrides()
	_check(RegioninfoNames.display_for_region(null, 0, 0) == "", "tolerates a null table")

	_check(RegioninfoNames.DEFAULT_NAMES.size() == 15, "ships a name for each of the 15 real zones (got %d)" % RegioninfoNames.DEFAULT_NAMES.size())

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
