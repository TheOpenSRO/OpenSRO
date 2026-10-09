extends EfpSim
class_name EfpSimNative

## Round 763: an EfpSim stepped in Rust (native/src/core/efp_sim.rs through
## native/src/gd_efp.rs). Round 762 put weapon and seal particles back on every
## player within 720 units, about 50 EquipFx masters simulated in GDScript:
## about 4 ms of EquipFx a frame in the live crowd, and GDScript barely scales
## across threads (round 761: 0.4-1.4x on 5). The port steps the same rules
## and gives the same particles, bit for bit (efp_native_test,
## client/tools/efp_native_parity.gd on the real files; docs/rounds/r763.md).
##
## **Where it is used.** EquipFx's masters (EfpEffect.use_native_sim), stepped
## all at once by EfpSimBatch.run -> run_batch: the Rust batch keeps round
## 761's ordered global cap exactly, on a Rust thread pool (configure) and the
## main thread, and builds each master's MultiMesh buffers and Link chains on
## the thread that stepped it; the main thread hands them to the
## RenderingServer in bulk (EfpEffect._apply_native_*). Every other effect
## (skills, auras, the world's ambient effects, a weapon's own simulation) is
## still EfpSim in GDScript, under EfpSim's global cap; the native masters
## have none (USER DECISION 2026-10-09, `native_cap` below).
##
## **The fallback.** Without the library (or with OPENSRO_NATIVE=0, or
## OPENSRO_EFP_NATIVE=0 for this alone, or a template the packer refuses) the
## masters are EfpSim and step as before. Nothing names the native classes as
## types: they are looked up by name, so the client compiles without them.
##
## **The API.** This class keeps EfpSim's: advance, step, restart, clear,
## finished, growth_bounds, set_origin, shift, origin, count, set_phase, and
## age / dropped / spawned / revived kept current after every native call.
## `particles` stays empty -- the particles are in Rust; particle_list() builds
## a snapshot (the QA log, tests), and EfpEffect draws from the native buffers.

const SIM_CLASS := "SrEfpSim"
const TEMPLATE_CLASS := "SrEfpTemplate"
const BATCH_CLASS := "SrEfpBatch"
## The effect interface's own number (gd_efp.rs EFP_API): its classes are
## additive, so NativeAssets.NATIVE_API is unchanged.
const EFP_API := 1
## Threads a batch uses at most by default, the main thread included (OURS,
## round 763's measurement: docs/rounds/r763.md sections 3 and 9). Bounded
## further by Godot's WorkerThreadPool size and the machine's cores;
## OPENSRO_EFP_THREADS sets it (1 = the main thread alone). The pool is used
## only for a batch of at least pool_min_work particle-steps (its review, L2).
const DEFAULT_THREADS := 4
## Floats an instance takes in a MultiMesh buffer (TRANSFORM_3D, colours,
## custom data).
const STRIDE := 20

## USER DECISION 2026-10-09: no global particle cap while the masters
## simulate natively, as the original has none (READ, round 761); the
## GDScript fallback keeps EfpSim's 2,000. So the native masters count their
## own particles here, not in EfpSim.live_total: the GDScript effects' cap
## (skills, auras, the world's effects) keeps meaning what it meant, and the
## masters' particles neither count against it nor are refused by it.
static var live_native := 0
## The native masters' cap: none (UNBOUNDED) unless OPENSRO_QA_EFP_CAP names
## one (QA; the same switch as EfpSim's, round 761), or a test sets it.
const UNBOUNDED := 1 << 30
static var native_cap := _native_cap()

static func _native_cap() -> int:
	var v := OS.get_environment("OPENSRO_QA_EFP_CAP")
	if v == "" or not v.is_valid_int() or int(v) <= 0:
		return UNBOUNDED
	return int(v)

## The limit a native sim's spawn is held to (EfpSim.limit_for's rule on
## native_cap): unbounded, or with a QA cap RESERVE below it for any effect
## not reserved. The ordered admission (core/efp_batch.rs) takes it as any
## limit: with it unbounded every spawn is decided at once and nothing waits.
static func limit_native(is_reserved: bool) -> int:
	if native_cap >= UNBOUNDED or is_reserved:
		return native_cap
	return native_cap - RESERVE

