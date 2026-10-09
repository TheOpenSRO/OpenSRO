extends SceneTree

## Round 763: EfpSimNative (EfpSim's stepping in Rust) holds the particles
## EfpSim holds, bit for bit, on synthetic effects built here -- never game
## data -- that run every command family, every follow level, the kept
## effect, the link variants, the scale graph and NeverExtinct / Loop / Extinct
## lives:
## - one effect at a time, the global cap binding or not, hitches past the
##   10-step catch-up, placements and re-centring (set_origin / shift);
## - EfpSimBatch's ordered cap at 8 / 33 / 60 effects with the cap binding, at
##   1, 2, 4 and every core: equal to the main thread's order, frame by frame;
## - the MultiMesh buffers and Link chains it builds, against EfpEffect's own
##   _update_draws arithmetic and EfpLinks.gather_from;
## - live_total kept through restart and clear.
## Without the library it checks the fallback (EquipFx's masters stay EfpSim)
## and the packer, and passes. The real files: client/tools/efp_native_parity.gd.
##   godot4 --headless --path client --script res://scripts/efp/efp_native_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _cmd(name: String, value = null, space: int = 0, start: float = 0.0, step: float = 1.0, end: float = 0.0) -> EfpReader.EfpCommand:
	var c := EfpReader.EfpCommand.new()
	c.name = name
	c.value = value
	c.space = space
	c.time_flags = 0
	c.start = start
	c.step = step
	c.end = end
	return c

func _emit(delay: int, duration: int, interval: int, count: int, per: float) -> EfpReader.EfpCommand:
	return _cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": delay, "duration": duration,
		"interval": interval, "max_live": count, "per_trigger": per})

func _node(name: String, frames: int, life: String, emit: EfpReader.EfpCommand, cmds: Array = [], kids: Array = [],
		flags: Dictionary = {}, render: String = "RenderNone", view: String = "ViewNone") -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = name
	n.frames = frames
	n.extinct = _cmd(life)
	if emit != null:
		n.emit.append(emit)
	n.view = _cmd(view)
	n.render = _cmd(render)
	n.flags = flags
	if render != "RenderNone":
		var ref := EfpReader.EfpMeshRef.new()
		ref.mesh = "test\\mesh.bms" if render == "RenderMesh" else ""
		ref.textures = PackedStringArray(["test\\tex.ddj"])
		n.meshes.append(ref)
	for c in cmds:
		n.commands.append(c)
	for k in kids:
		n.children.append(k)
	return n

## A D3D row-major 4x4: a turn of `a` radians about `axis`, scaled by `s`.
func _mat(axis: Vector3, a: float, s: float = 1.0) -> PackedFloat32Array:
	var b := Basis(axis.normalized(), a).scaled(Vector3.ONE * s)
	return PackedFloat32Array([b.x.x, b.x.y, b.x.z, 0, b.y.x, b.y.y, b.y.z, 0, b.z.x, b.z.y, b.z.z, 0, 0, 0, 0, 1])

func _v(v: Vector3) -> Dictionary:
	return {"type": "Vector", "value": v}

func _cone(b: Vector3) -> Dictionary:
	return {"type": "AngleVector1", "a": Vector3(1, 2, 30), "b": b}

func _matv(m: PackedFloat32Array) -> Dictionary:
	return {"type": "Matrix", "matrix": m}

