extends RefCounted
class_name AlchemyNet

## The alchemy window's requests and replies (round 768), mirroring
## server/internal/session/alchemy.go.
##
## READ (sro_client.exe): the strengthening tab's start (CAlchemyMgrReinforce
## vslot 38, 0x57a810) sends retail 0x7150 for an elixir (0x825c50) and 0x7151
## for a stone (0x825dc0), both `u8 2, u8 op, u8 n, n x u8 slot` -- op 3 an
## elixir, 8 an advanced elixir, 4 a magic or bless stone, 5 an attribute
## stone; each slot is the bag index + 13 (the equipment slots come first),
## in the order target, elixir or stone, lucky powder. Its cancel (vslot 40,
## 0x8210f0) sends `u8 1`. The replies: 0xB150 (0x8729e0) and 0xB151
## (0x872cd0),
##   u8 2, u16 code                                   a refusal
##   u8 1, u8 1                                       cancelled
##   u8 1, u8 2, u8 success, u8 slot,
##     [0xB150, failed: u8 destroyed], [unless destroyed: the item record]
##
## OURS: OpenSRO's own opcodes. One request, 0x0113, carries 0x7150's body for
## every op; the replies keep retail's split, 0x0114 for 0xB150's body and
## 0x0115 for 0xB151's. 0x0113..0x0115 were free on 2026-10-11 (the highest
## ops in client/scripts/net and server/internal were RecallNet's 0x0111 and
## 0x0112). The server pins the same numbers.

const OP_REQUEST := 0x0113
const OP_REINFORCE_RESULT := 0x0114
const OP_STONE_RESULT := 0x0115

const ACTION_CANCEL := 1
const ACTION_START := 2

const OP_REINFORCE := 3
const OP_MAGIC := 4
const OP_ATTR := 5
const OP_UPPER := 8

## Bag index 0 on the wire: the 13 equipment slots come first.
const FIRST_BAG_SLOT := 13

## The refusal the client treats as a lost stone roll (0x872cd0: the failure
## effect and UIIT_MSG_REINFORCERR_FAIL instead of the error line).
const CODE_ENCHANT_FAILED := 0x5423

class Result:
	## Which reply: true for 0x0114 (0xB150's body), false for 0x0115.
	var reinforce: bool = true
	var ok: bool = false
	## A refusal's code.
	var code: int = 0
	var cancelled: bool = false
	var success: bool = false
	## The target's bag index (the wire slot - 13).
	var bag_slot: int = -1
	var destroyed: bool = false
	## The target afterwards; null when it was destroyed.
	var record: ItemInstance = null

## A start: `op` and the bag indices in order (target, elixir or stone,
## [powder]).
static func encode_start(op: int, bag_slots: Array) -> PackedByteArray:
	var out := PackedByteArray([ACTION_START, op, bag_slots.size()])
	for s in bag_slots:
		out.append(int(s) + FIRST_BAG_SLOT)
	return out

static func encode_cancel() -> PackedByteArray:
	return PackedByteArray([ACTION_CANCEL])

## Decodes either reply; null for a shape neither has.
static func decode_result(data: PackedByteArray, reinforce: bool) -> Result:
	if data.size() < 2:
		return null
	var r := Result.new()
	r.reinforce = reinforce
	if data[0] == 2:
		if data.size() != 3:
			return null
		r.code = data.decode_u16(1)
		return r
	if data[0] != 1:
		return null
	r.ok = true
	if data[1] == 1:
		r.cancelled = true
		return r
	if data[1] != 2 or data.size() < 4:
		return null
	r.success = data[2] != 0
	r.bag_slot = int(data[3]) - FIRST_BAG_SLOT
	var at := 4
	if reinforce and not r.success:
		if data.size() < 5:
			return null
		r.destroyed = data[4] != 0
		at = 5
	if r.success or not r.destroyed:
		var rec := ItemInstance.read_record(data, at)
		if rec[0] == null:
			return null
		r.record = rec[0]
		r.record.slot = r.bag_slot
	return r
