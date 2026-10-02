extends RefCounted
class_name CharSelectMath

## The retail character select screen's numbers, as pure functions (round
## 684): where the characters stand, in what order, where the camera flies,
## what the info panel and the deletion countdown say. No nodes, no archives
## -- charselect_test.gd runs every one headless. CharacterSelect.gd and
## CharSelectStage draw what these say.
##
## Labels as everywhere: READ (sro_client.exe, address given), INFERRED,
## OURS. docs/protocol/charselect.md sections 2 and 3 hold the reading.

# --- The scene -----------------------------------------------------------------

## READ: CPSCharacterSelect::OnCreate sets the region 0x6951 (hi 105, lo 81),
## the Constantinople harbour (0x85f3f8.., `(**(*FUN_009edd60()+4))(0x6951)`).
const REGION := Vector2i(105, 81)

## READ (charselect.md section 2; the globals DAT_00ec2e48..0xec2e64 that
## FUN_0085e900 interpolates): the dock line, region-local, and the yaw at
## each end.
const DOCK_START := Vector3(95.0, -27.6, 654.0)
const DOCK_START_YAW := 3.20
const DOCK_END := Vector3(29.0, -27.6, 644.0)
const DOCK_END_YAW := 3.35

## READ: 4 characters a page (FUN_0085e900's `n >> 2` pages of 4, the page
## count `(n - 1) / 4 + 1` at FUN_0085f840).
const PER_PAGE := 4

## READ, OnCreate (0x85f3f8..0x85f4b0, the floats at 0xdd7df0..0xdd7ea0) and
## charselect.md section 3: the race-select props, region-local, and yaw.
const BOX_BSR := "res\\interface\\box.bsr"
const IDOL_EUROPE_BSR := "res\\interface\\interface_idol_europe.bsr"
const IDOL_CHINA_BSR := "res\\interface\\interface_idol_china.bsr"
const LIZARD_BSR := "res\\interface\\interface_lizard.bsr"
const BOX_POS := Vector3(155.0, -20.0, 652.0)
const BOX_YAW := 3.0
const IDOL_EUROPE_POS := Vector3(157.0, -20.0, 654.4)
const IDOL_EUROPE_YAW := 3.31
const IDOL_CHINA_POS := Vector3(156.2, -20.0, 651.6)
const IDOL_CHINA_YAW := 3.03
const LIZARD_POS := Vector3(155.6, -20.0, 651.6)
const LIZARD_YAW := 3.0
## READ: the lizard plays clip index 0 from OnCreate and is switched to clip
## index 1 when the race-select fly ends (vslot_012 case 7, 0x85d80c:
## `(*(+0x1c0)+0xc)(1, 0, 200, 0, 1.0, 1.0)`). Its clips in .bsr order are
## interface_lizard_stand, _move, _run (MEASURED, charselect.md), so index 1
## is _move (INFERRED).
const LIZARD_RACE_CLIP := 1
const LIZARD_LIST_CLIP := 0

# --- Order and placement ----------------------------------------------------------

## READ, FUN_0085def0: each character is keyed "%03d %020I64d" (level, EXP)
## into a std::multimap (FUN_00859e70 inserts with no equality test, an equal
## key going to the right), walked from its end down (FUN_00857900 is the
## tree's decrement), so the highest level -- then the highest EXP -- is
## slot 0, and among equal keys the record that came LATER in the list.
static func sort_key(level: int, exp_offset: int) -> String:
	return "%03d %020d" % [clampi(level, 0, 999), maxi(exp_offset, 0)]

## The list's indices in slot order (READ, above). Records are anything with
## `level` and `exp_offset` (LobbyNet.Character).
static func slot_order(records: Array) -> Array[int]:
	var idx: Array[int] = []
	for i in range(records.size()):
		idx.append(i)
	idx.sort_custom(func(a: int, b: int) -> bool:
		var ka := sort_key(records[a].level, records[a].exp_offset)
		var kb := sort_key(records[b].level, records[b].exp_offset)
		if ka != kb:
			return ka > kb
		return a > b)
	return idx

static func page_count(n: int) -> int:
	return 0 if n <= 0 else (n - 1) / PER_PAGE + 1

