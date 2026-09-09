extends SceneTree

## Dev tool: builds a real HudWindow from a real archive and prints the
## resulting node tree -- every node's class, rect, draw order and whether
## its texture actually loaded.
##
## This exists because "the window looks wrong" is not a finding. A window
## is a stack of authored rectangles; when one is in the wrong place, or is
## drawn in the wrong order, or has no texture behind it, that is visible
## here as a number rather than guessed at from a screenshot.
##
## Usage:
##   godot4 --headless --path client --script res://tools/dump_window_tree.gd -- \
##     --pk2=/path/to/Media.pk2 --layout=ifplayerinfo [--layout=ifinventory]

func _args(flag: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

func _init() -> void:
	var pk2 := _args("--pk2")
	var layouts := _args("--layout")
	if pk2.is_empty() or layouts.is_empty():
		printerr("usage: --pk2=<Media.pk2> --layout=<resinfo name>")
		quit(2)
		return

	var archive := Pk2Reader.open(pk2[0])
	if archive == null:
		printerr("could not open ", pk2[0])
		quit(1)
		return

	var builder := UiBuilder.new(archive, null)

	for name in layouts:
		var win := HudWindow.new()
		var built := win.build(builder, "resinfo\\" + name + ".txt", name)
		print("=== %s built=%s size=%s" % [name, str(built), str(win.size)])
		if not built:
			continue
		get_root().add_child(win)
		# Let the theme cache and the layout settle, so what is printed is
		# what the game actually draws rather than the state at build time.
		await process_frame
		await process_frame
		_describe(win, 0)
		get_root().remove_child(win)
		win.queue_free()
	quit(0)

func _describe(node: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	var line := "%s%s <%s>" % [pad, node.name, node.get_class()]
	if node is Control:
		var c := node as Control
		line += " rect=%s..%s" % [str(c.position), str(c.position + c.size)]
	if node is TextureRect:
		var tr := node as TextureRect
		if tr.texture == null:
			line += "  TEXTURE=null"
		else:
			line += "  min=%s" % str(tr.get_combined_minimum_size())
			line += "  tex=%s stretch=%d" % [str(tr.texture.get_size()), tr.stretch_mode]
			if tr.texture is AtlasTexture:
				line += " atlas_region=%s" % str((tr.texture as AtlasTexture).region)
	elif node is NinePatchRect:
		var np := node as NinePatchRect
		line += "  ninepatch tex=%s" % ("null" if np.texture == null else str(np.texture.get_size()))
	elif node is Label:
		var lb := node as Label
		var f := lb.get_theme_font("font")
		var fs := lb.get_theme_font_size("font_size")
		line += "  min=%s font_size=%d height=%.1f face=%s text=%s" % [
			str(lb.get_combined_minimum_size()), fs,
			(f.get_height(fs) if f != null else -1.0),
			(f.get_font_name() if f != null else "-"), lb.text]
	print(line)
	for child in node.get_children():
		_describe(child, depth + 1)
