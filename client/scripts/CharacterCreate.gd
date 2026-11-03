extends Control

## The character customize screen (round 685): retail's CPSCharacterCreateChina
## and CPSCharacterCreateEurope, built from the player's own Media.pk2 --
## `resinfo\pscharactercreatechina.txt` / `pscharactercreate_europe.txt`
## (every control, art and text key), the 3D backdrop of 98/168 or 105/79
## turning slowly, and the chosen character drawn over it.
##
## The rules (ranges, starting values, Europe's weapon -> armour rule, the
## tooltips, Confirm's checks, the create request) are CharCreateModel's; the
## motion (spin, zoom, backdrop turn) CharCreateView's; the model
## CharCreatePreview's. This file places and wires them. Everything is READ
## from sro_client.exe unless marked (docs/protocol/charselect.md section 4,
## WORLD_ISSUES round 685):
##
## **Placement** (OnCreate 0x84fbc0, 0x84ff83..0x8501ec). Only the bands (1,
## 2) and the black fade (14) are scaled to the screen (FUN_00849c70); every
## other window keeps its layout size in screen pixels, placed by code:
## - "mid" = halfway between band 1's bottom and band 2's top;
## - OK (10) at (W - 209, band 2's top + 27); Cancel (11) at (W - 105, the same);
## - the customize panel (7) at (75, mid - 155);
## - the rotate panel (8) at (W - 165, band 2's top - 69);
## - the tooltip (9) at (rotate.x - 59, rotate.y - 219) for China; Europe's
##   taller window (212x250) at (rotate.x - 69, rotate.y - 270) (0x853ea2..
##   0x853eca: -0x45, -0x10e);
## - the confirm box (13) centred;
## - the message line (500) at (26, band 2's top + 29), W - 26 by 100;
## - the title (3) and China's calligraphy (5) where the layout puts them.
## The windows are created in reverse file order (round 583), so from the
## back: bands, title, message line, calligraphy, the model (6), the panels,
## OK / Cancel, the dimmer (12), the box (13), the black fade (14).
##
## **Opening:** window 14 (black) fades 255 -> 0 over 0.5 s; when it is
## done the title (3) and the calligraphy (5) fade 0 -> 255 over 0.5 s
## (SendCharacterCreateChina's fade-end branch, 0x84e610). OURS: the black
## holds until the backdrop's first view is built (retail loads its region
## before its first frame; here the cells stream).
##
## **Confirm** (10): the screen's own checks (CharCreateModel.confirm_error),
## then the name's (0x84eac0: 2..12 units, then the AbuseFilter test,
## NameFilter -- round 788); a refusal shows in the message line with
## snd_error. Then the box (13) fades in over 0.5 s with the name in 31, and
## the dimmer (12) goes 0 -> 0x80 (0x84ec00). Create (32) fades the box out
## and the request is sent when that fade ends (0x84e610); the OK reply fades
## window 14 to black over 0.5 s (0x84cff0) and returns to select. A refusal
## is shown in the message line in the archive's words (LobbyNet.code_text).
## INFERRED: the box's Cancel (33) and Create fade it and the dimmer out over
## the same 0.5 s (their handlers were not read).
##
## **Cancel** (11, 0x84d300): straight back to select, no fade.
##
## **The name check** (42, 0x84ed90): the name's own checks first; then 0x7007
## action 4. OK shows UIO_MSG_ERROR_ADMISSON; a refusal its code's words.
##
## **Hover** (0x850540..0x8505d5): the slider under the cursor becomes the
## tooltip's subject when it is not already; a slider moved does the same.

const FADE_S := 0.5
## OURS (round 685's review): how long a create waits for its 0xB007 before
## the screen is given back, and what it says then (no retail key fits).
const CREATE_REPLY_TIMEOUT_S := 10.0
const CREATE_TIMEOUT_TEXT := "The server did not answer the create request."
## READ: the tooltip window's offset from the rotate window (see the header).
const EXPLAIN_OFFSET := {
	CharCatalog.RACE_CHINA: Vector2(-0x3b, -0xdb),
	CharCatalog.RACE_EUROPE: Vector2(-0x45, -0x10e),
}
## OURS: the backdrop's window around its target (the title's TITLE_RADIUS).
const BACKDROP_RADIUS := 1
## OURS: how long the black fade waits for the backdrop's first view.
const BACKDROP_WAIT_MS := 8000
const TEXT_TABLE_PATH := "server_dep\\silkroad\\textdata\\textuisystem.txt"
const SECTION_CUSTOM := "Custom"
const SECTION_EXPLAIN := "Explain"
const SECTION_ROTATE := "Rotate"
const SECTION_SLIDER := "Slider"
const SECTION_WCREATE := "WCreate"
## The art states every outer button has (MEASURED in Media.pk2).
const STATES := ["", "_focus", "_press"]
## READ (0x84f630 / 0x84f540): the sex buttons' art for each state.
const SEX_ART := {
	CharCatalog.SEX_MAN: ["interface\\outer\\man_on.ddj", "interface\\outer\\woman_off.ddj"],
	CharCatalog.SEX_WOMAN: ["interface\\outer\\man_off.ddj", "interface\\outer\\woman_on.ddj"],
}
const ZOOM_IN_ART := "interface\\outer\\zoomin.ddj"
const ZOOM_OUT_ART := "interface\\outer\\zoomout.ddj"
## OURS: words for keys the archive lacks (a dev run without the table).
const FALLBACK_TEXT := {
	"UIO_NEWCHAR_STT_NAME": "Name", "UIO_NEWCHAR_STT_SEX": "Sex", "UIO_NEWCHAR_STT_FIGURE": "Figure",
	"UIO_NEWCHAR_STT_HEIGHT": "Height", "UIO_NEWCHAR_STT_VOLUME": "Volume",
	"UIO_NEWCHAR_STT_PROTECTOR": "Cloth", "UIO_NEWCHAR_STT_WEAPON": "Weapon",
	"UIO_NEWCHAR_CTL_CHECK_OVERLAP": "Name Check", "UIO_NEWCHAR_CTL_MALE": "Male",
	"UIO_NEWCHAR_CTL_FEMALE": "Female", "UIO_NEWCHAR_CTL_CONFIRM": "Confirm",
	"UIO_COMMON_CTL_CANCEL": "Cancel", "UIO_COMMON_CTL_CREATE": "Create",
	"UIO_NEWCHAR_MSG_CREATE": "Create a new character?",
	"UIO_MSG_ERROR_CHARACTER_NAME_STRING": "A name is 2 to 12 letters or digits.",
	"UIO_MSG_ERROR_CHARACTER_WRONGSTRING": "That name has a character that cannot be used.",
	"UIO_MSG_ERROR_CHARACTER_SELECTWEAPON": "Choose a weapon first.",
	"UIO_MSG_ERROR_CHARACTER_SELECTARMOR": "Choose an armour set first.",
	"UIO_MSG_ERROR_ADMISSON": "That name can be used.",
}

