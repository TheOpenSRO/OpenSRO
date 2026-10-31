extends SceneTree

## Round 734's review fixes in EquipFx (the kept particles of glowing gear,
## drawn per effect type):
## - F3: the re-selection is spread over RESELECT_FRAMES frames, sorts nothing
##   while the candidates fit the budget, and a holder runs no _process;
## - F4: a holder takes the host's uniform scale (the body's height factor)
##   times the row's (round 741: and the bone's frame, mirror included);
## - F5: a viewport drawing nothing (the closed equipment window) shows none
##   and pauses its masters, and shows them again the frame it opens.
##   godot4 --headless --path client --script res://scripts/assets/equip_fx_test.gd
## SYNTHETIC: masters are empty EfpEffects put under the key add_host builds,
## so no Particles.pk2 is read.

const EFP := "system\\test_fx.efp"
const SCALE := 1.75

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await process_frame
	_test_budget()
	_test_scale_and_pause()
	_test_two_rows_one_bone()
	_test_weapon_budget()
	_test_world_commands()
	_test_own_nearest()
	_test_own_prefer_keep_free()
	_test_prefer_root_freed()
	print("FAILURES: %d" % _failures if _failures > 0 else "all passed")
	quit(1 if _failures > 0 else 0)

func _viewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(320, 180)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 5, -50), Vector3(0, 0, 400))
	cam.current = true
	return vp

## The driver of `vp`, stepped by hand, with an empty master for EFP at SCALE.
func _driver(vp: SubViewport) -> EquipFx:
	var d := EquipFx.driver_for(vp)
	d.set_process(false)
	var key := EquipFx.kind_key(EFP, SCALE)
	if not d._kinds.has(key):
		var m := EfpEffect.new()
		var mm := MultiMeshInstance3D.new()
		mm.multimesh = MultiMesh.new()
		m.add_child(mm)
		d.add_child(m)
		var k := EquipFx.Kind.new()
		k.key = key
		k.master = m
		d._kinds[key] = k
	return d

func _host(parent: Node, d: EquipFx, pos: Vector3) -> Skeleton3D:
	var s := Skeleton3D.new()
	s.add_bone("ai_end")
	s.position = pos
	parent.add_child(s)
	d.add_host(s, "ai_end", EFP, SCALE, null)
	return s

func _shown_holder(s: Skeleton3D) -> EfpEffect:
	for c in s.get_children():
		if c is EfpEffect and (c as EfpEffect).visible:
			return c
	return null

func _test_budget() -> void:
	var vp := _viewport()
	var d := _driver(vp)
	# Round 748's review, F6: the driver places holders after the world's
	# _process, which poses the player.
	_check(d.process_priority > 0, "the driver runs after default-priority _process (priority %d)" % d.process_priority)
	var near: Array = []
	for i in 10:
		near.append(_host(vp, d, Vector3(0, 0, 10 + i * 5)))
	d._process(1.0 / 60.0)
	_check(int(d.stats["shown"]) == 10, "10 weapons, under the budget: all 10 show, the frame after they were added (%d)" % int(d.stats["shown"]))
	var processing := 0
	var holders := 0
	for s in near:
		var h := _shown_holder(s)
		if h != null:
			holders += 1
			if h.is_processing():
				processing += 1
	_check(holders == 10 and processing == 0, "every holder is made, and none runs a _process of its own (%d holders, %d processing)" % [holders, processing])
	var far: Array = []
	for i in 70:
		far.append(_host(vp, d, Vector3(0, 0, 200 + i * 5)))
	for f in EquipFx.RESELECT_FRAMES + 1:
		d._process(1.0 / 60.0)
	_check(int(d.get("_per_frame")) == 8, "a cycle's scan is spread: 80 hosts, 8 a frame (%d)" % int(d.get("_per_frame")))
	var shown_far := 0
	for s in far:
		if _shown_holder(s) != null:
			shown_far += 1
	var near_kept := 0
	for s in near:
		if _shown_holder(s) != null:
			near_kept += 1
	_check(int(d.stats["shown"]) == EquipFx.VISIBLE_BUDGET and near_kept == 10 and shown_far == EquipFx.VISIBLE_BUDGET - 10,
		"80 weapons: the 64 nearest show (all 10 near, %d of the far)" % shown_far)
	var nearest_far := true
	for i in far.size():
		if (_shown_holder(far[i]) != null) != (i < EquipFx.VISIBLE_BUDGET - 10):
			nearest_far = false
	_check(nearest_far, "the far ones chosen are the nearest of them")
	vp.free()

