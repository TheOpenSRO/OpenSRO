extends SceneTree

## The Option window's Video tab (round 694): VideoOptions (the original's
## presets, ladders and curve as READ; this client's defaults; the saved
## file) and OptionVideoPage on a synthetic optionwnd.2dt whose pane-78
## records carry the real file's ids, types, parents and rects (MEASURED; no
## art, no text, no game data). Also the two places the options reach that
## run headless: MapAnimation's object range and SkillEffects' effect gate.
##
## NEGATIVE: before round 694 VideoOptions, OptionVideoPage,
## MapAnimation.object_range and SkillEffects.wants_effect do not exist --
## this suite does not parse.
##
## `godot4 --headless --path client --script res://scripts/setting/video_options_test.gd`

const READER_PATH := "res://scripts/ui/twodt_reader.gd"

var _failures := 0
var _dir := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_dir = OS.get_user_data_dir().path_join("video_options_test_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_dir)
	_presets()
	_rows()
	_ladders()
	_storage()
	_map_range()
	_effects()
	_post_effects()
	await _page()
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(f))
	DirAccess.remove_absolute(_dir)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)

# --- the data ------------------------------------------------------------------

func _presets() -> void:
	var P := VideoOptions.PRESETS
	# READ, 0x5015a0, one row per quality.
	_check(P[VideoOptions.QUALITY_LOW] == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0], "Low: every row off or lowest, Effect Quality 'See Hit Effects' (1)")
	_check(P[VideoOptions.QUALITY_MIDDLE] == [0, 1, 2, 2, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0], "Middle: Circle shadows, sight 3/3, reflection OFF, bloom/lens/filter/metal ON")
	_check(P[VideoOptions.QUALITY_HIGH] == [0, 2, 4, 4, 1, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0], "High: Detail shadows, sight 5/5, reflection on, water and texture High")
	_check(P[VideoOptions.QUALITY_WAR] == [0, 0, 2, 4, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0], "Large scale battle: no shadow, background 3, characters 5, texture Middle")
	var p := VideoOptions.Profile.new()
	_check(p.quality == VideoOptions.QUALITY_USER and p.brightness == 2, "a new record is User control, Normal brightness (OURS default; brightness READ)")
	for e in VideoOptions.DEFAULTS:
		_check(p.value(e) == int(VideoOptions.DEFAULTS[e]), "default row %s = %d" % [VideoOptions.row_of(e)["key"], VideoOptions.DEFAULTS[e]])
	_check(p.value(VideoOptions.SHADOW) == 2 and p.value(VideoOptions.WATER_REFLECTION) == 1 and p.value(VideoOptions.TEXTURE) == 2 \
		and p.value(VideoOptions.FILTERING) == 0 and p.value(VideoOptions.BLOOM) == 0 and p.value(VideoOptions.SSAO) == 0,
		"the defaults draw what the client drew before: sun shadow + blob, reflection, full textures, no MSAA, no glow, no SSAO")
	VideoOptions.set_row(p, VideoOptions.QUALITY, VideoOptions.QUALITY_MIDDLE)
	_check(p.value(VideoOptions.BLOOM) == 1 and p.value(VideoOptions.WATER_REFLECTION) == 0 and p.value(VideoOptions.SHADOW) == 1,
		"choosing Middle fills the rows from its preset (bloom on, reflection off, Circle)")
	_check(p.user[VideoOptions.SHADOW] == 2, "the player's own values stay behind a preset (retail's second copy)")
	VideoOptions.set_row(p, VideoOptions.WATER_REFLECTION, 1)
	_check(p.quality == VideoOptions.QUALITY_USER, "setting a row under a preset switches the record to User control")
	_check(p.value(VideoOptions.WATER_REFLECTION) == 1 and p.value(VideoOptions.BLOOM) == 1 and p.value(VideoOptions.SHADOW) == 1,
		"... keeping every other row as the preset had it (bloom 1, Circle 1), the one row changed")
	VideoOptions.set_row(p, VideoOptions.SSAO, 1)
	VideoOptions.set_row(p, VideoOptions.QUALITY, VideoOptions.QUALITY_LOW)
	_check(p.value(VideoOptions.SSAO) == 1 and p.quality == VideoOptions.QUALITY_LOW, "SSAO (OURS) is the player's under every preset and does not switch to User")
	VideoOptions.set_row(p, VideoOptions.SHADOW, 9)
	_check(p.value(VideoOptions.SHADOW) == 2, "a value past the choices is clamped (Shadow 9 -> 2)")

