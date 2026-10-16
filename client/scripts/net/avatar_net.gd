extends RefCounted
class_name AvatarNet

## Avatars on the wire (round 789, lane AC): every layout below is READ from
## both binaries in /root/opensro-pk3av789/AVATAR_RESEARCH.md (moves, 0x3013's
## avatar section, the spawn block, 0x3038/0x3039) and
## AVATAR_ALCHEMY_RESEARCH.md (the grant 0x34A9/0x34AA); the golden vectors
## the server is held to are testdata/avatar_golden.json (avatar_net_test.gd).
## docs/protocol/avatars.md (lane AS) is the protocol page; this file is the
## client's codec and touches no window.
##
##   0x7034 type 0x24 (bag -> avatar):  u8 src = bag slot + 13, u8 dst = avatar slot 0..4
##   0x7034 type 0x23 (avatar -> bag):  u8 src = avatar slot 0..4, u8 dst = bag slot + 13
##       (READ s:0x4d8e8a parser, c:0x7923a0 serializer, c:0x7950b0 senders)
##   0xB034 ok:   u8 1, u8 type, u8 src, u8 dst, u16 qty (0), u8 n, n x (u8 type, u8 src, u8 dst, u16 qty)
##   0xB034 fail: u8 2, u16 code                           (READ s:0x4f804d, c:0x87eb50)
##   0x3038: u32 uid, u8 avatar slot, u32 RefItemID, u8 plus  (s:0x4e9c40; the client ignores the
##   0x3039: u32 uid, u8 avatar slot, u32 RefItemID            slot byte for avatars, c:0x8a9260/0x8a9560)
##   spawn (0x3015/0x3017-0x3019): u8 size (5), u8 count, count x (u32 RefItemID, u8 plus only for
##       3/1/13 and 3/1/14)                                (c:0x9de3e2..0x9de4a1, s:0x4ba720 mode 2)
##   0x3013's avatar section: u8 size, u8 count, count x (u8 slot, item record) (c:0x9d9c39, s:0x4ba720)
##   0x34A9: u8 slot (bag + 13), u16 n, n x ASCII MATTR code (c:0x822a30)
##   0x34AA: u8 1, u8 flag, u8 slot, item record -- or u8 2, u16 code (gs:0x507b5c, c:0x899f40)
##
## OURS: OpenSRO has no 0x3013. The client asks for its avatar inventory with
## OP_LIST_REQUEST when it asks for the bag and the worn list, and the server
## answers OP_LIST, whose payload is exactly 0x3013's avatar section. The
## request carries the character's name as the bag and worn list requests do
## (InventoryNet / EquipmentNet: u16 length, the name).

const OP_ITEM_MOVE := 0x7034
const OP_ITEM_MOVE_ACK := 0xB034
const OP_EQUIP_BROADCAST := 0x3038
const OP_UNEQUIP_BROADCAST := 0x3039
const OP_GRANT := 0x34A9
const OP_GRANT_ACK := 0x34AA
const OP_LIST_REQUEST := 0x0044
const OP_LIST := 0x0045
## The item-state notice (READ s:0x4bbd60): `u8 kind, u8 avatar slot`; kind 3
## is a worn devil's spirit that expired (its params already removed; the
## item stays in its slot). Other kinds are not READ here.
const OP_ITEM_STATE := 0x3078
const ITEM_STATE_SPIRIT_EXPIRED := 3

const TYPE_AVATAR_TO_BAG := 0x23
const TYPE_BAG_TO_AVATAR := 0x24
## Bag slots on the wire are the bag index + 13 (the 13 equip slots first).
const BAG_OFFSET := 13
## The avatar storage's size (READ s:0x4e1340: created with size 5, type 5).
const STORAGE_SIZE := 5
## The storage slot the client sends for a devil's spirit (READ c:0x55edf0).
const DEVIL_SPIRIT_SLOT := 4

