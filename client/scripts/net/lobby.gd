extends RefCounted
class_name LobbyNet

## The character lobby on retail's wire (round 682): 0x7007/0xB007 (create,
## list, delete, name check, restore) and 0x7001/0xB001 (Start), byte for
## byte the layouts docs/protocol/charselect.md section 5 READ out of
## sro_client.exe and SR_ShardManager.exe, on retail's own opcode numbers over
## our framing (the user's decision, 2026-10-02). The server's twin is
## server/internal/session/lobby.go; testdata/lobby_golden.json holds both to
## the same bytes (lobby_test.gd here, TestLobbyGolden there).
##
## Names are a u16 length and narrow bytes (READ). They are written as
## UTF-8, which is the same bytes for the ASCII names the server accepts; a
## name grandfathered from before round 682 decodes as UTF-8 too.

const OP_LOBBY := 0x7007          # client -> server
const OP_LOBBY_RESULT := 0xB007   # server -> client
const OP_START := 0x7001          # client -> server
const OP_START_RESULT := 0xB001   # server -> client

const ACTION_CREATE := 1
const ACTION_LIST := 2
const ACTION_DELETE := 3
const ACTION_NAME_CHECK := 4
const ACTION_RESTORE := 5

const RESULT_OK := 1
const RESULT_FAIL := 2

## The codes (READ; charselect.md section 5's table).
const CODE_REFUSED := 0x402
const CODE_BAD_CHARGEN := 0x403
const CODE_NO_WEAPON := 0x404
const CODE_ACCOUNT_FULL := 0x405
const CODE_CREATE_FAILED := 0x406
const CODE_NO_USER := 0x407
const CODE_DELETE_NAME := 0x408
const CODE_NOT_ON_ACCOUNT := 0x40b
const CODE_NAME_LENGTH := 0x40c
const CODE_NAME_INVALID := 0x40d
const CODE_BUSY := 0x40e
const CODE_NAME_EXISTS := 0x410
const CODE_NOTHING_TO_RESTORE := 0x419

const MAX_ITEMS := 9
const MAX_AVATARS := 5

## 4 characters an account (READ, client 0x85de50 and the server's 0x405).
const MAX_CHARACTERS := 4

## The deletion delay the countdown gauge is measured against: 10080 minutes
## (READ, the client's gauge 1 - remaining / 10080).
const DELETE_MINUTES := 10080

## A 0x7007 request.
class Request:
	var action: int = 0
	var name: String = ""
	var ref_obj_id: int = 0
	var scale: int = 0
	var chest: int = 0
	var legs: int = 0
	var feet: int = 0
	var weapon: int = 0
	var error: String = ""

## One listed character (READ, the client's SCharacterInfo reader 0x85e620).
class Character:
	var ref_obj_id: int = 0
	var char_name: String = ""
	var scale: int = 0
	var level: int = 0
	var exp_offset: int = 0
	var str_stat: int = 0
	var int_stat: int = 0
	var stat_points: int = 0
	var hp: int = 0
	var mp: int = 0
	var deleting: bool = false
	var minutes_left: int = 0
	## 0 none, 1 member, 2 master; academy 0 none, 1 student, 2 guardian (READ,
	## the delete refusal's message choice, client 0x858b66-0x858bd4).
	var guild_class: int = 0
	var guild_rename: bool = false
	var guild_name: String = ""
	var academy_class: int = 0
	var items: Array = []    # of {"id": int, "plus": int}
	var avatars: Array = []  # of {"id": int, "plus": int}

	## The HP and MP gauges' maxima as the retail select screen draws them:
	## HP / (Str x 10) and MP / (Int x 10) (READ, 0x85a7d0..0x85a834 -- the
	## client approximates the maximum from the stat).
	func gauge_max_hp() -> int:
		return str_stat * 10

	func gauge_max_mp() -> int:
		return int_stat * 10

## A 0xB007 result.
class Result:
	var action: int = 0
	var ok: bool = false
	var code: int = 0
	var characters: Array = []  # of Character
	var error: String = ""      # "" when the payload decoded

## A 0xB001 result.
class StartResult:
	var ok: bool = false
	var code: int = 0
	var error: String = ""

