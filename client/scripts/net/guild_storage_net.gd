extends RefCounted
class_name GuildStorageNet

## The guild storage's messages (round 844, lane H; docs/protocol/
## guild_storage.md). All READ from sro_client.exe:
##   - the talk line 0x1d (UIIT_CTL_GUILD_WAREHOUSE) sends 0x7046 {npc, 0x0f}
##     (CIF_NPCTalk::FUN_007020c0 case 0x1d); 0xB046 {1, 0x0f} sends 0x7250
##     {u32 npc} (c:0x888fc8 -> 0x820840(npc, 1));
##   - 0xB250 (Guild_OnWarehouseUseResult c:0x88f630): {1} opens the window
##     (0x79bf40(1), the inventory beside it) and sends 0x7252 {u32 npc}
##     (0x820980); {2, u16 code}: 0x4c48 is followed by the holder's name and
##     shown as UIIT_MSG_GUILD_WAREHOUSE_USE, any other code through the
##     guild's error box (0x778190(0x10, code)); a refusal also ends the NPC
##     talk (0x704B, 0x78fc20);
##   - the window's X (CIFStorageRoom::vslot_043, 0x91) sends 0x7251 {u32 npc}
##     (0x79bf40(0) -> 0x820840(npc, 0)); 0xB251 {1} ends the talk (0x704B)
##     and sounds (0x88d160);
##   - the list: 0x3253 {u64 gold} begins it (0x88d1d0 -> the window's gold,
##     0x6cc470), 0x3255 appends bytes (0x88eb10), 0x3254 parses them
##     (0x88d240): u8 size, u8 n, n x {u8 slot, item record}, slot / 0x1e the
##     page, % 0x1e the cell;
##   - the moves are 0x7034 (the serializer c:0x7923a0, the parser c:0x87eb50):
##     0x1d inside {u8 src, u8 dst, u16 count, u32 npc} -> {src, dst, count};
##     0x1e bag -> storage {u8 src+13, u8 dst, u32 npc} -> {src, dst};
##     0x1f storage -> bag {u8 src, u8 dst+13, u32 npc} -> {src, dst};
##     0x20 gold in, 0x21 gold out {u64 amount} -> {u64 amount}.

const OP_OPEN := 0x7250
const OP_OPEN_RESULT := 0xB250
const OP_CLOSE := 0x7251
const OP_CLOSE_RESULT := 0xB251
const OP_LIST := 0x7252
const OP_LIST_RESULT := 0xB252
const OP_BEGIN := 0x3253
const OP_END := 0x3254
const OP_DATA := 0x3255

const TYPE_INSIDE := 0x1d
const TYPE_DEPOSIT := 0x1e
const TYPE_WITHDRAW := 0x1f
const TYPE_GOLD_IN := 0x20
const TYPE_GOLD_OUT := 0x21

## The NPC interaction the talk line opens (0x7046 {npc, 0x0f}).
const INTERACTION := 0x0f
const BAG_OFFSET := 13
## One page of the window's lattice (CIFStorageRoom builds 0x1e cells).
const PAGE_SLOTS := 30
## The refusal the client words with the holder's name.
const CODE_IN_USE := 0x4c48
const IN_USE_KEY := "UIIT_MSG_GUILD_WAREHOUSE_USE"

## The 0x7034 refusals the storage gets, as the client's item-operation
## table words them (docs/protocol/error_codes.md).
const MOVE_ERROR_TEXT := {
	0x1806: "UIIT_MSG_STRGERR_WRONG_POSITION",
	0x1807: "UIIT_MSG_STRGERR_INVENTORY_FULL",
	0x180f: "UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD",
	0x1814: "UIIT_MSG_STRGERR_ENABLEINPUT_FEWERTHAN_REMAIN",
	0x1829: "UIIT_MSG_STRGERR_SPECIFY_POSITIVE_NUMBER_ONLY",
	0x1834: "UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED",
	0x1843: "UIIT_MSG_STRGERR_INVALID_TARGET_STORAGE",
	0x18b2: "UIIT_MSG_COSPETERR_CANT_MOVETO_CHEST2",
}

static func encode_npc(npc: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, npc)
	return out

