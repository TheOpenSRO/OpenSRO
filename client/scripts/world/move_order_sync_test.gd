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

## Round 749's verification, FP4: the echo timeout stays inside the server's
## banked second (server/internal/world/claim.go AllowanceSeconds 1.0).
## FP1-FP3: a correction is answered with a stop only while a 0x7021 may be in
## flight, and never twice for the same server point -- so no correction can
## loop. And an order that ended unreported awaits no echo any more.
func _test_corrections() -> void:
	_check(MoveOrderSync.ECHO_TIMEOUT_MS <= 1000, "the echo timeout is at most the server's banked second (%d ms)" % MoveOrderSync.ECHO_TIMEOUT_MS)
	var s := MoveOrderSync.new()
	_check(not s.corrected(Vector3(5, 0, 5)), "a correction with nothing in flight is not answered")
	_check(s.rest == Vector3(5, 0, 5) and not s.active, "and the server has the player there, with no leg")
	_check(not s.corrected(Vector3(5, 0, 5)), "nor is a second at the same point")
	s.sent_destination(Vector3(100, 0, 0), 1000)
	_check(s.corrected(Vector3(5, 0, 5)), "a correction while a 0x7021 is in flight is answered with a stop")
	_check(s.pending_ms == -1, "and the order awaits no echo any more")
	_check(not s.corrected(Vector3(5, 0, 5)), "the correction that answers that stop is not answered again")
	s.sent_destination(Vector3(100, 0, 0), 2000)
	s.answered = Vector3(5, 0, 5)
	_check(not s.corrected(Vector3(5, 0, 5)), "never twice for the same server point, even with an order in flight")
	s.sent_destination(Vector3(100, 0, 0), 3000)
	_check(s.corrected(Vector3(9, 0, 9)), "a new order in flight and a new point: answered")
	# A walk that ends at its point before its echo comes.
	s.sent_destination(Vector3(100, 0, 0), 4000)
	s.arrived()
	_check(s.pending_ms == -1, "an order that ended at its point awaits no echo")
	_check(s.decide(false, false, Vector3.INF, Vector3.INF, -1, Vector3(100, 0, 0), 4000 + 5 * MoveOrderSync.ECHO_TIMEOUT_MS) == "",
		"so the ended order is never taken as refused")

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
	# Round 846 (READ, FUN_009e1050 against 50.0, 0xd8f0b0).
	_check(OtherWalk.start_at(Vector3(0, 0, 0), Vector3(40, 0, 0), true) == Vector3.ZERO, "a source 40 off: the drawn body still walks on")
	_check(OtherWalk.start_at(Vector3(0, 0, 0), Vector3(50, 0, 0), true) == Vector3.ZERO, "and at exactly 50")
	_check(OtherWalk.start_at(Vector3(0, 0, 0), Vector3(51, 0, 0), true) == Vector3(51, 0, 0), "a source 51 off: the body is put there")
	_check(OtherWalk.start_at(Vector3(0, 0, 0), Vector3(80, 0, 0), false) == Vector3.ZERO, "no source: the drawn body")

