extends Control

## Character select and race select: retail's CPSCharacterSelect (round 684).
##
## The account's characters stand on the Constantinople harbour's dock
## (region 105/81) in their own bodies, armour and weapons, fading in as the
## camera comes down the quay; hovering one fades its name in above it,
## clicking one flies the camera to it and opens its panel, and Start enters
## the world. Create flies the camera to the table with the two idols, where
## the race is picked; the customize screen (round 685) takes it from there
## through CharSelectHandoff.
##
## Everything visible is the archive's: the layout resinfo\pscharacterselect
## .txt (FrontEndFrame reads its bands and title, this file the rest), its art
## and the textuisystem words. Every behaviour is READ from sro_client.exe --
## OnCreate 0x85eb10, the per-frame vslot_012 0x85ce30, the click FUN_0085b680,
## the race fly FUN_0085c4a0 and the others named where they are used; the
## numbers are CharSelectMath's, the 3D CharSelectStage's -- and where a value
## is ours it says OURS. docs/protocol/charselect.md has the reading.
##
## The wiring of round 682 is kept: LobbyNet through NetClient (list,
## delete, restore, Start), OPENSRO_QA_FAKECHARS and the scripted
## OPENSRO_QA_RECONNECT_VIA_LOGIN.

## An idol was clicked: CharCatalog.RACE_CHINA or RACE_EUROPE. The screen
## then flies, fades and opens the customize screen (CharSelectHandoff).
signal race_chosen(race: int)

const STILL_DDJ := "interface\\loading\\loading_constantinople.ddj"
const TEXT_TABLE_PATH := "server_dep\\silkroad\\textdata\\textuisystem.txt"
const BUTTON_STATES := ["", "_focus", "_press"]
const WORLD_SCENE := "res://scenes/World3D.tscn"
const LOGIN_SCENE := "res://scenes/Login.tscn"

## Test seams (OURS): what Start sends and how the scene changes, when set;
## NetClient.enter_world and the tree's change_scene_to_file otherwise.
var send_start := Callable()
var change_scene := Callable()
## Round 788: the drop box (NetOffBox), once shown.
var netoff_box: NetOffBox = null
## Round 788 (OURS): Start on a legacy server's agent.
const LEGACY_NO_WORLD := "Entering the world on an original server is not supported yet: its world protocol is not built."

## The screen's states, numbered as retail's +0xe4 (vslot_012's switch).
## LOADING is ours: the region builds before anything moves.
enum S { INTRO = 0, PLACE = 1, LIST = 2, ZOOM = 3, PLACE_AGAIN = 4, SELECTED = 5, DESELECT = 6,
	RACE_FLY = 7, RACE = 8, IDOL_FLY = 9, RACE_BACK = 11, ENTERING = 14, BACK = 13, CONFIRM = 15,
	LOADING = 100 }

## The windows, by their layout IDs (pscharacterselect.txt, section Select).
const ID_TITLE := 3
const ID_REGIONTITLE := 4
const ID_CHINA := 9
const ID_EUROPE := 11
const ID_CREATE := 12
const ID_BACK := 13
const ID_START := 14
const ID_DELETE := 15
const ID_DESELECT := 16
const ID_RACE_CANCEL := 17
const ID_INFO := 18
const ID_SCREENFADE := 19
const ID_POPUP := 20
const ID_FADE := 21
const ID_RESTORE := 25
const ID_REMAIN := 26
const ID_PREV := 45
const ID_NEXT := 46
const ID_PAGE := 50
const ID_MESSAGE := 500

var state: int = S.LOADING
var _media: Pk2Reader = null
var _layout: UiLayoutParser.LayoutDef = null
var _text: UiTextTable = null
var _frame: FrontEndFrame = null
var stage: CharSelectStage = null
var _has_3d := false
var _started_ms := 0

## The list as the server sent it, and the slot order (CharSelectMath).
var _records: Array = []
var _plan: Array[Dictionary] = []
## Characters in slot order.
var _slots: Array = []
var _page := 0
var selected := -1
var hovered := -1
var hovered_idol := -1
var _path: IntroCameraPath = null
## The pose the camera was last put at (the stage keeps its own; this one
## serves the no-3D fallback and the tests).
var _last_pose: IntroCameraPath.Pose = null
var _level_exp := {}
## The countdown's own clock (READ: +0x120 seconds, +0x124 whole minutes).
var _clock_s := 0.0
var _clock_min := 0
var _shown_min := -1
## A delete or restore was answered: re-select this name when the list comes
## (READ: +0x12f = 2, then FUN_0085f840's state 0xf branch), and how.
## READ, FUN_0085f840: the re-select takes the same slot INDEX
## (DAT_00ec2d60), not the same name -- the list is sorted again and the
## camera stays where it is. -1: none pending.
var _reselect_index := -1
var _reselect_deleted := false
var _confirm_delete := true
## The state the confirm was opened from (a click during the zoom leaves the
## fly running; closing goes back to it).
var _confirm_from: int = S.SELECTED
var _busy := 0
var _list_arrived := false
var _scene_ready := false
var _fake := false
## OPENSRO_QA_SELECT_RELOAD=<n> (OURS, QA): the leak check -- once the list
## is up, the screen is left for itself again, n times, printing the
## engine's counts each time.
static var _qa_reloads := 0
var _qa_reload_at := -1.0
var _built_list := false

var _windows := {}      # layout id -> Control
var _labels: Array = [] # per slot: Label
var _label_alpha: Array = []  # per label: {} or the fade {from, to, t, dur}
var _info := {}         # id -> Control inside the info panel
var _remain := {}       # id -> Control inside the countdown
var _popup_parts := {}
var _black: ColorRect = null
var _dim: ColorRect = null
var _message: Label = null
## The account PIN, "Character Lock" (round 788, CharSelectLock; OURS).
var _lock: CharSelectLock = null

func _ready() -> void:
	_started_ms = Time.get_ticks_msec()
	mouse_filter = Control.MOUSE_FILTER_STOP
	NetClient.character_list_result.connect(_on_list_result)
	NetClient.character_delete_result.connect(_on_delete_result)
	NetClient.character_restore_result.connect(_on_restore_result)
	NetClient.enter_world_result.connect(_on_enter_world_result)
	NetClient.disconnected.connect(_on_disconnected)
	_media = FrontEndUi.open_media()
	FrontEndUi.apply_client_font(self, _media)
	_text = _load_text_table()
	if _media != null and NetClient.lobby_text == null:
		NetClient.lobby_text = _text
	_layout = FrontEndFrame.load_layout(_media, FrontEndFrame.SELECT_LAYOUT_PATH)
	_level_exp = _load_level_exp()
	_build_ui()
	_setup_lock()
	_begin_stage()
	# QA render hook: with no logged-in session this screen would list
	# nothing, so a render can inject clearly-fake sample characters.
	_fake = OS.get_environment("OPENSRO_QA_FAKECHARS") != ""
	if _fake:
		_on_list_result.call_deferred(_qa_sample_characters(), "")
	else:
		# READ: OnCreate asks for the list (FUN_008560e0, 0x7007 action 2).
		NetClient.list_characters()

# --- Building -------------------------------------------------------------------

## The account PIN (round 788; OURS, CharSelectLock has the rules): asked
## for when the screen opens, and asked before Start, Delete and Restore.
func _setup_lock() -> void:
	_lock = CharSelectLock.new()
	add_child(_lock)
	_lock.setup(self, UiBuilder.new(_media, _text), NetClient, _def("Select", ID_START), _button,
		func() -> bool: return state in LIST_BUTTON_STATES or state in SELECTED_BUTTON_STATES)
	_lock.place_button((_windows[ID_START] as Control).position)
	# A legacy server's agent carries only the lobby (NetClient._send_retail):
	# it is never asked, and with no status pending hold() lets every action
	# through.
	if not _fake and not NetClient.is_retail():
		_lock.query()

func _section(name: String) -> UiLayoutParser.SectionDef:
	return _layout.sections.get(name) if _layout != null else null

func _def(section: String, id: int) -> UiLayoutParser.ControlDef:
	return FrontEndFrame.by_id(_section(section), id)

