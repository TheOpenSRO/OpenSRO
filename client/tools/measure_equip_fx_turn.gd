extends SceneTree

## Round 741: where a worn item's particles are drawn against its own weapon,
## at many headings -- the measurement behind the fix, not a picture.
##
## Dresses one body per (loadout, heading) through CharacterAppearance, turns
## the body to the heading, sways the hands a little (so the bones turn too),
## lets EquipFx place its holders and the masters simulate for --frames, then
## prints, per loadout:
##   TURN <loadout> <efp> bone <b>: headings <n>, particles <p>, axis <len>,
##        along [<min>, <max>], off max <d> (now) | <d> (round 734's placement)
## `along` / `off` are each drawn particle's world distance along and from the
## line from the row's bone to the item's other end bone (ai_start <-> ai_end,
## Bone01 <-> Bone03), the same measure as EquipFx's QA EQUIPFX log; "round
## 734's placement" is the same particles placed at the bone's position with
## the effect's axes along the world's. Headless (the placement and the
## simulation are CPU work; the vertex shaders that draw them are checked by
## equip_fx_turn_test's replay and by the render):
##   remote_godot.sh script res://tools/measure_equip_fx_turn.gd -- \
##     --pk2dir=/opt/sro-files/client --frames=120 \
##     --loadouts='6=4118+9/6=4118+0/6=62607+9/6=4046+9,7=4226+9/6=4190+9'

var _rows: Array = []   # [{loadout, body, heading}]
var _frames := 120
var _frame := 0

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _initialize() -> void:
	var dir := _arg("--pk2dir", "/opt/sro-files/client")
	var data := Pk2Reader.open(dir.path_join("Data.pk2"))
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var app := CharacterAppearance.from_archives(data, media)
	app.particles = Pk2Reader.open(dir.path_join("Particles.pk2"))
	_frames = int(_arg("--frames", "120"))
	await process_frame
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	root.add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 400, -10), Vector3(0, 0, 0))
	cam.current = true
	var headings := [0, 45, 90, 135, 180, 225, 270, 315]
	var i := 0
	# Loadouts are separated by "/" (a ";" would end the remote shell's command).
	for spec in _arg("--loadouts", "6=4118+9").split("/", false):
		var lo := EquipGlow.parse_loadout(spec)
		var items: Array = []
		for slot in lo[0]:
			items.append({"id": lo[0][slot], "plus": int((lo[1] as Dictionary).get(slot, 0))})
		for hd in headings:
			var b := app.build(1907, CharacterAppearance.DEFAULT_SCALE, items)
			if b == null:
				print("TURN %s: no body" % spec)
				break
			# Within EquipFx.ALWAYS_NEAR of nothing: 25 apart, all in view of
			# the camera high above.
			b.position = Vector3((i % 8 - 3.5) * 25.0, 0, (i / 8) * 25.0)
			b.rotation.y = deg_to_rad(float(hd))
			vp.add_child(b)
			_rows.append({"loadout": spec, "body": b, "heading": hd})
			i += 1
	print("TURN %d bodies" % _rows.size())

func _process(_delta: float) -> bool:
	_frame += 1
	var t := float(_frame) * 0.1
	for r in _rows:
		var sk: Skeleton3D = (r["body"] as CharacterAppearance.Body).skeleton
		for nm in ["Bip01 R Hand", "Bip01 L Hand", "Bip01 R Forearm", "Bip01 L Forearm"]:
			var bi := sk.find_bone(nm)
			if bi >= 0:
				sk.set_bone_pose_rotation(bi, sk.get_bone_rest(bi).basis.get_rotation_quaternion() * Quaternion(Vector3.UP, 0.3 * sin(t + float(r["heading"]))))
	if _frame < _frames:
		return false
	_report()
	quit(0)
	return true

