extends Node3D

## First real 3D world scene: a player-controlled CharacterBody3D moving
## over a placeholder flat ground, synced to the server over the same
## OpMove/OpEntityEntered/OpEntityMoved/OpEntityLeft protocol the 2D
## World.tscn already decodes but never sent or rendered anything for (see
## docs/PROGRESS.md). Other connected characters render as simple labeled
## capsules at their real, server-authoritative positions.
##
## The ground is a placeholder collision box, but its *visual* mesh is
## replaced by real terrain if you set SRREVAMP_MAPM_PATH to a real
## Map.pk2 region .m file (see below) -- .mapm's grid width (17) is now a
## real, mechanistically confirmed constant (see
## docs/protocol/MAPM_FORMAT.md and MapmTerrainBuilder), not the unresolved
## blocker it used to be. Collision still uses the flat placeholder shape
## (no HeightMapShape3D wired up yet), and the terrain's real world
## position/scale relative to a player's actual spawn coordinate is still
## unconfirmed -- it's placed near the player for visibility, not at a
## confirmed real-world offset. Other entities are still labeled
## capsules -- there's no confirmed mapping from a server-side character to
## a specific real asset (this project's server doesn't track a
## race/gender/equipment loadout per character yet), so every *other*
## player shows the same placeholder regardless of who they really are.
##
## The *player's own* body is no longer a placeholder if you point this
## project at your own real game data (this project ships with none --
## BYO, see docs/LEGAL.md): set SRREVAMP_PK2_PATH to a real pk2 archive
## (e.g. Data.pk2) and this scene auto-loads a real assembled character --
## a real .bsk skeleton plus real body-part .bms meshes rigidly attached to
## it via CharacterAssembler -- using the conventional real path layout
## found during reverse-engineering (Prim/Skel/Char/China/chinaman_skel.bsk
## + Prim/Mesh/Char/China/man/*.bms). This is a fixed default (always the
## China-man body), not a real per-account race/gender selection -- there's
## no confirmed mapping to pick a different one automatically. Falls back
## to the placeholder capsule if any of that isn't found.
##
## SRREVAMP_PK2_PATH + SRREVAMP_BSR_PATH also loads one real, textured
## static scenery object nearby via ObjectLoader, and
## SRREVAMP_BSK_PATH + SRREVAMP_BAN_PATH loads a real animated decoration
## skeleton (its own separate .bsk/.ban pair, not the player's body) via
## Skeleton3DBuilder -- both accept either a loose file path or a path
## inside SRREVAMP_PK2_PATH (see AssetSource). SRREVAMP_MAPM_PATH loads real
## terrain (a real Map.pk2 region's .m file, e.g. "100\\100.m") via
## MapmTerrainBuilder -- Map.pk2 is a separate archive from Data.pk2 in a
## real retail install, so it accepts either a loose file or a path inside
## SRREVAMP_MAP_PK2_PATH (its own separate pk2 env var, not
## SRREVAMP_PK2_PATH). Any variable left unset is skipped gracefully (a
## printed hint, not an error) -- this scene works fine with none of them
## set, same as always.

const MOVE_SPEED := 6.0
const GRAVITY := 20.0
## Minimum real-world distance moved, and minimum time elapsed, before
## sending another OpMove -- avoids flooding the connection with a packet
## every single physics frame while walking.
const MIN_SEND_INTERVAL := 0.1
const MIN_SEND_DISTANCE := 0.05
## Plausible (unconfirmed) .ban playback rate -- see docs/protocol/BAN_FORMAT.md.
const BAN_FPS := 30.0

## Conventional real path layout found during reverse-engineering (private
## server package data, not from any pk2 -- but real pk2 archives are
## expected to mirror the same Prim/ tree). Not confirmed as the only
## layout real client pk2 archives use.
const PLAYER_SKELETON_PATH := "Prim\\Skel\\Char\\China\\chinaman_skel.bsk"
const PLAYER_MESH_DIR := "Prim\\Mesh\\Char\\China\\man"
const PLAYER_BODY_PARTS := ["man_pelvis", "man_torso_lower", "man_torso_upper", "man_thigh", "man_calf", "man_arm_upper", "man_arm_lower"]
## Real material file matched to the body-part meshes above -- picked
## because a real man_thigh.bms's own material_name field reads
## "chinaman_body", which is also a real layer_name found inside this real
## .bmt (confirmed by inspecting both files directly). Body-part meshes are
## shared across every China-man class/skin choice, so any class's .bmt
## works here -- "warrior" is an arbitrary fixed pick, consistent with this
## file's fixed-default player character (see top comment).
const PLAYER_MATERIAL_PATH := "Prim\\Mtrl\\Char\\China\\man\\chinaman_warrior.bmt"

