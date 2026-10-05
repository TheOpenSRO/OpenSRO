extends SceneTree

## Measurement (round 734): the weapon and shield glow as this renderer draws
## it, against the arithmetic it was built from (docs/protocol/weapon_glow.md
## §2.2, ItemGlowTables). Three parts, every frame read back from the GPU:
##
## 1. **The stage maths and the pulse** (`QUAD` lines). A flat quad per glow
##    row of the real table, drawn with the real glow shader over 1x1
##    textures of known colour (item 0.2, option 0.3: nothing clamps before
##    stage 1), so every pixel should be ItemGlowTables.glow_colour at the
##    frame's pulse. The engine's TIME at a frame is not readable, so the run
##    finds the pulse's two ends in the frames (the frames nearest colour 1
##    and colour 2) and reports: the rendered colour there against the
##    expected one (in 0..255), and the frames between the ends (x 1000 /
##    fps: the period in ms).
## 2. **The scroll** (`SCROLL` lines). The same quad with the row's real
##    option texture and a black item: the pattern's shift between frames,
##    found by searching integer pixel offsets for the best match over a
##    window, as texture units a second against uv x 50.
## 3. **Real items** (`ITEM` lines). Each case is a body dressed through
##    CharacterAppearance (the code the game uses) with everything but the
##    weapon and shield hidden and the particles taken off: the mean colour
##    of the item's pixels (those not the background) per frame, at frame 0,
##    at the frame farthest from it, the frames between the two, and the
##    plain (+0) item's mean for comparison; `--png=<dir>` saves frame 0 and
##    the far frame of each. `--scenes` adds one picture per case of the
##    whole dressed body with its particles, every `--scene-every` frames.
##
## Run with a fixed frame rate so TIME advances 1/fps a frame:
##   tools/xwl_run.sh godot --rendering-method forward_plus --rendering-driver vulkan \
##     --fixed-fps 60 --path client --script res://tools/measure_equip_glow.gd -- \
##     --pk2dir=/opt/sro-files/client --frames=150 \
##     --cases='sword+9:1907:6=101+9;bow+10:1907:6=245+10' [--png=/var/tmp/r734/png] [--scenes]

const SIZE := 192
const BG := Color(0, 0, 0)
const ITEM_GREY := 0.2
const OPTION_GREY := 0.3

var _fps := 60
var _frames := 150
var _frame := 0
var _quads: Array = []      # {row, vp, series: Array[Color]}
var _scrolls: Array = []    # {row, vp, images: Array[Image]}
var _items: Array = []      # {label, vp, series: Array[Color], plain: Color, count: PackedInt32Array, images}
var _scenes: Array = []     # {label, vp}
var _png := ""
var _scene_every := 15
var _tables: ItemGlowTables
var _appearance: CharacterAppearance
var _data: Pk2Reader
var _pending: Array = []    # views to frame once their bodies are placed

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
		if a == flag:
			return "1"
	return ""

func _initialize() -> void:
	var dir := _arg("--pk2dir")
	_data = Pk2Reader.open(dir.path_join("Data.pk2"))
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	if _data == null or media == null:
		printerr("GLOW could not open Data.pk2 / Media.pk2 under --pk2dir")
		quit(2)
		return
	if _arg("--frames").is_valid_int():
		_frames = int(_arg("--frames"))
	_fps = Engine.physics_ticks_per_second
	var fixed := Engine.max_fps
	_png = _arg("--png")
	if _png != "":
		DirAccess.make_dir_recursive_absolute(_png)
	if _arg("--scene-every").is_valid_int():
		_scene_every = maxi(1, int(_arg("--scene-every")))
	_tables = ItemGlowTables.for_archive(media)
	_appearance = CharacterAppearance.from_archives(_data, media)
	_appearance.particles = particles
	print("GLOW renderer %s, adapter %s, fixed fps arg %s (max_fps %d), %d frames" % [RendererChoice.running(),
		RenderingServer.get_video_adapter_name(), str(OS.get_cmdline_args().has("--fixed-fps")), fixed, _frames])
	var fixed_fps := 60
	for i in OS.get_cmdline_args().size():
		if OS.get_cmdline_args()[i] == "--fixed-fps" and i + 1 < OS.get_cmdline_args().size():
			fixed_fps = int(OS.get_cmdline_args()[i + 1])
	_fps = fixed_fps
	# The object include undoes the world's tone map (ObjectLight); these
	# views tone-map linearly, so nothing is to be undone (w 0).
	RenderingServer.global_shader_parameter_set("srr_obj_tonemap", Vector4(1, 1, 0, 0))
	# The views are framed with global transforms, which need the tree live
	# and the bodies' attachments placed.
	await process_frame
	_build_quads()
	for spec in _arg("--cases").split(";", false):
		_build_case(spec)
	await process_frame
	await process_frame
	for p in _pending:
		_frame_view(p)
	RenderingServer.frame_post_draw.connect(_drawn)

