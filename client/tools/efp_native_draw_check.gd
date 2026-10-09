extends SceneTree

## Round 763: what the RENDERER holds for a natively simulated master against
## a GDScript one -- run with a real rendering server (Forward+ through
## xwl_run.sh), not headless, whose MultiMeshes keep nothing to read back.
## For each real EquipFx file (round 761's set, the first --n) a GDScript
## effect and its native twin with the same seed, both shared-turn as EquipFx
## makes them, stepped --frames frames: the GDScript one draws through
## EfpEffect._update_draws (set_instance_transform / color / custom_data per
## particle), the native one through its batch's buffers
## (multimesh_set_buffer from Rust). Then, every frame, each draw node's
## MultiMesh is read back from the RenderingServer (multimesh_get_buffer,
## multimesh_get_visible_instances) and the two compared float for float over
## the visible instances: the GPU gets the same instance data, so the same
## pixels. Prints `PARITY OK` / `PARITY FAIL`.
##   xwl_run.sh godot --rendering-method forward_plus --path <client> --script res://tools/efp_native_draw_check.gd -- \
##     --pk2dir=/opt/sro-files/client --n=74 --frames=120

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _initialize() -> void:
	if not EfpSimNative.available():
		print("PARITY FAIL: no native simulation (%s)" % EfpSimNative.status)
		quit(1)
		return
	print("renderer: %s on %s" % [RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name()])
	var dir := _arg("--pk2dir", "/opt/sro-files/client")
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var tables := ItemGlowTables.for_archive(media)
	var files: Array = []
	for call in tables._particle_calls:
		for pair in call:
			var f := String((pair[1] as ItemGlowTables.ParticleRow).efp).to_lower()
			if not files.has(f):
				files.append(f)
	files = files.slice(0, int(_arg("--n", "74")))
	var frames := int(_arg("--frames", "120"))
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var mesh := BoxMesh.new()
	var gd: Array = []
	var nat: Array = []
	for i in files.size():
		var t := EfpEffect.template_for(files[i], particles)
		if t == null:
			continue
		for native in [false, true]:
			var e := EfpEffect.from_template(t, func(_p): return tex, func(_p): return mesh, 2000 + i)
			e.loop = true
			e.auto_free = false
			e.use_shared_turn()
			if native:
				e.use_native_sim(2000 + i)
				nat.append(e)
			else:
				gd.append(e)
			root.add_child(e)
			e.set_process(false) # stepped below, not by its own _process
	EfpSim.cap_total = 1 << 30 # no cap: each pair steps on its own, the same particles either way
	var nodes := 0
	var compared := 0
	var bad := ""
	var floats := 0
	for fr in frames:
		var delta := 1.0 / 20.0
		for i in gd.size():
			var g: EfpEffect = gd[i]
			var n: EfpEffect = nat[i]
			g.step_pre(delta)
			g.step_sim(delta)
			g.step_post()
			n.step_pre(delta)
			EfpSimBatch.run([n], delta)
			n.step_post()
		for i in gd.size():
			var g: EfpEffect = gd[i]
			var n: EfpEffect = nat[i]
			for k in g._draws.size():
				var grid: RID = (g._draws[k][1] as MultiMeshInstance3D).multimesh.get_rid()
				var nrid: RID = (n._draws[k][1] as MultiMeshInstance3D).multimesh.get_rid()
				var gv := (g._draws[k][1] as MultiMeshInstance3D).multimesh.visible_instance_count
				var nv := RenderingServer.multimesh_get_visible_instances(nrid)
				if fr == 0:
					nodes += 1
				if gv != nv:
					if bad == "":
						bad = "%s node %d frame %d: %d visible against %d" % [files[i], k, fr, nv, gv]
					continue
				if gv <= 0:
					continue
				var gb := RenderingServer.multimesh_get_buffer(grid)
				var nb := RenderingServer.multimesh_get_buffer(nrid)
				var m := gv * EfpSimNative.STRIDE
				if gb.size() < m or nb.size() < m:
					if bad == "":
						bad = "%s node %d frame %d: buffers %d / %d floats for %d" % [files[i], k, fr, nb.size(), gb.size(), m]
					continue
				compared += 1
				floats += m
				if gb.slice(0, m).to_byte_array() != nb.slice(0, m).to_byte_array() and bad == "":
					var a := gb.slice(0, m)
					var b := nb.slice(0, m)
					for j in m:
						if a[j] != b[j] or is_nan(a[j]) != is_nan(b[j]):
							bad = "%s node %d frame %d instance %d float %d: %.9g against %.9g" % [files[i], k, fr, j / EfpSimNative.STRIDE, j % EfpSimNative.STRIDE, b[j], a[j]]
							break
	print("NATIVEDRAW %d files, %d draw nodes, %d frames: %d node-frames read back from the renderer, %d floats, %s" % [
		gd.size(), nodes, frames, compared, floats, "all the same" if bad == "" else "first difference " + bad])
	print("PARITY OK" if bad == "" and compared > 0 else "PARITY FAIL")
	for e in gd + nat:
		(e as EfpEffect).sim.clear()
		(e as Node).queue_free()
	quit()
