extends SceneTree

## Round 789: AvatarNet against the golden bytes the Go server is held to.
## Every vector of testdata/avatar_golden.json -- written by hand from the
## READ layouts (AVATAR_RESEARCH.md, AVATAR_ALCHEMY_RESEARCH.md) -- is
## encoded from its fields and must equal its hex, and decoded from its hex
## and must equal its fields; a vector marked "error" must fail to decode.
## The server's avatar tests (lane AS) run the same file.
##
## NEGATIVE: before round 789 AvatarNet does not exist and this suite does
## not parse; user_spawn.gd refused any avatar in a player record.

const GOLDEN := "res://scripts/net/testdata/avatar_golden.json"

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

## A golden item's fields -> an ItemInstance (mag params [id, value] pairs).
static func _instance(f: Dictionary) -> ItemInstance:
	var it := ItemInstance.new()
	it.ref_item_id = int(f["ref"])
	it.opt_level = int(f.get("opt_level", 0))
	it.variance = int(f.get("variance", 0))
	it.durability = int(f.get("durability", 0))
	for p in f.get("mag_params", []):
		it.mag_params.append(int(p[0]) | (int(p[1]) << 32))
	return it

static func _same_instance(a: ItemInstance, b: ItemInstance) -> bool:
	return a != null and b != null and a.ref_item_id == b.ref_item_id and a.opt_level == b.opt_level \
		and a.variance == b.variance and a.durability == b.durability and a.mag_params == b.mag_params

