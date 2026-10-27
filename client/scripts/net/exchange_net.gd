extends RefCounted
class_name ExchangeNet

## Round 834: the exchange on the retail wire, mirroring
## server/internal/session/exchange.go (docs/protocol/exchange.md and its
## review exchange_verify.md; c: the client's addresses, READ unless marked).
##
##   C->S 0x7081 {u32 target id}                     (c:SendTradeMsg_081 0x81d790)
##   S->C 0xB081 {1, u32 target} | {2, u16 code}     (c:0x880330)
##   S->C 0x3080 {1, u32 asker id}                   kind 1, the request box (c:0x88aa60)
##   C->S 0x3080 {1, u8 answer}                      1 accepts, 0 refuses (c:0x81db80)
##   S->C 0x3085 {u32 asker id}                      to the target (c:0x8803f0)
##   C->S 0x7034 {4, u8 bag slot + 13} / {5, u8 index} / {0xd, u64 gold}
##   S->C 0xB034 {1, 4, slot, index} / {1, 5, index} / {1, 0xd, u64} / {2, u16}
##   S->C 0x308C {u32 owner, u8 n, n x ([u8 slot] to the owner, u8 index, record)}
##   S->C 0x3089 {2, u64 gold} (kind 1, {u8 index, record}, is read but never sent)
##   S->C 0x3086 {}  the partner confirmed        (c:0x87fcb0)
##   C->S 0x7082 / 0x7083 / 0x7084 {}             confirm, approve, cancel
##   S->C 0xB082 / 0xB083 / 0xB084 {1} | {2, u16}
##   S->C 0x3087 {} done; 0x3088 {u16 code} closed

const OP_REQUEST := 0x7081
const OP_REQUEST_RESULT := 0xB081
const OP_STARTED := 0x3085
const OP_CONFIRM := 0x7082
const OP_CONFIRM_RESULT := 0xB082
const OP_APPROVE := 0x7083
const OP_APPROVE_RESULT := 0xB083
const OP_CANCEL := 0x7084
const OP_CANCEL_RESULT := 0xB084
const OP_CONFIRMED := 0x3086
const OP_DONE := 0x3087
const OP_CLOSED := 0x3088
const OP_UPDATE := 0x3089
const OP_OFFER := 0x308C
const OP_ITEM_MOVE := 0x7034

const MOVE_ADD := 4
const MOVE_REMOVE := 5
const MOVE_GOLD := 0x0d
const REQUEST_KIND := 1
const BAG_OFFSET := 13

## The category-1 codes the client shows (the storage switch: code - 0x180b,
## index bytes c:0x7bb6d4, targets c:0x7bb438; 3 at c:0x7b8c9c), every one
## READ this round. Any other code shows nothing (the default c:0x7b913a).
## Each is a system line of type 5 (c:0x7b966d -> 0x7781b0(5, text)); the
## codes in CODE_BANNER are first put on the warning banner too (c:0x7b8ccc /
## 0x7b8cc7 -> 0x77b580, then the same line).
const CODE_TEXTS := {
	3: "UIIT_MSG_STRGERR_INVALID_TARGET",
	0x180f: "UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD",
	0x181e: "UIIT_MSG_STRGERR_BUSY",
	0x181f: "UIIT_MSG_STRGERR_CANNOT_DEAL_NORMALCY",
	0x1820: "UIIT_MSG_STRGERR_CANNOT_DEAL_NORMALCY",
	0x1821: "UIIT_MSG_STRGERR_TRADE_BAY_FULL",
	0x1823: "UIIT_MSG_STRGERR_DEAL_FAIL_NON_ITEM",
	0x1826: "UIIT_MSG_STRGERR_TIMEOUT",
	0x1827: "UIIT_MSG_STRGERR_CANNOT_FIND_TARGET",
	0x1828: "UIIT_MSG_STRGERR_TRADING_DENIED",
	0x1829: "UIIT_MSG_STRGERR_SPECIFY_POSITIVE_NUMBER_ONLY",
	0x182b: "UIIT_MSG_STRGERR_EXCHANGE_CANCEL",
	0x182c: "UIIT_MSG_STRGERR_TRADING_CANCELED_BY_USER",
	0x1834: "UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED",
	0x1836: "UIIT_MSG_STRGERR_NOT_ENOUGH_OPPONENT_INV_SPACE",
	0x183a: "UIIT_MSG_STRGERR_CANNOT_BE_TRADED",
	0x1850: "UIIT_MSG_STRGERR_YOU_CANT_DEAL_SPECIALTY",
	0x185f: "UIIT_MSG_STRGERR_REQUESTED_JOB_BLOCKED_BY_QUEST",
	0x18b6: "UIIT_MSG_COSPETERR_CANT_TRADE",
	0x18fa: "UIIT_CTL_NASRUN_NOT_TRADE",
}

