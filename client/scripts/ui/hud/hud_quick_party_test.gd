extends SceneTree

## Round 715 (lane C3): the party member boxes (HudQuickParty), against what
## CIFQuickPartyWnd / CIFQuickPartySlot do (docs/protocol/party_gui.md §7 and
## the header of hud_quick_party.gd). The slot layout is synthetic but carries
## resinfo\ifquickpartyslot.txt's authored names, IDs, rects and styles (no
## textures, no archive text: never real game data).
##
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_quick_party_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _c(control_name: String, type: String, rect: String, id: int, ddj: String = "", style: int = 0,
		uv_rb: String = "1,1") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"%d\"\n\t\tText=STRING,\"\"\n\t\tUV_LT=POINT,\"0,0\"\n\t\tUV_RB=POINT,\"%s\"\n\t}\n" % [
		control_name, type, ddj, id, rect, style, uv_rb]

## ifquickpartyslot.txt's controls, front to back as the file lists them
## (MEASURED from the archive, round 715).
func _ifquickpartyslot() -> String:
	var b := ""
	b += _c("GDR_QPS_PARTY_BUFF", "CIFBuffViewer", "32,39,0,0", 10)
	b += _c("GDR_QPS_PARTY_LEADER", "CIFStatic", "30,6,0,0", 7, "interface\\ifcommon\\com_pt_leader.ddj", 64)
	b += _c("GDR_QPS_PARTY_RACE_MARK", "CIFStatic", "-2,2,16,16", 6, "interface\\ifcommon\\com_kindred_china16.ddj", 64)
	b += _c("GDR_QPS_STATUS", "CIFStatic", "6,6,28,28", 5)
	b += _c("GDR_QPS_TXT_ID", "CIFStatic", "43,5,73,12", 4)
	b += _c("GDR_QPS_GAUGE_MP", "CIFGauge", "42,30,76,4", 3, "interface\\quickparty\\qpt_mp.ddj")
	b += _c("GDR_QPS_GAUGE_HP", "CIFGauge", "42,24,76,4", 2, "interface\\quickparty\\qpt_hp.ddj")
	b += _c("GDR_QPS_EFFECT_MP", "CIFStatic", "54,30,64,32", 21, "interface\\playerminiinfo\\pmi_mp_quick_effect_caution.ddj", 512, "0.25,0.5")
	b += _c("GDR_QPS_EFFECT_HP", "CIFStatic", "54,24,64,32", 20, "interface\\playerminiinfo\\pmi_hp_quick_effect_caution.ddj", 512, "0.25,0.5")
	b += _c("GDR_QPS_PICTURE", "CIFStaticWithPictureClip", "6,6,28,28", 1)
	b += _c("GDR_QPS_SELECT", "CIFStatic", "-3,-4,132,48", 100, "interface\\quickparty\\qpt_grope_select.ddj", 64)
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n%s}\n" % b

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifquickpartyslot.txt"] = UiLayoutParser.parse(_ifquickpartyslot())
	return builder

func _member(jid: int, member_name: String, hp: int = 10, mp: int = 10) -> PartyNet.Member:
	var m := PartyNet.Member.new()
	m.jid = jid
	m.member_name = member_name
	m.hp_cur = hp
	m.hp_max = 10
	m.mp_cur = mp
	m.mp_max = 10
	return m

## A party of `n` with the player (JID 1, "Me") first and JID 2 leading.
func _party(n: int) -> PartyState:
	var p := PartyState.new()
	p.in_party = true
	p.own_jid = 1
	p.leader_jid = 2
	p.exp_share = 1
	p.members.append(_member(2, "Lead"))
	p.members.append(_member(1, "Me"))
	for i in range(3, n + 1):
		p.members.append(_member(i, "M%d" % i))
	return p

func _board(party: PartyState) -> HudQuickParty:
	var b := HudQuickParty.new(_builder(), party)
	b.screen_height = func() -> float: return 768.0
	b.own_name = func() -> String: return "Me"
	b.play_sound = func(_p: String) -> void: pass
	root.add_child(b)
	b.setup()
	return b

