extends Control
class_name PartyMatchBox

## The shared shell of the party-matching dialogs (round 714, lane C2): the
## register dialog, the auto-match dialog, the leader's join popup and the
## joining progress window are each a `msgbox2_window_` frame with a centred
## caption static and one resinfo layout section loaded into it.
##
## READ (sro_client.exe):
## - the frame art, from each window's own record (ifpartymatch.txt's
##   JoinProgress / PartyRegister / AutoMatch sections, ginterface's
##   GDR_PARTY_MATCH_REQ_JOIN): `interface\messagebox\msgbox2_window_`;
## - the caption: a static at (10, 11), the width less 21 wide and 12 high,
##   font 0, centred (CIFPartyMatchReqJoin::Create 0x7400c0: `0xa`, `0xb`,
##   `width + 0xffffffeb`, `0xc`; HAlign 1, VAlign 0), the same rect
##   CIFSetPartyMode uses (PartySettingsDialog);
## - CIFRadioButton's item geometry, set per dialog through 0x657910 (origin,
##   +0x384/+0x388), 0x657930 (pitch, +0x374), 0x657940 (label x offset,
##   +0x378), 0x657950 (label alignment), 0x657960 (label width) and
##   0x657c40 (count, 0 vertical / 1 horizontal): see each dialog.
## The radio dot's art, its 16x16 size and the label's +3 / 12-high rect are
## the ones round 711 read for CIFSetPartyMode (PartySettingsDialog).

const FRAME := "interface\\messagebox\\msgbox2_window_"
const RADIO_ON := "interface\\ifcommon\\com_radiobutton_on.ddj"
const RADIO_OFF := "interface\\ifcommon\\com_radiobutton_off.ddj"
const DOT_SIZE := Vector2(16, 16)
const LABEL_DY := 3.0
const LABEL_H := 12.0

var _builder: UiBuilder
var root: Control
## The frame's art (round 801: the trade-info window, a main frame, sets
## `interface\frame\mframe_wnd_` before build_shell).
var frame_ddj := FRAME
var caption: Label
## Per radio group: {"dots": Array[TextureButton], "labels": Array[Label],
## "choice": int, "enabled": Array[bool]}.
var _radios := {}

signal radio_chosen(group: String, index: int)

## Frame + caption + the layout's section. False when the layout is missing.
func build_shell(builder: UiBuilder, box_size: Vector2, caption_key: String, caption_fallback: String,
		layout_path: String, section: String = "Create") -> bool:
	_builder = builder
	size = box_size
	custom_minimum_size = box_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	var frame_def := UiLayoutParser.ControlDef.new()
	frame_def.name = "Frame"
	frame_def.type = "CIFFrame"
	frame_def.ddj = frame_ddj
	frame_def.rect = Rect2i(Vector2i.ZERO, Vector2i(box_size))
	var frame := builder.build_control(frame_def) if builder != null else null
	if frame != null:
		add_child(frame)
	caption = Label.new()
	caption.name = "Caption"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.position = Vector2(10, 11)
	caption.size = Vector2(box_size.x - 21, 12)
	caption.text = text(caption_key, caption_fallback)
	add_child(caption)
	if builder == null:
		return false
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(layout_path)
	if layout == null:
		return false
	root = builder.build_section(layout, section)
	if root == null:
		return false
	add_child(root)
	UiBuilder.settle_authored_rects(root)
	return true

func text(key: String, fallback: String) -> String:
	if _builder == null or key == "":
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t

func node(control_name: String) -> Control:
	return root.get_node_or_null(control_name) as Control if root != null else null

## Builds a CIFRadioButton's items into `group` (the layout's record node).
func build_radio(group: Control, key: String, labels: Array, origin: Vector2, pitch: float,
		label_dx: float, label_w: float, horizontal: bool, centred: bool) -> void:
	if group == null:
		return
	var dots: Array[TextureButton] = []
	var lbls: Array[Label] = []
	var enabled: Array[bool] = []
	for i in labels.size():
		var at := origin + (Vector2(pitch * i, 0) if horizontal else Vector2(0, pitch * i))
		var dot := TextureButton.new()
		dot.name = "Item%d" % i
		dot.ignore_texture_size = true
		dot.stretch_mode = TextureButton.STRETCH_SCALE
		dot.position = at
		dot.size = DOT_SIZE
		dot.custom_minimum_size = DOT_SIZE
		dot.pressed.connect(choose.bind(key, i))
		group.add_child(dot)
		dots.append(dot)
		var lbl := Label.new()
		lbl.name = "Label%d" % i
		lbl.text = String(labels[i])
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if centred else HORIZONTAL_ALIGNMENT_LEFT
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.position = at + Vector2(label_dx, LABEL_DY)
		lbl.size = Vector2(label_w, LABEL_H)
		lbl.clip_text = false
		group.add_child(lbl)
		lbls.append(lbl)
		enabled.append(true)
	group.mouse_filter = Control.MOUSE_FILTER_PASS
	_radios[key] = {"dots": dots, "labels": lbls, "choice": 0, "enabled": enabled}
	_paint_radio(key)

