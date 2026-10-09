extends SceneTree

## Exercises WorldNet's encoding, run headless:
## `godot4 --headless --path client --script res://scripts/net/world_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_encode_enter_world() -> void:
	var encoded := WorldNet.encode_enter_world("Aria")
	_check(encoded.decode_u16(0) == 4, "name length prefix is 4")
	_check(encoded.slice(2, 6).get_string_from_utf8() == "Aria", "name bytes follow prefix")

func _test_encode_move() -> void:
	var encoded := WorldNet.encode_move(1.5, -2.5, 100.0)
	_check(encoded.size() == 12, "move payload is 12 bytes (got %d)" % encoded.size())
	_check(encoded.decode_float(0) == 1.5, "x round-trips")
	_check(encoded.decode_float(4) == -2.5, "y round-trips")
	_check(encoded.decode_float(8) == 100.0, "z round-trips")

## Hand-builds an OpEnterWorldResult payload matching
## server/internal/session's encoding.
func _build_enter_world_result(ok: bool, reason: String, zone: String, x: float, y: float, z: float, own_gender: String, others: Array, hp: int = 0, max_hp: int = 0) -> PackedByteArray:
	var out := PackedByteArray([1 if ok else 0])
	var reason_bytes := reason.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, reason_bytes.size())
	out.append_array(len_buf)
	out.append_array(reason_bytes)
	if not ok:
		return out

	var zone_bytes := zone.to_utf8_buffer()
	len_buf.encode_u16(0, zone_bytes.size())
	out.append_array(len_buf)
	out.append_array(zone_bytes)

	var pos_buf := PackedByteArray()
	pos_buf.resize(12)
	pos_buf.encode_float(0, x)
	pos_buf.encode_float(4, y)
	pos_buf.encode_float(8, z)
	out.append_array(pos_buf)

	var own_gender_bytes := own_gender.to_utf8_buffer()
	len_buf.encode_u16(0, own_gender_bytes.size())
	out.append_array(len_buf)
	out.append_array(own_gender_bytes)

	# Vitals sit between the gender field and the entity list, so getting
	# their width wrong desyncs everything after them.
	var vitals := PackedByteArray()
	vitals.resize(8)
	vitals.encode_s32(0, hp)
	vitals.encode_s32(4, max_hp)
	out.append_array(vitals)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, others.size())
	out.append_array(count_buf)

	for o in others:
		var id_buf := PackedByteArray()
		id_buf.resize(8)
		id_buf.encode_s64(0, o["id"])
		out.append_array(id_buf)
		var oname_bytes: PackedByteArray = o["name"].to_utf8_buffer()
		len_buf.encode_u16(0, oname_bytes.size())
		out.append_array(len_buf)
		out.append_array(oname_bytes)
		var opos_buf := PackedByteArray()
		opos_buf.resize(12)
		opos_buf.encode_float(0, o["x"])
		opos_buf.encode_float(4, o["y"])
		opos_buf.encode_float(8, o["z"])
		out.append_array(opos_buf)
		var worn: Dictionary = o.get("equipped", {})
		out.append(worn.size())
		for slot in worn:
			out.append(int(slot))
			var item_buf := PackedByteArray()
			item_buf.resize(8)
			item_buf.encode_s64(0, int(worn[slot]))
			out.append_array(item_buf)
		var ogender_bytes: PackedByteArray = String(o.get("gender", "")).to_utf8_buffer()
		len_buf.encode_u16(0, ogender_bytes.size())
		out.append_array(len_buf)
		out.append_array(ogender_bytes)

	return out