static var _checked := false
static var _available := false
static var _batch: Object = null
## The batch's threads: the main thread plus `helpers` pool threads.
static var threads := 1
static var helpers := 0
## Round 763's review, L2: below this many particle-steps a batch runs on the
## main thread alone (core/efp_batch.rs POOL_MIN_WORK; OPENSRO_EFP_POOL_MIN_WORK
## sets it, 0: the pool whenever there are helpers).
static var pool_min_work := 4000
## The one log line saying whether the masters simulate natively, and why.
static var status := ""

## True when the masters can be simulated natively. Logged once.
static func available() -> bool:
	if not _checked:
		_checked = true
		var why := ""
		if OS.get_environment("OPENSRO_EFP_NATIVE") == "0":
			why = "forced off by OPENSRO_EFP_NATIVE=0"
		elif not NativeAssets.available():
			why = "native readers off"
		elif not (ClassDB.class_exists(SIM_CLASS) and ClassDB.class_exists(TEMPLATE_CLASS) and ClassDB.class_exists(BATCH_CLASS)):
			why = "the library has no effect simulation (built before round 763: rebuild it with native/build.sh)"
		else:
			_batch = ClassDB.instantiate(BATCH_CLASS)
			if not _batch.has_method("efp_api") or int(_batch.call("efp_api")) != EFP_API:
				why = "the library's effect interface is %s, this client needs %d" % [str(_batch.call("efp_api")) if _batch.has_method("efp_api") else "none", EFP_API]
				_batch = null
		_available = why == ""
		if _available:
			configure()
			status = "EfpSimNative: native effect simulation ON (%d thread(s): the main thread and %d pool helper(s); Godot's pool %d, cores %d)" % [
				threads, helpers, godot_pool_threads(), OS.get_processor_count()]
		else:
			status = "EfpSimNative: native effect simulation OFF (%s) -- EquipFx's masters simulate in GDScript" % why
		print(status)
	return _available and not NativeAssets.force_gdscript

## Godot's WorkerThreadPool size: threading/worker_pool/max_threads, or the
## cores when it is unset (-1, Godot's default).
static func godot_pool_threads() -> int:
	var n := int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
	return n if n > 0 else OS.get_processor_count()

## Sizes the batch's pool. The batch runs while the main thread waits for it,
## so the main thread is one of its threads; the rest are bounded by Godot's
## own pool and the cores, so the effects never take more threads than the
## engine was given (OURS).
static func configure(want: int = -1) -> void:
	var cores := maxi(OS.get_processor_count(), 1)
	var n := want
	if n <= 0:
		var env := OS.get_environment("OPENSRO_EFP_THREADS")
		n = int(env) if env.is_valid_int() and int(env) > 0 else mini(DEFAULT_THREADS, mini(cores, godot_pool_threads()))
	if OS.get_environment("OPENSRO_QA_EFP_THREADS") == "0":
		n = 1
	threads = clampi(n, 1, maxi(cores, 1))
	helpers = threads - 1
	var mw := OS.get_environment("OPENSRO_EFP_POOL_MIN_WORK")
	if mw.is_valid_int():
		pool_min_work = maxi(int(mw), 0)
	elif _batch != null and _batch.has_method("pool_min_work"):
		pool_min_work = int(_batch.call("pool_min_work"))
	if _batch != null:
		_batch.call("set_helpers", helpers)

## The template's native twin, made once (null: it stays GDScript).
static func native_template(t: EfpSim.Template) -> Object:
	if t == null:
		return null
	if t.native_tried:
		return t.native
	t.native_tried = true
	var d := pack_template(t)
	if d.has("error"):
		t.native_error = String(d["error"])
		return null
	var nt: Object = ClassDB.instantiate(TEMPLATE_CLASS)
	var err := String(nt.call("build", d))
	if err != "":
		t.native_error = err
		return null
	t.native = nt
	return nt

