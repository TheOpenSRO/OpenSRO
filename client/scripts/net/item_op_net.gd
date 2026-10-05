extends RefCounted
class_name ItemOpNet

## The retail item operation (round 728, after its review), mirroring
## server/internal/session/itemop.go. READ: the client's serializer
## c:0x7923a0 and record parser c:0x87eb50 (docs/rounds/r728_review.md, "The
## retail layouts"). Bag slots on the wire are the bag index + 13.
##
##   0x7034 type 0 (split):   u8 src, u8 dst, u16 count
##   0x7034 type 9 (sell):    u8 src, u16 count, u32 NPC uid
##   0x7034 type 2 (deposit): u8 src, u8 dst (warehouse), u32 NPC uid
##   0x7168 (buy back):       u32 NPC uid, u8 index (0 = the oldest)
##   0xB034: u8 1, u8 type, the record -- or u8 2, u16 code
##   0xB168: u8 2, u16 code (a buy back's failure; success is 0xB034 0x22)
##
## The other item moves stay on OpenSRO's own messages for now.

const OP_MOVE := 0x7034
const OP_MOVE_RESULT := 0xB034
const OP_BUYBACK := 0x7168
const OP_BUYBACK_FAIL := 0xB168

const TYPE_BAG_TO_BAG := 0
const TYPE_DEPOSIT := 2
const TYPE_SELL := 9
const TYPE_BUYBACK := 0x22
const BAG_OFFSET := 13
## The sell result's book byte when the sale was not booked.
const NOT_BOOKED := 0xFF

## The refusal codes the client shows a line for, and the line (READ:
## r728_review.md F10 and the deposit's 0x180f).
const ERR_NOT_ENOUGH_GOLD := 0x180f
const ERR_BAG_FULL := 0x1807
const ERR_NO_SUCH_ENTRY := 0x18d3
const ERROR_TEXT := {
	0x180f: "UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD",
	0x1807: "UIIT_MSG_STRGERR_INVENTORY_FULL",
	0x18d3: "UIIT_MSG_ERROR_RE_BUY_OBJECT_CANT",
	0x183b: "UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP",
}

static func encode_split(src: int, dst: int, count: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_BAG_TO_BAG, src + BAG_OFFSET, dst + BAG_OFFSET, 0, 0])
	out.encode_u16(3, count)
	return out

static func encode_sell(src: int, count: int, npc: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_SELL, src + BAG_OFFSET, 0, 0, 0, 0, 0, 0])
	out.encode_u16(2, count)
	out.encode_u32(4, npc)
	return out

static func encode_deposit(src: int, dst: int, npc: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_DEPOSIT, src + BAG_OFFSET, dst, 0, 0, 0, 0])
	out.encode_u32(3, npc)
	return out

static func encode_buyback(npc: int, index: int) -> PackedByteArray:
	var out := PackedByteArray([0, 0, 0, 0, index])
	out.encode_u32(0, npc)
	return out

## A decoded 0xB034 (or 0xB168): ok, the type, and the record's fields --
## "src", "dst" (bag indexes, the +13 removed, except a deposit's warehouse
## "dst"), "count", "npc", "book", "index"; or "code" on a failure. Empty
## when truncated.
static func decode_result(data: PackedByteArray) -> Dictionary:
	if data.size() < 1:
		return {}
	if data[0] != 1:
		return {"ok": false, "code": data.decode_u16(1) if data.size() >= 3 else 0}
	if data.size() < 2:
		return {}
	var t: int = data[1]
	var r := {"ok": true, "type": t}
	match t:
		TYPE_BAG_TO_BAG:
			if data.size() < 6:
				return {}
			r["src"] = data[2] - BAG_OFFSET
			r["dst"] = data[3] - BAG_OFFSET
			r["count"] = data.decode_u16(4)
		TYPE_SELL:
			if data.size() < 10:
				return {}
			r["src"] = data[2] - BAG_OFFSET
			r["count"] = data.decode_u16(3)
			r["npc"] = data.decode_u32(5)
			r["book"] = data[9]
		TYPE_DEPOSIT:
			if data.size() < 4:
				return {}
			r["src"] = data[2] - BAG_OFFSET
			r["dst"] = data[3]
		TYPE_BUYBACK:
			if data.size() < 6:
				return {}
			r["dst"] = data[2] - BAG_OFFSET
			r["index"] = data[3]
			r["count"] = data.decode_u16(4)
	return r

## The client's buy-back list (c:0x78d900, READ): on a booked sale -- the
## result's book byte not 0xFF -- the oldest entry is dropped when five are
## held and the sold item appended at the back. `book` is the list of
## {"item_id", "quantity"} dictionaries, oldest first; returns it changed.
static func book_sale(book: Array, item_id: int, quantity: int, book_byte: int) -> Array:
	if book_byte == NOT_BOOKED:
		return book
	var out := book.duplicate()
	if out.size() > 4:
		out.pop_front()
	out.append({"item_id": item_id, "quantity": quantity})
	return out

## Whether a sale of this item is never booked (gs:0x6b2950 / 0x61b820,
## READ): TypeID 3/3/8 unless bionic, any 3/2/x, 3/1/13, or a CodeName
## starting ITEM_QNO, ITEM_QTUTORIAL, ITEM_QSP, ITEM_QCX, ITEM_ETC_E,
## SN_ITEM_EVENT, or equal to SN_ITEM_ETC_TAIWAN_50000_GOLD. The Ctrl+sell
## warning (UIIT_MSG_CANNOT_BUYBACK_ITEM_SELL) asks for these.
static func never_booked(type_ids: Array, bionic: bool, code_name: String) -> bool:
	if type_ids.size() >= 3 and int(type_ids[0]) == 3:
		var t2 := int(type_ids[1])
		var t3 := int(type_ids[2])
		if (t2 == 3 and t3 == 8 and not bionic) or t2 == 2 or (t2 == 1 and t3 == 13):
			return true
	if code_name == "SN_ITEM_ETC_TAIWAN_50000_GOLD":
		return true
	for p in ["ITEM_QNO", "ITEM_QTUTORIAL", "ITEM_QSP", "ITEM_QCX", "ITEM_ETC_E", "SN_ITEM_EVENT"]:
		if code_name.begins_with(p):
			return true
	return false