func _test_decode_enter_world_result_success() -> void:
	var payload := _build_enter_world_result(true, "", "jangan", 1.0, 2.0, 3.0, CharacterNet.GENDER_CHINA_MAN, [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "equipped": {EquipmentNet.SLOT_HELM: 4734, EquipmentNet.SLOT_BOOTS: 4950, EquipmentNet.SLOT_WEAPON: 3632, EquipmentNet.SLOT_SHIELD: 3639}, "gender": CharacterNet.GENDER_CHINA_WOMAN}], 73, 100)
	var result := WorldNet.decode_enter_world_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")
	_check(result.zone == "jangan", "zone round-trips")
	_check(result.x == 1.0 and result.y == 2.0 and result.z == 3.0, "position round-trips")
	_check(result.gender == CharacterNet.GENDER_CHINA_MAN, "own gender round-trips")
	_check(result.hp == 73 and result.max_hp == 100, "vitals round-trip (got %d/%d)" % [result.hp, result.max_hp])
	_check(result.others.size() == 1, "one other entity (got %d)" % result.others.size())
	if result.others.size() == 1:
		_check(result.others[0].character_id == 42, "other's character_id round-trips")
		_check(result.others[0].char_name == "Bram", "other's name round-trips")
		_check(result.others[0].x == 4.0, "other's x round-trips")
		_check(result.others[0].equipped.size() == 4, "other's four worn slots round-trip (got %d)" % result.others[0].equipped.size())
		_check(result.others[0].item_in(EquipmentNet.SLOT_HELM) == 4734, "the helm's item id round-trips (got %d)" % result.others[0].item_in(EquipmentNet.SLOT_HELM))
		_check(result.others[0].item_in(EquipmentNet.SLOT_WEAPON) == 3632, "the weapon's item id round-trips")
		_check(result.others[0].item_in(EquipmentNet.SLOT_MAIL) == 0, "an empty slot reads as item 0")
		_check(result.others[0].gender == CharacterNet.GENDER_CHINA_WOMAN, "other's gender round-trips")

func _test_decode_enter_world_result_failure() -> void:
	var payload := _build_enter_world_result(false, "no such character", "", 0, 0, 0, "", [])
	var result := WorldNet.decode_enter_world_result(payload)
	_check(result.error == "", "no decode error")
	_check(not result.ok, "ok is false")
	_check(result.reason == "no such character", "reason round-trips")

func _test_decode_entity_entered() -> void:
	var payload := _build_enter_world_result(true, "", "z", 0, 0, 0, "", [{"id": 7, "name": "Bram", "x": 1.0, "y": 2.0, "z": 3.0, "equipped": {EquipmentNet.SLOT_MAIL: 4842, EquipmentNet.SLOT_SHIELD: 3639}, "gender": CharacterNet.GENDER_CHINA_MAN}])
	# _build_enter_world_result wraps a single EntitySnapshot the same way
	# OpEntityEntered's payload is just one bare EntitySnapshot -- slice off
	# the EnterWorldResult framing in front of it (ok byte + empty reason +
	# zone + position + own-gender + vitals + count) to get just that
	# snapshot's bytes.
	var snapshot_start := 1 + 2 + 0 + 2 + 1 + 12 + 2 + 8 + 2
	var entered := WorldNet.decode_entity_entered(payload.slice(snapshot_start))
	_check(entered != null, "decodes successfully")
	if entered != null:
		_check(entered.character_id == 7, "character_id round-trips")
		_check(entered.char_name == "Bram", "name round-trips")
		_check(entered.item_in(EquipmentNet.SLOT_MAIL) == 4842, "the mail's item id round-trips (got %d)" % entered.item_in(EquipmentNet.SLOT_MAIL))
		_check(entered.item_in(EquipmentNet.SLOT_WEAPON) == 0, "no weapon reads as item 0")
		_check(entered.item_in(EquipmentNet.SLOT_SHIELD) == 3639, "the shield's item id round-trips")
		_check(entered.gender == CharacterNet.GENDER_CHINA_MAN, "gender round-trips")

	var unarmored := _build_enter_world_result(true, "", "z", 0, 0, 0, "", [{"id": 8, "name": "Aria", "x": 0.0, "y": 0.0, "z": 0.0, "equipped": {EquipmentNet.SLOT_WEAPON: 3632}, "gender": CharacterNet.GENDER_CHINA_WOMAN}])
	var entered2 := WorldNet.decode_entity_entered(unarmored.slice(snapshot_start))
	_check(entered2 != null and entered2.equipped.size() == 1, "second entity wears one thing")
	_check(entered2 != null and entered2.item_in(EquipmentNet.SLOT_WEAPON) == 3632, "second entity's weapon round-trips")
	_check(entered2 != null and entered2.item_in(EquipmentNet.SLOT_SHIELD) == 0, "second entity's empty shield slot reads 0")
	_check(entered2 != null and entered2.gender == CharacterNet.GENDER_CHINA_WOMAN, "second entity's gender round-trips")