## The rich effect: a looping holder with rotations, a rotation velocity, shape
## turns, scale and colour keys; sparks that follow it on every level, run
## every position / velocity / force family in each space, the link variants,
## a texture slide and a random scale from a graph; NeverExtinct grandchildren
## with a negative u3 and BAN keys; children that die at once.
func _rich(k: int, render: bool = false) -> EfpSim.Template:
	var v := float(k % 5)
	var scales := PackedVector3Array()
	var colors := PackedInt64Array()
	for i in 30:
		scales.append(Vector3(1.0 + 0.05 * i, 0.5 + 0.02 * i * v, 1.0))
		colors.append(0x80FF0000 | (i * 8) << 8 | (255 - i * 5))
	var slides: Array = []
	for i in 25:
		slides.append(Vector4(0.25 * (i % 4), 0.25 * (i / 4 % 4), 0.25, 0.25))
	var bans := PackedVector3Array()
	var banr: Array = []
	for i in 8:
		bans.append(Vector3(0.1 * i, -0.05 * i, 0.02 * i * i))
		banr.append(_mat(Vector3(0.2, 1, 0.1), 0.15 * i))
	var gk := _node("grand", 1, "NeverExtinct", _emit(0, 6 + k % 3, 2, 3, 1.0), [
		_cmd("SetPosition", _v(Vector3(0.3, 0, 0.1)), 5),
		_cmd("SetBANPos", {"type": "FrameBANPosition", "head": 0.0, "positions": bans}, 1, 0.0, 1.0, 7.0),
		_cmd("SetBANRot", {"type": "FrameBANRotation", "head": 0.0, "matrices": banr}, 2, 0.0, 1.0, 7.0),
	], [], {"b0": 1, "b1": 1, "u2": 2, "u3": 0xFFFFFFFF, "u4": 0, "u6": 2},
		"RenderPlate" if render else "RenderNone", "ViewBillboard")
	var spark := _node("spark", 25, "NormalTimeExtinct", _emit(2, 100000, 1, 30 + k % 7, 1.5 + 0.25 * v), [
		_cmd("SetConePos", _cone(Vector3(0.5, 2.0, 1.2)), 4),
		_cmd("SetVelocity", _v(Vector3(0.01, 0.05, -0.02)), 2),
		_cmd("Force", _v(Vector3(0, -0.004, 0.001)), 1, 1.0, 5.0, 24.0),
		_cmd("ConeForce", _cone(Vector3(0.001, 0.01, 0.6)), 0, 2.0, 7.0, 24.0),
		_cmd("Attraction", {"type": "float", "value": -0.02}, 0, 4.0, 4.0, 20.0),
		_cmd("Attraction", {"type": "float", "value": 0.01}, 1, 5.0, 4.0, 20.0),
		_cmd("SetSpherePos", _v(Vector3(0.5, 0.25, 1.0)), 0, 3.0),
		_cmd("SetSpherePos", _v(Vector3(2, 2, 2)), 1, 6.0),
		_cmd("SetSpherePos", _v(Vector3(1, 1, 1)), 2, 9.0),
		_cmd("SetPosition", _v(Vector3(0, 0.2, 0)), 7, 12.0),
		_cmd("SetPosition", _v(Vector3(0.1, 0, 0)), 9, 15.0),
		_cmd("SetConeVel", _cone(Vector3(0.02, 0.08, 0.9)), 3, 10.0),
		_cmd("SetRotation", _matv(_mat(Vector3(1, 0, 0), 0.4)), 3, 11.0),
		_cmd("TextureSlide", {"type": "FrameTextureSlide", "head": Vector3.ZERO, "keys": slides}, 0, 0.0, 1.0, 24.0),
		_cmd("SetGraphRandomScale", {"type": "BlendScaleGraphPointer", "value": 0}, 0, 1.0),
	], [gk], {"b0": 1, "b1": 1, "u2": 1, "u3": 1, "u4": 1, "u6": 1},
		"RenderPlate" if render else "RenderNone", "ViewYBillboard" if k % 2 == 0 else "ViewVBillboard")
	spark.vars.append({"type": "BlendScaleGraph", "value": {"type": "BlendScaleGraph", "a": 0.1, "b": 0.9,
		"times": PackedFloat32Array([0.0, 0.3, 0.6, 1.0]), "scales": PackedVector3Array([Vector3(1, 1, 1), Vector3(2, 0.5, 1), Vector3(0.5, 3, 2), Vector3(1, 1, 4)])}})
	var gone := _node("gone", 0, "NeverExtinct", _emit(0, 3, 1, 2, 1.0), [], [], {"u6": 1})
	var trail := _node("trail", 18, "NormalTimeExtinct", _emit(0, 100000, 1, 20, 1.0), [
		_cmd("SetConeVel", _cone(Vector3(0.05, 0.1, 0.3)), 0),
	], [], {"u6": 0}, "RenderLinkPipe" if render else "RenderNone")
	var ribbon := _node("ribbon", 14, "NormalTimeExtinct", _emit(0, 100000, 1, 14, 1.0), [
		_cmd("SetRotation", _matv(_mat(Vector3(0, 0, 1), 0.7)), 1),
		_cmd("SetVelocity", _v(Vector3(0, 0.03, 0)), 1),
	], [], {"b0": 1, "u3": 1, "u6": 1}, "RenderLinkObj" if render else "RenderNone")
	var root := _node("root", 30, "NormalTimeLoop", _emit(0, 100000, 4, 6, 2.0), [
		_cmd("SetRotation", _matv(_mat(Vector3(0, 1, 0), 0.3 + 0.1 * v)), 1, 0.0, 3.0, 29.0),
		_cmd("SetRVelocity", _matv(_mat(Vector3(0.3, 1, 0), 0.05)), 0),
		_cmd("SetShapeRot", _matv(_mat(Vector3(1, 1, 0), 0.5, 1.5)), 0),
		_cmd("SetShapeRotVel", _matv(_mat(Vector3(0, 0, 1), 0.1)), 0),
		_cmd("SetConeVel", _cone(Vector3(0.05, 0.2, 0.8)), 0),
		_cmd("SetGraphScale", {"type": "FrameScale", "frames": scales}, 0, 0.0, 1.0, 29.0),
		_cmd("SetGraphDiffuse", {"type": "FrameDiffuse", "colors": colors}, 0, 0.0, 1.0, 29.0),
	], [spark, gone, trail, ribbon], {"b0": 1, "b1": 1, "u6": 1},
		"RenderMesh" if render else "RenderNone", "ViewNone")
	return EfpSim.compile(root)

