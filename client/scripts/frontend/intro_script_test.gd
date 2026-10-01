extends SceneTree

## IntroScript (round 678): the title intro's script format, READ from the
## client's loader FUN_0056cb10 (docs/protocol/intro_script.md). Every input
## here is a SYNTHETIC snippet written for this test -- ours, not a retail
## file (no game data in the repo); the real archive's seven scripts are
## checked at runtime by client/tools/check_intro_scripts.gd on the box.
##
## NEGATIVE: before round 678 there is no IntroScript -- this suite does not
## parse ("Identifier "IntroScript" not declared").
##
## `godot4 --headless --path client --script res://scripts/frontend/intro_script_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Text as the retail files store it: UTF-16LE behind FF FE.
static func utf16le(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

const SNIPPET := "[CAMERA]\r\n\r\nAREA=OUR_TEST_AREA\r\n" \
	+ "0.0 S_CameraInsert 0.0 10 20 100.5 50.25 -30.0 0.1 3.0 0.0 100\r\n" \
	+ "9.9 S_CameraInsert 2.5 10 20 2000.0f 60.0 1950.75f -0.2 -6.0 0.5 10\r\n" \
	+ "70 S_CameraShake 1 100 9000 7\r\n" \
	+ "0.0\tS_CameraInsert\t5.0\t10\t20\t-100\t70\t500\t0.3\t1.0\t0\t50\r\n" \
	+ "\r\n[SCRIPT]\r\n0 S_SetWorldTime 22\r\n1\tS_EffectCreate fx \"a\\b.efp\" 10 20 1 2 3 0 1 1\r\n[END]\r\n" \
	+ "0.0 S_CameraInsert 9.0 1 1 1 1 1 1 1 1 1\r\n"

func _initialize() -> void:
	var p := IntroScript.parse(utf16le(SNIPPET))
	_check(p.ok(), "the snippet parses (error '%s')" % p.error)
	_check(p.keyframes.size() == 3, "three S_CameraInsert keyframes -- the line after [END] is outside every section (got %d)" % p.keyframes.size())
	_check(p.area == "OUR_TEST_AREA", "AREA= is kept without its prefix (got '%s')" % p.area)
	_check(p.skipped_camera_lines.size() == 1 and p.skipped_camera_lines[0].begins_with("70 S_CameraShake"),
		"a [CAMERA] line that is not a keyframe is skipped, not read as one (%s)" % str(p.skipped_camera_lines))
	_check(p.script_lines.size() == 2 and p.script_lines[0] == "0 S_SetWorldTime 22",
		"[SCRIPT] lines are kept as text (%s)" % str(p.script_lines))
	if p.keyframes.size() == 3:
		var a: IntroScript.Keyframe = p.keyframes[0]
		_check(is_equal_approx(a.time, 0.0) and a.region_lo == 10 and a.region_hi == 20,
			"keyframe 0: time 0, region lo 10 hi 20 (third and fourth values)")
		_check(a.pos.is_equal_approx(Vector3(100.5, 50.25, -30.0)), "keyframe 0: x y z (got %s)" % str(a.pos))
		_check(is_equal_approx(a.pitch, 0.1) and is_equal_approx(a.yaw, 3.0) and is_equal_approx(a.roll, 0.0) and is_equal_approx(a.distance, 100.0),
			"keyframe 0: pitch, yaw, roll, distance in that order")
		var b: IntroScript.Keyframe = p.keyframes[1]
		_check(b.pos.is_equal_approx(Vector3(2000.0, 60.0, 1950.75)), "a trailing 'f' ends a number as _wtof's does (got %s)" % str(b.pos))
		_check(is_equal_approx(b.time, 2.5), "the FIRST token (9.9) is not the time; the third is (got %.2f)" % b.time)
		var c: IntroScript.Keyframe = p.keyframes[2]
		_check(c.pos.is_equal_approx(Vector3(-100, 70, 500)) and is_equal_approx(c.distance, 50.0), "tab-separated tokens read the same")
		_check(is_equal_approx(p.duration(), 5.0), "the length is the last keyframe's time (got %.2f)" % p.duration())
		_check(IntroScript.origin_region(p) == Vector2i(20, 10), "the origin is the LAST keyframe's region as (hi, lo) (got %s)" % str(IntroScript.origin_region(p)))

	# FUN_0056c870's preload set: the keyframe's own region, then the low byte
	# shifted for x >= 1920 or x <= 0 and the high byte for z, separately.
	var regions := IntroScript.preload_regions(p)
	var want: Array[Vector2i] = [Vector2i(20, 10), Vector2i(19, 10), Vector2i(20, 11), Vector2i(21, 10), Vector2i(20, 9)]
	_check(regions == want, "preload regions: own, z<=0 -> hi-1, x>=1920 -> lo+1, z>=1920 -> hi+1, x<=0 -> lo-1 (got %s)" % str(regions))
	var far := IntroScript.parse(utf16le("[CAMERA]\n0 S_CameraInsert 0 71 100 -274.76 143.33 -7211.69 0 0 0 100\n[END]\n"))
	var want_far: Array[Vector2i] = [Vector2i(100, 71), Vector2i(100, 70), Vector2i(96, 71)]
	_check(IntroScript.preload_regions(far) == want_far,
		"z = -7211.69 preloads hi - trunc(z / -1920) - 1 = 100 - 3 - 1 = 96; x = -274.76 lo 70 (got %s)" % str(IntroScript.preload_regions(far)))

	# Encodings: an operator's UTF-8 file (OURS), with and without a BOM, and
	# UTF-16LE without its mark.
	var utf8 := IntroScript.parse(("[CAMERA]\n0 S_CameraInsert 1 2 3 4 5 6 7 8 9 10\n[END]\n").to_utf8_buffer())
	_check(utf8.keyframes.size() == 1 and is_equal_approx(utf8.keyframes[0].distance, 10.0), "a UTF-8 script reads")
	var bom8 := PackedByteArray([0xEF, 0xBB, 0xBF])
	bom8.append_array(("[CAMERA]\n0 S_CameraInsert 1 2 3 4 5 6 7 8 9 10\n").to_utf8_buffer())
	_check(IntroScript.parse(bom8).keyframes.size() == 1, "a UTF-8 script with a BOM reads")
	_check(IntroScript.parse(("[CAMERA]\r\n0 S_CameraInsert 1 2 3 4 5 6 7 8 9 10\r\n").to_utf16_buffer()).keyframes.size() == 1,
		"UTF-16LE without FF FE reads")

	# Failures come back with a reason, never a crash.
	_check(not IntroScript.parse(PackedByteArray()).ok(), "no bytes: not ok")
	_check(IntroScript.parse(utf16le("[SCRIPT]\n0 S_SetWorldTime 22\n")).error != "", "no [CAMERA] keyframe: an error")
	_check(not IntroScript.parse(PackedByteArray([0x00, 0xFF, 0x13])).ok(), "garbage: not ok")

	# option.txt: the uncommented IntroName (a synthetic file in its shape).
	var option := "//StartProcess = \"X\"\r\n//IntroName = \"script\\intro\\a.txt\"\r\nIntroName = \"script\\intro\\b.txt\"\r\nIntroBGM = \"x.ogg\"\r\n"
	_check(IntroScript.parse_option_intro_name(option.to_utf8_buffer()) == "script\\intro\\b.txt",
		"option.txt: the live IntroName, not the commented one (got '%s')" % IntroScript.parse_option_intro_name(option.to_utf8_buffer()))

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()
