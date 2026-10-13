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
## this parser then let later rows overwrite earlier ones, every stat label
## in the character panel rendered as the digit 0. (It now keeps the FIRST
## row of a key, as the client does -- see parse.)
##
## So the column is chosen by content: column 8 when it holds real Latin
## text, and otherwise the first usable Latin field to its right, then the
## first from column 3 up. That picks the English text in both shapes above
## without depending on the row's width.
##
## It used to scan right to left, preferring the *rightmost* Latin field,
## on the theory that a later column held a more recently authored string.
## Measured against a real archive's three tables (2026-09-11) the two
## rules disagree on 93 of 13,059 object rows, 243 of 12,570 UI rows and 2
## of 8,395 item rows, and in every one of those the rightmost Latin field
## was a *Vietnamese* column (Latin letters in Windows-1258 mojibake) --
## "Hép b¸u vËt" where column 9 said "Jewel Box". On a multi-language
## archive it is worse: the rightmost Latin field is Spanish
## ("Administrador de Arena") or an Arabic column carrying a Latin name, and
## every NPC in Jangan was labelled that way. Column-8-first gives the same
## 19 Jangan NPC names on the single-language archive and English on the
## other.

## Column 0 is the row's service flag: the client loads a row only when it
## reads as 1 (TextStringManager 0x8cac30: `0xb9cc80(0, 1)`, then `cmp eax,1;
## jne` at 0x8cb110..0x8cb118). The continuation lines of a value that spans
## lines fail it too, so they never become keys.
const COL_SERVICE := 0
const COL_TOKEN := 1
## The conventional position of the English column, and the first one tried.
const COL_ENGLISH := 8
## Fields at or before this index are the token, its id and the Korean
## original; the search never reaches into them.
const FIRST_LANGUAGE_COL := 3

var _strings: Dictionary = {}

