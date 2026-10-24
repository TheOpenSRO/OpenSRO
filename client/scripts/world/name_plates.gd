extends RefCounted
class_name NamePlates

## When a name plate shows (round 673). The rule is retail's, READ from
## sro_client.exe; the schedule that applies it is ours. Kept apart from
## World3D so a headless test can hold both to account.
##
## READ: a character's name is drawn by CICharactor's name pass,
## GlobalDataManager::FUN_009d0a80, which calls the object's vslot 15 with
## pass 4 (the screen-space overlay: CICMonster's 0x9d3e70 places the party
## mark beside the name box FUN_008b2d30 gives) and then the name text itself
## (FUN_008b4d90 at the projected head point, alpha 0xff -- no fade). Its only
## distance test is at 0x9d0ac3: unless the object's +0xf0 is set, it returns
## when `300.0 <= object+0x24c` (the float at 0xd85224 = 300.0, read out of
## the PE image). +0x24c is written at 0x9d6f7e by CICPlayer::vslot_005
## (0x9d6c80), message 0xd, in its walk over every object of the entity list
## (0xec4ae4): sqrt of the squared x, y and z differences between the LOCAL
## PLAYER's position (its own +0x90/+0x94/+0x98, loaded at 0x9d6ea1..0x9d6ec6)
## and the object's. So a name shows while its owner is within 300 units of
## the player, from any camera angle and at any zoom; the camera does not
## enter into it. The constructor's 1000.0 (0xda95ec, 0x9c2340) keeps a new
## object's name hidden until the first walk measures it.
##
## Before this round the client hid a plate by its distance from the CAMERA
## (GeometryInstance3D.visibility_range_end = 80, fading over 8; OURS, "a
## project choice"): with the camera up to 90 units out on its arm, a monster
## 73 units from the player showed its name from the default 42-degree pitch
## and lost it looking straight down (round 673's render: 97 plate pixels at
## camera distance 87, none at 103).
##
## NOT modelled: what object+0xf0 is (a set +0xf0 shows the name at any
## distance); the other early returns of FUN_009d0a80 (a vcall at +0xb0 on
## FUN_009edd60's object, and flag bits +0xd4 & 2 and +0x464 & 2); and the
## global byte 0xec4b58 that the overlay pass is drawn under. docs/TODO.md.
const RANGE := 300.0

## Round 811: the box behind a character's name. READ: every CICharactor's
## name setter (vtable slot 29, GlobalDataManager::FUN_009cbb90 -- players,
## NPCs, monsters and COS alike) and the title setter (slot 30, FUN_009c28a0)
## render their text through FUN_008b3bd0, which gives the text item font 0
## (FUN_00ba5460(0) -> +0x4) and the box colour 0x40000000 (FUN_008b2b90 ->
## +0xc); the item's draw (FUN_008b48b0) fills (x - 1, y - 1) .. (x + w + 1,
## y + h + 1) with that colour as the texture factor under SRCALPHA /
## INVSRCALPHA (render states 0x13 = 5, 0x14 = 6 in FUN_008b4d90) before the
## glyphs -- black at alpha 64/255. The text item is centred on its point
## (FUN_008b4d90: x - w/2, y - h/2). Round 817, READ, the box's size and
## place against the ink: the item's h (+0x4e, FUN_008b3910) is its line
## gap +0x30 (5, the constructor FUN_008b46d0) plus the font's +4, the POINT
## size GNFontChar was made with (9 for font 0; FUN_00baa110 keeps it at +4
## and makes the 12 px em from it) -- 14, so the box is 16 rows; and each
## glyph cell is drawn from the item's y down (FUN_008b2290, no per-glyph
## rise), so the cell top is y and the baseline the face's ascent below it:
## the box's top is 1 row above the cell, ascent + 1 above the baseline.
## MEASURED on the user's private-server picture (2x): 4 rows above Tahoma's
## 9-row caps, 3 below the baseline. Rounds 673-816 centred a 16-row box on
## the label's line (ascent + descent) and raised it a row, which put it half
## a row high under Tahoma (ascent 12, descent 3) -- 4.5 rows over the caps,
## 2 under the baseline, MEASURED on the user's v0.1.577 capture -- and a row
## low under the Arial fallback. Width: round 673's MEASURED 2 px either side
## of the text. Round 673 MEASURED the alpha at 0.29 off a screenshot.
const BOX_COLOUR := Color(0.0, 0.0, 0.0, 64.0 / 255.0)
const BOX_PAD_PX := 2.0
## The item's 14 rows (line gap 5 + font 0's 9) and a row either side.
const BOX_HEIGHT_PX := 16.0
## The box's top over the glyph cell's.
const BOX_OVER_CELL_PX := 1.0
## A label drawn with the box (World3D._retail_plate_look).
const BOX_META := &"plate_box"
## The box's extension left of the name, in the label's font pixels: a job
## title's width and gap (World3D._layout_job_decor), whose own box touches
## the name's in the original (2 px apart, 1 px each).
const BOX_LEFT_META := &"plate_box_left"