func _test_scale_and_pause() -> void:
	var vp := _viewport()
	var d := _driver(vp)
	# The select screen's root is mirrored (1, 1, -1); a tall body is 1.06.
	var mirror := Node3D.new()
	mirror.scale = Vector3(1, 1, -1)
	vp.add_child(mirror)
	var body := Node3D.new()
	body.scale = Vector3.ONE * 1.06
	body.position = Vector3(0, 0, -20)
	mirror.add_child(body)
	var s := _host(body, d, Vector3.ZERO)
	d._process(1.0 / 60.0)
	var h := _shown_holder(s)
	var b := h.global_transform.basis if h != null else Basis()
	# Round 741: the holder takes the bone's whole frame, so it is mirrored with
	# the body (its billboards are built per camera and do not care).
	_check(h != null and absf(b.x.length() - SCALE * 1.06) < 1e-4 and absf(b.z.length() - SCALE * 1.06) < 1e-4 and b.determinant() < 0.0,
		"the holder takes the body's height factor x the row's scale, %.4f, mirrored with the body (%s)" % [SCALE * 1.06, str(b.get_scale()) if h != null else "none"])
	var k: EquipFx.Kind = d._kinds.values()[0]
	_check(d.steps_master(k), "shown: its master simulates")
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	d._process(1.0 / 60.0)
	_check(int(d.stats["shown"]) == 0 and not d.steps_master(k) and _shown_holder(s) == null,
		"the viewport drawing nothing (the closed equipment window): none shown, the master paused, the frame it closes")
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	d._process(1.0 / 60.0)
	_check(int(d.stats["shown"]) == 1 and d.steps_master(k) and _shown_holder(s) != null, "opened again: shown the same frame")
	vp.free()

## Round 741: a seal weapon's itemrare.txt row and its +8 itemoptionefp.txt row
## sit on the same bone (Sun spear 4118: raretype_a_step3 and enchant_a_01,
## both ai_end); retail makes a mod for each (FUN_00a5f3e0's loop). Keyed by
## bone alone, round 734 dropped the second.
func _test_two_rows_one_bone() -> void:
	var vp := _viewport()
	var d := _driver(vp)
	var other := "system\\test_fx_2.efp"
	var key2 := EquipFx.kind_key(other, SCALE)
	var m := EfpEffect.new()
	var mm := MultiMeshInstance3D.new()
	mm.multimesh = MultiMesh.new()
	m.add_child(mm)
	d.add_child(m)
	var k := EquipFx.Kind.new()
	k.key = key2
	k.master = m
	d._kinds[key2] = k
	var s := _host(vp, d, Vector3(0, 0, 20))
	d.add_host(s, "ai_end", other, SCALE, null)
	d.add_host(s, "ai_end", EFP, SCALE, null)
	_check(d._hosts.size() == 2, "two effects on one bone: two hosts, the same one twice: still two (%d)" % d._hosts.size())
	d._process(1.0 / 60.0)
	var holders := 0
	for c in s.get_children():
		if c is EfpEffect and (c as EfpEffect).visible:
			holders += 1
	_check(holders == 2, "both are drawn (%d holders)" % holders)
	d.remove_skel(s)
	_check(d._hosts.is_empty(), "the skeleton leaving takes both")
	vp.free()

