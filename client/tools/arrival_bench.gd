extends SceneTree

## Dev tool (round 756): what an arriving other player costs on the main thread,
## phase by phase, for a crowd of different kits (every body its own Figure,
## armour, weapon, plus and scale byte) -- the numbers the arrival's design is
## sized by. Run on the render box, under the GPU for the real RenderingServer
## costs (xwl_run.sh ... --rendering-method forward_plus), or headless for the
## script's own share:
##
##   remote_godot.sh script res://tools/arrival_bench.gd -- --pk2=<Data.pk2> --media=<Media.pk2>
##       [--count=300] [--seed=756] [--kinds=diverse|same]
##
## Prints one `BENCH` line a phase: the mean, p50 and p95 microseconds a body,
## after a warm pass that makes every template (the cached state a crowd
## arrives into once its kinds are prepared).

var _appearance: CharacterAppearance
var _crowd: CrowdGpu
var _world: Node3D
var _rng := RandomNumberGenerator.new()

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--count=300] [--seed=756] [--kinds=diverse|same]")
		quit(2)
		return
	_appearance = CharacterAppearance.from_archives(data, media)
	_appearance.canonical = true
	_world = Node3D.new()
	root.add_child(_world)
	var cam := Camera3D.new()
	_world.add_child(cam)
	_crowd = CrowdGpu.new(root.find_world_3d().scenario)
	_rng.seed = int(_arg("--seed", "756"))
	_run.call_deferred()

## Random kits: a Figure, an armour piece per worn slot of its race and sex, a
## weapon (a shield beside a one-handed one), a plus and a scale byte.
func _kits(count: int, same: bool) -> Array:
	_appearance._item_info(-1)
	var cat := _appearance.catalog()
	var figs: Array = []
	for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
		for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			for f in cat.figures(r, s):
				figs.append(f)
	var by := {}   # "race|sex|slot" -> [item ids]
	for id in _appearance._items.keys():
		var info: Dictionary = _appearance._items[id]
		var tids: PackedInt32Array = info.get("type_ids", PackedInt32Array())
		var slot := CharacterAppearance.visual_slot(tids)
		if slot < 0 or slot > CharacterAppearance.SLOT_SHIELD:
			continue
		var e := cat.get_entry(int(id))
		var race := e.race if e != null else -1
		for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
			if race != -1 and race != r:
				continue
			for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
				if e != null and not e.fits_sex(s):
					continue
				var k := "%d|%d|%d" % [r, s, slot]
				if not by.has(k):
					by[k] = []
				(by[k] as Array).append(int(id))
	var out: Array = []
	for i in range(count):
		var f: CharCatalog.Entry = figs[(i if not same else 0) % figs.size()] if same else figs[_rng.randi() % figs.size()]
		var items: Array = []
		for slot in [CharacterAppearance.SLOT_HEAD, CharacterAppearance.SLOT_SHOULDER, CharacterAppearance.SLOT_CHEST,
				CharacterAppearance.SLOT_LEGS, CharacterAppearance.SLOT_HANDS, CharacterAppearance.SLOT_FEET,
				CharacterAppearance.SLOT_WEAPON, CharacterAppearance.SLOT_SHIELD]:
			var pool: Array = by.get("%d|%d|%d" % [f.race, f.sex, slot], [])
			if pool.is_empty() or (slot == CharacterAppearance.SLOT_SHIELD and _rng.randf() < 0.5):
				continue
			var pick: int = pool[_rng.randi() % pool.size()] if not same else pool[0]
			var plus := _rng.randi() % 14 if (slot == CharacterAppearance.SLOT_WEAPON or slot == CharacterAppearance.SLOT_SHIELD) and not same else 0
			items.append({"id": pick, "plus": plus})
		var scale := ((_rng.randi() % 5) << 4) | (_rng.randi() % 5) if not same else CharacterAppearance.DEFAULT_SCALE
		out.append([f.id, scale, items])
	return out

static func _sig(p: Dictionary) -> String:
	return "%d/%d/%d/%.4f/%d/%.3f" % [(p["mesh"] as Mesh).get_instance_id(), (p["material"] as Material).get_instance_id(), int(p["vol"]),
		float(p["centre"]), int(p["layers"]), float(p["sort"])]

