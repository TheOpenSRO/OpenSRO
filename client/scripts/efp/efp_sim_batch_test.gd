extends SceneTree

## Round 761: EfpSimBatch (EquipFx's effect masters on WorkerThreadPool) makes
## the particles the main thread made -- the same count, spawned, dropped and
## positions for every effect at every frame -- when the global particle cap
## (OURS) binds. Round 759's review F1 found the pool's even share re-dealt
## the room (600 of 600 frames differed at 33 effects, 15 fps) and never gave
## out its remainder. This is that review's probe as a suite, on synthetic
## decoded trees built here -- never game data: bursts, steady streams,
## holders with children of their own, delays, random cones (the RNG), a
## reserved effect, effects held outside the batch, and a long hitch (several
## 50 ms steps in one advance). The real files: client/tools/efp_cap_probe.gd.
##   godot4 --headless --path client --script res://scripts/efp/efp_sim_batch_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _cmd(name: String, value = null) -> EfpReader.EfpCommand:
	var c := EfpReader.EfpCommand.new()
	c.name = name
	c.value = value
	c.space = 0
	c.time_flags = 0
	c.start = 0.0
	c.step = 1.0
	c.end = 0.0
	return c

func _emit(delay: int, duration: int, interval: int, count: int, per: float) -> EfpReader.EfpCommand:
	return _cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": delay, "duration": duration,
		"interval": interval, "max_live": count, "per_trigger": per})

func _node(frames: int, life: String, emit: EfpReader.EfpCommand, cmds: Array = [], kids: Array = []) -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = "n"
	n.frames = frames
	n.extinct = _cmd(life)
	if emit != null:
		n.emit.append(emit)
	n.view = _cmd("ViewNone")
	n.render = _cmd("RenderNone")
	for c in cmds:
		n.commands.append(c)
	for k in kids:
		n.children.append(k)
	return n

## Six kinds of effect, `k` picking one and varying its numbers; `w` scales
## how many particles they want.
func _template(k: int, w: int = 1) -> EfpSim.Template:
	var cone := _cmd("SetConePos", {"type": "AngleVector1", "a": Vector3(1, 3, 0.5), "b": Vector3(2, 4, 1.0)})
	var vel := _cmd("SetConeVel", {"type": "AngleVector1", "a": Vector3(0.1, 0.4, 1.0), "b": Vector3(0.2, 0.6, 2.0)})
	var v := k / 6
	match k % 6:
		0: # bursts: up to 60 every 20 frames, living 40
			return EfpSim.compile(_node(40 + v % 7, "NormalTimeExtinct", _emit(0, 100000, 20, 200 * w, 60.0 * w), [cone, vel]))
		1: # a steady stream, 2 a frame up to 40 alive
			return EfpSim.compile(_node(30 + v % 5, "NormalTimeExtinct", _emit(0, 100000, 1, (40 + v % 9) * w, 2.0 * w), [cone]))
		2: # three looping holders, each a stream of its own
			var child := _node(15 + v % 4, "NormalTimeExtinct", _emit(0, 100000, 2, 20 * w, 4.0 * w), [cone, vel])
			return EfpSim.compile(_node(20, "NormalTimeLoop", _emit(0, 1, 1, 3, 3.0), [], [child]))
		3: # a delayed, re-arming emitter on a looping node
			return EfpSim.compile(_node(60, "NormalTimeLoop", _emit(5 + v % 3, 50, 3, 30 * w, 5.5 * w), [vel]))
		4: # fractional per-trigger, long lives
			return EfpSim.compile(_node(90, "NormalTimeExtinct", _emit(0, 100000, 1, 120 * w, 1.7 * w), [cone]))
		_: # a holder whose children burst
			var spark := _node(12, "NormalTimeExtinct", _emit(0, 100000, 6, 50 * w, 25.0 * w), [cone, vel])
			return EfpSim.compile(_node(40, "NormalTimeExtinct", _emit(0, 100000, 10, 4, 2.0), [], [spark]))

