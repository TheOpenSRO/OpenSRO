extends SceneTree

## Round 691: the skill window lays out the player's race's masteries. Synthetic
## skillmasterydata rows shaped like the real table (never real game data):
##   godot4 --headless --path client --script res://scripts/ui/hud/skill_window_race_test.gd
##
## A Europe character's window shows Europe's three tabs (Physical/Magical/
## Assist; the fallback labels Melee/Caster/Buff with no text table) and its
## six masteries, two to a tab, and none of China's; a China character's shows
## China's two tabs and seven masteries and none of Europe's. The race comes
## from the server's mastery list (OpSkillState names every held mastery). The
## mastery total reads against the race's cap: 330 flat for China,
## min(240, 2 x level) for Europe (CIFSkill FUN_006aa3e0, READ).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A skillmasterydata row with the columns MasteryReader reads.
func _row(id: int, name_code: String, tab_code: String, tab: int, icon: String) -> String:
	var cols := PackedStringArray()
	cols.resize(13)
	cols.fill("0")
	cols[MasteryReader.COL_ID] = str(id)
	cols[MasteryReader.COL_NAME_CODE] = name_code
	cols[MasteryReader.COL_TAB_CODE] = tab_code
	cols[MasteryReader.COL_TAB] = str(tab)
	cols[MasteryReader.COL_ICON] = icon
	return "\t".join(cols)

func _table() -> Array:
	var rows := PackedStringArray(["//Mastery ID\tthe header row"])
	for id in [257, 258, 259]:
		rows.append(_row(id, "UIIT_STT_CH_%d" % id, "UIIT_CTL_WEAPON_SKILL", 0, "icon\\skillmastery\\china\\m%d.ddj" % id))
	for id in [273, 274, 275, 276]:
		rows.append(_row(id, "UIIT_STT_CH_%d" % id, "UIIT_CTL_FORCE_SKILL", 1, "icon\\skillmastery\\china\\m%d.ddj" % id))
	# Europe in the table's own file order: 513, 515, 514, 516, 517, 518.
	var eu := [[513, 0], [515, 0], [514, 1], [516, 1], [517, 2], [518, 2]]
	var codes := ["UIIT_CTL_EU_SKILLWND_PHYSICAL", "UIIT_CTL_EU_SKILLWND_MASICAL", "UIIT_CTL_EU_SKILLWND_ASSIST"]
	for e in eu:
		rows.append(_row(int(e[0]), "UIIT_STT_EU_%d" % int(e[0]), codes[int(e[1])], int(e[1]),
			"icon\\skillmastery\\europe\\m%d.ddj" % int(e[0])))
	# A row neither race holds (the table's 1-4) is dropped.
	rows.append(_row(2, "xxx", "", 255, "xxx"))
	return MasteryReader.parse_all(("\n".join(rows) + "\n").to_utf16_buffer())

func _window() -> HudWindow:
	var w := HudWindow.new()
	w.panel_root = Control.new()
	w.add_child(w.panel_root)
	var board := Control.new()
	board.name = "GDR_SKILL_BOARD"
	board.size = Vector2(345, 241)
	w.panel_root.add_child(board)
	for n in ["GDR_SKILL_TEXT_SP_NUM", "GDR_SKILL_TEXT_TOTAL_MASTERYLEV_NUM"]:
		var l := Label.new()
		l.name = n
		w.panel_root.add_child(l)
	return w

## The titles of one of the view's tab strips (round 781: SkillBoard draws the
## tabs as art buttons with a Title label, beside the board in the pane).
func _tabs(w: HudWindow, strip: String) -> PackedStringArray:
	var out := PackedStringArray()
	var view := w.find_child("SkillBoardView", true, false)
	if view == null:
		return out
	var node := view.find_child(strip, true, false)
	if node == null:
		return out
	for c in node.get_children():
		var title := (c as Node).get_node_or_null("Title") as Label
		if title != null and not c.is_queued_for_deletion():
			out.append(title.text)
	return out

func _ids(masteries: Array) -> Array:
	var out: Array = []
	for m in masteries:
		out.append((m as MasteryReader.Mastery).id)
	return out

func _panels(script: GDScript) -> Node:
	var p: Node = script.new()
	p.set("_mastery_table", _table())
	p.set("_masteries_loaded", true)
	# No archive in a suite: mark the catalog read so the fill does not look.
	p.set("_skill_catalog_loaded", true)
	return p

