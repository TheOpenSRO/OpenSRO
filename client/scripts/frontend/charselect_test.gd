extends SceneTree

## Round 684: the retail character select screen's numbers and flow, headless,
## on synthetic records (no archive):
##   - the dock placement: a full page at k/5, a last page of r at k/(r+1);
##   - the slot order: level, then EXP, descending; ties the later first;
##   - the list -> scene mapping: each slot's record, place, page, idle and
##     opacity (stand at 0xff, seated at 0xcc pending deletion);
##   - the delete-state display: which windows a selected character shows,
##     the countdown text and gauge, the minutes counted down;
##   - idol picking emits the race (retail's index 0 Europe, 1 China,
##     translated) and hands it to the customize screen;
##   - the Start flow: 0x7001 with the selected name, the world on OK, the
##     refusal's words and Start again on a refusal;
##   - the camera keys (READ values) and the click pose.
## `godot4 --headless --path client --script res://scripts/frontend/charselect_test.gd`
##
## NEGATIVE: before round 684 none of CharSelectMath, CharSelectHandoff or the
## 3D CharacterSelect exists -- every check below fails to compile or FAILs.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _v_near(a: Vector3, b: Vector3, eps: float = 1e-3) -> bool:
	return a.distance_to(b) <= eps

func _rec(char_name: String, level: int, exp_offset: int, deleting: bool = false, minutes: int = 0) -> LobbyNet.Character:
	var c := LobbyNet.Character.new()
	c.char_name = char_name
	c.level = level
	c.exp_offset = exp_offset
	c.deleting = deleting
	c.minutes_left = minutes
	c.ref_obj_id = 1907
	c.scale = 0x22
	c.str_stat = 20
	c.int_stat = 20
	return c

