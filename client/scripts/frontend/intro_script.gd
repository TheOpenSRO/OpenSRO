extends RefCounted
class_name IntroScript

## The title screen's intro script: Media.pk2 `script\intro\<name>.txt`, the
## camera path the login screen flies before the login window fades in. See
## docs/protocol/intro_script.md for the format and every address below.
##
## READ (round 678) from the client's loader UI_ALCHEMYBOX::FUN_0056cb10 (the
## intro object is the global at 0xee7be8, loaded once at startup from
## option.txt's IntroName by Client_LoadAllRefData -> FUN_00840670):
##   - the text is UTF-16 (each retail file starts FF FE), read line by line;
##     a line's tokens are split on tab and space (the tokenizer is set up
##     with 0x09 and 0x20 at 0x56d45b..0x56d47f);
##   - the FIRST token of a line switches section by prefix: `[SCRIPT]`
##     (wcsncmp, 8 chars), `[CAMERA]` (8), `[END]` (5 -- back to no section);
##   - in [CAMERA], a first token starting `AREA=` (5 chars) names a crowd
##     area (FUN_00520580 builds EUROP_CONSTANTINOPLE's crowd at the title,
##     FUN_0051dea0); otherwise the SECOND token must be exactly
##     `S_CameraInsert` and ten more follow: time (_wtof), region low byte and
##     high byte (thunk_FUN_00b43f75, kept as bytes at keyframe +4 and +5),
##     x, y, z, then four rotation values (_wtof each, keyframe +8 .. +0x20).
##     The first token of a keyframe line is read and never used. Any other
##     line in [CAMERA] (ruby_baghdad's `S_CameraShake`) is skipped;
##   - [SCRIPT] lines go, token by token, to the GScript interpreter
##     (FUN_004779a0 / FUN_00477ca0) -- kept here as text, not executed
##     (OPEN: the GScript subset);
##   - each keyframe is appended in FILE order (FUN_0056ca60) and its region
##     handed to FUN_0056c870, which collects the regions to preload
##     (preload_regions below).
## The four rotation values are the camera's pitch, yaw, roll and distance
## (READ from the camera, see IntroCameraPath).
##
## OURS: an operator's own script (custom/intro/<name>.txt, FrontEndTheme)
## may also be UTF-8; the retail files are all UTF-16LE.

const SECTION_NONE := 0
const SECTION_CAMERA := 1
const SECTION_SCRIPT := 2

## The region span (READ: the 1920.0 double at 0xe1b800 FUN_0056c870 and
## FUN_004e5bf0 compare against).
const REGION_SPAN := 1920.0

## Sanity bounds (OURS, round 678's review): a value outside them -- or not
## a finite number at all (`1e999` reads as inf) -- makes the whole script
## unusable, so the title falls back to the next intro with a log line
## instead of flying (or hanging) on it. Retail has none; its own files sit
## far inside them (MEASURED, check_intro_scripts.gd: times <= 53 s, |x|,
## |z| <= 8320, y -434..2008, |angles| <= 14.9, distances 1..100,
## at most 21 keyframes).
const MAX_KEYFRAMES := 1024
const MAX_TIME := 3600.0
const MAX_HORIZONTAL := REGION_SPAN * 32.0
const MAX_HEIGHT := 20000.0
const MAX_ANGLE := 1000.0
const MAX_DISTANCE := 100000.0
## [SCRIPT] lines kept as text (not run); more are dropped.
const MAX_SCRIPT_LINES := 10000

class Keyframe:
	var time: float = 0.0
	## The region word's bytes: lo is the X sector, hi the Z sector (this
	## project writes a region "hi/lo", e.g. Jangan 97/168).
	var region_lo: int = 0
	var region_hi: int = 0
	## Region-local position, which may lie outside [0, 1920) -- retail's
	## intros fly regions away from the region they name.
	var pos := Vector3.ZERO
	var pitch: float = 0.0
	var yaw: float = 0.0
	var roll: float = 0.0
	var distance: float = 0.0

	func region_word() -> int:
		return (region_hi << 8) | region_lo

class Parsed:
	var keyframes: Array[Keyframe] = []
	## The `AREA=` value, without the prefix ("" when none).
	var area: String = ""
	## The [SCRIPT] section's lines as written (not executed this round).
	var script_lines: PackedStringArray = PackedStringArray()
	## [CAMERA] lines that were neither a keyframe nor AREA= (e.g.
	## `S_CameraShake`), for the log.
	var skipped_camera_lines: PackedStringArray = PackedStringArray()
	## Why nothing usable came out, or "".
	var error: String = ""

	func duration() -> float:
		# READ: FUN_00869b50 stores the LAST keyframe's time as the path's
		# length (path +0xf0) -- the last in file order, not the largest.
		return keyframes[keyframes.size() - 1].time if not keyframes.is_empty() else 0.0

	func ok() -> bool:
		return error == "" and not keyframes.is_empty()