## The box behind `label`, in its font pixels (which FontOversampling may
## have multiplied): `position` the box's centre against the label's origin
## (y up, as Label3D's and Sprite3D's offsets), `size` whole pixels. Hung
## from the text's baseline: Label3D centres the line (Godot's ascent +
## descent) on its offset, so the baseline is (descent - ascent) / 2 from it;
## the cell's top is cell_ascent over that.
static func box_rect(label: Label3D) -> Rect2:
	var font: Font = label.font if label.font != null else ThemeDB.fallback_font
	var fk := FontOversampling.factor() if label.has_meta(FontOversampling.META) else 1.0
	var ext := float(label.get_meta(BOX_LEFT_META, 0.0))
	var text_w := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x
	var baseline := label.offset.y + (font.get_descent(label.font_size) - font.get_ascent(label.font_size)) * 0.5
	var w := ceilf(text_w + 2.0 * BOX_PAD_PX * fk + ext)
	var h := roundf(BOX_HEIGHT_PX * fk)
	var top := baseline + cell_ascent(font, label.font_size) + BOX_OVER_CELL_PX * fk
	return Rect2(Vector2(label.offset.x - ext * 0.5, top - h * 0.5), Vector2(maxf(w, 1.0), h))

## The glyph cell's height over the baseline for `font` at an em of `size`
## px: GDI's tmAscent, which the original's cell is (FUN_00baa110 asks
## GetTextMetricsA of a CreateFontIndirectA with lfHeight -em). INFERRED,
## GDI's rule, and MEASURED to match (Tahoma 12 px: 12, 4 rows over its
## 9-row caps in the user's picture): the face's OS/2 usWinAscent over its
## head unitsPerEm, times the em, rounded to nearest. Not Godot's ascent,
## which FreeType rounds UP -- Tahoma's 2049/2048 x 12 = 12.006 is 13 there,
## a row too many. A face whose tables cannot be read keeps Godot's.
static func cell_ascent(font: Font, size: int) -> float:
	var base := font
	while base is FontVariation and (base as FontVariation).base_font != null:
		base = (base as FontVariation).base_font
	var m: Vector2i = _win_ascent.get(base.get_instance_id(), Vector2i(-1, -1)) if base != null else Vector2i.ZERO
	if m.x == -1:
		m = win_ascent_of((base as FontFile).data) if base is FontFile else Vector2i.ZERO
		_win_ascent[base.get_instance_id()] = m
	if m.x <= 0 or m.y <= 0:
		return font.get_ascent(size)
	return roundf(float(m.y) * float(size) / float(m.x))

static var _win_ascent := {}

## [unitsPerEm, usWinAscent] of a TrueType/OpenType file (the first face of
## a collection), or zero when it has no head or OS/2 table.
static func win_ascent_of(data: PackedByteArray) -> Vector2i:
	var at := 0
	if data.size() >= 16 and data.slice(0, 4).get_string_from_ascii() == "ttcf":
		at = _u32(data, 12)
	if data.size() < at + 12:
		return Vector2i.ZERO
	var upm := 0
	var win := 0
	var n := _u16(data, at + 4)
	for i in range(n):
		var rec := at + 12 + i * 16
		if data.size() < rec + 16:
			break
		var tag := data.slice(rec, rec + 4).get_string_from_ascii()
		var off := _u32(data, rec + 8)
		if tag == "head" and data.size() >= off + 20:
			upm = _u16(data, off + 18)
		elif tag == "OS/2" and data.size() >= off + 76:
			win = _u16(data, off + 74)
	return Vector2i(upm, win)