func _build_ui() -> void:
	add_child(FrontEndUi.ground(Color(0, 0, 0)))
	# The 3D world draws in the viewport behind every Control; the ground is
	# shown only while there is no 3D (a still and a 2D list, OURS).
	get_child(0).name = "Ground"
	var custom_dir := FrontEndTheme.custom_dir()
	var theme := CharSelectHandoff.theme
	if theme == null:
		theme = _resolve_theme(custom_dir)
	_frame = FrontEndFrame.new()
	_frame.name = "FrontEndFrame"
	add_child(_frame)
	var framed := _layout != null and _frame.build(_media, theme, custom_dir,
		"Ver %s" % UpdateChecker.CLIENT_VERSION.trim_prefix("v"), _layout, "Select", FrontEndFrame.SELECT_ROLES)
	if not framed:
		print("SELECT: no %s -- a plain frame" % FrontEndFrame.SELECT_LAYOUT_PATH)
	# READ: the version line is CPSTitle's own window (0x86bc1d); the select
	# screen's OnCreate makes none.
	if _frame.version_label != null:
		_frame.version_label.visible = false
	# Window 4, "REGION", in the title's place, hidden until race select
	# (READ: FUN_0085b1f0 hides it).
	var region_title := _art(_def("Select", ID_REGIONTITLE))
	_scaled_place(region_title, _def("Select", ID_REGIONTITLE))
	region_title.modulate.a = 0.0
	add_child(region_title)
	_windows[ID_REGIONTITLE] = region_title
	if _frame.title_art != null:
		_windows[ID_TITLE] = _frame.title_art
		_frame.set_alpha(_frame.title_art, 0)

	# The info panel (18) and its fields (section Info).
	var info := _art(_def("Select", ID_INFO), Vector2(228, 140))
	add_child(info)
	_windows[ID_INFO] = info
	for c in (_section("Info").controls if _section("Info") != null else []):
		var cd: UiLayoutParser.ControlDef = c
		var n: Control
		if cd.type == "CIFGauge":
			n = _gauge(cd)
		else:
			n = _static(cd, _t(cd.text, ""))
		info.add_child(n)
		_info[cd.id] = n

	# The countdown (26) and its parts (section Remain).
	var remain := _art(_def("Select", ID_REMAIN), Vector2(328, 92))
	add_child(remain)
	_windows[ID_REMAIN] = remain
	var remain_defs: Array = _section("Remain").controls if _section("Remain") != null else []
	for i in range(remain_defs.size() - 1, -1, -1):
		var cd: UiLayoutParser.ControlDef = remain_defs[i]
		var n: Control
		if cd.type == "CIFGauge":
			n = _gauge(cd)
		elif cd.type == "CIFPML":
			n = _pml(cd)
		elif cd.ddj != "":
			n = _art(cd)
		else:
			n = _static(cd, _t(cd.text, ""))
		remain.add_child(n)
		_remain[cd.id] = n

	# The idol panels (9 China, 11 Europe) with their tooltips (sections
	# China / Europe: 101 the title, 200 / 201 the text).
	for pair in [[ID_CHINA, "China"], [ID_EUROPE, "Europe"]]:
		var panel := _art(_def("Select", pair[0]), Vector2(440, 152))
		add_child(panel)
		_windows[pair[0]] = panel
		panel.gui_input.connect(_on_race_panel_input.bind(0 if pair[0] == ID_EUROPE else 1))
		for c in (_section(pair[1]).controls if _section(pair[1]) != null else []):
			var cd: UiLayoutParser.ControlDef = c
			var lab := _static(cd, _t(cd.text, ""))
			if cd.type == "CIFTextBox":
				lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				lab.vertical_alignment = VERTICAL_ALIGNMENT_TOP
			panel.add_child(lab)
			_refit(lab, cd)

	# The buttons, in three columns in the bottom band (placed in _relayout).
	for spec in [[ID_START, "UIO_SELCHAR_CTL_START", "Start"], [ID_CREATE, "UIO_COMMON_CTL_CREATE", "Create"],
			[ID_DELETE, "UIO_SELCHAR_CTL_DELETE", "Delete"], [ID_RESTORE, "UIO_STT_CHAR_RECOVERY", "Restore"],
			[ID_BACK, "UIO_COMMON_CTL_CANCEL", "Cancel"], [ID_DESELECT, "UIO_COMMON_CTL_CANCEL", "Cancel"],
			[ID_RACE_CANCEL, "UIO_COMMON_CTL_CANCEL", "Cancel"]]:
		var d := _def("Select", spec[0])
		var b := _button(d, d.text if d != null else spec[1], spec[2])
		b.name = "Button%d" % spec[0]
		add_child(b)
		_windows[spec[0]] = b
	(_windows[ID_START] as Button).pressed.connect(_on_start_pressed)
	(_windows[ID_CREATE] as Button).pressed.connect(_on_create_pressed)
	(_windows[ID_DELETE] as Button).pressed.connect(_on_delete_pressed)
	(_windows[ID_RESTORE] as Button).pressed.connect(_on_delete_pressed)
	(_windows[ID_BACK] as Button).pressed.connect(_on_back_pressed)
	(_windows[ID_DESELECT] as Button).pressed.connect(_on_deselect_pressed)
	(_windows[ID_RACE_CANCEL] as Button).pressed.connect(_on_race_cancel_pressed)
	for id in [ID_PREV, ID_NEXT]:
		var d := _def("Select", id)
		var b := _button(d, "", "<" if id == ID_PREV else ">")
		if b.size == Vector2.ZERO or b.size.x < 8:
			b.size = Vector2(32, 64)
		add_child(b)
		_windows[id] = b
	(_windows[ID_PREV] as Button).pressed.connect(func() -> void: _change_page(-1))
	(_windows[ID_NEXT] as Button).pressed.connect(func() -> void: _change_page(1))
	var page_label := _static(_def("Select", ID_PAGE), "")
	add_child(page_label)
	_windows[ID_PAGE] = page_label

	# The message line (500): all status and error text.
	_message = _static(_def("Select", ID_MESSAGE), "")
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	add_child(_message)

	# Name labels, one per slot of a page (READ: font 4, the name only).
	for i in range(CharSelectMath.PER_PAGE):
		var l := Label.new()
		l.name = "NameLabel%d" % i
		l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[4])
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 3)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.modulate.a = 0.0
		add_child(l)
		_labels.append(l)
		_label_alpha.append({})

	# The delete confirm (20) under its dimming (19).
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 1)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.modulate.a = 0.0
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)
	var popup := _art(_def("Select", ID_POPUP), Vector2(344, 192))
	popup.mouse_filter = Control.MOUSE_FILTER_STOP
	popup.set_meta("blocks_clicks", true)
	add_child(popup)
	_windows[ID_POPUP] = popup
	for c in (_section("Warning").controls if _section("Warning") != null else []):
		var cd: UiLayoutParser.ControlDef = c
		var n: Control
		if cd.type == "CIFButton":
			n = _button(cd, cd.text, "Cancel" if cd.id == 43 else "Delete")
			n.position = Vector2(cd.rect.position)
		else:
			n = _static(cd, _t(cd.text, ""))
			if cd.type == "CIFTextBox":
				(n as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		popup.add_child(n)
		_refit(n, cd)
		_popup_parts[cd.id] = n
	if _popup_parts.has(42):
		(_popup_parts[42] as Button).pressed.connect(_on_confirm_accept)
	if _popup_parts.has(43):
		(_popup_parts[43] as Button).pressed.connect(_on_confirm_cancel)

	# Window 21, the black fade: opaque while the region builds (OURS), then
	# 0x80 -> 0 over 0.5 s (READ, OnCreate).
	_black = ColorRect.new()
	_black.name = "Fade21"
	_black.color = Color(0, 0, 0, 1)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_black)

	for id in [ID_INFO, ID_REMAIN, ID_CHINA, ID_EUROPE, ID_START, ID_CREATE, ID_DELETE, ID_RESTORE,
			ID_BACK, ID_DESELECT, ID_RACE_CANCEL, ID_PREV, ID_NEXT, ID_PAGE, ID_POPUP]:
		_hide_now(_windows[id])
	resized.connect(_relayout)
	_relayout()

## READ, OnCreate 0x85ee33..0x85f15c (CharSelectMath.button_position): the
## windows in screen pixels around the bands as scaled.
func _relayout() -> void:
	var w := int(size.x)
	var h := int(size.y)
	var band1 := _frame.band_bottom_edge() if _frame != null and _frame.layout != null else int(h * 172.0 / 1200.0)
	var down := _frame.role_def("screendown") if _frame != null and _frame.layout != null else null
	var band2 := int(_frame.scaled(down.rect).position.y) if down != null else int(h * 1030.0 / 1200.0)
	for id in [ID_CREATE, ID_DELETE, ID_RESTORE, ID_BACK, ID_DESELECT, ID_RACE_CANCEL, ID_START, ID_INFO]:
		(_windows[id] as Control).position = CharSelectMath.button_position(id, w, band1, band2)
	var remain := _windows[ID_REMAIN] as Control
	remain.position = CharSelectMath.countdown_position(w, band2, int(remain.size.x))
	# READ: x is window 2's own x + 0x1a (0x85efdb; 0 in the archive's layout).
	var band2_x := int(_frame.scaled(down.rect).position.x) if down != null else 0
	_message.position = CharSelectMath.button_position(ID_MESSAGE, w, band1, band2) + Vector2(band2_x, 0)
	# Window 501 (the unity-server line) is not built: OnCreate shows it only
	# when DAT_00eed9b8 is set (READ), a service this server is not.
	_message.size = Vector2(w - 0x1a, 100)
	var popup := _windows[ID_POPUP] as Control
	popup.position = Vector2((w - int(popup.size.x)) / 2, (h - int(popup.size.y)) / 2)
	for id in [ID_PREV, ID_NEXT]:
		var b := _windows[id] as Control
		b.position = CharSelectMath.arrow_position(id, Vector2i(w, h), Vector2i(b.size))
	var page := _windows[ID_PAGE] as Control
	page.position = Vector2((w - page.size.x) / 2, band2 - page.size.y - 8) # OURS: 50 is placed by code not read
	if _lock != null:
		_lock.place_button((_windows[ID_START] as Control).position)

func _scaled_place(n: Control, d: UiLayoutParser.ControlDef) -> void:
	if d == null or _frame == null or _frame.layout == null:
		return
	var r := _frame.scaled(d.rect)
	n.position = r.position
	n.size = r.size

## A window's art (its DDJ) at the layout's size, or an empty Control.
func _art(d: UiLayoutParser.ControlDef, fallback_size: Vector2 = Vector2.ZERO) -> Control:
	var tex := FrontEndUi.load_ddj(_media, d.ddj) if d != null and d.ddj != "" else null
	var n: Control
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		n = tr
	else:
		n = Panel.new() if fallback_size != Vector2.ZERO else Control.new()
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	n.size = Vector2(d.rect.size) if d != null and d.rect.size != Vector2i.ZERO else fallback_size
	if d != null and d.rect.position != Vector2i.ZERO:
		n.position = Vector2(d.rect.position)
	return n

