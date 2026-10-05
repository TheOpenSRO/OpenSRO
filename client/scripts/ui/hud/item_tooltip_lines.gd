extends RefCounted
class_name ItemTooltipLines

## The lines of an item's hover tooltip, composed as the original composes
## them (round 731; docs/protocol/item_tooltip.md). Each entry is a
## Dictionary {"text": String, "color": Color, "bold": bool, "icon": bool};
## a blank entry has text "" -- the original's colour-0 entries, drawn as an
## empty line (no rule: round 731 measured the "rules" as the window behind).
##
## The four equipment builders share one skeleton (READ, UI_SILKMALL
## 0x6827c0 armour, 0x683040 shield, 0x682ba0 accessory, 0x682df0 weapon):
##
##   name (0x67a570) [blank]                     -- bold, the name icon
##   seal / set (UI_PARAM 0x66fa60)              -- gold / green, bold
##   "Sort of item: <type>"                      -- beige
##   armour position (armour only, 0x6827c0)     -- beige
##   "Degree: %d degrees" (0x66f0c0)             -- beige
##   [blank]
##   the description (0x66f850) [blank]          -- white, when it resolves
##   the stat block (0x66c5b0)                   -- white
##   [blank] requirements (IFSlotWithHelp 0x67eec0) -- white / red
##   "Max. no. of magic options: %dUnit" (0x66e030) -- beige
##   [blank] magic options (0x6780c0)            -- cyan
##   advanced elixir (UI_SOCKET 0x66fd60)        -- grey, bold
##   a store's price (0x6784a0, slot kind 0x0f)  -- white
##
## What is not the binary's is labelled OURS where it is done.

## Colours, ARGB as the client passes them (READ at the addresses named).
const WHITE := Color8(255, 255, 255)
## Sort of item, armour position, degree, max magic options (0xffefdaa4).
const BEIGE := Color8(0xef, 0xda, 0xa4)
## A seal item's name and seal line (0xffffd953).
const GOLD := Color8(0xff, 0xd9, 0x53)
## The set line (0xff6ce675).
const GREEN := Color8(0x6c, 0xe6, 0x75)
## An item with magic options: its name and its option lines (0xff00eaff).
const CYAN := Color8(0x00, 0xea, 0xff)
## An unmet requirement; a broken item's durability (0xffff4a4a).
const RED := Color8(0xff, 0x4a, 0x4a)
## "Able to use Advanced elixir." (0xffc8c8c8, 0x66fd60).
const GREY := Color8(0xc8, 0xc8, 0xc8)

## The equipment families (TypeID3) and their builder (READ, 0x685f20).
const ARMOUR_FAMILIES := [1, 2, 3, 9, 10, 11]
const SHIELD_FAMILY := 4
const ACCESSORY_FAMILIES := [5, 12]
const WEAPON_FAMILY := 6

## Armour position keys by TypeID4 (0x6827c0; the archive's armour rows read
## HA 1, SA 2, BA 3, LA 4, AA 5, FA 6 -- MEASURED).
const ARMOUR_POSITION_KEYS := {
	1: "UIIT_STT_ARMOR_POSITION_HEAD", 2: "UIIT_STT_ARMOR_POSITION_SHOULDER",
	3: "UIIT_STT_ARMOR_POSITION_BREAST", 4: "UIIT_STT_ARMOR_POSITION_LEG",
	5: "UIIT_STT_ARMOR_POSITION_HAND", 6: "UIIT_STT_ARMOR_POSITION_FOOT",
}

## Whether an item has a tooltip of the four-builder shape: equipment of
## TypeID 3/1 in one of those families.
static func is_equipment_shape(item: ItemTableReader.Item) -> bool:
	if item == null or item.type_ids.size() < 4:
		return false
	if item.type_ids[0] != 3 or item.type_ids[1] != 1:
		return false
	var fam := item.family()
	if fam == SHIELD_FAMILY:
		return item.type_ids[3] == 1 or item.type_ids[3] == 2
	return ARMOUR_FAMILIES.has(fam) or ACCESSORY_FAMILIES.has(fam) or fam == WEAPON_FAMILY

## A seal item: Rarity 2 or 6 (FUN_008ba600 on ref +0xa0, READ).
static func is_seal(item: ItemTableReader.Item) -> bool:
	return item.rarity == 2 or item.rarity == 6

