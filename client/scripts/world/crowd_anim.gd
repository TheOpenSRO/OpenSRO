extends RefCounted
class_name CrowdAnim

## Other players in a crowd (round 738, docs/protocol/crowd_scale.md lane A).
## Round 736 measured 1000 other players at about 196 ms a frame, two thirds
## of it posing: every other player was posed every rendered frame, in view or
## not, through the name-searched pose (Skeleton3DBuilder.apply_ban_pose_at),
## and each pose wrote 14 skins per body. This file holds the rules that cut
## that, apart from World3D so a headless test can hold them to account
## (crowd_anim_test.gd). The skins are CharacterAppearance's (A2).
##
## - **A1, pose only what is drawn (READ).** The original poses a character
##   only when it was drawn in the previous frame: the draw sets `+0xbc` when
##   the object passes the frustum test (0x9c4bc4..0x9c4bd3), and the update
##   passes `vis = +0xbc && !+0xbd` to `CCompChar::FUN_00c33230`, whose
##   keyframe sampling (`AniMixer::FUN_00c54200`) runs only when it is set; the
##   clip time (`AniMixer::FUN_00c53e80`) always runs. Here another player's
##   skeleton is posed only while its sphere touches the camera's frustum
##   (the test MonsterDraw.pose_wanted makes for monsters, without their range
##   cut or hide); its clip's clock runs on, so a body turning into view is
##   posed where its clip has got to. Its clip sounds are untouched (round 736
##   B3 is lane B's). The local player is posed by its own tick, and the
##   character window's doll and the screens are not "other players": both
##   are posed every frame, as before.
## - **A3, a clip's poses computed once (OURS).** A pose is the clip's two
##   keys blended at a time; every body playing that clip at that time needs
##   the same bone values. pose_cached bakes each clip's pose at multiples of
##   QUANTUM_MS of clip time, lazily, once per clip and skeleton layout, and a
##   body takes the baked frame nearest its time; a body that stays on a clip
##   is given only the channels the clip moves. What a body shows is always
##   an exact pose of its clip, at a clip time at most QUANTUM_MS / 2 from its
##   own. The clip clock advances in whole physics steps (1/60 s, two quanta:
##   MonsterCrowd.TickGate sums them), so within one cycle of a loop that
##   offset is the same at every pose of a body -- a fixed shift of its clip's
##   phase, which is itself ours (World3D gives each body 0.37 s times its
##   index). At a loop's wrap it is re-rounded unless the duration is a
##   multiple of the quantum: at most 0.67 ms of step error once a cycle
##   (MEASURED by round 738's review: 50 of the Figures' 75 loops, worst
##   chinaman_fighter_walkforward). A one-shot's clock lands on its frames
##   exactly (the review: 0.000004 units worst over 38 one-shots).
##   MEASURED (tools/crowd_anim_probe.gd, the 52 Figures standing and
##   running): the fastest bone, a running foot, is 0.44 units from the exact
##   pose at the worst offset.
## - **A4, far bodies posed less often (OURS).** Beyond POSE_FULL of the
##   camera a body is posed every second frame, beyond POSE_HALF every fourth,
##   each on its own slot (MonsterCrowd.pose_due), and only while the clip
##   tick holds at least CROWD_MIN characters -- the original's own trigger
##   for its every-other-frame pose skip (`Map::FUN_00bbdb00(count > 99)`,
##   0x9d7078, READ), which it applies to far non-players only (for a
##   CICPlayer its LOD factor is 0: READ). So this is OURS for players. The
##   bands are not the monsters' 300 / 900 (round 664): a near or mid-range
##   body must look as before, and round 738's probe MEASURED the fastest
##   bone of the Figures' clips (a running foot) at 1.77 units in 1/60 s --
##   5.5 px at 300 units, 1.8 px at 900 (1080 lines, 60 degrees: COMPUTED).
##   Under 100 characters, or within 900, nothing changes.
## - **The indexed pose (OURS, round 664's).** Other players' skeletons carry
##   MonsterCrowd.META_LAYOUT (CharacterAppearance.build), so a pose that is
##   not baked looks each track's bone up once per clip and layout and leaves
##   the bone globals to the skeleton's own end-of-frame update, as a
##   monster's does, instead of a name search per track and a forced update.
##
## The switches are for the QA A/B (QaCrowdProbe's `anim=` steps); all are on
## in play. With every one off, another player is posed exactly as before.
static var cull_players := true
static var indexed_players := true
static var cache_poses := true
static var lod_players := true

