extends RefCounted
class_name EquipTarget

## Round 829: which worn slot a bag item goes to when it is put down on the
## equipment window -- on any of its slots or on the character picture -- or
## when a quick slot holding it is pressed. READ, sro_client.exe:
##
## - CIFEquipment::vslot_028 (0x6ad180) takes a held BAG slot (kind 0x46)
##   only; anything else is put back and nothing is sent. It never looks at
##   the slot or the picture under the cursor: the item's TypeIDs choose the
##   worn slot (below), and 0x7950b0(0x46, bag, 0x47, worn) sends 0x7034
##   type 0. Every worn slot (CIFSlotWithHelp::vslot_028 0x666560 hands the
##   drop to its parent) and the picture reach it the same way.
## - A quick slot holding a bag item that is not 3/3/x (but ammo 3/3/4) nor
##   3/2/x is pressed through the same handler: 0x60b850 case 0x46
##   (0x60b94f..0x60ba95) holds the bag slot, calls CIFEquipment's vslot 28
##   and lets go.
##
## The rule, tested in this order (0x6ad1ed.., the TypeID tests 0x56fa80,
## 0x56fab0, 0x60ae20, 0x56fa30, 0x56fb40; the CICPlayer bytes +0x896..+0x898
## are the constants 6, 7, 8 from its constructor 0x9da6d0):
##
## | TypeIDs | worn slot |
## |---|---|
## | 3/1/7/x (job suit, PvP voucher) | 8 |
## | 3/1/13/x, 3/1/14/x (avatars, devil's spirit) | the avatar storage (AvatarEquipment) |
## | 3/1/6/x (every weapon) | 6 |
## | 3/1/4/1, 3/1/4/2 (shields), 3/3/4/x (ammo) | 7 |
## | 3/1/{1,2,3,9,10,11}/n (armour) | n: 1 head 0, 2 shoulder 2, 3 mail 1, 4 pants 4, 5 gauntlet 3, 6 boots 5 |
## | 3/1/{5,12}/n (accessories) | 1 earring 9, 2 necklace 10, 3 ring: 11 when 11 is empty, else 12 when 12 is empty, else 11 (0x6ad502..0x6ad516) |
## | anything else | none: nothing sent, no message |

const HEAD := 0
const MAIL := 1
const SHOULDER := 2
const GAUNTLET := 3
const PANTS := 4
const BOOTS := 5
const WEAPON := 6
const SHIELD := 7
const JOB := 8
const EARRING := 9
const NECKLACE := 10
const RING_LEFT := 11
const RING_RIGHT := 12

## Armour TypeID4 -> worn slot (the jump table at 0x6ad594).
const ARMOUR_SLOT := {1: HEAD, 2: SHOULDER, 3: MAIL, 4: PANTS, 5: GAUNTLET, 6: BOOTS}
const ARMOUR_TID3 := [1, 2, 3, 9, 10, 11]
const ACCESSORY_TID3 := [5, 12]

## The worn slot `types` (TypeID1..4) goes to, or -1 for none (an avatar
## included: AvatarEquipment places those). `worn(slot) -> bool` says
## whether a worn slot holds something (the ring rule asks).
static func worn_slot_for(types: PackedInt32Array, worn: Callable) -> int:
	if types.size() < 4 or types[0] != 3:
		return -1
	var t2 := types[1]
	var t3 := types[2]
	var t4 := types[3]
	if t2 == 3 and t3 == 4:
		return SHIELD
	if t2 != 1:
		return -1
	if t3 == 7:
		return JOB
	if t3 == 13 or t3 == 14:
		return -1
	if t3 == 6:
		return WEAPON
	if t3 == 4 and (t4 == 1 or t4 == 2):
		return SHIELD
	if t3 in ARMOUR_TID3:
		return int(ARMOUR_SLOT.get(t4, -1))
	if t3 in ACCESSORY_TID3:
		match t4:
			1:
				return EARRING
			2:
				return NECKLACE
			3:
				if not bool(worn.call(RING_LEFT)):
					return RING_LEFT
				if not bool(worn.call(RING_RIGHT)):
					return RING_RIGHT
				return RING_LEFT
	return -1

## Whether pressing a quick slot that holds this bag item equips it rather
## than using it (0x60b850 case 0x46): anything but 3/3/x (ammo 3/3/4 aside)
## and 3/2/x.
static func equips_from_quick_slot(types: PackedInt32Array) -> bool:
	if types.size() < 3 or types[0] != 3:
		return false
	if types[1] == 3:
		return types[2] == 4
	return types[1] != 2

## Round 830: where a quick slot's item binding goes after a list (World3D.
## _resync_quickslot_items): the bag slot the item is in now, KEEP_INERT (-1,
## the slot stays on the bar and does nothing) or CLEAR (-2, the item is gone).
## `bag` is {bag slot: item id}; `worn` / `pending` the ids worn now and those
## with an equip on its way. `bag_fresh` is false when the list that triggered
## this is a worn list: an equip answers with the worn list first and the bag
## list (its own request) after, so an item the worn list just dropped -- the
## one a swap put back in the bag, the shield a two-hander displaced -- is in
## neither until that bag list lands, and must not be cleared from a stale
## bag. Clearing it there was the round 830 bug (the previous weapon's quick
## slot emptied on a swap over a real network; on one box the bag list beat
## the deferred resync).
const KEEP_INERT := -1
const CLEAR := -2

static func quick_slot_binding(item_id: int, bag_slot: int, bag: Dictionary, worn: Dictionary,
		pending: Dictionary, equipment_known: bool, bag_fresh: bool) -> int:
	var found := HudUnderbar.resolve_item_binding(item_id, bag_slot, bag)
	if found >= 0:
		return found
	if worn.has(item_id) or pending.has(item_id) or not equipment_known or not bag_fresh:
		return KEEP_INERT
	return CLEAR