func _test_decode_entity_moved() -> void:
	var buf := PackedByteArray()
	buf.resize(20)
	buf.encode_s64(0, 7)
	buf.encode_float(8, 1.0)
	buf.encode_float(12, 2.0)
	buf.encode_float(16, 3.0)
	var m := WorldNet.decode_entity_moved(buf)
	_check(m != null, "decodes successfully")
	if m != null:
		_check(m.character_id == 7, "character_id round-trips")
		_check(m.x == 1.0 and m.y == 2.0 and m.z == 3.0, "position round-trips")

func _test_decode_entity_left() -> void:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_s64(0, 99)
	_check(WorldNet.decode_entity_left(buf) == 99, "character_id round-trips")

func _test_encode_change_zone() -> void:
	var encoded := WorldNet.encode_change_zone("100/100")
	_check(encoded.decode_u16(0) == 7, "zone length prefix is 7")
	_check(encoded.slice(2, 9).get_string_from_utf8() == "100/100", "zone bytes follow prefix")
	_check(encoded.size() == 9, "no spot, no trailing bytes")
	# Round 764: the zone box's spot rides as two trailing f32s (the server's
	# ChangeZoneRequest.Spot), and an older server's refusal of them sends the
	# request again without it, the refusal not passed on.
	var spotted := WorldNet.encode_change_zone("97/168", Vector2(969, 1369))
	_check(spotted.size() == 2 + 6 + 8 and is_equal_approx(spotted.decode_float(8), 969.0) and is_equal_approx(spotted.decode_float(12), 1369.0),
		"r764: the spot follows the zone as two f32s")
	var nc = load("res://scripts/net/net_client.gd").new()
	var results: Array = []
	nc.set("_zone_spot_retry", "97/168")
	nc.change_zone_result.connect(func(r): results.append(r))
	# Unconnected, the resend itself only reports "not connected".
	var refused := _build_change_zone_result(false, "malformed request", "", 0, 0, 0)
	nc._dispatch(Packet.new(WorldNet.OP_CHANGE_ZONE_RESULT, refused))
	_check(results.is_empty() and String(nc.get("_zone_spot_retry")) == "",
		"r764: an older server's 'malformed request' to a spotted change is not passed on (it is sent again plain)")
	nc._dispatch(Packet.new(WorldNet.OP_CHANGE_ZONE_RESULT, refused))
	_check(results.size() == 1, "r764: ... and a refusal with no spot pending is passed on")
	nc.free()

## Hand-builds an OpChangeZoneResult payload matching
## server/internal/session's encoding.
func _build_change_zone_result(ok: bool, reason: String, zone: String, x: float, y: float, z: float, others: Array = []) -> PackedByteArray:
	var out := PackedByteArray([1 if ok else 0])
	var reason_bytes := reason.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, reason_bytes.size())
	out.append_array(len_buf)
	out.append_array(reason_bytes)
	if not ok:
		return out

	var zone_bytes := zone.to_utf8_buffer()
	len_buf.encode_u16(0, zone_bytes.size())
	out.append_array(len_buf)
	out.append_array(zone_bytes)

	var pos_buf := PackedByteArray()
	pos_buf.resize(12)
	pos_buf.encode_float(0, x)
	pos_buf.encode_float(4, y)
	pos_buf.encode_float(8, z)
	out.append_array(pos_buf)

	var count_buf := PackedByteArray()
	count_buf.resize(2)
	count_buf.encode_u16(0, others.size())
	out.append_array(count_buf)

	for o in others:
		var id_buf := PackedByteArray()
		id_buf.resize(8)
		id_buf.encode_s64(0, o["id"])
		out.append_array(id_buf)
		var oname_bytes: PackedByteArray = o["name"].to_utf8_buffer()
		len_buf.encode_u16(0, oname_bytes.size())
		out.append_array(len_buf)
		out.append_array(oname_bytes)
		var opos_buf := PackedByteArray()
		opos_buf.resize(12)
		opos_buf.encode_float(0, o["x"])
		opos_buf.encode_float(4, o["y"])
		opos_buf.encode_float(8, o["z"])
		out.append_array(opos_buf)
		var worn: Dictionary = o.get("equipped", {})
		out.append(worn.size())
		for slot in worn:
			out.append(int(slot))
			var item_buf := PackedByteArray()
			item_buf.resize(8)
			item_buf.encode_s64(0, int(worn[slot]))
			out.append_array(item_buf)
		var ogender_bytes: PackedByteArray = String(o.get("gender", "")).to_utf8_buffer()
		len_buf.encode_u16(0, ogender_bytes.size())
		out.append_array(len_buf)
		out.append_array(ogender_bytes)

	return out

