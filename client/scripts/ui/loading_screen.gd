class_name LoadingScreen
extends Control

## The "NOW LOADING" screen over world entry, so the ~minute of region loading
## is not a black, frozen window. Real backdrop art (loading_default.ddj) from
## the player's own Media.pk2, a "NOW LOADING..." caption and a gold gauge that
## fills as region cells stream in. Added as the top child of the HUD Control
## (so it renders over everything) and freed when the load is done.
##
## Since round 562 World3D puts it up BEFORE the centre cell is built and
## before the HUD exists (World3D._ready -> _show_loading_screen; until then
## _drain_initial_load created it after the synchronous centre cell, so for
## the first seconds of every login the window kept whatever it had drawn
## last -- round 561's baseline: `cell 97/168 built in 5373 ms at frame 13`
## with no screen before it; round 562's runs: the screen at frame 13, the
## centre cell at 14, measured on the frames as well as in the log). The
## HUD is then added to the same parent after the screen, and CanvasItem draw
## order is child order, so the caller moves the screen back over the HUD
## with `cover_siblings()` once the HUD is built. The same round lets the
## caller hand in the Media.pk2 it already holds: until then every screen --
## every login and every teleport -- opened a reader of its own through
## FrontEndUi.open_media(). `_ready` prints which it did and what it cost.
##
## The gauge and caption are our styling, disclosed; the backdrop is the
## client's own art. It only animates while the loader yields the main thread
## (World3D pumps the region queue with awaits); a phase that does not yield
## holds the last frame, which is still a branded screen rather than a freeze.

const DEFAULT_BACKDROP := "interface\\loading\\loading_default.ddj"

var _backdrop_path: String
## The Media.pk2 handed in by the caller, or null to open one in _ready.
var _media: Pk2Reader
var _fill: ColorRect
var _bar_width := 0.0
var _caption: Label

## Where the backdrop's archive came from, set in _ready: "reused" (the
## handle the caller already held), "opened" (this screen opened Media.pk2
## itself -- the path every screen took before round 562, kept for a caller
## with no handle) or "none" (no Media.pk2 configured, or it failed to open).
var media_source := ""
## What the open in _ready cost in milliseconds; 0 when the handle was
## reused. Measured, not assumed: Pk2Reader.open reads the 256-byte header
## and walks directories lazily, so this is the open alone.
var media_open_ms := 0

func _init(backdrop_ddj: String = DEFAULT_BACKDROP, media: Pk2Reader = null) -> void:
	_backdrop_path = backdrop_ddj
	_media = media

func _ready() -> void:
	var t_start := Time.get_ticks_msec()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var screen := get_viewport().get_visible_rect().size

	var ground := ColorRect.new()
	ground.color = Color.BLACK
	ground.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(ground)

	var media := _media
	if media != null:
		media_source = "reused"
	else:
		var t_open := Time.get_ticks_msec()
		media = FrontEndUi.open_media()
		media_open_ms = Time.get_ticks_msec() - t_open
		media_source = "opened" if media != null else "none"
	var t_backdrop := Time.get_ticks_msec()
	var bg := FrontEndUi.backdrop(media, _backdrop_path)
	var backdrop_ms := Time.get_ticks_msec() - t_backdrop
	if bg != null:
		add_child(bg)
	add_child(FrontEndUi.vignette())

	var bar_w := 760.0
	_caption = FrontEndUi.label("NOW LOADING...", 22)
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.size = Vector2(400, 30)
	_caption.position = Vector2(screen.x * 0.5 - 200, screen.y - 118)
	add_child(_caption)

	var trough := Panel.new()
	trough.add_theme_stylebox_override("panel", FrontEndUi.plate_style(Color(0.05, 0.05, 0.06, 0.95), FrontEndUi.GOLD_EDGE))
	trough.size = Vector2(bar_w, 26)
	trough.position = Vector2(screen.x * 0.5 - bar_w * 0.5, screen.y - 80)
	add_child(trough)
	_bar_width = bar_w - 8.0
	_fill = ColorRect.new()
	_fill.color = Color(0.86, 0.66, 0.20)
	_fill.position = Vector2(4, 4)
	_fill.size = Vector2(0, 18)
	trough.add_child(_fill)
	# The frame this screen joined the tree in (it is drawn from the next one
	# on), how its archive was come by, and what the screen itself cost --
	# the line a load log is read by (client/tools/README.md, "Load
	# benchmark").
	print("LoadingScreen: up at frame %d (media %s, %d ms; backdrop %s, %d ms; built in %d ms)" % [
		Engine.get_frames_drawn(), media_source, media_open_ms,
		"decoded" if bg != null else "missing", backdrop_ms, Time.get_ticks_msec() - t_start])

## Puts this screen over every sibling added after it. CanvasItem draw order
## is child order, so a screen put up before the HUD is built (World3D._ready
## since round 562) would otherwise be drawn under the minimap, underbar,
## panels and chat that ui_control gains after it. No-op without a parent.
func cover_siblings() -> void:
	var parent := get_parent()
	if parent == null:
		return
	parent.move_child(self, parent.get_child_count() - 1)

## Sets the gauge fill, `fraction` in 0..1.
func set_progress(fraction: float) -> void:
	if _fill != null:
		_fill.size.x = _bar_width * clampf(fraction, 0.0, 1.0)

func set_caption(text: String) -> void:
	if _caption != null:
		_caption.text = text
