extends RefCounted
class_name BsrReader

## Read-only parser for the .bsr (JMXVRES) "static object" resource format.
## See docs/protocol/BSR_FORMAT.md for the on-disk layout. Mirrors
## server/internal/bsr's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVRES 0109"
const MAGIC_LEN := 12
const PREAMBLE_END := 0x44
const MAX_PATH_LEN := 512

# Section offset table in the header. Every real file checked (characters,
# buildings and nature objects alike) has these four pointing at the
# count word that starts each list -- see docs/protocol/BSR_FORMAT.md.
const OFF_PTR_MATERIAL := 0x0C
const OFF_PTR_MESH := 0x10
const OFF_PTR_SKELETON := 0x14
const OFF_PTR_ANIMATION := 0x18
## The next three pointers in the same table, read since the
## hundred-and-thirty-second round: mesh groups (which meshes draw
## together), animation groups (which animation plays for what, per weapon
## kind), and the sound-effect list. Each section's parse ends exactly on
## the next pointer in every real file checked, which is what shows the
## entry layouts below are right.
const OFF_PTR_MESH_GROUP := 0x1C
const OFF_PTR_ANIMATION_GROUP := 0x20
const OFF_PTR_SOUND := 0x24

## Object type, the low uint16 of the word at 0x40. Authored in the file --
## this is the game's own classification, not a guess from the path or from
## which order the fields happen to appear in.
const OFF_TYPE := 0x40
## The player's own body -- `char\china\chinaman_fighter.bsr` and the other
## 25 rows characterdata gives ids 1907-1932. Written 0, not 1: the
## client's object factory (`FUN_00be9250`, a switch on this value) builds
## a `ResChar` for case 0 -- see docs/protocol/BSR_FORMAT.md -- and every
## one of the archive's 174 type-0 files is a playable character class.
## Same layout as TYPE_CHARACTER: a skeleton, skinned mesh pieces, and
## the animation list that drives them.
const TYPE_PLAYER_CHARACTER := 0
const TYPE_CHARACTER := 1
const TYPE_BUILDING := 2
const TYPE_NATURE := 4
## An equippable item: `item\china\man_item\clothes_01_ba.bsr` and the
## rest of the 3,421 files the archive holds under this value. One mesh,
## its material, and **optionally a skeleton of its own plus the body bone
## it hangs from** -- a weapon carries `blade_01.bsk` and `Bip01 R HandMid`,
## a shoulder piece `clothes_sa.bsk` and `Bip01 Neck1`, while a suit or a
## pair of boots names no skeleton because its mesh is weighted straight
## onto the body's bones.
const TYPE_ITEM := 5

## The two words between the animation section pointer and its count. Both
## observed identical (4096, then 0) in every real file checked; their
## meaning isn't confirmed, so they're skipped rather than interpreted.
const ANIMATION_HEADER_WORDS := 2

