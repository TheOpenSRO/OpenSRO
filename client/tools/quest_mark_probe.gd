extends SceneTree

## Round 785's client review, finding 3: does a quest-marked NPC draw
## particles? Puts each mark kind on a stand-in NPC holder exactly as World3D
## does -- QuestMarks.apply_one with the world's own loader shape (the .bsr's
## ambient entries, QuestMarks.entries_of, from Data.pk2) and its effect
## maker (EfpEffect.create from Particles.pk2) -- steps the effects for a
## second and prints, per mark, the effects built, their live particles,
## the draw nodes' visible instances and where they stand over the holder.
## Reads the player's archives at runtime and prints only counts, paths and
## numbers (no game data is stored).
##
##   godot4 --headless --path client --script res://tools/quest_mark_probe.gd -- \
##       --pk2dir=/opt/sro-files/client [--height=20]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	await process_frame
	var dir := _arg("--pk2dir", "/opt/sro-files/client")
	var data := Pk2Reader.open(dir.path_join("Data.pk2"))
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	if data == null or particles == null:
		print("QUEST MARK PROBE: could not open the archives under %s" % dir)
		quit(1)
		return
	var height := float(_arg("--height", "20"))
	var loader := func(path: String) -> Array:
		var e := ObjectLoader.find_file(data, path)
		return QuestMarks.entries_of(data.read_file(e)) if e != null else []
	var make_fx := func(efp: String) -> EfpEffect:
		var fx := EfpEffect.create(efp, particles)
		if fx == null:
			print("QUEST MARK PROBE: %s did not build (%s)" % [efp, EfpEffect.last_error])
		return fx
	var bad := 0
	for kind in [QuestNet.MARK_START, QuestNet.MARK_GOING, QuestNet.MARK_END, 4]:
		var holder := Node3D.new()
		holder.set_meta(QuestMarks.HEIGHT_META, height)
		root.add_child(holder)
		await process_frame
		var m := QuestNet.Mark.new()
		m.object_id = 1
		m.mark_type = kind
		var models := {}
		QuestMarks.apply_one(holder, m, models, loader, make_fx)
		var node := holder.get_node_or_null(QuestMarks.MARK_NODE) as Node3D
		var fxs: Array = node.get_children().filter(func(c): return c is EfpEffect) if node != null else []
		var live := 0
		var shown := 0
		var peak_shown := 0
		for f in 20:
			shown = 0
			live = 0
			for fx_v in fxs:
				var fx := fx_v as EfpEffect
				fx._process(0.05)
				live += fx.sim.particles.size() if fx.sim != null else 0
				for c in fx.get_children():
					if c is MultiMeshInstance3D and (c as MultiMeshInstance3D).multimesh != null:
						shown += maxi((c as MultiMeshInstance3D).multimesh.visible_instance_count, 0)
			peak_shown = maxi(peak_shown, shown)
		var where := "-"
		if not fxs.is_empty():
			where = str((fxs[0] as EfpEffect).placed_at() - holder.global_position)
		print("QUEST MARK PROBE kind %d %s: %d effect(s) %s, after 1 s %d live particle(s), %d drawn instance(s) (peak %d), placed at %s over the holder" % [
			kind, QuestMarks.mark_path(kind), fxs.size(), str((models.values()[0] as Array).map(func(x): return x[0])) if not models.is_empty() else "[]",
			live, shown, peak_shown, where])
		if fxs.is_empty() or peak_shown == 0:
			bad += 1
		holder.free()
	print("QUEST MARK PROBE: %s" % ("every mark draws particles" if bad == 0 else "%d mark(s) draw nothing" % bad))
	quit(0 if bad == 0 else 1)
