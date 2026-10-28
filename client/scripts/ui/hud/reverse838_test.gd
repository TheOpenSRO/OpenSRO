extends SceneTree

## Round 838 (OURS): the special reverse return scroll's client half -- the
## five-destination box, the add-on list boxes, the saved-location wire and
## the use's options 4 and 5. No archive: the boxes build their stand-ins.
##   godot4 --headless --path client --script res://scripts/ui/hud/reverse838_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	# The plain box keeps retail's four buttons; the special one has six.
	var plain := ReverseReturnBox.new()
	plain.build(null, 3)
	_check(plain.member("PartyMember") == null and plain.member("SavedLocation") == null,
		"the plain scroll's box has no add-on buttons")
	_check(plain.box_size == ReverseReturnBox.SIZE, "the plain box keeps retail's 300 x 204")
	var special := ReverseReturnBox.new()
	special.build(null, 3, true)
	_check(special.member("PartyMember") != null and special.member("SavedLocation") != null,
		"the special scroll's box has the party and saved-location buttons")
	_check(special.caption_of("PartyMember") == "Move to a party member."
		and special.caption_of("SavedLocation") == "Move to a saved location.",
		"their captions are the add-on's texts")
	_check(special.box_size == ReverseReturnBox.SPECIAL_SIZE, "the special box is 300 x 266")
	var asked := []
	special.party_requested.connect(func() -> void: asked.append("party"))
	special.saved_requested.connect(func() -> void: asked.append("saved"))
	special.member("PartyMember").pressed.emit()
	special.member("SavedLocation").pressed.emit()
	_check(asked == ["party", "saved"], "the two buttons ask for their windows (%s)" % [asked])

	# A list box: one row a choice, the disabled ones disabled, Cancel last.
	var list := ReverseAddonBox.new()
	list.build_list(null, 3, "T", "Title", "M", "Message", [
		{"text": "1. Jangan", "enabled": true}, {"text": "2. Empty Slot", "enabled": false}])
	var r0 := list.find_child("Row0", true, false) as BaseButton
	var r1 := list.find_child("Row1", true, false) as BaseButton
	_check(r0 != null and not r0.disabled and r1 != null and r1.disabled, "rows built, an empty slot disabled")
	var picked := []
	list.row_chosen.connect(func(i: int) -> void: picked.append(i))
	r0.pressed.emit()
	_check(picked == [0], "a row reports its index")
	_check(list.box_size.y == 76 + 3 * 31 + 4, "the box grows a row at a time")

	# The wire: options 4 and 5 carry their u32, the saved-location request and
	# its answer.
	var use := UseItemNet.encode_use("Aria", 2, UseItemNet.OPTION_PARTY, 0x01020304)
	_check(use.size() == 2 + 4 + 8 + 1 + 4 and use[14] == 4 and use.decode_u32(15) == 0x01020304,
		"option 4 carries the member's JID")
	use = UseItemNet.encode_use("Aria", 2, UseItemNet.OPTION_SAVED, 2)
	_check(use[14] == 5 and use.decode_u32(15) == 2, "option 5 carries the slot")
	var req := UseItemNet.encode_reverse_saved(UseItemNet.SAVED_REGISTER, 2, 7)
	_check(req.size() == 10 and req[0] == 1 and req[1] == 2 and req.decode_s64(2) == 7, "the register request")
	var ans := PackedByteArray([1, 1, 0, 0, 2])
	var slot := PackedByteArray()
	slot.resize(16)
	slot.encode_s32(0, 25000)
	slot.encode_float(4, 700.0)
	slot.encode_float(8, 0.0)
	slot.encode_float(12, 400.0)
	ans.append_array(slot)
	ans.append_array(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	var d := UseItemNet.decode_reverse_saved(ans)
	_check(bool(d.get("ok")) and bool(d.get("registered")) and (d["slots"] as Array).size() == 2
		and int(d["slots"][0]["region"]) == 25000 and int(d["slots"][1]["region"]) == 0,
		"the answer's slots decode")
	_check(UseItemNet.decode_reverse_saved(PackedByteArray([1, 0])).is_empty(), "a short answer decodes to {}")

	for n in [plain, special, list]:
		n.free()
	print("ALL PASS" if _failures == 0 else "FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
