extends RefCounted
class_name MonsterMotion

## How a server-driven monster move is drawn: the leg an OpMonsterMoved push
## or an OpMonsterMotionList entry starts (docs/protocol/monster_ai.md,
## "OpenSRO's own monster protocol (placeholders)"), stepped every physics
## frame by the engine's own mover, with the walk or run clip and the body
## turned along its path. Pure and static so a headless test can hold every
## rule to account; World3D._on_monster_moved, _on_monster_motion_list and
## _step_monster_bodies are the glue.
##
## A leg's state is a Dictionary:
##   pos    Vector2  where the body is drawn (world x, z)
##   dest   Vector2  where the leg ends
##   speed  float    world units per second
##   mode   int      0 walk clip, 1 run clip
##   moving bool     the leg has not arrived
##   stop   bool     the message was a stop (dest == the server position):
##                  the body glides to it in the stand clip and is not turned

## THE ENGINE'S STEP CAP: one frame never moves a body more than 160 units.
## CGObjMoverByDest::FUN_0048bff0 (SR_GameServer.exe) returns the owner's unit
## direction (+0x24/+0x2c) times min(|speed(+0x174) x dt|, cap), and the cap is
## the .rdata float at 0xb45ea8 = 0x43200000 = 160.0f (re-read 2026-09-24).
## Its zeroing of a component under 0.01f (0xb45df8) is not modelled.
const MOVER_STEP_CAP := 160.0

## How far the drawn body may drift from the server's position before it is
## put back there. OpenSRO's own number: it must exceed the lag a moving body
## legitimately carries, and the fastest roster run -- Earth Ghost's 75 u/s
## (characterdata col 47, docs/protocol/monster_ai.md "The roster's real walk
## and run speeds") -- over a 0.3 s round trip is 22.5.
const RESYNC_DISTANCE := 32.0
## How far a walking body moves between two height resolves. OpenSRO's own
## number; the height comes from the region's walkable graph, with the
## terrain-only ray where no loaded region covers the body
## (World3D._moving_monster_height_at, round 557; before it the ray alone).
const HEIGHT_RESOLVE_STEP := 2.0
## At most this many height resolves a frame across every walking body; the
## rest keep their height until a later frame. OpenSRO's own number.
const MAX_HEIGHT_RESOLVES_PER_FRAME := 32
## A move for a monster the client has not been told about asks for the list,
## but no more than once in this many seconds. OpenSRO's own number.
const UNKNOWN_MOVE_PULL_SECONDS := 5.0
## A motion-list entry re-aims a body only when its destination differs from
## the one being walked to by more than this. OpenSRO's own number.
const REAIM_EPSILON := 0.5

const MODE_WALK := 0
const MODE_RUN := 1

## Which way a model's body faces in its own skeleton space: -Z, for every
## monster model.
##
## MEASURED by client/tools/probe_monster_front.gd on the render box (the
## mean toe-minus-foot bone vector and the head-minus-pelvis offset, at the
## bind pose and at the walk clip's first frame; the player's body,
## CHAR_CH_MAN_FIGHTER, read -Z as the control). Round 533 probed the eleven
## roster species (seven models, all -Z) and kept them in a table; every
## model not in it was left unturned, "facing unmeasured". Round 660 put
## every field species on the map, so most monsters never turned: round
## 673's live run measured the Gun Powder ghosts beside Donwhang's Earth
## Ghosts facing one fixed way on all 14 of a chase's legs, 2 to 179 degrees
## off their path, while the Earth Ghosts (in the table) kept within 0.5.
## Round 673's census (--all=1) probed all 155 models the MOB_ rows draw:
## 117 read -Z; 36 name no axis (no toe, head or pelvis bones -- the
## tombstones, Nachal -- or readings that disagree: a crab's toes point back
## from its head); 2, the event Jinn pets (cos\p_jinn*.bsr), read +Z on a
## single weak reading (a head offset of 0.51 against the probe's 0.5 floor,
## their walk pose naming no axis). None reads +-X.
##
## INFERRED for the models that do not settle: the client turns every object
## by one heading with no per-model front (FUN_009ec850 turns the heading h
## into the facing (sin h, 0, -cos h) for any object, round 637), so the
## models are authored to one front, the one every clear reading names. The
## Jinn readings are OPEN (docs/TODO.md).
const MODEL_FRONT := "-Z"

