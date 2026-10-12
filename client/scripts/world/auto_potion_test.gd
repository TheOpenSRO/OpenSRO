extends SceneTree

## The auto potion (round 786, AutoPotion): retail's CAutoPotion as READ in
## sro_client.exe -- the wire words (0x82d2e0 / 0x82cf60), the defaults
## (0x8a7bd0), the threshold (0x82cdb0), the checks (0x82d0e0 / 0x82d160 /
## 0x82d1d0), the timers (0xb93320 / 0xb933d0) and Confirm (0x741590).
## Reached by path, so against a client without it this reports FAIL lines.
## No game data.
##   godot4 --headless --path client --script res://scripts/world/auto_potion_test.gd

const PATH := "res://scripts/world/auto_potion.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	if not ResourceLoader.exists(PATH):
		_check(false, "the auto potion exists (auto_potion.gd)")
		_finish()
		return
	var script := load(PATH) as Script
	_wire(script)
	_defaults(script)
	_threshold(script)
	_checks(script)
	_timers(script)
	_confirm(script)
	_finish()

func _wire(script: Script) -> void:
	# HP on at 50 % on F1 "1": 0x8000 | 50 << 8 | 0x11.
	_check(int(script.call("encode_row", true, 50, 1)) == 0xb211, "HP on 50 %% F1 1 -> 0xb211 (got %x)" % int(script.call("encode_row", true, 50, 1)))
	# F1 "0" is slot 10: belt nibble 1, key nibble 10 (the key "0" is 10).
	_check(int(script.call("encode_row", false, 40, 10)) == 0x281a, "off 40 %% F1 0 -> 0x281a (got %x)" % int(script.call("encode_row", false, 40, 10)))
	# F4 "0" is slot 40: 4, 10.
	_check(int(script.call("encode_row", true, 100, 40)) == 0xe44a, "on 100 %% F4 0 -> 0xe44a (got %x)" % int(script.call("encode_row", true, 100, 40)))
	_check(int(script.call("encode_row", false, 0, 0)) == 0, "no slot encodes as 0")
	for slot in range(0, 41):
		var w := int(script.call("encode_row", true, 33, slot))
		var d: Dictionary = script.call("decode_row", w)
		if not (d["enabled"] and d["percent"] == 33 and d["slot"] == slot):
			_check(false, "slot %d round-trips (got %s)" % [slot, str(d)])
			return
	_check(true, "every slot 0..40 round-trips through the word")
	# 0x82cf60's byte arithmetic: a key nibble with a zero belt nibble lands
	# past 40 and is capped there.
	var odd: Dictionary = script.call("decode_row", 0x0003)
	_check(odd["slot"] == 40, "belt nibble 0 with key 3 caps at 40 (got %d)" % odd["slot"])
	var ap = script.new()
	ap.load_bytes(PackedByteArray([0x11, 0xb2, 0x2a, 0xa8, 0x13, 0x00, 0x8a]))
	var v: Dictionary = ap.values()
	_check(v["rows"][0] == {"enabled": true, "percent": 50, "slot": 1}, "HP row read (got %s)" % str(v["rows"][0]))
	_check(v["rows"][1] == {"enabled": true, "percent": 40, "slot": 20}, "MP row read: F2 0 is slot 20 (got %s)" % str(v["rows"][1]))
	_check(v["rows"][2] == {"enabled": false, "percent": 0, "slot": 3}, "abnormal row read (got %s)" % str(v["rows"][2]))
	_check(v["delay_enabled"] and v["delay_ms"] == 1000, "delay 0x8a: on, 1000 ms")
	_check(ap.encode() == PackedByteArray([0x11, 0xb2, 0x2a, 0xa8, 0x13, 0x00, 0x8a]), "the same seven bytes go back out")

