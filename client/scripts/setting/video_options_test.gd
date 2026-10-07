extends SceneTree

## The Option window's Video tab (round 694): VideoOptions (the original's
## presets, ladders and curve as READ; the Middle default (the user's
## decision, 2026-10-02); the saved
## file) and OptionVideoPage on a synthetic optionwnd.2dt whose pane-78
## records carry the real file's ids, types, parents and rects (MEASURED; no
## art, no text, no game data). Also the two places the options reach that
## run headless: MapAnimation's object range and SkillEffects' effect gate.
##
## NEGATIVE: before round 694 VideoOptions, OptionVideoPage,
## MapAnimation.object_range and SkillEffects.wants_effect do not exist --
## this suite does not parse. Before round 696 VideoOptions.restore_for_size,
## window_placement and frame_insets and OptionVideoPage.combo_field_rect do
## not exist (it does not parse either), and the combos had no field: the
## ComboField / ComboArrow checks fail.
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
	_window_placement()
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
	_check(p.quality == VideoOptions.QUALITY_MIDDLE and p.brightness == 2, "a new record is Middle, Normal brightness (READ 0x5f75e0; the user's choice of default)")
	for e in VideoOptions.DEFAULTS:
		_check(p.value(e) == int(VideoOptions.DEFAULTS[e]), "default row %s = %d" % [VideoOptions.row_of(e)["key"], VideoOptions.DEFAULTS[e]])
	for e in VideoOptions.VALUE_ENTRIES:
		if e != VideoOptions.SSAO and e != VideoOptions.FOG:
			_check(int(VideoOptions.DEFAULTS[e]) == int(VideoOptions.PRESETS[VideoOptions.QUALITY_MIDDLE][e]), "the player's own copy of %s starts as Middle's" % VideoOptions.row_of(e)["key"])
	_check(p.value(VideoOptions.BLOOM) == 1 and p.value(VideoOptions.WATER_REFLECTION) == 0 and p.value(VideoOptions.SHADOW) == 1 and p.value(VideoOptions.SSAO) == 0,
		"the default: bloom ON, reflection OFF, Circle shadows, SSAO off")
	VideoOptions.set_row(p, VideoOptions.QUALITY, VideoOptions.QUALITY_HIGH)
	_check(p.value(VideoOptions.SHADOW) == 2 and p.value(VideoOptions.WATER_REFLECTION) == 1, "choosing High fills the rows from its preset (Detail, reflection on)")
	p.user[VideoOptions.SHADOW] = 0
	VideoOptions.set_row(p, VideoOptions.QUALITY, VideoOptions.QUALITY_MIDDLE)
	_check(p.value(VideoOptions.BLOOM) == 1 and p.value(VideoOptions.WATER_REFLECTION) == 0 and p.value(VideoOptions.SHADOW) == 1,
		"choosing Middle fills the rows from its preset (bloom on, reflection off, Circle)")
	_check(p.user[VideoOptions.SHADOW] == 0, "the player's own values stay behind a preset (retail's second copy)")
	VideoOptions.set_row(p, VideoOptions.WATER_REFLECTION, 1)
	_check(p.quality == VideoOptions.QUALITY_USER, "setting a row under a preset switches the record to User control")
	_check(p.value(VideoOptions.WATER_REFLECTION) == 1 and p.value(VideoOptions.BLOOM) == 1 and p.value(VideoOptions.SHADOW) == 1,
		"... keeping every other row as the preset had it (bloom 1, Circle 1), the one row changed")
	VideoOptions.set_row(p, VideoOptions.SSAO, 1)
	VideoOptions.set_row(p, VideoOptions.QUALITY, VideoOptions.QUALITY_LOW)
	_check(p.value(VideoOptions.SSAO) == 1 and p.quality == VideoOptions.QUALITY_LOW, "SSAO (OURS) is the player's under every preset and does not switch to User")
	# Round 702: the temporary fog row, on by default (the original's look).
	var pf := VideoOptions.Profile.new()
	_check(pf.value(VideoOptions.FOG) == 1, "Fog (temporary, OURS) is on by default: the original always draws its fog")
	VideoOptions.set_row(pf, VideoOptions.FOG, 0)
	_check(pf.value(VideoOptions.FOG) == 0 and pf.quality == VideoOptions.QUALITY_MIDDLE, "turning Fog off keeps the Graphic Quality (it is not a retail row)")
	VideoOptions.set_row(pf, VideoOptions.QUALITY, VideoOptions.QUALITY_HIGH)
	_check(pf.value(VideoOptions.FOG) == 0, "... and no preset turns it back on")
	VideoOptions.set_row(p, VideoOptions.SHADOW, 9)
	_check(p.value(VideoOptions.SHADOW) == 2, "a value past the choices is clamped (Shadow 9 -> 2)")

