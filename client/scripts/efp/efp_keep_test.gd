extends SceneTree

## Round 623: a kept (AT_LOOP) effect stays on screen, as retail's does.
## Synthetic trees shaped like the retail auras (a 20-frame RenderNone root
## that emits once, 20-frame drawn children that emit for 20 frames) -- never
## game data. Run headless:
## `godot4 --headless --path client --script res://scripts/efp/efp_keep_test.gd`
##
## The rules under test are READ (EfpSim "Dying, and the kept effect", "An
## emitter's life"): a kept effect's root particles are revived at age 0
## instead of dying (CEFEffect::vslot_000), an emitter's done flag is
## recomputed every frame (0x00c84e70), and a death is queued and flushed at
## the next update's start (CEFUpdater::vslot_002). Only fields and calls
## that existed before round 623 are used, so this suite runs (and fails)
## against the earlier code as well.

var _failures := 0
var S: GDScript
var E: GDScript
var _tex: Texture2D
var _host: Node3D

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
	return c

func _emit(delay: int, duration: int, interval: int, max_live: int, per: float) -> EfpReader.EfpCommand:
	return _cmd("StaticEmit", {"type": "SEFStaticEmit", "delay": delay, "duration": duration,
		"interval": interval, "max_live": max_live, "per_trigger": per})

func _node(frames: int, life: String, emit: EfpReader.EfpCommand, render: String = "RenderNone") -> EfpReader.EfpNode:
	var n := EfpReader.EfpNode.new()
	n.name = "n"
	n.frames = frames
	n.extinct = _cmd(life)
	if emit != null:
		n.emit.append(emit)
	n.view = _cmd("ViewNone")
	n.render = _cmd(render)
	var st := EfpReader.EfpRenderState.new()
	st.src_blend = 5
	st.dest_blend = 2
	n.state = st
	var ref := EfpReader.EfpMeshRef.new()
	ref.textures = PackedStringArray(["t.ddj"])
	n.meshes.append(ref)
	return n

## The retail aura's shape (MEASURED on lightning_gyeonggong_keep_a /
## cold_gigongta_keep_a, round 623): a 20-frame root that emits once, drawn
## children of 20 frames that each keep one particle for 20 frames, and one
## that adds a second particle at frame 10.
func _aura_tree() -> EfpReader.EfpNode:
	var root := _node(20, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0))
	for _i in range(3):
		root.children.append(_node(20, "NormalTimeExtinct", _emit(0, 20, 1, 1, 1.0), "RenderPlate"))
	root.children.append(_node(20, "NormalTimeExtinct", _emit(0, 20, 10, 2, 1.0), "RenderPlate"))
	return root

func _effect(root: EfpReader.EfpNode, kept: bool):
	var fx = E.from_template(S.compile(root), func(p: String): return _tex if p == "t.ddj" else null,
		func(_p: String): return null, 5)
	fx.loop = kept
	_host.add_child(fx)
	return fx

## Particles drawn this frame: the MultiMeshes' visible instances.
func _drawn(fx) -> int:
	var n := 0
	for d in fx._draws:
		n += (d[1] as MultiMeshInstance3D).multimesh.visible_instance_count
	return n

func _initialize() -> void:
	S = load("res://scripts/efp/efp_sim.gd")
	E = load("res://scripts/efp/efp_effect.gd")
	_tex = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	_host = Node3D.new()
	get_root().add_child(_host)
	_kept_aura_is_continuous()
	_unkept_plays_once()
	_emitter_restarts_with_its_owner()
	_death_is_drawn_then_flushed()
	_kept_that_cannot_keep_ends()
	_stop_ends_kept()
	# Round 623's review follow-up.
	_kept_retries_a_refused_root()
	_kept_children_still_die()
	_revived_root_keeps_its_followers()
	_revived_root_keeps_its_link_chain()
	_oneshot_guard()
	_inline_tick_matches_emit_tick()
	_host.queue_free()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