## One frame of the engine's mover: the step is min(|speed x delta|, 160)
## along the line to dest (FUN_0048bff0), and a step longer than what is left
## lands exactly on dest -- CGObjMoverByDest::vslot_003 (0x48c4e0) computes
## dest - position (FUN_00430ad0, called at 0x48c5a9), compares the two
## lengths (fcompp at 0x48c622) and replaces the step with dest - position
## when the step is longer (0x48c62b..0x48c63c). So a body never overshoots.
static func step(pos: Vector2, dest: Vector2, speed: float, delta: float) -> Vector2:
	var s := minf(absf(speed * delta), MOVER_STEP_CAP)
	var left := pos.distance_to(dest)
	if s >= left:
		return dest
	return pos + (dest - pos) / left * s

## The state a new leg starts in. It starts from where the body is DRAWN, so a
## push never teleports it, unless that is more than RESYNC_DISTANCE from where
## the server had it -- then from (msg.x, msg.z). A stop (dest == (x, z)) is
## marked so the body is not turned toward a sub-unit correction; a leg with no
## speed has nothing to glide at and is placed at its end at once (the server
## sends a stop with the leg's speed, or the species' walk speed when it was
## not moving -- the protocol table -- so this is for a malformed message).
static func begin(displayed: Vector2, msg: CombatNet.MonsterMoved) -> Dictionary:
	var server := Vector2(msg.x, msg.z)
	var dest := Vector2(msg.dest_x, msg.dest_z)
	var pos := displayed
	if displayed.distance_to(server) > RESYNC_DISTANCE:
		pos = server
	var speed := absf(msg.speed)
	if speed <= 0.0:
		pos = dest
	return {"pos": pos, "dest": dest, "speed": speed, "mode": msg.mode,
		"moving": pos != dest, "stop": dest.is_equal_approx(server)}

## Where a listed monster's body is placed on a list refresh. A standing body
## goes where the list says (the server's word). A walking one keeps its drawn
## position -- the list is a snapshot of where the server had it, which a body
## drawn one latency behind never matches, and snapping to it teleported the
## body back on every refresh -- unless it has drifted more than
## RESYNC_DISTANCE from the list.
static func reconcile(displayed: Vector2, snapshot: Vector2, moving: bool) -> Vector2:
	if moving and displayed.distance_to(snapshot) <= RESYNC_DISTANCE:
		return displayed
	return snapshot

## The clip a leg plays, as a BsrReader action type: 1 walk (TYPE_WALK) for
## mode 0, 7 run (TYPE_RUN) for mode 1, 0 stand once it is not moving. The
## types are the `.bsr` animation group's (mangnyang: 0 stand01, 1 walk,
## 7 run -- docs/protocol/BSR_FORMAT.md). Mode 0/1 -> walk/run is an inference:
## AITactics_Handler_110 (0x5489b0) picks 0 or 1 and the 0x704f byte is
## (mode == 1) + 2 (0x54184d..0x541859); how the mover uses owner+0x155/+0x174
## is untraced.
static func gait_type(mode: int, moving: bool) -> int:
	if not moving:
		return BsrReader.AnimationEntry.TYPE_STAND
	return BsrReader.AnimationEntry.TYPE_RUN if mode == MODE_RUN else BsrReader.AnimationEntry.TYPE_WALK

## The clip a leg's state plays now: a stop glides in the stand clip.
static func state_gait(state: Dictionary) -> int:
	return gait_type(int(state["mode"]), bool(state["moving"]) and not bool(state["stop"]))

## Whether a leg turns the body toward its destination: a moving leg that is
## not a stop.
static func turns_to_face(state: Dictionary) -> bool:
	return bool(state["moving"]) and not bool(state["stop"])

## The front of a drawn model (MODEL_FRONT), or "" for no model -- the
## capsule a species with no model is drawn as, which has no front to turn.
static func front_of(model_path: String) -> String:
	return MODEL_FRONT if model_path != "" else ""

