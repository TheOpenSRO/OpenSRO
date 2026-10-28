extends RefCounted
class_name StallNet

## Round 839 (lane S): the players' stalls on the retail wire, mirroring
## server/internal/session/stall.go (docs/protocol/stall.md; c: the client's
## addresses, READ unless marked). Strings are a u16 length and the bytes
## (c:0x4fc870 / 0x53d880 write, 0x4f7a70 / 0x4fc700 read).
##
##   C->S 0x70B1 {str name}                    open (c:0x81df20)
##   S->C 0xB0B1 {1} | {2, u16}                (c:0x872040)
##   C->S 0x70B2 {}                            close, the owner (c:0x81e0d0)
##   S->C 0xB0B2 {1} | {2, u16}                (c:0x8720f0)
##   C->S 0x70B3 {u32 owner}                   enter (c:0x81e170)
##   S->C 0xB0B3 {1, u32 owner, str greeting, u8 open, u8 ?, list, u8 n, n x u32}  (c:0x873ff0)
##   C->S 0x70B4 {u8 slot}                     buy (c:0x81e2f0)
##   S->C 0xB0B4 {1, u8 slot} | {2, u16}       (c:0x872500)
##   C->S 0x70B5 {}                            leave, a visitor (c:0x81e250)
##   S->C 0xB0B5 {1} | {2, u16}                (c:0x872450)
##   C->S 0x70BA {u8 type, ...}                the owner's update (c:0x81e3b0)
##   S->C 0xB0BA {1, u8 type, ...} | {2, u16}  (c:0x878230)
##   S->C 0x30B7 {1|2, u32 uid} | {3, u8 slot, str buyer, list}  (c:0x87a260)
##   S->C 0x30B8 {u32 owner, str name, u32 decoration}           (c:0x873c10)
##   S->C 0x30B9 {u32 owner, u16 reason}                         (c:0x8721b0)
##   S->C 0x30BB {u32 owner, str name}                           (c:0x873d60)
##
## A list (c:0x872290) is, until a slot byte of 0xFF: u8 slot, the item
## record (SOItem::FUN_008be4f0 mode 1, ItemInstance.read_record), u8 bag
## slot (+13), u16 count, u64 price.

const OP_OPEN := 0x70B1
const OP_OPEN_RESULT := 0xB0B1
const OP_CLOSE := 0x70B2
const OP_CLOSE_RESULT := 0xB0B2
const OP_ENTER := 0x70B3
const OP_ENTER_RESULT := 0xB0B3
const OP_BUY := 0x70B4
const OP_BUY_RESULT := 0xB0B4
const OP_LEAVE := 0x70B5
const OP_LEAVE_RESULT := 0xB0B5
const OP_UPDATE := 0x70BA
const OP_UPDATE_RESULT := 0xB0BA
const OP_EVENT := 0x30B7
const OP_APPEAR := 0x30B8
const OP_GONE := 0x30B9
const OP_RENAMED := 0x30BB

## 0x70BA's types (the jump table c:0x81e674).
const UPDATE_PRICE := 1
const UPDATE_ADD := 2
const UPDATE_REMOVE := 3
const UPDATE_VALUE4 := 4
const UPDATE_OPEN := 5
const UPDATE_GREETING := 6
const UPDATE_RENAME := 7

## 0x30B7's kinds.
const EVENT_LEFT := 1
const EVENT_CAME := 2
const EVENT_SOLD := 3

const BAG_OFFSET := 13
const SLOTS := 10
const LIST_END := 0xFF
## The price box's bound (c:0x634f20(0x2540BE3FF)), and the server's.
const MAX_PRICE := 9999999999
## The title box's 40 characters, the greeting box's 64 (c:0x634f80).
const TITLE_MAX := 40
const GREETING_MAX := 64
## The click's reach (c:0x7938d5: +0x24c against 100.0) and the server's.
const ENTER_RANGE := 100.0
## The chat type of the window's chat module (+0x7b0 = 9, c:0x6bb633).
const CHAT_TYPE := 9