## The seal keys' stock English rows (textuisystem.txt), for a table-less test.
const SEAL_FALLBACKS := {"PARAM_RARE_FIRST": "Seal of Star", "PARAM_RARE_FIRST2": "Seal of Nova",
	"PARAM_RARE_SECOND": "Seal of Moon", "PARAM_RARE_THIRD": "Seal of Sun"}

## The degree: (ItemClass - 1) / 3 + 1 (0x66f13b..0x66f15b, READ).
static func degree(item: ItemTableReader.Item) -> int:
	return (item.item_class - 1) / 3 + 1 if item.item_class > 0 else 0

## The seal line's key: the tier (ItemClass - 1) mod 3 (FUN_008ba6e0, READ):
## 0 "Seal of Star" (PARAM_RARE_FIRST2 "Seal of Nova" from ItemClass 31),
## 1 "Seal of Moon", 2 "Seal of Sun".
static func seal_key(item: ItemTableReader.Item) -> String:
	var tier := item.item_class - 1 - ((item.item_class - 1) / 3) * 3
	match tier:
		0:
			return "PARAM_RARE_FIRST2" if item.item_class >= 31 else "PARAM_RARE_FIRST"
		1:
			return "PARAM_RARE_SECOND"
		2:
			return "PARAM_RARE_THIRD"
	return ""

## The "(+x%)" quality of a value inside its [lower, upper] range: f =
## (value - lower) / (upper - lower) x 100, truncated, and 100 when the range
## is empty (0x66c5b0, READ). A reference item with no instance (a store's
## goods) has variance 0, so its value is the lower end: 0 %, or 100 % for an
## empty range -- the original's "Critical 2 (+100%)".
static func quality(value: float, lower: float, upper: float) -> int:
	if upper <= lower:
		return 100
	return int(clampf((value - lower) / (upper - lower), 0.0, 1.0) * 100.0)

## A min ~ max line's "(+x%)" for a reference item: each end rated on its own
## range and the two averaged, truncated (round 732's reading of 0x66c66f..
## 0x66c841) -- so 0 %, 100 % with both ranges empty, 50 % with one.
static func range_quality(lo_l: float, lo_u: float, hi_l: float, hi_u: float) -> int:
	return int((quality(lo_l, lo_l, lo_u) + quality(hi_l, hi_l, hi_u)) * 0.5)