## The body's rotation.y that puts its front along `dir`, a WORLD-space ground
## vector (x, z) -- bodies are children of OtherEntities in world space
## (World3D._spawn_or_update_monster). The player's convention: a node's local
## +Z points along atan2(dir.x, dir.z) (World3D._physics_process), and the
## player's -Z-front skeleton is turned PI (_try_apply_real_player_character).
## A monster's skeleton is not turned, so its measured front's own yaw is
## taken off instead.
static func facing_yaw(dir: Vector2, front: String) -> float:
	return wrapf(atan2(dir.x, dir.y) - front_yaw(front), -PI, PI)

## The yaw of a measured front from the node's +Z: PI for -Z, +-PI/2 for +-X,
## 0 otherwise. A body's rotation.y is its heading less this (RemoteFacing.yaw_of).
static func front_yaw(front: String) -> float:
	match front:
		"-Z":
			return PI
		"+X":
			return PI / 2.0
		"-X":
			return -PI / 2.0
	return 0.0

## The ground direction (x, z) a server heading points along. OpenSRO's
## headings are radians in its world frame, measured from +x toward +z
## (server/internal/ai/wander.go): the unit heading the engine's SetHeading
## writes to an object's +0x24/+0x28/+0x2c is (cos a, 0, sin a) --
## GObjPC::FUN_00482440 (IGObj slot 230; the CGObjMobile override 0x0048ba10
## writes the same three), through FUN_00489490 -> 0x009fc0b0, the CRT's cos
## (its x87 path runs fcos at 0x9fc11d), and FUN_004894b0 -> 0x009fbf80, its
## sin (fsin at 0x9fbfed); re-read on the RE box in round 540. An
## OpMonsterSpawned carries one (World3D._on_monster_spawned); facing_yaw
## turns a body along it.
static func heading_dir(heading: float) -> Vector2:
	return Vector2(cos(heading), sin(heading))

## The clip for a gait: stand is the model's own idle (the assembler's
## `idle_animation`, which falls back to the name hints when the file has no
## groups -- animation_for(TYPE_STAND) returns nothing for those), walk and run
## come from its `default` group. null when the model has no such clip; the
## caller then keeps whatever loop it has.
static func gait_clip(archive: Pk2Reader, assembled: SkinnedBsrAssembler.AssembledCharacter, gait: int) -> BanReader.ParsedAnimation:
	if assembled == null:
		return null
	if gait == BsrReader.AnimationEntry.TYPE_STAND:
		return assembled.idle_animation
	if archive == null:
		return null
	return SkinnedBsrAssembler.animation_for(archive, assembled, gait)

## Replaces `skeleton`'s looping clip in World3D's `_animated` list (entries
## [skeleton, anim, frames, phase, loops, started, resume, (hold)]) with `anim`,
## in place, keeping its phase. While a one-shot plays (a hit), the loop it will
## resume -- its entry[6] -- is the one replaced, so the hit hands back to the
## new gait. A death hold (entry[7] true, set by World3D._play_once for a
## death) keeps its last frame: nothing is swapped. A one-shot that is NOT a
## hold but has nothing to resume -- a hit on a body whose idle was never
## registered (a clip of one frame, OPENSRO_NO_IDLE_ANIM) -- is given the new
## loop to resume (round 534; it used to be taken for a death and never got a
## walk clip). A skeleton with no entry gets one. Never a second loop: a swap
## that appended whenever it found no loop entry would, beside a one-shot,
## leave two entries fighting over one skeleton -- which is why World3D's
## other-player gait swap (_set_other_gait) goes through here too since round
## 540, when another player's body began playing a hit one-shot.
## Returns whether anything changed; a null clip changes nothing.
##
## `hint` (round 748, OURS): a one-element array holding the index the
## skeleton's entry was found at last time, read and updated. A hint that
## still names this skeleton's entry is used without a scan; any other is
## found by the scan as before. Other players' gait swaps scanned the whole
## list (every monster and player) once each: 1000 players walking spent
## about 13 ms a frame on it (MEASURED, round 748's crowd split).
static func swap_loop(animated: Array, skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, frames: int, now: float, hint: Array = [],
		fades = null, in_ms: float = ClipMixer.LOOP_IN_MS) -> bool:
	if skeleton == null or anim == null or frames <= 1:
		return false
	if not hint.is_empty():
		var h: int = hint[0]
		if h >= 0 and h < animated.size() and animated[h][0] == skeleton:
			return _swap_entry(animated, animated[h], skeleton, anim, frames, now, fades, in_ms)
	for i in animated.size():
		var entry: Array = animated[i]
		if entry[0] != skeleton:
			continue
		if not hint.is_empty():
			hint[0] = i
		return _swap_entry(animated, entry, skeleton, anim, frames, now, fades, in_ms)
	if not hint.is_empty():
		hint[0] = animated.size()
	animated.append(_new_loop(animated, skeleton, anim, frames, now))
	return true

