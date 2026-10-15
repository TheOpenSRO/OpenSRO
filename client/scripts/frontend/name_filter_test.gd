extends SceneTree

## NameFilter (round 788) on a small abusefilter.txt built here (never the
## real one, which is game data), run headless:
## `godot4 --headless --path client --script res://scripts/frontend/name_filter_test.gd`
##
## What it holds (READ, name_filter.gd's header): type.txt's Language ->
## group; the loader's groups, cells, flags, comments and numbers; the name
## test (f1) and the guild test (f3); the code -> character step (OURS:
## Windows-1252); the create screen's name rule and the guild prompt's.
##
## With OPENSRO_NAMEFILTER_MEDIA=<Media.pk2> (or `-- --media=<Media.pk2>`) it
## also prints a measurement on
## the player's own archive: the Language, the list sizes, and a few names'
## verdicts (never the words).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## One line: groups[g] is that group's 6 cells.
func _row(groups: Dictionary) -> String:
	var cells := PackedStringArray()
	cells.resize(36)
	for g in groups:
		var cs: Array = groups[g]
		for i in range(cs.size()):
			cells[g * 6 + i] = cs[i]
	return "\t".join(cells)

func _allow(from: String, to: String) -> Array:
	return ["#ALLOW_ID_TABLE", from, to, "", "", ""]

func _word(w: String, f1: String, f3: String = "0") -> Array:
	return [w, f1, "0", f3, "0", ""]

## UTF-16LE with a BOM, CR LF lines.
func _file(lines: Array) -> PackedByteArray:
	var text := "\r\n".join(PackedStringArray(lines)) + "\r\n"
	var out := PackedByteArray([0xff, 0xfe])
	for u in NameFilter.utf16_units(text):
		out.append(u & 0xff)
		out.append(u >> 8)
	return out

func _english() -> Array:
	return [
		_row({4: _allow("0x0030", "0x0039"), 5: _allow("0x0030", "0x0039")}),
		_row({4: _allow("0x0041", "0x005A"), 5: _allow("0x0041", "0x005A")}),
		_row({4: _allow("0x005F", "0x005F"), 5: _allow("0x005F", "0x005F")}),
		_row({4: _allow("0x0061", "0x007A"), 5: _allow("0x0061", "0x007A")}),
		_row({5: _allow("0x00C0", "0x00D6")}),
	]

