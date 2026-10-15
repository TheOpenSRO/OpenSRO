extends RefCounted
class_name NameFilter

## The client's name filter (round 788, lane N): CStringCheck's name and
## guild-name tests, READ out of sro_client.exe, on the player's own Media.pk2
## `server_dep\silkroad\textdata\abusefilter.txt` (never shipped). The server's
## twin, on narrow bytes, is server/internal/namefilter. Labels: READ,
## MEASURED, INFERRED, OURS, OPEN.
##
## **The group** (READ CGame::FUN_008469c0, 0x847b84..0x847e83): Media.pk2's
## root `type.txt`, key `Language` (matched by CompareStringA with
## NORM_IGNORECASE), its quoted value compared byte for byte with Korean 0,
## Chinese 1, Taiwan 2, Japan 3, English 4, Vietnam 5, Turkey 7, Thailand 8,
## Russia 9, Spain 10, Arabic 11 -> CGame+0x858 -> the filter's +0x14 (ctor
## 0x8c46a0). The loader 0x8c4a10 skips 6 cells a group for 0..5 and 48, 36,
## 42, 54, 60 cells for 7..11 (groups 8, 6, 7, 9, 10); any other value skips
## none (group 0). The file has 6 groups (MEASURED: 36 cells a line), so 7..11
## find no cell on any line: nothing is allowed, every name with a character
## in it is refused (INFERRED from the READ loader on the MEASURED file). A
## value matching none of the names leaves CGame+0x858 at its constructor's
## value, which was not found (OPEN); here it is English (OURS). The deployed
## exe jumps over the Vietnam compare (0x847d2d patched 75 -> eb) and its
## vPlus DLL sets +0x858 at runtime (OPEN); this follows the unpatched exe.
##
## **The loader** (READ 0x8c4a10 and its tokenizer 0xb9d2e0 / 0xb9d580 /
## 0xb9cc80): the first UTF-16 unit is skipped whatever it is (the BOM), lines
## end at CR LF only, from a line's first '/' a "//" cuts the rest and a "/*"
## cuts it and skips lines to the first "*/", empty lines are skipped; the
## group's first cell (up to TAB, CR or NUL, not trimmed) is lower-cased (A-Z
## only, 0x8c1660). "#allow_id_table" marks the codes from..to (the next two
## numbers) as allowed; any other non-empty cell is a word with four flag
## numbers: per flag 1 a whole-word set, 2 a substring list. f1 is the name
## test's (+0x2048 set, +0x2018 list), f3 the guild name's (+0x2098, +0x2030;
## f2 is chat's, f4 the stall's). A number skips whitespace (space,
## 0x01..0x10: tabs and empty cells too), needs a digit next or reads 0
## without moving, and is hex with an x second. Then the table is inverted:
## a set bit refuses.
##
## **A code to a character** (READ 0x8c5217..): each allowed code becomes the
## bytes [code, 0] below 0x100 and [hi, lo] otherwise, through
## MultiByteToWideChar(CP_ACP) into ONE wide character. OURS: Godot has no
## system code page, so the code page is Windows-1252 -- the first byte
## decoded (that a too-small buffer still receives the first character is
## INFERRED: it is how an English Windows lets the English group's letters
## through at all). The English group's codes are all below 0x80, so it is
## exact there; for the DBCS groups (0..3) a Western Windows sets the bit of
## the lead byte's Windows-1252 character, and so does this.
##
## **The name test** 0x8c3cb0 (READ): the name lower-cased (A-Z only), every
## UTF-16 unit against the table, then no substring word found in it
## (0x8c3200, std::wstring::find, case-sensitive on the lower-cased name),
## then the name split on spaces (0x8c3060) with no token a whole word
## (0x8c3ae0). The guild-name test 0x8c3de0 is the same on the f3 lists.

const ABUSEFILTER_PATH := "server_dep\\silkroad\\textdata\\abusefilter.txt"
const TYPE_TXT_PATH := "type.txt"

## READ: the Language names and the values they store (0x847c11..0x847e83).
const LANGUAGES := {
	"Korean": 0, "Chinese": 1, "Taiwan": 2, "Japan": 3, "English": 4, "Vietnam": 5,
	"Turkey": 7, "Thailand": 8, "Russia": 9, "Spain": 10, "Arabic": 11,
}
const LANGUAGE_ENGLISH := 4

## READ 0x8c4c40: the cells the loader skips for each language value.
const SKIP_CELLS := {0: 0, 1: 6, 2: 12, 3: 18, 4: 24, 5: 30, 7: 48, 8: 36, 9: 42, 10: 54, 11: 60}

## Windows-1252's 0x80..0x9F row (the undefined five map to themselves, as
## Windows' table does). OURS: the stand-in for CP_ACP.
const CP1252_HIGH := [
	0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
	0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
]