## Composes the lines.
##
## ctx:
##   "text": Callable(key: String, fallback: String) -> String -- the UI table
##   "names": UiTextTable or null -- the object names (item and set names)
##   "type_name": String -- "Sort of item"'s name (ItemTypeNames), "" if none
##   "set_name": String -- the set line's text, "" if none
##   "player": {"level", "str", "int", "country", "gender"} -- -1 unknown
##   "instance": {} for a reference item (a store's goods: variance 0);
##     otherwise any of "plus", "durability" [cur, max], "magic_options"
##     (Array of String), "adv_elixir" (int), "stats" (Dictionary of the
##     instance's computed values, lane B), "unknown_variance" (bool: an
##     owned item whose white stats the client does not have yet)
##   "price": int, a store's own price for its goods, or -1
##   "description": String, column 6's text through the object table, or ""
static func compose(item: ItemTableReader.Item, ctx: Dictionary) -> Array:
	var lines: Array = []
	if item == null:
		return lines
	var t: Callable = ctx.get("text", func(_k, f): return f)
	var instance: Dictionary = ctx.get("instance", {})
	var names: UiTextTable = ctx.get("names", null)
	var plus: int = int(instance.get("plus", 0))
	var options: Array = instance.get("magic_options", [])
	if not is_equipment_shape(item):
		return _compose_other(item, ctx)

	# 1. The name (0x67a570): "%s (+%d)" with the plus, gold for a seal item,
	# cyan with magic options, else white; bold, with the name icon; a blank
	# after it.
	var name := item.display_name(names)
	if name == "":
		name = item.code_name
	if plus > 0:
		name = "%s (+%d)" % [name, plus]
	var name_colour := WHITE
	if is_seal(item):
		name_colour = GOLD   # pink 0xffff75f2 when FUN_008bd660 holds: OPEN
	elif not options.is_empty():
		name_colour = CYAN
	_add(lines, name, name_colour, true, true)
	_blank(lines)

	# 2. Seal and set (0x66fa60): the seal line, bold gold; Rarity above 2
	# adds the set line, bold green, after a blank when there was no seal.
	var sealed := false
	if is_seal(item):
		var key := seal_key(item)
		if key != "":
			_add(lines, t.call(key, SEAL_FALLBACKS.get(key, key)), GOLD, true)
			sealed = true
	if item.rarity > 2:
		if not sealed:
			_blank(lines)
		var set_name: String = ctx.get("set_name", "")
		if set_name != "":
			_add(lines, set_name, GREEN, true)

	# 3. Sort of item, armour position, degree -- beige -- then a blank.
	var type_name: String = ctx.get("type_name", "")
	_add(lines, "%s: %s" % [t.call("UIIT_STT_ITEM_TYPE", "Sort of item"), type_name], BEIGE)
	var fam := item.family()
	if ARMOUR_FAMILIES.has(fam):
		var pos_key: String = ARMOUR_POSITION_KEYS.get(item.type_ids[3], "")
		if pos_key != "":
			_add(lines, "%s: %s" % [t.call("UIIT_STT_ARMOR_POSITION", "Mounting part"), t.call(pos_key, pos_key)], BEIGE)
	var deg := degree(item)
	if deg > 0:
		var fmt: String = t.call("UIIT_TOOLTIP_EQUIPMENT_CLASS", "Degree: %d degrees")
		_add(lines, fmt.replace("%d", str(deg)), BEIGE)
	_blank(lines)

	# 3b. The description (0x66f850): column 6's key through the object text
	# table (FUN_008c9bb0), white, then a blank -- only when it resolves.
	var desc: String = ctx.get("description", "")
	if desc != "":
		_add(lines, desc, WHITE)
		_blank(lines)

	# 4. The stat block (0x66c5b0).
	_stats(lines, item, ctx, t, plus)

	# 5. Requirements (0x67eec0): a blank, then each line white when met and
	# red when not.
	_requirements(lines, item, ctx, t)

	# 6. Max. no. of magic options (0x66e030), beige -- always, 0 included
	# (every builder calls it unconditionally).
	_add(lines, "%s: %d%s" % [t.call("UIIT_STT_AVATAR_MAGICOPTION_MAXCOUNT", "Max. no. of magic options"),
		item.max_magic_options, t.call("UIIT_STT_UNIT", "Unit")], BEIGE)

	# 7. Magic options (0x6780c0): a blank, then each option in cyan. The
	# option texts come from the instance (lane B, round 732).
	if not options.is_empty():
		_blank(lines)
		for o in options:
			_add(lines, String(o), CYAN)

	# 8. Advanced elixir (0x66fd60): unused -> grey bold "Able to use Advanced
	# elixir."; used -> UIIT_STT_SOCKET_TIP_UPPER_REINFOREC_USED with the
	# count, white bold.
	var adv: int = int(instance.get("adv_elixir", 0))
	if adv == 0:
		_add(lines, t.call("UIIT_STT_SOCKET_TIP_UPPER_REINFOREC_UNUSE", "Able to use Advanced elixir."), GREY, true)
	else:
		var used: String = t.call("UIIT_STT_SOCKET_TIP_UPPER_REINFOREC_USED", "%d")
		_add(lines, used.replace("%d", str(adv)), WHITE, true)

	# 9. Prices (0x6784a0): a store's goods (slot kind 0x0f) print
	# "%s : %I64d%s" with UIIT_STT_PRICE and UIIT_STT_GOLD, no blank before
	# (READ, 0x678cf2..). PARAM_STORE_PURCHASE_PRICE is the store's offer for
	# the player's own item while a shop is open (kinds 0x46/0x47/0x21): not
	# built (OPEN).
	_price(lines, ctx, t)
	return lines

