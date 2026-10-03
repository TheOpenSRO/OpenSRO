extends SceneTree

## Round 703: the notice banners and the area banner against what was read
## out of CIFNotify / CIFStretchWnd and CIFRegionView
## (docs/protocol/notice_banner.md). No archive is read: the region codes and
## zone texts are SYNTHETIC rows in the files' shapes.
##
## Everything is reached by path and call(), so against a client without
## round 703 this reports FAIL lines instead of failing to compile.

const NOTICE_PATH := "res://scripts/ui/hud/hud_notice.gd"
const REGION_PATH := "res://scripts/ui/hud/hud_region_view.gd"
const WORLD_PATH := "res://scripts/World3D.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _load(path: String) -> Script:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Script

func _has(script: Script, method: String) -> bool:
	for d in script.get_script_method_list():
		if d["name"] == method:
			return true
	return false

func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the checks never reported (a script error stopped them)")
		quit(1))
	await process_frame
	var notice := _load(NOTICE_PATH)
	_check(notice != null, "hud_notice.gd exists")
	if notice != null:
		_kind_checks(notice)
		_frame_checks(notice)
		await _show_checks(notice)
	var region := _load(REGION_PATH)
	_check(region != null, "the area banner exists (hud_region_view.gd)")
	if region != null:
		_region_code_checks(region)
		await _region_rule_checks(region)
		_region_timing_checks(region)
		_region_layout_checks(region)
	_world_checks()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- Kind -> style (the callers of 0x777bf0 and 0x77b580) ---------------------

func _kind_checks(s: Script) -> void:
	if not _has(s, "style_for_kind"):
		_check(false, "HudNotice.style_for_kind maps a line's kind to its instance")
		return
	var consts := s.get_script_constant_map()
	var note: Dictionary = consts["STYLE_NOTICE"]
	var warn: Dictionary = consts["STYLE_WARNING"]
	for k in ["gm_notice", "guild_created", "arena"]:
		_check(s.call("style_for_kind", k) == note, "%s goes to GDR_NOTICE (0x777bf0's callers)" % k)
	for k in ["level_up", "unique", "recall_point", "system", "anything else"]:
		_check(s.call("style_for_kind", k) == warn, "%s goes to GDR_WARNING_WND (0x77b580)" % k)
	_check((note["fill"] as Color).to_html(false) == "802d43" and note["y"] == 100
		and String(note["corner"]).ends_with("com_notice_corner.ddj"),
		"GDR_NOTICE is the pink-red (128, 45, 67) banner at y 100 with com_notice_*")
	_check((warn["fill"] as Color).to_html(false) == "00345c" and warn["y"] == 130
		and String(warn["edge2"]).ends_with("com_warning_edge2.ddj"),
		"GDR_WARNING_WND is the blue (0, 52, 92) banner at y 130 with com_warning_*")
	_check(consts.get("TEXT_BOLD") == true and consts.get("TEXT_SHADOW") == false,
		"the notice text is bold (flag 2) with no shadow (flag 1 unset)")

# --- The stretch frame (0x8182e0, 0x818a50(0), 0x818d30(0)) -------------------

