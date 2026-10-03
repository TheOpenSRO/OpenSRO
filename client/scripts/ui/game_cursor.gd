extends RefCounted
class_name GameCursor

## The game's cursor on every screen (round 697): the set CursorSet reads
## from the player's sro_client.exe, loaded once at boot, shown at the UI
## scale, and switched by id. Static, because the cursor is one per process
## -- retail's cursor manager is one object owned by the main frame
## (0xba6260; its show flag, id and HCURSOR at +0x20 / +0x24 / +0x28) and
## the first process state sets 0x95 before the login screen
## (CPSVersionCheck::vslot_011 0x86d150, READ). Labels: READ, MEASURED,
## INFERRED, OURS.
##
## **Scale (OURS, the user's decision 2026-10-03):** "Scale the cursor with
## the dpi scaling, just like the rasterized images. It doesn't look great
## but it's authentic and usable." Each cursor is scaled by the window's
## content_scale_factor (round 672's UI scale) with nearest-neighbour
## (CursorSet.scaled); retail itself never scales -- LoadCursorA with no size
## gives the system's cursor size (INFERRED from the Win32 contract; the exe
## passes no size). Godot does not rescale it again: on Windows
## DisplayServerWindows::cursor_set_custom_image builds the HCURSOR at the
## texture's own pixel size (CreateIconIndirect on a DIB of
## texture_size, 4.2.2), and the process is DPI-aware, so a 64 x 64 image is
## 64 screen pixels. (macOS's native build sizes the NSImage in points, so
## there the OS doubles on a Retina screen; the user's Mac runs the Windows
## build under CrossOver, where Wine's own mapping applies -- not measured.)
## One scaled set is cached per factor, so a hover change only swaps a
## texture already made.

## Hover kind -> resource id: what CGInterface::vslot_005 (0x789820) passes
## to SetHoverCursor for each class (READ; the table in CursorSet).
const KIND_IDS := {
	"normal": CursorSet.ID_NORMAL,
	"attack": CursorSet.ID_ATTACK,
	"talk": CursorSet.ID_TALK,
	"pickup": CursorSet.ID_PICKUP,
	"pickup_held": CursorSet.ID_PICKUP_HELD,
	"gate": CursorSet.ID_GATE,
	"player_hostile": CursorSet.ID_PLAYER_HOSTILE,
	# TODO(stalls): a CICUser in the stall state (+0x471 == 4, set by the
	# 0x30b8 broadcast, 0x873c10) -- wired here, reached once other players'
	# stalls exist (player_kind's `stalling`).
	"stall": CursorSet.ID_STALL,
}

## The shapes Godot's own controls switch to by themselves (a LineEdit's
## I-beam, a link's hand). Retail's window proc answers every WM_SETCURSOR
## with the manager's one handle (0xba6f10 case 0x20, READ), so the game's
## cursor shows over text fields too: these get the default cursor.
const PLAIN_SHAPES := [Input.CURSOR_IBEAM, Input.CURSOR_POINTING_HAND]

static var _base: Dictionary = {}      # id -> CursorSet.Cursor (unscaled)
static var _loaded := false
static var _source := ""
static var _scaled_sets: Dictionary = {}   # factor key -> {id: [ImageTexture, Vector2i]}
static var _current_id := -1
static var _current_key := ""
static var _suspended := false

static func id_for(kind: String) -> int:
	return int(KIND_IDS.get(kind, CursorSet.ID_NORMAL))

## Loads the set once: the exe search (CursorSet.exe_candidates) against
## where Data.pk2 resolved and where this executable is, logging the file
## used or every path tried -- a tester's log then says why the cursor is
## the system arrow.
static func load_once() -> void:
	if _loaded:
		return
	_loaded = true
	var candidates := CursorSet.exe_candidates(Pk2Config.data_path(), OS.get_executable_path(),
		OS.get_environment("SRREVAMP_CLIENT_EXE"))
	var r := CursorSet.load_first(candidates)
	_base = r["cursors"]
	_source = r["path"]
	if _source != "":
		print("GameCursor: %d cursor(s) from %s" % [_base.size(), _source])
	else:
		print("GameCursor: no sro_client.exe found -- the system cursor stays. Tried: %s. Put your own sro_client.exe beside Data.pk2 to get the game's cursors." % ", ".join(r["tried"]))

static func has_cursors() -> bool:
	return not _base.is_empty()

static func source_path() -> String:
	return _source

static func current_id() -> int:
	return _current_id

static func _key(factor: float) -> String:
	return "%.3f" % factor

static func _factor_of(window: Window) -> float:
	return window.content_scale_factor if window != null else 1.0

## The scaled texture and hotspot for an id at a factor ([ImageTexture,
## Vector2i]), made once per factor; [] when the id is not in the set.
static func scaled_entry(id: int, factor: float) -> Array:
	if not _base.has(id):
		return []
	var key := _key(factor)
	var bucket: Dictionary = _scaled_sets.get(key, {})
	if not bucket.has(id):
		var pair := CursorSet.scaled(_base[id], factor)
		bucket[id] = [ImageTexture.create_from_image(pair[0]), pair[1]]
		_scaled_sets[key] = bucket
	return bucket[id]

