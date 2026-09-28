extends RefCounted
class_name SoundTable

## The retail effect-sound table and the calls that play from it (round 611).
## Part of the audio CONTRACT (docs/protocol/SOUND_FORMAT.md):
##
##   SoundTable.play_key(key: String, pos = null, obj = null) -> void
##     `key` is an effectsound.txt key, six tokens joined with ':' --
##     `object:handle:skill:event1:event2:event3`, e.g.
##     `PLAYER:snd_walk1:-:FIELD:DIRT:-` or `UI:snd_window_open:-:-:-:-`.
##     The match is EXACT: the table stores the handle lowercased and the
##     skill token uppercased, so build keys with make_key() (or spell them
##     that way). `-` is a literal token, not a wildcard.
##     `pos` is a world position (Vector3) or null; `obj` is a Node3D whose
##     global_position is used when `pos` is null (retail plays a character's
##     sounds at the object's own position). Neither -> a 2-D sound at full
##     distance volume (the UI path).
##   SoundTable.play_file(path: String, pos = null) -> void
##     A plain Data.pk2 path ("prim\snd\ui\uiwinopen.wav"), at row volume 1.0
##     (skilleffect SndBegin/SndEnd and the hard-coded UI paths).
##   SoundTable.set_listener(node: Node3D, facing: Node3D = null) -> void
##     What distances and pan are measured from; see AudioService.
##   SoundTable.sound_object(refobj_code: String) -> String
##     skilleffect.txt `#section characterInfo`: a characterdata code
##     (MOB_CH_MANGNYANG) -> its sound object (MOB_MANGNYANG), or "".
##   SoundTable.make_key(object, handle, skill, e1, e2, e3) -> String
##
## Everything below marked READ is from sro_client.exe (audio_spec 5 and 8,
## sec_B): CGEffSoundBody::vslot_008 (0xa75020) loads the table,
## FUN_00a6f7f0 plays by key, CPrimSound::FUN_00c1ebb0 + vslot_002 compute a
## positioned sound's volume.
##
## THE TABLE (READ): Media.pk2 server_dep\silkroad\textdata\effectsound.txt,
## CP949 (the file was checked: plain bytes, CRLF, Korean only in comments
## and the description column, so the parse works on bytes). `//` comments
## run to the end of the line; `/* */` blocks are skipped (the tokenizer,
## 0x401b80). Retail's tokenizer splits on space and tab AND on `"`, `,` and
## `=`; this parse splits on space and tab only, which reads the shipped
## table the same because no live row has `"`, `,` or `=` in its first ten
## columns (MEASURED: 0 of 6,004). Columns:
##   object handle skill_ID event1 event2 event3 blank folder filename volume description
## - key = the first six joined with ':'; handle lowercased, skill uppercased.
## - several rows may share a key (a multimap); a trigger picks one with
##   rand() % n.
## - `blank` is a per-row skip counter: the row plays on its first trigger
##   and then once every blank+1 triggers (entry +0 blank, +2 counter).
## - volume = clamp(col, 0, 100) / 100.0 (atoi, so `-` is 0).
## - path = "prim\snd\" + folder + filename, lowercased.
## A row with fewer than ten tokens is skipped: MEASURED, one row in the
## shipped table (a MOB_JUPITER_BABILION SND_STAND1 row missing a column).
## How retail treats it is not read; its key would end in the blank column's
## `0`, which no handler builds, so skipping it plays the same (INFERRED).
##
## THE VOLUME LAW (READ; constants 0xd85154 / 0xd85224 at 0x841c41, floor
## and ceiling at 0xbc1a78, cull constant 0xda98fc):
##   cull: a positioned sound more than 600 units from the listener is not
##         played at all -- checked BEFORE the pick, so it spends no counter.
##   d       = |src - listener|            (prim+0x7c scale INFERRED 1.0)
##   distMB  = 0 within 100, linear in dB down to -3000 at 300, -3000 beyond
##   optFrac = (effectMB + 3000) / 3000,   effectMB = 20*slider - 2000
##   vol     = -3000 + int((distMB + 3000) * optFrac * rowVolume)
##   played only if vol > -3000.
##   (rowVolume in that product is prim+0x80, INFERRED to be the row's
##   volume column / 100.) A 2-D sound takes distMB = 0 (INFERRED: the NULL
##   position path skips the distance, audio_spec 4).
## PAN (READ): int(lateral / 300 * 10000) DirectSound units, lateral = the
## source's signed sideways distance from the listener's forward line in
## XZ, clamped to +-10000 by DirectSound.
## OURS, labelled:
## - Godot turns that pan into left/right gains with its own 3-D panner
##   (the sound is placed on the unit circle around the camera at the
##   retail pan's sine), not DirectSound's dB pan law, and scaled by
##   audio/general/3d_panning_strength (default 0.5) -- the NUMBER is
##   retail's, the resulting stereo image is not (AudioService._pan_point).
## - The Effect bus carries the slider (AudioOptions); each voice plays at
##   vol/100 dB MINUS the bus's dB, so voice + bus = retail's number.
## - Voices: retail duplicates each loaded sound into N buffers, takes the
##   first idle one, and restarts a random one when all N are busy
##   (FUN_00c1db70, READ); N is not read. We use VOICES_PER_SOUND = 4.
## - The random pick uses Godot's randi(), not MSVC's rand().
## OPEN, not in the contract: FUN_00a6f7f0 takes a third float argument `f`;
## when it is non-zero the source is moved to listener + dir * (40.0 / f)
## (the 40.0 at 0xe1b8f8, READ). Footstep, swing and damage calls pass 0;
## which callers pass another value was not traced, so play_key has no such
## parameter yet.

