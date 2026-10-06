extends SceneTree

## Dev tool (round 683): CharacterAppearance and CharCatalog against the real
## archives. It measures, and optionally renders:
##
## - the catalogue's counts against charselect.md (52 Figures, 13 per race and
##   sex; 5 China and 9 Europe weapons; one shield per race; 3 armour sets per
##   race and sex; 104 ids);
## - every Figure built with a kit (OURS: the catalogue's sample_kit, rotating
##   through the race's weapons so every weapon model is drawn), checking the
##   body assembled and every kit item hung something;
## - the build time, cold (the first build of a body, which assembles it) and
##   warm (the same build again, from the templates);
## - Height: the head bone's height at Height 0/2/4 against Height 2;
## - Volume: the skinned vertices' girth (CPU skinning, the same sum the GPU
##   does) at Volume 0/2/4.
## A failed check prints `PARITY FAIL`, which remote_godot.sh turns into exit 1.
##
## Renders (with --out, needs a GL context: xvfb-run + vglrun, no --headless):
## the 52 Figures at Height 0/2/4 and Volume 0/4, and one body per race and sex
## at the three Heights and the three Volumes side by side.
##
##   godot4 --path client --rendering-driver opengl3 --resolution 1600x1200 \
##     --script res://tools/appearance_probe.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 \
##     [--out=/var/tmp/<lane>/shots]

