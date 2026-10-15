extends RefCounted
class_name LoginMessages

## What the title tells the player about a login (round 788): each message's
## text, built exactly as sro_client builds it (RESEARCH section 1 of round
## 788, docs/protocol/opcodes/login.md) from the player's own
## textuisystem.txt -- the FIRST row of a key, English column (UiTextTable) --
## with a short English fallback of our own for a run without Media.pk2
## (OURS; the archive's words are never copied into the repo). An empty
## string means the original shows nothing.

## The keys (READ, the client's references to them; see each use).
const KEY_SEVER_CONNECT := "UIO_MSG_ERROR_SEVER_CONNECT"
const KEY_CITATION := "UIO_MSG_ERROR_CITATION"
const KEY_PASSWORD := "UIIT_STT_GLOBAL_PASSWORD_INPUT_ERROR"
const KEY_ACCOUNT_STOP := "UIO_MSG_ERROR_ACCOUNT_STOP"
const KEY_STOP_BLOCK := "UIO_MSG_ERROR_ACCOUNT_STOP_BLOCK"
const KEY_BLOCK_TIME := "UIO_MSG_ERROR_ACCOUNT_BLOCK_TIME"
const KEY_INSPECTION := "UIO_MSG_ERROR_ACCOUNT_CONNECT_IMPOSSIBILE"
const KEY_NO_ACCOUNT_INFO := "UIO_MSG_ERROR_THERE_IS_NO_ACCOUNT_INFO"
const KEY_FREE_OVER := "UIO_MSG_ERROR_GRATIS_USER_BLOCKED"
const KEY_OVERLAP := "UIO_MSG_ERROR_OVERLAP"
const KEY_FULL := "UIO_MSG_ERROR_SERVER_BUSY_CONNECT_IMPOSSIBILE"
const KEY_IP_LIMIT := "UIO_MSG_ERROR_CONTENT_FAIL_INSUFFICIENT_IP"
const KEY_BILLING := "UIIO_CLIENT_START_CONTENT_FAIL_BILLING_RELATED"
const KEY_BILLING_FAILED := "UIIO_CLIENT_START_CONTENT_FAIL_BILLING_FAILED"
const KEY_ADULT_ONLY := "UIIO_SMERR_ADULT_ONLY_SERVER"
const KEY_TEEN_OVER_ONLY := "UIIO_SMERR_TEENOVER_ONLY_SERVER"
const KEY_TEEN_SERVER := "UITT_TEENSERVER_ERRMGS_ADULT"
const KEY_CAPTCHA_FAILED := "UIIT_STT_GLOBAL_AUTHENTICATION_INPUT_ERROR"
const KEY_CAPTCHA_TITLE := "UIIT_PAG_GLOBAL_AUTHENTICATION"
const KEY_NETOFF := "UIIT_MSG_MSGBOX_NETOFF"
const KEY_CONFIRM_BOX := "UIIT_STT_CONFIRM_BOX"

## Our own words where the archive's are not to hand (OURS).
const FALLBACK := {
	KEY_SEVER_CONNECT: "Could not connect to the server.",
	KEY_CITATION: "Connecting, please wait.",
	KEY_PASSWORD: "Wrong password (%d tries allowed, %d used).",
	KEY_ACCOUNT_STOP: "This account is blocked.",
	KEY_STOP_BLOCK: "Reason: ",
	KEY_BLOCK_TIME: "Until: ",
	KEY_INSPECTION: "The server is under maintenance.",
	KEY_NO_ACCOUNT_INFO: "The account's details are incomplete.",
	KEY_FREE_OVER: "The free service for this account has ended.",
	KEY_OVERLAP: "This account is already logged in.",
	KEY_FULL: "The server is full.",
	KEY_IP_LIMIT: "Too many connections from this address.",
	KEY_BILLING: "The billing service failed.",
	KEY_BILLING_FAILED: "The billing service refused the login.",
	KEY_ADULT_ONLY: "This server is for adults only.",
	KEY_TEEN_OVER_ONLY: "This server is for players over 12 only.",
	KEY_TEEN_SERVER: "This server is not open to adults.",
	KEY_CAPTCHA_FAILED: "Wrong image code (%d of %d).",
	KEY_CAPTCHA_TITLE: "Image code",
	KEY_NETOFF: "You have been disconnected from the server.",
	KEY_CONFIRM_BOX: "Confirmation",
}

