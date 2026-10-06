extends SceneTree

## MoveOrderSync and OtherWalk (round 749): what the player's own walk tells the
## server now that a walk is retail's 0x7021, and how another player's body
## walks the 0xB021 it is told of.
## `godot4 --headless --path client --script res://scripts/world/move_order_sync_test.gd`
##
## NEGATIVES: a resend on every tick of an approach (decide without the
## NEAR_DESTINATION test) fails "a point moved 4 is not sent again"; a stop on
## every arrival (no ARRIVE_SLACK) fails "a walk that ends 2 short of the point
## says nothing"; OtherWalk.step without the cut fails "never passes its point".

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## decide with the target already on whole units (its own truncation) at 0 ms.
func _dec(s: MoveOrderSync, has: bool, run: bool, target: Vector3, wire: int, pos: Vector3) -> String:
	return s.decide(has, run, target, target, wire, pos, 0)

func _test_click_walk() -> void:
	var s := MoveOrderSync.new()
	var pos := Vector3(0, 0, 0)
	var d := Vector3(100, 0, 0)
	_check(_dec(s, false, false, Vector3.ZERO, -1, pos) == "", "no order, nothing")
	_check(_dec(s, true, false, d, -1, pos) == "dest", "a click sends its 0x7021")
	s.sent_destination(d)
	_check(_dec(s, true, false, d, -1, Vector3(10, 0, 0)) == "", "the same point is not sent again")
	_check(_dec(s, true, false, d + Vector3(3, 0, -2.9), -1, Vector3(10, 0, 0)) == "", "a point moved 4 is not sent again (the server's 5.0)")
	# Round 749's review, F5: the server refuses a destination within 5.0,
	# `<=`, of its own, both truncated: exactly 5 is not sent, past it is.
	_check(_dec(s, true, false, d + Vector3(0, 0, 5), -1, Vector3(10, 0, 0)) == "", "a point moved exactly 5 is not sent (the server's <=)")
	_check(_dec(s, true, false, d + Vector3(0, 0, 6), -1, Vector3(10, 0, 0)) == "dest", "a point moved 6 is")
	_check(s.decide(true, false, d + Vector3(0, 0, 5.9), d + Vector3(0, 0, 5), -1, Vector3(10, 0, 0), 0) == "",
		"a point 5.9 off that the wire truncates to 5.0 is not sent")
	s.sent_destination(d + Vector3(0, 0, 5))
	# The walk ends within its stop distance of the point: nothing.
	_check(_dec(s, false, false, Vector3.ZERO, -1, Vector3(98, 0, 5)) == "ended", "a walk that ends 2 short of the point says nothing")
	s.arrived()
	_check(not s.active and s.rest == Vector3(100, 0, 5), "and the server is taken to stand on the point")
	_check(_dec(s, false, false, Vector3.ZERO, -1, Vector3(98, 0, 5)) == "", "nothing more after it")
	# A wall: the walk ends well short.
	_check(_dec(s, true, false, Vector3(300, 0, 5), -1, Vector3(98, 0, 5)) == "dest", "a new click from rest is sent")
	s.sent_destination(Vector3(300, 0, 5))
	_check(_dec(s, false, false, Vector3.ZERO, -1, Vector3(150, 0, 5)) == "stop", "a walk a wall ended 150 short reports its stop")
	s.placed(Vector3(150, 0, 5))
	_check(s.rest == Vector3(150, 0, 5) and not s.active, "the stop is where the server has it")
	_check(_dec(s, true, false, Vector3(150.2, 0, 5), -1, Vector3(150, 0, 5)) == "", "an order closer than 0.5 is not sent")

func _test_heading_run() -> void:
	var s := MoveOrderSync.new()
	var pos := Vector3(1, 0, 1)
	_check(_dec(s, true, true, Vector3.ZERO, 0x4000, pos) == "heading", "a sky click sends the heading form")
	s.sent_heading(0x4000)
	_check(_dec(s, true, true, Vector3.ZERO, 0x4000, pos) == "", "the same heading is not sent again")
	_check(_dec(s, true, true, Vector3.ZERO, 0x4100, pos) == "heading", "a new heading is")
	s.sent_heading(0x4100)
	_check(_dec(s, false, false, Vector3.ZERO, -1, pos) == "stop", "a heading run's end is always reported (it has no point)")
	_check(s.flush(pos) == "stop", "and flushed")

