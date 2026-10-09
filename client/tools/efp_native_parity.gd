extends SceneTree

## Round 763: EquipFx's masters simulated in Rust (EfpSimNative) against
## GDScript (EfpSim) on the REAL effect files -- every distinct efp of
## Media.pk2's itemrare / itemoptionefp particle rows (round 761's probe's
## set), the first --n from --offset, --copies of each -- with the same seeds
## (1000 + i), kept as a master is.
##
## Parity (the default): each frame the GDScript sims advance one after another
## (the main thread's order, the global cap first come first served) and the
## native batch steps its twins at every thread count in --threads; every sim's
## whole state is compared bit for bit (EfpNativeParity: every particle's
## position, velocity, rotations, scale, colour, UV, age, link; the emitters;
## the counters, the clock and the random state), and every --draw_every
## frames the MultiMesh buffers and the Link chains (stand-in textures and
## meshes, so every plate and mesh node draws; shared turn as EquipFx sets it)
## under a turned camera. Prints `PARITY OK` or `PARITY FAIL` (remote_godot.sh
## exits 1 on the latter).
##
## --time=1: the batch's time per frame instead, each mode on fresh sims: the
## GDScript main thread, the GDScript pool (EfpSimBatch's Job), and the
## native batch at each thread count (its draw buffers included).
##
##   godot --headless --path <client> --script res://tools/efp_native_parity.gd -- \
##     --pk2dir=/opt/sro-files/client --n=33 --frames=600 --fps=15 [--cap=2000] [--time=1]
## Reads the user's archives at run time; prints statistics only.

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

var _tex: Texture2D
var _mesh: Mesh

func _files(dir: String, particles: Pk2Reader) -> PackedStringArray:
	var files := _arg("--files", "").split(",", false)
	if not files.is_empty():
		return files
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var tables := ItemGlowTables.for_archive(media)
	var seen := {}
	for call in tables._particle_calls:
		for pair in call:
			var f := String((pair[1] as ItemGlowTables.ParticleRow).efp).to_lower()
			if not seen.has(f):
				seen[f] = true
				files.append(f)
	print("NATIVEPARITY %d distinct EquipFx files in the tables" % files.size())
	var n := int(_arg("--n", "33"))
	var off := int(_arg("--offset", "0"))
	return files.slice(off, off + n)

## An effect for template `t` as EquipFx makes a master: stand-in assets (the
## draws depend on the particles alone), kept, shared turn; natively when
## `native`.
func _effect(t: EfpSim.Template, seed_value: int, native: bool) -> EfpEffect:
	var e := EfpEffect.from_template(t, func(_p): return _tex, func(_p): return _mesh, seed_value)
	e.loop = true
	e.auto_free = false
	e.use_shared_turn()
	if native and not e.use_native_sim(seed_value):
		push_error("not simulated natively: %s" % t.native_error)
	return e

func _free(fx: Array) -> void:
	for e in fx:
		(e as EfpEffect).sim.clear()
		(e as Node).free()

func _initialize() -> void:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	_tex = ImageTexture.create_from_image(img)
	_mesh = BoxMesh.new()
	if not EfpSimNative.available():
		print("PARITY FAIL: no native simulation (%s)" % EfpSimNative.status)
		quit(1)
		return
	var dir := _arg("--pk2dir", "/opt/sro-files/client")
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	var files := _files(dir, particles)
	var copies := int(_arg("--copies", "1"))
	var cap := int(_arg("--cap", "-1"))
	if cap >= 0:
		EfpSim.cap_total = cap if cap > 0 else 1 << 30
	var tpls: Array = []
	var nodes := 0
	var links := 0
	for f in files:
		var t := EfpEffect.template_for(f, particles)
		if t == null:
			continue
		if EfpSimNative.native_template(t) == null:
			print("PARITY FAIL: %s does not pack: %s" % [f, t.native_error])
		for tp in t.tpls:
			var mode := tp.node.render_mode()
			if mode == EfpEffect.PLATE or mode == EfpEffect.MESH:
				nodes += 1
			elif EfpEffect.LINK_MODES.has(mode):
				links += 1
		for c in range(copies):
			tpls.append([f, t])
	var frames := int(_arg("--frames", "600"))
	var fps := float(_arg("--fps", "15"))
	print("NATIVEPARITY %d sims (%d files: %d plate / mesh nodes, %d Link nodes), %d frames at %.1f fps, cap %d" % [
		tpls.size(), tpls.size() / maxi(copies, 1), nodes, links, frames, fps, EfpSim.cap_total])
	if _arg("--time", "0") == "1":
		_time(tpls, frames, fps)
	else:
		_parity(tpls, frames, fps)
	EfpSimBatch.reap_all()
	quit()

func _threads() -> Array:
	var cores := OS.get_processor_count()
	var out: Array = []
	for s in _arg("--threads", "1,2,4,all").split(","):
		var n := cores if s == "all" else int(s)
		if n >= 1 and n <= cores and not out.has(n):
			out.append(n)
	return out