func _frame_checks(s: Script) -> void:
	if not _has(s, "frame_pieces"):
		_check(false, "HudNotice.frame_pieces lays the stretch frame out")
		return
	var w := 200.0
	var h := 14.0
	var p: Array = s.call("frame_pieces", w, h)
	_check(p.size() == 8, "eight quads: four corners, four edges")
	if p.size() != 8:
		return
	var want := [
		["corner", Rect2(-40, -8, 40, 8), false, false],
		["corner", Rect2(200, -8, 40, 8), true, false],
		["corner", Rect2(200, 14, 40, 8), true, true],
		["corner", Rect2(-40, 14, 40, 8), false, true],
		["edge2", Rect2(-40, 0, 40, 14), false, false],
		["edge", Rect2(0, -8, 200, 8), false, false],
		["edge2", Rect2(200, 0, 40, 14), true, false],
		["edge", Rect2(0, 14, 200, 8), false, true],
	]
	var names := ["TL corner", "TR corner", "BR corner", "BL corner", "left edge2", "top edge", "right edge2", "bottom edge"]
	for i in 8:
		var got: Dictionary = p[i]
		_check(got["piece"] == want[i][0] and got["rect"] == want[i][1] and got["flip_h"] == want[i][2]
			and got["flip_v"] == want[i][3], "%s: %s %s mirrored %s/%s (got %s)" % [names[i], want[i][0], want[i][1],
				want[i][2], want[i][3], got])
	var window := Rect2(0, 0, w, h)
	var outside := true
	for q in p:
		if (q["rect"] as Rect2).intersects(window):
			outside = false
	_check(outside, "no piece overlaps the window's rect: the frame lies outside it")
	var n: Control = s.new()
	root.add_child(n)
	n.call("setup", null)
	n.call("show_notice", "You have advanced to level [101].")
	var band: Rect2 = n.call("band_rect")
	_check(band == Rect2(-40, -8, n.size.x + 80, n.size.y + 16),
		"the band is the text's rect plus 40 px each side and 8 px above and below (got %s for %s)" % [band, n.size])
	n.free()

# --- Showing and fading (0x7b3eb0, 0x7b3e20) ---------------------------------

