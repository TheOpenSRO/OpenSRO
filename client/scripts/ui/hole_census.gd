extends RefCounted
class_name HoleCensus

## Round 858: where a window lets what is behind it show through. A flat
## ground is put directly behind the window (its sibling, just before it), the
## frame is taken twice -- once over magenta, once over green -- and inside the
## window's drawn area the pixels that differ between the two are the ones the
## ground reaches: "full" where nothing is drawn, "part" where it is drawn
## translucent. Each hole is grouped into connected pieces, and each piece says
## what is drawn over its first pixel: UNCOVERED (no picture at all -- a
## missing piece) or the topmost picture with its texel's alpha (the art's own
## transparency, which the original draws the same way: c:0x655ca0 sets the
## stage's alpha to texture alpha x the window's, READ).
##
## The drawn area: a HudWindow's own rect, joined with the rect of every
## visible control in it that draws a picture or a fill (TextureRect,
## TextureButton, NinePatchRect, ColorRect, Panel) and of every 8-/6-slice
## frame UiBuilder built (its inside is the window's though the frame draws
## nothing there). Text does not count.
##
## Used by tools/window_hole_census.gd (every HUD window) and, through
## qa_hook, by the front-end scenes and World3D in a real client run:
##   OPENSRO_QA_HOLES=LoginWindow,ServerListWindow   node names to measure
##   OPENSRO_QA_HOLES_AT=10                           seconds after the scene's _ready
##   OPENSRO_QA_HOLES_OUT=/var/tmp/x                  the magenta frames, for a human
## Prints `HOLES <name> full <n> part <n> area <n>` and `PIECE` lines.
## Needs a real renderer (the frame is read back).

const GROUND_A := Color(1, 0, 1)
const GROUND_B := Color(0, 1, 0)
const TOL := 3.0 / 255.0

## Measures `window`; returns {"full", "part", "area", "pieces": [...]} and
## prints the lines. `names` maps a Texture2D to its archive name for the
## PIECE lines (optional).
static func measure(window: Control, label: String, out_dir: String = "", min_piece: int = 4,
		names: Dictionary = {}) -> Dictionary:
	var tree := window.get_tree()
	var vp := window.get_viewport()
	var view := Vector2i(vp.get_visible_rect().size)
	var ground := ColorRect.new()
	ground.name = "HoleCensusGround"
	ground.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var parent := window.get_parent()
	var inv := Transform2D.IDENTITY
	if parent is CanvasItem:
		inv = (parent as CanvasItem).get_global_transform().affine_inverse()
	ground.position = inv * Vector2.ZERO
	ground.size = inv * Vector2(view) - ground.position
	ground.color = GROUND_A
	parent.add_child(ground)
	parent.move_child(ground, window.get_index())
	await tree.process_frame
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var a := vp.get_texture().get_image()
	ground.color = GROUND_B
	await tree.process_frame
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var b := vp.get_texture().get_image()
	parent.remove_child(ground)
	ground.queue_free()
	if out_dir != "":
		DirAccess.make_dir_recursive_absolute(out_dir)
		a.save_png("%s/%s.png" % [out_dir, label])
	return count(window, label, a, b, view, min_piece, names)

## The counting half of measure, on two frames already taken.
static func count(window: Control, label: String, a: Image, b: Image, view: Vector2i,
		min_piece: int = 4, names: Dictionary = {}) -> Dictionary:
	var pictures: Array = []
	_pictures(window, pictures, Rect2(Vector2.ZERO, Vector2(view)))
	var area := Rect2(window.get_global_rect()) if window is HudWindow else Rect2()
	var inside := Image.create(view.x, view.y, false, Image.FORMAT_L8)
	if area.size.x > 0:
		_fill(inside, area, view)
	elif not pictures.is_empty():
		area = pictures[0][0]
	var box := area
	for p in pictures:
		_fill(inside, p[0], view)
		box = box.merge(p[0])
	var bi := Rect2i(box.abs()).intersection(Rect2i(Vector2i.ZERO, view))
	var full := 0
	var part := 0
	var counted := 0
	var holes := PackedByteArray()
	holes.resize(view.x * view.y)
	for y in range(bi.position.y, bi.end.y):
		for x in range(bi.position.x, bi.end.x):
			if inside.get_pixel(x, y).r < 0.5:
				continue
			counted += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if _close(ca, cb):
				continue
			if _close(ca, GROUND_A) and _close(cb, GROUND_B):
				full += 1
				holes[y * view.x + x] = 2
			else:
				part += 1
				holes[y * view.x + x] = 1
	print("HOLES %s full %d part %d area %d rect %s" % [label, full, part, counted, str(area)])
	var pieces := _pieces(holes, view)
	var out: Array = []
	for piece in pieces:
		if int(piece["n"]) < min_piece:
			continue
		var first: Vector2 = piece["first"]
		piece["cover"] = _cover(pictures, first + Vector2(0.5, 0.5), window, names)
		out.append(piece)
		print("PIECE %s %s n %d full %d at %s :: %s" % [label, str(piece["box"]), piece["n"], piece["full"],
			str(first - window.get_global_position()), piece["cover"]])
	return {"full": full, "part": part, "area": counted, "pieces": out}