func _init() -> void:
	# --- type.txt's Language (READ 0x847b84..) ---
	var tt := func(s: String) -> int: return NameFilter.language_from_type_txt(s.to_ascii_buffer())
	_check(tt.call("Language = \"Vietnam\"\r\nCountry = \"Vietnam\"\r\n") == 5, "Language = \"Vietnam\" -> 5")
	_check(tt.call("language=\"English\"") == 4, "the key is matched ignoring case")
	_check(tt.call("Language = \"Turkey\"") == 7 and tt.call("Language = \"Thailand\"") == 8 and tt.call("Language = \"Arabic\"") == 11, "Turkey 7, Thailand 8, Arabic 11")
	_check(tt.call("Language = \"vietnam\"") == NameFilter.LANGUAGE_ENGLISH, "the value is exact (OURS fallback English)")
	_check(tt.call("GameType = \"x\"") == NameFilter.LANGUAGE_ENGLISH, "no Language: English (OURS)")

	# --- the name test on group 4 (f1) and the guild test (f3) ---
	var lines := _english()
	lines.append(_row({4: _word("GM", "2", "0"), 5: _word("viet", "2")}))
	lines.append(_row({4: _word("Admin", "1", "1")}))
	lines.append(_row({4: _word("bad", "0", "2")}))
	lines.append(_row({4: _word("**Monster**", "0")}))
	var data := _file(lines)
	var f := NameFilter.load_bytes(data, 4)
	var c := f.counts()
	_check(c["allow_rows"] == 4 and c["name_substr"] == 1 and c["name_whole"] == 1 and c["guild_substr"] == 1 and c["guild_whole"] == 1,
		"group 4: 4 allow rows, f1 1+1 words, f3 1+1 (got %s)" % [c])
	for pair in [["Tester", true], ["GMBob", false], ["bobgm", false], ["Admin", false], ["ADMIN", false],
			["Admins", true], ["Badguy", true], ["Bob_1", true], ["Bob-1", false], ["Krämer", false],
			["a b", false], ["Vietnam", true], ["Àlex", false]]:
		_check(f.name_ok(pair[0]) == pair[1], "name %s -> %s" % [pair[0], pair[1]])
	# f3 is the guild's: "gm" is not in it, "bad" is.
	_check(f.guild_name_ok("GMGuild") and not f.guild_name_ok("Badlands") and not f.guild_name_ok("admin"),
		"the guild test reads f3's lists")

	# --- group 5: its own words, and 0xC0..0xD6 allowed on the client ---
	var g5 := NameFilter.load_bytes(data, 5)
	_check(g5.name_ok("Àlex") and not g5.name_ok("Øyvind"), "group 5 allows U+00C0 but not U+00D8")
	_check(not g5.name_ok("Vietnam") and g5.name_ok("GMBob"), "group 5 has its own words")

	# --- languages 7..11 read cells past the file's 36: nothing allowed ---
	var tr := NameFilter.load_bytes(data, 7)
	_check(tr.counts()["allow_rows"] == 0 and not tr.name_ok("Tester") and not tr.name_ok("ab"), "Turkey (7): no cell, every name refused")
	# A value with no case (6) skips no cell: group 0.
	var z := NameFilter.load_bytes(_file([_row({0: _allow("0x0061", "0x0061"), 4: _allow("0x0062", "0x0062")})]), 6)
	_check(z.name_ok("aa") and not z.name_ok("bb"), "language 6 reads group 0")

	# --- comments, empty flag cells, CR LF only ---
	var cl := _english()
	cl.append("// a comment line")
	cl.append(_row({4: _word("one", "2")}) + "\t// trailing")
	cl.append("/* a block")
	cl.append(_row({4: _word("two", "2")}))
	cl.append("still in it */")
	cl.append(_row({4: _word("three", "2")}))
	cl.append(_row({4: ["four", "", "2", "0", "0", ""]}))
	cl.append(_row({4: _word("fi\nve", "2")}))
	var fc := NameFilter.load_bytes(_file(cl), 4)
	_check(not fc.name_ok("Oneill") and fc.name_ok("Twofer") and not fc.name_ok("Three3"), "// and /* */ as the tokenizer reads them")
	_check(not fc.name_ok("Fourth"), "an empty f1 cell borrows the next number")
	_check(fc.name_ok("Five"), "a lone LF stays inside a cell")

	# --- the code -> character step (OURS: Windows-1252) ---
	var cp := NameFilter.load_bytes(_file([_row({4: _allow("0x0080", "0x0080")}), _row({4: _allow("0x8141", "0x8141")}), _row({4: _allow("0x0061", "0x0061")})]), 4)
	_check(cp.name_ok("a€") and cp.name_ok("a\u0081"), "0x80 is U+20AC; 0x8141's lead 0x81 is U+0081")
	_check(not cp.name_ok("a腁"), "a DBCS code is not its own number as a character")
	# A character above U+FFFF is two surrogate units, neither allowed here.
	_check(not f.name_ok("ab😀"), "a surrogate pair is refused")

	# --- numbers ---
	var nums := NameFilter.load_bytes(_file([_row({4: ["#allow_id_table", "97", "+98"]})]), 4)
	_check(nums.name_ok("ab") and not nums.name_ok("ac"), "decimal and signed numbers; the marker in any case")

	# --- the create screen's rule (READ 0x84eac0) and the guild prompt's ---
	_check(CharCreateModel.name_error("a", f) == CharCreateModel.MSG_NAME_LENGTH, "1 unit: NAME_STRING")
	_check(CharCreateModel.name_error("Abcdefghijklm", f) == CharCreateModel.MSG_NAME_LENGTH, "13 units: NAME_STRING")
	_check(CharCreateModel.name_error("GMBob", f) == CharCreateModel.MSG_NAME_CHARS, "a word: WRONGSTRING")
	_check(CharCreateModel.name_error("Tester", f) == "", "a clean name passes")
	_check(CharCreateModel.name_error("Bob-1") == CharCreateModel.MSG_NAME_CHARS, "no filter: [0-9A-Za-z_] only (OURS)")
	_check(NameFilter.guild_name_error("G", f) == NameFilter.GUILD_MSG_LENGTH and NameFilter.guild_name_error("Abcdefghijklm", f) == NameFilter.GUILD_MSG_LENGTH, "guild: 2..12 bytes")
	_check(NameFilter.guild_name_error("Silk Legion", f) == NameFilter.GUILD_MSG_NOT_ALLOWED, "guild: a space is refused")
	_check(NameFilter.guild_name_error("BadGuild", f) == NameFilter.GUILD_MSG_NOT_ALLOWED and NameFilter.guild_name_error("GMGuild", f) == "", "guild: f3's words")

	# --- the no-file filter ---
	var nf := NameFilter.no_file()
	_check(nf.name_ok("Bob_1") and not nf.name_ok("it's") and not nf.name_ok("a b"), "no file: [0-9A-Za-z_] (OURS)")

	_measure()

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(0)

## The measurement on a real Media.pk2 (only with OPENSRO_NAMEFILTER_MEDIA).
func _measure() -> void:
	var path := OS.get_environment("OPENSRO_NAMEFILTER_MEDIA")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--media="):
			path = a.substr(8)
	if path == "":
		return
	var media := Pk2Reader.open(path)
	if media == null:
		print("MEASURE: cannot open %s" % path)
		return
	var te := ObjectLoader.find_file(media, NameFilter.TYPE_TXT_PATH)
	print("MEASURE: type.txt %s, Language value %d" % ["found" if te != null else "missing",
		NameFilter.language_from_type_txt(media.read_file(te)) if te != null else -1])
	var f := NameFilter.from_media(media)
	print("MEASURE: language %d, from file %s, counts %s" % [f.language, f.from_file, f.counts()])
	var names := ["Tester", "GMBob", "a", "Abcdefghijklm", "Bob_1", "Krämer", "Àlex", "Admin", "Hello", "Gamemaster"]
	for lang in [4, 5]:
		var data := media.read_file(ObjectLoader.find_file(media, NameFilter.ABUSEFILTER_PATH))
		var g := NameFilter.load_bytes(data, lang)
		var out := PackedStringArray()
		for n in names:
			var why := CharCreateModel.name_error(n, g)
			out.append("%s=%s" % [n, "ok" if why == "" else ("LENGTH" if why == CharCreateModel.MSG_NAME_LENGTH else "WRONGSTRING")])
		print("MEASURE: group %d counts %s: %s" % [lang, g.counts(), " ".join(out)])
