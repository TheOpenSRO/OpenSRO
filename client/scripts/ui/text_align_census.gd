extends RefCounted
class_name TextAlignCensus

## Round 859: where a window's text and an edit's caret are drawn, against
## where the original draws them (TextLayout's rules: CIFStatic c:0x64d9b0 for
## static and button text, CIFEdit c:0x637b70 for edits, both inside the
## control's ClientRect, c:0x652800). MEASURED, not computed: for every text
## node with a layout control behind it, the frame is read back
##   - with everything shown,
##   - with the node's text hidden (its ink is what changed), and
##   - with the node's text hidden and the same string drawn by this class at
##     the original's origin, in the same face and size (the reference ink),
## and the two inks' boxes are compared: `dx` / `dy` (left / top edges) and
## `dr` (right edge), in UI pixels. The same face on both sides cancels the
## face's own bearings; what is left is where the text was put. Edits also get
## their caret measured (the frame with the caret against one without) against
## the original's quad (x at the text's left + the advance before the caret,
## 2 wide, from the text's top, tmHeight + 2 tall).
##
## The layout control is found by name in the builder's parsed layouts
## (`UiBuilder._layout_cache`), so the rule comes from the archive's own
## record (ClientRect, HAlign, VAlign) and not from what the node was given:
##   - a Label named "Text" / "ButtonLabel" is its owner's caption (a static's
##     art, a button): the owner's record, in the owner's rect;
##   - a Label or LineEdit with a record of its own name: that record, in the
##     rect the builder laid it at (UiBuilder.AUTHORED_RECT_META) or its own;
##   - a LineEdit laid over an authored edit (the chat line's "Input"): the
##     authored edit's record, in its rect.
## Text nodes with no record (code-made, OURS) are counted as `norule`.
## Multi-line text is skipped (the rules above are for one line).
##
## Used by tools/window_text_census.gd (every HUD window, at any UI scale) and
## by World3D's QA step `textalign:<name>` in a real client. Needs a real
## renderer. Prints `TEXT <window> <node> <kind> ... dx dy dr` per node,
## `CARET ...` per edit and `TEXTSUM <window> ...`.

const SAMPLE := "Sample 123"
## How far (UI px) around a node's rect its ink is looked for.
const SEARCH := 24.0

## Every parsed control of the builder's layouts, by name.
static func index_layouts(builder: UiBuilder) -> Dictionary:
	var out := {}
	if builder == null:
		return out
	var cache = builder.get("_layout_cache")
	if not (cache is Dictionary):
		return out
	for k in cache:
		var layout = cache[k]
		if layout == null:
			continue
		for sname in layout.sections:
			var sec = layout.sections[sname]
			for d in sec.controls:
				var arr: Array = out.get(d.name, [])
				if not arr.has(d):
					arr.append(d)
				out[d.name] = arr
	return out

static func _def_for(index: Dictionary, node_name: String, size: Vector2):
	var arr: Array = index.get(node_name, [])
	if arr.is_empty():
		return null
	for d in arr:
		if Vector2(d.rect.size) == size:
			return d
	return arr[0]

static func _rect_of(c: Control) -> Rect2:
	if c.has_meta(UiBuilder.AUTHORED_RECT_META):
		var r: Rect2 = c.get_meta(UiBuilder.AUTHORED_RECT_META)
		if r.size.x > 0 and r.size.y > 0:
			return r
	return Rect2(c.position, c.size)

## The text nodes under `window` with the rule each follows.
static func collect(window: Control, index: Dictionary) -> Array:
	var items: Array = []
	var norule: Array = []
	_collect(window, index, items, norule)
	return [items, norule]

static func _collect(n: Node, index: Dictionary, items: Array, norule: Array) -> void:
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is LineEdit and _has_edit_child(n):
		# An authored edit with the real line laid over it (the chat's box):
		# the player sees the line's text, not the box's.
		pass
	elif n is Label or n is LineEdit:
		var c := n as Control
		var item := _item(c, index)
		if item.is_empty():
			if (n is Label and (n as Label).text != "") or n is LineEdit:
				norule.append(c)
		else:
			items.append(item)
	elif n is RichTextLabel or n is Button:
		if (n is RichTextLabel and (n as RichTextLabel).text != "") or (n is Button and (n as Button).text != ""):
			norule.append(n)
	for ch in n.get_children():
		_collect(ch, index, items, norule)

static func _has_edit_child(n: Node) -> bool:
	for ch in n.get_children():
		if ch is LineEdit:
			return true
	return false