## The user's report on v0.1.457: the auras blinked out every cycle. Over 30
## s (600 frames) of a kept aura, no frame draws nothing, the root particle
## is the same one throughout, and the effect never finishes.
func _kept_aura_is_continuous() -> void:
	var fx = _effect(_aura_tree(), true)
	var zero_frames: Array = []
	var fewest := 1 << 30
	var root_obj = null
	var root_same := true
	for f in range(600):
		fx._process(0.05)
		var dn := _drawn(fx)
		if dn == 0:
			zero_frames.append(f)
		fewest = mini(fewest, dn)
		for p in fx.sim.particles:
			if p.tpl == 0:
				if root_obj == null:
					root_obj = p
				elif p != root_obj:
					root_same = false
	_check(zero_frames.is_empty(), "a kept aura draws something on every one of 600 frames (blank frames: %s)" %
		str(zero_frames.slice(0, 8)))
	_check(fewest >= 4, "... every drawn child keeps a particle across the cycle boundary (fewest drawn %d, want 4)" % fewest)
	_check(root_same and root_obj != null, "... its root particle is revived at age 0, never replaced (READ, CEFEffect::vslot_000)")
	_check(not fx.is_queued_for_deletion(), "... and the kept effect never ends by itself")
	var spawned_children: int = fx.sim.spawned - 1
	# 3 nodes x 1 a cycle + 1 node x 2 a cycle, 30 cycles of 20 frames.
	_check(spawned_children == 150, "... the children re-emit every 20-frame cycle: %d spawns in 600 frames (want 150)" % spawned_children)
	fx.stop()

## The same tree, not kept (an ACT_L played once without a buff token, or any
## one-shot): one 20-frame cycle, drawn for all 20 frames, then it ends.
func _unkept_plays_once() -> void:
	var fx = _effect(_aura_tree(), false)
	var drawn_frames := 0
	var ended_at := -1
	for f in range(60):
		fx._process(0.05)
		if fx.is_queued_for_deletion():
			ended_at = f
			break
		if _drawn(fx) >= 4:
			drawn_frames += 1
	_check(drawn_frames == 20, "a one-shot draws its 20-frame children for 20 frames (%d)" % drawn_frames)
	_check(ended_at >= 20 and ended_at <= 31, "... and then ends by itself (frame %d)" % ended_at)

## An emitter is not latched done (READ, 0x00c84e70): a child emitter of a
## NormalTimeLoop parent emits again every time the parent's age wraps.
func _emitter_restarts_with_its_owner() -> void:
	var root := _node(10, "NormalTimeLoop", _emit(0, 1, 1, 1, 1.0))
	root.children.append(_node(3, "NormalTimeExtinct", _emit(0, 2, 1, 2, 1.0), "RenderPlate"))
	var sim = S.new(S.compile(root), 3)
	var at: Array = []
	for f in range(40):
		var before: int = sim.spawned
		sim.step()
		if sim.spawned > before:
			at.append(f)
	_check(at == [0, 1, 10, 11, 20, 21, 30, 31],
		"a child emitter of a looping parent emits again at each wrap: frames %s (want [0, 1, 10, 11, 20, 21, 30, 31])" % str(at))
	sim.clear()

## A death is queued and the particle drawn at its last frame; the flush at
## the next frame's start refunds the emitter first, so a max_live-1 emitter
## replaces a 4-frame particle with no frame in between.
func _death_is_drawn_then_flushed() -> void:
	var sim = S.new(S.compile(_node(4, "NormalTimeExtinct", _emit(0, 40, 1, 1, 1.0), "RenderPlate")), 3)
	var counts: Array = []
	for _f in range(16):
		sim.step()
		counts.append(sim.particles.size())
	_check(not counts.has(0), "an emitter replaces its dying particle with no empty frame: %s" % str(counts))
	_check(sim.spawned == 4, "... one 4-frame particle after another: 4 spawned in 16 frames (%d)" % sim.spawned)
	sim.clear()

