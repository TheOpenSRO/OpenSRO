extends SceneTree

## Round 788: the title's login behaviour, piece by piece (no archive: the
## plain fallbacks; the archive's layouts are drawn in the live run).
##   - Connect (READ 0x8688f0): nothing with an empty ID, an empty password
##     or no server, and no message; nothing inside the 3.0 s lock or while a
##     request is answered.
##   - The message line (READ 0x8613b0): a message replaces the last and
##     clears after 15 s.
##   - The NETOFF box (READ 0x862450): 308 x 148 at (W/2 - 150, H/2 - 72),
##     the drop text, one button, whose press quits.
##   - The image-code window (READ CIFConfirmbox): a picture shows it with
##     the edit cleared; Enter submits once until the next picture, the button
##     submits the text as typed; it hides on 0xA323.
##   - The title's 0xA102 handling on OpenSRO's connection: the box text for a
##     refusal, the input given back.
##
## NEGATIVE: before round 788 Login.connect_allowed, NetOffBox and
## CaptchaWindow do not exist and this suite does not parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await process_frame
	_connect_rule()
	await _message_line()
	await _netoff()
	await _captcha()
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

func _connect_rule() -> void:
	var L = load("res://scripts/Login.gd")
	_check(L.connect_allowed(0.0, false, "id", "pw", true), "ID, password and a server: Connect goes on")
	_check(not L.connect_allowed(0.0, false, "", "pw", true), "an empty ID: nothing")
	_check(not L.connect_allowed(0.0, false, "id", "", true), "an empty password: nothing")
	_check(not L.connect_allowed(0.0, false, "id", "pw", false), "no server: nothing")
	_check(not L.connect_allowed(0.01, false, "id", "pw", true), "inside the lock: nothing")
	_check(L.connect_allowed(-0.5, false, "id", "pw", true), "the lock runs out (it may go negative, READ)")
	_check(not L.connect_allowed(0.0, true, "id", "pw", true), "while a request is answered: nothing")
	_check(L.SUBMIT_LOCK_S == 3.0 and L.MESSAGE_CLEAR_S == 15.0, "3.0 s lock, 15 s message (READ)")

func _message_line() -> void:
	var login: Control = load("res://scripts/Login.gd").new()
	login.status_label = Label.new()
	login.add_child(login.status_label)
	login._say("first")
	login._say("second")
	_check(login.status_label.text == "second", "a message replaces the last")
	login._process(14.9)
	_check(login.status_label.text == "second", "still there at 14.9 s")
	login._process(0.2)
	_check(login.status_label.text == "", "cleared after 15 s")
	# The 0xA102 on OpenSRO's connection: a refusal's text, input given back.
	login._busy = true
	var a := LoginAckNet.Ack.new()
	a.code = LoginAckNet.ERR_PASSWORD
	a.max_attempts = 3
	a.used_attempts = 2
	login._set_busy(true)
	login._on_gateway_login_result(a)
	_check(not login._busy and login.status_label.text == "Wrong password (3 tries allowed, 2 used).", "0xA102 code 1: the text, the input back: '%s'" % login.status_label.text)
	var silent := LoginAckNet.Ack.new()
	silent.code = 13
	login.status_label.text = "x"
	login._on_gateway_login_result(silent)
	_check(login.status_label.text == "x", "code 13 shows nothing")
	login.free()
	await process_frame

func _netoff() -> void:
	_check(NetOffBox.box_position(Vector2(1024, 768)) == Vector2(362, 312), "the box at (W/2 - 150, H/2 - 72)")
	var host := Control.new()
	host.size = Vector2(1024, 768)
	root.add_child(host)
	var b := NetOffBox.show_on(host, null, null)
	await process_frame
	_check(b.box.size == Vector2(308, 148), "308 x 148")
	_check(b.message_text() == "You have been disconnected from the server.", "the drop text: '%s'" % b.message_text())
	_check(b.find_children("*", "BaseButton", true, false).size() == 1, "one button (Confirm)")
	var quit_called := []
	b.on_confirm = func() -> void: quit_called.append(true)
	b.confirm_button.pressed.emit()
	_check(quit_called.size() == 1, "Confirm quits")
	host.queue_free()
	await process_frame

func _captcha() -> void:
	var w := CaptchaWindow.new()
	w.build(null)
	root.add_child(w)
	_check(not w.visible, "hidden until a picture comes")
	var px := PackedByteArray()
	px.resize(200 * 64)
	px[0] = 1
	var codes := []
	w.submitted.connect(func(c: String) -> void: codes.append(c))
	var err := w.show_image(RetailCaptcha.encode(200, 64, px))
	_check(err == "" and w.visible and w.edit.text == "" and w.picture.texture != null and w.picture.size == Vector2(200, 64),
		"a picture shows the window, unscaled 200 x 64, the edit empty")
	w.edit.text = " aB1 "
	w.edit.text_submitted.emit(w.edit.text)
	w.edit.text_submitted.emit(w.edit.text)
	_check(codes == [" aB1 "], "Enter submits once, the text as typed: %s" % [codes])
	w.show_image(RetailCaptcha.encode(200, 64, px))
	_check(w.edit.text == "" and w.edit.editable, "a new picture clears the edit and takes input again")
	w.edit.text = "7"
	w.accept.pressed.emit()
	_check(codes == [" aB1 ", "7"], "the button submits")
	w.hide_window()
	_check(not w.visible, "0xA323 hides it")
	_check(CaptchaWindow.plain_pml("<sml2>To do,<br>type it.</sml2>") == "To do,\ntype it.", "PML reduced to lines")
	w.queue_free()
	await process_frame
