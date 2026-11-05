extends SceneTree

## Round 862: a mesh-less `.bsr` an AuraModel keeps (the guild war mark's
## `res\etc\guild_war_mark.bsr`, MEASURED: no mesh, one `ambient` entry,
## `map\guild\guild_war_mark.efp` at 0,3,0) plays its offset ambient
## entries on the model, looping, and drops them with the model; a bone's
## entry (mode 0) and a night-only one do not play. No game data.
## `godot4 --headless --path client --script res://scripts/effects/guild_war_mark862_test.gd`

var _failures := 0
var _made: Array = []

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _entry(efp: String, mode: int, offset: Vector3, b51: int = 0) -> BsrReader.ParticleEntry:
	var e := BsrReader.ParticleEntry.new()
	e.efp = efp
	e.mode = mode
	e.offset = offset
	e.bone = "Bone01" if mode == 0 else ""
	e.b51 = b51
	return e

func _effect(path: String) -> EfpEffect:
	var n := EfpReader.EfpNode.new()
	n.frames = 3
	var ex := EfpReader.EfpCommand.new()
	ex.name = "NormalTimeExtinct"
	n.extinct = ex
	var em := EfpReader.EfpCommand.new()
	em.name = "StaticEmit"
	em.value = {"type": "SEFStaticEmit", "delay": 0, "duration": 1, "interval": 1, "max_live": 1, "per_trigger": 1.0}
	n.emit.append(em)
	var rd := EfpReader.EfpCommand.new()
	rd.name = "RenderPlate"
	n.render = rd
	var vw := EfpReader.EfpCommand.new()
	vw.name = "ViewNone"
	n.view = vw
	n.state = EfpReader.EfpRenderState.new()
	var ref := EfpReader.EfpMeshRef.new()
	ref.textures = PackedStringArray(["missing.ddj"])
	n.meshes.append(ref)
	var S: GDScript = load("res://scripts/efp/efp_sim.gd")
	var E: GDScript = load("res://scripts/efp/efp_effect.gd")
	var fx = E.from_template(S.compile(n), func(_p): return null, func(_p): return null, 5)
	fx.set_meta("efp", path)
	_made.append(fx)
	return fx

func _run() -> void:
	var asked: Array = []
	AuraModel.builder = func(_p: String) -> Node3D:
		var t := Node3D.new()
		t.set_meta(AmbientParticles.META_ENTRIES, [[
			_entry("map\\guild\\guild_war_mark.efp", 1, Vector3(0, 3, 0)),
			_entry("skill\\bone_one.efp", 0, Vector3.ZERO),
			_entry("map\\night_only.efp", 1, Vector3(0, 1, 0), 1),
		]])
		return t
	AuraModel.effect_factory = func(p: String) -> EfpEffect:
		asked.append(p)
		return _effect(p)
	var body := Node3D.new()
	get_root().add_child(body)
	var m := AuraModel.spawn("res\\etc\\guild_war_mark.bsr", body, "*", Vector3(0, 16, 0))
	_check(m != null and m.model != null, "the mesh-less model is built")
	_check(asked == ["map\\guild\\guild_war_mark.efp"], "only the offset, all-day entry is asked for (%s)" % str(asked))
	_check(m != null and m.ambient_fx.size() == 1, "one ambient effect plays on it")
	if m != null and m.ambient_fx.size() == 1:
		var fx := m.ambient_fx[0] as EfpEffect
		_check(fx.loop and not fx.auto_free, "... looping, kept")
		_check(fx.get_parent() == m.model, "... a child of the model, so it follows the body's `*`")
	# NEGATIVE: a template without the meta plays nothing (round 860's look).
	var bare := Node3D.new()
	_check(AuraModel.ambient_entries_of(bare).is_empty(), "no ambient set: no effect")
	bare.free()
	m.release()
	body.queue_free()
	AuraModel.effect_factory = Callable()
	AuraModel.reset()
	_finish.call_deferred()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
