extends SceneTree

## Round 785's client review, finding 8: an abnormal state's colour pulse
## (StateLook) and the berserk look (BerserkLook) on one body compose -- in
## any of the four orders the two come on and go, the body ends on its own
## material, and the shared material itself is never painted. Before the fix
## each kept the other's copy as "the original": a state ending under berserk
## put the shared material under berserk's pulse (which then painted every
## body sharing it), and berserk's end put the state's stale copy back.
## Synthetic tables and bodies, never game data. Run headless on the render
## box (`client/tools/remote_godot.sh tests`).

const BerserkLook = preload("res://scripts/effects/berserk_look.gd")

var _failures := 0
const PLAIN := Color(0.59, 0.59, 0.59, 1.0)
const BURN := 0x8

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

## The berserk table: one kept row whose script is a colour pulse only (no
## size, so its end is over at the next tick).
func _table() -> PackedByteArray:
	var cols: Array = ["label", "SYSTEM_CH_HWANMODE", "ACT_L", "0", "FALSE", "none", "CHAR_BASE", "0", "0", "0", "0", "1",
		"0,0", "AT_LOOP", "MOV_NONE,0,0,0", "0,0,0", "false,0,0,0,0,false", "fx\\", "keep.efp", "Bip01", "0,0,0",
		"none", "0,0,0", "none", "0", "SCT_MAT,10,20,30,110,120,130,1000", "none", "none"]
	return _utf16("#section\tskilleffectset\r\n" + "\t".join(PackedStringArray(cols)) + "\r\n")

## A body holding a skeleton holding one mesh drawn with `shared`.
func _body(shared: StandardMaterial3D) -> Array:
	var body := Node3D.new()
	var skel := Skeleton3D.new()
	body.add_child(skel)
	var mi := MeshInstance3D.new()
	mi.material_override = shared
	skel.add_child(mi)
	root.add_child(body)
	return [body, mi]

func _state(body: Node3D, on: bool) -> void:
	StateLook.set_tint(body, StateLook.TINTS[BURN] if on else [])
	StateLook.tick(0.25)

func _berserk(body: Node3D, on: bool) -> void:
	if on:
		BerserkLook.start(body, true)
	else:
		BerserkLook.stop(body)
	BerserkLook.tick(0.25)
	BerserkLook.tick(0.25)

func _order(name: String, steps: Array) -> void:
	var shared := StandardMaterial3D.new()
	shared.albedo_color = PLAIN
	var made := _body(shared)
	var body: Node3D = made[0]
	var mi: MeshInstance3D = made[1]
	var worst := ""
	for st in steps:
		if st == "S+":
			_state(body, true)
		elif st == "S-":
			_state(body, false)
		elif st == "B+":
			_berserk(body, true)
		else:
			_berserk(body, false)
		# Either look still on draws a copy; the shared material is never painted.
		StateLook.tick(0.25)
		BerserkLook.tick(0.25)
		if not shared.albedo_color.is_equal_approx(PLAIN) and worst == "":
			worst = "after %s the shared material is painted %s" % [st, shared.albedo_color]
		var lit := StateLook.tinted(body) or BerserkLook.active(body)
		if lit and mi.material_override == shared and worst == "":
			worst = "after %s a look is on but the mesh draws the shared material" % st
	_check(worst == "", "%s: the shared material is never painted, and a look on draws a copy%s" % [name, " (" + worst + ")" if worst != "" else ""])
	_check(mi.material_override == shared and not mi.has_meta(StateLook.ORIGINAL_META) and not mi.has_meta(BerserkLook.ORIGINAL_META),
		"%s: both off, the body draws its own material again (got %s)" % [name,
			"the shared one" if mi.material_override == shared else str(mi.material_override)])
	body.free()

func _initialize() -> void:
	BerserkLook.set_rows(BerserkLook.parse_rows(_table()))
	BerserkLook.effect_factory = func(_path: String): return null
	BerserkLook.sound_player = func(_path: String, _pos) -> void: pass
	_order("state on, berserk on, state off, berserk off", ["S+", "B+", "S-", "B-"])
	_order("state on, berserk on, berserk off, state off", ["S+", "B+", "B-", "S-"])
	_order("berserk on, state on, state off, berserk off", ["B+", "S+", "S-", "B-"])
	_order("berserk on, state on, berserk off, state off", ["B+", "S+", "B-", "S-"])
	StateLook.clear()
	BerserkLook.clear()
	# The static hooks hold lambdas bound to this script: left set, the exit's
	# static clean-up aborted the run (MEASURED: rc 134, "corrupted size vs.
	# prev_size in fastbins").
	BerserkLook.effect_factory = Callable()
	BerserkLook.sound_player = Callable()
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
