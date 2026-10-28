extends RefCounted
class_name SkinChangeModel

## What the skin change window chooses (round 838), apart from its drawing:
## CIFChangePlayerModel's state, READ from sro_client.exe
## (docs/WORLD_ISSUES.md, round 838; the window is SkinChangeWindow).
##
## - **The list** (IFChangePlayerModel::FUN_007eeb30): the client's id list
##   0xeedf08 -- filled from `server_dep\silkroad\textdata\usableresobjiddata
##   .txt` by Client_LoadRefDataFile case 7 (0x9538b3) -- for the player's race
##   (+0x288 China, +0x2b0 Europe), keeping the ids that are player bodies
##   (bionic, TypeID1 1), split by the body's sex (+0x1c4) into a woman's list
##   (+0xa20) and a man's (+0xa30), each in the file's order.
## - **The start** (vslot_040 0x7edff0): the shown sex is the player's; FIGURE's
##   range is 1..that list's size, at the player's own body's 1-based place;
##   HEIGHT and WEIGHT are 0..4 at the scale byte's low and high nibbles.
## - **Male / Female** (0x7edef0 / 0x7edf10): the other list. That FIGURE
##   then starts at 1 is INFERRED.
## - **Confirm** (0x7edc90, re-tested on every change): disabled while the shown
##   sex is the player's, the chosen body is the player's and the scale is
##   unchanged.
## - **The pre-check** (SendItem_HandleUseItem 0x796660 case 9): a body of the
##   other sex while equip slots 0..5 or 8 or any avatar slot hold something
##   is refused here with UIIT_MSG_CHAR_SKIN_ERR_ARMOR (0x1892) and nothing is
##   sent.

const SEX_WOMAN := 0
const SEX_MAN := 1
## The scale sliders' range (READ vslot_040: 0..4 each).
const SCALE_MAX := 4
## The refusal the client raises itself (category 1's 0x1892).
const ERR_ARMOR := 0x1892
const ERR_ARMOR_KEY := "UIIT_MSG_CHAR_SKIN_ERR_ARMOR"
## The equip slots a change of sex needs empty (READ: 0..5 and 8).
const GEAR_SLOTS := [0, 1, 2, 3, 4, 5, 8]

## The two lists, ids in file order.
var women: Array[int] = []
var men: Array[int] = []
## The player's own body, sex and scale byte.
var own_id := 0
var own_sex := SEX_MAN
var own_scale := 0x22
## The shown sex, the 1-based place in its list, and the scale byte.
var shown_sex := SEX_MAN
var figure := 1
var scale := 0x22

## Builds the lists from the usable-id file's ids, in order, keeping those
## `body_of` knows as a body of `race` ({race, sex} or {} for anything else).
static func from_ids(ids: Array, race: int, body_of: Callable) -> SkinChangeModel:
	var m := SkinChangeModel.new()
	for id in ids:
		var b: Dictionary = body_of.call(int(id))
		if b.is_empty() or int(b.get("race", -1)) != race:
			continue
		if int(b.get("sex", -1)) == SEX_WOMAN:
			m.women.append(int(id))
		elif int(b.get("sex", -1)) == SEX_MAN:
			m.men.append(int(id))
	return m

## The ids of a `usableresobjiddata.txt` (UTF-8 text: "<service>\t<id>" rows,
## service 1 kept), in order.
static func parse_usable_ids(text: String) -> Array[int]:
	var out: Array[int] = []
	for line in text.replace("\ufeff", "").replace("\r", "").split("\n", false):
		var cols := line.strip_edges().split("\t", false)
		if cols.size() < 2 or not cols[0].strip_edges().is_valid_int() or int(cols[0]) == 0:
			continue
		if cols[1].strip_edges().is_valid_int():
			out.append(int(cols[1]))
	return out

## Starts on the player's own body (vslot_040).
func start(player_id: int, player_sex: int, player_scale: int) -> void:
	own_id = player_id
	own_sex = player_sex
	own_scale = player_scale & 0xff
	shown_sex = player_sex
	scale = own_scale
	var at := list().find(player_id)
	figure = at + 1 if at >= 0 else 1

func list() -> Array[int]:
	return women if shown_sex == SEX_WOMAN else men

func figure_count() -> int:
	return list().size()

## The body FIGURE shows now, 0 when the list is empty.
func chosen_id() -> int:
	var l := list()
	if l.is_empty():
		return 0
	return l[clampi(figure, 1, l.size()) - 1]

func set_sex(sex: int) -> void:
	if sex == shown_sex:
		return
	shown_sex = sex
	figure = 1

func set_figure(v: int) -> void:
	figure = clampi(v, 1, maxi(1, figure_count()))

func height() -> int:
	return scale & 0x0f

func weight() -> int:
	return (scale >> 4) & 0x0f

func set_height(v: int) -> void:
	scale = (scale & 0xf0) | clampi(v, 0, SCALE_MAX)

func set_weight(v: int) -> void:
	scale = (scale & 0x0f) | (clampi(v, 0, SCALE_MAX) << 4)

## Confirm's state (0x7edc90).
func can_confirm() -> bool:
	if chosen_id() == 0:
		return false
	return not (shown_sex == own_sex and chosen_id() == own_id and scale == own_scale)

## Whether the change is of sex.
func changes_sex() -> bool:
	return shown_sex != own_sex

## The pre-check: 0 to send, ERR_ARMOR when a change of sex finds gear on.
## `worn` holds the occupied equip slot numbers, `avatars` the avatar items held.
func precheck(worn: Array, avatars: int) -> int:
	if not changes_sex():
		return 0
	for s in GEAR_SLOTS:
		if worn.has(s):
			return ERR_ARMOR
	return ERR_ARMOR if avatars > 0 else 0
