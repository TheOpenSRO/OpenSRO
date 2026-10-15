extends SceneTree

## CharacterLockNet (round 788, lane P): the account PIN's payloads, byte for
## byte the server's (server/internal/session/characterlock_test.go,
## TestCharLockCodecs, holds the same bytes).
##
## `godot4 --headless --path client --script res://scripts/net/character_lock_net_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_check(CharacterLockNet.OP_STATUS == 0x0120 and CharacterLockNet.OP_REPLY == 0x0121 \
		and CharacterLockNet.OP_CREATE == 0x0122 and CharacterLockNet.OP_VERIFY == 0x0123 \
		and CharacterLockNet.OP_REMOVE == 0x0124, "the opcodes are the server's 0x0120..0x0124")

	# The verify layout: u16 4 "1234", u8 1, u16 2 "ab" (the server's bytes).
	var v := CharacterLockNet.encode_verify("1234", true, "ab")
	_check(v == PackedByteArray([4, 0, 0x31, 0x32, 0x33, 0x34, 1, 2, 0, 0x61, 0x62]), "verify bytes %s" % v.hex_encode())
	# Not remembering sends no token.
	var nv := CharacterLockNet.encode_verify("1234", false, "ab")
	_check(nv == PackedByteArray([4, 0, 0x31, 0x32, 0x33, 0x34, 0, 0, 0]), "verify without remember: no token (%s)" % nv.hex_encode())
	_check(CharacterLockNet.encode_pin("2580") == PackedByteArray([4, 0, 0x32, 0x35, 0x38, 0x30]), "create / remove bytes")
	_check(CharacterLockNet.encode_status("") == PackedByteArray([0, 0]), "status with no token: an empty string")

	# The reply the server encodes as 02 02 09 00 08 07 00 00: verify, locked,
	# has-pin + locked, 0 left, 1800 s.
	var r := CharacterLockNet.decode_reply(PackedByteArray([2, 2, 9, 0, 0x08, 0x07, 0, 0]))
	_check(r.error == "" and r.op == CharacterLockNet.REPLY_VERIFY and r.code == CharacterLockNet.CODE_LOCKED,
		"reply op and code")
	_check(r.has_pin and r.locked and not r.unlocked and not r.required and r.attempts_left == 0 and r.locked_seconds == 1800,
		"reply flags and numbers")
	var s := CharacterLockNet.decode_reply(CharacterLockNet.encode_reply(0, 0, CharacterLockNet.FLAG_HAS_PIN | CharacterLockNet.FLAG_UNLOCKED, 5, 0))
	_check(s.has_pin and s.unlocked and s.passes() and s.attempts_left == 5, "a status round trip")
	_check(CharacterLockNet.decode_reply(PackedByteArray([0, 0, 1])).error != "", "a short reply is an error, not a status")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