func _test_decode_change_zone_result_success() -> void:
	var payload := _build_change_zone_result(true, "", "100/100", 1.0, 2.0, 3.0, [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "gender": CharacterNet.GENDER_CHINA_MAN}])
	var result := WorldNet.decode_change_zone_result(payload)
	_check(result.error == "", "no decode error")
	_check(result.ok, "ok is true")
	_check(result.zone == "100/100", "zone round-trips")
	_check(result.x == 1.0 and result.y == 2.0 and result.z == 3.0, "position round-trips")
	_check(result.others.size() == 1, "one other entity (got %d)" % result.others.size())
	if result.others.size() == 1:
		_check(result.others[0].character_id == 42, "other's character_id round-trips")
		_check(result.others[0].char_name == "Bram", "other's name round-trips")

## Round 570: the server names the coordinate frame. FrameRegion is a
## u16-prefixed "x/y" string trailing the entity list
## (server/internal/session/world.go's EnterWorldResult/ChangeZoneResult);
## a payload that ends at the list -- every server before round 570 -- decodes
## with frame "", and one cut inside the field is a decode error. The frame is
## read through get(), so a WorldNet without the field FAILS here rather than
## failing to parse (before round 570 there is no `frame` and every row below
## fails).
func _with_frame(payload: PackedByteArray, frame: String) -> PackedByteArray:
	var frame_bytes := frame.to_utf8_buffer()
	var len_buf := PackedByteArray()
	len_buf.resize(2)
	len_buf.encode_u16(0, frame_bytes.size())
	return payload + len_buf + frame_bytes

func _frame_of(result: Object) -> String:
	var frame = result.get("frame")
	return frame if frame is String else "<no frame property>"

func _test_decode_frame_region() -> void:
	var others := [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "gender": CharacterNet.GENDER_CHINA_MAN}]
	var zone_legacy := _build_change_zone_result(true, "", "jangan", 0.0, 0.0, 0.0, others)
	var zone_framed := WorldNet.decode_change_zone_result(_with_frame(zone_legacy, "97/168"))
	_check(zone_framed.error == "", "a ChangeZoneResult with a trailing frame decodes (error '%s')" % zone_framed.error)
	_check(_frame_of(zone_framed) == "97/168", "its frame is 97/168 (got %s)" % _frame_of(zone_framed))
	_check(zone_framed.zone == "jangan" and zone_framed.others.size() == 1 and zone_framed.others[0].char_name == "Bram",
		"and everything before the frame reads as it did")
	var zone_old := WorldNet.decode_change_zone_result(zone_legacy)
	_check(zone_old.error == "" and zone_old.others.size() == 1, "an older server's ChangeZoneResult still decodes")
	_check(_frame_of(zone_old) == "", "with frame \"\" (got %s)" % _frame_of(zone_old))
	var zone_cut := zone_legacy + PackedByteArray([0x06, 0x00]) + "97/1".to_utf8_buffer()
	_check(WorldNet.decode_change_zone_result(zone_cut).error == "truncated frame", "a frame cut short is a decode error")
	_check(WorldNet.decode_change_zone_result(zone_legacy + PackedByteArray([0x06])).error == "truncated frame length",
		"one stray byte after the list is a decode error")

	var enter_legacy := _build_enter_world_result(true, "", "jangan", 0.0, 0.0, 0.0, CharacterNet.GENDER_CHINA_MAN, others, 73, 100)
	var enter_framed := WorldNet.decode_enter_world_result(_with_frame(enter_legacy, "97/168"))
	_check(enter_framed.error == "" and _frame_of(enter_framed) == "97/168",
		"an EnterWorldResult's trailing frame decodes to 97/168 (got %s, error '%s')" % [_frame_of(enter_framed), enter_framed.error])
	_check(enter_framed.hp == 73 and enter_framed.max_hp == 100 and enter_framed.others.size() == 1, "and its vitals and list read as before")
	var enter_old := WorldNet.decode_enter_world_result(enter_legacy)
	_check(enter_old.error == "" and _frame_of(enter_old) == "", "an older server's EnterWorldResult decodes with frame \"\" (got %s)" % _frame_of(enter_old))

	# A refusal carries no frame, as it carries no zone.
	var refused := WorldNet.decode_change_zone_result(_build_change_zone_result(false, "already in that zone", "", 0, 0, 0))
	_check(refused.error == "" and _frame_of(refused) == "", "a refusal has frame \"\"")

