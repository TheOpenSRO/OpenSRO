extends SceneTree

## Round 717: party members on the minimap and the world map
## (PartyMapMarks, HudMinimap.update_party, HudWorldmap.party_world).

const HudMinimap = preload("res://scripts/ui/hud/hud_minimap.gd")
const UiBuilder = preload("res://scripts/ui/ui_builder.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _near(a: Vector2, b: Vector2, eps := 0.01) -> bool:
	return a.distance_to(b) <= eps

func _angle_near(a: float, b: float) -> bool:
	return absf(wrapf(a - b, -PI, PI)) < 0.001

func _member(jid: int, world_id: int, region: int, x: int, z: int, member_name := "") -> PartyNet.Member:
	var m := PartyNet.Member.new()
	m.jid = jid
	m.world_id = world_id
	m.region = region
	m.x = x
	m.z = z
	m.member_name = member_name
	return m

func _init() -> void:
	var here := Vector2(1000, 1000)
	var S := 160.0  # HudMinimap.TILE_PX_START, the drawn tile size at boot

	# --- the offset: (dx, -dz) / 1920 x S, x east and y down --------------
	_check(_near(PartyMapMarks.minimap_offset(here, here + Vector2(96, 0), S), Vector2(8, 0)),
		"96 units east is 8 px right at 160 px a region")
	_check(_near(PartyMapMarks.minimap_offset(here, here + Vector2(0, 96), S), Vector2(0, -8)),
		"96 units north is 8 px up (local z north, screen y down)")

	# --- dot or arrow: 47.0 map pixels (0xda0ef0), >= is the arrow --------
	var edge := 47.0 * 1920.0 / S  # 564 units at the boot zoom
	_check(not PartyMapMarks.is_arrow(PartyMapMarks.minimap_offset(here, here + Vector2(edge - 1.0, 0), S)),
		"a member just inside 47 px is the dot")
	_check(PartyMapMarks.is_arrow(PartyMapMarks.minimap_offset(here, here + Vector2(edge, 0), S)),
		"a member at exactly 47 px is the arrow (the test is >=)")
	# The switch follows the zoom: 600 units is an arrow zoomed in, a dot out.
	_check(PartyMapMarks.is_arrow(PartyMapMarks.minimap_offset(here, here + Vector2(600, 0), 256.0)),
		"600 units is the arrow at the closest zoom (256 px a region)")
	_check(not PartyMapMarks.is_arrow(PartyMapMarks.minimap_offset(here, here + Vector2(600, 0), 64.0)),
		"600 units is the dot at the farthest zoom (64 px a region)")

	# --- the arrow on the rim, one per quadrant ----------------------------
	var cases := [
		["east", Vector2(1500, 0), Vector2(47, 0), -PI],
		["north", Vector2(0, 1500), Vector2(0, -47), -PI / 2.0 - PI],
		["west", Vector2(-1500, 0), Vector2(-47, 0), 0.0],
		["south", Vector2(0, -1500), Vector2(0, 47), PI / 2.0 - PI],
		["north-east", Vector2(1500, 1500), Vector2(47, -47) / sqrt(2.0), -PI / 4.0 - PI],
	]
	for c in cases:
		var off := PartyMapMarks.minimap_offset(here, here + (c[1] as Vector2), S)
		_check(_near(PartyMapMarks.arrow_centre(off), c[2]),
			"%s: the arrow sits on the 47 px rim at %s (got %s)" % [c[0], str(c[2]), str(PartyMapMarks.arrow_centre(off))])
		_check(_angle_near(PartyMapMarks.arrow_rotation(off), c[3]),
			"%s: the arrow is turned atan2(oy, ox) - pi (got %.3f, want %.3f)" % [c[0], PartyMapMarks.arrow_rotation(off), c[3]])
	# The original's own form, -(theta + pi) with theta = acos(ox / d) negated
	# when dz < 0 (screen oy > 0), agrees for every quadrant.
	for c in cases:
		var off := PartyMapMarks.minimap_offset(here, here + (c[1] as Vector2), S)
		var theta := acos(off.x / off.length())
		if off.y > 0.0:
			theta = -theta
		_check(_angle_near(PartyMapMarks.arrow_rotation(off), -(theta + PI)),
			"%s: atan2(oy, ox) - pi equals the client's -(theta + pi)" % c[0])

	# --- records: region y steps x, region x steps z, y unused ------------
	var pr := Vector2i(97, 168)
	_check(_near(PartyMapMarks.record_local(pr, (97 << 8) | 169, 10, 20), Vector2(1930, 20)),
		"a record one region y over is 1920 further east")
	_check(_near(PartyMapMarks.record_local(pr, (96 << 8) | 168, 10, 20), Vector2(10, -1900)),
		"a record one region x lower is 1920 further south")

	# --- who is drawn -------------------------------------------------------
	var own := 7
	_check(not PartyMapMarks.minimap_draws(_member(own, 1, 0x61a8, 0, 0), own, 1), "the player is not marked")
	_check(PartyMapMarks.minimap_draws(_member(8, 1, 0x61a8, 0, 0), own, 1), "a member in the same world is marked")
	_check(not PartyMapMarks.minimap_draws(_member(8, 2, 0x61a8, 0, 0), own, 1),
		"the minimap leaves out a member of another world (record +0x68 vs +0x20e4)")
	_check(PartyMapMarks.worldmap_draws(_member(8, 2, 0x61a8, 0, 0), own),
		"the world map has no world test")
	_check(not PartyMapMarks.minimap_draws(_member(8, 1, 0x8001, 0, 0), own, 1)
		and not PartyMapMarks.worldmap_draws(_member(8, 1, 0x8001, 0, 0), own),
		"a dungeon record is not marked (OURS: no dungeon positions are sent)")

	# --- the world map's hover: the 16x16 quad inset by 2, inclusive ------
	var quad := Rect2(100, 100, 16, 16)
	_check(PartyMapMarks.hover_hit(quad, Vector2(102, 102)) and PartyMapMarks.hover_hit(quad, Vector2(113, 113)),
		"the hover rectangle is L + 2 ..= L + 13 (the corners less the half pixel, inset by 2)")
	_check(not PartyMapMarks.hover_hit(quad, Vector2(101, 108)) and not PartyMapMarks.hover_hit(quad, Vector2(114, 114))
		and not PartyMapMarks.hover_hit(quad, Vector2(108, 114)),
		"L + 1 and L + 14 are outside (0x61fecb..0x61ff2d)")
	_check(PartyMapMarks.hover_hit(quad, Vector2(113.9, 102.5)), "the mouse counts in whole pixels")

	# --- the world map's position: the player's own rule -------------------
	var w := HudWorldmap.party_world(97, 168, Vector2(1010, 690))
	_check(_near(w, Vector2((168 - 135) * 192 + 101, (97 - 92) * 192 + 69)),
		"a member at the dragon fountain is at the player's own world-map coordinates (got %s)" % str(w))

	# --- HudMinimap.update_party: pooled dots and arrows -------------------
	var builder := UiBuilder.new(null, null)
	var minimap := HudMinimap.new(builder, null, null)
	minimap.setup(null)
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	minimap._party_dot_tex = ImageTexture.create_from_image(img)
	var img2 := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	minimap._party_arrow_tex = ImageTexture.create_from_image(img2)
	var members := PackedVector2Array([here + Vector2(96, 0), here + Vector2(1500, 0), here + Vector2(0, -1500)])
	minimap.update_party(here, members)
	var report := minimap.party_marks_report()
	_check(report == "dot@(8.0,0.0) arrow@(47.0,0.0)r-180 arrow@(0.0,47.0)r-90",
		"each member has its own mark: the near one a dot, the far ones rim arrows (got '%s')" % report)
	var east := minimap.get_node_or_null("MapMarks/PartyArrows/arrow_0") as TextureRect
	_check(east != null and east.flip_h and _angle_near(east.rotation, -PI - PI / 2.0),
		"the east arrow is mirrored and turned a further -90 degrees: the quad's transposed texture")
	var near := minimap.get_node_or_null("MapMarks/PartyMarks/dot_0") as TextureRect
	_check(near != null and near.flip_h and _angle_near(near.rotation, -PI / 2.0),
		"the dot is transposed too (the same quad)")
	# What the node draws must be the client's quad: the texture transposed
	# (screen (x, y) samples texture (y, x)), then turned. An off-axis probe
	# (up and a little right in the art, which a mirror moves) follows both
	# for every quadrant; dropping flip_h or the extra -90 degrees fails it.
	var probe := Vector2(0.3, -1.0)
	for c in cases:
		var off := PartyMapMarks.minimap_offset(here, here + (c[1] as Vector2), S)
		var want := Vector2(probe.y, probe.x).rotated(PartyMapMarks.arrow_rotation(off))
		var node_rot := PartyMapMarks.arrow_rotation(off) + PartyMapMarks.TRANSPOSE_TURN
		var got := Vector2(-probe.x, probe.y).rotated(node_rot)   # flip_h, then the node's turn
		_check(_near(got, want, 0.001), "%s: the node's mirror and turn draw the transposed, turned art (got %s, want %s)"
			% [c[0], str(got), str(want)])
	_check(east != null and _angle_near(east.rotation, PartyMapMarks.arrow_rotation(Vector2(1, 0)) + PartyMapMarks.TRANSPOSE_TURN),
		"the east arrow node carries that turn")
	# The art points up (MEASURED): after the transpose and the east turn the
	# tip points east, outward.
	var tip := Vector2(0, -1)
	_check(_near(Vector2(tip.y, tip.x).rotated(-PI), Vector2(1, 0), 0.001), "the east arrow's tip points east, outward")
	var root := minimap.get_node_or_null("MapMarks/PartyMarks")
	var arrow := minimap.get_node_or_null("MapMarks/PlayerArrow")
	_check(root != null and arrow != null and root.get_index() < arrow.get_index(),
		"the party's dots are drawn under the player's own arrow")
	var arrows_root := minimap.get_node_or_null("MapMarks/PartyArrows")
	var marks := minimap.get_node_or_null("MapMarks")
	var frame := minimap.get_node_or_null("MinimapFrame")
	_check(marks != null and frame != null and marks.get_index() > frame.get_index() and not (marks as Control).clip_contents,
		"the marks are drawn over the window's frame, unclipped")
	_check(root != null and arrows_root != null and arrow != null
		and root.get_index() < arrows_root.get_index() and arrows_root.get_index() < arrow.get_index(),
		"vslot_013's order: the party's dots, then its arrows, then the player's arrow")
	minimap.update_party(here, PackedVector2Array([here + Vector2(96, 0)]))
	_check(minimap.party_marks_report() == "dot@(8.0,0.0)", "a member who leaves loses the mark")
	_check(root != null and root.get_child_count() == 1 and arrows_root != null and arrows_root.get_child_count() == 2,
		"the marks are pooled, not rebuilt")
	minimap.update_party(here, PackedVector2Array())
	_check(minimap.party_marks_report() == "", "no party, no marks")
	minimap.free()

	# --- HudWorldmap.place_party_dots --------------------------------------
	var wm := HudWorldmap.new(null)
	var canvas := Control.new()
	var marker := Control.new()
	var img3 := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	wm.make_party_layer(canvas, ImageTexture.create_from_image(img3))
	canvas.add_child(marker)
	var px := PackedVector2Array([Vector2(100.7, 50.2), Vector2(130.5, 60.9), Vector2(400, 400)])
	var nm := PackedStringArray(["Cara", "Dex", "Eve"])
	wm.place_party_dots(px, nm, false, Vector2(-1000, -1000))
	_check(wm.party_dots_report() == "(100,50) (130,60) (400,400)",
		"the dots' corners are truncated (_ftol2): centres (100,50) (130,60) (got '%s')" % wm.party_dots_report())
	_check(wm.party_hover_text() == "", "no mouse, no name")
	var layer := canvas.get_node_or_null("PartyMarks")
	_check(layer != null and layer.get_index() < marker.get_index(), "the party's dots are under the player's marker")
	# Over Dex's dot (quad at 122, 52; the hover box is 124..135 x 54..65).
	wm.place_party_dots(px, nm, false, Vector2(124, 54))
	_check(wm.party_hover_text() == "Dex", "the hovered member's name shows (got '%s')" % wm.party_hover_text())
	var label := layer.get_node_or_null("PartyHover") as Label if layer != null else null
	var dex_dot := layer.get_node_or_null("party_1") if layer != null else null
	_check(label != null and dex_dot != null and label.get_index() == dex_dot.get_index() + 1,
		"the name is drawn right after its dot, under later dots")
	_check(label != null and is_equal_approx(label.position.x, floorf(130.5 - floorf(label.size.x / 2.0)))
		and is_equal_approx(label.position.y, floorf(60.9 - 8.0 - label.size.y)),
		"the name sits centred above the quad, truncated (got %s)" % (str(label.position) if label != null else "null"))
	wm.place_party_dots(px, nm, true, Vector2(124, 54))
	_check(wm.party_hover_text() == "*Dex", "in a job party the name has its `*` (0x99a4c5)")
	wm.place_party_dots(px, nm, true, Vector2(136, 54))
	_check(wm.party_hover_text() == "", "one pixel past the hover box, no name")
	wm.place_party_dots(PackedVector2Array([px[0]]), PackedStringArray(["Cara"]), false, Vector2(-1000, -1000))
	_check(wm.party_dots_report() == "(100,50)", "a member who leaves loses the dot")
	canvas.free()
	wm.free()

	print("party_map_marks_test: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
