extends Node
class_name CharSelectLock

## The account PIN at character select (round 788, lane P; OURS throughout --
## the retail game has no PIN, docs/protocol/pin.md). CharacterSelect keeps
## one of these and asks it before Start, Delete and Restore (`hold`); it
## does everything else itself, so the screen's own code changes by a few
## lines:
##
## - when the screen opens it asks the server for the account's lock status,
##   carrying this PC's device token when one was made (a remembered PC is
##   let through then, without a prompt);
## - `hold(retry)`: Start, Delete or Restore with a PIN set and this login not
##   yet past it opens the Character Lock window to verify; a server that
##   requires a PIN, on an account with none, opens it to create one; a
##   locked PIN opens it showing when the lock ends. On success `retry` runs
##   again, and passes. A server that never answers the status (an OpenSRO
##   server from before round 788) is let through after STATUS_TIMEOUT_S, and
##   its own refusal, if any, is what the player sees;
## - a "Pin Code" button in the select screen's bottom band, in the column
##   left of Start (OURS placement: the band's buttons stand 0x68 apart from
##   x = W - 0x69 leftward -- Cancel, Create/Delete/Restore, Start -- and the
##   next column is the first free spot in the retail layout), sets up a PIN,
##   or verifies and offers Remove Pin.
##
## OPENSRO_QA_PIN (QA only, OURS): drives the window through its own cell
## presses, the way a click does, one press every QA_PRESS_S:
##   OPENSRO_QA_PIN=create:2580          set up 2580 when Start is held (on an
##                                       account with none, as if Pin Code
##                                       had been pressed first)
##   OPENSRO_QA_PIN=verify:1111,2580     try 1111, then 2580, when asked
##   OPENSRO_QA_PIN_REMEMBER=1           tick "Remember this PC" first
##   OPENSRO_QA_PIN_DELAY=<s>            wait this long before the first press
##                                       (a frame of the window over the
##                                       harbour once the screen has built)
## and prints `QA PIN ...` lines (never the token).

## Unanswered for this long, the status is taken as "this server has no
## PIN" (OURS).
const STATUS_TIMEOUT_S := 3.0
const BUTTON_TEXT := "Pin Code"
const QA_PRESS_S := 0.6

var host: Control = null
var net: Node = null
## The last status the server sent (a reply to anything), or null.
var status: CharacterLockNet.Reply = null
var window: CharacterLockWindow = null
var button: Button = null
var _dim: ColorRect = null
var _awaiting := false
var _waited_s := 0.0
var _unsupported := false
## The action held while the window is up (or while the status is awaited).
var _retry := Callable()
## What the window was opened for: "hold" (an action waits) or "manage".
var _purpose := ""
var _builder: UiBuilder = null
var _shown := Callable()
## The QA script's steps, and the time to the next press.
var _qa_steps: Array = []
var _qa_wait := 0.0

## Builds the window (hidden) and the button over `host_control`, using the
## archive through `builder`.
##
## `make_button(def, text_key, fallback)` makes a button the screen's way (its
## `_button`, from Start's own definition); `shown()` says whether the
## screen's buttons are up now.
func setup(host_control: Control, builder: UiBuilder, net_client: Node, start_button_def: UiLayoutParser.ControlDef,
		make_button: Callable, shown: Callable) -> void:
	host = host_control
	_shown = shown
	net = net_client
	_builder = builder
	name = "CharSelectLock"
	if net != null and net.has_signal("character_lock_reply"):
		net.character_lock_reply.connect(_on_reply)
	if make_button.is_valid():
		button = make_button.call(start_button_def, "", BUTTON_TEXT)
	else:
		button = Button.new()
		button.text = BUTTON_TEXT
	button.name = "PinCodeButton"
	button.visible = false
	button.pressed.connect(manage)
	host.add_child(button)
	_dim = ColorRect.new()
	_dim.name = "CharacterLockDim"
	_dim.color = Color(0, 0, 0, 0.5)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.visible = false
	host.add_child(_dim)
	window = CharacterLockWindow.new()
	window.build(builder)
	window.visible = false
	window.submitted.connect(_on_submitted)
	window.closed.connect(close)
	host.add_child(window)

## Asks for the status, with this PC's token for the server if one exists.
func query() -> void:
	if net == null or not net.has_method("char_lock_status"):
		_unsupported = true
		return
	_awaiting = true
	_waited_s = 0.0
	net.char_lock_status(CharacterLockDevice.existing_token(net.server_host, net.server_port))

## Whether Start / Delete / Restore may go ahead now; false opens the window
## (or waits for the status) and runs `retry` once the lock is passed.
func hold(retry: Callable) -> bool:
	if _unsupported:
		return false
	if status == null:
		if not _awaiting:
			return false
		_retry = retry
		_purpose = "hold"
		print("CharSelectLock: waiting for the lock status before the action")
		return true
	if status.unlocked and not (not status.has_pin and OS.get_environment("OPENSRO_QA_PIN").begins_with("create:")):
		return false
	_retry = retry
	_purpose = "hold"
	if status.locked:
		_open("locked")
	elif status.has_pin:
		_open("verify")
	else:
		_open("create")
	return true

## The Pin Code button: set up a PIN, or verify (with Remove Pin offered).
func manage() -> void:
	if status == null or (window != null and window.visible):
		return
	_retry = Callable()
	_purpose = "manage"
	if status.locked:
		_open("locked")
	elif status.has_pin:
		_open("verify")
	else:
		_open("create")