var _fails := 0

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _expect(cond: bool, msg: String) -> void:
	if cond:
		print("ok   " + msg)
	else:
		print("PARITY FAIL " + msg)
		_fails += 1

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--out=<dir>]")
		quit(2)
		return
	var t0 := Time.get_ticks_usec()
	var app := CharacterAppearance.from_archives(data, media)
	print("from_archives: %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var cat := app.catalog()
	_check_catalog(cat)

	var bodies := _build_all(app, cat)
	_check_index_items(app)
	_measure_height(app, cat)
	_measure_volume(app, cat)

	if _arg("--showthrough") != "":
		await _measure_show_through(app, cat, _arg("--showthrough") == "all")
	if _arg("--closeup") != "":
		await _render_closeups(app, cat, _arg("--closeup"))
	var out := _arg("--out")
	if out != "" and _arg("--norender") == "":
		await _render_all(app, cat, out)
	for b in bodies:
		b.free()
	app.free_templates()
	print("RESULT: %s (%d failing)" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0)

# --- the catalogue -------------------------------------------------------------

func _check_catalog(cat: CharCatalog) -> void:
	var races := [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]
	var sexes := [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]
	var figures := 0
	for r in races:
		for s in sexes:
			var f := cat.figures(r, s)
			figures += f.size()
			_expect(f.size() == 13, "race %d sex %d: 13 Figures (got %d, ids %d..%d)" % [r, s, f.size(),
				f[0].id if not f.is_empty() else 0, f[-1].id if not f.is_empty() else 0])
			var sets := cat.all_armour_sets(r, s)
			_expect(sets.size() == 3, "race %d sex %d: 3 armour sets (got %s)" % [r, s, str(sets.map(func(x): return x.name))])
			for st in sets:
				_expect(not st.ids().has(0), "race %d sex %d set %s is whole: %s" % [r, s, st.name, str(st.ids())])
	_expect(figures == 52, "52 Figures (got %d)" % figures)
	var cw := cat.weapons(CharCatalog.RACE_CHINA)
	var ew := cat.weapons(CharCatalog.RACE_EUROPE)
	_expect(cw.size() == 5, "5 China weapons (got %s)" % str(cw.map(func(e): return e.id)))
	_expect(ew.size() == 9, "9 Europe weapons (got %s)" % str(ew.map(func(e): return e.id)))
	_expect(cat.shield(CharCatalog.RACE_CHINA) != null and cat.shield(CharCatalog.RACE_EUROPE) != null, "a shield per race")
	_expect(cat.size() == 104, "104 catalogue ids (got %d)" % cat.size())
	# The ids charselect.md section 4 lists (MEASURED there; the table, not a constant here).
	var ids := cat.all_ids()
	_expect(ids.has(1907) and ids.has(1932) and ids.has(14875) and ids.has(14900), "the Figure id ranges 1907-1932 / 14875-14900")
	_expect(cw.map(func(e): return e.id) == [3632, 3633, 3634, 3635, 3636], "China weapons are 3632-3636 in order")
	_expect(ew.map(func(e): return e.id) == [10887, 10888, 10889, 10890, 10891, 10892, 10893, 10894, 10895], "Europe weapons are 10887-10895 in order")
	var eu_sets := {}
	for w in ew:
		eu_sets[w.id] = cat.armour_sets(CharCatalog.RACE_EUROPE, CharCatalog.SEX_MAN, w.id).map(func(x): return x.name)
	print("Europe weapon -> sets: %s" % str(eu_sets))
	_expect(eu_sets[10887] == ["light"] and eu_sets[10888] == ["heavy", "light"] and eu_sets[10892] == ["robe"] \
		and eu_sets[10895] == ["light", "robe"], "Europe's weapon -> armour rule matches charselect.md's table")
	var sets_ch := cat.all_armour_sets(CharCatalog.RACE_CHINA, CharCatalog.SEX_MAN)
	_expect(sets_ch.size() == 3 and str(sets_ch[0].ids()) == str([3637, 3638, 3639]) and str(sets_ch[2].ids()) == str([3643, 3644, 3645]),
		"China man's sets: heavy 3637.. first, clothes 3643.. last")

# --- building every Figure -------------------------------------------------------

func _build_all(app: CharacterAppearance, cat: CharCatalog) -> Array:
	var out := []
	var cold := []
	var warm := []
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			var figs := cat.figures(r, s)
			var nweap := cat.weapons(r).size()
			for i in range(figs.size()):
				var kit := cat.sample_kit(r, s, i % maxi(nweap, 1))
				var b := app.build(figs[i].id, 0x22, kit)
				if b == null:
					_expect(false, "Figure %d (%s) builds" % [figs[i].id, figs[i].code])
					continue
				cold.append(app.last_build_usec)
				var b2 := app.build(figs[i].id, 0x22, kit)
				warm.append(app.last_build_usec)
				b2.free()
				var hung := 0
				var models := 0
				for w in b.worn:
					models += (w["models"] as PackedStringArray).size()
					hung += (w["nodes"] as Array).size()
				_expect(b.assembled != null and b.assembled.skinned_pieces > 0 and hung == models and b.worn.size() == kit.size(),
					"%-26s %5d  pieces %d  worn %d/%d items, %d/%d models  group %s  woman %s" % [figs[i].code, figs[i].id,
					b.assembled.skinned_pieces if b.assembled != null else 0, b.worn.size(), kit.size(), hung, models,
					b.weapon_group, str(b.is_woman)])
				out.append(b)
				# Round 687: the body's attachable block names the nine piece
				# keys charselect.md section 9 lists (MEASURED by the research
				# across all Figures), and every kit item has a block.
				var blk: BsrReader.Attachable = b.assembled.parsed.attachable if b.assembled != null and b.assembled.parsed != null else null
				var body_keys := []
				if blk != null:
					body_keys = Array(blk.keys())
					body_keys.sort()
				var blocks := 0
				var drawn_models := 0
				for w in b.worn:
					drawn_models += (w["drawn"] as PackedStringArray).size()
					for a in w.get("attachables", []):
						if a != null:
							blocks += 1
				_expect(body_keys == [0, 1, 2, 3, 5, 6, 11, 12, 13] and blocks == drawn_models,
					"%-26s body keys %s, %d/%d worn models with a block, %d body meshes hidden" % [figs[i].code,
					str(body_keys), blocks, drawn_models, b.hidden_body_meshes])
	cold.sort()
	warm.sort()
	if not cold.is_empty():
		print("build time, cold (assembles the body): median %.1f ms, max %.1f ms over %d" % [
			cold[cold.size() / 2] / 1000.0, cold[-1] / 1000.0, cold.size()])
		print("build time, warm (from templates):     median %.1f ms, max %.1f ms over %d" % [
			warm[warm.size() / 2] / 1000.0, warm[-1] / 1000.0, warm.size()])
		print("assemblies: %d bodies, %d items; %d builds" % [app.stats["body_assemblies"], app.stats["item_assemblies"], app.stats["builds"]])
	return out

# --- Height ----------------------------------------------------------------------

## The head bone's world height, in the built node's frame (the body at the origin).
func _head_height(b: CharacterAppearance.Body) -> float:
	b.skeleton.force_update_all_bone_transforms()
	var head := b.skeleton.find_bone("Bip01 Head")
	if head == -1:
		return 0.0
	return (b.transform * b.skeleton.get_bone_global_pose(head).origin).y

func _measure_height(app: CharacterAppearance, cat: CharCatalog) -> void:
	var worst := 0.0
	var rows := []
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			for f in cat.figures(r, s):
				var h := []
				for scale in [0x20, 0x22, 0x24]:
					var b := app.build(f.id, scale, [])
					h.append(_head_height(b))
					b.free()
				var lo: float = h[0] / h[1]
				var hi: float = h[2] / h[1]
				worst = maxf(worst, maxf(absf(lo - 0.94), absf(hi - 1.06)))
				rows.append("%-26s head %.2f / %.2f / %.2f  ratio %.4f %.4f" % [f.code, h[0], h[1], h[2], lo, hi])
	for line in rows:
		print("height " + line)
	_expect(worst < 1e-4, "every Figure's head height scales by 0.94 / 1.06 at Height 0 / 4 (worst error %.6f)" % worst)

# --- Volume ----------------------------------------------------------------------

## Every vertex skinned to the body skeleton, posed as the GPU would pose it
## (sum over its influences of weight x bone pose x bind x vertex), in the
## skeleton's frame.
func _skinned_points(skel: Skeleton3D) -> PackedVector3Array:
	var pts := PackedVector3Array()
	skel.force_update_all_bone_transforms()
	for mi in CharacterAppearance._skinned_to(skel):
		if String(mi.name).ends_with("_front"):
			continue
		var skin: Skin = mi.skin
		var xf: Array[Transform3D] = []
		for i in range(skin.get_bind_count()):
			xf.append(skel.get_bone_global_pose(skin.get_bind_bone(i)) * skin.get_bind_pose(i))
		var mesh: Mesh = mi.mesh
		for sidx in range(mesh.get_surface_count()):
			var arr := mesh.surface_get_arrays(sidx)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			if bones == null or weights == null or v.is_empty():
				continue
			var per := int(bones.size() / v.size())
			for k in range(v.size()):
				var p := Vector3.ZERO
				var wsum := 0.0
				for j in range(per):
					var w: float = weights[k * per + j]
					if w <= 0.0:
						continue
					var bi: int = bones[k * per + j]
					if bi < xf.size():
						p += (xf[bi] * v[k]) * w
						wsum += w
				if wsum > 0.0:
					pts.append(p / wsum)
	return pts

## {height, width, depth} of the points, and the depth of the band at
## [lo, hi] of the height (the torso at 0.55-0.75, the thighs at 0.30-0.45).
func _girth(pts: PackedVector3Array) -> Dictionary:
	var box := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		box = box.expand(p)
	var out := {"height": box.size.y, "width": box.size.x, "depth": box.size.z}
	for band in [["torso", 0.55, 0.75], ["thighs", 0.30, 0.45]]:
		var y0: float = box.position.y + box.size.y * float(band[1])
		var y1: float = box.position.y + box.size.y * float(band[2])
		var zmin := INF
		var zmax := -INF
		for p in pts:
			if p.y >= y0 and p.y <= y1:
				zmin = minf(zmin, p.z)
				zmax = maxf(zmax, p.z)
		out[band[0]] = zmax - zmin
	return out

func _measure_volume(app: CharacterAppearance, cat: CharCatalog) -> void:
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			var f: CharCatalog.Entry = cat.figures(r, s)[0]
			var g := []
			for scale in [0x02, 0x22, 0x42]:
				var b := app.build(f.id, scale, [])
				g.append(_girth(_skinned_points(b.skeleton)))
				b.free()
			print("volume %-24s height %.2f/%.2f/%.2f  width %.2f/%.2f/%.2f  depth %.2f/%.2f/%.2f  torso depth %.2f/%.2f/%.2f  thigh depth %.2f/%.2f/%.2f" % [
				f.code, g[0]["height"], g[1]["height"], g[2]["height"], g[0]["width"], g[1]["width"], g[2]["width"],
				g[0]["depth"], g[1]["depth"], g[2]["depth"], g[0]["torso"], g[1]["torso"], g[2]["torso"],
				g[0]["thighs"], g[1]["thighs"], g[2]["thighs"]])
			_expect(g[0]["torso"] < g[1]["torso"] and g[1]["torso"] < g[2]["torso"], "%s: the torso deepens with Volume" % f.code)
			_expect(absf(g[2]["height"] / g[1]["height"] - 1.0) < 0.01 and absf(g[0]["height"] / g[1]["height"] - 1.0) < 0.01,
				"%s: Volume leaves the height within 1%%" % f.code)

# --- renders -----------------------------------------------------------------------

func _render_all(app: CharacterAppearance, cat: CharCatalog, out: String) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var world := Node3D.new()
	get_root().add_child(world)
	_lights(world)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.current = true
	world.add_child(cam)
	for variant in [["lineup_h0", 0x20], ["lineup_h2", 0x22], ["lineup_h4", 0x24], ["lineup_v0", 0x02], ["lineup_v4", 0x42]]:
		var holder := Node3D.new()
		world.add_child(holder)
		var row := 0
		for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
			for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
				var figs := cat.figures(r, s)
				var nweap := cat.weapons(r).size()
				for i in range(figs.size()):
					var b := app.build(figs[i].id, int(variant[1]), cat.sample_kit(r, s, i % maxi(nweap, 1)))
					if b == null:
						continue
					_stand(app, b)
					b.position = Vector3(i * 12.0, -row * 26.0, 0.0)
					holder.add_child(b)
				row += 1
		# 13 across at 12 apart (156 wide) needs an ortho height of 120 at 4:3.
		_frame(cam, Vector3(6.0 * 12.0, -1.5 * 26.0 + 10.0, 0.0), 120.0)
		await _shoot(out.path_join(variant[0] + ".png"))
		holder.free()
	for variant in [["compare_height", [0x20, 0x22, 0x24]], ["compare_volume", [0x02, 0x22, 0x42]]]:
		var holder := Node3D.new()
		world.add_child(holder)
		# A 2 x 2 grid: China above Europe, men left of women, each group the
		# three values left to right.
		var group := 0
		for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
			for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
				var f: CharCatalog.Entry = cat.figures(r, s)[0]
				var k := 0
				for scale in variant[1]:
					var b := app.build(f.id, int(scale), cat.sample_kit(r, s, 0))
					_stand(app, b)
					b.position = Vector3((group % 2) * 40.0 + k * 11.0, -(group / 2) * 26.0, 0.0)
					holder.add_child(b)
					k += 1
				group += 1
		_frame(cam, Vector3(31.0, -3.5, 0.0), 60.0)
		await _shoot(out.path_join(variant[0] + ".png"))
		holder.free()
	world.free()

## Round 687's pictures for a human (not evidence; the show-through counts
## are): the first China woman and the first Europe man in their light set,
## textured, front and back, with every body piece drawn ("before") and with
## the worn items' hides ("after"), side by side in one frame per view.
func _render_closeups(app: CharacterAppearance, cat: CharCatalog, out: String) -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var world := Node3D.new()
	get_root().add_child(world)
	_lights(world)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.current = true
	world.add_child(cam)
	for who in [[CharCatalog.RACE_CHINA, CharCatalog.SEX_WOMAN, "china_woman"], [CharCatalog.RACE_EUROPE, CharCatalog.SEX_MAN, "europe_man"]]:
		var f: CharCatalog.Entry = cat.figures(who[0], who[1])[0]
		var armour := []
		for st in cat.all_armour_sets(who[0], who[1]):
			if st.name == "light":
				for id in st.ids():
					armour.append({"id": id, "plus": 0})
		var before := app.build(f.id, 0x22, armour)
		var after := app.build(f.id, 0x22, armour)
		for mi in before.skeleton.get_children():
			if mi.has_meta(SkinnedBsrAssembler.BODY_MESH_META):
				(mi as Node3D).visible = true
		for pair in [[before, -5.5], [after, 5.5]]:
			var b: CharacterAppearance.Body = pair[0]
			_stand(app, b)
			b.position = Vector3(float(pair[1]), 0, 0)
			world.add_child(b)
		print("closeup %s %s (%d): after hides %d body meshes" % [who[2], f.code, f.id, after.hidden_body_meshes])
		for view in [["front", PI], ["back", 0.0]]:
			before.rotation.y = view[1]
			after.rotation.y = view[1]
			_frame(cam, Vector3(0, 10.0, 0), 13.0)
			await _shoot(out.path_join("%s_light_%s_before_left_after_right.png" % [who[2], view[0]]))
		before.free()
		after.free()
	world.free()

func _stand(app: CharacterAppearance, b: CharacterAppearance.Body) -> void:
	if _arg("--bind") == "":
		var idle := app.animation_for(b, BsrReader.AnimationEntry.TYPE_STAND)
		b.pose(idle, 0.0)
	# A body faces its own -Z and the camera sits on +Z looking down -Z, so
	# turn the body round to face it.
	b.rotation.y = PI

func _frame(cam: Camera3D, centre: Vector3, height: float) -> void:
	cam.size = height
	cam.look_at_from_position(centre + Vector3(0, 0, 200), centre, Vector3.UP)
	cam.far = 1000.0

func _lights(world: Node3D) -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 25, 0)
	world.add_child(key)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.21)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.62, 0.66)
	env_node.environment = env
	world.add_child(env_node)

