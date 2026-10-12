extends RefCounted
class_name FxDriftProbe

## Round 786 (QA, OPENSRO_QA_FXDRIFT): where the effects on a body draw their
## particles against where each effect is placed, sampled over a scripted
## stand / walk / turn / teleport. The user's report: "Seal and skill effects
## will float or fly off from that character" -- a Chinese character just
## teleported from Donwhang to Jangan, its buffs' auras and its seal weapon's
## particles drawn away from the body.
##
## Every sample walks the EfpEffects under the body (its skill effects and
## auras, SkillEffects.attach; its weapon's own world-space seal simulation,
## EquipFx's EquipFxOwn) and measures each drawn particle's world position
## against the effect's placement point (EfpEffect.placed_at: the bone plus
## the row's offset). An effect's BOUND is the farthest any of its drawn
## particles stood from that point while the body stood still in the first
## phase ("stand", the baseline): its own authored spread on a still host,
## measured, not assumed. A drawn particle farther than bound + TOL is PAST,
## and NEAR as well while it is within NEAR of the body: in sight beside it.
##
## Lines (one per sample and effect with drawn particles):
##   QA FXDRIFT tick <t> phase <p> <path> far <d> bound <b> past <n> near <n> drawn <n>
## and at each phase change and the end, one per phase:
##   QA FXDRIFT PHASE <p> effects <n> samples <n> past_samples <n>
##       past_particles <n> near_samples <n> near_particles <n> worst +<excess> <path>
## A body move larger than MOVE_LOG units between two samples prints
##   QA FXDRIFT MOVE tick <t> from <v> to <v> (<d> units)
## so the teleport's re-placements are lined up with what the effects did.
## Reads the player's archives at runtime and prints only numbers and paths.

## OURS: how far past its still bound a drawn particle may stand before it
## counts as off the body.
const TOL := 10.0
## A PAST particle nearer than this to the placement point is NEAR: in sight
## of the body (OURS; the original draws a character's particle mods only
## within 720 of the camera, READ round 761).
const NEAR := 2000.0
const MOVE_LOG := 5.0

## path (lower case) -> bound (native units).
var bounds: Dictionary = {}
var phase := "stand"
var _stats: Dictionary = {}
var _last_body := Vector3.INF
var verbose := true

func set_phase(p: String, tick: int) -> void:
	if p == phase:
		return
	_report_phase(phase)
	print("QA FXDRIFT tick %d phase %s -> %s" % [tick, phase, p])
	phase = p

func finish() -> void:
	_report_phase(phase)

func _report_phase(p: String) -> void:
	var s: Dictionary = _stats.get(p, {})
	if s.is_empty():
		print("QA FXDRIFT PHASE %s: no samples" % p)
		return
	print("QA FXDRIFT PHASE %s effects %d samples %d past_samples %d past_particles %d near_samples %d near_particles %d worst +%.1f %s (far %.1f bound %.1f)" % [
		p, (s["effects"] as Dictionary).size(), s["samples"], s["past_samples"], s["past_particles"],
		s["near_samples"], s["near_particles"], s["worst"], s["worst_path"], s["worst_far"], s["worst_bound"]])

## One sample of every effect under `body`.
func sample(body: Node3D, tick: int) -> void:
	if body == null or not is_instance_valid(body):
		return
	var at := body.global_position
	if _last_body != Vector3.INF and at.distance_to(_last_body) > MOVE_LOG:
		print("QA FXDRIFT MOVE tick %d from %s to %s (%.1f units)" % [tick, _last_body, at, at.distance_to(_last_body)])
	_last_body = at
	var s: Dictionary = _stats.get(phase, {})
	if s.is_empty():
		s = {"effects": {}, "samples": 0, "past_samples": 0, "past_particles": 0, "worst": 0.0,
			"worst_path": "-", "worst_far": 0.0, "worst_bound": 0.0, "near_samples": 0, "near_particles": 0}
		_stats[phase] = s
	for n in body.find_children("*", "EfpEffect", true, false):
		var fx := n as EfpEffect
		if fx == null or fx.sim == null or fx.is_queued_for_deletion() or not fx.is_visible_in_tree():
			continue
		var m := measure(fx)
		if int(m["drawn"]) == 0:
			continue
		var key := fx.path.to_lower()
		var far: float = m["far"]
		if phase == "stand":
			bounds[key] = maxf(float(bounds.get(key, 0.0)), far)
		var bound: float = bounds.get(key, -1.0)
		var past := 0
		var near := 0
		if bound >= 0.0:
			past = count_past(fx, bound + TOL)
			near = count_past(fx, bound + TOL, NEAR)
		(s["effects"] as Dictionary)[key] = true
		s["samples"] += 1
		s["near_particles"] += near
		if near > 0:
			s["near_samples"] += 1
		if past > 0:
			s["past_samples"] += 1
			s["past_particles"] += past
			if far - bound > float(s["worst"]):
				s["worst"] = far - bound
				s["worst_path"] = fx.path
				s["worst_far"] = far
				s["worst_bound"] = bound
		if verbose:
			print("QA FXDRIFT tick %d phase %s %s far %.1f bound %.1f past %d near %d drawn %d" % [tick, phase, fx.path,
				far, bound, past, near, m["drawn"]])

## The nodes an effect draws (its plates and meshes, and its Link strips).
static func drawn_tpls(fx: EfpEffect) -> Dictionary:
	var drawn := {}
	for d in fx._draws:
		drawn[int(d[0])] = true
	for d in fx._links:
		drawn[int(d[0])] = true
	return drawn

## Where one particle of `fx` is in the world: the simulation's space is the
## effect node's own (its anchor once placed on a host, EfpEffect._place).
static func world_of(fx: EfpEffect, p: EfpSim.Particle) -> Vector3:
	return fx.global_transform * p.pos

## {far: the farthest drawn particle from the effect's placement point,
## drawn: how many particles it draws}.
static func measure(fx: EfpEffect) -> Dictionary:
	var drawn := drawn_tpls(fx)
	var ref := fx.placed_at()
	var far := 0.0
	var n := 0
	for p in fx.sim.particle_list():
		if not drawn.has(p.tpl):
			continue
		n += 1
		far = maxf(far, world_of(fx, p).distance_to(ref))
	return {"far": far, "drawn": n}

## The drawn particles farther than `limit` from the placement point (and
## nearer than `within`).
static func count_past(fx: EfpEffect, limit: float, within: float = INF) -> int:
	var drawn := drawn_tpls(fx)
	var ref := fx.placed_at()
	var n := 0
	for p in fx.sim.particle_list():
		if not drawn.has(p.tpl):
			continue
		var d := world_of(fx, p).distance_to(ref)
		if d > limit and d < within:
			n += 1
	return n
