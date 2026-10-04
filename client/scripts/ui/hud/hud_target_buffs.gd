extends Control
class_name HudTargetBuffs

## The selected target's buffs, under the target window (round 638): retail's
## CIFBuffViewer, `GDR_TW_BUFF` (ID 100) in resinfo\iftargetwindow.txt. Every
## rule here is read out of sro_client.exe unless it says OURS;
## docs/protocol/target_window_buffs.md has the full record with the
## addresses. Labels: READ (the binary), MEASURED (the archives), INFERRED,
## OURS (a choice of this project), OPEN.
##
## WHERE IT SITS (READ, CIFTargetWindow's select 0x699540, 0x69a182..0x69a1cb):
## after the piece is chosen the viewer is shown and moved to
## (window x, piece y + piece height + 1) -- directly under the shown piece,
## at its left edge. The layout's own Rect (0,37) is not used. HudTarget
## places it (HudTarget.buff_viewer_offset).
##
## WHICH TARGETS (READ, the same function): a byte set to 1 in the CICMonster
## branch (0x6999ec, every rarity), the CICCos branch (0x699b62: pets, horses,
## transport) and the CICUser branch (0x699ee2: players, this player
## included); the CICNPC and CICATStruct branches leave it 0 and the viewer
## stays hidden (0x69a187 skips it and kills the refresh timer, 0x69a269).
##
## WHAT IT SHOWS (READ, 0x9d25e0 -> 0x699480): the target's list of skill
## objects (CIDecoSkill, the character's +0x284, a std::list in arrival order:
## 0x9cd050 inserts before the head), those of type 2 -- made by 0xa54020,
## which the 0xB0BD buff-start handler calls for EVERY owner it finds, not
## only this player -- and type 3 (0xa53fc0, from 0xB0BE, a buff carrying a
## name; OpenSRO sends none). Then the abnormal-state bits of +0x2c4
## (0x7fd2e0, into the second list), one icon per set bit, low to high --
## since round 659 OpenSRO sends every object's mask (StatusNet, 0x3057), and
## World3D hands them in as entries with a negative id (abnormal_id): the
## icon is icon\stateodd\ + 0x7fdab0's file, drawn like a skill icon, and
## the tooltip StatusNet.tooltip's (0x7fc260 kind 2, READ in part). The premium IS a skill buff (round 638 review): the premium items
## carry [USU1:SKILL_MALL_PRE_APRU_4W_01], whose job engages the skill and
## sends 0xB0BD, so it shows here as any buff does. Only the buff bar's
## item-time kinds 3/4/5 (the UIL1/UIU1 grants) never reach this viewer.
## 0xB0BD attaches its object only when the owner's +0x21c is not -1
## (0x8a5d58); the item-use effects (0x8735d0) use ids 0x80000023..25, which
## the collector skips as not > 0.
##
## THE GRID (READ, 0x699480 sets it, 0x7fbea0 lays it out): 8 per row
## (0x7fabb0(8)), a 23 x 23 pitch (0x7fabc0(0x17, 0x17)), 20 x 20 icons
## (0x7fabe0(0x14, 0x14)). The main list's icon i at ((i % 8) * 23,
## (i / 8) * 23); a skill with `bbuf` goes to the second list (0x7fd020:
## param "is type 3" clear and the skill row's +0x184 set), whose icon j sits
## at ((j % 8) * 23, (j / 8 + rows1) * 23 + 2). rows1 is 0 for an EMPTY main
## list (0x7fbff1: `je` past the division) -- unlike the buff bar's board,
## which counts an empty list as a row. No cap (+0x36c / +0x370 are 0 from
## the constructor 0x7fb820).
##
## A SLOT (READ, 0x7fd020 -> 0x806d50(0, 0, lnks, type3, 1)): a CIFStateSlot
## like the buff bar's, but its first argument is 0, so NO time gauge is made
## and the slot is the bare 20 x 20 icon (0x807160..0x80719a sizes it to the
## icon when +0x388 is null). The icon file is the skill row's +0x108, the
## same 32 x 32 skill-window icon the buff bar draws (0x7ff240 kind 1), so it
## is point-sampled to 20 x 20 the same way (HudBuffBoard.retail_icon_image).
## The `lnks` frame and the admittance sprites are the buff bar's OPEN items.
##
## LIVE (READ): the target window arms timer 1 at 1000 ms when it shows the
## viewer (0x69a215, 0xb93320) and its OnTimer (vslot_005 0x6993a0) re-reads
## the target's list and diffs it into the viewer (0x7fd640): an icon whose
## skill id is still in the list stays where it is (its "not affected" byte
## is refreshed); one that is not is removed at once -- no burst, no sound;
## what is new is appended in list order; then the grid is laid out again.
## A target that is gone clears the viewer (0x69945b -> 0x7fbcf0). So an icon
## appears or goes within a second of its start or end, as retail's does.
##
## THE TOOLTIP (READ, 0x7fc260 builds it, 0x653dc0 stores it on the slot, and
## CIFStateSlot::vslot_048 0x806640 shows it through the generic tooltip when
## the slot's parent is not a CIFMagicStateBoard): "%s Lv %d\n\n" -- the
## name and the row's level, with the LITERAL "Lv" (not UIIT_STT_LEVEL_LV) --
## or "%s\n\n" for twelve mall/fortress name codes (NAME_ONLY_CODES; the buff
## bar's list less SN_SKILL_MALL_PRE_APRU_4W); then the description plus
## "\n\n" when it is not empty; then the skill's parameter lines from
## 0x96e480(7) -- NOT built here (OPEN: that is the skill window's parameter
## text, which OpenSRO does not generate). No remaining-time line: the
## entry's +0x28 stays 0 (0x7fb0f0) for a skill buff. A type-3 entry adds
## "%s : %s" (UIIT_STT_TARGETTING, its name); none are sent.
## OURS: the trailing blank lines are trimmed, so Godot's tooltip does not
## draw empty rows under the text.
##
## NO RIGHT-CLICK, NO LEFT-CLICK (READ): CIFBuffViewer's vtable (0xdcf59c,
## 49 slots) overrides only slots 0, 1, 2 and 10; its mouse slots are
## CIFWnd's empty stubs, and so are CIFStateSlot's own. Only the buff bar
## (CIFMagicStateBoard::vslot_033) cancels a buff.

