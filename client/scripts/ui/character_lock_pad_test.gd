extends SceneTree

## The Character Lock window (round 788, lane P): CharacterLockPad's state
## machine, the window built over it (no archive: plain controls), and the
## device token's file.
##
## `godot4 --headless --path client --script res://scripts/ui/character_lock_pad_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _type(pad: CharacterLockPad, digits: String) -> String:
	var last := ""
	for c in digits:
		last = pad.press_cell(pad.layout.find(int(c)))
	return last

func _initialize() -> void:
	_create()
	_verify_shuffle()
	_keys()
	_replies()
	_window()
	_device()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _create() -> void:
	var pad := CharacterLockPad.new()
	pad.open_create()
	_check(pad.layout == [1, 2, 3, 4, 5, 6, 7, 8, 9, CharacterLockPad.KEY_CLEAR, 0, CharacterLockPad.KEY_BACK],
		"create: the keypad in order, 1 2 3 / 4 5 6 / 7 8 9 / C 0 <")
	_check(pad.message == CharacterLockPad.TEXT_CHOOSE, "create: asks to choose")
	_check(_type(pad, "258") == CharacterLockPad.SUBMIT_NONE and pad.masked() == "***", "three digits: masked, nothing sent")
	_check(_type(pad, "0") == CharacterLockPad.SUBMIT_NONE and pad.mode == CharacterLockPad.Mode.CONFIRM and pad.entry == "",
		"the fourth digit asks for it again")
	_check(pad.message == CharacterLockPad.TEXT_CONFIRM, "confirm: asks for the same again")
	_check(_type(pad, "2581") == CharacterLockPad.SUBMIT_NONE and pad.mode == CharacterLockPad.Mode.CREATE \
		and pad.message == CharacterLockPad.TEXT_MISMATCH and pad.first == "" and pad.entry == "",
		"a mismatch: the message, and start over")
	_type(pad, "2580")
	var kind := _type(pad, "2580")
	_check(kind == CharacterLockPad.SUBMIT_CREATE and pad.pin() == "2580" and pad.busy, "the same twice: create 2580 is sent")
	_check(pad.press_cell(0) == CharacterLockPad.SUBMIT_NONE and pad.pin() == "2580", "presses wait while the request is out")
	pad.open_create(true)
	_check(pad.message == CharacterLockPad.TEXT_REQUIRED, "create when the server requires one: says so")

func _verify_shuffle() -> void:
	var rng := RandomNumberGenerator.new()
	var seen := {}
	for seed in 40:
		rng.seed = seed
		var pad := CharacterLockPad.new()
		pad.open_verify(rng)
		var digits := []
		for cell in 12:
			if cell != CharacterLockPad.CELL_CLEAR and cell != CharacterLockPad.CELL_BACK:
				digits.append(pad.layout[cell])
		var sorted := digits.duplicate()
		sorted.sort()
		if sorted != [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] or pad.layout[9] != CharacterLockPad.KEY_CLEAR \
				or pad.layout[11] != CharacterLockPad.KEY_BACK:
			_check(false, "verify layout %s (seed %d) is a permutation of 0-9 with C and < fixed" % [str(pad.layout), seed])
			return
		seen[str(pad.layout)] = true
	_check(true, "40 verify layouts: each a permutation of 0-9 in the digit cells, C at cell 9, < at cell 11")
	_check(seen.size() >= 39, "the layouts differ from open to open (%d distinct of 40)" % seen.size())
	var a := CharacterLockWindow.secure_rng()
	var b := CharacterLockWindow.secure_rng()
	_check(a.seed != b.seed, "the window's generator is seeded from the OS, not a constant")

func _keys() -> void:
	var pad := CharacterLockPad.new()
	pad.open_verify(RandomNumberGenerator.new())
	_type(pad, "12")
	pad.press_cell(CharacterLockPad.CELL_BACK)
	_check(pad.entry == "1" and pad.masked() == "*", "< takes the last digit off")
	pad.press_cell(CharacterLockPad.CELL_BACK)
	pad.press_cell(CharacterLockPad.CELL_BACK)
	_check(pad.entry == "", "< on nothing does nothing")
	_type(pad, "987")
	pad.press_cell(CharacterLockPad.CELL_CLEAR)
	_check(pad.entry == "" and pad.mode == CharacterLockPad.Mode.VERIFY, "C clears the entry")
	_check(_type(pad, "1357") == CharacterLockPad.SUBMIT_VERIFY and pad.pin() == "1357", "verify: the fourth digit sends")
	_check(pad.press_key(4) == CharacterLockPad.SUBMIT_NONE and pad.entry.length() == 4, "no fifth digit")
	pad.busy = false
	_check(pad.press_key(4) == CharacterLockPad.SUBMIT_NONE and pad.entry.length() == 4, "4 digits at most, even when not busy")
	pad.entry = ""
	pad.begin_remove()
	_check(pad.mode == CharacterLockPad.Mode.REMOVE and pad.message == CharacterLockPad.TEXT_REMOVE, "Remove Pin asks for the PIN")
	_check(_type(pad, "1357") == CharacterLockPad.SUBMIT_REMOVE, "remove: the fourth digit sends")

