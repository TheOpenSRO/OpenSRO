extends SceneTree

## An abnormal state's colour pulse (StateLook) and the berserk look
## (BerserkLook) on one body share its one colour slot, BodyPulse (round 855,
## READ: the compound's +0x48 / +0x4c -- the last start wins and an end ends
## the colour, whoever set it). Round 856 (READ, FUN_009cd5e0's guard): while
## the body mode is 1 (berserk) a state bit's +0x48 and +0x4c are left out,
## so berserk keeps its colour over a state that starts or ends inside it,
## and berserk's end ends the colour whatever state still runs. In each of
## the four orders the two come on and go: the colour drawn is the slot's,
## the shared material is never painted, and with both off the body draws its
## own material.
## Synthetic tables and bodies, never game data. Run headless on the render
## box (`client/tools/remote_godot.sh tests`).

const BerserkLook = preload("res://scripts/effects/berserk_look.gd")

var _failures := 0
const PLAIN := Color(0.59, 0.59, 0.59, 1.0)
const BURN := 0x8
const BERSERK_C1 := Color8(10, 20, 30)

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

## The body mode 0x30BF kind 4 gave the body (1 while berserk).
var _mode := 0

## A state's tinted bit on or off, as World3D walks it, with the body's guard.
func _state(body: Node3D, on: bool) -> void:
	var w := StateLook.walk(0 if on else BURN, BURN if on else 0, {}, StateLook.guard_of(_mode, 0))
	StateLook.apply_pulse(body, w["pulse"])

func _berserk(body: Node3D, on: bool) -> void:
	_mode = 1 if on else 0
	if on:
		BerserkLook.start(body, true)
	else:
		BerserkLook.stop(body)
	BerserkLook.tick(0.25)
	BerserkLook.tick(0.25)

func _order(name: String, steps: Array, want: Array) -> void:
	var shared := StandardMaterial3D.new()
	shared.albedo_color = PLAIN
	var made := _body(shared)
	var body: Node3D = made[0]
	var mi: MeshInstance3D = made[1]
	var worst := ""
	for i in steps.size():
		var st: String = steps[i]
		if st == "S+":
			_state(body, true)
		elif st == "S-":
			_state(body, false)
		elif st == "B+":
			_berserk(body, true)
		else:
			_berserk(body, false)
		BodyPulse.tick(0.0)
		if not shared.albedo_color.is_equal_approx(PLAIN) and worst == "":
			worst = "after %s the shared material is painted %s" % [st, shared.albedo_color]
		var who := BodyPulse.who(body)
		if who != want[i] and worst == "":
			worst = "after %s the colour is %s's, want %s's" % [st, who, want[i]]
		if who != "" and mi.material_override == shared and worst == "":
			worst = "after %s a colour is on but the mesh draws the shared material" % st
		if who == "" and mi.material_override != shared and worst == "":
			worst = "after %s no colour is on but the mesh draws %s" % [st, mi.material_override]
		var drawn := (mi.material_override as StandardMaterial3D).albedo_color
		if who == "berserk" and not drawn.is_equal_approx(Color(BERSERK_C1, 1.0)) and worst == "":
			worst = "after %s berserk's colour 1 is not drawn (%s)" % [st, drawn]
		if who == "state" and not drawn.is_equal_approx(Color(StateLook.TINTS[BURN][0], 1.0)) and worst == "":
			worst = "after %s the burn's colour 1 is not drawn (%s)" % [st, drawn]
	_check(worst == "", "%s: %s%s" % [name, " -> ".join(PackedStringArray(want.map(func(w): return w if w != "" else "none"))),
		" (" + worst + ")" if worst != "" else ""])
	_check(mi.material_override == shared and not mi.has_meta(BodyPulse.ORIGINAL_META),
		"%s: both off, the body draws its own material again (got %s)" % [name,
			"the shared one" if mi.material_override == shared else str(mi.material_override)])
	body.free()

func _initialize() -> void:
	BerserkLook.set_rows(BerserkLook.parse_rows(_table()))
	BerserkLook.effect_factory = func(_path: String): return null
	BerserkLook.sound_player = func(_path: String, _pos) -> void: pass
	# READ: berserk's start overwrites; a state's start and end inside berserk
	# are left out (round 856); berserk's end clears the slot.
	_order("state on, berserk on, state off, berserk off", ["S+", "B+", "S-", "B-"], ["state", "berserk", "berserk", ""])
	_order("state on, berserk on, berserk off, state off", ["S+", "B+", "B-", "S-"], ["state", "berserk", "", ""])
	_order("berserk on, state on, state off, berserk off", ["B+", "S+", "S-", "B-"], ["berserk", "berserk", "berserk", ""])
	_order("berserk on, state on, berserk off, state off", ["B+", "S+", "B-", "S-"], ["berserk", "berserk", "", ""])
	# Before round 856 (no guard) the third order drew the state's colour over
	# berserk's and left none for berserk's last seconds.
	var unguarded := StateLook.walk(0, BURN, {})
	var guarded := StateLook.walk(0, BURN, {}, StateLook.guard_of(1, 0))
	_check(unguarded["pulse"] != null and guarded["pulse"] == null and guarded["tint"] == StateLook.TINTS[BURN],
		"the guard leaves the colour call out, not the state's own look (tint %s)" % [guarded["tint"]])
	# A mask change with no tinted bit leaves berserk's colour (no +0x48/+0x4c).
	var shared := StandardMaterial3D.new()
	shared.albedo_color = PLAIN
	var made := _body(shared)
	var body: Node3D = made[0]
	_state(body, true)
	_berserk(body, true)
	var w := StateLook.walk(BURN, BURN | 0x100, {"tint": StateLook.TINTS[BURN]})
	StateLook.apply_pulse(body, w["pulse"])
	_check(w["pulse"] == null and BodyPulse.who(body) == "berserk", "a slowness coming on beside a burn leaves berserk's colour (%s)" % BodyPulse.who(body))
	# The size's way back after berserk's end does not end a state's colour
	# set meanwhile (berserk's +0x4c is called once, at its end).
	BerserkLook.stop(body)
	_mode = 0
	_state(body, false)
	_state(body, true)
	BerserkLook.tick(2.0)
	_check(BodyPulse.who(body) == "state", "a state set after berserk's end keeps its colour while the size goes back")
	body.free()
	BodyPulse.tick(0.0)
	StateLook.clear()
	BerserkLook.clear()
	# The static hooks hold lambdas bound to this script: left set, the exit's
	# static clean-up aborted the run (MEASURED: rc 134, "corrupted size vs.
	# prev_size in fastbins").
	BerserkLook.effect_factory = Callable()
	BerserkLook.sound_player = Callable()
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
