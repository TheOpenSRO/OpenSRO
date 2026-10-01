extends SceneTree

## Dev tool (round 672): measures how crisp the client's text is at each UI
## scale, from the rendered frame -- not from a look at it.
##
## Builds the HUD's text the way World3D does (HudPlayerInfo's name, level and
## HP/MP numbers, the chat and the system-message lists, the GM notice, the
## character window, a name plate) from a real Media.pk2, then for every UI
## scale asked for: applies it with ClientSettings.apply_ui_scale, renders a
## frame, renders it again with one text kind made invisible, and diffs the
## two. The pixels that changed are that kind's text, and each is fitted to
## the background plus a fraction of the text's own colour (or its shadow's
## or outline's):
##
##   coverage = dot(shown - hidden, ink - hidden) / |ink - hidden|^2
##
## Aliased text drawn 1:1 -- the reference client's, glyphs from
## GetGlyphOutlineW(GGO_BITMAP) -- has every text pixel at coverage 1: one
## level, a 1-pixel edge. A glyph texture magnified by a linear filter has
## a ramp of partial pixels at every edge.
##
## One line per kind per scale:
##   TEXT <scale> <kind> px=<text pixels> partial=<% not at a full ink>
##        levels=<distinct coverage values, 1/16 steps> edge=<mean px per edge>
##        mass=<sum of coverage / scale^2, the ink area in canvas units: a glyph
##        drawn as a solid block or lost shows here> fill=<text px / ink box>
##        ink_w=<ink width px> want_w=<string width x scale> ratio=<ink/want>
## plus OVERSAMPLING <scale> <text server's global value> <window flag>,
## RECT lines (each text control's screen rect and the font it resolves to,
## for a layout diff between two revisions), EACH/LOST lines (each Button's
## ink width against its string's advance width, judged against its own
## ratio at the first scale -- the lost-last-glyph check, 2026-09-11's
## "Registe", round 672's "Sel") and crops of each kind per scale.
##
## Usage (a real GL context, so a window; on the render box under xvfb-run):
##   godot4 --rendering-driver opengl3 --resolution 3840x2160 --path client \
##     --script res://tools/measure_text_crispness.gd -- --pk2=/path/Media.pk2 \
##     [--scales=1,1.25,1.5,1.95,2] [--out=/var/tmp/x] [--login] [flags]
## The scales are applied one after another in the running client, as the
## debug panel's slider does. Flags:
##   --login           adds the 2026-09-11 login form (a VBoxContainer of
##                     LineEdits and Buttons, "Register" among them)
##   --scale-first     applies the first scale before anything is built, as
##                     Boot does (a fresh start at that scale)
##   --no-plate        leaves out the name plate
##   --each-all        prints every Button's and Label's INK line
##   --force-oversampling, --nearest-text, --snap-vertices, --snap-transforms
##                     variants weighed in round 672 before the fix; the
##                     first reproduces the solid-block glyphs (a flag
##                     flipped with no size change, ClientSettings)

var _out := ""
var _builder: UiBuilder
var _ui: Control
var _kinds: Array = []   # [{name, nodes:Array, hide:Callable, show:Callable, inks:Array, want_w:Callable}]
var _plate: Label3D
var _cam: Camera3D
## Each string's ink/advance ratio at the first scale measured.
var _first_ratio := {}
## Where each built window sits, in canvas units, re-applied at every scale.
var _place := {}