## The flag columns (0-based: f1 = 0, f3 = 2).
const FLAG_NAME := 0
const FLAG_GUILD := 2

var language := LANGUAGE_ENGLISH
## True when a file was read; false is the no-file filter (see no_file()).
var from_file := false
## The 65,536-bit table, a set bit refused (after the inversion).
var refused := PackedByteArray()
## Per flag column: Array of PackedInt32Array words (substring lists) and a
## Dictionary key -> true (whole-word sets).
var substr: Array = [[], [], [], []]
var whole: Array = [{}, {}, {}, {}]
var allow_rows := 0

static var _shared: NameFilter = null
static var _fallback: NameFilter = null

## A cached no_file() filter, for callers given none.
static func fallback() -> NameFilter:
	if _fallback == null:
		_fallback = no_file()
	return _fallback

## The process's filter, loaded once from media (the no-file filter when media
## holds no abusefilter.txt). media null gives the no-file filter without
## caching it, so a later call with the archive still loads it.
static func shared(media: Pk2Reader) -> NameFilter:
	if _shared != null:
		return _shared
	if media == null:
		return fallback()
	_shared = from_media(media)
	return _shared

## READ (0x6f91b0, the guild-create prompt): the name's narrow byte count
## 2..12, else the code 0x4c18; then 0x8c3de0, else 0x4c19. The text key for
## each code is INFERRED from the codes' GUILDERR_* names (the prompt shows a
## code through 0x778190, whose table was not read). The byte count here is
## the UTF-8 the client sends (OURS: retail counts its ANSI bytes; the two
## agree on every name the English group allows). "" when the name passes.
const GUILD_MSG_LENGTH := "UIIT_MSG_GUILDERR_INVALID_GUILDNAME_LEN"
const GUILD_MSG_NOT_ALLOWED := "UIIT_MSG_GUILDERR_NOT_ALLOWED_GUILDNAME"

static func guild_name_error(name: String, filter: NameFilter = null) -> String:
	var n := name.to_utf8_buffer().size()
	if n < 2 or n > 12:
		return GUILD_MSG_LENGTH
	if filter == null:
		filter = fallback()
	if not filter.guild_name_ok(name):
		return GUILD_MSG_NOT_ALLOWED
	return ""

## Builds the filter from Media.pk2: the group from type.txt, the table and
## words from abusefilter.txt.
static func from_media(media: Pk2Reader) -> NameFilter:
	if media == null:
		return no_file()
	var lang := LANGUAGE_ENGLISH
	var te := ObjectLoader.find_file(media, TYPE_TXT_PATH)
	if te != null:
		lang = language_from_type_txt(media.read_file(te))
	var ae := ObjectLoader.find_file(media, ABUSEFILTER_PATH)
	if ae == null:
		var f := no_file()
		f.language = lang
		return f
	return load_bytes(media.read_file(ae), lang)

## The filter without a file. READ: retail's loader on a missing file leaves
## the table zeroed and never inverts it, so it refuses no character; OURS
## (round 788): the server's no-file charset instead, [0-9A-Za-z_], so the
## two sides agree.
static func no_file() -> NameFilter:
	var f := NameFilter.new()
	f.refused.resize(0x2000)
	f.refused.fill(0xff)
	for r in [[0x30, 0x39], [0x41, 0x5a], [0x5f, 0x5f], [0x61, 0x7a]]:
		for c in range(r[0], r[1] + 1):
			f.refused[c >> 3] &= ~(1 << (c & 7))
	return f

## The Language value type.txt names (READ: the key case-insensitively, the
## quoted value exactly); LANGUAGE_ENGLISH when there is none or it matches
## no name (OURS, see the header).
static func language_from_type_txt(data: PackedByteArray) -> int:
	var text := data.get_string_from_ascii()
	for line in text.split("\n"):
		var eq := line.find("=")
		if eq < 0:
			continue
		if line.substr(0, eq).strip_edges().to_lower() != "language":
			continue
		var rest := line.substr(eq + 1)
		var q1 := rest.find("\"")
		var q2 := rest.find("\"", q1 + 1) if q1 >= 0 else -1
		if q1 < 0 or q2 < 0:
			continue
		var value := rest.substr(q1 + 1, q2 - q1 - 1)
		return int(LANGUAGES.get(value, LANGUAGE_ENGLISH))
	return LANGUAGE_ENGLISH

# --- the loader -----------------------------------------------------------------