@onready var player: CharacterBody3D = $Player
@onready var player_mesh: MeshInstance3D = $Player/Mesh
@onready var ground_mesh: MeshInstance3D = $Ground/Mesh
@onready var other_entities: Node3D = $OtherEntities
@onready var zone_label: Label = $UI/Control/ZoneLabel
@onready var character_label: Label = $UI/Control/CharacterLabel

var _other_bodies := {} # character_id -> Node3D
var _last_sent_pos := Vector3.ZERO
var _time_since_send := 0.0

var _real_skeleton: Skeleton3D
var _real_skeleton_track: BanReader.Bone
var _real_skeleton_time := 0.0

func _ready() -> void:
	character_label.text = "Character: %s" % NetClient.current_character_name

	var result := NetClient.last_enter_world_result
	if result != null and result.ok:
		zone_label.text = "Zone: %s" % result.zone
		player.position = Vector3(result.x, result.y, result.z)
		_last_sent_pos = player.position
		for other in result.others:
			_spawn_or_update_other(other.character_id, other.char_name, Vector3(other.x, other.y, other.z))

	NetClient.entity_entered.connect(_on_entity_entered)
	NetClient.entity_moved.connect(_on_entity_moved)
	NetClient.entity_left.connect(_on_entity_left)

	_try_load_real_scenery()
	_try_load_real_decoration_skeleton()
	_try_load_real_player_character()
	_try_load_real_terrain()

## Loads real static scenery through the exact same pk2 -> BsrReader ->
## ObjectLoader pipeline client/tools/render_asset.gd verifies standalone,
## live in this scene -- if SRREVAMP_PK2_PATH and SRREVAMP_BSR_PATH are
## both set. Skips gracefully (a printed hint, not an error) otherwise,
## since this project ships with no game data.
func _try_load_real_scenery() -> void:
	var pk2_path := OS.get_environment("SRREVAMP_PK2_PATH")
	var bsr_path := OS.get_environment("SRREVAMP_BSR_PATH")
	if pk2_path == "" or bsr_path == "":
		print("World3D: SRREVAMP_PK2_PATH/SRREVAMP_BSR_PATH not set -- no real scenery loaded")
		return

	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("World3D: could not open pk2 archive at ", pk2_path)
		return

	var obj := ObjectLoader.load_object(archive, bsr_path)
	if obj == null:
		printerr("World3D: could not load ", bsr_path, " from ", pk2_path)
		return

	# +Z is behind the third-person camera (it sits at a +Z/+Y offset from
	# the player looking back toward -Z) -- place scenery on the -Z side
	# so it's actually in view near spawn.
	obj.position = Vector3(4, 0, -4)
	add_child(obj)
	print("World3D: loaded real scenery %s from %s" % [bsr_path, pk2_path])