## How long the client waits for the list before it says the server did not
## answer (OURS, round 682's review): an older server ignores 0x7007 and the
## select screen would otherwise sit empty and silent.
const LIST_TIMEOUT_MS := 5000

## What the select screen says then. OURS: no retail text key says this (the
## nearest, UIO_MSG_ERROR_SEVER_CONNECT "Failed to connect to server.", is
## false here -- the connection is up).
const LIST_TIMEOUT_TEXT := "The server did not answer the character list -- the client or server may need updating."

## Watches one outstanding list request: armed when it is sent, cleared by
## the answer, expired LIST_TIMEOUT_MS later without one. Times are passed in
## (milliseconds) so a test can step them.
class ListWatch:
	var _since := -1

	func arm(now_ms: int) -> void:
		_since = now_ms

	func answered() -> void:
		_since = -1

	func pending() -> bool:
		return _since >= 0

	## True once, the first time it is polled past the timeout; it is then
	## cleared, so the timeout is reported once per request.
	func expired(now_ms: int) -> bool:
		if _since < 0 or now_ms - _since < LIST_TIMEOUT_MS:
			return false
		_since = -1
		return true

# --- Encoding ---------------------------------------------------------------

static func _u8(out: PackedByteArray, v: int) -> void:
	out.append(v & 0xff)

static func _u16(out: PackedByteArray, v: int) -> void:
	out.append(v & 0xff)
	out.append((v >> 8) & 0xff)

static func _u32(out: PackedByteArray, v: int) -> void:
	for i in range(4):
		out.append((v >> (8 * i)) & 0xff)

static func _u64(out: PackedByteArray, v: int) -> void:
	for i in range(8):
		out.append((v >> (8 * i)) & 0xff)

static func _str(out: PackedByteArray, s: String) -> void:
	var b := s.to_utf8_buffer()
	_u16(out, b.size())
	out.append_array(b)

## Encodes a request as the retail client writes it: the action byte, then
## for create the name, u32 model, u8 scale, u32 chest, legs, feet, weapon
## (READ, writer 0x84e2e0); for list nothing; for the others the name.
static func encode_request(r: Request) -> PackedByteArray:
	var out := PackedByteArray()
	_u8(out, r.action)
	match r.action:
		ACTION_LIST:
			pass
		ACTION_CREATE:
			_str(out, r.name)
			_u32(out, r.ref_obj_id)
			_u8(out, r.scale)
			_u32(out, r.chest)
			_u32(out, r.legs)
			_u32(out, r.feet)
			_u32(out, r.weapon)
		_:
			_str(out, r.name)
	return out

static func encode_list() -> PackedByteArray:
	var r := Request.new()
	r.action = ACTION_LIST
	return encode_request(r)

static func encode_named(action: int, name: String) -> PackedByteArray:
	var r := Request.new()
	r.action = action
	r.name = name
	return encode_request(r)

static func encode_create(name: String, ref_obj_id: int, scale: int, chest: int, legs: int, feet: int, weapon: int) -> PackedByteArray:
	var r := Request.new()
	r.action = ACTION_CREATE
	r.name = name
	r.ref_obj_id = ref_obj_id
	r.scale = scale
	r.chest = chest
	r.legs = legs
	r.feet = feet
	r.weapon = weapon
	return encode_request(r)

## 0x7001: the name alone, no action byte (READ, 0x858770).
static func encode_start(name: String) -> PackedByteArray:
	var out := PackedByteArray()
	_str(out, name)
	return out

## Encodes a result as the server writes it (the tests' fake server uses it).
static func encode_result(r: Result) -> PackedByteArray:
	var out := PackedByteArray()
	_u8(out, r.action)
	if not r.ok:
		_u8(out, RESULT_FAIL)
		_u16(out, r.code)
		return out
	_u8(out, RESULT_OK)
	if r.action == ACTION_LIST:
		_u8(out, r.characters.size())
		for c in r.characters:
			_encode_character(out, c)
	return out