## An abnormal state's entry id: -1 - its mask bit, so it can never meet a
## skill id (0x9d25e0 skips a skill id that is not > 0). OURS.
static func abnormal_id(bit: int) -> int:
	return -1 - bit

## The mask bit of an abnormal entry id, -1 for a skill.
static func abnormal_bit(id: int) -> int:
	return -1 - id if id < 0 else -1

## An object's abnormal states as viewer entries, in 0x699480's order (bit 0
## up): [{skill_id: abnormal_id(bit), token: 0, level}]. `levels` is
## StatusNet's bit -> level.
static func abnormal_entries(mask: int, levels: Dictionary) -> Array:
	var out: Array = []
	for bit in StatusNet.drawn_bits(mask):
		out.append({"skill_id": abnormal_id(bit), "token": 0, "level": int(levels.get(bit, 0))})
	return out

const COLUMNS := 8
const PITCH := Vector2(23, 23)
const ICON_SIZE := Vector2(20, 20)
const SECOND_LIST_GAP := 2
## Timer 1's period (0x69a215: push 0x3e8).
const REFRESH_MS := 1000

## The name codes whose title is the name alone (0x7fc412..0x7fc594, each
## compared at its full length).
const NAME_ONLY_CODES := [
	"SN_SKILL_ASSAULTING_SOILDER", "SN_SKILL_ELITE_ASSAULTING_SOILDER",
	"SN_SKILL_CENTURION", "SN_SKILL_ASSAULTING_LEADER",
	"SN_SKILL_ELITE_IMPERIAL_GUARD", "SN_SKILL_COMBAT_COMMANDER",
	"SN_SKILL_MALL_PET_SKILL_COLD", "SN_SKILL_MALL_PET_SKILL_FIRE",
	"SN_SKILL_MALL_PET_SKILL_LIGHTNING", "SN_SKILL_MALL_PET_WATCH_CHULHYEN",
	"SN_SKILL_MALL_PET_WATCH_AGOL", "SN_SKILL_MALL_PET_GROWTH_POTION",
]

## One icon in the viewer.
class Entry:
	var skill_id: int
	var token: int
	## An abnormal state's level (the 0x3057 byte; 0 for none or a skill).
	var level: int
	var main_list: bool
	var slot: Slot

## A slot's control: the 20x20 icon; its tooltip is the viewer's text.
class Slot extends Control:
	var viewer: HudTargetBuffs
	var skill_id: int
	var icon: TextureRect

	func _get_tooltip(_at_position: Vector2) -> String:
		return viewer.tooltip_for(skill_id) if viewer != null else ""