func _initialize() -> void:
	_test_positions()
	_test_faraway_steps()
	_test_record_distance()
	_test_rebuild()
	_test_lock()
	_test_selection_glow()
	_test_overlay_and_caution()
	_test_click_and_swap()
	_test_buffs()
	_test_member_update()
	_test_buff_cap()
	_test_buff_grid()
	_time_tick()
	print("hud_quick_party_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

func _test_positions() -> void:
	# 0x6db04b..0x6db07c on a 768-tall screen, board at y 137, 73-px rows:
	# rows 0..292 fit, at 365 (768-137-365-73 = 193 < 230) a new column.
	var at := HudQuickParty.slot_positions(7, 768.0, 137.0, 73)
	_check(at[0] == Vector2(13, 0) and at[1] == Vector2(13, 73) and at[4] == Vector2(13, 292),
		"slots step 73 down from x 13 (board x + 13)")
	_check(at[5] == Vector2(146, 0) and at[6] == Vector2(146, 73), "the sixth starts a column 133 to the right")
	var short := HudQuickParty.slot_positions(7, 768.0, 137.0, 56)
	_check(short[5] == Vector2(13, 280) and short[6] == Vector2(146, 0),
		"with the buff option off the step is 56 and the wrap still tests 73-px slots")

func _test_faraway_steps() -> void:
	var cases := [[359999.0, 0], [360000.0, 1], [489999.0, 1], [490000.0, 2], [640000.0, 3],
		[809999.0, 3], [810000.0, 4], [999999.0, 4], [1000000.0, 5], [4.0e6, 5]]
	var ok := true
	for c in cases:
		if HudQuickParty.faraway_level(float(c[0]), true) != int(c[1]):
			ok = false
			print("  d2 %s -> %d, want %d" % [c[0], HudQuickParty.faraway_level(float(c[0]), true), c[1]])
	_check(ok, "faraway levels at 600/700/800/900/1000 units, each >= (0x6db380)")
	_check(HudQuickParty.faraway_level(4.0e6, false) == 0, "no overlay in a party that does not share EXP")

func _test_record_distance() -> void:
	var here := Vector2i(97, 168)
	var d := HudQuickParty.record_distance_sq(here, Vector3(100, 0, 100), (97 << 8) | 168, 400.0, 500.0)
	_check(is_equal_approx(d, 300.0 * 300.0 + 400.0 * 400.0), "same region: plain dx, dz")
	d = HudQuickParty.record_distance_sq(here, Vector3(1900, 0, 100), (97 << 8) | 169, 20.0, 100.0)
	_check(is_equal_approx(d, 40.0 * 40.0), "region y + 1 steps world X by 1920: 1900 -> 1920+20 is 40")
	d = HudQuickParty.record_distance_sq(here, Vector3(100, 0, 1900), (98 << 8) | 168, 100.0, 20.0)
	_check(is_equal_approx(d, 40.0 * 40.0), "region x + 1 steps world Z by 1920")
	d = HudQuickParty.record_distance_sq(here, Vector3(100, 30, 100), (97 << 8) | 168, 100.0, 100.0)
	_check(is_equal_approx(d, 900.0), "the record is taken at y 0: only the player's height counts")

func _test_rebuild() -> void:
	var party := _party(4)
	var b := _board(party)
	_check(b.visible and b.position == HudQuickParty.FALLBACK_POSITION, "in a party: shown at 4,137")
	_check(b.slot_count() == 3, "one slot per member but the player (4 members, 3 slots)")
	_check(b.slot(0).member_name == "Lead" and b.slot(1).member_name == "M3", "slots in the party's order, the player skipped")
	_check(b.slot(0).position == Vector2(13, 0) and b.slot(1).position == Vector2(13, 73), "slot positions from the rebuild")
	_check(b.slot(0).size == HudQuickParty.SLOT_SIZE, "each slot 122x40 (0x6da110)")
	_check(b.slot(0).leader_flag != null and b.slot(0).leader_flag.visible, "the leader's red flag on the leader's slot")
	_check(not b.slot(1).leader_flag.visible, "... and not on another")
	var race := b.slot(0).built.get_node_or_null("GDR_QPS_PARTY_RACE_MARK") as Control
	_check(race != null and not race.visible, "the race mark stays hidden (never taken by Create)")
	_check(b.slot(0).masteries.size() == 2 and b.slot(0).masteries[0].position == Vector2(-3, 39)
		and b.slot(0).masteries[1].position == Vector2(15, 39), "two mastery icons at -3,39 and 15,39")
	var rec := MasteryReader.Mastery.new()
	rec.id = 257
	rec.name_code = "UIIT_STT_MASTERY_SWORD"
	b.set_mastery_table([rec])
	party.members[0].mastery1 = 257
	party.members[0].mastery2 = 999
	b.rebuild()
	_check(b.slot(0).masteries[0].visible and not b.slot(0).masteries[1].visible,
		"a first mastery with a record shows; a second id with none hides the second icon")
	party.members[0].mastery1 = 0
	party.members[0].mastery2 = 257
	b.rebuild()
	_check(b.slot(0).masteries[0].visible and b.slot(0).masteries[1].visible,
		"retail never hides the first icon once shown (0x6d8630, 0x6d9495): it keeps its last art")
	var fresh := _board(_party(3))
	fresh.set_mastery_table([rec])
	fresh.state.members[0].mastery1 = 0
	fresh.state.members[0].mastery2 = 0
	fresh.rebuild()
	_check(not fresh.slot(0).masteries[0].visible and not fresh.slot(0).masteries[1].visible,
		"a new slot starts with both hidden (0x6d8a64)")
	fresh.queue_free()
	party.members[2].hp_cur = 5
	b.rebuild()
	_check(absf(b.slot(1).hp_gauge.value / b.slot(1).hp_gauge.max_value - 0.5) < 0.001, "HP gauge from the record's ratio")
	party.in_party = false
	b.rebuild()
	_check(not b.visible and b.slot_count() == 0, "out of a party: no slots, board hidden")
	b.queue_free()

func _test_lock() -> void:
	var party := _party(2)
	var b := _board(party)
	_check(not b.lock_button().visible, "two members: no lock (0x6db3f9: count > 2)")
	party.members.append(_member(3, "M3"))
	b.rebuild()
	_check(b.lock_button().visible, "three members: the lock shows")
	_check(b.lock_button().position == Vector2(-4, -7), "the lock at screen x 0, 7 above the board")
	b.toggle_lock()
	_check(b.unlocked, "a click unlocks reordering")
	b.toggle_lock()
	_check(not b.unlocked, "... and a second locks it")
	b.queue_free()

func _test_selection_glow() -> void:
	var party := _party(3)
	var b := _board(party)
	var sel := [0]
	b.selected_jid = func() -> int: return sel[0]
	b.tick(0)
	_check(not b.slot(0).select_glow.visible and not b.slot(1).select_glow.visible, "nothing selected: no glow")
	sel[0] = 3
	b.tick(16)
	_check(not b.slot(0).select_glow.visible and b.slot(1).select_glow.visible, "the selected member's slot glows, only it")
	sel[0] = 2
	b.tick(32)
	_check(b.slot(0).select_glow.visible and not b.slot(1).select_glow.visible, "the glow follows the selection")
	sel[0] = 0
	b.tick(48)
	_check(not b.slot(0).select_glow.visible, "a selection elsewhere clears it")
	b.queue_free()

func _test_overlay_and_caution() -> void:
	var party := _party(3)
	party.members[0].region = (97 << 8) | 168
	party.members[0].x = 100
	party.members[0].z = 100
	party.members[2].region = (97 << 8) | 168
	party.members[2].x = 100 + 650
	party.members[2].z = 100
	var b := _board(party)
	b.player_region = func() -> Vector2i: return Vector2i(97, 168)
	b.player_local = func() -> Vector3: return Vector3(100, 0, 100)
	b.tick(0)
	_check(b.slot(0).faraway == 0 and b.slot(1).faraway == 1, "a member 650 away: level 1; one beside the player: 0")
	_check(b.slot(1).status != null and b.slot(1).status.visible and not b.slot(0).status.visible,
		"the overlay picture shows only at level >= 1")
	party.members[2].x = 100 + 1500
	b.tick(16)
	_check(b.slot(1).faraway == 5, "1500 away: level 5")
	party.exp_share = 0
	b.tick(32)
	_check(b.slot(1).faraway == 0, "the same member in a free-for-all party: no overlay")
	party.exp_share = 1
	party.members[0].hp_cur = 2
	b.rebuild()
	b.tick(48)
	_check(not b.hp_caution and not b.mp_caution and b.show_buffs,
		"the game options start as 0x7776c0 writes them: buff row on, both cautions off")
	_check(not b.slot(0).hp_effect.visible, "so HP below 30 % shows no caution by default")
	b.hp_caution = true
	b.tick(64)
	_check(b.slot(0).hp_effect.visible, "with option +0x12 set: the HP caution effect")
	_check(not b.slot(0).mp_effect.visible, "MP full: no MP caution")
	party.members[0].x = 100 + 2000
	b.tick(80)
	_check(b.slot(0).faraway == 5 and not b.slot(0).hp_effect.visible, "at level 5 the caution is hidden")
	b.queue_free()

func _test_click_and_swap() -> void:
	var party := _party(4)
	var b := _board(party)
	var got := []
	var sounds := []
	b.member_clicked.connect(func(j: int, n: String) -> void: got.append([j, n]))
	b.play_sound = func(p: String) -> void: sounds.append(p)
	b.click_slot(b.slot(1))
	_check(got.size() == 1 and got[0][0] == 3 and got[0][1] == "M3", "a click names the slot's member")
	_check(sounds == [HudQuickParty.SELECT_SOUND], "... and plays uiwinopen.wav (0x6d8500)")
	_check(b.member_at(0) == 2 and b.member_at(2) == 4 and b.member_at(3) == 0, "Ctrl+2..8's slot lookup (0x6da850)")
	b.swap_members(2, 4)
	_check(b.slot(0).member_name == "M4" and b.slot(2).member_name == "Lead", "a drop swaps two members and rebuilds")
	b.queue_free()

func _test_member_update() -> void:
	var party := _party(3)
	var b := _board(party)
	var rebuilds := [0]
	b.rebuilt.connect(func() -> void: rebuilds[0] += 1)
	party.members[0].hp_cur = 3
	party.member_updated.emit(2)
	_check(rebuilds[0] == 0 and absf(b.slot(0).hp_gauge.value / b.slot(0).hp_gauge.max_value - 0.3) < 0.001,
		"a member update refills that slot alone, no rebuild (PartyState.member_updated)")
	b.queue_free()

func _test_buff_cap() -> void:
	var party := _party(3)
	var b := _board(party)
	var body := Node3D.new()
	root.add_child(body)
	b.member_body = func(jid: int) -> Node3D: return body if jid == 2 else null
	var list := []
	for i in 8:
		list.append({"skill_id": 300 + i, "token": i + 1})
	for bit in 8:
		list.append({"skill_id": HudTargetBuffs.abnormal_id(bit), "token": 0})
	b.buffs_of = func(_jid: int) -> Array: return list
	b.rebuild()
	_check(b.slot(0).buffs.count(true) == 6 and b.slot(0).buffs.count(false) == 6,
		"8 buffs and 8 states: one row of 6 each (0x7fab90(1,1))")
	_check(b.slot(0).buffs.skill_ids(true) == [300, 301, 302, 303, 304, 305], "the first six in add order are kept")
	var t := HudTargetBuffs.new(null, null)
	t.rebuild(list)
	_check(t.count(true) == 8 and t.count(false) == 8, "the target window's viewer has no cap")
	t.free()
	body.queue_free()
	b.queue_free()

func _test_buffs() -> void:
	var party := _party(3)
	var b := _board(party)
	var body := Node3D.new()
	root.add_child(body)
	b.member_body = func(jid: int) -> Node3D: return body if jid == 2 else null
	b.buffs_of = func(_jid: int) -> Array: return [{"skill_id": 101, "token": 5}]
	b.rebuild()
	_check(b.slot(0).buffs.visible and b.slot(0).buffs.count(true) == 1, "a spawned member's buffs show")
	_check(not b.slot(1).buffs.visible, "a member not spawned here shows none")
	b.show_buffs = false
	b.rebuild()
	_check(not b.slot(0).buffs.visible, "the buff option off clears the row")
	body.queue_free()
	b.queue_free()

## Not a check: what one frame of the board's own logic costs with a full
## party (7 slots, every member placed by record against a known player
## position, the world's lookups stubbed), printed for the round's notes.
func _time_tick() -> void:
	var party := _party(8)
	for i in party.members.size():
		party.members[i].region = (97 << 8) | 168
		party.members[i].x = 100 + 150 * i
		party.members[i].z = 100
	var b := _board(party)
	b.player_region = func() -> Vector2i: return Vector2i(97, 168)
	b.player_local = func() -> Vector3: return Vector3(100, 0, 100)
	b.selected_jid = func() -> int: return 3
	var n := 2000
	var t0 := Time.get_ticks_usec()
	for i in n:
		b.tick(i * 16)
	var per := float(Time.get_ticks_usec() - t0) / n
	print("TIMING: HudQuickParty.tick with %d slots: %.1f us a frame (mean of %d)" % [b.slot_count(), per, n])
	b.queue_free()

func _test_buff_grid() -> void:
	var v := HudTargetBuffs.new(null, null)
	v.set_grid(HudQuickParty.BUFF_COLUMNS, HudQuickParty.BUFF_PITCH, HudQuickParty.BUFF_ICON)
	var list := []
	for i in 8:
		list.append({"skill_id": 200 + i, "token": i + 1})
	v.rebuild(list)
	_check(v.slot_of(200).position == Vector2(0, 0) and v.slot_of(205).position == Vector2(75, 0)
		and v.slot_of(206).position == Vector2(0, 15), "6 per row at a 15-px pitch (0x6d9010)")
	_check(v.slot_of(200).size == Vector2(12, 12), "12x12 icons")
	var t := HudTargetBuffs.new(null, null)
	t.rebuild([{"skill_id": 1, "token": 1}, {"skill_id": 2, "token": 2}])
	_check(t.slot_of(2).position == Vector2(23, 0) and t.slot_of(1).size == Vector2(20, 20),
		"the target window's viewer keeps its own grid")
	v.free()
	t.free()
