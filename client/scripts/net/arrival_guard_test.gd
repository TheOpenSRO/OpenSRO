extends SceneTree

## Round 786 (part): the protection after a teleport, the client's half
## (ArrivalGuard; docs/protocol/arrival_guard.md).
##
## - The loading-done report (0x3012) goes only when the load is over: armed by
##   an arrival, held while the loading screen is up or a cell is left to
##   build, sent once (FUN_0084c060's order: the screen's windows go, then the
##   send, READ), and not again until the next arrival arms it.
## - NetClient keeps this player's own body mode from 0x30BF kind 4, resets it
##   at an arrival, and while it is 2 refuses its own skills and duel blows
##   without sending them (READ, 0x81ba58 / 0x791fda).
## - The screen flash is this player's on any non-zero mode (0x8a826f).
## - The server's refusal text shows as the archive's own key.
##
## `godot4 --headless --path client --script res://scripts/net/arrival_guard_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _state(id: int, kind: int, value: int) -> Packet:
	var d := PackedByteArray()
	d.resize(7 if value == 1 else 6)
	d.encode_u32(0, id)
	d.encode_u8(4, kind)
	d.encode_u8(5, value)
	return Packet.new(WorldNet.OP_STATE_CHANGE, d)

class FakeTable:
	extends RefCounted
	var rows := {}
	func has(k: String) -> bool:
		return rows.has(k)
	func get_text(k: String, _d: String = "") -> String:
		return rows.get(k, "")

func _initialize() -> void:
	# --- the report's timing ---
	var sends := [0]
	var r := ArrivalGuard.ReadyReport.new(func() -> void: sends[0] += 1)
	_check(not r.loading_done(false, 0) and sends[0] == 0, "nothing is sent before an arrival arms the report")
	r.arm("zone change")
	_check(not r.loading_done(true, 0) and sends[0] == 0, "held while the loading screen is up")
	_check(not r.loading_done(false, 3) and sends[0] == 0, "held while cells are left to build")
	_check(r.loading_done(false, 0) and sends[0] == 1, "sent when the screen is down and nothing is left")
	_check(not r.loading_done(false, 0) and sends[0] == 1, "sent once per arrival")
	r.arm("teleport")
	_check(r.loading_done(false, 0) and sends[0] == 2 and r.why == "teleport", "the next arrival arms it again")
	_check(WorldNet.OP_READY_TO_PLAY == 0x3012, "the report is retail's 0x3012")

	# --- the own body mode and the client's refusals ---
	var net: Node = (load("res://scripts/net/net_client.gd") as GDScript).new()
	net.set("own_character_id", 41)
	var refused: Array = []
	net.untouchable_refused.connect(func(what: String) -> void: refused.append(what))
	net.call("_dispatch", _state(41, WorldNet.STATE_KIND_BODY_MODE, 2))
	_check(int(net.get("own_body_mode")) == 2, "this player's body mode 2 is kept (own %d)" % int(net.get("own_body_mode")))
	net.call("_dispatch", _state(77, WorldNet.STATE_KIND_BODY_MODE, 2))
	net.call("_dispatch", _state(41, WorldNet.STATE_KIND_MOTION, 4))
	_check(int(net.get("own_body_mode")) == 2, "another body's mode and a motion leave it")
	net.call("use_skill", "Aria", 3, 9)
	net.call("duel_attack", "Aria")
	_check(refused == ["skill", "duel"], "a skill and a duel blow are refused locally in mode 2 (%s)" % [refused])
	net.call("_dispatch", _state(41, WorldNet.STATE_KIND_BODY_MODE, 0))
	_check(int(net.get("own_body_mode")) == 0, "its end (0) lifts it")
	refused.clear()
	net.call("use_skill", "Aria", 3, 9) # not connected: skipped, but not refused
	_check(refused.is_empty(), "no refusal after the end")
	net.call("_dispatch", _state(41, WorldNet.STATE_KIND_BODY_MODE, 2))
	# An ok OpChangeZoneResult: ok, no reason, the zone, a point, no others.
	var czr := PackedByteArray([1, 0, 0])
	var zone := "donwhang".to_utf8_buffer()
	czr.append_array(PackedByteArray([zone.size(), 0]))
	czr.append_array(zone)
	czr.resize(czr.size() + 14)
	net.call("_dispatch", Packet.new(WorldNet.OP_CHANGE_ZONE_RESULT, czr))
	_check(int(net.get("own_body_mode")) == 0, "an arrival starts the own body mode over")
	net.free()

	# --- the rules ---
	_check(ArrivalGuard.refuses_skill(2) and not ArrivalGuard.refuses_skill(0) and not ArrivalGuard.refuses_skill(1),
		"skills refused in mode 2 only")
	_check(ArrivalGuard.flashes(true, 2) and ArrivalGuard.flashes(true, 1) and not ArrivalGuard.flashes(true, 0) \
		and not ArrivalGuard.flashes(false, 2), "the flash is this player's, any non-zero mode")
	var t := FakeTable.new()
	_check(ArrivalGuard.error_line(ArrivalGuard.SERVER_REFUSAL, t) == ArrivalGuard.FALLBACK_TEXT,
		"the server's refusal without the key: the fallback")
	t.rows[ArrivalGuard.REFUSAL_KEY] = "archive words"
	_check(ArrivalGuard.error_line(ArrivalGuard.SERVER_REFUSAL, t) == "archive words",
		"the server's refusal in the archive's words")
	_check(ArrivalGuard.error_line("too far", t) == "too far", "other errors pass through")
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(0 if _failures == 0 else 1)