## The filter for language from an abusefilter.txt's bytes (see the header).
static func load_bytes(data: PackedByteArray, lang: int) -> NameFilter:
	var f := NameFilter.new()
	f.language = lang
	f.from_file = true
	f.refused.resize(0x2000)
	f.refused.fill(0)
	var n := data.size() / 2 - 1
	var units := PackedInt32Array()
	units.resize(maxi(n, 0))
	for i in range(n):
		units[i] = data[2 + 2 * i] | (data[3 + 2 * i] << 8)
	var skip: int = SKIP_CELLS.get(lang, 0)
	var lines := _Lines.new(units)
	while true:
		var line: PackedInt32Array = lines.next()
		if line.is_empty():
			break
		var c := _Cursor.new(line)
		c.skip_cells(skip)
		if c.pos >= line.size():
			continue
		var cell := lower_ascii(c.read_cell())
		if _is_allow_marker(cell):
			var from := c.read_int() & 0xffff
			var to := c.read_int() & 0xffff
			for code in range(from, to + 1):
				var wc := _code_to_wide(code)
				f.refused[wc >> 3] |= 1 << (wc & 7)
			f.allow_rows += 1
			continue
		if cell.is_empty():
			continue
		for col in range(4):
			var flag := c.read_int()
			if flag == 1:
				var set_col: Dictionary = f.whole[col]
				set_col[_key(cell)] = true
			elif flag == 2:
				var list_col: Array = f.substr[col]
				list_col.append(cell)
	for i in range(0x2000):
		f.refused[i] = ~f.refused[i] & 0xff
	return f

const _ALLOW_MARKER := "#allow_id_table"

static func _is_allow_marker(cell: PackedInt32Array) -> bool:
	if cell.size() != _ALLOW_MARKER.length():
		return false
	for i in range(cell.size()):
		if cell[i] != _ALLOW_MARKER.unicode_at(i):
			return false
	return true

## MultiByteToWideChar's first character for the code's bytes (OURS:
## Windows-1252; see the header).
static func _code_to_wide(code: int) -> int:
	var b := code if code < 0x100 else (code >> 8)
	if b >= 0x80 and b < 0xa0:
		return CP1252_HIGH[b - 0x80]
	return b

static func _key(units: PackedInt32Array) -> String:
	var parts := PackedStringArray()
	for u in units:
		parts.append(str(u))
	return ",".join(parts)

## 0x8c1660: A-Z become a-z, every other unit stays.
static func lower_ascii(units: PackedInt32Array) -> PackedInt32Array:
	var out := units.duplicate()
	for i in range(out.size()):
		if out[i] >= 0x41 and out[i] <= 0x5a:
			out[i] += 0x20
	return out