## The batch suite's simpler kinds (efp_sim_batch_test's), for volume.
func _simple(k: int, w: int) -> EfpSim.Template:
	var cone := _cmd("SetConePos", _cone(Vector3(2, 4, 1.0)))
	var vel := _cmd("SetConeVel", _cone(Vector3(0.2, 0.6, 2.0)))
	var v := k / 6
	match k % 6:
		0:
			return EfpSim.compile(_node("b", 40 + v % 7, "NormalTimeExtinct", _emit(0, 100000, 20, 200 * w, 60.0 * w), [cone, vel]))
		1:
			return EfpSim.compile(_node("s", 30 + v % 5, "NormalTimeExtinct", _emit(0, 100000, 1, (40 + v % 9) * w, 2.0 * w), [cone]))
		2:
			var child := _node("c", 15 + v % 4, "NormalTimeExtinct", _emit(0, 100000, 2, 20 * w, 4.0 * w), [cone, vel], [], {"u6": 1})
			return EfpSim.compile(_node("h", 20, "NormalTimeLoop", _emit(0, 1, 1, 3, 3.0), [], [child]))
		3:
			return EfpSim.compile(_node("d", 60, "NormalTimeLoop", _emit(5 + v % 3, 50, 3, 30 * w, 5.5 * w), [vel]))
		4:
			return EfpSim.compile(_node("f", 90, "NormalTimeExtinct", _emit(0, 100000, 1, 120 * w, 1.7 * w), [cone]))
		_:
			var spark := _node("p", 12, "NormalTimeExtinct", _emit(0, 100000, 6, 50 * w, 25.0 * w), [cone, vel], [], {"u6": 1})
			return EfpSim.compile(_node("q", 40, "NormalTimeExtinct", _emit(0, 100000, 10, 4, 2.0), [], [spark]))

func _template(k: int, w: int) -> EfpSim.Template:
	return _rich(k) if k % 4 == 1 else _simple(k, w)

# ---------------------------------------------------------------- one effect