## Loads a real .bsk skeleton + .ban animation through Skeleton3DBuilder
## (see client/tools/render_skeleton3d_animated.gd for the standalone
## verification of this same pipeline), live in this scene as an animated
## decoration (not the player's own body -- see _try_load_real_player_character())
## -- if SRREVAMP_BSK_PATH and SRREVAMP_BAN_PATH are both set. Each accepts
## either a loose file path or a path inside SRREVAMP_PK2_PATH (see
## AssetSource). Skips gracefully otherwise.
func _try_load_real_decoration_skeleton() -> void:
	var bsk_path := OS.get_environment("SRREVAMP_BSK_PATH")
	var ban_path := OS.get_environment("SRREVAMP_BAN_PATH")
	if bsk_path == "" or ban_path == "":
		print("World3D: SRREVAMP_BSK_PATH/SRREVAMP_BAN_PATH not set -- no real decoration skeleton loaded")
		return

	var archive := _open_pk2_if_set()
	var bsk_bytes := AssetSource.read_bytes(bsk_path, archive)
	var ban_bytes := AssetSource.read_bytes(ban_path, archive)
	if bsk_bytes.is_empty() or ban_bytes.is_empty():
		printerr("World3D: could not find .bsk/.ban at ", bsk_path, " / ", ban_path)
		return

	var skel := BskReader.parse(bsk_bytes)
	var anim := BanReader.parse(ban_bytes)
	if skel == null or anim == null or anim.bones.is_empty():
		printerr("World3D: could not parse .bsk/.ban at ", bsk_path, " / ", ban_path)
		return

	_real_skeleton = Skeleton3DBuilder.build_skeleton3d(skel)
	_real_skeleton_track = anim.bones[0]
	_real_skeleton.position = Vector3(-6, 0, -6)
	# Real .bsk bind-pose data uses a much larger native scale than this
	# scene's ~2-unit-tall player capsule (position values in the hundreds
	# -- see docs/protocol/BSK_FORMAT.md) -- scale down so the whole
	# creature is visible near the player instead of dwarfing the scene.
	_real_skeleton.scale = Vector3.ONE * 0.02
	add_child(_real_skeleton)
	# A bare Skeleton3D has no visual representation of its own -- see
	# Skeleton3DBuilder.build_debug_visualization()'s doc comment.
	Skeleton3DBuilder.build_debug_visualization(_real_skeleton)
	print("World3D: loaded real skeleton %s + animation %s (%d bones, %d keyframes on track %s)" % [
		bsk_path, ban_path, skel.bones.size(), _real_skeleton_track.keyframes.size(), _real_skeleton_track.bone_name])

## Opens SRREVAMP_PK2_PATH if it's set, or returns null if it's unset or
## fails to open. Used so AssetSource can fall back to an in-archive path
## for any of the loose-file-shaped environment variables.
func _open_pk2_if_set() -> Pk2Reader:
	var pk2_path := OS.get_environment("SRREVAMP_PK2_PATH")
	if pk2_path == "":
		return null
	return Pk2Reader.open(pk2_path)

## Opens SRREVAMP_MAP_PK2_PATH if it's set, or returns null if it's unset or
## fails to open. Map.pk2 is a separate archive from SRREVAMP_PK2_PATH's
## Data.pk2 in a real retail install (confirmed from the user's own real
## client file listing: Data.pk2, Media.pk2, Map.pk2, Particles.pk2 are all
## separate files) -- so terrain gets its own pk2 env var rather than
## reusing SRREVAMP_PK2_PATH.
func _open_map_pk2_if_set() -> Pk2Reader:
	var map_pk2_path := OS.get_environment("SRREVAMP_MAP_PK2_PATH")
	if map_pk2_path == "":
		return null
	return Pk2Reader.open(map_pk2_path)