func _rows() -> void:
	var entries: Array = []
	for r in VideoOptions.ROWS:
		entries.append(int(r["entry"]))
	_check(entries == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 18, 17], "the list: retail's rows 0..13 and 15 (READ, 14 never listed), then SSAO, the temporary fog row and the renderer (OURS)")
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
	_check(VideoOptions.fit_resolution(Vector2i(2560, 1440), Vector2i(1920, 1040)) == Vector2i(1920, 1040)
		and VideoOptions.fit_resolution(Vector2i(1024, 768), Vector2i(1920, 1040)) == Vector2i(1024, 768),
		"a saved size larger than the screen is cut to the screen's usable area (round 694 review)")
	_check(VideoOptions.parse_resolution("1280x720") == Vector2i(1280, 720) and VideoOptions.parse_resolution("junk") == Vector2i.ZERO
		and VideoOptions.format_resolution(Vector2i(1024, 768)) == "1024x768", "resolution text round trip")

# --- the window (round 696) ---------------------------------------------------

## The user's report: in a window, a lower resolution left a black border.
## READ (Godot 4.2.2): DisplayServerWindows::window_set_size returns while the
## window is maximised, but Window::set_size has already sized the viewport,
## so a maximised window must be restored first. The rects here are synthetic
## (OURS): a 3840 x 2112 work area and a Windows-10-like frame (8 px sides,
## a 31 px title bar: client offset (8, 31), frame extra (16, 39)).
func _window_placement() -> void:
	_check(VideoOptions.restore_for_size(Window.MODE_MAXIMIZED) and VideoOptions.restore_for_size(Window.MODE_MINIMIZED)
		and VideoOptions.restore_for_size(Window.MODE_FULLSCREEN) and not VideoOptions.restore_for_size(Window.MODE_WINDOWED),
		"a maximised, minimised or full-screen window is restored before it is sized; a plain window is not")
	var area := Rect2i(0, 0, 3840, 2112)
	var inset := VideoOptions.frame_insets(Vector2i(1008, 531), Vector2i(1280, 720), Vector2i(1000, 500), Vector2i(1296, 759))
	_check(inset == Rect2i(8, 31, 16, 39), "the frame: client offset (8, 31) inside it, 16 x 39 extra (got %s)" % str(inset))
	var r := VideoOptions.window_placement(Vector2i(1280, 720), area, inset)
	_check(r.size == Vector2i(1280, 720), "1280 x 720 asked: the client area is 1280 x 720 (got %s)" % str(r.size))
	_check(r.position == Vector2i((3840 - 1296) / 2 + 8, (2112 - 759) / 2 + 31),
		"... with the FRAME centred in the work area (retail centres the frame too, FUN_00835510) (got %s)" % str(r.position))
	r = VideoOptions.window_placement(Vector2i(3840, 2160), area, inset)
	_check(r.size == Vector2i(3840 - 16, 2112 - 39) and r.position == Vector2i(8, 31),
		"3840 x 2160 on that screen: cut to the work area less the frame, the frame at the area's corner -- never off screen (got %s)" % str(r))
	r = VideoOptions.window_placement(Vector2i(1024, 768), Rect2i(3840, 0, 1920, 1040), Rect2i())
	_check(r == Rect2i(3840 + 448, 136, 1024, 768), "no frame (a box X server with no window manager), a second screen at x 3840: centred on that screen (got %s)" % str(r))
	_check(VideoOptions.frame_insets(Vector2i(10, 10), Vector2i(800, 600), Vector2i(10, 10), Vector2i(800, 600)) == Rect2i(),
		"no frame reported: no insets")
	_check(VideoOptions.window_placement(Vector2i(800, 600), Rect2i(), Rect2i()).size == Vector2i(800, 600),
		"no usable area known: the size as asked")
	_check(not VideoOptions.sync_window_size(null) and not VideoOptions.sync_window_size(root),
		"headless: nothing to correct (the live check is the box's windowed run, round 696)")
	# Round 696 review M1: the UI scale. Retail lists no mode below 800 x 600
	# (READ 0x5fef70); here that is the smallest VIEW, window / scale. The
	# user's scale is 2.0 (1.95 in the report).
	_check(VideoOptions.min_window(1.0) == Vector2i(800, 600) and VideoOptions.min_window(1.95) == Vector2i(1560, 1170)
		and VideoOptions.min_window(2.0) == Vector2i(1600, 1200), "the smallest window: 800 x 600 at 1, 1560 x 1170 at 1.95, 1600 x 1200 at 2.0")
	var c195 := VideoOptions.resolution_choices(Vector2i(3840, 2160), Vector2i.ZERO, 1.95)
	_check(c195[0] == Vector2i(1600, 1200) and not c195.has(Vector2i(1280, 720)) and not c195.has(Vector2i(1920, 1080))
		and c195.has(Vector2i(2560, 1440)) and c195[-1] == Vector2i(3840, 2160),
		"at 1.95 on 3840 x 2160 the list starts at 1600 x 1200: no 1280 x 720 (a 656 x 369 view), no 1920 x 1080 (985 x 554) (got %s)" % [c195])
	var c20 := VideoOptions.resolution_choices(Vector2i(3840, 2160), Vector2i(3840, 2019), 2.0)
	_check(c20[0] == Vector2i(1600, 1200) and not c20.has(Vector2i(1680, 1050)) and c20.has(Vector2i(1920, 1200)) and c20.has(Vector2i(3840, 2019)),
		"at 2.0: from 1600 x 1200, no 1680 x 1050 (a 525-tall view), the maximised 3840 x 2019 kept (got %s)" % [c20])
	_check(VideoOptions.resolution_choices(Vector2i(1920, 1080), Vector2i.ZERO, 2.0) == [Vector2i(1920, 1080)],
		"at 2.0 a 1920 x 1080 screen has no size with an 800 x 600 view: the list is the largest that fits, never empty")
	_check(VideoOptions.resolution_choices(Vector2i(1920, 1080), Vector2i.ZERO)[0] == Vector2i(800, 600), "at 1.0 the list still starts at 800 x 600")
	r = VideoOptions.window_placement(Vector2i(1280, 720), area, inset, 1.95)
	_check(r.size == Vector2i(1560, 1170), "a saved 1280 x 720 at 1.95 is raised to 1560 x 1170 -- the Option window's buttons stay on screen (got %s)" % str(r.size))
	r = VideoOptions.window_placement(Vector2i(1280, 720), area, inset, 2.0)
	_check(r.size == Vector2i(1600, 1200) and r.position == Vector2i((3840 - 1616) / 2 + 8, (2112 - 1239) / 2 + 31),
		"... and to 1600 x 1200 at 2.0, centred (got %s)" % str(r))
	r = VideoOptions.window_placement(Vector2i(1280, 720), Rect2i(0, 0, 1920, 1040), Rect2i(), 2.0)
	_check(r.size == Vector2i(1600, 1040), "the screen wins over the minimum: 1600 x 1040 on a 1920 x 1040 area at 2.0 (got %s)" % str(r.size))
	_check(VideoOptions.window_placement(Vector2i(1280, 720), area, inset).size == Vector2i(1280, 720), "at 1.0 nothing is raised")
	var touched := VideoOptions.new()
	touched.resolution = Vector2i(1280, 720)
	touched.resolution_touched = true
	_check(not VideoOptions.needs_resize(null, touched) and not touched.duplicate_options().resolution_touched,
		"L1: needs_resize wants a window; the touched mark is not copied (store hands it on once)")