func _init() -> void:
	# The pure parts first.
	var table := _table()
	_check(table.size() == 13, "parse_all keeps both races' 13 masteries and drops the rest (got %d)" % table.size())
	var eu := MasteryReader.for_race(table, MasteryReader.RACE_EUROPE)
	_check(_ids(eu) == [513, 515, 514, 516, 517, 518],
		"Europe's masteries come by tab then id: Warrior, Rogue | Wizard, Warlock | Bard, Cleric (got %s)" % str(_ids(eu)))
	var ch := MasteryReader.for_race(table, MasteryReader.RACE_CHINA)
	_check(_ids(ch) == [257, 258, 259, 273, 274, 275, 276], "China's seven, weapon then force (got %s)" % str(_ids(ch)))
	_check(MasteryReader.race_of_masteries([517, 518]) == MasteryReader.RACE_EUROPE
		and MasteryReader.race_of_masteries([257]) == MasteryReader.RACE_CHINA
		and MasteryReader.race_of_masteries([1, 2]) == -1,
		"race_of_masteries names the race of a held list, -1 for none")

func _initialize() -> void:
	var script := load("res://scripts/ui/hud/hud_panels.gd") as GDScript
	_check(script != null and script.can_instantiate(), "HudPanels compiles")
	if script == null or not script.can_instantiate():
		_finish()
		return

	# The cap the total reads against.
	_check(int(script.call("mastery_total_cap", MasteryReader.RACE_CHINA, 10)) == 330, "China's total cap is 330 at level 10")
	_check(int(script.call("mastery_total_cap", MasteryReader.RACE_EUROPE, 20)) == 40, "Europe's total cap is 2 x 20 = 40 at level 20")
	_check(int(script.call("mastery_total_cap", MasteryReader.RACE_EUROPE, 130)) == 240, "Europe's total cap stops at 240 (level 130)")

	# A Europe character: the server lists 513-518 (Rogue at 3).
	var p := _panels(script)
	p.call("set_skill_state", 5, {513: 0, 514: 0, 515: 3, 516: 0, 517: 0, 518: 0}, 20, {})
	var w := _window()
	p.call("_fill_skill_masteries", w)
	_check(_ids(p.get("_masteries")) == [513, 515, 514, 516, 517, 518],
		"a Europe character's window holds the six Europe masteries (got %s)" % str(_ids(p.get("_masteries"))))
	var top := _tabs(w, "SkillCategoryTabs")
	_check(top == PackedStringArray(["Melee", "Caster", "Buff"]), "three top tabs, Physical/Magical/Assist (got %s)" % str(top))
	var sub := _tabs(w, "SkillMasteryTabs")
	_check(sub.size() == 2, "the first tab holds two masteries, Warrior and Rogue (got %s)" % str(sub))
	var total := (w.node("GDR_SKILL_TEXT_TOTAL_MASTERYLEV_NUM") as Label).text
	_check(total == "3/40", "the total reads against min(240, 2 x 20), \"%%d/%%d\" (got '%s')" % total)
	p.call("_on_skill_tab", 2)
	p.call("_fill_skill_masteries", w)
	var view := w.find_child("SkillBoardView", true, false)
	var board: Node = view.find_child("SkillHeader", true, false) if view != null else null
	_check(board != null, "the Assist tab lays out a mastery board")
	var shown: Array = []
	for m in p.get("_masteries"):
		if (m as MasteryReader.Mastery).tab == 2:
			shown.append((m as MasteryReader.Mastery).id)
	_check(shown == [517, 518], "the Assist tab's masteries are Bard and Cleric (got %s)" % str(shown))
	# NEGATIVE: no China mastery anywhere in a Europe window.
	var any_china := false
	for id in _ids(p.get("_masteries")):
		if int(id) < 513:
			any_china = true
	_check(not any_china, "a Europe window lists no China mastery")

	# A China character: 257-276, two tabs, the flat 330.
	var q := _panels(script)
	q.call("set_skill_state", 0, {257: 4, 258: 0, 259: 0, 273: 0, 274: 0, 275: 0, 276: 0}, 20, {})
	var w2 := _window()
	q.call("_fill_skill_masteries", w2)
	_check(_ids(q.get("_masteries")) == [257, 258, 259, 273, 274, 275, 276],
		"a China character's window holds China's seven (got %s)" % str(_ids(q.get("_masteries"))))
	var top2 := _tabs(w2, "SkillCategoryTabs")
	_check(top2 == PackedStringArray(["Weapon", "Force"]), "China has two top tabs (got %s)" % str(top2))
	var sub2 := _tabs(w2, "SkillMasteryTabs")
	_check(sub2.size() == 3, "China's Weapon tab holds its three weapon masteries (got %s)" % str(sub2))
	var total2 := (w2.node("GDR_SKILL_TEXT_TOTAL_MASTERYLEV_NUM") as Label).text
	_check(total2 == "4/330", "China's total reads against 330 (got '%s')" % total2)

	# Before any state the window is China's (the default race), and a QA
	# override can lay out Europe's.
	var r := _panels(script)
	r.call("set_skill_race", MasteryReader.RACE_EUROPE)
	var w3 := _window()
	r.call("_fill_skill_masteries", w3)
	_check(_ids(r.get("_masteries")).size() == 6 and int(r.get("_skill_race")) == MasteryReader.RACE_EUROPE,
		"set_skill_race(Europe) lays out the six Europe masteries")

	_mastery_name_checks(script)
	_finish()

