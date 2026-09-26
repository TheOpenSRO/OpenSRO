extends RefCounted
class_name TwoDtBuilder

## Builds a Godot Control tree from a parsed `.2dt` window file (TwoDtReader),
## the way the client's loader creates its windows. docs/protocol/2DT_FORMAT.md
## has the spec and every address; each rule below says whether it was read
## out of `sro_client.exe`, measured in the retail files, or inferred.
##
## - **Positions** (read, 0x48fa40..0x48fa93 and the factory 0xba223e): record
##   0 at its authored rect under the load parent, every other record at its
##   rect less record 0's. Linking a record to its real parent does not move
##   it, so each node sits at its root-relative position less its parent's
##   (TwoDtReader.TwoDtFile.local_rect). The caller places the root.
## - **Order** (measured, not read): children are added in file order, which
##   is back to front -- in 690 of 694 overlapping sibling pairs of a tile and
##   a content control the tile comes first (tools/check_2dt_files.gd). **This is the opposite of the
##   `resinfo\*.txt` layouts**, which UiBuilder.build_section adds reversed.
##   The render loop itself was not read.
## - **Art per type** (read, the factory 0x489b80 and each class's texture
##   setter; defaults are the strings each case pushes):
##     0, 1   8-slice frame from the base (0x4745a0), defaults
##            `interface\frame\mframe_wnd_` / `interface\inventory\int_window_`
##     3      six-piece stretch frame (0x49b040, no mid_up / mid_down),
##            default `interface\ifcommon\com_blacksquare_`
##     2      one tile, default `interface\ifcommon\bg_tile\com_bg_tile_b.ddj`
##     9      four-cell lattice (0x49d030),
##            default `interface\ifcommon\lattice_window\com_lattice_`
##     15     three-slice bar: the texture cut after its last `_`, plus
##            `left` / `mid` / `right` (0x4733a0, 0x472a40)
##     16     tab: the texture cut after its last `_`, plus `on` / `off` /
##            `disable` (0x47a4e0, strings 0xe17ec0 / c8 / d0); `on` is the
##            checked piece (the click handler puts +0x370, the `on` texture,
##            up when checked and +0x374, `off`, when not: 0x47a387 / 0x47a2f7)
##     4      button: the texture plus `_focus` / `_press` / `_disable`
##            (0x4717b0), default `interface\ifcommon\com_button.ddj`
##     11     check box: the texture cut after its last `_`, plus `off` for
##            the box (0x482ef2) and `on` for the mark (0x482f2c);
##            default `interface\ifcommon\com_checkbutton02_on.ddj`
##     5, 8, 10, 18, 19   the texture as it is (only when set; 10 and 19 have
##            defaults `interface\playerminiinfo\pmi_hp.ddj` and
##            `interface\recovery\re_selectbar.ddj`)
##   Types 6, 7, 12, 13, 14, 17 and 20 take no art from the record; their
##   classes draw their own, which is not read, so they are built as empty
##   controls marked META_UNBUILT.
## - **Text** (read, 0x48af85..0x48afc6): the text id through the archive's
##   text table. The sample text at 0x300 is **never drawn** -- it is shown
##   only in the editor mode the retail install never enters (the reader's
##   Record.sample_bytes), and nor is the designer's comment.
## - **Colour** (destination read, meaning inferred): the record's colour
##   goes to the text object, so it is used as the text colour and never as
##   a tint -- it sits on tiles that draw no text.
## - **Alignment** (destination read, meaning inferred): 0x3cd / 0x3ce go to
##   the text object's slots 5 and 6, the slots a `.txt` layout's HAlign and
##   VAlign feed (round 586). The values are read as 0 = left / top,
##   1 = centre, 2 = right / bottom, the mapping the `.txt` path already uses
##   (UiBuilder._map_halign); the code that consumes them was not traced.
## - **Tabs** (read, 0x47a200 / 0x47a240): see set_tab_checked and click_tab.

const UiLayoutParser = preload("res://scripts/ui/ui_layout_parser.gd")

const META_ID := "twodt_id"
const META_INDEX := "twodt_index"
const META_TYPE := "twodt_type"
const META_CLASS := "twodt_class"
const META_FILE := "twodt_file"
const META_TAB_GROUP := "twodt_tab_group"
const META_TAB_PANE := "twodt_tab_pane"
const META_CHECKED := "twodt_checked"
const META_TAB_ON := "twodt_tab_on"
const META_TAB_OFF := "twodt_tab_off"
## A control whose class draws art this builder does not know (see the header).
const META_UNBUILT := "twodt_unbuilt"
## The name of the Label a record's text goes on.
const TEXT_NODE := "Text"

