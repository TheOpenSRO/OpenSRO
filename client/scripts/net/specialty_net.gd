extends RefCounted
class_name SpecialtyNet

## Round 801: the specialty trade's messages as the client reads and writes
## them, mirroring server/internal/session/specialtytrade.go. READ in
## sro_client.exe unless a line says otherwise (docs/protocol/jobs.md,
## "Specialty trade"):
##
##   0x7034 type 0x13  buy into the transport  u8 0x13, u32 cos, u8 tab, u8 slot, u16 count, u32 npc  (c:0x7923a0)
##   0x7034 type 0x14  sell from the transport u8 0x14, u32 cos, u8 slot, u16 count, u32 npc
##   0xB034 type 0x13  1, 0x13, u32 cos, u8 tab, u8 slot, u8 n, n x u8 dest, u16 count   (c:0x87eb50)
##   0xB034 type 0x14  1, 0x14, u32 cos, u8 slot, u16 count, u32 npc, u8 book
##   0x30E0            u8 n, n x {u32 ref item, u32 unit price}                     (c:0x881600)
##   0x30E8            u8 scale                                                      the trade scale
##   0x30E7            u8 kind (1: too far from the transport)                        (c:0x883b10)
##   0x74D4            u32 NPC ref id                                                 (c:0x569dd0)
##   0xB4D4            u16 n, n x {u32 ref item, u16 percent}                         (c:0x88e210)

const TYPE_BUY := 0x13
const TYPE_SELL := 0x14
const OP_PRICES := 0x30E0
const OP_SCALE := 0x30E8
const OP_LEASH := 0x30E7
const OP_INFO := 0x74D4
const OP_INFO_RESULT := 0xB4D4
## The leash's distance in the client's own line: a hard-coded 100 (m)
## formatted into UIIT_MSG_COSERR_TOO_FAR_FROM_TRADECART (c:0x883b10, READ).
const LEASH_METRES := 100
## 0x300C's word for a thief walking into a town with a transport
## (UIIT_MSG_JSERR_ROBBER_CANT_ENTER_TOWN_WITH_CART; the server's
## CGObjPC::vslot_220, s:0x4eb220).
const NOTICE_ROBBER_CART_TOWN := 0x0c01

static func encode_buy(cos: int, tab: int, slot: int, count: int, npc: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_BUY, 0, 0, 0, 0, tab & 0xff, slot & 0xff, 0, 0, 0, 0, 0, 0])
	out.encode_u32(1, cos)
	out.encode_u16(7, count)
	out.encode_u32(9, npc)
	return out

static func encode_sell(cos: int, slot: int, count: int, npc: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_SELL, 0, 0, 0, 0, slot & 0xff, 0, 0, 0, 0, 0, 0])
	out.encode_u32(1, cos)
	out.encode_u16(6, count)
	out.encode_u32(8, npc)
	return out

static func encode_info(npc_ref: int) -> PackedByteArray:
	var out := PackedByteArray([0, 0, 0, 0])
	out.encode_u32(0, npc_ref)
	return out

## A 0xB034 of type 0x13 or 0x14: {ok, type, cos, tab, slot, dests, count,
## npc}; {ok false, code} for a refusal; {} when short.
static func decode_result(data: PackedByteArray) -> Dictionary:
	if data.size() < 1:
		return {}
	if data[0] != 1:
		return {"ok": false, "code": data.decode_u16(1) if data.size() >= 3 else 0}
	if data.size() < 6:
		return {}
	var t: int = data[1]
	var out := {"ok": true, "type": t, "cos": data.decode_u32(2)}
	match t:
		TYPE_BUY:
			if data.size() < 9:
				return {}
			out["tab"] = data[6]
			out["slot"] = data[7]
			var n: int = data[8]
			if data.size() < 9 + n + 2:
				return {}
			var dests: Array = []
			for i in n:
				dests.append(data[9 + i])
			out["dests"] = dests
			out["count"] = data.decode_u16(9 + n)
		TYPE_SELL:
			if data.size() < 14:
				return {}
			out["slot"] = data[6]
			out["count"] = data.decode_u16(7)
			out["npc"] = data.decode_u32(9)
			out["book"] = data[13]
		_:
			return {}
	return out

## 0x30E0: {ref item: unit price}, in the wire's order as "order".
static func decode_prices(data: PackedByteArray) -> Dictionary:
	var out := {"prices": {}, "order": []}
	if data.size() < 1:
		return out
	var n: int = data[0]
	for i in n:
		var at := 1 + 8 * i
		if at + 8 > data.size():
			break
		var item := data.decode_u32(at)
		out["prices"][item] = data.decode_u32(at + 4)
		(out["order"] as Array).append(item)
	return out

## 0xB4D4: [{item, percent}].
static func decode_info(data: PackedByteArray) -> Array:
	var out: Array = []
	if data.size() < 2:
		return out
	var n := data.decode_u16(0)
	for i in n:
		var at := 2 + 6 * i
		if at + 6 > data.size():
			break
		out.append({"item": data.decode_u32(at), "percent": data.decode_u16(at + 4)})
	return out

## Whether a row's TypeIDs make it a specialty good (CGObj::IsSpecialty,
## the TID word 0x46c, c:0x666d40: 3/3/8 and not bionic).
static func is_good(type_ids: Array) -> bool:
	return type_ids.size() >= 3 and int(type_ids[0]) == 3 and int(type_ids[1]) == 3 and int(type_ids[2]) == 8

## The COS inventory's stars (c:0x7a6970, table 0x7a6a28, READ): the first
## min(scale, 5) of the five stars shown, all tinted by the count.
const STAR_COLOURS := [Color8(0x3c, 0x9b, 0xe8), Color8(0x34, 0xc9, 0x7c), Color8(0xff, 0xff, 0xff),
	Color8(0xff, 0x7e, 0x00), Color8(0xfa, 0x48, 0x48)]

static func star_colour(scale: int) -> Color:
	if scale <= 0:
		return Color.WHITE
	return STAR_COLOURS[mini(scale, 5) - 1]

## The open id for a store line at an NPC with ids (CIF_NPCTalk::FUN_007020c0
## case 1, c:0x7022d6..0x702330: 0xc when the NPC's set holds it, else 1).
static func store_open_id(ids: PackedByteArray) -> int:
	return 0x0c if ids.has(0x0c) else 1
