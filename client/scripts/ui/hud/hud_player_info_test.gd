extends SceneTree

## The player block's berserk gauge, stat panel and race emblem (round 629),
## built from a synthetic layout carrying ifplayerminiinfo.txt's real control
## names and rects (never real game data):
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_player_info_test.gd
##
## What is checked is what CIFPlayerMiniInfo does (READ, hud_player_info.gd):
## the orbs fill from CIRCLE4 (bottom) up and an unlit one is HIDDEN; the
## ready circle shows at five; activation hides it and lights the flames; the
## stat panel is a toggle filled from the stats packet, with the client's own
## balance formula; the emblem follows the Country byte.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _control(control_name: String, type: String, rect: String, ddj: String = "", text: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [control_name, type, ddj, rect, text]

func _layout() -> String:
	var body := ""
	body += _control("GDR_PMI_RACE_MARK", "CIFStatic", "53,41,24,24")
	body += _control("GDR_PMI_BTN_STATUP", "CIFButton", "150,3,16,16")
	body += _control("GDR_PMI_BTN_CINFO", "CIFButton", "41,56,20,20")
	body += _control("GDR_PMI_HWAN_EFF_FACE", "CIFStatic", "15,7,48,48")
	for i in range(5):
		body += _control("GDR_PMI_DECO_HWAN_SLOT%d" % i, "CIFDecoratedStatic", "%d,%d,16,28" % [[2, -1, 2, 12, 26][i], [-6, 9, 24, 35, 41][i]])
	var rows := [["PARRY", 225], ["HIT", 205], ["MAGBAL", 185], ["PHYBAL", 165], ["MAGDEF", 145], ["MAGATT", 125], ["PHYDEF", 105], ["PHYATT", 85]]
	for r in rows:
		body += _control("GDR_PMI_TXT_%sDAT" % r[0], "CIFStatic", "132,%d,65,12" % r[1])
		body += _control("GDR_PMI_TXT_%s" % r[0], "CIFStatic", "82,%d,47,12" % r[1])
	body += _control("GDR_PMI_TXT_INTDAT", "CIFStatic", "170,65,29,12")
	body += _control("GDR_PMI_TXT_STRDAT", "CIFStatic", "100,65,29,12")
	body += _control("GDR_PMI_TXT_INT", "CIFStatic", "145,65,23,12")
	body += _control("GDR_PMI_TXT_STR", "CIFStatic", "82,65,15,12")
	body += _control("GDR_PMI_STA_CINFOBG", "CIFStatic", "72,57,135,189")
	body += _control("GDR_PMI_BTN_JAHWAN", "CIFButton", "16,-5,20,20")
	body += _control("GDR_PMI_PICTURE", "CIFStaticWithPictureClip", "15,7,48,48")
	var circles := ["7,13", "4,28", "7,43", "17,54", "31,60"]
	for i in range(5):
		body += _control("GDR_PMI_CIRCLE%d" % i, "CIFStatic", circles[i] + ",8,8")
	body += _control("GDR_PMI_TXT_MP", "CIFStatic", "79,42,124,12")
	body += _control("GDR_PMI_TXT_HP", "CIFStatic", "79,26,124,12")
	body += _control("GDR_PMI_TXT_LEVEL", "CIFStatic", "168,7,37,15")
	body += _control("GDR_PMI_TXT_ID", "CIFStatic", "71,4,93,15")
	body += _control("GDR_PMI_GAUGE_MP", "CIFGauge", "79,41,124,12")
	body += _control("GDR_PMI_GAUGE_HP", "CIFGauge", "79,25,124,12")
	body += _control("GDR_PMI_HWAN_EFF_GLOW", "CIFStatic", "-4,-3,220,80")
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifplayerminiinfo.txt"] = UiLayoutParser.parse(_layout())
	return builder

func _visible(pmi: Node, control_name: String) -> bool:
	var c := pmi.find_child(control_name, true, false) as CanvasItem
	return c != null and c.visible

