extends SceneTree

## Round 682: LobbyNet against the golden bytes the Go server is held to.
## Every vector of testdata/lobby_golden.json -- written by hand from the
## READ layouts (docs/protocol/charselect.md section 5) -- is encoded from its
## fields and must equal its hex, and decoded from its hex and must equal its
## fields; a vector marked "error" must fail to decode. The Go side runs the
## same file (server/internal/session TestLobbyGolden).
##
## NEGATIVE: before round 682 LobbyNet does not exist and this suite does
## not parse.

const GOLDEN := "res://scripts/net/testdata/lobby_golden.json"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

static func _bytes(hex: String) -> PackedByteArray:
	var clean := hex.replace(" ", "").replace("|", "")
	var out := PackedByteArray()
	for i in range(0, clean.length(), 2):
		out.append(clean.substr(i, 2).hex_to_int())
	return out

static func _hex(b: PackedByteArray) -> String:
	return b.hex_encode()

func _request_from(f: Dictionary) -> LobbyNet.Request:
	var r := LobbyNet.Request.new()
	r.action = int(f.get("action", 0))
	r.name = str(f.get("name", ""))
	r.ref_obj_id = int(f.get("ref_obj_id", 0))
	r.scale = int(f.get("scale", 0))
	r.chest = int(f.get("chest", 0))
	r.legs = int(f.get("legs", 0))
	r.feet = int(f.get("feet", 0))
	r.weapon = int(f.get("weapon", 0))
	return r

func _items_from(a: Array) -> Array:
	var out: Array = []
	for it in a:
		out.append({"id": int(it["id"]), "plus": int(it["plus"])})
	return out

func _result_from(f: Dictionary) -> LobbyNet.Result:
	var r := LobbyNet.Result.new()
	r.action = int(f.get("action", 0))
	r.ok = bool(f.get("ok", false))
	r.code = int(f.get("code", 0))
	for c in f.get("characters", []):
		var ch := LobbyNet.Character.new()
		ch.ref_obj_id = int(c["ref_obj_id"])
		ch.char_name = str(c["name"])
		ch.scale = int(c["scale"])
		ch.level = int(c["level"])
		ch.exp_offset = int(c["exp"])
		ch.str_stat = int(c["str"])
		ch.int_stat = int(c["int"])
		ch.stat_points = int(c["stat_points"])
		ch.hp = int(c["hp"])
		ch.mp = int(c["mp"])
		ch.deleting = bool(c["deleting"])
		ch.minutes_left = int(c["minutes_left"])
		ch.guild_class = int(c["guild_class"])
		ch.guild_rename = bool(c["guild_rename"])
		ch.guild_name = str(c["guild_name"])
		ch.academy_class = int(c["academy_class"])
		ch.items = _items_from(c["items"])
		ch.avatars = _items_from(c["avatars"])
		r.characters.append(ch)
	return r

static func _character_dict(c: LobbyNet.Character) -> Dictionary:
	return {"ref_obj_id": c.ref_obj_id, "name": c.char_name, "scale": c.scale, "level": c.level, "exp": c.exp_offset,
		"str": c.str_stat, "int": c.int_stat, "stat_points": c.stat_points, "hp": c.hp, "mp": c.mp,
		"deleting": c.deleting, "minutes_left": c.minutes_left, "guild_class": c.guild_class,
		"guild_rename": c.guild_rename, "guild_name": c.guild_name, "academy_class": c.academy_class,
		"items": c.items, "avatars": c.avatars}

func _same_result(a: LobbyNet.Result, b: LobbyNet.Result) -> bool:
	if a.action != b.action or a.ok != b.ok or a.code != b.code or a.characters.size() != b.characters.size():
		return false
	for i in range(a.characters.size()):
		if str(_character_dict(a.characters[i])) != str(_character_dict(b.characters[i])):
			return false
	return true