func _arg(flag: String, default_val: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return default_val

func _has(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)

func _initialize() -> void:
	var watchdog := create_timer(600.0)
	watchdog.timeout.connect(func() -> void:
		print("=== watchdog: stopped")
		quit(1))
	await process_frame
	var pk2 := _arg("--pk2", "")
	_out = _arg("--out", "")
	if _out != "":
		DirAccess.make_dir_recursive_absolute(_out)
	var scales: Array[float] = []
	for s in _arg("--scales", "1,1.25,1.5,1.95,2").split(","):
		scales.append(float(s))
	var archive: Pk2Reader = Pk2Reader.open(pk2) if pk2 != "" else null
	if archive == null:
		printerr("usage: --pk2=<Media.pk2> [--scales=..] [--out=dir] [--login]")
		quit(2)
		return
	var table: UiTextTable = null
	var entry := ObjectLoader.find_file(archive, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	if entry != null:
		table = UiTextTable.parse(archive.read_file(entry))
	_builder = UiBuilder.new(archive, table)
	if _has("--scale-first"):
		# As Boot does: the scale is in place before any text is drawn.
		(load("res://scripts/client_settings.gd") as GDScript).call("apply_ui_scale", get_root(), scales[0])
		if _has("--force-oversampling"):
			get_root().set_use_font_oversampling(true)
		for i in 3:
			await process_frame
	await _build()
	for s in scales:
		await _measure_scale(s)
	print("=== done")
	quit(0)

# --- building ---------------------------------------------------------------

func _build() -> void:
	_ui = Control.new()
	_ui.name = "UI"
	_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(_ui)
	# The in-game UI root's own font setup, when this revision has one.
	if _builder.has_method("apply_ui_theme"):
		_builder.call("apply_ui_theme", _ui)
	# A flat backdrop that is the clear colour, so the 3D name plate shows
	# through the canvas.
	RenderingServer.set_default_clear_color(Color(0.32, 0.27, 0.2))

	var pmi_script := load("res://scripts/ui/hud/hud_player_info.gd") as GDScript
	var pmi: Control = pmi_script.new(_builder)
	_ui.add_child(pmi)
	pmi.position = Vector2(4, 7)
	pmi.call("setup")
	pmi.call("set_character", "deadass3", 140)
	pmi.call("set_hp", 24936, 24936)
	pmi.call("set_mp", 90333, 90333)
	for n in ["GDR_PMI_TXT_ID", "GDR_PMI_TXT_LEVEL", "GDR_PMI_TXT_HP", "GDR_PMI_TXT_MP"]:
		var l := pmi.find_child(n, true, false) as Label
		if l != null:
			_add_label_kind("pmi_" + n.trim_prefix("GDR_PMI_TXT_").to_lower(), [l])

	var chat_script := load("res://scripts/ui/hud/hud_chat.gd") as GDScript
	var chat: Control = chat_script.new(_builder)
	_ui.add_child(chat)
	chat.call("setup")
	_place[chat] = Vector2(4, 620)
	chat.call("add_message", "deadass3", "Selling Blue stones and Elixirs, whisper me", Color.WHITE)
	chat.call("add_message", "Notice", "The Tiger Girl has appeared in the Tiger Mountain.", Color(1.0, 0.86, 0.3))
	chat.call("add_message", "Ranger", "lfp Jangan cave 1, need priest (Lv 90+)", Color(0.6, 0.9, 1.0))
	await process_frame
	var list: Control = chat.call("_current_list")
	if list != null:
		var inks := [Color.WHITE, Color(1.0, 0.86, 0.3), Color(0.6, 0.9, 1.0), Color(0, 0, 0)]
		for m in list.get("lines"):
			inks.append(m["color"])
		_add_modulate_kind("chat_lines", [list], inks, Callable())

	var sys_script := load("res://scripts/ui/hud/hud_system_message.gd") as GDScript
	var syslog: Control = sys_script.new(_builder)
	_ui.add_child(syslog)
	syslog.call("setup")
	_place[syslog] = Vector2(560, 620)
	syslog.call("add_message", 0, "You have gained 1,204 experience points.")
	syslog.call("add_message", 0, "Unique monster Tiger Girl has been killed.")
	await process_frame
	var slist: Control = syslog.call("list")
	if slist != null:
		var inks2 := [Color(0, 0, 0)]
		for m in slist.get("lines"):
			inks2.append(m["color"])
		_add_modulate_kind("syslog_lines", [slist], inks2, Callable())

	var notice_script := load("res://scripts/ui/hud/hud_notice.gd") as GDScript
	var notice: Control = notice_script.new()
	_ui.add_child(notice)
	notice.call("setup", _builder)
	notice.call("show_notice", "Unique Tiger Girl has been defeated by deadass3.")
	notice.set_process(false)
	_place[notice] = Vector2(480, 30)
	var ntext: String = notice.call("text")
	_kinds.append({
		"name": "notice",
		"nodes": [notice],
		"hide": func() -> void:
			notice.set("_text", "")
			notice.queue_redraw(),
		"show": func() -> void:
			notice.set("_text", ntext)
			notice.queue_redraw(),
		"inks": [notice.get("TEXT_COLOR")],
		"want_w": func() -> float:
			var f: Font = notice.get("_font")
			return f.get_string_size(ntext, HORIZONTAL_ALIGNMENT_LEFT, -1, int(notice.get("_font_size"))).x,
	})

	var panels_script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	var panels: Control = panels_script.new(_builder)
	_ui.add_child(panels)
	await process_frame
	var win: Control = panels.call("open", "character")
	if win != null:
		_place[win] = Vector2(470, 90)
		win.position = _place[win]
		await process_frame
		var labels: Array = []
		_collect_labels(win, labels)
		_add_label_kind("charwin_labels", labels)

	# Text Buttons the way the game's own dialogs make them (Button.new() and
	# a text), in whatever font the UI root gives them; each is checked for
	# a lost glyph on its own (the 2026-09-11 "Registe").
	var bbox := VBoxContainer.new()
	_place[bbox] = Vector2(1240, 560)
	_ui.add_child(bbox)
	var buttons: Array = []
	for bt in ["Register", "Buy", "Sell", "Cancel", "Deposit", "Withdraw", "LEVEL UP", "Close"]:
		var b := Button.new()
		b.text = bt
		b.custom_minimum_size = Vector2(160, 0)
		bbox.add_child(b)
		buttons.append(b)
	_add_button_kind("buttons", buttons)

	if _has("--login"):
		var box := VBoxContainer.new()
		box.position = Vector2(1240, 300)
		box.size = Vector2(300, 180)
		# Godot's own font, as the 2026-09-11 login form had: no theme here.
		_ui.add_child(box)
		var t := Label.new()
		t.text = "SRRevamp"
		box.add_child(t)
		for p in ["127.0.0.1:15779", "Username"]:
			var e := LineEdit.new()
			e.text = p
			box.add_child(e)
		var ctrls: Array = []
		for bt in ["Login", "Register"]:
			var b := Button.new()
			b.text = bt
			box.add_child(b)
			ctrls.append(b)
		if _ui.theme != null:
			# Keep it in Godot's default font even when the root has a theme.
			box.theme = Theme.new()
			box.theme.default_font = ThemeDB.fallback_font
		_add_button_kind("login_register_default_font", [ctrls[1]])

	if not _has("--no-plate"):
		await _build_plate()
	for i in 3:
		await process_frame

## A name plate: World3D's own builder, in front of a camera.
func _build_plate() -> void:
	var w3d_script := load("res://scripts/World3D.gd") as GDScript
	var w3d: Node = w3d_script.new()
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.current = true
	cam.position = Vector3.ZERO
	var anchor := Node3D.new()
	get_root().add_child(anchor)
	anchor.position = Vector3(3.2, -2.6, -12.0)
	_plate = w3d.call("_name_plate", "deadass3", 0.0)
	anchor.add_child(_plate)
	_cam = cam
	w3d.free()
	_kinds.append({
		"name": "name_plate",
		"nodes": [],
		"hide": func() -> void: _plate.visible = false,
		"show": func() -> void: _plate.visible = true,
		"inks": [_plate.modulate, Color(_plate.outline_modulate, 1.0), Color(0, 0, 0)],
		"want_w": func() -> float: return -1.0,
		"plate": true,
	})

func _collect_labels(node: Node, out: Array) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Label and (node as Label).text.strip_edges() != "":
		out.append(node)
	for c in node.get_children():
		_collect_labels(c, out)

func _label_inks(l: Control) -> Array:
	var inks := [l.get_theme_color("font_color")]
	var sh := l.get_theme_color("font_shadow_color")
	if sh.a > 0.0:
		inks.append(sh)
	if l.get_theme_constant("outline_size") > 0:
		inks.append(l.get_theme_color("font_outline_color"))
	return inks

func _add_label_kind(kind: String, labels: Array) -> void:
	if labels.is_empty():
		return
	var inks: Array = []
	for l in labels:
		inks.append_array(_label_inks(l))
	_add_modulate_kind(kind, labels, inks, func() -> float:
		var w := 0.0
		for l in labels:
			var lab := l as Label
			var f := lab.get_theme_font("font")
			w = maxf(w, f.get_string_size(lab.text, HORIZONTAL_ALIGNMENT_LEFT, -1, lab.get_theme_font_size("font_size")).x)
		return w if labels.size() == 1 else -1.0)

func _add_modulate_kind(kind: String, nodes: Array, inks: Array, want: Callable) -> void:
	_kinds.append({
		"name": kind,
		"nodes": nodes,
		"hide": func() -> void:
			for n in nodes:
				(n as CanvasItem).self_modulate.a = 0.0,
		"show": func() -> void:
			for n in nodes:
				(n as CanvasItem).self_modulate.a = 1.0,
		"inks": inks,
		"want_w": want if want.is_valid() else func() -> float: return -1.0,
	})

const BUTTON_COLOURS := ["font_color", "font_pressed_color", "font_hover_color", "font_focus_color",
	"font_hover_pressed_color", "font_disabled_color", "font_outline_color"]

func _add_button_kind(kind: String, buttons: Array) -> void:
	_kinds.append({
		"name": kind,
		"nodes": buttons,
		"hide": func() -> void:
			for b in buttons:
				for c in BUTTON_COLOURS:
					(b as Control).add_theme_color_override(c, Color(0, 0, 0, 0)),
		"show": func() -> void:
			for b in buttons:
				for c in BUTTON_COLOURS:
					(b as Control).remove_theme_color_override(c),
		"inks": [(buttons[0] as Control).get_theme_color("font_color")],
		"want_w": func() -> float:
			var b := buttons[0] as Button
			return b.get_theme_font("font").get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, b.get_theme_font_size("font_size")).x,
	})

# --- measuring --------------------------------------------------------------

func _frame() -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return get_root().get_texture().get_image()

func _screen_rect(nodes: Array, s: float, img: Image) -> Rect2i:
	var r := Rect2()
	var first := true
	for n in nodes:
		var c := n as Control
		var cr := Rect2(c.get_global_rect().position * s, c.get_global_rect().size * s).grow(24.0 * s)
		r = cr if first else r.merge(cr)
		first = false
	if first:
		return Rect2i(0, 0, img.get_width(), img.get_height())
	return Rect2i(r).intersection(Rect2i(0, 0, img.get_width(), img.get_height()))

func _measure_scale(s: float) -> void:
	var settings_script := load("res://scripts/client_settings.gd") as GDScript
	settings_script.call("apply_ui_scale", get_root(), s)
	for i in 4:
		await process_frame
	# Variants, to weigh a fix before writing it (round 672).
	if _has("--force-oversampling"):
		get_root().set_use_font_oversampling(true)
	if _has("--snap-vertices"):
		get_root().snap_2d_vertices_to_pixel = true
	if _has("--snap-transforms"):
		get_root().snap_2d_transforms_to_pixel = true
	if _has("--nearest-text"):
		for k in _kinds:
			for n in k["nodes"]:
				(n as CanvasItem).texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_plate.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	for c in _place:
		(c as Control).position = _place[c]
	for i in 3:
		await process_frame
	var ts := TextServerManager.get_primary_interface()
	print("OVERSAMPLING %.2f %.4f flag=%s window=%s" % [s, ts.font_get_global_oversampling(),
		str(get_root().is_using_font_oversampling()), str(get_root().size)])
	var shown := await _frame()
	_dump_rects(s)
	var tag := ("%.2f" % s).replace(".", "_")
	if _out != "":
		shown.save_png("%s/full_%s.png" % [_out, tag])
		_save_crop(shown, Rect2i(Vector2i(0, 0), Vector2i(Vector2(430, 120) * s)), "%s/pmi_%s.png" % [_out, tag])
	for k in _kinds:
		(k["hide"] as Callable).call()
		var hidden := await _frame()
		(k["show"] as Callable).call()
		var rect: Rect2i
		if k.get("plate", false):
			var at := _cam.unproject_position(_plate.global_position) * s
			rect = Rect2i(Vector2i(at) - Vector2i(400, 120), Vector2i(800, 240)).intersection(
				Rect2i(0, 0, shown.get_width(), shown.get_height()))
		else:
			rect = _screen_rect(k["nodes"], s, shown)
		var m := _measure(shown, hidden, rect, k["inks"])
		var want: float = (k["want_w"] as Callable).call()
		var want_px := want * s if want > 0.0 else -1.0
		var bb: Rect2i = m["bbox"]
		print("TEXT %.2f %s px=%d partial=%.1f%% levels=%d edge=%.2f mass=%.0f fill=%.2f ink_w=%d want_w=%.1f ratio=%s" % [
			s, k["name"], m["px"], m["partial"], m["levels"], m["edge"], m["mass"] / (s * s),
			float(m["px"]) / maxf(1.0, bb.size.x * bb.size.y), m["ink_w"], want_px,
			("%.3f" % (float(m["ink_w"]) / want_px)) if want_px > 0.0 else "-"])
		var per := _per_control(shown, hidden, k["nodes"], s)
		if per != "":
			print("EACH %.2f %s %s" % [s, k["name"], per])
		if _out != "" and m["px"] > 0:
			_save_crop(shown, m["bbox"].grow(int(4 * s)), "%s/%s_%s.png" % [_out, k["name"], tag])
	await _frame()

## For each Label/Button of a kind: its ink width in its own rect against
## its string's width, and the worst one -- a lost glyph is a short ink box.
func _per_control(a: Image, b: Image, nodes: Array, s: float) -> String:
	var worst := 9.0
	var worst_text := ""
	var n := 0
	var lost := 0
	for node in nodes:
		var c := node as Control
		if c == null or not (c is Label or c is Button):
			continue
		var text := String(c.get("text"))
		var f := c.get_theme_font("font")
		var want := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, c.get_theme_font_size("font_size")).x * s
		var gr := c.get_global_rect()
		var r := Rect2i(Rect2(gr.position * s, gr.size * s).grow_individual(4 * s, 0, 4 * s, 0)).intersection(Rect2i(0, 0, a.get_width(), a.get_height()))
		var minx := 1 << 30
		var maxx := -1
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				if absf(ca.r - cb.r) > 0.012 or absf(ca.g - cb.g) > 0.012 or absf(ca.b - cb.b) > 0.012:
					minx = mini(minx, x)
					maxx = maxi(maxx, x)
		if maxx < 0 or want <= 0.0:
			continue
		n += 1
		var ratio := float(maxx - minx + 1) / want
		if _has("--each-all"):
			print("INK %.2f %s ink=%d want=%.1f ratio=%.3f" % [s, text.substr(0, 30), maxx - minx + 1, want, ratio])
		# Against the same string's own ratio at the first scale measured
		# (1.0): a lost glyph took 0.905 -> 0.800 off "Sell" at 1.25. Only
		# Buttons are judged: they are the path that clips (UiBuilder.
		# guard_button_font); a two- or three-letter Label moves by 0.07
		# between scales on its glyphs' own rounding ("Int" 0.923 -> 0.857
		# at a whole 2.0, base and round 672 alike).
		if not (c is Button):
			continue
		if not _first_ratio.has(text):
			_first_ratio[text] = ratio
		elif ratio < float(_first_ratio[text]) - 0.06:
			lost += 1
			print("LOST %.2f '%s' ink/advance %.3f, %.3f at the first scale" % [s, text.substr(0, 30), ratio, _first_ratio[text]])
		if ratio < worst:
			worst = ratio
			worst_text = text
	if n < 2:
		return ""
	return "n=%d lost=%d worst_ratio=%.3f worst=%s" % [n, lost, worst, worst_text.substr(0, 30)]

