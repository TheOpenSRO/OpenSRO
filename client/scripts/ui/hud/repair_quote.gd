extends RefCounted
class_name RepairQuote

## Round 829: what the original client quotes before a repair, READ from
## sro_client.exe (docs/protocol/durability.md has the server's side).
##
## - **The cost of one item** (SOItem::FUN_008bacc0, x87 at 0x8bad39..0x8bae00):
##   a broken item (durability 0) costs its CostRevive (ref +0xc4, itemdata
##   column 28) and is counted from 1; then the missing points times the unit
##   price, CostRepair (ref +0xc0, column 27) over the maximum, held to
##   1.0 .. 9.9999997e37, cut toward zero (the control word OR 0xC00).
##   Nothing for an item at its maximum. The total is an int sum.
## - **Which items a Repair All counts** (0x6abd50 + 0x6b6050): worn slots
##   0..7 (the job suit and the accessories, 8..12, are not walked) and every
##   bag slot; an item counts when it is equipment (3/1, the type word's bit 1
##   clear), not an accessory (TypeID3 5 or 12), can be repaired
##   (can_be_repaired) and costs more than 0. CanRepair (column 22) is not
##   asked here -- only by the hammer's click (CIFSlotWithHelp::vslot_029
##   0x6811e9).
## - **Whether an item can be repaired** (0x8bd0e0): not when one of its magic
##   options is MATTR_NOT_REPARABLE, nor when it has MATTR_REPAIR at 1 or
##   less; anything that is not equipment answers yes.
## OURS: GDScript's float64 stands in for the x87's 80-bit arithmetic.

const MIN_UNIT := 1.0
const MAX_UNIT := 9.9999997e37
## The worn slots a Repair All walks (0x6abd50: 8 iterations).
const WORN_SLOTS := 8

## One item's cost in gold.
static func cost(current: int, maximum: int, cost_repair: int, cost_revive: int) -> int:
	if maximum <= 0:
		return 0
	var cur := current
	var fee := 0
	if cur == 0:
		fee = cost_revive
		cur = 1
	var diff := maximum - cur
	if diff <= 0:
		return 0
	var unit := clampf(float(cost_repair) / float(maximum), MIN_UNIT, MAX_UNIT)
	return int(float(diff) * unit) + fee

## Whether a Repair All counts an item of these TypeIDs at all.
static func counts(types: PackedInt32Array) -> bool:
	return types.size() >= 4 and types[0] == 3 and types[1] == 1 and types[2] != 5 and types[2] != 12

## 0x8bd0e0 on an item's magic options ([{code, value}], ItemTooltipInstance.
## option_entries).
static func can_be_repaired(types: PackedInt32Array, options: Array) -> bool:
	if types.size() < 2 or types[0] != 3 or types[1] != 1:
		return true
	for o in options:
		var code := String((o as Dictionary).get("code", ""))
		if code == "MATTR_NOT_REPARABLE":
			return false
		if code == "MATTR_REPAIR" and int((o as Dictionary).get("value", 0)) <= 1:
			return false
	return true