func _storage() -> void:
	var path := _dir.path_join("settings.cfg")
	var legacy := ConfigFile.new()
	legacy.set_value("world", "water_reflection", false)
	legacy.set_value("ui", "scale", 1.5)
	legacy.save(path)
	var o := VideoOptions.load_saved(path)
	_check(o.value(VideoOptions.WATER_REFLECTION) == 0 and o.current().quality == VideoOptions.QUALITY_MIDDLE,
		"a pre-694 file with [world] water_reflection=false: Middle, as it is (its reflection is off too)")
	var legacy_on := ConfigFile.new()
	legacy_on.set_value("world", "water_reflection", true)
	legacy_on.save(_dir.path_join("legacy_on.cfg"))
	var lo := VideoOptions.load_saved(_dir.path_join("legacy_on.cfg"))
	_check(lo.value(VideoOptions.WATER_REFLECTION) == 1 and lo.current().quality == VideoOptions.QUALITY_USER
		and lo.value(VideoOptions.BLOOM) == 1 and lo.value(VideoOptions.SHADOW) == 1 and lo.profiles[1].value(VideoOptions.WATER_REFLECTION) == 1,
		"a pre-694 file with water_reflection=true: the stored choice wins -- User control with Middle's other rows, both records")
	var bare := ConfigFile.new()
	bare.set_value("ui", "scale", 1.25)
	bare.save(_dir.path_join("bare.cfg"))
	var bo := VideoOptions.load_saved(_dir.path_join("bare.cfg"))
	_check(bo.current().quality == VideoOptions.QUALITY_MIDDLE and bo.value(VideoOptions.WATER_REFLECTION) == 0 and bo.value(VideoOptions.BLOOM) == 1,
		"a pre-694 file with no video key at all: Middle (reflection off, bloom on)")
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
	_check(none.active == 0 and not none.fullscreen and none.current().quality == VideoOptions.QUALITY_MIDDLE, "no file: Graphic 1, a window, Middle")

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
	_check(not env.ssao_enabled and not env.glow_enabled, "apply_post_effects: Bloom on never turns Godot's glow on (round 702 review: RetailBloom draws the original's bloom)")
	VideoOptions.apply_post_effects(env, true, true)
	_check(is_equal_approx(env.ssao_radius, 16.0) and is_equal_approx(env.ssao_light_affect, 1.0) and is_equal_approx(env.ssao_intensity, 4.0),
		"SSAO on takes this world's scale: radius 16, intensity 4, light affect 1 (OURS; Godot's radius 1 drew nothing measurable)")
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

