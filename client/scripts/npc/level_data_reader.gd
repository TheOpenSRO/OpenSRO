extends RefCounted
class_name LevelDataReader

## Reads `server_dep\silkroad\textdata\leveldata.txt` from the player's own
## Media.pk2 for one thing: what raising a mastery costs in skill points, so
## the skill window's LEVEL UP button can say so before the click.
##
## The table is UTF-16LE and tab separated, one row per character level, and
## ends with a `//` copyright line; the level is column 0 (the same layout the
## server's `cmd/export-leveldata` reads, colLevel = 0).
##
## Column 2 is the mastery cost. Grounding, docs/LEVELING.md "The level
## record's layout, from four independent use sites (round 295)": the server's
## Mastery_LevelUp (0x0059c4e0) reads the level record's +0x10, which is
## column 2, for the mastery's CURRENT level --
##   59c667  mov eax,esi            ; esi = the mastery's current level
##   59c669  call 0x411130          ; RefLevel_GetEntry = rows[level - 1]
##   59c66e  mov ecx,[eax+0x10]     ; leveldata column 2
## -- and refuses with 0x3802 only when that cost is above the character's
## skill points (`cmp eax,[ecx+0x80] ; jbe` at 0x59c694: equal is allowed).
## The server serves the same column as leveldata.Table.MasteryUpCost.
## Nothing from the archive is copied here: the tests use synthetic rows.

const TABLE_PATH := "server_dep\\silkroad\\textdata\\leveldata.txt"

const COL_LEVEL := 0
## Grounded above: the record's +0x10 (docs/LEVELING.md, round 295).
const COL_MASTERY_SP := 2

## The last mastery level whose raise costs skill points: 0x78 = 120. It is NOT
## a refusal. Mastery_LevelUp's cost loop tests `cmp esi,0x78 ; jg 0x59c687`
## (0x59c64e) and jumps to the skill-point check, so a raise from above 120
## sums nothing and costs 0 (docs/RE_COMPLETION.md, round 484; the server's
## session.MasteryCostLevelCeiling).
const MASTERY_COST_LAST_LEVEL := 0x78

## Column 2 by level: {level: skill points to raise a mastery FROM that level}.
## Comment lines, a header and any row whose level or column 2 is not an
## integer give no entry.
static func parse_mastery_costs(data: PackedByteArray) -> Dictionary:
	var costs := {}
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_MASTERY_SP:
			continue
		var level_text := cols[COL_LEVEL].strip_edges()
		var cost_text := cols[COL_MASTERY_SP].strip_edges()
		if not level_text.is_valid_int() or not cost_text.is_valid_int():
			continue
		costs[int(level_text)] = int(cost_text)
	return costs

## The skill points raising a mastery from `level` to level + 1 costs, as the
## engine charges it; 0 when it charges nothing or the table does not say.
##   - level < 1: the first point is free. `test cl,cl` at 0x59c628 sends a
##     level-0 mastery to the level setter FUN_005a8bf0 and on to 0x59c6d8,
##     past the cost loop and the 0x3802 check (0x59c628-0x59c633).
##   - level > MASTERY_COST_LAST_LEVEL: the loop breaks before summing.
##   - no row, or a value <= 0: nothing known to charge. There is deliberately
##     no fallback: the server's disclosed `currentLevel + 1` is its own
##     no-table stand-in, not the game's cost, and is not shown here.
static func mastery_up_cost(costs: Dictionary, level: int) -> int:
	if level < 1 or level > MASTERY_COST_LAST_LEVEL:
		return 0
	var cost := int(costs.get(level, 0))
	return cost if cost > 0 else 0

## Same decoding as MasteryReader._lines: UTF-16LE with or without its BOM,
## UTF-8 as a fallback, one entry per line.
static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text.replace("\r", "").split("\n")