func _defaults(script: Script) -> void:
	var ap = script.new()
	ap.load_bytes(PackedByteArray([0, 0, 0, 0, 0, 0, 0]))
	var v: Dictionary = ap.values()
	_check(v["rows"][0] == {"enabled": false, "percent": 50, "slot": 1}, "no settings: HP off, 50 %, slot 1 (0x3211)")
	_check(v["rows"][1] == {"enabled": false, "percent": 50, "slot": 2}, "no settings: MP off, 50 %, slot 2 (0x3212)")
	_check(v["rows"][2] == {"enabled": false, "percent": 0, "slot": 3}, "no settings: abnormal off, slot 3 (0x0013)")
	_check(v["delay_enabled"] and v["delay_ms"] == 1000, "no settings: delay on, 1.0 s (0x8a)")
	var fresh = script.new()
	_check(fresh.delay_ms == 500, "the object is built with a 500 ms delay (0x82d034)")

func _threshold(script: Script) -> void:
	var ap = script.new()
	ap.load_bytes(PackedByteArray([0x11, 0xb2, 0x2a, 0xa8, 0x13, 0x00, 0x8a]))
	ap.on_hp(300, 300)
	ap.on_mp(200, 201)
	_check(ap.rows[0].threshold == 150, "HP 50 %% of 300 is 150 (got %d)" % ap.rows[0].threshold)
	_check(ap.rows[1].threshold == 80, "MP 40 %% of 201 is trunc(80.4) = 80 (got %d)" % ap.rows[1].threshold)
	ap.on_hp(300, 1000)
	_check(ap.rows[0].threshold == 500, "a new maximum recomputes it (0x9d4b60): 500 (got %d)" % ap.rows[0].threshold)
	# float32(0.07) x 100 = 7.0000002 -> 7; float32(0.29) x 100 = 28.9999998 -> 28.
	ap.apply({"rows": [{"enabled": true, "percent": 29, "slot": 1}]})
	ap.on_hp(1000, 100)
	_check(ap.rows[0].threshold == 28, "29 %% of 100 is 28: float32(0.29) is under 0.29 (got %d)" % ap.rows[0].threshold)

## A harness: an AutoPotion whose slots hold potions, recording each use.
func _armed(script: Script, used: Array, can_act := [true], usable := {1: true, 2: true, 3: true}):
	var ap = script.new()
	ap.load_bytes(PackedByteArray([0x11, 0xb2, 0x12, 0xb2, 0x13, 0x80, 0x8a])) # HP 50 % slot 1, MP 50 % slot 2, abnormal on slot 3, 1.0 s
	ap.can_act = func() -> bool: return can_act[0]
	ap.slot_usable = func(s: int) -> bool: return bool(usable.get(s, false))
	ap.use_slot = func(s: int) -> void: used.append(s)
	ap.step(0)
	ap.on_hp(1000, 1000)
	ap.on_mp(1000, 1000)
	return ap

