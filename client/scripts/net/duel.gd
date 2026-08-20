extends RefCounted
class_name DuelNet

## Opcodes and payload encoding for the PvP duel system, mirroring
## server/internal/session (duel.go). All require a prior successful
## enter_world (target resolution happens server-side via world.Hub, the
## same as whispers).

const OP_CHALLENGE := 0x00C0         # client -> server
const OP_CHALLENGE_RESULT := 0x00C1  # server -> client, ack to the challenger
const OP_INVITE := 0x00C2            # server -> client, direct to the target
const OP_RESPOND := 0x00C3           # client -> server
const OP_RESPOND_RESULT := 0x00C4    # server -> client, ack to the responder
const OP_STARTED := 0x00C5           # server -> client, direct to both sides
const OP_DECLINED := 0x00C6          # server -> client, direct to the challenger
const OP_ATTACK := 0x00C7            # client -> server
const OP_ATTACK_RESULT := 0x00C8     # server -> client, direct to the attacker
const OP_OPPONENT_DAMAGED := 0x00C9  # server -> client, direct to the defender
const OP_ENDED := 0x00CA             # server -> client, direct to both sides

## Result of decode_invite().
class Invite:
	var challenger_name: String

## Result of decode_started().
class Started:
	var opponent_name: String

## Result of decode_declined().
class Declined:
	var target_name: String

## Result of decode_attack_result().
class AttackResult:
	var error: String
	var damage: int
	var opponent_hp: int
	var opponent_died: bool

## Result of decode_opponent_damaged().
class OpponentDamaged:
	var damage: int
	var remaining_hp: int

## Result of decode_ended().
class Ended:
	var winner_name: String

static func _encode_string(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

## Encodes an OpDuelChallenge request.
static func encode_challenge(character_name: String, target_name: String) -> PackedByteArray:
	var out := _encode_string(character_name)
	out.append_array(_encode_string(target_name))
	return out

## Encodes an OpDuelRespond request.
static func encode_respond(character_name: String, challenger_name: String, accept: bool) -> PackedByteArray:
	var out := _encode_string(character_name)
	out.append_array(_encode_string(challenger_name))
	out.append(1 if accept else 0)
	return out

## Encodes an OpDuelAttack request: just the attacker's own character name.
static func encode_attack(character_name: String) -> PackedByteArray:
	return _encode_string(character_name)

## Decodes an OpDuelInvite payload.
static func decode_invite(data: PackedByteArray) -> Invite:
	if data.size() < 2:
		return null
	var name_len := data.decode_u16(0)
	if 2 + name_len > data.size():
		return null
	var invite := Invite.new()
	invite.challenger_name = data.slice(2, 2 + name_len).get_string_from_utf8()
	return invite

## Decodes an OpDuelStarted payload.
static func decode_started(data: PackedByteArray) -> Started:
	if data.size() < 2:
		return null
	var name_len := data.decode_u16(0)
	if 2 + name_len > data.size():
		return null
	var started := Started.new()
	started.opponent_name = data.slice(2, 2 + name_len).get_string_from_utf8()
	return started

## Decodes an OpDuelDeclined payload.
static func decode_declined(data: PackedByteArray) -> Declined:
	if data.size() < 2:
		return null
	var name_len := data.decode_u16(0)
	if 2 + name_len > data.size():
		return null
	var declined := Declined.new()
	declined.target_name = data.slice(2, 2 + name_len).get_string_from_utf8()
	return declined

## Decodes an OpDuelAttackResult payload.
static func decode_attack_result(data: PackedByteArray) -> AttackResult:
	var result := AttackResult.new()
	if data.size() < 2:
		result.error = "truncated"
		return result

	var error_len := data.decode_u16(0)
	var offset := 2 + error_len
	if offset > data.size():
		result.error = "truncated error field"
		return result
	result.error = data.slice(2, offset).get_string_from_utf8()
	if result.error != "":
		return result

	if offset + 9 > data.size():
		result.error = "truncated result fields"
		return result
	result.damage = data.decode_u32(offset)
	result.opponent_hp = data.decode_u32(offset + 4)
	result.opponent_died = data[offset + 8] != 0
	return result

## Decodes an OpDuelOpponentDamaged payload.
static func decode_opponent_damaged(data: PackedByteArray) -> OpponentDamaged:
	if data.size() < 8:
		return null
	var d := OpponentDamaged.new()
	d.damage = data.decode_u32(0)
	d.remaining_hp = data.decode_u32(4)
	return d

## Decodes an OpDuelEnded payload.
static func decode_ended(data: PackedByteArray) -> Ended:
	if data.size() < 2:
		return null
	var name_len := data.decode_u16(0)
	if 2 + name_len > data.size():
		return null
	var ended := Ended.new()
	ended.winner_name = data.slice(2, 2 + name_len).get_string_from_utf8()
	return ended