## Loads real terrain from a real Map.pk2 region .m file via MapmReader +
## MapmTerrainBuilder, replacing the placeholder ground's visual mesh (not
## its collision shape -- see this file's top comment) -- if
## SRREVAMP_MAPM_PATH is set. Accepts either a loose file path or a path
## inside SRREVAMP_MAP_PK2_PATH (see AssetSource). Skips gracefully
## otherwise.
func _try_load_real_terrain() -> void:
	var mapm_path := OS.get_environment("SRREVAMP_MAPM_PATH")
	if mapm_path == "":
		print("World3D: SRREVAMP_MAPM_PATH not set -- ground stays a placeholder")
		return

	var archive := _open_map_pk2_if_set()
	var bytes := AssetSource.read_bytes(mapm_path, archive)
	if bytes.is_empty():
		printerr("World3D: could not find terrain at ", mapm_path)
		return

	var region := MapmReader.parse(bytes)
	if region == null:
		printerr("World3D: could not parse terrain at ", mapm_path)
		return

	var terrain_mesh := MapmTerrainBuilder.build_mesh(region)
	if terrain_mesh == null:
		printerr("World3D: parsed ", region.tiles.size(), " tiles from ", mapm_path, " but couldn't recover enough complete rows for a mesh")
		return

	var terrain := MeshInstance3D.new()
	terrain.mesh = terrain_mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	terrain.material_override = mat
	# Real world-space alignment with the player's own spawn position isn't
	# confirmed (see top comment) -- centered near the player purely for
	# visibility, same as the scenery/decoration-skeleton placement choices
	# elsewhere in this file. The vertical offset uses the real height of
	# the mesh's own first-row, middle-column vertex (the part of the mesh
	# that ends up nearest the player/camera once placed) rather than the
	# whole mesh's average -- terrain height varies enormously row to row,
	# so a global average can land nowhere near where the player actually
	# is; this keeps the offset tied to the specific real vertex the player
	# spawns next to.
	#
	# MapmTerrainBuilder lays successive rows out along local +Z, but this
	# scene's third-person camera looks down -Z (+Z is behind it -- see the
	# scenery-placement comment in _try_load_real_scenery()), so an
	# unrotated terrain mesh would extend almost entirely behind the
	# camera. Rotating 180 degrees around Y flips both axes consistently
	# (a pure rotation, so front-face winding/normals stay correct) so
	# successive rows extend further *into* view instead.
	var aabb := terrain_mesh.get_aabb()
	var near_arrays := terrain_mesh.surface_get_arrays(0)
	var near_positions: PackedVector3Array = near_arrays[Mesh.ARRAY_VERTEX]
	var near_height := near_positions[MapmTerrainBuilder.GRID_WIDTH / 2].y
	terrain.rotation.y = PI
	terrain.position = Vector3(aabb.size.x / 2.0, -near_height, 0)
	add_child(terrain)
	ground_mesh.visible = false
	print("World3D: loaded real terrain from %s (%d tiles parsed, %d complete rows rendered)" % [
		mapm_path, region.tiles.size(), terrain_mesh.get_aabb().size.z / MapmTerrainBuilder.TILE_SIZE + 1])

## Auto-loads a real assembled character (real .bsk skeleton + real
## body-part .bms meshes via CharacterAssembler) as the player's own body,
## using the conventional real path layout this project found during
## reverse-engineering -- see this file's top comment for the honest scope
## of what "auto" means here (a fixed default, not real per-account
## selection). Only needs SRREVAMP_PK2_PATH; falls back to leaving the
## placeholder capsule visible if the conventional paths aren't found in
## that archive (e.g. a real archive laid out differently than the one
## sample this project could check against).
func _try_load_real_player_character() -> void:
	var archive := _open_pk2_if_set()
	if archive == null:
		print("World3D: SRREVAMP_PK2_PATH not set -- player stays a placeholder capsule")
		return

	var bsk_bytes := AssetSource.read_bytes(PLAYER_SKELETON_PATH, archive)
	if bsk_bytes.is_empty():
		printerr("World3D: could not find player skeleton at ", PLAYER_SKELETON_PATH, " in ", OS.get_environment("SRREVAMP_PK2_PATH"))
		return
	var skel := BskReader.parse(bsk_bytes)
	if skel == null:
		printerr("World3D: could not parse player skeleton at ", PLAYER_SKELETON_PATH)
		return

	var parts := {}
	for part_name in PLAYER_BODY_PARTS:
		var bytes := AssetSource.read_bytes(PLAYER_MESH_DIR + "\\" + part_name + ".bms", archive)
		if bytes.is_empty():
			continue
		var mesh := BmsReader.parse(bytes)
		if mesh != null:
			parts[part_name] = mesh
	if parts.is_empty():
		printerr("World3D: found the player skeleton but no body-part meshes under ", PLAYER_MESH_DIR)
		return

	var skeleton := Skeleton3DBuilder.build_skeleton3d(skel)
	var fallback_mat := StandardMaterial3D.new()
	fallback_mat.albedo_color = Color(0.85, 0.7, 0.55)
	var materials_by_name := _load_player_materials(archive)
	CharacterAssembler.assemble(skeleton, parts, fallback_mat, materials_by_name)

	# Real bind-pose data uses a different native scale than this scene's
	# ~1.8-unit-tall placeholder capsule -- rescale so the assembled
	# character's own bind-pose height matches it, rather than a fixed
	# guessed factor (real body-part scale isn't necessarily the same
	# across every character/skeleton pair -- see
	# docs/protocol/BSK_FORMAT.md).
	var min_y := INF
	var max_y := -INF
	for i in range(skeleton.get_bone_count()):
		var y: float = skeleton.get_bone_global_rest(i).origin.y
		min_y = min(min_y, y)
		max_y = max(max_y, y)
	var real_height := max_y - min_y
	if real_height > 0.01:
		skeleton.scale = Vector3.ONE * (1.8 / real_height)

	player.add_child(skeleton)
	player_mesh.visible = false
	print("World3D: loaded real player character (%d bones, %d body parts) from %s" % [
		skel.bones.size(), parts.size(), OS.get_environment("SRREVAMP_PK2_PATH")])

