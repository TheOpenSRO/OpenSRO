extends RefCounted
class_name CharacterLockPad

## The Character Lock window's state (round 788, lane P), apart from its
## drawing so it can be tested headless. The feature is OURS (the retail game
## has no PIN; docs/protocol/pin.md); so is every rule and word here.
##
## The keypad is 12 cells, 3 wide and 4 high, read left to right, top to
## bottom. Create shows the digits in order, `1 2 3 / 4 5 6 / 7 8 9 / C 0 <`
## (the user's screenshot); verify and remove put the ten digits in a random
## order each time the window opens, with C (clear) and < (backspace) kept in
## their corners -- the user's request, "to make it harder to steal the pin":
## a recording of where the clicks landed does not give the digits.
##
## There is no OK button (the screenshot has none): the fourth digit submits.
## Create asks for the four digits twice; a mismatch starts over.
##
## Keyboard digits do not type (OURS). The shuffle defeats a recording of the
## clicks; digits typed on the keyboard would hand the PIN to a key logger,
## which is the other way PINs are stolen, so the window takes the pad only --
## in every mode, so the habit it teaches is one.

const PIN_LENGTH := 4

## The two keys that are not digits, as cell values.
const KEY_CLEAR := 10
const KEY_BACK := 11

## Where C and < sit: bottom left and bottom right.
const CELL_CLEAR := 9
const CELL_BACK := 11

## The in-order layout (create): digit cells 1..9, then C, 0, <.
const ORDERED := [1, 2, 3, 4, 5, 6, 7, 8, 9, KEY_CLEAR, 0, KEY_BACK]

enum Mode { CREATE, CONFIRM, VERIFY, REMOVE, LOCKED }

## What a key press asks the window to send, if anything.
const SUBMIT_NONE := ""
const SUBMIT_CREATE := "create"
const SUBMIT_VERIFY := "verify"
const SUBMIT_REMOVE := "remove"

## The words (OURS: no textdata key exists for this feature). Short, in the
## screenshot's voice.
const TEXT_ENTER := "Enter your pin code.\nOnly 4 digits allowed."
const TEXT_CHOOSE := "Choose a pin code.\nOnly 4 digits allowed."
const TEXT_REQUIRED := "This server asks for a pin code. Choose one.\nOnly 4 digits allowed."
const TEXT_CONFIRM := "Enter the same pin code again."
const TEXT_MISMATCH := "The pin codes did not match. Choose again."
const TEXT_REMOVE := "Enter your pin code to remove it."
const TEXT_WRONG := "Wrong pin code.\n%d attempts left."
const TEXT_WRONG_ONE := "Wrong pin code.\n1 attempt left."
const TEXT_LOCKED := "Too many wrong entries.\nLocked until %s."
const TEXT_CREATED := "Pin code created."
const TEXT_REMOVED := "Pin code removed."
const TEXT_EXISTS := "This account already has a pin code."
const TEXT_NONE := "This account has no pin code."
const TEXT_FAILED := "The server could not check the pin code. Try again."
const TEXT_CHECKING := "Checking..."

var mode: int = Mode.VERIFY
## The digits typed so far, at most PIN_LENGTH.
var entry := ""
## Create's first entry, while CONFIRM asks for it again.
var first := ""
## Cell -> key (0..9 a digit, KEY_CLEAR, KEY_BACK).
var layout: Array = ORDERED.duplicate()
var message := TEXT_ENTER
## A request is out; presses wait for its answer.
var busy := false
## When LOCKED: the unix time the lock ends (the local clock).
var locked_until_unix := 0

## Opens for creating a PIN (required: the server asks for one).
func open_create(required: bool = false) -> void:
	mode = Mode.CREATE
	layout = ORDERED.duplicate()
	entry = ""
	first = ""
	busy = false
	message = TEXT_REQUIRED if required else TEXT_CHOOSE

## Opens for entering the PIN, the digits shuffled by `rng`.
func open_verify(rng: RandomNumberGenerator) -> void:
	mode = Mode.VERIFY
	layout = shuffled(rng)
	entry = ""
	first = ""
	busy = false
	message = TEXT_ENTER