static func _encode_character(out: PackedByteArray, c: Character) -> void:
	_u32(out, c.ref_obj_id)
	_str(out, c.char_name)
	_u8(out, c.scale)
	_u8(out, c.level)
	_u64(out, c.exp_offset)
	_u16(out, c.str_stat)
	_u16(out, c.int_stat)
	_u16(out, c.stat_points)
	_u32(out, c.hp)
	_u32(out, c.mp)
	if c.deleting:
		_u8(out, 1)
		_u32(out, c.minutes_left)
	else:
		_u8(out, 0)
	_u8(out, c.guild_class)
	if c.guild_rename:
		_u8(out, 1)
		_str(out, c.guild_name)
	else:
		_u8(out, 0)
	_u8(out, c.academy_class)
	var items: Array = c.items.slice(0, MAX_ITEMS)
	_u8(out, items.size())
	for it in items:
		_u32(out, int(it["id"]))
		_u8(out, int(it["plus"]))
	var avatars: Array = c.avatars.slice(0, MAX_AVATARS)
	_u8(out, avatars.size())
	for it in avatars:
		_u32(out, int(it["id"]))
		_u8(out, int(it["plus"]))

static func encode_start_result(ok: bool, code: int = 0) -> PackedByteArray:
	var out := PackedByteArray()
	if ok:
		_u8(out, RESULT_OK)
	else:
		_u8(out, RESULT_FAIL)
		_u16(out, code)
	return out

# --- Decoding ---------------------------------------------------------------

## A little-endian reader that remembers the first shortfall.
class Reader:
	var data: PackedByteArray
	var pos := 0
	var error := ""

	func _init(d: PackedByteArray) -> void:
		data = d

	func _take(n: int) -> bool:
		if error != "":
			return false
		if pos + n > data.size():
			error = "truncated"
			return false
		return true

	func u8() -> int:
		if not _take(1):
			return 0
		var v := data[pos]
		pos += 1
		return v

	func u16() -> int:
		if not _take(2):
			return 0
		var v := data.decode_u16(pos)
		pos += 2
		return v

	func u32() -> int:
		if not _take(4):
			return 0
		var v := data.decode_u32(pos)
		pos += 4
		return v

	func u64() -> int:
		if not _take(8):
			return 0
		var v := data.decode_u64(pos)
		pos += 8
		return v

	func text() -> String:
		var n := u16()
		if not _take(n):
			return ""
		var s := data.slice(pos, pos + n).get_string_from_utf8()
		pos += n
		return s

static func decode_request(data: PackedByteArray) -> Request:
	var rd := Reader.new(data)
	var r := Request.new()
	r.action = rd.u8()
	match r.action:
		ACTION_LIST:
			pass
		ACTION_CREATE:
			r.name = rd.text()
			r.ref_obj_id = rd.u32()
			r.scale = rd.u8()
			r.chest = rd.u32()
			r.legs = rd.u32()
			r.feet = rd.u32()
			r.weapon = rd.u32()
		ACTION_DELETE, ACTION_NAME_CHECK, ACTION_RESTORE:
			r.name = rd.text()
	r.error = rd.error
	return r

static func _decode_character(rd: Reader) -> Character:
	var c := Character.new()
	c.ref_obj_id = rd.u32()
	c.char_name = rd.text()
	c.scale = rd.u8()
	c.level = rd.u8()
	c.exp_offset = rd.u64()
	c.str_stat = rd.u16()
	c.int_stat = rd.u16()
	c.stat_points = rd.u16()
	c.hp = rd.u32()
	c.mp = rd.u32()
	if rd.u8() != 0:
		c.deleting = true
		c.minutes_left = rd.u32()
	c.guild_class = rd.u8()
	if rd.u8() != 0:
		c.guild_rename = true
		c.guild_name = rd.text()
	c.academy_class = rd.u8()
	var n := rd.u8()
	if n > MAX_ITEMS and rd.error == "":
		rd.error = "%d items, at most %d" % [n, MAX_ITEMS]
	for i in range(n):
		if rd.error != "":
			break
		c.items.append({"id": rd.u32(), "plus": rd.u8()})
	n = rd.u8()
	if n > MAX_AVATARS and rd.error == "":
		rd.error = "%d avatars, at most %d" % [n, MAX_AVATARS]
	for i in range(n):
		if rd.error != "":
			break
		c.avatars.append({"id": rd.u32(), "plus": rd.u8()})
	return c