## Shows cursor `id` at the window's UI scale. Cheap when nothing changed:
## same id and scale is a no-op. A changed scale also re-sets the plain
## shapes (PLAIN_SHAPES) to the default cursor.
static func show(id: int, window: Window, force: bool = false) -> bool:
	if _base.is_empty() or _suspended:
		return false
	if not _base.has(id):
		id = CursorSet.ID_NORMAL
	var factor := _factor_of(window)
	var key := _key(factor)
	if not force and id == _current_id and key == _current_key:
		return false
	var entry := scaled_entry(id, factor)
	if entry.is_empty():
		return false
	# A display server without custom cursors (the headless suite) keeps the
	# state but is not asked: it would warn on every change.
	if DisplayServer.has_feature(DisplayServer.FEATURE_CUSTOM_CURSOR_SHAPE):
		if key != _current_key or force:
			var plain := scaled_entry(CursorSet.ID_NORMAL, factor)
			for shape in PLAIN_SHAPES:
				Input.set_custom_mouse_cursor(plain[0], shape, plain[1])
		Input.set_custom_mouse_cursor(entry[0], Input.CURSOR_ARROW, entry[1])
	_current_id = id
	_current_key = key
	return true

static func show_kind(kind: String, window: Window) -> bool:
	return show(id_for(kind), window)

## Re-shows the current cursor when the UI scale changed (ClientSettings.
## apply_ui_scale calls this; the world's hover tick checks too).
static func refresh(window: Window) -> void:
	if _current_id < 0 or _suspended:
		return
	if _key(_factor_of(window)) != _current_key:
		show(_current_id, window)

## A mode that shows a system shape instead (the ground pick's cross, round
## 617, OURS): the game's arrow is lifted until resume().
static func suspend() -> void:
	_suspended = true
	if DisplayServer.has_feature(DisplayServer.FEATURE_CUSTOM_CURSOR_SHAPE):
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)

static func resume(window: Window, id: int = CursorSet.ID_NORMAL) -> void:
	_suspended = false
	show(id, window, true)

static func is_suspended() -> bool:
	return _suspended

## A CICUser under the mouse (vslot_005's 0xef1bc0 branch, READ; its asm
## 0x7899a4..0x789a87): outside the party with the target's IsHostile(Alt)
## true -> 0xa0; else the stall pouch 0xa3 when it is stalling; else 0x95.
## Then, in a siege-fortress zone, an enemy guild (relation 0xca / 0xcc)
## gives 0x97 and an allied one (0xc9 / 0xcb) or a party member 0x95; then,
## while this player's team byte +0x81d is not 0xff, the team decides alone:
## another team 0x97, the same 0x95. `hostile` is IsHostile(Alt held)
## (0x9de780): this client has no teams, fortress war, job modes, murder
## state or the list 0x992a90 reads, so only its Alt branch can be true
## here (INFERRED: each other branch tests a state this client never has).
## `team_mine` / `team_theirs` are -1 for none.
static func player_kind(hostile: bool, in_party: bool, stalling: bool,
		team_mine: int = -1, team_theirs: int = -1) -> String:
	var kind := "normal"
	if not in_party and hostile:
		kind = "player_hostile"
	elif stalling:
		kind = "stall"
	if team_mine >= 0:
		kind = "attack" if team_mine != team_theirs else "normal"
	return kind

## IsHostile(Alt) as far as this client can evaluate it (see player_kind):
## the Alt branch (0x9de780's `param_2 != 0`, reached when either side has no
## job and the two are not both in job suits).
static func player_hostile(alt_held: bool) -> bool:
	return alt_held

## A CICMonster under the mouse (vslot_005's 0xef1a84 branch, READ, asm
## 0x789aa0..0x789b10): attack (0x97) when its vslot 0xdc says so (always,
## for CICMonster, 0x9d3160) and the interface's set at +0x500 has key 5
## (INFERRED "attack allowed"; always, here) -- unless this player's job mode
## (vslot 0xac) is 4 and the monster is TypeID 1/2/1/2 or 1/2/1/3
## (0x779dd0 / 0x779e20: the thief and hunter NPC monsters). Mode 4 is
## INFERRED "no job" (the target window shows the plain player piece for it,
## 0x699e0b); this client has no job, so it is always 4. The TypeID is read
## off the code name: every 1/2/1/2 and 1/2/1/3 row in the box's archive is
## a `MOB_..THIEF_NPC..` / `MOB_..HUNTER_NPC..` and no other row is (11,195
## rows, MEASURED) -- a stand-in for the column, not the column.
static func monster_kind(code_name: String, jobless: bool = true) -> String:
	if jobless and is_job_monster(code_name):
		return "normal"
	return "attack"

static func is_job_monster(code_name: String) -> bool:
	var c := code_name.to_upper()
	return c.begins_with("MOB_") and (c.contains("THIEF_NPC") or c.contains("HUNTER_NPC"))

## A dropped item: 0x99, or 0x9a while the left button is held (READ: the
## input manager's +0x258, which WM_LBUTTONDOWN sets and WM_LBUTTONUP
## clears, 0xba7240's table 0xba75cc).
static func item_kind(left_held: bool) -> String:
	return "pickup_held" if left_held else "pickup"

## For the suite: forget the loaded set.
static func reset_for_test() -> void:
	_base = {}
	_loaded = false
	_source = ""
	_scaled_sets = {}
	_current_id = -1
	_current_key = ""
	_suspended = false

## For the suite: install a set without an exe.
static func install_for_test(cursors: Dictionary) -> void:
	reset_for_test()
	_base = cursors
	_loaded = true
