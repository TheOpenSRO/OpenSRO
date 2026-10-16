extends SceneTree

## Round 789: the equipment window's avatar rules (AvatarEquipment) -- the
## display window by type, the storage slot a drop asks for, the client's own
## refusals, the greyed attachment window, the devil's spirit's skill strip --
## and NetClient's avatar inventory: the list, a move's reply applied to it,
## a refusal routed to the avatar handler, not the item operation's.
##
## NEGATIVE: before round 789 the avatar windows were display-only (nothing
## filled them, nothing could be dropped on them) and a 0xB034 refusal of an
## avatar move would have reached item_op_result.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Test ids -> TypeIDs: hats 10/11, dress 20 (takes an attachment), dress 21
## (takes none), attachment 30, flag 40, devil's spirit 50, a sword 60.
const TYPES := {10: [3, 1, 13, 1], 11: [3, 1, 13, 1], 20: [3, 1, 13, 2], 21: [3, 1, 13, 2], 30: [3, 1, 13, 3],
	40: [3, 1, 13, 4], 50: [3, 1, 14, 1], 60: [3, 1, 6, 2]}

static func types_of(id: int) -> PackedInt32Array:
	return PackedInt32Array(TYPES.get(id, []))

static func child_count(id: int) -> int:
	return 1 if id == 20 else 0

static func inst(ref: int, slot: int, period: int = 0) -> ItemInstance:
	var it := ItemInstance.new()
	it.ref_item_id = ref
	it.slot = slot
	it.durability = period
	return it

func _test_display() -> void:
	var A := AvatarEquipment
	_check(A.display_index(types_of(10)) == 0 and A.display_index(types_of(20)) == 1 and A.display_index(types_of(30)) == 2
		and A.display_index(types_of(40)) == 3 and A.display_index(types_of(50)) == 4,
		"display by type (c:0x6abcd0): hat 0, dress 1, attachment 2, flag 3, devil's spirit 4")
	_check(A.display_index(types_of(60)) == -1 and not A.is_avatar_item(types_of(60)) and A.is_avatar_item(types_of(50)),
		"a sword has no avatar window; a devil's spirit is an avatar item")
	# Storage out of type order: a dress in storage 0, a hat in 1, the spirit in 4.
	var storage := {0: inst(20, 0), 1: inst(10, 1), 4: inst(50, 4)}
	var shown := A.by_display(storage, types_of)
	_check(shown == {1: 0, 0: 1, 4: 4}, "windows show by type, the storage slot kept for the wire: %s" % [shown])

func _test_drop() -> void:
	var A := AvatarEquipment
	var empty := {}
	_check(A.drop_target(types_of(10), empty, types_of) == {"send": true, "dst": 0}, "a hat into an empty inventory: storage 0")
	var with_hat := {0: inst(10, 0)}
	_check(A.drop_target(types_of(11), with_hat, types_of) == {"refuse": "UIIT_MSG_STRGERR_EQUIPITEM"},
		"a second hat: the client refuses with STRGERR_EQUIPITEM, nothing sent (no swap)")
	_check(A.drop_target(types_of(20), with_hat, types_of) == {"send": true, "dst": 1}, "a dress: the first EMPTY storage slot, 1")
	_check(A.drop_target(types_of(30), with_hat, types_of) == {"refuse": "UIIT_STT_AVATAR_MAIL_ONLY_WEAR"},
		"an attachment with no dress: AVATAR_MAIL_ONLY_WEAR")
	var gap := {1: inst(20, 1), 3: inst(10, 3)}
	_check(A.drop_target(types_of(30), gap, types_of) == {"send": true, "dst": 0},
		"an attachment over a dress: storage 0, the first empty, whatever the type (c:0x6ad416..0x6ad463)")
	_check(A.drop_target(types_of(50), gap, types_of) == {"send": true, "dst": 4}, "a devil's spirit: always storage 4 (c:0x55edf0)")
	var full := {0: inst(10, 0), 1: inst(20, 1), 2: inst(30, 2), 3: inst(50, 3), 4: inst(50, 4)}
	_check(A.drop_target(types_of(40), full, types_of) == {"send": true, "dst": 5}, "all five full: storage 5 is sent (the server answers 3)")
	_check(A.drop_target(types_of(60), empty, types_of).is_empty(), "a sword is not the avatar path")
	_check(not A.attachment_disabled({0: inst(20, 0)}, types_of, child_count) and A.attachment_disabled({0: inst(21, 0)}, types_of, child_count)
		and not A.attachment_disabled({}, types_of, child_count), "the attachment window greys under a dress with ChildItemCount 0 only")

func _test_skill_strip() -> void:
	var A := AvatarEquipment
	var awake := {4: inst(50, 4, (1 << 31) | 3600)}
	var asleep := {4: inst(50, 4, 0)}
	var over := {4: inst(50, 4, 1 << 31)}
	_check(A.skill_strip_shown(true, awake, types_of), "avatar mode, an awake devil's spirit with time left: the strip shows")
	_check(not A.skill_strip_shown(false, awake, types_of), "equipment mode: hidden")
	_check(not A.skill_strip_shown(true, asleep, types_of) and not A.skill_strip_shown(true, over, types_of),
		"never activated, or its time over: hidden")
	_check(not A.skill_strip_shown(true, {0: inst(10, 0)}, types_of), "a hat alone: hidden")
	_check(A.spirit_seconds_left(inst(50, 4, (1 << 31) | 7)) == 7 and A.spirit_seconds_left(inst(50, 4, 7)) == 0,
		"the period word's seconds count only once activated")