static func decode_result(data: PackedByteArray) -> Result:
	var rd := Reader.new(data)
	var r := Result.new()
	r.action = rd.u8()
	var res := rd.u8()
	if res == RESULT_OK:
		r.ok = true
		if r.action == ACTION_LIST:
			var n := rd.u8()
			for i in range(n):
				if rd.error != "":
					break
				r.characters.append(_decode_character(rd))
	elif res == RESULT_FAIL:
		r.code = rd.u16()
	elif rd.error == "":
		rd.error = "result byte %d" % res
	r.error = rd.error
	return r

static func decode_start(data: PackedByteArray) -> String:
	var rd := Reader.new(data)
	var name := rd.text()
	return name if rd.error == "" else ""

static func decode_start_result(data: PackedByteArray) -> StartResult:
	var rd := Reader.new(data)
	var r := StartResult.new()
	var res := rd.u8()
	if res == RESULT_OK:
		r.ok = true
	elif res == RESULT_FAIL:
		r.code = rd.u16()
	elif rd.error == "":
		rd.error = "result byte %d" % res
	r.error = rd.error
	return r

# --- Words ------------------------------------------------------------------

## The text key the retail client shows for each code (READ, charselect.md
## section 5's table, decoded through the byte index tables 0x861b84 and
## 0x861a40). Keys marked in SERVER_SUFFIX get "(S<decimal code>)" appended.
const TEXT_KEY_BY_CODE := {
	0x402: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x403: "UIO_SMERR_INVALID_CHARGEN_INFO",
	0x404: "UIO_MSG_ERROR_CHARACTER_SELECTWEAPON",
	0x405: "UIO_MSG_ERROR_CHARACTER_OVER_3",
	0x406: "UIO_SMERR_FAILED_TO_CREATE_CHARACTER",
	0x407: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x408: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x409: "UIO_SMERR_CANT_FIND_GAMESERVER",
	0x40a: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x40b: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x40c: "UIO_MSG_ERROR_CHARACTER_NAME_STRING",
	0x40d: "UIO_SMERR_NOT_ALLOWED_CHARNAME",
	0x40e: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x40f: "UIO_SMERR_CANT_ACCESS_PARENT_SERVER",
	0x410: "UIO_MSG_ERROR_ID",
	0x411: "UIO_MSG_ERROR_OVERLAP",
	0x412: "UIO_SMERR_FAILED_TO_CREATE_NEW_USER",
	0x413: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x414: "UIO_SMERR_MAX_USER_EXCEEDED",
	0x415: "UIO_SMERR_FAILED_TO_ENTERLOBBY",
	0x416: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x417: "UIO_MSG_ERROR_SEVER_CONNECT",
	0x418: "UIO_MSG_ERROR_SEVER_CONNECT",
}
const SERVER_SUFFIX := [0x402, 0x403, 0x406, 0x407, 0x408, 0x409, 0x40a, 0x40b, 0x40e, 0x40f, 0x412, 0x413, 0x415, 0x416, 0x417, 0x418]

## Our own words for each code when the archive's text is not to hand (OURS;
## the game's are read from the player's textuisystem when it is).
const FALLBACK_BY_CODE := {
	0x403: "Those choices cannot make a character.",
	0x404: "Choose a weapon first.",
	0x405: "This account already has the most characters it can hold.",
	0x406: "The character could not be created.",
	0x40c: "A name is 2 to 12 letters or digits.",
	0x40d: "That name cannot be used.",
	0x410: "That name is already taken.",
	0x419: "That character is not waiting to be deleted.",
}

## The words for a refusal: the archive's text when table has the key, our
## own otherwise, with the "(S<code>)" suffix the client adds to server-side
## failures. 0x405's text carries a %d, the account limit.
static func code_text(code: int, table: UiTextTable) -> String:
	var text := ""
	var key: String = TEXT_KEY_BY_CODE.get(code, "")
	if key != "" and table != null and table.has(key):
		text = table.get_text(key).strip_edges()
		if text == key:
			text = ""
	if text == "":
		text = FALLBACK_BY_CODE.get(code, "The server refused (code 0x%x)." % code)
	# The archive writes its line breaks as a literal backslash-n (MEASURED:
	# UIO_SMERR_NOT_ALLOWED_CHARNAME, seen raw in round 682's e2e).
	text = text.replace("\\n", "\n")
	if text.find("%d") >= 0:
		text = text.replace("%d", str(MAX_CHARACTERS))
	if code in SERVER_SUFFIX:
		text += "(S%d)" % code
	return text
