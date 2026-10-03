extends SceneTree

## CharacterBlobs (round 702): the Shadow Detail row against the round
## shadow, as the original's SWorld::vslot_024 draws it -- Circle under up to
## ten characters of every kind, Detail and Nothing none -- and World3D's use
## of it (every character type registers; the first video apply applies
## every row).
##
## `godot4 --headless --path client --script res://scripts/world/character_blobs_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_run.call_deferred()

## After a frame, so the nodes added to the root are inside the tree.
func _run() -> void:
	await process_frame
	# The mapping (READ): 0 Nothing, 1 Circle, 2 Detail.
	_check(not CharacterBlobs.blobs_visible(0), "Nothing: no circle")
	_check(CharacterBlobs.blobs_visible(1), "Circle: the circle")
	_check(not CharacterBlobs.blobs_visible(2), "Detail: no circle (the original draws the projected shadows instead)")
	# The size (READ: BCRadius + 5) and the colour (READ 0xa8).
	_check(is_equal_approx(CharacterBlobs.blob_size(4.0), 9.0), "BCRadius 4 (the default body) -> 9")
	_check(is_equal_approx(CharacterBlobs.blob_size(12.0), 17.0), "BCRadius 12 -> 17")
	_check(is_equal_approx(CharacterBlobs.blob_size(0.0), CharacterBlobs.DEFAULT_RADIUS + 5.0), "an unknown radius draws the default body's")
	_check(CharacterBlobs.MAX_BLOBS == 10 and is_equal_approx(CharacterBlobs.ALPHA, 168.0 / 255.0), "at most ten circles, at alpha 0xa8")

	var blobs := CharacterBlobs.new()
	root.add_child(blobs)
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	blobs.setup(ImageTexture.create_from_image(img))
	var mat := blobs.blob(0).material_override as StandardMaterial3D
	_check(mat != null and is_equal_approx(mat.albedo_color.a, CharacterBlobs.ALPHA) and mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
		"the circle's material: the texture at 0xa8 / 255 alpha, unshaded")

	# Every character kind casts one: the player, another player, a monster, an NPC.
	var kinds := ["player", "other player", "monster", "npc"]
	var casters: Array = []
	for i in 12:
		var n := Node3D.new()
		n.name = "%s_%d" % [kinds[i % kinds.size()].replace(" ", "_"), i]
		root.add_child(n)
		n.global_position = Vector3(float(i) * 10.0, 0.0, 0.0)
		CharacterBlobs.register(n, 4.0 if i != 3 else 12.0)
		casters.append(n)
	var ground := func(n: Node3D) -> float: return n.global_position.y
	blobs.update(Vector3.ZERO, 1, ground)
	_check(blobs.shown_count() == 10, "Circle with twelve characters about: ten circles (got %d)" % blobs.shown_count())
	var kinds_seen := {}
	var nearest := CharacterBlobs.nearest(casters, Vector3.ZERO, 10)
	for n in nearest:
		kinds_seen[String(n.name).get_slice("_", 0)] = true
	_check(kinds_seen.size() == 4, "the ten nearest include every kind of character (%s)" % str(kinds_seen.keys()))
	_check(nearest[0] == casters[0] and nearest[9] == casters[9], "nearest first")
	var b3 := blobs.blob(3)
	_check(b3 != null and is_equal_approx(b3.global_transform.basis.get_scale().x, 17.0)
		and is_equal_approx(b3.global_position.x, 30.0) and is_equal_approx(b3.global_position.y, CharacterBlobs.LIFT),
		"each circle sits at its character's feet at its own size (BCRadius 12 -> 17)")
	blobs.update(Vector3.ZERO, 2, ground)
	_check(blobs.shown_count() == 0, "Detail: every circle hidden, for every character kind")
	blobs.update(Vector3.ZERO, 0, ground)
	_check(blobs.shown_count() == 0, "Nothing: every circle hidden")
	blobs.update(Vector3.ZERO, 1, ground)
	_check(blobs.shown_count() == 10, "back to Circle: ten again")
	(casters[0] as Node3D).visible = false
	_check(not CharacterBlobs.nearest(casters, Vector3.ZERO, 10).has(casters[0]), "a hidden character casts none")
	_check(CharacterBlobs.nearest(casters, Vector3.ZERO, 10, 35.0).size() == 3, "none past the Character Sight Range (35: the three at 10..30)")
	var no_ground := func(_n: Node3D) -> float: return NAN
	blobs.update(Vector3.ZERO, 1, no_ground)
	_check(blobs.shown_count() == 0, "no ground found: no circle")

	# World3D's side.
	var src := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	_check(src.count("CharacterBlobs.register(") >= 4 and src.contains("CharacterBlobs.register(holder,")
		and src.contains("CharacterBlobs.register(body,") and src.contains("CharacterBlobs.register(node,")
		and src.contains("CharacterBlobs.register(player,"), "World3D registers the player, other players, monsters and NPCs")
	_check(src.contains("var before: VideoOptions = _video if _video_applied else null"),
		"the first video apply applies every row (round 702: the saved Shadow Detail reached the world only after a change)")
	_check(src.contains("directional_light.directional_shadow_max_distance = SHADOW_MAP_DISTANCE"),
		"Detail's shadow map reaches a fixed distance, not Godot's 100 that faded shadows with the zoom")

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)
