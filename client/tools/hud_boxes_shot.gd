extends SceneTree

## Dev tool (round 848, lane H): renders the HUD's boxes and inputs that round
## 848 moved off Godot's native widgets, each alone over a grey ground, from
## the player's own Media.pk2, through the HUD's public entry points -- the
## same calls before and after the round, so one tool takes both sets of
## frames (run it on the base tree and on the branch). Needs a real renderer:
##
##   su - ghidra -c "flock <lock> <dir>/tools/xwl_run.sh -s 1280x720 <godot> --rendering-method \
##     forward_plus --rendering-driver vulkan --resolution 1280x720 --path <dir> \
##     --script res://tools/hud_boxes_shot.gd -- --pk2=<Media.pk2> --out=<dir for PNGs>"
##
## Writes <out>/<scene>.png at 1280 x 720 and prints `SHOT <scene> <file>`.
## Nothing is committed from the archive; the PNGs stay on the box.

const VIEW := Vector2i(1280, 720)
const GROUND := Color(0.35, 0.37, 0.4)

var _builder: UiBuilder
var _out := ""
var _media: Pk2Reader

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_out = _arg("--out", "/var/tmp/hud_boxes_shot")
	DirAccess.make_dir_recursive_absolute(_out)
	_media = Pk2Reader.open(_arg("--pk2", "/opt/sro-files/client/Media.pk2"))
	if _media == null:
		print("no Media.pk2")
		quit(1)
		return
	var entry := ObjectLoader.find_file(_media, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(_media.read_file(entry)) if entry != null else null
	_builder = UiBuilder.new(_media, table)
	root.size = VIEW
	await process_frame
	var only := _arg("--only", "")
	for scene in ["revive", "revive_lv11", "recall", "guild_name", "use_on", "buff_cancel", "gold_time", "edit_typed",
			"composite", "gacha", "help", "notice_write", "give_up"]:
		if only != "" and not only.split(",").has(scene):
			continue
		await _shot(scene)
	print("SHOTS DONE")
	quit(0)

## One scene on a fresh HUD root, three frames to settle, then the frame.
func _shot(scene: String) -> void:
	var ground := ColorRect.new()
	ground.color = GROUND
	ground.size = Vector2(VIEW)
	root.add_child(ground)
	var ui := Control.new()
	ui.name = "UI"
	ui.size = Vector2(VIEW)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ui)
	_builder.apply_ui_theme(ui)
	var panels: Control = (load("res://scripts/ui/hud/hud_panels.gd") as GDScript).new()
	panels.size = Vector2(VIEW)
	panels.set("_builder", _builder)
	ui.add_child(panels)
	var talk := HudWindow.new()
	talk.name = "Window_npctalk"
	talk.position = Vector2(60, 120)
	talk.size = Vector2(386, 451)
	panels.add_child(talk)
	(panels.get("_windows") as Dictionary)["npctalk"] = talk
	var focus: LineEdit = null
	match scene:
		"revive":
			panels.call("show_revive_prompt", "You were killed by a Wolf.", 10)
		"revive_lv11":
			panels.call("show_revive_prompt", "You were killed by a Wolf.", 11)
		"recall":
			panels.call("open_recall_designate_prompt", "STORE_CH_GATE", "Jangan")
		"guild_name":
			panels.call("open_guild_name_prompt", "NPC_CH_GENARAL_SP")
		"use_on":
			panels.call("_use_on_confirm", 0, 1)
		"buff_cancel", "gold_time":
			var board: Control = (load("res://scripts/ui/hud/hud_buff_board.gd") as GDScript).new(_builder, SkillBuffCatalog.new(null))
			ui.add_child(board)
			if scene == "buff_cancel":
				board.call("_open_confirm", 1, 2)
			else:
				board.call("open_confirm_box", "Pause the Gold Time? It stops 20 seconds from now.", func() -> void: pass)
		"edit_typed":
			var box: Control = (load("res://scripts/ui/hud/hud_cos_boxes.gd") as GDScript).new()
			box.call("build_stall_input", _builder, false, "Selling potions")
			ui.add_child(box)
			box.position = Vector2(500, 288)
			focus = box.get("edit") as LineEdit
		"composite":
			var win := CompositeItemWindow.new()
			ui.add_child(win)
			win.setup(_builder)
			win.show_entries([[1, "Energy of life", 3], [2, "Hwan regeneration fill", 0]])
			win.position = Vector2(533, 237)
			win.show()
		"gacha":
			var g := GachaSelectWindow.new()
			ui.add_child(g)
			g.setup(_builder, null)
			g.open()
		"help":
			var h := HelpWindow.new()
			ui.add_child(h)
			h.setup(_builder, [{"title": "Playing", "path": "res://docs/HELP_PLAYING.md"},
				{"title": "Release notes", "path": "res://docs/RELEASE_NOTES.md"}], false)
			h.open()
		"notice_write":
			var nw: Control = (load("res://scripts/ui/hud/guild_notice_write.gd") as GDScript).new()
			nw.call("build_write", _builder)
			ui.add_child(nw)
			nw.position = Vector2(420, 206)
			nw.call("set_texts", "Guild hunt", "Meet at the Jangan gate\nat 20:00.")
			var body = nw.get("body_edit")
			if body is Control:
				(body as Control).grab_focus()
		"give_up":
			var gb := PartyMatchConfirm.new()
			var ok: bool = gb.callv("build", [_builder, _builder.resolve_text("UIIT_MSG_QUEST_GIVEUP_WINDOW_1"),
				PartyMatchConfirm.SIZE, "UIIT_STT_AGREEMENT_BOX"]) if gb.get_method_list().any(func(m) -> bool:
					return m["name"] == "build" and (m["args"] as Array).size() >= 4) else false
			if ok:
				ui.add_child(gb)
				gb.centre_on(Vector2(VIEW))
			else:
				gb.free()
	for i in 3:
		await process_frame
	if focus != null:
		focus.grab_focus()
		focus.caret_column = focus.text.length()
		# The caret drawn steadily for the frame (its blink is timed apart).
		focus.caret_blink = false
		await process_frame
		await process_frame
	var path := "%s/%s.png" % [_out, scene]
	root.get_texture().get_image().save_png(path)
	print("SHOT %s %s" % [scene, path])
	ground.queue_free()
	ui.queue_free()
	await process_frame