## A label's alignment as the layout codes it (0 / 1 / 2).
static func _code_h(h: HorizontalAlignment) -> int:
	return 1 if h == HORIZONTAL_ALIGNMENT_CENTER else (2 if h == HORIZONTAL_ALIGNMENT_RIGHT else 0)

static func _code_v(v: VerticalAlignment) -> int:
	return 1 if v == VERTICAL_ALIGNMENT_CENTER else (2 if v == VERTICAL_ALIGNMENT_BOTTOM else 0)

static func _item(c: Control, index: Dictionary) -> Dictionary:
	var it := _item_of(c, index)
	# A window that sets a label's alignment at run time (the party pane's
	# leader name: centred with no party, left in one -- its own READ) is
	# measured against the alignment it chose, and the line says so.
	if not it.is_empty() and c is Label:
		var l := c as Label
		var d = it["def"]
		if _code_h(l.horizontal_alignment) != d.halign or _code_v(l.vertical_alignment) != d.valign:
			it["halign"] = _code_h(l.horizontal_alignment)
			it["valign"] = _code_v(l.vertical_alignment)
			it["note"] = "align set at run time h%d v%d" % [it["halign"], it["valign"]]
	return it

static func _item_of(c: Control, index: Dictionary) -> Dictionary:
	var parent := c.get_parent() as Control
	if c is Label:
		var l := c as Label
		if l.text == "" or l.text.contains("\n") or l.autowrap_mode != TextServer.AUTOWRAP_OFF:
			return {}
		if (c.name == "Text" or c.name == "ButtonLabel") and parent != null:
			var pr := _rect_of(parent)
			var pd = _def_for(index, parent.name, pr.size)
			if pd != null:
				return {"node": c, "kind": "static", "def": pd, "rect": Rect2(Vector2.ZERO, pr.size), "name": "%s/%s" % [parent.name, c.name]}
		var r := _rect_of(c)
		var d = _def_for(index, c.name, r.size)
		if d != null:
			return {"node": c, "kind": "static", "def": d, "rect": r, "name": String(c.name)}
		if c.has_meta(UiBuilder.AUTHORED_RECT_META):
			# No record of its own (a window caption, a spin's value, a tab's
			# caption): the rect it was laid at and its own alignment, by
			# CIFStatic's rule -- how far the label is from where that rule
			# puts its text (the rect and the alignment are the code's).
			var own := UiLayoutParser.ControlDef.new()
			own.name = c.name
			own.type = "CIFStatic"
			own.client_rect = c.get_meta(UiBuilder.CLIENT_RECT_META, Rect2i())
			own.halign = _code_h(l.horizontal_alignment)
			own.valign = _code_v(l.vertical_alignment)
			var nm := String(c.name) if parent == null else "%s/%s" % [parent.name, c.name]
			return {"node": c, "kind": "static", "def": own, "rect": r, "name": nm, "note": "own rect and alignment"}
		if parent != null and is_equal_approx(c.anchor_right, 1.0) and is_equal_approx(c.anchor_bottom, 1.0) \
				and is_zero_approx(c.anchor_left) and is_zero_approx(c.anchor_top):
			# A label over its whole control (TwoDtBuilder.set_text's, a .2dt
			# CNIFStatic's text with the record's alignment): the control's
			# rect and the label's alignment by CIFStatic's rule (CNIFStatic's
			# own draw is not read: INFERRED the same, as CNIFEdit's is).
			var full := UiLayoutParser.ControlDef.new()
			full.name = c.name
			full.type = "CIFStatic"
			full.halign = _code_h(l.horizontal_alignment)
			full.valign = _code_v(l.vertical_alignment)
			return {"node": c, "kind": "static", "def": full, "rect": Rect2(Vector2.ZERO, parent.size),
				"name": "%s/%s" % [parent.name, c.name], "note": "over its control, own alignment"}
		return {}
	var e := c as LineEdit
	var er := _rect_of(e)
	var ed = _def_for(index, e.name, er.size)
	if ed != null and (ed.type == "CIFEdit" or ed.type == "CIFEInputChatBox"):
		return {"node": e, "kind": "edit", "def": ed, "rect": er, "name": String(e.name)}
	if parent != null and parent is LineEdit:
		var pr2 := _rect_of(parent)
		var pd2 = _def_for(index, parent.name, pr2.size)
		if pd2 != null:
			return {"node": e, "kind": "edit", "def": pd2, "rect": Rect2(Vector2.ZERO, pr2.size), "name": "%s/%s" % [parent.name, e.name]}
	return {}

