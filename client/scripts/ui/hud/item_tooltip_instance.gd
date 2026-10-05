extends RefCounted
class_name ItemTooltipInstance

## An owned item's own data, from round 732's lane B, turned into the
## "instance" fields ItemTooltipLines.compose takes: the plus, the white
## stats and their "(+x%)", the blue lines and the advanced elixir.
##
## Lane B's classes -- ItemInstance (the record), ItemQuality (the stat and
## percent maths, READ from c:0x8bd980 / c:0x66c5b0) and MagicOptionTable
## (the blue lines, READ from c:0x670dd0) -- are reached by path and called
## by name, so this file compiles on a branch without them and does nothing
## there (fields() returns {}); on the merged tree it is the tooltip's data.
## The formulas are theirs; only the plumbing is here.

const QUALITY_PATH := "res://scripts/items/item_quality.gd"
const MAGIC_PATH := "res://scripts/items/magic_option_table.gd"

static var _quality = null
static var _magic = null
static var _looked := false

static func _scripts() -> bool:
	if not _looked:
		_looked = true
		if ResourceLoader.exists(QUALITY_PATH):
			_quality = load(QUALITY_PATH)
		if ResourceLoader.exists(MAGIC_PATH):
			_magic = load(MAGIC_PATH)
	return _quality != null

## Whether lane B's maths is in this tree.
static func available() -> bool:
	return _scripts()

## The ItemQuality kind of an item: "weapon", "armour", "shield",
## "accessory", or "" (TypeID3, docs/protocol/item_tooltip.md §2).
static func kind_of(item: ItemTableReader.Item) -> String:
	var fam := item.family()
	if fam == ItemTooltipLines.WEAPON_FAMILY:
		return "weapon"
	if fam == ItemTooltipLines.SHIELD_FAMILY:
		return "shield"
	if ItemTooltipLines.ACCESSORY_FAMILIES.has(fam):
		return "accessory"
	if ItemTooltipLines.ARMOUR_FAMILIES.has(fam):
		return "armour"
	return ""