## 0xB034's refusals for an avatar move and the client's message names
## (AVATAR_RESEARCH.md 1.7, docs/protocol/error_codes.md). The codes the
## research found no name for (0x1806, 0x1809, 2) are left out: the client
## shows our own line for them (OPEN). Which error-box category the client
## dispatches 0xB034's code under is not READ here; these are the storage
## category's names (category 1, as ErrorText's storage rows).
const MOVE_REFUSAL_KEYS := {
	3: "UIIT_MSG_STRGERR_INVALID_TARGET",
	0x180e: "UIIT_MSG_STRGERR_EQUIPITEM",
	0x1807: "UIIT_MSG_STRGERR_INVENTORY_FULL",
	0x1816: "UIIT_MSG_STRGERR_GENDER_MISMATCH",
	0x182f: "UIIT_MSG_STRGERR_COUNTRY_MISMATCH",
	0x1830: "UIIT_MSG_STRGERR_HIGHER_STRENGTH_REQUIRED",
	0x1831: "UIIT_MSG_STRGERR_HIGHER_INTELLECT_REQUIRED",
	0x1834: "UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED",
	0x1837: "UIIT_MSG_STRGERR_CANT_EQUIP_RAZED_ITEM",
	0x183c: "UIIT_STT_RENT_EQ_ITEM_USED_ERORR",
	0x186c: "UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM",
	0x18f7: "UIIT_MSG_HWANITEM_CANNOT_USE",
	0x18f9: "UIIT_MSG_NASRUN_NOT_AWAKE_WEAR_ERROR",
}

## 0x34AA's refusals in the error box's category 0x20 (READ c:0x7bacb3, the
## table c:0x7bb378 + 0x80, `code - 6` through c:0x7bbe9c). 2, 3, 9, 0xb and
## any other code fall to the switch's default with an empty key (c:0x7bb2f3):
## what that shows is OPEN, so they keep our own line.
const GRANT_REFUSAL_KEYS := {
	6: "UIIT_MSG_AVATAR_MAGICOPTION_ADD_ERORR",
	7: "UIIT_STT_AVATAR_MAGICOPTION_ADD_FAIL",
	8: "UIIT_STT_AVATAR_MAGICOPTION_ONLY_AVATAR",
	0xa: "UIIT_STT_AVATAR_MAGICOPTION_WRONG",
}

# --- 0x7034 / 0xB034 ----------------------------------------------------------

## A move request: [type, src, dst].
static func encode_move(type: int, src: int, dst: int) -> PackedByteArray:
	return PackedByteArray([type & 0xff, src & 0xff, dst & 0xff])

## Bag index `bag_slot` -> avatar storage slot `avatar_slot` (type 0x24).
static func encode_equip(bag_slot: int, avatar_slot: int) -> PackedByteArray:
	return encode_move(TYPE_BAG_TO_AVATAR, bag_slot + BAG_OFFSET, avatar_slot)

## Avatar storage slot -> the bag index clicked (type 0x23; the server puts
## the item in the first free bag slot whatever this names, s:0x525ac0).
static func encode_unequip(avatar_slot: int, bag_slot: int) -> PackedByteArray:
	return encode_move(TYPE_AVATAR_TO_BAG, avatar_slot, bag_slot + BAG_OFFSET)

## The server side of a request (tests, fixtures): {type, src, dst}, or
## {"error"} unless it is exactly three bytes of type 0x23 or 0x24.
static func decode_move(data: PackedByteArray) -> Dictionary:
	if data.size() != 3:
		return {"error": "an avatar move is 3 bytes, got %d" % data.size()}
	var t: int = data[0]
	if t != TYPE_AVATAR_TO_BAG and t != TYPE_BAG_TO_AVATAR:
		return {"error": "type 0x%02x is not an avatar move" % t}
	return {"type": t, "src": int(data[1]), "dst": int(data[2])}

## Whether a 0xB034 is an avatar move's success (its type byte 0x23/0x24).
## A refusal carries no type; NetClient routes it by what it sent.
static func is_move_ack(data: PackedByteArray) -> bool:
	return data.size() >= 2 and data[0] == 1 and (data[1] == TYPE_AVATAR_TO_BAG or data[1] == TYPE_BAG_TO_AVATAR)

## A 0xB034 for an avatar move: {ok true, type, src, dst, qty, subs: [{type,
## src, dst, qty}]} or {ok false, code}; {"error"} when it is short or longer
## than its sub-ops say.
static func decode_move_ack(data: PackedByteArray) -> Dictionary:
	if data.size() < 1:
		return {"error": "empty"}
	if data[0] == 2:
		if data.size() != 3:
			return {"error": "a refusal is 3 bytes, got %d" % data.size()}
		return {"ok": false, "code": data.decode_u16(1)}
	if data[0] != 1:
		return {"error": "result %d" % data[0]}
	if data.size() < 7:
		return {"error": "short success (%d bytes)" % data.size()}
	var t: int = data[1]
	if t != TYPE_AVATAR_TO_BAG and t != TYPE_BAG_TO_AVATAR:
		return {"error": "type 0x%02x is not an avatar move" % t}
	var out := {"ok": true, "type": t, "src": int(data[2]), "dst": int(data[3]), "qty": data.decode_u16(4), "subs": []}
	var n: int = data[6]
	var at := 7
	for i in n:
		if at + 5 > data.size():
			return {"error": "sub-op %d of %d cut short" % [i, n]}
		(out["subs"] as Array).append({"type": int(data[at]), "src": int(data[at + 1]), "dst": int(data[at + 2]),
			"qty": data.decode_u16(at + 3)})
		at += 5
	if at != data.size():
		return {"error": "%d byte(s) after the sub-ops" % (data.size() - at)}
	return out

