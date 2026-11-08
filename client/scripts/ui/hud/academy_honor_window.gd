extends RefCounted
class_name AcademyHonorWindow

## Round 865: the academy honor ranking -- CIFApprenticeShipHonorRanking,
## "ApprenticeShipHonorRankWnd" (academy.md 7.9 / 10.4). READ from
## sro_client.exe:
## - a CIFMainFrame (RTTI) framed by the registry entry GDR_APPRENTICESHIP_
##   HONOR_RANK (ginterface ID 154, 512 x 386, msgbox2_window_, Text
##   UIIT_STT_TC_HONOR_RANKING "Honor Rank"); its layout resinfo\
##   ifapprenticeshiphonorranking.txt: Create (the black square, two tiles,
##   the page spin 4, Confirm 3), RankingListBtn (the headers 20..25),
##   RankingSlotList (rows 30..39, CIFApprenticeShipHonorSlot, each loading
##   ifapprenticeshiphonorslot.txt);
## - 0xB478's success (c:0x89c620) clears the list (0x993360), reads the rows
##   (0x993230) and opens / refreshes the window (0x79d180(1));
## - the rows (c:0x808100, the arguments READ in asm c:0x807cd5..0x807d46):
##   RANK "%d" the ranking; CLASS com_honor_level_<rank>.ddj; NAME the
##   guardian; LEVEL "%d(%d)%s" (c:0x8082b1: current, max, then the
##   UIIT_STT_LEVEL_LV text);
##   GRADUATION "%d"; GUILD the name, or UIIT_STT_NO_GUILD when empty;
## - ten rows a page, pages = ceil(n / 10) on the spin (c:0x807e30);
## - Confirm (3) closes the window.
## MEASURED: with no ranked camp the reply is `01 00` and the window opens
## empty with the spin at "1".

const LAYOUT := "resinfo\\ifapprenticeshiphonorranking.txt"
const SLOT_LAYOUT := "resinfo\\ifapprenticeshiphonorslot.txt"
const REGISTRY := "GDR_APPRENTICESHIP_HONOR_RANK"
const SECTIONS := ["RankingListBtn", "RankingSlotList"]
const ROWS := 10
const SPIN := "GDR_APPRENTICESHIP_SPIN_CTRL"
const BTN_CONFIRM := "GDR_APPRENTICESHIP_CONFIRM_BTN"
const HONOR_ART := "interface\\ifcommon\\com_honor_level_%d.ddj"
const META := "academy_honor"

var window: HudWindow
var _builder: UiBuilder
var rows: Array = []
var page := 0
var _slots: Array[Control] = []

static func compose(w: HudWindow, builder: UiBuilder) -> AcademyHonorWindow:
	if w == null:
		return null
	if w.has_meta(META):
		return w.get_meta(META) as AcademyHonorWindow
	var h := AcademyHonorWindow.new()
	h.window = w
	h._builder = builder
	h._build()
	w.set_meta(META, h)
	return h

static func of(w: HudWindow) -> AcademyHonorWindow:
	return w.get_meta(META) as AcademyHonorWindow if w != null and w.has_meta(META) else null

func _build() -> void:
	var layout: UiLayoutParser.LayoutDef = _builder.load_layout(SLOT_LAYOUT) if _builder != null else null
	for i in ROWS:
		var slot := window.node("GDR_APPRENTICESHIP_SLOTLIST_SLOT_%02d" % (i + 1))
		_slots.append(slot)
		if slot == null or layout == null:
			continue
		var built := _builder.build_section(layout, "Create")
		if built == null:
			continue
		built.name = "HonorSlot"
		slot.add_child(built)
		UiBuilder.settle_authored_rects(built)
		built.visible = false
	var ok := window.node(BTN_CONFIRM) as BaseButton
	if ok != null:
		ok.pressed.connect(func() -> void: window.hide())
	var spin := window.node(SPIN)
	if spin != null and spin.has_user_signal("spin_changed"):
		spin.connect("spin_changed", func(v: int) -> void:
			page = v
			_draw_page())

func slot_node(i: int, control_name: String) -> Control:
	var s: Control = _slots[i] if i >= 0 and i < _slots.size() else null
	var holder := s.get_node_or_null("HonorSlot") if s != null else null
	return holder.get_node_or_null(control_name) as Control if holder != null else null

## 0xB478's rows (AcademyNet.HonorRow).
func fill(list: Array) -> void:
	rows = list
	page = 0
	var spin := window.node(SPIN)
	if spin != null:
		var pages := maxi(1, int(ceil(float(rows.size()) / float(ROWS))))
		UiBuilder.set_spin_range(spin, 0, pages - 1)
		spin.set_meta("value", 0)
		UiBuilder._spin_refresh(spin)
	_draw_page()

func _draw_page() -> void:
	for i in ROWS:
		var at := page * ROWS + i
		var s: Control = _slots[i] if i < _slots.size() else null
		var holder := s.get_node_or_null("HonorSlot") as Control if s != null else null
		if holder == null:
			continue
		if at >= rows.size():
			holder.visible = false
			continue
		holder.visible = true
		var h: AcademyNet.HonorRow = rows[at]
		_put(slot_node(i, "GDR_APPRENTICESHIPHONOR_SLOT_RANK"), "%d" % h.ranking)
		_art(slot_node(i, "GDR_APPRENTICESHIPHONOR_SLOT_CLASS"), HONOR_ART % h.rank)
		_put(slot_node(i, "GDR_APPRENTICESHIPHONOR_SLOT_NAME"), h.guardian)
		_put(slot_node(i, "GDR_APPRENTICESHIPHONOR_SLOT_LEVEL"), "%d(%d)%s" % [h.cur_level, h.max_level, _text("UIIT_STT_LEVEL_LV", "Lv")])
		_put(slot_node(i, "GDR_APPRENTICESHIPHONOR_SLOT_GRADUATION"), "%d" % h.graduates)
		_put(slot_node(i, "GDR_APPRENTICESHIPHONOR_SLOT_GUILD"), h.guild if h.guild != "" else _text("UIIT_STT_NO_GUILD", "<No guild>"))

func _put(n: Control, t: String) -> void:
	if n == null:
		return
	if _builder != null:
		_builder.set_static_text(n, t)
	elif n is Label:
		(n as Label).text = t

func _art(n: Control, ddj: String) -> void:
	if n == null:
		return
	var pic := n.get_node_or_null("Art") as TextureRect
	if pic == null:
		pic = TextureRect.new()
		pic.name = "Art"
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.stretch_mode = TextureRect.STRETCH_KEEP
		n.add_child(pic)
	pic.texture = _builder.load_texture(ddj) if _builder != null else null
	pic.set_meta("ddj", ddj)

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t