## The archive's text for key (its literal "\n" a line break, as LobbyNet
## reads it), else the fallback.
static func text(table: UiTextTable, key: String) -> String:
	var t := ""
	if table != null and table.has(key):
		t = table.get_text(key, "")
		if t == key:
			t = ""
	if t == "":
		t = str(FALLBACK.get(key, ""))
	return t.replace("\\n", "\n")

## sprintf for the conversions these texts carry: %d and %s in order, %% a
## percent sign; anything else is left as written.
static func printf(fmt: String, args: Array) -> String:
	var out := ""
	var i := 0
	var k := 0
	while i < fmt.length():
		var c := fmt[i]
		if c == "%" and i + 1 < fmt.length():
			var n := fmt[i + 1]
			if n == "%":
				out += "%"
				i += 2
				continue
			if (n == "d" or n == "s") and k < args.size():
				out += str(args[k])
				k += 1
				i += 2
				continue
		out += c
		i += 1
	return out

## "Failed to connect to server." with the client's "(C<n>)" -- "(%c%d)" with
## 'C', no space (READ 0x861890); n < 0 adds nothing.
static func connect_failed(table: UiTextTable, n: int) -> String:
	var t := text(table, KEY_SEVER_CONNECT)
	return t + ("(C%d)" % n if n >= 0 else "")

## READ (0x8688f0): shown as the 0x6102 goes out.
static func citation(table: UiTextTable) -> String:
	return text(table, KEY_CITATION)

## The text for a 0xA102 refusal (READ: CPSTitle::vslot_006 0x86bfc0, jump
## table 0x86caf8; the client's "(C<n>)" numbers are the wire's + 1,
## INFERRED).
static func ack_text(a: LoginAckNet.Ack, table: UiTextTable) -> String:
	if a.ok:
		return ""
	match a.code:
		LoginAckNet.ERR_PASSWORD:
			# READ: filled (max, used), each cut to 16 bits (0x4cf5f7, 0x86c0ca).
			return printf(text(table, KEY_PASSWORD), [a.max_attempts & 0xffff, a.used_attempts & 0xffff])
		LoginAckNet.ERR_BLOCKED:
			match a.block_kind:
				LoginAckNet.BLOCK_PUNISHED:
					return punishment_text(table, a.block_reason, a.block_end)
				LoginAckNet.BLOCK_INSPECTION:
					return text(table, KEY_INSPECTION)
				LoginAckNet.BLOCK_NO_ACCOUNT_INFO:
					return text(table, KEY_NO_ACCOUNT_INFO)
				LoginAckNet.BLOCK_FREE_OVER:
					return text(table, KEY_FREE_OVER)
			return ""
		LoginAckNet.ERR_ALREADY_CONNECTED:
			return text(table, KEY_OVERLAP)
		LoginAckNet.ERR_NO_SHARD:
			return connect_failed(table, 5)
		LoginAckNet.ERR_FULL:
			return text(table, KEY_FULL)
		LoginAckNet.ERR_FAILED:
			return connect_failed(table, 7)
		LoginAckNet.ERR_SHARD_MISMATCH:
			return connect_failed(table, 8)
		LoginAckNet.ERR_IP_LIMIT:
			return text(table, KEY_IP_LIMIT)
		LoginAckNet.ERR_BILLING:
			return text(table, KEY_BILLING)
		LoginAckNet.ERR_ADULT_ONLY:
			return text(table, KEY_ADULT_ONLY)
		LoginAckNet.ERR_TEEN_OVER_ONLY:
			return text(table, KEY_TEEN_OVER_ONLY)
		LoginAckNet.ERR_TEEN_SERVER:
			return text(table, KEY_TEEN_SERVER)
	return "" # READ: 0 and 13 and above show nothing