## decode_move_ack's inverse (tests, fixtures).
static func encode_move_ack(f: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	if not bool(f.get("ok", false)):
		out.resize(3)
		out[0] = 2
		out.encode_u16(1, int(f.get("code", 0)))
		return out
	var subs: Array = f.get("subs", [])
	out.resize(7)
	out[0] = 1
	out[1] = int(f["type"])
	out[2] = int(f["src"])
	out[3] = int(f["dst"])
	out.encode_u16(4, int(f.get("qty", 0)))
	out[6] = subs.size()
	for s in subs:
		var b := PackedByteArray([int(s["type"]), int(s["src"]), int(s["dst"]), 0, 0])
		b.encode_u16(3, int(s.get("qty", 0)))
		out.append_array(b)
	return out

# --- 0x3038 / 0x3039 ------------------------------------------------------------

## A broadcast's fields: {uid, slot, ref, plus (0x3038 only)}; {} when cut
## short. The avatar 0x3038 always carries the plus (an avatar is TypeID
## 3/1, READ c:0x8a9260).
static func decode_broadcast(data: PackedByteArray, opcode: int) -> Dictionary:
	if data.size() < 9:
		return {}
	var out := {"uid": data.decode_u32(0), "slot": int(data[4]), "ref": data.decode_u32(5)}
	if opcode == OP_EQUIP_BROADCAST:
		if data.size() < 10:
			return {}
		out["plus"] = int(data[9])
	return out

static func encode_broadcast(opcode: int, f: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(9)
	out.encode_u32(0, int(f["uid"]))
	out[4] = int(f["slot"])
	out.encode_u32(5, int(f["ref"]))
	if opcode == OP_EQUIP_BROADCAST:
		out.append(int(f.get("plus", 0)) & 0xff)
	return out

## 0x3078: {kind, slot}; {} when cut short.
static func decode_item_state(data: PackedByteArray) -> Dictionary:
	if data.size() < 2:
		return {}
	return {"kind": int(data[0]), "slot": int(data[1])}

# --- the spawn's avatar block -----------------------------------------------------

## Reads the spawn record's avatar block at `r` (NpcSpawnNet.Reader): [{id,
## plus}] in storage order. `has_plus(id)` answers whether the id is a 3/1/13
## or 3/1/14 (the only kinds whose plus byte the client reads, READ
## c:0x9de3e2..0x9de4a1); a reader without it reads every plus. r.error is
## set on a short block.
static func read_spawn_block(r, has_plus: Callable = Callable()) -> Array:
	var items: Array = []
	r.u8() # size: 5 (READ s:0x4e1340); the client does not keep it
	var n: int = r.u8()
	for i in n:
		var id: int = r.u32()
		var plus := 0
		if not has_plus.is_valid() or bool(has_plus.call(id)):
			plus = r.u8()
		items.append({"id": id, "plus": plus})
	return items

## The block read_spawn_block reads (tests, fixtures); `has_plus` as there.
static func encode_spawn_block(size: int, items: Array, has_plus: Callable = Callable()) -> PackedByteArray:
	var out := PackedByteArray([size & 0xff, items.size() & 0xff])
	for it in items:
		var b := PackedByteArray()
		b.resize(4)
		b.encode_u32(0, int(it["id"]))
		out.append_array(b)
		if not has_plus.is_valid() or bool(has_plus.call(int(it["id"]))):
			out.append(int(it.get("plus", 0)) & 0xff)
	return out

# --- the avatar list (0x3013's avatar section) ---------------------------------

## OP_LIST_REQUEST's payload (OURS): the character's name, as the bag list's.
static func encode_list_request(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## The avatar section: {size, items: {storage slot: ItemInstance}} or
## {"error"} when an item is cut short or bytes are left over.
static func decode_list(data: PackedByteArray) -> Dictionary:
	if data.size() < 2:
		return {"error": "short avatar list (%d bytes)" % data.size()}
	var out := {"size": int(data[0]), "items": {}}
	var n: int = data[1]
	var at := 2
	for i in n:
		if at + 1 > data.size():
			return {"error": "avatar %d of %d: no slot" % [i, n]}
		var slot: int = data[at]
		var rec := ItemInstance.read_record(data, at + 1)
		if rec[0] == null:
			return {"error": "avatar %d of %d: record cut short" % [i, n]}
		var it: ItemInstance = rec[0]
		it.slot = slot
		(out["items"] as Dictionary)[slot] = it
		at = int(rec[1])
	if at != data.size():
		return {"error": "%d byte(s) after the avatar list" % (data.size() - at)}
	return out

## decode_list's inverse (tests, fixtures): items in ascending slot order.
static func encode_list(size: int, items: Dictionary) -> PackedByteArray:
	var out := PackedByteArray([size & 0xff, items.size() & 0xff])
	var slots := items.keys()
	slots.sort()
	for s in slots:
		out.append(int(s) & 0xff)
		out.append_array((items[s] as ItemInstance).encode_record())
	return out

# --- the grant (0x34A9 / 0x34AA) -------------------------------------------------

## 0x34A9: bag index `bag_slot`, the row's MATTR code (narrowed to ASCII,
## c:0x4fc950 -> 0x4fc870).
static func encode_grant(bag_slot: int, code: String) -> PackedByteArray:
	return encode_grant_raw(bag_slot + BAG_OFFSET, code)

## 0x34A9 with the wire slot as sent (bag index + 13).
static func encode_grant_raw(wire_slot: int, code: String) -> PackedByteArray:
	var text := code.to_ascii_buffer()
	var out := PackedByteArray([wire_slot & 0xff, 0, 0])
	out.encode_u16(1, text.size())
	out.append_array(text)
	return out

## The server side of 0x34A9 (tests): {slot, code} or {"error"}.
static func decode_grant(data: PackedByteArray) -> Dictionary:
	if data.size() < 3:
		return {"error": "short grant request"}
	var n := data.decode_u16(1)
	if 3 + n != data.size():
		return {"error": "the code is %d byte(s), %d follow" % [n, data.size() - 3]}
	return {"slot": int(data[0]), "code": data.slice(3).get_string_from_ascii()}

## 0x34AA: {ok true, flag, slot (as sent: bag index + 13), item: ItemInstance
## or null when flag is 0} or {ok false, code}; {"error"} when malformed.
static func decode_grant_ack(data: PackedByteArray) -> Dictionary:
	if data.size() < 1:
		return {"error": "empty"}
	if data[0] == 2:
		if data.size() != 3:
			return {"error": "a refusal is 3 bytes, got %d" % data.size()}
		return {"ok": false, "code": data.decode_u16(1)}
	if data[0] != 1 or data.size() < 3:
		return {"error": "malformed grant reply"}
	var out := {"ok": true, "flag": int(data[1]), "slot": int(data[2]), "item": null}
	if out["flag"] == 0:
		return out
	var rec := ItemInstance.read_record(data, 3)
	if rec[0] == null:
		return {"error": "the item record is cut short"}
	if int(rec[1]) != data.size():
		return {"error": "%d byte(s) after the item" % (data.size() - int(rec[1]))}
	var it: ItemInstance = rec[0]
	it.slot = int(data[2]) - BAG_OFFSET
	out["item"] = it
	return out

static func encode_grant_ack(f: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	if not bool(f.get("ok", false)):
		out.resize(3)
		out[0] = 2
		out.encode_u16(1, int(f.get("code", 0)))
		return out
	out = PackedByteArray([1, int(f.get("flag", 1)) & 0xff, int(f["slot"]) & 0xff])
	var it = f.get("item")
	if it != null:
		out.append_array((it as ItemInstance).encode_record())
	return out

# --- the refusal lines --------------------------------------------------------------

## A move refusal in words: the client's message through `text` (Callable(key,
## fallback) -> String), or our own line for a code it has no name for.
static func move_refusal_line(code: int, text: Callable = Callable()) -> String:
	var fallback := "The avatar could not be moved (code 0x%x)." % code
	var key: String = MOVE_REFUSAL_KEYS.get(code, "")
	if key == "" or not text.is_valid():
		return fallback
	return String(text.call(key, fallback))

## A grant refusal in words, as move_refusal_line.
static func grant_refusal_line(code: int, text: Callable = Callable()) -> String:
	var fallback := "The magic option could not be granted (code %d)." % code
	var key: String = GRANT_REFUSAL_KEYS.get(code, "")
	if key == "" or not text.is_valid():
		return fallback
	return String(text.call(key, fallback))
