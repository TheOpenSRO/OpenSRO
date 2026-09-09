extends RefCounted
class_name UiTextTable

## Parser and lookup table for Silkroad Online's UI string catalog
## (server_dep\silkroad\textdata\textuisystem.txt inside Media.pk2).
##
## textuisystem.txt is a UTF-16LE tab-separated file mapping UI string tokens
## (e.g. "UIIT_STT_GOLD", "UIIS_CTL_EXIT") to localized strings across
## multiple language columns. Column 1 is the token name.
##
## **The English column is not at a fixed index.** This parser used to take
## column 8 always, and that is wrong often enough to break the interface:
## real rows for the same token differ in width and in which column carries
## the English, and column 8 frequently holds the literal string "0".
##
##   16 cols  UIIT_STT_PHYSICAL_ATTACK  [8]="Phy. Atk:"  [9]="Phy. Atk:"
##   19 cols  UIIT_STT_PHYSICAL_ATTACK  [8]="0"          [9]="Phy. atk"
##
## Reading index 8 unconditionally returned "0" for the second, and since
## later rows overwrite earlier ones, every stat label in the character
## panel rendered as the digit 0.
##
## So the column is chosen by content instead: scan right to left and take
## the first field that is not empty, is not the "0" filler, and contains a
## Latin letter. That picks the English text in both shapes above without
## depending on the row's width.

const COL_TOKEN := 1
## Kept as the starting point for the search, and as the documented
## conventional position.
const COL_ENGLISH := 8
## Fields at or before this index are the token, its id and the Korean
## original; the search never reaches into them.
const FIRST_LANGUAGE_COL := 3

var _strings: Dictionary = {}

static func parse(data: PackedByteArray, lang_col: int = COL_ENGLISH) -> UiTextTable:
	var table := UiTextTable.new()
	if data.is_empty():
		return table

	# Strip UTF-16LE BOM if present (0xFF, 0xFE)
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)

	var full_text: String
	if raw.size() >= 2:
		full_text = raw.get_string_from_utf16()
	if full_text.is_empty() and raw.size() > 0:
		# Fallback in case utf-8 was passed
		full_text = raw.get_string_from_utf8()

	var lines := full_text.split("\n")
	for line in lines:
		var clean_line := line.strip_edges()
		if clean_line.is_empty() or clean_line.begins_with("//") or clean_line.begins_with("#"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_TOKEN:
			continue
		var token := cols[COL_TOKEN].strip_edges()
		if token.is_empty():
			continue

		var val := _pick_language_column(cols, lang_col)
		if val == "":
			# Nothing usable in any language column: fall back to the Korean
			# original, then to the token itself, so a label shows *something*
			# recognisable rather than an empty box.
			if cols.size() > 2 and _is_usable(cols[2]):
				val = cols[2].strip_edges()
			else:
				val = token

		table._strings[token] = val

	return table

## True if a field carries real text rather than the "0" filler this file
## uses for "no string in this language".
static func _is_usable(field: String) -> bool:
	var trimmed := field.strip_edges()
	return trimmed != "" and trimmed != "0"

## True if a field contains at least one Latin letter -- how the English
## column is told apart from numeric ids and from the Korean original.
static func _has_latin_letter(field: String) -> bool:
	for c in field:
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z"):
			return true
	return false

## The English text in a row, chosen by content rather than by a fixed
## index. Searches right to left from the end of the row down to
## FIRST_LANGUAGE_COL, preferring the rightmost usable Latin field --
## which is the English column in every real row shape checked.
static func _pick_language_column(cols: PackedStringArray, preferred: int) -> String:
	if preferred < cols.size() and _is_usable(cols[preferred]) and _has_latin_letter(cols[preferred]):
		var direct := cols[preferred].strip_edges()
		# The preferred column is right whenever it holds real text, but a
		# later column may hold a better (more recently authored) string, so
		# keep looking and prefer the rightmost.
		var better := _scan_right_to_left(cols, preferred + 1)
		return better if better != "" else direct
	return _scan_right_to_left(cols, FIRST_LANGUAGE_COL)

static func _scan_right_to_left(cols: PackedStringArray, lowest: int) -> String:
	var i := cols.size() - 1
	while i >= lowest:
		if _is_usable(cols[i]) and _has_latin_letter(cols[i]):
			return cols[i].strip_edges()
		i -= 1
	return ""

## Returns the translated text for token. If not found, returns default_val
## (or token itself if default_val is empty).
func get_text(token: String, default_val: String = "") -> String:
	if _strings.has(token):
		return _strings[token]
	if default_val != "":
		return default_val
	return token

func has(token: String) -> bool:
	return _strings.has(token)

func count() -> int:
	return _strings.size()