func _parity(tpls: Array, frames: int, fps: float) -> void:
	var delta := 1.0 / fps
	var draw_every := int(_arg("--draw_every", "10"))
	var runs := _threads()
	EfpSimNative.configure(OS.get_processor_count())
	var gd: Array = []
	for i in tpls.size():
		gd.append(_effect(tpls[i][1], 1000 + i, false))
	var nat: Array = []
	var nat_live: Array = []
	for r in runs:
		var group: Array = []
		for i in tpls.size():
			group.append(_effect(tpls[i][1], 1000 + i, true))
		nat.append(group)
		nat_live.append(0)
	var gd_live := 0
	var compared := 0
	var draws_compared := 0
	var bad := 0
	var first := ""
	var tot_sum := 0
	var tot_max := 0
	var at_cap := 0
	var misses := 0
	var waits := 0
	var chains := 0
	for fr in frames:
		var d := 0.3 if fr % 211 == 210 else delta
		EfpSim.live_total = gd_live
		for e in gd:
			(e as EfpEffect).step_sim(d)
		gd_live = EfpSim.live_total
		tot_sum += gd_live
		tot_max = maxi(tot_max, gd_live)
		if gd_live >= EfpSim.limit_for(false) - 2:
			at_cap += 1
		var want: Array = []
		for e in gd:
			want.append(EfpNativeParity.gd_dump((e as EfpEffect).sim))
		var draw_now := draw_every > 0 and fr % draw_every == 0
		var cam := Basis(Vector3(0.3, 1, 0.2).normalized(), 0.01 * fr) * Basis(Vector3(1, 0, 0), -0.25)
		var want_draws: Array = []
		var want_chains: Array = []
		var want_strips: Array = []
		if draw_now:
			for e in gd:
				want_draws.append(EfpNativeParity.gd_draws(e, (e as EfpEffect).sim, cam))
				var wc := EfpNativeParity.gd_chains(e, (e as EfpEffect).sim)
				chains += (wc["meta"] as PackedInt32Array).size() / 2
				want_chains.append(wc)
				want_strips.append(EfpNativeParity.gd_strips(e, (e as EfpEffect).sim))
		for r in runs.size():
			EfpSimNative.helpers = int(runs[r]) - 1
			EfpSim.live_total = nat_live[r]
			EfpSimBatch.run(nat[r], d)
			nat_live[r] = EfpSim.live_total
			misses += int(EfpSimBatch.last.get("misses", 0))
			waits += int(EfpSimBatch.last.get("waits", 0))
			for i in tpls.size():
				var ns := (nat[r][i] as EfpEffect).sim as EfpSimNative
				var why := EfpNativeParity.compare(want[i], ns.dump())
				if why == "" and draw_now:
					ns.build_outputs(cam)
					why = EfpNativeParity.compare_draws(want_draws[i], ns.take_draws())
					if why == "":
						why = EfpNativeParity.compare_chains(want_chains[i], ns.take_chains())
					if why == "":
						why = EfpNativeParity.compare_strips(want_strips[i], ns.take_strips())
					draws_compared += 1
				compared += 1
				if why != "":
					bad += 1
					if first == "":
						first = "frame %d, %d thread(s), sim %d (%s): %s" % [fr, runs[r], i, tpls[i][0], why]
			if nat_live[r] != gd_live:
				bad += 1
				if first == "":
					first = "frame %d, %d thread(s): live_total %d against %d" % [fr, runs[r], nat_live[r], gd_live]
	var dropped := 0
	for e in gd:
		dropped += (e as EfpEffect).sim.dropped
	print("NATIVEPARITY %d sim-frames compared bit for bit (%d with their draws, chains and strips, %d chains) at %s thread(s): %d differ%s" % [
		compared, draws_compared, chains, str(runs), bad, "" if first == "" else ", first " + first])
	print("NATIVEPARITY particles: mean %.1f, max %d, frames at the cap %d of %d, dropped %d; bound misses %d, waits %d" % [
		float(tot_sum) / frames, tot_max, at_cap, frames, dropped, misses, waits])
	print("NATIVEPARITY singular bases inverted (left unchanged, the editor build's rule): %d" % EfpSimNative.singular_inverses())
	print("PARITY OK" if bad == 0 and misses == 0 else "PARITY FAIL")
	_free(gd)
	for group in nat:
		_free(group)
	EfpSim.live_total = 0
	EfpSimNative.configure()

func _time(tpls: Array, frames: int, fps: float) -> void:
	var delta := 1.0 / fps
	var modes: Array = ["gd_main", "gd_pool"]
	for n in _threads():
		modes.append("native_%d" % n)
	EfpSimNative.configure(OS.get_processor_count())
	for mode in modes:
		EfpSim.live_total = 0
		var native := String(mode).begins_with("native")
		if native:
			EfpSimNative.helpers = int(String(mode).get_slice("_", 1)) - 1
		var fx: Array = []
		for i in tpls.size():
			fx.append(_effect(tpls[i][1], 1000 + i, native))
		var usec := 0
		var tot := 0
		var worst := 0
		for fr in frames:
			var t0 := Time.get_ticks_usec()
			if mode == "gd_main":
				for e in fx:
					(e as EfpEffect).step_sim(delta)
			else:
				EfpSimBatch.run(fx, delta)
			var dt := Time.get_ticks_usec() - t0
			usec += dt
			worst = maxi(worst, dt)
			tot += EfpSim.live_total
		print("NATIVEPARITY time %s: %.3f ms a frame (worst %.2f), mean particles %.1f" % [
			mode, usec / 1000.0 / frames, worst / 1000.0, float(tot) / frames])
		_free(fx)
	EfpSim.live_total = 0
	EfpSimNative.configure()