## Resolves PLAYER_MATERIAL_PATH's real .bmt (via ObjectLoader, the same
## pk2 -> BmtReader -> DdjReader pipeline already verified for scenery) into
## a Dictionary keyed by each layer's own real layer_name -- ready to pass
## straight into CharacterAssembler.assemble's materials_by_name, which
## looks parts up by their own real material_name field (the two are the
## same string in real data -- see PLAYER_MATERIAL_PATH's doc comment).
## Returns an empty Dictionary (not an error) if the .bmt isn't found at
## that conventional path, since CharacterAssembler falls back to a flat
## color in that case.
func _load_player_materials(archive: Pk2Reader) -> Dictionary:
	var material := ObjectLoader.load_material(archive, PLAYER_MATERIAL_PATH)
	if material == null:
		printerr("World3D: could not load player material at ", PLAYER_MATERIAL_PATH, " -- falling back to a flat color")
		return {}

	var by_name := {}
	for layer in material.layers:
		var godot_material := ObjectLoader.build_godot_material(archive, PLAYER_MATERIAL_PATH, layer)
		if godot_material != null:
			by_name[layer.layer_name] = godot_material
	return by_name

func _physics_process(delta: float) -> void:
	var input_dir := Vector3.ZERO
	input_dir.x = Input.get_axis("ui_left", "ui_right")
	input_dir.z = Input.get_axis("ui_up", "ui_down")
	if input_dir.length() > 0.0:
		input_dir = input_dir.normalized()

	player.velocity.x = input_dir.x * MOVE_SPEED
	player.velocity.z = input_dir.z * MOVE_SPEED
	if not player.is_on_floor():
		player.velocity.y -= GRAVITY * delta
	else:
		player.velocity.y = 0.0
	player.move_and_slide()

	_time_since_send += delta
	if _time_since_send >= MIN_SEND_INTERVAL and player.position.distance_to(_last_sent_pos) >= MIN_SEND_DISTANCE:
		NetClient.move_to(player.position.x, player.position.y, player.position.z)
		_last_sent_pos = player.position
		_time_since_send = 0.0

	if _real_skeleton != null and _real_skeleton_track.keyframes.size() > 1:
		_real_skeleton_time += delta
		var frame_count := _real_skeleton_track.keyframes.size()
		var frame_idx := int(_real_skeleton_time * BAN_FPS) % frame_count
		Skeleton3DBuilder.apply_ban_keyframe(_real_skeleton, _real_skeleton_track, frame_idx)
		Skeleton3DBuilder.update_debug_visualization(_real_skeleton.get_node("DebugVisualization"), _real_skeleton)

func _spawn_or_update_other(character_id: int, char_name: String, pos: Vector3) -> void:
	if _other_bodies.has(character_id):
		_other_bodies[character_id].position = pos
		return

	var body := Node3D.new()
	body.position = pos

	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	mesh.mesh = capsule
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.3, 0.3)
	mesh.material_override = mat
	mesh.position.y = 0.9
	body.add_child(mesh)

	var label := Label3D.new()
	label.text = char_name
	label.position.y = 2.2
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	body.add_child(label)

	other_entities.add_child(body)
	_other_bodies[character_id] = body

func _on_entity_entered(snapshot: WorldNet.EntitySnapshot) -> void:
	_spawn_or_update_other(snapshot.character_id, snapshot.char_name, Vector3(snapshot.x, snapshot.y, snapshot.z))

func _on_entity_moved(moved: WorldNet.EntityMoved) -> void:
	if _other_bodies.has(moved.character_id):
		_other_bodies[moved.character_id].position = Vector3(moved.x, moved.y, moved.z)

func _on_entity_left(character_id: int) -> void:
	if _other_bodies.has(character_id):
		_other_bodies[character_id].queue_free()
		_other_bodies.erase(character_id)

func _on_back_to_2d_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/World.tscn")