func _test_golden() -> void:
	var text := FileAccess.get_file_as_string(GOLDEN)
	_check(text != "", "the golden file is readable at " + GOLDEN)
	var doc = JSON.parse_string(text)
	_check(doc is Dictionary, "the golden file parses")
	if not (doc is Dictionary):
		return
	var ops: Dictionary = doc["opcodes"]
	_check(int(ops["item_move"]) == AvatarNet.OP_ITEM_MOVE and int(ops["item_move_ack"]) == AvatarNet.OP_ITEM_MOVE_ACK
		and int(ops["equip_broadcast"]) == AvatarNet.OP_EQUIP_BROADCAST and int(ops["unequip_broadcast"]) == AvatarNet.OP_UNEQUIP_BROADCAST
		and int(ops["avatar_grant"]) == AvatarNet.OP_GRANT and int(ops["avatar_grant_ack"]) == AvatarNet.OP_GRANT_ACK
		and int(ops["avatar_list_request"]) == AvatarNet.OP_LIST_REQUEST and int(ops["avatar_list"]) == AvatarNet.OP_LIST,
		"the opcodes are 0x7034/0xB034, 0x3038/0x3039, 0x34A9/0x34AA, 0x0044/0x0045")
	var played := 0

	for v in doc["move_requests"]:
		played += 1
		var want := _bytes(v["hex"])
		var got := AvatarNet.decode_move(want)
		if v.get("error", false):
			_check(got.has("error"), "move request %s: refused (%s)" % [v["name"], got.get("error", "")])
			continue
		var f: Dictionary = v["fields"]
		var enc := AvatarNet.encode_move(int(f["type"]), int(f["src"]), int(f["dst"]))
		_check(enc == want, "move request %s: encodes (got %s, want %s)" % [v["name"], enc.hex_encode(), want.hex_encode()])
		_check(not got.has("error") and got["type"] == int(f["type"]) and got["src"] == int(f["src"]) and got["dst"] == int(f["dst"]),
			"move request %s: decodes to its fields" % v["name"])
		# The two senders the windows call produce the same bytes.
		if int(f["type"]) == AvatarNet.TYPE_BAG_TO_AVATAR:
			_check(AvatarNet.encode_equip(int(f["src"]) - 13, int(f["dst"])) == want, "move request %s: encode_equip(bag index) matches" % v["name"])
		else:
			_check(AvatarNet.encode_unequip(int(f["src"]), int(f["dst"]) - 13) == want, "move request %s: encode_unequip(bag index) matches" % v["name"])

	for v in doc["move_acks"]:
		played += 1
		var want := _bytes(v["hex"])
		var got := AvatarNet.decode_move_ack(want)
		if v.get("error", false):
			_check(got.has("error"), "move ack %s: refused (%s)" % [v["name"], got.get("error", "")])
			continue
		var f: Dictionary = v["fields"]
		var enc := AvatarNet.encode_move_ack(f)
		_check(enc == want, "move ack %s: encodes (got %s, want %s)" % [v["name"], enc.hex_encode(), want.hex_encode()])
		var same: bool = not got.has("error") and bool(got["ok"]) == bool(f["ok"])
		if same and bool(f["ok"]):
			same = got["type"] == int(f["type"]) and got["src"] == int(f["src"]) and got["dst"] == int(f["dst"]) \
				and got["qty"] == int(f["qty"]) and (got["subs"] as Array).size() == (f["subs"] as Array).size()
			for i in mini((got["subs"] as Array).size(), (f["subs"] as Array).size()):
				var gs: Dictionary = got["subs"][i]
				var fs: Dictionary = f["subs"][i]
				same = same and gs["type"] == int(fs["type"]) and gs["src"] == int(fs["src"]) and gs["dst"] == int(fs["dst"]) and gs["qty"] == int(fs["qty"])
			_check(AvatarNet.is_move_ack(want), "move ack %s: recognised as an avatar move's success" % v["name"])
		elif same:
			same = got["code"] == int(f["code"])
		_check(same, "move ack %s: decodes to its fields (%s)" % [v["name"], str(got)])

	for v in doc["broadcasts"]:
		played += 1
		var op := int(v["opcode"])
		var want := _bytes(v["hex"])
		var f: Dictionary = v["fields"]
		var enc := AvatarNet.encode_broadcast(op, f)
		_check(enc == want, "broadcast %s: encodes (got %s, want %s)" % [v["name"], enc.hex_encode(), want.hex_encode()])
		var got := AvatarNet.decode_broadcast(want, op)
		var same: bool = not got.is_empty() and got["uid"] == int(f["uid"]) and got["slot"] == int(f["slot"]) and got["ref"] == int(f["ref"])
		if op == AvatarNet.OP_EQUIP_BROADCAST:
			same = same and got["plus"] == int(f["plus"])
		_check(same, "broadcast %s: decodes to its fields" % v["name"])
		# The existing equipment reader takes the same bytes (NetClient's one
		# dispatch for both): the avatar branch is World3D's, by the ref's type.
		var eb := EquipmentNet.decode_broadcast(want)
		_check(eb != null and eb.uid == int(f["uid"]) and eb.ref_item_id == int(f["ref"]),
			"broadcast %s: EquipmentNet reads the same uid and ref" % v["name"])

	# The spawn block's plus byte follows only a 3/1/13 or 3/1/14 id; every
	# id in the golden is an avatar (test values).
	var avatar := func(_id: int) -> bool: return true
	for v in doc["spawn_avatar_blocks"]:
		played += 1
		var want := _bytes(v["hex"])
		var f: Dictionary = v["fields"]
		var items: Array = []
		for it in f["items"]:
			items.append({"id": int(it["ref"]), "plus": int(it["plus"])})
		var enc := AvatarNet.encode_spawn_block(int(f["size"]), items, avatar)
		_check(enc == want, "spawn block %s: encodes (got %s, want %s)" % [v["name"], enc.hex_encode(), want.hex_encode()])
		var r := NpcSpawnNet.Reader.new(want)
		var got := AvatarNet.read_spawn_block(r, avatar)
		var same: bool = r.error == "" and r.pos == want.size() and got.size() == (f["items"] as Array).size()
		for i in mini(got.size(), (f["items"] as Array).size()):
			same = same and int(got[i]["id"]) == int(f["items"][i]["ref"]) and int(got[i]["plus"]) == int(f["items"][i]["plus"])
		_check(same, "spawn block %s: decodes to its fields (%s)" % [v["name"], str(got)])

	for v in doc["avatar_lists"]:
		played += 1
		var want := _bytes(v["hex"])
		var got := AvatarNet.decode_list(want)
		if v.get("error", false):
			_check(got.has("error"), "avatar list %s: refused (%s)" % [v["name"], got.get("error", "")])
			continue
		var f: Dictionary = v["fields"]
		var items := {}
		for it in f["items"]:
			items[int(it["slot"])] = _instance(it)
		var enc := AvatarNet.encode_list(int(f["size"]), items)
		_check(enc == want, "avatar list %s: encodes (got %s, want %s)" % [v["name"], enc.hex_encode(), want.hex_encode()])
		var same: bool = not got.has("error") and got["size"] == int(f["size"]) and (got["items"] as Dictionary).size() == items.size()
		for s in items:
			same = same and (got["items"] as Dictionary).has(s) and _same_instance(got["items"][s], items[s]) \
				and (got["items"][s] as ItemInstance).slot == int(s)
		_check(same, "avatar list %s: decodes to its fields" % v["name"])

	for v in doc["grant_requests"]:
		played += 1
		var want := _bytes(v["hex"])
		var got := AvatarNet.decode_grant(want)
		if v.get("error", false):
			_check(got.has("error"), "grant request %s: refused (%s)" % [v["name"], got.get("error", "")])
			continue
		var f: Dictionary = v["fields"]
		var enc := AvatarNet.encode_grant(int(f["slot"]) - 13, str(f["code"]))
		_check(enc == want, "grant request %s: encodes (got %s, want %s)" % [v["name"], enc.hex_encode(), want.hex_encode()])
		_check(not got.has("error") and got["slot"] == int(f["slot"]) and got["code"] == str(f["code"]),
			"grant request %s: decodes to its fields" % v["name"])

	for v in doc["grant_acks"]:
		played += 1
		var want := _bytes(v["hex"])
		var got := AvatarNet.decode_grant_ack(want)
		var f: Dictionary = v["fields"]
		var ff := f.duplicate()
		if f.has("item"):
			ff["item"] = _instance(f["item"])
		var enc := AvatarNet.encode_grant_ack(ff)
		_check(enc == want, "grant ack %s: encodes (got %s, want %s)" % [v["name"], enc.hex_encode(), want.hex_encode()])
		var same: bool = not got.has("error") and bool(got["ok"]) == bool(f["ok"])
		if same and bool(f["ok"]):
			same = got["flag"] == int(f["flag"]) and got["slot"] == int(f["slot"]) and _same_instance(got["item"], ff["item"]) \
				and (got["item"] as ItemInstance).slot == int(f["slot"]) - 13
		elif same:
			same = got["code"] == int(f["code"])
		_check(same, "grant ack %s: decodes to its fields (%s)" % [v["name"], str(got)])
	_check(played == 23, "all 23 vectors were played (%d)" % played)