## The stat block, in the binary's order, each line only when its value is
## non-zero. Values: an instance's computed stats when given (lane B,
## ItemTooltipInstance); otherwise the reference's lower ends plus the plus
## increments -- what a variance-0 instance computes. The "(+x%)" is printed
## for a reference item (variance 0: 0 %, or 100 % on an empty range; a
## min ~ max line averages its two ends) and for an instance whose variance
## is known; an owned item whose instance the client has not got shows none
## (OURS: the percent would be invented).
static func _stats(lines: Array, item: ItemTableReader.Item, ctx: Dictionary, t: Callable, plus: int) -> void:
	var instance: Dictionary = ctx.get("instance", {})
	var given: Dictionary = instance.get("stats", {})
	var unknown := bool(instance.get("unknown_variance", false)) and given.is_empty()
	var inc := item.plus_incs
	# The plus bonus is TRUNCATED (round 732: c:0x8bdb75's fistp chops).
	var inc_at := func(i: int) -> float: return float(int(float(inc[i]) * plus)) if i < inc.size() else 0.0

	# Phy./Mag. atk: "%s %d ~ %d (+%d%%)".
	if item.phys_atk != Vector2i.ZERO:
		var pa: Array = given.get("pa", [item.phys_atk.x + roundi(inc_at.call(ItemTableReader.PLUS_INC_PA)),
			item.phys_atk.y + roundi(inc_at.call(ItemTableReader.PLUS_INC_PA))])
		var q: int = int(given.get("pa_q", range_quality(item.phys_atk.x, item.phys_atk_upper.x, item.phys_atk.y, item.phys_atk_upper.y)))
		_stat(lines, "%s %d ~ %d" % [t.call("PARAM_PA", "Phy. atk. pwr."), pa[0], pa[1]], q, unknown)
	if item.mag_atk != Vector2i.ZERO:
		var ma: Array = given.get("ma", [item.mag_atk.x + roundi(inc_at.call(ItemTableReader.PLUS_INC_MA)),
			item.mag_atk.y + roundi(inc_at.call(ItemTableReader.PLUS_INC_MA))])
		var q: int = int(given.get("ma_q", range_quality(item.mag_atk.x, item.mag_atk_upper.x, item.mag_atk.y, item.mag_atk_upper.y)))
		_stat(lines, "%s %d ~ %d" % [t.call("PARAM_MA", "Mag. atk. pwr."), ma[0], ma[1]], q, unknown)
	# Defences and absorptions: "%s %.1f (+%d%%)", one value.
	for spec in [["pd", "PARAM_PD", "Phy. def. pwr.", item.phys_def, ItemTableReader.PLUS_INC_PD],
			["md", "PARAM_MD", "Mag. def. pwr.", item.mag_def, ItemTableReader.PLUS_INC_MD],
			["pr", "PARAM_PR", "Phy. absorption", item.phys_absorb, ItemTableReader.PLUS_INC_PAR],
			["mr", "PARAM_MR", "Mag. absorption", item.mag_absorb, ItemTableReader.PLUS_INC_MAR]]:
		var range_v: Vector2 = spec[3]
		if range_v == Vector2.ZERO:
			continue
		var v: float = float(given.get(spec[0], range_v.x + inc_at.call(spec[4])))
		var q: int = int(given.get(spec[0] + "_q", quality(range_v.x, range_v.x, range_v.y)))
		_stat(lines, "%s %.1f" % [t.call(spec[1], spec[2]), v], q, unknown)
	# Durability: "%s %d/%d (+%d%%)", red when broken (0x66c5b0). The max is
	# the instance's (lane B's dur_max, or the server's durability block),
	# else the reference's lower end; the percent is the instance's
	# trunc(q / 0.31) (round 732), 0 for a reference item.
	var dur: Array = instance.get("durability", [])
	var dur_l := item.durability
	if dur_l > 0 or dur.size() == 2:
		var mx: int = int(given.get("dur_max", int(dur[1]) if dur.size() == 2 else dur_l))
		var cur: int = int(dur[0]) if dur.size() == 2 else int(instance.get("durability_cur", mx))
		var body := "%s %d/%d" % [t.call("PARAM_DUR", "Durability"), cur, mx]
		var known := given.has("dur_q") or not bool(instance.get("unknown_variance", false))
		if known:
			body = "%s (+%d%%)" % [body, int(given.get("dur_q", 0))]
		_add(lines, body, RED if cur == 0 and (dur.size() == 2 or instance.has("durability_cur")) else WHITE)
	# Attack distance: "%s %.1f m", the range in tenths (ref +0x254).
	if item.attack_range != 0:
		_add(lines, "%s %.1f m" % [t.call("PARAM_RANGE", "Attack distance"), item.attack_range / 10.0], WHITE)
	# Attack rate, parry rate, critical, blocking rate: "%s %d (+%d%%)".
	if item.attack_rate != 0:
		var v: int = int(given.get("hr", item.attack_rate + roundi(inc_at.call(ItemTableReader.PLUS_INC_HR))))
		_stat(lines, "%s %d" % [t.call("PARAM_HR", "Attack rate"), v],
			int(given.get("hr_q", quality(item.attack_rate, item.attack_rate, item.attack_rate_upper))), unknown)
	if item.parry != Vector2.ZERO:
		var v: int = int(given.get("er", roundi(item.parry.x + inc_at.call(ItemTableReader.PLUS_INC_ER))))
		_stat(lines, "%s %d" % [t.call("PARAM_ER", "Parry rate"), v],
			int(given.get("er_q", quality(item.parry.x, item.parry.x, item.parry.y))), unknown)
	if item.critical != 0:
		var v: int = int(given.get("cr", item.critical))
		_stat(lines, "%s %d" % [t.call("PARAM_CRITICAL", "Critical"), v],
			int(given.get("cr_q", quality(item.critical, item.critical, item.critical_upper))), unknown)
	if item.block != Vector2.ZERO:
		var v: int = int(given.get("br", roundi(item.block.x)))
		_stat(lines, "%s %d" % [t.call("PARAM_BLOCKING", "Blocking rate"), v],
			int(given.get("br_q", quality(item.block.x, item.block.x, item.block.y))), unknown)
	# Reinforce: "%s %.1f %% ~ %.1f %% (+%d%%)", tenths of a percent.
	# 0x66c5b0 picks the form by the WEAPON pair: non-zero -> the range form
	# from columns 105-112; zero -> the single form from the armour/shield
	# pair, columns 82/83 (84/85 magic), stored / 1000 and shown x 100, i.e.
	# the column / 10, rated on its own [L, U] (round 731's review, READ).
	for spec in [["ps", "PARAM_PHYSICAL_SPECIALIZE", "Phy. reinforce", item.phys_reinforce, item.phys_reinforce_upper, item.armour_phys_reinforce],
			["ms", "PARAM_MAGICAL_SPECIALIZE", "Mag. reinforce", item.mag_reinforce, item.mag_reinforce_upper, item.armour_mag_reinforce]]:
		var r: Vector2i = spec[3]
		var ru: Vector2i = spec[4]
		var a: Vector2 = spec[5]
		var label: String = t.call(spec[1], spec[2])
		if r != Vector2i.ZERO:
			var vals: Array = given.get(spec[0], [r.x, r.y])
			var body := "%s %.1f %% ~ %.1f %%" % [label, float(vals[0]) / 10.0, float(vals[1]) / 10.0]
			_stat(lines, body, int(given.get(spec[0] + "_q", range_quality(r.x, ru.x, r.y, ru.y))), unknown)
		elif a != Vector2.ZERO:
			var v: float = float(given.get(spec[0], a.x))
			_stat(lines, "%s %.1f %%" % [label, v / 10.0], int(given.get(spec[0] + "_q", quality(a.x, a.x, a.y))), unknown)

