extends RefCounted
class_name MallNet

## Round 837: the item mall on the retail wire (docs/protocol/item_mall_wire.md
## and its review item_mall_wire_verify.md; item_mall.md for the window). c:
## the client's addresses, READ unless marked.
##
##   C->S 0x7121 {u16 shop group word}            open (c:0x821d80, only when
##                                                 the stock table has rows)
##   S->C 0xB121 {u8 result, [u16 key, u8 n, n x {u32, u16}]}   (c:0x8a1360)
##   C->S 0x7034 {0x18, u16 group, u8 shop, u8 tab, u8 slot, str package code,
##                u16 count, u64 points, u32 package id}   (c:0x7923a0 case 0x18)
##   S->C 0xB034 {1, 0x18, u16 group, u8 shop, u8 tab, u8 slot, u8 n,
##                n x u8 bag slot, u16 count, n x rent block} | {2, u16 code}
##                (c:0x87f370 -> 0x87eb50; the rent block c:0x8bb130)
##   S->C 0x3153 {u32 silk, u32 gift silk, u32 point}   (c:0x882de0)
##   S->C 0x3154 {u8 reason, u8 cash type, u32 offset}   (c:0x882e50)
##   C->S 0x711a {u8 kind, u8 period}             silk history (c:0x7ecb90)
##   S->C 0xB11A {u8 kind, u8 ?, u8 result, [u16 n, n x {u32 amount, u32 date}]}
##                (c:0x8990c0)
##
## OURS, the item chest (not retail: item_mall.md "The Chest window"; the
## server's opcodes are its own, server/internal/session): a mall purchase
## with too few free bag slots goes to the chest, n = 0 in the 0xB034 above.
##   C->S 0x00D0 {}                    list
##   S->C 0x00D1 {u16 n, n x {u32 entry, u32 ref item, u32 count, str from, u32 date}}
##   C->S 0x00D2 {u32 entry}           take one (0 = take all)
##   S->C 0x00D3 {u8 result, u16 value}
##   C->S 0x00D4 {}                    the take log
##   S->C 0x00D5 {u16 n, n x {u32 ref item, u32 count, str from, u32 date, u32 taken}}
##   S->C 0x00D6 {u32 ref item, u32 count}   an item went into the chest

const OP_OPEN := 0x7121
const OP_OPEN_RESULT := 0xB121
const OP_ITEM_MOVE := 0x7034
const OP_SILK := 0x3153
const OP_SILK_CHANGED := 0x3154
const OP_HISTORY := 0x711a
const OP_HISTORY_RESULT := 0xB11A
const OP_CHEST_LIST := 0x00D0
const OP_CHEST_LIST_RESULT := 0x00D1
const OP_CHEST_TAKE := 0x00D2
const OP_CHEST_TAKE_RESULT := 0x00D3
const OP_CHEST_LOG := 0x00D4
const OP_CHEST_LOG_RESULT := 0x00D5
const OP_CHEST_RECEIVED := 0x00D6

const TYPE_BUY := 0x18
const BAG_OFFSET := 13
## 0x711a's kinds (c:0x7ecb90 sends 1, the Buying list); period 0xff cancels
## a pending inquiry (c:0x7eabe0, sm:0x413fc2).
const HISTORY_BUY := 1
const HISTORY_RECEIVE := 2
const HISTORY_CANCEL := 0xff

## A purchase as the request carries it (c:0x826460).
class Buy:
	var group := 0
	var shop_index := 0
	var tab := 0
	var slot := 0
	var package_code := ""
	var count := 1
	var points := 0
	var package_id := 0

static func encode_open(group: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, group)
	return b

## 0xB121: [ok]. The pairs update the stock table (INFERRED counts); this
## client keeps no stock table, so only the result is read.
static func decode_open_result(data: PackedByteArray) -> bool:
	return data.size() >= 1 and data[0] == 1

## 0x7034 type 0x18 (c:0x7923a0, 0x792944..0x79299d: the u64 is always sent).
static func encode_buy(b: Buy) -> PackedByteArray:
	var out := PackedByteArray([TYPE_BUY, 0, 0, b.shop_index & 0xff, b.tab & 0xff, b.slot & 0xff])
	out.encode_u16(1, b.group)
	var name := b.package_code.to_utf8_buffer()
	var n := PackedByteArray()
	n.resize(2)
	n.encode_u16(0, name.size())
	out.append_array(n)
	out.append_array(name)
	var tail := PackedByteArray()
	tail.resize(14)
	tail.encode_u16(0, b.count)
	tail.encode_u64(2, maxi(b.points, 0))
	tail.encode_u32(10, b.package_id)
	out.append_array(tail)
	return out

