extends SceneTree

## Round 761 (round 759's review F1, its probe kept): EquipFx's effect masters
## over the real effect files -- every distinct efp of Media.pk2's itemrare /
## itemoptionefp particle rows, the first --n from --offset -- stepped as the
## main thread steps them (each sim's advance in turn, the global cap first
## come first served in the list's order) and through EfpSimBatch.run (the
## pool), with the same seeds (1000 + i, kept as a master is), and compared
## frame by frame: every sim's particle count, spawned and dropped. Prints the
## cap's use, the pool's waits, and the time of each mode. Reads the user's
## archives at run time; prints statistics only.
##   godot --headless --path <client> --script res://tools/efp_cap_probe.gd -- \
##     --pk2dir=/opt/sro-files/client --n=33 --frames=600 --fps=15
## OPENSRO_QA_EFP_CAP=<n> (0: none) runs both modes under another cap.

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _initialize() -> void:
	var dir := _arg("--pk2dir", "/opt/sro-files/client")
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	var files := _arg("--files", "").split(",", false)
	if files.is_empty():
		var media := Pk2Reader.open(dir.path_join("Media.pk2"))
		var tables := ItemGlowTables.for_archive(media)
		var seen := {}
		for call in tables._particle_calls:
			for pair in call:
				var f := String((pair[1] as ItemGlowTables.ParticleRow).efp).to_lower()
				if not seen.has(f):
					seen[f] = true
					files.append(f)
		print("CAPPROBE %d distinct EquipFx files in the tables" % files.size())
		var n := int(_arg("--n", "33"))
		var off := int(_arg("--offset", "0"))
		files = files.slice(off, off + n)
	var frames := int(_arg("--frames", "600"))
	var fps := float(_arg("--fps", "15"))
	var copies := int(_arg("--copies", "1"))
	var delta := 1.0 / fps
	var tpls: Array = []
	for f in files:
		var t := EfpEffect.template_for(f, particles)
		if t != null:
			for c in range(copies):
				tpls.append([f, t])
	print("CAPPROBE %d sims, %d frames at %.1f fps, cap %d" % [tpls.size(), frames, fps, EfpSim.cap_total])
	var hist := {}
	for mode in ["main", "pool"]:
		EfpSim.live_total = 0
		var fx: Array = []
		for i in range(tpls.size()):
			var e := EfpEffect.new()
			e.sim = EfpSim.new(tpls[i][1], 1000 + i)
			e.sim.keep = true
			fx.append(e)
		var usec := 0
		var tot_sum := 0
		var tot_max := 0
		var diff_frames := 0
		var diff_sims := 0
		var first_diff := -1
		var at_cap := 0
		var waits := 0
		var wait_usec := 0
		var misses := 0
		var helpers := 0
		var bu := 0
		var su := 0
		for fr in range(frames):
			var t0 := Time.get_ticks_usec()
			if mode == "main":
				for e in fx:
					(e as EfpEffect).step_sim(delta)
			else:
				EfpSimBatch.run(fx, delta)
			usec += Time.get_ticks_usec() - t0
			if mode == "pool":
				waits += int(EfpSimBatch.last.get("waits", 0))
				wait_usec += int(EfpSimBatch.last.get("wait_usec", 0))
				misses += int(EfpSimBatch.last.get("misses", 0))
				helpers += int(EfpSimBatch.last.get("by_helpers", 0))
				bu += int(EfpSimBatch.last.get("bounds_usec", 0))
				su += int(EfpSimBatch.last.get("sim_usec", 0))
			var counts := PackedInt32Array()
			var tot := 0
			for e in fx:
				var s: EfpSim = (e as EfpEffect).sim
				counts.append(s.particles.size())
				counts.append(s.spawned)
				counts.append(s.dropped)
				tot += s.particles.size()
			tot_sum += tot
			tot_max = maxi(tot_max, tot)
			if EfpSim.live_total >= EfpSim.limit_for(false):
				at_cap += 1
			if mode == "main":
				hist[fr] = counts
			else:
				var a: PackedInt32Array = hist[fr]
				var d := 0
				for i in range(0, counts.size(), 3):
					if counts[i] != a[i] or counts[i + 1] != a[i + 1] or counts[i + 2] != a[i + 2]:
						d += 1
				if d > 0:
					diff_frames += 1
					diff_sims += d
					if first_diff < 0:
						first_diff = fr
		var dropped := 0
		var zero := 0
		for e in fx:
			dropped += (e as EfpEffect).sim.dropped
			if (e as EfpEffect).sim.particles.is_empty():
				zero += 1
		print("CAPPROBE %s: %.1f ms (%.3f ms a frame), live_total %d, mean particles %.1f max %d, frames at the cap %d, dropped %d, sims empty at end %d%s" % [
			mode, usec / 1000.0, usec / 1000.0 / frames, EfpSim.live_total, float(tot_sum) / frames, tot_max, at_cap, dropped, zero,
			"" if mode == "main" else ", frames differing from main %d (first %d, sim-frames %d), waits %d (%.1f ms), by helpers %d, bound misses %d; thread ms: bounds %.1f, sims %.1f" % [
				diff_frames, first_diff, diff_sims, waits, wait_usec / 1000.0, helpers, misses, bu / 1000.0, su / 1000.0]])
		for e in fx:
			(e as EfpEffect).sim.clear()
			(e as Node).free()
	EfpSimBatch.reap_all()
	quit()