## The Remove Pin button: the next four digits remove the PIN. The keypad
## keeps its order (it is already shuffled).
func begin_remove() -> void:
	if mode == Mode.LOCKED:
		return
	mode = Mode.REMOVE
	entry = ""
	busy = false
	message = TEXT_REMOVE

## Locked until `until_unix`, shown in the local clock's hours and minutes.
func open_locked(until_unix: int) -> void:
	mode = Mode.LOCKED
	entry = ""
	busy = false
	locked_until_unix = until_unix
	message = TEXT_LOCKED % clock_text(until_unix)

static func clock_text(unix: int) -> String:
	var t := Time.get_datetime_dict_from_unix_time(unix + _utc_offset_s())
	return "%02d:%02d" % [int(t.hour), int(t.minute)]

static func _utc_offset_s() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60

## The ten digits in a random order in the digit cells; C and < stay put.
static func shuffled(rng: RandomNumberGenerator) -> Array:
	var digits := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
	# Fisher-Yates.
	for i in range(digits.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: int = digits[i]
		digits[i] = digits[j]
		digits[j] = tmp
	var out := []
	var k := 0
	for cell in 12:
		if cell == CELL_CLEAR:
			out.append(KEY_CLEAR)
		elif cell == CELL_BACK:
			out.append(KEY_BACK)
		else:
			out.append(digits[k])
			k += 1
	return out

## The masked entry: one * per digit.
func masked() -> String:
	return "*".repeat(entry.length())

## A press on cell `cell`. Returns what to send (SUBMIT_*), with the PIN in
## `pin()` until the answer comes.
func press_cell(cell: int) -> String:
	if cell < 0 or cell >= layout.size():
		return SUBMIT_NONE
	return press_key(int(layout[cell]))

func press_key(key: int) -> String:
	if busy or mode == Mode.LOCKED:
		return SUBMIT_NONE
	if key == KEY_CLEAR:
		entry = ""
		return SUBMIT_NONE
	if key == KEY_BACK:
		if entry.length() > 0:
			entry = entry.left(entry.length() - 1)
		return SUBMIT_NONE
	if key < 0 or key > 9 or entry.length() >= PIN_LENGTH:
		return SUBMIT_NONE
	entry += str(key)
	if entry.length() < PIN_LENGTH:
		return SUBMIT_NONE
	match mode:
		Mode.CREATE:
			first = entry
			entry = ""
			mode = Mode.CONFIRM
			message = TEXT_CONFIRM
			return SUBMIT_NONE
		Mode.CONFIRM:
			if entry != first:
				first = ""
				entry = ""
				mode = Mode.CREATE
				message = TEXT_MISMATCH
				return SUBMIT_NONE
			busy = true
			message = TEXT_CHECKING
			return SUBMIT_CREATE
		Mode.VERIFY:
			busy = true
			message = TEXT_CHECKING
			return SUBMIT_VERIFY
		Mode.REMOVE:
			busy = true
			message = TEXT_CHECKING
			return SUBMIT_REMOVE
	return SUBMIT_NONE

## The PIN to send with a submit.
func pin() -> String:
	return entry

## The server's answer to the submit. `now_unix` is the local clock. Returns
## true when the window's job is done (OK).
func on_reply(code: int, attempts_left: int, locked_seconds: int, now_unix: int) -> bool:
	busy = false
	var was := mode
	entry = ""
	first = ""
	match code:
		CharacterLockNet.CODE_OK:
			message = TEXT_REMOVED if was == Mode.REMOVE else (TEXT_CREATED if was == Mode.CONFIRM else TEXT_ENTER)
			return true
		CharacterLockNet.CODE_WRONG_PIN:
			message = TEXT_WRONG_ONE if attempts_left == 1 else TEXT_WRONG % attempts_left
		CharacterLockNet.CODE_LOCKED:
			open_locked(now_unix + maxi(locked_seconds, 0))
		CharacterLockNet.CODE_PIN_EXISTS:
			message = TEXT_EXISTS
		CharacterLockNet.CODE_NO_PIN:
			message = TEXT_NONE
		_:
			message = TEXT_FAILED
	if was == Mode.CONFIRM and mode != Mode.LOCKED:
		mode = Mode.CREATE
	return false
