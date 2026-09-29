extends RefCounted
class_name CompositeNet

## The Energy of life scroll's grants (round 632 review, server
## session/composite.go). Using the scroll grants one use of the "Hwan
## regeneration fill" for an hour. Retail shows the grant as a buff-bar icon
## (kind 5 on CIFMagicStateBoard, the scroll's own icon with its time gauge),
## a left-click on it opens CIFCompositeItemWnd, and a button there sends
## 0x715F. srrevamp carries the same exchange on its own opcodes (OURS):
const OP_USE := 0x0104      # client -> server: spend one use of a granted item
const OP_USE_RESULT := 0x0105
const OP_LIST := 0x0106     # client -> server: which grants do I hold
const OP_STATE := 0x0107    # server -> client: the grants (reply and push)

## One running grant: the item it lets the player use, the uses left of the
## maximum, and the seconds it still runs.
class Grant extends RefCounted:
	var item_id: int = 0
	## The composite item that granted it (the scroll): the icon and the
	## gauge's total come from its row.
	var scroll_id: int = 0
	var remaining: int = 0
	var maximum: int = 0
	var seconds_left: int = 0

class State extends RefCounted:
	var grants: Array = []
	## The berserk-duration bonus in seconds, and how long it still runs.
	var bonus_seconds: int = 0
	var bonus_seconds_left: int = 0

class UseResult extends RefCounted:
	var error: String = ""
	var item_id: int = 0
	var remaining: int = 0
	var berserk_gauge: int = 0
	var berserk_active: bool = false

static func _name(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

static func encode_use(character_name: String, item_id: int) -> PackedByteArray:
	var out := _name(character_name)
	var tail := PackedByteArray()
	tail.resize(8)
	tail.encode_s64(0, item_id)
	out.append_array(tail)
	return out

static func encode_list(character_name: String) -> PackedByteArray:
	return _name(character_name)

static func decode_use_result(data: PackedByteArray) -> UseResult:
	var r := UseResult.new()
	if data.size() < 2:
		r.error = "truncated"
		return r
	var n := data.decode_u16(0)
	var off := 2 + n
	if off + 17 > data.size():
		r.error = "truncated"
		return r
	r.error = data.slice(2, off).get_string_from_utf8()
	r.item_id = data.decode_s64(off)
	r.remaining = data.decode_s32(off + 8)
	r.berserk_gauge = data.decode_s32(off + 12)
	r.berserk_active = data[off + 16] != 0
	return r

static func decode_state(data: PackedByteArray) -> State:
	var s := State.new()
	if data.size() < 2:
		return s
	var n := data.decode_u16(0)
	if data.size() < 2 + n * 28 + 8:
		return s
	for i in n:
		var o := 2 + i * 28
		var g := Grant.new()
		g.item_id = data.decode_s64(o)
		g.scroll_id = data.decode_s64(o + 8)
		g.remaining = data.decode_s32(o + 16)
		g.maximum = data.decode_s32(o + 20)
		g.seconds_left = data.decode_s32(o + 24)
		s.grants.append(g)
	var t := 2 + n * 28
	s.bonus_seconds = data.decode_s32(t)
	s.bonus_seconds_left = data.decode_s32(t + 4)
	return s