## A CIFGauge: its art clipped to the fill (OURS drawing; the fill is READ).
func _gauge(d: UiLayoutParser.ControlDef) -> Control:
	var clip := Control.new()
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.position = Vector2(d.rect.position)
	clip.size = Vector2(d.rect.size)
	clip.set_meta("full_width", float(d.rect.size.x))
	var tex := FrontEndUi.load_ddj(_media, d.ddj) if d.ddj != "" else null
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.size = Vector2(d.rect.size)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip.add_child(tr)
	return clip

static func set_gauge(g: Control, fill: float) -> void:
	if g == null:
		return
	g.size.x = roundf(float(g.get_meta("full_width", g.size.x)) * clampf(fill, 0.0, 1.0))

## Sizes a window again once it is in the tree: a Label sized before it has
## its theme takes the default font's minimum, and a wrapped text box came
## out taller than its rect and centred lower (round 684, seen on the box).
static func _refit(n: Control, d: UiLayoutParser.ControlDef) -> void:
	if d == null or n is BaseButton:
		return
	n.position = Vector2(d.rect.position)
	n.size = Vector2(d.rect.size)

## A CIFPML window: the archive's markup as BBCode (CharSelectMath.pml_to_bbcode).
func _pml(d: UiLayoutParser.ControlDef) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = false
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# OURS: wider than its 328 px rect, centred on it -- the archive's line
	# does not fit 328 px in this client's font (retail's 9 pt face is
	# narrower); the text is centred (HAlign 1) either way.
	var extra := 160
	r.position = Vector2(d.rect.position) - Vector2(extra / 2, 0)
	r.size = Vector2(d.rect.size.x + extra, maxi(d.rect.size.y, 18))
	r.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[clampi(d.font_index, 0, UiBuilder.FONT_SIZES.size() - 1)])
	r.add_theme_color_override("default_color", d.font_color)
	return r

## A key's text without the escapes _t unfolds (the PML keeps its own).
func _raw_text(key: String) -> String:
	if _text != null and _text.has(key):
		return _text.get_text(key, "")
	return ""

func _static(d: UiLayoutParser.ControlDef, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = false
	if d != null:
		if d.type == "CIFTextBox":
			# READ: a CIFTextBox wraps in its rect. OURS: this client's 12 px
			# face sets lines ~15 px apart where retail's 9 pt face fits the
			# archive's 7-line confirm into the box's 90 px; -3 keeps it there.
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.add_theme_constant_override("line_spacing", -3)
			l.custom_minimum_size = Vector2(d.rect.size.x, 0)
		l.position = Vector2(d.rect.position)
		l.size = Vector2(d.rect.size)
		l.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[clampi(d.font_index, 0, UiBuilder.FONT_SIZES.size() - 1)])
		l.add_theme_color_override("font_color", d.font_color)
		l.horizontal_alignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][clampi(d.halign, 0, 2)]
		l.vertical_alignment = [VERTICAL_ALIGNMENT_TOP, VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_BOTTOM][clampi(d.valign, 0, 2)]
	return l

## A button from the layout: its DDJ's three state images (as Login's), its
## text key's words.
func _button(d: UiLayoutParser.ControlDef, text_key: String, fallback: String) -> Button:
	var b := Button.new()
	b.text = _t(text_key, fallback)
	b.size = Vector2(d.rect.size) if d != null and d.rect.size != Vector2i.ZERO else Vector2(92, 41)
	b.custom_minimum_size = b.size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", UiBuilder.FONT_SIZES[clampi(d.font_index if d != null else 0, 0, UiBuilder.FONT_SIZES.size() - 1)])
	b.add_theme_color_override("font_color", d.font_color if d != null else Color.WHITE)
	var base: String = d.ddj if d != null and d.ddj != "" else "interface\\outer\\button.ddj"
	var styles := ["normal", "hover", "pressed"]
	for i in range(BUTTON_STATES.size()):
		var tex := FrontEndUi.load_ddj(_media, base.get_basename() + str(BUTTON_STATES[i]) + ".ddj")
		if tex == null:
			continue
		var sb := StyleBoxTexture.new()
		sb.texture = tex
		b.add_theme_stylebox_override(styles[i], sb)
	return b

func _t(key: String, fallback: String) -> String:
	if _text != null and key != "" and _text.has(key):
		var s := _text.get_text(key, fallback).strip_edges()
		if s != "" and s != key:
			return s.replace("\\n", "\n")
	return fallback

func _load_text_table() -> UiTextTable:
	if NetClient.lobby_text != null:
		return NetClient.lobby_text
	if _media == null:
		return null
	var entry := ObjectLoader.find_file(_media, TEXT_TABLE_PATH)
	return UiTextTable.parse(_media.read_file(entry)) if entry != null else null

func _load_level_exp() -> Dictionary:
	if _media == null:
		return {}
	var entry := ObjectLoader.find_file(_media, LevelDataReader.TABLE_PATH)
	return LevelDataReader.parse_exp(_media.read_file(entry)) if entry != null else {}

## The theme when Login left none (a QA run straight into this screen): the
## local sources only (OURS).
static func _resolve_theme(custom_dir: String) -> FrontEndTheme:
	var warnings := PackedStringArray()
	return FrontEndTheme.resolve(FrontEndTheme.from_environment(warnings), null, null,
		FrontEndTheme.from_custom_folder(custom_dir, warnings), null)

# --- Show and hide (CIFFade through FrontEndFrame.fade) ---------------------------------

func _hide_now(n: Control) -> void:
	if n == null:
		return
	if _frame != null:
		_frame.set_alpha(n, 0)
	n.modulate.a = 0.0
	n.visible = false
	_set_clickable(n, false)

## READ: the screen's windows fade (FUN_00854860 -> CIFFade) rather than pop;
## OURS: a window fading out stops taking clicks at once.
func _show(id: int, on: bool, duration: float = CharSelectMath.FADE_S) -> void:
	var n: Control = _windows.get(id)
	if n == null:
		return
	if on:
		n.visible = true
	_set_clickable(n, on)
	var from := int(roundf(n.modulate.a * 255.0))
	if _frame != null:
		_frame.fade(n, from, 255 if on else 0, duration)
	else:
		n.modulate.a = 1.0 if on else 0.0

func _set_clickable(n: Control, on: bool) -> void:
	if n != null and n.has_meta("blocks_clicks"):
		# A window that takes the clicks under it (the confirm) stops doing so
		# the moment it starts fading out (OURS).
		n.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
		for c in n.get_children():
			if c is BaseButton:
				(c as Control).mouse_filter = n.mouse_filter
	if n != null and n is BaseButton:
		n.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
		(n as BaseButton).disabled = not on

func _say(key: String, fallback: String = "") -> void:
	_message.text = _t(key, fallback) if key != "" else fallback

# --- The 3D -------------------------------------------------------------------------------

func _begin_stage() -> void:
	stage = CharSelectStage.new()
	stage.name = "CharSelectStage"
	add_child(stage)
	var phase := CharSelectHandoff.front_end_phase()
	_has_3d = stage.begin(phase)
	if not _has_3d:
		stage.queue_free()
		stage = null
		var still := FrontEndUi.backdrop(_media, STILL_DDJ)
		if still != null:
			add_child(still)
			move_child(still, 1)
		print("SELECT: no 3D harbour -- the 2D still (OURS fallback)")
		_on_scene_ready()
		return
	stage.build_props()
	print("SELECT: harbour 105/81 started at %d ms (title hour phase %.4f)" % [Time.get_ticks_msec() - _started_ms, phase])
	# The camera waits where the list intro begins while the region builds.
	stage.show_pose(CharSelectMath.list_intro_path().sample(0.0))
	stage.scene_ready.connect(_on_scene_ready, CONNECT_ONE_SHOT)
	# Retail draws the 3D world behind the UI; our ground is only the
	# no-3D fallback.
	(get_node("Ground") as CanvasItem).visible = false

## The region is built: retail's OnCreate state begins (OURS: retail loads
## synchronously in OnCreate, so nothing waits there).
func _on_scene_ready() -> void:
	_scene_ready = true
	print("SELECT: usable at %d ms (%s)" % [Time.get_ticks_msec() - _started_ms,
		"%d cell(s) built" % stage.backdrop.cells_loaded() if stage != null else "no 3D"])
	# The leak check across Login -> select -> Login (OURS, measured in the
	# round 684 entry): the engine's own counts when the screen is up.
	print("SELECT: engine counts -- nodes %d, objects %d, orphan nodes %d, resources %d, static %.1f MB" % [
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0])
	# READ, OnCreate: window 21 from 0x80 to 0 over 0.5 s.
	if _frame != null:
		_frame.fade(_black, CharSelectMath.OPEN_FADE_FROM, 0, CharSelectMath.FADE_S)
	else:
		_black.visible = false
	if stage != null:
		stage.fades_paused = false
	_start_list_intro()

func _build_characters() -> void:
	_built_list = true
	if stage != null:
		stage.fades_paused = not _scene_ready
		stage.set_characters(_slots, _plan)
		stage.show_page(_page)

## READ, FUN_0085b1f0: the title fades in, REGION and the panels hide,
## Create and Back fade in, Cancel 17 hides, the camera flies the list keys.
func _start_list_intro() -> void:
	if _frame != null and _frame.title_art != null:
		_frame.fade(_frame.title_art, int(_frame.title_art.modulate.a * 255.0), 255, CharSelectMath.FADE_S)
	_windows[ID_REGIONTITLE].modulate.a = 0.0
	_hide_now(_windows[ID_CHINA])
	_hide_now(_windows[ID_EUROPE])
	_show(ID_CREATE, true)
	_show(ID_BACK, true)
	_show(ID_RACE_CANCEL, false)
	_path = CharSelectMath.list_intro_path()
	_set_state(S.INTRO)