func _test_net_client() -> void:
	var nc = load("res://scripts/net/net_client.gd").new()
	var lists := []
	var moves := []
	var ops := []
	nc.avatar_list_result.connect(func(items): lists.append(items.keys()))
	nc.avatar_move_result.connect(func(r): moves.append(r))
	nc.item_op_result.connect(func(r): ops.append(r))
	var hat := inst(10, 0)
	var dress := inst(20, 1)
	nc._dispatch(Packet.new(AvatarNet.OP_LIST, AvatarNet.encode_list(5, {0: hat, 1: dress})))
	_check(lists == [[0, 1]] and nc.avatar_list_received and nc.last_avatar_instances[1].ref_item_id == 20,
		"the avatar list fills NetClient's avatar inventory (%s)" % [lists])
	# Bag index 2 holds an attachment; 0x24 2 -> storage 2 succeeds.
	nc.last_inventory_instances = {2: inst(30, 2)}
	nc._item_op_kinds.append("avatar")
	nc._dispatch(Packet.new(AvatarNet.OP_ITEM_MOVE_ACK, AvatarNet.encode_move_ack({"ok": true, "type": 0x24, "src": 15, "dst": 2, "subs": []})))
	_check(moves.size() == 1 and nc.last_avatar_instances.has(2) and nc.last_avatar_instances[2].ref_item_id == 30
		and not nc.last_inventory_instances.has(2), "0x24 moves bag 2 into storage 2 (c:0x87ba20)")
	# The dress comes off with the attachment: the outer op, then the sub-op.
	nc._item_op_kinds.append("avatar")
	nc._dispatch(Packet.new(AvatarNet.OP_ITEM_MOVE_ACK, AvatarNet.encode_move_ack({"ok": true, "type": 0x23, "src": 1, "dst": 16,
		"subs": [{"type": 0x23, "src": 2, "dst": 17}]})))
	_check(moves.size() == 2 and nc.last_avatar_instances.keys() == [0] and nc.last_inventory_instances.get(3).ref_item_id == 20
		and nc.last_inventory_instances.get(4).ref_item_id == 30, "0x23 with its sub-op: dress to bag 3, attachment to bag 4")
	# A refusal names no type: an avatar move out routes it to the avatar handler.
	nc._item_op_kinds.append("avatar")
	nc._dispatch(Packet.new(AvatarNet.OP_ITEM_MOVE_ACK, PackedByteArray([2, 0x0e, 0x18])))
	_check(moves.size() == 3 and not bool(moves[2]["ok"]) and int(moves[2]["code"]) == 0x180e and ops.is_empty(),
		"a refusal while an avatar move is out is the avatar's (0x180e), not item_op_result")
	# A split's refusal still goes to the item operation.
	nc._item_op_kinds.append("item")
	nc._dispatch(Packet.new(AvatarNet.OP_ITEM_MOVE_ACK, PackedByteArray([2, 0x07, 0x18])))
	_check(ops.size() == 1 and moves.size() == 3 and nc._item_op_kinds.is_empty(), "a split's refusal is item_op_result's")
	# A buy back's success (type 0x22, sent as 0x7168) takes no entry.
	nc._item_op_kinds.append("avatar")
	nc._dispatch(Packet.new(AvatarNet.OP_ITEM_MOVE_ACK, PackedByteArray([1, 0x22, 13, 0, 1, 0])))
	_check(ops.size() == 2 and nc._item_op_kinds == ["avatar"], "a buy back's success leaves the avatar entry waiting")
	# 0x3078 {3, slot}: the worn devil's spirit expired; the strip goes.
	var spirit := inst(50, 4, (1 << 31) | 3600)
	nc.last_avatar_instances[4] = spirit
	_check(AvatarEquipment.skill_strip_shown(true, nc.last_avatar_instances, types_of), "an awake spirit: the strip shows")
	var expired := []
	nc.avatar_spirit_expired.connect(func(s): expired.append(s))
	nc._dispatch(Packet.new(AvatarNet.OP_ITEM_STATE, PackedByteArray([3, 4])))
	_check(expired == [4] and AvatarEquipment.spirit_active(spirit) and AvatarEquipment.spirit_seconds_left(spirit) == 0
		and not AvatarEquipment.skill_strip_shown(true, nc.last_avatar_instances, types_of),
		"0x3078 {3, 4}: the spirit's time is over and the strip hides")
	# A grant: the item at bag index slot - 13 is replaced.
	var granted := inst(10, 0)
	granted.mag_params.append(291 | (1 << 32))
	var grants := []
	nc.avatar_grant_result.connect(func(r): grants.append(r))
	nc._dispatch(Packet.new(AvatarNet.OP_GRANT_ACK, AvatarNet.encode_grant_ack({"ok": true, "flag": 1, "slot": 20, "item": granted})))
	_check(grants.size() == 1 and nc.last_inventory_instances.get(7) != null and nc.last_inventory_instances[7].option_count() == 1,
		"0x34AA puts the granted item at bag index 7 (slot 20 - 13)")
	nc.free()

func _init() -> void:
	_test_display()
	_test_drop()
	_test_skill_strip()
	_test_net_client()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
