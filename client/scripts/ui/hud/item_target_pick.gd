extends RefCounted
class_name ItemTargetPick

## Round 838 (lane 2): the switch tools' own rules -- TypeID 3/3/13/8, the
## gender switch tool and the private server's switchers -- inside HudPanels'
## use-on mode (lane 4's: the gold 0xa6 arrow, the target click, box 0x1f;
## docs/protocol/item_switchers.md has both lanes' READ citations).
##
## READ, sro_client.exe SendItem_HandleUseItem 0x796660, case 8 (the box's
## OK): a worn target is refused on the spot with 0x1882
## (UIIT_MSG_STRGERR_CANT_MUTATE_EQUIPED_ITEM, the client posting itself
## 0xB04C {2, code}); a bag target that is not armour (FUN_0056fa30) with
## 0x1884; any other window sends nothing; otherwise 0x704C {u8 slot + 13,
## u16 type word, u8 target + 13}. OpenSRO's request carries the target's wire
## slot in its Option byte (World3D._on_use_on_requested).
##
## OURS: the private server's tools (the avatar, devil's spirit and flag
## switchers, the type switchers, the model switchers) take the same pick and
## box -- their descriptions' "right click this scroll, then left click on the
## item ... click Yes on the confirmation window" -- without the armour test,
## which is retail's tool's; the server decides what each takes.

## The window kinds a target click names (CIFSlotWithHelp's kind byte).
const KIND_BAG := 0x46
const KIND_WORN := 0x47
const KIND_AVATAR := 0x4e
## SendItem_HandleUseItem case 8's own refusals (error_codes.md).
const ERR_EQUIPPED := 0x1882
const ERR_TARGET := 0x1884

## Whether TypeIDs are a switch tool, 3/3/13/8 (UseByKind case 8).
static func is_switch_tool(types: PackedInt32Array) -> bool:
	return types.size() >= 4 and types[0] == 3 and types[1] == 3 and types[2] == 13 and types[3] == 8

## Whether a 3/3/13/8 row is the private server's own (OURS, the server's
## switchToolOf): those skip retail's client-side armour test.
static func is_private_tool(code: String) -> bool:
	if code in ["ITEM_AVATAR_SWITCHER", "ITEM_DEVIL_SWITCHER", "ITEM_GDF_SWITCHER"]:
		return true
	if code.begins_with("ITEM_MODEL_") or code.begins_with("ITEM_MODELSWITCHER_") or code.begins_with("ITEM_UPGRADESTONE_"):
		return true
	return code.ends_with("_SWITCHER") or code.ends_with("_UNLOCK")

## Whether TypeIDs are armour: FUN_0056fa30, equipment whose TypeID3 is 1, 2,
## 3, 9, 10 or 11 (the client's copy of the server's CGObj::IsArmor).
static func is_armour(types: PackedInt32Array) -> bool:
	return types.size() >= 4 and types[0] == 3 and types[1] == 1 and types[2] in [1, 2, 3, 9, 10, 11]

## What the box's OK does with a target (SendItem_HandleUseItem case 8): 0
## sends the use; a code refuses with it; -1 does nothing.
static func check(tool_code: String, kind: int, target_types: PackedInt32Array) -> int:
	if kind == KIND_WORN:
		return ERR_EQUIPPED
	if kind != KIND_BAG:
		return -1
	if not is_private_tool(tool_code) and not is_armour(target_types):
		return ERR_TARGET
	return 0
