extends SceneTree

## Dev tool (round 858): where each game window lets the world show through.
## Builds every window and box the HUD opens (as audit_input_bleed.gd does),
## one scenario at a time, and measures each with HoleCensus (a magenta and a
## green ground straight behind the window, the pixels that differ inside its
## drawn area; scripts/ui/hole_census.gd has the rules). A scenario that names
## no window is measured by what it put on screen.
##
## Needs a real renderer:
##
##   su - ghidra -c "flock <lock> <dir>/tools/xwl_run.sh -s 1920x1080 <godot> --rendering-method \
##     forward_plus --rendering-driver vulkan --resolution 1920x1080 --path <dir> \
##     --script res://tools/window_hole_census.gd -- --pk2=<Media.pk2> [--panel=help ...] [--out=<dir>]"
##
## Prints `HOLES <window> full <n> part <n> area <n>` per window, then a
## `PIECE` line per piece of at least --min px (default 4), and with --out
## writes <out>/<window>.png (the magenta frame) for a human.

const VIEW := Vector2i(1920, 1080)

const PANELS := ["inventory", "character", "skill", "action", "party", "academy",
	"quest", "guild", "community", "storage", "guild_storage", "store", "exchange", "exchange_retail",
	"stall", "system", "partymatch", "autopotion", "npctalk", "alchemy", "grant", "itemmall",
	"option", "worldmap", "help",
	"party_settings", "guild_name", "guild_leave", "guild_box", "guild_union", "recall", "stall_text", "stall_avatar",
	"silk_history", "exchange_gold", "hammer", "crest", "reverse_return", "custom_title", "cast_bar",
	"friend_add", "friend_delete", "stall_network", "stall_network_notice", "guild_notice_write",
	"guild_donate", "guild_level_up", "guild_master_leave", "guild_vote", "guild_gp_history",
	"guild_event", "guild_recall", "revive", "use_on", "composite", "gacha_select", "whole_chat",
	"buff_cancel"]

var _builder: UiBuilder
## The UI's own size (VIEW, unless an extension scales the UI).
var _ui_view := VIEW
var _names := {}
var _min_piece := 4

func _args(flag: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var watchdog := create_timer(900.0)
	watchdog.timeout.connect(func() -> void:
		print("=== watchdog: stopped")
		quit(1))
	var pk2 := _args("--pk2")
	var archive := Pk2Reader.open(pk2[0] if not pk2.is_empty() else "/opt/sro-files/client/Media.pk2")
	if archive == null:
		printerr("could not open Media.pk2")
		quit(1)
		return
	if not _args("--min").is_empty():
		_min_piece = int(_args("--min")[0])
	var out := ""
	if not _args("--out").is_empty():
		out = _args("--out")[0]
		DirAccess.make_dir_recursive_absolute(out)
	var entry := ObjectLoader.find_file(archive, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(archive.read_file(entry)) if entry != null else null
	_builder = UiBuilder.new(archive, table)
	root.size = VIEW
	_set_up_view()
	var wanted := _args("--panel")
	if wanted.is_empty():
		wanted = PackedStringArray(_panels())
	var ground := ColorRect.new()
	ground.size = Vector2(_ui_view)
	ground.color = Color(0.2, 0.2, 0.2)
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ground)
	var ui := Control.new()
	ui.name = "UI"
	ui.size = Vector2(_ui_view)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ui)
	_builder.apply_ui_theme(ui)
	var panels: Control = (load("res://scripts/ui/hud/hud_panels.gd") as GDScript).new(_builder)
	panels.size = Vector2(_ui_view)
	ui.add_child(panels)
	await process_frame
	var total_full := 0
	for id in wanted:
		var before := {}
		_visible_set(ui, before)
		var roots := await _open(String(id), ui, panels)
		# The layout settles over a few frames (UiBuilder.settle_authored_rects).
		for i in 8:
			await process_frame
		# A scenario that names no window: what it put on screen, every node
		# shown now that was not before, highest first.
		var shown: Array = roots.duplicate()
		if shown.is_empty():
			_newly_shown(ui, before, shown)
		var n := 0
		for w in shown:
			var c := w as Control
			if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
				continue
			if _covered_by(c, shown):
				continue
			var label := String(id) if n == 0 else "%s#%s" % [id, c.name]
			var r: Dictionary = await _measure(c, label, out)
			total_full += int(r.get("full", 0))
			n += 1
		if n == 0:
			print("HOLES %s not built" % id)
		# Everything the scenario showed goes again, so the next one is alone.
		_hide_new(ui, before)
		if id == "option":
			panels.call("close_option")
		await process_frame
	print("HOLES TOTAL full %d" % total_full)
	print("CENSUS DONE")
	quit(0)