## Round 786, REGRESSION GUARD ("sorcery -> cold force"): the China window's
## mastery tabs and header, with the real mastery name codes and a joined
## textuisystem shaped like the archive's (a first table, then a stock table
## naming 273 "Sorcery"): the Force tab reads Cold, Lightning, Fire, Force and
## 273's header "Cold Mastery" -- the client's first row (0x69f860 ->
## 0x8c9bb0, keep-first 0x8ca120). And no control of the window carries a
## native tooltip_text (the hover goes to the original's bubble).
func _mastery_name_checks(script: GDScript) -> void:
	var codes := {257: "VI", 258: "HEUK", 259: "PA", 273: "HAN", 274: "PUNG", 275: "HWA", 276: "GI"}
	var rows := PackedStringArray(["//Mastery ID\tthe header row"])
	for id in codes:
		var tab := 0 if int(id) < 270 else 1
		rows.append(_row(int(id), "UIIT_STT_MASTERY_%s" % codes[id], "UIIT_CTL_FORCE_SKILL" if tab == 1 else "UIIT_CTL_WEAPON_SKILL",
			tab, "icon\\skillmastery\\china\\m%d.ddj" % int(id)))
	var table := MasteryReader.parse_all(("\n".join(rows) + "\n").to_utf16_buffer())
	var text := PackedStringArray()
	var english := [["Bicheon", "Heuksal", "Pacheon", "Cold", "Lightning", "Fire", "Force"],
		["Bicheon", "Heuksal", "Pacheon", "Sorcery", "Lightning", "Fire", "Force"]]
	for block in english:
		for i in 8:
			text.append("1\tUIIT_K%d\tፕ\t0\t0\t0\t0\t0\tK%d" % [i, i])
		var k := 0
		for id in codes:
			text.append("1\tUIIT_STT_MASTERY_%s\tፕ\t0\t0\t0\t0\t0\t%s" % [codes[id], block[k]])
			k += 1
		text.append("1\tUIIT_CTL_FORCE_SKILL\tፕ\t0\t0\t0\t0\t0\tForce")
		text.append("1\tPARAM_MASTERY\tፕ\t0\t0\t0\t0\t0\tMastery")
	var tt := UiTextTable.parse(("\n".join(text) + "\n").to_utf16_buffer())
	var z: Node = script.new()
	z.set("_builder", UiBuilder.new(null, tt))
	z.set("_mastery_table", table)
	z.set("_masteries_loaded", true)
	z.set("_skill_catalog_loaded", true)
	z.call("set_skill_state", 0, {257: 0, 258: 0, 259: 0, 273: 3, 274: 0, 275: 0, 276: 0}, 20, {})
	z.set("_skill_active_tab", 1)
	var w := _window()
	z.call("_fill_skill_masteries", w)
	var force := _tabs(w, "SkillMasteryTabs")
	_check(force == PackedStringArray(["Cold", "Lightning", "Fire", "Force"]),
		"REGRESSION: the Force tab's masteries read Cold, Lightning, Fire, Force -- not Sorcery (got %s)" % str(force))
	var view := w.find_child("SkillBoardView", true, false)
	var name_node: Node = view.find_child("GDR_SKILLBOARD_MASTERYNAME", true, false) if view != null else null
	var header := (name_node as Label).text if name_node is Label else ""
	_check(header == "Cold Mastery", "273's header reads \"%%s %%s\" = 'Cold Mastery' (got '%s')" % header)
	var natives := 0
	if view != null:
		for n in view.find_children("*", "Control", true, false):
			if (n as Control).tooltip_text != "":
				natives += 1
	_check(view != null and natives == 0, "NEGATIVE: no control of the skill window keeps a native tooltip_text (got %d)" % natives)
	var icon: Node = view.find_child("GDR_SKILLBOARD_ICON", true, false) if view != null else null
	var tip: Array = z.call("bubble_tip_lines", icon) if icon is Control else []
	_check(not tip.is_empty() and String(tip[0]["text"]) == "Cold", "the mastery icon's help is in the bubble, its first row the name (got %s)" % str(tip))
	z.free()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
