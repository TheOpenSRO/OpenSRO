extends SceneTree

## Exercises BmsReader.parse_collision and BmsCollision against synthetic
## files (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/bms/bms_collision_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _f32(v: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b

func _u16(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, v)
	return b

## Builds a real-shaped .bms carrying nothing but a collision section: one
## unit quad of two triangles, four outline edges and the one shared
## internal edge -- the same shape a real minimal object navigation mesh has.
## `flags` is the real COLLISION_FLAGS_OFFSET bitfield, so the same geometry
## can be emitted in every real record-size variant.
func _build(flags: int, events: Array[String] = []) -> PackedByteArray:
	var cell_pad := 1 if (flags & BmsReader.COLLISION_FLAG_WIDE_CELL) != 0 else 0
	var edge_pad := 1 if (flags & BmsReader.COLLISION_FLAG_WIDE_EDGE) != 0 else 0

	var sec := PackedByteArray()
	# Four vertices of a quad, raised so a height mistake can't hide at zero.
	var positions := [
		Vector3(0.0, 5.0, 0.0), Vector3(10.0, 5.0, 0.0),
		Vector3(10.0, 7.0, 10.0), Vector3(0.0, 7.0, 10.0),
	]
	sec.append_array(_u32(positions.size()))
	for i in range(positions.size()):
		var p: Vector3 = positions[i]
		sec.append_array(_f32(p.x))
		sec.append_array(_f32(p.y))
		sec.append_array(_f32(p.z))
		sec.append(0xA0 + i) # real files carry a per-vertex flag byte

	var cells := [[0, 1, 2], [0, 2, 3]]
	sec.append_array(_u32(cells.size()))
	for cell in cells:
		for idx in cell:
			sec.append_array(_u16(idx))
		sec.append_array(_u16(0)) # always zero in every real file measured
		for _p in range(cell_pad):
			sec.append(0)

	# Outline edges: real files always carry NO_CELL on the far side.
	var outline := [[0, 1, 0, 3], [1, 2, 0, 3], [2, 3, 1, 3], [3, 0, 1, 3]]
	# One internal edge, joining the two real cells, passable.
	var internal := [[0, 2, 0, 1, 4]]
	sec.append_array(_u32(outline.size()))
	for e in outline:
		sec.append_array(_u16(e[0]))
		sec.append_array(_u16(e[1]))
		sec.append_array(_u16(e[2]))
		sec.append_array(_u16(BmsReader.NO_CELL))
		sec.append(e[3])
		for _p in range(edge_pad):
			sec.append(0)
	sec.append_array(_u32(internal.size()))
	for e in internal:
		sec.append_array(_u16(e[0]))
		sec.append_array(_u16(e[1]))
		sec.append_array(_u16(e[2]))
		sec.append_array(_u16(e[3]))
		sec.append(e[4])
		for _p in range(edge_pad):
			sec.append(0)

	if (flags & BmsReader.COLLISION_FLAG_HAS_EVENTS) != 0:
		sec.append_array(_u32(events.size()))
		for name in events:
			var raw := name.to_utf8_buffer()
			sec.append_array(_u32(raw.size()))
			sec.append_array(raw)

	# Lookup grid: 2x1, first square holding both cells, second holding none.
	sec.append_array(_f32(0.0))
	sec.append_array(_f32(0.0))
	sec.append_array(_u32(2))
	sec.append_array(_u32(1))
	sec.append_array(_u32(2))
	sec.append_array(_u32(2))
	sec.append_array(_u16(0))
	sec.append_array(_u16(1))
	sec.append_array(_u32(0))

	var head := PackedByteArray()
	head.resize(BmsReader.PREAMBLE_END)
	var magic := BmsReader.MAGIC.to_ascii_buffer()
	for i in range(magic.size()):
		head[i] = magic[i]
	head.encode_u32(BmsReader.COLLISION_PTR_OFFSET, BmsReader.PREAMBLE_END)
	head.encode_u32(BmsReader.COLLISION_FLAGS_OFFSET, flags)
	return head + sec

