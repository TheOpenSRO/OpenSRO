extends RefCounted
class_name NpcTalkNet

## The retail NPC interaction (round 727): select 0x7045 -> 0xB045, open
## 0x7046 -> 0xB046, end 0x704B -> 0xB04B, and the client's state around
## them. Every byte is READ from both binaries (docs/protocol/npc_gui.md,
## "The retail NPC protocol (round 727)"; the server's npctalk package
## writes the same layouts). It never touches a window, so it runs headless
## in the tests; World3D opens the talk box, the store and the storage on its
## signals.

const OP_SELECT := 0x7045        # C->S {u32 entity}            (c:0x78f5f0)
const OP_SELECT_RESULT := 0xB045 # S->C                         (c:0x88b200)
const OP_OPEN := 0x7046          # C->S {u32 entity, u8 id}     (c:0x702316)
const OP_OPEN_RESULT := 0xB046
const OP_END := 0x704B           # C->S {u32 entity}            (c:0x78fc20)
const OP_END_RESULT := 0xB04B
const SERVER_OPCODES := [OP_SELECT_RESULT, OP_OPEN_RESULT, OP_END_RESULT]

## The ids the select reply's tail depends on (c:0x88b659, c:0x88b6c3).
const ID_STRUCTURE_UPDATE := 0x1f
const ID_ARENA_MANAGER := 0x21

## The select reply named this NPC and its interaction-id set.
signal selected(entity: int, ids: PackedByteArray)
## The select was refused: {u8 2, u16 code} (3 no target or busy, 4 out of
## reach -- the server's 0x50fd41 / 0x50fd11). The client shows nothing for
## it (round 701's reading of 0x88b200's failure branch).
signal select_refused(code: int)
## An open succeeded: the id echoed (10 comes back as 2, s:0x5104a8).
signal opened(id: int)
signal open_refused(code: int)
signal ended
signal end_refused(code: int)

## Sends a message: Callable(opcode: int, payload: PackedByteArray). World3D
## binds NetClient's sender; the tests capture.
var send: Callable
## The NPC the last select named (0 none) and its set.
var entity := 0
var ids := PackedByteArray()
## A 0x7046 is out and unanswered: the close does not send 0x704B meanwhile
## (the NPC window's close slot 0x7040b0 asks 0x841780, "may send", first).
var open_in_flight := false
## The id of the open in flight (World3D acts on the store's or storage's).
var open_id := 0

func _send(opcode: int, payload: PackedByteArray) -> void:
	if send.is_valid():
		send.call(opcode, payload)

## Wires this state to NetClient's dispatcher (round 711's hook).
func register_with(net: Node) -> void:
	for op in SERVER_OPCODES:
		net.register_handler(op, handle.bind(op))

# --- Codecs ------------------------------------------------------------------

static func encode_entity(e: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, e)
	return b

static func encode_open(e: int, id: int) -> PackedByteArray:
	var b := encode_entity(e)
	b.append(id & 0xff)
	return b

## The select reply: {} on a short or failed message, else
## {"entity", "ids", "structure_word", "npc_byte", "arena_word"} -- the
## client's own read order (c:0x88b400..0x88b6dc): u8 1, u32 entity, u8 n,
## n ids, a u16 when 0x1f is among them, the NPC's u8, a u16 when 0x21 is.
static func decode_select(data: PackedByteArray) -> Dictionary:
	if data.size() < 6 or data[0] != 1:
		return {}
	var n := int(data[5])
	if data.size() < 6 + n:
		return {}
	var id_set := data.slice(6, 6 + n)
	var at := 6 + n
	var out := {"entity": data.decode_u32(1), "ids": id_set, "structure_word": 0, "npc_byte": 0, "arena_word": 0}
	if id_set.has(ID_STRUCTURE_UPDATE):
		if data.size() < at + 2:
			return {}
		out["structure_word"] = data.decode_u16(at)
		at += 2
	if data.size() < at + 1:
		return {}
	out["npc_byte"] = data[at]
	at += 1
	if id_set.has(ID_ARENA_MANAGER):
		if data.size() < at + 2:
			return {}
		out["arena_word"] = data.decode_u16(at)
	return out

## A refusal's code ({u8 2, u16 code}), -1 when the message is not one.
static func refusal_code(data: PackedByteArray) -> int:
	if data.size() >= 3 and data[0] == 2:
		return data.decode_u16(1)
	return -1

# --- Requests ----------------------------------------------------------------

## 0x7045: select an NPC (the click in reach, or a talk approach's arrival).
func select(e: int) -> void:
	_send(OP_SELECT, encode_entity(e))

## 0x7046: open interaction `id` at the selected NPC.
func open(id: int) -> void:
	if entity == 0:
		return
	open_in_flight = true
	open_id = id
	_send(OP_OPEN, encode_open(entity, id))

## 0x704B: end the interaction -- the NPC window's close (its close button,
## the end line, a store line's close) while no open is in flight
## (c:0x7040b0 -> 0x841780), and the store's or storage's close. False when
## nothing was sent.
func end() -> bool:
	if entity == 0 or open_in_flight:
		return false
	_send(OP_END, encode_entity(entity))
	return true

# --- Replies -----------------------------------------------------------------

func handle(data: PackedByteArray, op: int) -> void:
	match op:
		OP_SELECT_RESULT:
			var code := refusal_code(data)
			if code >= 0:
				select_refused.emit(code)
				return
			var s := decode_select(data)
			if s.is_empty():
				return
			entity = int(s["entity"])
			ids = s["ids"]
			selected.emit(entity, ids)
		OP_OPEN_RESULT:
			open_in_flight = false
			var code := refusal_code(data)
			if code >= 0:
				open_refused.emit(code)
				return
			if data.size() >= 2 and data[0] == 1:
				opened.emit(int(data[1]))
		OP_END_RESULT:
			var code := refusal_code(data)
			if code >= 0:
				end_refused.emit(code)
				return
			if data.size() >= 1 and data[0] == 1:
				ended.emit()