enum State { OPENING, READY, BOX, SENDING, LEAVING }

var _state := State.OPENING
var _race := CharCatalog.RACE_CHINA
var _media: Pk2Reader = null
var _data: Pk2Reader = null
var _text: UiTextTable = null
var _layout: UiLayoutParser.LayoutDef = null
var _main: UiLayoutParser.SectionDef = null
var _model: CharCreateModel = null
var _view := CharCreateView.new()
var _appearance: CharacterAppearance = null
var _preview: CharCreatePreview = null
var _preview_rect: TextureRect = null
var _backdrop: FrontEndBackdrop = null
var _frame: FrontEndFrame = null
var _back_image: TextureRect = null
var _panel: TextureRect = null
var _rotate_panel: TextureRect = null
var _explain: TextureRect = null
var _tip_title: Label = null
var _tip_text: Label = null
var _name_edit: LineEdit = null
var _check: TextureButton = null
var _male: TextureButton = null
var _female: TextureButton = null
var _sliders := {} # CharCreateModel.Ctl -> CharCreateSlider
var _zoom: TextureButton = null
var _ok: TextureButton = null
var _cancel: TextureButton = null
var _message: Label = null
var _dim: ColorRect = null
var _box: TextureRect = null
var _box_name: Label = null
var _box_create: TextureButton = null
var _box_cancel: TextureButton = null
var _fade: ColorRect = null
var _tip_control := -1
var _started_ms := 0
var _usable_ms := -1
var _backdrop_ready := false
var _create_pending := false
var _box_closing := false
var _send_serial := 0
var _qa_state := ""
## OPENSRO_QA_CREATE_SHOTS="spec|spec|..." with OPENSRO_QA_CREATE_SHOT_DIR:
## each spec (as OPENSRO_QA_CREATE_STATE's) is applied in turn once the
## backdrop's scene is built, and the screen saved QA_SHOT_SETTLE_S later as
## shot_<n>.png; the client quits after the last. Renders only, off in play.
var _qa_shots: PackedStringArray = []
var _qa_shot_dir := ""
var _qa_shot_index := -1
var _qa_shot_at := 0.0
var _scene_ready := false
const QA_SHOT_SETTLE_S := 2.5

func _ready() -> void:
	# Round 858: the window hole census in a real run (OPENSRO_QA_HOLES; HoleCensus).
	HoleCensus.qa_hook(self)
	_started_ms = Time.get_ticks_msec()
	_print_memory("open #%d" % (_qa_opens + 1))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_race = _pick_race()
	_media = FrontEndUi.open_media()
	_data = AssetArchives.data()
	FrontEndUi.apply_client_font(self, _media)
	_text = _load_text()
	NetClient.character_create_result.connect(_on_create_result)
	NetClient.name_check_result.connect(_on_name_check_result)
	# Round 788, READ (slot 40, 0x862450): a dropped connection is the NETOFF
	# box, whose Confirm quits (NetOffBox).
	NetClient.disconnected.connect(_on_disconnected)
	_layout = _load_layout()
	_main = _layout.sections.get(CharCreateModel.SECTION_MAIN[_race]) if _layout != null else null
	if _media != null and _data != null:
		var t0 := Time.get_ticks_msec()
		_appearance = CharacterAppearance.from_archives(_data, _media)
		print("CREATE: catalogue and builder in %d ms (%d entries)" % [Time.get_ticks_msec() - t0, _appearance.catalog().size()])
	if _main == null or _appearance == null:
		_build_bare()
		return
	_model = CharCreateModel.create(_appearance.catalog(), _race, true)
	_begin_backdrop()
	_build()
	_apply_all(true)
	_relayout()
	resized.connect(_relayout)
	_qa_state = OS.get_environment("OPENSRO_QA_CREATE_STATE")
	_qa_shot_dir = OS.get_environment("OPENSRO_QA_CREATE_SHOT_DIR")
	if _qa_shot_dir != "":
		_qa_shots = OS.get_environment("OPENSRO_QA_CREATE_SHOTS").split("|", false)
		if _qa_shots.is_empty():
			_qa_shots = PackedStringArray([""])
	print("CREATE: %s screen built in %d ms" % ["China" if _race == CharCatalog.RACE_CHINA else "Europe", Time.get_ticks_msec() - _started_ms])