static func _font(c: Control) -> Font:
	return c.get_theme_font(&"font")

static func _font_size(c: Control) -> int:
	return c.get_theme_font_size(&"font_size")

static func _shown_text(c: Control) -> String:
	if c is LineEdit:
		var e := c as LineEdit
		if e.secret and e.text != "":
			return (e.secret_character if e.secret_character != "" else "*").left(1).repeat(e.text.length())
		return e.text
	return (c as Label).text

static func _width(font: Font, fs: int, s: String) -> float:
	var line := TextLine.new()
	line.add_string(s, font, fs)
	return line.get_size().x

## The original's origin for an item (UI px, in the node's parent's space),
## truncated as the original truncates the screen coordinate (the windows
## sit at whole pixels).
static func expected_origin(item: Dictionary) -> Vector2:
	var c: Control = item["node"]
	var d = item["def"]
	var font := _font(c)
	var fs := _font_size(c)
	var s := _shown_text(c)
	var tw := _width(font, fs, s)
	var fh := font.get_height(fs)
	var o: Vector2
	var ha: int = item.get("halign", d.halign)
	var va: int = item.get("valign", d.valign)
	if item["kind"] == "edit":
		o = TextLayout.edit_origin(item["rect"], d.client_rect, ha, va, Vector2(tw, fh), fh)
		var tr := TextLayout.text_rect(item["rect"], d.client_rect)
		var col := (c as LineEdit).caret_column
		o.x = TextLayout.edit_scrolled_left(o.x, tr, tw, _width(font, fs, s.left(col)))
	else:
		o = TextLayout.static_origin(item["rect"], d.client_rect, ha, va, Vector2(tw, fh))
	return o.floor()

## Draws a string at a point of its parent's space (the reference ink).
class RefText extends Control:
	var font: Font
	var font_size := 12
	var text := ""
	var at := Vector2.ZERO
	var colour := Color.WHITE
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		set_meta(UiBuilder.TEXT_NODE_META, true)
	func _draw() -> void:
		if font != null:
			draw_string(font, at + Vector2(0, font.get_ascent(font_size)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)

static func _text_colour(c: Control) -> Color:
	if c is CifEdit:
		return (c as CifEdit).colour()
	return c.get_theme_color(&"font_color")

static func _hide_text(c: Control, saved: Dictionary) -> void:
	if c is Label:
		saved[c] = c.self_modulate
		c.self_modulate = Color(1, 1, 1, 0)
	else:
		var keep := {}
		for k in [&"font_color", &"font_uneditable_color", &"font_placeholder_color"]:
			keep[k] = c.get_theme_color(k) if c.has_theme_color_override(k) else null
			c.add_theme_color_override(k, Color(0, 0, 0, 0))
		saved[c] = keep

static func _show_text(c: Control, saved: Dictionary) -> void:
	if not saved.has(c):
		return
	if c is Label:
		c.self_modulate = saved[c]
	else:
		var keep: Dictionary = saved[c]
		for k in keep:
			if keep[k] == null:
				c.remove_theme_color_override(k)
			else:
				c.add_theme_color_override(k, keep[k])
	saved.erase(c)

static func _quiet_carets(n: Node, saved: Dictionary) -> void:
	if n is LineEdit:
		var e := n as LineEdit
		if "caret_probe" in e:
			saved[e] = "own"
			e.set_process(false)
			e.set("_blink_on", false)
			e.queue_redraw()
		else:
			saved[e] = e.get_theme_color(&"caret_color") if e.has_theme_color_override(&"caret_color") else null
			e.add_theme_color_override(&"caret_color", Color(0, 0, 0, 0))
	for ch in n.get_children():
		_quiet_carets(ch, saved)

static func _restore_carets(saved: Dictionary) -> void:
	for e in saved:
		if not is_instance_valid(e):
			continue
		var v = saved[e]
		if v is String and v == "own":
			(e as LineEdit).set_process((e as LineEdit).has_focus())
		elif v == null:
			(e as LineEdit).remove_theme_color_override(&"caret_color")
		else:
			(e as LineEdit).add_theme_color_override(&"caret_color", v)

static func _frame(tree: SceneTree, vp: Viewport) -> Image:
	await tree.process_frame
	await tree.process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()

## Pixels that differ between `a` and `b` inside `box` (physical px): their
## bounding box, or an empty Rect2i.
static func _diff_box(a: Image, b: Image, box: Rect2i) -> Rect2i:
	var bi := box.intersection(Rect2i(Vector2i.ZERO, a.get_size()))
	var x0 := 1 << 30
	var y0 := 1 << 30
	var x1 := -1
	var y1 := -1
	for y in range(bi.position.y, bi.end.y):
		for x in range(bi.position.x, bi.end.x):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			if absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b) > 0.02:
				x0 = mini(x0, x)
				y0 = mini(y0, y)
				x1 = maxi(x1, x)
				y1 = maxi(y1, y)
	if x1 < 0:
		return Rect2i()
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

