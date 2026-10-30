extends RefCounted
class_name UnionOps

## Round 844 (lane U): the players' union requests and their replies, as
## sro_client.exe sends and reads them (the server's side is
## server/internal/session/unionops.go; docs/protocol/guild_union.md). READ
## unless a line says otherwise.
##
## Requests:
## - 0x70FB (SendGuildMsg_0fb c:0x8201b0, the union pane's Apply 51): u32 the
##   selected object -- a player, or a pet's owner (its +0xf8) -- never the
##   player itself; nothing is sent without one.
## - 0x70FC (c:0x8202f0, Secede's Yes): no body.
## - 0x70FD (c:0x820390, Expel's Yes): u32 the selected guild's id.
## - 0x3080 the request box's answer (box 0x1d, c:0x797d90 case 0x798667):
##   {1, 1} yes, {2, u16 0} no -- a zero code, where the guild's box sends
##   0x4c16.
## Replies (c:0x881dd0 / 0x881e20 / 0x881e70): u8 1, or u8 2 + u16 code shown
## through category 0x10 (GuildOpsNet.UIIT_BY_CODE; a code without a row --
## 0x4c2e the target's "no", 0x4c10 the 30 s, 0x4c2f, 0x4c30 -- shows nothing).
## 0x3080 kind 6 {u32 the requester} (c:0x88afb4): dropped unless the
## requester is a spawned player with a guild line; else box 0x1d with that
## guild's name.

const OP_REQUEST := 0x70FB
const OP_REQUEST_RESULT := 0xB0FB
const OP_LEAVE := 0x70FC
const OP_LEAVE_RESULT := 0xB0FC
const OP_EXPEL := 0x70FD
const OP_EXPEL_RESULT := 0xB0FD
const OP_BOX := 0x3080
const RESULT_OPCODES := [OP_REQUEST_RESULT, OP_LEAVE_RESULT, OP_EXPEL_RESULT]
## 0x3080's kind for a union request (c:0x88afb4).
const REQUEST_KIND := 6

## A line for the system message window: a text key (category 0x10's, ""
## for a code with no row) and the code.
signal notice(key: String, args: Array, code: int)
## 0x3080 kind 6 for a spawned player with a guild line: box 0x1d.
signal request_box(requester_uid: int, guild_name: String)
## Any reply, for the QA log.
signal result(op: int, ok: bool, code: int)

## Sends a message (op, payload); unset: nothing goes out.
var send: Callable
## uid -> the player's name, "" for no spawned player (as GuildOpsState).
var player_name: Callable
## uid -> the player's guild name from its plate record, "" for none.
var player_guild: Callable
## The requester whose box is open (0 none).
var pending_requester := 0

static func encode_u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

## Box 0x1d's answer (c:0x798667: yes joins box 0x0F's {1, 1}; no writes
## {2} and the zero at [esp+0x18], 0x7986e2).
static func encode_answer(accept: bool) -> PackedByteArray:
	return PackedByteArray([1, 1]) if accept else PackedByteArray([2, 0, 0])

## 0x3080 kind 6's requester, or -1 when the message is not one.
static func requester_of(data: PackedByteArray) -> int:
	if data.size() < 5 or data[0] != REQUEST_KIND:
		return -1
	return data.decode_u32(1)

func _send(op: int, payload: PackedByteArray) -> void:
	if send.is_valid():
		send.call(op, payload)

## 0x70FB for the selected object's uid (0 / the player's own: nothing).
func request(target_uid: int, own_uid: int) -> bool:
	if target_uid <= 0 or target_uid == own_uid:
		return false
	_send(OP_REQUEST, encode_u32(target_uid))
	return true

func leave() -> void:
	_send(OP_LEAVE, PackedByteArray())

func expel(guild_id: int) -> void:
	if guild_id != 0:
		_send(OP_EXPEL, encode_u32(guild_id))

## The box's answer; nothing with no box open.
func answer(accept: bool) -> void:
	if pending_requester == 0:
		return
	pending_requester = 0
	_send(OP_BOX, encode_answer(accept))

## The box's own timer closed it (0x644650): forgotten, unanswered.
func forget_request() -> void:
	pending_requester = 0

func reset_connection() -> void:
	pending_requester = 0

## Registers the replies on `net` (NetClient.register_handler).
func register_with(net: Node) -> void:
	for op in RESULT_OPCODES:
		net.register_handler(op, func(data: PackedByteArray) -> void: handle(op, data))

## 0x3080 kind 6 (true when it was one) or a reply.
func handle(op: int, data: PackedByteArray) -> bool:
	if op == OP_BOX:
		var who := requester_of(data)
		if who < 0:
			return false
		var pname: String = String(player_name.call(who)) if player_name.is_valid() else ""
		var gname: String = String(player_guild.call(who)) if player_guild.is_valid() else ""
		if pname == "" or gname == "":
			print("UnionOps: request from %d dropped (no spawned player with a guild)" % who)
			return true
		pending_requester = who
		request_box.emit(who, gname)
		return true
	if not RESULT_OPCODES.has(op):
		return false
	if data.is_empty():
		return true
	var ok := data[0] == 1
	var code := 0
	if not ok:
		if data[0] != 2 or data.size() < 3:
			return true
		code = data.decode_u16(1)
		notice.emit(GuildOpsNet.error_key(code), [], code)
	result.emit(op, ok, code)
	return true