## How many times this screen has opened in this run (the QA race list).
static var _qa_opens := 0

## The race the select screen chose (CharSelectHandoff, round 684). OURS:
## China when none was (the create screen opened directly). QA:
## OPENSRO_QA_CREATE_RACE="europe" or a list "europe,china,..." taken one
## per opening (the last repeating), for runs before the race select exists.
func _pick_race() -> int:
	var qa := OS.get_environment("OPENSRO_QA_CREATE_RACE").to_lower().split(",", false)
	_qa_opens += 1
	if not qa.is_empty():
		var pick := qa[mini(_qa_opens - 1, qa.size() - 1)].strip_edges()
		if pick == "europe":
			return CharCatalog.RACE_EUROPE
		if pick == "china":
			return CharCatalog.RACE_CHINA
	return CharCatalog.RACE_EUROPE if CharSelectHandoff.race == CharCatalog.RACE_EUROPE else CharCatalog.RACE_CHINA

func _load_text() -> UiTextTable:
	if NetClient.lobby_text != null:
		return NetClient.lobby_text
	if _media == null:
		return null
	var entry := ObjectLoader.find_file(_media, TEXT_TABLE_PATH)
	if entry == null:
		return null
	NetClient.lobby_text = UiTextTable.parse(_media.read_file(entry))
	return NetClient.lobby_text

func _load_layout() -> UiLayoutParser.LayoutDef:
	if _media == null:
		return null
	var path: String = CharCreateModel.LAYOUT_EUROPE if _race == CharCatalog.RACE_EUROPE else CharCreateModel.LAYOUT_CHINA
	var entry := ObjectLoader.find_file(_media, path)
	if entry == null:
		print("CREATE: no %s in Media.pk2" % path)
		return null
	return UiLayoutParser.parse(_media.read_file(entry), true, PackedStringArray())

## The archive's words for a key. A key the table holds with no English text
## shows nothing, as the client's would (MEASURED: the weapon explanations'
## English column is empty in this archive); our words only when the table
## is missing or lacks the key.
func _t(key: String) -> String:
	if _text != null and key != "" and _text.has(key):
		var s := _text.get_text(key, "").strip_edges()
		return "" if s == key else s.replace("\\n", "\n")
	return FALLBACK_TEXT.get(key, key)

func _def(section: String, id: int) -> UiLayoutParser.ControlDef:
	if _layout == null or not _layout.sections.has(section):
		return null
	return FrontEndFrame.by_id(_layout.sections[section], id)

func _main_def(id: int) -> UiLayoutParser.ControlDef:
	return FrontEndFrame.by_id(_main, id)

func _ddj(path: String) -> Texture2D:
	return FrontEndUi.load_ddj(_media, path) if path != "" else null

# --- building ---------------------------------------------------------------

## No archive or no layout: a plain note and the way back.
func _build_bare() -> void:
	add_child(FrontEndUi.ground(Color(0, 0, 0)))
	var l := Label.new()
	l.text = "No game data: the customize screen needs your Media.pk2 and Data.pk2."
	l.position = Vector2(40, 40)
	add_child(l)
	var b := Button.new()
	b.text = "Cancel"
	b.position = Vector2(40, 80)
	b.pressed.connect(_on_cancel)
	add_child(b)
	_state = State.READY

func _begin_backdrop() -> void:
	FrontEndBackdrop.preload_world()
	_backdrop = FrontEndBackdrop.new()
	_backdrop.name = "CreateBackdrop"
	add_child(_backdrop)
	var phase := CharSelectHandoff.front_end_phase()
	var region: Vector2i = CharCreateView.BACKDROP[_race]["region"]
	if not _backdrop.begin(region, BACKDROP_RADIUS, phase):
		print("CREATE: no backdrop for %d/%d" % [region.x, region.y])
		_backdrop.queue_free()
		_backdrop = null
		_backdrop_ready = true
		return
	_backdrop.show_pose(CharCreateView.backdrop_pose(_race, Time.get_ticks_msec()))
	_backdrop.first_view_ready.connect(_on_backdrop_ready, CONNECT_ONE_SHOT)
	_backdrop.scene_ready.connect(func(): _scene_ready = true, CONNECT_ONE_SHOT)

func _on_backdrop_ready() -> void:
	_backdrop_ready = true
	print("CREATE: backdrop first view at %d ms" % (Time.get_ticks_msec() - _started_ms))

## The frame: FrontEndFrame over a "Title" section made of this layout's own
## bands (1, 2) and title (3, as the frame's 5). Archive art only (OURS: the
## operator's branding is the title's; see WORLD_ISSUES round 685).
func _build_frame() -> void:
	var title := UiLayoutParser.SectionDef.new()
	title.name = "Title"
	for pair in [[CharCreateModel.ID_BAND_UP, FrontEndFrame.ID_SCREENUP], [CharCreateModel.ID_BAND_DOWN, FrontEndFrame.ID_SCREENDOWN], [CharCreateModel.ID_TITLE, FrontEndFrame.ID_TITLE]]:
		var d := _main_def(pair[0])
		if d != null:
			var c := d.with_rect(d.rect)
			c.id = pair[1]
			title.controls.append(c)
	var synthetic := UiLayoutParser.LayoutDef.new()
	synthetic.sections["Title"] = title
	_frame = FrontEndFrame.new()
	_frame.name = "CreateFrame"
	add_child(_frame)
	_frame.build(_media, null, FrontEndTheme.custom_dir(), "", synthetic)
	for n in [_frame.logo, _frame.big_logo, _frame.version_label, _frame.copyright_label, _frame.cover_top, _frame.cover_bottom]:
		if n != null:
			n.visible = false
	_frame.set_alpha(_frame.title_art, 0)