## Where slot `k` (0-based, in slot order) of `n` stands: {pos, yaw}. READ,
## FUN_0085e900: a full page puts its slots at 1/5 .. 4/5 of the dock line;
## the last, partial page of r characters at 1/(r+1) .. r/(r+1). (Retail's y
## step divides by 5 on a partial page too -- a slip with no effect, both
## ends being at the same height.)
static func slot_place(k: int, n: int) -> Dictionary:
	var page := k / PER_PAGE
	var in_page := k % PER_PAGE
	var full_pages := n / PER_PAGE
	var div := 5.0
	if page >= full_pages:
		div = float(n % PER_PAGE + 1)
	var u := float(in_page + 1) / div
	var pos := DOCK_START + (DOCK_END - DOCK_START) * u
	# READ: y always steps by /5 (see above).
	pos.y = DOCK_START.y + (DOCK_END.y - DOCK_START.y) * float(in_page + 1) / 5.0
	return {"pos": pos, "yaw": DOCK_START_YAW + (DOCK_END_YAW - DOCK_START_YAW) * u}

## The list as the scene draws it, one entry per slot in slot order:
## {"index": the record's index in the list, "pos", "yaw" (slot_place),
## "page", "action": the idle (READ, FUN_0085a580: action 0 standing, 0xe
## seated when pending deletion), "alpha": the opacity it fades in to (READ,
## FUN_0085def0: 0xff, or 0xcc pending)}.
static func scene_plan(records: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var order := slot_order(records)
	for k in range(order.size()):
		var r = records[order[k]]
		var place := slot_place(k, records.size())
		out.append({"index": order[k], "pos": place["pos"], "yaw": place["yaw"], "page": k / PER_PAGE,
			"action": BsrReader.AnimationEntry.TYPE_SITTING if r.deleting else BsrReader.AnimationEntry.TYPE_STAND,
			"alpha": PENDING_ALPHA if r.deleting else 255})
	return out

## What a selected character shows (READ, FUN_0085b680's tail): Start (14)
## and Delete (15), or for one pending deletion Restore (25), the countdown
## (26) and the message UIO_STT_CHAR_DEL_WAITING. {id: shown}, and "message".
static func selected_windows(pending: bool) -> Dictionary:
	return {14: not pending, 15: not pending, 25: pending, 26: pending,
		"message": "UIO_STT_CHAR_DEL_WAITING" if pending else ""}

# --- Height factors and the camera ------------------------------------------------

## READ: table 0xec64b0 through UI_ALCHEMYBOX::FUN_00a5b910 -- the scale
## byte's low nibble picks it; 0xFF gives 0 (CharacterAppearance has the same
## table).
static func height_factor(scale: int) -> float:
	if scale == 0xff:
		return 0.0
	return CharacterAppearance.height_factor(scale)

## READ, vslot_013 (0x85a8c0): the name label floats at the slot's height plus
## height factor x 20 (the double at 0xe1b830), or x 19 (0xdd7c90) when the
## model's vslot 0x34 is set -- INFERRED a woman (CharacterAppearance).
static func label_height(scale: int, woman: bool) -> float:
	return height_factor(scale) * (19.0 if woman else 20.0)

## The camera at the end of the list intro and after a deselect (READ, the
## globals DAT_00ec2d8c, two keys 0x20 apart; charselect.md section 2).
const LIST_KEYS := [
	{"t": 0.0, "pos": Vector3(60.0, -15.0, 700.0), "pitch": 0.1, "yaw": 3.0, "roll": 0.0, "dist": 30.0},
	{"t": 2.0, "pos": Vector3(60.0, -15.0, 660.0), "pitch": 0.1, "yaw": 3.0, "roll": 0.0, "dist": 30.0},
]
## READ: the race-select fly, DAT_00ec2dcc, 4 keys at t = k x 5.0 / 3.0
## (0xd81950, 0xe1b808; FUN_0085c4a0).
const RACE_KEYS := [
	{"t": 0.0, "pos": Vector3(60.0, -15.0, 660.0), "pitch": 0.1, "yaw": 3.0, "roll": 0.0, "dist": 30.0},
	{"t": 5.0 / 3.0, "pos": Vector3(100.0, 0.0, 625.0), "pitch": -0.1, "yaw": 2.2, "roll": 0.0, "dist": 30.0},
	{"t": 10.0 / 3.0, "pos": Vector3(150.0, -10.0, 642.0), "pitch": -0.01, "yaw": 1.8, "roll": 0.0, "dist": 30.0},
	{"t": 5.0, "pos": Vector3(165.2, -33.9, 640.3), "pitch": 0.62, "yaw": 2.53, "roll": 0.0, "dist": 30.0},
]
## READ, FUN_0085ca10: an idol click flies, over 1.0 s, from the race-select
## pose to this target at the same rotation and distance 30 (0xd82ef0).
const IDOL_TARGET_EUROPE := Vector3(168.5, -34.9, 639.1)   # 0xdd7cfc, pick index 0
const IDOL_TARGET_CHINA := Vector3(165.8, -35.1, 636.7)    # 0xdd7d08, pick index 1
const IDOL_FLY_S := 1.0
const IDOL_FLY_DIST := 30.0

## READ, FUN_0085b680: a click flies 2.0 s (0xe1b898) -- or 2.0 / 2 = 1.0 s
## when re-selecting after a list refresh (param 0) -- to the slot + (2, Y, 2),
## pitch 0, yaw 0.3925 (the double at 0xdd7cb0) - slot yaw, roll 0, distance 8
## (0xd8ad3c).
const CLICK_S := 2.0
const CLICK_OFFSET := 2.0
const CLICK_YAW_BASE := 0.39250001311302185
const CLICK_DIST := 8.0

## The clicked character's camera target height (READ, FUN_0085b680): with
## h the height factor, standing h x 16 - 28.779 (0xe1b8e0, 0xdd7c98), or
## h x 15 - 28.779 (0xd878a0) when vslot 0x34 is set (a woman, INFERRED);
## seated (pending deletion) h x 9 - 29 (0xdd7ca8, 0xdd7ca0), or h x 8.5 - 30
## (0xd99a80, 0xdd6018).
static func click_target_y(scale: int, woman: bool, pending: bool) -> float:
	var h := height_factor(scale)
	if pending:
		return h * 8.5 - 30.0 if woman else h * 9.0 - 29.0
	return (h * 15.0 if woman else h * 16.0) - 28.779172897338867

static func click_pose(slot: Dictionary, scale: int, woman: bool, pending: bool) -> IntroCameraPath.Pose:
	var p := IntroCameraPath.Pose.new()
	var at: Vector3 = slot["pos"]
	p.target = Vector3(at.x + CLICK_OFFSET, click_target_y(scale, woman, pending), at.z + CLICK_OFFSET)
	p.pitch = 0.0
	p.yaw = CLICK_YAW_BASE - float(slot["yaw"])
	p.roll = 0.0
	p.distance = CLICK_DIST
	return p

static func key_pose(k: Dictionary) -> IntroCameraPath.Pose:
	var p := IntroCameraPath.Pose.new()
	p.target = k["pos"]
	p.pitch = k["pitch"]
	p.yaw = k["yaw"]
	p.roll = k["roll"]
	p.distance = k["dist"]
	return p

## A path through `poses` at `times` (IntroCameraPath: retail's own
## Catmull-Rom camera path, FUN_004e67b0 adding the keys).
static func path_of(poses: Array, times: Array) -> IntroCameraPath:
	var kfs: Array = []
	for i in range(poses.size()):
		var p: IntroCameraPath.Pose = poses[i]
		var kf := IntroScript.Keyframe.new()
		kf.time = float(times[i])
		kf.pos = p.target
		kf.pitch = p.pitch
		kf.yaw = p.yaw
		kf.roll = p.roll
		kf.distance = p.distance
		kfs.append(kf)
	return IntroCameraPath.from_keyframes(kfs)

static func _keys_path(keys: Array, reverse: bool) -> IntroCameraPath:
	var poses: Array = []
	var times: Array = []
	var n := keys.size()
	var length: float = keys[n - 1]["t"]
	for i in range(n):
		var k: Dictionary = keys[n - 1 - i] if reverse else keys[i]
		poses.append(key_pose(k))
		times.append(length - float(k["t"]) if reverse else float(k["t"]))
	return path_of(poses, times)

## READ, FUN_0085b1f0: the list intro, the two LIST_KEYS at t = 0 and 2.
static func list_intro_path() -> IntroCameraPath:
	return _keys_path(LIST_KEYS, false)

## READ, 0x85b560 (Back, id 13): the same keys reversed, (60, -15, 660) at 0
## to (60, -15, 700) at 2.0 -- the dolly out, under a 0.5 s fade to black.
static func back_path() -> IntroCameraPath:
	return _keys_path(LIST_KEYS, true)

## READ, FUN_0085c4a0 (Create): the race fly.
static func race_path() -> IntroCameraPath:
	return _keys_path(RACE_KEYS, false)

## READ, 0x85c7e0 (Cancel 17, not in the decompile's function list): the race
## keys reversed, the table at 0 to (60, -15, 660) at 5.0.
static func race_back_path() -> IntroCameraPath:
	return _keys_path(RACE_KEYS, true)

## READ, FUN_0085c1d0 (Cancel 16, deselect): from where the camera is to the
## list's last key over 2.0 s (0xd86ecc).
static func deselect_path(from: IntroCameraPath.Pose) -> IntroCameraPath:
	return path_of([from, key_pose(LIST_KEYS[1])], [0.0, 2.0])

static func click_path(from: IntroCameraPath.Pose, to: IntroCameraPath.Pose, reselect: bool) -> IntroCameraPath:
	return path_of([from, to], [0.0, CLICK_S / (1.0 if not reselect else 2.0)])

## READ, FUN_0085ca10: `idol_index` 0 (Europe) or 1 (China).
static func idol_path(from: IntroCameraPath.Pose, idol_index: int) -> IntroCameraPath:
	var to := IntroCameraPath.Pose.new()
	to.target = IDOL_TARGET_EUROPE if idol_index == 0 else IDOL_TARGET_CHINA
	to.pitch = from.pitch
	to.yaw = from.yaw
	to.roll = from.roll
	to.distance = IDOL_FLY_DIST
	return path_of([from, to], [0.0, IDOL_FLY_S])

# --- Fades -------------------------------------------------------------------------

## READ: most of the screen's fades are 0.5 s (0xe1b7e0); the titles' swap
## on Create and Cancel 17 is 5.0 s (0xe1b86c); the black fade over an idol
## click 1.0 s; a model's own opacity fade 1.0 s (FUN_0085def0 sets +0x29c to
## 1.0 from the model's current alpha, so a new list fades every character in
## from 0, FUN_0085f840 zeroing it first).
const FADE_S := 0.5
const TITLE_SWAP_S := 5.0
const IDOL_BLACK_S := 1.0
const MODEL_FADE_S := 1.0
## READ: the opacity a pending character is drawn at (FUN_0085def0, +0x298).
const PENDING_ALPHA := 0xcc
## READ: the black fade on open, window 21 from 0x80 to 0 over 0.5 s (OnCreate).
const OPEN_FADE_FROM := 0x80

## READ, vslot_012 case 2 (FUN_00855400's third argument): a name label fades
## at one rate, a whole fade taking 0.5 s (0xe1b7d0 x the bytes left / 255,
## 0xd83108), so a label half in fades out in 0.25 s.
static func label_fade_s(from_alpha: int, to_alpha: int) -> float:
	return absf(float(to_alpha - from_alpha)) * 0.5 / 255.0

## INFERRED (charselect.md section 3): the idol panels fade at 1/3 s.
const IDOL_PANEL_FADE_S := 1.0 / 3.0

# --- The info panel --------------------------------------------------------------

## READ, FUN_0085a580: EXP x 100 (0xe1b7d8) / leveldata's EXP for the level
## (the level record's +8, FUN_00937f20), capped at 99.99 once it reaches it
## (0xd986f8 / 0xd986f0); FUN_0085b680 prints it "%.2f%%".
static func exp_percent(exp_offset: int, level_exp: int) -> float:
	if level_exp <= 0:
		return 0.0
	var f := float(exp_offset) * 100.0 / float(level_exp)
	if f >= 99.98999786376953:
		f = 99.98999786376953
	return f

static func exp_text(exp_offset: int, level_exp: int) -> String:
	return "%.2f%%" % exp_percent(exp_offset, level_exp)

## READ, FUN_0085a580: HP / (Str x 10) and MP / (Int x 10), the gauges' fill.
static func gauge_fill(value: int, stat: int) -> float:
	if stat <= 0:
		return 0.0
	return clampf(float(value) / float(stat * 10), 0.0, 1.0)

# --- Deletion -----------------------------------------------------------------------

## READ: 7 days in minutes (the double at 0xdd7d60, LobbyNet.DELETE_MINUTES).
const DELETE_MINUTES := 10080

## READ, vslot_012: the gauge reads 1 - remaining / 10080.
static func delete_gauge(minutes_left: int) -> float:
	return clampf(1.0 - float(minutes_left) / float(DELETE_MINUTES), 0.0, 1.0)

## READ, vslot_012: the minutes the countdown shows -- the list's value less one
## per 60 s of the screen's own clock (0xd880d8), at least 1.
static func minutes_now(minutes_left: int, elapsed_minutes: int) -> int:
	if elapsed_minutes < minutes_left:
		return minutes_left - elapsed_minutes
	return 1

## The countdown line: the archive's UIO_MSG_CHAR_DEL_TIME, "%d days %d hours
## %d minuites" (READ format; days, hours and minutes of the minutes left).
static func countdown_text(fmt: String, minutes: int) -> String:
	var days := minutes / 1440
	var hours := (minutes % 1440) / 60
	var mins := minutes % 60
	if fmt.count("%d") == 3:
		return fmt % [days, hours, mins]
	return "%d days %d hours %d minutes" % [days, hours, mins]

## The countdown's archive text is CIFPML markup (MEASURED, textuisystem's
## UIO_MSG_CHAR_DEL_TIME: `<sml2>... <font color="255,255,208,81">%d</font>
## days ...</sml2>`, its quotes doubled by the table's own quoting). As
## BBCode for a RichTextLabel: a `<font color="a,r,g,b">` run in that colour,
## every other tag dropped. INFERRED: CIFPML's renderer was not read, so what
## `<sml2>` does (a size or style) is not applied.
static func pml_to_bbcode(pml: String) -> String:
	var s := pml.replace("\"", "")
	var out := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if c != "<":
			out += "[lb]" if c == "[" else c
			i += 1
			continue
		var close := s.find(">", i)
		if close < 0:
			out += s.substr(i)
			break
		var tag := s.substr(i + 1, close - i - 1).strip_edges()
		var low := tag.to_lower()
		if low.begins_with("font") and low.find("color=") >= 0:
			var parts := low.substr(low.find("color=") + 6).strip_edges().split(",")
			if parts.size() >= 4:
				out += "[color=#%02x%02x%02x]" % [parts[1].to_int(), parts[2].to_int(), parts[3].to_int()]
			elif parts.size() == 3:
				out += "[color=#%02x%02x%02x]" % [parts[0].to_int(), parts[1].to_int(), parts[2].to_int()]
			else:
				out += "[color=#ffffff]"
		elif low == "/font":
			out += "[/color]"
		i = close + 1
	return out

# --- The frame's buttons ------------------------------------------------------------

## READ, OnCreate 0x85ee33..0x85efed: placed in screen pixels (not scaled),
## x from the screen width W, y from the bottom band's top (window 2's rect as
## scaled, `band2`) or the top band's bottom (`band1`):
##   12 Create, 15 Delete, 25 Restore   (W - 0xd1, band2 + 0x1b)
##   13 Back, 16 Cancel, 17 Cancel      (W - 0x69, band2 + 0x1b)
##   14 Start                           (W - 0x139, band2 + 0x1b)
##   18 the info panel                  (W - 0x10f, band1 + 0x29)
##   26 the countdown                   ((W - its width) >> 1, band2 - 0x66)
##   500 the message line               (band2.x + 0x1a, band2 + 0x1d), sized
##                                       (W - 0x1a) x 100 (vslot 0x54)
static func button_position(id: int, screen_w: int, band1_bottom: int, band2_top: int) -> Vector2:
	match id:
		12, 15, 25:
			return Vector2(screen_w - 0xd1, band2_top + 0x1b)
		13, 16, 17:
			return Vector2(screen_w - 0x69, band2_top + 0x1b)
		14:
			return Vector2(screen_w - 0x139, band2_top + 0x1b)
		18:
			return Vector2(screen_w - 0x10f, band1_bottom + 0x29)
		500:
			return Vector2(0x1a, band2_top + 0x1d)
	return Vector2.ZERO

static func countdown_position(screen_w: int, band2_top: int, width: int) -> Vector2:
	return Vector2((screen_w - width) >> 1, band2_top - 0x66)

## READ, vslot_012 case 0: the page arrows once the intro ends -- 45 at
## (10, (H - h) >> 1), 46 at (W - w - 10, the same).
static func arrow_position(id: int, screen: Vector2i, arrow: Vector2i) -> Vector2:
	var y := (screen.y - arrow.y) >> 1
	return Vector2(10, y) if id == 45 else Vector2(screen.x - arrow.x - 10, y)

## READ, vslot_012 case 7 (0x85d682..0x85d7f6): an idol panel's top-left is the
## projection of the idol's bounding-box centre, less half the panel's width,
## the x held at 5 or more; y is the projection's own.
static func idol_panel_position(projected: Vector2, panel_w: int) -> Vector2:
	var x := int(projected.x) - (panel_w >> 1)
	if x < 5:
		x = 5
	return Vector2(x, int(projected.y))
