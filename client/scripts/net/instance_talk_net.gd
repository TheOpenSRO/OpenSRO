extends RefCounted
class_name InstanceTalkNet

## Round 869 (lane C1): the instance NPCs' talk-line messages -- the exit NPC
## (interaction 0x29) and the party recall NPC (interaction 0x27) -- byte for
## byte as sro_client.exe sends and reads them (docs/protocol/game_worlds.md 5,
## forgotten_world.md 8). Codecs only; RecallFlow (world/recall_flow.gd) acts
## on them. Labels: READ (`c:` sro_client.exe), INFERRED, OURS, OPEN.
##
## READ, the senders (each a Net_SendRequestPacket + MsgStreamBuffer writes):
## - 0x751D {u32 npc}: CIF_NPCTalk::FUN_008234f0, the talk line of type 0x3e
##   (CIF_NPCTalk::FUN_007020c0 case 0x3e, c:0x703b47..0x703b62, the talk
##   window's NPC); the window is left as it is (the case returns 1);
## - 0x7519 {u32 npc}: CIF_NPCTalk::FUN_00823290, the line of type 0x3d
##   (case 0x3d, c:0x703b22..0x703b3d), likewise;
## - 0x751A {u32 char id}: SendCallUserMsg_51a (c:0x823350), from the summon
##   window's button 7 (c:0x607c80, the selected row's entry +0x00);
## - 0x751C {u32 requester, u32 own id, u8 1 | 0}: SendSummonPartyUserMsg_51c
##   (c:0x823410), from the confirm box's answer (c:0x6076d0: +0x7c8 the push's
##   requester, the party object's +0x18 -- [0xeeebd8 + 0x20] + 0x18, the own
##   JID 0xB060 writes at c:0x880059..0x880064 -- and Yes as 1).
## READ, the readers (registered at c:0x8a45d5..0x8a4661):
## - 0xB519 c:0x89a590: u8 result; 1 -> u8 n, n x {u32 char id, u8 state, u8
##   level, u16 minutes} (c:0x89a617..0x89a64a, handed to c:0x609d60 in that
##   order); else u16 code -> category 0xd (c:0x89a686..0x89a6aa);
## - 0x751A c:0x89f010 (the push to a member): u32 requester, u32, u32, the
##   name (c:0x4f7a70: u16 length, ANSI bytes) -> c:0x608a60(requester, u32 2);
## - 0xB51A c:0x89a6c0: u8 result; != 1 -> u16 code -> category 0x23;
## - 0xB51C c:0x89a710: u8 result; 2 -> u16 code -> category 0xd;
## - 0xB51D c:0x89a760: u8 result; != 1 -> u16 code -> category 1.
## Every refusal goes to the error dispatcher with colour 0xffdbc99b
## (FUN_00778190(cat, code, 0xffdbc99b, 0, 1)).

const OP_EXIT := 0x751D
const OP_EXIT_ACK := 0xB51D
const OP_RECALL_LIST := 0x7519
const OP_RECALL_LIST_ACK := 0xB519
const OP_SUMMON := 0x751A
const OP_SUMMON_ACK := 0xB51A
const OP_ANSWER := 0x751C
const OP_ANSWER_ACK := 0xB51C
const SERVER_OPCODES := [OP_EXIT_ACK, OP_RECALL_LIST_ACK, OP_SUMMON, OP_SUMMON_ACK, OP_ANSWER_ACK]

## The error dispatcher's category of each reply (READ, above).
const CATEGORY := {OP_EXIT_ACK: 1, OP_RECALL_LIST_ACK: 0xd, OP_SUMMON_ACK: 0x23, OP_ANSWER_ACK: 0xd}

## A row's state byte (READ c:0x608780): 1 done, 2 can be summoned, 3 cannot.
const STATE_DONE := 1
const STATE_POSSIBLE := 2
const STATE_IMPOSSIBLE := 3

static func encode_u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v & 0xffffffff)
	return b

## 0x751D / 0x7519: the talk window's NPC.
static func encode_npc(npc: int) -> PackedByteArray:
	return encode_u32(npc)

## 0x751A: the member to summon.
static func encode_summon(char_id: int) -> PackedByteArray:
	return encode_u32(char_id)

## 0x751C: the push's requester, the own JID, Yes as 1.
static func encode_answer(requester: int, own_id: int, accept: bool) -> PackedByteArray:
	var b := encode_u32(requester)
	b.append_array(encode_u32(own_id))
	b.append(1 if accept else 0)
	return b

## One row of 0xB519.
class Entry:
	var char_id := 0
	var state := 0
	## The u8 the row prints with "%d" under the PARAM_LV header (c:0x608984;
	## the header's key is MEASURED in the .2dt): INFERRED the member's level.
	var level := 0
	var minutes := 0

## 0xB519: {"ok": bool, "code": int, "entries": Array[Entry]}; {} when short.
## Trailing bytes are left alone, as the client reads only what it needs.
static func decode_list(data: PackedByteArray) -> Dictionary:
	if data.size() < 1:
		return {}
	if data[0] != 1:
		if data.size() < 3:
			return {}
		return {"ok": false, "code": data.decode_u16(1), "entries": []}
	if data.size() < 2:
		return {}
	var n := int(data[1])
	if data.size() < 2 + n * 8:
		return {}
	var out: Array[Entry] = []
	for i in n:
		var at := 2 + i * 8
		var e := Entry.new()
		e.char_id = data.decode_u32(at)
		e.state = data[at + 4]
		e.level = data[at + 5]
		e.minutes = data.decode_u16(at + 6)
		out.append(e)
	return {"ok": true, "code": 0, "entries": out}

## 0x751A from the server (the member's push): {"requester", "second",
## "third", "name"}; {} when short. The second u32 is kept at +0x7cc and
## never sent (READ c:0x6076d0 sends the party's own JID); the third is read
## and dropped (c:0x89f010); what either means is OPEN.
static func decode_push(data: PackedByteArray) -> Dictionary:
	if data.size() < 14:
		return {}
	var n := data.decode_u16(12)
	if data.size() < 14 + n:
		return {}
	return {"requester": data.decode_u32(0), "second": data.decode_u32(4), "third": data.decode_u32(8),
		"name": data.slice(14, 14 + n).get_string_from_ascii()}

## A {u8 result, u16 code} reply's refusal code, -1 when it is the success
## (or too short to hold a code). `only_two`: 0xB51C reads the code only on 2
## (c:0x89a710); the others on anything but 1.
static func refusal_code(data: PackedByteArray, only_two: bool = false) -> int:
	if data.size() < 1 or data[0] == 1:
		return -1
	if only_two and data[0] != 2:
		return -1
	if data.size() < 3:
		return -1
	return data.decode_u16(1)
