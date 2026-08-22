extends Node3D

## First real 3D world scene: a player-controlled CharacterBody3D moving
## over a placeholder flat ground, synced to the server over the same
## OpMove/OpEntityEntered/OpEntityMoved/OpEntityLeft protocol the 2D
## World.tscn already decodes but never sent or rendered anything for (see
## docs/PROGRESS.md). Other connected characters render as simple labeled
## capsules at their real, server-authoritative positions.
##
## The ground is a placeholder collision box by default, but both its
## *visual* mesh and its *collision* shape are replaced by real terrain if
## you set SRREVAMP_MAPM_PATH to a real Map.pk2 region .m file (see below)
## -- .mapm's grid width (17) is now a real, mechanistically confirmed
## constant (see docs/protocol/MAPM_FORMAT.md and MapmTerrainBuilder), not
## the unresolved blocker it used to be. The real collision shape is a
## ConcavePolygonShape3D built directly from the same real triangle data as
## the visual mesh (Mesh.create_trimesh_shape() -- no separate collision
## geometry to keep in sync), so the player physically walks on the actual
## real terrain surface, not a flat box, whenever real terrain data loads.
## The terrain's real world position/scale relative to a player's actual
## spawn coordinate is still unconfirmed -- it's placed near the player for
## visibility, not at a confirmed real-world offset. Other entities are
## still labeled capsules -- there's no confirmed mapping from a
## server-side character to
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
## + Prim/Mesh/Char/China/man/*.bms). It also wears a real, fixed 6-piece
## armor set (Prim/Mesh/Item/China/man_item/clothes_03_*.bms -- arm, body,
## foot, head, leg, shoulder), attached the same rigid way via
## CharacterAssembler.assemble_equipment, plus a real, fixed one-handed
## weapon (Prim/Mesh/Item/China/weapon/blade_01.bms) attached to the real
## confirmed hand bone via CharacterAssembler.assemble_weapon. Real
## per-account race/gender selection now exists (see character.Gender
## server-side and CharacterSelect.tscn's gender picker), but this is
## otherwise a fixed body per gender (always the same China-man or
## China-woman class/skin pick) -- there's no confirmed mapping to vary
## that automatically. Which armor *pieces* show, and whether the weapon
## shows, is real, per-piece, though: gated on the player's actual,
## server-authoritative equip state across a real, decompiler-confirmed
## 8-slot layout (HELM/MAIL/SHOULDERGUARD/PANTS/BOOTS/WEAPON/SHIELD/EXTRA
## -- see docs/protocol/EQUIP_SLOTS.md and _real_player_equipped_slots()),
## not one all-or-nothing bundle. A newly-created character has nothing
## equipped, so it renders bare-skinned and bare-handed until the player
## actually equips real pieces -- mixing e.g. a real helm with no other
## armor renders correctly, not just "some vs. none". Falls back to the
## placeholder capsule if the body itself isn't found.
##
## Other connected players use their own real Gender's body too (see
## _build_assembled_character()) rather than a capsule, when
## SRREVAMP_PK2_PATH is set -- their armor pieces, weapon, and shield are
## real per-player as well: the server broadcasts each entity's actual
## live per-piece equip state as part of OpEnterWorldResult/
## OpEntityEntered (WorldNet.EntitySnapshot.armor_slots_mask/has_weapon/
## has_shield -- see server/internal/session/world.go's equippedSlots), so
## other players only show the real pieces their own account actually
## equipped, same as the local player. Falls back to the labeled capsule
## per-entity if the shared character assets never loaded.
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
## SRREVAMP_PK2_PATH). SRREVAMP_MAPM_TEXTURE_PATH additionally textures that
## terrain with a real per-region minimap image (e.g. "minimap\\100x100.ddj",
## matching the same region number as SRREVAMP_MAPM_PATH) -- these live in
## Media.pk2, a third separate archive, so it accepts either a loose file or
## a path inside its own SRREVAMP_MEDIA_PK2_PATH. Falls back to real
## per-tile vertex-color variation (see MapmTerrainBuilder) if unset -- no
## real-time 3D ground-texture system has been found yet (see
## docs/protocol/MAPM_FORMAT.md), so a region's own real minimap art is the
## closest real, region-accurate substitute currently available.
## SRREVAMP_MAPO_PATH loads real placed objects (a real Map.pk2 region's
## .o file, e.g. "0\\0.o", via SRREVAMP_MAP_PK2_PATH) and renders each with
## its real resolved .bsr model -- not a placeholder marker -- via a real
## type-ID-to-resource-path lookup (a real, root-level "object.ifo" file
## inside SRREVAMP_PK2_PATH's Data.pk2, see docs/protocol/MAPO_FORMAT.md
## for how this was found; it was a confirmed dead end earlier in this
## project). Any
## variable left unset is skipped gracefully (a printed hint, not an error)
## -- this scene works fine with none of them set, same as always.
##
## The server now has a real multi-zone concept: OpChangeZone/
## OpChangeZoneResult (NetClient.change_zone/change_zone_result, see
## docs/PROGRESS.md) let a character warp between zone labels, and
## NetClient.current_zone tracks which one they're actually in server-side.
## This scene doesn't react to that yet -- SRREVAMP_MAPM_PATH/
## SRREVAMP_MAPO_PATH above are still a one-time, env-var-driven load at
## scene startup, not re-resolved when current_zone changes. Wiring a zone
## change to actually tear down and reload this scene's terrain/objects for
## the new real region (by turning a zone label like "100/100" into
## "Map\\100\\100.m"/"Map\\100\\100.o" and re-running
## _try_load_real_terrain()/_try_load_real_map_objects()) is real, honestly
## unfinished follow-up work, not attempted here.