const DEFAULT_MAINFRAME := "interface\\frame\\mframe_wnd_"
const DEFAULT_FRAME := "interface\\inventory\\int_window_"
const DEFAULT_TILE := "interface\\ifcommon\\bg_tile\\com_bg_tile_b.ddj"
const DEFAULT_STRETCH := "interface\\ifcommon\\com_blacksquare_"
const DEFAULT_BUTTON := "interface\\ifcommon\\com_button.ddj"
const DEFAULT_LATTICE := "interface\\ifcommon\\lattice_window\\com_lattice_"
const DEFAULT_GAUGE := "interface\\playerminiinfo\\pmi_hp.ddj"
const DEFAULT_CHECKBOX := "interface\\ifcommon\\com_checkbutton02_on.ddj"
const DEFAULT_SLIDER := "interface\\recovery\\re_selectbar.ddj"

const SHORT_NAMES := ["MainFrame", "Frame", "Tile", "Stretch", "Button", "Static", "Edit",
	"TextBox", "Slot", "Lattice", "Gauge", "Check", "Combo", "VScroll", "Pages", "Bar", "Tab",
	"BothGauge", "Wnd", "Slider", "Spin"]

var _ui: UiBuilder

func _init(ui_builder: UiBuilder) -> void:
	_ui = ui_builder

## Builds the whole file: the root record's node, with every other record
## under the record it links to, in file order. `label` names the file in
## the nodes' META_FILE (a lookup aid, not data). The root is left at (0, 0);
## the caller puts it where the loading class does.
func build(file: TwoDtReader.TwoDtFile, label: String = "") -> Control:
	if file == null or file.records.is_empty():
		return null
	var nodes: Array[Control] = []
	nodes.resize(file.records.size())
	for i in file.records.size():
		var node := build_record(file, i)
		node.set_meta(META_FILE, label)
		nodes[i] = node
		if i > 0:
			nodes[file.records[i].parent_index].add_child(node, true)
	return nodes[0]

## One record's node, at its rect relative to the record it hangs under.
func build_record(file: TwoDtReader.TwoDtFile, i: int) -> Control:
	var r := file.records[i]
	var local := file.local_rect(i)
	var node := _node_for(r, local.size)
	var short: String = SHORT_NAMES[r.type] if r.type >= 0 and r.type < SHORT_NAMES.size() else "Type%d" % r.type
	node.name = "%s%d" % [short, r.id]
	node.set_meta(META_ID, r.id)
	node.set_meta(META_INDEX, r.index)
	node.set_meta(META_TYPE, r.type)
	node.set_meta(META_CLASS, r.name)
	node.position = Vector2(local.position)
	node.size = Vector2(local.size)
	node.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2(local.position), Vector2(local.size)))
	if r.text_id != "":
		set_text(node, _ui.resolve_text(r.text_id), r)
	return node

func _node_for(r: TwoDtReader.Record, size: Vector2i) -> Control:
	match r.type:
		TwoDtReader.TYPE_MAINFRAME:
			return _frame(r.base if r.base != "" else DEFAULT_MAINFRAME, size)
		TwoDtReader.TYPE_FRAME:
			return _frame(r.base if r.base != "" else DEFAULT_FRAME, size)
		TwoDtReader.TYPE_STRETCH:
			return _frame(r.base if r.base != "" else DEFAULT_STRETCH, size)
		TwoDtReader.TYPE_NORMAL_TILE:
			return _ui._build_tile(_def(r.base if r.base != "" else DEFAULT_TILE, size))
		TwoDtReader.TYPE_LATTICE:
			var ldef := _def(r.base if r.base != "" else DEFAULT_LATTICE, size)
			ldef.type = "CIFLattice"
			return _ui._build_lattice(ldef)
		TwoDtReader.TYPE_BUTTON:
			return _button(r.texture if r.texture != "" else DEFAULT_BUTTON)
		TwoDtReader.TYPE_BAR:
			return _bar(r.texture, size)
		TwoDtReader.TYPE_TAB:
			return _tab(r)
		TwoDtReader.TYPE_CHECKBOX:
			return _checkbox(r.texture if r.texture != "" else DEFAULT_CHECKBOX)
		TwoDtReader.TYPE_GAUGE:
			return _gauge(r.texture if r.texture != "" else DEFAULT_GAUGE)
		TwoDtReader.TYPE_SLIDER:
			return _picture(r.texture if r.texture != "" else DEFAULT_SLIDER, Control.MOUSE_FILTER_PASS)
		TwoDtReader.TYPE_STATIC:
			return _picture(r.texture, Control.MOUSE_FILTER_IGNORE)
		TwoDtReader.TYPE_SLOT, TwoDtReader.TYPE_WND:
			return _picture(r.texture, Control.MOUSE_FILTER_PASS)
		TwoDtReader.TYPE_EDIT:
			return _edit(r)
	var other := Control.new()
	other.mouse_filter = Control.MOUSE_FILTER_PASS
	other.set_meta(META_UNBUILT, true)
	return other

