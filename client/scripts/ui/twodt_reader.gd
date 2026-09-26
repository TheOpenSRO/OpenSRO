extends RefCounted
class_name TwoDtReader

## Reads the retail client's `.2dt` window files (`Media.pk2`, `res_ui\*.2dt`)
## exactly the way its loader does. docs/protocol/2DT_FORMAT.md is the spec;
## every address below is `sro_client.exe`'s (md5 2a5794b72c90908d945be8b3f3f2edd4).
##
## These are the newer windows (`CNIF*`): the guild and community window, the
## quest list, the enchant window, the world-map guide, the menu bar, the
## option window and the rest -- 42 files, all in Media.pk2 (measured). The
## older `resinfo\if*.txt` layouts are a different format with their own
## parser (UiLayoutParser).
##
## **The container** (read, the pk2 branch of the loader `0x48f3d0`): a `u32`
## record count (`ReadFile(h, &count, 4)`, 0x48f983..0x48f990), then that many
## fixed 976-byte records (`push 0x3d0` at 0x48f9b5, one ReadFile per record in
## the loop 0x48f9a4..0x48fc7e). Nothing else: a file that is not exactly
## `4 + count * 976` bytes is not one the loader reads, and is refused here.
##
## **The fields** (read at the offsets named, relative to the record buffer,
## `[esp+0xac]` at the loop's top): see Record.
##
## **Parents** (read, `0x48cb00`): ids are **not** unique within a file (41,
## 52, 72, 341 and others repeat), so a record names its parent by two ids --
## the parent's id (0x348) and the parent's own parent's id (0x34c). The
## loader matches `window.id == parent && window.parent.id == grandparent`
## over the windows already created from the same file (+0x1f8 is the file's
## root window, compared at 0x48cbce; the record's own window is created
## first, at 0x48fa93, and linked after, at 0x48fbaa). A grandparent of 0
## means the load parent (0x48fb5a..0x48fb6d). The root record's parent is the
## load parent (0x48fb51). A record whose pair matches nothing stays under the
## root, where it was created (0x48cb00 returns 0 without re-parenting).
## A parent id of 0 takes 0x48cb00's first branch (0x48cb0f: the id equals
## loader+0x3c, which is 0 -- stored at 0x48999a; its setter 0x48cd60 has
## no direct caller) and returns at 0x48cc27 without a move. And after
## finding the parent, 0x48cb00 asks it for a direct child with the record's
## own id (GetChild, 0x48cbe6..0x48cbf7) and does not re-link when it has
## one: the record stays under the root (kept_under_root).

const RECORD_SIZE := 0x3d0
const HEADER_SIZE := 4

## The type field (0x340) indexes the loader's switch at 0x489d64
## (`jmp [eax*4+0x48b398]`); each case creates this class unless the record's
## name finds a registered class (types 0, 1, 4, 8, 15 and 18, `0xb9b6a0`).
const TYPE_NAMES := ["CNIFMainFrame", "CNIFFrame", "CNIFNormalTile", "CNIFStretchWnd",
	"CNIFButton", "CNIFStatic", "CNIFEdit", "CNIFTextBox", "CNIFSlot", "CNIFLattice",
	"CNIFGauge", "CNIFCheckBox", "CNIFComboBox", "CNIFVerticalScroll", "CNIFPageManager",
	"CNIFBarWnd", "CNIFTabButton", "CNIFBothSidesGauge", "CNIFWnd", "CNIFSliderCtrl",
	"CNIFSpinButtonCtrl"]
const TYPE_MAINFRAME := 0
const TYPE_FRAME := 1
const TYPE_NORMAL_TILE := 2
const TYPE_STRETCH := 3
const TYPE_BUTTON := 4
const TYPE_STATIC := 5
const TYPE_EDIT := 6
const TYPE_TEXTBOX := 7
const TYPE_SLOT := 8
const TYPE_LATTICE := 9
const TYPE_GAUGE := 10
const TYPE_CHECKBOX := 11
const TYPE_COMBOBOX := 12
const TYPE_VSCROLL := 13
const TYPE_PAGE_MANAGER := 14
const TYPE_BAR := 15
const TYPE_TAB := 16
const TYPE_BOTH_SIDES_GAUGE := 17
const TYPE_WND := 18
const TYPE_SLIDER := 19
const TYPE_SPIN := 20

## A tab button's pane field when it shows no pane (0x390 == 0xffffffff).
const NO_PANE := -1
## The key the root record's parent is known by when the caller does not say
## which window the file is loaded under.
const LOAD_PARENT := -2