## 0xB034 for a mall buy: {"ok", "group", "shop", "tab", "slot", "slots"
## (0-based bag indexes), "count"}, or {"ok": false, "code"}; {} when it is
## not a mall reply (another move's, which the caller routes elsewhere).
## n = 0 in a success is OURS: the purchase went to the item chest.
static func decode_buy_result(data: PackedByteArray) -> Dictionary:
	if data.size() >= 2 and data[0] == 1 and data[1] == TYPE_BUY:
		if data.size() < 8:
			return {}
		var n: int = data[7]
		if data.size() < 8 + n + 2:
			return {}
		var slots: Array = []
		for i in n:
			slots.append(int(data[8 + i]) - BAG_OFFSET)
		return {"ok": true, "group": data.decode_u16(2), "shop": int(data[4]), "tab": int(data[5]),
			"slot": int(data[6]), "slots": slots, "count": data.decode_u16(8 + n), "chest": n == 0}
	return {}

static func decode_failure(data: PackedByteArray) -> int:
	return data.decode_u16(1) if data.size() >= 3 and data[0] == 2 else 0

## 0x3153: [silk, gift silk, point], each u32 (the server clamps negatives).
static func decode_silk(data: PackedByteArray) -> Array:
	if data.size() < 12:
		return []
	return [data.decode_u32(0), data.decode_u32(4), data.decode_u32(8)]

## 0x3154 (c:0x882e50): the text key by reason, the offset printed into it.
const SILK_REASON_KEYS := ["UIIT_STT_SILK_BUY_RESULT", "UIIT_STT_SILK_BUY_CANCLE", "UIIT_STT_SILK_BUY_RECEIVE",
	"UIIT_STT_SILK_SEND_RESULT", "UIIT_STT_SILK_POINT_BUY_RECEIVE", "UIIT_STT_SILK_POINT_USE_RECEIVE"]

static func decode_silk_changed(data: PackedByteArray) -> Dictionary:
	if data.size() < 6:
		return {}
	return {"reason": int(data[0]), "type": int(data[1]), "offset": data.decode_u32(2)}

static func encode_history(kind: int, period: int) -> PackedByteArray:
	return PackedByteArray([kind & 0xff, period & 0xff])

## 0xB11A: {"kind", "result", "rows": [[amount, date], ...]}.
static func decode_history(data: PackedByteArray) -> Dictionary:
	if data.size() < 3:
		return {}
	var out := {"kind": int(data[0]), "result": int(data[2]), "rows": []}
	if data[2] != 0 or data.size() < 5:
		return out
	var n := data.decode_u16(3)
	var at := 5
	for i in n:
		if at + 8 > data.size():
			break
		(out["rows"] as Array).append([data.decode_u32(at), data.decode_u32(at + 4)])
		at += 8
	return out

# --- the item chest (OURS) ----------------------------------------------------------

static func encode_chest_take(entry: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, entry)
	return b

static func _str(data: PackedByteArray, at: int) -> Array:
	if at + 2 > data.size():
		return ["", -1]
	var n := data.decode_u16(at)
	if at + 2 + n > data.size():
		return ["", -1]
	return [data.slice(at + 2, at + 2 + n).get_string_from_utf8(), at + 2 + n]

## 0x00D1: [{"entry", "item", "count", "from", "date"}, ...].
static func decode_chest_list(data: PackedByteArray) -> Array:
	var out: Array = []
	if data.size() < 2:
		return out
	var n := data.decode_u16(0)
	var at := 2
	for i in n:
		if at + 12 > data.size():
			break
		var e := {"entry": data.decode_u32(at), "item": data.decode_u32(at + 4), "count": data.decode_u32(at + 8)}
		var s := _str(data, at + 12)
		if int(s[1]) < 0 or int(s[1]) + 4 > data.size():
			break
		e["from"] = s[0]
		e["date"] = data.decode_u32(int(s[1]))
		at = int(s[1]) + 4
		out.append(e)
	return out

static func decode_chest_take(data: PackedByteArray) -> Dictionary:
	if data.size() < 3:
		return {}
	return {"ok": data[0] == 1, "value": data.decode_u16(1)}

## 0x00D5: [{"item", "count", "from", "date", "taken"}, ...].
static func decode_chest_log(data: PackedByteArray) -> Array:
	var out: Array = []
	if data.size() < 2:
		return out
	var n := data.decode_u16(0)
	var at := 2
	for i in n:
		if at + 8 > data.size():
			break
		var e := {"item": data.decode_u32(at), "count": data.decode_u32(at + 4)}
		var s := _str(data, at + 8)
		if int(s[1]) < 0 or int(s[1]) + 8 > data.size():
			break
		e["from"] = s[0]
		e["date"] = data.decode_u32(int(s[1]))
		e["taken"] = data.decode_u32(int(s[1]) + 4)
		at = int(s[1]) + 8
		out.append(e)
	return out

static func decode_chest_received(data: PackedByteArray) -> Dictionary:
	if data.size() < 8:
		return {}
	return {"item": data.decode_u32(0), "count": data.decode_u32(4)}
