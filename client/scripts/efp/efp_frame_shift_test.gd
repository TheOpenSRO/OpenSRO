extends SceneTree

## Round 786 (READ, EfpEffect "shift_effects"): what the original does to its
## effects across a zone change, and the user's report it fixes -- after a
## gate teleport from Donwhang to Jangan the auras' particles floated off the
## body and some flew away.
## - A change of frame moves every effect whole (CICPlayer slot 37,
##   0x009d5900 -> CEFEffect::vslot_006, 0x00ca9f20): EfpEffect.shift_effects
##   with World3D.zone_frame_shift's offset.
## - Nothing is updated while the zone loads (CPSMission::vslot_012,
##   0x0084c300): EfpEffect.pause_world.
## - A placement has no distance test (CEFEffect::vslot_007, 0x00caa020): a
##   move of any size is motion (rounds 621-785 carried one past 400).
## Synthetic trees only -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_frame_shift_test.gd`

var _failures := 0
var S: GDScript
var E: GDScript
var W: GDScript

## Donwhang's gate point to Jangan's as this client placed the body before
## round 786 (teleportdata GATE_WC (957, 1508) in 102/153, GATE_CH
## (969, 1369) in 97/168, each zone in its own frame; MEASURED 141.3 with the
## heights): the move every effect saw.
const GATE_TO_GATE := Vector3(12, -22.5, 139)
## The two frames' offset (World3D.zone_frame_shift, 102/153 -> 97/168).
const FRAME := Vector3(-28800, 0, -9600)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _cmd(name: String, value = null, space: int = 0) -> EfpReader.EfpCommand:
	var c := EfpReader.EfpCommand.new()
	c.name = name
	c.value = value
	c.space = space
	c.time_flags = 0
	c.start = 0.0
	c.step = 1.0
	c.end = 0.0
	return c

func _state() -> EfpReader.EfpRenderState:
	var s := EfpReader.EfpRenderState.new()
	s.cull = 1
	s.src_blend = 5
	s.dest_blend = 2
	s.color_arg1 = 2
	s.color_arg2 = 0
	s.color_op = 4
	s.alpha_arg1 = 2
	s.alpha_arg2 = 0
	s.alpha_op = 4
	return s

## A drawn node emitting one particle a frame, living `frames`.
func _node(frames: int, flags: Dictionary) -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = "n"
	n.frames = frames
	n.extinct = _cmd("NormalTimeExtinct")
	n.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 400,
		"interval": 1, "max_live": 20, "per_trigger": 1.0}))
	n.view = _cmd("ViewNone")
	n.render = _cmd("RenderPlate")
	n.state = _state()
	var ref := EfpReader.EfpMeshRef.new()
	ref.mesh = ""
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	n.flags = flags
	return n

## Round 785's orphan: a holder that dies at 4 frames (u6 = 1) with a child
## born on frame 0, living 200 frames and following it (u6 = 1).
func _orphans_tree() -> EfpReader.EfpNode:
	var holder := _node(4, {"u6": 1, "b1": 1})
	holder.emit.clear()
	holder.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 1,
		"interval": 1, "max_live": 1, "per_trigger": 1.0}))
	var kid := _node(200, {"u6": 1, "b1": 1})
	kid.emit.clear()
	kid.emit.append(_cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": 0, "duration": 1,
		"interval": 1, "max_live": 1, "per_trigger": 1.0}))
	holder.children.append(kid)
	return holder

func _effect(root: EfpReader.EfpNode, host: Node3D):
	var fx = E.from_template(S.compile(root), func(_p): return PlaceholderTexture2D.new(),
		func(_p): return null, 5)
	host.add_child(fx)
	fx.follow_host(host, "", Vector3.ZERO)
	return fx

func _host() -> Node3D:
	var host := Node3D.new()
	host.add_child(Skeleton3D.new())
	get_root().add_child(host)
	return host

## Every particle's distance from the host, in the world.
func _dists(fx, host: Node3D) -> Array:
	var out: Array = []
	for p in fx.sim.particles:
		out.append(((fx.global_transform * p.pos) - host.global_position).length())
	return out

func _farthest(fx, host: Node3D) -> float:
	var far := 0.0
	for d in _dists(fx, host):
		far = maxf(far, d)
	return far

