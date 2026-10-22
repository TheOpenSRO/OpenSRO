extends RefCounted
class_name ClipMixer

## One body's clips as the client mixes them (round 808; docs/protocol/
## animation_mixer.md): loops that crossfade, one-shots on top of them, and
## nothing ever switched in a single frame. This is what makes a click behind
## the player "take a step" -- the run starts from its first frame and fades
## in over 100 ms while the stand fades out over 200, and on arrival the run
## goes on cycling while it fades out over 200 -- where a single clip swapped
## each frame popped into mid-stride and back.
##
## **The rules (READ, sro_client.exe; addresses in the doc):**
## - **Two lists.** A clip the play call (character vtable +0xbc -> 0x9cfb40
##   -> CCObjAnimation 0xa5b550) finds cyclic goes on the loop list
##   (AniMixer::FUN_00c55360), any other on the one-shot list (0xc554e0).
## - **A loop played starts over**: t = 0 and weight 0, even when the same clip
##   is already on the list (0xc74170, 0xc731a0). Each frame (CRTAniCyclic
##   vslot_002, 0xc74790) its clock steps `speed x dt` ms and wraps at its
##   length, and its weight moves linearly to the target over the fade's
##   remaining ms: `w += (target - w) x step / rem`, `rem -= step`; at the end
##   `w = target`, and a clip whose target is 0 is dropped.
## - **A one-shot** (CRTAniOneShot vslot_002, 0xc749a0) fades in over A ms
##   (`w = 1 - rem / A`; A = 0 is weight 1 at once), plays to its end, then
##   **holds its last frame while it fades out over B ms** (`w = rem / B`) and
##   is dropped at 0.
## - **A stop** (+0xc0 -> 0x9cfc10) fades the clip to 0 over the ms given,
##   linearly (a one-shot at its current weight's rate, 0xc73310).
## - **The mix, per bone** (AniMixer::FUN_00c54200, CRTBone 0xc48e30 /
##   0xc48ef0): within a list a normalised weighted average (the first sample
##   copied, then each next one `t = w / (acc + w)` -- slerp, lerp -- and
##   `acc += w`); the one-shots are committed first at `min(acc, 1)`, the
##   loops into what is left, `w2 = min(acc, 1 - committed)`, as
##   `lerp(one-shots, loops, w2 / (committed + w2))`. So a one-shot at weight 1
##   hides every loop, and as it fades the loops under it show through; a lone
##   clip shows fully whatever its weight; with nothing playing the bones keep
##   their last pose.
## - The clock steps whole milliseconds (`round(speed x dt + carry)`); this
##   class keeps the fraction instead -- the same time, without the rounding.
##
## OURS: a held one-shot (`hold`, the die clip: OpenSRO holds its last frame
## where the client fades it into the death loop) and a repeating one-shot
## (`repeat`, a decoration's WAIT hold) are this client's own states, played
## here as one-shots that never fade.

## The fades the character states pass (READ, the state table at 0xec5fb8:
## the enter and exit functions' pushed constants; docs/protocol/
## animation_mixer.md has the table).
const RUN_IN_MS := 100.0
const LOOP_IN_MS := 200.0
const STOP_MS := 200.0
## A one-shot a state starts with no fade-in and hands back over 200 ms: sit
## down 13, stand up 15, a hit 3, the death 4 (0xa5a270, 0xa5a160, 0xa59b10,
## 0xa59cc0: `(type, 0, 200, ...)`).
const SNAP_IN_MS := 0.0
const SHOT_OUT_MS := 200.0
## The pick-up 38 and the emotes 0x32+n fade both ways (0xa59a00, 0xa59bc0).
const SHOT_IN_MS := 200.0
## The idle fidget fades both ways over 400 (0xa59460).
const FIDGET_MS := 400.0