func _set_state(s: int) -> void:
	if s == state:
		return
	state = s
	print("SELECT: state %d at %d ms" % [s, Time.get_ticks_msec() - _started_ms])

# --- The list ------------------------------------------------------------------------------

func _qa_sample_characters() -> Array:
	# OURS, QA only: clearly-fake names over real catalogue ids (charselect.md
	# section 4 lists them; references, not data). OPENSRO_QA_FAKECHARS=<n>
	# gives n of them (default 3); the third is pending deletion.
	# OPENSRO_QA_FAKECHARS_PLUS=<n> (round 734) puts that plus on each one's
	# last item, the weapon, for the glow (EquipGlow).
	var n := 3
	var weapon_plus := clampi(OS.get_environment("OPENSRO_QA_FAKECHARS_PLUS").to_int(), 0, 255)
	var v := OS.get_environment("OPENSRO_QA_FAKECHARS")
	if v.is_valid_int():
		n = clampi(v.to_int(), 0, 8)
	var specs := [
		["QA_Aria", 1923, 0x22, 12, 0, [3652, 3653, 3654, 3632]],
		["QA_Bram", 1909, 0x40, 31, 0, [3637, 3638, 3639, 3634]],
		["QA_Wei", 1919, 0x24, 7, 4321, [3640, 3641, 3642, 3636]],
		["QA_Livia", 14888, 0x22, 20, 0, [11629, 11630, 11631, 10887]],
		["QA_Marco", 14880, 0x13, 5, 0, [11617, 11618, 11619, 10889]],
		["QA_Sun", 1928, 0x31, 2, 0, [3649, 3650, 3651, 3633]],
		["QA_Otto", 14876, 0x22, 1, 0, [11623, 11624, 11625, 10893]],
		["QA_Mei", 1925, 0x22, 1, 0, [3646, 3647, 3648, 3635]],
	]
	var out: Array = []
	for i in range(n):
		var spec: Array = specs[i]
		var s := LobbyNet.Character.new()
		s.char_name = spec[0]
		s.ref_obj_id = spec[1]
		s.scale = spec[2]
		s.level = spec[3]
		s.exp_offset = 37 * (i + 1)
		s.hp = 80 + 10 * i
		s.mp = 60 + 10 * i
		s.str_stat = 20
		s.int_stat = 20
		s.stat_points = 3 * i
		s.deleting = spec[4] > 0
		s.minutes_left = spec[4]
		# OPENSRO_QA_PENDING_NAME=<name> (round 719, QA): that one is the
		# character pending deletion instead.
		var pend := OS.get_environment("OPENSRO_QA_PENDING_NAME")
		if pend != "":
			s.deleting = s.char_name == pend
			s.minutes_left = 4321 if s.deleting else 0
		var kit: Array = spec[5].duplicate()
		# OPENSRO_QA_FAKECHARS_WEAPON=<id> (round 767, QA): that item is each
		# one's weapon instead, e.g. a seal weapon for its seal effects.
		var weapon := OS.get_environment("OPENSRO_QA_FAKECHARS_WEAPON")
		if weapon.is_valid_int():
			kit[kit.size() - 1] = weapon.to_int()
		for j in range(kit.size()):
			s.items.append({"id": kit[j], "plus": weapon_plus if j == kit.size() - 1 else 0})
		out.append(s)
	return out

func _on_list_result(characters: Array, error: String) -> void:
	_busy = 0
	if error != "":
		_message.text = error
		_qa_report(error + " -- no list to start from, staying on the select screen")
		return
	_records = characters
	_plan = CharSelectMath.scene_plan(characters)
	_slots.clear()
	for p in _plan:
		_slots.append(characters[int(p["index"])])
	_list_arrived = true
	_clock_s = 0.0
	_clock_min = 0
	_shown_min = -1
	var names := PackedStringArray()
	for r in _slots:
		names.append("%s (Lv %d%s)" % [r.char_name, r.level, ", deleting" if r.deleting else ""])
	print("SELECT: list of %d in slot order: %s" % [_slots.size(), ", ".join(names)])
	_page = clampi(_page, 0, maxi(CharSelectMath.page_count(_slots.size()) - 1, 0))
	# The models fade in from nothing over 1.0 s (READ). Built at once --
	# their first assembly costs the main thread ~1 s (MEASURED, 4 bodies) --
	# but faded only once the region is up, so the fade is seen (OURS:
	# retail's region is there already).
	_build_characters()
	_update_page_windows()
	if _slots.is_empty():
		_qa_report("No characters yet -- nothing to start, staying on the select screen")
	# READ, FUN_0085f840: after a delete or restore the same character is
	# selected again where the camera is, sitting down or standing up.
	if _reselect_index >= 0:
		var k := _reselect_index if _reselect_index < _slots.size() else -1
		var deleted := _reselect_deleted
		_reselect_index = -1
		_close_confirm()
		if k >= 0:
			if stage != null:
				if deleted:
					stage.play_deleted(k)
				else:
					stage.play_restored(k)
			_select(k, true)
		return
	if OS.get_environment("OPENSRO_QA_RECONNECT_VIA_LOGIN") != "" and not _slots.is_empty():
		_qa_start(QaSignIn.character_name())

func _slot_of(char_name: String) -> int:
	for k in range(_slots.size()):
		if _slots[k].char_name == char_name:
			return k
	return -1

## OPENSRO_QA_RECONNECT_VIA_LOGIN: start `who` the way Start does.
func _qa_start(who: String) -> void:
	var k := _slot_of(who)
	if k < 0:
		printerr("QA RECONNECT: CharacterSelect has no character named %s -- staying on the select screen" % who)
		return
	selected = k
	print("QA RECONNECT: CharacterSelect starting %s at frame %d" % [who, Engine.get_frames_drawn()])
	_on_start_pressed()

func _qa_report(text: String) -> void:
	print("SELECT: %s" % text)
	if OS.get_environment("OPENSRO_QA_RECONNECT_VIA_LOGIN") != "":
		print("QA RECONNECT: CharacterSelect: %s" % text)

# --- Each frame ------------------------------------------------------------------------------

## OPENSRO_QA_SELECT_FADEIN_FRAMES=1 (round 719, OURS, QA): the longest real frame
## (wall clock, not the movie's fixed step) over the first 3.0 s of each
## list's fade-in, where the pending pairs' shaders compile.
var _qa_frame_prev_us := 0
var _qa_frame_max_us := 0
var _qa_frame_s := -1.0
func _qa_frame_time_tick(delta: float) -> void:
	if OS.get_environment("OPENSRO_QA_SELECT_FADEIN_FRAMES") == "" or not _scene_ready:
		return
	var now := Time.get_ticks_usec()
	if _qa_frame_s < 0.0:
		_qa_frame_s = 0.0
		_qa_frame_prev_us = now
		return
	if _qa_frame_s > 3.0:
		return
	_qa_frame_max_us = maxi(_qa_frame_max_us, now - _qa_frame_prev_us)
	_qa_frame_prev_us = now
	_qa_frame_s += delta
	if _qa_frame_s > 3.0:
		print("QA SELECT FADE-IN longest frame %.1f ms" % (_qa_frame_max_us / 1000.0))

func _process(delta: float) -> void:
	_qa_frame_time_tick(delta)
	_tick_countdown(delta)
	if _scene_ready and _path != null and not _qa_camera_frozen:
		var pose := _path.advance(delta)
		_last_pose = pose
		if stage != null:
			stage.show_pose(pose)
	_tick_labels(delta)
	if not _scene_ready:
		return
	var done := _path == null or _path.finished()
	_qa_pending_probe_tick(delta)
	match state:
		S.INTRO:
			if done:
				# READ, vslot_012 case 0: the arrows are placed, then case 1
				# places the labels and shows the page's buttons (FUN_00858e50).
				_relayout()
				_set_state(S.PLACE)
		S.PLACE, S.PLACE_AGAIN:
			_update_page_windows()
			_set_state(S.LIST)
			_qa_print_anchors()
		S.LIST:
			_hover(_pick_mouse())
			_qa_list_tick(delta)
			_qa_reload_tick()
		S.ZOOM:
			if done:
				_set_state(S.SELECTED)
				_qa_print_anchors()
		S.DESELECT:
			if done:
				_set_state(S.PLACE_AGAIN)
		S.RACE_FLY:
			if done:
				_arrive_at_table()
		S.RACE:
			_hover_idol(stage.pick_idol(get_viewport().get_mouse_position()) if stage != null else -1)
			_place_idol_panels()
		S.RACE_BACK:
			if done:
				# READ, case 0xb: the lizard is hidden, the page is placed.
				if stage != null:
					stage.set_lizard(false)
				_update_page_windows()
				_set_state(S.LIST)
				_qa_print_anchors()
		S.IDOL_FLY:
			if done and (_frame == null or _frame.fades_running() == 0):
				_go_create()
		S.BACK:
			if done:
				_leave_to_login()

## Where the camera is now, for a fly that starts from it.
func _current_pose() -> IntroCameraPath.Pose:
	if stage != null and stage.current_pose() != null:
		return stage.current_pose()
	if _last_pose != null:
		return _last_pose
	return CharSelectMath.key_pose(CharSelectMath.LIST_KEYS[1])