func _effects(n: int, reserved: int) -> Array:
	var fx: Array = []
	var w := 3 if n <= 8 else 1
	for i in range(n):
		var e := EfpEffect.new()
		e.sim = EfpSim.new(_template(i, w), 1000 + i)
		e.sim.keep = true
		e.sim.reserved = i == reserved
		fx.append(e)
	return fx

func _free(fx: Array) -> void:
	for e in fx:
		(e as EfpEffect).sim.clear()
		(e as Node).free()

## One run: `frames` frames at `fps` (frame `hitch` lasts 0.3 s), the
## effects advanced in turn on the main thread ("main") or by
## EfpSimBatch.run ("pool"). Returns per frame one PackedFloat64Array: per
## effect its count, spawned, dropped and a sum over its particles' positions;
## then live_total. Also the totals of the run in `out`.
func _run(mode: String, n: int, fps: float, frames: int, held: int, reserved: int, hitch: int, out: Dictionary) -> Array:
	EfpSim.live_total = held
	var fx := _effects(n, reserved)
	var hist: Array = []
	var at_cap := 0
	var top := 0
	var waits := 0
	var misses := 0
	var helpers := 0
	var t0 := Time.get_ticks_usec()
	for fr in range(frames):
		var delta := 0.3 if fr == hitch else 1.0 / fps
		if mode == "main":
			for e in fx:
				(e as EfpEffect).step_sim(delta)
		else:
			EfpSimBatch.run(fx, delta)
			waits += int(EfpSimBatch.last["waits"])
			misses += int(EfpSimBatch.last["misses"])
			helpers += int(EfpSimBatch.last["by_helpers"])
		var row := PackedFloat64Array()
		for e in fx:
			var s: EfpSim = (e as EfpEffect).sim
			var sum := 0.0
			for p in s.particles:
				sum += p.pos.x + 3.0 * p.pos.y + 7.0 * p.pos.z
			row.append(s.particles.size())
			row.append(s.spawned)
			row.append(s.dropped)
			row.append(sum)
		row.append(EfpSim.live_total)
		hist.append(row)
		if EfpSim.live_total >= EfpSim.MAX_TOTAL - EfpSim.RESERVE:
			at_cap += 1
		top = maxi(top, EfpSim.live_total)
	var dropped := 0
	var counted := held
	for e in fx:
		dropped += (e as EfpEffect).sim.dropped
		counted += (e as EfpEffect).sim.particles.size()
	out["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	out["at_cap"] = at_cap
	out["top"] = top
	out["dropped"] = dropped
	out["waits"] = waits
	out["misses"] = misses
	out["helpers"] = helpers
	out["counted"] = counted == EfpSim.live_total
	_free(fx)
	EfpSim.live_total = 0
	return hist

func _differ(a: Array, b: Array) -> Vector2i:
	var frames := 0
	var first := -1
	for fr in range(mini(a.size(), b.size())):
		if a[fr] != b[fr]:
			frames += 1
			if first < 0:
				first = fr
	return Vector2i(frames + absi(a.size() - b.size()), first)

func _case(n: int, fps: float, frames: int, held: int = 0, reserved: int = -1, hitch: int = -1) -> void:
	var m := {}
	var p := {}
	var q := {}
	var main := _run("main", n, fps, frames, held, reserved, hitch, m)
	var pool := _run("pool", n, fps, frames, held, reserved, hitch, p)
	var again := _run("pool", n, fps, frames, held, reserved, hitch, q)
	var d := _differ(main, pool)
	var name := "%d effects, %.0f fps, %d frames%s%s%s" % [n, fps, frames,
		", %d held outside" % held if held > 0 else "", ", #%d reserved" % reserved if reserved >= 0 else "",
		", a 0.3 s hitch at %d" % hitch if hitch >= 0 else ""]
	print("BATCH %s: main %.0f ms, at the cap %d frames, top %d, dropped %d | pool %.0f ms, at the cap %d, top %d, dropped %d, waits %d, by helpers %d" % [
		name, m["ms"], m["at_cap"], m["top"], m["dropped"], p["ms"], p["at_cap"], p["top"], p["dropped"], p["waits"], p["helpers"]])
	_check(int(m["at_cap"]) >= frames / 4,
		"%s: the cap binds on the main thread (%d of %d frames at it)" % [name, m["at_cap"], frames])
	_check(d.x == 0, "%s: the pool equals the main thread at every frame -- count, spawned, dropped, positions, live_total (%d frames differ, first %d)" % [name, d.x, d.y])
	_check(_differ(pool, again).x == 0, "%s: deterministic -- a second pool run is the first, frame for frame" % name)
	_check(int(p["misses"]) == 0 and int(q["misses"]) == 0, "%s: every effect's change fell inside the bounds it published (misses %d)" % [name, p["misses"]])
	_check(bool(p["counted"]) and bool(m["counted"]), "%s: live_total is the particles counted" % name)

## With room for everything the bounds decide every spawn: nothing waits.
func _roomy() -> void:
	var fx: Array = []
	for i in range(8):
		var e := EfpEffect.new()
		e.sim = EfpSim.new(EfpSim.compile(_node(30, "NormalTimeExtinct", _emit(0, 100000, 1, 40, 2.0),
			[_cmd("SetConePos", {"type": "AngleVector1", "a": Vector3(1, 3, 0.5), "b": Vector3(2, 4, 1.0)})])), 50 + i)
		fx.append(e)
	var waits := 0
	var top := 0
	for _fr in range(120):
		EfpSimBatch.run(fx, 1.0 / 20.0)
		waits += int(EfpSimBatch.last["waits"])
		top = maxi(top, EfpSim.live_total)
	_check(top > 200 and top < EfpSim.MAX_TOTAL - EfpSim.RESERVE and waits == 0,
		"with room (8 streams, %d particles at most), no spawn waits for the effects before it (%d waits)" % [top, waits])
	_free(fx)
	EfpSim.live_total = 0

## growth_bounds before an advance holds the advance's real change.
func _bounds() -> void:
	var ok := true
	var tight := 0
	var steps := 0
	for k in range(12):
		var s := EfpSim.new(_template(k), 300 + k)
		s.keep = true
		for fr in range(150):
			var delta := 0.3 if fr % 37 == 36 else 1.0 / 15.0
			var b := s.growth_bounds(delta)
			var before := s.particles.size()
			var n := s.advance(delta)
			var d := s.particles.size() - before
			if d < b.x or d > b.y:
				ok = false
			if n > 0:
				steps += 1
				if b.y - b.x <= 60:
					tight += 1
		s.clear()
	EfpSim.live_total = 0
	_check(ok, "growth_bounds holds every advance's change (12 effects x 150 frames, hitches included)")
	_check(tight * 2 >= steps, "... and is mostly tight: %d of %d stepping advances within 60" % [tight, steps])

func _lint() -> void:
	var lint: GDScript = load("res://scripts/assets/const_array_lint_test.gd")
	var files: Array = lint.get_script_constant_map().get("WORKER_FILES", []) if lint != null else []
	var all := true
	for f in ["res://scripts/efp/efp_sim_batch.gd", "res://scripts/efp/efp_sim.gd", "res://scripts/efp/efp_reader.gd", "res://scripts/efp/efp_effect.gd"]:
		if not files.has(f):
			all = false
	_check(all, "const_array_lint_test's WORKER_FILES has every script a batch runs off the main thread")

func _initialize() -> void:
	EfpSim.live_total = 0
	_bounds()
	_roomy()
	_case(8, 37.0, 300)
	_case(33, 15.0, 300, 0, 3)
	_case(60, 30.0, 300, 250, -1, 150)
	_lint()
	EfpSimBatch.reap_all()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