func _initialize() -> void:
	# Every real record-size variant found in real data, plus the plain one.
	var variants := {
		0x0: "plain (8-byte cells, 9-byte edges, no events)",
		BmsReader.COLLISION_FLAG_WIDE_EDGE: "wide edges",
		BmsReader.COLLISION_FLAG_WIDE_CELL: "wide cells",
		BmsReader.COLLISION_FLAG_HAS_EVENTS: "events",
		0x6: "wide cells + events (the commonest real non-zero value)",
		0x7: "wide cells + wide edges + events",
		0x5: "wide edges + events",
	}
	for flags in variants:
		var label: String = variants[flags]
		var events: Array[String] = []
		if (flags & BmsReader.COLLISION_FLAG_HAS_EVENTS) != 0:
			events.append("EVENT")
		var cm := BmsReader.parse_collision(_build(flags, events))
		if cm == null:
			_check(false, "variant %s parses" % label)
			continue
		_check(cm.vertices.size() == 4, "variant %s: 4 vertices" % label)
		_check(cm.cells.size() == 2, "variant %s: 2 cells" % label)
		_check(cm.outline_edges.size() == 4, "variant %s: 4 outline edges" % label)
		_check(cm.internal_edges.size() == 1, "variant %s: 1 internal edge" % label)
		_check(cm.events.size() == events.size(), "variant %s: %d events" % [label, events.size()])
		_check(cm.grid_cells.size() == 2, "variant %s: grid read to the end" % label)

	# The section is self-checking: it must land exactly on the end of the
	# file, so reading it at the wrong record size has to fail rather than
	# silently produce plausible garbage. This is the property that let the
	# real bitfield be recovered at all.
	var wide := _build(BmsReader.COLLISION_FLAG_WIDE_CELL)
	wide.encode_u32(BmsReader.COLLISION_FLAGS_OFFSET, 0)
	_check(BmsReader.parse_collision(wide) == null, "wide-cell data read as narrow is rejected")
	var narrow := _build(0)
	narrow.encode_u32(BmsReader.COLLISION_FLAGS_OFFSET, BmsReader.COLLISION_FLAG_WIDE_CELL)
	_check(BmsReader.parse_collision(narrow) == null, "narrow-cell data read as wide is rejected")

	# A real .bms with no navigation data is the common case, not an error.
	var none := _build(0)
	none.encode_u32(BmsReader.COLLISION_PTR_OFFSET, 0)
	_check(BmsReader.parse_collision(none) == null, "a mesh with no collision section returns null")
	_check(BmsReader.parse_collision(PackedByteArray()) == null, "an empty buffer returns null")

	var mesh := BmsReader.parse_collision(_build(0))
	_check(mesh != null, "the plain variant parsed for the geometry checks")
	if mesh == null:
		_finish()
		return

	# Real event names must survive as text, not as bytes.
	var with_event := BmsReader.parse_collision(
		_build(BmsReader.COLLISION_FLAG_HAS_EVENTS, ["EVENT"])
	)
	_check(with_event != null and with_event.events[0] == "EVENT", "a real event name reads back as text")

	# Real edge semantics, measured across 507 real collision sections: every
	# outline edge blocks and carries NO_CELL, every internal edge is
	# passable and joins two real cells.
	for edge in mesh.outline_edges:
		_check(edge.cell_to == BmsReader.NO_CELL, "an outline edge carries NO_CELL")
	_check(BmsCollision.is_blocking(mesh.outline_edges[0]), "a real flag-3 outline edge blocks")
	_check(not BmsCollision.is_blocking(mesh.internal_edges[0]), "a real flag-4 internal edge is passable")
	_check(mesh.internal_edges[0].cell_to != BmsReader.NO_CELL, "an internal edge joins two cells")
	_check(BmsCollision.BLOCKING_FLAG_MASK == NvmCollision.BLOCKING_FLAG_MASK,
		"object and terrain navmeshes share the real blocking mask")
	_check(BmsCollision.blocking_edges(mesh).size() == 4, "collects only the real blocking edges")

	# The walkable surface must come out at the file's own real heights --
	# this is the whole point of using it instead of the render mesh.
	var faces := BmsCollision.surface_triangles(mesh)
	_check(faces.size() == 6, "one triangle per real cell (got %d verts)" % faces.size())
	var min_y := INF
	var max_y := -INF
	for v in faces:
		min_y = minf(min_y, v.y)
		max_y = maxf(max_y, v.y)
	_check(absf(min_y - 5.0) < 0.001, "surface keeps the real low height (got %s)" % min_y)
	_check(absf(max_y - 7.0) < 0.001, "surface keeps the real high height (got %s)" % max_y)
	_check(faces[0].is_equal_approx(Vector3(0.0, 5.0, 0.0)), "surface winding is left as the file stores it")

	var walls := BmsCollision.build_wall_triangles(mesh, 12.0)
	_check(walls.size() == 4 * 6, "two triangles per blocking edge (got %d verts)" % walls.size())
	var wall_max := -INF
	for v in walls:
		wall_max = maxf(wall_max, v.y)
	_check(absf(wall_max - 19.0) < 0.001,
		"walls rise the requested height above the real edge height (got %s)" % wall_max)

	# The shape ObjectLoader actually attaches must be two-sided. Godot's
	# ConcavePolygonShape3D defaults to one-sided, and with that default a
	# capsule dropped onto a real staircase's navigation mesh falls straight
	# through it -- measured, not theorised. Guarded here so the default
	# can't creep back in.
	var mesh_instance := MeshInstance3D.new()
	ObjectLoader._add_object_navmesh_collision(mesh_instance, mesh)
	var body := mesh_instance.get_node_or_null("NavmeshCollision")
	_check(body is StaticBody3D, "ObjectLoader attaches a navmesh collision body")
	var attached: ConcavePolygonShape3D = null
	if body != null:
		for child in body.get_children():
			if child is CollisionShape3D and (child as CollisionShape3D).shape is ConcavePolygonShape3D:
				attached = (child as CollisionShape3D).shape as ConcavePolygonShape3D
	_check(attached != null, "the attached shape is a ConcavePolygonShape3D")
	if attached != null:
		_check(attached.backface_collision, "the attached shape collides on both faces")
		_check(attached.get_faces().size() == 6 + 4 * 6,
			"the shape carries the real surface *and* the real walls (got %d verts)" % attached.get_faces().size())
	mesh_instance.free()

	var empty := BmsReader.CollisionMesh.new()
	_check(BmsCollision.surface_triangles(empty).is_empty(), "an empty mesh has no surface")
	_check(BmsCollision.build_wall_triangles(empty, 5.0).is_empty(), "an empty mesh builds no walls")

	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
