extends RefCounted
class_name TradeNet

## Opcodes and payload encoding for the player trading system, mirroring
## server/internal/session (trade.go). All require a prior successful
## enter_world (target resolution happens server-side via world.Hub, same
## as whispers/duels).

const OP_REQUEST := 0x00D0          # client -> server
const OP_REQUEST_RESULT := 0x00D1   # server -> client, ack to the requester
const OP_INVITE := 0x00D2           # server -> client, direct to the target
const OP_RESPOND := 0x00D3          # client -> server
const OP_RESPOND_RESULT := 0x00D4   # server -> client, ack to the responder
const OP_STARTED := 0x00D5          # server -> client, direct to both sides
const OP_DECLINED := 0x00D6         # server -> client, direct to the requester
const OP_SET_OFFER := 0x00D7        # client -> server
const OP_OFFER_RESULT := 0x00D8     # server -> client, ack to the offering side
const OP_OFFER_UPDATED := 0x00D9    # server -> client, direct to the other side
const OP_CONFIRM := 0x00DA          # client -> server
const OP_CONFIRM_RESULT := 0x00DB   # server -> client, ack
const OP_COMPLETED := 0x00DC        # server -> client, direct to both sides (what THEY received)
const OP_CANCEL := 0x00DD           # client -> server
const OP_CANCELLED := 0x00DE        # server -> client, direct to both sides

## ItemSlot value meaning "no item offered" -- gold-only, or nothing yet.
const ITEM_SLOT_NONE := -1

## One side's offer.
class Offer:
	var gold: int
	var item_slot: int
	var quantity: int

## Result of decode_invite().
class Invite:
	var requester_name: String

## Result of decode_started().
class Started:
	var partner_name: String

## Result of decode_declined().
class Declined:
	var target_name: String

## Result of decode_offer_updated().
class OfferUpdated:
	var offer: Offer

## Result of decode_completed().
class Completed:
	var received_gold: int
	var received_item_id: int
	var received_quantity: int

## Result of decode_cancelled().
class Cancelled:
	var cancelled_by_name: String

static func _encode_string(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

static func _encode_offer_fields(gold: int, item_slot: int, quantity: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(8)
	out.encode_s64(0, gold)
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_u32(0, item_slot)
	buf.encode_u32(4, quantity)
	out.append_array(buf)
	return out

## Encodes an OpTradeRequest.
static func encode_request(character_name: String, target_name: String) -> PackedByteArray:
	var out := _encode_string(character_name)
	out.append_array(_encode_string(target_name))
	return out

## Encodes an OpTradeRespond.
static func encode_respond(character_name: String, requester_name: String, accept: bool) -> PackedByteArray:
	var out := _encode_string(character_name)
	out.append_array(_encode_string(requester_name))
	out.append(1 if accept else 0)
	return out

## Encodes an OpTradeSetOffer.
static func encode_set_offer(character_name: String, gold: int, item_slot: int, quantity: int) -> PackedByteArray:
	var out := _encode_string(character_name)
	out.append_array(_encode_offer_fields(gold, item_slot, quantity))
	return out

## Encodes an OpTradeConfirm.
static func encode_confirm(character_name: String) -> PackedByteArray:
	return _encode_string(character_name)

## Encodes an OpTradeCancel.
static func encode_cancel(character_name: String) -> PackedByteArray:
	return _encode_string(character_name)

static func _decode_name(data: PackedByteArray) -> String:
	if data.size() < 2:
		return ""
	var name_len := data.decode_u16(0)
	if 2 + name_len > data.size():
		return ""
	return data.slice(2, 2 + name_len).get_string_from_utf8()

static func _decode_offer(data: PackedByteArray) -> Offer:
	if data.size() < 16:
		return null
	var o := Offer.new()
	o.gold = data.decode_s64(0)
	o.item_slot = data.decode_u32(8)
	o.quantity = data.decode_u32(12)
	return o

## Decodes an OpTradeInvite payload.
static func decode_invite(data: PackedByteArray) -> Invite:
	if data.size() < 2:
		return null
	var i := Invite.new()
	i.requester_name = _decode_name(data)
	return i

## Decodes an OpTradeStarted payload.
static func decode_started(data: PackedByteArray) -> Started:
	if data.size() < 2:
		return null
	var s := Started.new()
	s.partner_name = _decode_name(data)
	return s

## Decodes an OpTradeDeclined payload.
static func decode_declined(data: PackedByteArray) -> Declined:
	if data.size() < 2:
		return null
	var d := Declined.new()
	d.target_name = _decode_name(data)
	return d

## Decodes an OpTradeOfferUpdated payload.
static func decode_offer_updated(data: PackedByteArray) -> OfferUpdated:
	var offer := _decode_offer(data)
	if offer == null:
		return null
	var u := OfferUpdated.new()
	u.offer = offer
	return u

## Decodes an OpTradeCompleted payload.
static func decode_completed(data: PackedByteArray) -> Completed:
	if data.size() < 20:
		return null
	var c := Completed.new()
	c.received_gold = data.decode_s64(0)
	c.received_item_id = data.decode_s64(8)
	c.received_quantity = data.decode_u32(16)
	return c

## Decodes an OpTradeCancelled payload.
static func decode_cancelled(data: PackedByteArray) -> Cancelled:
	if data.size() < 2:
		return null
	var c := Cancelled.new()
	c.cancelled_by_name = _decode_name(data)
	return c
