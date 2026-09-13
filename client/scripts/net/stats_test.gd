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

## The full 48-byte body: the 24 above, then level, exp (s64), exp_to_next
## (s64), skill_points -- the server's field order in stats.go.
func _server_payload_full(gold: int, hp: int, max_hp: int, level: int, exp: int, to_next: int, sp: int) -> PackedByteArray:
	var out := _server_payload("", gold, hp, max_hp, 0, 0)
	var tail := PackedByteArray()
	tail.resize(24)
	tail.encode_s32(0, level)
	tail.encode_s64(4, exp)
	tail.encode_s64(12, to_next)
	tail.encode_s32(20, sp)
	out.append_array(tail)
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

	# The appended level/exp/SP fields decode, and drive the EXP gauge.
	var lvl := StatsNet.decode_result(_server_payload_full(500, 94, 140, 2, 130, 470, 14))
	_check(lvl.level == 2, "level decoded (got %d)" % lvl.level)
	_check(lvl.exp == 130 and lvl.exp_to_next == 470, "exp/exp_to_next decoded (got %d/%d)" % [lvl.exp, lvl.exp_to_next])
	_check(lvl.skill_points == 14, "skill points decoded (got %d)" % lvl.skill_points)
	_check(abs(lvl.exp_percent() - (130.0 / 470.0 * 100.0)) < 0.01, "exp_percent computes the gauge fill (got %.2f)" % lvl.exp_percent())
	# An old 24-byte result still decodes, with the new fields at defaults.
	var old := StatsNet.decode_result(_server_payload("", 1, 2, 3, 0, 0))
	_check(old.error == "" and old.level == 1 and old.exp_to_next == 0, "an old 24-byte result decodes with default level/exp")

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
