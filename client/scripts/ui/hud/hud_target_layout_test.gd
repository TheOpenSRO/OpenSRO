extends SceneTree

## The target window's container is resinfo\iftargetwindow.txt, the layout
## CIFTargetWindow::Create (0x699080) loads, read with the defines this build
## takes (docs/RE_COMPLETION.md, round 588). The fixtures carry the authored
## names, IDs, rects and UVs of the real controls, with both #ifdef branches
## spelled as the archive spells them, and one synthetic atlas texture --
## never real game data:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_target_layout_test.gd
##
## Round 589 adds which window a monster gets: CIFTargetWindow's CICMonster
## branch (0x6996a0, table 0x69a2d0) shows the special-mob window for rarity
## 0, 1, 3-8 and no piece for 2 (or anything above 8), and 0x69b4c0 fills its
## rank icon, rank text and "Lv %d" level row.
##
## Also cached: iftargetwindowex.txt, the file the window used to read (in the
## archive, never loaded by the exe), so a tree that still reads it builds
## and fails on what it shows rather than on a missing file.

const TARGET_PATH := "res://scripts/ui/hud/hud_target.gd"
const ATLAS := "interface\\ifcommon\\window_all.ddj"
const ATLAS_SIZE := Vector2i(1024, 512)

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## A control with the fields these layouts use. `uv` is [lt, rb] or [].
func _control(control_name: String, type: String, id: int, rect: String, ddj: String = "",
		uv: Array = []) -> String:
	var uvs := ""
	if not uv.is_empty():
		uvs = "\t\tUV_LT=POINT,\"%s\"\n\t\tUV_RB=POINT,\"%s\"\n" % uv
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"1\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n%s\t}\n" % [
		control_name, type, ddj, id, rect, uvs]

func _layout(body: String) -> String:
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

## iftargetwindow.txt as the archive has it.
func _container() -> String:
	var body := _control("GDR_TW_BUFF", "CIFBuffViewer", 100, "0,37,0,0")
	body += _control("GDR_TW_CLOSE", "CIFCloseButton", 11, "176,9,16,16")
	body += "#ifdef APPLY_SIEGE_FORTRESS_SYSTEM\n"
	body += _control("GDR_TW_FORTRESSSTRUCTER", "CIFTargetWindowFortressStructure", 8, "0,0,196,51", ATLAS, ["0.723632,0.626953", "0.954101,0.726562"])
	body += "#endif\n#ifdef UI_UPDATE_2009_FIRST\n"
	body += _control("GDR_TW_COMMONENEMY", "CIFTargetWindowCommonEnemy", 4, "0,0,236,51", ATLAS, ["0.72363,0.8847", "0.9541,0.9550"])
	body += _control("GDR_TW_SPECIALMOBWND", "CIFTargetWindowSpecialMob", 2, "0,0,236,78", ATLAS, ["0.723632,0.730468", "0.954101,0.882812"])
	body += _control("GDR_TW_JOB_PLAYERWND", "CIFTargetWindowJobPlayer", 1, "0,0,236,58", ATLAS, ["0.530273,0.410156", "0.72168,0.523438"])
	body += _control("GDR_TW_PLAYERWND", "CIFTargetWindowPlayer", 0, "0,0,236,35", ATLAS, ["0.492187,0.716796", "0.722656,0.785156"])
	body += "#else\n"
	body += _control("GDR_TW_COMMONENEMY", "CIFTargetWindowCommonEnemy", 4, "0,0,196,51", ATLAS, ["0.530273,0", "0.72168,0.0996094"])
	body += _control("GDR_TW_SPECIALMOBWND", "CIFTargetWindowSpecialMob", 2, "0,0,196,78", ATLAS, ["0.530273,0.101563", "0.72168,0.253906"])
	body += _control("GDR_TW_JOB_PLAYERWND", "CIFTargetWindowJobPlayer", 1, "0,0,196,58", ATLAS, ["0.530273,0.410156", "0.72168,0.523438"])
	body += _control("GDR_TW_PLAYERWND", "CIFTargetWindowPlayer", 0, "0,0,196,36", ATLAS, ["0.530273,0.564453", "0.721679,0.634765"])
	body += "#endif\n"
	return _layout(body)

