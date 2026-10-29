extends SceneTree

## Round 841 (lane X): the exchange window's busts play their clip, the
## player block's face does not. From a synthetic skeleton and clip (never
## real game data):
##   godot4 --headless --path client --script res://scripts/ui/hud/exchange_bust841_test.gd
##
## READ (player_portrait.gd, "Round 841"): CIFExchange's clones play type 0
## once per exchange and are stepped every frame by the frame's milliseconds
## (vslot_012 0x7b2210 -> 0xa5ac80, the int at 0x110f7f8, 1..3000) and drawn
## every frame (vslot_015 0x7b21b0); the clip loops as its IsCyclic says. The
## player block's face is posed once per dress (FUN_007b7740).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## Three bones: a root, `Bip01 Spine1` and `Bip01 Head` above it.
func _skeleton() -> Skeleton3D:
	var sk := Skeleton3D.new()
	sk.name = "Body"
	sk.add_bone("Bip01")
	sk.add_bone("Bip01 Spine1")
	sk.add_bone("Bip01 Head")
	sk.set_bone_parent(1, 0)
	sk.set_bone_parent(2, 1)
	sk.set_bone_rest(0, Transform3D.IDENTITY)
	sk.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, 10, 0)))
	sk.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0, 6, 0)))
	sk.reset_bone_poses()
	return sk

func _key(angle: float, pos: Vector3) -> BanReader.Keyframe:
	var k := BanReader.Keyframe.new()
	k.rotation = Quaternion(Vector3(0, 0, 1), angle)
	k.position = pos
	return k

## A clip of `ms` whose spine sways 0 -> 0.4 rad -> 0 over its keys (0, ms/2,
## ms); the root and head hold.
func _clip(ms: int, cyclic: bool) -> BanReader.ParsedAnimation:
	var a := BanReader.ParsedAnimation.new()
	a.animation_name = "synthetic_stand"
	a.duration_ms = ms
	a.authored_fps = 30
	a.cyclic = cyclic
	a.key_times = PackedInt32Array([0, ms / 2, ms])
	for spec in [["Bip01", Vector3.ZERO, false], ["Bip01 Spine1", Vector3(0, 10, 0), true], ["Bip01 Head", Vector3(0, 6, 0), false]]:
		var b := BanReader.Bone.new()
		b.bone_name = spec[0]
		for angle in [0.0, 0.4, 0.0]:
			b.keyframes.append(_key(angle if spec[2] else 0.0, spec[1]))
		a.bones.append(b)
	return a

func _spine(p: PlayerPortrait) -> Quaternion:
	var sk := p.character()
	return sk.get_bone_pose_rotation(sk.find_bone("Bip01 Spine1"))

func _run() -> void:
	root.size = Vector2i(320, 240)
	var holder := Control.new()
	root.add_child(holder)
	# The exchange's bust: animated.
	var bust := PlayerPortrait.new()
	bust.animate = true
	holder.add_child(bust)
	var clip := _clip(1000, true)
	bust.set_character(_skeleton(), clip)
	_check(bust.clip() == clip and is_equal_approx(bust.clip_ms, 1.0) and bust.clip_frames == 0,
		"set-up: the clip at its start (1 ms, the set-up's step)")
	var start := _spine(bust)
	await process_frame
	await process_frame
	await process_frame
	_check(bust.clip_frames >= 2 and bust.clip_ms > 1.0, "the bust's clip advances each frame (%d frames, %.1f ms)" % [bust.clip_frames, bust.clip_ms])
	_check(not _spine(bust).is_equal_approx(start), "its pose moves with the clip")
	# Steps by the frame's milliseconds, at least 1 and at most 3000 (READ).
	var before := bust.clip_ms
	bust.step_clip(250.0)
	_check(is_equal_approx(bust.clip_ms, before + 250.0), "step_clip adds the frame's ms")
	_check(bust.render_target_update_mode == SubViewport.UPDATE_ONCE, "a stepped bust renders on this frame")
	# A cyclic clip wraps: 1250 ms into a 1000 ms loop is 250 ms in.
	bust.clip_ms = 0.0
	bust.step_clip(1250.0)
	var wrapped := _spine(bust)
	bust.clip_ms = 0.0
	bust.step_clip(250.0)
	_check(wrapped.is_equal_approx(_spine(bust)), "a cyclic clip loops at its length")
	# Hidden: the clip waits (retail's tick runs for shown windows only).
	holder.visible = false
	var frames_hidden := bust.clip_frames
	await process_frame
	await process_frame
	_check(bust.clip_frames == frames_hidden, "a hidden bust is neither stepped nor drawn")
	holder.visible = true
	# A new body (the next exchange) starts its clip again.
	bust.set_character(_skeleton(), clip)
	_check(is_equal_approx(bust.clip_ms, 1.0) and bust.clip_frames == 0, "a new body starts its clip again")
	# A one-shot plays once and holds its last pose; it is not drawn again.
	var once := _clip(100, false)
	bust.set_character(_skeleton(), once)
	bust.step_clip(500.0)
	var held := bust.clip_frames
	await process_frame
	await process_frame
	_check(bust.clip_frames == held, "a one-shot past its end holds and is not drawn again")

	# The player block's face: not animated -- one render per dress (READ,
	# FUN_007b7740), the regression guard.
	var face := PlayerPortrait.new()
	holder.add_child(face)
	face.set_character(_skeleton(), clip)
	var posed := _spine(face)
	var renders := face.renders_requested
	await process_frame
	await process_frame
	await process_frame
	_check(face.clip() == null and face.clip_frames == 0 and _spine(face).is_equal_approx(posed),
		"the player block's face holds its pose")
	_check(face.renders_requested == renders and renders == 1, "and renders once per dress, not every frame")
	holder.queue_free()
	await process_frame