func _test_flush() -> void:
	var s := MoveOrderSync.new()
	_check(s.flush(Vector3.ZERO) == "stop", "nothing known: the position goes out")
	s.placed(Vector3(5, 0, 5))
	_check(s.flush(Vector3(5.3, 1, 5)) == "", "within 0.5 of the server's: nothing")
	_check(s.flush(Vector3(6, 0, 5)) == "stop", "a unit off: the stop")
	s.sent_destination(Vector3(50, 0, 5))
	_check(s.flush(Vector3(49.8, 0, 5)) == "", "on the point being walked to: nothing")
	_check(s.flush(Vector3(40, 0, 5)) == "stop", "short of it (an approach in reach): the stop")

## Round 749's review, F3: an order with no echo within ECHO_TIMEOUT_MS is
## refused; its echo confirms it; an older order's echo does not.
func _test_echo() -> void:
	var s := MoveOrderSync.new()
	s.sent_destination(Vector3(100, 0, 0), 1000)
	_check(s.decide(true, false, Vector3(100, 0, 0), Vector3(100, 0, 0), -1, Vector3.ZERO, 1000 + MoveOrderSync.ECHO_TIMEOUT_MS) == "",
		"waiting for the echo")
	_check(s.decide(true, false, Vector3(100, 0, 0), Vector3(100, 0, 0), -1, Vector3.ZERO, 1001 + MoveOrderSync.ECHO_TIMEOUT_MS) == "unconfirmed",
		"no echo past the timeout: refused")
	s.sent_destination(Vector3(100, 0, 0), 5000)
	s.confirm(DestMoveNet.KIND_DESTINATION, Vector3(40, 0, 0), -1)
	_check(s.pending_ms == 5000, "an echo of another point confirms nothing")
	s.confirm(DestMoveNet.KIND_DESTINATION, Vector3(100, 0, 0), -1)
	_check(s.pending_ms == -1, "its own echo confirms it")
	_check(s.decide(true, false, Vector3(100, 0, 0), Vector3(100, 0, 0), -1, Vector3.ZERO, 99999) == "", "and nothing times out")
	s.sent_heading(0x4000, 0)
	s.confirm(DestMoveNet.KIND_HEADING, Vector3.ZERO, 0x4000)
	_check(s.pending_ms == -1, "a heading echo confirms the run")

func _test_other_walk() -> void:
	var leg := OtherWalk.to_point(Vector3(100, 7, 0), 50.0)
	var at := Vector3.ZERO
	var frames := 0
	var passed := false
	while frames < 200:
		var r := OtherWalk.step(leg, at, 1.0 / 60.0)
		at = r["pos"]
		frames += 1
		if at.x > 100.0 + 1e-4:
			passed = true
		if bool(r["done"]):
			break
	_check(not passed and at == Vector3(100, 0, 0), "a walk never passes its point and lands on it, its height the caller's (%s)" % str(at))
	_check(frames == 120 or frames == 121, "100 units at 50 a second is 120 frames, give or take the float (%d)" % frames)
	var half := OtherWalk.step(OtherWalk.to_point(Vector3(100, 0, 0), 50.0), Vector3.ZERO, 0.5)
	_check(is_equal_approx(float((half["pos"] as Vector3).x), 25.0) and not bool(half["done"]), "half a second is 25 units")
	# Wire angle 0 is heading pi/2: +x (RemoteFacing).
	var run := OtherWalk.on_heading(0, 50.0)
	var r2 := OtherWalk.step(run, Vector3(1, 2, 3), 1.0)
	_check((r2["pos"] as Vector3).is_equal_approx(Vector3(51, 2, 3)) and not bool(r2["done"]), "a heading run at wire 0 runs +x and never ends (%s)" % str(r2["pos"]))
	_check(OtherWalk.facing(run, Vector3.ZERO).is_equal_approx(Vector3(1, 0, 0)), "and faces +x")
	_check(OtherWalk.start_at(Vector3(0, 0, 0), Vector3(10, 0, 0), true) == Vector3.ZERO, "a source 10 off: the drawn body walks on")
	_check(OtherWalk.start_at(Vector3(0, 0, 0), Vector3(40, 0, 0), true) == Vector3(40, 0, 0), "a source 40 off: the body is put there")
	_check(OtherWalk.start_at(Vector3(0, 0, 0), Vector3(40, 0, 0), false) == Vector3.ZERO, "no source: the drawn body")

func _init() -> void:
	_test_click_walk()
	_test_heading_run()
	_test_flush()
	_test_echo()
	_test_other_walk()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
