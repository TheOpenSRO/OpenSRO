extends SceneTree

## Round 788: the title's login messages, text by text, from a SYNTHETIC
## textuisystem-shaped table (our own words, never the archive's): every
## 0xA102 code to its exact text, the punishment box's "%s\n%s%s\n%s%s" with
## the en-US long date, the "(C<n>)" suffixes, 0xA103's codes, the image
## code's (max, used) order, and the fallbacks without a table.
##
## NEGATIVE: before round 788 LoginMessages does not exist and this suite does
## not parse.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Synthetic rows: token at column 1, English at column 8, UTF-16 like the
## archive's. The FIRST row of a key wins: SEVER_CONNECT's second row must
## never show.
func _table() -> UiTextTable:
	var rows := PackedStringArray()
	var add := func(key: String, value: String) -> void:
		rows.append("1\t%s\t0\t0\t0\t0\t0\t0\t%s\t0" % [key, value])
	add.call("UIO_MSG_ERROR_SEVER_CONNECT", "Conn fail.")
	add.call("UIO_MSG_ERROR_SEVER_CONNECT", "Second row.")
	add.call("UIO_MSG_ERROR_CITATION", "Wait.")
	add.call("UIIT_STT_GLOBAL_PASSWORD_INPUT_ERROR", "Bad pw: max %d used %d.")
	add.call("UIO_MSG_ERROR_ACCOUNT_STOP", "Stopped.")
	add.call("UIO_MSG_ERROR_ACCOUNT_STOP_BLOCK", "Why:")
	add.call("UIO_MSG_ERROR_ACCOUNT_BLOCK_TIME", "When:")
	add.call("UIO_MSG_ERROR_ACCOUNT_CONNECT_IMPOSSIBILE", "Inspect.")
	add.call("UIO_MSG_ERROR_THERE_IS_NO_ACCOUNT_INFO", "No info.\\nLine two.")
	add.call("UIO_MSG_ERROR_GRATIS_USER_BLOCKED", "Free over.")
	add.call("UIO_MSG_ERROR_OVERLAP", "Overlap.")
	add.call("UIO_MSG_ERROR_SERVER_BUSY_CONNECT_IMPOSSIBILE", "Full.")
	add.call("UIO_MSG_ERROR_CONTENT_FAIL_INSUFFICIENT_IP", "IP limit.")
	add.call("UIIO_CLIENT_START_CONTENT_FAIL_BILLING_RELATED", "Billing.")
	add.call("UIIO_CLIENT_START_CONTENT_FAIL_BILLING_FAILED", "Billing failed.")
	add.call("UIIO_SMERR_ADULT_ONLY_SERVER", "Adults.")
	add.call("UIIO_SMERR_TEENOVER_ONLY_SERVER", "Over 12.")
	add.call("UITT_TEENSERVER_ERRMGS_ADULT", "Teen server.")
	add.call("UIIT_STT_GLOBAL_AUTHENTICATION_INPUT_ERROR", "Code failed %d out of %d.")
	add.call("UIIT_MSG_MSGBOX_NETOFF", "Net off.")
	add.call("UIIT_STT_CONFIRM_BOX", "Confirm")
	return UiTextTable.parse("\n".join(rows).to_utf16_buffer())

func _ack(code: int, kind: int = 0) -> LoginAckNet.Ack:
	var a := LoginAckNet.Ack.new()
	a.code = code
	a.block_kind = kind
	return a

func _test_codes(t: UiTextTable) -> void:
	var a := _ack(1)
	a.max_attempts = 3
	a.used_attempts = 0x10002 # cut to 16 bits: 2
	_check(LoginMessages.ack_text(a, t) == "Bad pw: max 3 used 2.", "code 1: (max, used), 16 bits each: '%s'" % LoginMessages.ack_text(a, t))
	var want := {
		3: "Overlap.", 4: "Conn fail.(C5)", 5: "Full.", 6: "Conn fail.(C7)", 7: "Conn fail.(C8)", 8: "IP limit.",
		9: "Billing.", 10: "Adults.", 11: "Over 12.", 12: "Teen server.", 0: "", 13: "", 200: "",
	}
	for code in want:
		var got := LoginMessages.ack_text(_ack(code), t)
		_check(got == want[code], "code %d -> '%s' (got '%s')" % [code, want[code], got])
	_check(LoginMessages.ack_text(_ack(2, 2), t) == "Inspect.", "2/2 inspection")
	_check(LoginMessages.ack_text(_ack(2, 3), t) == "No info.\nLine two.", "2/3, the literal \\n a line break")
	_check(LoginMessages.ack_text(_ack(2, 4), t) == "Free over.", "2/4 free service over")
	_check(LoginMessages.ack_text(_ack(2, 9), t) == "", "2/9 shows nothing (OURS: no case)")
	var ok := LoginAckNet.Ack.new()
	ok.ok = true
	_check(LoginMessages.ack_text(ok, t) == "", "success shows nothing")

