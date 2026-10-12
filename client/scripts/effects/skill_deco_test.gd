extends SceneTree

## Round 785: the cast decoration (SkillDeco), the skill-action tail
## (SkillHits), the re-use timers (SkillCooldowns) and the abnormal-state
## walk (StateLook), against synthetic rows -- never game data. Run headless:
## `godot4 --headless --path client --script res://scripts/effects/skill_deco_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_plan()
	_test_timeline()
	_test_wait_hold()
	_test_no_clips()
	_test_hits()
	_test_cooldowns()
	_test_state_walk()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

## SkillDeco.plan, as FUN_00a54f00 starts a decoration (READ).
func _test_plan() -> void:
	var D: GDScript = load("res://scripts/effects/skill_deco.gd")
	_check(D != null, "scripts/effects/skill_deco.gd loads (SkillDeco)")
	if D == null:
		return
	_check(String(D.plan({}, 0)["kind"]) == "none", "no skillaniset2 record: nothing is drawn")
	var none := {"group": "default", "ready": [], "wait": [], "shot": []}
	_check(String(D.plan(none, 7)["kind"]) == "none", "READY, WAIT and SHOT all none (Grass Walk, the imbues): nothing")
	_check(String(D.plan(none, 7, true)["kind"]) == "anim", "... unless the id is a system one (bit 31)")
	var fire := {"group": "default", "ready": [41], "wait": [92], "shot": [27]}
	var p: Dictionary = D.plan(fire, 3)
	_check(String(p["kind"]) == "anim" and int(p["ready"]) == 41 and int(p["wait"]) == 92 and int(p["shot"]) == 27
		and String(p["group"]) == "default", "Flame Wave E's record: READY02 41, WAIT02 92, SKILL_2 27 in DEFAULT")
	var base := {"group": "spear", "ready": [], "wait": [], "shot": [2, 5, 16, 17]}
	_check(int(D.plan(base, 0)["shot"]) == 2 and int(D.plan(base, 5)["shot"]) == 5 and int(D.plan(base, 6)["shot"]) == 16,
		"a list of four is picked by the decoration's byte modulo 4 (pick 0 -> 2, 5 -> 5, 6 -> 16)")
	var ghost := {"group": "default", "ready": [], "wait": [32], "shot": []}
	var g: Dictionary = D.plan(ghost, 0)
	_check(int(g["ready"]) == -1 and int(g["wait"]) == 32 and int(g["shot"]) == -1, "Ghost Walk: WAIT ANI_SKILL_7 (32) only")

func _clips(t: int) -> Dictionary:
	match t:
		41: return {"ms": 400, "events": []}
		92: return {"ms": 600, "events": []}
		27: return {"ms": 1000, "events": [300, 700]}
	return {}

func _kinds(actions: Array) -> Array:
	var out: Array = []
	for a in actions:
		match String(a[0]):
			"clip": out.append("clip:%d:%d%s" % [a[1], a[2], ":loop" if a[3] else ""])
			"group": out.append("group:%d:%d" % [a[1], a[2]])
			_: out.append(String(a[0]))
	return out

## The phases on the clips' own time, the groups on their events.
func _test_timeline() -> void:
	var D: GDScript = load("res://scripts/effects/skill_deco.gd")
	if D == null:
		return
	var p: Dictionary = D.plan({"group": "default", "ready": [41], "wait": [92], "shot": [27]}, 0)
	var d = D.new(1, p, _clips, 1000, 3000)
	var a0: Array = _kinds(d.tick(1000))
	_check(a0 == ["clip:0:41", "group:0:0"], "start: READY's clip and its group 0 (got %s)" % str(a0))
	var a1: Array = _kinds(d.tick(1399))
	_check(a1.is_empty(), "READY holds for its clip (got %s)" % str(a1))
	var a2: Array = _kinds(d.tick(1400))
	_check(a2 == ["clip:1:92:loop", "group:1:0"], "READY's end: the WAIT loop and its group 0 (got %s)" % str(a2))
	_check(_kinds(d.tick(2999)).is_empty() and d.phase == D.WAIT, "WAIT holds until the act or its due time")
	var a3: Array = _kinds(d.tick(3000))
	_check(a3 == ["clip:2:27", "group:2:0"], "due: SHOT -- its clip, group 0; the loops are kept (got %s)" % str(a3))
	var a4: Array = _kinds(d.tick(3300))
	_check(a4 == ["group:2:1"], "the SHOT clip's first hit event fires group 1 (got %s)" % str(a4))
	var a5: Array = _kinds(d.tick(4000))
	_check(a5 == ["group:2:2", "stop_loops", "end"], "its second event, then its end ends the decoration (got %s)" % str(a5))
	_check(d.is_done(), "the decoration is done")

