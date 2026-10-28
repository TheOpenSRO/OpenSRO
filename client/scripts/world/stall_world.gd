extends RefCounted
class_name StallWorld

## Round 839 (lane S): a stall as the world shows it -- the booth, the stall's
## name over the owner, the vendor pose, the stall cursor and the click that
## enters it. READ from sro_client.exe unless marked (docs/protocol/stall.md):
##
## - 0x30B8 (c:0x873c10) and a spawn record with +0x471 == 4 (c:0x9ddee9,
##   the stall block c:0x9de103..0x9de1bd; the spawn's c:0x9ca3d9): the title
##   "[" + name + "]" (c:0x9dc3a0) in the plate item +0x474 in 0xFFFEB5FF
##   (c:0x9c89a0), the decoration at +0x790, and FUN_009dd040(1): the booth
##   (StallBooth) drawn with the character's own world matrix every frame
##   (CICUser::vslot_010 c:0x9dd350) and character state 0xF, whose enter
##   (c:0xa5a330) plays animation type 80 -- `chinaman_vendor01.ban` /
##   `chinawoman_vendor01.ban` in the body's .bsr.
## - 0x30B9 (c:0x8721b0): +0x471 = 0, FUN_009dd040(0) -- the booth deleted,
##   the title cleared, state 3. 0x30BB (c:0x873d60): the title again.
## - The cursor 0xa3 over a stalling player (GameCursor.player_kind). A click
##   on one (c:0x793570 at 0x7938d5) selects it; within 100.0 (+0x24c) it
##   sends 0x70B3 at once, farther it walks there and sends it on arrival
##   (c:0x78f8d0(.., 1, 2) -> 0x78ff60(2, uid); INFERRED from the pending
##   target it sets, +0x634..+0x63c with 80.0 and 20.0).
##
## OURS, disclosed: the booth is the body's sibling of its skeleton, with the
## skeleton's own local turn (PI) and mirror (BodyMirror) -- the character's
## world matrix as this client draws a body; the title is a plate of its own
## 22 px over the name plate (how retail stacks the two is OPEN); a far
## stall's walk ends when it is in reach, then sends.

## Animation type 80, the vendor loop (c:0xa5a330).
const VENDOR_ACTION := 80
const BOOTH_NODE := "StallBooth"
const TITLE_NODE := "StallTitle"
## The title over the name plate, in plate pixels (OURS).
const TITLE_RAISE_PX := 22.0

## The World3D this serves (its helpers: _name_plate, _retail_plate_look,
## _item_rows, _data_pk2, _race_of_body).
var world
## The stall a walk is taking this player to (uid), or -1.
var pending_owner := -1

func _init(w) -> void:
	world = w

static func _net():
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("/root/NetClient") if tree != null else null

## Whether uid (a character id or wire uid) has a stall open.
func stalling(uid: int) -> bool:
	var n = _net()
	return n != null and (n.stalls as Dictionary).has(uid & 0xffffffff)

func info(uid: int) -> Dictionary:
	var n = _net()
	return (n.stalls as Dictionary).get(uid & 0xffffffff, {}) if n != null else {}

## The booth and the title on `node` (the body's root) for uid: put on when
## it stalls, taken off when not. `race` is the body's (0 China, 1 Europe),
## `top` the body's height.
func apply(uid: int, node: Node3D, race: int, top: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var booth := node.get_node_or_null(BOOTH_NODE) as Node3D
	var title := node.get_node_or_null(TITLE_NODE) as Label3D
	print("STALL: %d %s (booth %s, title %s)" % [uid, "stalls" if stalling(uid) else "does not stall",
		str(booth != null), str(title != null)])
	if not stalling(uid):
		if booth != null:
			node.remove_child(booth)
			booth.queue_free()
		if title != null:
			node.remove_child(title)
			title.queue_free()
		return
	var st := info(uid)
	var deco := int(st.get("decoration", 0))
	if booth != null and int(booth.get_meta("decoration", -1)) != deco:
		node.remove_child(booth)
		booth.queue_free()
		booth = null
	if booth == null:
		var path := StallBooth.model_path(world._item_rows.get(deco), race)
		booth = StallBooth.build(world._data_pk2, path)
		if booth != null:
			booth.name = BOOTH_NODE
			booth.set_meta("decoration", deco)
			booth.rotation.y = PI
			BodyMirror.apply(booth)
			node.add_child(booth)
		print("STALL: booth for %d (decoration %d, race %d) -> %s (%s)" % [uid, deco, race, path,
			"built" if booth != null else "not found"])
	var text := StallNet.plate_title(String(st.get("name", "")))
	if title == null:
		title = world._name_plate(text, top, true)
		title.name = TITLE_NODE
		world._retail_plate_look(title, StallNet.TITLE_COLOUR)
		title.offset.y += TITLE_RAISE_PX
		node.add_child(title)
	else:
		title.text = text
		title.position.y = top * (1.0 + world.NAME_PLATE_CLEARANCE_FRACTION)

## A click on a stalling player (c:0x7938d5): 0x70B3 within reach, else the
## walk there first.
func click(uid: int, distance: float, walk: Callable) -> String:
	var n = _net()
	if distance <= StallNet.ENTER_RANGE:
		pending_owner = -1
		n.stall_enter(uid & 0xffffffff)
		return "enter"
	pending_owner = uid
	walk.call()
	return "walk to the stall"

## Each frame while a walk to a stall is on: in reach, 0x70B3. `distance` is
## the player's to it, or < 0 when it is gone.
func step(distance: float) -> void:
	if pending_owner < 0:
		return
	if distance < 0.0 or not stalling(pending_owner):
		pending_owner = -1
		return
	if distance <= StallNet.ENTER_RANGE:
		var n = _net()
		n.stall_enter(pending_owner & 0xffffffff)
		pending_owner = -1