## The states the list's buttons (Create 12, Back 13) work in: shown and
## taking the mouse from the intro on, through a deselect and the fly back
## from the table. READ: retail's handlers check no state (0x85c4a0,
## 0x85b560; 0x85de20/0x85de40 just jump); round 684's review found clicks
## dropped during the flies.
const LIST_BUTTON_STATES := [S.INTRO, S.PLACE, S.LIST, S.DESELECT, S.PLACE_AGAIN, S.RACE_BACK]
## Cancel 16, Delete 15 and Restore 25 work from the click on (the zoom).
const SELECTED_BUTTON_STATES := [S.ZOOM, S.SELECTED]

## OURS: once the screen is leaving (Back's dolly, the idol fly, Start
## answered) nothing more is taken, and the buttons left on screen say so.
func _freeze_buttons() -> void:
	for id in [ID_START, ID_CREATE, ID_DELETE, ID_RESTORE, ID_BACK, ID_DESELECT, ID_RACE_CANCEL, ID_PREV, ID_NEXT]:
		_set_clickable(_windows.get(id), false)

func _pick_mouse() -> int:
	if stage == null:
		return -1
	return stage.pick(get_viewport().get_mouse_position(), _page)

## READ, vslot_012 case 2: the hovered character's label fades in, the one
## left fades out, at 0.5 s for a whole fade (CharSelectMath.label_fade_s).
func _hover(k: int) -> void:
	if k == hovered:
		return
	if hovered >= 0:
		_fade_label(hovered, 0)
	hovered = k
	if k >= 0:
		_fade_label(k, 255)
		print("SELECT: hover %d (%s)" % [k, _slots[k].char_name])

func _fade_page_labels_out() -> void:
	for i in range(CharSelectMath.PER_PAGE):
		var k := _page * CharSelectMath.PER_PAGE + i
		if k < _slots.size():
			_fade_label(k, 0)

func _fade_label(k: int, to: int) -> void:
	var i := k % CharSelectMath.PER_PAGE
	if i >= _labels.size():
		return
	var l: Label = _labels[i]
	l.text = _slots[k].char_name if k < _slots.size() else ""
	var from := int(roundf(l.modulate.a * 255.0))
	_label_alpha[k % CharSelectMath.PER_PAGE] = {"from": float(from), "to": float(to), "t": 0.0,
		"dur": CharSelectMath.label_fade_s(from, to)}

func _tick_labels(delta: float) -> void:
	for i in range(_labels.size()):
		var l: Label = _labels[i]
		var k := _page * CharSelectMath.PER_PAGE + i
		var f: Dictionary = _label_alpha[i]
		if not f.is_empty():
			f["t"] = float(f["t"]) + delta
			var u := 1.0 if float(f["dur"]) <= 0.0 else clampf(float(f["t"]) / float(f["dur"]), 0.0, 1.0)
			l.modulate.a = lerpf(float(f["from"]), float(f["to"]), u) / 255.0
			if u >= 1.0:
				_label_alpha[i] = {}
		if stage == null:
			_fallback_label(l, i, k)
			continue
		if l.modulate.a <= 0.0 or k >= _slots.size():
			continue
		var at = stage.label_anchor(k)
		if at == null:
			l.visible = false
			continue
		l.size = Vector2(200, 24)
		# INFERRED: the text is centred on the projected point, its bottom there.
		l.position = (at as Vector2) - Vector2(100, 24)
		if f.is_empty() and not l.has_meta("qa_shown"):
			l.set_meta("qa_shown", true)
			print("QA SELECT: label %d '%s' at (%d, %d)" % [k, l.text, int(l.position.x), int(l.position.y)])
		l.visible = true

## OURS: with no 3D harbour (no Map.pk2 or region -- a dev run) the page's
## names stand in a row over the 2D still, and a click on one selects it.
func _fallback_label(l: Label, i: int, k: int) -> void:
	l.visible = k < _slots.size()
	if not l.visible:
		return
	l.text = _slots[k].char_name
	l.modulate.a = 1.0
	l.size = Vector2(200, 24)
	l.position = Vector2(size.x * float(i + 1) / 5.0 - 100.0, size.y * 0.55)

func _fallback_pick(at: Vector2) -> int:
	for i in range(_labels.size()):
		var l: Label = _labels[i]
		var k := _page * CharSelectMath.PER_PAGE + i
		if l.visible and k < _slots.size() and Rect2(l.position, l.size).has_point(at):
			return k
	return -1

# --- Selecting -----------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	# READ, vslot_017 (0x85ddb0): a left press (0x201) selects the hovered
	# character in state 2, or picks the hovered idol in state 8. A press on
	# nothing does nothing.
	if state == S.LIST:
		var k := stage.pick(mb.position, _page) if stage != null else _fallback_pick(mb.position)
		print("SELECT: click at (%d, %d) -> slot %d" % [int(mb.position.x), int(mb.position.y), k])
		if k >= 0:
			_select(k, false)
	elif state == S.RACE:
		var i := stage.pick_idol(mb.position) if stage != null else -1
		print("SELECT: click at (%d, %d) -> idol %d" % [int(mb.position.x), int(mb.position.y), i])
		if i >= 0:
			_pick_idol(i)

## READ, FUN_0085b680: `reselect` false is a click (param 1), true the
## re-select after a delete or restore (param 0).
func _select(k: int, reselect: bool) -> void:
	selected = k
	var r = _slots[k]
	print("SELECT: selected %d (%s)%s" % [k, r.char_name, " again" if reselect else ""])
	if not reselect:
		_show(ID_CREATE, false)
		_show(ID_BACK, false)
		_show(ID_PREV, false)
		_show(ID_NEXT, false)
		_show(ID_PAGE, false)
		_show(ID_DESELECT, true)
		_show(ID_INFO, true)
	_fill_info(r)
	var shown := CharSelectMath.selected_windows(r.deleting)
	for id in [ID_START, ID_DELETE, ID_RESTORE, ID_REMAIN]:
		_show(id, bool(shown[id]))
	if r.deleting:
		_shown_min = -1
		_say(shown["message"], "The character's deletion is reserved.")
	# Every label fades out (READ, the loop at the function's end).
	_fade_page_labels_out()
	hovered = -1
	var from := _current_pose()
	var woman: bool = stage.is_woman(k) if stage != null else false
	var to: IntroCameraPath.Pose
	if reselect:
		to = CharSelectMath.reselect_pose(from, r.scale, woman, r.deleting)
	elif stage != null:
		to = CharSelectMath.click_pose(stage.drawn[k].slot, r.scale, woman, r.deleting)
	else:
		to = from
	_path = CharSelectMath.click_path(from, to, reselect)
	_set_state(S.ZOOM)

## READ, FUN_0085b680: name, HP and MP gauges, EXP "%.2f%%", stat points
## ("%d"), level ("%d").
func _fill_info(r) -> void:
	if _info.has(31):
		(_info[31] as Label).text = r.char_name
	set_gauge(_info.get(32), CharSelectMath.gauge_fill(r.hp, r.str_stat))
	set_gauge(_info.get(33), CharSelectMath.gauge_fill(r.mp, r.int_stat))
	if _info.has(34):
		(_info[34] as Label).text = CharSelectMath.exp_text(r.exp_offset, int(_level_exp.get(r.level, 0)))
	if _info.has(35):
		(_info[35] as Label).text = "%d" % r.stat_points
	if _info.has(36):
		(_info[36] as Label).text = "%d" % r.level

## READ, FUN_0085c1d0 (Cancel 16).
func _on_deselect_pressed() -> void:
	if not state in SELECTED_BUTTON_STATES:
		return
	_show(ID_CREATE, true)
	_show(ID_BACK, true)
	for id in [ID_START, ID_DELETE, ID_RESTORE, ID_DESELECT, ID_REMAIN, ID_INFO]:
		_show(id, false)
	_say("", "")
	selected = -1
	_path = CharSelectMath.deselect_path(_current_pose())
	_set_state(S.DESELECT)

func _change_page(step: int) -> void:
	var pages := CharSelectMath.page_count(_slots.size())
	if state != S.LIST or pages <= 1:
		return
	_page = clampi(_page + step, 0, pages - 1)
	for l in _labels:
		(l as Label).modulate.a = 0.0
	hovered = -1
	if stage != null:
		stage.show_page(_page)
	_update_page_windows()
	print("SELECT: page %d" % _page)
	_qa_print_anchors()

## READ, FUN_00858e50: the arrows show while there is a page that way, and
## "[ %d / %d ]" (window 50) with more than 4 characters.
func _update_page_windows() -> void:
	if state != S.LIST and state != S.PLACE and state != S.PLACE_AGAIN:
		return
	var pages := CharSelectMath.page_count(_slots.size())
	_show(ID_PREV, _page > 0)
	_show(ID_NEXT, _page + 1 < pages)
	if _slots.size() > CharSelectMath.PER_PAGE:
		(_windows[ID_PAGE] as Label).text = "[ %d / %d ]" % [_page + 1, pages]
		_show(ID_PAGE, true)
	else:
		_show(ID_PAGE, false)

# --- Start ---------------------------------------------------------------------------------

## READ, 0x858770: 0x7001 with the name; 0xB001 1 switches to the loading
## and the world.
func _on_start_pressed() -> void:
	if selected < 0 or selected >= _slots.size():
		return
	if _lock != null and _lock.hold(_on_start_pressed):
		return
	var char_name: String = _slots[selected].char_name
	print("SELECT: Start %s" % char_name)
	# Round 788 (OURS): on a legacy server's agent the lobby works but the
	# world does not -- its protocol is not the original one yet.
	if NetClient.is_retail():
		_message.text = LEGACY_NO_WORLD
		print("SELECT: %s" % LEGACY_NO_WORLD)
		return
	_busy += 1
	_set_clickable(_windows.get(ID_START), false)
	if send_start.is_valid():
		send_start.call(char_name)
	else:
		NetClient.enter_world(char_name)

