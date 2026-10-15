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
## The server (round 679): when setting/config.yaml lists servers
## (ClientConfig), the Server field shows the chosen one's name, read-only,
## and the LIST button opens the server list (ServerListWindow) with each
## server's status; the last choice is remembered. Without a list the field
## is a typed host:port, so a friend on the same LAN can point at the host's
## real IP (e.g. "192.168.1.23:15779"); it defaults to 127.0.0.1:15779 and is
## remembered (ClientSettings) between runs. The password never is.

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
## GDR_BTN_SERVER, the LIST button (READ, pstitle.txt: 203,86 48x24,
## list_button.ddj, which carries the word in its art).
const ID_BTN_SERVER := 44
## The password field's mask (READ: see _login_edit).
const PASSWORD_CHAR := "*"
## Round 788: the message line, window 500 (READ, pstitle.txt Title), and its
## FontColor 255,255,103,29 for a layout without it.
const ID_MESSAGE := 500
const MESSAGE_COLOR := Color8(255, 103, 29)

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
## The address the theme was asked of (the cache is kept per address).
var _theme_address := ""
## setting/config.yaml (round 679): never null once _ready has run.
var _config: ClientConfig = null
## The chosen server when the config lists servers, else null (the typed
## host:port field).
var _selected: ClientConfig.ServerEntry = null
## OPENSRO_QA_SERVER's address, which a QA run connects to whatever the
## config lists.
var _address_override := ""
var _list_button: Button = null
var _server_list: ServerListWindow = null
## What the open server list hid (_set_login_visible).
var _hidden_for_list: Array = []

# --- Round 788: logging in as the original does --------------------------------

## READ (Connect handler 0x8688f0): a press while this is above 0 does
## nothing; a press that goes on to send sets it to 3.0 s (0xd8adc4), and
## the title's per-frame slot (0x8692b5) counts it down.
const SUBMIT_LOCK_S := 3.0
var _lock := 0.0
## READ (0x862410 / 0x8622a0): while the login request is answered the whole
## title takes no input (CGWnd+0x62 = 0); any 0xA102 gives it back
## (0x86c08c); after a success it stays off until character select.
var _busy := false
var _blocker: Control = null
## READ (0x8613b0): the message line's text clears after 15 s (timer 1000).
const MESSAGE_CLEAR_S := 15.0
var _message_left := 0.0
## The legacy path (RetailLogin), its image-code window and the drop box.
var _retail: RetailLogin = null
var _captcha: CaptchaWindow = null
var _netoff: NetOffBox = null
## Round 788 (OURS): the shard row chosen in the list for a legacy server, by
## name (RetailGatewayClient.pick_shard matches it).
var _shard_name := ""
## The archive's content id and version (RetailClientInfo), read once.
var _client_info := {}
## Set while this screen closes a connection itself: no drop box for it.
var _closing_ourselves := false
## OURS: the remembered shard row (ClientSettings' server section).
const KEY_SHARD_NAME := "shard_name"