static func encode_inside(src: int, dst: int, count: int, npc: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_INSIDE, src, dst, 0, 0, 0, 0, 0, 0])
	out.encode_u16(3, count)
	out.encode_u32(5, npc)
	return out

## bag_slot is the bag index (the +13 added here).
static func encode_deposit(bag_slot: int, dst: int, npc: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_DEPOSIT, bag_slot + BAG_OFFSET, dst, 0, 0, 0, 0])
	out.encode_u32(3, npc)
	return out

static func encode_withdraw(src: int, bag_slot: int, npc: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_WITHDRAW, src, bag_slot + BAG_OFFSET, 0, 0, 0, 0])
	out.encode_u32(3, npc)
	return out

static func encode_gold(deposit: bool, amount: int) -> PackedByteArray:
	var out := PackedByteArray([TYPE_GOLD_IN if deposit else TYPE_GOLD_OUT, 0, 0, 0, 0, 0, 0, 0, 0])
	out.encode_u64(1, amount)
	return out

## 0xB250: {"ok": true} or {"ok": false, "code", "name"} ({} malformed).
static func decode_open_result(data: PackedByteArray) -> Dictionary:
	if data.size() >= 1 and data[0] == 1:
		return {"ok": true}
	if data.size() < 3 or data[0] != 2:
		return {}
	var out := {"ok": false, "code": data.decode_u16(1), "name": ""}
	if int(out.code) == CODE_IN_USE and data.size() >= 5:
		var n := data.decode_u16(3)
		if data.size() >= 5 + n:
			out.name = data.slice(5, 5 + n).get_string_from_utf8()
	return out

## 0xB251 / 0xB252: {"ok": true} or {"ok": false, "code"} ({} malformed).
static func decode_result(data: PackedByteArray) -> Dictionary:
	if data.size() >= 1 and data[0] == 1:
		return {"ok": true}
	if data.size() >= 3 and data[0] == 2:
		return {"ok": false, "code": data.decode_u16(1)}
	return {}

## The list's bytes (0x3254's parse, c:0x88d240): {"capacity", "slots":
## {slot: ItemInstance}} or {} when they do not parse.
static func decode_list(body: PackedByteArray) -> Dictionary:
	if body.size() < 2:
		return {}
	var slots := {}
	var at := 2
	for i in body[1]:
		if at >= body.size():
			return {}
		var slot: int = body[at]
		var rec := ItemInstance.read_record(body, at + 1)
		if rec[0] == null:
			return {}
		var it: ItemInstance = rec[0]
		it.slot = slot
		slots[slot] = it
		at = int(rec[1])
	return {"capacity": int(body[0]), "slots": slots}

## Whether a 0xB034 is a guild storage move's success.
static func is_move_ack(data: PackedByteArray) -> bool:
	return data.size() >= 2 and data[0] == 1 and data[1] >= TYPE_INSIDE and data[1] <= TYPE_GOLD_OUT

## A 0xB034 of these types: {"ok": true, "type", "src", "dst", "count"} or
## {"ok": true, "type", "amount"} for gold; {"ok": false, "code"} a refusal.
static func decode_move(data: PackedByteArray) -> Dictionary:
	if data.size() >= 3 and data[0] == 2:
		return {"ok": false, "code": data.decode_u16(1)}
	if not is_move_ack(data):
		return {}
	var t: int = data[1]
	match t:
		TYPE_GOLD_IN, TYPE_GOLD_OUT:
			if data.size() < 10:
				return {}
			return {"ok": true, "type": t, "amount": data.decode_u64(2)}
		TYPE_INSIDE:
			if data.size() < 6:
				return {}
			return {"ok": true, "type": t, "src": int(data[2]), "dst": int(data[3]), "count": data.decode_u16(4)}
		_:
			if data.size() < 4:
				return {}
			return {"ok": true, "type": t, "src": int(data[2]), "dst": int(data[3])}

## The deposit box's fee, as the client computes it for the guild
## (c:0x6b111a..0x6b11ec): (the unit fee x the count) / 2, at least 1.
static func deposit_fee(unit_fee: int, count: int) -> int:
	return maxi(1, (unit_fee * maxi(1, count)) / 2)