static func _def(ddj: String, size: Vector2i) -> UiLayoutParser.ControlDef:
	var def := UiLayoutParser.ControlDef.new()
	def.ddj = ddj
	def.rect = Rect2i(Vector2i.ZERO, size)
	return def

## An 8-slice or six-piece frame. UiBuilder._build_frame is the round-584
## code: every piece at its own size, and for a set with no mid_up / mid_down
## the vertical pieces reused for the top and bottom (round 126's reading of
## the stretch loader). Its children go on top of the pieces.
func _frame(base: String, size: Vector2i) -> Control:
	var frame := _ui._build_frame(_def(base, size))
	frame.mouse_filter = Control.MOUSE_FILTER_PASS
	return frame

## A picture as it is, or an empty control when the record names none.
func _picture(texture: String, filter: Control.MouseFilter) -> Control:
	if texture == "":
		var plain := Control.new()
		plain.mouse_filter = filter
		return plain
	var rect := TextureRect.new()
	rect.texture = _ui.load_texture(texture)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = filter
	return rect

func _button(texture: String) -> TextureButton:
	var btn := TextureButton.new()
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.focus_mode = Control.FOCUS_NONE
	btn.texture_normal = _ui.load_texture(texture)
	btn.texture_hover = _ui.load_texture(_ui._insert_suffix(texture, "_focus"))
	btn.texture_pressed = _ui.load_texture(_ui._insert_suffix(texture, "_press"))
	btn.texture_disabled = _ui.load_texture(_ui._insert_suffix(texture, "_disable"))
	return btn

## The base a bar, tab or check box texture names: cut after its last `_`
## (the client's rfind `'_'`, 0x4733a0).
static func slice_base(texture: String) -> String:
	var cut := texture.rfind("_")
	return texture.substr(0, cut + 1) if cut >= 0 else texture

func _bar(texture: String, size: Vector2i) -> Control:
	var bar := Control.new()
	bar.mouse_filter = Control.MOUSE_FILTER_PASS
	if texture != "":
		# Only a name ending in `.ddj` is cut (0x472b05); none of the retail
		# bars names anything else.
		var base := slice_base(texture) if texture.to_lower().ends_with(".ddj") else texture
		_ui._add_row_bar_from(bar, base, Vector2(size))
	return bar

func _tab(r: TwoDtReader.Record) -> TextureButton:
	var btn := TextureButton.new()
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_meta(META_TAB_GROUP, r.tab_group)
	btn.set_meta(META_TAB_PANE, r.tab_pane)
	btn.set_meta(META_CHECKED, false)
	if r.texture != "":
		var base := slice_base(r.texture)
		btn.set_meta(META_TAB_ON, _ui.load_texture(base + "on.ddj"))
		btn.set_meta(META_TAB_OFF, _ui.load_texture(base + "off.ddj"))
		btn.texture_disabled = _ui.load_texture(base + "disable.ddj")
		btn.texture_normal = btn.get_meta(META_TAB_OFF)
	# Through the class, not this builder: a builder is a RefCounted the
	# caller may drop once the tree is built, and the tab outlives it.
	btn.pressed.connect(func() -> void: TwoDtBuilder.click_tab(btn))
	return btn

## A check box: the `off` piece is the box, the `on` piece the mark (read,
## see the header). Its initial state is not read; every check box in the
## guild and community files sits in a pane hidden when it is created.
func _checkbox(texture: String) -> TextureButton:
	var base := slice_base(texture)
	var box := TextureButton.new()
	box.ignore_texture_size = true
	box.stretch_mode = TextureButton.STRETCH_SCALE
	box.focus_mode = Control.FOCUS_NONE
	box.toggle_mode = true
	box.texture_normal = _ui.load_texture(base + "off.ddj")
	box.texture_pressed = _ui.load_texture(base + "on.ddj")
	return box

## A gauge's fill is data; with none it is drawn empty. The class's own
## starting ratio is not read.
func _gauge(texture: String) -> TextureProgressBar:
	var gauge := TextureProgressBar.new()
	gauge.min_value = 0
	gauge.max_value = 100
	gauge.value = 0
	gauge.nine_patch_stretch = true
	gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gauge.texture_progress = _ui.load_texture(texture)
	return gauge