## A GDScript sim's native twin for the same template and keep / reserved
## flags, with a new random stream (`seed_value`, 0: a random one), or null
## when it cannot be one.
static func from_sim(s: EfpSim, seed_value: int = 0) -> EfpSimNative:
	if s == null or not available() or native_template(s.template) == null:
		return null
	var n := EfpSimNative.new(s.template, seed_value)
	if n._n == null:
		return null
	n.keep = s.keep
	n.reserved = s.reserved
	return n

var _n: Object = null
var _count := 0

func _init(tmpl: EfpSim.Template = null, seed_value: int = 0) -> void:
	super(tmpl, seed_value)
	var nt := native_template(tmpl) if available() else null
	if nt == null:
		return
	_n = ClassDB.instantiate(SIM_CLASS)
	# The stream RandomNumberGenerator.seed = seed makes (EfpSim._init's: the
	# seed given, or the one randomize() chose).
	if not bool(_n.call("setup", nt, _rng.seed)):
		_n = null
		return
	_pull()

## Whether the native simulation is live (else this behaves as an empty EfpSim).
func is_native() -> bool:
	return _n != null

func _pull() -> void:
	var c: PackedInt64Array = _n.call("counters")
	age = c[0]
	dropped = c[1]
	spawned = c[2]
	revived = c[3]
	_count = c[4]

func restart() -> void:
	if _n == null:
		super.restart()
		return
	live_native -= int(_n.call("restart"))
	_pull()

func clear() -> void:
	if _n == null:
		super.clear()
		return
	live_native -= int(_n.call("clear"))
	_pull()

func finished() -> bool:
	if _n == null:
		return super.finished()
	return bool(_n.call("finished"))

func advance(delta: float) -> int:
	if _n == null:
		return super.advance(delta)
	var r: PackedInt64Array = _n.call("advance", delta, live_native, limit_native(reserved), keep, EfpSim.interval_mul, EfpSim.threshold)
	if r.size() < 2:
		# Broken (a panic stepped it, round 763's review M1): GDScript from now on.
		disable("an effect's step failed")
		_fall_back()
		return super.advance(delta)
	live_native += r[1]
	_pull()
	return r[0]

func step() -> void:
	if _n == null:
		super.step()
		return
	live_native += int(_n.call("step", live_native, limit_native(reserved), keep, EfpSim.interval_mul, EfpSim.threshold))
	if bool(_n.call("broken")):
		disable("an effect's step failed")
		_fall_back()
		return
	_pull()

func growth_bounds(delta: float) -> Vector2i:
	if _n == null:
		return super.growth_bounds(delta)
	return _n.call("growth_bounds", delta, EfpSim.interval_mul, EfpSim.threshold)

func set_origin(pos: Vector3, rot: Basis = Basis.IDENTITY) -> bool:
	if _n == null:
		return super.set_origin(pos, rot)
	return bool(_n.call("set_origin", pos, rot))

func shift(v: Vector3) -> void:
	if _n == null:
		super.shift(v)
		return
	_n.call("shift", v)

func origin() -> Vector3:
	if _n == null:
		return super.origin()
	return _n.call("origin")

func count() -> int:
	return _count if _n != null else particles.size()

func set_phase(acc: float) -> void:
	if _n == null:
		super.set_phase(acc)
		return
	_n.call("set_acc", acc)

## The step clock (EfpSim._acc), for tests.
func clock() -> float:
	return float(_n.call("acc")) if _n != null else _acc

## A native sim is never stepped through EfpSimBatch's GDScript Job (run_batch
## steps it): these keep EfpSim's contract for a caller that does.
func begin_deferred(gate: Object, index: int) -> void:
	if _n == null:
		super.begin_deferred(gate, index)

func end_deferred() -> void:
	if _n == null:
		super.end_deferred()

# ---------------------------------------------------------------- the draws

## What EfpEffect draws of it: its plate / mesh nodes (template index, view 0
## rotation / 1 billboard / 2 Y billboard / 3 velocity billboard, shared
## turn) and its Link nodes (template index, kind 0 LinkDPipe / 1 LinkPipe /
## 2 LinkObj, shared turn).
func set_outputs(draw_tpls: PackedInt32Array, views: PackedInt32Array, turns: PackedByteArray,
		link_tpls: PackedInt32Array, link_kinds: PackedByteArray, link_turns: PackedByteArray) -> void:
	if _n == null:
		return
	_n.call("set_draws", draw_tpls, views, turns)
	_n.call("set_links", link_tpls, link_kinds, link_turns)