const MOVE_SPEED := 6.0
const GRAVITY := 20.0
## Minimum real-world distance moved, and minimum time elapsed, before
## sending another OpMove -- avoids flooding the connection with a packet
## every single physics frame while walking.
const MIN_SEND_INTERVAL := 0.1
const MIN_SEND_DISTANCE := 0.05
## Plausible (unconfirmed) .ban playback rate -- see docs/protocol/BAN_FORMAT.md.
const BAN_FPS := 30.0

## Real, per-Gender asset path layout found during reverse-engineering
## (private server package data plus, for the woman/gender-parity check,
## direct confirmation against a real retail Data.pk2 -- see
## docs/PROGRESS.md). Real client pk2 archives are expected to mirror the
## same Prim/ tree; not confirmed as the *only* layout they use. Keyed by
## the same real Gender strings as character.GenderChinaMan/GenderChinaWoman
## (server/internal/character/character.go) -- only these two, since this
## project's available real client data has complete, parallel body/
## skeleton/armor asset sets for exactly these two and not for any other
## real race found in that data (see character.go's doc comment).
##
## Body-part meshes are shared across every class/skin choice within a
## gender, so any class's .bmt works for "material" -- "warrior" is an
## arbitrary fixed pick per gender, confirmed real by direct inspection
## (each gender's man_thigh/woman_thigh.bms material_name field matches a
## real layer_name inside that gender's chinaman_warrior.bmt/
## chinawoman_warrior.bmt). "clothes_03" is likewise an arbitrary fixed
## pick among many real numbered armor sets found for each gender -- not a
## real per-account equipment loadout (see this file's top comment).
##
## China-man's real forearm mesh is "man_arm_lower"; China-woman's real
## equivalent is "woman_arm_fore" -- different real filename convention,
## same real bones (see CharacterAssembler.BODY_PART_BONES).
const GENDER_ASSET_PATHS := {
	"china_man": {
		"skeleton": "Prim\\Skel\\Char\\China\\chinaman_skel.bsk",
		"mesh_dir": "Prim\\Mesh\\Char\\China\\man",
		"body_parts": ["man_pelvis", "man_torso_lower", "man_torso_upper", "man_thigh", "man_calf", "man_arm_upper", "man_arm_lower"],
		"material": "Prim\\Mtrl\\Char\\China\\man\\chinaman_warrior.bmt",
		"equipment_mesh_dir": "Prim\\Mesh\\Item\\China\\man_item",
		"equipment_parts": ["clothes_03_aa", "clothes_03_ba", "clothes_03_fa", "clothes_03_ha", "clothes_03_la", "clothes_03_sa"],
		"equipment_material": "Prim\\Mtrl\\Item\\China\\man_item\\clothes_03.bmt",
	},
	"china_woman": {
		"skeleton": "Prim\\Skel\\Char\\China\\chinawoman_skel.bsk",
		"mesh_dir": "Prim\\Mesh\\Char\\China\\woman",
		"body_parts": ["woman_pelvis", "woman_torso_lower", "woman_torso_upper", "woman_thigh", "woman_calf", "woman_arm_upper", "woman_arm_fore"],
		"material": "Prim\\Mtrl\\Char\\China\\woman\\chinawoman_warrior.bmt",
		"equipment_mesh_dir": "Prim\\Mesh\\Item\\China\\woman_item",
		"equipment_parts": ["clothes_03_aa", "clothes_03_ba", "clothes_03_fa", "clothes_03_ha", "clothes_03_la", "clothes_03_sa"],
		"equipment_material": "Prim\\Mtrl\\Item\\China\\woman_item\\clothes_03.bmt",
	},
}
## Falls back to this real gender's assets when a requested gender's assets
## didn't load (or a peer reports an unrecognized gender string) -- matches
## character.DefaultGender server-side.
const DEFAULT_GENDER := "china_man"