func _viewport(size: int) -> SubViewport:
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.size = Vector2i(size, size)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	return vp

func _ortho(vp: SubViewport, at: Vector3, from: Vector3, size: float) -> void:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size
	cam.near = 0.01
	cam.far = 10000.0
	vp.add_child(cam)
	cam.look_at_from_position(from, at, Vector3.UP if absf(from.direction_to(at).y) < 0.9 else Vector3.FORWARD)
	cam.current = true

func _flat(c: float) -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(c, c, c, 1.0))
	return ImageTexture.create_from_image(img)

func _quad(vp: SubViewport, mat: Material) -> void:
	var q := MeshInstance3D.new()
	var m := QuadMesh.new()
	m.size = Vector2(1, 1)
	q.mesh = m
	q.material_override = mat
	vp.add_child(q)
	_ortho(vp, Vector3.ZERO, Vector3(0, 0, 5), 1.0)

## One quad per distinct (type, tier) of the real table: type 1's and type
## 3's rows (the alpha flag and the scroll direction are the only differences
## between 1/2 and 3/4).
func _build_quads() -> void:
	for ty in [1, 3]:
		for p in [3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]:
			var row := _row(ty, p)
			if row == null:
				continue
			var plain := ShaderMaterial.new()
			plain.shader = ObjectLoader.OBJECT_SHADER
			plain.set_shader_parameter("albedo_texture", _flat(ITEM_GREY))
			var g := EquipGlow.material_for(plain, row, _flat(OPTION_GREY))
			var vp := _viewport(8)
			_quad(vp, g)
			_quads.append({"row": row, "vp": vp, "series": []})
			# The scroll: the real option texture over a black item.
			var black := ShaderMaterial.new()
			black.shader = ObjectLoader.OBJECT_SHADER
			black.set_shader_parameter("albedo_texture", _flat(0.0))
			var opt := EquipGlow.option_texture(_data, row.texture)
			var s := EquipGlow.material_for(black, row, opt)
			var svp := _viewport(SIZE)
			_quad(svp, s)
			_scrolls.append({"row": row, "vp": svp, "images": []})

## The row of type `ty` at threshold `p` (the table's own, through a code
## name of that type).
func _row(ty: int, p: int) -> ItemGlowTables.GlowRow:
	for code in _tables._types:
		if int(_tables._types[code]) == ty:
			var r := _tables.glow_row(code, p)
			return r if r != null and r.plus == p else null
	return null

## "label:ref_obj_id:slot=id+plus,..." -> a weapon-only viewport (and a
## +0 twin for the plain colour), and with --scenes a whole-body one.
func _build_case(spec: String) -> void:
	var parts := spec.split(":")
	if parts.size() != 3 or not parts[1].is_valid_int():
		print("GLOW bad case '%s'" % spec)
		return
	var label := parts[0]
	var loadout := EquipGlow.parse_loadout(parts[2])
	var items: Array = []
	var plain_items: Array = []
	for slot in loadout[0]:
		items.append({"id": loadout[0][slot], "plus": int((loadout[1] as Dictionary).get(slot, 0))})
		plain_items.append({"id": loadout[0][slot], "plus": 0})
	var lit := _weapon_view(label, int(parts[1]), items)
	var plain := _weapon_view(label + "/plain", int(parts[1]), plain_items)
	if lit.is_empty():
		return
	lit["plain_vp"] = plain.get("vp")
	_items.append(lit)
	if _arg("--scenes") != "":
		var body := _appearance.build(int(parts[1]), CharacterAppearance.DEFAULT_SCALE, items)
		if body != null:
			var vp := _viewport(512)
			vp.add_child(body)
			_pending.append({"vp": vp, "body": body, "keep": [], "label": label, "scene": true})
			_scenes.append({"label": label, "vp": vp})