func _rows() -> void:
	var entries: Array = []
	for r in VideoOptions.ROWS:
		entries.append(int(r["entry"]))
	_check(entries == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17], "the list: retail's rows 0..13 and 15 (READ, 14 never listed), then SSAO and the renderer (OURS)")
	_check(VideoOptions.choice_count(VideoOptions.QUALITY) == 5 and VideoOptions.choice_count(VideoOptions.SHADOW) == 3
		and VideoOptions.choice_count(VideoOptions.SCENERY) == 5 and VideoOptions.choice_count(VideoOptions.EFFECT) == 3
		and VideoOptions.choice_count(VideoOptions.FRIEND_ENEMY) == 2, "the choice counts READ in 0x5fef70 (5, 3, 5, 3, 2)")
	_check(VideoOptions.row_of(VideoOptions.BLOOM)["label"] == "UIIT_STT_BLOOM_EFFECT" and VideoOptions.row_of(VideoOptions.BLOOM)["tip"] == "UIIT_STT_VIDIO_TTDESC_13",
		"Bloom's label and tooltip keys (READ)")
	_check(VideoOptions.row_of(VideoOptions.FILTERING)["tip"] == "UIIT_STT_VIDIO_TTDESC_15" and VideoOptions.row_of(VideoOptions.EFFECT)["tip"] == "UIIT_STT_VIDIO_TTDESC_16",
		"the tooltip keys follow 0x5fef70's pushes, not their number order (Filtering 15, Effect 16)")

func _ladders() -> void:
	var views: Array = []
	for i in 5:
		views.append(VideoOptions.view_distance(i))
	_check(views == [1200.0, 2000.0, 2500.0, 2500.0, 2500.0], "view distance = min(0.8 x far, 2500): 1200/2000/2500/2500/2500 (got %s)" % [views])
	_check(VideoOptions.far_plane(0) == 1500.0 and VideoOptions.far_plane(4) == 5500.0, "far planes 1500..5500 (READ)")
	_check(is_equal_approx(VideoOptions.brightness_curve(2, 0.5), 0.5), "Normal brightness is the identity")
	_check(is_equal_approx(VideoOptions.brightness_curve(0, 1.0), pow(0.8, 1.4)), "Very Dark: white -> 0.8^1.4 (%.4f)" % VideoOptions.brightness_curve(0, 1.0))
	_check(is_equal_approx(VideoOptions.brightness_curve(4, 0.5), pow(0.7, 0.6)) and VideoOptions.brightness_curve(4, 1.0) == 1.0,
		"Very bright: 0.5 -> 0.7^0.6, white clamps at 1")
	_check(VideoOptions.water_rows(1) == 512 and VideoOptions.mip_bias(2) == 0.0 and VideoOptions.mip_bias(0) == 2.0,
		"Water Detail Middle keeps the 512-row target; Texture Detail High is no bias, Low drops 2 levels (READ SetLOD(2 - v))")
	_check(VideoOptions.character_range(2) == 0.0 and VideoOptions.character_range(0) == 600.0, "Character Sight 3 draws as before (no limit); 1 is 600 (OURS)")
	var choices := VideoOptions.resolution_choices(Vector2i(1920, 1080), Vector2i(1234, 777))
	_check(choices.has(Vector2i(1920, 1080)) and not choices.has(Vector2i(2560, 1440)) and choices.has(Vector2i(1234, 777))
		and choices[0] == Vector2i(800, 600), "resolutions: no larger than the screen, from 800 x 600, the current size added")
	_check(VideoOptions.parse_resolution("1280x720") == Vector2i(1280, 720) and VideoOptions.parse_resolution("junk") == Vector2i.ZERO
		and VideoOptions.format_resolution(Vector2i(1024, 768)) == "1024x768", "resolution text round trip")