func _build() -> void:
	_build_frame()
	# The message line (500).
	_message = _label(_main_def(CharCreateModel.ID_MESSAGE), "")
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_message)
	# China's calligraphy (5); Europe's window 5 has no art.
	var bd := _main_def(CharCreateModel.ID_BACKIMAGE)
	if bd != null and bd.ddj != "":
		_back_image = _art(bd)
		_back_image.modulate.a = 0.0
		add_child(_back_image)
	# The model (6).
	_preview = CharCreatePreview.new()
	_preview.name = "CreatePreview"
	_preview.appearance = _appearance
	_preview.size = Vector2i(maxi(int(size.x), 2), maxi(int(size.y), 2))
	add_child(_preview)
	_preview_rect = TextureRect.new()
	_preview_rect.name = "CreatePreviewView"
	_preview_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_preview_rect.texture = _preview.get_texture()
	add_child(_preview_rect)
	# The model renders at the screen's physical pixels, not the UI's units
	# (round 695, ViewportPixels): at UI scale 2.0 it was drawn magnified 2x.
	ViewportPixels.attach(_preview_rect, _preview)
	if _backdrop != null and _backdrop.world != null:
		var zl = _backdrop.world.get("_portrait_zone_light")
		if zl is Array and (zl as Array).size() == 2:
			_preview.set_zone_light(zl[0], zl[1])
	_build_custom_panel()
	_build_rotate_panel()
	_build_explain()
	_ok = _button(_main_def(CharCreateModel.ID_OK))
	_ok.pressed.connect(_on_confirm)
	add_child(_ok)
	_cancel = _button(_main_def(CharCreateModel.ID_CANCEL))
	_cancel.pressed.connect(_on_cancel)
	add_child(_cancel)
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 1)
	_dim.modulate.a = 0.0
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	_build_box()
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 1)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)

func _build_custom_panel() -> void:
	_panel = _art(_main_def(CharCreateModel.ID_CUSTOM))
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	var sec: UiLayoutParser.SectionDef = _layout.sections.get(SECTION_CUSTOM)
	if sec == null:
		return
	for d in sec.controls:
		if d.type == "CIFStatic" and d.text != "":
			var l := _label(d, _t(d.text))
			_panel.add_child(l)
	var ed := FrontEndFrame.by_id(sec, CharCreateModel.ID_NAME)
	_name_edit = CifEdit.new()
	KeyInput.line_edit_as_42(_name_edit)  # round 754
	_name_edit.name = "NameEdit"
	_name_edit.max_length = CharCreateModel.NAME_MAX
	_name_edit.context_menu_enabled = false
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "focus", "read_only"]:
		_name_edit.add_theme_stylebox_override(s, empty)
	_name_edit.add_theme_font_size_override("font_size", _font_size(ed.font_index if ed != null else 0))
	_name_edit.add_theme_color_override("font_color", ed.font_color if ed != null else Color.WHITE)
	# Round 848: CIFEdit's caret and rules (CifEdit, READ); the limit
	# stays the name's own (as bytes, CifEdit's 0x634f80 rule).
	CifEdit.style(_name_edit, ed.font_color if ed != null else Color.WHITE)
	# Round 859: GDR_EDIT_NAME's own layout (HAlign 0, VAlign 1), as CIFEdit
	# draws it; the caret by its rule (CifEdit.lay_out).
	if ed != null:
		_name_edit.lay_out(ed.client_rect, ed.halign, ed.valign)
	if ed != null:
		_place_centred(_name_edit, Rect2(ed.rect))
	_name_edit.text_submitted.connect(func(_t): _on_confirm())
	_panel.add_child(_name_edit)
	_check = _button(FrontEndFrame.by_id(sec, CharCreateModel.ID_CHECK))
	_check.pressed.connect(_on_name_check)
	_panel.add_child(_check)
	_male = _button(FrontEndFrame.by_id(sec, CharCreateModel.ID_MALE))
	_male.pressed.connect(func(): _on_sex(CharCatalog.SEX_MAN))
	_panel.add_child(_male)
	_female = _button(FrontEndFrame.by_id(sec, CharCreateModel.ID_FEMALE))
	_female.pressed.connect(func(): _on_sex(CharCatalog.SEX_WOMAN))
	_panel.add_child(_female)
	var sdefs := {}
	var sart := {}
	for id in [CharCreateModel.ID_SLIDER_PREV, CharCreateModel.ID_SLIDER_NEXT, CharCreateModel.ID_SLIDER_THUMB]:
		var d := _def(SECTION_SLIDER, id)
		sdefs[id] = d
		sart[id] = _state_textures(d.ddj if d != null else "")
	for c in CharCreateModel.SLIDER_IDS:
		var d := FrontEndFrame.by_id(sec, CharCreateModel.SLIDER_IDS[c])
		var s := CharCreateSlider.new()
		s.name = "Slider%d" % CharCreateModel.SLIDER_IDS[c]
		if d != null:
			s.position = Vector2(d.rect.position)
			s.size = Vector2(d.rect.size)
		s.build(sdefs, sart)
		var ctl: int = c
		s.value_changed.connect(func(v): _on_slider(ctl, v))
		s.hovered.connect(func(): _show_tip(ctl, false))
		_panel.add_child(s)
		_sliders[c] = s
	var order := CharCreateModel.slider_order_from_layout(sec)
	print("CREATE: slider order from the layout: %s" % ", ".join(order.map(func(c): return CharCreateModel.Ctl.keys()[c])))