func _ready() -> void:
	_started_ms = Time.get_ticks_msec()
	NetClient.connected.connect(_on_connected)
	NetClient.connection_failed.connect(_on_connection_failed)
	NetClient.login_result.connect(_on_login_result)
	NetClient.gateway_login_result.connect(_on_gateway_login_result)
	NetClient.register_result.connect(_on_register_result)
	NetClient.disconnected.connect(_on_net_disconnected)
	# Round 678: the 3D title. The server's front-end theme decides the intro,
	# its music and the branding (FrontEndTheme). The question goes out first
	# (round 678's review), so its round trip overlaps the archive work
	# below; the screen is built when it answers or gives up.
	# The theme comes from the server this screen will connect to: the one
	# remembered from last time (or a QA run's OPENSRO_QA_SERVER).
	_load_config()
	var qa_server := OS.get_environment("OPENSRO_QA_SERVER")
	_theme_address = (qa_server if qa_server != "" else _target_address()).strip_edges()
	var address := _parse_server_address(_theme_address)
	_query = ThemeQuery.new()
	_query.name = "ThemeQuery"
	add_child(_query)
	# Round 681: a `type: legacy` server speaks only the original protocol,
	# so it is never sent this project's own theme question (0x0005).
	if qa_server == "" and _address_override == "" and _selected != null and _selected.type == ServerStatus.TYPE_LEGACY:
		print("SETTING: '%s' is a legacy server -- no theme question" % _selected.name)
		address = {}
	_query.start(address.get("host", ""), int(address.get("port", 0)))
	_media = _open_media()
	FrontEndUi.apply_client_font(self, _media)
	# Without Media.pk2 and its title layout there is no title to build: the
	# plain screen at once.
	_layout = FrontEndFrame.load_layout(_media)
	if _media == null or _layout == null or not _layout.sections.has("Title") or not _layout.sections.has("Login"):
		_query.abandon("no title layout to build")
		_query = null
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
	if _query.is_done():
		_on_theme_answer(_query.result_theme, _query.result_why)
	else:
		_query.finished.connect(_on_theme_answer, CONNECT_ONE_SHOT)

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
	# A listed server's name, read-only (LIST chooses another); else the
	# server that last answered, so a tester is not retyping host:port every
	# launch, with the account name.
	show_server_field(server_address_edit, _selected, _remembered_address())
	_show_selected_server()
	if _selected == null:
		server_address_edit.text_changed.connect(func(t: String) -> void: server_address_edit.tooltip_text = t)
	var remembered_username := ClientSettings.username()
	if remembered_username != "":
		username_edit.text = remembered_username
	# Enter submits from any field.
	for field in [username_edit, password_edit, server_address_edit]:
		field.text_submitted.connect(func(_t): _on_login_pressed())
	_set_tab_order()
	# OPENSRO_QA_RECONNECT_VIA_LOGIN (round 558): a scripted reconnect that
	# takes the tester's route lands here from World3D._on_disconnected.
	# Sign back in with the QA account through the same Connect path a click
	# takes, so this screen's own work (Media.pk2, the net flow, the
	# remembered settings) runs as it does for a player; CharacterSelect
	# then starts the QA character.
	if OS.get_environment("OPENSRO_QA_RECONNECT_VIA_LOGIN") != "":
		if _title != null:
			_title.skip("OPENSRO_QA_RECONNECT_VIA_LOGIN")
		_qa_sign_in()

func _remembered_address() -> String:
	var remembered := ClientSettings.server_address()
	return remembered if remembered != "" else "127.0.0.1:%d" % DEFAULT_SERVER_PORT

## Tab moves between the ID and password fields only, as retail's does
## (round 679's review) -- and the server field when it is a typed host:port;
## LIST, Connect, Exit and the register link take no keyboard focus, so
## Enter in a field always submits.
func _set_tab_order() -> void:
	var cycle: Array = [username_edit, password_edit]
	if server_address_edit != null and server_address_edit.editable:
		cycle.append(server_address_edit)
	for i in range(cycle.size()):
		var a: Control = cycle[i]
		var b: Control = cycle[(i + 1) % cycle.size()]
		a.focus_next = a.get_path_to(b)
		b.focus_previous = b.get_path_to(a)
	for b in [login_button, _exit_button, register_button, _list_button]:
		if b != null:
			(b as Control).focus_mode = Control.FOCUS_NONE

## The field a returning player types into: the password when the ID is
## filled, else the ID.
func _focus_first_empty() -> void:
	if username_edit == null or not username_edit.is_inside_tree() or not username_edit.is_visible_in_tree():
		return
	if username_edit.text == "":
		username_edit.grab_focus()
	else:
		password_edit.grab_focus()

## setting/config.yaml, and the server it starts on (round 679).
func _load_config() -> void:
	var warnings := PackedStringArray()
	_config = ClientConfig.load_default(warnings)
	for w in warnings:
		print("SETTING: %s" % w)
	print("SETTING: %s %s" % [ClientConfig.config_path() if _config.source != "" else "no " + ClientConfig.config_path(), _config.describe()])
	_selected = _config.pick_server(ClientSettings.server_name())
	if _selected != null and _selected.type == ServerStatus.TYPE_LEGACY:
		_shard_name = str(ClientSettings.get_value(ClientSettings.SECTION_SERVER, KEY_SHARD_NAME, ""))

## The address Connect goes to (and the theme is asked of): the QA
## override, else the chosen listed server's gateway, else the typed field
## (before the screen exists, the remembered address).
func _target_address() -> String:
	if _address_override != "":
		return _address_override
	if _selected != null:
		return _selected.gateway_address()
	if server_address_edit != null:
		return server_address_edit.text
	return _remembered_address()

