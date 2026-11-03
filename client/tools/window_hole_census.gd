extends SceneTree

## Dev tool (round 858): where each game window lets the world show through.
## Builds every window the HUD opens (as audit_input_bleed.gd does) alone over
## a flat ground, takes the frame twice -- once over magenta, once over green
## -- and counts, inside the window's drawn area, the pixels that differ
## between the two: a pixel the ground reaches. "full" pixels are the ground
## itself (nothing drawn there), "part" pixels are drawn translucent.
##
## The drawn area is the window's own rect joined with the rect of every
## visible control in it that draws a picture or a fill (TextureRect,
## TextureButton, NinePatchRect, ColorRect, Panel; text is not counted), so a
## side panel hung outside the window (the Help window's menu) is inside.
##
## Each hole is grouped into connected pieces, and each piece says what is
## drawn over its first pixel: "UNCOVERED" (no picture there at all -- a
## missing piece) or the topmost picture and its texel's alpha there (the
## art's own transparency, which the original draws the same way).
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
const GROUND_A := Color(1, 0, 1)
const GROUND_B := Color(0, 1, 0)

const PANELS := ["inventory", "character", "skill", "action", "party", "academy",
	"quest", "guild", "community", "storage", "guild_storage", "store", "exchange", "exchange_retail",
	"stall", "system", "partymatch", "autopotion", "npctalk", "alchemy", "grant", "itemmall",
	"option", "worldmap", "help",
	"party_settings", "guild_name", "guild_leave", "guild_box", "recall", "stall_text", "stall_avatar",
	"silk_history", "exchange_gold", "hammer", "crest", "reverse_return", "custom_title", "cast_bar",
	"friend_add", "friend_delete", "stall_network", "stall_network_notice", "guild_notice_write",
	"guild_donate", "guild_level_up", "guild_master_leave", "guild_vote", "guild_gp_history",
	"guild_event", "guild_recall", "revive", "use_on", "composite", "gacha_select", "whole_chat",
	"buff_cancel"]

var _builder: UiBuilder
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
	var wanted := _args("--panel")
	if wanted.is_empty():
		wanted = PackedStringArray(PANELS)
	var ground := ColorRect.new()
	ground.size = Vector2(VIEW)
	ground.color = GROUND_A
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ground)
	var ui := Control.new()
	ui.name = "UI"
	ui.size = Vector2(VIEW)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(ui)
	_builder.apply_ui_theme(ui)
	var panels: Control = (load("res://scripts/ui/hud/hud_panels.gd") as GDScript).new(_builder)
	panels.size = Vector2(VIEW)
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
			total_full += await _census(label, c, ground, out)
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

## Opens one scenario; returns the window(s) it built (may be empty when the
## shown-set diff finds them).
func _open(id: String, ui: Control, panels: Control) -> Array:
	var noop := func() -> void: pass
	var noop1 := func(_a = null) -> void: pass
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
			return []
		"exchange", "exchange_retail":
			panels.call("_drop_exchange_window")
			ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, id == "exchange")
			panels.set("exchange_canvas", Vector2(VIEW))
			panels.call("open_exchange_window")
			var inv = (panels.get("_windows") as Dictionary).get("inventory")
			if inv != null:
				(inv as Control).hide()
			var ex = (panels.get("_windows") as Dictionary).get("exchange")
			if id == "exchange_retail":
				ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_EXCHANGE_PORTRAITS, true)
			return [ex] if ex != null else []
		"party_settings":
			panels.call("open_party_settings")
		"guild_name":
			panels.call("open_guild_name_prompt", "NPC_CH_GENARAL_SP")
		"guild_leave":
			panels.call("open_guild_leave_prompt", "NPC_CH_GENARAL_SP")
		"guild_box":
			panels.call("open_guild_box", 1, "Guild", "Bob")
		"recall":
			panels.call("open_recall_designate_prompt", "STORE_CH_GATE", "Jangan")
		"stall_text":
			panels.call("open_stall_text_box", false, "Selling potions", noop1, noop)
		"stall_avatar":
			panels.call("open_stall_avatar_question", noop1)
		"silk_history":
			panels.call("open_silk_history")
		"exchange_gold":
			panels.call("open_exchange_gold_box")
		"hammer":
			panels.call("open_hammer_confirm", 13)
		"crest":
			panels.call("open_crest_box", 13, 0)
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