## Round 746 (the review's finding 2): the budget cuts by whole weapons (item
## skeletons): a chosen weapon shows every effect it carries, within 64
## holders.
func _test_weapon_budget() -> void:
	var vp := _viewport()
	var d := _driver(vp)
	var other := "system\\test_fx_2.efp"
	var key2 := EquipFx.kind_key(other, SCALE)
	var m := EfpEffect.new()
	var mm := MultiMeshInstance3D.new()
	mm.multimesh = MultiMesh.new()
	m.add_child(mm)
	d.add_child(m)
	var k := EquipFx.Kind.new()
	k.key = key2
	k.master = m
	d._kinds[key2] = k
	var skels: Array = []
	for i in 80:
		var s := _host(vp, d, Vector3(0, 0, 10 + i * 5))
		d.add_host(s, "ai_end", other, SCALE, null)
		skels.append(s)
	for f in EquipFx.RESELECT_FRAMES + 2:
		d._process(1.0 / 60.0)
	var whole := 0
	var half := 0
	for i in skels.size():
		var n := 0
		for c in (skels[i] as Node).get_children():
			if c is EfpEffect and (c as EfpEffect).visible:
				n += 1
		if n == 2:
			whole += 1
		elif n == 1:
			half += 1
	var cap := EquipFx.VISIBLE_BUDGET / 2
	_check(int(d.stats["weapons"]) == cap and int(d.stats["shown"]) == EquipFx.VISIBLE_BUDGET,
		"80 weapons with 2 effects each: 64 holders, 32 whole weapons (%d, %d)" % [int(d.stats["weapons"]), int(d.stats["shown"])])
	_check(whole == cap and half == 0, "every shown weapon shows both its effects, none half (%d whole, %d half)" % [whole, half])
	var nearest := true
	for i in skels.size():
		var shown := false
		for c in (skels[i] as Node).get_children():
			if c is EfpEffect and (c as EfpEffect).visible:
				shown = true
		if shown != (i < cap):
			nearest = false
	_check(nearest, "the weapons shown are the nearest")
	vp.free()

## Round 746 (the review's finding 1): which commands point along the world.
func _test_world_commands() -> void:
	var t := EfpSim.Template.new()
	var tp := EfpSim.Tpl.new()
	tp.schedule = [[
		[EfpSim.K_CONEVEL, 0, Vector3(0, 0.5, 0.2)],   # world: no frame
		[EfpSim.K_CONEVEL, 2, Vector3(0, 0.5, 0.2)],   # the parent's frame
		[EfpSim.K_POS, 7, Vector3(-1.2, 0, 0)],        # parent's position, turned by it
		[EfpSim.K_POS, 1, Vector3(1, 0, 0)],           # parent's position, NOT turned: world
		[EfpSim.K_POS, 1, Vector3.ZERO],               # nothing to turn
		[EfpSim.K_SPHERE, 1, Vector3(2, 2, 2)],        # a ball: the same in any frame
		[EfpSim.K_SPHERE, 1, Vector3(1, 0, 1)],        # a disc in the world's XZ
		[EfpSim.K_RVEL, 0, Basis(Vector3.UP, 0.1)],    # applied in the outer frame
		[EfpSim.K_FORCE, 2, Vector3(0, -1, 0)],
		[EfpSim.K_SCALE, 0, Vector3.ONE],
	]]
	t.tpls.append(tp)
	_check(EquipFx.world_commands(t) == 4, "world-axis commands: cone velocity space 0, a position space 1, a disc, a rotation velocity (%d)" % EquipFx.world_commands(t))

## Round 746: a world-axis effect's OWN_BUDGET nearest weapons run their own
## simulation; the rest draw the shared master.
func _test_own_nearest() -> void:
	var vp := _viewport()
	var d := _driver(vp)
	var key := EquipFx.kind_key(EFP, SCALE)
	(d._kinds[key] as EquipFx.Kind).own = true
	EquipFx.own_factory = func(_efp: String) -> EfpEffect:
		return EfpEffect.new()
	var skels: Array = []
	for i in 12:
		skels.append(_host(vp, d, Vector3(0, 0, 10 + i * 5)))
	d._process(1.0 / 60.0)
	var ok := true
	for i in skels.size():
		var own := false
		var shared := false
		for c in (skels[i] as Node).get_children():
			if c is EfpEffect and (c as EfpEffect).visible:
				if String(c.name).begins_with("EquipFxOwn"):
					own = true
				else:
					shared = true
		if own != (i < EquipFx.OWN_BUDGET) or shared == own:
			ok = false
	_check(ok and int(d.stats["own"]) == EquipFx.OWN_BUDGET,
		"12 weapons with a world-axis effect: the %d nearest simulate on their own, the rest draw the shared master (%d own)" % [EquipFx.OWN_BUDGET, int(d.stats["own"])])
	EquipFx.own_factory = Callable()
	vp.free()

