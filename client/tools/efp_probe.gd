extends SceneTree

## Round 785: measures how a skill's effects play -- what each node is, and,
## per 50 ms simulation frame, what is alive, drawn, how far from the host,
## and whether it would be culled -- on a host that stands or runs, at a
## given render rate. Reads the player's archives at runtime and prints only
## counts, paths and numbers (no game data is stored).
##
##   godot4 --headless --path client --script res://tools/efp_probe.gd -- \
##       --pk2dir=/opt/sro-files/client [--skills=8150,8214] [--files=a.efp;b.efp]
##       [--fps=60] [--speed=50] [--seconds=6] [--tree] [--trace] [--keep=0|1]
##       [--native]
##
## --skills plays every skilleffectset row of those skill ids (the row's
## ActType decides kept or not); --files plays those paths (kept with
## --keep=1). --speed is the host's run speed in world (native) units a
## second along +x; the world is in native units (World3D's run speed 50).
## --native simulates through EfpSimNative where the library is loaded.
##
## Each run prints a SUMMARY line: frames until the first drawn particle,
## frames it lasted (or "running"), the peak and the per-frame minimum of
## drawn particles once started, gap frames (nothing drawn after it started),
## the farthest drawn particle from the host, the drawn particles outside
## EfpEffect.DRAW_AABB around the node, and the root revivals a second.

var _fps := 60.0
var _speed := 0.0
var _seconds := 6.0
var _tree := false
var _trace := false
var _keep := -1
var _native := false

func _init() -> void:
	var dir := OS.get_environment("OPENSRO_PK2_DIR")
	var skills := PackedStringArray()
	var files := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2dir="):
			dir = a.substr(9)
		elif a.begins_with("--skills="):
			skills = a.substr(9).split(",", false)
		elif a.begins_with("--files="):
			# "/" for "\\": a backslash does not survive the ssh and su layers.
			files = a.substr(8).replace("/", "\\").split(";", false)
		elif a.begins_with("--fps="):
			_fps = float(a.substr(6))
		elif a.begins_with("--speed="):
			_speed = float(a.substr(8))
		elif a.begins_with("--seconds="):
			_seconds = float(a.substr(10))
		elif a.begins_with("--keep="):
			_keep = int(a.substr(7))
		elif a == "--tree":
			_tree = true
		elif a == "--trace":
			_trace = true
		elif a == "--native":
			_native = true
	call_deferred("_run", dir, skills, files)

func _run(dir: String, skills: PackedStringArray, files: PackedStringArray) -> void:
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	if media == null or particles == null:
		print("cannot open Media.pk2 / Particles.pk2 under %s" % dir)
		quit(2)
		return
	var jobs: Array = [] # [path, kept, label]
	if not skills.is_empty():
		var entry := ObjectLoader.find_file(media, SkillEffects.SKILLEFFECT_PATH)
		var rows := SkillEffects.parse_rows(media.read_file(entry))
		AudioBank._archives["media"] = media
		SkillAudio.warm()
		for s in skills:
			for r in SkillAudio.effect_rows_in(SkillAudio._skills, rows, int(s)):
				var act := int(r["act"])
				var kept := act == SkillEffects.AT_LOOP or act == SkillEffects.AT_STOP
				var label := "skill %s %s/%d %s bone %s offset %s" % [s, SkillAudio._phase_name(int(r["ani"])),
					int(r["event"]), SkillEffects.ACT_TYPES[act] if act >= 0 else "?", r["bone"], r["offset"]]
				print("ROW " + label + " " + String(r["path"]))
				jobs.append([String(r["path"]), kept, label])
	for f in files:
		jobs.append([f, _keep == 1, "file"])
	for j in jobs:
		_probe(String(j[0]), bool(j[1]) if _keep < 0 else _keep == 1, String(j[2]), particles)
	media.close()
	particles.close()
	quit(0)