## The chosen server's name in the Server field (round 679): centred and
## read-only like retail's GDR_STA_SERVER static, the address as its tooltip.
func _show_selected_server() -> void:
	if server_address_edit != null and _selected != null:
		show_server_field(server_address_edit, _selected, "")
		# Round 788: a legacy server's chosen shard as its list row reads.
		if _shard_name != "" and _shard_name != _selected.name:
			server_address_edit.text = "%s - %s" % [_selected.name, _shard_name]

## LIST (GDR_BTN_SERVER): the server list, with each server's status.
func _open_server_list() -> void:
	if _config == null or not _config.has_servers():
		return
	if _server_list != null and is_instance_valid(_server_list):
		_server_list.refresh_now()
		return
	_server_list = ServerListWindow.new()
	_server_list.name = "ServerListWindow"
	add_child(_server_list)
	_server_list.chosen.connect(_on_server_chosen)
	_server_list.closed.connect(_on_server_list_closed)
	_server_list.open(_media, _frame, _text, _config.servers, _selected)
	if _title != null:
		_title.logo_held = true
	_set_login_visible(false)

func _on_server_chosen(entry: ClientConfig.ServerEntry) -> void:
	# Round 681's review: a connection left open to the server chosen before
	# (a failed login keeps it) must not carry the next login elsewhere.
	var shard: String = _server_list.chosen_shard_name if _server_list != null and is_instance_valid(_server_list) else ""
	if entry != _selected and NetClient.is_connected_to_server():
		print("LOGIN: server changed -- closing the connection to %s:%d" % [NetClient.server_host, NetClient.server_port])
		_close_quietly()
	if _retail != null and (entry != _selected or shard != _shard_name):
		_retail.cancel()
	_selected = entry
	_shard_name = shard
	_show_selected_server()
	ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_SERVER_NAME, entry.name)
	ClientSettings.set_value(ClientSettings.SECTION_SERVER, KEY_SHARD_NAME, shard)
	print("LOGIN: server '%s' chosen (%s)" % [entry.name, entry.gateway_address()])

func _on_server_list_closed() -> void:
	_server_list = null
	_set_login_visible(true)
	# A reveal of the logo that came due while the list was open (round
	# 679's review).
	if _title != null:
		_title.release_logo()
	# The fields again take the keys (round 679's review).
	_focus_first_empty.call_deferred()

## The logo, login window, Connect and Exit while the server list is up:
## READ, LIST's FUN_00864870(1, 0) fades windows 8, 9, 11 and 12 out as it
## fades the list in, and Cancel/Select the reverse (the 0.5 s fades are
## left out, OURS).
## Only what was showing is hidden, and only that is shown again (the
## archive's logo stays held back over the 2D still, round 678's L2).
func _set_login_visible(on: bool) -> void:
	if not on:
		_hidden_for_list.clear()
		for n in [_login_window, login_button, _exit_button, register_button, _frame.logo if _frame != null else null]:
			if n != null and (n as CanvasItem).visible:
				(n as CanvasItem).visible = false
				_hidden_for_list.append(n)
		return
	for n in _hidden_for_list:
		if is_instance_valid(n):
			(n as CanvasItem).visible = true
	_hidden_for_list.clear()

## OPENSRO_QA_RECONNECT_VIA_LOGIN: fill the fields from the QA environment
## (OPENSRO_QA_SERVER; the account QaSignIn reads) and press Connect. Says
## why when it cannot, so a run that stalls on this screen says so in its
## log rather than in a status label no log carries.
func _qa_sign_in() -> void:
	var target := OS.get_environment("OPENSRO_QA_SERVER")
	if target == "":
		printerr("QA RECONNECT: Login has no OPENSRO_QA_SERVER to sign in to -- staying on the login screen")
		return
	var credentials := QaSignIn.account_credentials()
	_address_override = target
	if _selected == null:
		server_address_edit.text = target
	username_edit.text = credentials[0]
	password_edit.text = credentials[1]
	print("QA RECONNECT: Login signing in to %s as %s at frame %d" % [target, credentials[0], Engine.get_frames_drawn()])
	_on_login_pressed()