## swap_loop on the skeleton's entry, found.
static func _swap_entry(animated: Array, entry: Array, skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, frames: int, now: float,
		fades = null, in_ms: float = ClipMixer.LOOP_IN_MS) -> bool:
	if entry[4]:
		# Round 808: with `fades` (World3D's), the change is the client's --
		# the new loop from its first frame (entry[3] puts its clock at 0 now;
		# entry[5], its sounds' play, is new), the old one fading out over
		# 200 ms while it fades in over `in_ms` (ClipMixer.Fade). Without, the
		# old swap: the clip replaced on the entry's own phase.
		if fades != null and entry[1] != anim:
			var f := ClipMixer.Fade.new()
			f.from = entry[1]
			var dur := float((entry[1] as BanReader.ParsedAnimation).duration_ms)
			f.from_ms = fposmod((now + float(entry[3])) * 1000.0, dur) if dur > 0.0 else 0.0
			f.from_loop = true
			f.at = now
			f.in_ms = in_ms
			(fades as Dictionary)[skeleton.get_instance_id()] = f
			entry[3] = -now
			entry[5] = now
		entry[1] = anim
		entry[2] = frames
		return true
	if entry.size() > 7 and bool(entry[7]):
		return false
	if entry[6] == null:
		entry[6] = _new_loop(animated, skeleton, anim, frames, now)
		return true
	entry[6][1] = anim
	entry[6][2] = frames
	return true

## A loop entry for swap_loop, with the staggered phase
## World3D._animate_skeleton and _set_other_gait give a new loop, so a crowd
## does not step in time.
static func _new_loop(animated: Array, skeleton: Skeleton3D, anim: BanReader.ParsedAnimation, frames: int, now: float) -> Array:
	return [skeleton, anim, frames, float(animated.size()) * 0.37, true, now, null]

## Whether a walking body has moved far enough since its last height ray to
## need another (HEIGHT_RESOLVE_STEP).
static func needs_height(last_xz: Vector2, pos: Vector2) -> bool:
	return last_xz.distance_to(pos) >= HEIGHT_RESOLVE_STEP

## How much of a frame's height budget the monsters' queue may take when
## `item_wants` ground items are waiting for ground too (round 572): the
## budget less the items' want, up to half of it. So two queues that both want
## more than half share it evenly, and either one takes what the other does
## not want -- the items take whatever the monsters leave
## (World3D._step_heights). Until round 572 the items had only what the
## monsters left, and from MAX_HEIGHT_RESOLVES_PER_FRAME monster bodies that
## can never resolve (listed outside every loaded region) they had nothing.
## The even split is OpenSRO's own design, not a tuned number.
static func monster_height_share(budget: int, item_wants: int) -> int:
	return budget - mini(maxi(item_wants, 0), budget / 2)

## Which bodies get a height ray this frame, taking turns (round 534).
## `wants[i]` says whether the i-th body of the frame's walk order needs one;
## at most `budget` are served (MAX_HEIGHT_RESOLVES_PER_FRAME), starting at
## `cursor` and wrapping round. {"picked": the served indices, in order,
## "cursor": where the next frame starts -- just after the last one served,
## so a body passed over this frame is served first the next}. Starting every
## frame at the first body instead gave the budget to the same bodies whenever
## more of them wanted a ray than it covers, and the rest never got theirs.
## A cursor past the end (bodies left the list) wraps.
static func height_turns(wants: Array, cursor: int, budget: int) -> Dictionary:
	var picked: Array[int] = []
	var n := wants.size()
	if n == 0:
		return {"picked": picked, "cursor": 0}
	var start := posmod(cursor, n)
	var next := start
	for k in range(n):
		if picked.size() >= budget:
			break
		var i := (start + k) % n
		if bool(wants[i]):
			picked.append(i)
			next = (i + 1) % n
	return {"picked": picked, "cursor": next}
