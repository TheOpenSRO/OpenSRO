extends RefCounted
class_name AvatarEquipment

## The equipment window's avatar slots as CIFEquipment runs them (round 789,
## lane AC): which window an avatar is shown in, which storage slot a drop
## asks for, what the client refuses before sending, and when the devil's
## spirit's skill strip shows. Pure rules over the avatar inventory
## (NetClient.last_avatar_instances) and an item-type lookup; HudPanels draws
## and sends. Every rule is READ from sro_client.exe in
## /root/opensro-pk3av789/AVATAR_RESEARCH.md (1.2, 2.1) and
## AVATAR_ALCHEMY_RESEARCH.md ("GDR_AVATAR_SKILL_WND") unless labelled.
##
## **Display is by type, storage is not** (c:0x6abcd0): the window index is
## TypeID4 - 1 for a 3/1/13 (0 hat, 1 dress, 2 attachment, 3 flag) and
## TypeID4 + 3 for a 3/1/14 (4, the devil's spirit) -- GDR_AVATAR_SLOT_01..05
## in that order -- while the slot on the wire is the storage index 0..4 the
## item sits in, which the client picks as the first empty one.

## The display windows (GDR_AVATAR_SLOT_01..05).
const DISPLAY_HAT := 0
const DISPLAY_DRESS := 1
const DISPLAY_ATTACHMENT := 2
const DISPLAY_FLAG := 3
const DISPLAY_DEVIL_SPIRIT := 4
const DISPLAYS := 5

## The client's own refusals of a drop (c:0x6ad180), shown as a local
## message, nothing sent.
const REFUSE_SAME_TYPE := "UIIT_MSG_STRGERR_EQUIPITEM"
const REFUSE_NEEDS_DRESS := "UIIT_STT_AVATAR_MAIL_ONLY_WEAR"

## The display window of an item by its TypeID1..4, or -1 for anything that
## is not an avatar or a devil's spirit (READ c:0x6abcd0).
static func display_index(type_ids: PackedInt32Array) -> int:
	if type_ids.size() < 4 or type_ids[0] != 3 or type_ids[1] != 1:
		return -1
	if type_ids[2] == 13 and type_ids[3] >= 1 and type_ids[3] <= 4:
		return type_ids[3] - 1
	if type_ids[2] == 14 and type_ids[3] == 1:
		return type_ids[3] + 3
	return -1

## Whether an item goes to the avatar inventory at all: TypeID 3/1/13 or
## 3/1/14 (the client offers only 0x23/0x24 for kind 0x4e, READ c:0x7950b0).
static func is_avatar_item(type_ids: PackedInt32Array) -> bool:
	return type_ids.size() >= 3 and type_ids[0] == 3 and type_ids[1] == 1 and (type_ids[2] == 13 or type_ids[2] == 14)

## The avatar inventory by display window: {display index: storage slot}.
## `storage` is {storage slot: ItemInstance or a RefItemID}; `types_of` a
## Callable(ref id) -> PackedInt32Array. Two items of one display (the
## server never allows it, s:0x4ba130) keep the lower storage slot.
static func by_display(storage: Dictionary, types_of: Callable) -> Dictionary:
	var out := {}
	var slots := storage.keys()
	slots.sort()
	for s in slots:
		var d := display_index(types_of.call(_ref_of(storage[s])))
		if d >= 0 and not out.has(d):
			out[d] = int(s)
	return out

static func _ref_of(v) -> int:
	if v is ItemInstance:
		return (v as ItemInstance).ref_item_id
	return int(v)

## What a drop of an item of `type_ids` on the equipment window does (READ
## CIFEquipment::vslot_028 c:0x6ad180; the hovered slot is not looked at):
## {"send": true, "dst": storage slot} or {"refuse": message key}; {} when the
## item is no avatar (not this window's avatar path).
## - 3/1/13: the display window of its TypeID4 already holds one ->
##   UIIT_MSG_STRGERR_EQUIPITEM; an attachment (13/3) while the dress window
##   is empty -> UIIT_STT_AVATAR_MAIL_ONLY_WEAR; else the first empty storage
##   slot 0..4, or 5 when all are full (the client sends it; the server
##   answers 3).
## - 3/1/14: storage slot 4, no client check (c:0x55edf0).
static func drop_target(type_ids: PackedInt32Array, storage: Dictionary, types_of: Callable) -> Dictionary:
	if not is_avatar_item(type_ids) or type_ids.size() < 4:
		return {}
	if type_ids[2] == 14:
		return {"send": true, "dst": AvatarNet.DEVIL_SPIRIT_SLOT}
	var shown := by_display(storage, types_of)
	var d := display_index(type_ids)
	if d >= 0 and shown.has(d):
		return {"refuse": REFUSE_SAME_TYPE}
	if d == DISPLAY_ATTACHMENT and not shown.has(DISPLAY_DRESS):
		return {"refuse": REFUSE_NEEDS_DRESS}
	for k in AvatarNet.STORAGE_SIZE:
		if not storage.has(k):
			return {"send": true, "dst": k}
	return {"send": true, "dst": AvatarNet.STORAGE_SIZE}

## Whether the attachment window is greyed: a dress is worn whose
## ChildItemCount (itemdata col 159, ref +0x535 INFERRED) is 0 (READ
## c:0x6ae6a3, c:0x6ae9a8: FUN_00b8f540(0) + FUN_006668f0(1) on window 2).
static func attachment_disabled(storage: Dictionary, types_of: Callable, child_count_of: Callable) -> bool:
	var shown := by_display(storage, types_of)
	if not shown.has(DISPLAY_DRESS):
		return false
	return int(child_count_of.call(_ref_of(storage[shown[DISPLAY_DRESS]]))) == 0

## Whether GDR_AVATAR_SKILL_WND shows (READ c:0x6abde0): in avatar mode only,
## when one of the five slots holds a non-bionic 3/1/14 whose remaining time
## (SOItem +0x60) is above 0 -- a worn, awake devil's spirit. The remaining
## time is the record's period word's low 31 bits while its bit 31 says it
## was activated (s:0x42e5c3..0x42e63f; INFERRED that +0x60 is that word).
static func skill_strip_shown(avatar_mode: bool, storage: Dictionary, types_of: Callable) -> bool:
	if not avatar_mode:
		return false
	for s in storage:
		var v = storage[s]
		var t: PackedInt32Array = types_of.call(_ref_of(v))
		if t.size() < 3 or t[0] != 3 or t[1] != 1 or t[2] != 14:
			continue
		if v is ItemInstance and spirit_seconds_left(v as ItemInstance) > 0:
			return true
	return false

## A devil's spirit's period word (READ s:0x42e5c3..0x42e63f): bit 31 set once
## it was activated, the low 31 bits the seconds left (0 once expired).
static func spirit_active(it: ItemInstance) -> bool:
	return (it.durability >> 31) & 1 == 1

static func spirit_seconds_left(it: ItemInstance) -> int:
	return it.durability & 0x7fffffff if spirit_active(it) else 0
