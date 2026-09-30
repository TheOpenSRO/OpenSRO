extends RefCounted
class_name StatusNet

## An object's abnormal states (round 659): what the server's OpObjectStatus
## tells the zone. The number is retail's 0x3057 and the payload that
## message's flag-4 block; server/internal/session/status.go has the layout.
## Labels: READ (sro_client.exe), MEASURED, INFERRED, OURS, OPEN.
##
##   u8  owner kind (SkillNet.OWNER_CHARACTER 0, OWNER_MONSTER 1)  -- OURS
##   i64 id                                                        -- OURS
##   u16 cause (0)
##   u8  flags; 4 = the abnormal block follows
##   u32 mask                        -- READ: 0x8a9e30 `if (flags & 4)`
##   u8  level, one per set bit b of mask with (1 << b) & 0x17fefc0,
##       low bit first               -- READ: MsgStreamBuffer 0x9d2220
##
## The mask is stored on the object (+0x2c4, 0x9cd5e0), and the target
## window's buff viewer adds one icon per set bit, low to high, after the
## skill buffs (0x699480 -> 0x7fd2e0). The icon and label per bit are
## UI_PARAM::AbnormalState_IconAndLabelForMask (0x7fdab0); its third string
## is the state's category, which the tooltip names.

const OP_OBJECT_STATUS := 0x3057
const FLAG_ABNORMAL := 0x4
## The bits that carry a level byte (0x9d2220's `& 0x17fefc0`). READ.
const LEVEL_BITS := 0x17fefc0

## bit -> [icon file under icon\stateodd\, label, category]; READ from
## 0x7fdab0's switch. Bits 12 and 23 have no case and draw nothing.
const STATES := {
	0: ["s_freeze_icon.ddj", "FZ", "PARAM_RESTRICTION"],
	1: ["s_frostbite_icon.ddj", "FB", "PARAM_RESTRICTION"],
	2: ["s_electricshock_icon.ddj", "ES", "PARAM_WEAKLY"],
	3: ["s_burn_icon.ddj", "BU", "PARAM_WEAKLY"],
	4: ["s_poisoning_icon.ddj", "PS", "PARAM_WEAKLY"],
	5: ["s_zombi_icon.ddj", "ZB", "PARAM_CURSING"],
	6: ["s_sleep_icon.ddj", "SLEEP", "PARAM_RESTRICTION"],
	7: ["s_root_icon.ddj", "ROOT", "PARAM_RESTRICTION"],
	8: ["s_blunting_icon.ddj", "SLOW", "PARAM_RESTRICTION"],
	9: ["s_fear_icon.ddj", "FEAR", "PARAM_CURSING"],
	10: ["s_myopia_icon.ddj", "MYOPIA", "PARAM_CURSING"],
	11: ["s_bleeding_icon.ddj", "BLOOD", "PARAM_WEAKLY"],
	13: ["s_dark_icon.ddj", "DN", "PARAM_WEAKLY"],
	14: ["s_stun_icon.ddj", "STUN", "PARAM_ETC"],
	15: ["s_disease_icon.ddj", "DISEASE", "PARAM_CURSING"],
	16: ["s_confusion_icon.ddj", "CHAOS", "PARAM_CURSING"],
	17: ["s_decay_icon.ddj", "CURSE_PD", "PARAM_WEAKLY"],
	18: ["s_weakness_icon.ddj", "CURSE_MD", "PARAM_WEAKLY"],
	19: ["s_powerless_icon.ddj", "CURSE_STR", "PARAM_WEAKLY"],
	20: ["s_dissociation_icon.ddj", "CURSE_INT", "PARAM_WEAKLY"],
	21: ["s_panic_icon.ddj", "CURSE_HP", "PARAM_CURSING"],
	22: ["s_combustion_icon.ddj", "CURSIE_MP", "PARAM_CURSING"],
	24: ["s_incubation_icon.ddj", "TIME_BOMB", "PARAM_CURSING"],
}

class ObjectStatus:
	var owner_kind: int = 0
	var owner_id: int = 0
	var mask: int = 0
	## bit -> level, for the bits that carry one.
	var levels: Dictionary = {}
	var error: String = ""

static func decode_object_status(data: PackedByteArray) -> ObjectStatus:
	var r := ObjectStatus.new()
	if data.size() < 12:
		r.error = "short"
		return r
	r.owner_kind = data[0]
	r.owner_id = data.decode_s64(1)
	var flags: int = data[11]
	if flags & FLAG_ABNORMAL == 0:
		return r
	if data.size() < 16:
		r.error = "short mask"
		return r
	r.mask = data.decode_u32(12)
	var at := 16
	for bit in 32:
		var b := 1 << bit
		if r.mask & b == 0 or LEVEL_BITS & b == 0:
			continue
		if at >= data.size():
			r.error = "short levels"
			return r
		r.levels[bit] = data[at]
		at += 1
	return r

## The set bits of a mask that draw an icon, low to high (0x699480's loop
## over 32 bits; 0x7fdab0 answers nothing for 12 and 23).
static func drawn_bits(mask: int) -> Array:
	var out: Array = []
	for bit in 32:
		if mask & (1 << bit) != 0 and STATES.has(bit):
			out.append(bit)
	return out

## The icon path for a bit, "" for none.
static func icon_path(bit: int) -> String:
	if not STATES.has(bit):
		return ""
	return "icon\\stateodd\\" + String(STATES[bit][0])

static func label(bit: int) -> String:
	return String(STATES[bit][1]) if STATES.has(bit) else ""

static func category(bit: int) -> String:
	return String(STATES[bit][2]) if STATES.has(bit) else ""

## The tooltip 0x7fc260 builds for an abnormal slot (kind 2), READ in part:
## the text of "PARAM_" + the label, then " <level><UIIT_STT_GRADE>" when the
## slot carries a level, then a line with the category's text and
## UIIT_STT_MACROPOTION_ABNORMAL. OPEN: the description line it adds after
## (a DE_UIIT_MSG_STATE_SKILL_CURSING_ text whose full key was not read).
## `text` resolves a token (UI text tables); a token it cannot resolve is
## shown as the token.
static func tooltip(bit: int, level: int, text: Callable) -> String:
	if not STATES.has(bit):
		return ""
	var t := func(token: String) -> String:
		return String(text.call(token)) if text.is_valid() else token
	var head: String = t.call("PARAM_" + label(bit))
	if level != 0:
		head += " %d%s" % [level, t.call("UIIT_STT_GRADE")]
	return "%s\n%s %s" % [head, t.call(category(bit)), t.call("UIIT_STT_MACROPOTION_ABNORMAL")]
