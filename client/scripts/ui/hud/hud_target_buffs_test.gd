extends SceneTree

## Headless checks for the target window's buff viewer and race emblem
## (round 638, docs/protocol/target_window_buffs.md): the per-owner book fed by
## OpBuffStart / OpBuffEnd, CIFBuffViewer's grid (0x7fbea0), its per-second
## diff (0x7fd640), its tooltip (0x7fc260), where HudTarget puts it
## (0x69a1ab) and the kindred mark's file (0x98caa0). Synthetic skill rows and
## a synthetic text table: no archive, no game data.
##
## Everything is reached by name (load / has_method / call), so on a base
## without the viewer this script still runs and prints FAIL lines instead of
## failing to compile.

const VIEWER_PATH := "res://scripts/ui/hud/hud_target_buffs.gd"
const HudTarget = preload("res://scripts/ui/hud/hud_target.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A text table with the given code -> English rows (textuisystem's shape:
## service 1, the code in column 1, English in column 8), UTF-16 as the file.
static func _names(rows: Dictionary) -> UiTextTable:
	var text := ""
	for code in rows:
		text += "1\t%s\tx\t0\t0\t0\t0\t0\t%s\t%s\n" % [code, rows[code], rows[code]]
	return UiTextTable.parse(text.to_utf16_buffer())

func _catalog() -> SkillBuffCatalog:
	var c := SkillBuffCatalog.new(null)
	# Synthetic rows (the ids are real skill ids so the log reads well, the
	# contents are made up): 113 plain, 107 plain, 157 bbuf, 34917 lnks.
	c.set_row({"id": 113, "level": 1, "icon": "skill\\t_a.ddj", "name_code": "SN_T_A", "desc_code": "SN_T_A_STUDY",
		"cbuf": false, "nbuf": false, "bbuf": false, "lnks": false})
	c.set_row({"id": 107, "level": 3, "icon": "skill\\t_b.ddj", "name_code": "SN_T_B", "desc_code": "",
		"cbuf": false, "nbuf": false, "bbuf": false, "lnks": false})
	c.set_row({"id": 157, "level": 2, "icon": "skill\\t_c.ddj", "name_code": "SN_T_C", "desc_code": "",
		"cbuf": false, "nbuf": true, "bbuf": true, "lnks": false})
	c.set_row({"id": 34917, "level": 5, "icon": "skill\\t_d.ddj", "name_code": "SN_SKILL_CENTURION", "desc_code": "",
		"cbuf": false, "nbuf": false, "bbuf": false, "lnks": true})
	# The premium's skill row shape (round 638 review): a USU1 skill buff.
	c.set_row({"id": 5412, "level": 1, "icon": "item\\etc\\t_pre.ddj", "name_code": "SN_SKILL_MALL_PRE_APRU_4W", "desc_code": "",
		"cbuf": false, "nbuf": false, "bbuf": false, "lnks": false})
	for i in 20:
		c.set_row({"id": 1000 + i, "level": 1, "icon": "", "name_code": "SN_N%d" % i, "desc_code": "",
			"cbuf": false, "nbuf": false, "bbuf": false, "lnks": false})
	c.set_names(_names({"SN_T_A": "Grass Walk", "SN_T_A_STUDY": "Moves faster.", "SN_T_B": "Lightning Force",
		"SN_SKILL_CENTURION": "Centurion"}))
	# The premium's name is only in textdata_object (MEASURED), the second
	# file of the client's one text map.
	var objects := _names({"SN_SKILL_MALL_PRE_APRU_4W": "Premium"})
	c.set("object_names_provider", func() -> UiTextTable: return objects)
	c.finish_loading()
	return c

func _ids(list: Array) -> Array:
	var out: Array = []
	for b in list:
		out.append(int(b["skill_id"]))
	return out

func _init() -> void:
	var exists := ResourceLoader.exists(VIEWER_PATH)
	_check(exists, "hud_target_buffs.gd exists (the CIFBuffViewer port)")
	var Viewer = load(VIEWER_PATH) if exists else null

	# --- The book: every owner's buffs in start order (0x9cd050 appends). ---
	var book = Viewer.Book.new() if Viewer != null else null
	_check(book != null, "a per-owner buff book exists")
	if book != null:
		book.start("character:7", 11, 113)
		book.start("character:7", 12, 107)
		book.start("character:8", 13, 157)
		book.start("character:7", 12, 107) # a zone re-send of the same token
		book.start("character:7", 14, 0)   # skill id not > 0: skipped (0x9d25e0)
		_check(_ids(book.list_of("character:7")) == [113, 107], "book: arrival order, a re-sent token once, id 0 skipped")
		_check(_ids(book.list_of("character:8")) == [157], "book: owners kept apart")
		book.end("character:7", [11])
		_check(_ids(book.list_of("character:7")) == [107], "book: an end removes its token")
		book.drop("character:8")
		_check(book.list_of("character:8").is_empty(), "book: an owner that left has none")
		var copy: Array = book.list_of("character:7")
		copy.clear()
		_check(book.list_of("character:7").size() == 1, "book: list_of is a copy")
		book.clear()
		_check(book.list_of("character:7").is_empty(), "book: clear empties every owner")

	# --- The grid (0x7fbea0 with 0x699480's 8, 23x23, 20x20). ---
	var cat := _catalog()
	var v = Viewer.new(null, cat) if Viewer != null else null
	_check(v != null, "the viewer builds without an archive")
	if v != null:
		var ten: Array = []
		for i in 10:
			ten.append({"token": 100 + i, "skill_id": 1000 + i})
		v.rebuild(ten)
		_check(v.count(true) == 10 and v.count(false) == 0, "ten plain buffs -> main list")
		_check(v.slot_of(1000).position == Vector2(0, 0), "icon 0 at (0,0)")
		_check(v.slot_of(1007).position == Vector2(161, 0), "icon 7 at (7*23, 0)")
		_check(v.slot_of(1008).position == Vector2(0, 23), "icon 8 wraps to (0, 23): 8 a row, 23 px rows")
		_check(v.slot_of(1009).position == Vector2(23, 23), "icon 9 at (23, 23)")
		_check(v.size == Vector2(184, 69), "size 184 x (2 main rows + 1 second) * 23")
		var slot = v.slot_of(1000)
		_check(slot.size == Vector2(20, 20), "a slot is the bare 20x20 icon")
		_check(slot.get_child_count() == 1 and slot.get_child(0).name == "Icon",
			"no time gauge under a target's icon (0x806d50's first argument is 0)")

		# bbuf -> the second list; an empty main list counts NO rows here.
		v.rebuild([{"token": 1, "skill_id": 157}])
		_check(v.count(true) == 0 and v.count(false) == 1, "a bbuf skill goes to the second list")
		_check(v.slot_of(157).position == Vector2(0, 2),
			"second list under an EMPTY main list starts at y 2 (rows1 = 0, 0x7fbff1)")
		v.rebuild([{"token": 1, "skill_id": 113}, {"token": 2, "skill_id": 157}, {"token": 3, "skill_id": 107}])
		_check(v.skill_ids(true) == [113, 107] and v.skill_ids(false) == [157], "mixed: lists kept in order")
		_check(v.slot_of(157).position == Vector2(0, 25), "second list one main row down plus 2: (0, 25)")
		_check(v.slot_of(107).position == Vector2(23, 0), "main list closes up: 107 at (23, 0)")
		v.rebuild([])
		_check(v.size == Vector2(184, 23), "empty viewer: size 184 x 23 (the second list's one row)")

		# --- The per-second diff (0x7fd640). ---
		v.rebuild([{"token": 1, "skill_id": 113}, {"token": 2, "skill_id": 107}, {"token": 3, "skill_id": 34917}])
		var kept = v.slot_of(34917)
		v.sync([{"token": 1, "skill_id": 113}, {"token": 3, "skill_id": 34917}, {"token": 4, "skill_id": 1000}])
		_check(v.skill_ids(true) == [113, 34917, 1000], "diff: the ended one goes, the new one is appended")
		_check(v.slot_of(34917) == kept, "diff: a buff still on keeps its slot")
		_check(v.slot_of(34917).position == Vector2(23, 0), "diff: the grid is laid out again")
		v.sync([])
		_check(v.count(true) == 0 and v.count(false) == 0, "diff with nothing left: empty")

		# --- The tooltip (0x7fc260). ---
		_check(v.tooltip_for(113) == "Grass Walk Lv 1\n\nMoves faster.",
			"tooltip: \"%%s Lv %%d\" then the description (got '%s')" % v.tooltip_for(113).c_escape())
		_check(v.tooltip_for(107) == "Lightning Force Lv 3", "tooltip: no description, no time line")
		_check(v.tooltip_for(34917) == "Centurion", "tooltip: a name-only code shows the name alone")
		_check(not v.tooltip_for(113).contains("Remain"), "tooltip: no remaining time for a target's buff")
		# 0x7fc412..0x7fc594's list has no SN_SKILL_MALL_PRE_APRU_4W (the
		# buff bar's does): a target's premium reads "<name> Lv 1".
		_check(cat.text_of("SN_SKILL_MALL_PRE_APRU_4W") == "Premium",
			"a skill name only textdata_object has resolves (the client's one text map)")
		_check(cat.text_of("SN_T_A") == "Grass Walk", "the skill table still comes first")
		_check(v.tooltip_for(5412) == "Premium Lv 1", "tooltip: a target's premium is \"<name> Lv 1\" (got '%s')" % v.tooltip_for(5412))
		v.free()

	# --- HudTarget: where the viewer goes, the kindred mark. ---
	var hud := HudTarget.new(null)
	_check(hud.has_method("buff_viewer_offset"), "HudTarget places a buff viewer")
	if hud.has_method("buff_viewer_offset"):
		_check(hud.call("buff_viewer_offset", Vector2(236, 35)) == Vector2(0, 36),
			"player piece 236x35 -> viewer at (0, 36): piece bottom + 1")
		_check(hud.call("buff_viewer_offset", Vector2(236, 78)) == Vector2(0, 79),
			"special-mob piece 236x78 -> viewer at (0, 79)")
	_check(hud.has_method("kindred_mark_path"), "HudTarget knows the race emblem")
	if hud.has_method("kindred_mark_path"):
		_check(String(hud.call("kindred_mark_path", 0)) == "interface\\ifcommon\\com_kindred_china.ddj", "race 0 -> China emblem")
		_check(String(hud.call("kindred_mark_path", 1)) == "interface\\ifcommon\\com_kindred_europe.ddj", "race 1 -> Europe emblem")
		_check(String(hud.call("kindred_mark_path", 2)) == "" and String(hud.call("kindred_mark_path", -1)) == "",
			"any other race -> no emblem")

	# The live refresh (timer 1, 1000 ms), with a viewer put in by hand.
	if Viewer != null and hud.has_method("advance_buffs"):
		var feed = Viewer.Book.new()
		feed.start("character:5", 21, 113)
		var viewer = Viewer.new(null, cat)
		hud.set("_buffs", viewer)
		hud.add_child(viewer)
		hud.set("buff_source", feed.list_of)
		var piece := Control.new()
		piece.size = Vector2(236, 35)
		hud.call("_show_buffs", piece, "character:5")
		_check(viewer.visible and viewer.position == Vector2(0, 36), "shown under the piece")
		_check(viewer.skill_ids(true) == [113], "first fill from the owner's list")
		feed.start("character:5", 22, 107)
		hud.call("advance_buffs", 999.0)
		_check(viewer.skill_ids(true) == [113], "not yet: the refresh is every 1000 ms")
		hud.call("advance_buffs", 1.0)
		_check(viewer.skill_ids(true) == [113, 107], "a started buff appears on the next tick")
		feed.end("character:5", [21])
		hud.call("advance_buffs", 1000.0)
		_check(viewer.skill_ids(true) == [107], "an ended buff goes on the next tick")
		# The same target shown again (an HP update) keeps its slots.
		var kept_slot = viewer.slot_of(107)
		hud.call("_show_buffs", piece, "character:5")
		_check(viewer.slot_of(107) == kept_slot, "showing the same target again keeps its icons (a diff, not a rebuild)")
		# Re-keyed: this player selected before its id came.
		if hud.has_method("set_buff_owner"):
			feed.start("character:9", 31, 1001)
			hud.call("set_buff_owner", "character:9")
			_check(viewer.skill_ids(true) == [1001], "re-keyed to the real id: that owner's buffs")
			hud.call("set_buff_owner", "character:5")
		else:
			_check(false, "HudTarget can re-key its owner")
		# vslot_012: a target that no longer exists hides the window.
		if hud.has_method("check_target"):
			var lost: Array = []
			hud.connect("target_lost", func(k: String) -> void: lost.append(k))
			hud.visible = true
			hud.set("target_exists", func(_k: String) -> bool: return true)
			_check(not bool(hud.call("check_target")) and hud.visible, "a target that exists keeps the window")
			hud.set("target_exists", func(_k: String) -> bool: return false)
			_check(bool(hud.call("check_target")) and not hud.visible and lost == ["character:5"],
				"a target that is gone hides the window and says which (vslot_012)")
			_check(not viewer.visible and String(hud.call("buff_owner")) == "", "and the viewer goes with it")
			hud.set("target_exists", func(_k: String) -> bool: return true)
		else:
			_check(false, "HudTarget checks its target each frame (vslot_012)")
		hud.call("_show_buffs", piece, "character:5")
		hud.call("_show_buffs", null, "monster:3")
		_check(not viewer.visible, "no piece (a rarity-2 monster): no viewer")
		hud.call("_show_buffs", piece, "character:5")
		hud.clear()
		_check(not viewer.visible and viewer.count(true) == 0, "closing the window hides and empties it")
		piece.free()
	else:
		_check(false, "HudTarget refreshes the viewer every 1000 ms")
	hud.free()

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % _failures)
	quit(1 if _failures > 0 else 0)