func _edit(r: TwoDtReader.Record) -> LineEdit:
	var edit := LineEdit.new()
	# The class draws no box of its own that is read here, so Godot's is
	# removed rather than shown in its place.
	for style in ["normal", "focus", "read_only"]:
		edit.add_theme_stylebox_override(style, StyleBoxEmpty.new())
	edit.add_theme_color_override("font_color", argb(r.color))
	var font := _ui.font_at(r.font_index)
	if font != null:
		edit.add_theme_font_override("font", font)
	edit.add_theme_font_size_override("font_size", _font_size(r.font_index))
	return edit

static func _font_size(index: int) -> int:
	return UiBuilder.FONT_SIZES[index] if index >= 0 and index < UiBuilder.FONT_SIZES.size() \
		else UiBuilder.FONT_SIZE_FALLBACK

## An ARGB colour as the record stores it.
static func argb(value: int) -> Color:
	return Color8((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff, (value >> 24) & 0xff)

## Puts `text` on `node`'s text label, creating it the first time: a Label
## over the whole control, in the record's colour, font and alignment. The
## same call fills a control at runtime (a friend's name, say). With no
## record, the label keeps what it had or takes white, index 0, left / top.
func set_text(node: Control, text: String, r: TwoDtReader.Record = null) -> Label:
	if node is LineEdit:
		(node as LineEdit).text = text
		return null
	var label := node.get_node_or_null(TEXT_NODE) as Label
	if label == null:
		label = Label.new()
		label.name = TEXT_NODE
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.clip_text = false
		var index := r.font_index if r != null else 0
		var font := _ui.font_at(index)
		if font != null:
			label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", _font_size(index))
		label.add_theme_color_override("font_color", argb(r.color if r != null else 0xffffffff))
		if r != null:
			label.horizontal_alignment = _ui._map_halign(r.halign)
			label.vertical_alignment = _ui._map_valign(r.valign)
		node.add_child(label)
	label.text = text
	return label

## The text a control shows, or "".
static func text_of(node: Node) -> String:
	if node is LineEdit:
		return (node as LineEdit).text
	var label := node.get_node_or_null(TEXT_NODE) as Label if node != null else null
	return label.text if label != null else ""

## The direct child of `parent` with this id -- the client's GetChild
## (0x46e060) searches direct children only.
static func child(parent: Node, id: int) -> Control:
	if parent == null:
		return null
	for c in parent.get_children():
		if c is Control and c.has_meta(META_ID) and int(c.get_meta(META_ID)) == id:
			return c
	return null

## Follows `ids` down from `root` one direct child at a time, the way the
## client chains GetChild (`0x2f` then `0x4b0` is 47 -> 1200).
static func find_path(root: Node, ids: Array) -> Control:
	var at: Node = root
	for id in ids:
		at = child(at, int(id))
		if at == null:
			return null
	return at as Control

static func is_tab(node: Node) -> bool:
	return node is Control and node.has_meta(META_TAB_GROUP)

static func is_checked(tab: Node) -> bool:
	return tab != null and bool(tab.get_meta(META_CHECKED, false))

## A tab's SetCheck (0x47a200): its checked look (`on` or `off`, 0x47a950),
## then `parent.GetChild(pane).ShowWindow(checked)`. A tab whose pane is
## NO_PANE, or names no direct sibling, changes only its look.
static func set_tab_checked(tab: Control, checked: bool) -> void:
	if tab == null:
		return
	tab.set_meta(META_CHECKED, checked)
	var btn := tab as TextureButton
	if btn != null:
		var art: Texture2D = tab.get_meta(META_TAB_ON if checked else META_TAB_OFF, null)
		if art != null:
			btn.texture_normal = art
	var pane_id := int(tab.get_meta(META_TAB_PANE, TwoDtReader.NO_PANE))
	if pane_id == TwoDtReader.NO_PANE:
		return
	var pane := child(tab.get_parent(), pane_id)
	if pane != null:
		pane.visible = checked

## A tab click (0x47a240, on the button's release, message 0x202): every tab
## of the same group under the same parent is unchecked and its pane hidden,
## then this one is checked and its pane shown. The parent is then told
## (0xb8f150); a window that acts on that connects to the button's
## `pressed` after this.
static func click_tab(tab: Control) -> void:
	var parent := tab.get_parent()
	if parent == null:
		return
	var group := int(tab.get_meta(META_TAB_GROUP, 0))
	for sibling in parent.get_children():
		if is_tab(sibling) and int(sibling.get_meta(META_TAB_GROUP)) == group:
			set_tab_checked(sibling as Control, false)
	set_tab_checked(tab, true)
