extends SceneTree

## Round 854: UiScaleChoices -- Windows' percentages, only those that leave a
## view of at least the original's 800 x 600 (VideoOptions.MIN_VIEW, READ
## c:0x5fef70), the snapping of old and odd values, and the re-fit when the
## window changes size. Headless; restores the settings file it touches.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_list()
	_filter()
	_snap()
	_console()
	await _refit()
	print("ui_scale_choices_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)

func _list() -> void:
	_check(UiScaleChoices.PERCENTS == [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500],
		"Windows' display-scale steps, 100% to 500%")
	_check(UiScaleChoices.DEFAULT_PERCENT == 100 and VideoOptions.MIN_VIEW == Vector2i(800, 600),
		"default 100% (the original's size); minimum view 800 x 600")
	_check(UiScaleChoices.label(175) == "175%", "labels read 175%")

func _filter() -> void:
	var cases := [
		[Vector2i(800, 600), 100], [Vector2i(1024, 768), 125], [Vector2i(1280, 720), 100],
		[Vector2i(1366, 768), 125], [Vector2i(1600, 900), 150], [Vector2i(1920, 1080), 175],
		[Vector2i(1920, 1200), 200], [Vector2i(2560, 1440), 225], [Vector2i(3440, 1440), 225],
		[Vector2i(3840, 2160), 350], [Vector2i(5120, 2880), 450], [Vector2i(7680, 4320), 500],
		[Vector2i(640, 480), 100], [Vector2i.ZERO, 100]]
	for c in cases:
		var got := UiScaleChoices.offered(c[0])
		var want: Array = []
		for p in UiScaleChoices.PERCENTS:
			if p <= int(c[1]):
				want.append(p)
		_check(got == want, "%dx%d offers up to %d%% (got %s)" % [c[0].x, c[0].y, c[1], got])
	# The edges are exact: a view of exactly 800 x 600 fits.
	_check(UiScaleChoices.fits(150, Vector2i(1200, 900)) and not UiScaleChoices.fits(150, Vector2i(1199, 900))
		and not UiScaleChoices.fits(150, Vector2i(1200, 899)), "150% needs 1200 x 900 exactly")
	_check(UiScaleChoices.fits(125, Vector2i(1000, 750)) and not UiScaleChoices.fits(125, Vector2i(1000, 749)),
		"125% needs 1000 x 750 exactly")
	_check(UiScaleChoices.effective(150, Vector2i(1920, 1080)) == 150 and UiScaleChoices.effective(200, Vector2i(1920, 1080)) == 175
		and UiScaleChoices.effective(300, Vector2i(1280, 720)) == 100 and UiScaleChoices.effective(130, Vector2i(3840, 2160)) == 125,
		"effective: the choice when it fits, else the largest that does; an odd one snapped first")

func _snap() -> void:
	var cases := [[1.0, 100], [0.5, 100], [0.75, 100], [1.1, 100], [1.125, 100], [1.13, 125], [1.3, 125],
		[1.5, 150], [1.95, 200], [2.35, 225], [2.75, 250], [2.76, 300], [3.0, 300], [4.2, 400], [9.0, 500],
		[0.0, 100], [-2.0, 100], [NAN, 100], [INF, 100]]
	for c in cases:
		_check(UiScaleChoices.snap(c[0]) == c[1], "snap(%s) -> %d%% (got %d)" % [str(c[0]), c[1], UiScaleChoices.snap(c[0])])

func _console() -> void:
	var cases := [[["150"], 150], [["150%"], 150], [["1.5"], 150], [["1.3"], 125], [["0.5"], 100],
		[["275"], 250], [["2.8"], 300], [["900"], 500], [["big"], 0], [["0"], 0], [[], 0], [["1", "2"], 0]]
	for c in cases:
		_check(Console.uiscale_percent(c[0]) == c[1], "/uiscale %s -> %d (got %d)" % [" ".join(c[0]), c[1], Console.uiscale_percent(c[0])])

func _frames(n: int = 2) -> void:
	for i in n:
		await process_frame

func _refit() -> void:
	await _frames()
	var path := ClientSettings.PATH
	var had := FileAccess.file_exists(path)
	var original := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	# An older build's value reads snapped.
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_UI_SCALE, 1.3)
	_check(UiScaleChoices.saved_percent() == 125 and is_equal_approx(ClientSettings.ui_scale(), 1.25), "a saved 1.3 reads as 125%")
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_UI_SCALE, 0.5)
	_check(UiScaleChoices.saved_percent() == 100, "a saved 0.5 reads as 100%")
	UiScaleChoices.save_percent(150)
	_check(is_equal_approx(float(ClientSettings.get_value(ClientSettings.SECTION_UI, ClientSettings.KEY_UI_SCALE, 0.0)), 1.5),
		"150% is saved as 1.5 under [ui] scale (round 672's key)")
	# A managed window follows its size.
	root.size = Vector2i(1920, 1080)
	await _frames()
	var used := UiScaleChoices.apply_saved(root)
	_check(used == 150 and is_equal_approx(root.content_scale_factor, 1.5), "1920 x 1080: 150%% in force (got %d)" % used)
	root.size = Vector2i(1280, 720)
	await _frames()
	_check(is_equal_approx(root.content_scale_factor, 1.0), "shrunk to 1280 x 720: 100%% in force (got %.2f)" % root.content_scale_factor)
	_check(UiScaleChoices.saved_percent() == 150, "... and 150% still saved")
	root.size = Vector2i(1600, 900)
	await _frames()
	_check(is_equal_approx(root.content_scale_factor, 1.5), "1600 x 900: 150%% fits again (got %.2f)" % root.content_scale_factor)
	_check(UiScaleChoices.describe(150, 125, Vector2i(1366, 768)).contains("fits up to 125%"), "the line says what is used and why")
	UiScaleChoices.save_percent(500)
	root.size = Vector2i(4000, 3000)
	await _frames()
	_check(is_equal_approx(root.content_scale_factor, 5.0), "4000 x 3000 takes 500%% (apply_ui_scale allows 5.0) (got %.2f)" % root.content_scale_factor)
	# Released, a hand-set scale is left alone.
	UiScaleChoices.release(root)
	root.content_scale_factor = 1.95
	root.size = Vector2i(1280, 720)
	await _frames()
	_check(is_equal_approx(root.content_scale_factor, 1.95), "released: a resize leaves a hand-set scale")
	root.content_scale_factor = 1.0
	root.size = Vector2i(1152, 648)
	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(original)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
