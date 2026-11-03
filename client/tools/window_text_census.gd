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
	return ["chat"] + PANELS

func _open_extra(id: String, ui: Control, _panels_node: Control):
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
