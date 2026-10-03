extends Node

## Round 679's render tool (OURS): the login screen at a UI scale, as a
## player whose settings carry that scale sees it -- Boot applies the scale
## before Login; this applies OPENSRO_QA_UI_SCALE (default 1.0) and
## instances res://scenes/Login.tscn, without Boot's update check. Then, by
## the clock: the title skipped at SKIP_S; at SHOT_S the logo's and the login
## box's rects printed (canvas units) and the screen saved to
## <OPENSRO_QA_SHOT_DIR>/login.png; the server list opened (as LIST does);
## at LIST_SHOT_S the screen saved to list.png; quit.
##
##   OPENSRO_QA_UI_SCALE=1.95 OPENSRO_QA_SHOT_DIR=/var/tmp/x xvfb-run godot \
##     --path client res://tools/login_at_scale.tscn --resolution 3840x2160
##   -> `LOGINRECT logo (x, y, w, h) box (x, y, w, h) gap g canvas WxH`

const SKIP_S := 10.0
const SHOT_S := 14.0
const LIST_SHOT_S := 19.0

var _login: Node = null
var _t := 0.0
var _step := 0
var _dir := ""

func _ready() -> void:
	var scale := OS.get_environment("OPENSRO_QA_UI_SCALE")
	ClientSettings.apply_ui_scale(get_window(), scale.to_float() if scale != "" else 1.0)
	_dir = OS.get_environment("OPENSRO_QA_SHOT_DIR")
	_login = (load("res://scenes/Login.tscn") as PackedScene).instantiate()
	add_child(_login)

func _process(delta: float) -> void:
	_t += delta
	match _step:
		0:
			if _t >= SKIP_S:
				_step = 1
				var title = _login.get("_title")
				if title != null:
					title.skip("login_at_scale")
				# Typed values, so the shot shows the centred text and the mask.
				var id_edit = _login.get("username_edit")
				var pw_edit = _login.get("password_edit")
				if id_edit != null and pw_edit != null:
					id_edit.text = "tester"
					pw_edit.text = "secret12"
					pw_edit.grab_focus()
					pw_edit.caret_column = pw_edit.text.length()
		1:
			if _t >= SHOT_S:
				_step = 2
				_measure()
				_save("login.png")
				_login.call("_open_server_list")
		2:
			if _t >= LIST_SHOT_S:
				_step = 3
				_save("list.png")
				get_tree().quit()

func _measure() -> void:
	var frame = _login.get("_frame")
	var box = _login.get("_login_window")
	if frame == null or box == null:
		print("LOGINRECT no title frame (plain screen)")
		return
	var logo: Control = frame.logo
	var lr := Rect2(logo.position, logo.size)
	var br := Rect2((box as Control).position, (box as Control).size)
	print("LOGINRECT logo %s box %s gap %d canvas %s" % [lr, br, int(br.position.y - lr.end.y), get_viewport().get_visible_rect().size])

func _save(name: String) -> void:
	if _dir == "":
		return
	var img := get_viewport().get_texture().get_image()
	var path := _dir.path_join(name)
	print("LOGINSHOT %s %dx%d -> %s" % [name, img.get_width(), img.get_height(), "ok" if img.save_png(path) == OK else "FAILED"])