## Real weapon mesh + material, found during reverse-engineering under a
## faction-wide (not per-gender) real folder -- Prim\Mesh\Item\China\weapon\
## has no man/woman split, unlike body/armor meshes, so this is shared
## across both real genders. "blade_01" is an arbitrary fixed pick among
## many real numbered weapons found (same honesty level as GENDER_ASSET_
## PATHS's class/armor-set picks), attached via
## CharacterAssembler.assemble_weapon to the real confirmed WEAPON_BONE.
## The material path was found by parsing a real blade_01.bms and matching
## its own real material_name field ("blade1_5") against a real .bmt file
## of the same name in the weapon material folder -- the same real
## name-matching mechanism every other equipped mesh in this project uses.
const PLAYER_WEAPON_PATH := "Prim\\Mesh\\Item\\China\\weapon\\blade_01.bms"
const PLAYER_WEAPON_MATERIAL_PATH := "Prim\\Mtrl\\Item\\China\\weapon\\blade1_5.bmt"

## Real shield mesh + material -- same real weapon folder as
## PLAYER_WEAPON_PATH (shields aren't a separate top-level folder, and
## like weapons aren't gender-split), "shield_11" an arbitrary fixed pick
## among many real numbered shields found, attached via
## CharacterAssembler.assemble_shield to the real confirmed SHIELD_BONE.
## Material path found the same real name-matched way: a real
## shield_11.bms's own material_name field ("shield_11") matches a real
## .bmt file of the same name.
const PLAYER_SHIELD_PATH := "Prim\\Mesh\\Item\\China\\weapon\\shield_11.bms"
const PLAYER_SHIELD_MATERIAL_PATH := "Prim\\Mtrl\\Item\\China\\weapon\\shield_11.bmt"

## Real, root-level file inside Data.pk2 (SRREVAMP_PK2_PATH) mapping a real
## .mapo placement's type ID to a real .bsr resource path -- see
## docs/protocol/MAPO_FORMAT.md and ObjidxReader for the full derivation.
## This was a confirmed dead end earlier in this project (no such mapping
## had been found); it turned up once server/internal/pk2's directory-chain
## bug was fixed, since this file lives inside a real archive folder that
## bug was silently dropping from every listing.
const OBJECT_INDEX_PATH := "object.ifo"
## How many real *placements* from SRREVAMP_MAPO_PATH's region to
## instantiate -- an arbitrary, honestly-scoped cap, not a real engine
## limit. Distinct real .bsr models are only parsed once each and
## duplicated for repeat placements (see _try_load_real_map_objects), so
## this mostly bounds real node/instance count, not real file parsing.
const MAX_MAP_OBJECTS := 300

@onready var player: CharacterBody3D = $Player
@onready var player_mesh: MeshInstance3D = $Player/Mesh
@onready var ground_mesh: MeshInstance3D = $Ground/Mesh
@onready var ground_collision: CollisionShape3D = $Ground/Collision
@onready var other_entities: Node3D = $OtherEntities
@onready var zone_label: Label = $UI/Control/ZoneLabel
@onready var character_label: Label = $UI/Control/CharacterLabel

var _other_bodies := {} # character_id -> Node3D
var _last_sent_pos := Vector3.ZERO
var _time_since_send := 0.0

var _real_skeleton: Skeleton3D
var _real_skeleton_track: BanReader.Bone
var _real_skeleton_time := 0.0

## Cached, parsed real character assets, one entry per real Gender (see
## GENDER_ASSET_PATHS), loaded once by _load_character_assets() and reused
## by _build_assembled_character() to build a fresh Skeleton3D per
## character instance (player or other) -- reparsing the same .bms/.bmt
## files for every single connected player would be real, avoidable waste.
## Keyed by gender string; a gender with no entry here means its assets
## weren't found (or SRREVAMP_PK2_PATH isn't set at all) -- callers fall
## back to DEFAULT_GENDER, and to the placeholder capsule if even that
## didn't load.
var _character_assets: Dictionary = {}

## Cached, parsed real weapon mesh + resolved material (see
## PLAYER_WEAPON_PATH), shared across every gender/character instance --
## real weapon meshes aren't gender-split, unlike body/armor. Stays null
## if SRREVAMP_PK2_PATH isn't set or the weapon path isn't found.
var _weapon_mesh: BmsReader.ParsedMesh
var _weapon_materials: Dictionary = {}

