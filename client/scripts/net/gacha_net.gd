extends RefCounted
class_name GachaNet

## Magic POP on the wire (round 838, lane 5). READ from both binaries
## (docs/protocol/magic_pop.md) unless a line says otherwise:
##
##   0x7118 C->S  u32 npc uid, u32 GachaID, u8 card's bag slot + 13
##                (the PLAY timer c:0x746df8; s:0x511570)
##   0xB118 S->C  u8 1, u8 win (the coupon's Param1) | u8 2, u16 code
##                (c:0x88d690 keeps only the code's low byte; s:0x4e7250)
##   0x7119 C->S  u32 npc uid (Gori's line 0x28, c:0x7020c0; s:0x5115e0)
##   0xB119 S->C  u8 2, u16 code -- a failure only (c:0x88d700)
##   0x3120 S->C  u32 prize ref id, u16 count (c:0x88f880, the win notice)

const OP_PLAY := 0x7118
const OP_PLAY_RESULT := 0xB118
const OP_EXCHANGE := 0x7119
const OP_EXCHANGE_RESULT := 0xB119
const OP_ANNOUNCE := 0x3120
const BAG_BASE := 13

static func encode_play(npc_uid: int, gacha_id: int, bag_slot: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(9)
	b.encode_u32(0, npc_uid)
	b.encode_u32(4, gacha_id)
	b[8] = bag_slot + BAG_BASE
	return b

static func encode_exchange(npc_uid: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, npc_uid)
	return b

## 0xB118: {"ok": true, "win": bool} or {"ok": false, "code": int}.
static func decode_play_result(d: PackedByteArray) -> Dictionary:
	if d.size() >= 2 and d[0] == 1:
		return {"ok": true, "win": d[1] != 0}
	return {"ok": false, "code": d.decode_u16(1) if d.size() >= 3 else 0}

## 0xB119's code.
static func decode_failure(d: PackedByteArray) -> int:
	return d.decode_u16(1) if d.size() >= 3 else 0

## 0x3120: {"ref", "count"}.
static func decode_announce(d: PackedByteArray) -> Dictionary:
	if d.size() < 6:
		return {}
	return {"ref": d.decode_u32(0), "count": d.decode_u16(4)}
