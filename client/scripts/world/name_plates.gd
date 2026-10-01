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