## Particles off the body but in sight of it: past `spread` and nearer than
## 2,000 units (OURS: past the 720 within which the original draws a
## character's particle mods at all, READ round 761).
func _near_off(fx, host: Node3D, spread: float) -> int:
	var n := 0
	for d in _dists(fx, host):
		if d > spread and d < 2000.0:
			n += 1
	return n

func _initialize() -> void:
	S = load("res://scripts/efp/efp_sim.gd")
	E = load("res://scripts/efp/efp_effect.gd")
	W = load("res://scripts/World3D.gd")
	var probe = E.new() if E != null else null
	var ok: bool = probe != null and probe.has_method("shift_effects") and probe.has_method("pause_world")
	if probe != null:
		probe.free()
	_check(ok, "EfpEffect.shift_effects / pause_world / placed_under exist")
	if not ok:
		_finish()
		return
	await process_frame
	_frame_offset()
	_motion_any_size()
	_old_bug()
	_zone_change()
	_frozen_move()
	_paused()
	_world_calls()
	_finish()

## World3D.zone_frame_shift: the offset between two frames' grids, from the
## cells' own placement (_group_position of _cell_offset): region y drives
## world X, region x world Z (mirrored), the anchors the height.
func _frame_offset() -> void:
	var d: Vector3 = W.zone_frame_shift(Vector2i(102, 153), NAN, Vector2i(97, 168), NAN)
	_check(d.is_equal_approx(FRAME), "Donwhang's frame (102/153) to Jangan's (97/168) is %s" % str(d))
	var h: Vector3 = W.zone_frame_shift(Vector2i(97, 168), 10.0, Vector2i(97, 168), 4.0)
	_check(h.is_equal_approx(Vector3(0, 6, 0)), "one region on another height anchor moves by the anchors' difference (%s)" % str(h))
	# The same point of region 100/160 in both grids differs by the offset.
	var a: Vector2 = W.region_local_to_world(100, 160, 300.0, 700.0, 102, 153)
	var b: Vector2 = W.region_local_to_world(100, 160, 300.0, 700.0, 97, 168)
	_check((b - a).is_equal_approx(Vector2(d.x, d.z)), "... the offset every region of the grid moves by (%s)" % str(b - a))

## No distance test (CEFEffect::vslot_007): 5,000 units in one frame is
## motion -- a trail stays where it was, a follower comes along.
func _motion_any_size() -> void:
	for u6 in [0, 1]:
		var host := _host()
		var fx = _effect(_node(30, {"u6": u6}), host)
		for f in range(6):
			fx._process(0.05)
		host.position += Vector3(5000, 0, 0)
		fx._process(0.05)
		var far := _farthest(fx, host)
		if u6 == 0:
			_check(far > 4990.0, "a 5,000-unit move is motion: the trail stays behind (%.0f)" % far)
		else:
			_check(far < 0.01, "... and a follower (u6 = 1) is on the host (%.2f)" % far)
		fx.sim.clear()
		host.free()

## The report: the body re-placed by GATE_TO_GATE with no change of frame --
## what this client did before round 786 -- leaves the trail 140 units off,
## in sight.
func _old_bug() -> void:
	var host := _host()
	var fx = _effect(_node(30, {"u6": 0}), host)
	for f in range(10):
		fx._process(0.05)
	host.position += GATE_TO_GATE
	fx._process(0.05)
	_check(_near_off(fx, host, 10.0) > 0, "without the frame's shift the old place is %.0f units off: particles float beside the body" % GATE_TO_GATE.length())
	fx.sim.clear()
	host.free()

