extends SceneTree

## SitState's rules (round 605), run headless:
##   godot4 --headless --path client --script res://scripts/world/sit_state_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _test_press_and_answer() -> void:
	var s := SitState.new()
	_check(s.press(10.0), "N while standing sends a request")
	_check(s.locked(10.5), "movement is held while the request is out")
	_check(not s.press(10.5), "a second N while the first is out sends nothing")
	_check(s.classify(42, false, 10.2) == "self", "the answer to this player's own N is its own")
	_check(s.own_id == 42, "and teaches its id")
	_check(s.answer(4, 10.2) == "sit_down", "sitting down from standing plays 13 then 14")
	_check(s.sitting, "the player sits")
	_check(s.locked(11.6), "movement is held 1.5 s after the answer (the server's CHANGEMOTION)")
	_check(not s.locked(11.71), "and released after it")
	_check(s.answer(4, 12.0) == "sit", "a sit answer while seated plays the loop only")
	_check(s.answer(0, 13.0) == "stand_up", "standing up from sitting plays 15")
	_check(not s.sitting, "the player stands")
	_check(s.answer(0, 20.0) == "stand", "a stand answer while standing plays nothing")

## Round 605's review: a refused N has no answer, so the id-learning window
## must close, or any stranger's 0x30bf would be taken as this player's.
func _test_request_expires() -> void:
	var s := SitState.new()
	s.press(0.0)
	_check(not s.request_pending(SitState.REQUEST_WAIT), "an unanswered request expires after REQUEST_WAIT")
	_check(not s.locked(SitState.REQUEST_WAIT + 0.01), "and stops holding movement")
	_check(s.classify(77, false, 5.0) == "unknown", "a 0x30bf after the request expired is not taken as this player's")
	_check(s.own_id == -1, "and teaches nothing")
	_check(s.classify(77, true, 5.0) == "other", "another body's id is another player's")

## Round 605's review: the client ended its sit on any movement intent while the
## server heard of it only from an OpMove past the send distance, so a one-frame
## tap left the client standing and the server seated. Leaving the seat must
## send the position at once.
func _test_leaving_by_moving_sends() -> void:
	var s := SitState.new()
	s.press(0.0)
	s.classify(1, false, 0.1)
	s.answer(4, 0.1)
	_check(s.leave_by_moving(), "a move while seated must be sent at once")
	_check(not s.sitting, "and the sit ends")
	_check(not s.leave_by_moving(), "a move while standing needs no extra send")

func _test_reset() -> void:
	var s := SitState.new()
	s.press(0.0)
	s.answer(4, 0.1)
	s.reset()
	_check(not s.sitting and not s.locked(0.2), "reset stands the player with nothing held")

func _init() -> void:
	_test_press_and_answer()
	_test_request_expires()
	_test_leaving_by_moving_sends()
	_test_reset()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