## Round 746's review, findings 4-6: the player's weapon first, a margin
## before the own slot moves, a parked own effect freed after a while, and a
## master no shared holder uses does not step.
func _own_of(s: Skeleton3D) -> bool:
	for c in s.get_children():
		if c is EfpEffect and (c as EfpEffect).visible and String(c.name).begins_with("EquipFxOwn"):
			return true
	return false

func _cycle(d: EquipFx) -> void:
	for f in EquipFx.RESELECT_FRAMES:
		d._process(1.0 / 60.0)

func _test_own_prefer_keep_free() -> void:
	var vp := _viewport()
	var d := _driver(vp)
	var key := EquipFx.kind_key(EFP, SCALE)
	var k: EquipFx.Kind = d._kinds[key]
	k.own = true
	EquipFx.own_factory = func(_efp: String) -> EfpEffect:
		return EfpEffect.new()
	var budget := EquipFx.OWN_BUDGET
	EquipFx.OWN_BUDGET = 1
	# The player's weapon (the farthest here) is preferred.
	var player := Node3D.new()
	vp.add_child(player)
	var near := _host(vp, d, Vector3(0, 0, 10))
	var mine := _host(player, d, Vector3(0, 0, 40))
	d.prefer_root = player
	d._process(1.0 / 60.0)
	_check(_own_of(mine) and not _own_of(near), "the player's own weapon runs the own simulation, not the nearer one")
	# Finding 6: the only host drawn through the master is `near`; with both
	# own, the master would pause.
	_check(d.steps_master(k), "a master a shared holder uses keeps stepping")
	d.prefer_root = null
	EquipFx.OWN_BUDGET = 2
	_cycle(d)
	_check(_own_of(mine) and _own_of(near) and not d.steps_master(k),
		"every shown host on its own: the master does not step (finding 6)")
	# Hysteresis: one slot, `near` holds it; a weapon 15 % nearer does not
	# take it, one 30 % nearer does.
	EquipFx.OWN_BUDGET = 1
	mine.position = Vector3(0, 0, 400)
	_cycle(d)
	_cycle(d)
	var held := _own_of(near)
	var rival := _host(vp, d, Vector3(0, 0, 0))
	var dn := (near.global_position - vp.get_camera_3d().global_position).length()
	rival.position = Vector3(0, 0, 10 - 0.15 * dn)
	_cycle(d)
	_cycle(d)
	_check(held and _own_of(near) and not _own_of(rival), "a rival 15 %% nearer does not take the slot (margin %.0f %%)" % (EquipFx.OWN_KEEP_MARGIN * 100))
	rival.position = Vector3(0, 0, 10 - 0.3 * dn)
	# Two cycles: the scan that saw the move ends on the cycle after it.
	_cycle(d)
	_cycle(d)
	_check(_own_of(rival) and not _own_of(near), "a rival 30 % nearer does")
	# Finding 5: `near`'s parked own effect goes after OWN_FREE_CYCLES.
	var hid := ""
	for id in d._hosts:
		if (d._hosts[id] as EquipFx.Host).skel == near:
			hid = id
	var h: EquipFx.Host = d._hosts[hid]
	_check(h.own_fx != null and is_instance_valid(h.own_fx) and not h.own_fx.visible, "the old own effect is parked")
	for c in EquipFx.OWN_FREE_CYCLES + 1:
		_cycle(d)
	_check(h.own_fx == null, "and freed after %d cycles parked" % EquipFx.OWN_FREE_CYCLES)
	EquipFx.OWN_BUDGET = budget
	EquipFx.own_factory = Callable()
	vp.free()

## Round 847: the driver hangs off the viewport and outlives the world; a
## player freed by a relog to the select screen must not reach the batch's
## typed `own: Node` (a "previously freed" SCRIPT ERROR every frame).
func _test_prefer_root_freed() -> void:
	var vp := _viewport()
	var d := _driver(vp)
	var player := Node3D.new()
	vp.add_child(player)
	_host(player, d, Vector3(0, 0, 20))
	d.prefer_root = player
	d._process(1.0 / 60.0)
	player.free()
	d._process(1.0 / 60.0)
	_check(d.prefer_root == null, "a freed player is dropped from prefer_root on the next step")
	vp.free()