const EFFECTSOUND_PATH := "server_dep\\silkroad\\textdata\\effectsound.txt"
const SKILLEFFECT_PATH := "server_dep\\silkroad\\textdata\\skilleffect.txt"
const SOUND_PREFIX := "prim\\snd\\"
const CHARACTER_INFO_SECTION := "characterInfo"

const NEAR := 100.0
const FAR := 300.0
const FLOOR_MB := -3000
const CEIL_MB := 0
const CULL_DISTANCE := 600.0
const CULL_DISTANCE_SQ := 360000.0
const PAN_SPAN := 300.0
const PAN_MAX := 10000
## OURS: voices per loaded sound (retail's N is not read).
const VOICES_PER_SOUND := 4

## One effectsound.txt row.
class Row:
	var blank: int = 0
	## Retail entry +2: starts at 0, a trigger decrements it, the row sounds
	## when it goes negative and it is then reset to `blank`.
	var counter: int = 0
	var volume: float = 1.0
	var path: String = ""

## A key, spelled the way the table stores it.
static func make_key(object: String, handle: String, skill: String = "-",
		event1: String = "-", event2: String = "-", event3: String = "-") -> String:
	return ":".join([object, handle.to_lower(), skill.to_upper(), event1, event2, event3])

## Parses effectsound.txt's bytes: key -> Array of Row, in file order.
static func parse(bytes: PackedByteArray) -> Dictionary:
	var table: Dictionary = {}
	for line in text_lines(bytes):
		var tokens := line.replace("\t", " ").split(" ", false)
		if tokens.size() < 10:
			continue
		var key := make_key(tokens[0], tokens[1], tokens[2], tokens[3], tokens[4], tokens[5])
		var row := Row.new()
		row.blank = _atoi(tokens[6])
		row.volume = float(clampi(_atoi(tokens[9]), 0, 100)) / 100.0
		row.path = (SOUND_PREFIX + tokens[7] + tokens[8]).to_lower()
		if not table.has(key):
			table[key] = []
		(table[key] as Array).append(row)
	return table

## The table's lines with comments removed, as Latin-1 text (one character
## per byte, so a CP949 byte pair survives as two characters and the ASCII
## structure is untouched: no CP949 trail byte is a space, tab, '/', '"',
## '<' or '~').
static func text_lines(bytes: PackedByteArray) -> PackedStringArray:
	var text := latin1(bytes)
	# `/* ... */` blocks, which may span lines.
	var start := text.find("/*")
	while start >= 0:
		var stop := text.find("*/", start + 2)
		text = text.substr(0, start) + (text.substr(stop + 2) if stop >= 0 else "")
		start = text.find("/*", start)
	var out := PackedStringArray()
	for raw in text.split("\n"):
		var line: String = raw
		var cut := line.find("//")
		if cut >= 0:
			line = line.substr(0, cut)
		line = line.strip_edges()
		if line != "":
			out.append(line)
	return out

## Bytes as Latin-1: one character per byte, whatever its value.
## Godot 4.2's get_string_from_ascii widens each byte as Latin-1 (checked by
## sound_table_test.gd on 0xB3 0xB7); a NUL would cut it short, so a length
## mismatch takes the slow path.
static func latin1(bytes: PackedByteArray) -> String:
	var fast := bytes.get_string_from_ascii()
	if fast.length() == bytes.size():
		return fast
	# Widen each byte to one UTF-32 unit, a NUL to a space.
	var wide := PackedByteArray()
	wide.resize(bytes.size() * 4)
	for i in range(bytes.size()):
		wide[i * 4] = bytes[i] if bytes[i] != 0 else 0x20
	return wide.get_string_from_utf32()