## Round 846 (READ, FUN_009e0550): a body drawn behind the server's mover
## walks faster by its distance to the point over the mover's, at most 3x.
## NEGATIVES: catch_up returning 1.0 always fails "drawn 30 behind on a
## 10-unit step is 3x"; without the cap, "never more than 3x".
func _test_catch_up() -> void:
	var dest := Vector3(100, 0, 0)
	_check(OtherWalk.catch_up(Vector3(90, 0, 0), Vector3(90, 0, 0), true, dest) == 1.0, "drawn on the source: its own speed")
	_check(OtherWalk.catch_up(Vector3(95, 0, 0), Vector3(90, 0, 0), true, dest) == 1.0, "drawn ahead of the source: its own speed")
	_check(is_equal_approx(OtherWalk.catch_up(Vector3(80, 0, 0), Vector3(90, 0, 0), true, dest), 2.0), "drawn 10 behind on a 10-unit leg: 2x")
	_check(is_equal_approx(OtherWalk.catch_up(Vector3(60, 0, 0), Vector3(90, 0, 0), true, dest), 3.0), "drawn 30 behind on a 10-unit step is 3x")
	_check(is_equal_approx(OtherWalk.catch_up(Vector3(0, 0, 0), Vector3(90, 0, 0), true, dest), 3.0), "never more than 3x")
	_check(is_equal_approx(OtherWalk.catch_up(Vector3(98, 0, 0), dest, true, dest), 3.0), "a source on the point itself: 3x")
	_check(OtherWalk.catch_up(Vector3(0, 0, 0), Vector3(90, 0, 0), false, dest) == 1.0, "no source: its own speed")
	_check(is_equal_approx(OtherWalk.catch_up(Vector3(80, 50, 0), Vector3(90, -20, 0), true, dest), 2.0), "on the ground: heights do not count")
	# Two units a frame at 60 frames a second is 120 a second: x2 on 60.
	var leg := OtherWalk.to_point(dest, 60.0, 2.0)
	var r := OtherWalk.step(leg, Vector3(80, 0, 0), 1.0 / 60.0)
	_check(is_equal_approx(float((r["pos"] as Vector3).x), 82.0), "a leg at 60 with x2 walks 2 a frame (%s)" % str(r["pos"]))
	leg["speed"] = 120.0
	r = OtherWalk.step(leg, Vector3(80, 0, 0), 1.0 / 60.0)
	_check(is_equal_approx(float((r["pos"] as Vector3).x), 84.0), "a new run speed keeps the factor (%s)" % str(r["pos"]))

## Round 846: a click near the point the server may still be walking to is
## held back until its leg is over, and goes out then, walk ended or not.
## NEGATIVES: decide without the hold fails "a near click while the server's
## leg runs is held"; without "held", "the held point goes out once the
## server's leg is over".
func _test_held() -> void:
	var s := MoveOrderSync.new()
	var a := Vector3(100, 0, 0)
	s.sent_destination(a, 1000)
	_check(s.server_free_ms == 1000 + MoveOrderSync.ECHO_TIMEOUT_MS, "until its echo, the server may walk the leg for the echo's timeout")
	s.confirm(DestMoveNet.KIND_DESTINATION, a, -1, 1300)
	_check(s.server_free_ms == 1300, "its echo says when the server's leg is over")
	# The walk here lands on the point and ends first.
	_check(s.decide(false, false, Vector3.INF, Vector3.INF, -1, a, 1100) == "ended", "the walk ends on the point")
	s.arrived()
	var b := Vector3(103, 0, 0)
	_check(s.decide(true, false, b, b, -1, a, 1150) == "" and s.held == b, "a near click while the server's leg runs is held")
	_check(s.decide(true, false, b, b, -1, Vector3(102, 0, 0), 1200) == "", "and stays held while it runs")
	_check(s.decide(false, false, Vector3.INF, Vector3.INF, -1, b, 1250) == "", "its walk ended here: still held")
	_check(s.decide(false, false, Vector3.INF, Vector3.INF, -1, b, 1300) == "held", "the held point goes out once the server's leg is over")
	s.sent_destination(s.held, 1300)
	_check(s.held == Vector3.INF and s.active and s.dest == b, "and is the order the server walks")
	# Held while the walk to it still runs: it goes out as the order's own.
	s.confirm(DestMoveNet.KIND_DESTINATION, b, -1, 1400)
	_check(s.decide(false, false, Vector3.INF, Vector3.INF, -1, b, 1350) == "ended", "that walk ends")
	s.arrived()
	var c := Vector3(99, 0, 2)
	_check(s.decide(true, false, c, c, -1, b, 1360) == "", "a second near click is held")
	_check(s.decide(true, false, c, c, -1, Vector3(101, 0, 1), 1400) == "dest", "and sent with its walk still going when the leg is over")
	# A far click is never held, nor one after the leg is over.
	s.sent_destination(Vector3(200, 0, 0), 2000)
	s.confirm(DestMoveNet.KIND_DESTINATION, Vector3(200, 0, 0), -1, 4000)
	s.arrived()
	_check(s.decide(true, false, Vector3(300, 0, 0), Vector3(300, 0, 0), -1, Vector3(200, 0, 0), 2100) == "dest", "a far click goes out at once")
	s.sent_destination(Vector3(300, 0, 0), 2100)
	s.confirm(DestMoveNet.KIND_DESTINATION, Vector3(300, 0, 0), -1, 2200)
	s.arrived()
	_check(s.decide(true, false, Vector3(302, 0, 0), Vector3(302, 0, 0), -1, Vector3(300, 0, 0), 2200) == "dest", "a near click after the leg is over goes out at once")
	# A stop or placement: the server has no leg; a correction drops what is held.
	s.sent_destination(Vector3(400, 0, 0), 3000)
	s.arrived()
	_check(s.decide(true, false, Vector3(402, 0, 0), Vector3(402, 0, 0), -1, Vector3(400, 0, 0), 3010) == "", "held before its echo")
	s.placed(Vector3(400, 0, 0))
	_check(s.decide(true, false, Vector3(402, 0, 0), Vector3(402, 0, 0), -1, Vector3(400, 0, 0), 3020) == "dest", "a placement frees it at once")
	s.sent_destination(Vector3(500, 0, 0), 5000)
	s.arrived()
	s.decide(true, false, Vector3(503, 0, 0), Vector3(503, 0, 0), -1, Vector3(500, 0, 0), 5010)
	s.corrected(Vector3(10, 0, 10))
	_check(s.held == Vector3.INF, "a correction drops the held point")
	# A heading run's echo sets nothing to wait for.
	s.sent_heading(0x4000, 6000)
	_check(s.server_free_ms == 0, "a heading run refuses no destination")