## Frames baked so far, every clip and layout (QA: QaCrowdProbe's line).
static var baked_frames := 0

## The original's crowd count for its pose skip: more than 99 (READ,
## 0x9d7078 `count > 99`).
const CROWD_MIN := 100

## The bands of A4 (OURS; see the header): every frame within POSE_FULL of
## the camera, every second frame to POSE_HALF, every fourth beyond.
const POSE_FULL := 900.0
const POSE_HALF := 1800.0

## The baking quantum of A3, in milliseconds of clip time (OURS). 1000/120:
## half a physics step, so a body's offset from its own time (at most 4.2 ms)
## is fixed within a loop's cycle (see the header). docs/rounds/r738.md has
## what it moves a bone and what the frames cost in memory (MEASURED).
const QUANTUM_MS := 1000.0 / 120.0

## How much a player's cull sphere is grown past its meshes' bind-pose reach
## (OURS): a clip can swing a limb or a weapon past the bind box, and a body
## half in view must be posed. 1.5 costs a few bodies at the screen's edges.
const RADIUS_MARGIN := 1.5

## The CullCache entry of another player has this many fields; a monster's
## or NPC's has five (MonsterCrowd.CullCache).
const PLAYER_INFO_SIZE := 6

## Meta on another player's skeleton once the cull cache has seen it:
## MonsterCrowd.pose_at then poses it from its clip's baked frames (A3, pose_cached).
const META_CACHED := "opensro_crowd_cached"
## Meta on a skeleton pose_cached posed: the Frames it last took, so a body
## that stays on a clip is given only the channels the clip moves.
const META_LAST := "opensro_crowd_last"
## Meta on a clip: its baked frames, by skeleton layout.
const META_FRAMES := "opensro_crowd_frames"

## Whether `skeleton` is another player's body: its holder is the node
## World3D._spawn_or_update_other makes, which carries the player's
## `character_id` (and _redress_other keeps). The local player, the doll, the
## screens' bodies, NPCs and monsters have no such holder.
static func is_other_player(skeleton: Skeleton3D) -> bool:
	var holder := skeleton.get_parent()
	return holder != null and holder.has_meta("character_id")

## The radius of another player's cull sphere about its feet: its meshes'
## bind-pose reach (MonsterDraw.cull_radius) times its scale (Height), grown
## by RADIUS_MARGIN.
static func player_radius(skeleton: Skeleton3D) -> float:
	var s := skeleton.scale
	return MonsterDraw.cull_radius(skeleton, 1.0) * maxf(maxf(s.x, s.y), maxf(s.z, 1.0)) * RADIUS_MARGIN

## Every how many frames another player `dist` from the camera is posed, with
## `characters` animated bodies in the tick (A4): 1 below CROWD_MIN or within
## POSE_FULL, 2 within POSE_HALF, else 4.
static func pose_interval(dist: float, characters: int) -> int:
	if not lod_players or characters < CROWD_MIN or dist < POSE_FULL:
		return 1
	return 2 if dist < POSE_HALF else 4

## Sets the switches from a step's list: "1" A1, "i" the indexed pose, "3"
## A3, "4" A4, "5" A5 (round 747: far bodies drawn by CrowdGpu, which needs
## A3's frames); any other text (e.g. "-") none. QA only.
static func set_switches(list: String) -> void:
	cull_players = list.contains("1")
	indexed_players = list.contains("i")
	cache_poses = list.contains("3")
	lod_players = list.contains("4")
	CrowdGpu.enabled = list.contains("5")

static func switches() -> String:
	var s := ""
	if cull_players:
		s += "1"
	if indexed_players:
		s += "i"
	if cache_poses:
		s += "3"
	if lod_players:
		s += "4"
	if CrowdGpu.enabled:
		s += "5"
	return s if s != "" else "-"

