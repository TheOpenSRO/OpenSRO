extends RefCounted
class_name DimensionHole

## The Dimension hole on the client (round 869, docs/protocol/forgotten_world.md
## sections 2 and 3): the item that makes a gate to the Forgotten World. Labels:
## READ (sro_client.exe, `c:`), MEASURED, INFERRED, OURS, OPEN.
##
## - **Which item** (READ c:0x666f80): type word 0x3E6C, TypeID 3/3/12/7 (not
##   bionic, (w & 0x1c) == 0xc, (w & 0x60) == 0x60, (w & 0x780) == 0x600,
##   (w & 0xf800) == 0x3800). MEASURED: ITEM_ETC_TELEPORT_HOLE_* ids
##   35883..35904.
## - **The use** (READ): a bag use opens message box 0x2e at once, with no
##   local check (IFSlotWithHelp::FUN_00676570, c:0x677006 -> `push 0x2e`
##   c:0x677039; MsgBoxInif.Kind.MAGIC_HOLE). Its Yes is FUN_00797d90's case
##   0x2e (c:0x79865d), the plain item use through SendItem_HandleUseItem
##   (c:0x796660 -> c:0x797660): retail 0x704C {u8 slot, u16 0x3E6C}. OpenSRO's
##   client sends every item use as UseItemNet.OP_USE_ITEM (0x008a) with the
##   slot, so the hole's goes that way too.
## - **The re-use check** (READ c:0x7972aa..0x7972f5, in SendItem_HandleUseItem,
##   so after the box): an item whose COOLTIME group (ref +0x53c) is not 0 asks
##   the re-use manager (game +0x77c) for the group's time left (0x9ba5c0),
##   otherwise for its own id's (0x9ba6e0); time left -> FUN_00778190(1, 0x185b,
##   0xffdbc99b, 0, 1), UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY "Still have time
##   to reuse the item." in the system line, and nothing is sent. MEASURED: a
##   second hole during the cool time showed that line and sent no packet.
##   The hole's group is 0x71 (COOLTIME:0x00000071, 18,000,000 ms, every hole).
##   ItemCooldowns.data_key is exactly that store choice. (The same check runs
##   for every item in the original's send path; only the hole uses it here.)
## - **Success** (READ c:0x87b478..0x87b4bf, Item_OnUseItemResult): the 0xB04C
##   success for an item of this type word plays prim\snd\ui\gacha_change_2.wav
##   (0xdda9d8) at volume 1.0 through the sound manager's slot +0x30 with the
##   player's +0x90 (INFERRED: its position, where the listener is); played
##   2-D here (OURS).
## - **The tooltip** (READ c:0x66f400, reached from the generic builder
##   UI_SILKMALL::FUN_006860a0 at c:0x686a95..0x686aa3): see tooltip_lines.

const TYPE_WORD := 0x3E6C
const SUCCESS_SOUND := "prim\\snd\\ui\\gacha_change_2.wav"
## UiSounds.fired's entry for the success sound (tests and QA).
const SUCCESS_SOUND_TAG := "FILE:prim\\snd\\ui\\gacha_change_2.wav"
## Category 1's code for the client's own re-use refusal (READ c:0x7972e9).
const REUSE_CODE := 0x185b
## Only when the archive lacks UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY (OURS).
const REUSE_FALLBACK := "Still have time to reuse the item."

## Whether TypeIDs are a Dimension hole's, 3/3/12/7 (c:0x666f80).
static func is_hole(types: PackedInt32Array) -> bool:
	return types.size() >= 4 and types[0] == 3 and types[1] == 3 and types[2] == 12 and types[3] == 7

## The type word of TypeIDs (cash 0, bionic 0): TypeID1 << 2 | TypeID2 << 5 |
## TypeID3 << 7 | TypeID4 << 11 -- 0x3E6C for a hole.
static func type_word(types: PackedInt32Array) -> int:
	if types.size() < 4:
		return 0
	return (types[0] << 2) | (types[1] << 5) | (types[2] << 7) | (types[3] << 11)

