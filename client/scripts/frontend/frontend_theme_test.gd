extends SceneTree

## The operator's front-end theme (round 678, OURS) and the pieces that act
## on it:
##   - the one JSON structure (server answer, settings cache, custom/theme.json)
##     with its reserved charselect/create slots;
##   - the order: preview variables > the server's fresh answer (else the
##     cached one, as one layer) > custom/theme.json > retail's defaults;
##   - names never escape their folders (custom/intro, custom/frontend,
##     script\intro);
##   - the server's OpFrontEndTheme frame, read by ThemeQuery (the exact
##     134-byte frame the server's own test produces);
##   - the intro choice: custom/intro/<name>.txt first, a broken one falls
##     back, then option.txt's IntroName (TitleIntro.resolve_intro);
##   - the logo and band art: custom file -> archive, a broken file -> the
##     archive, with the reason logged (FrontEndFrame);
##   - the fade every frame piece uses (CIFFade, READ FUN_006552f0).
##
## NEGATIVE: before round 678 none of FrontEndTheme, ThemeQuery, TitleIntro
## or FrontEndFrame exists -- this suite does not parse.

var _failures := 0
var _dir := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()

func _initialize() -> void:
	_dir = OS.get_user_data_dir().path_join("frontend_theme_test_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_dir)
	_structure()
	_order()
	_names()
	_wire()
	_intro_choice()
	_images()
	_fades()
	_rm(_dir)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_rm(path.path_join(sub))
	DirAccess.remove_absolute(path)

func _structure() -> void:
	var t := FrontEndTheme.new()
	t.intro = "roc"
	t.copyright = "(c) Ours"
	var json := t.to_json()
	var d = JSON.parse_string(json)
	_check(d is Dictionary and d.has("charselect") and d["charselect"] == null and d.has("create") and d["create"] == null,
		"the structure carries the reserved charselect/create slots as null: %s" % json)
	for k in ["v", "intro", "bgm", "logo", "copyright", "band_top", "band_bottom"]:
		_check(d.has(k), "key %s present" % k)
	var back := FrontEndTheme.from_json(json)
	_check(back != null and back.intro == "roc" and back.copyright == "(c) Ours" and back.bgm == "", "JSON round trip")
	_check(FrontEndTheme.from_json("[1, 2]") == null and FrontEndTheme.from_json("not json") == null, "not an object: null")
	var warnings := PackedStringArray()
	var odd := FrontEndTheme.from_json('{"intro": 5, "logo": "../../evil.png", "zzz": "x", "bgm": "maintheme_cut.ogg"}', warnings)
	_check(odd != null and odd.intro == "" and odd.logo == "" and odd.bgm == "maintheme_cut.ogg" and warnings.size() == 2,
		"a non-string and an unsafe name are dropped with warnings, an unknown key ignored (%s)" % str(warnings))

func _order() -> void:
	var preview := FrontEndTheme.new()
	preview.logo = "preview.png"
	var server := FrontEndTheme.new()
	server.intro = "constantinople"
	server.logo = "server.png"
	var cached := FrontEndTheme.new()
	cached.intro = "jupiter_login"
	cached.copyright = "old line"
	var custom := FrontEndTheme.new()
	custom.intro = "china_wharf"
	custom.band_top = "top.png"
	custom.copyright = "custom line"
	var r := FrontEndTheme.resolve(preview, server, cached, custom)
	_check(r.logo == "preview.png" and r.origin["logo"] == "preview", "the preview variables win (logo)")
	_check(r.intro == "constantinople" and r.origin["intro"] == "server", "then the server's fresh answer (intro)")
	_check(r.copyright == "custom line" and r.origin["copyright"] == "custom",
		"a fresh answer replaces the cache WHOLE: the server cleared the line, the stale cached one does not come back; custom/theme.json's does")
	_check(r.band_top == "top.png" and r.bgm == "", "custom/theme.json fills what the server left; unset stays the default")
	var r2 := FrontEndTheme.resolve(null, null, cached, custom)
	_check(r2.intro == "jupiter_login" and r2.origin["intro"] == "cache" and r2.copyright == "old line",
		"no answer in time: the cached answer stands in for the server")
	var r3 := FrontEndTheme.resolve(null, null, null, null)
	_check(r3.is_empty(), "nothing anywhere: every field is retail's default")

func _names() -> void:
	for good in ["roc", "my_intro-2", "script\\intro\\roc.txt", "SCRIPT\\INTRO\\Ruby Baghdad.TXT"]:
		_check(FrontEndTheme.is_safe_name(good) or FrontEndTheme.is_archive_intro_path(good), "accepted intro name '%s'" % good)
	for bad in ["../x", "..\\x", "C:\\x", "/etc/passwd", "script\\intro\\..\\x.txt", "a/b", "x.txt", "", "a".repeat(65), "script\\intro\\x.txt\\y"]:
		_check(not FrontEndTheme.is_safe_name(bad) and not FrontEndTheme.is_archive_intro_path(bad), "refused intro name '%s'" % bad)
	_check(FrontEndTheme.archive_intro_path("roc") == "script\\intro\\roc.txt", "a bare name is script\\intro\\<name>.txt")
	_check(FrontEndTheme.custom_intro_path(_dir, "../frontend_theme_test") == "", "custom_intro_path refuses a parent")
	for good in ["logo.png", "My-Logo_2.DDJ"]:
		_check(FrontEndTheme.is_safe_file(good, ["png", "ddj"], false), "accepted image '%s'" % good)
	for bad in ["../logo.png", "logo.png.exe", "logo", "a\\b.png", "c:logo.png", "lo go.png"]:
		_check(not FrontEndTheme.is_safe_file(bad, ["png", "ddj"], false), "refused image '%s'" % bad)
	_check(FrontEndTheme.is_safe_file("maintheme_cut.ogg", ["ogg"], true) and not FrontEndTheme.is_safe_file("../x.ogg", ["ogg"], true),
		"music: the archive's names, no parent")
	var w := PackedStringArray()
	var long := FrontEndTheme.sanitize("copyright", "x".repeat(250) + "\u0007", w)
	_check(long.length() == FrontEndTheme.COPYRIGHT_MAX and w.size() == 1, "copyright: control characters dropped, cut at 200")

func _wire() -> void:
	# The server's own test frame (server/internal/session/
	# frontendtheme678_test.go's example), byte for byte.
	var hex := "8000060000007e007b2276223a312c22696e74726f223a22726f63222c2262676d223a22222c226c6f676f223a22222c22636f70797269676874223a22286329204f757273222c2262616e645f746f70223a22222c2262616e645f626f74746f6d223a22222c226368617273656c656374223a6e756c6c2c22637265617465223a6e756c6c7d"
	var bytes := hex.hex_decode()
	var r := ThemeQuery.parse_frames(bytes)
	_check(r.has("theme_json"), "the server's 134-byte OpFrontEndTheme frame reads")
	var t := FrontEndTheme.from_json(str(r.get("theme_json", "")))
	_check(t != null and t.intro == "roc" and t.copyright == "(c) Ours", "and decodes to intro=roc copyright='(c) Ours'")
	_check(ThemeQuery.parse_frames(bytes.slice(0, 40)).is_empty(), "half a frame: keep waiting")
	var other := Packet.new(0x0002, PackedByteArray([1, 0, 0])).encode()
	other.append_array(bytes)
	_check(ThemeQuery.parse_frames(other).has("theme_json"), "another frame first is skipped")
	_check(Packet.new(ThemeQuery.OP_REQUEST).encode() == "000005000000".hex_decode(), "the request is 00 00 05 00 00 00")

func _intro_choice() -> void:
	var good := "[CAMERA]\n0 S_CameraInsert 0 71 100 1 2 3 0 0 0 100\n0 S_CameraInsert 4 71 100 5 6 7 0 0 0 100\n[END]\n"
	_write(_dir.path_join("intro").path_join("mine.txt"), good.to_utf8_buffer())
	_write(_dir.path_join("intro").path_join("broken.txt"), "nothing here".to_utf8_buffer())
	var got := TitleIntro.resolve_intro(null, "mine", _dir)
	_check(got.has("parsed") and str(got["source"]).begins_with("custom") and (got["parsed"] as IntroScript.Parsed).keyframes.size() == 2,
		"custom/intro/mine.txt is preferred when the theme names 'mine' (%s)" % str(got.get("source", got.get("error"))))
	var broken := TitleIntro.resolve_intro(null, "broken", _dir)
	_check(not broken.has("parsed") and broken.has("error"),
		"a custom script that does not parse falls back (to the archive, then option.txt -- none here): %s" % str(broken.get("error")))
	var evil := TitleIntro.resolve_intro(null, "../intro/mine", _dir)
	_check(not evil.has("parsed"), "a name with a parent never reaches the folder")

func _images() -> void:
	var img := Image.create(16, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	_write(_dir.path_join("frontend").path_join("logo.png"), img.save_png_to_buffer())
	_write(_dir.path_join("frontend").path_join("bad.png"), "not a png".to_utf8_buffer())
	var tex := FrontEndFrame.load_image_file(_dir.path_join("frontend").path_join("logo.png"))
	_check(tex != null and tex.get_width() == 16, "an operator's PNG loads")
	_check(FrontEndFrame.load_image_file(_dir.path_join("frontend").path_join("bad.png")) == null, "a broken file is null, not a crash")
	var frame := FrontEndFrame.new()
	var named := frame._custom_texture("bad.png", "logo.png", _dir, "logo")
	_check(named == null, "a named file that cannot be read falls back to the archive's art")
	var dflt := frame._custom_texture("", "logo.png", _dir, "logo")
	_check(dflt != null, "with no name, custom/frontend/logo.png is used when present")
	var missing := frame._custom_texture("nothere.png", "logo.png", _dir, "logo")
	_check(missing == null, "a named file that is missing falls back to the archive's art (not to logo.png)")
	_check(frame._custom_texture("../logo.png", "x.png", _dir, "logo") == null, "an unsafe name is refused")
	frame.free()

func _fades() -> void:
	# READ, FUN_006552f0: from while elapsed <= 0, to once elapsed >= the
	# duration, else round(from * (1 - u) + to * u).
	_check(FrontEndFrame.fade_alpha(0, 255, 3.0, -15.0) == 0, "the big logo before its 15 s start: 0")
	_check(FrontEndFrame.fade_alpha(0, 255, 3.0, 1.5) == 128, "half way: round(127.5) = 128")
	_check(FrontEndFrame.fade_alpha(255, 0, 0.5, 0.5) == 0 and FrontEndFrame.fade_alpha(255, 0, 0.5, 9.0) == 0, "done: the target")
	_check(FrontEndFrame.fade_alpha(200, 255, 0.5, 0.0) == 200, "elapsed 0: the start value")