const CODE_BANNER := [0x180f, 0x181f, 0x1820, 0x1821, 0x183a, 0x185f, 0x18b6, 0x18fa]

## One offered item: its index in the bay, the bag slot (the owner's own
## list only, -1 otherwise) and the item.
class Offered:
	var index: int
	var bag_slot: int = -1
	var item: ItemInstance

static func _u32(v: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, v)
	return out

static func encode_request(target_id: int) -> PackedByteArray:
	return _u32(target_id)

static func encode_answer(accept: bool) -> PackedByteArray:
	return PackedByteArray([1, 1 if accept else 0])

## 0x7034 type 4 for a bag index (the +13 added).
static func encode_add(bag_index: int) -> PackedByteArray:
	return PackedByteArray([MOVE_ADD, bag_index + BAG_OFFSET])

static func encode_remove(index: int) -> PackedByteArray:
	return PackedByteArray([MOVE_REMOVE, index])

## 0x7034 type 0xd, clamped to 0..1,000,000,000 as the serializer does
## (c:0x7923ee).
static func encode_gold(gold: int) -> PackedByteArray:
	var out := PackedByteArray([MOVE_GOLD])
	out.resize(9)
	out.encode_u64(1, clampi(gold, 0, 1000000000))
	return out

## {1} -> 1, {2, code} -> the code, anything else -> -1.
static func decode_result(data: PackedByteArray) -> int:
	if data.size() >= 1 and data[0] == 1:
		return 1
	if data.size() >= 3 and data[0] == 2:
		return data.decode_u16(1)
	return -1

## 0xB081: [ok, target id or code].
static func decode_request_result(data: PackedByteArray) -> Array:
	if data.size() >= 5 and data[0] == 1:
		return [true, data.decode_u32(1)]
	if data.size() >= 3 and data[0] == 2:
		return [false, data.decode_u16(1)]
	return []

## 0x308C: {"owner", "items": [Offered]}, or {} when it does not parse.
## `own` is whether the receiver is the owner (then each entry carries its
## bag slot, c:0x8806b0 compares the owner with the player's id).
static func decode_offer(data: PackedByteArray, own_id: int) -> Dictionary:
	if data.size() < 5:
		return {}
	var owner := data.decode_u32(0)
	var own := owner == own_id
	var n: int = data[4]
	var at := 5
	var items: Array = []
	for i in n:
		var o := Offered.new()
		if own:
			if at >= data.size():
				return {}
			o.bag_slot = int(data[at]) - BAG_OFFSET
			at += 1
		if at >= data.size():
			return {}
		o.index = data[at]
		var rec := ItemInstance.read_record(data, at + 1)
		if rec[0] == null:
			return {}
		o.item = rec[0]
		at = int(rec[1])
		items.append(o)
	return {"owner": owner, "own": own, "items": items}

## 0x3089 kind 2: the gold, or -1.
static func decode_gold_update(data: PackedByteArray) -> int:
	if data.size() >= 9 and data[0] == 2:
		return data.decode_u64(1)
	return -1

## A 0xB034 of the exchange's: {"type", "slot", "index", "gold"}, or {}
## for another move.
static func decode_move_result(data: PackedByteArray) -> Dictionary:
	if data.size() < 2 or data[0] != 1:
		return {}
	match int(data[1]):
		MOVE_ADD:
			if data.size() >= 4:
				return {"type": MOVE_ADD, "slot": int(data[2]) - BAG_OFFSET, "index": int(data[3])}
		MOVE_REMOVE:
			if data.size() >= 3:
				return {"type": MOVE_REMOVE, "index": int(data[2])}
		MOVE_GOLD:
			if data.size() >= 10:
				return {"type": MOVE_GOLD, "gold": data.decode_u64(2)}
	return {}