## The canvas-to-image scale (the UI scale, measured from the frame).
static func _scale(vp: Viewport, img: Image) -> float:
	var vis := vp.get_visible_rect().size
	return float(img.get_width()) / vis.x if vis.x > 0 else 1.0

static func _global_box(parent: Control, r: Rect2, s: float) -> Rect2i:
	var g := parent.get_global_transform_with_canvas()
	var p0 := g * r.position
	var p1 := g * r.end
	var gr := Rect2(p0, p1 - p0).abs().grow(SEARCH)
	return Rect2i(Vector2i((gr.position * s).floor()), Vector2i((gr.size * s).ceil()))

## Measures `window`; returns {"n", "off", "worst", "items": [...]}.
## `sample` fills an empty edit with SAMPLE for the measure (restored after).
static func measure(window: Control, label: String, index: Dictionary, sample := true) -> Dictionary:
	var tree := window.get_tree()
	var vp := window.get_viewport()
	var got := collect(window, index)
	var items: Array = got[0]
	var norule: Array = got[1]
	var restore := {}
	for it in items:
		var c: Control = it["node"]
		if c is LineEdit and sample and (c as LineEdit).text == "":
			restore[c] = (c as LineEdit).caret_column
			(c as LineEdit).text = SAMPLE
			(c as LineEdit).caret_column = SAMPLE.length()
	# No caret blinks while the texts are measured (a blink between two
	# frames would be counted as ink): every edit's caret is held off.
	var quiet := {}
	_quiet_carets(window, quiet)
	var base := await _frame(tree, vp)
	var s := _scale(vp, base)
	# Groups whose search boxes do not touch: hidden together in one frame.
	var groups: Array = []
	for it in items:
		var c: Control = it["node"]
		var parent := c.get_parent() as Control
		var exp := expected_origin(it)
		it["expected"] = exp
		var box := _global_box(parent, (it["rect"] as Rect2).merge(Rect2(exp, Vector2(1, 1))), s)
		it["box"] = box
		var placed := false
		for g in groups:
			var clash := false
			for other in g:
				if (other["box"] as Rect2i).intersects(box):
					clash = true
					break
			if not clash:
				g.append(it)
				placed = true
				break
		if not placed:
			groups.append([it])
	var results: Array = []
	var off := 0
	var worst := 0.0
	for g in groups:
		var saved := {}
		var refs: Array = []
		for it in g:
			var c: Control = it["node"]
			_hide_text(c, saved)
		var hidden := await _frame(tree, vp)
		for it in g:
			var c: Control = it["node"]
			var ref := RefText.new()
			ref.font = _font(c)
			ref.font_size = _font_size(c)
			ref.text = _shown_text(c)
			ref.at = it["expected"]
			ref.colour = Color(_text_colour(c), 1.0)
			var parent := c.get_parent() as Control
			if it["kind"] == "edit":
				# Round 860: an edit's text is cut at the edit's own rect (the
				# viewport CIFEdit's draw sets, READ 0x6531a0), so the
				# reference is too -- a long text's ends are measured where
				# both are drawn.
				var er: Rect2 = it["rect"]
				var holder := Control.new()
				holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
				holder.clip_contents = true
				holder.position = er.position
				holder.size = er.size
				parent.add_child(holder)
				ref.at = ref.at - er.position
				holder.add_child(ref)
				ref.size = er.size
				refs.append(holder)
			else:
				parent.add_child(ref)
				ref.size = parent.size
				refs.append(ref)
		var with_ref := await _frame(tree, vp)
		for ref in refs:
			(ref as Node).get_parent().remove_child(ref)
			(ref as Node).queue_free()
		for it in g:
			_show_text(it["node"], saved)
		for it in g:
			var ours := _diff_box(base, hidden, it["box"])
			var want := _diff_box(with_ref, hidden, it["box"])
			var r := {"name": it["name"], "kind": it["kind"], "text": _shown_text(it["node"])}
			var d = it["def"]
			r["rule"] = "rect %s cr %s h%d v%d%s" % [str(it["rect"]), str(d.client_rect), d.halign, d.valign,
				(" (%s)" % it["note"]) if it.has("note") else ""]
			if ours.size.x == 0 or want.size.x == 0:
				r["status"] = "noink"
			else:
				r["dx"] = (ours.position.x - want.position.x) / s
				r["dy"] = (ours.position.y - want.position.y) / s
				r["dr"] = (ours.end.x - want.end.x) / s
				r["status"] = "ok"
				var m := maxf(absf(r["dx"]), maxf(absf(r["dy"]), absf(r["dr"])))
				if m >= 0.999:
					off += 1
				worst = maxf(worst, m)
			results.append(r)
			if r["status"] == "ok":
				print("TEXT %s %s %s dx %+.1f dy %+.1f dr %+.1f '%s' :: %s" % [label, r["name"], r["kind"], r["dx"], r["dy"], r["dr"], r["text"], r["rule"]])
			else:
				print("TEXT %s %s %s noink '%s' :: %s" % [label, r["name"], r["kind"], r["text"], r["rule"]])
	# Carets (still held off but for the one measured).
	for it in items:
		if it["kind"] != "edit":
			continue
		var cr := await measure_caret(it, tree, vp, s)
		if not cr.is_empty():
			print("CARET %s %s dx %+.1f dy %+.1f dw %+.1f dh %+.1f col %d :: ours %s want %s" % [label, it["name"],
				cr["dx"], cr["dy"], cr["dw"], cr["dh"], cr["col"], str(cr["ours"]), str(cr["want"])])
			results.append({"name": it["name"], "kind": "caret", "status": "ok", "dx": cr["dx"], "dy": cr["dy"],
				"dw": cr["dw"], "dh": cr["dh"]})
		else:
			print("CARET %s %s noink" % [label, it["name"]])
	_restore_carets(quiet)
	for c in restore:
		if is_instance_valid(c):
			(c as LineEdit).text = ""
			(c as LineEdit).caret_column = 0
	for n in norule:
		print("NORULE %s %s %s '%s'" % [label, (n as Node).get_path(), (n as Node).get_class(),
			str(n.get("text")).substr(0, 30)])
	print("TEXTSUM %s items %d off %d worst %.1f norule %d scale %.2f" % [label, results.size(), off, worst, norule.size(), s])
	return {"n": results.size(), "off": off, "worst": worst, "items": results, "norule": norule.size()}