func _open(mode: String) -> void:
	match mode:
		"locked":
			window.open_locked(int(Time.get_unix_time_from_system()) + status.locked_seconds)
		"verify":
			window.open_verify()
		_:
			window.open_create(status.required and not status.has_pin)
	_place()
	_dim.visible = true
	window.visible = true
	UiSounds.play("snd_window_open", "character select: the character lock")
	print("CharSelectLock: window open (%s, %s) at frame %d" % [mode, _purpose, Engine.get_frames_drawn()])
	_qa_begin(mode)

func close() -> void:
	if window == null or not window.visible:
		return
	window.visible = false
	_dim.visible = false
	_retry = Callable()
	_qa_steps.clear()
	UiSounds.play("snd_window_close", "character select: the character lock")
	print("CharSelectLock: window closed")

func _place() -> void:
	if host == null or window == null:
		return
	window.position = ((host.size - window.size) / 2.0).floor()

func _on_submitted(kind: String, pin: String, remember: bool) -> void:
	if net == null:
		return
	match kind:
		CharacterLockPad.SUBMIT_CREATE:
			net.char_lock_create(pin)
		CharacterLockPad.SUBMIT_VERIFY:
			var token := CharacterLockDevice.token_for(net.server_host, net.server_port) if remember else ""
			net.char_lock_verify(pin, remember, token)
		CharacterLockPad.SUBMIT_REMOVE:
			net.char_lock_remove(pin)
	print("CharSelectLock: sent %s%s" % [kind, " (remember this PC)" if remember else ""])

func _on_reply(reply: CharacterLockNet.Reply) -> void:
	if reply.error != "":
		print("CharSelectLock: a malformed reply (%s)" % reply.error)
		return
	_awaiting = false
	status = reply
	print("CharSelectLock: reply op %d code %d -- pin %s, required %s, unlocked %s, locked %s s, %d attempts left" % [
		reply.op, reply.code, reply.has_pin, reply.required, reply.unlocked,
		reply.locked_seconds if reply.locked else 0, reply.attempts_left])
	if reply.op == CharacterLockNet.REPLY_STATUS:
		if reply.unlocked and reply.has_pin:
			print("CharSelectLock: unlocked without a prompt (a remembered PC)")
		if _retry.is_valid() and not (window != null and window.visible):
			var retry := _retry
			_retry = Callable()
			retry.call()
		return
	if window == null or not window.visible:
		return
	var done := window.apply_reply(reply)
	print("CharSelectLock: message \"%s\"" % window.pad.message.replace("\n", " "))
	if not done:
		return
	var said := ""
	match reply.op:
		CharacterLockNet.REPLY_CREATE:
			said = CharacterLockPad.TEXT_CREATED
		CharacterLockNet.REPLY_REMOVE:
			said = CharacterLockPad.TEXT_REMOVED
	var retry := _retry
	close()
	if said != "" and host != null and host.has_method("_say"):
		host.call("_say", "", said)
	if retry.is_valid():
		retry.call()

func _process(delta: float) -> void:
	if _awaiting and status == null:
		_waited_s += delta
		if _waited_s >= STATUS_TIMEOUT_S:
			_awaiting = false
			_unsupported = true
			print("CharSelectLock: no lock status after %.0f s -- this server has no PIN" % STATUS_TIMEOUT_S)
			if _retry.is_valid():
				var retry := _retry
				_retry = Callable()
				retry.call()
	_update_button()
	_qa_tick(delta)

## The button shows while the list's or the selected character's buttons do,
## once the server has said it keeps a PIN.
func _update_button() -> void:
	if button == null:
		return
	var on: bool = status != null and not _unsupported and _shown.is_valid() and bool(_shown.call()) \
		and not window.visible
	button.visible = on
	button.disabled = not on

## The button's place: one column (0x68) left of Start's (OURS, the header).
func place_button(start_position: Vector2) -> void:
	if button != null:
		var at := start_position - Vector2(0x68, 0)
		if at != button.position:
			print("CharSelectLock: Pin Code button at %s, size %s (Start at %s)" % [at, button.size, start_position])
		button.position = at
	_place()

# --- QA --------------------------------------------------------------------------------

func _qa_begin(mode: String) -> void:
	var spec := OS.get_environment("OPENSRO_QA_PIN")
	if spec == "" or mode == "locked":
		if mode == "locked":
			print("QA PIN: locked -- %s" % window.pad.message.replace("\n", " "))
		return
	var parts := spec.split(":", false)
	if parts.size() != 2:
		return
	_qa_steps.clear()
	if OS.get_environment("OPENSRO_QA_PIN_REMEMBER") != "" and mode == "verify":
		_qa_steps.append("remember")
	for pin in parts[1].split(",", false):
		for i in (2 if mode == "create" else 1):
			for c in pin:
				_qa_steps.append(c)
		_qa_steps.append("wait")
	var delay := OS.get_environment("OPENSRO_QA_PIN_DELAY")
	_qa_wait = delay.to_float() if delay.is_valid_float() else QA_PRESS_S
	print("QA PIN: %s window open, layout %s" % [mode, str(window.pad.layout)])

func _qa_tick(delta: float) -> void:
	if _qa_steps.is_empty() or window == null or not window.visible:
		return
	if window.pad.busy:
		return
	_qa_wait -= delta
	if _qa_wait > 0.0:
		return
	_qa_wait = QA_PRESS_S
	var step: String = _qa_steps.pop_front()
	if step == "wait":
		print("QA PIN: message \"%s\" at frame %d" % [window.pad.message.replace("\n", " "), Engine.get_frames_drawn()])
		return
	if step == "remember":
		window.remember_box.button_pressed = true
		print("QA PIN: ticked Remember this PC")
		return
	var cell: int = window.pad.layout.find(int(step))
	window.press_cell(cell)
	print("QA PIN: pressed cell %d, entry %s" % [cell, window.pad.masked()])
