extends Control
class_name EquipStateImg

## Round 829: the HUD's worn-out gear figure, CEquipStateImg -- READ from
## sro_client.exe, the layout MEASURED from the archive:
##
## - `resinfo\ginterface.txt`'s GDR_EQUIP_STATE_WND:CEquipStateImg (ID 157,
##   Rect 824,74,68,96, under UI_UPDATE_2009_FIRST, which config\define.txt
##   defines), moved to (screen width - 200, 74) (0x79f272..0x79f293).
## - vslot_010 (0x65cd20) makes eight 68 x 96 children, one a worn slot, each
##   with a yellow and a red texture (`interface\ifcommon\`): 0 head
##   com_re_avatar01, 1 mail com_re_avatar04, 2 shoulders com_re_avatar03,
##   3 gauntlets com_re_avatar02, 4 pants com_re_avatar05, 5 boots
##   com_re_avatar06, 6 weapon com_re_sword, 7 shield com_re_shield, each
##   `_y` / `_r`.
## - The state (0x65cc50), worn slots 0..7: an occupied slot whose item is
##   equipment but not an accessory (0x56fb40) at durability below 7 -- 0
##   red, 1..6 yellow; else nothing (the maximum is not asked here).
## - The draw (0x65cb40): each child its texture or hidden; with any shown the
##   parent's own texture is `com_re_avatar.ddj` (the knight), with none it has
##   none, so the figure is not seen at all. No timer: it does not flash.
## - Refreshed by 0x778b20 (via 0x7998e0, window 0x9d): the worn branch of
##   0x3052's handler (0x8ae126), the interface's start, and the 0xB034 move
##   replies.

const DIR := "interface\\ifcommon\\"
const BASE_DDJ := "com_re_avatar.ddj"
const PARTS := ["com_re_avatar01", "com_re_avatar04", "com_re_avatar03", "com_re_avatar02",
	"com_re_avatar05", "com_re_avatar06", "com_re_sword", "com_re_shield"]
const SIZE := Vector2(68, 96)
const FROM_RIGHT := 200.0
const TOP := 74.0
const SLOTS := 8

enum State { NONE, LOW, BROKEN }

var _base: TextureRect
var _parts: Array[TextureRect] = []
var _yellow: Array[Texture2D] = []
var _red: Array[Texture2D] = []
var _states: Array = []

## `load_texture(path) -> Texture2D` (UiBuilder.load_texture).
func build(load_texture: Callable) -> void:
	name = "EquipStateImg"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -FROM_RIGHT
	offset_right = -FROM_RIGHT + SIZE.x
	offset_top = TOP
	offset_bottom = TOP + SIZE.y
	_base = _rect("Base", load_texture.call(DIR + BASE_DDJ))
	for i in SLOTS:
		_yellow.append(load_texture.call(DIR + PARTS[i] + "_y.ddj"))
		_red.append(load_texture.call(DIR + PARTS[i] + "_r.ddj"))
		_parts.append(_rect("Part%d" % i, null))
	show_states([])

func _rect(n: String, tex: Texture2D) -> TextureRect:
	var t := TextureRect.new()
	t.name = n
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_SCALE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.position = Vector2.ZERO
	t.size = SIZE
	add_child(t)
	return t

## The state of worn slot `slot` (0x65cc50): `types` the item's TypeIDs
## (empty: the slot is empty), `cur` its durability.
static func state_for(types: PackedInt32Array, cur: int) -> int:
	if types.size() < 3 or types[0] != 3 or types[1] != 1 or types[2] == 5 or types[2] == 12:
		return State.NONE
	if cur >= 7:
		return State.NONE
	return State.BROKEN if cur <= 0 else State.LOW

## Shows slot i's state (states[i], State); missing entries are NONE.
func show_states(states: Array) -> void:
	_states = states.duplicate()
	var any := false
	for i in SLOTS:
		var s := int(states[i]) if i < states.size() else State.NONE
		var part := _parts[i] if i < _parts.size() else null
		if part == null:
			continue
		match s:
			State.LOW:
				part.texture = _yellow[i]
			State.BROKEN:
				part.texture = _red[i]
			_:
				part.texture = null
		part.visible = s != State.NONE
		any = any or part.visible
	if _base != null:
		_base.visible = any
	visible = any

func states() -> Array:
	return _states