class Layer:
	var clip: BanReader.ParsedAnimation
	var once := false
	## Where the clip is, in ms.
	var t := 0.0
	var speed := 1.0
	var w := 0.0
	var target := 1.0
	## The fade's ms left (a loop's fade, a one-shot's fade-in or fade-out).
	var rem := 0.0
	## A one-shot's fade-in (A) and fade-out (B).
	var fade_in := 0.0
	var fade_out := 0.0
	## A one-shot past its end, holding its last frame.
	var ended := false
	## Stopped: fading to 0 over `stop_ms` from `stop_w`.
	var stopping := false
	var stop_ms := 0.0
	var stop_w := 0.0
	var hold := false
	var repeat := false
	## Which play of the clip this is (for the sounds' "same play" test).
	var serial := 0

var loops: Array = []
var shots: Array = []
var _serial := 0
## clip instance id -> its tracks' bone indices in the skeleton last applied.
var _bones := {}
var _bones_skeleton := 0

## Plays a loop: from its first frame, fading in over `fade_in_ms`.
func play_loop(clip: BanReader.ParsedAnimation, fade_in_ms: float, speed: float = 1.0, weight: float = 1.0) -> void:
	if clip == null:
		return
	var l := _find(loops, clip)
	if l == null:
		l = Layer.new()
		l.clip = clip
		loops.append(l)
	l.t = 0.0
	l.w = 0.0 if fade_in_ms > 0.0 else minf(weight, 1.0)
	l.target = minf(weight, 1.0)
	l.rem = fade_in_ms
	l.speed = speed
	l.stopping = false
	_serial += 1
	l.serial = _serial

## Plays a one-shot over the loops: in over `fade_in_ms`, out over
## `fade_out_ms` once it has played. `hold` never fades it (it holds its last
## frame); `repeat` plays it again from its start each time it ends.
func play_once(clip: BanReader.ParsedAnimation, fade_in_ms: float, fade_out_ms: float, speed: float = 1.0,
		hold: bool = false, repeat: bool = false) -> void:
	if clip == null:
		return
	var l := _find(shots, clip)
	if l == null:
		l = Layer.new()
		l.clip = clip
		l.once = true
		shots.append(l)
	l.t = 0.0
	l.fade_in = fade_in_ms
	l.fade_out = fade_out_ms
	l.rem = fade_in_ms
	l.w = 0.0 if fade_in_ms > 0.0 else 1.0
	l.target = 1.0
	l.speed = speed
	l.ended = false
	l.stopping = false
	l.hold = hold
	l.repeat = repeat
	_serial += 1
	l.serial = _serial

## Fades `clip` out over `ms`, wherever it is (either list).
func stop(clip: BanReader.ParsedAnimation, ms: float) -> void:
	for l in loops + shots:
		if (l as Layer).clip == clip:
			_stop_layer(l, ms)

## Fades every loop but `keep` out over `ms`.
func stop_loops_except(keep: BanReader.ParsedAnimation, ms: float) -> void:
	for l in loops:
		if (l as Layer).clip != keep and not (l as Layer).stopping:
			_stop_layer(l, ms)

## Fades every one-shot out over `ms`.
func stop_shots(ms: float) -> void:
	for l in shots:
		if not (l as Layer).stopping:
			_stop_layer(l, ms)

func _stop_layer(l: Layer, ms: float) -> void:
	if ms <= 0.0:
		l.w = 0.0
		l.target = 0.0
		l.stopping = true
		l.stop_ms = 0.0
		return
	l.stopping = true
	l.stop_ms = ms
	l.stop_w = l.w
	l.rem = ms
	l.target = 0.0

## The loop `clip`'s layer at full or rising weight (not being stopped), or null.
func live_loop(clip: BanReader.ParsedAnimation) -> Layer:
	var l := _find(loops, clip)
	return l if l != null and not l.stopping else null

## Where `clip` is, in ms (-1 when it is not playing).
func time_ms(clip: BanReader.ParsedAnimation) -> float:
	for l in loops + shots:
		if (l as Layer).clip == clip:
			return (l as Layer).t
	return -1.0