## Beyond the golden: the spawn block reads a plus only for an avatar's id
## (READ c:0x9de3e2..0x9de4a1); the refusal lines name the client's keys.
func _test_rules() -> void:
	var only_avatars := func(id: int) -> bool: return id != 7
	var block := AvatarNet.encode_spawn_block(5, [{"id": 22912, "plus": 3}, {"id": 7, "plus": 9}], only_avatars)
	_check(block.size() == 2 + 5 + 4, "a non-avatar id in the block is written with no plus (%d bytes)" % block.size())
	var r := NpcSpawnNet.Reader.new(block)
	var got := AvatarNet.read_spawn_block(r, only_avatars)
	_check(r.pos == block.size() and got.size() == 2 and got[0]["plus"] == 3 and got[1]["plus"] == 0,
		"and read back with a plus for the avatar only (%s)" % str(got))
	var text := func(key: String, _f: String) -> String: return "<%s>" % key
	_check(AvatarNet.move_refusal_line(0x180e, text) == "<UIIT_MSG_STRGERR_EQUIPITEM>", "0x180e names STRGERR_EQUIPITEM")
	_check(AvatarNet.move_refusal_line(0x18f9, text) == "<UIIT_MSG_NASRUN_NOT_AWAKE_WEAR_ERROR>", "0x18f9 names NASRUN_NOT_AWAKE_WEAR_ERROR")
	_check(AvatarNet.move_refusal_line(0x1809, text).contains("0x1809"), "0x1809 (no name READ) keeps our own line")
	_check(AvatarNet.grant_refusal_line(6, text) == "<UIIT_MSG_AVATAR_MAGICOPTION_ADD_ERORR>", "grant code 6 names ADD_ERORR")
	_check(AvatarNet.grant_refusal_line(0xa, text) == "<UIIT_STT_AVATAR_MAGICOPTION_WRONG>", "grant code 0xa names WRONG")
	_check(AvatarNet.grant_refusal_line(2, text).contains("2"), "grant code 2 (the switch default) keeps our own line")
	_check(AvatarNet.encode_list_request("Ab") == PackedByteArray([2, 0, 0x41, 0x62]), "the list request names the character")

func _init() -> void:
	_test_golden()
	_test_rules()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
