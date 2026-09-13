extends RefCounted
class_name ShopNet

## Opcodes and payload encoding for buying from the NPC shop, mirroring
## server/internal/session (shop.go). Requires a prior login.

const OP_BUY := 0x0050         # client -> server
const OP_BUY_RESULT := 0x0051  # server -> client
const OP_LIST := 0x0052        # client -> server
const OP_LIST_RESULT := 0x0053 # server -> client

## Result of decode_buy_result().
class BuyResult:
	var ok: bool
	var reason: String
	var error: String # decode error, distinct from a well-formed "not ok" response

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
