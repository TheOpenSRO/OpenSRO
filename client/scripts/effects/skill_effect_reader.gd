extends RefCounted
class_name SkillEffectReader

## Reads skilleffect.txt (the client's own `server_dep\silkroad\textdata\`
## table) into a map from a skill's Basic_Code to the hit effect it plays -- so
## each skill can play its OWN recovered .efp rather than one hardcoded set.
## Recovered 2026-09-12 (see the skill-animations note). China focus for now.
##
## The file opens with a `#section characterInfo` block (rows keyed by a
## CHAR_/MOB_ code) and then the skill rows, each a tab-separated line whose
## col 2 is the skill's Basic_Code (no level suffix, e.g. SKILL_CH_SWORD_SMASH_A)
## and whose col 14 is the on-hit effect `hiteffect\*.efp`. Only rows whose col 2
## is a SKILL_ code are kept; a row without a real .efp there is skipped.

const TABLE := "server_dep\\silkroad\\textdata\\skilleffect.txt"

const E_CODE := 2
const E_HIT_EFP := 14

## Parses the table into Basic_Code (upper-cased) -> hit `.efp` path.
static func parse(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	for line in _lines(data):
		if not line.contains("SKILL_"):
			continue
		var cols := line.split("\t")
		if cols.size() <= E_CODE:
			continue
		var code := cols[E_CODE].strip_edges()
		if not code.begins_with("SKILL_"):
			continue
		var efp := ""
		if cols.size() > E_HIT_EFP:
			efp = cols[E_HIT_EFP].strip_edges()
		# Guard the fixed column: if it isn't a .efp, scan the row for one.
		if not efp.to_lower().ends_with(".efp"):
			efp = ""
			for c in cols:
				var cl := c.strip_edges()
				if cl.to_lower().ends_with(".efp"):
					efp = cl
					break
		if efp != "" and efp.to_lower() != "none":
			out[code.to_upper()] = efp
	return out

## The hit `.efp` for a Basic_Code, tolerating the level suffix (the table keys
## without it, e.g. SKILL_CH_SWORD_SMASH_A for ..._SMASH_A_01). "" if unknown.
static func hit_efp_for(effects: Dictionary, basic_code: String) -> String:
	var code := basic_code.to_upper()
	if effects.has(code):
		return effects[code]
	var us := code.rfind("_")
	if us > 0 and code.substr(us + 1).is_valid_int():
		code = code.substr(0, us)
	return effects.get(code, "")

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