## The measure each window gets (round 859: window_text_census.gd extends
## this tool with the text alignment census instead).
func _measure(c: Control, label: String, out: String) -> Dictionary:
	_name_textures()
	return await HoleCensus.measure(c, label, out, _min_piece, _names)

## The scenarios (an extension adds its own).
func _panels() -> Array:
	return PANELS

## The window and UI scale (an extension may change them).
func _set_up_view() -> void:
	pass

## Opens one scenario; returns the window(s) it built (may be empty when the
## shown-set diff finds them).
func _open(id: String, ui: Control, panels: Control) -> Array:
	var noop := func() -> void: pass
	var noop1 := func(_a = null) -> void: pass
	var extra = await _open_extra(id, ui, panels)
	if extra != null:
		return extra
	match id:
		"worldmap":
			var map: Control = (load("res://scripts/ui/hud/hud_worldmap.gd") as GDScript).new(_builder)
			ui.add_child(map)
			if map.call("build_worldmap"):
				map.call("open")
				return [map]
			return []
		"help":
			var help := HelpWindow.new()
			ui.add_child(help)
			help.setup(_builder, [{"title": "Playing", "path": "res://docs/HELP_PLAYING.md"},
				{"title": "Debug tools", "path": "res://docs/DEBUG_TOOLS.md"},
				{"title": "Release notes", "path": "res://docs/RELEASE_NOTES.md"}], false)
			help.open()
			var f := help.get_node_or_null("HelpFrame") as Control
			return [f] if f != null else []
		"option":
			var o = panels.call("toggle_option")
			return [o] if o != null else []
		"stall":
			panels.call("open_stall_window")
			# The slots' art comes with the first draw, as the stall's state
			# arrives in the game.
			panels.call("stall_draw", panels.call("_stall"))
			return []
		"exchange", "exchange_retail":
			panels.call("_drop_exchange_window")
			ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, id == "exchange")
			panels.set("exchange_canvas", Vector2(_ui_view))
			panels.call("open_exchange_window")
			var inv = (panels.get("_windows") as Dictionary).get("inventory")
			if inv != null:
				(inv as Control).hide()
			var ex = (panels.get("_windows") as Dictionary).get("exchange")
			if id == "exchange_retail":
				ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, true)
			return [ex] if ex != null else []
		"party_settings":
			panels.call("open", "party")
			await process_frame
			var dlg = panels.call("open_party_settings")
			return [dlg] if dlg != null else []
		"guild_name":
			panels.call("open", "npctalk")
			await process_frame
			var seen := {}
			_visible_set(ui, seen)
			panels.call("open_guild_name_prompt", "NPC_CH_GENARAL_SP")
			var out: Array = []
			_newly_shown(ui, seen, out)
			return out
		"guild_leave":
			panels.call("open_guild_leave_prompt", "NPC_CH_GENARAL_SP")
		"guild_box":
			panels.call("open_guild_box", 0x0F, "Guild", "Bob")
		"guild_union":
			panels.call("open_guild_box", 0x1d, "Guild", "Bob")
		"recall":
			panels.call("open_recall_designate_prompt", "STORE_CH_GATE", "Jangan")
		"stall_text":
			panels.call("open_stall_text_box", false, "Selling potions", noop1, noop)
		"stall_avatar":
			panels.call("open_stall_avatar_question", noop1)
		"silk_history":
			panels.call("open_silk_history")
		"exchange_gold":
			panels.call("open", "inventory")
			await process_frame
			var seen := {}
			_visible_set(ui, seen)
			panels.call("open_exchange_gold_box")
			var out: Array = []
			_newly_shown(ui, seen, out)
			return out
		"hammer":
			panels.call("open_hammer_confirm", 13)
		"crest":
			panels.call("open_crest_box", 13, 0x15)
		"reverse_return":
			panels.call("open_reverse_return_box", 13)
		"custom_title":
			panels.call("open_custom_title_box", 13)
		"cast_bar":
			panels.call("open_cast_bar", 1, 3000, "Return Scroll")
		"friend_add":
			panels.call("open_friend_add")
		"friend_delete":
			panels.call("open_friend_delete", 1, "Bob")
		"stall_network":
			panels.call("open_stall_network", true, false)
		"stall_network_notice":
			panels.call("open_stall_network_notice", "The stall network is open.")
		"guild_notice_write":
			panels.call("open_guild_notice_write")
		"guild_donate":
			panels.call("open_guild_donate")
		"guild_level_up":
			panels.call("open_guild_level_up", 1)
		"guild_master_leave":
			panels.call("open_guild_master_leave", 1)
		"guild_vote":
			panels.call("open_guild_vote_confirm", 1)
		"guild_gp_history":
			panels.call("open_guild_gp_history", [])
		"guild_event":
			panels.call("open_guild_event_box", "The guild war has begun.")
		"guild_recall":
			panels.call("open_guild_recall_box", 1, 2, 10)
		"revive":
			panels.call("show_revive_prompt", "You were killed by a Wolf.", 10)
		"use_on":
			panels.call("_use_on_confirm", 0, 1)
		"composite":
			var win := CompositeItemWindow.new()
			ui.add_child(win)
			win.setup(_builder)
			win.show_entries([[1, "Energy of life", 3], [2, "Hwan regeneration fill", 0]])
			win.position = Vector2(820, 400)
			win.show()
			return [win]
		"gacha_select":
			var g := GachaSelectWindow.new()
			ui.add_child(g)
			g.setup(_builder, null)
			g.open()
			return [g]
		"whole_chat":
			var wc: Control = (load("res://scripts/ui/hud/hud_whole_chat.gd") as GDScript).new()
			ui.add_child(wc)
			wc.call("setup", _builder)
			wc.call("open_for", 13, 1)
		"buff_cancel":
			var board: Control = (load("res://scripts/ui/hud/hud_buff_board.gd") as GDScript).new(_builder, SkillBuffCatalog.new(null))
			ui.add_child(board)
			board.call("_open_confirm", 1, 2)
		_:
			var w = panels.call("open", id)
			return [w] if w != null else []
	return []