func _on_enter_world_result(result: WorldNet.EnterWorldResult) -> void:
	_busy = maxi(_busy - 1, 0)
	if result.error != "" or not result.ok:
		var why: String = result.error if result.error != "" else result.reason
		_message.text = why
		_qa_report("Start refused: %s" % why)
		if state == S.SELECTED or state == S.ZOOM:
			_set_clickable(_windows.get(ID_START), true)
		return
	_set_state(S.ENTERING)
	_qa_report("entering the world at frame %d" % Engine.get_frames_drawn())
	if change_scene.is_valid():
		change_scene.call(WORLD_SCENE)
	else:
		get_tree().change_scene_to_file(WORLD_SCENE)

# --- Delete and restore ---------------------------------------------------------------------

## READ, 0x858b40: a guild member or master, or an academy student or
## guardian, is refused with the archive's line; anyone else gets the
## confirm (0x858950).
func _on_delete_pressed() -> void:
	if not state in SELECTED_BUTTON_STATES or selected < 0:
		return
	var r = _slots[selected]
	match int(r.guild_class):
		1:
			_say("UIO_MSG_CHAR_DEL_WANNING_CONFIRM_MEMBER", "Leave the guild first.")
			return
		2:
			_say("UIO_MSG_CHAR_DEL_WANNING_CONFIRM_MASTER", "Disband the guild first.")
			return
	match int(r.academy_class):
		1:
			_say("UIO_MSG_CHAR_DEL_WANNING_CONFIRM_STUDENT", "Leave the Academy first.")
			return
		2:
			_say("UIO_MSG_CHAR_DEL_WANNING_CONFIRM_GUARDIAN", "Disband the Academy first.")
			return
	if _lock != null and _lock.hold(_on_delete_pressed):
		return
	_open_confirm(not r.deleting)

## READ, 0x858950(1): the popup fades in over 0.5 s, the screen dims to 0x80,
## snd_window_open; its text and button are delete's or restore's.
func _open_confirm(delete: bool) -> void:
	_confirm_delete = delete
	var r = _slots[selected]
	if _popup_parts.has(41):
		(_popup_parts[41] as Label).text = r.char_name
	if _popup_parts.has(44):
		(_popup_parts[44] as Label).text = _t("UIO_STT_CHAR_DEL_CONFIRM" if delete else "UIO_STT_CHAR_RECOVERY_CONFIRM",
			"Delete this character?" if delete else "Restore this character?")
	if _popup_parts.has(42):
		(_popup_parts[42] as Button).text = _t("UIO_SELCHAR_CTL_DELETE" if delete else "UIO_STT_CHAR_RECOVERY",
			"Delete" if delete else "Restore")
	_show(ID_POPUP, true)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	if _frame != null:
		_frame.fade(_dim, 0, 0x80, CharSelectMath.FADE_S)
	UiSounds.play("snd_window_open", "character select: the delete confirm")
	_confirm_from = state
	_set_state(S.CONFIRM)

## READ, 0x858c00: 0x7007 action 3 (delete) or 5 (restore) with the name; the
## message line is cleared. The popup stays until the list comes back.
func _on_confirm_accept() -> void:
	if state != S.CONFIRM or selected < 0:
		return
	var char_name: String = _slots[selected].char_name
	_say("", "")
	_busy += 1
	_set_clickable(_popup_parts.get(42), false)
	print("SELECT: %s %s" % ["delete" if _confirm_delete else "restore", char_name])
	if _fake:
		_qa_fake_delete(char_name, _confirm_delete)
		return
	if _confirm_delete:
		NetClient.delete_character(char_name)
	else:
		NetClient.restore_character(char_name)

func _on_confirm_cancel() -> void:
	if state != S.CONFIRM:
		return
	_close_confirm()

## READ, 0x858950(0): the popup and the dimming fade out, snd_window_close.
func _close_confirm() -> void:
	if state != S.CONFIRM:
		return
	_show(ID_POPUP, false)
	if _popup_parts.has(42):
		_set_clickable(_popup_parts[42], true)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _frame != null:
		_frame.fade(_dim, int(_dim.modulate.a * 255.0), 0, CharSelectMath.FADE_S)
	UiSounds.play("snd_window_close", "character select: the delete confirm")
	_set_state(S.ZOOM if _confirm_from == S.ZOOM else S.SELECTED)

## READ, vslot_006: OK -> the list is asked for again and the character is
## re-selected where the camera is (+0x12f = 2); a refusal shows its words
## (the archive's, LobbyNet.code_text) and leaves the popup up.
func _on_delete_result(ok: bool, reason: String) -> void:
	_on_lobby_answer(ok, reason, true)

func _on_restore_result(ok: bool, reason: String) -> void:
	_on_lobby_answer(ok, reason, false)

func _on_lobby_answer(ok: bool, reason: String, deleted: bool) -> void:
	_busy = maxi(_busy - 1, 0)
	if not ok:
		_message.text = reason
		if _popup_parts.has(42):
			_set_clickable(_popup_parts[42], true)
		print("SELECT: %s refused: %s" % ["delete" if deleted else "restore", reason])
		return
	_reselect_index = selected
	_reselect_deleted = deleted
	NetClient.list_characters()

## QA only (OURS): the fake list answers a delete or restore itself.
func _qa_fake_delete(char_name: String, delete: bool) -> void:
	var k := _slot_of(char_name)
	if k >= 0:
		_slots[k].deleting = delete
		_slots[k].minutes_left = CharSelectMath.DELETE_MINUTES if delete else 0
	_reselect_index = k
	_reselect_deleted = delete
	_on_list_result.call_deferred(_records, "")

## READ, vslot_012: the countdown counts its own minutes from the list's
## arrival (+0x120 seconds, +0x124 minutes) and refreshes the text and the
## gauge when the whole minute changes.
func _tick_countdown(delta: float) -> void:
	_clock_s += delta
	if _clock_s > 60.0:
		_clock_min += 1
		_clock_s -= 60.0
	if selected < 0 or selected >= _slots.size() or not _slots[selected].deleting:
		return
	var m := CharSelectMath.minutes_now(_slots[selected].minutes_left, _clock_min)
	if m == _shown_min:
		return
	_shown_min = m
	if _remain.has(52):
		(_remain[52] as RichTextLabel).text = "[center]%s[/center]" % CharSelectMath.pml_to_bbcode(
			CharSelectMath.countdown_text(_raw_text("UIO_MSG_CHAR_DEL_TIME"), m))
	set_gauge(_remain.get(53), CharSelectMath.delete_gauge(m))

# --- Race select ---------------------------------------------------------------------------

## READ, FUN_0085c4a0 (Create, id 12): the titles swap over 5.0 s, Create and
## Back fade out, Cancel 17 in, the arrows and labels out, and the camera
## flies the 4 race keys.
func _on_create_pressed() -> void:
	if not state in LIST_BUTTON_STATES:
		return
	# READ, 0x85de50: a full account is refused before anything moves.
	if _slots.size() >= LobbyNet.MAX_CHARACTERS:
		_message.text = LobbyNet.code_text(LobbyNet.CODE_ACCOUNT_FULL, _text)
		return
	if _frame != null and _frame.title_art != null:
		_frame.fade(_frame.title_art, int(_frame.title_art.modulate.a * 255.0), 0, CharSelectMath.TITLE_SWAP_S)
		_frame.fade(_windows[ID_REGIONTITLE], 0, 255, CharSelectMath.TITLE_SWAP_S)
	_show(ID_CREATE, false)
	_show(ID_BACK, false)
	_show(ID_RACE_CANCEL, true)
	_show(ID_PREV, false)
	_show(ID_NEXT, false)
	_show(ID_PAGE, false)
	_fade_page_labels_out()
	hovered = -1
	# OURS: with no 3D there is no table to fly to (the races are offered as
	# the two panels at once, _arrive_at_table).
	_path = CharSelectMath.race_path(_current_pose()) if stage != null else null
	_set_state(S.RACE_FLY)

## READ, vslot_012 case 7: the idol panels placed over the idols and shown,
## the lizard shown in clip 1.
func _arrive_at_table() -> void:
	if stage != null:
		stage.set_lizard(true)
	_place_idol_panels()
	for id in [ID_EUROPE, ID_CHINA]:
		var p := _windows.get(id) as Control
		if p == null:
			continue
		p.visible = true
		p.modulate.a = 0.0
		if stage == null:
			# OURS, round 684's review: no idols to hover without the 3D, so
			# both panels -- the archive's own race tooltips -- stand side by
			# side and a click on one picks that race.
			var w := size.x if size.x > 0 else 1280.0
			var h := size.y if size.y > 0 else 720.0
			p.position = Vector2(w * 0.5 + (-p.size.x - 10.0 if id == ID_EUROPE else 10.0), h * 0.5 - p.size.y * 0.5)
			p.modulate.a = 1.0
			p.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_state(S.RACE)
	_qa_print_anchors()

## A click on a race panel in the no-3D fallback (OURS).
func _on_race_panel_input(event: InputEvent, idol_index: int) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		fallback_pick_race(idol_index)

func fallback_pick_race(idol_index: int) -> void:
	if stage == null and state == S.RACE:
		_pick_idol(idol_index)

func _place_idol_panels() -> void:
	if stage == null:
		return
	for i in range(2):
		var at = stage.idol_anchor(i)
		var p := _windows[ID_EUROPE if i == 0 else ID_CHINA] as Control
		if at != null:
			p.position = CharSelectMath.idol_panel_position(at, int(p.size.x))

