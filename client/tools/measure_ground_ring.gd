extends SceneTree

## Round 698's review: what GroundMarkers.step() costs a physics tick while
## the ring follows a moving body (the reviewer measured 118 us with a new
## ArrayMesh every tick). A synthetic mirrored region (never game data), a
## body walking at 50 units/s at 60 ticks a second, 1,200 ticks; prints the
## mean and the share of ticks that rebuilt the mesh. Headless on the render
## box:
##   client/tools/remote_godot.sh script res://tools/measure_ground_ring.gd
## `-- --script-path=res://...` measures another copy of ground_markers.gd
## (the round's first version, for the before figure).
##
## Round 701: a second walk on a synthetic deck (a 1 x 1200 x 100 box on
## layer 1, 5 above the highest terrain), where the ring takes the placed-floor
## drape, prints the same line with "floor" and the floor rays fired.

func _region() -> MapmReader.ParsedRegion:
	var region := MapmReader.ParsedRegion.new()
	for row in 6:
		for col in 6:
			var block := MapmReader.Block.new()
			block.plane_type = -1
			for r in 17:
				for c in 17:
					var v := MapmReader.Vertex.new()
					v.height = sin((col * 16 + c) * 0.3) * 5.0 + cos((row * 16 + r) * 0.2) * 3.0
					block.vertices.append(v)
			region.blocks.append(block)
	return region

func _initialize() -> void:
	var path := "res://scripts/world/ground_markers.gd"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--script-path="):
			path = a.substr(14)
	var script: GDScript = load(path)
	var world := Node3D.new()
	root.add_child(world)
	var grid := RegionGridState.new()
	grid.parsed_heightmaps["1_1"] = _region()
	var group := Node3D.new()
	group.name = "RealTerrain_1_1"
	group.position = Vector3(1920.0, 0.0, 0.0)
	group.scale = Vector3(1, 1, -1)
	world.add_child(group)
	var body := Node3D.new()
	world.add_child(body)
	body.global_position = Vector3(2500, 0, -900)
	var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var gm: Node3D = script.new()
	gm.call("setup", world, grid, func(_p: String) -> Texture2D: return tex,
		func(_k: String) -> Variant: return body.global_position)
	world.add_child(gm)
	await process_frame
	gm.call("attach", "k", 0)
	gm.call("step")
	var ticks := 1200
	var total := 0
	var meshes := 0
	var ring := gm.get_node("Ring") as MeshInstance3D
	var last_mesh: Mesh = ring.mesh
	for i in ticks:
		body.global_position += Vector3(50.0 / 60.0, 0, 0)
		var t0 := Time.get_ticks_usec()
		gm.call("step")
		total += Time.get_ticks_usec() - t0
		if ring.mesh != last_mesh:
			meshes += 1
			last_mesh = ring.mesh
	print("MEASURE ground ring (%s): step() %.1f us a tick (mean of %d, body at 50 units/s), %d new meshes (%.1f %% of ticks), ring visible %s" % [
		path, float(total) / ticks, ticks, meshes, 100.0 * meshes / ticks, str(ring.visible)])
	# The deck walk (round 701).
	if gm.has_method("floor_choice"):
		var deck := StaticBody3D.new()
		deck.collision_layer = 0b1
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1200, 1, 100)
		shape.shape = box
		deck.add_child(shape)
		deck.position = Vector3(3000, 12.5, -900)
		world.add_child(deck)
		await physics_frame
		await physics_frame
		body.global_position = Vector3(2450, 13.0, -900)
		gm.call("step")
		total = 0
		meshes = 0
		last_mesh = ring.mesh
		var rays0: int = gm.get("floor_rays")
		var floor_ticks := 0
		for i in ticks:
			body.global_position += Vector3(50.0 / 60.0, 0, 0)
			var t0 := Time.get_ticks_usec()
			gm.call("step")
			total += Time.get_ticks_usec() - t0
			if bool(gm.get("on_floor")):
				floor_ticks += 1
			if ring.mesh != last_mesh:
				meshes += 1
				last_mesh = ring.mesh
		print("MEASURE ground ring floor (%s): step() %.1f us a tick (mean of %d, body at 50 units/s on a deck), %d on the floor drape, %d new meshes (%.1f %% of ticks), %d floor rays (%.1f a tick), ring visible %s" % [
			path, float(total) / ticks, ticks, floor_ticks, meshes, 100.0 * meshes / ticks, int(gm.get("floor_rays")) - rays0,
			float(int(gm.get("floor_rays")) - rays0) / ticks, str(ring.visible)])
	gm.queue_free()
	await process_frame
	quit(0)
