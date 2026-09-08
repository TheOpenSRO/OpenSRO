extends RefCounted
class_name UiTextTable

## Parser and lookup table for Silkroad Online's UI string catalog
## (server_dep\silkroad\textdata\textuisystem.txt inside Media.pk2).
##
## textuisystem.txt is a UTF-16LE tab-separated file mapping UI string tokens
## (e.g. "UIIT_STT_GOLD", "UIIS_CTL_EXIT") to localized strings across
## multiple language columns. Column 1 is the token name, Column 8 is English.

const COL_TOKEN := 1
const COL_ENGLISH := 8

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

		var val := ""
		if cols.size() > lang_col and not cols[lang_col].strip_edges().is_empty():
			val = cols[lang_col].strip_edges()
		elif cols.size() > 2 and not cols[2].strip_edges().is_empty():
			# Fallback to Korean / primary column if target column is empty
			val = cols[2].strip_edges()
		else:
			val = token

		table._strings[token] = val

	return table

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
