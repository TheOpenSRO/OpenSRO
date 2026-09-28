extends RefCounted
class_name EnvSoundTable

## The zone -> music and ambient table, effectenvsnd.txt, and option.txt's
## title music (round 612). READ from sro_client.exe unless marked
## (audio_spec 2.1 and 6, sec_A A.1): the parser is the second half of
## CGEffSoundBody::vslot_008 (0xa75020).
##
## Media.pk2 server_dep\silkroad\textdata\effectenvsnd.txt, CP949, CRLF:
##   <1> ZoneName              opens a zone (a later duplicate REPLACES it)
##       "Jangan_Town.ogg" [n] the NEXT non-comment line: the zone's music,
##                             then a repeat count; 0 or absent is -1, loop
##                             for ever (no line in the data sets one)
##   <2> 낮 | 밤                day (CP949 B3 B7) or night (B9 E3) list
##   <3> "day_bird01.wav" a~b  an ambient entry, file under prim\snd\env\
## `//` and `/* */` are comments; tokens split on = " , space and tab. Any
## other `<2>` label or line token is an assert in retail; here it is one log
## line and skipped. Zone names are compared exactly (INFERRED
## case-sensitive, a std::map<std::string>).
## The resinfo\ copy is an older UTF-8 file with Korean zone names that the
## client does not load (INFERRED from its <2> byte compare).

const PATH := "server_dep\\silkroad\\textdata\\effectenvsnd.txt"
const OPTION_PATH := "config\\option.txt"
const ENV_PREFIX := "prim\\snd\\env\\"

## The CP949 day and night labels, as the Latin-1 text SoundTable.latin1
## makes of their bytes.
static var DAY_LABEL := String.chr(0xB3) + String.chr(0xB7)
static var NIGHT_LABEL := String.chr(0xB9) + String.chr(0xE3)

class Entry:
	var file: String = ""
	## `a~b`: seconds (INFERRED from the 2 s tick's arithmetic, AmbientBeds).
	## a == 0 is a looping bed.
	var a: int = 0
	var b: int = 0

class Zone:
	var name: String = ""
	var bgm: String = ""
	## -1 = loop for ever.
	var repeat: int = -1
	var day: Array = []
	var night: Array = []

	func list_for(night_time: bool) -> Array:
		return night if night_time else day

## Parses effectenvsnd.txt's bytes: zone name -> Zone.
static func parse(bytes: PackedByteArray) -> Dictionary:
	var zones: Dictionary = {}
	var zone: Zone = null
	var want_bgm := false
	var list_index := -1
	for line in SoundTable.text_lines(bytes):
		if want_bgm:
			want_bgm = false
			var quoted := _quoted(line)
			if quoted[0] != "":
				zone.bgm = quoted[0]
				var rest := _tokens(quoted[1])
				var n := SoundTable._atoi(rest[0]) if rest.size() > 0 else 0
				zone.repeat = n if n != 0 else -1
				continue
			# No quoted name on the next line: the zone has no music; fall
			# through and read the line as an ordinary one.
		var tokens := _tokens(line)
		if tokens.is_empty():
			continue
		match tokens[0]:
			"<1>":
				zone = Zone.new()
				zone.name = tokens[1] if tokens.size() > 1 else ""
				zones[zone.name] = zone
				want_bgm = true
				list_index = -1
			"<2>":
				var label: String = tokens[1] if tokens.size() > 1 else ""
				if label == DAY_LABEL:
					list_index = 0
				elif label == NIGHT_LABEL:
					list_index = 1
				else:
					list_index = -1
					print("AUDIO: effectenvsnd <2> label %s is neither day nor night -- its entries are skipped" % label.to_utf8_buffer().hex_encode())
			"<3>":
				if zone == null or list_index < 0:
					continue
				var quoted := _quoted(line)
				if quoted[0] == "":
					continue
				var entry := Entry.new()
				entry.file = quoted[0]
				var rest := _tokens(quoted[1])
				var span: PackedStringArray = rest[0].split("~") if rest.size() > 0 else PackedStringArray()
				entry.a = SoundTable._atoi(span[0]) if span.size() > 0 else 0
				entry.b = SoundTable._atoi(span[1]) if span.size() > 1 else entry.a
				(zone.day if list_index == 0 else zone.night).append(entry)
			_:
				pass
	return zones

## option.txt's `IntroBGM = "maintheme_cut.ogg"` (the title music; parsed by
## the exe at 0x84762d into CGame+0x8cc, READ), or "".
static func parse_intro_bgm(bytes: PackedByteArray) -> String:
	for line in SoundTable.text_lines(bytes):
		var tokens := _tokens(line)
		if tokens.size() >= 2 and tokens[0] == "IntroBGM":
			return tokens[1]
	return ""

## Splits on the tokenizer's delimiters: = " , space and tab.
static func _tokens(line: String) -> PackedStringArray:
	var t := line
	for sep in ["=", "\"", ",", "\t"]:
		t = t.replace(sep, " ")
	return t.split(" ", false)

## [the first "quoted" string on the line, the text after its closing quote].
## A file name with a space in it (ENV\bell towel 3.wav exists) stays whole.
static func _quoted(line: String) -> Array:
	var open := line.find("\"")
	if open < 0:
		return ["", line]
	var close := line.find("\"", open + 1)
	if close < 0:
		return [line.substr(open + 1).strip_edges(), ""]
	return [line.substr(open + 1, close - open - 1).strip_edges(), line.substr(close + 1)]