func _test_punishment(t: UiTextTable) -> void:
	var a := _ack(2, 1)
	a.block_reason = "Botting#example.test/ban#"
	a.block_end = {"year": 2026, "month": 10, "day": 22, "hour": 13, "minute": 5, "second": 9}
	var got := LoginMessages.ack_text(a, t)
	var want := "Stopped.\nWhy:Botting\nWhen:Thursday, October 22, 2026 1:05:09 PM"
	_check(got == want, "the punishment box: '%s'" % got.c_escape())
	_check(LoginMessages.long_date({"year": 2027, "month": 1, "day": 3, "hour": 0, "minute": 0, "second": 7}) == "Sunday, January 3, 2027 12:00:07 AM",
		"midnight is 12 AM: %s" % LoginMessages.long_date({"year": 2027, "month": 1, "day": 3, "hour": 0, "minute": 0, "second": 7}))
	_check(LoginMessages.long_date({"year": 2028, "month": 2, "day": 29, "hour": 12, "minute": 30, "second": 0}) == "Tuesday, February 29, 2028 12:30:00 PM", "noon is 12 PM; a leap day's weekday")
	_check(LoginMessages.shown_reason("no hash") == "no hash", "a reason without '#' is shown whole")
	_check(LoginMessages.shown_reason("a#b") == "a#b", "a '#' that is not last splits nothing (READ: ends-with)")
	_check(LoginMessages.reason_address("Botting#example.test/ban#") == "example.test/ban" and LoginMessages.reason_address("x") == "",
		"the address between the first and the last '#'")
	_check(LoginMessages.shown_reason("#addr#") == "" and LoginMessages.reason_address("#addr#") == "addr", "'#address#': no text, the address")

func _test_other(t: UiTextTable) -> void:
	_check(LoginMessages.connect_failed(t, 3) == "Conn fail.(C3)", "the suffix has no space: (%c%d)")
	_check(LoginMessages.connect_failed(t, -1) == "Conn fail.", "no number, no suffix")
	_check(LoginMessages.citation(t) == "Wait.", "the citation")
	var agent := {1: "Conn fail.(C9)", 2: "Conn fail.(C10)", 3: "Conn fail.(C10)", 4: "Full.", 5: "IP limit.", 6: "Billing failed.", 7: "", 0: ""}
	for code in agent:
		_check(LoginMessages.agent_text(code, t) == agent[code], "0xA103 code %d -> '%s'" % [code, agent[code]])
	_check(LoginMessages.captcha_failed(t, 3, 1) == "Code failed 3 out of 1.", "the image code: filled (max, used), as READ")
	_check(LoginMessages.netoff(t) == "Net off." and LoginMessages.confirm_title(t) == "Confirm", "the drop box's text and title")
	_check(LoginMessages.printf("100%% %d %s %x", [1, "a"]) == "100% 1 a %x", "printf: %%, %d, %s; others as written")

func _test_fallbacks() -> void:
	_check(LoginMessages.connect_failed(null, 5) == "Could not connect to the server.(C5)", "no table: our words with the suffix")
	var a := _ack(1)
	a.max_attempts = 3
	a.used_attempts = 1
	_check(LoginMessages.ack_text(a, null) == "Wrong password (3 tries allowed, 1 used).", "no table: code 1")
	_check(LoginMessages.netoff(null) == "You have been disconnected from the server.", "no table: the drop")
	for k in LoginMessages.FALLBACK:
		_check(str(LoginMessages.FALLBACK[k]) != "", "%s has a fallback" % str(k).to_lower())

func _init() -> void:
	var t := _table()
	_check(t != null and t.has("UIO_MSG_ERROR_SEVER_CONNECT"), "the synthetic table parses")
	_test_codes(t)
	_test_punishment(t)
	_test_other(t)
	_test_fallbacks()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
