extends RefCounted
class_name EquipmentNet

## Opcodes and payload encoding for equip/unequip, mirroring
## server/internal/session (equipment.go). Requires a prior login.

const OP_LIST := 0x0040    # client -> server
const OP_RESULT := 0x0041  # server -> client (list, or equip/unequip result)
const OP_EQUIP := 0x0042   # client -> server
const OP_UNEQUIP := 0x0043 # client -> server

## Slot numbers in the game's own order -- the order the client's
## equipment window loads its slot artwork in and its avatar's equip-visual
## struct keeps them in (see docs/protocol/EQUIP_SLOTS.md): helm, mail,
## shoulder guard, gauntlet, pants, boots, weapon, shield, then the
## accessories. Mirrors server/internal/equipment's Slot enum.
const SLOT_HELM := 0
const SLOT_MAIL := 1
const SLOT_SHOULDER_GUARD := 2
const SLOT_GAUNTLET := 3
const SLOT_PANTS := 4
const SLOT_BOOTS := 5
const SLOT_WEAPON := 6
const SLOT_SHIELD := 7
const SLOT_EXTRA := 8

## The six worn armour slots, in slot order. Mirrors
## server/internal/equipment.ArmorSlots.
const ARMOR_SLOTS := [SLOT_HELM, SLOT_MAIL, SLOT_SHOULDER_GUARD, SLOT_GAUNTLET, SLOT_PANTS, SLOT_BOOTS]

## Every slot whose item is drawn on the character: the armour plus what
## the hands hold.
const WEARABLE_SLOTS := [SLOT_HELM, SLOT_MAIL, SLOT_SHOULDER_GUARD, SLOT_GAUNTLET, SLOT_PANTS, SLOT_BOOTS, SLOT_WEAPON, SLOT_SHIELD]

## One equipped item.
class Equipped:
	var slot: int
	var item_id: int

## Result of decode_result(): either a list (from OP_LIST) or just an
## error/success marker (from OP_EQUIP/OP_UNEQUIP -- items is empty then).
class Result:
	var durabilities: Array = []  # InventoryNet.Durability, from the trailing block
	var error: String
	var items: Array[Equipped] = []

## Encodes an OpEquipmentList request: just a character name.
static func encode_list_request(character_name: String) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	return out

## Encodes an OpEquip request.
static func encode_equip(character_name: String, slot: int, inventory_slot: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_u32(0, slot)
	buf.encode_u32(4, inventory_slot)
	out.append_array(buf)
	return out

## Encodes an OpUnequip request. `to_bag_slot` is the bag slot the worn
## item was put down on (round 652), sent as a trailing int32 -- the retail
## client names it too (FUN_007950b0, 0x47 -> 0x46: `bag slot + 13`). -1
## sends none, and the server picks the first free slot.
static func encode_unequip(character_name: String, slot: int, to_bag_slot: int = -1) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_u32(0, slot)
	out.append_array(buf)
	if to_bag_slot >= 0:
		var to := PackedByteArray()
		to.resize(4)
		to.encode_s32(0, to_bag_slot)
		out.append_array(to)
	return out

static func _decode_equipped(data: PackedByteArray, offset: int) -> Array:
	if offset + 4 > data.size():
		return [null, -1]
	var e := Equipped.new()
	e.slot = data.decode_u32(offset)
	offset += 4
	if offset + 8 > data.size():
		return [null, -1]
	e.item_id = data.decode_s64(offset)
	offset += 8
	return [e, offset]

## Decodes an OpEquipmentResult payload.
static func decode_result(data: PackedByteArray) -> Result:
	var result := Result.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()

	if offset + 2 > data.size():
		result.error = "truncated item count"
		return result
	var count := data.decode_u16(offset)
	offset += 2

	for i in range(count):
		var decoded := _decode_equipped(data, offset)
		if decoded[0] == null:
			result.error = "truncated item %d" % i
			return result
		result.items.append(decoded[0])
		offset = decoded[1]

	# The same trailing per-slot durability block the inventory list carries
	# (session/durability.go); empty against an older server.
	result.durabilities = InventoryNet.decode_durability_block(data, offset)
	return result

## Repair opcodes (session/repair.go). An NPC's repair buttons: restore a
## worn slot, or all worn items, to full durability for gold.
const OP_REPAIR := 0x007a        # client -> server
const OP_REPAIR_RESULT := 0x007b # server -> client
## Slot value meaning "repair everything worn" (session.RepairAllSlots).
const REPAIR_ALL := -1

## Result of decode_repair_result(): a refusal code (0 = repaired), the gold
## spent, and the worn slots' durability afterwards (InventoryNet.Durability).
class RepairResult:
	var code: int
	var gold_spent: int
	var durabilities: Array = []

## Encodes an OpRepair request: character name, then the equipment slot as
## signed 32-bit (REPAIR_ALL for every worn item).
static func encode_repair_request(character_name: String, slot: int) -> PackedByteArray:
	var name_bytes := character_name.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, name_bytes.size())
	out.append_array(name_bytes)
	var tail := PackedByteArray()
	tail.resize(4)
	tail.encode_s32(0, slot)
	out.append_array(tail)
	return out

## Decodes an OpRepairResult payload: s32 code, s64 gold, then the durability
## block. Truncation yields a refusal so the UI never acts on garbage.
static func decode_repair_result(data: PackedByteArray) -> RepairResult:
	var r := RepairResult.new()
	if data.size() < 12:
		r.code = 0x1c11  # CANNOT_BE_REPAIRED
		return r
	r.code = data.decode_s32(0)
	r.gold_spent = data.decode_s64(4)
	r.durabilities = InventoryNet.decode_durability_block(data, 12)
	return r