## Round 696: every combo on the tab draws the original's black value box
## (READ, CNIFComboBox::vslot_010 0x486d30): the field {0, 0, W-20, H} filled
## 0xff000000 with the com_blacksquare_ frame, the arrow {W-20, 0, 20, H}, the
## text {5, 0, W-30, H}. The file's combos are 156 x 18 (Resolution, Set
## Brightness) and 150 x 20 (the rows), MEASURED.
func _combo_field(page: OptionVideoPage) -> void:
	_check(OptionVideoPage.combo_field_rect(Vector2(150, 20)) == Rect2(0, 0, 130, 20)
		and OptionVideoPage.combo_arrow_rect(Vector2(150, 20)) == Rect2(130, 0, 20, 20)
		and OptionVideoPage.combo_text_rect(Vector2(150, 20)) == Rect2(5, 0, 120, 20),
		"a 150 x 20 combo: field 130 x 20, arrow at x 130 (20 x 20), text from x 5, 120 wide (READ)")
	var combos: Array = [page.resolution_combo(), page.brightness_combo()]
	for n in page.slot_count():
		combos.append(page.slot_combo(n))
	var good := 0
	for c in combos:
		var combo := c as OptionButton
		if combo == null:
			continue
		var host := combo.get_parent() as Control
		var field := host.get_node_or_null("ComboField") as Control
		var arrow := host.get_node_or_null("ComboArrow") as TextureRect
		var hs := host.size
		var ok := field != null and arrow != null
		if ok:
			ok = field.get_rect() == Rect2(0, 0, hs.x - 20, hs.y) and arrow.get_rect() == Rect2(hs.x - 20, 0, 20, hs.y)
			ok = ok and field.get_index() < combo.get_index() and arrow.get_index() < combo.get_index()
			var blank := combo.get_theme_icon("arrow")
			ok = ok and blank != null and blank.get_width() == 20
			var st := combo.get_theme_stylebox("normal")
			ok = ok and st.content_margin_left == 5 and st.content_margin_right == 5 and combo.get_theme_constant("h_separation") == 0
			ok = ok and combo.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST and field.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE
			ok = ok and combo.has_meta(OptionVideoPage.LIST_META)
		if ok:
			good += 1
		else:
			print("  combo %s: field %s arrow %s host %s" % [combo.get_path(), str(field.get_rect()) if field != null else "none", str(arrow.get_rect()) if arrow != null else "none", str(hs)])
	_check(combos.size() == 14 and good == 14,
		"all 14 combos (Resolution, Set Brightness, the 12 rows) draw a field {0,0,W-20,H} and the arrow {W-20,0,20,H} behind a button whose text room is {5,0,W-30,H}, the text crisp, the open list ComboList (got %d of %d)" % [good, combos.size()])
	_check(page.resolution_combo() != null and (page.resolution_combo().get_parent() as Control).size == Vector2(156, 18),
		"the Resolution combo's record is 156 x 18 (the field 136 x 18)")

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
	# After the first frame (round 754): the start-up resets a root size set
	# before it to 64 x 64 (MEASURED, 4.2.2 and 4.7.2), and from Godot 4.7 a
	# Button counts a press only while the mouse hovers it, which the viewport
	# tracks inside its own rect alone (READ, base_button.cpp on_action_event,
	# `status.hovering`; MEASURED: every click here reached the buttons'
	# gui_input at (64, 64) and pressed none).
	await _frames()
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
	_check(page.slot_combo(0).item_count == 5 and page.slot_combo(0).get_item_text(4) == "User control" and page.slot_combo(0).selected == 1,
		"the quality combo lists five choices and shows Middle (the default)")
	_check(page.max_line() == 3, "18 rows, two a line, six lines shown: three more lines to scroll (got %d)" % page.max_line())
	_combo_field(page)
	# Low through the combo's own signal (a real popup choice emits it).
	page.slot_combo(0).item_selected.emit(0)
	await _frames()
	_check(page.edit.current().quality == VideoOptions.QUALITY_LOW and page.slot_combo(1).selected == 0,
		"choosing Low shows Nothing in Shadow Detail (READ preset)")
	_check(VideoOptions.in_force().current().quality == VideoOptions.QUALITY_MIDDLE, "nothing is in force before Apply")
	# Bloom is row 11: line 5 -- the third line shown once scrolled 3 lines.
	page.scroll_to(3)
	await _frames()
	_check(page.entry_at_slot(0) == VideoOptions.METAL and page.entry_at_slot(4) == VideoOptions.LENS_FLARE
		and page.entry_at_slot(5) == VideoOptions.BLOOM and page.entry_at_slot(10) == VideoOptions.FOG and page.entry_at_slot(11) == VideoOptions.RENDERER,
		"scrolled 3 lines: Metallic Sheen first, Lens Flare / Bloom on the third line, the temporary fog row and the renderer last")
	var bloom := page.combo_of(VideoOptions.BLOOM)
	var ssao := page.combo_of(VideoOptions.SSAO)
	_check(bloom != null and not bloom.disabled and ssao != null and ssao.disabled, "SSAO is greyed without Forward+; Bloom is not (the original's bloom is a canvas pass both renderers draw)")
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
	_check(page.edit.active == 1 and page.edit.current().quality == VideoOptions.QUALITY_MIDDLE, "the Graphic 2 tab shows the second record (still Middle)")
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
	# Round 696 review L1: the shown Resolution picked again counts.
	var res := page.resolution_combo()
	_check(res.allow_reselect and not page.edit.resolution_touched, "the Resolution combo takes a re-pick; nothing touched yet")
	res.item_selected.emit(maxi(res.selected, 0))
	_check(page.edit.resolution_touched, "re-picking the shown size marks the row touched")
	# Apply: stored and handed on.
	var got: Array = []
	win.video_applied.connect(func(o: VideoOptions) -> void: got.append(o))
	var path := ClientSettings.PATH
	var had := FileAccess.file_exists(path)
	var original := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	win.press_apply()
	_check(got.size() == 1 and (got[0] as VideoOptions).current().quality == VideoOptions.QUALITY_LOW and (got[0] as VideoOptions).camera_view == "third_person",
		"Apply hands the record on (Low, Third Person)")
	_check(got.size() == 1 and (got[0] as VideoOptions).resolution_touched and not page.edit.resolution_touched,
		"... with the touched mark, once: the edit is clear again for the next Apply")
	var cfg := ConfigFile.new()
	cfg.load(path)
	_check(int(cfg.get_value("video_graphic1", "quality", -1)) == 0 and bool(cfg.get_value("video", "fullscreen", false)), "Apply saves [video_graphic1] quality=0 and fullscreen")
	# Default: Middle on the shown record; the window mode untouched.
	win.press_default()
	_check(page.edit.current().quality == VideoOptions.QUALITY_MIDDLE and page.edit.fullscreen and page.edit.camera_view == "free"
		and page.edit.current().brightness == 2,
		"Default: Middle, Normal, the Free view, and the window mode left as it was (full screen here) -- the user's decision")
	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(original)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Round 696: the window is centred again when the view changes size under
	# it (an Apply that resized the game window left it half off the screen).
	win.show()
	win.place_centred()
	var was := win.position
	root.size = Vector2i(900, 560)
	await _frames()
	var want := Vector2(maxi(0, (900 >> 1) - (int(win.size.x) >> 1)), maxi(0, (560 >> 1) - (int(win.size.y) >> 1)))
	_check(win.position == want and win.position != was,
		"the view shrinks under the open Option window: it is centred again (%s -> %s, want %s)" % [str(was), str(win.position), str(want)])
	# ... and at a UI scale (round 672's content_scale_factor, the user's 1.95):
	# the view is the window's size over the factor, and the window is centred
	# in that.
	root.content_scale_factor = 1.95
	root.size = Vector2i(2400, 1400)
	await _frames()
	var view := win.get_viewport_rect().size
	want = Vector2(maxi(0, (int(view.x) >> 1) - (int(win.size.x) >> 1)), maxi(0, (int(view.y) >> 1) - (int(win.size.y) >> 1)))
	_check(absf(view.x - 2400.0 / 1.95) < 1.0 and win.position == want,
		"at UI scale 1.95 a 2400 x 1400 window is a %s view and the Option window is centred in it (%s, want %s)" % [str(view), str(win.position), str(want)])
	root.content_scale_factor = 1.0
	root.size = Vector2i(1152, 648)
	await _frames()
	win.queue_free()
	VideoOptions.set_in_force(saved_force)
	await _frames()