## One effect both ways, `frames` frames: the deltas vary (a 0.7 s hitch
## steps 10 frames and clips the clock), the effect is placed and turned now
## and then (the follow pass) and re-centred; `held` particles of others are
## alive throughout (so the cap binds when it is high).
func _single(t: EfpSim.Template, seed_value: int, frames: int, held: int, label: String, move: bool) -> void:
	var gd := EfpSim.new(t, seed_value)
	var nat := EfpSimNative.new(t, seed_value)
	gd.keep = seed_value % 2 == 0
	nat.keep = gd.keep
	var gd_live := held
	var nat_live := held
	var first := ""
	var at := -1
	var most := 0
	for f in frames:
		var delta := 0.7 if f % 97 == 96 else (0.3 if f % 41 == 40 else 1.0 / (15.0 + f % 50))
		var pos := Vector3(sin(f * 0.1) * 5.0, 0.2 * float(f % 7), cos(f * 0.13) * 3.0)
		var rot := Basis(Vector3(0, 1, 0), 0.05 * f) * Basis(Vector3(1, 0, 0), 0.02 * (f % 11))
		EfpSim.live_total = gd_live
		if move and f % 3 == 0:
			gd.set_origin(pos, rot)
		if move and f % 50 == 49:
			gd.shift(Vector3(1.5, 0, -2))
		var gb := gd.growth_bounds(delta)
		gd.advance(delta)
		gd_live = EfpSim.live_total
		EfpSimNative.live_native = nat_live
		if move and f % 3 == 0:
			nat.set_origin(pos, rot)
		if move and f % 50 == 49:
			nat.shift(Vector3(1.5, 0, -2))
		var nb := nat.growth_bounds(delta)
		nat.advance(delta)
		nat_live = EfpSimNative.live_native
		most = maxi(most, gd.particles.size())
		var why := EfpNativeParity.compare(EfpNativeParity.gd_dump(gd), nat.dump())
		if why == "" and gb != nb:
			why = "growth_bounds %s against %s" % [str(nb), str(gb)]
		if why == "" and gd_live != nat_live:
			why = "live_total %d against %d" % [nat_live, gd_live]
		if why != "" and first == "":
			first = why
			at = f
	_check(first == "", "%s: %d frames, the same particles bit for bit (at most %d alive, %d dropped)%s" % [
		label, frames, most, gd.dropped, "" if first == "" else " -- frame %d: %s" % [at, first]])
	# restart and clear give back their particles to live_total
	EfpSim.live_total = gd_live
	gd.restart()
	var g1 := EfpSim.live_total
	EfpSimNative.live_native = nat_live
	nat.restart()
	_check(EfpSimNative.live_native == g1 and nat.count() == 0 and EfpNativeParity.compare(EfpNativeParity.gd_dump(gd), nat.dump()) == "",
		"%s: restart gives every particle back to its count (%d)" % [label, EfpSimNative.live_native])
	EfpSim.live_total = 0
	EfpSimNative.live_native = 0

func _singles() -> void:
	for k in 6:
		_single(_rich(k), 100 + k, 400, 0, "rich effect %d, no cap" % k, k % 2 == 0)
	_single(_rich(7), 207, 400, EfpSim.limit_for(false) - 40, "rich effect, the cap binding", true)
	for k in 6:
		_single(_simple(k, 3), 300 + k, 300, EfpSim.limit_for(false) - 150 if k % 2 == 0 else 0, "simple kind %d" % k, false)

# ---------------------------------------------------------------- the batch

func _effects(n: int, reserved: int, native: bool) -> Array:
	var fx: Array = []
	var w := 3 if n <= 8 else 1
	for i in range(n):
		var e := EfpEffect.new()
		var t := _template(i, w)
		e.sim = EfpSimNative.new(t, 1000 + i) if native else EfpSim.new(t, 1000 + i)
		e.sim.keep = true
		e.sim.reserved = i == reserved
		fx.append(e)
	return fx