## Every owner's active buffs in the order they started, as OpBuffStart and
## OpBuffEnd tell the zone: OpenSRO's stand-in for each object's +0x284
## list (0xB0BD adds to it for any owner, 0xB072 removes). Keyed by the
## owner key World3D's effects use ("character:<id>" / "monster:<id>").
class Book:
	## owner key -> Array of [token, skill_id], arrival order.
	var _owners: Dictionary = {}

	func start(owner_key: String, token: int, skill_id: int) -> void:
		if token == 0 or skill_id <= 0:
			# 0x9d25e0 skips a skill object whose skill id is not > 0.
			return
		var list: Array = _owners.get(owner_key, [])
		for e in list:
			if int(e[0]) == token:
				# OURS: a token the zone re-sends (sendBuffsInView) is the
				# same buff; retail's objects are keyed per packet.
				e[1] = skill_id
				return
		list.append([token, skill_id])
		_owners[owner_key] = list

	func end(owner_key: String, tokens: Array) -> void:
		var list: Array = _owners.get(owner_key, [])
		var i := 0
		while i < list.size():
			if tokens.has(int(list[i][0])):
				list.remove_at(i)
			else:
				i += 1
		if list.is_empty():
			_owners.erase(owner_key)

	## An owner that left view (or died): its objects are gone with it.
	func drop(owner_key: String) -> void:
		_owners.erase(owner_key)

	func clear() -> void:
		_owners.clear()

	## [{token, skill_id}] in arrival order -- a copy.
	func list_of(owner_key: String) -> Array:
		var out: Array = []
		for e in _owners.get(owner_key, []):
			out.append({"token": int(e[0]), "skill_id": int(e[1])})
		return out

var _builder: UiBuilder = null
var catalog: SkillBuffCatalog = null
## The grid this viewer lays out with: the target window's by default
## (COLUMNS, PITCH, ICON_SIZE); a quick party slot's viewer sets its own
## (set_grid, round 715).
var grid_columns := COLUMNS
var grid_pitch := PITCH
var grid_icon := ICON_SIZE
var _main: Array = []
var _second: Array = []
## Where an icon's full-size Image comes from (tests replace it).
var icon_image_source: Callable = Callable()
var _icon_cache: Dictionary = {}

func _init(builder: UiBuilder = null, skill_catalog: SkillBuffCatalog = null) -> void:
	_builder = builder
	catalog = skill_catalog
	name = "GDR_TW_BUFF"
	# OURS, as the buff bar's board: the viewer lets clicks through its empty
	# cells; each slot takes the mouse for its tooltip.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layout()

## The grid's three calls (0x7fabb0 per row, 0x7fabc0 pitch, 0x7fabe0 icon
## size), as another owner of a CIFBuffViewer makes them.
func set_grid(columns: int, pitch: Vector2, icon: Vector2) -> void:
	grid_columns = maxi(columns, 1)
	grid_pitch = pitch
	grid_icon = icon
	_layout()

## Whether the catalog can say which list a skill goes to. Until it can, the
## viewer is left as it is (OURS: retail's reference data is always loaded).
func ready_to_fill() -> bool:
	return catalog == null or catalog.is_ready() or catalog.poll()

## The first fill (0x699480): everything cleared, then each buff added in
## list order, then the grid laid out.
func rebuild(buffs: Array) -> void:
	clear_all()
	for b in buffs:
		_add(int(b["skill_id"]), int(b.get("token", 0)), int(b.get("level", 0)))
	_layout()

## The per-second diff (0x7fd640), see the header.
func sync(buffs: Array) -> void:
	var left: Array = buffs.duplicate()
	var changed := false
	for list in [_main, _second]:
		var i := 0
		while i < list.size():
			var e: Entry = list[i]
			var at := -1
			for k in left.size():
				if int(left[k]["skill_id"]) == e.skill_id:
					at = k
					break
			if at >= 0:
				e.token = int(left[at].get("token", e.token))
				e.level = int(left[at].get("level", e.level))
				left.remove_at(at)
				i += 1
			else:
				_free_slot(e)
				list.remove_at(i)
				changed = true
	for b in left:
		_add(int(b["skill_id"]), int(b.get("token", 0)), int(b.get("level", 0)))
		changed = true
	if changed:
		_layout()

## Everything gone at once (0x7fbcf0).
func clear_all() -> void:
	for list in [_main, _second]:
		for e in list:
			_free_slot(e)
		list.clear()
	_layout()

func _free_slot(e: Entry) -> void:
	if e.slot != null and is_instance_valid(e.slot):
		remove_child(e.slot)
		e.slot.queue_free()
	e.slot = null

func _add(skill_id: int, token: int, level: int = 0) -> void:
	var bit := abnormal_bit(skill_id)
	var info: Dictionary = {}
	if bit >= 0:
		# 0x7fd2e0: an abnormal slot, always in the second list; its icon is
		# 0x7fdab0's (kind 2 of 0x7ff240).
		info = {"icon": StatusNet.icon_path(bit), "bbuf": true}
	elif catalog != null:
		info = catalog.info(skill_id)
	var e := Entry.new()
	e.skill_id = skill_id
	e.token = token
	e.level = level
	e.main_list = not bool(info.get("bbuf", false))
	e.slot = _make_slot(skill_id, info)
	add_child(e.slot)
	(_main if e.main_list else _second).append(e)