func _build_rotate_panel() -> void:
	_rotate_panel = _art(_main_def(CharCreateModel.ID_ROTATE))
	_rotate_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_rotate_panel)
	for pair in [[CharCreateModel.ID_ROTATE_LEFT, -1], [CharCreateModel.ID_ROTATE_RIGHT, 1]]:
		var b := _texture_button(_def(SECTION_ROTATE, pair[0]))
		var dir: int = pair[1]
		b.pressed.connect(func(): _view.click(dir))
		_rotate_panel.add_child(b)
	_zoom = _texture_button(_def(SECTION_ROTATE, CharCreateModel.ID_ZOOM))
	_zoom.pressed.connect(_on_zoom)
	_rotate_panel.add_child(_zoom)

func _build_explain() -> void:
	_explain = _art(_main_def(CharCreateModel.ID_EXPLAIN))
	add_child(_explain)
	_tip_title = _label(_def(SECTION_EXPLAIN, CharCreateModel.ID_TIP_TITLE), "")
	_explain.add_child(_tip_title)
	_tip_text = _label(_def(SECTION_EXPLAIN, CharCreateModel.ID_TIP_TEXT), "")
	_tip_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_explain.add_child(_tip_text)

func _build_box() -> void:
	_box = _art(_main_def(CharCreateModel.ID_BOX))
	_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_box.visible = false
	add_child(_box)
	var sec: UiLayoutParser.SectionDef = _layout.sections.get(SECTION_WCREATE)
	if sec == null:
		return
	for d in sec.controls:
		if d.type == "CIFStatic" and d.id != CharCreateModel.ID_BOX_NAME:
			_box.add_child(_label(d, _t(d.text)))
	_box_name = _label(FrontEndFrame.by_id(sec, CharCreateModel.ID_BOX_NAME), "")
	_box.add_child(_box_name)
	_box_create = _button(FrontEndFrame.by_id(sec, CharCreateModel.ID_BOX_CREATE))
	_box_create.pressed.connect(_on_box_create)
	_box.add_child(_box_create)
	_box_cancel = _button(FrontEndFrame.by_id(sec, CharCreateModel.ID_BOX_CANCEL))
	_box_cancel.pressed.connect(_on_box_cancel)
	_box.add_child(_box_cancel)

# --- widgets ----------------------------------------------------------------

func _font_size(index: int) -> int:
	return UiBuilder.FONT_SIZES[clampi(index, 0, UiBuilder.FONT_SIZES.size() - 1)]

## A layout static as a TextureRect of its art at its own size.
func _art(d: UiLayoutParser.ControlDef) -> TextureRect:
	var tr := TextureRect.new()
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	if d != null:
		tr.texture = _ddj(d.ddj)
		tr.size = Vector2(d.rect.size)
		tr.position = Vector2(d.rect.position)
	return tr

## A layout text control as a Label: its rect, font, colour and alignment.
func _label(d: UiLayoutParser.ControlDef, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = false
	if d != null:
		l.position = Vector2(d.rect.position)
		l.size = Vector2(d.rect.size)
		l.add_theme_font_size_override("font_size", _font_size(d.font_index))
		l.add_theme_color_override("font_color", d.font_color)
		l.horizontal_alignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][clampi(d.halign, 0, 2)]
		l.vertical_alignment = [VERTICAL_ALIGNMENT_TOP, VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_BOTTOM][clampi(d.valign, 0, 2)]
	return l

## [normal, focus, press] textures of an art path.
func _state_textures(ddj: String) -> Array:
	var out: Array = []
	if ddj == "":
		return out
	for st in STATES:
		out.append(_ddj(ddj.get_basename() + st + ".ddj"))
	return out

func _texture_button(d: UiLayoutParser.ControlDef) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.focus_mode = Control.FOCUS_NONE
	if d != null:
		b.position = Vector2(d.rect.position)
		b.size = Vector2(d.rect.size)
		_set_button_art(b, d.ddj)
	return b

func _set_button_art(b: TextureButton, ddj: String) -> void:
	var t := _state_textures(ddj)
	if t.size() == 3:
		b.texture_normal = t[0]
		b.texture_hover = t[1]
		b.texture_pressed = t[2]

## A layout button: its art's three states (a TextureButton at the layout's
## own size) and its text key in a label over it, inset by its ClientRect
## (the sex buttons' radio mark, INFERRED).
func _button(d: UiLayoutParser.ControlDef) -> TextureButton:
	var b := TextureButton.new()
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.focus_mode = Control.FOCUS_NONE
	if d == null:
		return b
	b.position = Vector2(d.rect.position)
	b.size = Vector2(d.rect.size)
	_set_button_art(b, d.ddj)
	if d.text != "":
		var l := Label.new()
		l.name = "Text"
		l.text = _t(d.text)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", _font_size(d.font_index))
		l.add_theme_color_override("font_color", d.font_color)
		place_button_text(l, d.client_rect)
		b.add_child(l)
	return b

