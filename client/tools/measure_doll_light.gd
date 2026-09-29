extends SceneTree

## Dev tool: measures how Godot lights the equipment preview (PaperDoll's
## use_equipment_view), so its key light's energy is set by a measurement
## rather than by eye (round 633).
##
## The client lights the preview in gamma space: a face turned full on to the
## camera gets its colour times 0.3 + 0.7 = 1.0, one turned away 0.3 of it.
## This puts a quad facing the camera (and so the light, which shines the way
## the camera looks) in the doll's own scene, with a StandardMaterial3D of the
## defaults the character's materials use and an albedo of 0.5 (sRGB),
## renders the doll at a sweep of key-light energies, and prints the quad's
## rendered value against the client's 0.5 * 1.0 = 128 of 255. Energy 0 leaves
## the ambient alone, against the client's 0.5 * 0.3 = 38.
##
## Needs a real GL context (not --headless):
##   xvfb-run -a vglrun -d egl0 godot4 --path client --rendering-driver opengl3 \
##     --script res://tools/measure_doll_light.gd

const ENERGIES := [0.0, 0.6, 0.7, 0.8, 0.85, 0.87, 0.88, 0.89, 0.9, 0.95, 1.0]

func _initialize() -> void:
	var doll := PaperDoll.new()
	root.add_child(doll)
	doll.use_equipment_view()
	var facing := _quad(Vector3(0, 9, 0))
	doll.get_node("DollScene").add_child(facing)
	var key := doll.get("_key") as DirectionalLight3D
	for energy in ENERGIES:
		key.light_energy = energy
		for i in 6:
			await process_frame
		var img := doll.get_texture().get_image()
		var a := _sample(img, doll.get("_camera") as Camera3D, facing.global_position)
		print("MEASURE energy %.2f: facing quad %d of 255 (client: 128 lit, 38 ambient alone)" % [energy, a])
	quit(0)

func _quad(at: Vector3) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(4, 4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.5, 0.5)
	mesh.material = mat
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	# A QuadMesh faces +Z; turned by PI it faces -Z, toward the camera.
	node.rotation.y = PI
	return node

func _sample(img: Image, camera: Camera3D, at: Vector3) -> int:
	var p := camera.unproject_position(at)
	var c := img.get_pixelv(Vector2i(clampi(int(p.x), 0, img.get_width() - 1), clampi(int(p.y), 0, img.get_height() - 1)))
	return int(round(c.r * 255.0))