## Round 863: the mover's destination, which the ground click's filter
## measures a far click against (RemoteFacing.click_rule's "snap"), is the
## echo's, not the click's. NEGATIVE: measuring against the click (the
## order sent, `dest`) fails "a far re-click before the first echo turns":
## the body snapped up to 180 degrees in one frame (round 863, MEASURED).
func _test_mover_dest() -> void:
	var s := MoveOrderSync.new()
	var pos := Vector3.ZERO
	_check(s.mover_dest == Vector3.INF, "no echo yet: the mover holds no destination")
	# Running north to a far point, echoed.
	s.sent_destination(Vector3(0, 0, -200), 0)
	s.confirm(DestMoveNet.KIND_DESTINATION, Vector3(0, 0, -200), -1)
	_check(s.mover_dest == Vector3(0, 0, -200), "the echo sets the mover's destination")
	# A far click straight behind, then a second within 5 degrees of it before
	# the first click's echo: measured against the mover's (north) -- a turn.
	var behind := Vector3(0, 0, 150)
	s.sent_destination(behind, 100)
	_check(RemoteFacing.click_rule(true, Vector3(4, 0, 150) - pos, s.mover_dest - pos) == "turn",
		"a far re-click before the first echo turns (the mover still holds the old order)")
	_check(RemoteFacing.click_rule(true, Vector3(4, 0, 150) - pos, s.dest - pos) == "snap",
		"(measured against the click sent it would have snapped)")
	# After the echo the same re-click snaps, as the original's does (MEASURED:
	# 90.7 degrees in one frame).
	s.confirm(DestMoveNet.KIND_DESTINATION, behind, -1)
	_check(RemoteFacing.click_rule(true, Vector3(4, 0, 150) - pos, s.mover_dest - pos) == "snap",
		"after the echo a far re-click within 5 degrees snaps (FUN_009e04b0)")
	s.mover_snapped(Vector3(4, 0, 150))
	_check(s.mover_dest == Vector3(4, 0, 150), "the snap re-aims the mover at the click")
	# An echo of an older order still lands in the mover (FUN_009e0550).
	s.confirm(DestMoveNet.KIND_DESTINATION, Vector3(0, 0, 150), -1)
	_check(s.mover_dest == Vector3(0, 0, 150), "every destination echo is the mover's")
	s.arrived()
	_check(s.mover_dest == Vector3(0, 0, 150), "an arrival keeps it (FUN_009e0e60 clears +0x84 only)")
	s.confirm(DestMoveNet.KIND_HEADING, Vector3.ZERO, 0x4000)
	_check(s.mover_dest == Vector3.INF, "a heading echo has no point")
	s.confirm(DestMoveNet.KIND_DESTINATION, Vector3(0, 0, 150), -1)
	s.placed(Vector3(1, 0, 1))
	_check(s.mover_dest == Vector3.INF, "a stop or placement clears it")

func _init() -> void:
	_test_click_walk()
	_test_heading_run()
	_test_flush()
	_test_echo()
	_test_corrections()
	_test_other_walk()
	_test_catch_up()
	_test_held()
	_test_mover_dest()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