## The main thread's order (each advanced in turn, the cap first come first
## served) against the native batch at `threads`.
func _batch(n: int, fps: float, frames: int, held: int, reserved: int, hitch: int, uncapped: bool = false) -> void:
	var gd := _effects(n, reserved, false)
	var cores := OS.get_processor_count()
	var runs: Array = []
	for th in [1, 2, 4, cores]:
		if th <= cores and not runs.has(th):
			runs.append(th)
	var nat: Array = []
	var nat_live: Array = []
	for th in runs:
		nat.append(_effects(n, reserved, true))
		nat_live.append(held)
	EfpSimNative.configure(cores)
	var gd_live := held
	var diffs := {}
	var first := {}
	var at_cap := 0
	var most_live := 0
	var waits := 0
	var misses := 0
	var helpers := 0
	for fr in frames:
		var delta := 0.3 if fr == hitch else 1.0 / fps
		EfpSim.live_total = gd_live
		for e in gd:
			(e as EfpEffect).step_sim(delta)
		gd_live = EfpSim.live_total
		most_live = maxi(most_live, gd_live)
		if gd_live >= EfpSim.limit_for(false) - 2:
			at_cap += 1
		var want: Array = []
		for e in gd:
			want.append(EfpNativeParity.gd_dump((e as EfpEffect).sim))
		for r in runs.size():
			# The pool sized once for the most; each run takes its share.
			EfpSimNative.helpers = int(runs[r]) - 1
			EfpSimNative.live_native = nat_live[r]
			EfpSimBatch.run(nat[r], delta)
			nat_live[r] = EfpSimNative.live_native
			waits += int(EfpSimBatch.last.get("waits", 0))
			misses += int(EfpSimBatch.last.get("misses", 0))
			helpers += int(EfpSimBatch.last.get("by_helpers", 0))
			var d := 0
			for i in n:
				var why := EfpNativeParity.compare(want[i], ((nat[r][i] as EfpEffect).sim as EfpSimNative).dump())
				if why != "":
					d += 1
					if not first.has(runs[r]):
						first[runs[r]] = "frame %d sim %d: %s" % [fr, i, why]
			if nat_live[r] != gd_live and not first.has(runs[r]):
				first[runs[r]] = "frame %d: live_total %d against %d" % [fr, nat_live[r], gd_live]
			if d > 0:
				diffs[runs[r]] = int(diffs.get(runs[r], 0)) + 1
	EfpSimNative.configure()
	for r in runs.size():
		_check(not diffs.has(runs[r]) and not first.has(runs[r]),
			"%d effects at %.0f fps%s, %d thread(s): %d frames, every particle the main thread's%s" % [
				n, fps, " uncapped" if uncapped else "", runs[r], frames, "" if not first.has(runs[r]) else " -- %d frames differ, first %s" % [int(diffs.get(runs[r], 0)), first[runs[r]]]])
	if uncapped:
		# USER DECISION 2026-10-09: natively there is no cap; the run holds far
		# more than the GDScript cap's 1,400, and with the limit unbounded the
		# ordered admission decides every spawn at once.
		_check(most_live > 1400 and waits == 0, "%d effects uncapped: up to %d particles alive (the GDScript cap: 1,400), %d spawns waited" % [n, most_live, waits])
	else:
		_check(at_cap * 3 >= frames or n <= 8, "%d effects: the cap binds (%d of %d frames at it)" % [n, at_cap, frames])
	_check(misses == 0, "%d effects: no change outside its published bounds (%d waits, %d stepped by helpers)" % [n, waits, helpers])
	for e in gd:
		(e as EfpEffect).sim.clear()
		(e as Node).free()
	for group in nat:
		for e in group:
			(e as EfpEffect).sim.clear()
			(e as Node).free()
	EfpSim.live_total = 0
	EfpSimNative.live_native = 0

## USER DECISION 2026-10-09: the native masters, uncapped, count apart: a
## GDScript effect (a skill, an aura) beside thousands of native particles
## keeps the GDScript cap's whole room, and theirs is not refused.
func _apart() -> void:
	var nat := _effects(60, -1, true)
	for f in 120:
		EfpSimBatch.run(nat, 1.0 / 20.0)
	var native_alive := EfpSimNative.live_native
	var g := EfpSim.new(_simple(1, 3), 9)
	var alone := EfpSim.new(_simple(1, 3), 9)
	var with_native := 0
	var by_itself := 0
	for f in 120:
		g.advance(1.0 / 20.0)
		with_native = g.particles.size()
	EfpSim.live_total = 0
	for f in 120:
		alone.advance(1.0 / 20.0)
		by_itself = alone.particles.size()
	_check(native_alive > EfpSim.limit_for(false) and EfpSim.live_total == by_itself and with_native == by_itself and g.dropped == alone.dropped,
		"%d native particles alive, uncapped; a GDScript effect beside them is the one alone (%d particles, %d dropped)" % [native_alive, with_native, g.dropped])
	for e in nat:
		(e as EfpEffect).sim.clear()
		(e as Node).free()
	g.clear()
	alone.clear()
	EfpSim.live_total = 0
	EfpSimNative.live_native = 0