func choice(key: String) -> int:
	return int(_radios[key]["choice"]) if _radios.has(key) else -1

func choose(key: String, index: int) -> void:
	if not _radios.has(key):
		return
	var r: Dictionary = _radios[key]
	if index < 0 or index >= (r["dots"] as Array).size() or not bool(r["enabled"][index]):
		return
	r["choice"] = index
	_paint_radio(key)
	radio_chosen.emit(key, index)

## 0x657890(index, enabled): a disabled item cannot be chosen.
func set_radio_enabled(key: String, index: int, on: bool) -> void:
	if not _radios.has(key):
		return
	var r: Dictionary = _radios[key]
	if index < 0 or index >= (r["enabled"] as Array).size():
		return
	r["enabled"][index] = on
	(r["dots"][index] as TextureButton).disabled = not on
	_paint_radio(key)

func radio_enabled(key: String, index: int) -> bool:
	return _radios.has(key) and bool(_radios[key]["enabled"][index])

func _paint_radio(key: String) -> void:
	var r: Dictionary = _radios[key]
	var on_tex := _builder.load_texture(RADIO_ON) if _builder != null else null
	var off_tex := _builder.load_texture(RADIO_OFF) if _builder != null else null
	for i in (r["dots"] as Array).size():
		var dot: TextureButton = r["dots"][i]
		dot.texture_normal = on_tex if i == int(r["choice"]) else off_tex
		var lbl: Label = r["labels"][i]
		lbl.modulate = Color.WHITE if bool(r["enabled"][i]) else Color(0.6, 0.6, 0.6)

## A CIFEdit from the layout: max length, starting text.
func setup_edit(control_name: String, max_len: int, value: String) -> LineEdit:
	var e := node(control_name) as LineEdit
	if e == null:
		return null
	e.max_length = max_len
	e.text = value
	return e

func set_static(control_name: String, value: String) -> Label:
	var n := node(control_name)
	if n == null or _builder == null:
		return null
	return _builder.set_static_text(n, value)

func button(control_name: String) -> BaseButton:
	return node(control_name) as BaseButton

## Centres the box on the view (0x798b70: screen w / 2 - w / 2, h / 2 - h / 2).
func centre_on(view: Vector2) -> void:
	position = Vector2(floorf(view.x / 2.0 - size.x / 2.0), floorf(view.y / 2.0 - size.y / 2.0))

func close() -> void:
	hide()
	queue_free()

## The `<sml2>` markup the PML strings carry (MEASURED in textuisystem:
## `<sml2>`, `<font color="a,r,g,b">`, `</font>`, `<br>`), as BBCode for a
## RichTextLabel. The four numbers are A, R, G, B (MEASURED, round 714's
## review: every `<font color>` in textuisystem starts with 255, e.g. 16x
## "255,0,0,0", black as ARGB and an invisible red as RGBA; resinfo's
## FontColor uses the same order; screenshot 08's "[Dasha]" measures
## (230,219,171) against ARGB's (239,218,164)).
static func sml2_to_bbcode(s: String) -> String:
	var out := s.replace("<sml2>", "").replace("</sml2>", "").replace("<br>", "\n")
	out = out.replace("[", "\u0001").replace("]", "\u0002").replace("\u0001", "[lb]").replace("\u0002", "[rb]")
	var re := RegEx.new()
	re.compile("<font color=\"(\\d+),(\\d+),(\\d+),(\\d+)\">")
	for m in re.search_all(out):
		var c := Color8(int(m.get_string(2)), int(m.get_string(3)), int(m.get_string(4)), int(m.get_string(1)))
		out = out.replace(m.get_string(0), "[color=#%s]" % c.to_html(c.a8 < 255))
	return out.replace("</font>", "[/color]")

## A RichTextLabel over a CIFPML record, centred (INFERRED from screenshots
## 08 and 09: CIFPML's own alignment was not read), with `bbcode`.
func fill_pml(control_name: String, bbcode: String) -> RichTextLabel:
	var holder := node(control_name)
	if holder == null:
		return null
	var rt := holder.get_node_or_null("PmlText") as RichTextLabel
	if rt == null:
		rt = RichTextLabel.new()
		rt.name = "PmlText"
		rt.bbcode_enabled = true
		rt.scroll_active = false
		rt.fit_content = false
		rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		if _builder != null and _builder.font_at(0) != null:
			rt.add_theme_font_override("normal_font", _builder.font_at(0))
		rt.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[0])
		holder.add_child(rt)
	rt.text = "[center]%s[/center]" % bbcode
	return rt