## The play serial of `clip` (0 when it is not playing).
func serial_of(clip: BanReader.ParsedAnimation) -> int:
	for l in loops + shots:
		if (l as Layer).clip == clip:
			return (l as Layer).serial
	return 0

## Nothing on either list.
func is_empty() -> bool:
	return loops.is_empty() and shots.is_empty()

## Drops every clip at once (a rebuilt body).
func clear() -> void:
	loops.clear()
	shots.clear()
	_bones.clear()

## Advances every clip by `dt_ms` of game time.
func step(dt_ms: float) -> void:
	var keep: Array = []
	for l in loops:
		if _step_loop(l, dt_ms):
			keep.append(l)
	loops = keep
	keep = []
	for l in shots:
		if _step_shot(l, dt_ms):
			keep.append(l)
	shots = keep

static func _step_loop(l: Layer, dt_ms: float) -> bool:
	var step := l.speed * dt_ms
	var dur := float(l.clip.duration_ms)
	l.t += step
	if dur > 0.0 and l.t >= dur:
		l.t = fposmod(l.t, dur)
	if l.rem > step:
		l.w += (l.target - l.w) * step / l.rem
		l.rem -= step
	else:
		l.rem = 0.0
		l.w = l.target
		if l.target <= 0.0:
			return false
	return true

static func _step_shot(l: Layer, dt_ms: float) -> bool:
	var step := l.speed * dt_ms
	var dur := float(l.clip.duration_ms)
	l.t += step
	if l.stopping:
		if l.stop_ms <= 0.0:
			return false
		l.rem -= step
		if l.rem <= 0.0:
			return false
		l.w = l.stop_w * l.rem / l.stop_ms
		if l.t > dur:
			l.t = dur
		return true
	if l.repeat and dur > 0.0 and l.t >= dur:
		l.t = fposmod(l.t, dur)
	if not l.ended and l.t >= dur:
		# Played: hold the last frame and fade out over B.
		l.ended = true
		l.t = dur
		l.rem = l.fade_out
		if l.hold:
			l.w = 1.0
			return true
		if l.fade_out <= 0.0:
			return false
		l.w = 1.0
		return true
	if l.ended:
		l.t = dur
		if l.hold:
			return true
		l.rem -= step
		if l.rem <= 0.0:
			return false
		l.w = l.rem / l.fade_out
		return true
	# Fading in (A), then at full weight.
	if l.fade_in > 0.0 and l.rem > 0.0:
		l.rem = maxf(l.rem - step, 0.0)
		l.w = 1.0 - l.rem / l.fade_in
	else:
		l.w = 1.0
	return true

## Poses `skeleton` from the clips (nothing playing leaves it as it is). A
## lone clip at any weight is posed exactly as Skeleton3DBuilder.
## apply_ban_pose_at poses it.
func apply(skeleton: Skeleton3D) -> void:
	if skeleton == null or is_empty():
		return
	if loops.size() + shots.size() == 1:
		var only: Layer = loops[0] if not loops.is_empty() else shots[0]
		Skeleton3DBuilder.apply_ban_pose_at(skeleton, only.clip, only.t / 1000.0, not only.once)
		return
	if skeleton.get_instance_id() != _bones_skeleton:
		_bones.clear()
		_bones_skeleton = skeleton.get_instance_id()
	var n := skeleton.get_bone_count()
	var shot_rot: Array = []
	var shot_pos := PackedVector3Array()
	var shot_acc := PackedFloat32Array()
	var loop_rot: Array = []
	var loop_pos := PackedVector3Array()
	var loop_acc := PackedFloat32Array()
	shot_rot.resize(n)
	loop_rot.resize(n)
	shot_pos.resize(n)
	loop_pos.resize(n)
	shot_acc.resize(n)
	loop_acc.resize(n)
	shot_acc.fill(-1.0)
	loop_acc.fill(-1.0)
	for l in shots:
		_accumulate(skeleton, l, shot_rot, shot_pos, shot_acc)
	for l in loops:
		_accumulate(skeleton, l, loop_rot, loop_pos, loop_acc)
	for b in n:
		var has_shot := shot_acc[b] >= 0.0
		var has_loop := loop_acc[b] >= 0.0
		if not has_shot and not has_loop:
			continue
		var rot: Quaternion
		var pos: Vector3
		if has_shot and has_loop:
			var committed := minf(shot_acc[b], 1.0)
			var w2 := minf(loop_acc[b], 1.0 - committed)
			# Both at weight 0 (a one-shot fading in from 0 over loops
			# fading out): the loops, as the weights' limit has it.
			var k := w2 / (committed + w2) if committed + w2 > 0.0 else 1.0
			rot = (shot_rot[b] as Quaternion).slerp(loop_rot[b] as Quaternion, k)
			pos = shot_pos[b].lerp(loop_pos[b], k)
		elif has_shot:
			rot = shot_rot[b]
			pos = shot_pos[b]
		else:
			rot = loop_rot[b]
			pos = loop_pos[b]
		skeleton.set_bone_pose_rotation(b, rot)
		skeleton.set_bone_pose_position(b, pos)
	Skeleton3DBuilder.refresh_global_poses(skeleton)