func _run() -> void:
	await process_frame
	var count := int(_arg("--count", "300"))
	var kits := _kits(count, _arg("--kinds", "diverse") == "same")
	var t := {}
	for k in ["build", "detach", "enter", "parts", "add", "plate", "collider", "body_node", "recipe", "recipe_hit", "ghost", "ghost_again"]:
		t[k] = PackedFloat64Array()
	# Warm: every template made, every clip baked, so the measured pass is the
	# cached state.
	var warm := 0
	for kit in kits:
		var b := _appearance.build(int(kit[0]), int(kit[1]), kit[2])
		if b == null:
			continue
		var anim := _appearance.animation_for(b, BsrReader.AnimationEntry.TYPE_STAND)
		var holder := Node3D.new()
		_world.add_child(holder)
		var skel := b.skeleton
		b.remove_child(skel)
		b.free()
		holder.add_child(skel)
		if anim != null:
			_crowd.can_draw(skel, [skel, anim, 2, 0.0, true, 0.0, null])
		holder.free()
		warm += 1
	_crowd.bake_all()
	print("BENCH: %d kits warmed" % warm)
	var mismatched := 0
	var compared := 0
	var refused := 0
	for i in range(kits.size()):
		var kit: Array = kits[i]
		# Round 756: the kind's far recipe (first and cached), and a ghost from it.
		var r0 := Time.get_ticks_usec()
		var recipe := _appearance.far_recipe(int(kit[0]), int(kit[1]), kit[2])
		var r1 := Time.get_ticks_usec()
		_appearance.far_recipe(int(kit[0]), int(kit[1]), kit[2])
		var r2 := Time.get_ticks_usec()
		t["recipe"].append(r1 - r0)
		t["recipe_hit"].append(r2 - r1)
		var t0 := Time.get_ticks_usec()
		var b := _appearance.build(int(kit[0]), int(kit[1]), kit[2])
		var t1 := Time.get_ticks_usec()
		if b == null:
			continue
		var anim := _appearance.animation_for(b, BsrReader.AnimationEntry.TYPE_STAND)
		var skel := b.skeleton
		var t2 := Time.get_ticks_usec()
		b.remove_child(skel)
		skel.scale = b.scale
		b.free()
		var t3 := Time.get_ticks_usec()
		var holder := Node3D.new()
		holder.position = Vector3(float(i % 40) * 8.0, 0.0, float(i / 40) * 10.0)
		_world.add_child(holder)
		var t4 := Time.get_ticks_usec()
		skel.rotation.y = PI
		holder.add_child(skel)
		var t5 := Time.get_ticks_usec()
		skel.set_meta(CrowdAnim.META_CACHED, true)
		var local0 := skel.transform
		var l := _crowd._layout_for(skel)
		var t6 := Time.get_ticks_usec()
		var parts = _crowd._parts_of(skel, l) if l != null else null
		var t7 := Time.get_ticks_usec()
		# The parity: the recipe's parts against the built body's.
		var geo = _crowd._recipe_geometry(recipe) if recipe != null else null
		if parts != null and geo != null:
			compared += 1
			var a := PackedStringArray()
			for p in parts:
				a.append(_sig(p))
			var c := PackedStringArray()
			for g in _crowd._lit_parts(recipe, (geo as Array)[0], -1.0):
				c.append(_sig(g))
			a.sort()
			c.sort()
			if a != c:
				mismatched += 1
				if mismatched <= 5:
					print("BENCH PARITY MISMATCH kit %s: built %s recipe %s" % [str(kit), ", ".join(a), ", ".join(c)])
		elif parts != null:
			refused += 1
		var ok := anim != null and _crowd.add(holder, skel, [skel, anim, 2, 0.37 * float(i), true, 0.0, null], 0.0)
		var t8 := Time.get_ticks_usec()
		if recipe != null and anim != null and geo != null:
			var gh := Node3D.new()
			gh.position = holder.position + Vector3(0.0, 0.0, 400.0)
			gh.set_meta("character_id", 100000 + i)
			_world.add_child(gh)
			var g0 := Time.get_ticks_usec()
			if _crowd.add_ghost(gh, recipe, [gh, anim, 2, 0.37 * float(i), true, 0.0, null], local0, 0.5, 0.0, true):
				t["ghost"].append(Time.get_ticks_usec() - g0)
			# A second body of the same kind and light: what a kind already seen costs.
			var gh2 := Node3D.new()
			gh2.position = gh.position + Vector3(4.0, 0.0, 0.0)
			_world.add_child(gh2)
			var g1 := Time.get_ticks_usec()
			if _crowd.add_ghost(gh2, recipe, [gh2, anim, 2, 0.5, true, 0.0, null], local0, 0.5, 0.0, true):
				t["ghost_again"].append(Time.get_ticks_usec() - g1)
		t8 = Time.get_ticks_usec()
		var label := Label3D.new()
		label.text = "Body%d" % i
		label.fixed_size = true
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.position = Vector3(0, 20, 0)
		holder.add_child(label)
		var t9 := Time.get_ticks_usec()
		var shape := CapsuleShape3D.new()
		shape.height = 18.0
		shape.radius = 5.0
		var sb := StaticBody3D.new()
		sb.collision_layer = 1 << 3
		sb.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.shape = shape
		sb.add_child(cs)
		holder.add_child(sb)
		var t10 := Time.get_ticks_usec()
		t["build"].append(t1 - t0)
		t["detach"].append(t3 - t2)
		t["body_node"].append(t4 - t3)
		t["enter"].append(t5 - t4)
		t["parts"].append(t7 - t6)
		if ok:
			t["add"].append(t8 - t7)
		t["plate"].append(t9 - t8)
		t["collider"].append(t10 - t9)
	for k in t:
		var v: PackedFloat64Array = t[k]
		if v.is_empty():
			print("BENCH %-9s none" % k)
			continue
		var s := 0.0
		for x in v:
			s += x
		var sorted := v.duplicate()
		sorted.sort()
		print("BENCH %-9s n=%d mean=%.0f us p50=%.0f p95=%.0f" % [k, v.size(), s / v.size(), sorted[sorted.size() / 2],
			sorted[mini(int(sorted.size() * 0.95), sorted.size() - 1)]])
	print("BENCH parity: %d kits compared, %d mismatched, %d built bodies the recipe path refused; recipe stats %s" % [
		compared, mismatched, refused, str(_appearance.far_stats)])
	print("BENCH crowd: %s" % _crowd.describe())
	_crowd.release_all()
	_crowd = null
	_appearance.free_templates()
	quit(0)
