extends Control

## Connect / login screen. Connects to the Go server and sends OpLogin /
## OpRegister via the NetClient autoload, then moves to character select on
## success.
##
## Since round 678 it is retail's title screen (CPSTitle): an intro script
## flown in 3D over the world's own regions (TitleIntro, FrontEndBackdrop),
## inside the letterbox frame built from Media.pk2's resinfo\pstitle.txt
## (FrontEndFrame), with the login window, Connect and Exit placed and faded
## in as FUN_00866760 / FUN_00865630 do -- all READ, docs/protocol/
## intro_script.md. The intro, its music and the branding are the server's
## front-end theme (FrontEndTheme, asked for at boot by ThemeQuery; OURS),
## else option.txt's. The art and text are the player's own Media.pk2's,
## loaded at runtime, never shipped.
##
## Fallbacks: no Media.pk2 (a dev run without game data) -- the plain styled
## panel below (_build_ui), so logging in always works; an intro or region
## that cannot load -- the 2D still (loading_login_01_2011.ddj) behind the
## same frame, the login window in at once, the reason in the log.
##
## The plain panel's layout constants are OURS, eyeballed against the frame
## art (288x140).
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

# --- Round 678: the 3D title (TitleIntro, FrontEndFrame, FrontEndTheme) -----

## The login window's art: READ, FUN_00866760 loads login_window_europe.ddj
## into window 9 by hand (0x8667d0, 39 chars at 0xdd8b6c), over the layout's
## own login_window.ddj.
const LOGIN_WINDOW_DDJ := "interface\\outer\\login_window_europe.ddj"
## The buttons' three states: the layout's button.ddj and its _focus/_press
## siblings in Media.pk2 (the same naming every outer button uses).
const BUTTON_STATES := ["", "_focus", "_press"]
## The labels' and buttons' text keys (READ, pstitle.txt's Text= fields):
## UIO_CTL_ID, UIO_CTL_PASSWORD, UIO_CTL_SELECT_SERVER, UIO_CTL_CONNECT,
## UIO_CTL_EXIT, looked up in textuisystem.txt.
const TEXT_TABLE_PATH := "server_dep\\silkroad\\textdata\\textuisystem.txt"
## The Login section's control IDs (READ, pstitle.txt).
const ID_STATIC_ID := 101
const ID_STATIC_PW := 102
const ID_STATIC_SERVER := 103
const ID_EDIT_ID := 41
const ID_EDIT_PASS := 42
const ID_STA_SERVER := 43

var _media: Pk2Reader = null
var _started_ms := 0
var _still: Control = null
var _frame: FrontEndFrame = null
var _title: TitleIntro = null
var _query: ThemeQuery = null
var _theme: FrontEndTheme = null
var _login_window: Control = null
var _exit_button: Button = null
var _text: UiTextTable = null
var _skip_pending := false
var _layout: UiLayoutParser.LayoutDef = null

func _ready() -> void:
	_started_ms = Time.get_ticks_msec()
	NetClient.connected.connect(_on_connected)
	NetClient.connection_failed.connect(_on_connection_failed)
	NetClient.login_result.connect(_on_login_result)
	NetClient.register_result.connect(_on_register_result)
	_media = _open_media()
	FrontEndUi.apply_client_font(self, _media)
	# Round 678: the 3D title. The server's front-end theme decides the intro,
	# its music and the branding (FrontEndTheme); ask for it first, with a
	# short deadline, and build the screen when it answers or gives up.
	# Without Media.pk2 there is no title to build: the plain screen at once.
	_layout = FrontEndFrame.load_layout(_media)
	if _media == null or _layout == null:
		_build_ui()
		_finish_ready()
		return
	# The world's scene compiles on a worker while the theme is asked for
	# and the screen is built (FrontEndBackdrop.preload_world).
	FrontEndBackdrop.preload_world()
	# The cover over the 3D while it loads (OURS): the dark ground and the 2D
	# still, faded out together once the first view is built -- and left up,
	# as the fallback, when no 3D intro can run.
	_still = Control.new()
	_still.name = "TitleCover"
	_still.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_still.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_still)
	_still.add_child(FrontEndUi.ground())
	var still_art := FrontEndUi.backdrop(_media, BACKDROP_DDJ)
	if still_art != null:
		_still.add_child(still_art)
	# The theme comes from the server this screen will connect to: the one
	# remembered from last time (or a QA run's SRREVAMP_QA_SERVER).
	var qa_server := OS.get_environment("SRREVAMP_QA_SERVER")
	var address := _parse_server_address(qa_server if qa_server != "" else _remembered_address())
	_query = ThemeQuery.new()
	_query.name = "ThemeQuery"
	add_child(_query)
	_query.finished.connect(_on_theme_answer, CONNECT_ONE_SHOT)
	_query.start(address.get("host", ""), int(address.get("port", 0)))