## A kept effect that has nothing alive and nothing to emit -- and whose
## root no budget refused -- is released, not started over (READ:
## CRTModParticle::FUN_00c80ff0 drops it when CEFEffect::vslot_000 returns
## 0). The budget case is _kept_retries_a_refused_root.
func _kept_that_cannot_keep_ends() -> void:
	var fx = _effect(_node(5, "NormalTimeExtinct", _emit(0, 1, 1, 1, 0.0), "RenderPlate"), true)
	var restarted := false
	for _f in range(10):
		fx._process(0.05)
		if fx.sim.age < 1 and not fx.is_queued_for_deletion():
			restarted = true
	_check(fx.is_queued_for_deletion() and not restarted and fx.sim.dropped == 0,
		"a kept effect that emits nothing (and had nothing refused) ends instead of restarting")

## stop() still ends a kept effect at once (READ, the interface's release).
func _stop_ends_kept() -> void:
	var fx = _effect(_aura_tree(), true)
	for _f in range(30):
		fx._process(0.05)
	var live_before: int = S.live_total
	var held: int = fx.sim.particles.size()
	fx.stop()
	_check(fx.is_queued_for_deletion() and fx.sim.particles.is_empty() and S.live_total == live_before - held,
		"stop() ends a kept aura at once: every particle goes")

## OURS, the review's first finding: the particle budget (retail has none)
## refused a kept aura's root -- say a crowd's auras filled it. The aura
## retries its root every frame and comes on once there is room, instead of
## ending for the rest of the buff.
func _kept_retries_a_refused_root() -> void:
	var saved: int = S.live_total
	S.live_total = 1000000
	var fx = _effect(_aura_tree(), true)
	for _f in range(5):
		fx._process(0.05)
	var alive_while_full: bool = not fx.is_queued_for_deletion()
	S.live_total = saved
	for _f in range(5):
		fx._process(0.05)
	_check(alive_while_full and not fx.is_queued_for_deletion() and _drawn(fx) >= 4,
		"a kept aura whose root the budget refused waits and comes on when there is room (drawn %d)" % _drawn(fx))
	fx.stop()

## Only the root is revived: the children of a kept effect die as usual,
## each replaced by a new particle.
func _kept_children_still_die() -> void:
	var fx = _effect(_aura_tree(), true)
	fx._process(0.05)
	var first: Array = []
	for p in fx.sim.particles:
		if p.tpl != 0:
			first.append(p)
	for _f in range(25):
		fx._process(0.05)
	var survivors := 0
	for p in first:
		if fx.sim.particles.has(p) or p.alive:
			survivors += 1
	_check(first.size() == 4 and survivors == 0,
		"a kept effect's child particles still die: %d of the first cycle's %d alive after 26 frames" % [survivors, first.size()])
	fx.stop()

## A revived root keeps the particles that follow it (u2 orbit, u6
## translation): through a revival, while the effect turns and moves, every
## child stays 5 units from the root.
func _revived_root_keeps_its_followers() -> void:
	var root := _node(20, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0))
	root.flags = {"b0": 1, "b1": 1, "u2": 1, "u3": 1, "u6": 1}
	var kid := _node(20, "NormalTimeExtinct", _emit(0, 20, 5, 4, 1.0), "RenderPlate")
	kid.flags = {"b1": 1, "u2": 1, "u6": 1}
	kid.commands.append(_pos_cmd(Vector3(5, 0, 0)))
	root.children.append(kid)
	var sim = S.new(S.compile(root), 3)
	sim.keep = true
	var worst := 0.0
	var seen := 0
	var root_obj = null
	var same := true
	for f in range(60):
		sim.set_origin(Vector3(f * 0.5, 0, 0), Basis(Vector3.UP, f * 0.1))
		sim.step()
		var r = null
		for p in sim.particles:
			if p.tpl == 0:
				r = p
		if root_obj == null:
			root_obj = r
		elif r != root_obj:
			same = false
		for p in sim.particles:
			if p.tpl == 1 and not p.dying:
				worst = maxf(worst, absf((p.pos - r.pos).length() - 5.0))
				seen += 1
	_check(same and seen > 100 and worst < 0.001 and sim.revived == 3,
		"through 3 revivals, u2/u6 children stay 5 from the moving, turning root (worst error %.4f over %d particle-frames)" % [worst, seen])
	sim.clear()