## Per Link node its natively built strip ([vertex count, verts, colours, uvs,
## custom0, custom1]) or null (gd_efp.rs take_strips).
func take_strips() -> Array:
	return _n.call("take_strips") if _n != null else []

## Each draw node's MultiMesh RID (apply_draws sends the buffers there).
func set_draw_rids(rids: Array) -> void:
	if _n != null:
		_n.call("set_draw_rids", rids)

## [draw node, instance count]... whose MultiMesh must grow first.
func draw_growth() -> PackedInt32Array:
	return _n.call("draw_growth") if _n != null else PackedInt32Array()

## The built buffers to the RenderingServer (gd_efp.rs apply_draws).
func apply_draws() -> int:
	return int(_n.call("apply_draws")) if _n != null else 0

## Each draw node's particle count after the last build.
func draw_counts() -> PackedInt32Array:
	return _n.call("draw_counts") if _n != null else PackedInt32Array()

## Whether the batch built the outputs after this sim's last step.
func fresh() -> bool:
	return _n != null and bool(_n.call("has_fresh"))

## Builds the outputs now (the camera turned without a step, or a step outside
## a batch), `cam` being EfpEffect's cam_rot.
func build_outputs(cam: Basis) -> void:
	if _n != null:
		_n.call("build_outputs", cam)

## [counts (PackedInt32Array), one PackedFloat32Array per draw node].
func take_draws() -> Array:
	return _n.call("take_draws") if _n != null else []

## {meta, pos, col, w, y}: the Link chains (gd_efp.rs take_chains).
func take_chains() -> Dictionary:
	return _n.call("take_chains") if _n != null else {}

func count_tpls(tpls: PackedInt32Array) -> int:
	return int(_n.call("count_tpls", tpls)) if _n != null else 0

## The native state as plain arrays (gd_efp.rs dump): the parity checks.
func dump() -> Dictionary:
	return _n.call("dump") if _n != null else {}

## The particles as EfpSim.Particle objects, rebuilt from the native state
## (the QA log and tests; the frame never needs it).
func particle_list() -> Array[EfpSim.Particle]:
	if _n == null:
		return super.particle_list()
	var out: Array[EfpSim.Particle] = []
	var d := dump()
	var pi: PackedInt64Array = d["p_int"]
	var pf: PackedFloat32Array = d["p_f32"]
	var n := pi.size() / 5
	for i in n:
		var p := EfpSim.Particle.new()
		var f := 70 * i
		p.tpl = pi[5 * i]
		p.age = pi[5 * i + 1]
		var fl := pi[5 * i + 2]
		p.alive = fl & 1 != 0
		p.dying = fl & 2 != 0
		p.changed = fl & 4 != 0
		p.has_rvel = fl & 8 != 0
		p.has_shape_vel = fl & 16 != 0
		p.color = pi[5 * i + 3]
		p.pos = Vector3(pf[f], pf[f + 1], pf[f + 2])
		p.vel = Vector3(pf[f + 3], pf[f + 4], pf[f + 5])
		p.rot = rows_basis(pf, f + 6)
		p.rvel = rows_basis(pf, f + 15)
		p.shape = rows_basis(pf, f + 24)
		p.shape_vel = rows_basis(pf, f + 33)
		p.scale = Vector3(pf[f + 42], pf[f + 43], pf[f + 44])
		p.uv = Vector4(pf[f + 45], pf[f + 46], pf[f + 47], pf[f + 48])
		p.old_pos = Vector3(pf[f + 49], pf[f + 50], pf[f + 51])
		p.old_rot = rows_basis(pf, f + 52)
		p.delta = rows_basis(pf, f + 61)
		out.append(p)
	for i in n:
		var l := pi[5 * i + 4]
		if l >= 0:
			out[i].link = out[l]
			out[l].next_link = out[i]
	return out