## Under OPENSRO_QA_RECONNECT_VIA_LOGIN the status label's text also goes
## to the log, which is all a scripted run can read.
func _qa_report(text: String) -> void:
	if OS.get_environment("OPENSRO_QA_RECONNECT_VIA_LOGIN") != "":
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
		FrontEndTheme.store_cache(server_theme, _theme_address)
	else:
		cached = FrontEndTheme.cached(_theme_address)
	for w in warnings:
		print("FrontEnd: theme: %s" % w)
	_theme = FrontEndTheme.resolve(preview, server_theme, cached, custom, _config.to_theme() if _config != null else null)
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
	server_address_edit = _login_edit(ID_STA_SERVER, false)
	if _selected != null:
		# Round 679: a listed server's name, read-only (retail's
		# GDR_STA_SERVER is a static), and the LIST button beside it.
		show_server_field(server_address_edit, _selected, "")
		_list_button = _art_button(_frame.login_def(ID_BTN_SERVER), "", "")
		_list_button.name = "ListButton"
		var lb := _frame.login_def(ID_BTN_SERVER)
		if lb != null:
			_list_button.position = Vector2(lb.rect.position)
		_list_button.pressed.connect(_open_server_list)
		_login_window.add_child(_list_button)
	else:
		# OURS: no list in setting/config.yaml -- the slot takes a typed
		# host:port, and the LIST button is left out.
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

	# Round 788, READ: the message line, window 500 (pstitle.txt's
	# GDR_TEXT_MESSAGE, a CIFTextBox: HAlign 0, FontColor 255,255,103,29),
	# where every title message goes (0x8613b0, _say); placed by
	# FUN_00866760 (FrontEndFrame.message_rect).
	status_label = Label.new()
	status_label.name = "MessageLine"
	var msg_def := _frame.def(ID_MESSAGE)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", _font_size(msg_def.font_index if msg_def != null else 0))
	status_label.add_theme_color_override("font_color", msg_def.font_color if msg_def != null else MESSAGE_COLOR)
	status_label.add_theme_color_override("font_outline_color", Color.BLACK)
	status_label.add_theme_constant_override("outline_size", 3)
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status_label)
	_show_cursor_hint()
	_frame.resized.connect(_layout_login_window)
	_layout_login_window()

## READ, FUN_00866760: around the screen's middle column cx = width >> 1 and
## the line midway between the bands (FrontEndFrame.centre_line), the login
## window at (cx - 0x90, mid + 6), Connect at (cx - 100, mid + 0x9c) and
## Exit at (cx + 9, mid + 0x9c) -- in pixels, unscaled.
## Round 700: without the game's cursors (no readable sro_client.exe), the
## status line says where to put it -- the log alone left a tester on
## Windows with the system arrow and no reason (GameCursor.missing_hint).
## The next connection message replaces it.
func _show_cursor_hint() -> void:
	GameCursor.load_once()
	var hint := GameCursor.missing_hint()
	if hint != "" and status_label != null and status_label.text == "":
		status_label.text = hint

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
	var mr := _frame.message_rect()
	status_label.position = mr.position
	status_label.size = mr.size
	if _blocker != null:
		_blocker.size = _frame.size

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

## The ID, password and server slots. READ (pstitle.txt's Login section):
## GDR_EDIT_ID, GDR_EDIT_PASS and GDR_STA_SERVER all carry HAlign=1, centred
## text -- the layout parser's own 0 = left, 1 = centre, 2 = right -- where
## the labels carry 0; the password field masks with PASSWORD_CHAR.
func _login_edit(id: int, secret: bool) -> LineEdit:
	var field := LineEdit.new()
	KeyInput.line_edit_as_42(field)  # round 754
	style_login_edit(field, _frame.login_def(id), secret, _login_window)
	return field

## One slot's field from its layout control (null: centred, font 0), added
## to `parent` (when given) BEFORE it is sized: outside the tree a Control's
## size is clamped to the default theme's minimum, and the 20-tall slots came
## out 31 tall with their text 5.5 low (round 679's review). Retail centres the
## text vertically too (VAlign=1 on 41/42/43; FUN_00637b70, top + (h -
## textHeight) * 0.5), which a LineEdit does in its own height.
static func style_login_edit(field: LineEdit, d: UiLayoutParser.ControlDef, secret: bool, parent: Node = null) -> void:
	field.secret = secret
	field.secret_character = PASSWORD_CHAR
	field.alignment = _h_alignment(d.halign if d != null else 1)
	field.flat = true # on the frame's own dark slot
	field.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[clampi(d.font_index if d != null else 0, 0, UiBuilder.FONT_SIZES.size() - 1)])
	field.add_theme_color_override("font_color", d.font_color if d != null else Color.WHITE)
	field.add_theme_constant_override("minimum_character_width", 1)
	var empty := StyleBoxEmpty.new()
	for sb in ["normal", "focus", "read_only"]:
		field.add_theme_stylebox_override(sb, empty)
	field.custom_minimum_size = Vector2.ZERO
	if parent != null:
		parent.add_child(field)
	if d != null:
		field.position = Vector2(d.rect.position)
		field.size = Vector2(d.rect.size)