static func _close(p: Color, q: Color) -> bool:
	return absf(p.r - q.r) <= TOL and absf(p.g - q.g) <= TOL and absf(p.b - q.b) <= TOL

static func _fill(img: Image, r: Rect2, view: Vector2i) -> void:
	var c := Rect2i(r.abs()).intersection(Rect2i(Vector2i.ZERO, view))
	if c.size.x > 0 and c.size.y > 0:
		img.fill_rect(c, Color.WHITE)

## Connected pieces (4-neighbour) of the hole mask: box, size, full count and
## the first pixel.
static func _pieces(holes: PackedByteArray, view: Vector2i) -> Array:
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
		var lo := Vector2i(view.x, view.y)
		var hi := Vector2i(-1, -1)
		while not stack.is_empty():
			var k: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			n += 1
			if holes[k] == 2:
				nfull += 1
			var x := k % view.x
			var y := k / view.x
			lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
			hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
			for d in [-1, 1, -view.x, view.x]:
				var m: int = k + int(d)
				if m < 0 or m >= holes.size():
					continue
				if (d == -1 and x == 0) or (d == 1 and x == view.x - 1):
					continue
				if holes[m] != 0 and seen[m] == 0:
					seen[m] = 1
					stack.append(m)
		out.append({"n": n, "full": nfull, "box": Rect2i(lo, hi - lo + Vector2i.ONE),
			"first": Vector2(i % view.x, i / view.x)})
	return out

## Every visible control under `node` that draws a picture or a fill, or is a
## built frame, in draw order: [global rect, control].
static func _pictures(node: Node, out: Array, clip: Rect2) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Control:
		var c := node as Control
		var r := c.get_global_rect().abs().intersection(clip)
		if r.size.x >= 1.0 and r.size.y >= 1.0 and (is_picture(c) or is_frame(c)):
			out.append([r, c])
		if c.clip_contents:
			clip = clip.intersection(c.get_global_rect().abs())
	for child in node.get_children():
		_pictures(child, out, clip)

## A frame UiBuilder built from an 8- or 6-slice base: a bare Control whose
## picture children run around its whole rect.
static func is_frame(c: Control) -> bool:
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

static func is_picture(c: Control) -> bool:
	if c is TextureRect:
		return (c as TextureRect).texture != null
	if c is TextureButton:
		return (c as TextureButton).texture_normal != null
	if c is NinePatchRect:
		return (c as NinePatchRect).texture != null
	return c is ColorRect or c is Panel

## What is drawn at `p`: the topmost picture, its texel alpha, and how many
## pictures lie under the point.
static func _cover(pictures: Array, p: Vector2, window: Control, names: Dictionary) -> String:
	var hits: Array = []
	for pr in pictures:
		if (pr[0] as Rect2).has_point(p) and is_picture(pr[1]):
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
		desc += " %s alpha %s" % [names.get(tex, "?"), texel_alpha(top, tex, p)]
	elif top is ColorRect:
		desc += " colour %s" % str((top as ColorRect).color)
	return "%s (%d under)" % [desc, hits.size()]

## The texture's alpha at screen point p as the control maps it (scale, tile
## or keep), or "?".
static func texel_alpha(c: Control, tex: Texture2D, p: Vector2) -> String:
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
	if uv.x < 0 or uv.y < 0 or uv.x >= ts.x or uv.y >= ts.y:
		return "outside-art"
	return "%.2f" % img.get_pixelv(Vector2i(int(uv.x), int(uv.y))).a

## The QA hook (see the header): measures the named nodes of `scene` once,
## OPENSRO_QA_HOLES_AT seconds after this is called. Does nothing unset.
static func qa_hook(scene: Node) -> void:
	var wanted := OS.get_environment("OPENSRO_QA_HOLES")
	if wanted == "" or scene == null:
		return
	var at := float(OS.get_environment("OPENSRO_QA_HOLES_AT")) if OS.get_environment("OPENSRO_QA_HOLES_AT") != "" else 10.0
	var out := OS.get_environment("OPENSRO_QA_HOLES_OUT")
	await scene.get_tree().create_timer(at).timeout
	if not is_instance_valid(scene):
		return
	for n in wanted.split(",", false):
		var node := scene.find_child(n.strip_edges(), true, false) as Control
		if node == null or not node.is_visible_in_tree():
			print("HOLES %s not shown in %s" % [n, scene.name])
			continue
		await measure(node, "%s_%s" % [scene.name, n.strip_edges()], out)
	print("HOLES QA DONE %s" % scene.name)