## Round 573: a restored entry. Restored is ONE byte after the frame
## (server/internal/session/world.go's EnterWorldResult.Restored), sent only
## when the server read the position back from the character's row; a payload
## that ends at the frame -- every other entry, and every older server's --
## decodes as not restored, and so does one that ends at the list. The flag is
## read through get(), so a WorldNet without it FAILS here rather than failing
## to parse (before round 573 every restored row below fails).
func _restored_of(result: Object) -> String:
	var restored = result.get("restored")
	return str(restored) if restored is bool else "<no restored property>"

func _test_decode_restored() -> void:
	var others := [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "gender": CharacterNet.GENDER_CHINA_MAN}]
	var legacy := _build_enter_world_result(true, "", "jangan", 100.0, 0.0, -200.0, CharacterNet.GENDER_CHINA_MAN, others, 73, 100)
	var framed := _with_frame(legacy, "97/168")

	var restored := WorldNet.decode_enter_world_result(framed + PackedByteArray([0x01]))
	_check(restored.error == "" and _restored_of(restored) == "true",
		"a trailing 0x01 after the frame decodes as restored (got %s, error '%s')" % [_restored_of(restored), restored.error])
	_check(restored.frame == "97/168" and restored.x == 100.0 and restored.z == -200.0 and restored.zone == "jangan",
		"and the frame, zone and position before it read as they did")
	_check(restored.hp == 73 and restored.others.size() == 1 and restored.others[0].char_name == "Bram",
		"and the vitals and the list too")

	var not_restored := WorldNet.decode_enter_world_result(framed)
	_check(not_restored.error == "" and _restored_of(not_restored) == "false",
		"a payload that ends at the frame is not restored (got %s)" % _restored_of(not_restored))
	var zero := WorldNet.decode_enter_world_result(framed + PackedByteArray([0x00]))
	_check(zero.error == "" and _restored_of(zero) == "false", "a trailing 0x00 is not restored (got %s)" % _restored_of(zero))
	var old := WorldNet.decode_enter_world_result(legacy)
	_check(old.error == "" and _restored_of(old) == "false",
		"an older server's payload, ending at the list, is not restored (got %s)" % _restored_of(old))
	var refused := WorldNet.decode_enter_world_result(_build_enter_world_result(false, "no such character", "", 0, 0, 0, "", []))
	_check(refused.error == "" and not refused.ok and _restored_of(refused) == "false", "a refusal is not restored")

func _test_decode_change_zone_result_failure() -> void:
	var payload := _build_change_zone_result(false, "already in that zone", "", 0, 0, 0)
	var result := WorldNet.decode_change_zone_result(payload)
	_check(result.error == "", "no decode error")
	_check(not result.ok, "ok is false")
	_check(result.reason == "already in that zone", "reason round-trips")