## What the Server field shows (round 679): a listed server's name, centred
## and read-only like retail's GDR_STA_SERVER static, with its address as the
## tooltip; or, without a list, the typed host:port, editable. Retail's slot
## is 86 px (READ); a host:port longer than it scrolls -- shown from its end,
## so the port is in view, with the whole address as the tooltip (round
## 678's review, OURS).
static func show_server_field(field: LineEdit, entry: ClientConfig.ServerEntry, address: String) -> void:
	if entry != null:
		field.text = entry.name
		_make_read_only(field)
		field.tooltip_text = entry.gateway_address()
		field.caret_column = 0
		return
	field.editable = true
	field.focus_mode = Control.FOCUS_ALL
	field.text = address
	field.caret_column = field.text.length()
	field.tooltip_text = address

static func _h_alignment(halign: int) -> HorizontalAlignment:
	match halign:
		1:
			return HORIZONTAL_ALIGNMENT_CENTER
		2:
			return HORIZONTAL_ALIGNMENT_RIGHT
	return HORIZONTAL_ALIGNMENT_LEFT

## A field that shows a value and cannot be typed into or focused.
static func _make_read_only(field: LineEdit) -> void:
	field.editable = false
	field.focus_mode = Control.FOCUS_NONE
	field.context_menu_enabled = false
	field.selecting_enabled = false
	field.mouse_default_cursor_shape = Control.CURSOR_ARROW
	# Read-only keeps the font colour (Godot greys it by default).
	field.add_theme_color_override("font_uneditable_color", field.get_theme_color("font_color"))

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
	_focus_first_empty()

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
	# The plain panel is this screen's login window (the server list hides it).
	_login_window = panel

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
	if _selected != null:
		# Round 679: the listed server's name and a plain List button (no
		# archive art without Media.pk2).
		show_server_field(server_address_edit, _selected, "")
		_list_button = _text_button("List", Vector2(0, 0))
		_list_button.name = "ListButton"
		_list_button.add_theme_font_size_override("font_size", 13)
		var h := panel_size.y * SLOT_HEIGHT_FRAC
		_list_button.position = Vector2(panel_size.x * (SLOT_SERVER[2] + 0.02), panel_size.y * SLOT_SERVER[3] - h * 0.5)
		_list_button.size = Vector2(panel_size.x * 0.12, h)
		_list_button.pressed.connect(_open_server_list)
		panel.add_child(_list_button)
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
	_show_cursor_hint()

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
	panel.add_child(label) # before sizing (round 679's review)
	label.position = Vector2(panel_size.x * slot[0], cy - h * 0.5)
	label.size = Vector2(panel_size.x * (slot[1] - slot[0]) - 4.0, h)

	var field := LineEdit.new()
	KeyInput.line_edit_as_42(field)  # round 754
	field.text = default_text
	field.secret = secret
	field.secret_character = PASSWORD_CHAR
	field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	field.flat = true # sit on the frame's own dark slot
	field.add_theme_color_override("font_color", Color(1, 1, 1))
	field.add_theme_color_override("font_outline_color", Color.BLACK)
	field.add_theme_constant_override("outline_size", 3)
	panel.add_child(field) # before sizing (round 679's review)
	field.position = Vector2(panel_size.x * slot[1], cy - h * 0.5)
	field.size = Vector2(panel_size.x * (slot[2] - slot[1]), h)
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