## READ: "%s\n%s%s\n%s%s" with ACCOUNT_STOP, ACCOUNT_STOP_BLOCK, the reason,
## ACCOUNT_BLOCK_TIME and the date. The reason is cut at its first '#'
## (shown_reason).
static func punishment_text(table: UiTextTable, reason: String, end: Dictionary) -> String:
	return printf("%s\n%s%s\n%s%s", [text(table, KEY_ACCOUNT_STOP), text(table, KEY_STOP_BLOCK),
		shown_reason(reason), text(table, KEY_BLOCK_TIME), long_date(end)])

## The part of a block reason the message shows. READ (0x86c136..0x86c416):
## only a reason whose LAST character is '#' is split (0x864790 is an
## ends-with test); any other is shown whole. A split one is cut at its first
## '#', and what lies between that and the last '#' is a web address the
## "[Block Detail]" button (id 800, 15 s) opens in Internet Explorer. The
## original computes the cut from a byte offset of a wide string (twice the
## character index), which is right only for a '#' at index 0 and throws for
## others; this client cuts where the code means to (INFERRED intent:
## "reason#address#"), and builds no button (OURS; docs/protocol/opcodes/
## login.md).
static func shown_reason(reason: String) -> String:
	if not reason.ends_with("#"):
		return reason
	return reason.substr(0, reason.find("#"))

## The split reason's address ("" when there is none; see shown_reason).
static func reason_address(reason: String) -> String:
	if not reason.ends_with("#"):
		return ""
	var at := reason.find("#")
	return reason.substr(at + 1, reason.length() - at - 2) if at < reason.length() - 1 else ""

const WEEKDAYS := ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS := ["January", "February", "March", "April", "May", "June", "July", "August",
	"September", "October", "November", "December"]

## The punishment's end as the client shows it. READ (0x4cf350):
## GetDateFormatA(LOCALE_SLONGDATE) + " " + GetTimeFormatA in the user's
## locale. Godot has no such call: OURS, Windows' en-US defaults --
## "dddd, MMMM d, yyyy" and "h:mm:ss tt", e.g. "Thursday, October 22, 2026
## 1:05:09 PM" -- whatever the player's locale.
static func long_date(t: Dictionary) -> String:
	var y := int(t.get("year", 0))
	var mo := int(t.get("month", 0))
	var d := int(t.get("day", 0))
	var h := int(t.get("hour", 0))
	var mi := int(t.get("minute", 0))
	var s := int(t.get("second", 0))
	if mo < 1 or mo > 12 or d < 1 or d > 31:
		return "%04d-%02d-%02d %02d:%02d:%02d" % [y, mo, d, h, mi, s] # OURS: not a date
	# The weekday by Sakamoto's method (0 = Sunday), without the engine's
	# calendar, which logs an error for a day the month does not have.
	var yy := y - 1 if mo < 3 else y
	var wd: int = (yy + yy / 4 - yy / 100 + yy / 400 + [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4][mo - 1] + d) % 7
	var h12 := h % 12
	if h12 == 0:
		h12 = 12
	return "%s, %s %d, %d %d:%02d:%02d %s" % [WEEKDAYS[wd], MONTHS[mo - 1], d, y, h12, mi, s, "AM" if h < 12 else "PM"]

## The text for a 0xA103 refusal (READ: vslot_018 0x4cf7a0): 1 "(C9)", 2 and
## 3 "(C10)", 4 full, 5 the IP limit, 6 BILLING_FAILED; others nothing.
static func agent_text(code: int, table: UiTextTable) -> String:
	match code:
		1:
			return connect_failed(table, 9)
		2, 3:
			return connect_failed(table, 10)
		4:
			return text(table, KEY_FULL)
		5:
			return text(table, KEY_IP_LIMIT)
		6:
			return text(table, KEY_BILLING_FAILED)
	return ""

## READ (0x4d0230, 0x86c364): filled (max, used) as 16-bit numbers, so the
## English reads "failed <max> out of <used> times".
static func captcha_failed(table: UiTextTable, max_tries: int, used: int) -> String:
	return printf(text(table, KEY_CAPTCHA_FAILED), [max_tries & 0xffff, used & 0xffff])

## READ (0x862450): the connection-drop box's text and title.
static func netoff(table: UiTextTable) -> String:
	return text(table, KEY_NETOFF)

static func confirm_title(table: UiTextTable) -> String:
	return text(table, KEY_CONFIRM_BOX)