## One clip into a list's running average: the first sample a bone gets is
## copied, each next one blended in by `w / (acc + w)`.
func _accumulate(skeleton: Skeleton3D, l: Layer, rots: Array, poss: PackedVector3Array, accs: PackedFloat32Array) -> void:
	var anim := l.clip
	var count := anim.key_times.size()
	if count == 0:
		return
	var key := sample_keys(anim, l.t, not l.once)
	var i: int = key[0]
	var j: int = key[1]
	var frac: float = key[2]
	var bones := _bone_map(skeleton, anim)
	var tracks := anim.bones
	for k in range(tracks.size()):
		var b: int = bones[k]
		if b < 0:
			continue
		var track: BanReader.Bone = tracks[k]
		var ka: BanReader.Keyframe = track.keyframes[i % track.keyframes.size()]
		var kb: BanReader.Keyframe = track.keyframes[j % track.keyframes.size()]
		var r := ka.rotation.slerp(kb.rotation, frac)
		var p := ka.position.lerp(kb.position, frac)
		var acc := accs[b]
		if acc < 0.0:
			rots[b] = r
			poss[b] = p
			accs[b] = l.w
			continue
		var tot := acc + l.w
		if tot <= 0.0:
			continue
		var s := l.w / tot
		rots[b] = (rots[b] as Quaternion).slerp(r, s)
		poss[b] = poss[b].lerp(p, s)
		accs[b] = tot

## The two keys bracketing `ms` into `anim` and how far between them: [i, j,
## frac] -- exactly the keys and blend Skeleton3DBuilder.apply_ban_pose_at
## uses (a loop wraps and blends its last key back into its first; a
## one-shot holds its last).
static func sample_keys(anim: BanReader.ParsedAnimation, ms: float, loop: bool) -> Array:
	var count := anim.key_times.size()
	var duration := float(anim.duration_ms)
	if loop and duration > 0.0:
		ms = fposmod(ms, duration)
	elif ms >= duration or count == 1:
		return [count - 1, count - 1, 0.0]
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
	return [i, j, frac]

func _bone_map(skeleton: Skeleton3D, anim: BanReader.ParsedAnimation) -> PackedInt32Array:
	var id := anim.get_instance_id()
	var found = _bones.get(id)
	if found != null:
		return found
	var out := PackedInt32Array()
	for track in anim.bones:
		out.append(-1 if track.keyframes.is_empty() else skeleton.find_bone(track.bone_name))
	_bones[id] = out
	return out

func _find(list: Array, clip: BanReader.ParsedAnimation) -> Layer:
	for l in list:
		if (l as Layer).clip == clip:
			return l
	return null