func _test_golden() -> void:
	var text := FileAccess.get_file_as_string(GOLDEN)
	_check(text != "", "the golden file is readable at " + GOLDEN)
	var doc = JSON.parse_string(text)
	_check(doc is Dictionary, "the golden file parses")
	if not (doc is Dictionary):
		return
	var ops: Dictionary = doc["opcodes"]
	_check(int(ops["lobby"]) == LobbyNet.OP_LOBBY and int(ops["lobby_result"]) == LobbyNet.OP_LOBBY_RESULT
		and int(ops["start"]) == LobbyNet.OP_START and int(ops["start_result"]) == LobbyNet.OP_START_RESULT,
		"the four opcodes are 0x7007 / 0xB007 / 0x7001 / 0xB001")
	var counted := {}
	for v in doc["vectors"]:
		var name: String = v["name"]
		var kind: String = v["kind"]
		var want := _bytes(v["hex"])
		var is_error: bool = v.get("error", false)
		var f: Dictionary = v.get("fields", {})
		counted[kind] = int(counted.get(kind, 0)) + 1
		match kind:
			"lobby_request":
				var got := LobbyNet.decode_request(want)
				if is_error:
					_check(got.error != "", "%s: refused to decode" % name)
					continue
				var req := _request_from(f)
				var enc := LobbyNet.encode_request(req)
				_check(enc == want, "%s: encodes to the golden bytes (got %s, want %s)" % [name, _hex(enc), _hex(want)])
				_check(got.error == "" and got.action == req.action and got.name == req.name and got.ref_obj_id == req.ref_obj_id
					and got.scale == req.scale and got.chest == req.chest and got.legs == req.legs and got.feet == req.feet
					and got.weapon == req.weapon, "%s: decodes to its fields" % name)
			"lobby_result":
				var got := LobbyNet.decode_result(want)
				if is_error:
					_check(got.error != "", "%s: refused to decode" % name)
					continue
				var res := _result_from(f)
				var enc := LobbyNet.encode_result(res)
				_check(enc == want, "%s: encodes to the golden bytes (got %s, want %s)" % [name, _hex(enc), _hex(want)])
				_check(got.error == "" and _same_result(got, res), "%s: decodes to its fields" % name)
			"start_request":
				var enc := LobbyNet.encode_start(str(f["name"]))
				_check(enc == want, "%s: encodes to the golden bytes" % name)
				_check(LobbyNet.decode_start(want) == str(f["name"]), "%s: decodes to its name" % name)
			"start_result":
				var got := LobbyNet.decode_start_result(want)
				if is_error:
					_check(got.error != "", "%s: refused to decode" % name)
					continue
				var enc := LobbyNet.encode_start_result(bool(f.get("ok", false)), int(f.get("code", 0)))
				_check(enc == want, "%s: encodes to the golden bytes" % name)
				_check(got.error == "" and got.ok == bool(f.get("ok", false)) and got.code == int(f.get("code", 0)), "%s: decodes to its fields" % name)
			_:
				_check(false, "%s: unknown kind %s" % [name, kind])
	for k in ["lobby_request", "lobby_result", "start_request", "start_result"]:
		_check(int(counted.get(k, 0)) > 0, "the file has %s vectors" % k)

func _test_words() -> void:
	# No archive text to hand: our own words, with the server suffix where the
	# client adds one.
	_check(LobbyNet.code_text(0x410, null) == "That name is already taken.", "0x410 in our words without an archive")
	_check(LobbyNet.code_text(0x406, null).ends_with("(S1030)"), "0x406 carries the (S<code>) suffix")
	_check(not LobbyNet.code_text(0x40c, null).contains("(S"), "0x40c has no suffix")
	# The archive's text, with 0x405's %d filled by the limit.
	var table := UiTextTable.parse(_table_bytes())
	_check(LobbyNet.code_text(0x405, table) == "A maximum of 4 characters can be created per account.", "0x405 in the archive's words, %%d -> 4 (got %s)" % LobbyNet.code_text(0x405, table))
	_check(LobbyNet.code_text(0x402, table) == "No connection.(S1026)", "0x402 is the connect-failure text with its suffix (got %s)" % LobbyNet.code_text(0x402, table))
	_check(LobbyNet.code_text(0x40d, table) == "Line one\nline two", "the archive's literal \\n becomes a line break (got %s)" % LobbyNet.code_text(0x40d, table))
	var c := LobbyNet.Character.new()
	c.str_stat = 20
	c.int_stat = 31
	_check(c.gauge_max_hp() == 200 and c.gauge_max_mp() == 310, "the select gauges' maxima are Str x 10 and Int x 10")

## A two-row textuisystem-shaped table, synthetic: token at column 1, "0"
## filler, English at column 8, UTF-16 like the archive's (teleport_test.gd's
## shape).
func _table_bytes() -> PackedByteArray:
	var rows := PackedStringArray([
		"1\tUIO_MSG_ERROR_CHARACTER_OVER_3\t0\t0\t0\t0\t0\t0\tA maximum of %d characters can be created per account.\t0",
		"1\tUIO_MSG_ERROR_SEVER_CONNECT\t0\t0\t0\t0\t0\t0\tNo connection.\t0",
		"1\tUIO_SMERR_NOT_ALLOWED_CHARNAME\t0\t0\t0\t0\t0\t0\tLine one\\nline two\t0",
	])
	return "\n".join(rows).to_utf16_buffer()

## Round 682's review: an unanswered list is reported once, LIST_TIMEOUT_MS
## after it was sent, and never once it is answered. NEGATIVE: before the
## review LobbyNet.ListWatch does not exist and this suite does not parse.
func _test_list_watch() -> void:
	var w := LobbyNet.ListWatch.new()
	_check(not w.expired(100000), "nothing armed: nothing expires")
	w.arm(1000)
	_check(w.pending() and not w.expired(1000 + LobbyNet.LIST_TIMEOUT_MS - 1), "armed: not expired a millisecond early")
	_check(w.expired(1000 + LobbyNet.LIST_TIMEOUT_MS), "expired on time")
	_check(not w.expired(1000 + 2 * LobbyNet.LIST_TIMEOUT_MS), "reported once, not again")
	w.arm(50000)
	w.answered()
	_check(not w.expired(50000 + 10 * LobbyNet.LIST_TIMEOUT_MS), "an answered list never expires")
	_check(LobbyNet.LIST_TIMEOUT_MS == 5000 and LobbyNet.LIST_TIMEOUT_TEXT.contains("may need updating"), "5 s, and the words say what to do")

func _init() -> void:
	_test_golden()
	_test_words()
	_test_list_watch()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