## A scenario an extension adds: its windows, or null when it is not one.
func _open_extra(_id: String, _ui: Control, _panels_node: Control):
	return null

func _visible_set(node: Node, out: Dictionary) -> void:
	if node is CanvasItem and not (node as CanvasItem).visible:
		return
	out[node.get_instance_id()] = true
	for c in node.get_children():
		_visible_set(c, out)

## Hides every node shown now that was not shown before.
func _hide_new(node: Node, before: Dictionary) -> void:
	if node is CanvasItem and not (node as CanvasItem).visible:
		return
	if not before.has(node.get_instance_id()) and node is CanvasItem:
		(node as CanvasItem).hide()
		return
	for c in node.get_children():
		_hide_new(c, before)

## The highest nodes shown now that were not shown before.
func _newly_shown(node: Node, before: Dictionary, out: Array) -> void:
	if node is CanvasItem and not (node as CanvasItem).visible:
		return
	if not before.has(node.get_instance_id()) and node is Control:
		out.append(node)
		return
	for c in node.get_children():
		_newly_shown(c, before, out)

## Whether `c` sits inside another root of the list (counted with it).
func _covered_by(c: Control, roots: Array) -> bool:
	for r in roots:
		if r != c and r is Node and (r as Node).is_ancestor_of(c):
			return true
	return false

func _name_textures() -> void:
	var cache = _builder.get("_texture_cache")
	if cache is Dictionary:
		for k in cache:
			_names[cache[k]] = String(k).get_file()