## One entry of an animation group: which animation plays for one action
## type, with the key events and the walk graph the client attaches to it.
##
## The type codes are the game's own, read off the `default` group of the
## China man's body -- each is a number paired with a self-describing file
## name: 0 `chinaman_fighter_standcity`, 1 `_walkforward`, 2 `_handstraightl`
## (a plain attack), 3 `_benormalhit`, 4 `_diehardhit`, 5 `_handstraightr`,
## 6 `chinaman_standbattle`, 7 `_runforward`, 9 `_behardhit`, 13-15 sit
## down / sit / stand up, 22 `_blocking`, 23 `_walkbackward`, 36 the death
## loop, 38 `_pickup`, 50-57 emotes, 61 a second town idle. Types 26 and up
## are skills.
class AnimationEntry:
	const TYPE_STAND := 0
	const TYPE_WALK := 1
	const TYPE_ATTACK := 2
	const TYPE_HIT := 3
	const TYPE_DIE := 4
	const TYPE_ATTACK_2 := 5
	const TYPE_STAND_BATTLE := 6
	const TYPE_RUN := 7
	const TYPE_HIT_HARD := 9
	## Sitting (round 605). The client's sit entry (0xa5a270) plays 13 when
	## it comes from standing and 14 as the loop; its stand entry (0xa5a160)
	## plays 15 when it comes from sitting. Looked up by type in the body's
	## own table, which is why the clips differ per body.
	const TYPE_SIT_DOWN := 13
	const TYPE_SITTING := 14
	const TYPE_STAND_UP := 15
	const TYPE_WALK_BACKWARD := 23
	const TYPE_DIE_LOOP := 36

	## Event types seen in real entries: 1 on every attack (once or twice
	## per swing -- the moment the blow lands), 2 on every walk and run
	## (twice per cycle, parameters (0, 1) then (1, 0) -- one per foot).
	const EVENT_HIT := 1
	const EVENT_FOOTSTEP := 2

	var action_type: int
	## Index into the file's animation list, and the path it names.
	var file_index: int
	var path: String
	## Key events: four words each -- a key time, a type, two parameters.
	## The key time reads as **milliseconds**: a run's two footsteps fall at
	## 305 and 633 of a cycle about 950 long, a walk's at 445 and 973 of
	## one about 1,300 long, and every attack's hit lands between 128 and
	## 651. That is consistent across every entry checked, not confirmed
	## against the client's own use of the value.
	var events: Array = []

	## The key time of the first event of a type, in the units above, or
	## -1 when the entry has none.
	func first_event_time(event_type: int) -> int:
		for e in events:
			if (e as PackedInt32Array)[1] == event_type:
				return (e as PackedInt32Array)[0]
		return -1
	## The walk graph: (x, y) points, two in every entry checked.
	var walk_points: PackedVector2Array = PackedVector2Array()
	## A trailing float, 1.0 in every entry checked.
	var trail: float = 1.0

class ParsedObject:
	var object_name: String
	var mesh_path: String
	var material_path: String
	var sub_mesh_paths: Array[String] = []
	var has_bounds: bool = false
	var bounds_min: Vector3
	var bounds_max: Vector3

	## Set for TYPE_CHARACTER files -- NPCs, monsters and the player's own
	## body. These are skinned models: the mesh pieces mean nothing without
	## the skeleton, so a caller that sees this set should assemble them
	## through CharacterAssembler rather than dropping the pieces into the
	## world as rigid scenery.
	var is_character: bool = false
	var skeleton_path: String
	var animation_paths: Array[String] = []
	## The low uint16 at OFF_TYPE, as the file states it. -1 when the file
	## was read through the scenery scan and the header was not trusted.
	var object_type: int = -1
	## For an item with a skeleton of its own: the body bone that skeleton
	## hangs from, authored right after the skeleton path. Empty for a
	## body, whose skeleton hangs from nothing.
	var attach_bone: String = ""
	## Mesh groups: a name and the indices (into all_mesh_paths()) of the
	## meshes drawn together under it. A body has one, `default`, listing
	## every piece.
	var mesh_groups: Dictionary = {}
	## Animation groups, keyed by name -- `default`, and one per weapon
	## kind the body can hold (`sword`, `spear`, `bow`, ...) -- each an
	## Array of AnimationEntry. What plays for a given action is looked up
	## by entry type in the group for the weapon in hand, falling back to
	## `default`; see animation_for().
	var animation_groups: Dictionary = {}

	func is_item() -> bool:
		return object_type == TYPE_ITEM

	## The animation path for an action (an AnimationEntry.TYPE_* code) in
	## group_name, falling back to the `default` group when that group has
	## no entry for it -- a sword has its own run but no walk of its own,
	## and the body's default walk is what plays then. "" if neither has
	## one.
	func animation_for(action_type: int, group_name: String = "default") -> String:
		var entry := animation_entry_for(action_type, group_name)
		return entry.path if entry != null else ""

	## The entry itself, with its events, for the same lookup.
	func animation_entry_for(action_type: int, group_name: String = "default") -> AnimationEntry:
		for name in [group_name, "default"]:
			for entry in animation_groups.get(name, []):
				if (entry as AnimationEntry).action_type == action_type:
					return entry
		return null

	## Every mesh piece, primary included -- the same paths as
	## mesh_path + sub_mesh_paths, in file order, for callers that don't
	## care which one the file happened to list first.
	func all_mesh_paths() -> Array[String]:
		var out: Array[String] = []
		if mesh_path != "":
			out.append(mesh_path)
		out.append_array(sub_mesh_paths)
		return out

