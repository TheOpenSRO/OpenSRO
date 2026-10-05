extends RefCounted
class_name ShopNet

## Opcodes and payload encoding for buying from the NPC shop, mirroring
## server/internal/session (shop.go). Requires a prior login.

const OP_BUY := 0x0050         # client -> server
const OP_BUY_RESULT := 0x0051  # server -> client
const OP_LIST := 0x0052        # client -> server
const OP_LIST_RESULT := 0x0053 # server -> client
const OP_SELL := 0x0054        # client -> server
const OP_SELL_RESULT := 0x0055 # server -> client

## Result of decode_buy_result().
class BuyResult:
	var ok: bool
	var reason: String
	var error: String # decode error, distinct from a well-formed "not ok" response

## Result of decode_sell_result(). gold_received is the real amount the server
## credited (its own SellValue), so the UI shows the truth, not its estimate.
class SellResult:
	var ok: bool
	var reason: String
	var gold_received: int
	var error: String

## One purchasable item, with enough stats to tell items apart -- refdata
## items have no display name (see docs/protocol/refdata_schema.md).
class CatalogEntry:
	var item_id: int
	var price: int
	var item_class: int
	var phys_attack_max: float
	var phys_defense_max: float

## Result of decode_list_result().
class ListResult:
	var error: String
	var entries: Array[CatalogEntry] = []

## Encodes an OpShopBuy request.
static func encode_buy(character_name: String, item_id: int, quantity: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)

	var id_buf := PackedByteArray()
	id_buf.resize(8)
	id_buf.encode_s64(0, item_id)
	out.append_array(id_buf)

	var qty_buf := PackedByteArray()
	qty_buf.resize(4)
	qty_buf.encode_u32(0, quantity)
	out.append_array(qty_buf)
	return out

## Decodes an OpShopBuyResult payload: 1 OK byte, then a length-prefixed
## reason string (same shape as Auth.decode_result).
static func decode_buy_result(data: PackedByteArray) -> BuyResult:
	var result := BuyResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result

	var ok := data[0] != 0
	if data.size() < 3:
		result.error = "truncated reason length prefix"
		return result

	var reason_len := data.decode_u16(1)
	if 3 + reason_len > data.size():
		result.error = "declared reason length %d exceeds remaining bytes" % reason_len
		return result

	result.ok = ok
	result.reason = data.slice(3, 3 + reason_len).get_string_from_utf8()
	return result

## Encodes an OpShopSell request: sell `quantity` from inventory `slot`.
static func encode_sell(character_name: String, slot: int, quantity: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var tail := PackedByteArray()
	tail.resize(8)
	tail.encode_u32(0, slot)
	tail.encode_u32(4, quantity)
	out.append_array(tail)
	return out

## Decodes an OpShopSellResult payload: 1 OK byte, a length-prefixed reason,
## then an optional 8-byte gold-received tail.
static func decode_sell_result(data: PackedByteArray) -> SellResult:
	var result := SellResult.new()
	if data.size() < 1:
		result.error = "empty payload"
		return result
	result.ok = data[0] != 0
	if data.size() < 3:
		result.error = "truncated reason length prefix"
		return result
	var reason_len := data.decode_u16(1)
	if 3 + reason_len > data.size():
		result.error = "declared reason length %d exceeds remaining bytes" % reason_len
		return result
	result.reason = data.slice(3, 3 + reason_len).get_string_from_utf8()
	var offset := 3 + reason_len
	if offset + 8 <= data.size():
		result.gold_received = data.decode_s64(offset)
	return result

## Encodes an OpShopList request: the item ids to price (the goods the NPC
## sells). Listing only these keeps the reply small -- the full catalogue is
## thousands of items, past a single frame.
static func encode_list_request(item_ids: Array = []) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, item_ids.size())
	for id in item_ids:
		var id_buf := PackedByteArray()
		id_buf.resize(8)
		id_buf.encode_s64(0, int(id))
		out.append_array(id_buf)
	return out

static func _decode_catalog_entry(data: PackedByteArray, offset: int) -> Array:
	if offset + 16 > data.size():
		return [null, -1]
	var e := CatalogEntry.new()
	e.item_id = data.decode_s64(offset)
	e.price = data.decode_s64(offset + 8)
	offset += 16

	if offset + 12 > data.size():
		return [null, -1]
	e.item_class = data.decode_u32(offset)
	e.phys_attack_max = data.decode_float(offset + 4)
	e.phys_defense_max = data.decode_float(offset + 8)
	offset += 12

	return [e, offset]

## Decodes an OpShopListResult payload.
static func decode_list_result(data: PackedByteArray) -> ListResult:
	var result := ListResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()
	if result.error != "":
		return result

	if offset + 2 > data.size():
		result.error = "truncated entry count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_catalog_entry(data, offset)
		if decoded[0] == null:
			result.error = "truncated entry %d" % i
			return result
		result.entries.append(decoded[0])
		offset = decoded[1]

	return result

# --- Buy back (round 728), mirroring server/internal/session/buyback.go ------

const OP_BUYBACK_LIST := 0x0118         # client -> server: my buy-back row
const OP_BUYBACK_LIST_RESULT := 0x0119  # server -> client
const OP_BUYBACK := 0x011A              # client -> server: buy entry N back
const OP_BUYBACK_RESULT := 0x011B       # server -> client

## One buy-back entry: what was sold, how many, and the gold one unit costs.
class BuybackEntry:
	var item_id: int
	var quantity: int
	var unit: int

class BuybackList:
	var error: String
	var entries: Array = []

class BuybackResult:
	var ok: bool
	var reason: String
	var gold_paid: int
	var error: String

static func _name_prefix(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## The list request is a character name.
static func encode_buyback_list(character_name: String) -> PackedByteArray:
	return _name_prefix(character_name)

## The buy request: a character name, then the entry's index as u32.
static func encode_buyback(character_name: String, index: int) -> PackedByteArray:
	var out := _name_prefix(character_name)
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, index)
	out.append_array(b)
	return out

## The list: an error string; when empty, a u8 count and per entry
## i64 item, u32 quantity, i64 unit price.
static func decode_buyback_list(data: PackedByteArray) -> BuybackList:
	var r := BuybackList.new()
	if data.size() < 2:
		r.error = "truncated"
		return r
	var elen := data.decode_u16(0)
	if 2 + elen > data.size():
		r.error = "truncated error"
		return r
	r.error = data.slice(2, 2 + elen).get_string_from_utf8()
	if r.error != "":
		return r
	var off := 2 + elen
	if off + 1 > data.size():
		r.error = "truncated count"
		return r
	var n := data[off]
	off += 1
	for i in range(n):
		if off + 20 > data.size():
			r.error = "entry %d truncated" % i
			return r
		var e := BuybackEntry.new()
		e.item_id = data.decode_s64(off)
		e.quantity = data.decode_u32(off + 8)
		e.unit = data.decode_s64(off + 12)
		off += 20
		r.entries.append(e)
	return r

static func decode_buyback_result(data: PackedByteArray) -> BuybackResult:
	var r := BuybackResult.new()
	if data.size() < 3:
		r.error = "truncated"
		return r
	r.ok = data[0] != 0
	var rlen := data.decode_u16(1)
	if 3 + rlen > data.size():
		r.error = "truncated reason"
		return r
	r.reason = data.slice(3, 3 + rlen).get_string_from_utf8()
	if 3 + rlen + 8 <= data.size():
		r.gold_paid = data.decode_s64(3 + rlen)
	return r
