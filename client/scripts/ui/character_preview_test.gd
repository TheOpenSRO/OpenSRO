extends SceneTree

## CharacterPreview.dress on a synthetic body (never real game data), run
## headless:
## `godot4 --headless --path client --script res://scripts/ui/character_preview_test.gd`
##
## Round 687 review: the create screen's preview hung the starting kit on the
## body without hiding the body's own pieces under it, so a new player's
## preview showed skin through the clothes. dress() hides them as the world
## does (READ CCompChar::FUN_00c1f790).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _block(flag: int, keys: Array) -> BsrReader.Attachable:
	var a := BsrReader.Attachable.new()
	a.flag = flag
	for k in keys:
		a.entries.append([k, 0])
	return a

## A body whose meshes are the piece keys in `order` (mesh i is key order[i]),
## each with a front-pass twin carrying the same index.
func _body(order: Array) -> SkinnedBsrAssembler.AssembledCharacter:
	var t := SkinnedBsrAssembler.AssembledCharacter.new()
	t.skeleton = Skeleton3D.new()
	t.skeleton.add_bone("Bip01")
	var pairs: Array = []
	for i in range(order.size()):
		for suffix in ["", "_front"]:
			var mi := MeshInstance3D.new()
			mi.name = "piece_%d%s" % [order[i], suffix]
			mi.set_meta(SkinnedBsrAssembler.BODY_MESH_META, i)
			t.skeleton.add_child(mi)
		pairs.append([order[i], i])
	t.parsed = BsrReader.ParsedObject.new()
	t.parsed.attachable = BsrReader.Attachable.new()
	t.parsed.attachable.entries = pairs
	return t

func _shown(t: SkinnedBsrAssembler.AssembledCharacter) -> Array:
	var out := []
	for c in t.skeleton.get_children():
		if (c as Node3D).visible and not String(c.name).ends_with("_front"):
			out.append(int(String(c.name).trim_prefix("piece_")))
	out.sort()
	return out

func _init() -> void:
	var t := _body([13, 6, 0, 12, 3, 1, 11, 5, 2])
	# Synthetic blocks shaped like the measured ones (round 687): a chest
	# {2,3,5}, legs {11,12} and feet {13}, each flag 1; and a model that does
	# not load.
	var kit := {
		"item\\clothes_ba.bsr": _block(1, [2, 3, 5]),
		"item\\clothes_la.bsr": _block(1, [11, 12]),
		"item\\clothes_fa.bsr": _block(1, [13]),
	}
	var calls := []
	var attach := func(model: String) -> SkinnedBsrAssembler.AttachedItem:
		calls.append(model)
		if not kit.has(model):
			return null
		var a := SkinnedBsrAssembler.AttachedItem.new()
		a.attachable = kit[model]
		return a
	var hidden := CharacterPreview.dress(t, ["item\\clothes_ba.bsr", "item\\clothes_la.bsr", "item\\clothes_fa.bsr", "item\\sword.bsr"], attach)
	_check(calls.size() == 4, "every kit model is attached (%d)" % calls.size())
	_check(_shown(t) == [0, 1, 6], "the kit hides torso, upper arm, pelvis, thigh and calf; hair, face and forearm show (got %s)" % str(_shown(t)))
	_check(hidden == 6, "six body meshes hidden, each counted once with its front-pass twin (got %d)" % hidden)
	var twins_hidden := 0
	for c in t.skeleton.get_children():
		if String(c.name).ends_with("_front") and not (c as Node3D).visible:
			twins_hidden += 1
	_check(twins_hidden == 6, "the front-pass twins hide with their meshes (got %d)" % twins_hidden)
	var bare := _body([0, 1, 2])
	_check(CharacterPreview.dress(bare, [], attach) == 0 and _shown(bare) == [0, 1, 2], "an undressed body shows every piece")
	t.skeleton.free()
	bare.skeleton.free()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(0)