## The caret of an edit item: the frame with the caret against one without,
## against TextLayout.caret_rect at the original's origin. Works on an edit
## that draws its own caret (CifEdit.caret_probe) and on one that draws
## Godot's (focused, forced on, then made transparent).
static func measure_caret(it: Dictionary, tree: SceneTree, vp: Viewport, s: float) -> Dictionary:
	var e: LineEdit = it["node"]
	var own := "caret_probe" in e
	var had_focus := e.has_focus()
	if own:
		e.set("caret_probe", true)
		e.queue_redraw()
	else:
		e.grab_focus()
		if e.has_method("edit"):
			e.call("edit")
		e.caret_force_displayed = true
		e.caret_blink = false
		e.add_theme_color_override(&"caret_color", Color(_text_colour(e), 1.0))
	var on := await _frame(tree, vp)
	if own:
		e.set("caret_probe", false)
		e.set("_blink_on", false)
		e.queue_redraw()
	else:
		e.add_theme_color_override(&"caret_color", Color(0, 0, 0, 0))
	var off := await _frame(tree, vp)
	if not own:
		# The colour itself comes back with the other carets (_restore_carets).
		e.caret_force_displayed = false
		e.caret_blink = true
		if not had_focus:
			e.release_focus()
	var box: Rect2i = it["box"]
	var ours := _diff_box(on, off, box)
	if ours.size.x == 0:
		return {}
	var font := _font(e)
	var fs := _font_size(e)
	var shown := _shown_text(e)
	var origin: Vector2 = it["expected"]
	var want := TextLayout.caret_rect(origin, _width(font, fs, shown.left(e.caret_column)), font.get_height(fs))
	var parent := e.get_parent() as Control
	var g := parent.get_global_transform_with_canvas()
	var wp := g * want.position
	var oursf := Rect2(Vector2(ours.position) / s, Vector2(ours.size) / s)
	return {"dx": oursf.position.x - wp.x, "dy": oursf.position.y - wp.y, "dw": oursf.size.x - want.size.x,
		"dh": oursf.size.y - want.size.y, "col": e.caret_column, "ours": oursf, "want": Rect2(wp, want.size)}