## Round 548: the player's own revive. OpRevive is empty; OpReviveResult is a
## u16-prefixed error, then s32 HP and s32 MP (docs/protocol/monster_ai.md,
## "The player's dead state", whose fixtures these bytes are).
func _test_encode_revive() -> void:
	_check(WorldNet.OP_REVIVE == 0x0028 and WorldNet.OP_REVIVE_RESULT == 0x0029, "the revive pair is 0x0028/0x0029")
	# Round 665: retail's option byte (FUN_00797d90 sends 0x3053 {u8}).
	_check(WorldNet.encode_revive(1) == PackedByteArray([1]), "option 1 (the return point) is the one byte 1")
	_check(WorldNet.encode_revive(2) == PackedByteArray([2]), "option 2 (the present point) is the one byte 2")

func _test_decode_revive_result() -> void:
	# Revived at 80 HP and 40 MP: 00 00 | 50 00 00 00 | 28 00 00 00.
	var revived := PackedByteArray([0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00])
	var r := WorldNet.decode_revive_result(revived)
	_check(r.error == "", "a revive has no error (got '%s')" % r.error)
	_check(r.hp == 80 and r.mp == 40, "HP and MP round-trip (got %d/%d)" % [r.hp, r.mp])

	# Refused: "not dead", and no tail after it.
	var refused := PackedByteArray([0x08, 0x00]) + "not dead".to_utf8_buffer()
	var f := WorldNet.decode_revive_result(refused)
	_check(f.error == "not dead", "a refusal carries the server's reason (got '%s')" % f.error)
	_check(f.hp == 0 and f.mp == 0, "and no pools")
	# A refusal with the tail the server may still write decodes the same.
	var refused_full := refused + PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
	_check(WorldNet.decode_revive_result(refused_full).error == "not dead", "a refusal with a zero tail is the same refusal")

	# Cut short: a success header with only half its vitals.
	var short := PackedByteArray([0x00, 0x00, 0x50, 0x00, 0x00, 0x00])
	_check(WorldNet.decode_revive_result(short).error == "truncated vitals", "a success cut inside its vitals is a decode error")
	_check(WorldNet.decode_revive_result(PackedByteArray([0x00])).error == "truncated", "one byte is a decode error")
	_check(WorldNet.decode_revive_result(PackedByteArray([0x09, 0x00]) + "not dead".to_utf8_buffer()).error == "truncated error field",
		"an error length past the payload is a decode error")

## Sitting (round 607): the retail opcodes and payloads, matching
## server/internal/session/motion.go (TestStateChangeLayout encodes the same
## six bytes).
func _test_motion() -> void:
	_check(WorldNet.OP_MOTION_REQUEST == 0x704F, "the motion request is the retail 0x704f")
	_check(WorldNet.OP_STATE_CHANGE == 0x30BF, "the state change is the retail 0x30bf")
	var req := WorldNet.encode_motion_request(WorldNet.MOTION_SIT)
	_check(req == PackedByteArray([4]), "N sends the one byte 4 (got %s)" % str(req))
	var sc := WorldNet.decode_state_change(PackedByteArray([0x04, 0x03, 0x02, 0x01, 0x01, 0x04]))
	_check(sc != null and sc.object_id == 0x01020304, "the id is a little-endian u32")
	_check(sc != null and sc.kind == WorldNet.STATE_KIND_MOTION and sc.value == WorldNet.MOTION_SIT, "kind 1, value 4")
	_check(WorldNet.decode_state_change(PackedByteArray([1, 2, 3, 4, 5])) == null, "a short payload decodes to null")
	_check(WorldNet.MOTION_CHANGE_SECONDS == 1.5, "the transition is .rdata 0x00b45c10 = 1.5")
	_check(BsrReader.AnimationEntry.TYPE_SIT_DOWN == 13 and BsrReader.AnimationEntry.TYPE_SITTING == 14 \
		and BsrReader.AnimationEntry.TYPE_STAND_UP == 15, "sit down / sitting / stand up are action types 13 / 14 / 15")

## The Seated tail (round 607): after an enter-world result's Restored byte and
## a zone-change result's frame, a u16 count and an s64 id per sitter --
## server/internal/session/world.go's encodeSeated, TestSeatedTailIsASuffix.
func _seated_tail(ids: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, ids.size())
	for id in ids:
		var b := PackedByteArray()
		b.resize(8)
		b.encode_s64(0, int(id))
		out.append_array(b)
	return out

