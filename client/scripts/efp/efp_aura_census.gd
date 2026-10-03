extends SceneTree

## Round 623: does every kept (AT_LOOP / AT_STOP) effect stay on screen?
## Runs each .efp that skilleffect.txt's skilleffectset names with a kept
## ActType through a real EfpEffect (the node's own _process, so the loop and
## restart logic under test is the shipped one) for --seconds of 50 ms frames
## and counts, every frame, the particles alive on DRAWN nodes. After the
## first frame that draws, a frame drawing nothing is a GAP: the aura blinked
## out. Reads the player's archives at runtime and prints only counts and
## paths.
##
##   godot4 --headless --path client --script res://scripts/efp/efp_aura_census.gd -- \
##       --pk2dir=/opt/sro-files/client [--seconds=30] [--phase=ACT_L|READY|WAIT|all]
##       [--only=<substring>] [--trace]
##
## --trace prints every frame of every matching file: "frame live drawn
## lit" (lit: drawn particles whose colour is not fully transparent black).
## Exits 0 when no file gaps, 1 otherwise.
##
## --oneshot takes the rows with a one-shot ActType (not AT_LOOP / AT_STOP)
## of the phase instead, plays each once (not kept) and reports how many
## frames each lasts: the regression check for hits and ACT_S bursts.

var _seconds := 30.0
var _only := ""
var _trace := false
var _phase := "ACT_L"
var _oneshot := false
var _oneshot_frames: Array = []

func _init() -> void:
	var dir := OS.get_environment("OPENSRO_PK2_DIR")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2dir="):
			dir = a.substr(9)
		elif a.begins_with("--seconds="):
			_seconds = float(a.substr(10))
		elif a.begins_with("--only="):
			_only = a.substr(7).to_lower()
		elif a.begins_with("--phase="):
			_phase = a.substr(8)
		elif a == "--oneshot":
			_oneshot = true
		elif a == "--trace":
			_trace = true
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	if media == null or particles == null:
		print("cannot open Media.pk2 / Particles.pk2 under %s" % dir)
		quit(2)
		return
	var entry := ObjectLoader.find_file(media, SkillEffects.SKILLEFFECT_PATH)
	if entry == null:
		print("no skilleffect.txt")
		quit(2)
		return
	var rows := SkillEffects.parse_rows(media.read_file(entry))
	var want := {}
	for id in rows:
		for r in rows[id]:
			var act := int(r["act"])
			var kept := act == SkillEffects.AT_LOOP or act == SkillEffects.AT_STOP
			if kept == _oneshot:
				continue
			var ani := int(r["ani"])
			var ok := false
			match _phase:
				"ACT_L":
					ok = ani == SkillAudio.ACT_L
				"READY":
					ok = ani == SkillAudio.READY
				"WAIT":
					ok = ani == SkillAudio.WAIT
				"ACT_S":
					ok = ani == SkillAudio.ACT_S
				"SHOT":
					ok = ani == SkillAudio.SHOT
				_:
					ok = true
			var p := String(r["path"]).to_lower()
			if ok and (_only == "" or p.find(_only) >= 0):
				want[p] = true
	var paths := want.keys()
	paths.sort()
	var frames := int(round(_seconds / EfpSim.FRAME_SEC))
	var n_ok := 0
	var n_gap := 0
	var n_none := 0
	var n_fail := 0
	for p in paths:
		var fx := EfpEffect.create(p, particles)
		if fx == null:
			n_fail += 1
			print("FAIL-LOAD %s (%s)" % [p, EfpEffect.last_error])
			continue
		var drawn := {}
		for d in fx._draws:
			drawn[int(d[0])] = true
		for d in fx._links:
			drawn[int(d[0])] = true
		if drawn.is_empty():
			n_none += 1
			print("NODRAW %s" % p)
			fx.free()
			continue
		if _trace:
			for tp in fx.sim.template.tpls:
				print("NODE %s #%d parent %d %s frames %d life %d emit %s drawn %s" % [p, tp.index,
					tp.parent, tp.node.name, tp.frames, tp.life, tp.emit, drawn.has(tp.index)])
		if _oneshot:
			var n_frames := _run_once(fx, frames)
			_oneshot_frames.append(n_frames)
			print("ONCE %s frames=%d" % [p, n_frames])
			fx.free()
			continue
		fx.loop = true
		fx.auto_free = false
		fx.reserved = true
		var started := -1
		var gaps := 0
		var gap_frames := 0
		var longest := 0
		var run := 0
		var first_gap := -1
		var min_after := 1 << 30
		var lit_zero := 0
		for f in range(frames):
			fx._process(EfpSim.FRAME_SEC)
			var live := fx.sim.particles.size()
			var dn := 0
			var lit := 0
			for q in fx.sim.particles:
				if drawn.has(q.tpl):
					dn += 1
					if (q.color & 0xFF000000) != 0 and (q.color & 0xFFFFFF) != 0:
						lit += 1
			if _trace:
				print("TRACE %s %d %d %d %d" % [p, f, live, dn, lit])
			if started < 0:
				if dn > 0:
					started = f
				continue
			min_after = mini(min_after, dn)
			if lit == 0:
				lit_zero += 1
			if dn == 0:
				gap_frames += 1
				run += 1
				if run == 1:
					gaps += 1
					if first_gap < 0:
						first_gap = f
				longest = maxi(longest, run)
			else:
				run = 0
		var t: EfpSim.Template = fx.sim.template
		var root_emit = t.tpls[0].emit if not t.tpls.is_empty() else null
		if gaps == 0 and started >= 0:
			n_ok += 1
			print("OK %s min_drawn=%d unlit_frames=%d root_emit=%s" % [p, min_after, lit_zero, root_emit])
		else:
			n_gap += 1
			print("GAP %s starts=%d gaps=%d gap_frames=%d longest=%d first_gap_frame=%d root_emit=%s" % [
				p, started, gaps, gap_frames, longest, first_gap, root_emit])
		fx.stop()
		fx.free()
	if _oneshot:
		var fs := _oneshot_frames.duplicate()
		fs.sort()
		var ended := 0
		var total := 0
		for f in fs:
			if f < frames:
				ended += 1
				total += f
		print("one-shot census (%s, %.0f s): %d files; ended %d (mean %.1f frames, median %d), still running %d, draw nothing %d, did not load %d" % [
			_phase, _seconds, paths.size(), ended, float(total) / maxi(ended, 1),
			fs[fs.size() / 2] if not fs.is_empty() else 0, fs.size() - ended, n_none, n_fail])
		media.close()
		particles.close()
		quit(0)
		return
	print("aura census (%s, %.0f s): %d files; continuous %d, gapped %d, draw nothing %d, did not load %d" % [
		_phase, _seconds, paths.size(), n_ok, n_gap, n_none, n_fail])
	media.close()
	particles.close()
	quit(0 if n_gap == 0 else 1)

## Plays a one-shot effect until it ends: the frames it lasted (`limit` if
## it never ended).
func _run_once(fx: EfpEffect, limit: int) -> int:
	fx.auto_free = false
	var ended := [false]
	fx.effect_finished.connect(func(): ended[0] = true)
	for f in range(limit):
		fx._process(EfpSim.FRAME_SEC)
		if ended[0]:
			fx.sim.clear()
			return f + 1
	fx.sim.clear()
	return limit
