extends RefCounted
class_name MonsterCrowd

## Dense monster fields (round 664). Round 660 put every field nest of the
## shard's database on the map; where its swapped spots cluster, the client
## holds 1,378 to 2,412 bodies and ran at 100-143 ms a frame. This file keeps
## the round's rules apart from World3D so a headless test can hold them to
## account, and carries the frame-split instrumentation the round measured
## with (QA only).

## What the round measured (docs/WORLD_ISSUES.md, round 664; 2,500 monsters
## of 17 species within 1,920 of the player, 1280x720 on the render box): 167
## ms a frame, of which the renderer took 6.6. The rest was the character
## clip tick (World3D._tick_idle_animations), 16.3 ms each time it ran -- 9.1
## of it advancing 2,500 bodies' clip sounds, 2.8 posing the 70 in view, 4.4
## the loop's own tests -- and it ran in every PHYSICS step: at 60 steps a
## second, a 100 ms frame runs six of them and a 167 ms one the capped eight,
## so the slower the frame, the more times it paid. The rules below cut
## those three costs without changing what a player near the camera sees or
## hears.

## **Once per rendered frame** (TickGate). The clip tick runs in the first
## physics step of each rendered frame, with every step's time since the last
## one, instead of in every step. A clip's clock keeps every second (the
## steps' deltas are summed, none dropped); what changes is only that a
## rendered frame poses once. At 60 frames a second there is one step a
## frame and nothing changes. OURS: retail has no physics step -- its world
## is updated once per rendered frame (INFERRED from the per-frame render
## path, CEntityManagerClient::vslot_011 0x9c4770, which lists every object
## once a frame).
class TickGate:
	var _frame := -1
	var _pending := 0.0

	## The time to tick this step with, or a negative number when this
	## rendered frame has ticked already (the delta is kept for the next).
	func take(frame: int, delta: float) -> float:
		if frame == _frame:
			_pending += delta
			return -1.0
		_frame = frame
		var total := _pending + delta
		_pending = 0.0
		return total

## **Sounds only where they can be heard.** A body's clip sounds are advanced
## only while it is within SoundTable.CULL_DISTANCE of the listener: READ,
## the core plays no positioned sound more than 600 units from the listener
## (FUN_00a6f7f0's cull, constant 0xda98fc; AudioService.play_key applies it
## to every key), so advancing a body farther away than that could never
## sound. The listener is the player (OURS, AudioService). A body that goes
## out of hearing is rested (AnimSounds.rest), so when it comes back it
## carries on from where its clip is then, firing nothing for the time it
## was away -- the one difference from before, where a track passed exactly
## as it came back into 600 could fire once.
static func hearable(origin: Vector3, listener: Vector3) -> bool:
	return origin.distance_squared_to(listener) <= SoundTable.CULL_DISTANCE_SQ

## **The loop's own cost.** The tick visits every animated body every frame,
## so what it does per body is paid 2,500 times: three metas read (has, get,
## has), three calls into MonsterDraw's static tests and one into
## AnimSounds per body cost 6.9 ms a frame at the crowd site. CullCache keeps
## a culled skeleton's metas -- its cull radius, whether it hides out of
## range, and whether its sounds are resting -- in one packed array, read
## once when the skeleton is first seen; World3D writes MonsterDraw's range
## and frustum tests out in the loop and rests a body's sounds only when it
## goes out of hearing, not every frame it stays out.
class CullCache:
	## The answer for a skeleton that is not culled (the player, other
	## players, the doll): no metas.
	const NONE: Array = []
	var _by_id := {}   # skeleton instance id -> [radius, hides (1/0), resting (1/0), slot, quiet (1/0)], or NONE
	var _ticks := 0
	var _slots := 0

	## [radius, hides, resting, slot, quiet] for a skeleton with MonsterDraw.META_CULL,
	## else NONE. The array is the cache's own: a write to [2] is kept.
	func info(skeleton: Skeleton3D) -> Array:
		var id := skeleton.get_instance_id()
		var got = _by_id.get(id)
		if got != null:
			return got
		var made: Array = NONE
		if skeleton.has_meta(MonsterDraw.META_CULL):
			_slots += 1
			made = [float(skeleton.get_meta(MonsterDraw.META_RADIUS, 1.0)),
				1.0 if skeleton.has_meta(MonsterDraw.META_HIDE) else 0.0, 0.0, _slots, 0.0]
		_by_id[id] = made
		return made

	## Once a tick: every 600th, the entries of freed skeletons are dropped.
	func tick() -> void:
		_ticks += 1
		if _ticks % 600 != 0:
			return
		for id in _by_id.keys():
			if not is_instance_id_valid(id):
				_by_id.erase(id)

	func size() -> int:
		return _by_id.size()

	## The ticks counted so far (pose_due's clock).
	func ticks() -> int:
		return _ticks

	## The cache itself, for the tick's own lookup (a method call per body
	## cost more than the lookup); a miss goes through info().
	func by_id() -> Dictionary:
		return _by_id

