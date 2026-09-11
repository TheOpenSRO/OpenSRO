class_name LoadingScreen
extends Control

## The "NOW LOADING" screen over world entry, so the ~minute of region loading
## is not a black, frozen window. Real backdrop art (loading_default.ddj) from
## the player's own Media.pk2, a "NOW LOADING..." caption and a gold gauge that
## fills as region cells stream in. Added as the top child of the HUD Control
## (so it renders over everything) and freed when the load is done.
##
## The gauge and caption are our styling, disclosed; the backdrop is the
## client's own art. It only animates while the loader yields the main thread
## (World3D pumps the region queue with awaits); a phase that does not yield
## holds the last frame, which is still a branded screen rather than a freeze.

const DEFAULT_BACKDROP := "interface\\loading\\loading_default.ddj"

var _backdrop_path: String
var _fill: ColorRect
var _bar_width := 0.0
var _caption: Label

func _init(backdrop_ddj: String = DEFAULT_BACKDROP) -> void:
	_backdrop_path = backdrop_ddj

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var screen := get_viewport().get_visible_rect().size

	var ground := ColorRect.new()
	ground.color = Color.BLACK
	ground.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(ground)

	var media := FrontEndUi.open_media()
	var bg := FrontEndUi.backdrop(media, _backdrop_path)
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

## Sets the gauge fill, `fraction` in 0..1.
func set_progress(fraction: float) -> void:
	if _fill != null:
		_fill.size.x = _bar_width * clampf(fraction, 0.0, 1.0)

func set_caption(text: String) -> void:
	if _caption != null:
		_caption.text = text
