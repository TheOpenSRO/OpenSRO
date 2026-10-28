extends RefCounted
class_name ServiceNet

## Round 838 (OURS): the private-server service scrolls' messages
## (server/internal/session/servicescroll.go). None is retail: the archive's
## mall sells the scrolls, but what they did was the private server's.
##
##   S->C 0x0138 {str text}                        a system line about a service
##   C->S 0x0139 {str name, str newName}           a waiting rename, at character select
##   S->C 0x013A {u8 result, u16 code, str name}   1 renamed (the new name), 2 refused (the code)
##   S->C 0x013B {u32 uid, u32 name, u32 title}    a character's plate colours, 0xAARRGGBB, 0 = default
##
## and 0xB001's code START_RENAME_PENDING: Start refused while the
## character's rename waits; the select screen asks for the new name.
##
## Strings are u16 length + UTF-8 bytes, as everywhere on the wire.

const OP_LINE := 0x0138
const OP_RENAME := 0x0139
const OP_RENAME_RESULT := 0x013A
const OP_PLATE_COLOURS := 0x013B
const START_RENAME_PENDING := 0x04F0
const RENAME_NOT_PENDING := 0x04F1

## A service line arrived (the HUD prints it).
signal line(text: String)
## A character's plate colours changed (uid; read them with name_colour /
## title_colour).
signal plate_colours_changed(uid: int)
## The rename's answer: ok, the code when refused, the new name when done.
signal rename_result(ok: bool, code: int, new_name: String)

## uid -> [name ARGB, title ARGB] (0 = the plate's default).
var plate_colours: Dictionary = {}

var send: Callable

func register_with(client: Node) -> void:
	client.register_handler(OP_LINE, func(data: PackedByteArray) -> void:
		var s := _str(data, 0)
		if int(s[1]) >= 0:
			line.emit(String(s[0])))
	client.register_handler(OP_PLATE_COLOURS, func(data: PackedByteArray) -> void:
		var c := decode_plate_colours(data)
		if c.is_empty():
			return
		var uid := int(c["uid"])
		if int(c["name"]) == 0 and int(c["title"]) == 0:
			plate_colours.erase(uid)
		else:
			plate_colours[uid] = [int(c["name"]), int(c["title"])]
		plate_colours_changed.emit(uid))
	client.register_handler(OP_RENAME_RESULT, func(data: PackedByteArray) -> void:
		var r := decode_rename_result(data)
		if not r.is_empty():
			rename_result.emit(bool(r["ok"]), int(r["code"]), String(r["name"])))

## 0x0139: rename `char_name` to `new_name`.
func request_rename(char_name: String, new_name: String) -> void:
	if send.is_valid():
		send.call(OP_RENAME, encode_rename(char_name, new_name))

## The name's colour for uid, or `fallback` when it has the default.
func name_colour(uid: int, fallback: Color) -> Color:
	var c: Array = plate_colours.get(uid & 0xffffffff, [])
	return argb_colour(int(c[0]), fallback) if c.size() == 2 else fallback

## The title's colour for uid, or `fallback` when it has the default.
func title_colour(uid: int, fallback: Color) -> Color:
	var c: Array = plate_colours.get(uid & 0xffffffff, [])
	return argb_colour(int(c[1]), fallback) if c.size() == 2 else fallback

static func argb_colour(argb: int, fallback: Color) -> Color:
	if argb == 0:
		return fallback
	return Color8((argb >> 16) & 0xff, (argb >> 8) & 0xff, argb & 0xff, (argb >> 24) & 0xff)

static func _str(d: PackedByteArray, at: int) -> Array:
	if at + 2 > d.size():
		return ["", -1]
	var n := d.decode_u16(at)
	if at + 2 + n > d.size():
		return ["", -1]
	return [d.slice(at + 2, at + 2 + n).get_string_from_utf8(), at + 2 + n]

static func _put_str(out: PackedByteArray, s: String) -> void:
	var b := s.to_utf8_buffer()
	var n := out.size()
	out.resize(n + 2)
	out.encode_u16(n, b.size())
	out.append_array(b)

static func encode_rename(char_name: String, new_name: String) -> PackedByteArray:
	var out := PackedByteArray()
	_put_str(out, char_name)
	_put_str(out, new_name)
	return out

static func decode_plate_colours(d: PackedByteArray) -> Dictionary:
	if d.size() < 12:
		return {}
	return {"uid": d.decode_u32(0), "name": d.decode_u32(4), "title": d.decode_u32(8)}

static func decode_rename_result(d: PackedByteArray) -> Dictionary:
	if d.size() < 3:
		return {}
	var s := _str(d, 3)
	return {"ok": d[0] == 1, "code": d.decode_u16(1), "name": String(s[0])}
