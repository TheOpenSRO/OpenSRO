extends RefCounted
class_name BodyFx

## Round 809: a character body's own particle effects -- the particle mods of
## its `.bsr` (BsrReader.ParticleMod), on monsters, NPCs, pets and mounts.
## READ from sro_client.exe (docs/protocol/BSR_FORMAT.md, "A body's particle
## mods (round 809)", has every address):
##
## - **The ambient set** (the clip-name set called `ambient`, kind 2) is
##   built with its keep flag set and every entry started at once
##   (CRTModParticle::vslot_001 0xc77a20 -> FUN_00c81510(keep)): it plays,
##   looping, from the body's creation for as long as the body stands --
##   Ishade's revolving snow (`monster\ambient_ishade_iceloop01.efp` on Bone03
##   and Bone04). Here it is an EquipFx row on the body's skeleton, as a worn
##   item's ambient set is (WornItemFx): EquipFx's shared masters and its
##   720-unit range, which is the particle mod's own LOD gate (0.9 x 800,
##   FUN_00c43780 / GlobalDataManager::FUN_009c4aa0). An entry whose bone the
##   skeleton lacks ends its mod (round 720's rule).
## - **The sets by action type** go with the body's clips: the clip of type N
##   found in group G carries the set (G, N), else ("default", N)
##   (AniMixer::FUN_00c551a0). Each entry fires once when the clip's time
##   crosses its key, the entry's word +0x4c in clip milliseconds (the key map
##   of AniMixer::FUN_00c741f0 / CRTModParticle::vslot_009 0xc778a0) -- every
##   cycle of a loop -- and plays once (keep 0). The same clip started again
##   stops the effects its last run started (CRTAnimation::vslot_001 0xc74170
##   -> the mod's slots 10 and 7). Isyutaru's death: six
##   `monster\dead\dead_bluesmog.efp` at 2379 ms.
## - Mode 0 is the named bone's full matrix (FUN_00c818c0, round 720); any
##   other mode the entry's offset in the object's frame times its scale
##   (FUN_00c81820 / FUN_00c81190), turned by its angles when byte +0x53 is set.
##
## OURS: a body's clip keys are read only where its sounds are (AnimSounds'
## listener range, 600) rather than within 720 of the camera; the ambient
## set's mode-1 entries (15 of 264 on character bodies, MEASURED) are not
## drawn (EquipFx places at bones only; OPEN); the named sets
## (status_bad_*, system_appear) are not played -- what plays them is OPEN.

## The particles archive the effects are made from (World3D sets it), and a
## factory the tests replace: func(path) -> EfpEffect or null.
var particles: Pk2Reader = null
var factory: Callable = Callable()
## skeleton instance id -> {set key -> [EfpEffect]}: a clip's effects still
## alive, stopped when the same clip starts again.
var _live := {}
## Effects started (for the log and the tests).
var fired := 0

## The ambient set's entries a body's skeleton can draw, as EquipFx rows
## (ItemGlowTables.ParticleRow): mode 0, not night-only, in file order; an
## entry whose bone `skel` lacks ends its mod (the rest of that mod's entries
## are not built). Mode-1 entries are skipped (see the header).
static func ambient_rows(parsed: BsrReader.ParsedObject, skel: Skeleton3D) -> Array:
	var rows: Array = []
	if parsed == null or skel == null:
		return rows
	for entries in AmbientParticles.ambient_entries(parsed.particle_mods):
		for e_v in entries:
			var e := e_v as BsrReader.ParticleEntry
			if e == null or e.efp == "" or AmbientParticles.night_only(e):
				continue
			if e.mode != 0:
				continue
			if skel.find_bone(e.bone) < 0:
				break
			var r := ItemGlowTables.ParticleRow.new()
			r.efp = e.efp
			r.bone = e.bone
			rows.append(r)
	return rows

## Puts a body's ambient set on its skeleton (EquipFx). Returns the rows
## placed.
static func attach_ambient(skel: Skeleton3D, parsed: BsrReader.ParsedObject, archive: Pk2Reader) -> int:
	if archive == null:
		return 0
	var rows := ambient_rows(parsed, skel)
	if rows.is_empty():
		return 0
	return EquipFx.attach(skel, rows, archive)

## Every effect file a body's sets by type name (a model's preload).
static func clip_paths(parsed: BsrReader.ParsedObject) -> PackedStringArray:
	var out := PackedStringArray()
	if parsed == null:
		return out
	for pm in parsed.particle_mods:
		var m := pm as BsrReader.ParticleMod
		if m == null or m.set_kind != BsrReader.SET_BY_TYPE:
			continue
		for e in m.entries:
			if (e as BsrReader.ParticleEntry).efp != "" and not out.has((e as BsrReader.ParticleEntry).efp):
				out.append((e as BsrReader.ParticleEntry).efp)
	return out

## The clip of (`action_type`, `group`) on `skel` has started again: its last
## run's effects stop.
func restart(skel: Object, set_key: String) -> void:
	var per: Dictionary = _live.get(skel.get_instance_id(), {})
	var list: Array = per.get(set_key, [])
	if list.is_empty():
		return
	for fx in list:
		if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion():
			(fx as EfpEffect).stop()
	per.erase(set_key)

## Fires `entries` (BsrReader.ParticleEntry) of a clip on `skel`, its body
## `host`. Returns the effects started.
func fire(host: Node3D, skel: Skeleton3D, set_key: String, entries: Array) -> Array:
	var started: Array = []
	if host == null or not is_instance_valid(host) or skel == null:
		return started
	var per: Dictionary = _live.get(skel.get_instance_id(), {})
	var list: Array = []
	for fx in per.get(set_key, []):
		if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion():
			list.append(fx)
	for e_v in entries:
		var e := e_v as BsrReader.ParticleEntry
		if e == null or e.efp == "" or AmbientParticles.night_only(e):
			continue
		if e.mode == 0 and skel.find_bone(e.bone) < 0:
			continue
		var fx: EfpEffect = factory.call(e.efp) if factory.is_valid() else EfpEffect.create(e.efp, particles)
		if fx == null:
			continue
		host.add_child(fx)
		if e.mode == 0:
			fx.follow_bone_full = true
			fx.follow_host(host, e.bone, Vector3.ZERO)
		else:
			if e.rotated:
				fx.follow_basis = AmbientParticles.rotation_basis(e.angles)
			fx.follow_host(host, "none", e.offset)
		list.append(fx)
		started.append(fx)
		fired += 1
	if not list.is_empty():
		per[set_key] = list
		_live[skel.get_instance_id()] = per
	return started

## A body gone: its record is dropped (its effects go with its node).
func forget(skel: Object) -> void:
	if skel != null:
		_live.erase(skel.get_instance_id())

## Drops the records of bodies no longer alive (called now and then).
func prune() -> void:
	for id in _live.keys():
		if not is_instance_valid(instance_from_id(id)):
			_live.erase(id)