func _replies() -> void:
	var pad := CharacterLockPad.new()
	pad.open_verify(RandomNumberGenerator.new())
	_type(pad, "0000")
	_check(not pad.on_reply(CharacterLockNet.CODE_WRONG_PIN, 3, 0, 0) and pad.message == "Wrong pin code.\n3 attempts left." \
		and pad.entry == "" and not pad.busy, "wrong: the attempts left, the entry cleared")
	_type(pad, "0000")
	pad.on_reply(CharacterLockNet.CODE_WRONG_PIN, 1, 0, 0)
	_check(pad.message == CharacterLockPad.TEXT_WRONG_ONE, "one attempt left: singular")
	_type(pad, "0000")
	pad.on_reply(CharacterLockNet.CODE_LOCKED, 0, 1800, 1_000_000)
	_check(pad.mode == CharacterLockPad.Mode.LOCKED and pad.locked_until_unix == 1_001_800 \
		and pad.message == CharacterLockPad.TEXT_LOCKED % CharacterLockPad.clock_text(1_001_800), "locked: until when")
	_check(pad.press_key(1) == CharacterLockPad.SUBMIT_NONE and pad.entry == "", "locked: the keypad does nothing")
	pad.open_verify(RandomNumberGenerator.new())
	_type(pad, "2580")
	_check(pad.on_reply(CharacterLockNet.CODE_OK, 5, 0, 0), "right: done")
	pad.open_create()
	_type(pad, "11112222")
	_type(pad, "1111")
	_type(pad, "1111")
	_check(pad.on_reply(CharacterLockNet.CODE_OK, 5, 0, 0) and pad.message == CharacterLockPad.TEXT_CREATED, "created")
	pad.open_create()
	_type(pad, "11111111")
	pad.on_reply(CharacterLockNet.CODE_PIN_EXISTS, 5, 0, 0)
	_check(pad.mode == CharacterLockPad.Mode.CREATE and pad.message == CharacterLockPad.TEXT_EXISTS, "create refused: back to create, says why")

func _window() -> void:
	var w := CharacterLockWindow.new()
	w.build(UiBuilder.new(null, null))
	get_root().add_child(w)
	_check(w.size == CharacterLockWindow.SIZE and w.tiles.size() == 12, "the window: 12 keys")
	var sent := []
	w.submitted.connect(func(kind: String, pin: String, remember: bool) -> void: sent.append([kind, pin, remember]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	w.open_verify(rng)
	var cell_of := func(d: int) -> int: return w.pad.layout.find(d)
	_check(w.tiles[CharacterLockPad.CELL_CLEAR].text == "C" and w.tiles[cell_of.call(5)].text == "5", "keys show their digits")
	w.remember_box.button_pressed = true
	for d in [2, 5, 8, 0]:
		w.tiles[cell_of.call(d)].pressed.emit()
	_check(sent.size() == 1 and sent[0] == ["verify", "2580", true], "four key presses send verify 2580 with remember (%s)" % str(sent))
	_check((w.get_node("Entry") as Label).text == "****", "the entry shows ****")
	var reply := CharacterLockNet.decode_reply(CharacterLockNet.encode_reply(2, CharacterLockNet.CODE_WRONG_PIN, 1, 4, 0))
	_check(not w.apply_reply(reply) and (w.get_node("Message") as Label).text == "Wrong pin code.\n4 attempts left.",
		"a wrong reply shows on the message box")
	w.open_create()
	_check(w.tiles[0].text == "1" and w.tiles[10].text == "0", "create: the keys in order")
	var closed := [false]
	w.closed.connect(func() -> void: closed[0] = true)
	w.close_window()
	_check(closed[0], "the close button closes")
	w.queue_free()

func _device() -> void:
	var path := "user://character_lock_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(CharacterLockDevice.existing_token("Example.org", 15779, path) == "", "no token until one is made")
	var a := CharacterLockDevice.token_for("Example.org", 15779, path)
	_check(a.length() == 64 and a.is_valid_hex_number(), "a token is 64 hex characters")
	_check(CharacterLockDevice.token_for("example.org", 15779, path) == a, "kept: the same server gets the same token")
	_check(CharacterLockDevice.existing_token("example.org", 15779, path) == a, "existing_token reads it")
	var b := CharacterLockDevice.token_for("example.org", 15780, path)
	_check(b != a and b.length() == 64, "another server, another token")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