## Everything after the screen exists: the remembered fields, Enter to
## submit, the QA sign-in.
func _finish_ready() -> void:
	# The title music, option.txt's IntroBGM (or the theme's, round 678),
	# pushed at playlist level 0 as CPSTitle::OnCreate does (round 612,
	# READ); character select and create touch nothing, so it keeps playing
	# through them (INFERRED).
	var svc := AudioService.instance()
	if svc != null and svc.music != null:
		svc.music.play_intro(_title_music())
	# The server that last answered and the account name come back from the
	# previous run so a tester is not retyping host:port every launch.
	server_address_edit.text = _remembered_address()
	var remembered_username := ClientSettings.username()
	if remembered_username != "":
		username_edit.text = remembered_username
	# Enter submits from any field.
	for field in [username_edit, password_edit, server_address_edit]:
		field.text_submitted.connect(func(_t): _on_login_pressed())
	# SRREVAMP_QA_RECONNECT_VIA_LOGIN (round 558): a scripted reconnect that
	# takes the tester's route lands here from World3D._on_disconnected.
	# Sign back in with the QA account through the same Connect path a click
	# takes, so this screen's own work (Media.pk2, the net flow, the
	# remembered settings) runs as it does for a player; CharacterSelect
	# then starts the QA character.
	if OS.get_environment("SRREVAMP_QA_RECONNECT_VIA_LOGIN") != "":
		if _title != null:
			_title.skip("SRREVAMP_QA_RECONNECT_VIA_LOGIN")
		_qa_sign_in()

func _remembered_address() -> String:
	var remembered := ClientSettings.server_address()
	return remembered if remembered != "" else "127.0.0.1:%d" % DEFAULT_SERVER_PORT

## SRREVAMP_QA_RECONNECT_VIA_LOGIN: fill the fields from the QA environment
## (SRREVAMP_QA_SERVER; the account QaSignIn reads) and press Connect. Says
## why when it cannot, so a run that stalls on this screen says so in its
## log rather than in a status label no log carries.
func _qa_sign_in() -> void:
	var target := OS.get_environment("SRREVAMP_QA_SERVER")
	if target == "":
		printerr("QA RECONNECT: Login has no SRREVAMP_QA_SERVER to sign in to -- staying on the login screen")
		return
	var credentials := QaSignIn.account_credentials()
	server_address_edit.text = target
	username_edit.text = credentials[0]
	password_edit.text = credentials[1]
	print("QA RECONNECT: Login signing in to %s as %s at frame %d" % [target, credentials[0], Engine.get_frames_drawn()])
	_on_login_pressed()

## Under SRREVAMP_QA_RECONNECT_VIA_LOGIN the status label's text also goes
## to the log, which is all a scripted run can read.
func _qa_report(text: String) -> void:
	if OS.get_environment("SRREVAMP_QA_RECONNECT_VIA_LOGIN") != "":
		print("QA RECONNECT: Login: %s" % text)

# --- The 3D title (round 678) ---------------------------------------------

## The theme query finished (answered, refused or timed out): settle the
## theme, build the screen from the archive's own layout and art, and start
## the intro.
func _on_theme_answer(server_theme: FrontEndTheme, why: String) -> void:
	var warnings := PackedStringArray()
	var preview := FrontEndTheme.from_environment(warnings)
	var custom_dir := FrontEndTheme.custom_dir()
	var custom := FrontEndTheme.from_custom_folder(custom_dir, warnings)
	var cached: FrontEndTheme = null
	if server_theme != null:
		FrontEndTheme.store_cache(server_theme)
	else:
		cached = FrontEndTheme.cached()
	for w in warnings:
		print("FrontEnd: theme: %s" % w)
	_theme = FrontEndTheme.resolve(preview, server_theme, cached, custom)
	print("FrontEnd: server theme %s (%s at %d ms); theme: %s" % [
		"answered" if server_theme != null else "not used", why,
		Time.get_ticks_msec() - _started_ms, _theme.describe()])
	_build_title_ui(custom_dir)
	_title = TitleIntro.new()
	_title.name = "TitleIntro"
	add_child(_title)
	# Below every control: the 3D draws under the 2D canvas anyway, and the
	# intro node holds no Control.
	move_child(_title, 0)
	_title.login_shown.connect(_on_title_login_shown)
	_title.start(_media, _theme, custom_dir, _frame, _still, [_frame.logo, _login_window, login_button, _exit_button, register_button])
	print("LOGIN: screen built at %d ms" % (Time.get_ticks_msec() - _started_ms))
	_finish_ready()
	if _skip_pending:
		_title.skip("a click or key while the theme was asked for")