# --- Net flow (round 788: the original's login) --------------------------------
#
# READ (RESEARCH section 1 of round 788; docs/protocol/opcodes/login.md):
# Connect (button 11 or Enter, 0x869460 -> 0x8688f0) with an empty ID, an
# empty password or no server sends nothing and says nothing; a press inside
# the 3.0 s lock is ignored; otherwise UIO_MSG_ERROR_CITATION goes to the
# message line, the title stops taking input, and 0x6102 goes out. The
# answer's text goes to the same line (LoginMessages); a connection the
# server closes is the NETOFF box (NetOffBox), whose Confirm quits.
#
# OpenSRO's own server gets 0x6102 on this project's framing (NetClient.
# gateway_login) and answers 0xA102 on it; a `type: legacy` server is
# logged in to the original way (RetailLogin), image code included, and the
# select screen then talks to its agent (NetClient.attach_retail).

func _process(delta: float) -> void:
	# READ (0x8692b5): the lock counts down every frame, unconditionally.
	_lock -= delta
	if _message_left > 0.0:
		_message_left -= delta
		if _message_left <= 0.0 and status_label != null:
			status_label.text = ""

## The message line (READ 0x8613b0): the text replaces the last, snd_error
## plays, and it clears after 15 s. Every message goes to the log too, which
## is what a scripted run reads.
func _say(text: String) -> void:
	print("LOGIN MESSAGE: %s" % text.c_escape())
	if text == "":
		return
	if status_label != null:
		status_label.text = text
	_message_left = MESSAGE_CLEAR_S
	UiSounds.error_box("login screen: %s" % text.left(40))
	_qa_report(text)

## OURS lines (the register link, the typed address): no sound, no timer.
func _note(text: String) -> void:
	print("LOGIN: %s" % text)
	if status_label != null:
		status_label.text = text
	_qa_report(text)

## READ (0x862410): while a request is answered the title takes no input.
## OURS: a full-screen catcher over the title's controls (the image-code
## window and the drop box sit above it), and the fields let go of the keys.
func _set_busy(on: bool) -> void:
	_busy = on
	if _blocker == null:
		_blocker = Control.new()
		_blocker.name = "BusyBlocker"
		_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
		_blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_blocker.z_index = 40
		add_child(_blocker)
	_blocker.visible = on
	if on:
		var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
		if f != null and (f == username_edit or f == password_edit or f == server_address_edit):
			f.release_focus()
	else:
		_focus_first_empty()

## Whether Connect may go on (READ 0x8688f0): not during the lock or while a
## request is answered; an empty ID or password, or no server, stops it
## silently.
static func connect_allowed(lock: float, busy: bool, username: String, password: String, has_server: bool) -> bool:
	if lock > 0.0 or busy:
		return false
	return username != "" and password != "" and has_server

func _on_login_pressed() -> void:
	var legacy := _is_legacy()
	var has_server := legacy or not _target_address().strip_edges().is_empty()
	if not connect_allowed(_lock, _busy, username_edit.text, password_edit.text, has_server):
		print("LOGIN: Connect -- nothing sent (lock %.2f s, busy %s, ID %s, password %s, server %s)" % [
			maxf(_lock, 0.0), _busy, "set" if username_edit.text != "" else "empty",
			"set" if password_edit.text != "" else "empty", "set" if has_server else "none"])
		return
	_pending_action = "login"
	_lock = SUBMIT_LOCK_S
	if legacy:
		_login_legacy()
		return
	_connect_and_send()

## OURS (the register link): kept as it was, on this project's own wire.
func _on_register_pressed() -> void:
	if _busy:
		return
	if username_edit.text.is_empty() or password_edit.text.is_empty():
		_note("Username and password are required.")
		return
	_pending_action = "register"
	_connect_and_send()

func _is_legacy() -> bool:
	return _address_override == "" and _selected != null and _selected.type == ServerStatus.TYPE_LEGACY

## Round 681's review: a live connection carries a login only when it is to
## the server the field shows -- not to a server chosen before, and never
## when the shown one is a legacy server.
static func connection_serves(connected: bool, conn_host: String, conn_port: int, target: Dictionary, target_legacy: bool) -> bool:
	if not connected or target_legacy or target.is_empty():
		return false
	return conn_host == str(target.get("host", "")) and conn_port == int(target.get("port", 0))

## Closes NetClient's connection without the drop box (this screen's own
## doing).
func _close_quietly() -> void:
	_closing_ourselves = true
	NetClient.disconnect_from_server()
	_closing_ourselves = false

