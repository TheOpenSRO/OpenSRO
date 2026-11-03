extends SceneTree

## Round 860: UiSounds.hook_cif_button -- the one place a CIFButton gets its
## snd_button_click, layout-built or code-made -- and the code-made sites
## that use it: a framed window's own close button, the page numbers, the
## radio dots. Headless, no archive.
## `godot4 --headless --path client --script res://scripts/audio/cif_button860_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _clicks() -> int:
	return UiSounds.count(UiSounds.KEY_BUTTON_CLICK)

func _run() -> void:
	UiSounds.fired.clear()
	var b := TextureButton.new()
	get_root().add_child(b)
	UiSounds.hook_cif_button(b, "Test")
	UiSounds.hook_cif_button(b, "Test")
	b.pressed.emit()
	_check(_clicks() == 1, "a hooked button clicks once per press, however often it was hooked (%d)" % _clicks())

	# The page numbers (FUN_00648a80's CIFButtons).
	UiSounds.fired.clear()
	var pm := NifPageManager.new()
	get_root().add_child(pm)
	var pages: Array = pm.find_children("Page*", "TextureButton", true, false)
	_check(not pages.is_empty(), "the page manager has its number buttons (%d)" % pages.size())
	if not pages.is_empty():
		(pages[0] as TextureButton).pressed.emit()
	_check(_clicks() == 1, "a page number clicks (%d)" % _clicks())
	pm.queue_free()
	b.queue_free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