func _weapon_view(label: String, ref: int, items: Array) -> Dictionary:
	var body := _appearance.build(ref, CharacterAppearance.DEFAULT_SCALE, items)
	if body == null:
		print("GLOW %s: body %d did not build" % [label, ref])
		return {}
	EquipGlow.strip_particles(body)
	var keep: Array = []
	var desc := PackedStringArray()
	for w in body.worn:
		var slot := int(w["slot"])
		if slot == CharacterAppearance.SLOT_WEAPON or slot == CharacterAppearance.SLOT_SHIELD:
			keep.append_array(w["nodes"])
			desc.append("%s +%d row +%d" % [w.get("code", "?"), int(w["plus"]), int(w.get("glow", 0))])
	for mi in body.find_children("*", "MeshInstance3D", true, false):
		var under := false
		for k in keep:
			if k == mi or (k as Node).is_ancestor_of(mi):
				under = true
		(mi as MeshInstance3D).visible = under
	var vp := _viewport(SIZE)
	vp.add_child(body)
	_pending.append({"vp": vp, "body": body, "keep": keep, "label": label, "desc": ", ".join(desc), "scene": false})
	return {"label": label, "vp": vp, "series": [], "counts": [], "images": []}

func _frame_view(p: Dictionary) -> void:
	var box := _aabb_of(p["body"], p["keep"])
	var c := box.get_center()
	var vp: SubViewport = p["vp"]
	var label: String = p["label"]
	if p["scene"]:
		# The body from its front (-Z), a little above.
		var span := maxf(box.size.y, box.size.x)
		_ortho(vp, c, c + Vector3(0, span * 0.15, -span * 3.0), span * 1.15)
		return
	# Look along the box's thinnest axis, so a blade is seen flat.
	var axis := Vector3.FORWARD
	var s := box.size
	if s.x <= s.y and s.x <= s.z:
		axis = Vector3.RIGHT
	elif s.y <= s.x and s.y <= s.z:
		axis = Vector3.UP
	else:
		axis = Vector3.BACK
	var extent := maxf(maxf(s.x, s.y), s.z)
	_ortho(vp, c, c + axis * (extent * 3.0 + 10.0), extent * 1.1)
	print("GLOW case %s: %s, view along %s, box %s" % [label, p.get("desc", ""), str(axis), str(box)])

## The box around the bones of the skeletons under `keep` (an item's own,
## for an item: a skinned mesh's AABB is its bind-space one, not where the
## skeleton draws it), or under `body` when `keep` is empty; grown by a
## margin, at least `min_size` across.
func _aabb_of(body: Node, keep: Array, min_size: float = 6.0) -> AABB:
	var roots: Array = keep if not keep.is_empty() else [body]
	var pts := PackedVector3Array()
	for r in roots:
		var skels: Array = (r as Node).find_children("*", "Skeleton3D", true, false)
		if r is Skeleton3D:
			skels.append(r)
		for sk in skels:
			var s := sk as Skeleton3D
			for i in s.get_bone_count():
				pts.append(s.global_transform * s.get_bone_global_pose(i).origin)
	if pts.is_empty():
		return AABB(Vector3.ZERO, Vector3.ONE * min_size)
	var box := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		box = box.expand(p)
	var grow := maxf(box.get_longest_axis_size() * 0.15, 1.0)
	box = box.grow(grow)
	for ax in 3:
		if box.size[ax] < min_size:
			box.position[ax] -= (min_size - box.size[ax]) * 0.5
			box.size[ax] = min_size
	return box

## Mean colour (0..1) of the pixels not the background, and their count.
static func _mean(img: Image) -> Array:
	img.convert(Image.FORMAT_RGBA8)
	var d := img.get_data()
	var sum := Vector3.ZERO
	var n := 0
	for i in range(0, d.size(), 4):
		if d[i] > 3 or d[i + 1] > 3 or d[i + 2] > 3:
			sum += Vector3(d[i], d[i + 1], d[i + 2])
			n += 1
	return [sum / maxf(float(n), 1.0) / 255.0, n]