func _connect_and_send() -> void:
	var legacy := _is_legacy()
	if NetClient.is_connected_to_server():
		if connection_serves(not NetClient.is_retail(), NetClient.server_host, NetClient.server_port, _parse_server_address(_target_address()), legacy):
			_send_pending_action()
			return
		print("LOGIN: connected to %s:%d, not the server shown -- closing it" % [NetClient.server_host, NetClient.server_port])
		_close_quietly()
	# A legacy server is never sent this project's own messages (round 681):
	# its login is _login_legacy's, and registering there is not ours to do.
	if legacy:
		print("LOGIN: '%s' is a legacy server -- nothing sent on this project's wire" % _selected.name)
		if _pending_action == "register":
			_note("'%s' speaks the original protocol: accounts are made on its own site." % _selected.name)
		return
	var address := _parse_server_address(_target_address())
	if address.is_empty():
		# OURS: retail has no typed address; one that does not parse says so.
		_note("Enter a valid server address, e.g. 192.168.1.23:15779")
		return
	if _server_list != null and is_instance_valid(_server_list):
		_server_list.close()
	if _pending_action == "login":
		_say(LoginMessages.citation(_text))
		_set_busy(true)
	else:
		_note("Connecting...")
	# The title's backdrop stops starting new cells (round 678's review): the
	# screen may be left soon, and leaving waits for any still preparing.
	if _title != null:
		_title.hold_backdrop("Connect pressed")
	NetClient.connect_to_server(address["host"], address["port"])

## The legacy path: on the open gateway connection after a refusal (READ:
## the gateway keeps it below the tolerance), else a new login.
func _login_legacy() -> void:
	if _client_info.is_empty():
		_client_info = RetailClientInfo.from_media(_media)
	if not _client_info.has("content_id"):
		# OURS: without the archive's content id and version a legacy
		# gateway cannot be asked at all.
		_note("'%s' speaks the original protocol, which needs Media.pk2's content id and version: %s" % [
			_selected.name, _client_info.get("error", "")])
		return
	if _server_list != null and is_instance_valid(_server_list):
		_server_list.close()
	_say(LoginMessages.citation(_text))
	_set_busy(true)
	if _title != null:
		_title.hold_backdrop("Connect pressed")
	if _retail != null and _retail.can_resubmit():
		print("LOGIN: legacy -- 0x6102 again on the open gateway connection")
		_retail.resubmit(username_edit.text, password_edit.text)
		return
	if _retail != null:
		_retail.cancel()
		_retail.queue_free()
	_retail = RetailLogin.new()
	_retail.name = "RetailLogin"
	add_child(_retail)
	_retail.step.connect(_on_retail_step)
	var shard := _shard_name if _shard_name != "" else _selected.name
	_retail.start(_selected, _client_info, username_edit.text, password_edit.text, shard)

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

func _remember_server() -> void:
	if _selected != null and _address_override == "":
		ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_SERVER_NAME, _selected.name)
	else:
		ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_ADDRESS, _target_address().strip_edges())
	ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_USERNAME, username_edit.text)

func _on_connected() -> void:
	_remember_server()
	_send_pending_action()

## The content id this client sends OpenSRO's server in 0x6102: the
## archive's (RetailClientInfo) when it can be read, else 0; the shard id 0
## (OURS: one process, one shard; the server checks neither).
func _own_content_id() -> int:
	if _client_info.is_empty():
		_client_info = RetailClientInfo.from_media(_media)
	return int(_client_info.get("content_id", 0))

func _send_pending_action() -> void:
	var username := username_edit.text
	var password := password_edit.text
	if _pending_action == "login":
		NetClient.gateway_login(_own_content_id(), username, password, 0)
	elif _pending_action == "register":
		if username.is_empty() or password.is_empty():
			_note("Username and password are required.")
			return
		_note("Registering...")
		NetClient.register_account(username, password)

## OURS: the title never connects in retail (the version check does, and a
## failure there quits with a Win32 box, READ 0x86d370), so a failed connect
## here is UIO_MSG_ERROR_SEVER_CONNECT without a "(C<n>)".
func _on_connection_failed() -> void:
	_set_busy(false)
	if _pending_action == "login":
		_say(LoginMessages.connect_failed(_text, -1))
	else:
		_note(LoginMessages.connect_failed(_text, -1))
		UiSounds.error_box("login screen: no connection")