static func _stat(lines: Array, body: String, q: int, unknown: bool) -> void:
	_add(lines, body if unknown else "%s (+%d%%)" % [body, q], WHITE)

## The mastery requirement types (ReqLevelType 0x101..0x114, 0x201..0x206)
## and their name keys, READ from 0x67eec0's branches; the type is the
## mastery's own id (257 = 0x101 ... 518 = 0x206).
const MASTERY_KEYS := {
	0x101: "UIIT_STT_MASTERY_VI", 0x102: "UIIT_STT_MASTERY_HEUK", 0x103: "UIIT_STT_MASTERY_PA",
	0x111: "UIIT_STT_MASTERY_HAN", 0x112: "UIIT_STT_MASTERY_PUNG", 0x113: "UIIT_STT_MASTERY_HWA",
	0x114: "UIIT_STT_MASTERY_GI",
	0x201: "UIIT_STT_WARRIOR", 0x202: "UIIT_STT_WIZARD", 0x203: "UIIT_STT_ROG",
	0x204: "UIIT_STT_WARLOCK", 0x205: "UIIT_STT_BARD", 0x206: "UIIT_STT_CLERIC",
}

## The requirement lines (0x67eec0): a blank; the four ReqLevelType /
## ReqLevel pairs (ref +0xd0 / +0xe0) in order -- type 1 "Required level %d",
## a mastery "%s: %s %s %d" (PARAM_MASTERY_LEVEL, the mastery's name,
## PARAM_MASTERY, the level) -- all in ONE colour, white when any of them is
## met and red when none is (cStack_585); then Str, Int, gender and race,
## each its own colour. The job-grade types 2/3/4 are not built (OPEN). The
## binary's Int line prints the Str requirement's value (READ in 0x67eec0:
## `L"%s %d"` with PARAM_INT and ref +0x1c8); reproduced.
static func _requirements(lines: Array, item: ItemTableReader.Item, ctx: Dictionary, t: Callable) -> void:
	var p: Dictionary = ctx.get("player", {})
	_blank(lines)
	var pair_lines := PackedStringArray()
	var any_met := false
	var any_unknown := false
	var masteries: Dictionary = p.get("masteries", {})
	for i in mini(item.req_level_types.size(), item.req_levels.size()):
		var kind: int = item.req_level_types[i]
		var need: int = item.req_levels[i]
		if kind == ItemTableReader.REQ_TYPE_CHARACTER_LEVEL:
			pair_lines.append("%s %d" % [t.call("PARAM_REQ_LV", "Required level"), need])
			var lv: int = int(p.get("level", -1))
			if lv < 0:
				any_unknown = true
			elif lv >= need:
				any_met = true
		elif MASTERY_KEYS.has(kind):
			pair_lines.append("%s: %s %s %d" % [t.call("PARAM_MASTERY_LEVEL", "Mastery level"),
				t.call(MASTERY_KEYS[kind], MASTERY_KEYS[kind]), t.call("PARAM_MASTERY", "Mastery"), need])
			if masteries.is_empty():
				any_unknown = true
			elif int(masteries.get(kind, 0)) >= need:
				any_met = true
	var pair_colour := WHITE if any_met or any_unknown else RED
	for l in pair_lines:
		_add(lines, l, pair_colour)
	if item.req_str != 0:
		var met: bool = int(p.get("str", -1)) < 0 or int(p.get("str", 0)) >= item.req_str
		_add(lines, "%s %d" % [t.call("PARAM_STR", "Str"), item.req_str], WHITE if met else RED)
	if item.req_int != 0:
		var met: bool = int(p.get("int", -1)) < 0 or int(p.get("int", 0)) >= item.req_int
		_add(lines, "%s %d" % [t.call("PARAM_INT", "Int"), item.req_str], WHITE if met else RED)
	if item.req_gender != ItemTableReader.REQ_GENDER_ANY:
		var key := "UIO_NEWCHAR_CTL_FEMALE" if item.req_gender == ItemTableReader.REQ_GENDER_WOMAN else "UIO_NEWCHAR_CTL_MALE"
		var g: int = int(p.get("gender", -1))
		_add(lines, t.call(key, "Female" if item.req_gender == 0 else "Male"), WHITE if g < 0 or g == item.req_gender else RED)
	if item.country != 3:
		var keys := ["UIO_NEWCHAR_CTL_CHINESE", "UIO_NEWCHAR_CTL_EUROPEAN", "UIO_NEWCHAR_CTL_ARABIAN"]
		var fallbacks := ["Chinese", "European", "Arabian"]
		if item.country >= 0 and item.country < 3:
			var c: int = int(p.get("country", -1))
			_add(lines, t.call(keys[item.country], fallbacks[item.country]), WHITE if c < 0 or c == item.country else RED)

