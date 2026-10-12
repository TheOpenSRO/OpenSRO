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
## --census plays every .efp the skilleffectset rows name (once per path and
## kept-or-not; --only=<substring> narrows it) and prints one SUMMARY line
## each, then CENSUS totals; with --quiet only the totals.
##
## --drift (round 786) runs each job through four host scenarios instead and
## prints one DRIFT line per scenario: `stand` (the host still), `jump` (still,
## then moved --jump=x,y,z native units in one frame -- a zone change, whose
## grid is built in the new zone's own frame, round 570 -- then still again),
## `walk` (still, then running at --speed, default 50, then still) and `turn`
## (still, then turning --turn degrees a second, default 180, then still).
## Each scenario's numbers are the farthest drawn particle from the effect's
## placement point (the host's origin) in its still lead-in (`still`, the
## effect's own spread on a still host: its authored bound) and from the
## scenario's event on (`after`), how many drawn particles stood past
## still + DRIFT_TOL, and the last frame one did. CENSUS DRIFT lines total
## them per scenario (`--census --drift`). A fifth, `zone`, is a zone change
## as round 786 plays it (READ, EfpEffect.shift_effects): the effect moved by
## the frames' offset (--frame=x,y,z, default Donwhang's frame to Jangan's),
## the host by --jump in the new frame. `near` counts the particles past the
## spread but within DRIFT_NEAR -- in sight of the body. --modes=jump,zone
## picks scenarios. --equip adds every equipment effect (the seal and enchant
## glows, kept) to the jobs.
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
var _census := false
var _quiet := false
var _only := ""
var _drift := false
## --equip (round 786): the equipment effects (seal and enchant glows) too.
var _equip := false
var _jump := Vector3(150, -30, -120)
var _turn := 180.0
## Round 786: the body's physics rate (--physics=60; 0 moves it every frame)
## and whether the effect is processed on those ticks (--physics-effects).
var _physics := 0
var _phys_acc := 0.0
var _physics_effects := false
var _ticks_done := 0
var _frame := Vector3(-28800, 0, -9600)
## The drift scenarios to run (--modes=jump,walk; all four by default).
var _modes := PackedStringArray(["stand", "jump", "walk", "turn"])
## A drawn particle farther than its still spread plus this (native units)
## from the placement point counts as off the host (DRIFT lines). OURS.
const DRIFT_TOL := 10.0
## Past the spread but nearer than this (native units): in sight of the body
## (OURS; the original draws a character's particle mods only within 720 of
## the camera, READ round 761).
const DRIFT_NEAR := 2000.0
## Per drift scenario: runs, runs with a particle past still + DRIFT_TOL, the
## worst excess and its file, particle-frames past it.
var _dt := {}
## Census totals: files, those whose drawn particles ever went past FAR_TRAIL
## from the host, the worst such distance, drawn particles following a dead
## ancestor (summed over frames), pops, and frames with particles outside the
## draw box.
var _t := {"files": 0, "trail_files": 0, "far_max": 0.0, "orphan_frames": 0, "pop_files": 0,
	"outside_files": 0, "loadfail": 0, "never_drawn": 0, "mismatch_files": 0, "dropped_files": 0}