func _frame_bytes(frame: String) -> PackedByteArray:
	var fb := frame.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, fb.size())
	out.append_array(fb)
	return out

func _test_decode_seated() -> void:
	var others := [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "gender": CharacterNet.GENDER_CHINA_MAN}]
	var enter := _build_enter_world_result(true, "", "jangan", 1.0, 2.0, 3.0, CharacterNet.GENDER_CHINA_MAN, others, 10, 20)
	enter.append_array(_frame_bytes("97/168"))
	var plain := WorldNet.decode_enter_world_result(enter)
	_check(plain.error == "" and plain.seated.is_empty(), "an enter-world result with no tail seats nobody")
	enter.append(0) # Restored, written as 0 when a Seated tail follows
	enter.append_array(_seated_tail([42]))
	var r := WorldNet.decode_enter_world_result(enter)
	_check(r.error == "" and not r.restored, "the tail decodes, Restored false (error %s)" % r.error)
	_check(r.seated == [42], "the enter-world result names Bram as seated (got %s)" % str(r.seated))
	var zone := _build_change_zone_result(true, "", "jangan", 0.0, 0.0, 0.0, others)
	zone.append_array(_frame_bytes("97/168"))
	zone.append_array(_seated_tail([42]))
	var z := WorldNet.decode_change_zone_result(zone)
	_check(z.error == "" and z.seated == [42], "the zone-change result names Bram as seated (got %s, error %s)" % [str(z.seated), z.error])
	var cut := zone.slice(0, zone.size() - 3)
	_check(WorldNet.decode_change_zone_result(cut).error != "", "a seated tail cut short is a decode error")

## The headings tail (round 637's review follow-up, "headings in the arrival
## lists"): after the Seated list -- always written when it follows, a zero
## count here -- a u16 count equal to the list's and a u16 wire angle per other
## (server/internal/session/world.go's encodeHeadings), then, on an enter-world
## result, this player's own. Wire angle 16384 is heading pi (the angle plus
## pi/2); 0 is pi/2.
func _u16s(values: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2 * values.size())
	for i in range(values.size()):
		out.encode_u16(2 * i, int(values[i]))
	return out

func _test_decode_headings() -> void:
	var others := [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "gender": CharacterNet.GENDER_CHINA_MAN}]
	var enter := _build_enter_world_result(true, "", "jangan", 1.0, 2.0, 3.0, CharacterNet.GENDER_CHINA_MAN, others, 10, 20)
	enter.append_array(_frame_bytes("97/168"))
	enter.append(0)
	enter.append_array(_seated_tail([]))
	enter.append_array(_u16s([1, 16384, 0]))
	var r := WorldNet.decode_enter_world_result(enter)
	_check(r.error == "" and r.others.size() == 1, "an enter-world result with a headings tail decodes (error %s)" % r.error)
	var h = r.others[0].get("heading") if r.others.size() == 1 else null
	_check(h != null and absf(float(h) - PI) < 1e-3, "Bram, standing there, faces heading pi (got %s)" % str(h))
	var own = r.get("heading")
	_check(own != null and absf(float(own) - PI / 2.0) < 1e-3, "and this player re-enters facing pi/2 (got %s)" % str(own))
	var zone := _build_change_zone_result(true, "", "jangan", 0.0, 0.0, 0.0, others)
	zone.append_array(_frame_bytes("97/168"))
	zone.append_array(_seated_tail([42]))
	zone.append_array(_u16s([1, 0]))
	var z := WorldNet.decode_change_zone_result(zone)
	var zh = z.others[0].get("heading") if z.others.size() == 1 else null
	_check(z.error == "" and z.seated == [42] and zh != null and absf(float(zh) - PI / 2.0) < 1e-3,
		"a zone-change result's tail seats Bram and faces him pi/2 (seated %s, heading %s, error %s)" % [str(z.seated), str(zh), z.error])
	var mismatched := zone.slice(0, zone.size() - 4)
	mismatched.append_array(_u16s([2, 0]))
	_check(WorldNet.decode_change_zone_result(mismatched).error != "", "a headings count that does not match the list is a decode error")
	# An older server's payload (no tail) leaves the heading unknown.
	var old := _build_change_zone_result(true, "", "jangan", 0.0, 0.0, 0.0, others)
	old.append_array(_frame_bytes("97/168"))
	var o := WorldNet.decode_change_zone_result(old)
	var oh = o.others[0].get("heading") if o.others.size() == 1 else 0.0
	_check(o.error == "" and oh != null and is_nan(float(oh)), "no tail: the heading stays unknown (NAN)")

