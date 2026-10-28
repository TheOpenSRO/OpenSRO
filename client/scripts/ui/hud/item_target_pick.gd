extends RefCounted
class_name ItemTargetPick

## Round 838: a tool used on another item -- the 3/3/13/8 tools (the gender
## switch tool and the private server's switchers). docs/protocol/
## item_switchers.md has the whole flow; HudPanels holds the state.
##
## READ, sro_client.exe:
##   - The right-click (IFSlotWithHelp::FUN_00676570, 0x6769a5..0x6769ff): a
##     3/3/13 item (FUN_005dd680) whose CanUse byte (ref +0xac) has 0x81 set
##     and whose TypeID4 is 8, 0xc, 0xf or 0x10 is not used: the inventory
##     keeps its slot (+0x380, FUN_006aef80) and the cursor is forced to 0xa6
##     (FUN_00777e70), the bright gold arrow (CursorSet.ID_ITEM_USE).
##   - The next left click on a slot holding an item (CIFSlotWithHelp::vslot_029
##     0x681130..0x6811b8) -- a bag slot (0x46), a worn slot (0x47) or an avatar
##     slot (0x4e) -- opens message box 0x1f (UIIT_STT_CONFIRM_BOX,
##     UIIT_MSG_QUESTION_SILKMALL_ITEM_USE "Will you use the selected item?";
##     the box's values "1" the tool's slot, "2" the clicked slot, "3" its
##     window kind) and clears the cursor. A click on an empty slot does
##     nothing and the cursor stays.
##   - The box's OK (FUN_00797d90 case 0x1f) sends the use with the target
##     (SendItem_HandleUseItem 0x796660, case 8): a worn target is refused on
##     the spot with 0x1882 (UIIT_MSG_STRGERR_CANT_MUTATE_EQUIPED_ITEM, the
##     client posting itself 0xB04C {2, code}); a bag target that is not armour
##     (FUN_0056fa30) with 0x1884; any other window sends nothing; otherwise
##     0x704C {u8 slot + 13, u16 type word, u8 target + 13}.
##   - A forced cursor is cleared by Escape (FUN_0078b660 0x1b -> FUN_0079d620)
##     and by the right button going down (CGInterface::vslot_017 WM_RBUTTONDOWN,
##     0x77c733).
##
## OURS: the private server's tools (the avatar, devil's spirit and flag
## switchers, the type switchers, the model switchers) take the same pick and
## box -- their descriptions' "right click this scroll, then left click on the
## item ... click Yes on the confirmation window" -- without the armour test,
## which is retail's tool's; the server decides what each takes. OpenSRO's
## request carries the target's wire slot in its Option byte (UseItemNet).

## The TypeID4s under 3/3/13 whose right-click picks a target (READ: the
## switch at 0x6769d0 sends 8, 0xc, 0xf and 0x10 to the pick). Round 838 wires
## 8, the switch tools; 0xc, 0xf and 0x10 have their own target rules in
## SendItem_HandleUseItem and stay as they were (OPEN).
const KINDS := [8]
## The CanUse bits the pick needs (0x6769ad `and al,0x81; cmp al,0x81`).
const CAN_USE_MASK := 0x81
## The window kinds a target click names (CIFSlotWithHelp's kind byte).
const KIND_BAG := 0x46
const KIND_WORN := 0x47
const KIND_AVATAR := 0x4e
## The box's question.
const CONFIRM_KEY := "UIIT_MSG_QUESTION_SILKMALL_ITEM_USE"
const CONFIRM_FALLBACK := "Will you use the selected item?"
## SendItem_HandleUseItem case 8's own refusals (error_codes.md).
const ERR_EQUIPPED := 0x1882
const ERR_TARGET := 0x1884

## Whether an item row picks a target on its right-click.
static func is_pick_tool(item: ItemTableReader.Item) -> bool:
	if item == null or item.type_ids.size() < 4:
		return false
	var t := item.type_ids
	return t[0] == 3 and t[1] == 3 and t[2] == 13 and KINDS.has(t[3]) \
		and (item.can_use & CAN_USE_MASK) == CAN_USE_MASK

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
