extends Node3D

## First real 3D world scene: a player-controlled CharacterBody3D moving
## over a placeholder flat ground, synced to the server over the same
## OpMove/OpEntityEntered/OpEntityMoved/OpEntityLeft protocol the 2D
## World.tscn already decodes but never sent or rendered anything for (see
## docs/PROGRESS.md). Other connected characters render as simple labeled
## capsules at their real, server-authoritative positions.
##
## Player/other-entity bodies and the ground are still placeholder
## primitives -- there's no confirmed mapping from a server-side character
## or a .mapo type ID to a real .bsr/.bsk/.ban asset (see
## docs/protocol/MAPO_FORMAT.md), so nothing here can *automatically* pick
## the "correct" real asset for any given entity. What *is* wired up now:
## if you point this project at your own real game data via environment
## variables (this project ships with none -- BYO, see docs/LEGAL.md), it
## loads and places real assets through the same ObjectLoader/
## Skeleton3DBuilder pipeline already proven in client/tools/'s standalone
## dev tools, live in this scene instead of a standalone screenshot:
##
## - SRREVAMP_PK2_PATH + SRREVAMP_BSR_PATH: a pk2 archive and a .bsr path
##   inside it, loaded via ObjectLoader and placed near spawn as real,
##   textured static scenery.
## - SRREVAMP_BSK_PATH + SRREVAMP_BAN_PATH: a real .bsk skeleton and .ban
##   animation (loose files -- real samples so far have only been found
##   outside any pk2, see docs/protocol/BSK_FORMAT.md), built into a real
##   Skeleton3D via Skeleton3DBuilder and placed near spawn, animated live
##   by cycling through the .ban track's keyframes at a plausible (but
##   unconfirmed -- see docs/protocol/BAN_FORMAT.md) 30fps.
##
## Any variable left unset is skipped gracefully (a printed hint, not an
## error) -- this scene works with none of them set, same as always.

const MOVE_SPEED := 6.0
const GRAVITY := 20.0
## Minimum real-world distance moved, and minimum time elapsed, before
## sending another OpMove -- avoids flooding the connection with a packet
## every single physics frame while walking.
const MIN_SEND_INTERVAL := 0.1
const MIN_SEND_DISTANCE := 0.05
## Plausible (unconfirmed) .ban playback rate -- see docs/protocol/BAN_FORMAT.md.
const BAN_FPS := 30.0

@onready var player: CharacterBody3D = $Player
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
	_try_load_real_skeleton()

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
## decoration -- if SRREVAMP_BSK_PATH and SRREVAMP_BAN_PATH are both set
## and name a real file on disk (not inside a pk2 -- real samples so far
## have only been found as loose files). Skips gracefully otherwise.
func _try_load_real_skeleton() -> void:
	var bsk_path := OS.get_environment("SRREVAMP_BSK_PATH")
	var ban_path := OS.get_environment("SRREVAMP_BAN_PATH")
	if bsk_path == "" or ban_path == "":
		print("World3D: SRREVAMP_BSK_PATH/SRREVAMP_BAN_PATH not set -- no real skeleton loaded")
		return

	var bsk_file := FileAccess.open(bsk_path, FileAccess.READ)
	var ban_file := FileAccess.open(ban_path, FileAccess.READ)
	if bsk_file == null or ban_file == null:
		printerr("World3D: could not open .bsk/.ban files at ", bsk_path, " / ", ban_path)
		return

	var skel := BskReader.parse(bsk_file.get_buffer(bsk_file.get_length()))
	var anim := BanReader.parse(ban_file.get_buffer(ban_file.get_length()))
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