## A Godot string as the client's UTF-16 units (a character above U+FFFF is a
## surrogate pair).
static func utf16_units(s: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in range(s.length()):
		var c := s.unicode_at(i)
		if c > 0xffff:
			c -= 0x10000
			out.append(0xd800 | (c >> 10))
			out.append(0xdc00 | (c & 0x3ff))
		else:
			out.append(c)
	return out

# --- the tests ------------------------------------------------------------------

## 0x8c3cb0: the character name test (f1's lists).
func name_ok(name: String) -> bool:
	return _test(name, FLAG_NAME)

## 0x8c3de0: the guild name test (f3's lists).
func guild_name_ok(name: String) -> bool:
	return _test(name, FLAG_GUILD)

func _test(name: String, col: int) -> bool:
	var low := lower_ascii(utf16_units(name))
	for u in low:
		if refused[u >> 3] & (1 << (u & 7)):
			return false
	for w in substr[col]:
		if _find(low, w) >= 0:
			return false
	var words: Dictionary = whole[col]
	if low.is_empty() or words.is_empty():
		return true
	for tok in _split_spaces(low):
		if words.has(_key(tok)):
			return false
	return true

## std::wstring::find(word) from 0 (0x4ee310); an empty word is found at 0.
static func _find(hay: PackedInt32Array, word: PackedInt32Array) -> int:
	var n := word.size()
	for p in range(hay.size() - n + 1):
		var hit := true
		for k in range(n):
			if hay[p + k] != word[k]:
				hit = false
				break
		if hit:
			return p
	return -1

## 0x8c3060: the run up to the first space, then the rest after the spaces
## that follow, recursively.
static func _split_spaces(units: PackedInt32Array) -> Array:
	var out: Array = []
	var i := 0
	while true:
		var start := i
		while i < units.size() and units[i] != 0x20:
			i += 1
		out.append(units.slice(start, i))
		while i < units.size() and units[i] == 0x20:
			i += 1
		if i >= units.size():
			break
	return out

## The lists' sizes (for the measurement; never the words).
func counts() -> Dictionary:
	return {
		"allow_rows": allow_rows,
		"name_substr": (substr[FLAG_NAME] as Array).size(), "name_whole": (whole[FLAG_NAME] as Dictionary).size(),
		"guild_substr": (substr[FLAG_GUILD] as Array).size(), "guild_whole": (whole[FLAG_GUILD] as Dictionary).size(),
	}

# --- the tokenizer ----------------------------------------------------------------

## Lines (0xb9d250: CR LF or NUL ends one) with the comment rules (0xb9d2e0)
## and empty ones skipped (0xb9d530). next() returns an empty array at the end.
class _Lines:
	var s: PackedInt32Array
	var pos := 0
	var in_comment := false

	func _init(units: PackedInt32Array) -> void:
		s = units

	func _raw() -> Variant:
		if pos >= s.size():
			return null
		var start := pos
		var i := start
		while i < s.size():
			if s[i] == 0:
				pos = i + 1
				return s.slice(start, i)
			if s[i] == 13 and i + 1 < s.size() and s[i + 1] == 10:
				pos = i + 2
				return s.slice(start, i)
			i += 1
		pos = s.size()
		return s.slice(start, s.size())

	func _comment_line() -> Variant:
		while true:
			var raw: Variant = _raw()
			if raw == null:
				return null
			var line: PackedInt32Array = raw
			if not in_comment:
				for i in range(line.size()):
					if line[i] != 0x2f:
						continue
					if i + 1 < line.size():
						if line[i + 1] == 0x2a:
							in_comment = true
							line = line.slice(0, i)
						elif line[i + 1] == 0x2f:
							line = line.slice(0, i)
					break
				return line
			for i in range(line.size()):
				if line[i] != 0x2a:
					continue
				if i + 1 < line.size() and line[i + 1] == 0x2f:
					in_comment = false
					return line.slice(i + 2)
				break
		return null

	func next() -> PackedInt32Array:
		while true:
			var l: Variant = _comment_line()
			if l == null:
				return PackedInt32Array()
			if not (l as PackedInt32Array).is_empty():
				return l
		return PackedInt32Array()

## The position in one line.
class _Cursor:
	var s: PackedInt32Array
	var pos := 0

	func _init(line: PackedInt32Array) -> void:
		s = line

	## 0x8c4c62..: past skip tab separators, stopping at the line's end.
	func skip_cells(skip: int) -> void:
		if skip <= 0:
			return
		var count := 0
		while pos < s.size():
			var ch := s[pos]
			if ch != 0:
				pos += 1
				if ch != 9:
					continue
			if pos >= s.size():
				return
			count += 1
			if count >= skip:
				return

	## 0xb9d580: up to the next NUL, TAB or CR, which stays.
	func read_cell() -> PackedInt32Array:
		var start := pos
		while pos < s.size() and s[pos] != 0 and s[pos] != 9 and s[pos] != 13:
			pos += 1
		return s.slice(start, pos)

	static func _space(ch: int) -> bool:
		return ch == 0x20 or (ch >= 1 and ch <= 0x10)

	func _skip_space() -> void:
		while pos < s.size() and s[pos] != 0 and _space(s[pos]):
			pos += 1

	static func _digit(ch: int) -> bool:
		return ch >= 0x30 and ch <= 0x39

	## 0xb9cc80 with 0xb9cbf0's look-ahead.
	func read_int() -> int:
		var saved := pos
		_skip_space()
		var ch := 0
		var ok := false
		if pos < s.size():
			ch = s[pos]
			pos += 1
			if (ch & 0xff) == 0x2d or (ch & 0xff) == 0x2b:
				ch = s[pos] if pos < s.size() else 0
				ok = _digit(ch)
			else:
				# READ: the unit's low byte is what is tested here.
				ok = _digit(ch & 0xff)
		pos = saved
		if not ok:
			return 0
		_skip_space()
		var start := pos
		var positive := true
		var first := 0
		var count := 0
		var hex := false
		while pos < s.size() and s[pos] != 0:
			var c := s[pos]
			if (c == 0x78 or c == 0x58) and count == 1:
				first = 2
				hex = true
			elif not (_digit(c) or (hex and ((c >= 0x61 and c <= 0x66) or (c >= 0x41 and c <= 0x46)))):
				if count != 0:
					break
				if c == 0x2d:
					positive = false
				elif c != 0x2b:
					break
				first = 1
			pos += 1
			count += 1
		var v := 0
		for i in range(first, count):
			var d := s[start + i]
			if hex:
				if d >= 0x61 and d <= 0x66:
					d -= 0x57
				elif d >= 0x41 and d <= 0x46:
					d -= 0x37
				else:
					d -= 0x30
				v = v * 16 + d
			else:
				v = v * 10 + (d - 0x30)
		# The engine's int is 32 bits.
		v &= 0xffffffff
		if v >= 0x80000000:
			v -= 0x100000000
		return -v if not positive else v