## C atoi: leading digits (with a sign), 0 when there are none.
static func _atoi(token: String) -> int:
	var digits := ""
	for i in range(token.length()):
		var c := token[i]
		if (c == "-" or c == "+") and i == 0:
			digits += c
		elif c >= "0" and c <= "9":
			digits += c
		else:
			break
	return digits.to_int() if digits.is_valid_int() else 0

## One trigger of a key's rows (FUN_00a6f7f0, READ): row `roll % n`, then
## the blank counter. Returns the row to play, or null when the counter says
## skip this trigger. `roll` is the random draw.
static func pick(rows: Array, roll: int) -> Row:
	if rows.is_empty():
		return null
	var row: Row = rows[absi(roll) % rows.size()]
	row.counter -= 1
	if row.counter >= 0:
		return null
	row.counter = row.blank
	return row

## distMB: the distance term of the volume law, in hundredths of a dB.
static func distance_mb(d: float) -> float:
	if d <= NEAR:
		return float(CEIL_MB)
	if d >= FAR:
		return float(FLOOR_MB)
	return float(FLOOR_MB) + (1.0 - (d - NEAR) / (FAR - NEAR)) * float(CEIL_MB - FLOOR_MB)

## The volume a sound plays at, in hundredths of a dB (READ law above).
## `effect_mb` is AudioOptions.slider_mb(effect slider).
static func volume_mb(dist_mb: float, effect_mb: int, row_volume: float) -> int:
	var opt_frac := float(effect_mb - FLOOR_MB) / float(CEIL_MB - FLOOR_MB)
	return FLOOR_MB + int((dist_mb - float(FLOOR_MB)) * opt_frac * row_volume)

## Whether a volume from volume_mb is played at all.
static func audible(vol_mb: int) -> bool:
	return vol_mb > FLOOR_MB

## Retail's pan number for a signed sideways distance (right positive).
static func pan_units(lateral: float) -> int:
	return clampi(int(lateral / PAN_SPAN * float(PAN_MAX)), -PAN_MAX, PAN_MAX)

## Whether a positioned sound this far away is culled before anything else.
static func culled(distance_sq: float) -> bool:
	return distance_sq > CULL_DISTANCE_SQ

## skilleffect.txt's `#section characterInfo`: column 1 (a characterdata
## code) -> column 2 (the effectsound object token). The server_dep copy is
## UTF-16 (the client reads it with its wide tokenizer, sec_B); a copy
## without a UTF-16 byte-order mark is read as bytes.
static func parse_character_info(bytes: PackedByteArray) -> Dictionary:
	var text := ""
	if bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE:
		text = bytes.slice(2).get_string_from_utf16()
	else:
		text = latin1(bytes)
	var out: Dictionary = {}
	var in_section := false
	for raw in text.split("\n"):
		var line: String = raw.strip_edges(false, true)
		if line.begins_with("#section"):
			var parts := line.replace("\t", " ").split(" ", false)
			in_section = parts.size() >= 2 and parts[1] == CHARACTER_INFO_SECTION
			continue
		if not in_section or line.strip_edges().begins_with("//"):
			continue
		var fields := line.split("\t")
		if fields.size() < 2:
			continue
		var code := fields[0].strip_edges()
		var obj := fields[1].strip_edges()
		if code != "" and obj != "":
			out[code] = obj
	return out

# --- The contract's calls: they reach the running AudioService autoload. ---

static func play_key(key: String, pos = null, obj = null) -> void:
	var svc := AudioService.instance()
	if svc != null:
		svc.play_key(key, pos, obj)

static func play_file(path: String, pos = null) -> void:
	var svc := AudioService.instance()
	if svc != null:
		svc.play_file(path, pos)

static func set_listener(node: Node3D, facing: Node3D = null) -> void:
	var svc := AudioService.instance()
	if svc != null:
		svc.set_listener(node, facing)

static func sound_object(refobj_code: String) -> String:
	var svc := AudioService.instance()
	return svc.sound_object(refobj_code) if svc != null else ""

static func has_key(key: String) -> bool:
	var svc := AudioService.instance()
	return svc != null and svc.effect_table().has(key)