const FAR_TRAIL := 100.0

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
		elif a == "--census":
			_census = true
		elif a == "--quiet":
			_quiet = true
		elif a == "--drift":
			_drift = true
		elif a == "--equip":
			_equip = true
		elif a.begins_with("--jump="):
			var v := a.substr(7).split(",")
			if v.size() == 3:
				_jump = Vector3(float(v[0]), float(v[1]), float(v[2]))
		elif a.begins_with("--physics="):
			_physics = int(a.substr(10))
		elif a == "--physics-effects":
			_physics_effects = true
		elif a.begins_with("--frame="):
			var fv := a.substr(8).split(",")
			if fv.size() == 3:
				_frame = Vector3(float(fv[0]), float(fv[1]), float(fv[2]))
		elif a.begins_with("--turn="):
			_turn = float(a.substr(7))
		elif a.begins_with("--modes="):
			_modes = a.substr(8).split(",", false)
		elif a.begins_with("--only="):
			_only = a.substr(7).to_lower()
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
				var kept := _kept(act)
				var label := "skill %s %s/%d %s bone %s offset %s" % [s, SkillAudio._phase_name(int(r["ani"])),
					int(r["event"]), SkillEffects.ACT_TYPES[act] if act >= 0 else "?", r["bone"], r["offset"]]
				print("ROW " + label + " " + String(r["path"]))
				jobs.append([String(r["path"]), kept, label])
	for f in files:
		jobs.append([f, _keep == 1, "file"])
	if _equip:
		# Round 786: every equipment effect (the seal and enchant glows the two
		# tables name, ItemGlowTables -- census_equip_world.gd's list), kept as
		# EquipFx keeps them.
		var gt := ItemGlowTables.for_archive(media)
		var eq := {}
		for call in gt._particle_calls:
			for pair in call:
				eq[(pair[1] as ItemGlowTables.ParticleRow).efp.to_lower()] = true
		var names := eq.keys()
		names.sort()
		for f in names:
			jobs.append([String(f), true, "equip"])
	if _census:
		var entry := ObjectLoader.find_file(media, SkillEffects.SKILLEFFECT_PATH)
		var rows := SkillEffects.parse_rows(media.read_file(entry))
		var seen := {}
		for id in rows:
			for r in rows[id]:
				var kept := _kept(int(r["act"]))
				var path := String(r["path"])
				var key := "%s|%s" % [path.to_lower(), kept]
				if seen.has(key) or (_only != "" and path.to_lower().find(_only) < 0):
					continue
				seen[key] = true
				jobs.append([path, kept, "census"])
		jobs.sort_custom(func(a, b): return String(a[0]) < String(b[0]))
	for j in jobs:
		if _drift:
			for mode in _modes:
				_probe_drift(String(j[0]), bool(j[1]) if _keep < 0 else _keep == 1, String(j[2]), particles, mode)
			continue
		_probe(String(j[0]), bool(j[1]) if _keep < 0 else _keep == 1, String(j[2]), particles)
	if _drift:
		for mode in _modes:
			var d: Dictionary = _dt.get(mode, {"runs": 0, "off": 0, "worst": 0.0, "pframes": 0, "worst_path": ""})
			print("CENSUS DRIFT %s jump %s frame %s speed %.0f turn %.0f: %d runs, %d with drawn particles past their still spread + %.0f (worst +%.1f, %s), %d particle-frames past it; in sight (under %.0f units) %d runs, %d particle-frames" % [
				mode, _jump, _frame, _speed if _speed > 0.0 else 50.0, _turn, d["runs"], d["off"], DRIFT_TOL,
				d["worst"], d["worst_path"], d["pframes"], DRIFT_NEAR, d.get("near_runs", 0), d.get("near", 0)])
		media.close()
		particles.close()
		quit(0)
		return
	if _census:
		print("CENSUS fps %.0f speed %.0f seconds %.1f: %d runs, %d did not load, %d never drew; drawn past %.0f units from the host in %d (worst %.1f); %d drawn particle-frames following a dead ancestor; %d with a pop; %d with drawn particles outside the draw box; %d whose draws lagged their particles; %d with spawns refused (the 300 cap)" % [
			_fps, _speed, _seconds, _t["files"], _t["loadfail"], _t["never_drawn"], FAR_TRAIL, _t["trail_files"],
			_t["far_max"], _t["orphan_frames"], _t["pop_files"], _t["outside_files"], _t["mismatch_files"], _t["dropped_files"]])
	media.close()
	particles.close()
	quit(0)

func _probe(path: String, kept: bool, label: String, particles: Pk2Reader) -> void:
	var fx := EfpEffect.create(path, particles)
	if fx == null:
		_t["loadfail"] += 1
		if not _quiet:
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
	var orphans := 0
	var pops := 0
	var last_dn := 0
	var mismatch := 0
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
			for a in [p.f_move, p.f_orbit, p.f_rot, p.f_vel]:
				if a != null and not a.alive:
					orphans += 1
					break
		if started < 0 and dn > 0:
			started = sim_frames
		# What the draws hold after this frame's update against the particles
		# of the drawn nodes (a node whose draw lags its particles).
		if fx.drawn_particles() != dn:
			mismatch += 1
		# A pop: the drawn count falls below half of the frame before's.
		if last_dn >= 4 and dn * 2 < last_dn:
			pops += 1
		last_dn = dn
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
	_t["files"] += 1
	if started < 0:
		_t["never_drawn"] += 1
	if far > FAR_TRAIL:
		_t["trail_files"] += 1
	_t["far_max"] = maxf(float(_t["far_max"]), far)
	_t["orphan_frames"] += orphans
	if pops > 0:
		_t["pop_files"] += 1
	if outside > 0:
		_t["outside_files"] += 1
	if mismatch > 0:
		_t["mismatch_files"] += 1
	if fx.sim.dropped > 0:
		_t["dropped_files"] += 1
	if _quiet:
		fx.stop()
		host.free()
		return
	print("SUMMARY %s kept %s fps %.0f speed %.0f: first_draw %d lasted %s peak %d min_after %s gap_frames %d far %.1f outside_aabb max %d in %d frames revivals/s %.2f sim_frames %d orphan_frames %d pops %d draw_mismatch %d dropped %d (%s)" % [
		path, kept, _fps, _speed, started, str(lasted) if lasted >= 0 else "running", peak,
		str(min_after) if started >= 0 else "-", gap, far, outside, outside_frames,
		float(fx.sim.revived - revived0) / maxf(secs, 0.001), sim_frames, orphans, pops, mismatch, fx.sim.dropped, label])
	fx.stop()
	host.free()