func _drawn() -> void:
	_frame += 1
	if _frame <= 3:
		return
	var k := _frame - 4
	if k >= _frames:
		return
	for q in _quads:
		var img := (q["vp"] as SubViewport).get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		(q["series"] as Array).append(img.get_pixel(4, 4))
	for s in _scrolls:
		if k % 6 == 0 and k <= 60:
			(s["images"] as Array).append((s["vp"] as SubViewport).get_texture().get_image())
	for it in _items:
		var img := (it["vp"] as SubViewport).get_texture().get_image()
		var m := _mean(img)
		(it["series"] as Array).append(m[0])
		(it["counts"] as Array).append(m[1])
		(it["images"] as Array).append(img if _png != "" else null)
		if k == 0 and it.get("plain_vp") != null:
			it["plain"] = _mean((it["plain_vp"] as SubViewport).get_texture().get_image())
	if _png != "" and k % _scene_every == 0:
		for sc in _scenes:
			(sc["vp"] as SubViewport).get_texture().get_image().save_png(_png.path_join("scene_%s_%03d.png" % [String(sc["label"]).replace("+", "p"), k]))
	if k == _frames - 1:
		_report()
		quit(0)

func _c255(v: Vector3) -> String:
	return "(%d, %d, %d)" % [roundi(v.x * 255.0), roundi(v.y * 255.0), roundi(v.z * 255.0)]

func _report() -> void:
	var worst := 0.0
	for q in _quads:
		var row: ItemGlowTables.GlowRow = q["row"]
		var series: Array = q["series"]
		var e1 := ItemGlowTables.glow_colour(Vector3.ONE * ITEM_GREY, Vector3.ONE * OPTION_GREY, ItemGlowTables.tfactor(row.color1, row.color2, 0.0), row.op0, row.op1)
		var e2 := ItemGlowTables.glow_colour(Vector3.ONE * ITEM_GREY, Vector3.ONE * OPTION_GREY, ItemGlowTables.tfactor(row.color1, row.color2, 1.0), row.op0, row.op1)
		var at1 := _nearest(series, e1)
		var at2 := _nearest(series, e2)
		var got1 := _v(series[at1])
		var got2 := _v(series[at2])
		var err := maxf(_maxdiff(got1, e1), _maxdiff(got2, e2)) * 255.0
		worst = maxf(worst, err)
		# The ends repeat every period: the frames between an end and the
		# next other end, all pairs averaged.
		var ends1 := _minima(series, e1)
		var ends2 := _minima(series, e2)
		var gaps := PackedInt32Array()
		for a in ends1:
			for b in ends2:
				if absi(a - b) < roundi(row.period_ms * _fps / 1000.0 * 1.5):
					gaps.append(absi(a - b))
		var gap_ms := -1.0
		if not gaps.is_empty():
			var t := 0
			for g in gaps:
				t += g
			gap_ms = float(t) / gaps.size() * 1000.0 / _fps
		print("QUAD type %d +%d: colour 1 end frame %d rendered %s expected %s; colour 2 end frame %d rendered %s expected %s; max error %.1f/255; ends %s / %s, end-to-end %.0f ms (period %d ms)" % [
			row.type_number, row.plus, at1, _c255(got1), _c255(e1), at2, _c255(got2), _c255(e2), err,
			str(ends1), str(ends2), gap_ms, row.period_ms])
	print("QUAD worst error %.1f/255 over %d rows" % [worst, _quads.size()])
	for s in _scrolls:
		var row: ItemGlowTables.GlowRow = s["row"]
		var imgs: Array = s["images"]
		var shifts: Array = []
		for i in range(imgs.size() - 1):
			shifts.append(_shift(imgs[i], imgs[i + 1], 12))
		var mean := Vector2.ZERO
		for v in shifts:
			mean += v
		mean /= maxf(float(shifts.size()), 1.0)
		# 6 frames between images; SIZE pixels = 1 texture unit (the quad
		# fills the view). The pattern moves opposite to the offset added to
		# the UV; image y grows downward as v does.
		var per_s := -mean / float(SIZE) * (float(_fps) / 6.0)
		print("SCROLL type %d +%d (%s): pattern shift per 6 frames %s px -> %.3f, %.3f units/s; expected uv x 50 = %s" % [
			row.type_number, row.plus, row.texture.get_file(), str(shifts), per_s.x, per_s.y, str(row.uv_per_second())])
	for it in _items:
		var series: Array = it["series"]
		if series.is_empty():
			continue
		var c0 := _v(series[0])
		var far := 0
		for i in series.size():
			if _maxdiff(_v(series[i]), c0) > _maxdiff(_v(series[far]), c0):
				far = i
		var plain: Array = it.get("plain", [Vector3.ZERO, 0])
		print("ITEM %s: %d px; frame 0 %s, farthest frame %d (%.0f ms) %s, change %s; plain +0 %s (%d px)" % [
			it["label"], int((it["counts"] as Array)[0]), _c255(c0), far, far * 1000.0 / _fps, _c255(_v(series[far])),
			_c255(_v(series[far]) - c0), _c255(plain[0]), int(plain[1])])
		var line := PackedStringArray()
		for i in range(0, series.size(), 10):
			line.append("%d:%s" % [i, _c255(_v(series[i]))])
		print("ITEM %s series (every 10 frames): %s" % [it["label"], " ".join(line)])
		if _png != "":
			var lab := String(it["label"]).replace("+", "p").replace("/", "_")
			(it["images"][0] as Image).save_png(_png.path_join("item_%s_f000.png" % lab))
			(it["images"][far] as Image).save_png(_png.path_join("item_%s_f%03d.png" % [lab, far]))
	print("GLOW done")