func _initialize() -> void:
	# The autoloads (NetClient, which CharacterSelect.gd names) are in only
	# after the first frame.
	await process_frame
	_placement()
	_order()
	_scene_plan()
	_delete_state()
	_camera()
	_info()
	_idol_and_start()
	print("ALL PASS" if _failures == 0 else "FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _placement() -> void:
	var a := CharSelectMath.DOCK_START
	var b := CharSelectMath.DOCK_END
	# Full page: k/5.
	for k in range(4):
		var p := CharSelectMath.slot_place(k, 4)
		var u := float(k + 1) / 5.0
		_check(_v_near(p["pos"], a.lerp(b, u)), "4 characters: slot %d at %d/5 of the dock" % [k, k + 1])
		_check(_near(p["yaw"], lerpf(CharSelectMath.DOCK_START_YAW, CharSelectMath.DOCK_END_YAW, u)), "4 characters: slot %d's yaw at %d/5" % [k, k + 1])
	# A partial page of r at k/(r+1).
	_check(_v_near(CharSelectMath.slot_place(0, 1)["pos"], a.lerp(b, 0.5)), "1 character stands at the dock's midpoint")
	_check(_v_near(CharSelectMath.slot_place(0, 2)["pos"], a.lerp(b, 1.0 / 3.0)) and _v_near(CharSelectMath.slot_place(1, 2)["pos"], a.lerp(b, 2.0 / 3.0)), "2 characters at thirds")
	for k in range(3):
		_check(_v_near(CharSelectMath.slot_place(k, 3)["pos"], a.lerp(b, float(k + 1) / 4.0)), "3 characters: slot %d at %d/4" % [k, k + 1])
	# 5 characters: page 0 full at k/5, page 1's one at the midpoint.
	_check(_v_near(CharSelectMath.slot_place(3, 5)["pos"], a.lerp(b, 4.0 / 5.0)), "5 characters: slot 3 on the full first page at 4/5")
	_check(_v_near(CharSelectMath.slot_place(4, 5)["pos"], a.lerp(b, 0.5)), "5 characters: slot 4 alone on page 2 at the midpoint")
	_check(_v_near(CharSelectMath.slot_place(5, 6)["pos"], a.lerp(b, 2.0 / 3.0)), "6 characters: slot 5 second of two on page 2, at 2/3")
	_check(CharSelectMath.page_count(0) == 0 and CharSelectMath.page_count(4) == 1 and CharSelectMath.page_count(5) == 2 and CharSelectMath.page_count(8) == 2, "pages = (n - 1) / 4 + 1")
	_check(_near(CharSelectMath.slot_place(0, 3)["pos"].y, -27.6), "the dock's height is kept on a partial page")

func _order() -> void:
	var recs := [_rec("low", 3, 900), _rec("high", 40, 1), _rec("midA", 20, 50), _rec("midB", 20, 70), _rec("tieA", 5, 7), _rec("tieB", 5, 7)]
	var order := CharSelectMath.slot_order(recs)
	var names := PackedStringArray()
	for i in order:
		names.append(recs[i].char_name)
	_check(", ".join(names) == "high, midB, midA, tieB, tieA, low", "slot order: level, then EXP, descending; a tie puts the later record first (got %s)" % ", ".join(names))
	_check(CharSelectMath.sort_key(5, 7) == "005 00000000000000000007", "the sort key is \"%03d %020I64d\"")

func _scene_plan() -> void:
	var recs := [_rec("a", 1, 0), _rec("b", 9, 0, true, 100), _rec("c", 5, 0)]
	var plan := CharSelectMath.scene_plan(recs)
	_check(plan.size() == 3, "one plan entry per character")
	_check(int(plan[0]["index"]) == 1 and int(plan[1]["index"]) == 2 and int(plan[2]["index"]) == 0, "the plan maps slot k to the list's record in slot order")
	_check(int(plan[0]["action"]) == BsrReader.AnimationEntry.TYPE_SITTING and int(plan[0]["alpha"]) == 0xcc, "a character pending deletion sits (action 0xe) at opacity 0xcc")
	_check(int(plan[1]["action"]) == BsrReader.AnimationEntry.TYPE_STAND and int(plan[1]["alpha"]) == 255, "the others stand (action 0) at 0xff")
	_check(_v_near(plan[1]["pos"], CharSelectMath.slot_place(1, 3)["pos"]) and int(plan[2]["page"]) == 0, "the plan carries each slot's place and page")
	var five := [_rec("a", 1, 0), _rec("b", 2, 0), _rec("c", 3, 0), _rec("d", 4, 0), _rec("e", 5, 0)]
	var p5 := CharSelectMath.scene_plan(five)
	_check(int(p5[4]["page"]) == 1 and five[int(p5[4]["index"])].char_name == "a", "5 characters: the lowest level is alone on page 2")

func _delete_state() -> void:
	var live := CharSelectMath.selected_windows(false)
	_check(live[14] and live[15] and not live[25] and not live[26] and live["message"] == "", "a live character shows Start and Delete, no Restore or countdown")
	var pending := CharSelectMath.selected_windows(true)
	_check(not pending[14] and not pending[15] and pending[25] and pending[26] and pending["message"] == "UIO_STT_CHAR_DEL_WAITING", "a pending character shows Restore, the countdown and DEL_WAITING")
	var fmt := "Complete deletion of the selected character in %d days %d hours %d minuites left."
	_check(CharSelectMath.countdown_text(fmt, 4321) == "Complete deletion of the selected character in 3 days 0 hours 1 minuites left.", "the countdown fills the archive's three %d: 4321 minutes = 3 d 0 h 1 m")
	_check(CharSelectMath.countdown_text(fmt, 10080).begins_with("Complete deletion of the selected character in 7 days 0 hours 0"), "a fresh deletion reads 7 days")
	_check(_near(CharSelectMath.delete_gauge(10080), 0.0) and _near(CharSelectMath.delete_gauge(5040), 0.5) and _near(CharSelectMath.delete_gauge(0), 1.0), "the gauge is 1 - remaining / 10080")
	_check(CharSelectMath.minutes_now(100, 0) == 100 and CharSelectMath.minutes_now(100, 30) == 70 and CharSelectMath.minutes_now(100, 100) == 1 and CharSelectMath.minutes_now(100, 500) == 1, "the screen counts a minute off per 60 s, never below 1")
	_check(CharSelectMath.countdown_text("", 61) == "0 days 1 hours 1 minutes", "with no archive text, our own words")
	var pml := '"""<sml2>left <font color=""""255,255,208,81"""">%d</font>days</sml2>"""'
	_check(CharSelectMath.pml_to_bbcode(pml % 3) == "left [color=#ffd051]3[/color]days", "the countdown's PML becomes BBCode: the font colour kept, sml2 and the quoting dropped (got %s)" % CharSelectMath.pml_to_bbcode(pml % 3))

func _camera() -> void:
	var intro := CharSelectMath.list_intro_path()
	_check(_near(intro.length, 2.0) and _v_near(intro.sample(0.0).target, Vector3(60, -15, 700)) and _v_near(intro.sample(2.0).target, Vector3(60, -15, 660)), "the list intro flies (60,-15,700) -> (60,-15,660) over 2.0 s")
	var back := CharSelectMath.back_path()
	_check(_v_near(back.sample(0.0).target, Vector3(60, -15, 660)) and _v_near(back.sample(2.0).target, Vector3(60, -15, 700)), "Back dollies the same keys out")
	var race := CharSelectMath.race_path()
	_check(_near(race.length, 5.0) and race.key_count() == 4 and _v_near(race.sample(5.0).target, Vector3(165.2, -33.9, 640.3)) and _near(race.sample(5.0).pitch, 0.62), "the race fly: 4 keys over 5.0 s to the table")
	_check(_v_near(race.sample(5.0 / 3.0).target, Vector3(100, 0, 625)), "the race fly's second key at 5/3 s")
	var rb := CharSelectMath.race_back_path()
	_check(_v_near(rb.sample(0.0).target, Vector3(165.2, -33.9, 640.3)) and _v_near(rb.sample(5.0).target, Vector3(60, -15, 660)), "Cancel 17 flies the race keys back")
	var slot := CharSelectMath.slot_place(0, 1)
	var pose := CharSelectMath.click_pose(slot, 0x22, false, false)
	var at: Vector3 = slot["pos"]
	_check(_near(pose.target.x, at.x + 2.0) and _near(pose.target.z, at.z + 2.0) and _near(pose.distance, 8.0) and _near(pose.pitch, 0.0), "a click targets the slot + (2, Y, 2) at distance 8, pitch 0")
	_check(_near(pose.yaw, 0.3925 - float(slot["yaw"]), 1e-5), "a click's yaw is 0.3925 - the slot's yaw")
	_check(_near(pose.target.y, 16.0 - 28.779172897338867), "standing man at height 2: target y = 16 - 28.779")
	_check(_near(CharSelectMath.click_target_y(0x22, true, true), 8.5 - 30.0) and _near(CharSelectMath.click_target_y(0x20, false, true), 0.94 * 9.0 - 29.0), "seated targets: h x 8.5 - 30 (woman), h x 9 - 29 (man)")
	var from := CharSelectMath.key_pose(CharSelectMath.LIST_KEYS[1])
	_check(_near(CharSelectMath.click_path(from, pose, false).length, 2.0) and _near(CharSelectMath.click_path(from, pose, true).length, 1.0), "a click flies 2.0 s, a re-select 1.0 s")
	var idol := CharSelectMath.idol_path(CharSelectMath.key_pose(CharSelectMath.RACE_KEYS[3]), 0)
	_check(_near(idol.length, 1.0) and _v_near(idol.sample(1.0).target, CharSelectMath.IDOL_TARGET_EUROPE) and _near(idol.sample(1.0).yaw, 2.53), "an idol click flies 1.0 s to the idol at the same rotation")
	_check(_near(CharSelectMath.label_height(0x22, false), 20.0) and _near(CharSelectMath.label_height(0x24, true), 1.06 * 19.0), "the name floats at height factor x 20 (x 19 for a woman)")
	_check(_near(CharSelectMath.label_fade_s(0, 255), 0.5) and _near(CharSelectMath.label_fade_s(128, 0), 128.0 * 0.5 / 255.0), "a label fades at 0.5 s for a whole fade")
	_check(CharSelectMath.button_position(14, 1280, 183, 1099) == Vector2(1280 - 313, 1099 + 27) and CharSelectMath.button_position(13, 1280, 183, 1099) == Vector2(1280 - 105, 1126), "Start at W-313, Back at W-105, 27 below the bottom band's top")
	_check(CharSelectMath.idol_panel_position(Vector2(100, 300), 440) == Vector2(5, 300) and CharSelectMath.idol_panel_position(Vector2(700, 300), 440) == Vector2(480, 300), "an idol panel centres on its idol, its x held at 5 or more")

func _info() -> void:
	_check(CharSelectMath.exp_text(250, 1000) == "25.00%", "EXP 250 of 1000 reads 25.00%")
	_check(CharSelectMath.exp_text(1000, 1000) == "99.99%", "EXP is capped at 99.99%")
	_check(CharSelectMath.exp_text(5, 0) == "0.00%", "no leveldata row reads 0.00%")
	_check(_near(CharSelectMath.gauge_fill(100, 20), 0.5) and _near(CharSelectMath.gauge_fill(500, 20), 1.0), "the HP gauge is HP / (Str x 10)")
	var raw := PackedByteArray([0xFF, 0xFE])
	raw.append_array(("1\t100\t0\n2\t250\t1\n// c\n").to_utf16_buffer())
	var exp := LevelDataReader.parse_exp(raw)
	_check(int(exp.get(1, 0)) == 100 and int(exp.get(2, 0)) == 250 and exp.size() == 2, "leveldata column 1 is the level's EXP")

func _idol_and_start() -> void:
	_check(CharSelectHandoff.race_from_idol_index(0) == CharCatalog.RACE_EUROPE and CharSelectHandoff.race_from_idol_index(1) == CharCatalog.RACE_CHINA and CharSelectHandoff.race_from_idol_index(2) == -1, "retail's idol index 0 is Europe, 1 China")
	var script := load("res://scripts/CharacterSelect.gd") as GDScript
	_check(script != null and script.can_instantiate(), "CharacterSelect.gd compiles")
	if script == null:
		return
	# Idol picking.
	var cs = script.new()
	var got := []
	cs.race_chosen.connect(func(r: int) -> void: got.append(r))
	var scenes := []
	cs.change_scene = func(path: String) -> void: scenes.append(path)
	CharSelectHandoff.race = -1
	cs._pick_idol(1)
	_check(got == [CharCatalog.RACE_CHINA] and CharSelectHandoff.race == CharCatalog.RACE_CHINA, "clicking the China idol emits race_chosen(China) and hands it over")
	_check(cs.state == 9, "and the screen goes to the idol fly (state 9)")
	cs._go_create()
	_check(scenes == [CharSelectHandoff.CREATE_SCENE], "the fly's end opens CharacterCreate.tscn")
	cs._pick_idol(0)
	_check(got.back() == CharCatalog.RACE_EUROPE, "the Europe idol emits race_chosen(Europe)")
	cs.free()
	# The Start flow.
	var st = script.new()
	var sent := []
	var went := []
	st.send_start = func(n: String) -> void: sent.append(n)
	st.change_scene = func(path: String) -> void: went.append(path)
	var start_button := Button.new()
	st._windows[14] = start_button
	st._message = Label.new()
	st._slots = [_rec("first", 9, 0), _rec("second", 3, 0)]
	st.selected = 1
	st.state = 5
	st._on_start_pressed()
	_check(sent == ["second"], "Start sends the selected character's name (0x7001)")
	_check(start_button.disabled, "Start waits for its answer")
	var refused := WorldNet.EnterWorldResult.new()
	refused.ok = false
	refused.reason = "Failed to connect to server.(S1026)"
	st._on_enter_world_result(refused)
	_check(went.is_empty() and st._message.text == refused.reason and not start_button.disabled, "a refusal shows the archive's words and Start comes back")
	var ok := WorldNet.EnterWorldResult.new()
	ok.ok = true
	st._on_enter_world_result(ok)
	_check(went == ["res://scenes/World3D.tscn"] and st.state == 14, "OK enters the world")
	st._message.free()
	start_button.free()
	st.free()
	# The handoff back.
	CharSelectHandoff.came_from = CharSelectHandoff.FROM_OTHER
	_check(CharSelectHandoff.FROM_CREATE_OK == 0 and CharSelectHandoff.FROM_CREATE_CANCEL == 10, "the create screens' return ids are retail's 0 and 10")