## Cached, parsed real shield mesh + resolved material (see
## PLAYER_SHIELD_PATH), shared across every gender/character instance --
## same reasoning as _weapon_mesh. Stays null if SRREVAMP_PK2_PATH isn't
## set or the shield path isn't found.
var _shield_mesh: BmsReader.ParsedMesh
var _shield_materials: Dictionary = {}

func _ready() -> void:
	character_label.text = "Character: %s" % NetClient.current_character_name

	_load_character_assets()

	var result := NetClient.last_enter_world_result
	if result != null and result.ok:
		zone_label.text = "Zone: %s" % result.zone
		player.position = Vector3(result.x, result.y, result.z)
		_last_sent_pos = player.position
		for other in result.others:
			_spawn_or_update_other(other.character_id, other.char_name, Vector3(other.x, other.y, other.z), other.armor_slots_mask, other.gender, other.has_weapon, other.has_shield)

	NetClient.entity_entered.connect(_on_entity_entered)
	NetClient.entity_moved.connect(_on_entity_moved)
	NetClient.entity_left.connect(_on_entity_left)

	_try_load_real_scenery()
	_try_load_real_decoration_skeleton()
	_try_apply_real_player_character()
	_try_load_real_terrain()
	_try_load_real_map_objects()

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

## Opens SRREVAMP_MEDIA_PK2_PATH if it's set, or returns null if it's unset
## or fails to open. A real client's per-map-region minimap image (see
## SRREVAMP_MAPM_TEXTURE_PATH below) lives in Media.pk2, a third separate
## archive from both Data.pk2 and Map.pk2 in a real retail install.
func _open_media_pk2_if_set() -> Pk2Reader:
	var media_pk2_path := OS.get_environment("SRREVAMP_MEDIA_PK2_PATH")
	if media_pk2_path == "":
		return null
	return Pk2Reader.open(media_pk2_path)

## Loads a real per-region minimap image (SRREVAMP_MAPM_TEXTURE_PATH, e.g.
## "minimap\100x100.ddj") as the terrain's real ground texture, if set.
## Accepts either a loose file path or a path inside SRREVAMP_MEDIA_PK2_PATH
## (see AssetSource) -- a real client's minimap images live in Media.pk2,
## confirmed via this project's own real-file search tooling
## (server/cmd/pk2list) against a real client install.
##
## This is an honest substitution, not a claim that this is the literal
## real-time 3D ground texture: no real-time multi-layer terrain-texture
## system (nor a lookup from a per-tile byte to a specific real texture
## file) has been found anywhere in this project's available real data --
## see docs/protocol/MAPM_FORMAT.md for that search. A region's own real
## minimap art is genuine, region-specific real game data (grass/dirt/rock
## color baked from that exact region), and looks far closer to the real
## game than the flat/procedural fallback color this function returns null
## for -- but it's a real top-down painted image, not sampled per-tile 3D
## terrain texture data.
func _load_real_terrain_texture() -> Texture2D:
	var tex_path := OS.get_environment("SRREVAMP_MAPM_TEXTURE_PATH")
	if tex_path == "":
		return null

	var archive := _open_media_pk2_if_set()
	var bytes := AssetSource.read_bytes(tex_path, archive)
	if bytes.is_empty():
		printerr("World3D: could not find terrain texture at ", tex_path)
		return null

	var parsed := DdjReader.parse(bytes)
	if parsed == null:
		printerr("World3D: could not parse terrain texture at ", tex_path)
		return null

	return DdjReader.to_texture(parsed)

