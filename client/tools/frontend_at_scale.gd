extends Node

## Round 688's measurement (OURS, a dev tool): a front-end screen at a UI
## scale, as a player whose settings carry it sees it -- Boot applies the
## scale before any screen; this applies OPENSRO_QA_UI_SCALE (default 1.0)
## and opens OPENSRO_QA_SCREEN (create, select or login; create by
## default). At SHOT_S every shown button's rect and its text's rect are
## printed, hidden ones too (CharSelectQa.button_report, canvas units) and the screen saved
## to <OPENSRO_QA_SHOT_DIR>/<screen>_<scale>.png; then the client quits.
##
##   OPENSRO_QA_UI_SCALE=1.95 OPENSRO_QA_SCREEN=create xvfb-run godot \
##     --path client res://tools/frontend_at_scale.tscn --resolution 3840x2160
##   -> `QA BUTTON <name> '<text>' button (...) text (...) over L T R B ...`

const SHOT_S := 16.0
const SCENES := {"create": "res://scenes/CharacterCreate.tscn", "select": "res://scenes/CharacterSelect.tscn",
	"login": "res://scenes/Login.tscn"}

var _screen: Node = null
var _name := "create"
var _t := 0.0
var _done := false

func _ready() -> void:
	var scale := OS.get_environment("OPENSRO_QA_UI_SCALE")
	ClientSettings.apply_ui_scale(get_window(), scale.to_float() if scale != "" else 1.0)
	var want := OS.get_environment("OPENSRO_QA_SCREEN")
	if SCENES.has(want):
		_name = want
	_screen = (load(SCENES[_name]) as PackedScene).instantiate()
	add_child(_screen)

func _process(delta: float) -> void:
	_t += delta
	if _name == "login" and _t >= 8.0 and _screen.get("_title") != null:
		_screen.get("_title").skip("frontend_at_scale")
	if _done or _t < SHOT_S:
		return
	_done = true
	var scale := get_window().content_scale_factor
	print("QA SCREEN %s scale %.2f canvas %s window %s" % [_name, scale, get_viewport().get_visible_rect().size, get_window().size])
	for d in CharSelectQa.button_report(_screen, true):
		print("QA BUTTON " + CharSelectQa.button_line(d))
	var dir := OS.get_environment("OPENSRO_QA_SHOT_DIR")
	if dir != "":
		get_viewport().get_texture().get_image().save_png(dir.path_join("%s_%.2f.png" % [_name, scale]))
	get_tree().quit()