## iftargetwindowex.txt: the #else pieces and the close button, no branches.
func _container_ex() -> String:
	return _layout(_control("GDR_TW_CLOSE", "CIFCloseButton", 11, "176,9,16,16")
		+ _control("GDR_TW_COMMONENEMY", "CIFTargetWindowCommonEnemy", 4, "0,0,196,51", ATLAS, ["0.530273,0", "0.72168,0.0996094"])
		+ _control("GDR_TW_SPECIALMOBWND", "CIFTargetWindowSpecialMob", 2, "0,0,196,78", ATLAS, ["0.530273,0.101563", "0.72168,0.253906"]))

## A name row whose rect is behind #ifdef UI_UPDATE_2009_FIRST, as the
## iftw_* files spell it (a property-level branch).
func _name_row(control_name: String, id: int, rect_else: String) -> String:
	return "\t%s:CIFStatic\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"1\"\n\t\tID=INTEGER,\"%d\"\n#ifdef UI_UPDATE_2009_FIRST\n\t\tRect=RECT,\"34,10,170,12\"\n#else\n\t\tRect=RECT,\"%s\"\n#endif\n\t\tText=STRING,\"\"\n\t}\n" % [control_name, id, rect_else]

func _common() -> String:
	return _layout(_control("GDR_TWCE_GEM", "CIFStatic", 10, "8,5,20,20")
		+ _control("GDR_TWCE_GAUGE_HPGAUGE", "CIFGauge", 1, "14,37,168,4", "interface\\targetwindow\\tw_hp.ddj")
		+ _name_row("GDR_TWCE_TEXT_ID", 0, "34,10,137,12"))

func _special() -> String:
	return _layout(_control("GDR_TWSM_GEM", "CIFStatic", 10, "8,5,20,20")
		+ _control("GDR_TWSM_LEVEL", "CIFStatic", 4, "10,56,30,16")
		+ _control("GDR_TWSM_ICON", "CIFStatic", 3, "65,54,16,16", "interface\\targetwindow\\tw_icon_champion.ddj")
		+ _control("GDR_TWSM_TEXT_LEV", "CIFStatic", 2, "85,56,168,12")
		+ _control("GDR_TWSM_GAUGE_HPGAUGE", "CIFGauge", 1, "14,37,168,4", "interface\\targetwindow\\tw_hp.ddj")
		+ _name_row("GDR_TWSM_TEXT_ID", 0, "34,10,137,12"))

func _player() -> String:
	return _layout(_control("GDR_TW_KINDRED_MARK", "CIFStatic", 10, "3,0,24,24")
		+ _name_row("GDR_TWP_TEXT_NAME", 1, "42,10,122,12"))

func _job_player() -> String:
	return _layout(_control("GDR_TWJP_KINDRED_MARK", "CIFStatic", 20, "3,0,24,24")
		+ _control("GDR_TWJP_JOB_GRADE", "CIFStatic", 12, "153,36,35,12")
		+ _control("GDR_TWJP_JOB_ALIAS", "CIFStatic", 1, "39,10,127,12"))

func _ifdef_key(path: String, defines: Array) -> String:
	return "%s%s%s" % [path, char(1), char(2).join(PackedStringArray(defines))]

## The rank keys 0x69b4c0 uses, with the English text the archive's
## textuisystem.txt gives each (measured; both of its rows per key agree).
## UIIT_STT_MOB_STRONG reads "Elite" in English (its Korean text means
## "strong").
func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for pair in [["UIIT_CTL_WARENETWORK_DETAIL_NORMAL", "General"], ["UIIT_STT_MOB_CHAMPION", "Champion"],
			["UIIT_STT_MOB_STRONG", "Elite"], ["UIIT_STT_MOB_UNIQUE", "Unique"]]:
		rows.append("1\t%s\t\t\t\t\t\t\t%s" % pair)
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

