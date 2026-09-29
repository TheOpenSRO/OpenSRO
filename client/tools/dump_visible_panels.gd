extends SceneTree

## Dev tool: builds every game window the way the HUD does (HudPanels, the
## world map) from a real archive and prints each one's VISIBLE nodes -- the
## path, class, rect and texture of every CanvasItem that is visible in the
## tree -- one line each, sorted, so two revisions can be diffed with `diff`.
##
## Written for round 633, where a shared UiBuilder rule (round 630: hide a
## control whose Style has bit 0x40) hid the registry frames of the main
## popup, the warehouse, the exchange and the help window. "The frame is
## missing" became a line present in one dump and absent in the other.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_visible_panels.gd -- \
##     --pk2=/path/to/Media.pk2 [--panel=inventory --panel=storage ...]
## With no --panel, every window below is dumped.

const PANELS := ["inventory", "character", "skill", "action", "party", "academy",
	"quest", "guild", "community", "storage", "store", "exchange", "system",
	"partymatch", "autopotion", "npctalk", "alchemy", "option", "worldmap", "help"]

func _args(flag: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

## HudPanels names the NetClient autoload, which a --script run registers
## only after the tool itself is compiled; so the panel scripts are loaded
## here, at run time, the way hud_main_popup_test.gd does.
func _initialize() -> void:
	var watchdog := create_timer(900.0)
	watchdog.timeout.connect(func() -> void:
		print("=== watchdog: stopped")
		quit(1))
	await process_frame
	var pk2 := _args("--pk2")
	if pk2.is_empty():
		printerr("usage: --pk2=<Media.pk2> [--panel=<id> ...]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2[0])
	if archive == null:
		printerr("could not open ", pk2[0])
		quit(1)
		return
	var table: UiTextTable = null
	var entry := ObjectLoader.find_file(archive, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	if entry != null:
		table = UiTextTable.parse(archive.read_file(entry))
	var builder := UiBuilder.new(archive, table)
	var wanted := _args("--panel")
	if wanted.is_empty():
		wanted = PackedStringArray(PANELS)
	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var map_script := load("res://scripts/ui/hud/hud_worldmap.gd") as GDScript
	root.size = Vector2i(1920, 1080)
	var panels: Control = panels_script.new(builder)
	get_root().add_child(panels)
	await process_frame
	for id in wanted:
		var window: Control = null
		if id == "worldmap":
			var map: Control = map_script.new(builder)
			get_root().add_child(map)
			if map.call("build_worldmap"):
				map.call("open")
				window = map
		elif id == "help":
			var help: Control = (load("res://scripts/ui/help_window.gd") as GDScript).new()
			get_root().add_child(help)
			help.call("setup", builder, [], false)
			help.show()
			window = help.get_node_or_null("HelpFrame") as Control
		elif id == "option":
			window = panels.call("toggle_option")
		else:
			window = panels.call("open", id)
		if window == null:
			print("=== %s: not built" % id)
			continue
		for i in 4:
			await process_frame
		var lines: Array[String] = []
		_collect(window, window, lines)
		lines.sort()
		print("=== %s: %d visible nodes, window rect %s" % [id, lines.size(), str(Rect2(window.position, window.size))])
		for line in lines:
			print("%s | %s" % [id, line])
		if id == "worldmap":
			window.queue_free()
		elif id == "help":
			window.get_parent().queue_free()
		elif id == "option":
			panels.call("close_option")
		else:
			window.hide()
	quit(0)

func _collect(win: Node, node: Node, out: Array[String]) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is CanvasItem:
		var line := "%s <%s>" % [str(win.get_path_to(node)), node.get_class()]
		if node is Control:
			var c := node as Control
			line += " %s" % str(Rect2(c.global_position - (win as Control).global_position, c.size).abs())
		var tex: Texture2D = null
		if node is TextureRect:
			tex = (node as TextureRect).texture
		elif node is TextureButton:
			tex = (node as TextureButton).texture_normal
		elif node is NinePatchRect:
			tex = (node as NinePatchRect).texture
		if tex != null:
			line += " tex=%s" % str(tex.get_size())
		if node is Label:
			line += " text=%s" % (node as Label).text.replace("\n", "\\n")
		out.append(line)
	for child in node.get_children():
		_collect(win, child, out)
