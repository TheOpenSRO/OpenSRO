extends SceneTree

## Round 757: the minimap's signs as one MultiMesh a kind (MinimapSigns), fed
## by moves (World3D._other_moved) rather than refilled from every body each
## frame. Run headless on the render box: `client/tools/remote_godot.sh tests`.
## No game data: a plain texture.
##
## Holds: a keyed sign is written where its entity is and dropped when it goes
## (its slot reused), a list kind is refilled whole, the radius rule
## (HudMinimap.SIGN_RADIUS, READ vslot_013) counts what is drawn exactly as the
## TextureRect pool did (sign_offset under the radius), no TextureRect is made
## per sign, and the buffer goes up only when something changed. World3D's
## side (the moves, the spread re-read) is world/crowd_main_thread_test.gd's.
##
## NEGATIVE, on the base (155822c1): MinimapSigns does not exist -- the suite
## does not compile; there update_signs made a TextureRect per sign (7,005 at the
## 7,000-body lineup, MEASURED).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await process_frame
	_test_layer()
	await _test_minimap()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _tex() -> Texture2D:
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)

func _test_layer() -> void:
	var s := MinimapSigns.new()
	root.add_child(s)
	s.set_texture("other", _tex())
	s.set_texture("npc", _tex())
	var player := Vector3(1000, 0, 1000)
	var px := 160.0
	var span := HudMinimap.REGION_SPAN
	var radius := HudMinimap.SIGN_RADIUS
	# 44.5 px at 160 px a region is 534 units.
	s.put("other", 7, player + Vector3(100, 0, 0))
	s.put("other", 8, player + Vector3(0, 0, -600))
	s.put("other", 9, player + Vector3(-50, 30, 20))
	_check(s.keyed_count("other") == 3, "three keyed signs held (%d)" % s.keyed_count("other"))
	_check(s.drawn("other", player, px, radius, span) == 2, "the radius rule draws the two within 534 units, not the one 600 away (%d)" % s.drawn("other", player, px, radius, span))
	# The same rule as the TextureRect pool: sign_offset under SIGN_RADIUS.
	var want := 0
	for p in [player + Vector3(100, 0, 0), player + Vector3(0, 0, -600), player + Vector3(-50, 30, 20)]:
		if HudMinimap.sign_offset(player, p, px).length() < radius:
			want += 1
	_check(want == 2, "and sign_offset agrees (%d)" % want)
	s.put("other", 8, player + Vector3(0, 0, -300))
	_check(s.drawn("other", player, px, radius, span) == 3, "a moved sign is written where it is now")
	s.drop("other", 7)
	_check(s.drawn("other", player, px, radius, span) == 2 and s.keyed_count("other") == 2, "a dropped sign is not drawn")
	s.put("other", 11, player)
	var k: MinimapSigns.Kind = s._kinds["other"]
	_check(k.used == 3, "and its slot is used again (%d slots for 3 signs)" % k.used)
	s.put("other", 12, player, false)
	_check(s.drawn("other", player, px, radius, span) == 3, "a hidden body's sign is held but not drawn")
	# Lists (npc, monster): refilled whole each frame.
	s.set_list("npc", [player, player + Vector3(10, 0, 10)])
	_check(s.drawn("npc", player, px, radius, span) == 2, "a list kind draws its list")
	s.set_list("npc", [player])
	_check(s.drawn("npc", player, px, radius, span) == 1, "and a shorter list hides the rest")
	_check(s.get_child_count() == 0, "no node a sign")
	# The review's F2: the quad's top-left on a whole unit, as the TextureRect's
	# position was (snap_controls_to_pixels rounds it), not between pixels.
	_check(MinimapSigns.SHADER_CODE.contains("floor(centre + off - sign_half + 0.5)"), "a sign's corner is rounded to a whole unit")
	# The buffer goes up when a kind changed, and only then.
	s.place(player, px, Vector2(52.5, 52.5), radius, span)
	_check(not k.dirty, "place() sends the changed kinds")
	s.place(player + Vector3(5, 0, 0), px, Vector2(52.5, 52.5), radius, span)
	_check(not k.dirty, "the player's move is a uniform, no buffer")
	_check(k.mm != null and k.mm.instance_count >= k.used and k.mm.visible_instance_count == k.used, "the MultiMesh holds the used slots (%d of %d)" % [k.mm.visible_instance_count if k.mm != null else -1, k.used])
	# The 2D transform is the identity and the custom data the world (x, z).
	var o := 0 * MinimapSigns.FLOATS
	_check(k.buf[o] == 1.0 and k.buf[o + 5] == 1.0 and k.buf[o + 3] == 0.0 and k.buf[o + 7] == 0.0, "an instance's transform is the identity")
	s.queue_free()

func _test_minimap() -> void:
	var mm := HudMinimap.new()
	root.add_child(mm)
	await process_frame
	var signs := mm.get_node_or_null("MapClip/Signs")
	_check(signs is MinimapSigns, "the minimap's Signs node is a MinimapSigns")
	var p := Vector3(1002, -52, 917)
	mm.update_signs(p, [p + Vector3(50, 0, 0)], [p + Vector3(0, 0, 50)], [])
	_check(signs != null and signs.get_child_count() == 0, "no TextureRect per sign")
	mm.put_other(5, p + Vector3(10, 0, 0))
	mm.drop_other(5)
	_check(mm.other_ids().is_empty(), "with no artwork nothing is held (the kind draws nothing)")
	mm.queue_free()
