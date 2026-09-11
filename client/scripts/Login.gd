extends Control

## Connect / login screen. Connects to the Go server and sends OpLogin /
## OpRegister via the NetClient autoload, then moves to character select on
## success.
##
## The look is the original's: the authored `login_window.ddj` frame over a
## Silkroad backdrop, with ID / PW / Server fields laid on the frame's own
## slots and Connect / Exit below it. That art is loaded at runtime from the
## player's own Media.pk2 (never shipped) exactly the way the HUD loads its
## windows -- through UiBuilder.load_texture. When no Media.pk2 is present
## (a dev run without game data) the screen falls back to a plain styled
## panel, so logging in always works.
##
## The layout constants here are OURS, eyeballed against the real frame art
## (288x140), not recovered values -- the retail client hardcodes this
## screen in C++ with no layout file. See docs/FRONTEND.md.
##
## Server address is user-entered so a friend on the same LAN can point at
## the host's real IP (e.g. "192.168.1.23:15779"); it defaults to
## 127.0.0.1:15779 and is remembered (ClientSettings) between runs. The
## password never is.

const DdjReader = preload("res://scripts/ddj/ddj_reader.gd")

const DEFAULT_SERVER_PORT := 15779

# Art in the player's own Media.pk2.
const FRAME_DDJ := "interface\\outer\\login_window.ddj"
const BACKDROP_DDJ := "interface\\loading\\loading_login_01_2011.ddj"

# The frame's native size and, as fractions of it, where its three input
# slots and their labels sit. Eyeballed from the real 288x140 art -- a
# disclosed design choice, tuned by rendering, not a measured constant.
const FRAME_NATIVE := Vector2(288.0, 140.0)
const FRAME_SCALE := 2.2
# [label_x, field_x, field_right, centre_y] as fractions of the frame.
const SLOT_ID := [0.14, 0.40, 0.86, 0.285]
const SLOT_PW := [0.14, 0.40, 0.86, 0.505]
const SLOT_SERVER := [0.14, 0.40, 0.72, 0.720]
const SLOT_HEIGHT_FRAC := 0.135

var server_address_edit: LineEdit
var username_edit: LineEdit
var password_edit: LineEdit
var login_button: Button
var register_button: Button
var status_label: Label

var _pending_action := "" # "login" or "register", sent once connected

func _ready() -> void:
	_build_ui()
	NetClient.connected.connect(_on_connected)
	NetClient.connection_failed.connect(_on_connection_failed)
	NetClient.login_result.connect(_on_login_result)
	NetClient.register_result.connect(_on_register_result)
	# The server that last answered and the account name come back from the
	# previous run so a tester is not retyping host:port every launch.
	var remembered_address := ClientSettings.server_address()
	server_address_edit.text = remembered_address if remembered_address != "" else "127.0.0.1:%d" % DEFAULT_SERVER_PORT
	var remembered_username := ClientSettings.username()
	if remembered_username != "":
		username_edit.text = remembered_username
	# Enter submits from any field.
	for field in [username_edit, password_edit, server_address_edit]:
		field.text_submitted.connect(func(_t): _on_login_pressed())

# --- Building the screen ---------------------------------------------------

func _build_ui() -> void:
	# A dark ground under everything, so a missing backdrop is black, not the
	# host's theme.
	var ground := ColorRect.new()
	ground.color = Color(0.03, 0.03, 0.04)
	ground.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(ground)

	var media := _open_media()
	var backdrop_tex := _load_ddj(media, BACKDROP_DDJ)
	if backdrop_tex != null:
		var bg := TextureRect.new()
		bg.texture = backdrop_tex
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)
	add_child(FrontEndUi.vignette())

	# The login panel, centred a little below the middle so the backdrop art
	# reads above it.
	var panel_size := FRAME_NATIVE * FRAME_SCALE
	var panel := Control.new()
	panel.custom_minimum_size = panel_size
	panel.size = panel_size
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-panel_size.x * 0.5, -panel_size.y * 0.5 + 60.0)
	add_child(panel)

	var frame_tex := _load_ddj(media, FRAME_DDJ)
	if frame_tex != null:
		var frame := TextureRect.new()
		frame.texture = frame_tex
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_SCALE
		frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(frame)
	else:
		# No art: a plain rounded panel so the fields still have a home.
		var plate := _plate()
		plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.add_child(plate)

	server_address_edit = _slot_field(panel, panel_size, SLOT_SERVER, "Server", "127.0.0.1:15779", false)
	username_edit = _slot_field(panel, panel_size, SLOT_ID, "ID", "", false)
	password_edit = _slot_field(panel, panel_size, SLOT_PW, "PW", "", true)

	# Connect / Exit under the panel.
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 16)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.position = Vector2(0.0, panel_size.y + 14.0)
	buttons.size = Vector2(panel_size.x, 44.0)
	panel.add_child(buttons)

	login_button = _text_button("Connect", Vector2(140.0, 40.0))
	login_button.pressed.connect(_on_login_pressed)
	buttons.add_child(login_button)

	var exit_button := _text_button("Exit", Vector2(120.0, 40.0))
	exit_button.pressed.connect(func(): get_tree().quit())
	buttons.add_child(exit_button)

	# Register kept as a small link under the buttons -- the original has a
	# separate flow, but a tester needs to make an account first.
	register_button = _text_button("Register a new account", Vector2(220.0, 30.0))
	register_button.flat = true
	register_button.add_theme_font_size_override("font_size", 13)
	register_button.add_theme_color_override("font_color", Color(0.86, 0.78, 0.5))
	register_button.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.72))
	register_button.add_theme_color_override("font_outline_color", Color.BLACK)
	register_button.add_theme_constant_override("outline_size", 3)
	register_button.position = Vector2(panel_size.x * 0.5 - 110.0, panel_size.y + 62.0)
	register_button.pressed.connect(_on_register_pressed)
	panel.add_child(register_button)

	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	status_label.add_theme_color_override("font_outline_color", Color.BLACK)
	status_label.add_theme_constant_override("outline_size", 4)
	status_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	status_label.position = Vector2(0.0, -40.0)
	status_label.size = Vector2(get_viewport_rect().size.x, 30.0)
	add_child(status_label)

