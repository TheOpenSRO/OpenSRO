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
	_check(WorldNet.encode_revive().is_empty(), "an OpRevive request carries nothing")

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

func _init() -> void:
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
	_test_encode_revive()
	_test_decode_revive_result()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