func _shoot(path: String) -> void:
	for _i in range(4):
		await process_frame
	get_root().get_texture().get_image().save_png(path)
	print("saved " + path)

# --- show-through ------------------------------------------------------------------

const _BODY_COLOR := Color(1, 0, 0)
const _WORN_COLOR := Color(0, 1, 0)

## Every MeshInstance3D under `n`.
func _mesh_instances(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_mesh_instances(c, out)

func _flat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.cull_mode = BaseMaterial3D.CULL_BACK
	return m

## The share of a worn armour's pixels where the body's own skin is drawn
## instead, front and back, each body with its armour only (no weapon or
## shield): pass 1 draws the armour alone (its mask), pass 2 body and armour
## in flat colours. MEASURED in pixels; needs a GL context.
func _measure_show_through(app: CharacterAppearance, cat: CharCatalog, every: bool) -> void:
	var world := Node3D.new()
	get_root().add_child(world)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.current = true
	world.add_child(cam)
	var body_mat := _flat(_BODY_COLOR)
	var worn_mat := _flat(_WORN_COLOR)
	var worst := 0.0
	var worst_all := 0.0
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			var figs := cat.figures(r, s)
			var count := figs.size() if every else 1
			for fi in range(count):
				var f: CharCatalog.Entry = figs[fi]
				for set_i in range(cat.all_armour_sets(r, s).size()):
					var armour := []
					var sets := cat.all_armour_sets(r, s)
					for id in sets[set_i].ids():
						armour.append({"id": id, "plus": 0})
					var line := "%-26s %-7s" % [f.code, sets[set_i].name]
					for scale in [0x02, 0x22, 0x42]:
						var b := app.build(f.id, scale, armour)
						_stand(app, b)
						world.add_child(b)
						var worn_nodes := []
						for w in b.worn:
							for n in w["nodes"]:
								_mesh_instances(n, worn_nodes)
						var all_nodes := []
						_mesh_instances(b.skeleton, all_nodes)
						var shrink := float(_arg("--shrink", "1.0"))
						if shrink != 1.0:
							for mi in all_nodes:
								if not worn_nodes.has(mi) and mi.skin != null:
									var sk: Skin = mi.skin.duplicate()
									for i in range(sk.get_bind_count()):
										sk.set_bind_pose(i, Transform3D(Basis.from_scale(Vector3.ONE * shrink), Vector3.ZERO) * sk.get_bind_pose(i))
									mi.skin = sk
						# What the builder left drawn: the body pieces its worn items
						# hide are off (round 687). "before" draws every body piece,
						# as the builder did until then; "after" keeps the hides.
						var built_visible := {}
						for mi in all_nodes:
							built_visible[mi] = mi.visible
						var shown := 0
						var shown_all := 0
						var covered := 0
						for yaw in [PI, 0.0]:
							b.rotation.y = yaw
							_frame(cam, Vector3(0, 9.5, 0), 21.0)
							for mi in all_nodes:
								var is_worn := worn_nodes.has(mi)
								mi.material_override = worn_mat if is_worn else body_mat
								mi.visible = is_worn
							var mask := await _grab()
							for mi in all_nodes:
								mi.visible = true
							var all_shot := await _grab()
							for mi in all_nodes:
								mi.visible = built_visible[mi]
							var both := await _grab()
							if _arg("--stdir") != "":
								both.save_png(_arg("--stdir").path_join("%s_%s_v%d_%d.png" % [f.code, sets[set_i].name, scale >> 4, int(yaw)]))
								all_shot.save_png(_arg("--stdir").path_join("%s_%s_v%d_%d_nohide.png" % [f.code, sets[set_i].name, scale >> 4, int(yaw)]))
								mask.save_png(_arg("--stdir").path_join("%s_%s_v%d_%d_mask.png" % [f.code, sets[set_i].name, scale >> 4, int(yaw)]))
							var counts := _compare(mask, both)
							covered += counts[0]
							shown += counts[1]
							shown_all += _compare(mask, all_shot)[1]
						var share := float(shown) / maxf(1.0, float(covered))
						var share_all := float(shown_all) / maxf(1.0, float(covered))
						worst = maxf(worst, share)
						worst_all = maxf(worst_all, share_all)
						line += "  v%d %5.2f%% -> %5.2f%% (%d hidden)" % [scale >> 4, share_all * 100.0, share * 100.0, b.hidden_body_meshes]
						b.free()
					print("show-through " + line)
	world.free()
	# Each cell is "every body piece drawn -> the worn items' hides applied"
	# (round 687). What is left is body pieces no worn item lists, which the
	# client draws too (READ, FUN_00c1f790), so the "after" figure is what the
	# archive's geometry gives at bind, not a defect count.
	print("show-through: worst %.2f%% of a worn armour's pixels with every body piece drawn, %.2f%% with the hides" % [worst_all * 100.0, worst * 100.0])

func _grab() -> Image:
	for _i in range(3):
		await process_frame
	return get_root().get_texture().get_image()

## [armour pixels in the mask, of those the body's colour in the full pass].
func _compare(mask: Image, both: Image) -> Array:
	var covered := 0
	var shown := 0
	for y in range(0, mask.get_height(), 2):
		for x in range(0, mask.get_width(), 2):
			var m := mask.get_pixel(x, y)
			if m.g > 0.5 and m.r < 0.5:
				covered += 1
				var c := both.get_pixel(x, y)
				if c.r > 0.5 and c.g < 0.5:
					shown += 1
	return [covered, shown]

# --- items only the index names ----------------------------------------------------

## An avatar hat from ItemData_23000.txt, a part itemdata.txt names and
## the world's old seven-path item list did not (MEASURED: ITEM_MALL_AVATAR_M_CH_WEDDING_HAT,
## 22912, `item\Avatar\avatar_m_ch_wedding_hat.bsr`), drawn on a China man.
func _check_index_items(app: CharacterAppearance) -> void:
	var b := app.build(1909, 0x22, [{"id": 22912, "plus": 0}])
	var drawn := 0
	if b != null and not b.worn.is_empty():
		drawn = (b.worn[0]["nodes"] as Array).size()
	_expect(drawn > 0, "an item only the index names (22912, ItemData_23000) is drawn as slot %s" % (
		str(b.worn[0]["slot"]) if b != null and not b.worn.is_empty() else "none"))
	print("full item table through itemdata.txt: %d rows in %.0f ms" % [
		app.stats["item_table_rows"], app.stats["item_table_usec"] / 1000.0])
	if b != null:
		b.free()