func _title_music() -> String:
	if _theme == null or _theme.bgm == "":
		return ""
	if not AudioBank.has_file(_theme.bgm):
		print("FrontEnd: title music '%s' is not in the archives -- option.txt's IntroBGM" % _theme.bgm)
		return ""
	return _theme.bgm

## The letterbox frame and the login window, from pstitle.txt and the
## archive's art (FrontEndFrame has the READ layout).
func _build_title_ui(custom_dir: String) -> void:
	_text = _load_text_table()
	_frame = FrontEndFrame.new()
	_frame.name = "FrontEndFrame"
	add_child(_frame)
	_frame.build(_media, _theme, custom_dir, "Ver %s" % UpdateChecker.CLIENT_VERSION.trim_prefix("v"), _layout)

	_login_window = Control.new()
	_login_window.name = "LoginWindow"
	_login_window.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var win_def := _frame.def(FrontEndFrame.ID_LOGINWINDOW)
	_login_window.size = Vector2(win_def.rect.size) if win_def != null else Vector2(288, 140)
	add_child(_login_window)
	var art := TextureRect.new()
	art.texture = FrontEndUi.load_ddj(_media, LOGIN_WINDOW_DDJ)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_login_window.add_child(art)
	_login_label(ID_STATIC_ID, "ID")
	_login_label(ID_STATIC_PW, "PW")
	_login_label(ID_STATIC_SERVER, "Server")
	username_edit = _login_edit(ID_EDIT_ID, false)
	password_edit = _login_edit(ID_EDIT_PASS, true)
	# OURS: the server slot takes a typed host:port (this client has no
	# server list; retail shows the chosen server's name here and opens its
	# list with the LIST button, GDR_BTN_SERVER, which is left out).
	server_address_edit = _login_edit(ID_STA_SERVER, false)
	server_address_edit.placeholder_text = "host:port"

	login_button = _art_button(_frame.def(FrontEndFrame.ID_OK), "UIO_CTL_CONNECT", "Connect")
	login_button.pressed.connect(_on_login_pressed)
	add_child(login_button)
	_exit_button = _art_button(_frame.def(FrontEndFrame.ID_CANCEL), "UIO_CTL_EXIT", "Exit")
	_exit_button.pressed.connect(func(): get_tree().quit())
	add_child(_exit_button)

	# OURS: account creation for testers (retail has no such link), small,
	# under the buttons.
	register_button = Button.new()
	register_button.text = "Register a new account"
	register_button.flat = true
	register_button.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[0])
	register_button.add_theme_color_override("font_color", Color(0.86, 0.78, 0.5))
	register_button.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.72))
	register_button.pressed.connect(_on_register_pressed)
	add_child(register_button)

	# OURS: the status line (the client's own errors go through a message
	# box; this screen keeps its one line of text).
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	status_label.add_theme_color_override("font_outline_color", Color.BLACK)
	status_label.add_theme_constant_override("outline_size", 3)
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status_label)
	_frame.resized.connect(_layout_login_window)
	_layout_login_window()

## READ, FUN_00866760: around the screen's middle column cx = width >> 1 and
## the line midway between the bands (FrontEndFrame.centre_line), the login
## window at (cx - 0x90, mid + 6), Connect at (cx - 100, mid + 0x9c) and
## Exit at (cx + 9, mid + 0x9c) -- in pixels, unscaled.
func _layout_login_window() -> void:
	if _frame == null or _login_window == null:
		return
	var c := _frame.centre_line()
	_login_window.position = Vector2(c.x - 0x90, c.y + 6)
	login_button.position = Vector2(c.x - 100, c.y + 0x9c)
	_exit_button.position = Vector2(c.x + 9, c.y + 0x9c)
	var below := login_button.position.y + login_button.size.y
	register_button.size = Vector2(220, 22)
	register_button.position = Vector2(c.x - 110, below + 6)
	status_label.size = Vector2(_frame.size.x, 22)
	status_label.position = Vector2(0, below + 30)