## The WAIT hold: shot() ends it; no due time holds it for good.
func _test_wait_hold() -> void:
	var D: GDScript = load("res://scripts/effects/skill_deco.gd")
	if D == null:
		return
	var ghost: Dictionary = D.plan({"group": "default", "ready": [], "wait": [32], "shot": []}, 0)
	var d = D.new(114, ghost, func(_t): return {"ms": 800, "events": []}, 0, -1)
	var a0: Array = _kinds(d.tick(0))
	_check(a0 == ["clip:1:32:loop", "group:0:0", "group:1:0"],
		"Ghost Walk: the WAIT clip at the start (READ), READY's group, WAIT's (got %s)" % str(a0))
	_check(_kinds(d.tick(60000)).is_empty() and d.phase == D.WAIT, "with no due time the hold lasts")
	d.shot()
	var a1: Array = _kinds(d.tick(60001))
	_check(a1 == ["group:2:0", "stop_loops", "end"], "shot(): SHOT (no clip) and the end (got %s)" % str(a1))
	var e = D.new(114, ghost, func(_t): return {}, 0, -1)
	e.tick(0)
	_check(_kinds(e.cancel()) == ["stop_loops", "end"] and e.is_done(), "cancel() ends a held decoration")
	# shot() on a deco with no WAIT entry changes nothing (READ: FUN_00a53090).
	var f = D.new(3, D.plan({"group": "sword", "ready": [], "wait": [], "shot": [26]}, 0),
		func(_t): return {"ms": 500, "events": [200]}, 0, -1)
	f.shot()
	var a2: Array = _kinds(f.tick(0))
	_check(a2 == ["group:0:0", "group:1:0", "clip:2:26", "group:2:0"],
		"a SHOT-only skill goes to SHOT at once, READY's and WAIT's group 0 on the way (got %s)" % str(a2))

## A body with none of the clips: the phases advance at once.
func _test_no_clips() -> void:
	var D: GDScript = load("res://scripts/effects/skill_deco.gd")
	if D == null:
		return
	var p: Dictionary = D.plan({"group": "default", "ready": [41], "wait": [], "shot": [27]}, 0)
	var d = D.new(1, p, func(_t): return {}, 0, -1)
	var a: Array = _kinds(d.tick(0))
	_check(a == ["group:0:0", "group:1:0", "group:2:0", "stop_loops", "end"],
		"no clips: every group 0 fires and the decoration ends (got %s)" % str(a))