## **Far bodies posed less often** (animation LOD; OURS). What a posed body
## costs is not the GDScript pose alone (40 us at the crowd site): a
## skeleton that changed is re-skinned by the renderer, and the two came to
## about 0.2 ms a posed body there (posing and sounds off took the site from
## ~25 to ~15 ms a frame with ~46 bodies posed a frame). Retail's per-object animation rule for characters is unread (it
## passes a distance / 800 LOD factor to the mesh draw, 0x9c4c05, which is a
## mesh LOD, not an animation one: READ, round 664). So, as our choice: a
## body within POSE_FULL of the camera is posed every frame, as before; one
## within POSE_HALF every second frame (30 poses a second at 60 frames); one
## farther out (to POSE_RANGE, 2,020) every fourth. Each body keeps its own
## clip time -- a skipped frame is not a slower clip, the next pose is where
## the clip has got to -- and the frames a body skips are spread by its
## slot, so the load is even. What the player fights -- within 300 units of
## the camera -- is posed every frame; round 664's READ window
## (session/aoi.go) sends a player only monsters 320-640 units around it.
const POSE_FULL := 300.0
const POSE_HALF := 900.0

## Every how many frames a body `dist` from the camera is posed: 1, 2 or 4.
static func pose_interval(dist: float) -> int:
	if dist < POSE_FULL:
		return 1
	if dist < POSE_HALF:
		return 2
	return 4

## Whether a body in `slot` is posed on `tick` at `interval`.
static func pose_due(tick: int, slot: int, interval: int) -> bool:
	return interval <= 1 or (tick + slot) % interval == 0

## **Quiet bodies tested every second frame** (OURS). Most of a crowd is
## out of view and out of hearing at any moment, and testing each of them
## every frame was most of the tick's own cost. A looping body that was
## neither in view nor within hearing at its last test is tested again on
## every second frame (its slot's parity): one that comes into view is posed
## at most one frame late, and one that comes within hearing starts its
## sounds a frame later, silently (it was resting). A one-shot is tested every
## frame, since its hand-back runs unseen.
static func recheck_due(tick: int, slot: int) -> bool:
	return (tick + slot) % 2 == 0

## **Posing without the name search.** Skeleton3DBuilder.apply_ban_pose_at
## looks every track's bone up by name each frame and then forces every bone
## transform to be recomputed at once. A monster body is a duplicate of its
## species' template (MonsterDraw.Templates), so every body of one model has
## the same bones in the same order: the bone index of each track is looked
## up once per clip and model (META_LAYOUT names the model), and the skeleton
## recomputes its transforms once, at the end of the frame, as Godot does
## for any pose change. The pose itself is the same: the same two keys, the
## same blend (the test compares the two bone by bone). A skeleton without
## META_LAYOUT (the player, other players, NPCs) takes the old path.
const META_LAYOUT := "srrevamp_crowd_layout"
const META_BONE_MAPS := "srrevamp_crowd_bone_maps"