func _login_label(id: int, fallback: String) -> void:
	var d := _frame.login_def(id)
	if d == null:
		return
	var label := Label.new()
	label.text = _text_for(d.text, fallback)
	label.position = Vector2(d.rect.position)
	label.size = Vector2(d.rect.size)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", _font_size(d.font_index))
	label.add_theme_color_override("font_color", d.font_color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_login_window.add_child(label)

func _login_edit(id: int, secret: bool) -> LineEdit:
	var d := _frame.login_def(id)
	var field := LineEdit.new()
	field.secret = secret
	field.flat = true # on the frame's own dark slot
	field.add_theme_font_size_override("font_size", _font_size(d.font_index if d != null else 0))
	field.add_theme_color_override("font_color", d.font_color if d != null else Color.WHITE)
	field.add_theme_constant_override("minimum_character_width", 1)
	var empty := StyleBoxEmpty.new()
	for sb in ["normal", "focus", "read_only"]:
		field.add_theme_stylebox_override(sb, empty)
	if d != null:
		field.position = Vector2(d.rect.position)
		field.size = Vector2(d.rect.size)
	field.custom_minimum_size = Vector2.ZERO
	_login_window.add_child(field)
	return field

func _art_button(d: UiLayoutParser.ControlDef, text_key: String, fallback: String) -> Button:
	var b := Button.new()
	b.text = _text_for(text_key, fallback)
	b.size = Vector2(d.rect.size) if d != null else Vector2(91, 41)
	b.custom_minimum_size = b.size
	b.add_theme_font_size_override("font_size", _font_size(d.font_index if d != null else 0))
	b.add_theme_color_override("font_color", d.font_color if d != null else Color.WHITE)
	var base := d.ddj if d != null and d.ddj != "" else "interface\\outer\\button.ddj"
	var styles := ["normal", "hover", "pressed"]
	for i in range(BUTTON_STATES.size()):
		var path: String = base.get_basename() + str(BUTTON_STATES[i]) + ".ddj"
		var tex := FrontEndUi.load_ddj(_media, path)
		if tex == null:
			continue
		var sb := StyleBoxTexture.new()
		sb.texture = tex
		b.add_theme_stylebox_override(styles[i], sb)
		if i == 1:
			b.add_theme_stylebox_override("focus", sb)
	return b

func _font_size(index: int) -> int:
	return UiBuilder.FONT_SIZES[clampi(index, 0, UiBuilder.FONT_SIZES.size() - 1)]

func _text_for(key: String, fallback: String) -> String:
	if _text != null and key != "" and _text.has(key):
		var t := _text.get_text(key, fallback)
		if t != "":
			return t
	return fallback

func _load_text_table() -> UiTextTable:
	if _media == null:
		return null
	var entry := ObjectLoader.find_file(_media, TEXT_TABLE_PATH)
	if entry == null:
		return null
	var sw := Time.get_ticks_msec()
	var table := UiTextTable.parse(_media.read_file(entry))
	print("LOGIN: text table read in %d ms" % (Time.get_ticks_msec() - sw))
	return table

func _on_title_login_shown() -> void:
	print("LOGIN: usable at %d ms" % (Time.get_ticks_msec() - _started_ms))
	if username_edit != null and username_edit.is_inside_tree():
		if username_edit.text == "":
			username_edit.grab_focus()
		else:
			password_edit.grab_focus()

## READ: a left button press (CPSTitle::vslot_017, message 0x201) or any key
## (FUN_0086ae50) while the login window is not up brings it in at once.
## The press or key is used up by the skip (OURS: retail's key handler goes
## on to treat Tab and Enter).
func _input(event: InputEvent) -> void:
	var press := (event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT) \
			or (event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo)
	if _title == null and _query != null and press:
		# Still asking for the theme (at most ThemeQuery.TIMEOUT_MS): the
		# player wants the login now, so stop waiting -- the cached answer
		# (else custom/theme.json, else retail's defaults) stands in, OURS --
		# and the skip is applied as the title starts.
		_skip_pending = true
		get_viewport().set_input_as_handled()
		_query.abandon("the player clicked through")
		return
	if _title == null or _title.login_up:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_title.skip("a click")
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		_title.skip("a key")
		get_viewport().set_input_as_handled()

# --- Building the screen ---------------------------------------------------

func _build_ui() -> void:
	# A dark ground under everything, so a missing backdrop is black, not the
	# host's theme.
	var ground := ColorRect.new()
	ground.color = Color(0.03, 0.03, 0.04)
	ground.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(ground)

	var media := _media
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
	_qa_report(status_label.text)
	# The front-end message box sounds snd_error (0x8613b0, read); that the
	# title screen's refusals go through it is inferred (UiSounds.error_box).
	UiSounds.error_box("login screen: no connection")

func _on_login_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Login OK."
		_qa_report(status_label.text)
		get_tree().change_scene_to_file("res://scenes/CharacterSelect.tscn")
	else:
		status_label.text = "Login failed: %s" % reason
		_qa_report(status_label.text)
		UiSounds.error_box("login screen: login refused")

func _on_register_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Registered - you can log in now."
	else:
		status_label.text = "Registration failed: %s" % reason
		UiSounds.error_box("login screen: registration refused")