## Parses a .bsr file's raw bytes. Returns null (and pushes an error) on
## failure -- including the known edge case of a file with an empty mesh
## path (see docs/protocol/BSR_FORMAT.md).
static func parse(data: PackedByteArray) -> ParsedObject:
	if data.size() < PREAMBLE_END:
		push_error("bsr: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("bsr: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var off := PREAMBLE_END
	var name_result = _read_len_prefixed_string(data, off)
	if name_result == null:
		push_error("bsr: reading name")
		return null
	var name: String = name_result[0]
	off = name_result[1]

	# The header's section table is the authored answer, and it is used for
	# every object type -- not just characters, as it was at first.
	#
	# **Measured across a real Data.pk2's 8,539 .bsr files** with
	# client/tools/sweep_bsr.gd: the table parses and chains for 7,978 of
	# them (93%), and on a 1,500-file verified sample **every mesh path it
	# produces resolves to a real file in the archive** -- zero unresolved.
	# The forward scan below, by contrast, returned a duplicated mesh for
	# 2,787 files (a third of the archive drawing one piece twice) and a
	# different mesh count for 3,770, including objects where it found one
	# piece and the table found six. Those were rendering with most of
	# their geometry missing.
	#
	# The table validates as it goes and returns null if anything doesn't
	# line up, so the 7% it can't read fall back to the scan rather than
	# producing confidently wrong paths.
	var sections = parse_sections(data)
	if sections != null and not (sections["meshes"] as Array).is_empty():
		var obj_type := _le_u32(data, OFF_TYPE) & 0xFFFF
		var skeletons: Array = sections["skeletons"]
		var is_character_type := obj_type == TYPE_CHARACTER or obj_type == TYPE_PLAYER_CHARACTER
		# A character with no skeleton is a contradiction -- its pieces are
		# skin, and posing them needs bones -- so let it fall through to the
		# scan rather than returning limbs at the origin.
		if not is_character_type or not skeletons.is_empty():
			var built := ParsedObject.new()
			built.object_name = name
			built.object_type = obj_type
			var materials: Array = sections["materials"]
			if not materials.is_empty():
				built.material_path = materials[0]
			var meshes: Array = sections["meshes"]
			built.mesh_path = meshes[0]
			for i in range(1, meshes.size()):
				built.sub_mesh_paths.append(meshes[i])
			for path in sections["animations"]:
				built.animation_paths.append(path)
			if not skeletons.is_empty():
				built.skeleton_path = skeletons[0]
				var attach_bones: Array = sections["attach_bones"]
				if not attach_bones.is_empty():
					built.attach_bone = attach_bones[0]
			built.mesh_groups = sections["mesh_groups"]
			built.animation_groups = _animation_groups(sections["animation_groups"], built.animation_paths)
			built.is_character = is_character_type and built.skeleton_path != ""
			return built

	# The exact byte layout between the name and the mesh/material paths
	# isn't fully understood (a fixed-looking header field that should
	# point at the mesh path turned out not to, in at least one real
	# file) -- so instead of trusting an offset, scan forward for the
	# first plausible length-prefixed path string. Real files were also
	# found to genuinely differ in *field order*: "building"-category
	# files (res\bldg\...) put the mesh path first, then the bounding box,
	# then the material path; "nature"-category files (res\nature\...,
	# e.g. vegetation/scatter objects) put the bounding box and material
	# path first, with the mesh path last -- see
	# docs/protocol/BSR_FORMAT.md. Scanning independently for the first
	# string ending in ".bms" and the first ending in ".bmt" (not
	# "whichever plausible string comes first, unconditionally called the
	# mesh path") finds the right field either way, since it doesn't
	# assume an order.
	var mesh_off := _scan_for_path_string_with_suffix(data, off, ".bms")
	var mat_off := _scan_for_path_string_with_suffix(data, off, ".bmt")
	if mat_off < 0:
		push_error("bsr: couldn't locate material path")
		return null

	var mat_result = _read_len_prefixed_string(data, mat_off)
	if mat_result == null:
		push_error("bsr: reading material path")
		return null
	var material_path: String = mat_result[0]
	var mat_end: int = mat_result[1]

	if mesh_off < 0:
		# A real, genuine mesh-less variant, not a parse failure: real
		# "*_particle.bsr" files (e.g. wreck_sship_particle.bsr, placed
		# over 1,200 times combined across a real client's map data --
		# found auditing this project's own full real object catalog,
		# 2026-08-25) carry a real material plus one or more real .efp
		# particle-effect references instead of any .bms mesh at all --
		# they're invisible particle-emitter markers, not scenery with a
		# missing/corrupt mesh. Returning a real ParsedObject with an empty
		# mesh_path (same "empty is a real, valid value" treatment
		# material_path already gets) lets a caller render just the real
		# particle effect (once this project has a real .efp renderer) or
		# skip the object's visual entirely, instead of treating every one
		# of these as a hard failure.
		var particle_obj := ParsedObject.new()
		particle_obj.object_name = name
		particle_obj.material_path = material_path
		return particle_obj

	var mesh_result = _read_len_prefixed_string(data, mesh_off)
	if mesh_result == null:
		push_error("bsr: reading mesh path")
		return null
	var mesh_path: String = mesh_result[0]
	var mesh_end: int = mesh_result[1]

	var obj := ParsedObject.new()
	obj.object_name = name
	obj.mesh_path = mesh_path
	obj.material_path = material_path

	if mesh_off >= mat_off:
		# Nature-category order (material, then mesh) -- confirmed real,
		# but nothing past the mesh path is understood for this layout
		# yet (no confirmed bounding-box position or sub-mesh-list
		# convention), so this is where a real file's real data ends as
		# far as this reader is concerned. Not guessed at.
		return obj

	# Building-category order (mesh, then material): best-effort bounding
	# box, observed as 6 floats (min xyz, max xyz) at the very start of
	# the gap between the mesh path and the material path in most real
	# files checked -- but not confirmed in all of them, so this is
	# skipped rather than guessed at when the gap is too short.
	var gap := mat_off - mesh_end
	if gap >= 24:
		obj.bounds_min = Vector3(_le_f32(data, mesh_end), _le_f32(data, mesh_end + 4), _le_f32(data, mesh_end + 8))
		obj.bounds_max = Vector3(_le_f32(data, mesh_end + 12), _le_f32(data, mesh_end + 16), _le_f32(data, mesh_end + 20))
		obj.has_bounds = true

	off = mat_end
	if off + 4 > data.size():
		return obj

	var sub_count := _le_u32(data, off)
	off += 4
	if sub_count > 1000:
		return obj

	# A real, larger multi-piece building (2026-08-23: found live-testing
	# real Jangan palace buildings, the first real content this project had
	# tested with more than a couple of sub-mesh pieces) can have its
	# declared sub_count not exactly match how many further length-prefixed
	# strings are actually still real path-shaped data -- the exact real
	# cause isn't confirmed (a real trailing per-piece field this project's
	# simpler samples never had enough pieces to expose, most likely).
	# Previously this failed the *entire* object, discarding the already-
	# confirmed-real primary mesh_path/material_path along with it over one
	# bad trailing sub-piece -- a disproportionate real failure mode. Now
	# it keeps whatever real sub-mesh paths parsed successfully and stops,
	# same "return the real partial result rather than nothing" precedent
	# already used elsewhere in this reader (see the nature-category
	# early-return above).
	for i in range(sub_count):
		var sub_result = _read_len_prefixed_string(data, off)
		if sub_result == null:
			push_error("bsr: reading sub-mesh path %d/%d -- keeping the %d real sub-mesh(es) already parsed" % [i + 1, sub_count, obj.sub_mesh_paths.size()])
			break
		var sub_path: String = sub_result[0]
		off = sub_result[1]
		# A real sub-mesh path that isn't a plausible ".bms" path (2026-08-23:
		# found live-testing real Jangan-adjacent trees) is never a real,
		# usable sub-mesh reference -- no real file has an empty name or a
		# single stray byte like "6" as a mesh path. It means the true real
		# sub-mesh list already ended and this read has spilled into the
		# file's own trailing boilerplate (the fixed 20-byte block +
		# "default" string documented above), which can contain real byte
		# sequences that happen to parse as a valid-looking but wrong
		# length-prefixed string rather than failing outright (an exactly
		# empty string from `tre_bank02.bsr`; a single real byte "6" from
		# `tre_maple01.bsr`). Stop here, same as a real read failure,
		# rather than recording a sub-mesh path `ObjectLoader` can never
		# resolve.
		if not (_is_plausible_path(sub_path.to_ascii_buffer()) and sub_path.to_lower().ends_with(".bms")):
			break
		obj.sub_mesh_paths.append(sub_path)

	return obj

## Reads a file's four sections through the header's offset table, without
## deciding what to do with them. Returns a dictionary of
## {materials, meshes, animations, skeletons} (each an Array[String]), or
## null if the sections don't chain.
##
## Exposed separately from _parse_character so a caller can compare the
## header table against the forward scan on the same real file -- which is
## how the building-category behaviour was checked across the whole archive
## before being changed (client/tools/sweep_bsr.gd).
static func parse_sections(data: PackedByteArray):
	if data.size() < PREAMBLE_END:
		return null
	if data.slice(0, MAGIC_LEN).get_string_from_ascii() != MAGIC:
		return null
	var ptr_material := _le_u32(data, OFF_PTR_MATERIAL)
	var ptr_mesh := _le_u32(data, OFF_PTR_MESH)
	var ptr_skeleton := _le_u32(data, OFF_PTR_SKELETON)
	var ptr_animation := _le_u32(data, OFF_PTR_ANIMATION)
	for ptr in [ptr_material, ptr_mesh, ptr_skeleton, ptr_animation]:
		if ptr < PREAMBLE_END or ptr + 4 > data.size():
			return null

	var materials = _read_string_list(data, ptr_material, ".bmt", 4)
	if materials == null or materials[1] != ptr_mesh:
		return null
	var meshes = _read_string_list(data, ptr_mesh, ".bms", 0)
	if meshes == null or meshes[1] != ptr_animation:
		return null

	var animations: Array[String] = []
	var anims = _read_string_list(data, ptr_animation + ANIMATION_HEADER_WORDS * 4, ".ban", 0)
	if anims != null and anims[1] == ptr_skeleton:
		animations = anims[0]
	var skeletons: Array[String] = []
	var attach_bones: Array[String] = []
	var skels = _read_skeleton_list(data, ptr_skeleton)
	if skels != null:
		skeletons = skels[0]
		attach_bones = skels[1]

	# The three sections after the skeleton. Each is read only if the
	# header points inside the file, and a section that does not parse
	# comes back empty rather than failing the object: an older file, or
	# one this reader has not seen the shape of, still yields its meshes.
	var ptr_mesh_group := _le_u32(data, OFF_PTR_MESH_GROUP)
	var ptr_animation_group := _le_u32(data, OFF_PTR_ANIMATION_GROUP)
	var ptr_sound := _le_u32(data, OFF_PTR_SOUND)
	var mesh_groups := {}
	var mg = _read_mesh_groups(data, ptr_mesh_group)
	if mg != null and mg[1] == ptr_animation_group:
		mesh_groups = mg[0]
	var animation_groups := {}
	var ag = _read_animation_groups(data, ptr_animation_group)
	if ag != null and ag[1] == ptr_sound:
		animation_groups = ag[0]

	return {
		"materials": materials[0],
		"meshes": meshes[0],
		"animations": animations,
		"skeletons": skeletons,
		"attach_bones": attach_bones,
		"mesh_groups": mesh_groups,
		"animation_groups": animation_groups,
	}

## Mesh groups: a count, then per group a length-prefixed name, a count and
## that many uint32 mesh indices. Returns [{name: PackedInt32Array}, end].
static func _read_mesh_groups(data: PackedByteArray, off: int):
	if off < PREAMBLE_END or off + 4 > data.size():
		return null
	var count := _le_u32(data, off)
	off += 4
	if count > 1000:
		return null
	var groups := {}
	for _i in range(count):
		var name_result = _read_len_prefixed_string(data, off)
		if name_result == null:
			return null
		off = name_result[1]
		if off + 4 > data.size():
			return null
		var n := _le_u32(data, off)
		off += 4
		if n > 10000 or off + n * 4 > data.size():
			return null
		var indices := PackedInt32Array()
		for j in range(n):
			indices.append(_le_u32(data, off + j * 4))
		off += n * 4
		groups[name_result[0]] = indices
	return [groups, off]

## Animation groups: a count, then per group a length-prefixed name, a
## count and that many entries -- each `type, file index, event count,
## events (four words apiece), walk-point count, points (two floats
## apiece), and a trailing float`. Returns [{name: Array of raw entries},
## end]; the entries are resolved against the animation list by
## _animation_groups.
static func _read_animation_groups(data: PackedByteArray, off: int):
	if off < PREAMBLE_END or off + 4 > data.size():
		return null
	var count := _le_u32(data, off)
	off += 4
	if count > 1000:
		return null
	var groups := {}
	for _i in range(count):
		var name_result = _read_len_prefixed_string(data, off)
		if name_result == null:
			return null
		off = name_result[1]
		if off + 4 > data.size():
			return null
		var n := _le_u32(data, off)
		off += 4
		if n > 10000:
			return null
		var entries: Array = []
		for _j in range(n):
			if off + 12 > data.size():
				return null
			var raw := {
				"type": _le_u32(data, off),
				"file_index": _le_u32(data, off + 4),
			}
			var event_count := _le_u32(data, off + 8)
			off += 12
			if event_count > 10000 or off + event_count * 16 > data.size():
				return null
			var events: Array = []
			for k in range(event_count):
				events.append(PackedInt32Array([
					_le_u32(data, off), _le_u32(data, off + 4),
					_le_u32(data, off + 8), _le_u32(data, off + 12)]))
				off += 16
			raw["events"] = events
			if off + 4 > data.size():
				return null
			var point_count := _le_u32(data, off)
			off += 4
			if point_count > 10000 or off + point_count * 8 + 4 > data.size():
				return null
			var points := PackedVector2Array()
			for k in range(point_count):
				points.append(Vector2(_le_f32(data, off), _le_f32(data, off + 4)))
				off += 8
			raw["walk_points"] = points
			raw["trail"] = _le_f32(data, off)
			off += 4
			entries.append(raw)
		groups[name_result[0]] = entries
	return [groups, off]

## Turns raw group entries into AnimationEntry objects with their paths
## resolved against the file's own animation list.
static func _animation_groups(raw_groups: Dictionary, animation_paths: Array) -> Dictionary:
	var out := {}
	for name in raw_groups:
		var entries: Array = []
		for raw in raw_groups[name]:
			var entry := AnimationEntry.new()
			entry.action_type = raw["type"]
			entry.file_index = raw["file_index"]
			if entry.file_index >= 0 and entry.file_index < animation_paths.size():
				entry.path = animation_paths[entry.file_index]
			entry.events = raw["events"]
			entry.walk_points = raw["walk_points"]
			entry.trail = raw["trail"]
			entries.append(entry)
		out[name] = entries
	return out

## Parses a TYPE_CHARACTER file through the header's section offset table.
##
## Unlike the scan-based scenery path below, nothing here is searched for:
## each of the four sections starts with a count word at the offset the
## header names, and the entries that follow abut one another exactly, so
## reading one section leaves the cursor on the next section's first byte.
## That chaining is what makes the layout checkable rather than guessed --
## every section is verified to end exactly where the header says the next
## one begins, and any mismatch aborts back to the caller.
##
## Returns null if the file doesn't match, so the caller can fall back.
static func _parse_character(data: PackedByteArray, name: String) -> ParsedObject:
	var ptr_material := _le_u32(data, OFF_PTR_MATERIAL)
	var ptr_mesh := _le_u32(data, OFF_PTR_MESH)
	var ptr_skeleton := _le_u32(data, OFF_PTR_SKELETON)
	var ptr_animation := _le_u32(data, OFF_PTR_ANIMATION)
	for ptr in [ptr_material, ptr_mesh, ptr_skeleton, ptr_animation]:
		if ptr < PREAMBLE_END or ptr + 4 > data.size():
			return null

	# Materials: a count, then one uint32 (unconfirmed -- an index or flag,
	# always small) in front of each path.
	var materials = _read_string_list(data, ptr_material, ".bmt", 4)
	if materials == null or materials[0].is_empty():
		return null
	# The material section must run right up to the mesh section.
	if materials[1] != ptr_mesh:
		return null

	# Meshes: a count, then the paths back to back with no per-entry field.
	var meshes = _read_string_list(data, ptr_mesh, ".bms", 0)
	if meshes == null or meshes[0].is_empty():
		return null
	if meshes[1] != ptr_animation:
		return null

	var obj := ParsedObject.new()
	obj.object_name = name
	obj.is_character = true
	obj.material_path = materials[0][0]
	var mesh_paths: Array = meshes[0]
	obj.mesh_path = mesh_paths[0]
	for i in range(1, mesh_paths.size()):
		obj.sub_mesh_paths.append(mesh_paths[i])

	# Animations sit behind two unconfirmed words, then the usual count.
	var animations = _read_string_list(
		data, ptr_animation + ANIMATION_HEADER_WORDS * 4, ".ban", 0
	)
	if animations != null and animations[1] == ptr_skeleton:
		for path in animations[0]:
			obj.animation_paths.append(path)

	# The skeleton list is count-prefixed like the rest, but a character
	# has exactly one in every real file checked, so only the first is
	# kept -- a second would need a reason to exist before it's used.
	var skeletons = _read_skeleton_list(data, ptr_skeleton)
	if skeletons != null and not skeletons[0].is_empty():
		obj.skeleton_path = skeletons[0][0]
		obj.attach_bone = skeletons[1][0]
	obj.object_type = _le_u32(data, OFF_TYPE) & 0xFFFF
	var mg = _read_mesh_groups(data, _le_u32(data, OFF_PTR_MESH_GROUP))
	if mg != null and mg[1] == _le_u32(data, OFF_PTR_ANIMATION_GROUP):
		obj.mesh_groups = mg[0]
	var ag = _read_animation_groups(data, _le_u32(data, OFF_PTR_ANIMATION_GROUP))
	if ag != null and ag[1] == _le_u32(data, OFF_PTR_SOUND):
		obj.animation_groups = _animation_groups(ag[0], obj.animation_paths)

	# A character without a skeleton is a contradiction: the mesh pieces
	# are skin, and posing them needs bones. Rather than hand back
	# something that would render as a heap of disconnected limbs at the
	# origin, fail and let the caller fall back to the scenery path.
	if obj.skeleton_path == "":
		return null
	return obj

## Reads the skeleton section: a count, then per entry a length-prefixed
## `.bsk` path **followed by a length-prefixed bone name** -- the body bone
## the skeleton hangs from. A body's own skeleton hangs from nothing and
## writes an empty string there (`chinaman_fighter.bsr` carries a zero
## length word after its skeleton path); an item's says which bone,
## `Bip01 R HandMid` for `blade_01.bsr`, `Bip01 Neck1` for a shoulder piece.
## Reading the list as bare paths worked only because nothing looked past
## the first entry's end.
##
## Returns [paths, attach_bones, end_offset] -- both arrays empty for a
## count of zero, which is what an item weighted straight onto the body
## writes -- or null if the list does not parse.
static func _read_skeleton_list(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var count := _le_u32(data, off)
	off += 4
	if count < 0 or count > 1000:
		return null
	var paths: Array[String] = []
	var bones: Array[String] = []
	for _i in range(count):
		var path_result = _read_len_prefixed_string(data, off)
		if path_result == null:
			return null
		var path: String = path_result[0]
		if not (_is_plausible_path(path.to_ascii_buffer()) and path.to_lower().ends_with(".bsk")):
			return null
		off = path_result[1]
		var bone_result = _read_len_prefixed_string(data, off)
		if bone_result == null:
			return null
		var bone: String = bone_result[0]
		if bone != "" and not _is_plausible_path(bone.to_ascii_buffer()):
			return null
		off = bone_result[1]
		paths.append(path)
		bones.append(bone)
	return [paths, bones, off]

## Reads a count-prefixed list of length-prefixed path strings at off, each
## entry preceded by lead_bytes of unread per-entry data. Every path must
## end with suffix, which is what turns "these bytes parsed" into "these
## bytes are the list the header promised". Returns [paths, end_offset], or
## null if the list doesn't parse or a path fails the suffix check.
static func _read_string_list(
	data: PackedByteArray, off: int, suffix: String, lead_bytes: int
):
	if off + 4 > data.size():
		return null
	var count := _le_u32(data, off)
	off += 4
	if count <= 0 or count > 1000:
		return null
	var paths: Array[String] = []
	for _i in range(count):
		off += lead_bytes
		var result = _read_len_prefixed_string(data, off)
		if result == null:
			return null
		var path: String = result[0]
		if not (_is_plausible_path(path.to_ascii_buffer()) and path.to_lower().ends_with(suffix)):
			return null
		paths.append(path)
		off = result[1]
	return [paths, off]

## Looks for the next plausible length-prefixed path string starting at or
## after off whose content ends with suffix (case-insensitive -- real
## paths use inconsistent casing throughout this project's data),
## returning its offset. Filtering by suffix (rather than accepting the
## first plausible string unconditionally) is what lets one scan
## correctly find the mesh path or material path regardless of which
## order a real file puts them in.
static func _scan_for_path_string_with_suffix(data: PackedByteArray, off: int, suffix: String) -> int:
	var pos := off
	while pos + 4 <= data.size():
		var n := _le_u32(data, pos)
		if n > 0 and n <= MAX_PATH_LEN and pos + 4 + n <= data.size():
			var candidate := data.slice(pos + 4, pos + 4 + n)
			if _is_plausible_path(candidate) and candidate.get_string_from_ascii().to_lower().ends_with(suffix):
				return pos
		pos += 1
	return -1

static func _is_plausible_path(b: PackedByteArray) -> bool:
	if b.size() == 0:
		return false
	for c in b:
		var is_alnum := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57)
		var is_extra := c == 92 or c == 46 or c == 95 or c == 45 or c == 32 # \ . _ - space
		if not (is_alnum or is_extra):
			return false
	return true

static func _read_len_prefixed_string(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n < 0 or off + n > data.size():
		return null
	return [data.slice(off, off + n).get_string_from_ascii(), off + n]

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

static func _le_f32(b: PackedByteArray, off: int) -> float:
	return b.slice(off, off + 4).decode_float(0)