## 0xA102 on OpenSRO's own connection.
func _on_gateway_login_result(ack: LoginAckNet.Ack) -> void:
	# READ (0x86c08c): any 0xA102 gives the title its input back first.
	_set_busy(false)
	if ack.error != "":
		_say(LoginMessages.connect_failed(_text, 7))
		print("LOGIN: 0xA102 malformed: %s" % ack.error)
		return
	if ack.ok:
		_enter_select("0xA102 ok (OpenSRO)")
		return
	print("LOGIN: 0xA102 refused: code %d kind %d max %d used %d" % [ack.code, ack.block_kind, ack.max_attempts, ack.used_attempts])
	_say(LoginMessages.ack_text(ack, _text))

## The legacy path's steps (RetailLogin).
func _on_retail_step(ev: Dictionary) -> void:
	match str(ev["kind"]):
		"connect_failed":
			print("LOGIN: legacy gateway: %s" % ev.get("why", ""))
			_set_busy(false)
			_say(LoginMessages.connect_failed(_text, -1))
		"login_failed":
			_set_busy(false)
			var ack: LoginAckNet.Ack = ev["ack"]
			print("LOGIN: legacy 0xA102 refused: code %d kind %d max %d used %d" % [ack.code, ack.block_kind, ack.max_attempts, ack.used_attempts])
			_say(LoginMessages.ack_text(ack, _text))
		"captcha":
			_show_captcha(ev["blob"])
		"captcha_ok":
			if _captcha != null:
				_captcha.hide_window()
		"captcha_failed":
			if _captcha != null:
				_captcha.hide_window()
			_say(LoginMessages.captcha_failed(_text, int(ev["max"]), int(ev["used"])))
		"agent_connect_failed":
			print("LOGIN: legacy agent: %s" % ev.get("why", ""))
			_set_busy(false)
			_say(LoginMessages.connect_failed(_text, 9)) # READ: internal 9 -> "(C9)"
		"agent_failed":
			_set_busy(false)
			_say(LoginMessages.agent_text(int(ev["code"]), _text))
		"logged_in":
			_remember_server()
			NetClient.attach_retail(ev["link"])
			_enter_select("0xA103 ok (legacy)")
		"closed":
			print("LOGIN: legacy connection closed: %s" % ev.get("why", ""))
			if _captcha != null:
				_captcha.hide_window()
			_show_netoff()

func _show_captcha(blob: PackedByteArray) -> void:
	if _captcha == null:
		_captcha = CaptchaWindow.new()
		_captcha.build(UiBuilder.new(_media, _text) if _media != null else null)
		add_child(_captcha)
		_captcha.submitted.connect(func(code: String) -> void:
			if _retail != null:
				_retail.submit_captcha(code))
	var s := get_viewport_rect().size
	_captcha.position = ((s - CaptchaWindow.SIZE) * 0.5).floor() # OURS: centred
	var err := _captcha.show_image(blob)
	print("LOGIN: image code asked%s" % ("" if err == "" else " (%s)" % err))

## READ (slot 40, 0x862450): a connection the server closes at the title is
## the NETOFF box; its Confirm quits the client.
func _on_net_disconnected() -> void:
	if _closing_ourselves or not is_inside_tree():
		return
	print("LOGIN: the server closed the connection")
	_show_netoff()

func _show_netoff() -> void:
	_set_busy(false)
	if _netoff != null and is_instance_valid(_netoff):
		return
	_netoff = NetOffBox.show_on(self, _media, _text)
	print("LOGIN MESSAGE: [box] %s" % _netoff.message_text().c_escape())

func _enter_select(why: String) -> void:
	print("LOGIN: %s -- character select" % why)
	_qa_report("Login OK.")
	# Round 684: the select screen keeps the title's hour (READ: no
	# front-end screen picks its own) and this screen's branding.
	CharSelectHandoff.day_phase = _title.day_phase if _title != null else -1.0
	CharSelectHandoff.theme = _theme
	CharSelectHandoff.came_from = CharSelectHandoff.FROM_OTHER
	get_tree().change_scene_to_file("res://scenes/CharacterSelect.tscn")

## The older OpLogin answer (QaSignIn still logs in that way).
func _on_login_result(ok: bool, reason: String) -> void:
	if ok:
		_enter_select("OpLogin ok")
	else:
		_note("Login failed: %s" % reason)

func _on_register_result(ok: bool, reason: String) -> void:
	if ok:
		_note("Registered - you can log in now.")
	else:
		_note("Registration failed: %s" % reason)
		UiSounds.error_box("login screen: registration refused")
