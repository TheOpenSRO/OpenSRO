extends "res://tools/window_hole_census.gd"

## Dev tool (round 859): where every HUD window draws its text and its edits'
## carets, against where the original draws them (TextAlignCensus: the frame
## read back with each text, without it, and with the same string drawn at the
## original's origin -- TextLayout's rules from CIFStatic 0x64d9b0 and CIFEdit
## 0x637b70 in the control's ClientRect). Opens the same windows as
## window_hole_census.gd, plus the chat window; at any UI scale.
##
## Needs a real renderer:
##
##   su - ghidra -c "flock <lock> <dir>/tools/xwl_run.sh -s 1920x1080 <godot> --rendering-method \
##     forward_plus --rendering-driver vulkan --resolution 1920x1080 --path <dir> \
##     --script res://tools/window_text_census.gd -- --pk2=<Media.pk2> [--scale=2 --view=960x540] [--panel=chat ...]"
##
## `--view` is the UI's size in UI pixels; the window is view x scale (pass
## the same to xwl_run's -s and --resolution). Prints `TEXT` / `CARET` /
## `NORULE` lines per node and `TEXTSUM` per window, then
## `TEXTCENSUS items <n> off <n> worst <px>`.

var _scale := 1.0
var _all_items := 0
var _all_off := 0
var _all_worst := 0.0
var _all_norule := 0

func _set_up_view() -> void:
	var sc := _args("--scale")
	if not sc.is_empty():
		_scale = float(sc[0])
	var v := _args("--view")
	if not v.is_empty():
		var wh := v[0].split("x")
		_ui_view = Vector2i(int(wh[0]), int(wh[1]))
	root.size = Vector2i(Vector2(_ui_view) * _scale)
	ClientSettings.apply_ui_scale(root, _scale)
	print("TEXTCENSUS view %s scale %.2f window %s" % [str(_ui_view), _scale, str(root.size)])

func _panels() -> Array:
	return ["chat", "frontend_edits"] + PANELS

## The front end's edits on a dark ground: the login's ID and password
## (Login.style_login_edit on pstitle.txt's records, the scene's own call),
## character create's name (GDR_EDIT_NAME, set up as CharacterCreate does)
## and character select's rename box (HudCosBox.build_rename_input).
func _open_frontend_edits(ui: Control) -> Array:
	var holder := Control.new()
	holder.name = "FrontEndEdits"
	holder.position = Vector2(40, 40)
	holder.size = Vector2(600, 400)
	ui.add_child(holder)
	var ground := ColorRect.new()
	ground.color = Color(0.08, 0.08, 0.1)
	ground.size = holder.size
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(ground)
	var login := load("res://scripts/Login.gd") as GDScript
	var title := _builder.load_layout("resinfo\\pstitle.txt")
	if title != null and title.sections.has("Login"):
		var sec = title.sections["Login"]
		for pair in [["GDR_EDIT_ID", false], ["GDR_EDIT_PASS", true]]:
			var d = sec.control_by_name.get(pair[0])
			if d == null:
				continue
			var f := CifEdit.new()
			f.name = pair[0]
			login.call("style_login_edit", f, d, pair[1], holder)
	var create := _builder.load_layout("resinfo\\pscharactercreatechina.txt")
	if create != null and create.sections.has("Custom"):
		var ed = create.sections["Custom"].control_by_name.get("GDR_EDIT_NAME")
		if ed != null:
			var n := CifEdit.new()
			n.name = "GDR_EDIT_NAME"
			for st in ["normal", "focus", "read_only"]:
				n.add_theme_stylebox_override(st, StyleBoxEmpty.new())
			n.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[ed.font_index])
			CifEdit.style(n, ed.font_color)
			if n.has_method("lay_out"):
				n.call("lay_out", ed.client_rect, ed.halign, ed.valign)
			holder.add_child(n)
			n.position = Vector2(ed.rect.position) + Vector2(0, 120)
			n.size = Vector2(ed.rect.size)
	var shown: Array = [holder]
	var box := HudCosBox.new()
	if box.build_rename_input(_builder):
		ui.add_child(box)
		box.centre_on(Vector2(_ui_view))
		box.position.y += 150
		shown.append(box)
	else:
		box.free()
	for i in 4:
		await process_frame
	return shown

func _open_extra(id: String, ui: Control, _panels_node: Control):
	if id == "frontend_edits":
		return await _open_frontend_edits(ui)
	if id != "chat":
		return null
	var chat: Control = (load("res://scripts/ui/hud/hud_chat.gd") as GDScript).new(_builder)
	chat.name = "ChatWindow"
	ui.add_child(chat)
	chat.call("setup")
	# The frame and the input row shown, as in the game with the chat open.
	chat.set("locked", true)
	chat.call("set_frame_shown", true)
	chat.position = Vector2(0, _ui_view.y - chat.size.y)
	for i in 4:
		await process_frame
	return [chat]

func _measure(c: Control, label: String, _out: String) -> Dictionary:
	var r := await TextAlignCensus.measure(c, label, TextAlignCensus.index_layouts(_builder))
	_all_items += int(r["n"])
	_all_off += int(r["off"])
	_all_worst = maxf(_all_worst, float(r["worst"]))
	_all_norule += int(r["norule"])
	print("TEXTCENSUS running items %d off %d worst %.1f norule %d" % [_all_items, _all_off, _all_worst, _all_norule])
	return {}
