extends RefCounted
class_name FriendNet

## Round 834: the messenger's friend list on the retail wire, mirroring
## server/internal/session/friend.go. docs/protocol/friends.md has the
## reading (c: the client's addresses, READ unless marked).
##
##   C->S 0x7302 {str name}                          ask (c:0x824c30)
##   S->C 0xB302 {2, u16 code} [0x640b: u8 reason, str name]   (c:0x885e50)
##   S->C 0x7302 {u32 job, u32 askerJID, str name}   the request (c:0x886000)
##   C->S 0x3303 {u32 job, u32 askerJID, u8 answer}  1 accepts, 0 refuses (c:0x820b20)
##   C->S 0x7304 {u32 charID}                        delete (c:0x820a60)
##   S->C 0xB304 {1, u32 charID} | {2, u16 code}     (c:0x881fd0)
##   S->C 0x3305 {u8 n, n x {u32 id, str name, u32 RefObjID, u8 state}}  (c:0x87fdd0)
##   S->C 0x3B07 {u8 kind, ...}: 2 added {u32 id, str name, u32 ref},
##        3 removed {u32 id}, 4 state {u32 id, u8 state}  (c:0x886310)
##
## Strings are a u16 length and single-byte characters (c:0x53d8c0 /
## c:0x4f7a70). State 0 is in the game, 1 is not.

const OP_ASK := 0x7302
const OP_ASK_FAILED := 0xB302
const OP_ANSWER := 0x3303
const OP_DELETE := 0x7304
const OP_DELETE_RESULT := 0xB304
const OP_LIST := 0x3305
const OP_PUSH := 0x3B07

const PUSH_ADDED := 2
const PUSH_REMOVED := 3
const PUSH_STATE := 4

const STATE_ONLINE := 0
const STATE_OFFLINE := 1

## The codes (category 0x13, c:0x7baad7) and their lines; 2, 3 and 5 show
## nothing.
const CODE_REFUSED := 0x640b
const CODE_TEXTS := {
	0x6408: "UIIT_MSG_FRIENDERR_FULLLIST",
	0x6409: "UIIT_MSG_FRIENDERR_ALREADYFRIEND",
	0x640a: "UIIT_MSG_FRIEND_SYSCANCEL",
	0x640d: "UIIT_MSG_FRIENDERR_UNKNOWNUSER",
	0x640e: "UIIT_MSG_FRIEND_SYSPROGRESS",
	0x640f: "UIIT_MSG_FRIENDERR_TARGETLISTFULL",
}
## 0x640b's reasons: 0 the target refused, 2 the 30 s wait ran out.
const REASON_REFUSED := 0
const REASON_TIMEOUT := 2

## One friend. `friend_name` and `online` keep the names GuildWindow's rows
## read.
class FriendEntry:
	var character_id: int
	var friend_name: String
	var ref_obj_id: int
	var state: int
	var online: bool:
		get:
			return state == STATE_ONLINE

## The request a player sent us (0x7302 from the server).
class Request:
	var job: int
	var asker_jid: int
	var asker_name: String

## A failed ask (0xB302 {2, code}).
class Failure:
	var code: int
	var reason: int = -1
	var name: String = ""

## A 0x3B07 push.
class Push:
	var kind: int
	var character_id: int
	var friend_name: String = ""
	var ref_obj_id: int = 0
	var state: int = -1

static func _str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, b.size())
	out.append_array(b)
	return out

## Reads a string at `at`: [text, next offset], or [] when short.
static func _read_str(data: PackedByteArray, at: int) -> Array:
	if at + 2 > data.size():
		return []
	var n := data.decode_u16(at)
	if at + 2 + n > data.size():
		return []
	return [data.slice(at + 2, at + 2 + n).get_string_from_utf8(), at + 2 + n]

static func encode_ask(target_name: String) -> PackedByteArray:
	return _str(target_name)

static func encode_answer(job: int, asker_jid: int, accept: bool) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(9)
	out.encode_u32(0, job)
	out.encode_u32(4, asker_jid)
	out[8] = 1 if accept else 0
	return out

static func encode_delete(character_id: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, character_id)
	return out

static func decode_request(data: PackedByteArray) -> Request:
	if data.size() < 8:
		return null
	var s := _read_str(data, 8)
	if s.is_empty():
		return null
	var r := Request.new()
	r.job = data.decode_u32(0)
	r.asker_jid = data.decode_u32(4)
	r.asker_name = s[0]
	return r

## 0xB302; null for result 1 (never sent, and ignored by c:0x885e98) or a
## short message.
static func decode_failure(data: PackedByteArray) -> Failure:
	if data.size() < 3 or data[0] != 2:
		return null
	var f := Failure.new()
	f.code = data.decode_u16(1)
	if f.code == CODE_REFUSED:
		if data.size() < 4:
			return null
		f.reason = data[3]
		var s := _read_str(data, 4)
		if s.is_empty():
			return null
		f.name = s[0]
	return f

static func decode_list(data: PackedByteArray) -> Array:
	var out: Array = []
	if data.is_empty():
		return out
	var n := data[0]
	var at := 1
	for i in n:
		if at + 4 > data.size():
			return out
		var e := FriendEntry.new()
		e.character_id = data.decode_u32(at)
		var s := _read_str(data, at + 4)
		if s.is_empty() or int(s[1]) + 5 > data.size():
			return out
		e.friend_name = s[0]
		at = s[1]
		e.ref_obj_id = data.decode_u32(at)
		e.state = data[at + 4]
		at += 5
		out.append(e)
	return out

static func decode_push(data: PackedByteArray) -> Push:
	if data.size() < 5:
		return null
	var p := Push.new()
	p.kind = data[0]
	p.character_id = data.decode_u32(1)
	match p.kind:
		PUSH_ADDED:
			var s := _read_str(data, 5)
			if s.is_empty() or int(s[1]) + 4 > data.size():
				return null
			p.friend_name = s[0]
			p.ref_obj_id = data.decode_u32(s[1])
			p.state = STATE_ONLINE # c:0x8863da pushes 0
		PUSH_REMOVED:
			pass
		PUSH_STATE:
			if data.size() < 6:
				return null
			p.state = data[5]
		_:
			return null
	return p

## 0xB304: [ok, id or code].
static func decode_delete_result(data: PackedByteArray) -> Array:
	if data.size() >= 5 and data[0] == 1:
		return [true, data.decode_u32(1)]
	if data.size() >= 3 and data[0] == 2:
		return [false, data.decode_u16(1)]
	return []

## The list after a push (c:0x886310): kind 2 appends with state 0, kind 3
## removes, kind 4 sets the state. Returns the list it changed in place.
static func apply_push(list: Array, p: Push) -> Array:
	match p.kind:
		PUSH_ADDED:
			var e := FriendEntry.new()
			e.character_id = p.character_id
			e.friend_name = p.friend_name
			e.ref_obj_id = p.ref_obj_id
			e.state = STATE_ONLINE
			list.append(e)
		PUSH_REMOVED:
			for i in range(list.size() - 1, -1, -1):
				if list[i].character_id == p.character_id:
					list.remove_at(i)
		PUSH_STATE:
			for e in list:
				if e.character_id == p.character_id:
					e.state = p.state
	return list

## The name of a friend in the list, or "".
static func name_of(list: Array, character_id: int) -> String:
	for e in list:
		if e.character_id == character_id:
			return e.friend_name
	return ""