## One labelled input laid over a frame slot. `slot` is
## [label_x, field_x, field_right, centre_y] in frame fractions.
func _slot_field(panel: Control, panel_size: Vector2, slot: Array, label_text: String, default_text: String, secret: bool) -> LineEdit:
	var h := panel_size.y * SLOT_HEIGHT_FRAC
	var cy: float = panel_size.y * slot[3]

	var label := Label.new()
	label.text = label_text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(0.93, 0.86, 0.6))
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.position = Vector2(panel_size.x * slot[0], cy - h * 0.5)
	label.size = Vector2(panel_size.x * (slot[1] - slot[0]) - 4.0, h)
	panel.add_child(label)

	var field := LineEdit.new()
	field.text = default_text
	field.secret = secret
	field.flat = true # sit on the frame's own dark slot
	field.add_theme_color_override("font_color", Color(1, 1, 1))
	field.add_theme_color_override("font_outline_color", Color.BLACK)
	field.add_theme_constant_override("outline_size", 3)
	field.position = Vector2(panel_size.x * slot[1], cy - h * 0.5)
	field.size = Vector2(panel_size.x * (slot[2] - slot[1]), h)
	panel.add_child(field)
	return field

func _plate() -> Control:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.11, 0.96)
	style.border_color = Color(0.72, 0.6, 0.28)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", style)
	return p

func _text_button(text: String, min_size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	# Dark plate with a gold edge, to sit with the frame rather than as a
	# grey system button. A disclosed style choice, not recovered art.
	if not text.begins_with("Register"):
		b.add_theme_stylebox_override("normal", _button_style(Color(0.11, 0.10, 0.08, 0.95), Color(0.66, 0.54, 0.26)))
		b.add_theme_stylebox_override("hover", _button_style(Color(0.17, 0.15, 0.10, 0.98), Color(0.85, 0.70, 0.34)))
		b.add_theme_stylebox_override("pressed", _button_style(Color(0.08, 0.07, 0.05, 1.0), Color(0.85, 0.70, 0.34)))
		b.add_theme_stylebox_override("focus", _button_style(Color(0.11, 0.10, 0.08, 0.95), Color(0.85, 0.70, 0.34)))
		b.add_theme_color_override("font_color", Color(0.95, 0.88, 0.62))
		b.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.72))
	return b

func _button_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(4)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s

# --- Media.pk2 access ------------------------------------------------------

func _open_media() -> Pk2Reader:
	var path := Pk2Config.media_path()
	if path == "":
		return null
	return Pk2Reader.open(path)

func _load_ddj(media: Pk2Reader, ddj_path: String) -> Texture2D:
	if media == null:
		return null
	var entry := ObjectLoader.find_file(media, ddj_path)
	if entry == null:
		return null
	var parsed := DdjReader.parse(media.read_file(entry))
	if parsed == null:
		return null
	return DdjReader.to_texture(parsed)

# --- Net flow (unchanged behaviour) ----------------------------------------

func _on_login_pressed() -> void:
	_pending_action = "login"
	_connect_and_send()

func _on_register_pressed() -> void:
	_pending_action = "register"
	_connect_and_send()

func _connect_and_send() -> void:
	if NetClient.is_connected_to_server():
		_send_pending_action()
		return
	var address := _parse_server_address(server_address_edit.text)
	if address.is_empty():
		status_label.text = "Enter a valid server address, e.g. 192.168.1.23:15779"
		return
	status_label.text = "Connecting..."
	NetClient.connect_to_server(address["host"], address["port"])

## Parses "host" or "host:port" into {"host", "port"} (port defaults to
## DEFAULT_SERVER_PORT). Returns {} for an empty host or a non-numeric port.
func _parse_server_address(text: String) -> Dictionary:
	text = text.strip_edges()
	if text.is_empty():
		return {}
	var host := text
	var port := DEFAULT_SERVER_PORT
	var colon := text.rfind(":")
	if colon != -1:
		host = text.substr(0, colon)
		var port_str := text.substr(colon + 1)
		if not port_str.is_valid_int():
			return {}
		port = port_str.to_int()
	if host.is_empty():
		return {}
	return {"host": host, "port": port}

func _on_connected() -> void:
	ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_ADDRESS, server_address_edit.text.strip_edges())
	ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_USERNAME, username_edit.text)
	_send_pending_action()

func _send_pending_action() -> void:
	var username := username_edit.text
	var password := password_edit.text
	if username.is_empty() or password.is_empty():
		status_label.text = "Username and password are required."
		return
	if _pending_action == "login":
		status_label.text = "Logging in..."
		NetClient.login(username, password)
	elif _pending_action == "register":
		status_label.text = "Registering..."
		NetClient.register_account(username, password)

func _on_connection_failed() -> void:
	status_label.text = "Could not connect to server."

func _on_login_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Login OK."
		get_tree().change_scene_to_file("res://scenes/CharacterSelect.tscn")
	else:
		status_label.text = "Login failed: %s" % reason

func _on_register_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Registered - you can log in now."
	else:
		status_label.text = "Registration failed: %s" % reason