func _save_crop(img: Image, r: Rect2i, path: String) -> void:
	r = r.intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	if r.size.x <= 0 or r.size.y <= 0:
		return
	img.get_region(r).save_png(path)

func _measure(a: Image, b: Image, r: Rect2i, inks: Array) -> Dictionary:
	var px := 0
	var mass := 0.0
	var partial := 0
	var levels := {}
	var edges := 0
	var edge_px := 0
	var minx := 1 << 30
	var maxx := -1
	var miny := 1 << 30
	var maxy := -1
	for y in range(r.position.y, r.end.y):
		var run := []  # coverage of the current run of changed pixels
		for x in range(r.position.x, r.end.x + 1):
			var cov := -1.0
			if x < r.end.x:
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				if absf(ca.r - cb.r) > 0.012 or absf(ca.g - cb.g) > 0.012 or absf(ca.b - cb.b) > 0.012:
					cov = _coverage(ca, cb, inks)
			if cov >= 0.0:
				px += 1
				mass += cov
				if cov < 0.9:
					partial += 1
				levels[int(round(cov * 16.0))] = true
				run.append(cov)
				minx = mini(minx, x)
				maxx = maxi(maxx, x)
				miny = mini(miny, y)
				maxy = maxi(maxy, y)
			elif not run.is_empty():
				# Partial pixels at the run's two ends, before the first and
				# after the last full one (a run with no full pixel is all edge).
				var lead := 0
				while lead < run.size() and run[lead] < 0.9:
					lead += 1
				var trail := 0
				while trail < run.size() - lead and run[run.size() - 1 - trail] < 0.9:
					trail += 1
				edges += 2
				edge_px += lead + trail + 2
				run.clear()
	return {
		"px": px,
		"mass": mass,
		"partial": 100.0 * partial / maxf(1.0, px),
		"levels": levels.size(),
		"edge": float(edge_px) / maxf(1.0, edges),
		"ink_w": maxx - minx + 1 if maxx >= 0 else 0,
		"bbox": Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1) if maxx >= 0 else Rect2i(),
	}