## The category-10 codes the client shows (c:0x7b8b40 case 10), READ. Any
## other code shows nothing.
const CODE_TEXTS := {
	3: "UIIT_STT_ERR_COMMON_INVALID_TARGET",
	4: "UIIT_STT_ERR_COMMON_TOO_FAR",
	5: "UIIT_STT_ERR_COMMON_INVALID_OPERATION",
	0x3c08: "UIIT_MSG_FLEAMARKET_ERR_INVALID_PRICE",
	0x3c0c: "UIIT_MSG_FLEAMARKET_ERR_NOTHING_TO_SELL",
	0x3c0e: "UIIT_MSG_FLEAMARKET_ERR_MARKET_CLOSED",
	0x3c11: "UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD",
	0x3c52: "UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD",
	0x3c12: "UIIT_MSG_FLEAMARKET_ERR_INVENTORY_FULL",
	0x3c53: "UIIT_MSG_FLEAMARKET_ERR_INVENTORY_FULL",
	0x3c15: "UIIT_MSG_FLEAMARKET_ERR_HOST_LEFT",
	0x3c16: "UIIT_MSG_FLEAMARKET_ERR_IM_BUSY",
	0x3c17: "UIIT_MSG_FLEAMARKET_ERR_CLOSED_BY_HOST",
	0x3c18: "UIIT_MSG_FLEAMARKET_ERR_MARKET_FULL",
	0x3c2b: "UIIT_MSG_FLEAMARKET_ERR_INVALID_HOST_STATE",
	0x3c2c: "UIIT_MSG_FLEAMARKET_ERR_CUSTOMER_BANNED",
	0x3c34: "UIIT_MSG_FLEAMARKET_ERR_CANT_OPEN_MARKET_IN_RIDESTATE",
	0x3c38: "UIIT_MSG_FLEAMARKET_ERR_NOT_ALLOWED_FMARKETNAME",
	0x3c39: "UIIT_MSG_FLEAMARKET_ERR_CANT_OPEN_MARKET_MURDERER",
	0x3c3b: "UIIT_MSG_FREEMARKET_NOTUSE_JOB",
	0x3c41: "UIIT_MSG_WARENETWORK_ERROR_FAIL",
	0x3c42: "UIIT_MSG_WARENETWORK_ERROR_FAIL",
	0x3c43: "UIIT_MSG_WARENETWORK_ERROR_FAIL",
	0x3c4c: "UIIT_STT_ERR_COMMON_INVALID_OPERATION",
	0x3c55: "UIIT_CTL_NASRUN_NOT_TRADE",
}

## One slot as a list carries it.
class Entry:
	var slot: int
	var item: ItemInstance
	var bag_slot: int
	var count: int
	var price: int

static func _str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, b.size())
	out.append_array(b)
	return out

## The string at `at`: [text, next], or ["", -1] when cut short.
static func _read_str(data: PackedByteArray, at: int) -> Array:
	if at + 2 > data.size():
		return ["", -1]
	var n := data.decode_u16(at)
	if at + 2 + n > data.size():
		return ["", -1]
	return [data.slice(at + 2, at + 2 + n).get_string_from_utf8(), at + 2 + n]

static func encode_open(title: String) -> PackedByteArray:
	return _str(title)

static func encode_enter(owner: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, owner)
	return out

static func encode_buy(slot: int) -> PackedByteArray:
	return PackedByteArray([slot])

## Type 1: {u8 slot, u16 count, u64 price, u16 net}.
static func encode_price(slot: int, count: int, price: int, net := 0) -> PackedByteArray:
	var out := PackedByteArray([UPDATE_PRICE, slot])
	out.resize(14)
	out.encode_u16(2, count)
	out.encode_u64(4, price)
	out.encode_u16(12, net)
	return out

## Type 2: {u8 slot, u8 bag slot + 13, u16 count, u64 price, u32 group, u16 net}.
static func encode_add(slot: int, bag_index: int, count: int, price: int, group: int, net := 0) -> PackedByteArray:
	var out := PackedByteArray([UPDATE_ADD, slot, bag_index + BAG_OFFSET])
	out.resize(19)
	out.encode_u16(3, count)
	out.encode_u64(5, price)
	out.encode_u32(13, group)
	out.encode_u16(17, net)
	return out

## Type 3: {u8 slot, u16 net}.
static func encode_remove(slot: int, net := 0) -> PackedByteArray:
	return PackedByteArray([UPDATE_REMOVE, slot, net & 0xff, (net >> 8) & 0xff])

## Type 5: {u8 open, u16 net}.
static func encode_open_state(open: bool, net := 0) -> PackedByteArray:
	return PackedByteArray([UPDATE_OPEN, 1 if open else 0, net & 0xff, (net >> 8) & 0xff])

## Type 6: the greeting.
static func encode_greeting(text: String) -> PackedByteArray:
	var out := PackedByteArray([UPDATE_GREETING])
	out.append_array(_str(text))
	return out