static func _u16(d: PackedByteArray, at: int) -> int:
	return (d[at] << 8) | d[at + 1]

static func _u32(d: PackedByteArray, at: int) -> int:
	return (d[at] << 24) | (d[at + 1] << 16) | (d[at + 2] << 8) | d[at + 3]

## Whether a plate on an owner at `owner` shows with the player at `player`:
## strictly nearer than `within` (0x9d0ac3 returns at 300 itself).
static func shown(owner: Vector3, player: Vector3, within: float = RANGE) -> bool:
	return owner.distance_squared_to(player) < within * within

## How many frames a full pass over the plates is spread across. OURS: retail
## measures every object every frame; a GDScript pass over a crowd's 2,500
## plates is not free, so each frame tests a sixth of them -- every plate is
## re-tested within 6 frames (0.1 s at 60 fps), while a body running at the
## fastest gait moves a few units, at a boundary 300 units away.
const SWEEP_FRAMES := 6
## Plates tested a frame whatever SWEEP_FRAMES gives, so a small set is
## tested every frame.
const MIN_PER_FRAME := 32

## The plates and the round-robin that tests them. A plate is the Label3D;
## its owner is the node it hangs from (the body, the NPC's holder, the
## player), whose position is the one the rule measures. A new plate is
## tested on the next step whatever the cursor says, and is hidden until
## then, as retail's 1000.0 keeps a new object's name hidden until it is
## measured.
class Sweep:
	var _plates: Array = []
	var _fresh: Array = []
	var _cursor := 0
	## The distance a plate shows within (RANGE; the debug panel's slider
	## changes it, World3D.set_name_plate_range).
	var reach := RANGE

	## Starts tracking `label`, hidden until its first test.
	func add(label: Node3D) -> void:
		if label == null:
			return
		label.visible = false
		_fresh.append(label)

	## Tests every plate on the next step (a range change).
	func retest_all() -> void:
		_fresh.append_array(_plates)
		_plates.clear()
		_cursor = 0

	func size() -> int:
		return _plates.size() + _fresh.size()

	## Stops testing `label` (round 757: a plate NamePlateBatch draws).
	func drop(label: Node3D) -> void:
		var i := _plates.find(label)
		if i >= 0:
			_plates[i] = _plates[_plates.size() - 1]
			_plates.pop_back()
		i = _fresh.find(label)
		if i >= 0:
			_fresh.remove_at(i)

	## One frame's share: every fresh plate, then the next
	## max(MIN_PER_FRAME, ceil(size / SWEEP_FRAMES)) of the rest (at most all
	## of them once). A freed plate
	## is dropped; one with no owner in the tree (not hung yet, or its owner
	## out of the scene for a while) waits as fresh. Returns how many plates
	## were tested.
	func step(player: Vector3) -> int:
		var tested := 0
		if not _fresh.is_empty():
			var waiting: Array = []
			for label in _fresh:
				if not is_instance_valid(label):
					continue
				if not _test(label, player):
					waiting.append(label)
					continue
				tested += 1
				_plates.append(label)
			_fresh = waiting
		# The plates measured just now are not measured again this step.
		var n := _plates.size() - tested
		if n <= 0:
			return tested
		var share := mini(n, maxi(MIN_PER_FRAME, int(ceil(float(n) / float(SWEEP_FRAMES)))))
		var i := 0
		while i < share and not _plates.is_empty():
			if _cursor >= _plates.size():
				_cursor = 0
			var label = _plates[_cursor]
			var valid := is_instance_valid(label)
			if not valid or not _test(label, player):
				# Freed: dropped. Out of the tree: back to waiting.
				if valid:
					_fresh.append(label)
				_plates[_cursor] = _plates[_plates.size() - 1]
				_plates.pop_back()
			else:
				_cursor += 1
				tested += 1
			i += 1
		return tested

	## Sets `label`'s visibility by its owner's distance; false when it has no
	## owner in the tree to measure.
	func _test(label: Node3D, player: Vector3) -> bool:
		var owner := label.get_parent() as Node3D
		if owner == null or not owner.is_inside_tree():
			return false
		var near := NamePlates.shown(owner.global_position, player, reach)
		if label.visible != near:
			label.visible = near
		return true