## The compose() "instance" fields for `item` and its ItemInstance `inst`
## (duck-typed); {} without lane B's classes or an instance.
static func fields(item: ItemTableReader.Item, inst: Object) -> Dictionary:
	if item == null or inst == null or not _scripts():
		return {}
	var Q = _quality
	var plus: int = int(inst.call("effective_plus"))
	var out := {"plus": plus, "adv_elixir": int(inst.get("adv_elixir"))}
	var kind := kind_of(item)
	var q := func(stat: String) -> int:
		var k: int = Q.group_for(kind, stat)
		return int(inst.call("variance_group", k)) if k >= 0 else 0
	var inc := func(i: int) -> float:
		return float(item.plus_incs[i]) if i < item.plus_incs.size() else 0.0
	var s := {}
	# Phy./Mag. attack: each end built and the line rated on both ends.
	if item.phys_atk != Vector2i.ZERO:
		var lo: int = Q.int_stat(item.phys_atk.x, item.phys_atk_upper.x, q.call("phys_attack"), inc.call(ItemTableReader.PLUS_INC_PA), plus)
		var hi: int = Q.int_stat(item.phys_atk.y, item.phys_atk_upper.y, q.call("phys_attack"), inc.call(ItemTableReader.PLUS_INC_PA), plus)
		s["pa"] = [lo, hi]
		s["pa_q"] = Q.range_int_pct(lo, hi, item.phys_atk.x, item.phys_atk_upper.x, item.phys_atk.y, item.phys_atk_upper.y,
			inc.call(ItemTableReader.PLUS_INC_PA), plus)
	if item.mag_atk != Vector2i.ZERO:
		var lo: int = Q.int_stat(item.mag_atk.x, item.mag_atk_upper.x, q.call("mag_attack"), inc.call(ItemTableReader.PLUS_INC_MA), plus)
		var hi: int = Q.int_stat(item.mag_atk.y, item.mag_atk_upper.y, q.call("mag_attack"), inc.call(ItemTableReader.PLUS_INC_MA), plus)
		s["ma"] = [lo, hi]
		s["ma_q"] = Q.range_int_pct(lo, hi, item.mag_atk.x, item.mag_atk_upper.x, item.mag_atk.y, item.mag_atk_upper.y,
			inc.call(ItemTableReader.PLUS_INC_MA), plus)
	# Defences and absorptions: fractional, the plus taken off the percent.
	for spec in [["pd", "phys_defence", item.phys_def, ItemTableReader.PLUS_INC_PD],
			["md", "mag_defence", item.mag_def, ItemTableReader.PLUS_INC_MD],
			["pr", "phys_absorption", item.phys_absorb, ItemTableReader.PLUS_INC_PAR],
			["mr", "mag_absorption", item.mag_absorb, ItemTableReader.PLUS_INC_MAR]]:
		var r: Vector2 = spec[2]
		if r == Vector2.ZERO:
			continue
		var v: float = Q.float_stat(r.x, r.y, q.call(spec[1]), inc.call(spec[3]), plus)
		s[spec[0]] = v
		s[spec[0] + "_q"] = Q.single_pct(v, r.x, r.y, inc.call(spec[3]), plus)
	# Hit, parry, critical, block: whole numbers; the percent takes no plus.
	if item.attack_rate != 0:
		var v: int = Q.int_stat(item.attack_rate, item.attack_rate_upper, q.call("attack_rate"), inc.call(ItemTableReader.PLUS_INC_HR), plus)
		s["hr"] = v
		s["hr_q"] = Q.single_pct(v, item.attack_rate, item.attack_rate_upper, 0.0, 0)
	if item.parry != Vector2.ZERO:
		var v: int = Q.int_stat(int(item.parry.x), int(item.parry.y), q.call("parry"), inc.call(ItemTableReader.PLUS_INC_ER), plus)
		s["er"] = v
		s["er_q"] = Q.single_pct(v, item.parry.x, item.parry.y, 0.0, 0)
	if item.critical != 0:
		var v: int = Q.int_stat(item.critical, item.critical_upper, q.call("critical"), 0.0, 0)
		s["cr"] = v
		s["cr_q"] = Q.single_pct(v, item.critical, item.critical_upper, 0.0, 0)
	if item.block != Vector2.ZERO:
		var v: int = Q.int_stat(int(item.block.x), int(item.block.y), q.call("block"), 0.0, 0)
		s["br"] = v
		s["br_q"] = Q.single_pct(v, item.block.x, item.block.y, 0.0, 0)
	# Reinforce: fractional, no plus term.
	for spec in [["ps", "phys_reinforce", item.phys_reinforce, item.phys_reinforce_upper],
			["ms", "mag_reinforce", item.mag_reinforce, item.mag_reinforce_upper]]:
		var r: Vector2i = spec[2]
		var ru: Vector2i = spec[3]
		if r == Vector2i.ZERO:
			continue
		var lo: float = Q.float_stat(r.x, ru.x, q.call(spec[1]), 0.0, 0)
		var hi: float = Q.float_stat(r.y, ru.y, q.call(spec[1]), 0.0, 0)
		s[spec[0]] = [lo, hi]
		s[spec[0] + "_q"] = Q.range_float_pct(lo, hi, r.x, ru.x, r.y, ru.y)
	# Durability: the max built with no plus term, the percent q / 0.31.
	if item.durability > 0 and Q.group_for(kind, "durability") >= 0:
		var dq: int = q.call("durability")
		s["dur_max"] = Q.int_stat(item.durability, maxi(item.durability_max, item.durability), dq, 0.0, 0)
		s["dur_q"] = Q.durability_pct(dq)
		out["durability_cur"] = int(inst.get("durability"))
	out["stats"] = s
	out["magic_options"] = blue_lines(inst)
	return out

## The blue lines (MagicOptionTable.format_line); an option whose format is
## not read yet (MagicOptionTable's OPEN codes) shows its code and value --
## a stand-in, OURS, so the option is not silently lost.
static func blue_lines(inst: Object) -> Array:
	var lines: Array = []
	if _magic == null:
		return lines
	var table = _magic.get("shared")
	var text = _magic.get("shared_text")
	var n: int = int(inst.call("option_count"))
	for i in n:
		var id: int = int(inst.call("option_id", i))
		var value: int = int(inst.call("option_value", i))
		var row = table.row(id) if table != null else null
		if row == null:
			lines.append("%d %d" % [id, value])
			continue
		var pct: int = _magic.blue_pct(row, value)
		var line: String = _magic.format_line(String(row.code), value, pct, text if text is Callable else Callable())
		lines.append(line if line != "" else "%s %d" % [row.code, value])
	return lines
