extends SceneTree

## Round 829: the worn-out marks (DurabilityMark, READ 0x67dfb8..0x67e2c7),
## the HUD figure (EquipStateImg, CEquipStateImg 0x65cc50 / 0x65cb40) and the
## wear sounds (UiSounds.durability_key, 0x8adf50).
##   godot4 --headless --path client --script res://scripts/ui/hud/durability829_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var sword := PackedInt32Array([3, 1, 6, 2])
	var ring := PackedInt32Array([3, 1, 12, 3])
	var S := DurabilityMark.State
	_check(DurabilityMark.state_for(sword, 0, 76) == S.BROKEN and DurabilityMark.state_for(ring, 0, 40) == S.BROKEN,
		"durability 0 with a maximum: broken (an accessory too)")
	_check(DurabilityMark.state_for(sword, 6, 76) == S.LOW and DurabilityMark.state_for(sword, 1, 76) == S.LOW
		and DurabilityMark.state_for(sword, 7, 76) == S.NONE, "1..6: the warning, 7 none")
	_check(DurabilityMark.state_for(ring, 3, 40) == S.NONE and DurabilityMark.state_for(sword, 0, 0) == S.NONE,
		"no warning on an accessory; nothing without a maximum")
	var frames: Array = []
	for c in 17:
		frames.append(DurabilityMark.frame_for(c))
	_check(frames == [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
		"the counter's 17 steps give frames 0 twice then 1..15 (ftol(c / 17 x 16)): %s" % str(frames))
	var icon := Control.new()
	icon.size = Vector2(32, 32)
	root.add_child(icon)
	DurabilityMark.apply(icon, S.BROKEN, null, null)
	_check(DurabilityMark.state_on(icon) == S.BROKEN and icon.modulate == Color.WHITE, "a broken mark goes over the icon, which stays lit")
	DurabilityMark.apply(icon, S.NONE, null, null)
	_check(DurabilityMark.state_on(icon) == S.NONE, "and comes off")
	icon.free()
	# The figure: worn slots 0..7, equipment that is no accessory, below 7.
	var E := EquipStateImg.State
	_check(EquipStateImg.state_for(sword, 0) == E.BROKEN and EquipStateImg.state_for(sword, 6) == E.LOW
		and EquipStateImg.state_for(sword, 7) == E.NONE and EquipStateImg.state_for(ring, 0) == E.NONE
		and EquipStateImg.state_for(PackedInt32Array(), 0) == E.NONE, "the figure: red at 0, yellow at 1..6, nothing else")
	var fig := EquipStateImg.new()
	var tex := ImageTexture.create_from_image(Image.create(68, 96, false, Image.FORMAT_RGBA8))
	fig.build(func(_p: String) -> Texture2D: return tex)
	root.add_child(fig)
	_check(not fig.visible, "with nothing worn out the figure is not shown")
	fig.show_states([E.NONE, E.BROKEN, E.NONE, E.NONE, E.NONE, E.NONE, E.LOW])
	_check(fig.visible and (fig.get_node("Part1") as Control).visible and (fig.get_node("Part6") as Control).visible
		and not (fig.get_node("Part0") as Control).visible and (fig.get_node("Base") as Control).visible,
		"the mail red and the weapon yellow on the knight")
	_check(fig.offset_left == -200.0 and fig.offset_top == 74.0 and fig.anchor_left == 1.0, "at (width - 200, 74)")
	fig.free()
	# The wear sounds.
	_check(UiSounds.durability_key(1, 0, true) == UiSounds.KEY_EQBREAK and UiSounds.durability_key(7, 6, true) == UiSounds.KEY_EQDANGER
		and UiSounds.durability_key(8, 7, true) == "" and UiSounds.durability_key(1, 0, false) == "",
		"a worn item breaking: snd_eqbreak; at exactly 6: snd_eqdanger; a bag item's fall: nothing")
	_check(UiSounds.durability_key(0, 50, false) == UiSounds.KEY_REVIVE and UiSounds.durability_key(10, 50, true) == UiSounds.KEY_REPAIR
		and UiSounds.durability_key(-1, 50, true) == "", "a rise: revive from 0, else repair; an unknown before: nothing")
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