## Parses intro script bytes. Never fails hard: a file with no keyframe comes
## back with `error` set.
static func parse(bytes: PackedByteArray) -> Parsed:
	var out := Parsed.new()
	var text := decode_text(bytes)
	if text == "":
		out.error = "empty or undecodable"
		return out
	var section := SECTION_NONE
	for raw_line in text.split("\n"):
		var line := (raw_line as String).replace("\r", "")
		var tokens := tokens_of(line)
		var first: String = tokens[0] if tokens.size() > 0 else ""
		if first.begins_with("[SCRIPT]"):
			section = SECTION_SCRIPT
			continue
		if first.begins_with("[CAMERA]"):
			section = SECTION_CAMERA
			continue
		if first.begins_with("[END]"):
			section = SECTION_NONE
			continue
		if section == SECTION_SCRIPT:
			if line.strip_edges() != "" and out.script_lines.size() < MAX_SCRIPT_LINES:
				out.script_lines.append(line.strip_edges())
		elif section == SECTION_CAMERA:
			if first.begins_with("AREA="):
				out.area = first.substr(5)
				continue
			if tokens.size() >= 2 and tokens[1] == "S_CameraInsert":
				var kf := Keyframe.new()
				kf.time = _wtof(_at(tokens, 2))
				kf.region_lo = _wtoi(_at(tokens, 3)) & 0xFF
				kf.region_hi = _wtoi(_at(tokens, 4)) & 0xFF
				kf.pos = Vector3(_wtof(_at(tokens, 5)), _wtof(_at(tokens, 6)), _wtof(_at(tokens, 7)))
				kf.pitch = _wtof(_at(tokens, 8))
				kf.yaw = _wtof(_at(tokens, 9))
				kf.roll = _wtof(_at(tokens, 10))
				kf.distance = _wtof(_at(tokens, 11))
				var bad := out_of_bounds(kf)
				if bad != "":
					out.error = "keyframe %d: %s" % [out.keyframes.size() + 1, bad]
					out.keyframes.clear()
					return out
				if out.keyframes.size() >= MAX_KEYFRAMES:
					out.error = "more than %d keyframes" % MAX_KEYFRAMES
					out.keyframes.clear()
					return out
				out.keyframes.append(kf)
			elif line.strip_edges() != "":
				out.skipped_camera_lines.append(line.strip_edges())
	if out.keyframes.is_empty():
		out.error = "no S_CameraInsert keyframe in a [CAMERA] section"
	return out

## Why a keyframe cannot be flown, or "" (the bounds above).
static func out_of_bounds(kf: Keyframe) -> String:
	var checks := [
		["time", kf.time, 0.0, MAX_TIME],
		["x", kf.pos.x, -MAX_HORIZONTAL, MAX_HORIZONTAL],
		["y", kf.pos.y, -MAX_HEIGHT, MAX_HEIGHT],
		["z", kf.pos.z, -MAX_HORIZONTAL, MAX_HORIZONTAL],
		["pitch", kf.pitch, -MAX_ANGLE, MAX_ANGLE],
		["yaw", kf.yaw, -MAX_ANGLE, MAX_ANGLE],
		["roll", kf.roll, -MAX_ANGLE, MAX_ANGLE],
		["distance", kf.distance, 0.0, MAX_DISTANCE],
	]
	for c in checks:
		var v: float = c[1]
		if is_nan(v) or is_inf(v):
			return "%s is not a finite number" % c[0]
		if v < float(c[2]) or v > float(c[3]):
			return "%s %s is outside %s..%s" % [c[0], str(v), str(c[2]), str(c[3])]
	return ""

## The region the camera is placed in: READ, CPSTitle::OnCreate asks the
## intro object for the LAST keyframe (FUN_0056be40, 0x86bda0) and hands its
## region word to FUN_004fb510, which makes it the current region (and its
## environment the sky's). The path itself never reads a keyframe's region
## (FUN_004e67b0 takes only time, position and rotation), so every position
## is relative to this one region.
static func origin_region(parsed: Parsed) -> Vector2i:
	if parsed.keyframes.is_empty():
		return Vector2i(-1, -1)
	var last: Keyframe = parsed.keyframes[parsed.keyframes.size() - 1]
	return Vector2i(last.region_hi, last.region_lo)

## Whether every keyframe names the same region (all the retail files do).
static func single_region(parsed: Parsed) -> bool:
	for kf in parsed.keyframes:
		if kf.region_word() != parsed.keyframes[0].region_word():
			return false
	return true