## READ, vslot_012 case 8: the hovered idol's panel fades in, the other out.
func _hover_idol(i: int) -> void:
	if i == hovered_idol:
		return
	hovered_idol = i
	print("SELECT: hover idol %d" % i)
	for j in range(2):
		var p := _windows[ID_EUROPE if j == 0 else ID_CHINA] as Control
		if _frame != null:
			_frame.fade(p, int(roundf(p.modulate.a * 255.0)), 255 if j == i else 0, CharSelectMath.IDOL_PANEL_FADE_S)

## READ, FUN_0085ca10: the pick is kept (race_chosen), the screen fades to
## black over 1.0 s, the panels out over 0.5 s, and the camera flies 1.0 s to
## the idol; then the customize screen.
func _pick_idol(i: int) -> void:
	var race := CharSelectHandoff.race_from_idol_index(i)
	print("SELECT: race_chosen %d (idol %d)" % [race, i])
	race_chosen.emit(race)
	CharSelectHandoff.race = race
	if _black != null:
		_black.visible = true
	if _frame != null:
		_frame.fade(_black, 0, 255, CharSelectMath.IDOL_BLACK_S)
		for id in [ID_EUROPE, ID_CHINA]:
			_frame.fade(_windows[id], int(_windows[id].modulate.a * 255.0), 0, CharSelectMath.FADE_S)
	_show(ID_RACE_CANCEL, false)
	_freeze_buttons()
	for id in [ID_EUROPE, ID_CHINA]:
		if _windows.get(id) != null:
			(_windows[id] as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	_path = CharSelectMath.idol_path(_current_pose(), i) if stage != null else null
	_set_state(S.IDOL_FLY)

func _go_create() -> void:
	_set_state(S.LOADING)
	if change_scene.is_valid():
		change_scene.call(CharSelectHandoff.CREATE_SCENE)
	else:
		CharSelectHandoff.go_create(get_tree(), CharSelectHandoff.race)

## READ, 0x85c7e0 (Cancel 17): the titles swap back over 5.0 s, Create and
## Back return, the panels hide, the camera flies the race keys back.
func _on_race_cancel_pressed() -> void:
	if state != S.RACE and state != S.RACE_FLY:
		return
	if _frame != null and _frame.title_art != null:
		_frame.fade(_frame.title_art, int(_frame.title_art.modulate.a * 255.0), 255, CharSelectMath.TITLE_SWAP_S)
		_frame.fade(_windows[ID_REGIONTITLE], int(_windows[ID_REGIONTITLE].modulate.a * 255.0), 0, CharSelectMath.TITLE_SWAP_S)
	_show(ID_CREATE, true)
	_show(ID_BACK, true)
	_show(ID_RACE_CANCEL, false)
	_show(ID_EUROPE, false)
	_show(ID_CHINA, false)
	hovered_idol = -1
	for id in [ID_EUROPE, ID_CHINA]:
		if _windows.get(id) != null:
			(_windows[id] as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	_path = CharSelectMath.race_back_path(_current_pose()) if stage != null else null
	_set_state(S.RACE_BACK)

# --- Back ------------------------------------------------------------------------------------

## READ, 0x85b560 (id 13): the black fade 0 -> 255 over 0.5 s, the camera
## dollies back up the quay over 2.0 s, then the title.
func _on_back_pressed() -> void:
	if not state in LIST_BUTTON_STATES:
		return
	if _black != null:
		_black.visible = true
	if _frame != null:
		_frame.fade(_black, 0, 255, CharSelectMath.FADE_S)
	_freeze_buttons()
	_path = CharSelectMath.back_path(_current_pose())
	_set_state(S.BACK)

func _leave_to_login() -> void:
	_set_state(S.LOADING)
	if change_scene.is_valid():
		change_scene.call(LOGIN_SCENE)
	else:
		get_tree().change_scene_to_file(LOGIN_SCENE)

## The server went away (round 684's review: Start and Delete were sent into
## nothing, silently). Round 788, READ (slot 40, 0x862450, the same for the
## title, select and create): the NETOFF box (NetOffBox), whose Confirm
## quits the client -- retail never returns to the title here.
func _on_disconnected() -> void:
	if state == S.LOADING or state == S.ENTERING:
		return
	_freeze_buttons()
	_set_state(S.LOADING)
	if netoff_box == null or not is_instance_valid(netoff_box):
		netoff_box = NetOffBox.show_on(self, _media, _text)
	print("SELECT: disconnected -- the box: %s" % netoff_box.message_text())

# --- QA ---------------------------------------------------------------------------------------

## Visits of this screen in this process (the QA luminance line's number).
static var _qa_visits := 0
var _qa_list_s := -1.0
var _qa_luma_done := false

## CharSelectQa's hooks (round 688, OURS, QA only): OPENSRO_QA_SELECT_RACE
## presses Create once the list is up; OPENSRO_QA_SELECT_LUMA measures the
## frame 1.5 s after it (the models' READ 1.0 s fade done).
func _qa_list_tick(delta: float) -> void:
	if _qa_list_s < 0.0:
		_qa_list_s = 0.0
		_qa_visits += 1
	_qa_list_s += delta
	if OS.get_environment("OPENSRO_QA_SELECT_LUMA") != "" and not _qa_luma_done and _qa_list_s >= 1.5:
		_qa_luma_done = true
		_qa_luma()
	_qa_frame_tick()
	if OS.get_environment("OPENSRO_QA_SELECT_RACE") != "" and _qa_list_s >= 2.0 and _slots.size() < LobbyNet.MAX_CHARACTERS:
		print("QA SELECT: pressing Create")
		_on_create_pressed()

func _qa_luma() -> void:
	if stage == null or stage.backdrop == null:
		return
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	var cam := stage.camera()
	var w := img.get_width()
	var h := img.get_height()
	var band1 := _frame.band_bottom_edge() if _frame != null and _frame.layout != null else int(h * 172.0 / 1200.0)
	var down := _frame.role_def("screendown") if _frame != null and _frame.layout != null else null
	var band2 := int(_frame.scaled(down.rect).position.y) if down != null else int(h * 1030.0 / 1200.0)
	# The viewport image is in physical pixels; the bands in the window's.
	var k := float(w) / maxf(size.x, 1.0)
	var band := Rect2i(0, int(band1 * k), w, int((band2 - band1) * k))
	var chars: Array = []
	for d in stage.drawn:
		var dd: CharSelectStage.Drawn = d
		if dd.body != null and dd.holder.visible:
			chars.append(CharSelectQa.screen_rect(cam, dd.body.global_transform, dd.bounds))
	var char_sum := 0.0
	var char_n := 0
	for r in chars:
		var m: float = CharSelectQa.mean_luma(img, r)
		if m >= 0.0:
			char_sum += m
			char_n += 1
	var world = stage.backdrop.world
	var light := world.get("directional_light") as DirectionalLight3D
	var env := (world.get("world_environment") as WorldEnvironment).environment
	print("QA SELECT LUMA visit %d phase %.4f backdrop %.1f characters %.1f (%d) light %s x %.2f ambient %s x %.2f tonemap %d exposure %.2f frame %d" % [
		_qa_visits, float(world.get("_env_time")), CharSelectQa.mean_luma(img, band, chars),
		char_sum / char_n if char_n > 0 else -1.0, char_n, light.light_color, light.light_energy,
		env.ambient_light_color, env.ambient_light_energy, env.tonemap_mode, env.tonemap_exposure, Engine.get_frames_drawn()])
	var dir := OS.get_environment("OPENSRO_QA_SELECT_SHOT_DIR")
	if dir != "":
		img.save_png("%s/select_visit%d.png" % [dir, _qa_visits])
	await _qa_body_luma(img)

## Round 688's review (OURS, QA): each body's own pixels on select against the
## same character in the customize screen's preview (CharCreatePreview, the
## backdrop's zone light, the zoomed-out pose), mean Rec. 709 luma of each.
## The body's pixels are those that change when it is hidden, its meshes'
## shadows switched off for that comparison so the ground they darken is not
## counted; the luma itself is read from the real frame `img`.
func _qa_body_luma(img: Image) -> void:
	var cam := stage.camera()
	var meshes: Array[GeometryInstance3D] = []
	var casts: Array = []
	for d in stage.drawn:
		var dd: CharSelectStage.Drawn = d
		if dd.body == null:
			continue
		for n in dd.body.find_children("*", "GeometryInstance3D", true, false):
			meshes.append(n as GeometryInstance3D)
			casts.append((n as GeometryInstance3D).cast_shadow)
			(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _qa_frames(3)
	var unshadowed := get_viewport().get_texture().get_image()
	var shown := []
	for d in stage.drawn:
		shown.append((d as CharSelectStage.Drawn).holder.visible)
		(d as CharSelectStage.Drawn).holder.visible = false
	await _qa_frames(3)
	var empty := get_viewport().get_texture().get_image()
	for i in range(stage.drawn.size()):
		(stage.drawn[i] as CharSelectStage.Drawn).holder.visible = shown[i]
	for i in range(meshes.size()):
		meshes[i].cast_shadow = casts[i]
	var zl = stage.backdrop.world.get("_portrait_zone_light")
	for k in range(stage.drawn.size()):
		var dd: CharSelectStage.Drawn = stage.drawn[k]
		if dd.body == null or not shown[k]:
			continue
		var r := CharSelectQa.screen_rect(cam, dd.body.global_transform, dd.bounds).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
		var sum := 0.0
		var n := 0
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				var a := unshadowed.get_pixel(x, y)
				var b := empty.get_pixel(x, y)
				if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.03:
					var c := img.get_pixel(x, y)
					sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
					n += 1
		var select_luma := sum / n * 255.0 if n > 0 else -1.0
		# The same character in the customize preview.
		var pv := CharCreatePreview.new()
		pv.size = Vector2i(512, 768)
		pv.appearance = stage.appearance
		add_child(pv)
		if zl is Array and (zl as Array).size() == 2:
			pv.set_zone_light(zl[0], zl[1])
		var items: Array = []
		items.append_array(dd.record.items)
		items.append_array(dd.record.avatars)
		pv.show_character(dd.record.ref_obj_id, dd.record.scale, items, true)
		pv.set_yaw(0.0)
		pv.set_pose(CharCreateView.pose_for(false, pv.height_factor(), pv.body != null and pv.body.is_woman))
		await _qa_frames(3)
		var pimg := pv.get_texture().get_image()
		var psum := 0.0
		var pn := 0
		for y in range(pimg.get_height()):
			for x in range(pimg.get_width()):
				var c := pimg.get_pixel(x, y)
				if c.a > 0.99:
					psum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
					pn += 1
		var preview_luma := psum / pn * 255.0 if pn > 0 else -1.0
		var vis := 0
		var hid := 0
		var portrait_mats := 0
		for m in dd.body.find_children("*", "MeshInstance3D", true, false):
			if (m as MeshInstance3D).visible:
				vis += 1
			else:
				hid += 1
			var mo := (m as MeshInstance3D).material_override
			if mo is ShaderMaterial and (mo as ShaderMaterial).shader != null and (mo as ShaderMaterial).shader.code.contains("modulate_scale"):
				portrait_mats += 1
		print("QA SELECT BODY %d %s (%d) select %.1f over %d px, preview %.1f over %d px, ratio %.2f; meshes %d shown, %d hidden, %d in the character light" % [k, dd.record.char_name,
			dd.record.ref_obj_id, select_luma, n, preview_luma, pn, preview_luma / select_luma if select_luma > 0.0 else 0.0, vis, hid, portrait_mats])
		pv.queue_free()

## OPENSRO_QA_SELECT_FRAMES=1 (OURS, QA, round 688's review): from 3 s to 8 s
## after the list is up, the mean and worst wall time of a frame and the
## viewport's measured render time on the CPU and the GPU (the frame is
## capped by vsync on the box, so the render times are the cost), then quit.
var _qa_frame_us := -1
var _qa_frame_sum := 0
var _qa_frame_n := 0
var _qa_frame_max := 0
var _qa_render_cpu := 0.0
var _qa_render_gpu := 0.0
func _qa_frame_tick() -> void:
	if OS.get_environment("OPENSRO_QA_SELECT_FRAMES") == "":
		return
	var vp := get_viewport().get_viewport_rid()
	if _qa_list_s < 3.0:
		RenderingServer.viewport_set_measure_render_time(vp, true)
		return
	var now := Time.get_ticks_usec()
	if _qa_frame_us >= 0:
		var dt := now - _qa_frame_us
		_qa_frame_sum += dt
		_qa_frame_n += 1
		_qa_frame_max = maxi(_qa_frame_max, dt)
		_qa_render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		_qa_render_gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	_qa_frame_us = now
	if _qa_list_s >= 8.0 and _qa_frame_n > 0:
		print("QA SELECT FRAMES %d frames, mean %.2f ms, worst %.2f ms, render cpu %.3f ms gpu %.3f ms (%s light)" % [_qa_frame_n,
			_qa_frame_sum / 1000.0 / _qa_frame_n, _qa_frame_max / 1000.0, _qa_render_cpu / _qa_frame_n, _qa_render_gpu / _qa_frame_n,
			"Godot" if OS.get_environment("OPENSRO_QA_SELECT_GODOT_LIGHT") != "" else "character"])
		get_tree().quit()

## OPENSRO_QA_PENDING_PROBE=1 (round 719, OURS, QA): the pending character's
## translucency measured. 2.5 s into the list it selects the first character
## pending deletion (the camera flies to it, as the user's screenshot); 1.0 s
## after the fly ends it freezes every pose and switches the bodies' shadows off, then saves
## the same frame with that character hidden, at 255, at its own 0xcc and
## hidden again to OPENSRO_QA_SELECT_SHOT_DIR (bg1, opaque, pending, bg2 .png)
## and quits; the camera's path is held too. The effective alpha of a pixel is
## (P - B) / (O - B); one translucent sheet gives the same value everywhere.
var _qa_pending_stage := 0
var _qa_pending_s := 0.0
func _qa_pending_probe_tick(delta: float) -> void:
	if OS.get_environment("OPENSRO_QA_PENDING_PROBE") == "" or stage == null:
		return
	var k := -1
	for i in range(_slots.size()):
		if _slots[i].deleting:
			k = i
			break
	if k < 0 or k >= stage.drawn.size():
		return
	if _qa_pending_stage == 0:
		if state == S.LIST:
			_qa_pending_s += delta
			if _qa_pending_s >= 2.5:
				_qa_pending_stage = 1
				_qa_pending_s = 0.0
				_select(k, false)
	elif _qa_pending_stage == 1:
		if state == S.SELECTED:
			_qa_pending_s += delta
			if _qa_pending_s >= 1.0:
				_qa_pending_stage = 2
				_qa_pending_probe(stage.drawn[k])

## QA (round 719): while set the camera path does not advance.
var _qa_camera_frozen := false

func _qa_pending_probe(d: CharSelectStage.Drawn) -> void:
	stage.qa_frozen = true
	_qa_camera_frozen = true
	for line in stage.qa_texture_alpha_report(d):
		print("QA PENDING TEXTURE %s" % line)
	# OPENSRO_QA_PENDING_SHADOWS=1 keeps the bodies' shadows (round 719's
	# review, finding 2: the shadow at 0xcc is what is measured then).
	if OS.get_environment("OPENSRO_QA_PENDING_SHADOWS") == "":
		for dd in stage.drawn:
			if (dd as CharSelectStage.Drawn).body == null:
				continue
			for n in (dd as CharSelectStage.Drawn).body.find_children("*", "GeometryInstance3D", true, false):
				(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var dir := OS.get_environment("OPENSRO_QA_SELECT_SHOT_DIR")
	# The background twice, first and last: a pixel where the two differ is
	# animated (water, sails) and is left out of the measurement.
	# "one" is alpha 1/255 (the review's check, finding 1): the body adds at
	# most 1/255 of its own colour, so inside its silhouette the frame must
	# equal the background -- a depth pass hiding what lies behind fails it.
	var shots := [["bg1", 0], ["opaque", 255], ["pending", CharSelectMath.PENDING_ALPHA], ["one", 1], ["bg2", 0]]
	for sh in shots:
		var a: int = sh[1]
		stage.qa_set_alpha(d, a)
		await _qa_frames(4)
		var img := get_viewport().get_texture().get_image()
		if dir != "" and img != null:
			img.save_png("%s/%s.png" % [dir, sh[0]])
		print("QA PENDING PROBE alpha %d frame %d %s" % [a, Engine.get_frames_drawn(), stage.qa_fade_report(d)])
	print("QA PENDING PROBE done")
	get_tree().quit()

func _qa_frames(n: int) -> void:
	for i in range(n):
		await RenderingServer.frame_post_draw

func _qa_reload_tick() -> void:
	var want := OS.get_environment("OPENSRO_QA_SELECT_RELOAD")
	if want == "" or _qa_reloads >= want.to_int():
		return
	if _qa_reload_at < 0.0:
		_qa_reload_at = Time.get_ticks_msec() / 1000.0 + 2.0
	elif Time.get_ticks_msec() / 1000.0 >= _qa_reload_at:
		_qa_reloads += 1
		print("QA SELECT: reload %d of %s" % [_qa_reloads, want])
		get_tree().change_scene_to_file(CharSelectHandoff.SELECT_SCENE)

## Where to click, for a scripted real-input run (OURS): each character's
## label anchor and its pick-box middle, and the idols' anchors.
func _qa_print_anchors() -> void:
	if stage == null:
		return
	var cam := stage.camera()
	if state == S.RACE:
		for i in range(2):
			var key: String = ["europe", "china"][i]
			if stage.props.has(key):
				var n := (stage.props[key] as Node3D).get_child(0) as Node3D
				var c := n.global_transform * (stage._prop_bounds[key] as AABB).get_center()
				var s := cam.unproject_position(c)
				print("QA SELECT: idol %d at (%d, %d)" % [i, int(s.x), int(s.y)])
		return
	for id in [ID_PREV, ID_NEXT]:
		var b := _windows[id] as Control
		if b.visible and b.mouse_filter == Control.MOUSE_FILTER_STOP:
			var m := b.position + b.size / 2.0
			print("QA SELECT: arrow %d at (%d, %d)" % [id, int(m.x), int(m.y)])
	for k in range(stage.drawn.size()):
		var d: CharSelectStage.Drawn = stage.drawn[k]
		if d.body == null or k / CharSelectMath.PER_PAGE != _page:
			continue
		var c: Vector3 = d.body.global_transform * d.bounds.get_center()
		var s := cam.unproject_position(c)
		var front := d.body.global_transform.basis * Vector3(0, 0, -1)
		var to_cam := (cam.global_position - c)
		front.y = 0.0
		to_cam.y = 0.0
		var facing := rad_to_deg(front.normalized().angle_to(to_cam.normalized())) if front.length() > 0.0 and to_cam.length() > 0.0 else -1.0
		print("QA SELECT: slot %d %s at (%d, %d), body front %.1f deg from the camera" % [k, d.record.char_name, int(s.x), int(s.y), facing])