func _report() -> void:
	var drivers := {}
	for r in _rows:
		var vp := (r["body"] as Node).get_viewport()
		drivers[vp.get_instance_id()] = EquipFx.driver_for(vp)
	# loadout|efp|bone -> summary
	var sums := {}
	for d in drivers.values():
		var fx := d as EquipFx
		# Every host, shown or not (the budget shows 64): the measure places
		# the particles as a holder would.
		for h in fx._hosts.values():
			var host := h as EquipFx.Host
			if not is_instance_valid(host.skel):
				continue
			var k: EquipFx.Kind = fx._kinds.get(host.key)
			if k == null or k.master.sim == null:
				continue
			var spec := ""
			var heading := 0
			for r in _rows:
				if (r["body"] as Node).is_ancestor_of(host.skel):
					spec = r["loadout"]
					heading = r["heading"]
			var m := EquipFx.measure(host, k)
			if m.is_empty():
				if heading == 0:
					print("TURN %s %s bone %s: nothing measured (%d live particle(s), bones %s)" % [spec, k.key.get_slice("|", 0),
						host.skel.get_bone_name(host.bone), k.master.sim.particles.size(), str(range(host.skel.get_bone_count()).map(func(i): return host.skel.get_bone_name(i)))])
				continue
			var key := "%s|%s|%s" % [spec, k.key.get_slice("|", 0), m["bone"]]
			_others[key] = "%s->%s" % [m["bone"], m["other"]]
			if not sums.has(key):
				sums[key] = {"n": 0, "p": 0, "lo": INF, "hi": -INF, "off": 0.0, "was": 0.0, "axis": 0.0, "headings": [], "cent": []}
			var s: Dictionary = sums[key]
			# The centroid against the weapon's axis: along it, and off it.
			var tip: Vector3 = m["tip"]
			var g: Transform3D = host.skel.global_transform
			var ob := host.skel.find_bone(String(m["other"]))
			var dir: Vector3 = (g * host.skel.get_bone_global_pose(ob).origin - tip).normalized()
			var cv: Vector3 = m["centroid"] - tip
			if not s.has("mesh"):
				s["mesh"] = _mesh_extent(host.skel, tip, dir)
			# The centroid in the item skeleton's own frame: the same at every
			# heading when the effect turns with the weapon.
			var inv := g.affine_inverse()
			if not s.has("local"):
				s["local"] = []
				s["local_was"] = []
			(s["local"] as Array).append(inv * (m["centroid"] as Vector3))
			(s["local_was"] as Array).append(inv * (m["was_centroid"] as Vector3))
			var ca := cv.dot(dir)
			var wv: Vector3 = m["was_centroid"] - tip
			var wa := wv.dot(dir)
			(s["cent"] as Array).append("%d:(%.2f, %.2f | was %.2f, %.2f)" % [heading, ca, (cv - dir * ca).length(), wa, (wv - dir * wa).length()])
			s["n"] += 1
			s["p"] += int(m["particles"])
			s["lo"] = minf(s["lo"], m["lo"])
			s["hi"] = maxf(s["hi"], m["hi"])
			s["off"] = maxf(s["off"], m["off_max"])
			s["was"] = maxf(s["was"], m["was_max"])
			s["axis"] = m["axis"]
			(s["headings"] as Array).append(heading)
	# What each effect draws: its plate/mesh nodes, its link nodes, and what
	# EfpEffect skipped (a texture or mesh that did not load, a mode not drawn).
	for d in drivers.values():
		for kk in (d as EquipFx)._kinds:
			var kind: EquipFx.Kind = (d as EquipFx)._kinds[kk]
			var turned := 0
			for dr in kind.master._draws:
				if dr.size() > 3 and bool(dr[3]):
					turned += 1
			print("TURN effect %s: %d plate/mesh node(s) (%d on the per-camera billboard), %d link node(s), skipped %s" % [
				String(kk).get_slice("|", 0), kind.master._draws.size(), turned, kind.master._links.size(), str(kind.master.skipped)])
	var keys := sums.keys()
	keys.sort()
	for key in keys:
		var s: Dictionary = sums[key]
		var parts := String(key).split("|")
		print("TURN %s %s bone %s: headings %d, particles %d, axis %.2f, along [%.2f, %.2f], off max %.3f (now) | %.3f (round 734's placement)" % [
			parts[0], parts[1], parts[2], s["n"], s["p"], s["axis"], s["lo"], s["hi"], s["off"], s["was"]])
		print("TURN   centroid (along, off | round 734's along, off) by heading: %s" % " ".join(PackedStringArray(s["cent"])))
		print("TURN   the item's own mesh along the same axis: %s" % str(s.get("mesh", "none")))
		print("TURN   centroid in the item's own frame, spread over the headings: %.3f (now) | %.3f (round 734's placement); axis %s" % [
			_spread(s.get("local", [])), _spread(s.get("local_was", [])), m_other(String(key))])

## The weapon's own mesh against the axis (independent of the bones'
## meaning): every vertex of the item skeleton's meshes, placed as the item
## stands (rest pose, the mesh instance's global transform), along `dir` from
## `tip` -- [min, max] -- and its largest distance off the axis. A bone at the
## weapon's end has min near 0.
func _mesh_extent(skel: Skeleton3D, tip: Vector3, dir: Vector3) -> String:
	var lo := INF
	var hi := -INF
	var off := 0.0
	var n := 0
	for c in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null or mi.get_parent() is EfpEffect:
			continue
		var gt := mi.global_transform
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			for v in (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				var w := gt * v - tip
				var a := w.dot(dir)
				lo = minf(lo, a)
				hi = maxf(hi, a)
				off = maxf(off, (w - dir * a).length())
				n += 1
	if n == 0:
		return "no mesh"
	return "%d vertices, along [%.2f, %.2f], off max %.2f" % [n, lo, hi, off]

var _others := {}

func m_other(key: String) -> String:
	return String(_others.get(key, "?"))

## The largest distance between any two of `pts`.
func _spread(pts: Array) -> float:
	var out := 0.0
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			out = maxf(out, (pts[i] as Vector3).distance_to(pts[j]))
	return out
