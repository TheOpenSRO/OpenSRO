extends SceneTree

## Round 808's follow-up: Footprints (READ addresses in its header) -- sand 1
## and snow 9 lay prints, nothing else; the toe angle; the 2.0 x 3.5 axes,
## the 2.0 across and the 3.5 along the facing; the 1020 ms fade at the end
## of 20 s; a print laid on a flat ground, aged out. Synthetic texture, never
## game data. `client/tools/remote_godot.sh tests`.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_check(Footprints.lays(1) and Footprints.lays(9) and not Footprints.lays(0) and not Footprints.lays(10) and not Footprints.lays(-1),
		"sand (1) and snow (9) lay prints; dirt, grass, no cell do not (0xa5a3f0's uVar1 >> 16 tests)")
	_check(is_equal_approx(Footprints.angle_for(1.0, true), 1.0 + 0.07853981852531433) and is_equal_approx(Footprints.angle_for(1.0, false), 1.0 - 0.07853981852531433),
		"the left foot's print turns out by +0.0785 rad, the right's by -0.0785 (double 0xde5b48)")
	for h in [0.0, 0.7, 2.5, 4.0]:
		var ax: Array = Footprints.axes(h)
		var across: Vector2 = ax[0]
		var along: Vector2 = ax[1]
		_check(absf(across.dot(along)) < 1e-6 and along.is_equal_approx(RemoteFacing.facing_of(h)),
			"at %.1f the 3.5 runs along the facing and the 2.0 across it" % h)
	_check(Footprints.alpha_at(20000.0) == 1.0 and Footprints.alpha_at(1020.0) == 1.0 and absf(Footprints.alpha_at(510.0) - 0.5) < 1e-6 and Footprints.alpha_at(0.0) == 0.0,
		"full until the last 1020 ms (0x3fc), then linear to 0")
	var fp := Footprints.new()
	root.add_child(fp)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	fp.load_texture = func(_p: String) -> Texture2D: return tex
	fp.ground_height = func(p: Vector3) -> float: return 7.0
	_check(not fp.add(Vector3(10, 7, 10), 0.0, true, 0), "dirt lays nothing")
	_check(fp.add(Vector3(10, 7, 10), 0.0, true, 1) and fp.count() == 1, "sand lays one print")
	fp.step(19000.0)
	_check(fp.count() == 1, "it is there 19 s on")
	fp.step(1500.0)
	_check(fp.count() == 0, "and gone after 20 s")
	fp.queue_free()
	print("footprints_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)