func _pos_cmd(v: Vector3) -> EfpReader.EfpCommand:
	var c := _cmd("SetPosition", {"value": v})
	c.space = 1 # o = 1: from the parent particle's position
	c.step = 1.0 # one key, at frame 0
	return c

## A revived root keeps its Link child's chain: the child emitter is the same
## emitter across the revival, so its strip never breaks into two or empties.
func _revived_root_keeps_its_link_chain() -> void:
	var root := _node(20, "NormalTimeExtinct", _emit(0, 1, 1, 1, 1.0))
	root.children.append(_node(20, "NormalTimeExtinct", _emit(0, 20, 1, 20, 1.0), "RenderLinkPipe"))
	var fx = _effect(root, true)
	var bad: Array = []
	for f in range(70):
		fx._process(0.05)
		var chains: Dictionary = E.link_chains(fx.sim, {1: true})
		var n: int = (chains[1] as Array).size() if chains.has(1) else 0
		var len: int = (chains[1][0] as Array).size() if n > 0 else 0
		if f >= 1 and (n != 1 or len < 2):
			bad.append("%d:%dx%d" % [f, n, len])
	_check(bad.is_empty(), "a Link child keeps one unbroken chain of 2+ through the root's revivals (bad frames %s)" % str(bad.slice(0, 6)))
	fx.stop()

## OURS guard, the review's second finding: a one-shot whose particles never
## run out (a NormalTimeLoop node re-arming its children) ends after
## ONESHOT_MAX_LIFE; a kept effect does not.
func _oneshot_guard() -> void:
	var root := _node(10, "NormalTimeLoop", _emit(0, 1, 1, 1, 1.0))
	root.children.append(_node(3, "NormalTimeExtinct", _emit(0, 2, 1, 2, 1.0), "RenderPlate"))
	var once = _effect(root, false)
	var kept = _effect(root, true)
	var ended_at := -1.0
	var t := 0.0
	while t < E.ONESHOT_MAX_LIFE + 2.0:
		once._process(0.05)
		kept._process(0.05)
		t += 0.05
		if ended_at < 0.0 and once.is_queued_for_deletion():
			ended_at = t
	_check(ended_at >= E.ONESHOT_MAX_LIFE - 0.06 and ended_at <= E.ONESHOT_MAX_LIFE + 0.06,
		"a one-shot that never runs out ends at ONESHOT_MAX_LIFE (%.2f s)" % ended_at)
	_check(not kept.is_queued_for_deletion(), "... a kept one does not")
	kept.stop()

## The allocation-free emitter frame gives what EfpReader.emit_tick gives,
## over ages, accumulators and both quality globals.
func _inline_tick_matches_emit_tick() -> void:
	var cases := [[0, 30, 3, 10, 1.0], [5, 20, 1, 4, 0.5], [0, 1, 1, 1, 1.0], [2, 40, 4, 12, 2.5],
		[0, 10, 0, 5, 1.0], [0, 20, 10, 2, 1.0]]
	var mismatches := 0
	var saved_mul: int = S.interval_mul
	var saved_thr: int = S.threshold
	for globals in [[0, 0], [2, 10], [5, 10]]:
		S.interval_mul = globals[0]
		S.threshold = globals[1]
		for c in cases:
			var n := _node(10, "NormalTimeExtinct", _emit(c[0], c[1], c[2], c[3], c[4]))
			var tp = S.compile(n).tpls[0]
			for age in range(-2, 50):
				for acc in [0.0, 0.5, 1.0, 3.7, 11.0]:
					var e = S.Emitter.new()
					e.acc = acc
					var got: int = S.emit_spawns(tp, age, e)
					var want: Dictionary = EfpReader.emit_tick(tp.emit, age, acc, globals[0], globals[1])
					if got != maxi(int(want["spawn"]), 0) or not is_equal_approx(e.acc, float(want["acc"])) \
							or e.done != bool(want["stopped"]):
						mismatches += 1
	S.interval_mul = saved_mul
	S.threshold = saved_thr
	_check(mismatches == 0, "the inline emitter frame matches EfpReader.emit_tick everywhere (%d mismatches)" % mismatches)