func _shown_circles(pmi: Node) -> Array:
	var out := []
	for i in range(5):
		if _visible(pmi, "GDR_PMI_CIRCLE%d" % i):
			out.append(i)
	return out

## A stats payload as the server encodes it (88 body bytes, round 629).
func _stats_payload(str_: int, int_: int, level: int, hwan: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2 + 96)
	out.encode_u16(0, 0)
	var o := 2
	out.encode_s64(o, 1000)
	out.encode_s32(o + 8, 214)
	out.encode_s32(o + 12, 214)
	out.encode_s32(o + 16, 26)
	out.encode_s32(o + 20, 19)
	out.encode_s32(o + 24, level)
	out.encode_s64(o + 28, 0)
	out.encode_s64(o + 36, 470)
	out.encode_s32(o + 44, 0)
	out.encode_s32(o + 48, 214)
	out.encode_s32(o + 52, 214)
	out.encode_s32(o + 56, str_)
	out.encode_s32(o + 60, int_)
	out.encode_s32(o + 64, 3)
	out.encode_s32(o + 68, 23)
	out.encode_s32(o + 72, 34)
	out.encode_s32(o + 76, 37)
	out.encode_s32(o + 80, 25)
	out.encode_s32(o + 84, hwan)
	out.encode_s32(o + 88, 36)
	out.encode_s32(o + 92, 35)
	return out

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	# Untyped, so the same file runs against a base without the new methods
	# and reports its FAIL lines before the first missing call.
	var pmi = HudPlayerInfo.new(_builder())
	pmi.setup()
	root.add_child(pmi)
	await process_frame

	# --- The gauge: bottom-up, unlit hidden (NEGATIVE: the base lit CIRCLE0
	# first and only dimmed the rest).
	pmi.set_berserk(0, false)
	_check(_shown_circles(pmi).is_empty(), "gauge 0: no orb shows (got %s)" % [_shown_circles(pmi)])
	_check(not _visible(pmi, "GDR_PMI_BTN_JAHWAN"), "gauge 0: the ready circle is hidden")
	pmi.set_berserk(20, false)
	_check(_shown_circles(pmi) == [4], "one orb: CIRCLE4, the bottom one (got %s)" % [_shown_circles(pmi)])
	pmi.set_berserk(60, false)
	_check(_shown_circles(pmi) == [2, 3, 4], "three orbs: CIRCLE2..4 (got %s)" % [_shown_circles(pmi)])
	_check(not pmi.hwan_ready(), "three orbs: not ready (0x778ac0 wants five)")
	pmi.set_berserk(100, false)
	_check(_shown_circles(pmi) == [0, 1, 2, 3, 4], "five orbs: all shown (got %s)" % [_shown_circles(pmi)])
	_check(_visible(pmi, "GDR_PMI_BTN_JAHWAN"), "five orbs: the ready circle shows")
	_check(pmi.hwan_ready(), "five orbs: ready")

	# --- The ready circle's click is the berserk request.
	var pressed := [0]
	pmi.berserk_pressed.connect(func() -> void: pressed[0] += 1)
	var btn := pmi.find_child("GDR_PMI_BTN_JAHWAN", true, false) as BaseButton
	_check(btn != null, "GDR_PMI_BTN_JAHWAN is a button")
	if btn != null:
		btn.pressed.emit()
	_check(pressed[0] == 1, "pressing the ready circle emits berserk_pressed (got %d)" % pressed[0])

	# --- Activation: the circle hides, the flames and the face light.
	pmi.set_berserk(0, true)
	_check(not _visible(pmi, "GDR_PMI_BTN_JAHWAN"), "berserk on: the ready circle hides")
	var flames := 0
	for i in range(5):
		if _visible(pmi, "GDR_PMI_DECO_HWAN_SLOT%d" % i):
			flames += 1
	_check(flames == 5, "berserk on: five flames (got %d)" % flames)
	_check(_visible(pmi, "GDR_PMI_HWAN_EFF_FACE") and _visible(pmi, "GDR_PMI_HWAN_EFF_GLOW"), "berserk on: the face and glow show")
	pmi.set_hwan_count(0)
	_check(_shown_circles(pmi) == [0, 1, 2, 3, 4], "berserk on: a stats count of 0 does not clear the orbs")
	# FUN_00778ae0(0, 0) refreshes nothing: a count of 0 with no start (an
	# AttackResult during berserk, the body mode's end) leaves the display
	# running (NEGATIVE against round 629's first commit, which ended it).
	pmi.set_berserk(0, false)
	_check(bool(pmi.get("_hwan_active")) and _visible(pmi, "GDR_PMI_DECO_HWAN_SLOT0"), "a count of 0 without a start leaves the berserk display running")
	# The display ends on its own drain: five ticks of timer 2.
	pmi._process(HudPlayerInfo.HWAN_DISPLAY_BASE_SEC + 0.1)
	_check(not bool(pmi.get("_hwan_active")) and _shown_circles(pmi).is_empty() and not _visible(pmi, "GDR_PMI_DECO_HWAN_SLOT4"),
		"the drain ends the display: orbs and flames gone (active %s, orbs %s)" % [str(bool(pmi.get("_hwan_active"))), _shown_circles(pmi)])
	# Death / zone reset (FUN_007b5300) fades a running display out ...
	pmi.set_berserk(100, false)
	pmi.set_berserk(0, true)
	pmi.reset_hwan_display()
	_check(not bool(pmi.get("_hwan_active")), "a reset stops the display")
	# ... and a berserk started straight after is not hidden by the old
	# fade's callback (the tweens are killed on a new start).
	pmi.set_berserk(100, false)
	pmi.set_berserk(0, true)
	await create_timer(1.3).timeout
	var shown := 0
	for i in range(5):
		if _visible(pmi, "GDR_PMI_DECO_HWAN_SLOT%d" % i) and _visible(pmi, "GDR_PMI_CIRCLE%d" % i):
			shown += 1
	_check(shown == 5, "a new berserk right after a reset keeps its five orbs and flames (got %d)" % shown)
	# FUN_007b4f40(0) during a display (round 629-632 integration; NEGATIVE
	# against b0ce3bd, whose refresh stopped the drain and hid the face): the
	# orbs follow the count, the flames hide, and the drain, the face and the
	# glow are left running.
	pmi.set_berserk(60, false)
	_check(_shown_circles(pmi) == [2, 3, 4], "a count during the display lights three orbs (got %s)" % [_shown_circles(pmi)])
	_check(bool(pmi.get("_hwan_active")), "a refresh during the display leaves the drain running")
	_check(_visible(pmi, "GDR_PMI_HWAN_EFF_FACE") and _visible(pmi, "GDR_PMI_HWAN_EFF_GLOW"), "a refresh leaves the face and the glow")
	_check(not _visible(pmi, "GDR_PMI_DECO_HWAN_SLOT4"), "a refresh hides the flames")
	pmi.set_hwan_count(0)
	_check(_shown_circles(pmi) == [2, 3, 4], "a count of 0 without a start refreshes nothing (FUN_00778ae0(0,0))")
	# The drain runs on and, at its fifth step, hides all ten -- the lit
	# three included, as retail's vslot_005 case 2 does.
	pmi._process(HudPlayerInfo.HWAN_DISPLAY_BASE_SEC + 0.1)
	_check(not bool(pmi.get("_hwan_active")) and _shown_circles(pmi).is_empty(), "the drain still ends the display after a refresh (orbs %s)" % [_shown_circles(pmi)])
	pmi.set_berserk(60, false)
	_check(_shown_circles(pmi) == [2, 3, 4] and not bool(pmi.get("_hwan_active")), "a count after the display refreshes it: three orbs")

	# --- The drain step (0x007b4f40): ROUND((stones + player+0x20f8 + 60) *
	# 1000 / 5) ms, fixed at the start (NEGATIVE against b0ce3bd: a fixed 12 s).
	_check(is_equal_approx(pmi.drain_period_seconds(), 12.0), "no bonus: a 12 s step (got %s)" % str(pmi.drain_period_seconds()))
	pmi.set_hwan_time_bonus(5, 3600)
	_check(is_equal_approx(pmi.drain_period_seconds(), 13.0), "a 5 s bonus: a 13 s step (got %s)" % str(pmi.drain_period_seconds()))
	pmi.set_hwan_time_bonus(14, 0)
	_check(is_equal_approx(pmi.drain_period_seconds(), 12.0), "a bonus whose job has no time left adds nothing (got %s)" % str(pmi.drain_period_seconds()))
	pmi.set_hwan_time_bonus(5, 3600)
	pmi.set_berserk(100, false)
	pmi.set_berserk(0, true)
	pmi.set_hwan_time_bonus(0, 0)
	_check(is_equal_approx(pmi.drain_period(), 13.0), "the step is fixed when the display starts (got %s)" % str(pmi.drain_period()))
	pmi._process(60.5)
	_check(bool(pmi.get("_hwan_active")) and int(pmi.get("_hwan_drained")) == 4, "at 60.5 s of a 65 s display four orbs have drained and it runs on (drained %d)" % int(pmi.get("_hwan_drained")))
	pmi._process(4.6)
	_check(not bool(pmi.get("_hwan_active")), "the 65 s display ends at 65 s")

	# --- FUN_007b5300 fades the face and the glow only at alpha 255: one
	# still fading in carries on; the flames' timer keeps running.
	pmi.set_berserk(100, false)
	pmi.set_berserk(0, true)
	pmi.reset_hwan_display()
	_check(not bool(pmi.get("_hwan_active")) and bool(pmi.get("_burn_running")), "a reset stops the drain, not the flames' timer")
	await create_timer(1.3).timeout
	_check(_shown_circles(pmi).is_empty(), "a reset fades the shown orbs out (got %s)" % [_shown_circles(pmi)])
	await create_timer(2.0).timeout
	var face := pmi.find_child("GDR_PMI_HWAN_EFF_FACE", true, false) as CanvasItem
	_check(face != null and face.visible and face.modulate.a >= 1.0, "a face still fading in at the reset finishes fading in (visible %s, alpha %s)" % [str(face.visible) if face != null else "-", str(face.modulate.a) if face != null else "-"])
	pmi.set_berserk(100, false)
	pmi.set_berserk(0, true)
	await create_timer(3.2).timeout
	pmi.reset_hwan_display()
	await create_timer(3.3).timeout
	_check(face != null and not face.visible, "a face at full alpha fades out and hides on a reset")
	pmi.set_hwan(0, false)
	_check(pmi.lit_circles(2) == [3, 4], "lit_circles(2) is [3, 4]")

	# --- The stat panel.
	_check(not _visible(pmi, "GDR_PMI_STA_CINFOBG") and not _visible(pmi, "GDR_PMI_TXT_PHYATTDAT"), "the stat panel starts closed")
	_check(_visible(pmi, "GDR_PMI_BTN_CINFO"), "the stat panel's button shows")
	var cinfo := pmi.find_child("GDR_PMI_BTN_CINFO", true, false) as BaseButton
	if cinfo != null:
		cinfo.pressed.emit()
	_check(_visible(pmi, "GDR_PMI_STA_CINFOBG") and _visible(pmi, "GDR_PMI_TXT_PARRY"), "a press opens it")
	var s := StatsNet.decode_result(_stats_payload(21, 21, 2, 3))
	_check(s.has_rates and s.hit_rate == 36 and s.parry_rate == 35, "the stats packet carries hit rate and parry")
	_check(s.has_hwan_count and s.hwan_count == 3, "the stats packet's fourth tail carries the orb count (got %d)" % s.hwan_count)
	pmi.set_stats(s)
	_check(pmi.stat_value("GDR_PMI_TXT_STRDAT") == "21" and pmi.stat_value("GDR_PMI_TXT_INTDAT") == "21", "Str / Int from the packet")
	_check(pmi.stat_value("GDR_PMI_TXT_PHYATTDAT") == "23 ~ 26", "Phy. atk is the range (got %s)" % pmi.stat_value("GDR_PMI_TXT_PHYATTDAT"))
	_check(pmi.stat_value("GDR_PMI_TXT_MAGATTDAT") == "34 ~ 37", "Mag. atk is the range (got %s)" % pmi.stat_value("GDR_PMI_TXT_MAGATTDAT"))
	_check(pmi.stat_value("GDR_PMI_TXT_PHYDEFDAT") == "19" and pmi.stat_value("GDR_PMI_TXT_MAGDEFDAT") == "25", "both defences")
	_check(pmi.stat_value("GDR_PMI_TXT_PHYBALDAT") == "72 %" and pmi.stat_value("GDR_PMI_TXT_MAGBALDAT") == "58 %",
		"balances by the client's formula: 72 %% / 58 %% for Str 21 Int 21 Lv 2 (got %s / %s)" % [
			pmi.stat_value("GDR_PMI_TXT_PHYBALDAT"), pmi.stat_value("GDR_PMI_TXT_MAGBALDAT")])
	_check(pmi.stat_value("GDR_PMI_TXT_HITDAT") == "36" and pmi.stat_value("GDR_PMI_TXT_PARRYDAT") == "35",
		"hit rate and parry from the packet's fifth and sixth tails (got %s / %s)" % [pmi.stat_value("GDR_PMI_TXT_HITDAT"), pmi.stat_value("GDR_PMI_TXT_PARRYDAT")])
	_check(_shown_circles(pmi) == [2, 3, 4], "the packet's orb count lights three (got %s)" % [_shown_circles(pmi)])
	_check(_visible(pmi, "GDR_PMI_BTN_STATUP"), "the stat-point '+' shows with points to spend")
	pmi.set_stats(StatsNet.decode_result(_stats_payload(22, 21, 2, 3)))
	_check(pmi.stat_value("GDR_PMI_TXT_STRDAT") == "22" and _visible(pmi, "GDR_PMI_STA_CINFOBG"), "a new packet updates the open panel, which stays open")
	_check(pmi.balance_percent(200, 1, false) == 120, "a balance caps at 120")
	if cinfo != null:
		cinfo.pressed.emit()
	_check(not _visible(pmi, "GDR_PMI_STA_CINFOBG"), "a second press closes it")

	# --- The race emblem.
	_check(not _visible(pmi, "GDR_PMI_RACE_MARK"), "no emblem before the race is known")
	pmi.set_race(0)
	_check(_visible(pmi, "GDR_PMI_RACE_MARK") and pmi.race_mark_path().ends_with("com_kindred_china.ddj"), "Country 0: the China emblem")
	pmi.set_race(1)
	_check(pmi.race_mark_path().ends_with("com_kindred_europe.ddj"), "Country 1: the Europe emblem")
	var rows := "1\t1909\tCHAR_CH_MAN_FIGHTER\tx\tx\tx\tx\t0\t1\t1\t1\t1\t0\t0\t0\t0\n1\t14884\tCHAR_EU_MAN_ADVENTURER\tx\tx\tx\tx\t0\t1\t1\t1\t1\t0\t0\t1\t0\n"
	var utf16 := PackedByteArray([0xFF, 0xFE])
	utf16.append_array(rows.to_utf16_buffer())
	var reader = NpcTableReader.new()
	var countries: Dictionary = reader.parse_country_by_code(utf16)
	_check(countries.get("CHAR_CH_MAN_FIGHTER", -1) == 0 and countries.get("CHAR_EU_MAN_ADVENTURER", -1) == 1, "characterdata column 14 read per code (got %s)" % [countries])

	# 0x30BF kind 4 value 1 carries one more byte (0x8a80a0 reads it only then).
	var on := PackedByteArray([7, 0, 0, 0, 4, 1, 9])
	var sc = WorldNet.decode_state_change(on)
	_check(sc != null and sc.kind == 4 and sc.value == 1 and sc.get("extra") == 9, "a body-mode-on change decodes its extra byte")
	_check(WorldNet.decode_state_change(on.slice(0, 6)) == null, "a body-mode-on change without its extra byte is refused")

	print("hud_player_info_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
