extends RefCounted
class_name ShopNet

## Opcodes and payload encoding for buying from the NPC shop, mirroring
## server/internal/session (shop.go). Requires a prior login.

const OP_BUY := 0x0050         # client -> server
const OP_BUY_RESULT := 0x0051  # server -> client

## Result of decode_buy_result().
class BuyResult:
	var ok: bool
	var reason: String
	var error: String # decode error, distinct from a well-formed "not ok" response

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