## One window: both frames, the hole mask inside its drawn area, the pieces.
## Returns the full-hole pixel count.
func _census(id: String, window: Control, ground: ColorRect, out: String) -> int:
	_name_textures()
	ground.color = GROUND_A
	await process_frame
	await process_frame
	var a := root.get_texture().get_image()
	ground.color = GROUND_B
	await process_frame
	await process_frame
	var b := root.get_texture().get_image()
	ground.color = GROUND_A
	if out != "":
		a.save_png("%s/%s.png" % [out, id])
	var pictures: Array = []
	_pictures(window, pictures, Rect2(Vector2.ZERO, Vector2(VIEW)))
	# A window's own rect is its area; a bare container (a box host the size
	# of the screen) has only what it draws.
	var area := Rect2(window.get_global_rect()) if window is HudWindow else Rect2()
	var inside := Image.create(VIEW.x, VIEW.y, false, Image.FORMAT_L8)
	if area.size.x > 0:
		_fill(inside, area)
	elif not pictures.is_empty():
		area = pictures[0][0]
	var box := area
	for p in pictures:
		_fill(inside, p[0])
		box = box.merge(p[0])
	var bi := Rect2i(box.abs()).intersection(Rect2i(Vector2i.ZERO, VIEW))
	var full := 0
	var part := 0
	var counted := 0
	var holes := PackedByteArray()
	holes.resize(VIEW.x * VIEW.y)
	for y in range(bi.position.y, bi.end.y):
		for x in range(bi.position.x, bi.end.x):
			if inside.get_pixel(x, y).r < 0.5:
				continue
			counted += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if _close(ca, cb, 3.0 / 255.0):
				continue
			if _close(ca, GROUND_A, 3.0 / 255.0) and _close(cb, GROUND_B, 3.0 / 255.0):
				full += 1
				holes[y * VIEW.x + x] = 2
			else:
				part += 1
				holes[y * VIEW.x + x] = 1
	print("HOLES %s full %d part %d area %d rect %s" % [id, full, part, counted, str(area)])
	for piece in _pieces(holes):
		if int(piece["n"]) < _min_piece:
			continue
		var first: Vector2 = piece["first"]
		print("PIECE %s %s n %d full %d at %s :: %s" % [id, str(piece["box"]), piece["n"], piece["full"],
			str(first - window.get_global_position()), _cover(pictures, first + Vector2(0.5, 0.5), window)])
	return full

func _close(p: Color, q: Color, tol: float) -> bool:
	return absf(p.r - q.r) <= tol and absf(p.g - q.g) <= tol and absf(p.b - q.b) <= tol

func _fill(img: Image, r: Rect2) -> void:
	var c := Rect2i(r.abs()).intersection(Rect2i(Vector2i.ZERO, VIEW))
	if c.size.x > 0 and c.size.y > 0:
		img.fill_rect(c, Color.WHITE)

## Connected pieces (4-neighbour) of the hole mask: box, size, full count and
## the first pixel.
func _pieces(holes: PackedByteArray) -> Array:
	var seen := PackedByteArray()
	seen.resize(holes.size())
	var out: Array = []
	for i in holes.size():
		if holes[i] == 0 or seen[i] != 0:
			continue
		var stack := PackedInt32Array([i])
		seen[i] = 1
		var n := 0
		var nfull := 0
		var lo := Vector2i(VIEW.x, VIEW.y)
		var hi := Vector2i(-1, -1)
		while not stack.is_empty():
			var k: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			n += 1
			if holes[k] == 2:
				nfull += 1
			var x := k % VIEW.x
			var y := k / VIEW.x
			lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
			hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
			for d in [-1, 1, -VIEW.x, VIEW.x]:
				var m: int = k + int(d)
				if m < 0 or m >= holes.size():
					continue
				if (d == -1 and x == 0) or (d == 1 and x == VIEW.x - 1):
					continue
				if holes[m] != 0 and seen[m] == 0:
					seen[m] = 1
					stack.append(m)
		out.append({"n": n, "full": nfull, "box": Rect2i(lo, hi - lo + Vector2i.ONE),
			"first": Vector2(i % VIEW.x, i / VIEW.x)})
	return out