## A Basis from nine floats, row by row.
static func rows_basis(a: PackedFloat32Array, at: int) -> Basis:
	return Basis(Vector3(a[at], a[at + 3], a[at + 6]), Vector3(a[at + 1], a[at + 4], a[at + 7]),
		Vector3(a[at + 2], a[at + 5], a[at + 8]))

## A Basis as nine floats, row by row, into `out` at `at`.
static func put_rows(out: PackedFloat32Array, at: int, b: Basis) -> void:
	out[at] = b.x.x
	out[at + 1] = b.y.x
	out[at + 2] = b.z.x
	out[at + 3] = b.x.y
	out[at + 4] = b.y.y
	out[at + 5] = b.z.y
	out[at + 6] = b.x.z
	out[at + 7] = b.y.z
	out[at + 8] = b.z.z

# ---------------------------------------------------------------- the batch

## Singular bases the native side inverted (returned unchanged, as an editor
## build's GDScript does; a release template's would divide by zero).
static func singular_inverses() -> int:
	return int(_batch.call("singular_inverses")) if _batch != null and _batch.has_method("singular_inverses") else 0

## Whether every effect of `effects` simulates natively (EfpSimBatch.run then
## steps them all here).
static func all_native(effects: Array) -> bool:
	if effects.is_empty():
		return false
	for e in effects:
		var s = (e as EfpEffect).sim
		if not (s is EfpSimNative) or (s as EfpSimNative)._n == null:
			return false
	return true

## EfpSimBatch.run for native sims: one Rust batch -- every effect advanced in
## the list's order of the global cap, on `threads` threads, each one's draws
## built after its step -- then live_native and the counters back here, and
## each effect's frames for its step_post. EfpSimBatch.last as the GDScript
## batch fills it.
static func run_batch(effects: Array, delta: float) -> bool:
	var n := effects.size()
	var sims: Array = []
	sims.resize(n)
	var limits := PackedInt64Array()
	limits.resize(n)
	var keeps := PackedByteArray()
	keeps.resize(n)
	var cams := PackedFloat32Array()
	cams.resize(9 * n)
	for i in n:
		var e: EfpEffect = effects[i]
		var s: EfpSimNative = e.sim
		sims[i] = s._n
		limits[i] = limit_native(s.reserved)
		keeps[i] = 1 if s.keep else 0
		# Only a billboard node that is not shared-turn draws with the camera;
		# nine zeros stand for the identity (gd_efp.rs b3_from).
		if e._native_needs_cam:
			put_rows(cams, 9 * i, e.native_cam_rot())
	# Untyped on purpose (round 763's review, M1): whatever comes back -- a
	# Dictionary, {error}, or nothing at all -- is looked at before it is used.
	var got = _batch.call("run", sims, delta, live_native, limits, keeps, cams, EfpSim.interval_mul, EfpSim.threshold,
		helpers, pool_min_work)
	var r: Dictionary = got if got is Dictionary else {}
	if r.is_empty() or r.has("error") or not r.has("steps"):
		# A step panicked (the effect is broken), a sim was listed twice, or
		# the batch could not run: the native simulation goes off for the
		# session and these effects simulate in GDScript from now on (the
		# caller steps them this frame, EfpSimBatch.run).
		disable("the batch failed: %s" % str(r.get("error", "no result")))
		for e in effects:
			((e as EfpEffect).sim as EfpSimNative)._fall_back()
		return false
	var steps: PackedInt64Array = r["steps"]
	var change: PackedInt64Array = r["change"]
	var counters: PackedInt64Array = r["counters"]
	for i in n:
		var e: EfpEffect = effects[i]
		var s: EfpSimNative = e.sim
		live_native += change[i]
		s.age = counters[5 * i]
		s.dropped = counters[5 * i + 1]
		s.spawned = counters[5 * i + 2]
		s.revived = counters[5 * i + 3]
		s._count = counters[5 * i + 4]
		e._pending_steps = steps[i]
		e._pending_sim_usec = 0
	batches += 1
	EfpSimBatch.last = {"n": n, "threaded": bool(r.get("pooled", false)), "native": true, "by_helpers": int(r["by_helpers"]),
		"waits": int(r["waits"]), "wait_usec": int(r["wait_usec"]), "misses": int(r["misses"]),
		"bounds_usec": int(r["bounds_usec"]), "sim_usec": int(r["sim_usec"]), "work": int(r.get("work", 0))}
	return true