## The re-use time left for `item`, in ms (READ c:0x7972aa: its group's entry
## when it has a group, else its own id's). `left_of` is Callable(key: String)
## -> int over ItemCooldowns' keys; unbound, 0.
static func reuse_left_ms(item: ItemTableReader.Item, left_of: Callable) -> int:
	if item == null or not left_of.is_valid():
		return 0
	return int(left_of.call(ItemCooldowns.data_key(item.id, item.cool_group)))

## Box 0x2e's Yes (FUN_00797d90 case 0x2e -> SendItem_HandleUseItem): the
## client's own re-use check, then the use. `left_of` as reuse_left_ms;
## `send` is Callable(slot) -- the item use (OpenSRO 0x008a; retail 0x704C
## {u8 slot, u16 0x3E6C}); `refuse` is Callable(code) for the category-1 line.
## Returns "sent", "reuse" (refused, nothing sent) or "none" (no item).
static func on_yes(item: ItemTableReader.Item, slot: int, left_of: Callable, send: Callable, refuse: Callable) -> String:
	if item == null:
		return "none"
	if reuse_left_ms(item, left_of) > 0:
		refuse.call(REUSE_CODE)
		return "reuse"
	UiSounds.expect_use(item.type_ids)
	send.call(slot)
	return "sent"

## The retail request's payload, 0x704C {u8 slot, u16 type word} (READ
## c:0x797191..0x7971a6; MEASURED in the success capture's 0xB04C echo).
static func retail_use_payload(slot: int) -> PackedByteArray:
	var b := PackedByteArray([slot & 0xff, 0, 0])
	b.encode_u16(1, TYPE_WORD)
	return b

## The hole's tooltip lines (READ c:0x66f400), every one white
## (FUN_00776d20(.., 0, 0xffffffff, 0, 1)), no blank between them:
##   "Level : %s" UIIT_STT_GOD_LV_EXTENT with "%d - %d" of Param3 / Param4
##     (ref +0x2bc / +0x2c0);
##   "Grade : %s" UIIT_STT_GOD_CLASS with UIIT_STT_GOD_CLASS_1..4 by Param1
##     (+0x2b4); another Param1 leaves the buffer as it was, so the line
##     prints the level's "%d - %d" (the switch's default skips the swprintf,
##     c:0x66f52b) -- reproduced;
##   "Number of Players Allowed: 1-%d" UIIT_STT_PARTY_SUMMON with Param5
##     (+0x2c4);
##   "%s %d%s" UIIT_STT_ITEM_FORMAT_COOLTIME, the re-use time left / 1000 while
##     it runs (0x9ba5c0 by group / 0x9ba6e0 by id), else the item's own
##     cool time (+0x540) / 1000; no line when both are 0.
## `t` is Callable(key, fallback) -> String. The running tooltip's once-a-second
## refresh (FUN_00b93320(0xf, 1000)) is not modelled: the line is the time
## left when the tooltip was built (OURS).
static func tooltip_lines(item: ItemTableReader.Item, t: Callable, reuse_left: int) -> Array:
	var out: Array = []
	if item == null:
		return out
	var band := "%d - %d" % [item.param3, item.param4]
	out.append(_fmt(t.call("UIIT_STT_GOD_LV_EXTENT", "Level : %s"), band))
	var grade := band
	if item.param1 >= 1 and item.param1 <= 4:
		var stars := ["★", "★★", "★★★", "★★★★"]
		grade = String(t.call("UIIT_STT_GOD_CLASS_%d" % item.param1, stars[item.param1 - 1]))
	out.append(_fmt(t.call("UIIT_STT_GOD_CLASS", "Grade : %s"), grade))
	var players := String(t.call("UIIT_STT_PARTY_SUMMON", "Number of Players Allowed: 1-%d"))
	out.append(players % [item.param5] if players.count("%d") == 1 and players.count("%") == 1 else players)
	var ms := reuse_left if reuse_left > 0 else item.cool_ms
	if ms != 0:
		out.append("%s %d%s" % [t.call("UIIT_STT_ITEM_FORMAT_COOLTIME", "Reuse time"), ms / 1000,
			t.call("PARAM_SECOND", "Second")])
	return out

static func _fmt(fmt: String, value: String) -> String:
	return fmt.replace("%s", value) if fmt.count("%s") == 1 else fmt