## The words of a layout button fill the button less its ClientRect inset,
## and follow its size (round 688). READ: the layout's HAlign/VAlign 1 centre
## them in that rect (CIFButton, pscharactercreate*.txt). They were placed
## with a fixed size computed before the label was in the tree, where its
## minimum width came from Godot's default face -- 98 units for "Name Check"
## against the button's 75 -- and a Label never shrinks below the size it
## was given: the client face's 71-unit string was centred in 98 units,
## 13.5 in from the button's left and 9.5 past its right edge at every UI
## scale (MEASURED, frontend_at_scale.gd, 1.0 and 1.95; the user's
## 2026-10-02 screenshot). Anchored to the button, the label is re-fitted
## whenever its minimum size changes (the face arriving with the tree) and
## whenever the button resizes; a string wider than the button (another
## archive's language) grows both ways and stays centred (OURS: retail does
## not clip, UiBuilder._apply_font's note).
static func place_button_text(l: Label, inset: Rect2i) -> void:
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.grow_vertical = Control.GROW_DIRECTION_BOTH
	l.offset_left = inset.position.x
	l.offset_top = inset.position.y
	l.offset_right = -inset.size.x
	l.offset_bottom = -inset.size.y

## Places a control on a rect, centring it vertically when its minimum height
## (the client font's line) is taller than the rect.
func _place_centred(c: Control, r: Rect2) -> void:
	var h := maxf(r.size.y, c.get_combined_minimum_size().y)
	c.position = Vector2(r.position.x, r.position.y + (r.size.y - h) * 0.5)
	c.size = Vector2(r.size.x, h)

# --- placement --------------------------------------------------------------

func _relayout() -> void:
	if _frame == null:
		return
	var w := size.x
	var h := size.y
	var up := _frame.scaled(_main_def(CharCreateModel.ID_BAND_UP).rect)
	var down := _frame.scaled(_main_def(CharCreateModel.ID_BAND_DOWN).rect)
	var bottom1 := int(up.position.y + up.size.y)
	var top2 := int(down.position.y)
	var mid := ((top2 - bottom1) >> 1) + bottom1
	_ok.position = Vector2(w - 0xd1, top2 + 0x1b)
	_cancel.position = Vector2(w - 0xd1 + 0x68, top2 + 0x1b)
	_panel.position = Vector2(0x4b, mid - 0x9b)
	_rotate_panel.position = Vector2(w - 0xa5, top2 - 0x45)
	_explain.position = _rotate_panel.position + EXPLAIN_OFFSET[_race]
	_box.position = Vector2(int(w - _box.size.x) >> 1, int(h - _box.size.y) >> 1)
	_message.position = Vector2(0x1a, top2 + 0x1d)
	_message.size = Vector2(w - 0x1a, 100)
	# The title stays at its layout rect (not scaled, READ: OnCreate scales
	# only 1, 2 and 14); the frame's own relayout scaled it.
	var td := _main_def(CharCreateModel.ID_TITLE)
	if td != null and _frame.title_art != null:
		_frame.title_art.position = Vector2(td.rect.position)
		_frame.title_art.size = Vector2(td.rect.size)
	for n in [_dim, _fade, _preview_rect]:
		if n != null:
			n.position = Vector2.ZERO
			n.size = size
	# The preview's buffer follows _preview_rect's new size (ViewportPixels).

# --- the state shown ----------------------------------------------------------

## Pushes the model into every control and the preview.
func _apply_all(restart: bool) -> void:
	for c in _sliders:
		_sync_slider(c)
	_apply_sex_art()
	_rebuild(restart)

func _sync_slider(c: int) -> void:
	var s: CharCreateSlider = _sliders[c]
	var r := _model.slider_range(c)
	s.set_range(r.x, r.y)
	s.set_value_quiet(_model.value(c))
	if c == CharCreateModel.Ctl.PROTECTOR:
		s.modulate.a = _model.protector_alpha() / 255.0

func _apply_sex_art() -> void:
	var art: Array = SEX_ART[_model.sex]
	_set_button_art(_male, art[0])
	_set_button_art(_female, art[1])

func _rebuild(restart: bool) -> void:
	var t0 := Time.get_ticks_usec()
	var ok := _preview.show_character(_model.preview_look(), restart)
	var total := Time.get_ticks_usec() - t0
	print("CREATE SWAP: %s in %d us (build %d us, materials %d us)%s" % [
		_describe(), total, _preview.last_build_usec, _preview.last_material_usec, "" if ok else " -- NOT BUILT"])

func _describe() -> String:
	var r := _model.request()
	return "race %d sex %d figure %d height %d volume %d weapon %d protector %d -> model %d scale 0x%02x chest %d legs %d feet %d weapon %d" % [
		_model.race, _model.sex, _model.figure, _model.height, _model.volume, _model.weapon, _model.protector,
		r["model"], r["scale"], r["chest"], r["legs"], r["feet"], r["weapon"]]

func _show_tip(c: int, force: bool) -> void:
	if c == _tip_control and not force:
		return
	var keys := _model.tooltip_keys(c)
	if keys.is_empty():
		return
	_tip_control = c
	_tip_title.text = _t(keys[0])
	_tip_text.text = _t(keys[1])

func _say(text: String, error: bool) -> void:
	_message.text = text
	print("CREATE MESSAGE: %s" % text.replace("\n", " "))
	if error:
		UiSounds.error_box("customize: %s" % text)

# --- input --------------------------------------------------------------------

