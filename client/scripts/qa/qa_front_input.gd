extends Node
class_name QaFrontInput

## OPENSRO_QA_FRONT_INPUT (round 862, QA only): a player's keys and clicks on
## a front-end screen (Login, CharacterSelect, CharacterCreate), as World3D's
## OPENSRO_QA_INPUT plays them in the world -- pushed into the real viewport
## (push_input), so Godot's own hit-testing, focus and key routing decide who
## gets each event. `<frame>:<action>[;<frame>:<action>...]`, the frame
## counted from the scene's `_ready`. Actions:
##   key:<name>          press and release a key (`key:shift+home` holds Shift)
##   type:<text>         a key per character
##   click:<x>,<y>       left press and release at a viewport point
##   skipintro           the title's intro skipped (the login window up now)
##   snap:<name>         this frame into OPENSRO_QA_SNAP_DIR/<name>.png
##   snapfield:<field>:<name>  the same, cut to the edit's rect grown by 20 px
##                       each side and 8 px above and below
##   clickfield:<field>  a left click at the middle of that edit (as click:)
##   editstate:<field>   where an edit draws its text and caret (CifEdit.
##                       placement): `<field>` a property of the scene holding
##                       the edit (Login's `username_edit`, `password_edit`)
##                       or a node name under it
## Each action prints `QA FRONT <frame> <action> ...`.

var _scene: Node
var _steps := {}
var _tick := 0

static func qa_hook(scene: Node) -> void:
	var spec := OS.get_environment("OPENSRO_QA_FRONT_INPUT")
	if spec == "" or scene == null:
		return
	var n := QaFrontInput.new()
	n.name = "QaFrontInput"
	n._scene = scene
	for part in spec.split(";", false):
		var at := String(part).find(":")
		if at > 0 and String(part).substr(0, at).is_valid_int():
			n._steps[int(String(part).substr(0, at))] = String(part).substr(at + 1)
	scene.add_child(n)

func _process(_delta: float) -> void:
	_tick += 1
	if _steps.has(_tick):
		_run(_steps[_tick])

func _run(action: String) -> void:
	var kind := action.get_slice(":", 0)
	var arg := action.substr(kind.length() + 1)
	var report := ""
	match kind:
		"key":
			for ev in key_events(arg):
				get_viewport().push_input(ev)
		"type":
			for i in arg.length():
				for ev in key_events(arg[i]):
					get_viewport().push_input(ev)
		"click", "clickfield":
			var at := Vector2.ZERO
			if kind == "clickfield":
				var cf := _find_edit(arg)
				at = cf.get_global_rect().get_center() if cf != null else Vector2(-1, -1)
			else:
				var xy := arg.split(",")
				at = Vector2(float(xy[0]), float(xy[1]))
			for pressed in [true, false]:
				var m := InputEventMouseMotion.new()
				m.position = at
				m.global_position = at
				get_viewport().push_input(m)
				var b := InputEventMouseButton.new()
				b.button_index = MOUSE_BUTTON_LEFT
				b.pressed = pressed
				b.position = at
				b.global_position = at
				b.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
				get_viewport().push_input(b)
			var hov := get_viewport().gui_get_hovered_control()
			report = "at %s (hovered %s)" % [at, hov.get_path() if hov != null else "nothing"]
		"skipintro":
			var title: Variant = _scene.get("_title")
			if title is Object and (title as Object).has_method("skip"):
				(title as Object).call("skip", "OPENSRO_QA_FRONT_INPUT")
		"snap":
			var sd := OS.get_environment("OPENSRO_QA_SNAP_DIR")
			if sd != "":
				DirAccess.make_dir_recursive_absolute(sd)
				get_viewport().get_texture().get_image().save_png("%s/%s.png" % [sd, arg])
				report = "-> %s/%s.png" % [sd, arg]
		"snapfield":
			var sd2 := OS.get_environment("OPENSRO_QA_SNAP_DIR")
			var sf := _find_edit(arg.get_slice(":", 0))
			if sd2 != "" and sf != null:
				DirAccess.make_dir_recursive_absolute(sd2)
				var img := get_viewport().get_texture().get_image()
				var r := Rect2i(sf.get_global_rect().grow_individual(20, 8, 20, 8)).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
				var out := arg.get_slice(":", 1)
				img.get_region(r).save_png("%s/%s.png" % [sd2, out])
				report = "-> %s/%s.png region %s" % [sd2, out, r]
		"editstate":
			var ce := _find_edit(arg)
			if ce == null:
				report = "(not shown)"
			else:
				var pl := ce.placement()
				var cr: Rect2 = pl.get("caret", Rect2())
				report = "-> EDIT col %d len %d focus %s text_w %.1f left %.1f top %.1f caret %s at %s size %s" % [
					ce.caret_column, ce.text.length(), ce.has_focus(), float(pl.get("text_w", 0.0)),
					float(pl.get("left", 0.0)), float(pl.get("top", 0.0)), cr, ce.get_global_rect().position, ce.size]
	print("QA FRONT %d %s %s" % [_tick, action, report])

func _find_edit(field: String) -> CifEdit:
	var v: Variant = _scene.get(field)
	if v is CifEdit:
		return v as CifEdit
	return _scene.find_child(field, true, false) as CifEdit

## A key's press and release as the OS delivers it (World3D._qa_push_key's
## form): keycode, physical keycode, label and, for one character, its
## unicode; "shift+" / "ctrl+" hold the modifier.
static func key_events(name: String) -> Array:
	var shift := name.to_lower().begins_with("shift+")
	var ctrl := name.to_lower().begins_with("ctrl+")
	var key_name := name.substr(6) if shift else name.substr(5) if ctrl else name
	var code := OS.find_keycode_from_string(key_name)
	if code == KEY_NONE and key_name == " ":
		code = KEY_SPACE
	var uni := 0
	if key_name.length() == 1 and not ctrl:
		uni = key_name.unicode_at(0)
	var out: Array = []
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.key_label = code
		ev.unicode = uni if pressed else 0
		ev.shift_pressed = shift
		ev.ctrl_pressed = ctrl
		ev.pressed = pressed
		out.append(ev)
	return out
