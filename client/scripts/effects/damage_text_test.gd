extends SceneTree

## Round 786: the combat numbers (DamageText), READ from sro_client.exe's
## CIDamageText (FUN_00a47720, CIDamageText::vslot_009, FUN_00a62860), and
## World3D's glue that makes one per hit. No game data: the art is not loaded,
## so the numbers here are the fallback's; the layout, colours and motion are
## the read values. Run headless on the render box:
## `client/tools/remote_godot.sh tests`.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _approx(a: float, b: float, eps: float = 0.0001) -> bool:
	return absf(a - b) <= eps

func _initialize() -> void:
	_test_art()
	_test_colour()
	_test_shows()
	_test_layout()
	_test_motion()
	_test_create()
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var ok := world_script != null and world_script.can_instantiate()
	_check(ok, "World3D compiles")
	if ok:
		# A node added in _initialize is in the tree only after a frame
		# (combat785_test's note).
		var watchdog := create_timer(60.0)
		watchdog.timeout.connect(func() -> void:
			print("FAIL the suite never reported (a script error stopped it)")
			quit(1))
		await _test_world_glue(world_script)
		await _test_swing_numbers(world_script)
		_test_hit_offsets(world_script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _test_art() -> void:
	_check(DamageText.art_of(0, 1, 0) == DamageText.Art.NUMBER, "kind 0, flags 1: the plain number")
	_check(DamageText.art_of(0, 2, 0) == DamageText.Art.CRITICAL, "kind 0, flags 2: the critical")
	_check(DamageText.art_of(0, 2 | 4, 0x10) == DamageText.Art.CRITICAL, "a critical in HWAN with states is still the critical")
	_check(DamageText.art_of(4, 2, 0) == DamageText.Art.CRITICAL, "kind 4 (knockdown) shows its critical")
	_check(DamageText.art_of(5, 2, 0) == DamageText.Art.NUMBER, "kind 5 (knockback) never shows the critical (READ: only kinds 0 and 4 test flags & 2)")
	_check(DamageText.art_of(2, 0, 0) == DamageText.Art.BLOCK, "kind 2: the block word")
	_check(DamageText.art_of(7, 2, 0) == DamageText.Art.NUMBER, "kind 7 (a wall): the plain number")
	_check(DamageText.art_of(8, 0, 0) == DamageText.Art.NUMBER, "kind 8 (void): a plain number (of 0: nothing drawn)")
	_check(DamageText.art_of(0, 0x10, 0) == DamageText.Art.RESIST, "an effect-only hit that landed no state: the resist word")
	_check(DamageText.art_of(0, 0x10, 0x4) == DamageText.Art.NUMBER, "an effect-only hit that landed a state: no resist")
	_check(DamageText.art_of(2, 0x10, 0) == DamageText.Art.RESIST, "resist overrides the block (READ: tested after the kind)")

func _test_colour() -> void:
	_check(DamageText.colour_of(false, true) == Color8(255, 255, 255), "a character's blow on a monster: white")
	_check(DamageText.colour_of(true, true) == Color8(0xFF, 0x3A, 0x3A), "a character's (a monster's) blow on a player: 0xFF3A3A")
	_check(DamageText.colour_of(true, false) == Color8(0xFF, 0xD3, 0x3A), "a state's tick on a player: 0xFFD33A")
	_check(DamageText.colour_of(false, false) == Color8(0xFF, 0x71, 0x3A), "a state's tick on a monster: 0xFF713A")
	_check(DamageText.colour_of(true, true, true) == Color8(0x3A, 0x3A, 0xFF), "the arena's: 0x3A3AFF")

func _test_shows() -> void:
	_check(DamageText.shows(1000.0, true), "this player's own blow shows at any distance")
	_check(DamageText.shows(199.9, false), "another's within 200 units shows")
	_check(not DamageText.shows(200.0, false), "another's at 200 units does not (strictly nearer, 0xe1b8b8)")

func _test_layout() -> void:
	var s := DamageText.sprites_of(DamageText.Art.NUMBER, 1234)
	_check(s.size() == 4, "1234: four digit sprites (%d)" % s.size())
	if s.size() == 4:
		_check(String(s[0]["file"]) == "hitcount_1" and String(s[3]["file"]) == "hitcount_4", "left to right 1, 2, 3, 4")
		_check(s[0]["size"] == Vector2(24, 40), "a plain digit is 24 x 40 (0xec5c78)")
		# Centred row advancing 22: centres at -33, -11, 11, 33.
		_check(_approx(s[0]["pos"].x, -33.0 - 12.0) and _approx(s[3]["pos"].x, 33.0 - 12.0),
			"the row is centred, advancing 22 (%s .. %s)" % [s[0]["pos"], s[3]["pos"]])
		_check(_approx(s[1]["pos"].y, -20.0), "a digit is centred on the anchor vertically")
	var c := DamageText.sprites_of(DamageText.Art.CRITICAL, 56)
	_check(c.size() == 3, "a critical: the word and its digits (%d)" % c.size())
	if c.size() == 3:
		_check(String(c[0]["file"]) == "critical" and c[0]["size"] == Vector2(96, 24), "the critical word first, 96 x 24 (0xec5c48)")
		_check(_approx(c[0]["pos"].y, -12.0 + 45.0), "the word 45 below the digits' centre (0xde5538)")
		_check(c[1]["size"] == Vector2(36, 60), "a critical digit is 36 x 60")
		_check(_approx(c[1]["pos"].x, -16.5 - 18.0) and _approx(c[2]["pos"].x, 16.5 - 18.0), "advancing 33")
	var b := DamageText.sprites_of(DamageText.Art.BLOCK, 99)
	_check(b.size() == 1 and String(b[0]["file"]) == "blocking" and b[0]["size"] == Vector2(60, 28),
		"a block: the blocking word alone, no digits")
	var r := DamageText.sprites_of(DamageText.Art.RESIST, 0)
	_check(r.size() == 1 and String(r[0]["file"]) == "resist", "a resist: the resist word alone")
	_check(DamageText.sprites_of(DamageText.Art.NUMBER, 0).is_empty(), "a plain 0: nothing")
	_check(DamageText.sprites_of(DamageText.Art.CRITICAL, 0).size() == 1, "a critical of 0: the word alone")
	_check(_approx(DamageText.ART_SCALE[DamageText.Art.BLOCK], 2.0) and _approx(DamageText.ART_SCALE[DamageText.Art.NUMBER], 1.0),
		"the words of a block or a resist draw at scale 2.0, the rest at 1.0")

func _test_motion() -> void:
	_check(_approx(DamageText.rise_at(0.0), 0.0) and _approx(DamageText.rise_at(0.5), 25.0)
		and _approx(DamageText.rise_at(1.0), 50.0) and _approx(DamageText.rise_at(3.0), 50.0),
		"rises 50 reference pixels over 1.0 s, linearly")
	_check(_approx(DamageText.alpha_at(0.0), 1.0) and _approx(DamageText.alpha_at(0.5), 1.0),
		"opaque for the first half second (the 2.0 -> 0 track clamped)")
	_check(_approx(DamageText.alpha_at(0.75), 0.5) and _approx(DamageText.alpha_at(1.0), 0.0),
		"then fades linearly to nothing at 1.0 s")

func _test_create() -> void:
	_check(DamageText.create(Vector3.ZERO, DamageText.Art.NUMBER, 0, Color.WHITE) == null, "no object for a plain 0")
	var n := DamageText.create(Vector3(1, 2, 3), DamageText.Art.CRITICAL, 77, Color.WHITE)
	_check(n != null and n.anchor().is_equal_approx(Vector3(1, 22, 3)), "the anchor is 20 units over the feet (0xe1b830)")
	if n != null:
		n.free()

func _numbers(world: Node) -> Array:
	var out: Array = []
	for c in world.get_children():
		if c is DamageText:
			out.append(c)
	return out

func _clear(world: Node) -> void:
	for c in _numbers(world):
		world.remove_child(c)
		c.free()

func _test_world_glue(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	root.add_child(player)
	world.set("player", player)
	var mob := Node3D.new()
	root.add_child(mob)
	mob.position = Vector3(10, 0, 0)
	await process_frame
	var crit := SkillHits.Hit.new()
	crit.kind = 0
	crit.flags = 2
	crit.damage = 345
	world.call("_damage_text_of_hit", mob, crit, false, true)
	var got := _numbers(world)
	_check(got.size() == 1, "a critical entry on a monster makes one number (%d)" % got.size())
	if got.size() == 1:
		var d: DamageText = got[0]
		_check(d.art() == DamageText.Art.CRITICAL and d.damage() == 345, "its art is the critical")
		_check(d.colour() == Color8(255, 255, 255), "white on a monster")
	_clear(world)
	var plain := SkillHits.Hit.new()
	plain.flags = 1
	plain.damage = 12
	world.call("_damage_text_of_hit", player, plain, true, false)
	got = _numbers(world)
	_check(got.size() == 1 and (got[0] as DamageText).colour() == Color8(0xFF, 0x3A, 0x3A), "red on this player")
	_clear(world)
	mob.position = Vector3(250, 0, 0)
	world.call("_damage_text_of_hit", mob, plain, false, false)
	_check(_numbers(world).is_empty(), "another's blow 250 units away: no number")
	world.call("_damage_text_of_hit", mob, plain, false, true)
	_check(_numbers(world).size() == 1, "this player's own blow 250 units away: a number")
	_clear(world)
	mob.position = Vector3(150, 0, 0)
	var blocked := SkillHits.Hit.new()
	blocked.kind = 2
	world.call("_damage_text_of_hit", mob, blocked, false, false)
	got = _numbers(world)
	_check(got.size() == 1 and (got[0] as DamageText).art() == DamageText.Art.BLOCK, "another's blocked hit 150 away: the block word")
	_clear(world)
	var void_hit := SkillHits.Hit.new()
	void_hit.kind = 8
	world.call("_damage_text_of_hit", mob, void_hit, false, true)
	_check(_numbers(world).is_empty(), "a void hit: nothing")
	world.call("_damage_text", player, DamageText.Art.NUMBER, 40, true, false, false)
	got = _numbers(world)
	_check(got.size() == 1 and (got[0] as DamageText).colour() == Color8(0xFF, 0xD3, 0x3A), "a state's tick on this player: gold")
	_clear(world)
	var loose := Node3D.new()
	world.call("_damage_text", loose, DamageText.Art.NUMBER, 40, false, true)
	_check(_numbers(world).is_empty(), "a body out of the tree: nothing")
	loose.free()
	world.free()
	player.queue_free()
	mob.queue_free()

func _test_swing_numbers(world_script: GDScript) -> void:
	var world: Node = world_script.new()
	var player := CharacterBody3D.new()
	root.add_child(player)
	world.set("player", player)
	var mob := Node3D.new()
	root.add_child(mob)
	await process_frame
	var result := CombatNet.AttackResult.new()
	result.monster_damage = 30
	result.player_critical = true
	world.call("_swing_numbers", mob, 9, result, [0.0])
	var got := _numbers(world)
	_check(got.size() == 1 and (got[0] as DamageText).art() == DamageText.Art.CRITICAL and (got[0] as DamageText).damage() == 30,
		"no hit block: the result's sum, critical by PlayerCritical")
	_clear(world)
	var hits := SkillHits.new()
	var t := SkillHits.Target.new()
	t.id = 9
	t.id_kind = SkillNet.OWNER_MONSTER
	for spec in [[0, 1, 10], [0, 2, 25]]:
		var h := SkillHits.Hit.new()
		h.kind = spec[0]
		h.flags = spec[1]
		h.damage = spec[2]
		t.hits.append(h)
	hits.targets.append(t)
	result.hits = hits
	result.player_critical = true
	# Out of the tree _after runs at once: both hits draw now.
	world.call("_swing_numbers", mob, 9, result, [0.0, 0.3])
	got = _numbers(world)
	_check(got.size() == 2, "a two-hit swing: one number per hit (%d)" % got.size())
	if got.size() == 2:
		_check((got[0] as DamageText).art() == DamageText.Art.NUMBER and (got[0] as DamageText).damage() == 10
			and (got[1] as DamageText).art() == DamageText.Art.CRITICAL and (got[1] as DamageText).damage() == 25,
			"each with its own art and damage, not the sum")
	_clear(world)
	var blocked_t := SkillHits.Target.new()
	blocked_t.id = 9
	blocked_t.id_kind = SkillNet.OWNER_MONSTER
	var bh := SkillHits.Hit.new()
	bh.kind = 2
	blocked_t.hits.append(bh)
	var bhits := SkillHits.new()
	bhits.targets.append(blocked_t)
	result.hits = bhits
	result.monster_damage = 0
	world.call("_swing_numbers", mob, 9, result, [])
	got = _numbers(world)
	_check(got.size() == 1 and (got[0] as DamageText).art() == DamageText.Art.BLOCK, "a blocked swing: the block word over the monster")
	_clear(world)
	world.free()
	player.queue_free()
	mob.queue_free()

func _test_hit_offsets(world_script: GDScript) -> void:
	var entry := BsrReader.AnimationEntry.new()
	entry.events = [PackedInt32Array([200, 2, 0, 1]), PackedInt32Array([300, 1, 0, 0]), PackedInt32Array([650, 1, 0, 0])]
	var world: Node = world_script.new()
	var offs: Array = world.call("_hit_event_offsets", entry)
	_check(offs.size() == 2 and _approx(offs[0], 0.0) and _approx(offs[1], 0.35),
		"a swing's hit events as offsets from the first (%s)" % [offs])
	_check((world.call("_hit_event_offsets", null) as Array).is_empty(), "no entry: no offsets")
	world.free()