func _on_slider(c: int, v: int) -> void:
	if _state != State.READY:
		_sync_slider(c)
		return
	if not _model.set_value(c, v):
		return
	match c:
		CharCreateModel.Ctl.HEIGHT, CharCreateModel.Ctl.VOLUME:
			var t0 := Time.get_ticks_usec()
			_preview.set_scale_byte(_model.scale_byte())
			print("CREATE SWAP: %s in %d us (scale only)" % [_describe(), Time.get_ticks_usec() - t0])
		CharCreateModel.Ctl.WEAPON:
			_sync_slider(CharCreateModel.Ctl.PROTECTOR)
			_rebuild(true)
		CharCreateModel.Ctl.FIGURE:
			_rebuild(true)
		CharCreateModel.Ctl.PROTECTOR:
			_rebuild(false)
	_show_tip(c, true)

func _on_sex(s: int) -> void:
	if _state != State.READY:
		return
	if not _model.set_sex(s):
		return
	_apply_all(true)

func _on_zoom() -> void:
	_view.toggle_zoom(_preview.height_factor(), _model.is_woman())
	_set_button_art(_zoom, ZOOM_OUT_ART if _view.zoomed else ZOOM_IN_ART)

func _on_name_check() -> void:
	if _state != State.READY:
		return
	var why := CharCreateModel.name_error(_name_edit.text, NameFilter.shared(_media))
	if why != "":
		_say(_t(why), true)
		return
	NetClient.check_character_name(_name_edit.text)

func _on_name_check_result(ok: bool, reason: String) -> void:
	if ok:
		_say(_t(CharCreateModel.MSG_NAME_OK), false)
	else:
		_say(reason, true)

func _on_confirm() -> void:
	if _state != State.READY:
		return
	var why := _model.confirm_error()
	if why == "":
		why = CharCreateModel.name_error(_name_edit.text, NameFilter.shared(_media))
	if why != "":
		_say(_t(why), true)
		return
	_state = State.BOX
	_block_input(true)
	_box_name.text = _name_edit.text
	_box.visible = true
	_frame.fade(_box, 0, 255, FADE_S)
	_frame.fade(_dim, 0, 0x80, FADE_S)

func _on_box_create() -> void:
	if _state != State.BOX or _box_closing:
		return
	_create_pending = true
	_close_box()

func _on_box_cancel() -> void:
	if _state != State.BOX or _box_closing:
		return
	_create_pending = false
	_close_box()

func _close_box() -> void:
	_box_closing = true
	_frame.fade(_box, 255, 0, FADE_S)
	_frame.fade(_dim, 0x80, 0, FADE_S)
	get_tree().create_timer(FADE_S).timeout.connect(_on_box_closed)

func _on_box_closed() -> void:
	_box_closing = false
	_box.visible = false
	if not _create_pending:
		_state = State.READY
		_block_input(false)
		return
	_create_pending = false
	_state = State.SENDING
	_send_serial += 1
	var serial := _send_serial
	get_tree().create_timer(CREATE_REPLY_TIMEOUT_S).timeout.connect(func(): _on_create_timeout(serial))
	var r := _model.request()
	print("CREATE SEND: name %s %s" % [_name_edit.text, _describe()])
	NetClient.create_character_full(_name_edit.text, r["model"], r["scale"], r["chest"], r["legs"], r["feet"], r["weapon"])

func _on_create_result(ok: bool, reason: String) -> void:
	if _state != State.SENDING:
		return
	if ok:
		print("CREATE RESULT: OK")
		_state = State.LEAVING
		_frame.fade(_fade, 0, 255, FADE_S)
		get_tree().create_timer(FADE_S).timeout.connect(func(): _leave(true))
	else:
		print("CREATE RESULT: refused -- %s" % reason)
		_state = State.READY
		_block_input(false)
		_say(reason, true)

## Round 685's review (OURS: what retail's window 12 does with the mouse is
## not read): while the box is up or the create is in flight the dimmer
## takes the mouse, so Cancel and the panel cannot be used and the screen
## cannot be left with the 0xB007 reply still due. The box sits above the
## dimmer and stays usable.
func _block_input(on: bool) -> void:
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE

## OURS: a create with no answer in CREATE_REPLY_TIMEOUT_S gives the screen
## back, saying so, rather than leaving it locked.
func _on_create_timeout(serial: int) -> void:
	if _state != State.SENDING or serial != _send_serial or not is_inside_tree():
		return
	print("CREATE RESULT: no answer in %.0f s" % CREATE_REPLY_TIMEOUT_S)
	_state = State.READY
	_block_input(false)
	_say(CREATE_TIMEOUT_TEXT, true)

func _on_cancel() -> void:
	if _state != State.READY and _state != State.OPENING:
		return
	_state = State.LEAVING
	_leave(false)

func _leave(created: bool) -> void:
	if _preview != null:
		_preview.release()
	_print_memory("leaving")
	CharSelectHandoff.back_to_select(get_tree(), created)

# --- each frame -----------------------------------------------------------------

func _process(delta: float) -> void:
	if _model == null:
		return
	if _state == State.OPENING:
		_tick_opening()
	_view.step_spin(delta)
	_preview.set_yaw(_view.yaw())
	_preview.set_pose(_view.step_zoom(delta))
	_preview.advance(delta)
	if _backdrop != null:
		_backdrop.show_pose(CharCreateView.backdrop_pose(_race, Time.get_ticks_msec()))
	# The tooltip follows the slider under the cursor (READ, per frame).
	if _state == State.READY:
		for c in _sliders:
			var s: CharCreateSlider = _sliders[c]
			if s.get_global_rect().has_point(get_global_mouse_position()):
				_show_tip(c, false)
				break
		if _qa_state != "":
			var spec := _qa_state
			_qa_state = ""
			_apply_qa_state(spec)
		if not _qa_shots.is_empty():
			_tick_qa_shots(delta)