## Round 763's review, M1: the native simulation off for the rest of the
## session (a step panicked, or a batch failed), with one log line. Masters
## made later are EfpSim; one that was native falls back on its own failure
## (_fall_back) or in the failed batch.
static func disable(why: String) -> void:
	if not _available:
		return
	_available = false
	status = "EfpSimNative: native effect simulation OFF (%s) -- EquipFx's masters simulate in GDScript from now on" % why
	push_warning(status)
	print(status)

## This sim simulates in GDScript from here on (its native twin failed): an
## empty EfpSim restarted on the same template, keep and reserved kept, its
## native particles given back to live_native.
func _fall_back() -> void:
	if _n == null:
		return
	live_native -= _count
	_count = 0
	_n = null
	super.restart()

## Native batches run (tests).
static var batches := 0

# ---------------------------------------------------------------- packing

## The compiled template as packed arrays for SrEfpTemplate.build (gd_efp.rs
## `unpack` names the keys), or {"error": why} when a payload is not of the
## type its command family runs with (the effect then stays GDScript).
static func pack_template(t: EfpSim.Template) -> Dictionary:
	var n := t.tpls.size()
	var parent := PackedInt32Array()
	var child_start := PackedInt32Array()
	var children := PackedInt32Array()
	var frames := PackedInt64Array()
	var life := PackedInt32Array()
	var has_emit := PackedByteArray()
	var emit_i := PackedInt64Array()
	var e_per := PackedFloat64Array()
	var lv := PackedInt64Array()
	var flags := PackedByteArray()
	var frame_start := PackedInt32Array()
	var cmd_start := PackedInt32Array()
	var cmd_kind := PackedInt32Array()
	var cmd_space := PackedInt64Array()
	var cmd_f := PackedFloat64Array()
	var cmd_c := PackedInt64Array()
	var sg_has := PackedByteArray()
	var sg_ab := PackedFloat64Array()
	var sg_start := PackedInt32Array()
	var sg_times := PackedFloat32Array()
	var sg_scales := PackedFloat32Array()
	var fan := PackedInt64Array()
	var has_fan := t.fan.size() == n and t.rate.size() == n and t.kids.size() == n
	for i in n:
		var tp: EfpSim.Tpl = t.tpls[i]
		if tp.index != i:
			return {"error": "node %d is indexed %d" % [i, tp.index]}
		parent.append(tp.parent)
		child_start.append(children.size())
		for k in tp.children:
			children.append(k)
		frames.append(tp.frames)
		life.append(tp.life)
		has_emit.append(1 if tp.emit != null else 0)
		emit_i.append(tp.e_delay)
		emit_i.append(tp.e_dur)
		emit_i.append(tp.e_int)
		emit_i.append(tp.e_max)
		e_per.append(tp.e_per)
		lv.append(tp.lv_orbit)
		lv.append(tp.lv_rot)
		lv.append(tp.lv_vel)
		lv.append(tp.lv_move)
		flags.append(1 if tp.keep_rot else 0)
		flags.append(1 if tp.keep_pos else 0)
		flags.append(1 if tp.follows_any else 0)
		if tp.schedule.size() != maxi(tp.frames, 0):
			return {"error": "node %d: %d frames, %d scheduled" % [i, tp.frames, tp.schedule.size()]}
		frame_start.append(cmd_start.size())
		for f in tp.schedule.size():
			cmd_start.append(cmd_kind.size())
			for entry in (tp.schedule[f] as Array):
				var why := _pack_cmd(entry, cmd_kind, cmd_space, cmd_f, cmd_c)
				if why != "":
					return {"error": "node %d frame %d: %s" % [i, f, why]}
		sg_start.append(sg_times.size())
		var g = tp.scale_graph
		if g is Dictionary:
			var times = (g as Dictionary).get("times", PackedFloat32Array())
			var scales = (g as Dictionary).get("scales", PackedVector3Array())
			if not (times is PackedFloat32Array) or not (scales is PackedVector3Array):
				return {"error": "node %d: a scale graph of other types" % i}
			sg_has.append(1)
			sg_ab.append(float((g as Dictionary).get("a", 0.0)))
			sg_ab.append(float((g as Dictionary).get("b", 1.0)))
			# Only the pairs sample_scale_graph reads (mini of the two sizes).
			var m := mini((times as PackedFloat32Array).size(), (scales as PackedVector3Array).size())
			for k in m:
				sg_times.append((times as PackedFloat32Array)[k])
				var v: Vector3 = (scales as PackedVector3Array)[k]
				sg_scales.append(v.x)
				sg_scales.append(v.y)
				sg_scales.append(v.z)
		else:
			sg_has.append(0)
			sg_ab.append(0.0)
			sg_ab.append(1.0)
		if has_fan:
			fan.append(t.rate[i])
			fan.append(t.kids[i])
			fan.append(t.fan[i])
	child_start.append(children.size())
	frame_start.append(cmd_start.size())
	cmd_start.append(cmd_kind.size())
	sg_start.append(sg_times.size())
	return {"n": n, "parent": parent, "child_start": child_start, "children": children, "frames": frames,
		"life": life, "has_emit": has_emit, "emit_i": emit_i, "e_per": e_per, "lv": lv, "flags": flags,
		"frame_start": frame_start, "cmd_start": cmd_start, "cmd_kind": cmd_kind, "cmd_space": cmd_space,
		"cmd_f": cmd_f, "cmd_c": cmd_c, "sg_has": sg_has, "sg_ab": sg_ab, "sg_start": sg_start,
		"sg_times": sg_times, "sg_scales": sg_scales, "fan": fan, "fan_child": t.fan_child, "has_fan": has_fan}

