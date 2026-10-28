extends RefCounted
class_name CompositeNet

## The Energy of life scroll's grants (round 632 review, server
## session/composite.go). Using the scroll grants one use of the "Hwan
## regeneration fill" for an hour. Retail shows the grant as a buff-bar icon
## (kind 5 on CIFMagicStateBoard, the scroll's own icon with its time gauge),
## a left-click on it opens CIFCompositeItemWnd, and a button there sends
## 0x715F. OpenSRO carries the same exchange on its own opcodes (OURS):
const OP_USE := 0x0104      # client -> server: spend one use of a granted item
const OP_USE_RESULT := 0x0105
const OP_LIST := 0x0106     # client -> server: which grants do I hold
const OP_STATE := 0x0107    # server -> client: the grants (reply and push)
const OP_END := 0x0108      # server -> client: a grant ended (retail 0x315B)
## Round 838 (server session/goldtime.go, compositeextra.go), retail's own:
## the premium Gold Time's state (0x3206 {u8 3, u8 1, u32 ref, u32 period
## seconds left, u32 prev << 16 | today, u8 paused}; the end {3, 1, ref, 0,
## 0}; a refusal {3, 2, u16 code, u32 ref}), its pause request (0x34BF {u8 3,
## u8 pause}), and a BFI1 grant's start / refresh / end (0x315C / 0x315D
## {u32 key, u32 seconds, u32 decoration}, 0x315E {u32 key, u32 decoration}).
const OP_GOLD_TIME := 0x3206
const OP_GOLD_TIME_PAUSE := 0x34BF
const OP_BUFF_ITEM_START := 0x315C
const OP_BUFF_ITEM_REFRESH := 0x315D
const OP_BUFF_ITEM_END := 0x315E

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
	## A return scroll fill's casting delay (round 838), 0 for none.
	var cast_ms: int = 0

## The premium's state (round 838, OP_GOLD_TIME).
class GoldTime extends RefCounted:
	var sub: int = 0          # 1 state, 2 refusal
	var ref_id: int = 0
	var period_left: int = 0  # seconds
	var prev: int = 0         # seconds carried from the day before
	var today: int = 0        # seconds
	var paused: bool = false
	var ended: bool = false
	var code: int = 0         # a refusal's

static func _name(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

static func encode_use(character_name: String, item_id: int, option: int = 0, target: int = 0) -> PackedByteArray:
	var out := _name(character_name)
	var tail := PackedByteArray()
	tail.resize(8)
	tail.encode_s64(0, item_id)
	out.append_array(tail)
	# Round 838: a reverse return scroll fill's option (0x715f's u8 when not
	# 0) and, for the map option 7, the u32 refoptionalteleport id.
	if option != 0:
		out.append(option & 0xff)
		if option == UseItemNet.OPTION_MAP:
			var id := PackedByteArray()
			id.resize(4)
			id.encode_u32(0, target)
			out.append_array(id)
	return out

## OP_GOLD_TIME_PAUSE's body: {u8 3, u8 pause}.
static func encode_gold_time_pause(pause: bool) -> PackedByteArray:
	return PackedByteArray([3, 1 if pause else 0])

static func decode_gold_time(data: PackedByteArray) -> GoldTime:
	var g := GoldTime.new()
	if data.size() < 2 or data[0] != 3:
		return null
	g.sub = data[1]
	if g.sub == 2:
		if data.size() >= 8:
			g.code = data.decode_u16(2)
			g.ref_id = data.decode_u32(4)
		return g
	if data.size() < 14:
		return null
	g.ref_id = data.decode_u32(2)
	g.period_left = data.decode_u32(6)
	var halves := data.decode_u32(10)
	g.prev = halves >> 16
	g.today = halves & 0xffff
	g.ended = g.period_left == 0 and halves == 0
	g.paused = data.size() >= 15 and data[14] != 0
	return g

## OP_BUFF_ITEM_*: {key, seconds, decoration} (start / refresh) or {key,
## decoration} (end), as a Dictionary.
static func decode_buff_item(op: int, data: PackedByteArray) -> Dictionary:
	if op == OP_BUFF_ITEM_END:
		if data.size() < 8:
			return {}
		return {"key": data.decode_u32(0), "decoration": data.decode_u32(4), "ended": true}
	if data.size() < 12:
		return {}
	return {"key": data.decode_u32(0), "seconds": data.decode_u32(4), "decoration": data.decode_u32(8), "ended": false}

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
	if off + 21 <= data.size():
		r.cast_ms = data.decode_u32(off + 17)
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

## OP_END: {i64 item_id, i64 scroll_id}; [item_id, scroll_id], or [] when short.
static func decode_end(data: PackedByteArray) -> Array:
	if data.size() < 16:
		return []
	return [data.decode_s64(0), data.decode_s64(8)]