## Kept (retail's keep flag, READ round 785: IDecoSkill::FUN_00a513a0 sets
## it for ActType 2, AT_LOOP, alone), by the ActType's name so the probe
## reads the same under either client's ACT_TYPES order.
func _kept(act: int) -> bool:
	return act >= 0 and act < SkillEffects.ACT_TYPES.size() and SkillEffects.ACT_TYPES[act] == "AT_LOOP"

const DRIFT_MODES := ["stand", "jump", "walk", "zigzag", "turn"]
const DRIFT_LEAD := 4.0 ## seconds still before the event (OURS)
const DRIFT_EVENT := 2.0 ## seconds of running or turning (OURS)
const DRIFT_TAIL := 4.0 ## seconds still after it (OURS)

## Round 786: one drift scenario of one effect (see --drift in the header).
func _probe_drift(path: String, kept: bool, label: String, particles: Pk2Reader, mode: String) -> void:
	var fx := EfpEffect.create(path, particles)
	if fx == null:
		return
	var drawn := {}
	for d in fx._draws:
		drawn[int(d[0])] = true
	for d in fx._links:
		drawn[int(d[0])] = true
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
	var dt := 1.0 / _fps
	_phys_acc = 0.0
	EfpEffect.tick_gate = _physics_effects and _physics > 0
	EfpEffect.tick_of = func(): return _ticks_done
	var speed := _speed if _speed > 0.0 else 50.0
	var lead := int(round(DRIFT_LEAD * _fps))
	var event := 0 if mode == "stand" or mode == "jump" or mode == "zone" else int(round(DRIFT_EVENT * _fps))
	var total := lead + event + int(round(DRIFT_TAIL * _fps))
	var still := 0.0
	var after := 0.0
	var past := 0
	var past_frames := 0
	var near := 0
	var last_past := -1
	var sim_frames := 0
	for i in range(total):
		if (mode == "jump" or mode == "zone") and i == lead:
			# `zone` (round 786): the frame's offset moves the effect whole
			# first (EfpEffect.shift_effects, READ CEFEffect::vslot_006).
			if mode == "zone":
				EfpEffect.shift_effects([fx], _frame)
			host.position += _jump
		# Round 786: the body moves on the game's physics ticks (--physics=N a
		# second; 0: every rendered frame), as World3D moves the player in
		# _physics_process; `zigzag` turns the walk 90 degrees every 0.5 s,
		# as a player's clicks do.
		var moving := (mode == "walk" or mode == "zigzag" or mode == "turn") and i >= lead and i < lead + event
		var ticks := 1
		var tick_dt := dt
		if _physics > 0:
			_phys_acc += dt
			tick_dt = 1.0 / float(_physics)
			ticks = int(floor(_phys_acc / tick_dt))
			_phys_acc -= float(ticks) * tick_dt
		for k in range(ticks):
			if not moving:
				break
			if mode == "walk":
				host.position.x += speed * tick_dt
			elif mode == "zigzag":
				var leg := int(floor(float(i - lead) * dt / 0.5)) % 4
				var dir := [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)][leg] as Vector3
				host.position += dir * speed * tick_dt
				host.rotation.y = atan2(dir.x, dir.z)
			elif mode == "turn":
				host.rotation.y += deg_to_rad(_turn) * tick_dt
		# --physics-effects: the game's tick gate (EfpEffect.tick_gate), the
		# effect placed once per physics tick, on this run's own tick count.
		_ticks_done += ticks
		fx._process(dt)
		if ended[0]:
			break
		if fx._pending_steps <= 0:
			continue
		sim_frames += fx._pending_steps
		# Where the drawn particles are in the world against where the
		# effect is placed now (the host's origin: no bone, no offset).
		var at := host.global_position
		var anchor := fx.global_transform
		var mx := 0.0
		var n_past := 0
		for p in fx.sim.particle_list():
			if not drawn.has(p.tpl):
				continue
			var dist := (anchor * p.pos - at).length()
			mx = maxf(mx, dist)
			if i >= lead and dist > still + DRIFT_TOL:
				n_past += 1
				if dist < DRIFT_NEAR:
					near += 1
		if i < lead:
			still = maxf(still, mx)
		else:
			after = maxf(after, mx)
			if n_past > 0:
				past += n_past
				past_frames += 1
				last_past = sim_frames
	var d: Dictionary = _dt.get(mode, {"runs": 0, "off": 0, "worst": 0.0, "pframes": 0, "worst_path": ""})
	d["runs"] += 1
	d["near_runs"] = int(d.get("near_runs", 0)) + (1 if near > 0 else 0)
	d["near"] = int(d.get("near", 0)) + near
	if past > 0:
		d["off"] += 1
		d["pframes"] += past
		if after - still > float(d["worst"]):
			d["worst"] = after - still
			d["worst_path"] = path
	_dt[mode] = d
	if not _quiet:
		print("DRIFT %s %s kept %s: still %.1f after %.1f (+%.1f) past %d particle-frames in %d frames (near %d), last at frame %d of %d (%s)" % [
			mode, path, kept, still, after, maxf(after - still, 0.0), past, past_frames, near, last_past, sim_frames, label])
	fx.stop()
	host.free()