func _checks(script: Script) -> void:
	var used := []
	var ap = _armed(script, used)
	ap.on_hp(501, 1000)
	_check(used.is_empty(), "HP 501 of 1000 (threshold 500): no use")
	ap.on_hp(500, 1000)
	_check(used == [1], "HP 500 <= 500 uses slot 1 (`cmp; ja` -- at the threshold it drinks) (got %s)" % str(used))
	_check(ap.timer_running(0xe) and ap.timer_interval(0xe) == 1000, "timer 0xe armed at the 1.0 s delay")
	ap.on_hp(400, 1000)
	_check(used == [1], "an update while armed does not check again (0x8aa147: ce80)")
	ap.on_mp(100, 1000)
	_check(used == [1, 2], "MP low uses slot 2")
	# Zombie: the HP row skips the use but still arms.
	used.clear()
	var z = _armed(script, used)
	z.on_status(0x20)
	z.on_hp(100, 1000)
	_check(used == [3], "zombie: only the abnormal row's pill, no HP potion (got %s)" % str(used))
	_check(z.timer_running(0xe), "zombie: the HP timer is armed all the same")
	# Stun: the abnormal row skips the use.
	used.clear()
	var s = _armed(script, used)
	s.on_status(0x4000 | 0x10)
	_check(used.is_empty(), "stunned (0x4000): the abnormal row uses nothing (got %s)" % str(used))
	_check(s.timer_running(0x10), "stunned: the abnormal timer is armed")
	# Cannot act: nothing used, timer killed.
	used.clear()
	var dead_flag := [false]
	var d = _armed(script, used, dead_flag)
	d.on_hp(10, 1000)
	_check(used.is_empty() and not d.timer_running(0xe), "unable to act: no use and no timer")
	# A slot without a potion (0x60b1d0 false): no use, but the timer runs.
	used.clear()
	var e = _armed(script, used, [true], {})
	e.on_hp(10, 1000)
	_check(used.is_empty() and e.timer_running(0xe), "an empty / non-potion slot: no use, the timer runs on")
	# A disabled row does nothing.
	used.clear()
	var off = _armed(script, used)
	off.apply({"rows": [{"enabled": false, "percent": 50, "slot": 1}]})
	off.on_hp(10, 1000)
	_check(used.is_empty() and not off.timer_running(0xe), "a disabled row does nothing")

func _timers(script: Script) -> void:
	var used := []
	var ap = _armed(script, used)
	ap.on_hp(100, 1000)
	_check(used == [1], "first use at once")
	ap.step(999)
	_check(used == [1], "nothing at 999 ms")
	ap.step(1000)
	_check(used == [1, 1], "the second at 1000 ms (the 1.0 s delay)")
	ap.step(1500)
	_check(used == [1, 1], "nothing at 1500 ms")
	ap.on_hp(900, 1000)
	ap.step(2000)
	_check(used == [1, 1] and not ap.timer_running(0xe), "above the threshold on the next tick: the timer is killed")
	ap.on_hp(100, 1000)
	_check(used == [1, 1, 1], "the next update below drinks again at once")
	# The delay box unchecked: 500 ms whatever the spin says.
	var u := []
	var nd = _armed(script, u)
	nd.apply({"delay_enabled": false, "delay_ms": 3000})
	nd.on_hp(100, 1000)
	_check(nd.timer_interval(0xe) == 500, "delay unchecked: 500 ms (0x82d126) (got %d)" % nd.timer_interval(0xe))
	# A running timer keeps its interval: 0xb93320 refuses a second add.
	var k := []
	var kt = _armed(script, k)
	kt.on_hp(100, 1000)
	kt.apply({"delay_enabled": true, "delay_ms": 3000})
	kt.step(1000)
	_check(k.size() == 2 and kt.timer_interval(0xe) == 1000, "a delay confirmed while the timer runs: the old interval stays")

func _confirm(script: Script) -> void:
	var ap = script.new()
	ap.load_bytes(PackedByteArray([0x11, 0x32, 0x12, 0x32, 0x13, 0x00, 0x8a]))
	var same: Dictionary = ap.values()
	_check(not ap.apply(same), "Confirm with nothing changed sends nothing")
	ap.on_hp(10, 1000)
	var v: Dictionary = ap.values()
	v["rows"][0]["percent"] = 30
	_check(ap.apply(v), "a changed percent is a change")
	_check(ap.rows[0].threshold == 300, "and recomputes the threshold (0x82d0b0) (got %d)" % ap.rows[0].threshold)
	v = ap.values()
	v["rows"][2]["percent"] = 77
	_check(not ap.apply(v), "the abnormal row has no percent to compare")
	v = ap.values()
	v["delay_ms"] = 2500
	_check(ap.apply(v) and ap.delay_ms == 2500, "a new delay is a change")
	_check(ap.encode()[6] == 0x80 | 25, "2.5 s on encodes as 0x99 (got %x)" % ap.encode()[6])

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