## One clip's poses on one skeleton layout, baked at multiples of QUANTUM_MS.
## A channel no key of the clip moves is kept once (its first key, which every
## blend of it equals); a frame holds only the channels the clip moves.
class Frames:
	## The clip's key times and duration (copies: the clip holds this object
	## in its meta, and a reference back would keep both alive for ever -- a
	## cast clip is parsed afresh for every cast).
	var key_times: PackedInt32Array
	var duration_ms := 0
	## The skeleton bone of each track with keys and a bone (MonsterCrowd.bone_map).
	var bones: PackedInt32Array = PackedInt32Array()
	## The track's keyframes, in the order of `bones`.
	var tracks: Array = []
	## Each bone's first key, rotation and position, in the order of `bones`.
	var static_rot: Array = []
	var static_pos: Array = []
	## Of `bones`, the indices whose rotation (resp. position) differs between
	## two of the clip's keys -- the channels a body on this clip needs each
	## frame -- and their skeleton bones.
	var moving_rot: PackedInt32Array = PackedInt32Array()
	var moving_pos: PackedInt32Array = PackedInt32Array()
	var moving_rot_bones: PackedInt32Array = PackedInt32Array()
	var moving_pos_bones: PackedInt32Array = PackedInt32Array()
	## How many frames a loop bakes (its duration in quanta, rounded up); a
	## one-shot has one more, its end.
	var count := 0
	## Frame -> [rotations (Quaternion, per moving_rot), positions (Vector3,
	## per moving_pos)], or null until a body first needs it.
	var frames: Array = []
	var baked := 0

	func _init(anim: BanReader.ParsedAnimation, bone_map: PackedInt32Array) -> void:
		key_times = anim.key_times
		duration_ms = anim.duration_ms
		for k in range(bone_map.size()):
			if bone_map[k] == -1:
				continue
			var track: BanReader.Bone = anim.bones[k]
			var keys: Array = track.keyframes
			bones.append(bone_map[k])
			tracks.append(keys)
			var first: BanReader.Keyframe = keys[0]
			static_rot.append(first.rotation)
			static_pos.append(first.position)
			var rot_moves := false
			var pos_moves := false
			for kf in keys:
				var f: BanReader.Keyframe = kf
				if f.rotation != first.rotation:
					rot_moves = true
				if f.position != first.position:
					pos_moves = true
			if rot_moves:
				moving_rot.append(bones.size() - 1)
				moving_rot_bones.append(bone_map[k])
			if pos_moves:
				moving_pos.append(bones.size() - 1)
				moving_pos_bones.append(bone_map[k])
		count = maxi(int(ceil(float(duration_ms) / QUANTUM_MS)), 1)
		frames.resize(count + 1)

	## Frame `f`'s moving channels, baked on first use: the blend pose_at
	## makes at f x QUANTUM_MS into the clip (a loop wrapping at its duration
	## into its first key; a one-shot holding its last).
	func frame(f: int, loop: bool) -> Array:
		var got = frames[f]
		if got != null:
			return got
		var ms := minf(float(f) * QUANTUM_MS, float(duration_ms))
		var key_count := key_times.size()
		var i := 0
		var j := 0
		var frac := 0.0
		if not loop and (ms >= float(duration_ms) or key_count == 1):
			i = key_count - 1
			j = i
		else:
			# The last key not past `ms` (BanReader.ParsedAnimation.key_index_at).
			for n in range(key_count):
				if float(key_times[n]) <= ms:
					i = n
				else:
					break
			j = i + 1
			var t0 := float(key_times[i])
			var t1: float
			if j < key_count:
				t1 = float(key_times[j])
			else:
				j = 0
				t1 = float(duration_ms)
			frac = 0.0 if t1 <= t0 else clampf((ms - t0) / (t1 - t0), 0.0, 1.0)
		var rots: Array = []
		var poss: Array = []
		rots.resize(moving_rot.size())
		poss.resize(moving_pos.size())
		for n in range(moving_rot.size()):
			var keys: Array = tracks[moving_rot[n]]
			var a: BanReader.Keyframe = keys[i % keys.size()]
			var b: BanReader.Keyframe = keys[j % keys.size()]
			rots[n] = a.rotation.slerp(b.rotation, frac)
		for n in range(moving_pos.size()):
			var keys: Array = tracks[moving_pos[n]]
			var a: BanReader.Keyframe = keys[i % keys.size()]
			var b: BanReader.Keyframe = keys[j % keys.size()]
			poss[n] = a.position.lerp(b.position, frac)
		got = [rots, poss]
		frames[f] = got
		baked += 1
		CrowdAnim.baked_frames += 1
		return got