## Loads real terrain from a real Map.pk2 region .m file via MapmReader +
## MapmTerrainBuilder, replacing both the placeholder ground's visual mesh
## and its collision shape (see this file's top comment) -- if
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
	var real_texture := _load_real_terrain_texture()
	var aabb := terrain_mesh.get_aabb()
	var row_count_estimate := aabb.size.z / MapmTerrainBuilder.TILE_SIZE + 1
	if real_texture != null:
		mat.albedo_texture = real_texture
		# The mesh's own UVs (see MapmTerrainBuilder) stretch 0..1 across
		# the whole recovered strip, which can be dozens of real rows long
		# -- squishing one square minimap image over that whole length
		# reads as heavy streaking rather than ground detail. Repeating it
		# roughly once per GRID_WIDTH rows (a real, confirmed value -- see
		# MapmTerrainBuilder) keeps each repeat closer to the image's own
		# roughly-square real aspect ratio instead of one giant stretch.
		mat.uv1_scale = Vector3(1.0, max(row_count_estimate / float(MapmTerrainBuilder.GRID_WIDTH), 1.0), 1.0)
	else:
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
	var near_arrays := terrain_mesh.surface_get_arrays(0)
	var near_positions: PackedVector3Array = near_arrays[Mesh.ARRAY_VERTEX]
	var near_height := near_positions[MapmTerrainBuilder.GRID_WIDTH / 2].y
	terrain.rotation.y = PI
	terrain.position = Vector3(aabb.size.x / 2.0, -near_height, 0)
	add_child(terrain)
	ground_mesh.visible = false
	ground_collision.disabled = true

	var terrain_body := StaticBody3D.new()
	var terrain_shape := CollisionShape3D.new()
	terrain_shape.shape = terrain_mesh.create_trimesh_shape()
	terrain_body.add_child(terrain_shape)
	terrain.add_child(terrain_body)

	print("World3D: loaded real terrain from %s (%d tiles parsed, %d complete rows rendered, real collision shape built)" % [
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
## Parses and caches, once at scene startup, real character assets for
## *every* real Gender in GENDER_ASSET_PATHS -- both _try_apply_real_
## player_character and every _spawn_or_update_other call reuse this same
## parsed data (keyed by gender, see _character_assets) rather than
## re-reading/re-parsing the same real .bms/.bmt files per character. A
## gender whose conventional real paths aren't found in the archive simply
## gets no entry (not an error -- see _build_assembled_character's
## DEFAULT_GENDER fallback). Leaves _character_assets empty if
## SRREVAMP_PK2_PATH isn't set at all.
func _load_character_assets() -> void:
	var archive := _open_pk2_if_set()
	if archive == null:
		print("World3D: SRREVAMP_PK2_PATH not set -- characters stay placeholders")
		return

	for gender in GENDER_ASSET_PATHS:
		var paths: Dictionary = GENDER_ASSET_PATHS[gender]

		var bsk_bytes := AssetSource.read_bytes(paths["skeleton"], archive)
		if bsk_bytes.is_empty():
			printerr("World3D: could not find %s skeleton at %s in %s" % [gender, paths["skeleton"], OS.get_environment("SRREVAMP_PK2_PATH")])
			continue
		var skel := BskReader.parse(bsk_bytes)
		if skel == null:
			printerr("World3D: could not parse %s skeleton at %s" % [gender, paths["skeleton"]])
			continue

		var parts := {}
		for part_name in paths["body_parts"]:
			var bytes := AssetSource.read_bytes(paths["mesh_dir"] + "\\" + part_name + ".bms", archive)
			if bytes.is_empty():
				continue
			var mesh := BmsReader.parse(bytes)
			if mesh != null:
				parts[part_name] = mesh
		if parts.is_empty():
			printerr("World3D: found the %s skeleton but no body-part meshes under %s" % [gender, paths["mesh_dir"]])
			continue

		var equipment_parts := {}
		for part_name in paths["equipment_parts"]:
			var eq_bytes := AssetSource.read_bytes(paths["equipment_mesh_dir"] + "\\" + part_name + ".bms", archive)
			if eq_bytes.is_empty():
				continue
			var eq_mesh := BmsReader.parse(eq_bytes)
			if eq_mesh != null:
				equipment_parts[part_name] = eq_mesh

		var equipment_materials := {}
		if not equipment_parts.is_empty():
			equipment_materials = _load_real_materials(archive, paths["equipment_material"])

		_character_assets[gender] = {
			"skel": skel,
			"body_parts": parts,
			"body_materials": _load_real_materials(archive, paths["material"]),
			"equipment_parts": equipment_parts,
			"equipment_materials": equipment_materials,
		}
		print("World3D: cached real %s character assets (%d bones, %d body parts, %d equipment parts) from %s" % [
			gender, skel.bones.size(), parts.size(), equipment_parts.size(), OS.get_environment("SRREVAMP_PK2_PATH")])

	var weapon_bytes := AssetSource.read_bytes(PLAYER_WEAPON_PATH, archive)
	if not weapon_bytes.is_empty():
		var weapon_mesh := BmsReader.parse(weapon_bytes)
		if weapon_mesh != null:
			_weapon_mesh = weapon_mesh
			_weapon_materials = _load_real_materials(archive, PLAYER_WEAPON_MATERIAL_PATH)
			print("World3D: cached real weapon mesh (%d verts) from %s" % [weapon_mesh.vertices.size(), OS.get_environment("SRREVAMP_PK2_PATH")])

	var shield_bytes := AssetSource.read_bytes(PLAYER_SHIELD_PATH, archive)
	if not shield_bytes.is_empty():
		var shield_mesh := BmsReader.parse(shield_bytes)
		if shield_mesh != null:
			_shield_mesh = shield_mesh
			_shield_materials = _load_real_materials(archive, PLAYER_SHIELD_MATERIAL_PATH)
			print("World3D: cached real shield mesh (%d verts) from %s" % [shield_mesh.vertices.size(), OS.get_environment("SRREVAMP_PK2_PATH")])

## Maps CharacterAssembler's real 2-letter equipment-slot codes (see
## EQUIPMENT_SLOT_BONES) to the real, decompiler-confirmed slot constants
## in EquipmentNet (see docs/protocol/EQUIP_SLOTS.md). "aa" (arm/forearm)
## has no confirmed real slot name of its own -- rendered together with
## "ba" (MAIL/body) below, the same bundling this project's one fixed
## armor set always used before per-piece slots existed.
const EQUIPMENT_CODE_TO_SLOT := {
	"ha": EquipmentNet.SLOT_HELM,
	"ba": EquipmentNet.SLOT_MAIL,
	"sa": EquipmentNet.SLOT_SHOULDER_GUARD,
	"la": EquipmentNet.SLOT_PANTS,
	"fa": EquipmentNet.SLOT_BOOTS,
}

## Filters parts (CharacterAssembler-shaped part_name -> ParsedMesh) down
## to only the pieces whose real slot bit is set in armor_slots_mask (see
## EQUIPMENT_CODE_TO_SLOT and EquipmentNet.ARMOR_SLOTS for the bit
## meaning). A part whose code isn't in EQUIPMENT_CODE_TO_SLOT (i.e. "aa")
## is included whenever "ba" (MAIL) is, per that const's doc comment.
func _filter_equipped_parts(parts: Dictionary, armor_slots_mask: int) -> Dictionary:
	var mail_bit_index := EquipmentNet.ARMOR_SLOTS.find(EquipmentNet.SLOT_MAIL)
	var mail_equipped := mail_bit_index != -1 and (armor_slots_mask & (1 << mail_bit_index)) != 0

	var out := {}
	for part_name in parts:
		var code: String = CharacterAssembler._equipment_slot(part_name)
		if not EQUIPMENT_CODE_TO_SLOT.has(code):
			if code == "aa" and mail_equipped:
				out[part_name] = parts[part_name]
			continue
		var slot: int = EQUIPMENT_CODE_TO_SLOT[code]
		var bit_index := EquipmentNet.ARMOR_SLOTS.find(slot)
		if bit_index != -1 and (armor_slots_mask & (1 << bit_index)) != 0:
			out[part_name] = parts[part_name]
	return out

## Builds one fresh, independent Skeleton3D + assembled body/equipment from
## the cached data _load_character_assets() parsed for the requested real
## gender -- each character instance (player or other) needs its own
## Skeleton3D node, so this re-runs CharacterAssembler against the shared
## parsed meshes rather than reparsing files. Falls back to DEFAULT_GENDER
## if gender's assets never loaded (or gender is empty/unrecognized -- e.g.
## an older peer, or the local player's own EnterWorldResult didn't carry
## one yet). Returns null only if even the default's assets never loaded.
func _build_assembled_character(armor_slots_mask: int = 0, gender: String = DEFAULT_GENDER, include_weapon: bool = false, include_shield: bool = false) -> Skeleton3D:
	var assets: Dictionary = _character_assets.get(gender, _character_assets.get(DEFAULT_GENDER, {}))
	if assets.is_empty():
		return null

	var skeleton := Skeleton3DBuilder.build_skeleton3d(assets["skel"])
	var fallback_mat := StandardMaterial3D.new()
	fallback_mat.albedo_color = Color(0.85, 0.7, 0.55)
	CharacterAssembler.assemble(skeleton, assets["body_parts"], fallback_mat, assets["body_materials"])
	var equipped_parts := _filter_equipped_parts(assets["equipment_parts"], armor_slots_mask)
	if not equipped_parts.is_empty():
		CharacterAssembler.assemble_equipment(skeleton, equipped_parts, null, assets["equipment_materials"])
	if include_weapon and _weapon_mesh != null:
		var weapon_material: Material = _weapon_materials.get(_weapon_mesh.material_name, null)
		CharacterAssembler.assemble_weapon(skeleton, _weapon_mesh, weapon_material)
	if include_shield and _shield_mesh != null:
		var shield_material: Material = _shield_materials.get(_shield_mesh.material_name, null)
		CharacterAssembler.assemble_shield(skeleton, _shield_mesh, shield_material)

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

	return skeleton

## Attaches a freshly-built real assembled character (see
## _build_assembled_character()) to the player node, hiding the
## placeholder capsule -- if the shared character assets loaded. Leaves
## the placeholder capsule visible otherwise.
##
## Whether the assembled character wears its armor/weapon is now driven by
## the real, server-authoritative equip state (EquipmentNet/OP_LIST via
## NetClient.list_equipment), not shown unconditionally -- a newly-created
## character has nothing equipped by default, so this makes the previous
## "everyone always wears the one fixed armor set" behavior more honest:
## the armor/weapon meshes are real either way, but now they only appear
## once the player has actually equipped something in that real slot.
func _try_apply_real_player_character() -> void:
	var equipped := await _real_player_equipped_slots()
	var gender := DEFAULT_GENDER
	if NetClient.last_enter_world_result != null and NetClient.last_enter_world_result.gender != "":
		gender = NetClient.last_enter_world_result.gender
	var skeleton := _build_assembled_character(equipped[0], gender, equipped[1], equipped[2])
	if skeleton == null:
		return
	player.add_child(skeleton)
	player_mesh.visible = false

## Queries the real server for the local player's actual equipped items
## (the same EquipmentNet protocol the 2D equipment HUD already uses) and
## reports [armor_slots_mask, has_weapon, has_shield] -- a real per-piece
## bitmask (see EquipmentNet.ARMOR_SLOTS) and whether SLOT_WEAPON/
## SLOT_SHIELD are occupied. Returns [0, false, false] without querying if
## there's no live server connection -- e.g. the standalone dev-tool/
## screenshot contexts used throughout this project's asset work, which
## load World3D.tscn directly with SRREVAMP_* env vars set but no real
## login/enter-world flow, so a query would otherwise await a signal that
## can never fire.
func _real_player_equipped_slots() -> Array:
	if not NetClient.is_connected_to_server() or NetClient.current_character_name == "":
		return [0, false, false]
	NetClient.list_equipment(NetClient.current_character_name)
	var items: Array = (await NetClient.equipment_result)[0]
	var armor_slots_mask := 0
	var has_weapon := false
	var has_shield := false
	for item in items:
		var bit_index := EquipmentNet.ARMOR_SLOTS.find(item.slot)
		if bit_index != -1:
			armor_slots_mask |= 1 << bit_index
		elif item.slot == EquipmentNet.SLOT_WEAPON:
			has_weapon = true
		elif item.slot == EquipmentNet.SLOT_SHIELD:
			has_shield = true
	return [armor_slots_mask, has_weapon, has_shield]

## Loads a real Map.pk2 region's real object placements (SRREVAMP_MAPO_PATH,
## e.g. "0\\0.o", via SRREVAMP_MAP_PK2_PATH -- same archive as
## SRREVAMP_MAPM_PATH) and renders up to MAX_MAP_OBJECTS of them with their
## real resolved .bsr models, via a real type-ID lookup
## (OBJECT_INDEX_PATH, from SRREVAMP_PK2_PATH's Data.pk2) -- see
## docs/protocol/MAPO_FORMAT.md for how this real mapping was found (it was
## a confirmed dead end earlier in this project). Skips gracefully if
## either env var is unset, or if a specific placement's type ID isn't in
## the index (real, expected -- not every real object type is necessarily
## resolvable, and this project doesn't try to hide that by falling back
## to a placeholder marker here).
func _try_load_real_map_objects() -> void:
	var mapo_path := OS.get_environment("SRREVAMP_MAPO_PATH")
	if mapo_path == "":
		print("World3D: SRREVAMP_MAPO_PATH not set -- no real map objects loaded")
		return

	var map_archive := _open_map_pk2_if_set()
	var mapo_bytes := AssetSource.read_bytes(mapo_path, map_archive)
	if mapo_bytes.is_empty():
		printerr("World3D: could not find map objects at ", mapo_path)
		return
	var region := MapoReader.parse(mapo_bytes)
	if region == null or region.objects.is_empty():
		printerr("World3D: no real objects parsed from ", mapo_path)
		return

	var data_archive := _open_pk2_if_set()
	if data_archive == null:
		printerr("World3D: SRREVAMP_PK2_PATH not set -- can't resolve real object type IDs")
		return
	var idx_bytes := AssetSource.read_bytes(OBJECT_INDEX_PATH, data_archive)
	if idx_bytes.is_empty():
		printerr("World3D: could not find real object index at ", OBJECT_INDEX_PATH)
		return
	var table := ObjidxReader.parse(idx_bytes)
	if table == null:
		printerr("World3D: could not parse real object index at ", OBJECT_INDEX_PATH)
		return

	var container := Node3D.new()
	container.name = "RealMapObjects"
	add_child(container)

	# Real world-space alignment with the player's own spawn position isn't
	# confirmed (same honest caveat as terrain/scenery elsewhere in this
	# file) -- cluster real objects relative to the region's own first
	# placement and offset that cluster near the player for visibility,
	# rather than trusting the raw absolute coordinates to land near
	# wherever the player happens to spawn.
	var origin: Vector3 = region.objects[0].position
	var loaded := 0
	var skipped_unresolved := 0
	# A real region repeats the same handful of real object types across
	# dozens/hundreds of placements (see docs/PROGRESS.md -- a real 58-
	# object region had only 4 distinct types) -- load each distinct real
	# .bsr once and duplicate the built node for repeat placements, rather
	# than re-parsing the same real .bms/.bmt/.ddj chain per placement.
	var templates := {} # resolved .bsr path -> loaded template Node3D
	for obj in region.objects:
		if loaded >= MAX_MAP_OBJECTS:
			break
		var entry := table.lookup(obj.type_id)
		if entry == null:
			skipped_unresolved += 1
			continue

		var node: Node3D
		if templates.has(entry.path):
			node = templates[entry.path].duplicate()
		else:
			var template := ObjectLoader.load_object(data_archive, entry.path)
			if template == null:
				continue
			templates[entry.path] = template
			node = template.duplicate()
		# Placed further out than the single-scenery-object offset above --
		# a real region's real objects can cluster tightly around their
		# own real relative positions (see docs/PROGRESS.md), so centering
		# the cluster at the same close distance as one lone object left
		# the player standing in the middle of it rather than able to see
		# it as a recognizable cluster.
		node.position = (obj.position - origin) + Vector3(20, 0, -30)
		container.add_child(node)
		loaded += 1

	print("World3D: loaded %d/%d real map objects from %s (%d unresolved type IDs skipped, %d distinct real models)" % [
		loaded, region.objects.size(), mapo_path, skipped_unresolved, templates.size()])

## Resolves a real .bmt at bmt_path (via ObjectLoader, the same
## pk2 -> BmtReader -> DdjReader pipeline already verified for scenery) into
## a Dictionary keyed by each layer's own real layer_name -- ready to pass
## straight into CharacterAssembler.assemble/assemble_equipment's
## materials_by_name, which looks parts up by their own real material_name
## field (the two are the same string in real data -- see
## GENDER_ASSET_PATHS's doc comment, confirmed true for real equipment
## materials too, e.g. clothes_03.bmt's layers name-match
## clothes_03_*.bms's own material_name fields). Returns an empty
## Dictionary (not an error) if the .bmt isn't found at that path, since
## CharacterAssembler falls back to a flat/no color in that case.
func _load_real_materials(archive: Pk2Reader, bmt_path: String) -> Dictionary:
	var material := ObjectLoader.load_material(archive, bmt_path)
	if material == null:
		printerr("World3D: could not load material at ", bmt_path, " -- falling back to a flat color")
		return {}

	var by_name := {}
	for layer in material.layers:
		var godot_material := ObjectLoader.build_godot_material(archive, bmt_path, layer)
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

func _spawn_or_update_other(character_id: int, char_name: String, pos: Vector3, armor_slots_mask: int = 0, gender: String = DEFAULT_GENDER, has_weapon: bool = false, has_shield: bool = false) -> void:
	if _other_bodies.has(character_id):
		_other_bodies[character_id].position = pos
		return

	var body := Node3D.new()
	body.position = pos

	# Real assembled character if the shared assets loaded, using this
	# player's own real Gender (WorldNet.EntitySnapshot.gender, from the
	# server's live character-store lookup -- see genderOf in
	# server/internal/session/world.go) -- falls back to the labeled
	# placeholder capsule otherwise. Armor, weapon, and shield are real
	# too: all come straight from the server's live equipment-store lookup
	# (equippedSlots), the same real signal that already gates the local
	# player's own equipment -- armor_slots_mask is a real per-piece
	# bitmask (see EquipmentNet.ARMOR_SLOTS), not one all-or-nothing flag.
	var skeleton := _build_assembled_character(armor_slots_mask, gender, has_weapon, has_shield)
	if skeleton != null:
		body.add_child(skeleton)
	else:
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
	_spawn_or_update_other(snapshot.character_id, snapshot.char_name, Vector3(snapshot.x, snapshot.y, snapshot.z), snapshot.armor_slots_mask, snapshot.gender, snapshot.has_weapon, snapshot.has_shield)

func _on_entity_moved(moved: WorldNet.EntityMoved) -> void:
	if _other_bodies.has(moved.character_id):
		_other_bodies[moved.character_id].position = Vector3(moved.x, moved.y, moved.z)

func _on_entity_left(character_id: int) -> void:
	if _other_bodies.has(character_id):
		_other_bodies[character_id].queue_free()
		_other_bodies.erase(character_id)

func _on_back_to_2d_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/World.tscn")