## SkillHits: the server lane's framing around retail's tail.
func _test_hits() -> void:
	var H: GDScript = load("res://scripts/net/skill_hits.gd")
	_check(H != null, "scripts/net/skill_hits.gd loads (SkillHits)")
	if H == null:
		return
	# Built byte by byte: tag, target 77, flags 1 (damage), 2 hits, 2 targets.
	var b := PackedByteArray([0xAB, 77, 0, 0, 0, 0x01, 2, 2])
	b.append_array(PackedByteArray([77, 0, 0, 0]))
	b.append(0x00) # hit 0: plain
	b.append_array(_u32((1200 << 8) | 0x01)); b.append_array(_u32(0))
	b.append(0x80 | 0x05) # hit 1: knockback, died
	b.append_array(_u32((800 << 8) | 0x02)); b.append_array(_u32(0x8))
	b.append_array(PackedByteArray([0xA8, 0x61])); b.append_array(_u32(100)); b.append_array(_u32(5)); b.append_array(_u32(200))
	b.append_array(PackedByteArray([78, 0, 0, 0]))
	b.append(0x02) # blocked
	b.append(0x07) # wall
	b.append_array(_u32((50 << 8) | 0x01)); b.append_array(PackedByteArray([10, 0, 100, 0]))
	b.append_array(PackedByteArray([1, 0])) # target kinds: monster, character
	b.append(1) # the leading target's kind
	var prefix := PackedByteArray([9, 9, 9])
	prefix.append_array(b)
	var h = H.decode(prefix, 3)
	_check(h != null and h.target_id == 77 and h.flags == 1 and h.hit_count == 2 and h.targets.size() == 2,
		"the tail decodes: target 77, flags 1, 2 hits on 2 targets")
	if h != null and h.targets.size() == 2:
		var t0 = h.targets[0]
		var t1 = h.targets[1]
		_check(t0.id == 77 and t0.id_kind == 1 and t1.id == 78 and t1.id_kind == 0, "per target: u32 id, nested hits; the kinds trail (OURS)")
		_check(t0.hits[0].kind == 0 and t0.hits[0].damage == 1200 and not t0.hits[0].critical(), "hit 0: 1200, normal")
		_check(t0.hits[1].kind == 5 and t0.hits[1].died and t0.hits[1].critical() and t0.hits[1].damage == 800
			and t0.hits[1].status_bits == 0x8 and t0.hits[1].region == 0x61a8 and t0.hits[1].point == Vector3(100, 5, 200),
			"hit 1: a knockback (kind 5) that killed, critical, 800, burn bit, region 0x61a8 at (100, 5, 200)")
		_check(t1.hits[0].blocked() and not t1.hits[0].hurts(), "kind 2 is a block, no damage")
		_check(t1.hits[1].kind == 7 and t1.hits[1].damage == 50 and t1.hits[1].wall_hp == 10 and t1.hits[1].wall_max == 100,
			"kind 7, a wall: damage 50, wall 10 / 100")
		_check(h.damage_from(77, 1, 1) == 800 and h.damage_from(77, 1, 0) == 2000, "damage still to come per target")
		_check(h.size == b.size(), "the whole tail is consumed (%d of %d bytes)" % [h.size, b.size()])
		_check(H.encode(h) == b, "encode() writes the same bytes back")
	_check(H.decode(prefix, 0) == null, "no tag: no tail")
	_check(H.decode(b.slice(0, 20), 0) == null, "a tail cut short is dropped")
	# A start's move only: flags 8 and the point.
	var m := PackedByteArray([0xAB, 5, 0, 0, 0, 0x08])
	m.append_array(PackedByteArray([0xA8, 0x61])); m.append_array(_u32(10)); m.append_array(_u32(0)); m.append_array(_u32(20))
	m.append(0)
	var mv = H.decode(m, 0)
	_check(mv != null and mv.has_move() and mv.move_region == 0x61a8 and mv.move_point == Vector3(10, 0, 20) and mv.targets.is_empty(),
		"a move (flags 8): region and point, no damage block")
	# OpAttackResult: the tail after the always-present wall suffix.
	var r := PackedByteArray([0, 0])
	r.resize(2 + 59)
	r.append_array(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	r.append_array(b)
	var ar := CombatNet.decode_attack_result(r)
	_check(ar.hits != null and ar.hits.hit_count == 2 and ar.wall == null,
		"OpAttackResult: the tail at payload offset 72, an all-zero wall suffix reads as no wall")
	var r2 := PackedByteArray([0, 0])
	r2.resize(2 + 59)
	_check(CombatNet.decode_attack_result(r2).hits == null, "an OpAttackResult without it decodes as before")

func _u32(v: int) -> PackedByteArray:
	var p := PackedByteArray()
	p.resize(4)
	p.encode_u32(0, v)
	return p

## SkillCooldowns: armed, refused by group, counted down, the tail.
func _test_cooldowns() -> void:
	var C: GDScript = load("res://scripts/world/skill_cooldowns.gd")
	_check(C != null, "scripts/world/skill_cooldowns.gd loads (SkillCooldowns)")
	if C == null:
		return
	var c = C.new()
	c.arm(3, 2, 3000)
	_check(c.remaining_ms(3, 2) == 3000 and is_equal_approx(c.ratio(3, 2), 1.0), "armed: 3000 ms left, sweep 1")
	_check(c.remaining_ms(4, 2) == 3000, "another skill of the same group (the next level) is refused too")
	_check(c.remaining_ms(5, 3) == 0, "a skill of another group is free")
	c.tick(1500)
	_check(c.remaining_ms(3, 2) == 1500 and is_equal_approx(c.ratio(3, 2), 0.5), "half way: 1500 left, sweep 0.5")
	c.tick(1500)
	_check(c.remaining_ms(3, 2) == 0 and is_equal_approx(c.flash(3, 2), 1.0), "done: free, the charged flash starts")
	c.tick(250)
	_check(is_equal_approx(c.flash(3, 2), 0.5), "the flash runs 500 ms")
	c.tick(250)
	c.tick(1)
	_check(c.count() == 0, "then the record goes")
	_check(C.delay_frame(1.0) == 0 and C.delay_frame(0.5) == 119 and C.delay_frame(0.0) == -1,
		"skill_delay.ddj's frame: ftol(239 - r * 239), none at 0")
	_check(C.charge_frame(1.0) == 0 and C.charge_frame(0.0) == -1, "skill_charge.ddj's frame: ftol(15 - f * 15)")
	c.arm(9, 0, 0)
	_check(c.count() == 0, "a skill with no re-use time arms nothing")

## StateLook.walk, as FUN_009cd5e0 walks a mask change (READ).
func _test_state_walk() -> void:
	var S: GDScript = load("res://scripts/effects/state_look.gd")
	_check(S != null, "scripts/effects/state_look.gd loads (StateLook)")
	if S == null:
		return
	var w: Dictionary = S.walk(0, 0x8 | 0x100, {})
	_check(w["on"] == [3, 8] and (w["tint"] as Array).size() == 2 and is_equal_approx(float(w["speed"]), 0.75),
		"burn + slow: two effects on, burn's pulse, clip speed 0.75")
	var w2: Dictionary = S.walk(0x8 | 0x100, 0x100, w)
	_check(w2["off"] == [3] and (w2["tint"] as Array).is_empty() and is_equal_approx(float(w2["speed"]), 0.75),
		"burn off: its pulse ends, slow stays")
	var w3: Dictionary = S.walk(0, 0x1, {})
	_check(bool(w3["frozen"]) and is_zero_approx(S.clip_speed(w3)), "frozen: the clips hold")
	var w4: Dictionary = S.walk(0x1, 0, w3)
	_check(not bool(w4["frozen"]) and is_equal_approx(S.clip_speed(w4), 1.0), "thawed: the clips run")
	_check(S.effect_id(3) == "PARAM_BU" and S.effect_id(14) == "PARAM_STUN" and S.effect_id(12) == "",
		"the decoration names: PARAM_BU, PARAM_STUN; bit 12 none")