func _v(c) -> Vector3:
	if c is Color:
		return Vector3((c as Color).r, (c as Color).g, (c as Color).b)
	return c

func _maxdiff(a: Vector3, b: Vector3) -> float:
	var d := (a - b).abs()
	return maxf(maxf(d.x, d.y), d.z)

func _nearest(series: Array, e: Vector3) -> int:
	var best := 0
	for i in series.size():
		if _maxdiff(_v(series[i]), e) < _maxdiff(_v(series[best]), e):
			best = i
	return best

## The frames where the series comes nearest `e` locally (its ends).
func _minima(series: Array, e: Vector3) -> PackedInt32Array:
	var out := PackedInt32Array()
	var lim := 2.5 / 255.0
	for i in series.size():
		var d := _maxdiff(_v(series[i]), e)
		if d > lim:
			continue
		var a := _maxdiff(_v(series[i - 1]), e) if i > 0 else INF
		var b := _maxdiff(_v(series[i + 1]), e) if i + 1 < series.size() else INF
		if d <= a and d < b:
			out.append(i)
	return out

## The integer pixel shift (dx, dy) that best moves `a` onto `b`, searched
## within +-r over the middle of the image (sum of squared luma differences).
func _shift(a: Image, b: Image, r: int) -> Vector2:
	a.convert(Image.FORMAT_L8)
	b.convert(Image.FORMAT_L8)
	var w := a.get_width()
	var h := a.get_height()
	var da := a.get_data()
	var db := b.get_data()
	var best := Vector2i.ZERO
	var best_e := INF
	var es := {}
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var e := 0.0
			for y in range(r, h - r, 2):
				for x in range(r, w - r, 2):
					var d := float(da[y * w + x]) - float(db[(y + dy) * w + x + dx])
					e += d * d
			es[Vector2i(dx, dy)] = e
			if e < best_e:
				best_e = e
				best = Vector2i(dx, dy)
	# Sub-pixel: a parabola through the best and its two neighbours per axis.
	var out := Vector2(best)
	for ax in 2:
		var step := Vector2i(1, 0) if ax == 0 else Vector2i(0, 1)
		if es.has(best - step) and es.has(best + step):
			var em: float = es[best - step]
			var ep: float = es[best + step]
			var den := em - 2.0 * best_e + ep
			if den > 0.0:
				out[ax] += 0.5 * (em - ep) / den
	return out
