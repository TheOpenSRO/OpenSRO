extends RefCounted
class_name ObjectLoader

## Glue layer tying Pk2Reader + BsrReader + BmsReader + BmtReader + DdjReader
## together: given an open pk2 archive and a .bsr path inside it, builds a
## renderable, textured Node3D.
##
## Sub-mesh pieces are added as siblings with no extra transform applied --
## confirmed correct, not a gap: each .bms piece already carries its own
## absolute position baked into its vertex data (see
## docs/protocol/BSR_FORMAT.md, "Sub-mesh pieces need no separate
## transform").
##
## Not yet handled:
## - Layer-to-mesh pairing: a .bmt can define multiple material "layers",
##   and a .bsr can reference multiple mesh pieces, but no confirmed rule
##   ties a specific layer to a specific piece. When the counts match, this
##   pairs them up 1:1 by index (mesh piece i <- material layer i) as a
##   plausible but unconfirmed heuristic; otherwise every piece gets the
##   material's first layer. See docs/protocol/BMT_FORMAT.md.

## Loads the .bsr at path within archive and returns a Node3D containing one
## MeshInstance3D per mesh piece (the primary mesh plus any sub-mesh
## pieces), textured where a .bmt/.ddj could be resolved. Returns null (and
## pushes an error) on failure.
static func load_object(archive: Pk2Reader, bsr_path: String) -> Node3D:
	var bsr_entry := find_file(archive, bsr_path)
	if bsr_entry == null:
		push_error("ObjectLoader: %s not found in archive" % bsr_path)
		return null
	var bsr_data := archive.read_file(bsr_entry)
	var obj := BsrReader.parse(bsr_data)
	if obj == null:
		return null

	var root := Node3D.new()
	root.name = obj.object_name

	var mesh_paths := [obj.mesh_path]
	mesh_paths.append_array(obj.sub_mesh_paths)

	var material := load_material(archive, obj.material_path) if obj.material_path != "" else null

	var loaded_count := 0
	for i in range(mesh_paths.size()):
		var mesh_instance := load_mesh(archive, mesh_paths[i])
		if mesh_instance != null:
			if material != null and material.layers.size() > 0:
				var layer_idx := i if material.layers.size() == mesh_paths.size() else 0
				var godot_material := build_godot_material(archive, obj.material_path, material.layers[layer_idx])
				if godot_material != null:
					mesh_instance.material_override = godot_material
			root.add_child(mesh_instance)
			loaded_count += 1

	if loaded_count == 0:
		push_error("ObjectLoader: %s: none of its %d mesh piece(s) could be loaded" % [bsr_path, mesh_paths.size()])
		root.free()
		return null

	return root

## Loads and parses the .bmt at path within archive. Returns null (and
## pushes an error) on failure.
static func load_material(archive: Pk2Reader, bmt_path: String) -> BmtReader.ParsedMaterial:
	var entry := find_file(archive, bmt_path)
	if entry == null:
		push_error("ObjectLoader: %s not found in archive" % bmt_path)
		return null
	return BmtReader.parse(archive.read_file(entry))

## Builds a Godot StandardMaterial3D from a parsed material layer, resolving
## its texture (a bare filename) against the same directory bmt_path lives
## in. bmt_path is only used for that directory resolution. Returns a
## colors-only material (no albedo texture) if the layer has no texture or
## it can't be found/decoded.
static func build_godot_material(archive: Pk2Reader, bmt_path: String, layer: BmtReader.Layer) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = layer.layer_name
	mat.albedo_color = layer.diffuse

	if layer.texture_path == "":
		return mat

	var dir := bmt_path.replace("\\", "/").get_base_dir()
	var tex_path := dir + "/" + layer.texture_path if dir != "" else layer.texture_path
	var tex_entry := find_file(archive, tex_path)
	if tex_entry == null:
		push_error("ObjectLoader: texture %s (referenced by %s) not found in archive" % [tex_path, bmt_path])
		return mat

	var parsed_tex := DdjReader.parse(archive.read_file(tex_entry))
	if parsed_tex == null:
		return mat
	var godot_tex := DdjReader.to_texture(parsed_tex)
	if godot_tex != null:
		mat.albedo_texture = godot_tex

	return mat

## Loads a single .bms mesh at path within archive and returns a
## MeshInstance3D. Returns null (and pushes an error) on failure.
static func load_mesh(archive: Pk2Reader, bms_path: String) -> MeshInstance3D:
	var entry := find_file(archive, bms_path)
	if entry == null:
		push_error("ObjectLoader: %s not found in archive" % bms_path)
		return null
	var data := archive.read_file(entry)
	var mesh := BmsReader.parse(data)
	if mesh == null:
		return null

	var instance := MeshInstance3D.new()
	instance.name = mesh.mesh_name
	instance.mesh = BmsReader.to_array_mesh(mesh)
	return instance

## Resolves a Windows-style backslash path (as stored in .bsr/.bms files)
## against an already-open pk2 archive, walking one directory level at a
## time. Returns null if any component isn't found.
static func find_file(archive: Pk2Reader, path: String) -> Pk2Reader.Entry:
	var parts := path.replace("\\", "/").split("/")
	var entries := archive.read_dir()
	for i in range(parts.size()):
		var part := parts[i]
		var found: Pk2Reader.Entry = null
		for e in entries:
			if e.name.to_lower() == part.to_lower():
				found = e
				break
		if found == null:
			return null
		if i == parts.size() - 1:
			return found
		if not found.is_dir:
			return null
		entries = archive.read_dir_at(found)
	return null