# --- Other bodies (round 808) ------------------------------------------------
#
# A body in the shared clip tick (World3D._animated: other players, monsters,
# NPCs, pets) keeps its one entry and its fast posing; what the mixer adds to
# it is the change from one clip to the next: the new loop starts from its
# first frame, and for the fade's length the outgoing clip -- a loop still
# cycling, or a one-shot holding its last frame -- is blended over the pose
# the entry wrote, by the same weights the full mixer gives the two.

## One body's change of clip, in progress.
class Fade:
	var from: BanReader.ParsedAnimation
	## Where `from` was at the change (ms), and whether it cycles on; an
	## outgoing one-shot goes on from there to its last frame and holds it (a
	## hand-back at its end starts at its length).
	var from_ms := 0.0
	var from_loop := true
	## The new clip is a one-shot fading in over the loop that goes on
	## (`from`): its share is its own fade-in weight (the fidget's 400 ms).
	var over := false
	## When the change was made (the clip tick's seconds) and its fades (ms):
	## the new loop's fade-in and the outgoing clip's fade-out.
	var at := 0.0
	var in_ms := LOOP_IN_MS
	var out_ms := STOP_MS
	var bones := PackedInt32Array()
	var bones_skeleton := 0

	func done(now: float) -> bool:
		if over:
			return (now - at) * 1000.0 >= in_ms
		return (now - at) * 1000.0 >= maxf(in_ms, out_ms)

## The new pose's share `e_ms` into a change (0 all old, 1 all new), as the
## mix weighs the two: an outgoing loop fading out linearly against the new one
## fading in, normalised; an outgoing one-shot, committed over the loops at its
## own fading weight, leaves them `1 - w`.
static func fade_share(e_ms: float, in_ms: float, out_ms: float, from_loop: bool, over: bool = false) -> float:
	if over:
		return 1.0 if in_ms <= 0.0 else clampf(e_ms / in_ms, 0.0, 1.0)
	var w_from := 0.0 if out_ms <= 0.0 else clampf(1.0 - e_ms / out_ms, 0.0, 1.0)
	if not from_loop:
		return 1.0 - w_from
	var w_to := 1.0 if in_ms <= 0.0 else clampf(e_ms / in_ms, 0.0, 1.0)
	if w_to + w_from <= 0.0:
		return 1.0
	return w_to / (w_to + w_from)

## Blends `fade`'s outgoing clip over the pose `skeleton` holds now (the new
## clip's, just written). False once the change is over.
static func blend_from(skeleton: Skeleton3D, fade: Fade, now: float) -> bool:
	if fade == null or fade.from == null or skeleton == null:
		return false
	var e := (now - fade.at) * 1000.0
	var share := fade_share(e, fade.in_ms, fade.out_ms, fade.from_loop, fade.over)
	if share >= 1.0:
		return not fade.done(now)
	var anim := fade.from
	if anim.key_times.is_empty():
		return false
	var t := fade.from_ms + e if fade.from_loop else minf(fade.from_ms + e, float(anim.duration_ms))
	var key := sample_keys(anim, t, fade.from_loop)
	var i: int = key[0]
	var j: int = key[1]
	var frac: float = key[2]
	if fade.bones_skeleton != skeleton.get_instance_id():
		fade.bones = PackedInt32Array()
		for track in anim.bones:
			fade.bones.append(-1 if track.keyframes.is_empty() else skeleton.find_bone(track.bone_name))
		fade.bones_skeleton = skeleton.get_instance_id()
	var tracks := anim.bones
	for k in range(tracks.size()):
		var b: int = fade.bones[k]
		if b < 0:
			continue
		var track: BanReader.Bone = tracks[k]
		var ka: BanReader.Keyframe = track.keyframes[i % track.keyframes.size()]
		var kb: BanReader.Keyframe = track.keyframes[j % track.keyframes.size()]
		var r := ka.rotation.slerp(kb.rotation, frac)
		var p := ka.position.lerp(kb.position, frac)
		skeleton.set_bone_pose_rotation(b, r.slerp(skeleton.get_bone_pose_rotation(b), share))
		skeleton.set_bone_pose_position(b, p.lerp(skeleton.get_bone_pose_position(b), share))
	return true