class Record:
	## Position in the file, 0-based. Record 0 is the root.
	var index: int = 0
	## 0x000 char[64]: the runtime class name looked up for types 0, 1, 4, 8,
	## 15 and 18 (0x48a295..0x48a2c2 for type 1). Non-empty also queues the
	## window for message 0x8065, its OnCreate, once the file is loaded
	## (0x48fbaf..0x48fc2b; sent at 0x48fca9).
	var name: String = ""
	## 0x040 char[256]: the frame or tile art of types 0, 1, 2, 3 and 9
	## (`add eax,0x40` at 0x48a2e8 in the type-1 case). Empty means the
	## type's own default (TwoDtBuilder).
	var base: String = ""
	## 0x140 char[256]: the texture of types 4, 5, 8, 10, 11, 15, 16, 18 and
	## 19 (`add edx,0x140`, e.g. 0x48ab65 for type 16).
	var texture: String = ""
	## 0x240 char[128]: a text-table key, set with SetText (0x48af85..0x48afc6).
	var text_id: String = ""
	## 0x2c0 char[64]: the designer's comment, cp949. Only the loose-file
	## (editor) branch copies it (0x48f6a1..0x48f6f2); the pk2 branch never
	## reads it. Kept as bytes and never decoded here.
	var comment_bytes := PackedByteArray()
	## 0x300 char[64]: sample text, used only in editor mode
	## (`singleton(0x115e9c8)+0x40`, 0x48b058 / 0x48b151), which is the same
	## byte as the loose-file flag. **Never drawn** (docs/protocol/2DT_FORMAT.md
	## has why). Kept as bytes and never decoded.
	var sample_bytes := PackedByteArray()
	## 0x340 u32: the control type (TYPE_NAMES).
	var type: int = 0
	## 0x344 u32: the control id. 0 means the loader assigns one
	## (0x489bfb..0x489c03).
	var id: int = 0
	## 0x348 u32: the parent's id.
	var parent_id: int = 0
	## 0x34c u32: the parent's parent's id; 0 means the load parent.
	var grandparent_id: int = 0
	## 0x358 u32 ARGB: stored into the control's text object (0x48af4b..
	## 0x48af69). That it is the **text** colour is inferred (the values are
	## white, gold on labels, cream on button captions, and it sits on tiles
	## that draw no text), so it is never used as a tint.
	var color: int = 0xffffffff
	## 0x35c i32 x4: x, y, width, height, in the designer's screen space.
	## The loader creates record 0 at this rect and every other record at
	## `(x - x0, y - y0)` under record 0 (0x48fa40..0x48fa93).
	var rect := Rect2i()
	## 0x36c f32 x8: passed to 0x46d110 and stored at wnd+0x21c..0x238.
	var uv := PackedFloat32Array()
	## 0x38c u32: a CNIFTabButton's group (-> wnd+0x368, 0x48fb09).
	var tab_group: int = 0
	## 0x390 u32: a CNIFTabButton's pane, the id of the sibling it shows
	## (-> wnd+0x36c, 0x48fb0f); NO_PANE for 0xffffffff.
	var tab_pane: int = NO_PANE
	## 0x394 u32: 1 on the root record (pushed on the root list, 0x48fb15).
	var is_root: bool = false
	## 0x398..0x39a: text-style bytes (0x48aeb1, 0x48af34, 0x48aef2). 0 in
	## every retail file (measured).
	var style_bytes := PackedByteArray()
	## 0x39b u8: font index into the table at 0x115e1f4 (0x48aea5..0x48aeef).
	var font_index: int = 0
	## 0x3a0 u32: CNIFTextBox's +0x374 (0 means 23, 0x48b0b7..0x48b0d3).
	var textbox_value: int = 0
	## 0x3cd u8: goes to the text object's slot 5 (0x48ae6a..0x48ae81), the
	## same text-board slot the layout builder feeds a `.txt` control's
	## HAlign into. What each value means is **inferred** (see TwoDtBuilder).
	var halign: int = 0
	## 0x3ce u8: the text object's slot 6 (0x48ae86..0x48ae9d); VAlign's slot.
	var valign: int = 0
	## The record this one hangs under once linked (-1 for the root).
	var parent_index: int = -1
	## The records hanging under this one, in file order.
	var children: Array[int] = []

	func type_name() -> String:
		return TYPE_NAMES[type] if type >= 0 and type < TYPE_NAMES.size() else "type%d" % type

class TwoDtFile:
	var records: Array[Record] = []
	## Non-root records whose (parent, grandparent) pair matched no earlier
	## window, left under the root as the loader leaves them.
	var unresolved: Array[int] = []
	## Records whose pair matched more than one earlier window; the loader
	## takes the first it walks to, and so does this.
	var ambiguous: Array[int] = []
	## Records whose parent already had a direct child with their id, which
	## 0x48cb00 does not re-link (0x48cbf7): they stay under the root.
	var kept_under_root: Array[int] = []

	func root() -> Record:
		return records[0] if not records.is_empty() else null

	## The rect of record `i` relative to the file's root record, which is
	## where the loader creates it under record 0.
	func rect_in_root(i: int) -> Rect2i:
		var r := records[i]
		if i == 0:
			return Rect2i(Vector2i.ZERO, r.rect.size)
		var r0 := records[0]
		return Rect2i(r.rect.position - r0.rect.position, r.rect.size)

	## The rect of record `i` relative to the record it hangs under. Linking
	## a window to its real parent does not move it (0x48cb00 only moves it
	## between child lists), so this is its root-relative position less its
	## parent's.
	func local_rect(i: int) -> Rect2i:
		var r := records[i]
		if r.parent_index < 0:
			return Rect2i(Vector2i.ZERO, r.rect.size)
		var here := rect_in_root(i)
		return Rect2i(here.position - rect_in_root(r.parent_index).position, here.size)

	## The direct children of `i` with this id, in file order.
	func child_with_id(i: int, id: int) -> Record:
		for c in records[i].children:
			if records[c].id == id:
				return records[c]
		return null

