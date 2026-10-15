extends RefCounted
class_name CharacterLockNet

## The account PIN, "Character Lock", on the wire (round 788, lane P). The
## feature is OURS -- the retail game has no PIN -- and so are these opcodes
## and payloads; the server's twin is server/internal/session/characterlock.go
## and docs/protocol/pin.md is the reference. Strings are a u16 length and
## ASCII bytes, as the lobby's names.

const OP_STATUS := 0x0120  # client -> server: str device token ("" for none)
const OP_REPLY := 0x0121   # server -> client: u8 op, u8 code, u8 flags, u8 attempts left, u32 seconds locked
const OP_CREATE := 0x0122  # client -> server: str PIN
const OP_VERIFY := 0x0123  # client -> server: str PIN, u8 remember, str device token
const OP_REMOVE := 0x0124  # client -> server: str PIN

## The reply's op byte.
const REPLY_STATUS := 0
const REPLY_CREATE := 1
const REPLY_VERIFY := 2
const REPLY_REMOVE := 3

## The reply's code byte (charlock.Code).
const CODE_OK := 0
const CODE_WRONG_PIN := 1
const CODE_LOCKED := 2
const CODE_PIN_EXISTS := 3
const CODE_NO_PIN := 4
const CODE_BAD_FORMAT := 5
const CODE_NOT_LOGGED_IN := 6
const CODE_FAILED := 7

## The reply's flags byte.
const FLAG_HAS_PIN := 1
const FLAG_REQUIRED := 2
const FLAG_UNLOCKED := 4
const FLAG_LOCKED := 8

## A 0x0121 reply.
class Reply:
	var op: int = 0
	var code: int = 0
	var has_pin := false
	var required := false
	var unlocked := false
	var locked := false
	var attempts_left: int = 0
	var locked_seconds: int = 0
	var error: String = ""

	## Whether the lobby's Start / Delete / Restore would pass the server's
	## gate now (charlock.Service.Allows).
	func passes() -> bool:
		return unlocked

static func _str(out: PackedByteArray, s: String) -> void:
	var b := s.to_ascii_buffer()
	out.append(b.size() & 0xff)
	out.append((b.size() >> 8) & 0xff)
	out.append_array(b)

static func encode_status(token: String) -> PackedByteArray:
	var out := PackedByteArray()
	_str(out, token)
	return out

static func encode_pin(pin: String) -> PackedByteArray:
	var out := PackedByteArray()
	_str(out, pin)
	return out

static func encode_verify(pin: String, remember: bool, token: String) -> PackedByteArray:
	var out := PackedByteArray()
	_str(out, pin)
	out.append(1 if remember else 0)
	_str(out, token if remember else "")
	return out

static func decode_reply(data: PackedByteArray) -> Reply:
	var r := Reply.new()
	if data.size() < 8:
		r.error = "truncated (%d bytes)" % data.size()
		return r
	r.op = data[0]
	r.code = data[1]
	var flags: int = data[2]
	r.has_pin = flags & FLAG_HAS_PIN != 0
	r.required = flags & FLAG_REQUIRED != 0
	r.unlocked = flags & FLAG_UNLOCKED != 0
	r.locked = flags & FLAG_LOCKED != 0
	r.attempts_left = data[3]
	r.locked_seconds = data.decode_u32(4)
	return r

## The server's own reply bytes (the tests' fake server).
static func encode_reply(op: int, code: int, flags: int, attempts_left: int, locked_seconds: int) -> PackedByteArray:
	var out := PackedByteArray([op, code, flags, attempts_left, 0, 0, 0, 0])
	out.encode_u32(4, locked_seconds)
	return out