## Round 763's review, L3: an emission far past MAX_PARTICLES is refused all at
## once, the same on both sides, and fast (one by one it was a loop of half a
## million a frame).
func _huge() -> void:
	var t := EfpSim.compile(_node("huge", 30, "NormalTimeExtinct", _emit(0, 100000, 1, 1000000, 500000.0),
		[_cmd("SetConePos", _cone(Vector3(1, 2, 0.5)))]))
	var t0 := Time.get_ticks_msec()
	_single(t, 41, 60, 0, "an emission of 500,000 a frame (folded refusals)", false)
	_check(Time.get_ticks_msec() - t0 < 20000, "... in %d ms (both sides)" % (Time.get_ticks_msec() - t0))

## Round 763's review, L5: a list mixing native masters and one the packer
## refuses (it stays EfpSim) is split: the native ones step in one native batch,
## the GDScript one in GDScript, each exactly as it steps alone.
func _mixed() -> void:
	var refused := _simple(1, 3)
	# A schedule longer than the node's frames: GDScript steps it as before
	# (it reads only ages below its length), the packer refuses it.
	refused.tpls[0].schedule.append([])
	var fx: Array = []
	var alone: Array = []
	var gd_alone := EfpEffect.new()
	gd_alone.sim = EfpSim.new(refused, 777)
	gd_alone.sim.keep = true
	for i in 6:
		var t := _template(i, 1)
		var e := EfpEffect.new()
		e.sim = EfpSim.new(t, 600 + i)
		e.sim.keep = true
		_check(e.use_native_sim(600 + i), "mixed: effect %d is native" % i)
		fx.append(e)
		var a := EfpEffect.new()
		a.sim = EfpSimNative.new(t, 600 + i)
		a.sim.keep = true
		alone.append(a)
		if i == 2:
			var g := EfpEffect.new()
			g.sim = EfpSim.new(refused, 777)
			g.sim.keep = true
			_check(not g.use_native_sim(777) and not (g.sim is EfpSimNative) and refused.native_error != "",
				"mixed: the packer refuses the tampered template (%s)" % refused.native_error)
			fx.append(g)
	var b0 := EfpSimNative.batches
	var same := true
	for f in 120:
		EfpSim.live_total = 0
		EfpSimNative.live_native = 0
		EfpSimBatch.run(fx, 1.0 / 25.0)
		var mixed_gd := EfpSim.live_total
		var mixed_native := EfpSimNative.live_native
		EfpSim.live_total = 0
		EfpSimNative.live_native = 0
		EfpSimBatch.run(alone, 1.0 / 25.0)
		gd_alone.step_sim(1.0 / 25.0)
		if mixed_gd != EfpSim.live_total or mixed_native != EfpSimNative.live_native:
			same = false
		var k := 0
		for e in fx:
			var s: EfpSim = (e as EfpEffect).sim
			var want: Dictionary
			if s is EfpSimNative:
				want = ((alone[k] as EfpEffect).sim as EfpSimNative).dump()
				k += 1
				if EfpNativeParity.compare(want, (s as EfpSimNative).dump()) != "":
					same = false
			elif EfpNativeParity.compare(EfpNativeParity.gd_dump(gd_alone.sim), EfpNativeParity.gd_dump(s)) != "":
				same = false
	_check(same and EfpSimNative.batches - b0 == 240,
		"mixed: 120 frames, the native effects through the native batch only (%d batches), the refused one in GDScript, each as it steps alone" % [EfpSimNative.batches - b0])
	for e in fx + alone + [gd_alone]:
		(e as EfpEffect).sim.clear()
		(e as Node).free()
	EfpSim.live_total = 0
	EfpSimNative.live_native = 0