func _probe(path: String, kept: bool, label: String, particles: Pk2Reader) -> void:
	var fx := EfpEffect.create(path, particles)
	if fx == null:
		print("LOADFAIL %s (%s)" % [path, EfpEffect.last_error])
		return
	var drawn := {}
	for d in fx._draws:
		drawn[int(d[0])] = String(d[2])
	for d in fx._links:
		drawn[int(d[0])] = String(d[2])
	var t: EfpSim.Template = fx.sim.template
	if _tree:
		print("TREE %s (%s) skipped %s" % [path, label, fx.skipped])
		for tp in t.tpls:
			var n: EfpReader.EfpNode = tp.node
			var cmds := {}
			for c in n.commands:
				var k := "%s/%d" % [c.name, c.space]
				cmds[k] = int(cmds.get(k, 0)) + 1
			var st := n.state
			print("  #%d parent %d %s frames %d life %s emit %s render %s view %s drawn %s blend %d/%d flags %s cmds %s" % [
				tp.index, tp.parent, n.name, tp.frames, ["extinct", "loop", "never"][tp.life],
				[tp.e_delay, tp.e_dur, tp.e_int, tp.e_max, tp.e_per] if tp.emit != null else "none",
				n.render_mode(), n.view_mode(), drawn.has(tp.index),
				st.src_blend if st else -1, st.dest_blend if st else -1, n.flags, cmds])
	var host := Node3D.new()
	var skel := Skeleton3D.new()
	host.add_child(skel)
	get_root().add_child(host)
	fx.loop = kept
	fx.reserved = true
	fx.auto_free = false
	var ended := [false]
	fx.effect_finished.connect(func(): ended[0] = true)
	host.add_child(fx)
	fx.follow_host(host, "", Vector3.ZERO)
	if _native:
		fx.use_native_sim(1)
	var dt := 1.0 / _fps
	var render_frames := int(round(_seconds * _fps))
	var started := -1
	var last_frame := -1
	var peak := 0
	var min_after := 1 << 30
	var gap := 0
	var far := 0.0
	var outside := 0
	var outside_frames := 0
	var revived0 := fx.sim.revived
	var sim_frames := 0
	var lasted := -1
	for i in range(render_frames):
		host.position.x += _speed * dt
		fx._process(dt)
		if ended[0]:
			lasted = sim_frames
			break
		var steps: int = fx._pending_steps
		if steps <= 0:
			continue
		sim_frames += steps
		var live := 0
		var dn := 0
		var lit := 0
		var mx := 0.0
		var out_n := 0
		var per_node := {}
		var origin: Vector3 = fx.sim.origin()
		for p in fx.sim.particle_list():
			live += 1
			if not drawn.has(p.tpl):
				continue
			dn += 1
			per_node[p.tpl] = int(per_node.get(p.tpl, 0)) + 1
			if (p.color & 0xFF000000) != 0:
				lit += 1
			mx = maxf(mx, (p.pos - origin).length())
			if not EfpEffect.DRAW_AABB.has_point(p.pos):
				out_n += 1
		if started < 0 and dn > 0:
			started = sim_frames
		if started >= 0:
			peak = maxi(peak, dn)
			min_after = mini(min_after, dn)
			if dn == 0:
				gap += 1
		far = maxf(far, mx)
		outside = maxi(outside, out_n)
		if out_n > 0:
			outside_frames += 1
		if _trace:
			print("  F %d live %d drawn %d lit %d far %.1f out %d revived %d nodes %s" % [sim_frames, live, dn, lit, mx,
				out_n, fx.sim.revived - revived0, per_node])
	var secs := float(sim_frames) * EfpSim.FRAME_SEC
	print("SUMMARY %s kept %s fps %.0f speed %.0f: first_draw %d lasted %s peak %d min_after %s gap_frames %d far %.1f outside_aabb max %d in %d frames revivals/s %.2f sim_frames %d (%s)" % [
		path, kept, _fps, _speed, started, str(lasted) if lasted >= 0 else "running", peak,
		str(min_after) if started >= 0 else "-", gap, far, outside, outside_frames,
		float(fx.sim.revived - revived0) / maxf(secs, 0.001), sim_frames, label])
	fx.stop()
	host.free()