static func parse(data: PackedByteArray, lang_col: int = COL_ENGLISH, keep_first: bool = true) -> UiTextTable:
	var _pp := ParseProfile.t0()
	var _out: UiTextTable = _pp_parse(data, lang_col, keep_first)
	ParseProfile.add("text.ui_table", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray, lang_col: int = COL_ENGLISH, keep_first: bool = true) -> UiTextTable:
	var table := UiTextTable.new()
	if data.is_empty():
		return table
	# The native port of the row loop below (round 671; native/src/core/
	# tables.rs `ui_text_rows`): every accepted row's token and value in file
	# order, with the keep-first rule applied here as below.
	var rows := NativeAssets.table_rows("ui_text_rows", [data, lang_col])
	if not rows.is_empty():
		table._strings = select_rows(rows["keys"], rows["values"], keep_first)
		return table

	# Strip UTF-16LE BOM if present (0xFF, 0xFE)
	var _pp := ParseProfile.t0()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)

	var full_text: String
	if raw.size() >= 2:
		full_text = TextDecode.utf16(raw)
	if full_text.is_empty() and raw.size() > 0:
		# Fallback in case utf-8 was passed
		full_text = raw.get_string_from_utf8()

	var lines := full_text.split("\n")
	ParseProfile.add("text.decode_split", _pp, data.size())
	var tokens := PackedStringArray()
	var values := PackedStringArray()
	for line in lines:
		var clean_line := line.strip_edges()
		if clean_line.is_empty() or clean_line.begins_with("//") or clean_line.begins_with("#"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_TOKEN:
			continue
		if cols[COL_SERVICE].strip_edges().to_int() != 1:
			continue
		var token := cols[COL_TOKEN].strip_edges()
		if token.is_empty():
			continue

		var val := _pick_language_column(cols, lang_col)
		if val == "":
			# No Latin text in any language column: the client shows its
			# language column's own content, raw -- 0x8c6a90 copies the field
			# whatever it holds, the "0" filler included (its compare with
			# L"0", DAT_00e1804c, only chooses between two columns, and the
			# CGame loads pass -1 for the first). So the English column's
			# field is the value, as the client would draw it: "0", blank,
			# or a mangled string -- never the Korean column 2 nor the token,
			# which retail never shows (rounds 633-635 integration review:
			# SN_ITEM_ETC_E060823_SATGAT_INT3_M's first row is all "0", and
			# the client names the hat "0").
			val = cols[lang_col].strip_edges() if lang_col < cols.size() else ""

		tokens.append(token)
		values.append(val)

	table._strings = select_rows(tokens, values, keep_first)
	return table

## Which row of a key is kept, from every accepted row in file order (both
## the native reader and the loop above hand their rows here).
##
## **The client keeps the FIRST row (READ, round 634's review, confirmed by
## round 725's):** its loader TextStringManager 0x8cac30 -- which reads
## textdataname.txt's list, textuisystem, textzonename, textquest, texthelp
## and textevent -- inserts every row into a stdext::hash_map (0x8ca120, the
## only call at 0x8cb266), which hands back the existing entry for a key it
## already holds and never writes the value. `keep_first` false keeps the old
## last-row rule, for the tool that lists the difference (docs/protocol/chat.md).
##
## **USER DECISION (2026-10-05), a departure from that rule: the stock
## English wins in a joined table.** The archive's textuisystem.txt is two
## whole tables, one after the other: a private server's reworded English
## (lines 1-6955, 16 columns) and then the stock English (6956-13915, 19
## columns); 5,167 keys are in both and 433 read differently. With keep-first
## the binary shows the reworded block; the user's own screenshots of the
## original show the stock wording ("Phy. atk", "Teleport to [%s]area.",
## "Party informaiton"), and the user chose it. So when the table is joined,
## a key's first row in the LATER table replaces the earlier one.
## - **Joined, by structure, not by a line number** (joined_table_start):
##   the file's opening keys appear again, in the same order, for at least
##   JOINED_MIN_RUN rows, and at least JOINED_MIN_SHARE of the keys before
##   that point appear again after it -- a whole table restarting. (The
##   archive's second table repeats the first's opening 89 keys in order.) A
##   vanilla archive with one table never restarts, and keeps every first row
##   exactly as before; so does a file with a stray repeated key. Of the
##   archive's text tables only textuisystem.txt is joined (round 725 census,
##   docs/rounds/r725.md): textdata_equip&skill.txt's first key recurs after a
##   4-row preamble, which neither rule accepts.
## - **OURS:** a later row with no English (no usable Latin field -- 109 of
##   the 433, Korean-only rows such as UIO_MSG_AUTOLOGIN) does not replace an
##   English one; the earlier row stays.
static func select_rows(tokens: PackedStringArray, values: PackedStringArray, keep_first: bool) -> Dictionary:
	var out: Dictionary = {}
	for i in tokens.size():
		if keep_first and out.has(tokens[i]):
			continue
		out[tokens[i]] = values[i]
	if not keep_first:
		return out
	var restart := joined_table_start(tokens)
	if restart < 0:
		return out
	var seen_later: Dictionary = {}
	for i in range(restart, tokens.size()):
		var token := tokens[i]
		if seen_later.has(token):
			continue
		seen_later[token] = true
		if keeps_first_row(token):
			continue
		if _is_usable(values[i]) and _has_latin_letter(values[i]):
			out[token] = values[i]
	return out

## **The mastery keys keep the client's own first row, even in a joined
## table (round 786, the user's report "sorcery -> cold force").** The
## skill window titles each mastery tab with the text of the mastery
## record's name code, through the same TextStringManager every key goes
## through (READ: CIFSkillMastery SetMasteryData 0x69f860 calls
## 0x8c9bb0(record + 4), the hash lookup 0x8c9b20, then the title's SetText,
## vslot 0xb4), and that manager keeps the FIRST row of a key (READ, 0x8ca120
## above). The box's (and the user's) textuisystem.txt has two rows per
## mastery key (MEASURED, 2026-10-13): the first table's and the stock
## table's agree on six of the seven China masteries, and differ on one --
## UIIT_STT_MASTERY_HAN, 273, is "Cold" in the first and "Sorcery" in the
## stock table, whose UIIT_STT_MASTERY_HAN_EXPLANATION reads "uses the
## energy of ice, lightning & fire" and which adds UIIT_CTL_SORCERY_SKILL:
## a server whose three elemental masteries were merged into one. This game
## keeps all three (skillmasterydata 273-275, RACE_MASTERIES), so the stock
## rows describe a mastery it does not have. The user decision of round 725
## (the stock English) stays for every other key; the mastery's own text
## (its name, its explanation) follows the client's READ rule. Round 725's
## joined-table rule is what turned 273 from "Cold" to "Sorcery" in the skill
## window, the mastery requirement lines and the practice box.
const FIRST_ROW_PREFIX := "UIIT_STT_MASTERY_"

## Whether a key keeps its first row in a joined table (FIRST_ROW_PREFIX).
static func keeps_first_row(token: String) -> bool:
	return token.begins_with(FIRST_ROW_PREFIX)

## Of the keys before a restart, at least this share must come back after it
## for the file to count as two joined tables (OURS thresholds, round 725:
## the archive's textuisystem.txt has 5,167 of 5,960 and an 89-key run;
## textdata_equip&skill.txt's preamble 1 of 4 and a 1-key run).
const JOINED_MIN_SHARE := 0.5
## How many of the file's opening keys must restart in order.
const JOINED_MIN_RUN := 8

## The row index where a second whole table starts, or -1: the first later
## row carrying the file's first key, when the next JOINED_MIN_RUN keys from
## there repeat the file's opening keys in order and at least
## JOINED_MIN_SHARE of the keys before it appear again after it.
static func joined_table_start(tokens: PackedStringArray) -> int:
	if tokens.size() < 2:
		return -1
	var restart := -1
	for i in range(1, tokens.size()):
		if tokens[i] == tokens[0]:
			restart = i
			break
	if restart < JOINED_MIN_RUN or restart + JOINED_MIN_RUN > tokens.size():
		return -1
	for j in JOINED_MIN_RUN:
		if tokens[restart + j] != tokens[j]:
			return -1
	var before: Dictionary = {}
	for i in restart:
		before[tokens[i]] = true
	var again: Dictionary = {}
	for i in range(restart, tokens.size()):
		if before.has(tokens[i]):
			again[tokens[i]] = true
	return restart if float(again.size()) >= JOINED_MIN_SHARE * float(before.size()) else -1

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
## index: the preferred column when it holds usable Latin text, otherwise
## the first usable Latin field after it, otherwise the first from
## FIRST_LANGUAGE_COL up. Left to right, because the other Latin-script
## languages an archive may carry (Vietnamese, Spanish, Turkish, German)
## sit to the *right* of the English column in every real file checked.
static func _pick_language_column(cols: PackedStringArray, preferred: int) -> String:
	if preferred < cols.size() and _is_usable(cols[preferred]) and _has_latin_letter(cols[preferred]):
		return cols[preferred].strip_edges()
	var after := _scan_left_to_right(cols, preferred + 1)
	if after != "":
		return after
	return _scan_left_to_right(cols, FIRST_LANGUAGE_COL)

static func _scan_left_to_right(cols: PackedStringArray, lowest: int) -> String:
	for i in range(lowest, cols.size()):
		if _is_usable(cols[i]) and _has_latin_letter(cols[i]):
			return cols[i].strip_edges()
	return ""

## Returns the translated text for token. If not found, returns default_val
## (or token itself if default_val is empty).
func get_text(token: String, default_val: String = "") -> String:
	if _strings.has(token):
		return _strings[token]
	if default_val != "":
		return default_val
	return token

## Adds `other`'s rows whose tokens this table lacks (round 731: the item
## names span two files, ItemTableReader.load_object_names).
func merge_missing(other: UiTextTable) -> void:
	if other == null:
		return
	for k in other._strings:
		if not _strings.has(k):
			_strings[k] = other._strings[k]

func has(token: String) -> bool:
	return _strings.has(token)

func count() -> int:
	return _strings.size()