## Round 763's review, M1: a step that panics, on the main thread or a pool
## thread. The batch returns (no hang), the native simulation goes off for the
## session, every effect of the batch carries on in GDScript, and nothing
## raises a script error. Last: it leaves the native simulation off.
func _panic() -> void:
	EfpSim.live_total = 0
	EfpSimNative.live_native = 0
	EfpSimNative.configure(4)
	EfpSimNative.pool_min_work = 0
	var fx := _effects(16, -1, true)
	for f in 20:
		EfpSimBatch.run(fx, 1.0 / 20.0)
	((fx[9] as EfpEffect).sim as EfpSimNative)._n.call("qa_panic_next_step")
	var t0 := Time.get_ticks_msec()
	EfpSimBatch.run(fx, 1.0 / 20.0)
	var took := Time.get_ticks_msec() - t0
	var all_gd := true
	for e in fx:
		if ((e as EfpEffect).sim as EfpSimNative).is_native():
			all_gd = false
	_check(took < 5000 and not EfpSimNative.available() and all_gd and EfpSimNative.status.contains("panic"),
		"a step that panics: the batch returned in %d ms, the native simulation is off (%s), every effect in GDScript" % [took, EfpSimNative.status])
	var before := 0
	for e in fx:
		before += (e as EfpEffect).sim.count()
	for f in 40:
		EfpSimBatch.run(fx, 1.0 / 20.0)
	var after := 0
	for e in fx:
		after += (e as EfpEffect).sim.particles.size()
	_check(after > 0 and EfpSim.live_total == after and EfpSimNative.live_native == 0,
		"... and they carry on in GDScript (%d particles after 40 frames, live_total %d, live_native %d)" % [after, EfpSim.live_total, EfpSimNative.live_native])
	var e2 := EfpEffect.new()
	e2.sim = EfpSim.new(_template(1, 1), 5)
	_check(not e2.use_native_sim(5), "... and a master made after it stays EfpSim")
	e2.free()
	for e in fx:
		(e as EfpEffect).sim.clear()
		(e as Node).free()
	EfpSim.live_total = 0
	EfpSimNative.live_native = 0

# ---------------------------------------------------------------- the draws

func _loaders() -> Array:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var mesh := BoxMesh.new()
	return [func(_p: String): return tex, func(_p: String): return mesh]

## The MultiMesh buffers and the Link chains, for effects shared-turn or not,
## under a turned camera.
func _draws() -> void:
	var ld := _loaders()
	var bad := ""
	var nodes := 0
	var chains := 0
	var strips := 0
	var compared := 0
	for k in 4:
		var t := _rich(k, true)
		var g := EfpEffect.from_template(t, ld[0], ld[1], 500 + k)
		var n := EfpEffect.from_template(t, ld[0], ld[1], 500 + k)
		if k % 2 == 1:
			g.use_shared_turn()
			n.use_shared_turn()
		g.sim.keep = true
		n.sim.keep = true
		if not n.use_native_sim(500 + k):
			bad = "use_native_sim refused a synthetic effect: %s" % t.native_error
			break
		nodes += g._draws.size()
		for f in 120:
			var cam := Basis(Vector3(0.2, 1, 0.1).normalized(), 0.03 * f) * Basis(Vector3(1, 0, 0), -0.3)
			g.sim.advance(1.0 / 20.0)
			var ns := n.sim as EfpSimNative
			ns.advance(1.0 / 20.0)
			ns.build_outputs(cam)
			var why := EfpNativeParity.compare_draws(EfpNativeParity.gd_draws(g, g.sim, cam), ns.take_draws())
			if why == "":
				var wc := EfpNativeParity.gd_chains(g, g.sim)
				chains += (wc["meta"] as PackedInt32Array).size() / 2
				why = EfpNativeParity.compare_chains(wc, ns.take_chains())
			if why == "":
				var st := ns.take_strips()
				for x in st:
					if x != null:
						strips += 1
				why = EfpNativeParity.compare_strips(EfpNativeParity.gd_strips(g, g.sim), st)
			compared += 1
			if why != "" and bad == "":
				bad = "effect %d frame %d: %s" % [k, f, why]
		g.sim.clear()
		n.sim.clear()
		g.free()
		n.free()
	EfpSim.live_total = 0
	_check(bad == "", "draw buffers, Link chains and strips: %d nodes over %d frames, %d chains, %d native strips, the same floats bit for bit%s" % [
		nodes, compared, chains, strips, "" if bad == "" else " -- " + bad])