static func pose_at(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, seconds: float, loop: bool) -> void:
	if not skeleton.has_meta(META_LAYOUT):
		Skeleton3DBuilder.apply_ban_pose_at(skeleton, anim, seconds, loop)
		return
	var count := anim.key_times.size()
	if count == 0:
		return
	var duration := float(anim.duration_ms)
	var ms := seconds * 1000.0
	if loop and duration > 0.0:
		ms = fposmod(ms, duration)
	elif ms >= duration or count == 1:
		Skeleton3DBuilder.apply_ban_pose(skeleton, anim, count - 1)
		return
	var i := anim.key_index_at(ms / 1000.0, false)
	var j := i + 1
	var t0 := float(anim.key_times[i])
	var t1: float
	if j < count:
		t1 = float(anim.key_times[j])
	else:
		j = 0
		t1 = duration
	var frac := 0.0 if t1 <= t0 else clampf((ms - t0) / (t1 - t0), 0.0, 1.0)
	var bones := bone_map(skeleton, anim)
	var tracks := anim.bones
	for k in range(tracks.size()):
		var bone_idx: int = bones[k]
		if bone_idx == -1:
			continue
		var track: BanReader.Bone = tracks[k]
		var a: BanReader.Keyframe = track.keyframes[i % track.keyframes.size()]
		var b: BanReader.Keyframe = track.keyframes[j % track.keyframes.size()]
		skeleton.set_bone_pose_rotation(bone_idx, a.rotation.slerp(b.rotation, frac))
		skeleton.set_bone_pose_position(bone_idx, a.position.lerp(b.position, frac))

## The bone index of each of `anim`'s tracks in `skeleton` (-1 for a bone it
## lacks or a track with no keys), found once per clip and META_LAYOUT and
## kept on the clip.
static func bone_map(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation) -> PackedInt32Array:
	var layout = skeleton.get_meta(META_LAYOUT)
	var maps: Dictionary = anim.get_meta(META_BONE_MAPS) if anim.has_meta(META_BONE_MAPS) else {}
	var found = maps.get(layout)
	if found != null:
		return found
	var out := PackedInt32Array()
	for track in anim.bones:
		out.append(-1 if track.keyframes.is_empty() else skeleton.find_bone(track.bone_name))
	maps[layout] = out
	anim.set_meta(META_BONE_MAPS, maps)
	return out

## The frame split (SRREVAMP_QA_MOBSPLIT=<frames>): every <frames> rendered
## frames, one line of where the time went -- the physics steps a rendered
## frame ran, the monster work inside them, and the renderer's own CPU and
## GPU times and counts. QA only.
class Split:
	var every := 0
	var frames := 0
	var steps := 0
	var physics_usec := 0
	var idle_usec := 0
	var heights_usec := 0
	var pump_usec := 0
	var pose_usec := 0
	var sound_usec := 0
	var minimap_usec := 0
	var posed := 0
	var started_usec := 0
	var last_frame := -1

	func _init(p_every: int) -> void:
		every = p_every

	## Called at the top of every physics step with the rendered frame count;
	## returns true when a line is due (the step that starts a new interval).
	func on_step(frame: int) -> void:
		steps += 1
		if frame != last_frame:
			last_frame = frame
			frames += 1

	func due() -> bool:
		return every > 0 and frames >= every

	## The line, and a reset.
	func line(frame: int, bodies: int, render_cpu_ms: float, render_gpu_ms: float, draws: int, objects: int, prims: int, process_ms: float = 0.0, physics_monitor_ms: float = 0.0) -> String:
		var now := Time.get_ticks_usec()
		var f := maxf(float(frames), 1.0)
		var wall_ms := float(now - started_usec) / 1000.0 / f if started_usec > 0 else 0.0
		var s := "QA MOBSPLIT frame %d frame_ms=%.2f steps_per_frame=%.2f physics_ms=%.2f idle_ms=%.2f pose_ms=%.2f sound_ms=%.2f minimap_ms=%.2f heights_ms=%.2f pump_ms=%.2f posed_per_frame=%.0f bodies=%d render_cpu_ms=%.2f render_gpu_ms=%.2f draws=%d objects=%d prims=%d process_ms=%.2f physics_monitor_ms=%.2f" % [
			frame, wall_ms, float(steps) / f, float(physics_usec) / 1000.0 / f,
			float(idle_usec) / 1000.0 / f, float(pose_usec) / 1000.0 / f, float(sound_usec) / 1000.0 / f, float(minimap_usec) / 1000.0 / f,
			float(heights_usec) / 1000.0 / f, float(pump_usec) / 1000.0 / f,
			float(posed) / f, bodies, render_cpu_ms, render_gpu_ms, draws, objects, prims, process_ms, physics_monitor_ms]
		started_usec = now
		frames = 0
		steps = 0
		physics_usec = 0
		idle_usec = 0
		heights_usec = 0
		pump_usec = 0
		pose_usec = 0
		sound_usec = 0
		minimap_usec = 0
		posed = 0
		return s