## A list's row count as 0x7fbea0 computes it: the main list 0 when empty,
## the second list at least one.
static func main_rows(count: int) -> int:
	return 0 if count == 0 else (count - 1) / COLUMNS + 1

static func second_rows(count: int) -> int:
	return maxi(count - 1, 0) / COLUMNS + 1

## Icon i's position; `second` for the second list, which starts rows1 rows
## down and 2 px lower.
static func slot_position(i: int, second: bool, rows1: int) -> Vector2:
	if not second:
		return Vector2((i % COLUMNS) * PITCH.x, (i / COLUMNS) * PITCH.y)
	return Vector2((i % COLUMNS) * PITCH.x, (i / COLUMNS + rows1) * PITCH.y + SECOND_LIST_GAP)

func _layout() -> void:
	var c := grid_columns
	var rows1 := 0 if _main.is_empty() else (_main.size() - 1) / c + 1
	for i in _main.size():
		(_main[i] as Entry).slot.position = Vector2((i % c) * grid_pitch.x, (i / c) * grid_pitch.y)
	for i in _second.size():
		(_second[i] as Entry).slot.position = Vector2((i % c) * grid_pitch.x, (i / c + rows1) * grid_pitch.y + SECOND_LIST_GAP)
	# The viewer's own size (0x7fc176: vslot 0x54(stepx * per, rows * stepy)).
	size = Vector2(grid_pitch.x * c, (rows1 + maxi(_second.size() - 1, 0) / c + 1) * grid_pitch.y)

## The tooltip text (0x7fc260, kind 1), see the header.
func tooltip_for(skill_id: int) -> String:
	var bit := abnormal_bit(skill_id)
	if bit >= 0:
		var level := 0
		for list in [_main, _second]:
			for e in list:
				if (e as Entry).skill_id == skill_id:
					level = (e as Entry).level
		return StatusNet.tooltip(bit, level, _ui_text)
	var info: Dictionary = catalog.info(skill_id) if catalog != null else {}
	var code := String(info.get("name_code", ""))
	var skill_name: String = catalog.text_of(code) if catalog != null else ""
	if skill_name == "":
		skill_name = code if code != "" else "Skill %d" % skill_id
	var text := ""
	if code in NAME_ONLY_CODES:
		text = "%s\n\n" % skill_name
	else:
		text = "%s Lv %d\n\n" % [skill_name, int(info.get("level", 0))]
	var desc: String = catalog.text_of(String(info.get("desc_code", ""))) if catalog != null else ""
	if desc != "":
		text += desc + "\n\n"
	return text.strip_edges(false, true)

## A UI text lookup for the abnormal tooltip (tests replace ui_text).
var ui_text: Callable = Callable()

func _ui_text(token: String) -> String:
	if ui_text.is_valid():
		return String(ui_text.call(token))
	if _builder != null:
		var s := _builder.resolve_text(token)
		if s != "" and s != token:
			return s
	return token

func _icon_texture(path: String) -> Texture2D:
	var full := HudBuffBoard.icon_path(path)
	if full == "":
		return null
	if not _icon_cache.has(full):
		var src: Image = null
		if icon_image_source.is_valid():
			src = icon_image_source.call(full)
		elif _builder != null:
			src = _builder.load_image(full)
		var img := HudBuffBoard.retail_icon_image(src, int(grid_icon.x), int(grid_icon.y))
		_icon_cache[full] = ImageTexture.create_from_image(img) if img != null else null
	return _icon_cache[full]

func _make_slot(skill_id: int, info: Dictionary) -> Slot:
	var slot := Slot.new()
	slot.name = "Buff%d" % skill_id
	slot.viewer = self
	slot.skill_id = skill_id
	slot.size = grid_icon
	slot.custom_minimum_size = grid_icon
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = _icon_texture(String(info.get("icon", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.size = grid_icon
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)
	slot.icon = icon
	return slot

## Test and QA read-outs.
func count(main_list: bool = true) -> int:
	return (_main if main_list else _second).size()

func skill_ids(main_list: bool = true) -> Array:
	var out: Array = []
	for e in (_main if main_list else _second):
		out.append((e as Entry).skill_id)
	return out

func slot_of(skill_id: int) -> Slot:
	for list in [_main, _second]:
		for e in list:
			if (e as Entry).skill_id == skill_id:
				return (e as Entry).slot
	return null

## One line for the log: every icon, its list and where it sits.
func describe() -> String:
	var parts := PackedStringArray()
	for list in [_main, _second]:
		for e in list:
			var en := e as Entry
			parts.append("%d@%s%s" % [en.skill_id, str(en.slot.position), "" if en.main_list else "(2nd)"])
	return "%d main, %d second: %s" % [_main.size(), _second.size(), ", ".join(parts)]