func _storage() -> void:
	var path := _dir.path_join("settings.cfg")
	var legacy := ConfigFile.new()
	legacy.set_value("world", "water_reflection", false)
	legacy.set_value("ui", "scale", 1.5)
	legacy.save(path)
	var o := VideoOptions.load_saved(path)
	_check(o.value(VideoOptions.WATER_REFLECTION) == 0 and o.profiles[1].value(VideoOptions.WATER_REFLECTION) == 0,
		"the round-628 key [world] water_reflection=false seeds both records' Water Reflection")
	o.active = 1
	o.fullscreen = true
	o.resolution = Vector2i(1600, 900)
	VideoOptions.set_row(o.profiles[1], VideoOptions.QUALITY, VideoOptions.QUALITY_HIGH)
	o.profiles[1].brightness = 3
	VideoOptions.set_row(o.profiles[0], VideoOptions.SCENERY, 0)
	_check(o.save(path), "save writes the file")
	var cfg := ConfigFile.new()
	cfg.load(path)
	_check(int(cfg.get_value("video", "profile", 0)) == 2 and cfg.get_value("video", "resolution", "") == "1600x900"
		and bool(cfg.get_value("video", "fullscreen", false)), "[video] profile=2 fullscreen=true resolution=\"1600x900\"")
	_check(int(cfg.get_value("video_graphic2", "quality", -1)) == 2 and int(cfg.get_value("video_graphic2", "brightness", -1)) == 3
		and int(cfg.get_value("video_graphic1", "background_sight_range", -1)) == 0, "the records under [video_graphic1] / [video_graphic2], rows by name")
	_check(is_equal_approx(float(cfg.get_value("ui", "scale", 0.0)), 1.5), "the file's other keys are kept")
	_check(bool(cfg.get_value("world", "water_reflection", false)) == true, "the old key follows the record in force (High: reflection on)")
	var back := VideoOptions.load_saved(path)
	_check(back.active == 1 and back.fullscreen and back.resolution == Vector2i(1600, 900)
		and back.current().quality == VideoOptions.QUALITY_HIGH and back.current().brightness == 3
		and back.profiles[0].value(VideoOptions.SCENERY) == 0, "load_saved reads back what save wrote")
	var none := VideoOptions.load_saved(_dir.path_join("missing.cfg"))
	_check(none.active == 0 and not none.fullscreen and none.current().quality == VideoOptions.QUALITY_USER, "no file: Graphic 1, a window, the defaults")

func _map_range() -> void:
	MapAnimation.set_view_distance(VideoOptions.view_distance(0))
	_check(is_equal_approx(MapAnimation.object_range, 720.0), "Background Sight 1: map objects animate within 1200 - 480 = 720 (READ rule)")
	_check(not MapAnimation.in_range(Vector3(800, 0, 0), 0.0, Vector3.ZERO) and MapAnimation.in_range(Vector3(700, 0, 0), 0.0, Vector3.ZERO),
		"in_range follows the range in force")
	MapAnimation.set_view_distance(VideoOptions.view_distance(2))
	_check(is_equal_approx(MapAnimation.object_range, MapAnimation.OBJECT_RANGE), "Background Sight 3: back to 2020, the range before round 694")

