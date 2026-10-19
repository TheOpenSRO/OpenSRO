extends SceneTree

## Round 794: a worn item's own particles and clips (WornItemFx). Run headless
## on the render box: `client/tools/remote_godot.sh tests`.
##
## Holds the rules READ from sro_client.exe (docs/protocol/CLOTH.md, "Worn
## items"): an item's ambient entries become rows on its own skeleton's
## bones, an entry whose bone is missing ends its mod, an entry placed by
## offset is not drawn; an item plays its own `default` clip of type 0 from
## the start, crosses to the body's stand / walk / run clip when it has a
## different one (200 ms), and keeps its clip for any other action.
##
## Everything is SYNTHETIC (a two-bone item skeleton, two one-bone clips); no
## game data.
##
## NEGATIVES: on the base (dev d43226f0) no class exists, and a worn item
## played neither its particles nor its clips.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	_rows()
	await _clips()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _entry(efp: String, bone: String, mode: int = 0) -> BsrReader.ParticleEntry:
	var e := BsrReader.ParticleEntry.new()
	e.efp = efp
	e.bone = bone
	e.mode = mode
	return e

func _rows() -> void:
	var skel := Skeleton3D.new()
	skel.add_bone("Bone04")
	skel.add_bone("Bone06")
	var node := Node3D.new()
	node.add_child(skel)
	node.set_meta(WornItemFx.AMBIENT_META, [
		[_entry("a.efp", "Bone04"), _entry("b.efp", "BoneXX"), _entry("c.efp", "Bone06")],
		[_entry("d.efp", "", 1)],
		[_entry("e.efp", "Bone06")]])
	_check(WornItemFx.item_skeleton(node) == skel, "an item's own skeleton is found under its node")
	var rows := WornItemFx.ambient_rows(node, skel)
	var got := []
	for r in rows:
		got.append("%s@%s" % [(r as ItemGlowTables.ParticleRow).efp, (r as ItemGlowTables.ParticleRow).bone])
	_check(got == ["a.efp@Bone04", "e.efp@Bone06"],
		"rows: a missing bone ends its mod, an offset entry is not drawn, the next mod goes on (got %s)" % [got])
	node.free()

## A clip turning Bone01 about Y to `deg` (two keys, 1000 ms).
func _clip(deg: float, type: int) -> BanReader.ParsedAnimation:
	var a := BanReader.ParsedAnimation.new()
	a.duration_ms = 1000
	a.cyclic = true
	a.key_times = PackedInt32Array([0, 500])
	var b := BanReader.Bone.new()
	b.bone_name = "Bone01"
	for k in range(2):
		var kf := BanReader.Keyframe.new()
		kf.rotation = Quaternion(Vector3.UP, deg_to_rad(deg))
		kf.position = Vector3.ZERO
		b.keyframes.append(kf)
	a.bones.append(b)
	a.set_meta(BsrReader.CLIP_META, [type, "default"])
	return a

func _angle(skel: Skeleton3D) -> float:
	return rad_to_deg(skel.get_bone_pose_rotation(0).get_angle())

func _clips() -> void:
	var body := Skeleton3D.new()
	body.add_bone("Bip01 Neck")
	root.add_child(body)
	var att := BoneAttachment3D.new()
	att.bone_name = "Bip01 Neck"
	body.add_child(att)
	var item := Skeleton3D.new()
	item.add_bone("Bone01")
	att.add_child(item)
	var stand := _clip(30.0, 0)
	var run := _clip(80.0, 7)
	att.set_meta(WornItemFx.CLIPS_META, {0: stand, 7: run})
	WornItemFx.apply([att], body, null)
	_check(item.is_in_group(WornItemFx.GROUP), "an item with clips joins the driver")
	var drv := WornItemFx.driver_for(root)
	await process_frame
	await process_frame
	_check(absf(_angle(item) - 30.0) < 0.5, "it plays its type-0 clip from the start (Bone01 %.1f deg, want 30)" % _angle(item))
	# The body runs (type 7): the item crosses to its run clip over 200 ms.
	body.set_meta(WornItemFx.BODY_CLIP_META, _clip(0.0, 7))
	await process_frame
	await process_frame
	var mid := _angle(item)
	_check(mid > 30.0 and mid < 80.0, "the body's run starts a 200 ms cross to the item's run clip (%.1f deg, between 30 and 80)" % mid)
	await create_timer(0.3).timeout
	await process_frame
	_check(absf(_angle(item) - 80.0) < 0.5, "and ends on it (%.1f deg, want 80)" % _angle(item))
	# An attack (type 2): parts are not asked again.
	body.set_meta(WornItemFx.BODY_CLIP_META, _clip(0.0, 2))
	await process_frame
	await process_frame
	_check(absf(_angle(item) - 80.0) < 0.5, "the body's attack leaves the item's clip as it is (%.1f deg)" % _angle(item))
	# Walk (type 1), which the item has no clip for: it keeps playing.
	body.set_meta(WornItemFx.BODY_CLIP_META, _clip(0.0, 1))
	await process_frame
	await process_frame
	_check(absf(_angle(item) - 80.0) < 0.5, "a walk the item has no clip for keeps its clip (%.1f deg)" % _angle(item))
	_check(drv.describe().begins_with("1 item"), "the driver holds one item skeleton (%s)" % drv.describe())
	body.queue_free()
	await process_frame
	await process_frame
	_check(drv.describe().begins_with("0 item"), "a freed body's item leaves it (%s)" % drv.describe())