## The frames of `anim` on `skeleton`'s layout (MonsterCrowd.META_LAYOUT),
## made once and kept on the clip.
##
## Frames are shared by file and layout between clip objects (round 738's
## review, F1): each body template keeps its own clip objects, since a clip
## carries the entry its body found it as (BsrReader.CLIP_META, the key to
## that body's sound set), but the same file is the same poses. A clip
## SkinnedBsrAssembler.animation_for parsed carries its path
## (CLIP_PATH_META); one without (a cast clip parsed for one cast) bakes its
## own. The answer is kept on the clip too, so the path is looked up once.
static func frames_for(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation) -> Frames:
	var layout = skeleton.get_meta(MonsterCrowd.META_LAYOUT)
	var by_layout: Dictionary = anim.get_meta(META_FRAMES) if anim.has_meta(META_FRAMES) else {}
	var got = by_layout.get(layout)
	if got != null:
		return got
	var made: Frames = null
	var key := ""
	if anim.has_meta(SkinnedBsrAssembler.CLIP_PATH_META):
		key = "%s|%s" % [String(anim.get_meta(SkinnedBsrAssembler.CLIP_PATH_META)), str(layout)]
		made = _shared.get(key)
	if made == null:
		made = Frames.new(anim, MonsterCrowd.bone_map(skeleton, anim))
		if key != "":
			_shared[key] = made
	by_layout[layout] = made
	anim.set_meta(META_FRAMES, by_layout)
	return made

## Frames by "clip path|layout", shared between the bodies' own clip objects.
static var _shared := {}

## Forgets the shared frames (CharacterAppearance.free_templates). A clip
## object keeps what it already found.
static func clear_shared_frames() -> void:
	_shared.clear()

static func shared_frames() -> int:
	return _shared.size()

## The baked frame a body `seconds` into `anim` takes: the nearest multiple
## of QUANTUM_MS, a loop's time wrapped at its duration (the frame past its
## last is its first, which is its end), a one-shot's held at its end.
static func frame_index(anim: BanReader.ParsedAnimation, seconds: float, loop: bool, count: int) -> int:
	var ms := seconds * 1000.0
	var duration := float(anim.duration_ms)
	if loop and duration > 0.0:
		return int(fposmod(ms, duration) / QUANTUM_MS + 0.5) % count
	return clampi(int(ms / QUANTUM_MS + 0.5), 0, count)

## Poses `skeleton` from the baked frame (A3): the channels the clip moves,
## and when it last took another clip (or none) every other channel too. The bone
## globals are left to the skeleton's own end-of-frame update, as
## MonsterCrowd.pose_at leaves them.
static func pose_cached(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, seconds: float, loop: bool) -> void:
	if anim.key_times.is_empty():
		return
	var fr := frames_for(skeleton, anim)
	var got: Array = fr.frame(frame_index(anim, seconds, loop, fr.count), loop)
	if not skeleton.has_meta(META_LAST) or skeleton.get_meta(META_LAST) != fr:
		skeleton.set_meta(META_LAST, fr)
		var bones := fr.bones
		for k in range(bones.size()):
			skeleton.set_bone_pose_rotation(bones[k], fr.static_rot[k])
			skeleton.set_bone_pose_position(bones[k], fr.static_pos[k])
	var rots: Array = got[0]
	var rb := fr.moving_rot_bones
	for n in range(rb.size()):
		skeleton.set_bone_pose_rotation(rb[n], rots[n])
	var poss: Array = got[1]
	var pb := fr.moving_pos_bones
	for n in range(pb.size()):
		skeleton.set_bone_pose_position(pb[n], poss[n])