## Round 689: the model tails, against testdata/world_model_golden.json -- the
## bytes the server's TestRound689ModelGolden encodes exactly.
func _test_decode_model_golden() -> void:
	var f := FileAccess.open("res://scripts/net/testdata/world_model_golden.json", FileAccess.READ)
	_check(f != null, "world_model_golden.json opens")
	if f == null:
		return
	var golden: Dictionary = JSON.parse_string(f.get_as_text())
	var seen := 0
	for v in golden["vectors"]:
		var data := String(v["hex"]).replace(" ", "").replace("|", "").hex_decode()
		var kind := String(v["kind"])
		var others: Array = []
		var own = null
		var err := ""
		if kind == "entity_entered":
			own = WorldNet.decode_entity_entered(data)
		elif kind == "enter_world_result":
			var r := WorldNet.decode_enter_world_result(data)
			own = r
			others = r.others
			err = r.error
		elif kind == "change_zone_result":
			var z := WorldNet.decode_change_zone_result(data)
			others = z.others
			err = z.error
		_check(err == "", "%s: decodes (error %s)" % [v["name"], err])
		if v.has("own"):
			_check(own != null and own.has_model and own.ref_obj_id == int(v["own"]["ref_obj_id"]) and own.scale == int(v["own"]["scale"]),
				"%s: own model %s" % [v["name"], str(v["own"])])
		var want: Array = v.get("others", [])
		_check(others.size() == want.size(), "%s: %d other(s)" % [v["name"], want.size()])
		for i in range(mini(others.size(), want.size())):
			var o: WorldNet.EntitySnapshot = others[i]
			_check(o.has_model and o.ref_obj_id == int(want[i]["ref_obj_id"]) and o.scale == int(want[i]["scale"]),
				"%s: other %d's model %d/%d" % [v["name"], i, o.ref_obj_id, o.scale])
		seen += 1
	_check(seen == 3, "three golden vectors (got %d)" % seen)
	# An older server's payload (no models tail) keeps has_model false, and a
	# models count that does not match the list is an error.
	var plain := _build_change_zone_result(true, "", "jangan", 0.0, 0.0, 0.0, [{"id": 42, "name": "Bram", "x": 4.0, "y": 5.0, "z": 6.0, "gender": CharacterNet.GENDER_CHINA_MAN}])
	plain.append_array(_frame_bytes("97/168"))
	plain.append_array(_seated_tail([]))
	plain.append_array(_u16s([1, 0]))
	var p := WorldNet.decode_change_zone_result(plain)
	_check(p.error == "" and p.others.size() == 1 and not p.others[0].has_model, "no models tail: no model")
	var bad := plain.duplicate()
	bad.append_array(_u16s([2]))
	bad.append_array(PackedByteArray([1, 0, 0, 0, 0x22]))
	_check(WorldNet.decode_change_zone_result(bad).error != "", "a models count that does not match the list is a decode error")

func _init() -> void:
	_test_decode_model_golden()
	_test_decode_seated()
	_test_decode_headings()
	_test_motion()
	_test_encode_enter_world()
	_test_encode_move()
	_test_decode_enter_world_result_success()
	_test_decode_enter_world_result_failure()
	_test_decode_entity_entered()
	_test_decode_entity_moved()
	_test_decode_entity_left()
	_test_encode_change_zone()
	_test_decode_change_zone_result_success()
	_test_decode_change_zone_result_failure()
	_test_decode_frame_region()
	_test_decode_restored()
	_test_encode_revive()
	_test_decode_revive_result()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