func _effects() -> void:
	var me := Node3D.new()
	var other := Node3D.new()
	var third := Node3D.new()
	var was: Node3D = SkillEffects.own_body
	SkillEffects.own_body = me
	SkillEffects.quality = SkillEffects.EFFECTS_ALL
	_check(SkillEffects.wants_effect(other, third, third), "See All Effects: a stranger's effect on a stranger is drawn")
	SkillEffects.quality = SkillEffects.EFFECTS_HITS
	_check(not SkillEffects.wants_effect(other, third, third) and SkillEffects.wants_effect(other, me, me) and SkillEffects.wants_effect(me, third, third),
		"See Hit Effects: only effects the player casts, takes or carries (INFERRED)")
	SkillEffects.quality = SkillEffects.EFFECTS_NONE
	_check(not SkillEffects.wants_effect(me, me, me), "Turn Off All Effects: none, the player's own included (READ, FUN_00a50dc0 returns 0)")
	SkillEffects.quality = SkillEffects.EFFECTS_ALL
	SkillEffects.own_body = was
	me.free()
	other.free()
	third.free()

func _post_effects() -> void:
	var env := Environment.new()
	VideoOptions.apply_post_effects(env, true, false)
	_check(env.ssao_enabled and not env.glow_enabled, "apply_post_effects: SSAO on, glow off")
	VideoOptions.apply_post_effects(env, false, true)
	_check(not env.ssao_enabled and env.glow_enabled, "apply_post_effects: SSAO off, glow (Bloom) on")
	_check(not VideoOptions.post_effects_available(), "headless (no RenderingDevice): SSAO and glow are reported unavailable, as under Compatibility")

# --- the page -------------------------------------------------------------------

func _rec(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(976)
	for pair in [[0x000, "name"], [0x040, "base"], [0x140, "tex"], [0x240, "textid"]]:
		var bytes: PackedByteArray = str(f.get(pair[1], "")).to_ascii_buffer()
		for i in bytes.size():
			b[pair[0] + i] = bytes[i]
	b.encode_u32(0x340, f.get("type", 5))
	b.encode_u32(0x344, f.get("id", 0))
	b.encode_u32(0x348, f.get("parent", 0))
	b.encode_u32(0x34c, f.get("gp", 0))
	b.encode_u32(0x358, 0xffffffff)
	var r: Rect2i = f.get("rect", Rect2i())
	b.encode_s32(0x35c, r.position.x)
	b.encode_s32(0x360, r.position.y)
	b.encode_s32(0x364, r.size.x)
	b.encode_s32(0x368, r.size.y)
	b.encode_u32(0x38c, f.get("group", 0))
	b.encode_u32(0x390, f.get("pane", 0xffffffff))
	b.encode_u32(0x394, 1 if f.get("root", false) else 0)
	return b

## optionwnd.2dt's window, buttons, top tabs and video pane (MEASURED ids,
## types, parents and rects; textures and texts left out).
func _optionwnd() -> PackedByteArray:
	var recs := [{"type": 0, "id": 98, "name": "CNIFOption", "root": true, "rect": Rect2i(49, 60, 700, 500)}]
	for b in [[5, 143], [6, 275], [8, 406], [9, 537]]:
		recs.append({"type": 4, "id": b[0], "parent": 98, "rect": Rect2i(b[1], 521, 112, 24)})
	for t in [[10, 79, 78], [14, 204, 269], [15, 329, 109], [16, 454, 149]]:
		recs.append({"type": 16, "id": t[0], "parent": 98, "rect": Rect2i(t[1], 105, 120, 24), "group": 10, "pane": t[2]})
	recs.append({"type": 18, "id": 269, "parent": 98, "rect": Rect2i(63, 132, 669, 264)})
	recs.append({"type": 18, "id": 78, "parent": 98, "rect": Rect2i(62, 226, 662, 287)})
	recs.append({"type": 1, "id": 21, "parent": 78, "gp": 98, "rect": Rect2i(60, 292, 665, 212)})
	recs.append({"type": 5, "id": 14, "parent": 78, "gp": 98, "rect": Rect2i(60, 151, 333, 32)})
	recs.append({"type": 12, "id": 15, "parent": 14, "gp": 78, "rect": Rect2i(230, 158, 156, 18)})
	recs.append({"type": 16, "id": 24, "parent": 78, "gp": 98, "rect": Rect2i(59, 265, 232, 28), "group": 11, "pane": 77})
	recs.append({"type": 16, "id": 25, "parent": 78, "gp": 98, "rect": Rect2i(296, 265, 232, 28), "group": 11, "pane": 0})
	recs.append({"type": 5, "id": 462, "parent": 78, "gp": 98, "rect": Rect2i(393, 151, 333, 32)})
	recs.append({"type": 12, "id": 15, "parent": 462, "gp": 78, "rect": Rect2i(563, 158, 156, 18)})
	recs.append({"type": 13, "id": 465, "parent": 78, "gp": 98, "rect": Rect2i(704, 317, 16, 143)})
	var slot_ids := [215, 218, 221, 224, 227, 230, 233, 236, 239, 242, 245, 248]
	for i in slot_ids.size():
		var x: int = 69 if i % 2 == 0 else 388
		var y: int = 304 + (i / 2) * 32
		recs.append({"type": 8, "id": slot_ids[i], "parent": 78, "gp": 98, "name": "CNIFVideoOptionSlot", "rect": Rect2i(x, y, 312, 28)})
		recs.append({"type": 5, "id": 216, "parent": slot_ids[i], "gp": 78, "rect": Rect2i(x + 9, y + 6, 141, 18)})
		recs.append({"type": 12, "id": 217, "parent": slot_ids[i], "gp": 78, "rect": Rect2i(x + 159, y + 4, 150, 20)})
	for c in [[203, 223, 192], [204, 387, 192], [207, 223, 229], [208, 387, 229], [209, 542, 229]]:
		recs.append({"type": 11, "id": c[0], "parent": 78, "gp": 98, "rect": Rect2i(c[1], c[2], 16, 16)})
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, recs.size())
	for r in recs:
		out.append_array(_rec(r))
	return out