## Parses a `.2dt` file. Returns null (and says why) when the size is not
## `4 + count * 976`, the one shape the loader reads. `load_parent_id` is the
## id of the window the file is loaded under, when a caller knows it; a
## grandparent naming it then matches the root, as a grandparent of 0 does.
static func parse(data: PackedByteArray, load_parent_id: int = LOAD_PARENT) -> TwoDtFile:
	if data.size() < HEADER_SIZE:
		push_error("TwoDtReader: %d bytes, too short for the record count" % data.size())
		return null
	var count := data.decode_u32(0)
	if data.size() != HEADER_SIZE + count * RECORD_SIZE:
		push_error("TwoDtReader: %d bytes is not 4 + %d * %d" % [data.size(), count, RECORD_SIZE])
		return null
	var file := TwoDtFile.new()
	for i in count:
		file.records.append(_record(data, HEADER_SIZE + i * RECORD_SIZE, i))
	_link(file, load_parent_id)
	return file

static func _cstr(data: PackedByteArray, at: int, length: int) -> String:
	var end := at
	while end < at + length and data[end] != 0:
		end += 1
	# The four string fields read here are ASCII in every retail file (the
	# box tool check_2dt_files.gd checks it); anything else would be cp949.
	return data.slice(at, end).get_string_from_ascii()

static func _raw(data: PackedByteArray, at: int, length: int) -> PackedByteArray:
	var end := at
	while end < at + length and data[end] != 0:
		end += 1
	return data.slice(at, end)

static func _record(data: PackedByteArray, at: int, index: int) -> Record:
	var r := Record.new()
	r.index = index
	r.name = _cstr(data, at + 0x000, 0x40)
	r.base = _cstr(data, at + 0x040, 0x100)
	r.texture = _cstr(data, at + 0x140, 0x100)
	r.text_id = _cstr(data, at + 0x240, 0x80)
	r.comment_bytes = _raw(data, at + 0x2c0, 0x40)
	r.sample_bytes = _raw(data, at + 0x300, 0x40)
	r.type = data.decode_u32(at + 0x340)
	r.id = data.decode_u32(at + 0x344)
	r.parent_id = data.decode_u32(at + 0x348)
	r.grandparent_id = data.decode_u32(at + 0x34c)
	r.color = data.decode_u32(at + 0x358)
	r.rect = Rect2i(data.decode_s32(at + 0x35c), data.decode_s32(at + 0x360),
		data.decode_s32(at + 0x364), data.decode_s32(at + 0x368))
	for k in 8:
		r.uv.append(data.decode_float(at + 0x36c + 4 * k))
	r.tab_group = data.decode_u32(at + 0x38c)
	var pane := data.decode_u32(at + 0x390)
	r.tab_pane = NO_PANE if pane == 0xffffffff else pane
	r.is_root = data.decode_u32(at + 0x394) != 0
	r.style_bytes = data.slice(at + 0x398, at + 0x39b)
	r.font_index = data[at + 0x39b]
	r.textbox_value = data.decode_u32(at + 0x3a0)
	r.halign = data[at + 0x3cd]
	r.valign = data[at + 0x3ce]
	return r

## Links every record to its parent the way 0x48cb00 does (see the header).
static func _link(file: TwoDtFile, load_parent_id: int) -> void:
	var records := file.records
	for i in range(1, records.size()):
		var r := records[i]
		r.parent_index = 0
		if r.parent_id == 0:
			# Two retail records do this; nothing has id 0, so they stay under
			# the root (measured and read: see the header).
			file.unresolved.append(i)
			records[0].children.append(i)
			continue
		var wanted := r.grandparent_id
		if wanted == 0 or wanted == load_parent_id:
			wanted = LOAD_PARENT
		var found := -1
		var matches := 0
		for j in range(0, i):
			if records[j].id != r.parent_id:
				continue
			var parents_parent := LOAD_PARENT if j == 0 else records[records[j].parent_index].id
			if parents_parent == wanted:
				matches += 1
				if found < 0:
					found = j
		if found < 0:
			file.unresolved.append(i)
			records[0].children.append(i)
			continue
		if matches > 1:
			file.ambiguous.append(i)
		if found != 0 and file.child_with_id(found, r.id) != null:
			file.kept_under_root.append(i)
			records[0].children.append(i)
			continue
		r.parent_index = found
		records[found].children.append(i)