## The batch builds a stepped effect's outputs on its thread: an EquipFx-like
## master's MultiMesh gets them through step_post.
func _through_step_post() -> void:
	var ld := _loaders()
	var t := _rich(3, true)
	var m := EfpEffect.from_template(t, ld[0], ld[1], 77)
	m.loop = true
	m.auto_free = false
	m.use_shared_turn()
	var ok := m.use_native_sim(77)
	var g := EfpEffect.from_template(t, ld[0], ld[1], 77)
	g.loop = true
	g.use_shared_turn()
	var same := true
	var stepped := 0
	for f in 60:
		m.step_pre(1.0 / 30.0)
		EfpSimBatch.run([m], 1.0 / 30.0)
		stepped += m._pending_steps
		m.step_post()
		g.sim.advance(1.0 / 30.0)
		if m.draw_updates == 0:
			continue # nothing drawn yet
		var counts := (m.sim as EfpSimNative).draw_counts()
		var want: Array = EfpNativeParity.gd_draws(g, g.sim, Basis.IDENTITY)
		for i in m._draws.size():
			# The buffers and visible counts go to the RenderingServer from Rust
			# (the headless server keeps none to read back): the counts are the
			# GDScript's, and each MultiMesh was grown to hold them.
			var mm := (m._draws[i][1] as MultiMeshInstance3D).multimesh
			if i >= counts.size() or counts[i] != (want[0] as PackedInt32Array)[i] or mm.instance_count < counts[i]:
				same = false
	_check(ok and same and stepped > 0 and m.draw_updates > 0,
		"a master stepped by the batch: through step_post its MultiMeshes hold the GDScript's particle counts (%d steps, %d draw updates)" % [stepped, m.draw_updates])
	m.sim.clear()
	g.sim.clear()
	m.free()
	g.free()
	EfpSim.live_total = 0

# ---------------------------------------------------------------- no library

func _fallback() -> void:
	var t := _rich(1)
	var d := EfpSimNative.pack_template(t)
	_check(not d.has("error") and int(d["n"]) == t.tpls.size() and (d["frame_start"] as PackedInt32Array).size() == t.tpls.size() + 1,
		"the packer takes a compiled template (%d nodes, %d commands)" % [t.tpls.size(), (d.get("cmd_kind", PackedInt32Array()) as PackedInt32Array).size()])
	var e := EfpEffect.new()
	e.sim = EfpSim.new(t, 5)
	var used := e.use_native_sim(5)
	_check(used == EfpSimNative.available() and (e.sim is EfpSimNative) == used,
		"use_native_sim follows the library: %s (%s)" % [str(used), EfpSimNative.status])
	e.sim.clear()
	e.free()
	EfpSim.live_total = 0

func _initialize() -> void:
	EfpSim.live_total = 0
	_fallback()
	if not EfpSimNative.available():
		print("skip: the native parity checks need the library (%s)" % EfpSimNative.status)
	else:
		# USER DECISION 2026-10-09: no cap natively, by default.
		_check(EfpSimNative.native_cap == EfpSimNative.UNBOUNDED or OS.get_environment("OPENSRO_QA_EFP_CAP") != "",
			"the native masters have no particle cap (USER DECISION 2026-10-09): limit %d" % EfpSimNative.limit_native(false))
		# The parity runs hold both to the GDScript cap, so it binds alike.
		EfpSimNative.native_cap = EfpSim.cap_total
		_singles()
		_batch(8, 37.0, 300, 0, -1, 77)
		_batch(33, 15.0, 300, 0, 3, -1)
		_batch(60, 30.0, 300, 250, -1, 150)
		# Uncapped: the GDScript reference with its cap lifted too.
		EfpSimNative.native_cap = EfpSimNative.UNBOUNDED
		var cap := EfpSim.cap_total
		EfpSim.cap_total = EfpSimNative.UNBOUNDED
		_batch(60, 30.0, 300, 0, -1, 150, true)
		EfpSim.cap_total = cap
		_apart()
		_huge()
		_mixed()
		_draws()
		_through_step_post()
		_panic()
	EfpSimBatch.reap_all()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