func _frames(n: int = 2) -> void:
	for i in n:
		await process_frame

func _click(at: Vector2) -> void:
	for pressed in [true, false]:
		var motion := InputEventMouseMotion.new()
		motion.position = at
		motion.global_position = at
		root.push_input(motion)
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		root.push_input(ev)

func _page() -> void:
	root.size = Vector2i(1152, 648)
	await _frames()
	var builder := UiBuilder.new(null, null)
	var twodt = builder.get("_twodt_cache")
	var Reader = load(READER_PATH)
	_check(twodt is Dictionary and Reader != null, "the builder's .2dt cache can be fed a synthetic file")
	if not (twodt is Dictionary) or Reader == null:
		return
	twodt["res_ui\\optionwnd.2dt"] = Reader.parse(_optionwnd())
	# The window reads the record in force; give it a known one.
	var saved_force := VideoOptions.in_force().duplicate_options()
	VideoOptions.set_in_force(VideoOptions.new())
	var win := OptionWindow.new(builder)
	root.add_child(win)
	_check(win.build_option(), "the Option window builds with its Video pane")
	await _frames(2)
	var page := win.video
	_check(page != null and page.slot_count() == 12, "twelve CNIFVideoOptionSlot rows found (got %d)" % (page.slot_count() if page != null else -1))
	if page == null or page.slot_count() < 12:
		win.queue_free()
		VideoOptions.set_in_force(saved_force)
		return
	_check(page.slot_label(0).text == "Graphic Quality" and page.slot_label(1).text == "Shadow Detail", "slot 0/1 labelled Graphic Quality / Shadow Detail (fallback text, no archive)")
	_check(page.slot_combo(0).item_count == 5 and page.slot_combo(0).get_item_text(4) == "User control" and page.slot_combo(0).selected == 4,
		"the quality combo lists five choices and shows User control (the default)")
	_check(page.max_line() == 3, "17 rows, two a line, six lines shown: three more lines to scroll (got %d)" % page.max_line())
	# Middle through the combo's own signal (a real popup choice emits it).
	page.slot_combo(0).item_selected.emit(1)
	await _frames()
	_check(page.edit.current().quality == VideoOptions.QUALITY_MIDDLE and page.slot_combo(1).selected == 1,
		"choosing Middle shows Circle in Shadow Detail (READ preset)")
	_check(VideoOptions.in_force().current().quality == VideoOptions.QUALITY_USER, "nothing is in force before Apply")
	# Bloom is row 11: line 5 -- the third line shown once scrolled 3 lines.
	page.scroll_to(3)
	await _frames()
	_check(page.entry_at_slot(0) == VideoOptions.METAL and page.entry_at_slot(4) == VideoOptions.LENS_FLARE
		and page.entry_at_slot(5) == VideoOptions.BLOOM and page.entry_at_slot(10) == VideoOptions.RENDERER and page.entry_at_slot(11) == -1,
		"scrolled 3 lines: Metallic Sheen first, Lens Flare / Bloom on the third line, the renderer last, its neighbour empty")
	var bloom := page.combo_of(VideoOptions.BLOOM)
	var ssao := page.combo_of(VideoOptions.SSAO)
	_check(bloom != null and bloom.disabled and ssao != null and ssao.disabled, "Bloom (Glow) and SSAO are greyed without Forward+")
	var filt := page.combo_of(VideoOptions.FILTERING)
	var texd := page.combo_of(VideoOptions.TEXTURE)
	_check(filt != null and filt.disabled and texd != null and texd.disabled, "so are Texture Filtering and Texture Detail (MSAA and the mip bias draw nothing under Compatibility, MEASURED)")
	_check(not page.combo_of(VideoOptions.LENS_FLARE).disabled, "Lens Flare is not greyed")
	_check(ssao != null and ssao.tooltip_text.contains("Forward+"), "... with a tooltip naming Forward+")
	_check(page.slot_label(page.slot_of(VideoOptions.BLOOM)).text.ends_with("(Glow)"), "Bloom's row says it is the glow")
	var renderer := page.combo_of(VideoOptions.RENDERER)
	_check(renderer != null and renderer.item_count == 2 and renderer.get_item_text(0) == "Forward+", "the renderer row lists Forward+ / Compatibility")
	# Graphic 2: its own record.
	var tab2: BaseButton = win.control([78, 25])
	_click(tab2.get_global_rect().get_center())
	await _frames()
	_check(page.edit.active == 1 and page.edit.current().quality == VideoOptions.QUALITY_USER, "the Graphic 2 tab shows the second record (still User)")
	page.select_profile(0)
	# The view and window rows.
	var third: BaseButton = win.control([78, 208])
	_click(third.get_global_rect().get_center())
	await _frames()
	var free: BaseButton = win.control([78, 207])
	_check(page.edit.camera_view == "third_person" and third.button_pressed and not free.button_pressed, "the view boxes act as one choice (Third Person)")
	var full: BaseButton = win.control([78, 203])
	_click(full.get_global_rect().get_center())
	await _frames()
	_check(page.edit.fullscreen and page.resolution_combo().disabled, "Full screen checked: the resolution row is unavailable (Godot keeps the desktop's size)")
	# Apply: stored and handed on.
	var got: Array = []
	win.video_applied.connect(func(o: VideoOptions) -> void: got.append(o))
	var path := ClientSettings.PATH
	var had := FileAccess.file_exists(path)
	var original := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	win.press_apply()
	_check(got.size() == 1 and (got[0] as VideoOptions).current().quality == VideoOptions.QUALITY_MIDDLE and (got[0] as VideoOptions).camera_view == "third_person",
		"Apply hands the record on (Middle, Third Person)")
	var cfg := ConfigFile.new()
	cfg.load(path)
	_check(int(cfg.get_value("video_graphic1", "quality", -1)) == 1 and bool(cfg.get_value("video", "fullscreen", false)), "Apply saves [video_graphic1] quality=1 and fullscreen")
	# Default: this client's defaults on the shown record, in a window.
	win.press_default()
	_check(page.edit.current().quality == VideoOptions.QUALITY_USER and not page.edit.fullscreen and page.edit.camera_view == "free",
		"Default: User control with this client's defaults, a window, the Free view (OURS; retail picks Middle and full screen)")
	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(original)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	win.queue_free()
	VideoOptions.set_in_force(saved_force)
	await _frames()