## One schedule entry [kind, space, payload]: nine floats (a Vector3, a Basis
## by rows, a Vector4, or Attraction's float first) and an int (a colour).
static func _pack_cmd(entry, kinds: PackedInt32Array, spaces: PackedInt64Array, fs: PackedFloat64Array, cs: PackedInt64Array) -> String:
	if not (entry is Array) or (entry as Array).size() < 3:
		return "an entry that is not [kind, space, payload]"
	var kind := int(entry[0])
	var v = entry[2]
	var f := PackedFloat64Array()
	f.resize(9)
	var c := 0
	match kind:
		K_POS, K_SPHERE, K_VEL, K_FORCE, K_CONEPOS, K_CONEVEL, K_CONEFORCE, K_BANPOS, K_SCALE:
			if not (v is Vector3):
				return "kind %d without a Vector3" % kind
			f[0] = (v as Vector3).x
			f[1] = (v as Vector3).y
			f[2] = (v as Vector3).z
		K_ATTRACT:
			if not (v is float):
				return "Attraction without a float"
			f[0] = v
		K_ROT, K_BANROT, K_RVEL, K_SHAPE, K_SHAPEVEL:
			if not (v is Basis):
				return "kind %d without a Basis" % kind
			var b: Basis = v
			f[0] = b.x.x
			f[1] = b.y.x
			f[2] = b.z.x
			f[3] = b.x.y
			f[4] = b.y.y
			f[5] = b.z.y
			f[6] = b.x.z
			f[7] = b.y.z
			f[8] = b.z.z
		K_DIFFUSE:
			if not (v is int):
				return "SetGraphDiffuse without a colour"
			c = v
		K_SLIDE:
			if not (v is Vector4):
				return "TextureSlide without a Vector4"
			f[0] = (v as Vector4).x
			f[1] = (v as Vector4).y
			f[2] = (v as Vector4).z
			f[3] = (v as Vector4).w
		K_RANDSCALE:
			pass
		_:
			return "kind %d" % kind
	kinds.append(kind)
	spaces.append(int(entry[1]))
	fs.append_array(f)
	cs.append(c)
	return ""