## The best fit of `shown` as `hidden` plus a fraction of one ink colour.
func _coverage(shown: Color, hidden: Color, inks: Array) -> float:
	var best := -1.0
	var best_res := INF
	for ink in inks:
		var c := ink as Color
		var d := Vector3(c.r - hidden.r, c.g - hidden.g, c.b - hidden.b)
		var dd := d.dot(d)
		if dd < 0.0004:
			continue
		var v := Vector3(shown.r - hidden.r, shown.g - hidden.g, shown.b - hidden.b)
		var t := clampf(v.dot(d) / dd, 0.0, 1.0)
		var res := (v - d * t).length()
		if res < best_res:
			best_res = res
			best = t
	return maxf(best, 0.0)

func _dump_rects(s: float) -> void:
	_dump_node(_ui, s)

func _dump_node(node: Node, s: float) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Control:
		var c := node as Control
		var text := ""
		var fname := ""
		if c is Label or c is Button or c is LineEdit:
			text = String(c.get("text"))
		if text.strip_edges() != "" or c is RichTextLabel:
			var f := c.get_theme_font("normal_font" if c is RichTextLabel else "font")
			var fs := c.get_theme_font_size("normal_font_size" if c is RichTextLabel else "font_size")
			fname = _font_desc(f)
			var gr := c.get_global_rect()
			print("RECT %.2f %s %s rect=%s font=%s size=%d text=%s" % [s, str(_ui.get_path_to(c)), c.get_class(),
				str(Rect2(gr.position * s, gr.size * s)), fname, fs, text.replace("\n", "\\n").substr(0, 40)])
	for ch in node.get_children():
		_dump_node(ch, s)

func _font_desc(f: Font) -> String:
	if f == null:
		return "none"
	var base := f
	while base is FontVariation and (base as FontVariation).base_font != null:
		base = (base as FontVariation).base_font
	var client := _builder.font_at(0)
	if client != null and base == client:
		return "client"
	if base == ThemeDB.fallback_font:
		return "godot_default"
	return "other:" + base.get_font_name()