func _tick_opening() -> void:
	var waited := Time.get_ticks_msec() - _started_ms
	if not _backdrop_ready and waited < BACKDROP_WAIT_MS:
		return
	if _usable_ms < 0:
		_frame.fade(_fade, 255, 0, FADE_S)
		_usable_ms = waited
		print("CREATE: usable at %d ms (backdrop %s)" % [waited, "ready" if _backdrop_ready else "still loading"])
		_print_layout()
		get_tree().create_timer(FADE_S).timeout.connect(_after_open_fade)
		_state = State.READY

func _after_open_fade() -> void:
	_frame.fade(_frame.title_art, 0, 255, FADE_S)
	if _back_image != null:
		_frame.fade(_back_image, 0, 255, FADE_S)

## The screen rects of the clickable controls, for real-input tests.
func _print_layout() -> void:
	var named := {"name": _name_edit, "check": _check, "male": _male, "female": _female, "ok": _ok, "cancel": _cancel, "zoom": _zoom}
	for c in _sliders:
		var s: CharCreateSlider = _sliders[c]
		named["slider_%d_prev" % CharCreateModel.SLIDER_IDS[c]] = s.prev_button
		named["slider_%d_next" % CharCreateModel.SLIDER_IDS[c]] = s.next_button
	var rot := _rotate_panel.get_children()
	for b in rot:
		if b is TextureButton and b != _zoom:
			named["rotate_%s" % ("left" if (b as Control).position.x < 50 else "right")] = b
	for k in named:
		var n: Control = named[k]
		if n != null:
			var r := n.get_global_rect()
			print("CREATE LAYOUT %s %d %d %d %d" % [k, r.position.x, r.position.y, r.size.x, r.size.y])
	# The box is hidden now; where its buttons will be once it shows.
	for pair in [["box_create", _box_create], ["box_cancel", _box_cancel]]:
		var b: Control = pair[1]
		if b != null:
			var bx := _box.position + b.position
			print("CREATE LAYOUT %s %d %d %d %d" % [pair[0], bx.x, bx.y, b.size.x, b.size.y])

## OPENSRO_QA_CREATE_STATE="sex=0;figure=5;height=4;volume=0;weapon=2;
## protector=1;name=QaName;spin=2;zoom=1;tip=4": drives the same handlers the
## controls do, for renders. Off in real play.
func _apply_qa_state(spec: String) -> void:
	var spin := 0
	for part in spec.split(";", false):
		var kv := part.split("=")
		if kv.size() != 2:
			continue
		var k := kv[0].strip_edges()
		var v := kv[1].strip_edges()
		match k:
			"sex": _on_sex(int(v))
			"figure": _set_qa(CharCreateModel.Ctl.FIGURE, int(v))
			"height": _set_qa(CharCreateModel.Ctl.HEIGHT, int(v))
			"volume": _set_qa(CharCreateModel.Ctl.VOLUME, int(v))
			"weapon": _set_qa(CharCreateModel.Ctl.WEAPON, int(v))
			"protector": _set_qa(CharCreateModel.Ctl.PROTECTOR, int(v))
			"name": _name_edit.text = v
			"spin": spin = int(v)
			"angle":
				_view.angle = float(v)
				_view.velocity = 0.0
			"zoom":
				if (int(v) != 0) != _view.zoomed:
					_on_zoom()
			"tip": _show_tip(int(v), true)
	for i in range(absi(spin)):
		_view.click(signi(spin))
	print("CREATE QA STATE: %s" % _describe())

func _set_qa(c: int, v: int) -> void:
	_on_slider(c, v)
	_sync_slider(c)

func _tick_qa_shots(delta: float) -> void:
	if _qa_shot_index < 0:
		if not (_scene_ready or _backdrop == null) or _frame.fades_running() > 0:
			return
		_qa_shot_index = 0
		_apply_qa_state(_qa_shots[0])
		_qa_shot_at = 0.0
		return
	_qa_shot_at += delta
	if _qa_shot_at < QA_SHOT_SETTLE_S:
		return
	var img := get_viewport().get_texture().get_image()
	var path := _qa_shot_dir.path_join("shot_%d.png" % _qa_shot_index)
	img.save_png(path)
	print("CREATE QA SHOT %d: %s -- %s" % [_qa_shot_index, path, _describe()])
	_qa_shot_index += 1
	_qa_shot_at = 0.0
	if _qa_shot_index >= _qa_shots.size():
		_qa_shots = PackedStringArray()
		print("CREATE QA SHOTS DONE")
		get_tree().quit()
		return
	_apply_qa_state(_qa_shots[_qa_shot_index])

## What the engine holds, for the select <-> create <-> select leak check
## (round 685): objects, nodes, orphan nodes, resources, static memory.
static func _print_memory(when: String) -> void:
	print("CREATE MEM %s: objects %d nodes %d orphans %d resources %d static %.1f MB" % [when,
		Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0])

## Round 788: the server closed the connection (READ 0x862450: the same box
## as the title's and select's).
var netoff_box: NetOffBox = null

func _on_disconnected() -> void:
	if not is_inside_tree() or (netoff_box != null and is_instance_valid(netoff_box)):
		return
	netoff_box = NetOffBox.show_on(self, _media, _text)
	print("CREATE: disconnected -- the box: %s" % netoff_box.message_text())