static func _price(lines: Array, ctx: Dictionary, t: Callable) -> void:
	var price: int = int(ctx.get("price", -1))
	if price < 0:
		return
	_add(lines, "%s : %d%s" % [t.call("UIIT_STT_PRICE", "Price"), price, t.call("UIIT_STT_GOLD", "Gold")], WHITE)

## Items outside the four equipment builders (consumables, alchemy, quest
## items...): their builders (other branches of 0x6860a0) are not read, so
## these keep the name, the type and the requirement block in the same bubble
## (OURS, labelled in item_tooltip.md).
static func _compose_other(item: ItemTableReader.Item, ctx: Dictionary) -> Array:
	var lines: Array = []
	var t: Callable = ctx.get("text", func(_k, f): return f)
	var name := item.display_name(ctx.get("names", null))
	if name == "":
		name = item.code_name
	_add(lines, name, WHITE, true, true)
	var type_name: String = ctx.get("type_name", "")
	if type_name != "":
		_blank(lines)
		_add(lines, "%s: %s" % [t.call("UIIT_STT_ITEM_TYPE", "Sort of item"), type_name], BEIGE)
	if item.required_character_level() > 0 or item.req_gender != ItemTableReader.REQ_GENDER_ANY:
		_requirements(lines, item, ctx, t)
	if int(ctx.get("price", -1)) >= 0:
		_blank(lines)
	_price(lines, ctx, t)
	return lines

static func _add(lines: Array, text: String, colour: Color, bold: bool = false, icon: bool = false) -> void:
	lines.append({"text": text, "color": colour, "bold": bold, "icon": icon})

static func _blank(lines: Array) -> void:
	lines.append({"text": "", "color": WHITE, "bold": false, "icon": false})

## Plain text of the lines, one per row (for logs and tests).
static func as_text(lines: Array) -> String:
	var out := PackedStringArray()
	for l in lines:
		out.append(String(l["text"]))
	return "\n".join(out)