## The regions retail preloads for the intro, as Vector2i(hi, lo), in
## insertion order without repeats -- READ, UI_ALCHEMYBOX::FUN_0056c870 per
## keyframe: its own region word, then (independently, never the diagonal)
## the low byte shifted when x >= 1920 or x <= 0, and the high byte shifted
## when z >= 1920 or z <= 0, by trunc(v / -1920.0) (the double at 0xd8ac80,
## fistp under a truncating control word), one more step down for v <= 0.
## The byte arithmetic wraps as the exe's does.
static func preload_regions(parsed: Parsed) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for kf in parsed.keyframes:
		var lo := kf.region_lo
		var hi := kf.region_hi
		_add_region(out, Vector2i(hi, lo))
		if (kf.region_word() & 0x8000) != 0:
			continue
		if kf.pos.x >= REGION_SPAN:
			_add_region(out, Vector2i(hi, (lo - int(kf.pos.x / -REGION_SPAN)) & 0xFF))
		if kf.pos.x <= 0.0:
			_add_region(out, Vector2i(hi, (lo - int(kf.pos.x / -REGION_SPAN) - 1) & 0xFF))
		if kf.pos.z >= REGION_SPAN:
			_add_region(out, Vector2i((hi - int(kf.pos.z / -REGION_SPAN)) & 0xFF, lo))
		if kf.pos.z <= 0.0:
			_add_region(out, Vector2i((hi - int(kf.pos.z / -REGION_SPAN) - 1) & 0xFF, lo))
	return out

static func _add_region(out: Array[Vector2i], r: Vector2i) -> void:
	if not out.has(r):
		out.append(r)

## Text from the file's bytes: UTF-16LE with or without its FF FE mark (the
## retail files), UTF-16BE with FE FF, else UTF-8 (an operator's own file,
## OURS) with or without EF BB BF.
static func decode_text(bytes: PackedByteArray) -> String:
	if bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE:
		return TextDecode.utf16(bytes.slice(2))
	if bytes.size() >= 2 and bytes[0] == 0xFE and bytes[1] == 0xFF:
		var swapped := bytes.slice(2)
		for i in range(0, swapped.size() - 1, 2):
			var t := swapped[i]
			swapped[i] = swapped[i + 1]
			swapped[i + 1] = t
		return TextDecode.utf16(swapped)
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
		return bytes.slice(3).get_string_from_utf8()
	# No mark: UTF-16LE if the second byte of most leading pairs is zero.
	var pairs := mini(bytes.size() / 2, 64)
	var zeros := 0
	for i in range(pairs):
		if bytes[i * 2 + 1] == 0 and bytes[i * 2] != 0:
			zeros += 1
	if pairs > 0 and zeros * 2 > pairs:
		return TextDecode.utf16(bytes)
	return bytes.get_string_from_utf8()

## A line's tokens, split on tab and space (READ: the tokenizer's two
## delimiters, 0x09 and 0x20).
static func tokens_of(line: String) -> PackedStringArray:
	return line.replace("\t", " ").split(" ", false)

static func _at(tokens: PackedStringArray, i: int) -> String:
	return tokens[i] if i < tokens.size() else ""

static var _float_re: RegEx = null
static var _int_re: RegEx = null

## _wtof: the longest leading float, 0 when there is none -- china_wharf's
## z values carry a trailing `f` ("484.136963f") that _wtof stops at.
static func _wtof(s: String) -> float:
	if _float_re == null:
		_float_re = RegEx.create_from_string("^\\s*[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?")
	var m := _float_re.search(s)
	return m.get_string().strip_edges().to_float() if m != null else 0.0

## _wtoi: the leading integer, 0 when there is none.
static func _wtoi(s: String) -> int:
	if _int_re == null:
		_int_re = RegEx.create_from_string("^\\s*[+-]?\\d+")
	var m := _int_re.search(s)
	return m.get_string().strip_edges().to_int() if m != null else 0

## option.txt's `IntroName = "script\intro\roc.txt"` (READ: parsed by
## CGame::FUN_008469c0 at 0x8475d3 into CGame+0x8b0), or "". A `//` line is
## a comment (the retail file comments out three other intros that way).
static func parse_option_intro_name(bytes: PackedByteArray) -> String:
	for line in SoundTable.text_lines(bytes):
		var t := (line as String)
		for sep in ["=", "\"", "\t"]:
			t = t.replace(sep, " ")
		var tokens := t.split(" ", false)
		if tokens.size() >= 2 and tokens[0] == "IntroName":
			return tokens[1]
	return ""