## Type 7: the new name.
static func encode_rename(title: String) -> PackedByteArray:
	var out := PackedByteArray([UPDATE_RENAME])
	out.append_array(_str(title))
	return out

## 0x7160 {u32 key, u32 decoration} (c:0x803e00 -> 0x821850): the avatar
## stall's Yes, for each BFI1 grant held (session/compositeextra.go).
const OP_AVATAR_STALL := 0x7160

static func encode_avatar_stall(key: int, decoration: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, key)
	out.encode_u32(4, decoration)
	return out

## fmntidgroupmapdata.txt (RefParse_fmntidgroupmapdata c:0x6d5570): Service,
## TidGroupID, TypeID1..4; the client's map is keyed by the packed TID
## (c:0x938370). Rows whose Service is not 1 are left out.
static func parse_tid_groups(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var f := line.strip_edges().split("\t", false)
		if f.size() < 6 or f[0] != "1" or not f[1].is_valid_int():
			continue
		var key := packed_tid([int(f[2]), int(f[3]), int(f[4]), int(f[5])])
		if not out.has(key):
			out[key] = int(f[1])
	return out

## {1} -> 1, {2, code} -> the code, anything else -> -1.
static func decode_result(data: PackedByteArray) -> int:
	if data.size() >= 1 and data[0] == 1:
		return 1
	if data.size() >= 3 and data[0] == 2:
		return data.decode_u16(1)
	return -1

## A list at `at`: [entries (slot -> Entry), next], or [null, -1].
static func read_list(data: PackedByteArray, at: int) -> Array:
	var entries := {}
	while true:
		if at >= data.size():
			return [null, -1]
		var slot: int = data[at]
		at += 1
		if slot == LIST_END:
			break
		var rec := ItemInstance.read_record(data, at)
		if rec[0] == null:
			return [null, -1]
		at = int(rec[1])
		if at + 11 > data.size():
			return [null, -1]
		var e := Entry.new()
		e.slot = slot
		e.item = rec[0]
		e.bag_slot = int(data[at]) - BAG_OFFSET
		e.count = data.decode_u16(at + 1)
		e.price = data.decode_u64(at + 3)
		at += 11
		entries[slot] = e
	return [entries, at]

## 0xB0B3: {"code"} for a refusal, else {"code": 1, "owner", "greeting",
## "open", "value4", "entries", "visitors"}; {} when it does not parse.
static func decode_enter(data: PackedByteArray) -> Dictionary:
	if data.size() >= 3 and data[0] == 2:
		return {"code": data.decode_u16(1)}
	if data.size() < 7 or data[0] != 1:
		return {}
	var owner := data.decode_u32(1)
	var s := _read_str(data, 5)
	if int(s[1]) < 0 or int(s[1]) + 2 > data.size():
		return {}
	var at: int = s[1]
	var open := data[at] == 1
	var value4: int = data[at + 1]
	var l := read_list(data, at + 2)
	if l[0] == null:
		return {}
	at = l[1]
	if at >= data.size():
		return {}
	var n: int = data[at]
	at += 1
	if at + 4 * n > data.size():
		return {}
	var visitors: Array = []
	for i in n:
		visitors.append(data.decode_u32(at + 4 * i))
	return {"code": 1, "owner": owner, "greeting": s[0], "open": open, "value4": value4,
		"entries": l[0], "visitors": visitors}

## 0xB0B4: {"code"} and, on 1, "slot".
static func decode_buy(data: PackedByteArray) -> Dictionary:
	if data.size() >= 2 and data[0] == 1:
		return {"code": 1, "slot": int(data[1])}
	if data.size() >= 3 and data[0] == 2:
		return {"code": data.decode_u16(1)}
	return {}

## 0xB0BA (c:0x878230): {"code"} for a refusal; else {"code": 1, "type"} and
## per type -- 1: slot, count, price, net; 2 / 3: net, entries; 4: value;
## 5: open, net; 6: greeting.
static func decode_update(data: PackedByteArray) -> Dictionary:
	if data.size() >= 3 and data[0] == 2:
		return {"code": data.decode_u16(1)}
	if data.size() < 2 or data[0] != 1:
		return {}
	var t: int = data[1]
	var out := {"code": 1, "type": t}
	match t:
		UPDATE_PRICE:
			if data.size() < 15:
				return {}
			out["slot"] = int(data[2])
			out["count"] = data.decode_u16(3)
			out["price"] = data.decode_u64(5)
			out["net"] = data.decode_u16(13)
		UPDATE_ADD, UPDATE_REMOVE:
			if data.size() < 4:
				return {}
			out["net"] = data.decode_u16(2)
			var l := read_list(data, 4)
			if l[0] == null:
				return {}
			out["entries"] = l[0]
		UPDATE_VALUE4:
			if data.size() < 3:
				return {}
			out["value"] = int(data[2])
		UPDATE_OPEN:
			if data.size() < 3:
				return {}
			out["open"] = data[2] == 1
			out["net"] = data.decode_u16(3) if data.size() >= 5 else 0
		UPDATE_GREETING:
			var s := _read_str(data, 2)
			if int(s[1]) < 0:
				return {}
			out["greeting"] = s[0]
	return out

## 0x30B7: {"kind", "uid"} (1, 2) or {"kind": 3, "slot", "buyer", "entries"}.
static func decode_event(data: PackedByteArray) -> Dictionary:
	if data.size() < 1:
		return {}
	var kind: int = data[0]
	if kind == EVENT_LEFT or kind == EVENT_CAME:
		if data.size() < 5:
			return {}
		return {"kind": kind, "uid": data.decode_u32(1)}
	if kind == EVENT_SOLD or kind == 4:
		if data.size() < 2:
			return {}
		var s := _read_str(data, 2)
		if int(s[1]) < 0:
			return {}
		var l := read_list(data, int(s[1]))
		if l[0] == null:
			return {}
		return {"kind": kind, "slot": int(data[1]), "buyer": s[0], "entries": l[0]}
	return {}

## 0x30B8: {"owner", "name", "decoration"}.
static func decode_appear(data: PackedByteArray) -> Dictionary:
	if data.size() < 6:
		return {}
	var s := _read_str(data, 4)
	if int(s[1]) < 0 or int(s[1]) + 4 > data.size():
		return {}
	return {"owner": data.decode_u32(0), "name": s[0], "decoration": data.decode_u32(int(s[1]))}

## 0x30B9: {"owner", "reason"}.
static func decode_gone(data: PackedByteArray) -> Dictionary:
	if data.size() < 4:
		return {}
	return {"owner": data.decode_u32(0), "reason": data.decode_u16(4) if data.size() >= 6 else 0}

## 0x30BB: {"owner", "name"}.
static func decode_renamed(data: PackedByteArray) -> Dictionary:
	if data.size() < 6:
		return {}
	var s := _read_str(data, 4)
	if int(s[1]) < 0:
		return {}
	return {"owner": data.decode_u32(0), "name": s[0]}

## The plate's text (c:0x9dc3a0): "[" + name + "]".
static func plate_title(name: String) -> String:
	return "[" + name + "]"

## The plate's colour, 0xFFFEB5FF (c:0x9c89a0, from 0x9dd176).
const TITLE_COLOUR := Color8(0xfe, 0xb5, 0xff)

## The slot's price colour by its amount (c:0x5d3df0), READ.
static func price_colour(price: int) -> Color:
	if price < 10000:
		return Color.WHITE
	if price < 100000:
		return Color8(0xff, 0xfa, 0x85)
	if price < 1000000:
		return Color8(0xff, 0xd3, 0x48)
	if price < 10000000:
		return Color8(0xff, 0xad, 0x5c)
	if price < 100000000:
		return Color8(0xff, 0x9a, 0xa1)
	if price < 1000000000:
		return Color8(0xeb, 0xa1, 0xff)
	if price < 10000000000:
		return Color8(0xb8, 0xbb, 0xff)
	if price < 100000000000:
		return Color8(0x95, 0xde, 0xff)
	return Color8(0x8b, 0xff, 0xe5)

## The price as the slot writes it (c:0x8c1d50(.., 3)): ',' every three
## digits.
static func group_digits(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	var n := s.length()
	for i in n:
		out += s[i]
		var left := n - 1 - i
		if left > 0 and left % 3 == 0:
			out += ","
	return ("-" if v < 0 else "") + out

## The packed TID the item's group is looked up by (c:0x938370: the ref's
## 16-bit TID with its low two bits cleared): TypeID1..4 at bits 2, 5, 7, 11.
static func packed_tid(type_ids: Array) -> int:
	if type_ids.size() < 4:
		return 0
	return ((int(type_ids[0]) & 7) << 2) | ((int(type_ids[1]) & 3) << 5) | ((int(type_ids[2]) & 0xf) << 7) \
		| ((int(type_ids[3]) & 0x1f) << 11)