const ICON_DIR := "interface\\targetwindow\\"

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var cache: Dictionary = builder.get("_layout_cache")
	var both := PackedStringArray(["UI_UPDATE_2009_FIRST", "APPLY_SIEGE_FORTRESS_SYSTEM"])
	var ui := PackedStringArray(["UI_UPDATE_2009_FIRST"])
	cache[_ifdef_key("resinfo\\iftargetwindow.txt", both)] = UiLayoutParser.parse(_container(), true, both)
	cache["resinfo\\iftargetwindowex.txt"] = UiLayoutParser.parse(_container_ex())
	for pair in [["resinfo\\iftw_commonenemy.txt", _common()], ["resinfo\\iftw_specialmob.txt", _special()],
			["resinfo\\iftw_player.txt", _player()], ["resinfo\\iftw_jobplayer_trijob2.txt", _job_player()]]:
		cache[_ifdef_key(pair[0], ui)] = UiLayoutParser.parse(pair[1], true, ui)
		cache[pair[0]] = UiLayoutParser.parse(pair[1])
	var img := Image.create(ATLAS_SIZE.x, ATLAS_SIZE.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.3, 0.3, 0.3, 1.0))
	var textures: Dictionary = builder.get("_texture_cache")
	textures[ATLAS.to_lower()] = ImageTexture.create_from_image(img)
	# One small texture per rank icon, told apart by identity.
	for icon in ["tw_icon_normal", "tw_icon_champion", "tw_icon_unique", "tw_icon_giant",
			"tw_icon_titan", "tw_icon_elite"]:
		var i := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		i.fill(Color(0.8, 0.8, 0.2, 1.0))
		textures[(ICON_DIR + icon + ".ddj").to_lower()] = ImageTexture.create_from_image(i)
	return builder

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the live checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var script := load(TARGET_PATH) as GDScript
	_check(script != null and script.can_instantiate(), "HudTarget compiles")
	if script != null and script.can_instantiate():
		await _checks(script)
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _checks(script: GDScript) -> void:
	var consts := script.get_script_constant_map()
	_check(consts.get("CONTAINER_LAYOUT", "") == "resinfo\\iftargetwindow.txt",
		"the container is iftargetwindow.txt, the layout CIFTargetWindow::Create loads (got %s)" % consts.get("CONTAINER_LAYOUT", ""))
	var target: Control = script.new(_builder())
	root.add_child(target)
	var built: bool = target.call("setup")
	_check(built, "the target window builds from iftargetwindow.txt's fixture")
	if not built:
		target.free()
		return

	# The close button at its authored 176,9 and held there by the settling
	# pass, like every other built control: knock it off its rect while that
	# pass runs (its first frames in the tree) and wait.
	var close := target.find_child("GDR_TW_CLOSE", true, false) as Control
	_check(close != null, "the container's close button is built")
	if close != null:
		close.position = Vector2(0, 0)
		close.size = Vector2(40, 40)
		for i in 5:
			await process_frame
		_check(close.position == Vector2(176, 9) and close.size == Vector2(16, 16),
			"the close button settles back to its authored 176,9,16,16 (got %s)" % Rect2(close.position, close.size))
	# The pieces, built from the 2009 branch.
	var common := target.get_node_or_null("GDR_TW_COMMONENEMY") as Control
	var frame := common.get_node_or_null("Frame") as TextureRect if common != null else null
	var region := (frame.texture as AtlasTexture).region if frame != null and frame.texture is AtlasTexture else Rect2()
	_check(frame != null and frame.size == Vector2(236, 51) and is_equal_approx(region.size.x, 236.0),
		"the common-enemy piece is the 2009 236x51 one, on the atlas's 236-wide region (got %s, region %s)" % [frame.size if frame != null else null, region])
	var name_label := target.find_child("GDR_TWCE_TEXT_ID", true, false) as Control
	var name_rect: Rect2 = name_label.get_meta(UiBuilder.AUTHORED_RECT_META) if name_label != null else Rect2()
	_check(name_rect == Rect2(34, 10, 170, 12),
		"the name row is UI_UPDATE_2009_FIRST's 34,10,170,12 (got %s)" % name_rect)

	# Which window a monster gets, per rarity (0x69a2d0), and its rank rows
	# (0x69b4c0). [rarity, rank icon, rank text]; a Mangyang is rarity 0.
	var textures: Dictionary = (target.get("_builder") as UiBuilder).get("_texture_cache")
	for case in [[0, "tw_icon_normal", "General"], [1, "tw_icon_champion", "Champion"],
			[3, "tw_icon_unique", "Unique"], [7, "tw_icon_normal", "Elite"], [8, "tw_icon_unique", "Unique"]]:
		var rarity: int = case[0]
		target.call("show_target", "Mangyang", 9, rarity, 54, 54)
		var special := target.get_node_or_null("GDR_TW_SPECIALMOBWND") as CanvasItem
		var shown := []
		for kind in ["GDR_TW_COMMONENEMY", "GDR_TW_SPECIALMOBWND", "GDR_TW_PLAYERWND", "GDR_TW_JOB_PLAYERWND"]:
			var k := target.get_node_or_null(kind) as CanvasItem
			if k != null and k.visible:
				shown.append(kind)
		_check(shown == ["GDR_TW_SPECIALMOBWND"] and target.size == Vector2(236, 78) and target.visible,
			"rarity %d: the special-mob window, 236x78 (got %s, %s)" % [rarity, shown, target.size])
		var icon := target.find_child("GDR_TWSM_ICON", true, false) as TextureRect
		var want_icon = textures.get((ICON_DIR + case[1] + ".ddj").to_lower())
		_check(icon != null and icon.visible and icon.texture == want_icon,
			"rarity %d: the rank icon is %s" % [rarity, case[1]])
		var rank := target.find_child("GDR_TWSM_TEXT_LEV", true, false) as Label
		var level := target.find_child("GDR_TWSM_LEVEL", true, false) as Label
		_check(rank != null and rank.text == case[2], "rarity %d: the rank row reads '%s' (got '%s')" % [rarity, case[2], rank.text if rank != null else null])
		_check(level != null and level.text == "Lv 9", "rarity %d: the level row reads 'Lv 9' (got '%s')" % [rarity, level.text if level != null else null])
	for rarity in [2, 9]:
		target.call("show_target", "Nothing", 9, rarity, 54, 54)
		var any := false
		for kind in ["GDR_TW_COMMONENEMY", "GDR_TW_SPECIALMOBWND", "GDR_TW_PLAYERWND", "GDR_TW_JOB_PLAYERWND"]:
			var k := target.get_node_or_null(kind) as CanvasItem
			any = any or (k != null and k.visible)
		var close_shows := (target.find_child("GDR_TW_CLOSE", true, false) as CanvasItem).visible
		_check(target.visible and not any and close_shows and target.size == Vector2.ZERO,
			"rarity %d: no piece, only the close button (pieces shown %s, size %s)" % [rarity, any, target.size])

	# Placement (round 590, read at 0x69a161): the window moves itself to
	# ((screen width - the shown piece's width) >> 1, 7), and this client
	# redoes it when the viewport changes size or UI scale.
	for view in [[Vector2i(1152, 648), 1.0], [Vector2i(1920, 1080), 1.0], [Vector2i(1366, 768), 1.5]]:
		root.size = view[0]
		root.content_scale_factor = view[1]
		await process_frame
		target.call("show_target", "Mangyang", 1, 0, 54, 54)
		var logical_w := target.get_viewport_rect().size.x
		var want := Vector2(floorf((logical_w - 236.0) / 2.0), 7.0)
		_check(target.global_position == want,
			"placed at ((%s - 236) >> 1, 7) = %s in a %s window at UI scale %s (got %s)" % [logical_w, want, view[0], view[1], target.global_position])
	root.size = Vector2i(1600, 900)
	root.content_scale_factor = 1.0
	await process_frame
	await process_frame
	var after_w := target.get_viewport_rect().size.x
	_check(target.global_position == Vector2(floorf((after_w - 236.0) / 2.0), 7.0),
		"a resize to %s re-centres it without a new target (got %s)" % [target.get_viewport_rect().size, target.global_position])

	# The live player kinds are built and hidden, as Create leaves them.
	var player := target.get_node_or_null("GDR_TW_PLAYERWND") as CanvasItem
	var job := target.get_node_or_null("GDR_TW_JOB_PLAYERWND") as CanvasItem
	_check(player != null and not player.visible and target.find_child("GDR_TWP_TEXT_NAME", true, false) != null,
		"GDR_TW_PLAYERWND is built from iftw_player.txt and hidden")
	_check(job != null and not job.visible and target.find_child("GDR_TWJP_JOB_ALIAS", true, false) != null,
		"GDR_TW_JOB_PLAYERWND is built from iftw_jobplayer_trijob2.txt and hidden")
	_check(target.find_child("GDR_TW_FORTRESSSTRUCTER", true, false) == null
		or not (target.find_child("GDR_TW_FORTRESSSTRUCTER", true, false) as CanvasItem).is_visible_in_tree(),
		"no fortress piece shows")

	target.free()
