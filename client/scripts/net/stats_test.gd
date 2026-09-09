extends SceneTree

## Exercises StatsNet against payloads built the way the *server* builds
## them -- by hand, from the field order in server/internal/session/stats.go
## -- rather than through StatsNet's own encoder. A round trip through one
## side's encoder cannot tell whether the two sides agree, which is how ten
## request handlers came to reject every listing the client sent.
##
##   godot4 --headless --path client --script res://scripts/net/stats_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## error string, then gold (s64), hp, max_hp, phys_attack, phys_defense.
func _server_payload(error: String, gold: int, hp: int, max_hp: int, attack: int, defense: int) -> PackedByteArray:
	var err_bytes := error.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, err_bytes.size())
	out.append_array(err_bytes)
	var body := PackedByteArray()
	body.resize(24)
	body.encode_s64(0, gold)
	body.encode_s32(8, hp)
	body.encode_s32(12, max_hp)
	body.encode_s32(16, attack)
	body.encode_s32(20, defense)
	out.append_array(body)
	return out

func _init() -> void:
	var stats := StatsNet.decode_result(_server_payload("", 1000, 87, 100, 12, 34))
	_check(stats.error == "", "no error on a good payload (got %s)" % stats.error)
	_check(stats.gold == 1000, "gold decoded (got %d)" % stats.gold)
	_check(stats.hp == 87 and stats.max_hp == 100, "vitals decoded (got %d/%d)" % [stats.hp, stats.max_hp])
	_check(stats.phys_attack == 12, "physical attack decoded (got %d)" % stats.phys_attack)
	_check(stats.phys_defense == 34, "physical defence decoded (got %d)" % stats.phys_defense)

	var refused := StatsNet.decode_result(_server_payload("no such character on this account", 0, 0, 0, 0, 0))
	_check(refused.error == "no such character on this account",
		"a refusal comes back as its reason (got %s)" % refused.error)

	# Gold is a 64-bit field: a value past 32 bits must survive.
	var rich := StatsNet.decode_result(_server_payload("", 5_000_000_000, 1, 1, 0, 0))
	_check(rich.gold == 5_000_000_000, "gold is 64-bit (got %d)" % rich.gold)

	var truncated := StatsNet.decode_result(PackedByteArray([0, 0, 1, 2, 3]))
	_check(truncated.error != "", "a short payload is reported, not read past")

	# The request is one length-prefixed name and nothing after it, which is
	# the shape every name-only request on this protocol takes.
	var req := StatsNet.encode_request("Aria")
	_check(req.size() == 6, "request is 2 + 4 bytes (got %d)" % req.size())
	_check(req.decode_u16(0) == 4, "request length prefix is the name's length")
	_check(req.slice(2).get_string_from_utf8() == "Aria", "request carries the name")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