## Every visible control under `node` that draws a picture or a fill, in draw
## order: [global rect, control].
func _pictures(node: Node, out: Array, clip: Rect2) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Control:
		var c := node as Control
		var r := c.get_global_rect().abs().intersection(clip)
		if r.size.x >= 1.0 and r.size.y >= 1.0 and (_is_picture(c) or _is_frame(c)):
			out.append([r, c])
		if c.clip_contents:
			clip = clip.intersection(c.get_global_rect().abs())
	for child in node.get_children():
		_pictures(child, out, clip)

## A frame UiBuilder built from an 8- or 6-slice base: a bare Control whose
## picture children run around its whole rect. Its inside is the window's
## too, though nothing of the frame draws there.
static func _is_frame(c: Control) -> bool:
	if c.get_class() != "Control" or c.size.x < 8.0 or c.size.y < 8.0:
		return false
	var n := 0
	var box := Rect2()
	for child in c.get_children():
		if child is TextureRect and (child as TextureRect).texture != null:
			var r := Rect2((child as Control).position, (child as Control).size)
			box = r if n == 0 else box.merge(r)
			n += 1
	return n >= 6 and box.position.is_equal_approx(Vector2.ZERO) and box.size.is_equal_approx(c.size)

static func _is_picture(c: Control) -> bool:
	if c is TextureRect:
		return (c as TextureRect).texture != null
	if c is TextureButton:
		return (c as TextureButton).texture_normal != null
	if c is NinePatchRect:
		return (c as NinePatchRect).texture != null
	return c is ColorRect or c is Panel

## What is drawn at `p`: the topmost picture, its texel alpha, and how many
## pictures lie under the point.
func _cover(pictures: Array, p: Vector2, window: Control) -> String:
	var hits: Array = []
	for pr in pictures:
		if (pr[0] as Rect2).has_point(p) and _is_picture(pr[1]):
			hits.append(pr[1])
	if hits.is_empty():
		return "UNCOVERED"
	var top := hits[hits.size() - 1] as Control
	var desc := "%s <%s>" % [str(window.get_path_to(top)), top.get_class()]
	var tex: Texture2D = null
	if top is TextureRect:
		tex = (top as TextureRect).texture
	elif top is TextureButton:
		tex = (top as TextureButton).texture_normal
	if tex != null:
		desc += " %s alpha %s" % [_names.get(tex, "?"), _texel_alpha(top, tex, p)]
	elif top is ColorRect:
		desc += " colour %s" % str((top as ColorRect).color)
	return "%s (%d under)" % [desc, hits.size()]

## The texture's alpha at screen point p as the control maps it (scale, tile
## or keep), or "?".
func _texel_alpha(c: Control, tex: Texture2D, p: Vector2) -> String:
	var img := tex.get_image()
	if img == null:
		return "?"
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	var local := c.get_global_transform().affine_inverse() * p
	var ts := Vector2(img.get_size())
	var uv := Vector2.ZERO
	var tile := c is TextureRect and (c as TextureRect).stretch_mode == TextureRect.STRETCH_TILE
	var keep := c is TextureRect and (c as TextureRect).stretch_mode in [TextureRect.STRETCH_KEEP, TextureRect.STRETCH_KEEP_CENTERED]
	if tile:
		uv = Vector2(fposmod(local.x, ts.x), fposmod(local.y, ts.y))
	elif keep:
		uv = local
	else:
		uv = local / c.size * ts
	var px := Vector2i(clampi(int(uv.x), 0, int(ts.x) - 1), clampi(int(uv.y), 0, int(ts.y) - 1))
	if uv.x < 0 or uv.y < 0 or uv.x >= ts.x or uv.y >= ts.y:
		return "outside-art"
	return "%.2f" % img.get_pixelv(px).a

func _name_textures() -> void:
	var cache = _builder.get("_texture_cache")
	if cache is Dictionary:
		for k in cache:
			_names[cache[k]] = String(k).get_file()