## The zone change: the frame's shift, then the body re-placed by
## GATE_TO_GATE in the new frame -- a true move of 30,000 units. Nothing is
## left in sight of the body; with the shift alone (no true move) nothing
## moves at all.
func _zone_change() -> void:
	var host := _host()
	var fx = _effect(_node(30, {"u6": 0}), host)
	for f in range(10):
		fx._process(0.05)
	var before := _dists(fx, host)
	var at_before: Vector3 = fx.global_transform * fx.sim.particles[0].pos
	var moved: int = E.shift_effects(E.placed_under(host), FRAME)
	host.position += FRAME
	fx._process(0.001)
	var after := _dists(fx, host)
	var same := before.size() == after.size()
	for i in range(mini(before.size(), after.size())):
		same = same and absf(float(before[i]) - float(after[i])) < 0.01
	_check(moved == 1 and same, "a change of frame alone moves the effect whole: no particle moves against the body")
	_check((fx.global_transform * fx.sim.particles[0].pos).is_equal_approx(at_before + FRAME),
		"... each particle by the frames' offset")
	host.position += GATE_TO_GATE - FRAME
	fx._process(0.05)
	_check(_near_off(fx, host, 10.0) == 0 and _farthest(fx, host) > 29000.0,
		"after the true move the old trail is left 30,000 units away, nothing in sight (farthest %.0f)" % _farthest(fx, host))
	fx.sim.clear()
	host.free()

## Round 785's frozen move on the arrival's frame: the orphan of a holder
## that died on it is never in sight of the body -- it carries 30,000 units a
## frame (or stays with the body), where without the shift it went on 140
## units a frame past the body.
func _frozen_move() -> void:
	for shifted in [false, true]:
		var near := 0
		for k in range(1, 7):
			var host := _host()
			var fx = _effect(_orphans_tree(), host)
			for f in range(k):
				fx._process(0.05)
			if shifted:
				E.shift_effects([fx], FRAME)
				host.position += GATE_TO_GATE
			else:
				host.position += GATE_TO_GATE
			for f in range(6):
				fx._process(0.05)
				near += _near_off(fx, host, 1.0)
			fx.sim.clear()
			host.free()
		if shifted:
			_check(near == 0, "with the frame's shift no orphan is ever in sight off the body")
		else:
			_check(near > 0, "without it an orphan flies past the body (%d particle-frames in sight)" % near)

## pause_world: nothing places or steps while held; released, the arrival
## is one placement.
func _paused() -> void:
	var host := _host()
	var fx = _effect(_node(30, {"u6": 1}), host)
	fx._process(0.05)
	var age: int = fx.sim.age
	E.pause_world(true)
	host.position += Vector3(50, 0, 0)
	for f in range(5):
		fx._process(0.05)
	_check(fx.sim.age == age and fx.sim.origin().is_equal_approx(Vector3.ZERO),
		"held: no step and no placement (age %d, origin %s)" % [fx.sim.age, str(fx.sim.origin())])
	E.pause_world(false)
	fx._process(0.05)
	_check(fx.sim.age == age + 1 and _farthest(fx, host) < 0.01, "released: one placement, one step, the follower on the host")
	fx.sim.clear()
	host.free()

## World3D's zone change (source checks): held from before the player is
## placed to the end of the arrival; the old frame's effects taken before
## the new grid is built and moved after it; no other re-placement touched.
func _world_calls() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	var zc := src.find("func _on_change_zone_result(")
	var body := src.substr(zc, src.find("\nfunc ", zc + 10) - zc)
	var taken := body.find("EfpEffect.placed_under(self)")
	var held := body.find("EfpEffect.pause_world(true)")
	var placed := body.find("player.position = Vector3(result.x, result.y, result.z)")
	var reload := body.find("_reload_zone_assets(result.zone, result.frame)")
	var shift := body.find("EfpEffect.shift_effects(fx_old_frame,")
	_check(taken >= 0 and held >= 0 and taken < placed and held < placed,
		"the zone change takes the old frame's effects and holds them before it places the player")
	_check(shift > reload and reload > 0, "... moves them by the frames' offset once the new grid is built")
	_check(body.rfind("EfpEffect.pause_world(false)") > body.find("await _drain_initial_load"),
		"... and lets them go once the arrival is laid out")
	var teardown := src.find("SkillEffects.clear_live()")
	var released := src.find("EfpEffect.pause_world(false)", teardown) if teardown > 0 else -1
	_check(released > teardown and released - teardown < 300,
		"a world torn down mid-load lets the effects go (the next world's are not held)")
	_check(not src.contains("carry_moved") and not src.contains("carry_begin"),
		"no other re-placement is treated apart: a move is motion (CEFEffect::vslot_007)")

func _finish() -> void:
	E.pause_world(false)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