func _show_checks(s: Script) -> void:
	_check(s.call("window_x", 1024, 301) == 512 - 150 and s.call("window_x", 1023, 300) == 511 - 150,
		"x = W/2 - w/2 with two truncating halvings")
	_check(s.call("fill_alpha_for", 255) == 128 and s.call("fill_alpha_for", 0) == 1, "fill alpha 128 at full, 1 at none")
	var n: Control = s.new()
	root.add_child(n)
	n.call("setup", null)
	n.call("show_notice", "Server maintenance")
	await process_frame
	var face: Font = n.call("text_font")
	var plain := face.get_string_size("Server maintenance", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var adv := 0.0
	for ch in "Server maintenance":
		adv += face.get_char_size(ch.unicode_at(0), 12).x
	var want_w := ceilf(adv + "Server maintenance".length()) if n.call("text_bold_file") == null \
		else ceilf((n.call("text_bold_file") as Font).get_string_size("Server maintenance", HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
	_check(n.size.x == want_w and n.size.x > plain,
		"the window is the bold text's extent: each glyph's advance plus 1 px without a bold file (got %s, want %s)" % [n.size, want_w])
	_check(s.call("bold_width", face, null, "ab", 12) == face.get_char_size(97, 12).x + face.get_char_size(98, 12).x + 2.0,
		"the synthetic bold widens every advance by one pixel (GDI's simulation)")
	var first_x := n.position.x
	n.call("advance", 3000)
	n.call("show_notice", "A longer second line replaces the first")
	_check(n.call("remaining_ms") == 7000 and n.call("alpha") == 255 and n.call("text") == "A longer second line replaces the first"
		and n.position.x < first_x, "a second show replaces the first at once: no queue")
	n.call("advance", 5000)
	_check(n.call("alpha") == 2000 * 255 / 2000, "full until 2000 ms are left")
	n.call("advance", 1000)
	_check(n.call("alpha") == 1000 * 255 / 2000, "then remaining * 255 / 2000")
	n.call("advance", 1000)
	_check(not n.visible, "and gone at 7000 ms")
	_check(n.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "the frame is point-sampled (0x819d80)")
	n.free()

# --- The area banner ----------------------------------------------------------

## regioncode.txt's shape: ANSI, tab-separated, a Korean note (CP949 bytes)
## in the fourth column.
func _region_codes_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	var rows := [
		"//Service\tRegion ID\tCode Name\t",
		"1\t25000\tRN_TEST_TOWN\t",
		"1\t25001\tRN_TEST_TOWN\t",
		"1\t25002\tRN_TEST_FIELD\t",
		"1\t25003\txxx\txxx",
		"0\t25004\tRN_TEST_OFF\t",
		"1\t25000\tRN_TEST_DUP\t",
		"1\t\tRN_TEST_NOID\t",
	]
	for r in rows:
		b.append_array(String(r).to_ascii_buffer())
		if r.ends_with("\t"):
			b.append_array(PackedByteArray([0xC0, 0xE5, 0xBE, 0xC8]))
		b.append_array(PackedByteArray([13, 10]))
	return b

func _zone_texts() -> UiTextTable:
	var rows := [
		"1\tRN_TEST_TOWN_01\tk\t0\t0\t0\t0\t0\tTest Town\tTest Town",
		"1\tRN_TEST_TOWN_02\tk\t0\t0\t0\t0\t0\tA town of tests\tA town of tests",
		"1\tRN_TEST_TOWN_03\txxx\t0\t0\t0\t0\t0\txxx\txxx",
		"1\tRN_TEST_FIELD_01\tk\t0\t0\t0\t0\t0\tTest Field\tTest Field",
		"1\tRN_TEST_FIELD_02\txxx\t0\t0\t0\t0\t0\txxx\txxx",
		"1\tRN_TEST_FIELD_03\tk\t0\t0\t0\t0\t0\tLv 10 ~ 20\tLv 10 ~ 20",
	]
	var text := "\r\n".join(PackedStringArray(rows)) + "\r\n"
	var data := PackedByteArray([0xFF, 0xFE])
	data.append_array(text.to_utf16_buffer())
	return UiTextTable.parse(data)

func _region_code_checks(s: Script) -> void:
	var codes: Dictionary = s.call("parse_region_codes", _region_codes_bytes())
	_check(codes.get(25000) == "RN_TEST_TOWN" and codes.get(25001) == "RN_TEST_TOWN" and codes.get(25002) == "RN_TEST_FIELD",
		"regioncode.txt rows map region id -> code (got %s)" % [codes])
	_check(not codes.has(25003), "an \"xxx\" code is not kept (0x844310)")
	_check(not codes.has(25004), "a service-0 row is not kept")
	_check(codes.get(25000) == "RN_TEST_TOWN", "the first row of an id wins (a map insert)")
	_check(codes.size() == 3, "no row without a region id (got %d codes)" % codes.size())

func _region_view(s: Script) -> Control:
	var v: Control = s.new()
	root.add_child(v)
	v.call("setup", null)
	v.call("set_tables", s.call("parse_region_codes", _region_codes_bytes()), _zone_texts())
	return v

func _region_rule_checks(s: Script) -> void:
	var v := _region_view(s)
	_check(v.call("enter_region", 25000) and v.get("current_code") == "RN_TEST_TOWN",
		"walking into a named region raises its banner")
	_check(v.get("title") == "Test Town" and v.get("line2") == "A town of tests" and v.get("line3") == "",
		"title _01, line _02, and _03 blanked when it is \"xxx\" (got '%s' '%s' '%s')" % [v.get("title"), v.get("line2"), v.get("line3")])
	_check(not v.call("enter_region", 25001), "another region with the same code shows nothing")
	_check(not v.call("enter_region", 25000), "nor does the same region again")
	_check(v.call("enter_region", 25002) and v.get("title") == "Test Field" and v.get("line2") == "" and v.get("line3") == "Lv 10 ~ 20",
		"a different code raises its own banner, an \"xxx\" description blank")
	_check(not v.call("enter_region", 25003) and v.get("current_code") == "",
		"an unnamed region shows nothing and forgets the code")
	_check(v.call("enter_region", 25002), "so walking back in raises the banner again")
	_check(not v.call("enter_region", 0), "region 0 is never tested")
	v.free()

func _region_timing_checks(s: Script) -> void:
	_check(s.call("fade_alpha", 0, 255, 0, 500) == 0 and s.call("fade_alpha", 0, 255, 250, 500) == 127
		and s.call("fade_alpha", 0, 255, 500, 500) == 255 and s.call("fade_alpha", 255, 0, 100, 500) == 204,
		"the fade is linear over 0.5 s, truncated to a byte (0x6552f0)")
	var v := _region_view(s)
	v.call("enter_region", 25000)
	_check(v.visible and v.call("alpha") == 0, "the banner starts at alpha 0")
	v.call("advance", 250)
	_check(v.call("alpha") == 127, "fades in over 500 ms (127 at 250)")
	v.call("advance", 250)
	_check(v.call("alpha") == 255, "and is full at 500")
	v.call("advance", 2500)
	_check(v.call("alpha") == 255 and v.visible, "held to 3000 ms after the texts were set")
	v.call("advance", 1)
	_check(v.call("alpha") == 255, "the fade out starts once more than 3000 ms have passed")
	v.call("advance", 250)
	_check(v.call("alpha") == 127, "and runs 500 ms")
	v.call("advance", 250)
	_check(not v.visible and v.call("alpha") == 0, "then the window is hidden")
	# Under the loading screen (OURS, round 703's review M2): held, then the
	# whole banner from the frame the screen lifts.
	var up := [true]
	v.set("covered", func() -> bool: return up[0])
	v.call("enter_region", 25002)
	_check(v.call("held") and not v.visible and v.get("title") == "Test Field",
		"a banner raised under the loading screen is held with its texts")
	v.call("_process", 5.0)
	_check(v.call("held") and not v.visible, "and stays held while the screen is up, its clock stopped")
	up[0] = false
	v.call("_process", 0.016)
	_check(not v.call("held") and v.visible and v.call("alpha") == 0, "the frame the screen lifts it starts at alpha 0")
	v.call("advance", 500)
	_check(v.call("alpha") == 255, "and fades in from there")
	v.free()

func _region_layout_checks(s: Script) -> void:
	var v := _region_view(s)
	v.size = Vector2(1024, 768)
	_check(v.call("window_rect") == Rect2(512 - 372, 95, 744, 104), "the window is 744 x 104 at (W/2 - 372, 95)")
	_check(s.call("title_origin", 512, Vector2(101, 21)) == Vector2(512 - 75, 119 - 7),
		"the title starts at W/2 - trunc(w * 1.5 / 2), 119 - trunc(h * 1.5 / 4)")
	var lay: Dictionary = v.call("layout")
	_check(lay["line2"] == Rect2(512 - 343, 156, 691, 13) and lay["line3"] == Rect2(512 - 214, 177, 427, 11),
		"the two lines' statics at (W/2 - 343, 156) and (W/2 - 214, 177)")
	var c := s.get_script_constant_map()
	_check((c["TITLE_COLOR"] as Color).to_html(false) == "3dfdff" and c["TITLE_SCALE"] == 1.5 and c["TITLE_FONT_INDEX"] == 4,
		"the title is ifregionview.txt's cyan (61, 253, 255), FontIndex 4, at scale 1.5")
	_check((c["LINE3_COLOR"] as Color).to_html(false) == "ffff5c" and c["LINE2_FONT_INDEX"] == 3 and c["LINE3_FONT_INDEX"] == 1,
		"line 2 white at FontIndex 3, line 3 (255, 255, 92) at FontIndex 1")
	_check(String(c["ART_DDJ"]) == "interface\\game\\area_deco.ddj", "the art is ginterface.txt's area_deco.ddj")
	v.free()

func _world_checks() -> void:
	var src := FileAccess.get_file_as_string(WORLD_PATH)
	var at := src.find("func _update_zone_label_for_region(")
	var body := src.substr(at, 600) if at >= 0 else ""
	_check(body.contains("_hud_region.enter_region(TextZoneNameReader.region_id(region_x, region_y))"),
		"every region the player enters runs the area banner's test")
	_check(src.contains("_hud_region.setup(_ui_builder)"), "World3D builds the area banner")
	_check(src.contains("_hud_region.covered = func() -> bool: return _loading_screen != null"),
		"and holds it while the loading screen is up")
	var routed := true
	for k in ["gm_notice", "recall_point", "unique", "level_up"]:
		if not src.contains("_show_banner(\"%s\"" % k):
			routed = false
	_check(routed and src.contains("HudNotice.style_for_kind(kind)"),
		"every banner World3D raises goes through style_for_kind (the GM notice, recall point, unique, level-up)")
	_check(src.count(".show_notice(") == 1, "and nothing raises one around it")
