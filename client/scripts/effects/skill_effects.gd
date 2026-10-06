extends RefCounted
class_name SkillEffects

## A skill's visual effects (round 620): the .efp each skilleffectset row
## names, played through EfpEffect at the same moments SkillAudio plays the
## row's sounds, on the body the row names, at its StartBone.
##
## THE ROWS -- `#section skilleffectset` of Media.pk2's
## server_dep\silkroad\textdata\skilleffect.txt, the table SkillAudio reads
## (see its header for how a skill finds its rows: by Basic_Group, else
## Basic_Code, after one Basic_Original step -- this class reuses
## SkillAudio.effect_rows_in and SkillAudio's skill table unchanged). The
## columns are found by the file's own header line (MEASURED on the box:
## "ActType", "Obj Path", "ObjName", "StartBone", "StartOffset"), with the
## spec's 0-based 13, 17, 18, 19, 20 as the fallback. The effect is Obj Path +
## ObjName (READ, spec §1.1); "none" names no effect.
##
## WHEN A PHASE FIRES (round 620 review follow-up) -- the client's own phase
## machine, READ in IDecoSkill (funcs_015):
## - A cast starts (GlobalDataManager::FUN_00a53610) at phase 0 and runs
##   FUN_00a534d0, which plays the phase's clip, moves +0xbe to the next
##   phase and (FUN_00a53480) fires that phase's StartEvent 0 rows at once
##   (FUN_00a52fe0: the row list at +0xbc + AniType*4, next event counter).
## - Each animation event of the clip (FUN_00a59970, event type 1 on the
##   current clip) fires the phase's next StartEvent; the clip's end (event
##   100) runs FUN_00a534d0 again: READY -> WAIT -> SHOT.
## - A phase with no clip of its own advances at once (FUN_00a53480: the
##   skill record's per-phase clip count at +8 + phase). WAIT plays no clip
##   and holds only while the skill has WAIT clips, until the server's
##   skill-action message (FUN_00a56680 kind 1 -> FUN_00a53090) forces SHOT.
## - ACT_S / ACT_L fire when the skill acts on its object (FUN_00a53850,
##   from the server's result; round 614).
## This client has no per-phase clips or clip events, so SkillEffects.cast
## schedules the phases from the skilldata timing columns (INFERRED: the
## READY clip spans Action_PreparingTime, col 11; the WAIT charge spans
## Action_CastingTime, col 12):
##   t0            READY rows (every StartEvent: the clip events' times are
##                 unknown here, OURS)
##   t0 + prep     WAIT rows; then SHOT at once when the skill has no WAIT
##                 row, else at shot(caster) -- the server's answer -- or
##                 t0 + prep + cast, whichever comes first (OURS fallback)
##   SHOT start    SHOT/0 rows; the cast's READY/WAIT loops end here
##                 (INFERRED: a kept phase effect belongs to its phase)
##   hit(caster)   SHOT/1 and later -- the blow's animation event, which the
##                 caller knows (World3D: the blow lands)
##   act(...)      ACT_S (and ACT_L one cycle when no buff token will come)
## cancel_cast(caster) ends a cast that was refused or interrupted: nothing
## more fires and its loops end.
## The sequencer runs on scene time: World3D calls tick(delta) every physics
## frame (a movie render runs slower than the wall clock).
##
## ON WHOM (ActType, the row's +0xe byte, READ in IDecoSkill::FUN_00a51bc0:
## 0 AT_ONE_FOLLOW, 1 AT_LOOP, 2 AT_STOP are the vocabulary's first three):
## - AT_ONE_FOLLOW plays once and follows the body (READ: the decoration is
##   created with its keep flag 0 and handed to the one-shot list,
##   FUN_00a4ddc0).
## - AT_LOOP and AT_STOP are created with the keep flag 1 (READ), which sets
##   the effect's keep flag (+0x49, CEFEffect::vslot_004): its root
##   particles are revived at age 0 instead of dying (CEFEffect::vslot_000,
##   READ in round 623), so the children cycle on and the aura never blinks
##   out, until its owner ends it (EfpEffect.stop, which drops every particle
##   at once, READ). EfpEffect.loop is that flag.
## - AT_TARGET, AT_TARGET_F and AT_DMG_POS play on the target (INFERRED from
##   the names); everything else on the caster.
## - AT_MOV_* (projectiles) play at the caster without the flight (OURS; the
##   flight is OPEN).
##
## HOW LONG:
## - ACT_L / AT_LOOP is the buff's aura: attach_aura keeps it per (owner,
##   token) until detach_aura -- World3D drives these from NetClient's
##   buff_started / buff_ended (rounds 616-618). With the buff's remaining
##   time it also ends by itself AURA_GRACE_MS after that time runs out, in
##   case the end never arrives (OURS).
## - READY / WAIT AT_LOOP: until the cast's SHOT starts, cancel_cast, or
##   READY_LOOP_MAX (OURS guard).
##
## WHERE (StartBone, StartOffset): at the named bone of the body's current
## skeleton, turned with the body (OURS: the bone's own rotation is not
## applied); "none", "*" and "#..." (OPEN) and a missing bone put it at the
## skeleton's origin. StartOffset is added in the body's native units
## (INFERRED). The effect is a child of the body and re-finds its skeleton
## each frame (EfpEffect.follow_host), so a skeleton rebuilt by an equipment
## change keeps its auras, and an aura attached before the skeleton exists
## finds it when it comes.
##
## BUDGET (OURS): effects on or cast by `own_body` (the local player) are
## `reserved` and may use EfpSim's reserved particle share.
## PRELOAD: preload_skill decodes a skill's effect files on a worker thread
## (World3D: known skills at the skill-state answer, and a hotbar assignment),
## so the first cast does not decode on the main thread.

const SKILLEFFECT_PATH := "server_dep\\silkroad\\textdata\\skilleffect.txt"
const SECTION := "skilleffectset"
const READY_LOOP_MAX := 4.0 ## OURS: seconds a READY/WAIT loop may run unattended
const AURA_GRACE_MS := 2000 ## OURS: an aura outlives its buff's time by this much at most
const C_PREP := 11 ## skilldata Action_PreparingTime (ms)
const C_CAST := 12 ## skilldata Action_CastingTime (ms)

## ActType vocabulary (the client's own UTF-16 strings, spec §1.1).
const ACT_TYPES := ["AT_ONE_FOLLOW", "AT_LOOP", "AT_STOP", "AT_TARGET", "AT_TARGET_F",
	"AT_SOURCE", "AT_DMG_POS", "AT_MOV_1TAR", "AT_MOV_OPTION", "AT_MOV_APIECE",
	"AT_MOV_SPLASH", "AT_MOV_PIERCE"]
const AT_ONE_FOLLOW := 0
const AT_LOOP := 1
const AT_STOP := 2
const AT_TARGET := 3
const AT_TARGET_F := 4
const AT_DMG_POS := 6

# Fallback column indices (0-based, spec §1.1).
const C_ID := 1
const C_ANI := 2
const C_EVENT := 3
const C_ACT := 13
const C_PATH := 17
const C_NAME := 18
const C_BONE := 19
const C_OFFSET := 20

## The Effect Quality option (round 694, VideoOptions.EFFECT): 0 "Turn Off
## All Effects", 1 "See Hit Effects", 2 "See All Effects" (the default).
## READ: the client asks IDecoSkill::FUN_00a50dc0(quality, owner) before it
## starts a skill's effect -- 0 shows none, 2 all, and 1 only an effect whose
## owner passes two tests (FUN_00b94b70 against DAT_00ef1a84 / DAT_00ef1b44)
## that were not read. INFERRED: those name the player and the player's own
## fight, so at 1 an effect is shown when the player casts it, is hit by it,
## or carries it (wants_effect).
const EFFECTS_NONE := 0
const EFFECTS_HITS := 1
const EFFECTS_ALL := 2
static var quality := EFFECTS_ALL

## Whether the Effect Quality option lets an effect on `host`, cast by
## `caster` at `target`, be started.
static func wants_effect(caster: Node3D, target: Node3D, host: Node3D) -> bool:
	if quality >= EFFECTS_ALL:
		return true
	if quality <= EFFECTS_NONE:
		return false
	return own_body != null and (caster == own_body or target == own_body or host == own_body)

## SkillEffectID -> Array of Dictionary {ani, event, act, path, bone, offset}.
static var _rows: Dictionary = {}
static var _loaded := false
static var _particles: Pk2Reader = null
## (owner key|token) -> {fx: Array of EfpEffect, expires: ms or -1}: the live buff auras.
static var _auras: Dictionary = {}
## Test seam: Callable(path: String) -> EfpEffect (or null). Defaults to
## EfpEffect.create against the archive given to set_archive.
static var effect_factory: Callable = Callable()

# --- parsing (pure) ----------------------------------------------------------

## skilleffect.txt bytes -> SkillEffectID -> rows that name an effect.
static func parse_rows(bytes: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	var in_section := false
	var col := {"act": C_ACT, "path": C_PATH, "name": C_NAME, "bone": C_BONE, "offset": C_OFFSET}
	for raw in SkillAudio._utf16_lines(bytes):
		var line: String = raw
		if line.begins_with("#section"):
			var parts := line.replace("\t", " ").split(" ", false)
			in_section = parts.size() >= 2 and parts[1] == SECTION
			continue
		if not in_section:
			continue
		if line.begins_with("//"):
			var header := line.substr(2).split("\t")
			var names := {"ActType": "act", "Obj Path": "path", "ObjName": "name",
				"StartBone": "bone", "StartOffset": "offset"}
			for h in names:
				var at := header.find(h)
				if at >= 0:
					col[names[h]] = at
			continue
		var cols := line.split("\t")
		if cols.size() <= int(col["name"]):
			continue
		var id := cols[C_ID].strip_edges()
		var ani_name := cols[C_ANI].strip_edges()
		if id == "" or not SkillAudio.ANI_TYPES.has(ani_name):
			continue
		var obj := cols[int(col["name"])].strip_edges()
		if obj == "" or obj.to_lower() == "none" or not obj.to_lower().ends_with(".efp"):
			continue
		var dir := cols[int(col["path"])].strip_edges()
		if dir.to_lower() == "none":
			dir = ""
		var ev_text := cols[C_EVENT].strip_edges()
		var act_name := cols[int(col["act"])].strip_edges()
		var row := {
			"ani": int(SkillAudio.ANI_TYPES[ani_name]),
			"event": int(ev_text) if ev_text.is_valid_int() else 0,
			"act": ACT_TYPES.find(act_name),
			"path": dir + obj,
			"bone": cols[int(col["bone"])].strip_edges() if cols.size() > int(col["bone"]) else "none",
			"offset": parse_offset(cols[int(col["offset"])] if cols.size() > int(col["offset"]) else ""),
		}
		if not out.has(id):
			out[id] = []
		(out[id] as Array).append(row)
	return out

## "x,y,z" -> Vector3 (zero for anything else).
static func parse_offset(cell: String) -> Vector3:
	var p := cell.strip_edges().split(",")
	if p.size() != 3:
		return Vector3.ZERO
	for s in p:
		if not String(s).strip_edges().is_valid_float():
			return Vector3.ZERO
	return Vector3(float(p[0]), float(p[1]), float(p[2]))

## The rows of `skill_id` for one phase (start_event -1 = any), against
## given tables.
static func rows_in(skills: Dictionary, rows: Dictionary, skill_id: int, ani_type: int,
		start_event: int = -1) -> Array:
	var out: Array = []
	for r in SkillAudio.effect_rows_in(skills, rows, skill_id):
		if int(r["ani"]) == ani_type and (start_event < 0 or int(r["event"]) == start_event):
			out.append(r)
	return out

## Whom a row plays on (see the header).
static func host_for(act: int, caster: Node3D, target: Node3D) -> Node3D:
	if act == AT_TARGET or act == AT_TARGET_F or act == AT_DMG_POS:
		return target if _valid(target) else caster
	return caster if _valid(caster) else target

# --- the loaded tables ---------------------------------------------------------

## skill id -> [prep_ms, cast_ms] (skilldata cols 11, 12).
static var _timings: Dictionary = {}
## The local player's body: effects on it or cast by it are reserved.
static var own_body: Node3D = null
## caster instance id -> the running cast {skill, caster, target, t0, prep,
## cast, phase, shot_at, loops}.
static var _casts: Dictionary = {}

## skilldata bytes -> id -> [prep_ms, cast_ms].
static func parse_timings(bytes: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	for line in SkillAudio._utf16_lines(bytes):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t", true, C_CAST + 1)
		if cols.size() <= C_CAST or not cols[SkillAudio.S_ID].strip_edges().is_valid_int():
			continue
		var prep := cols[C_PREP].strip_edges()
		var cast := cols[C_CAST].strip_edges()
		into[int(cols[SkillAudio.S_ID].strip_edges())] = [int(prep) if prep.is_valid_int() else 0,
			int(cast) if cast.is_valid_int() else 0]
	return into

## The archive effects load from; tables load from Media.pk2 on first use.
static func set_archive(particles: Pk2Reader) -> void:
	_particles = particles

static func warm() -> void:
	if _warm_task >= 0:
		# Started by warm_async: wait for it, and for SkillAudio's tables,
		# which the rows join through.
		WorkerThreadPool.wait_for_task_completion(_warm_task)
		_warm_task = -1
		SkillAudio.warm()
	if _loaded:
		return
	SkillAudio.warm()
	_warm_now()

## Round 746: warm() on a worker (every skilldata part the index names, as
## SkillAudio.warm_async); warm() waits for it. SkillAudio's own tables are
## warmed by its own task (World3D starts both).
static func warm_async() -> void:
	if _loaded or _warm_task >= 0:
		return
	_warm_task = WorkerThreadPool.add_task(func() -> void:
		SkillEffects._warm_now(), false, "skill effect tables")

static var _warm_task := -1

## Waits for a warm_async under way (a world leaving the tree; round 746's
## review, finding 9).
static func wait_pending() -> void:
	if _warm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_warm_task)
		_warm_task = -1

static func _warm_now() -> void:
	if _loaded:
		return
	_loaded = true
	var t0 := Time.get_ticks_msec()
	_rows = parse_rows(AudioBank.read_table("media", SKILLEFFECT_PATH))
	# Both races' skill files (round 691): a Europe cast keys its sound and
	# effect rows by its id like a China one, so its rows must be read too.
	# Every part the archive's skilldata.txt names (round 746).
	for path in SkillDataReader.all_tables(AudioBank._archive("media")):
		parse_timings(AudioBank.read_table("media", path), _timings)
	var n := 0
	for k in _rows:
		n += (_rows[k] as Array).size()
	print("EFFECTS skills: %d effect rows under %d effect ids, %d skill timings (%d ms)" % [n,
		_rows.size(), _timings.size(), Time.get_ticks_msec() - t0])

## Test seam: these rows (and timings) instead of the archive's
## (SkillAudio.set_tables sets the skill table).
static func set_rows(rows: Dictionary, timings: Dictionary = {}) -> void:
	_rows = rows
	_timings = timings
	_loaded = true

static func rows_for(skill_id: int, ani_type: int, start_event: int = -1) -> Array:
	warm()
	return rows_in(SkillAudio._skills, _rows, skill_id, ani_type, start_event)

## Every .efp path a skill's rows name.
static func paths_for(skill_id: int) -> PackedStringArray:
	warm()
	var out := PackedStringArray()
	for r in SkillAudio.effect_rows_in(SkillAudio._skills, _rows, skill_id):
		if not out.has(String(r["path"])):
			out.append(String(r["path"]))
	return out

## Decodes a skill's effect files off the main thread (see the header).
static func preload_skill(skill_id: int) -> int:
	return EfpEffect.preload_paths(paths_for(skill_id), _particles)

static func preload_skills(ids: Array) -> void:
	var all := PackedStringArray()
	for id in ids:
		for p in paths_for(int(id)):
			if not all.has(p):
				all.append(p)
	EfpEffect.preload_paths(all, _particles)

# --- playing -------------------------------------------------------------------

static func _valid(n) -> bool:
	return n != null and is_instance_valid(n) and n is Node3D and not (n as Node).is_queued_for_deletion()

static func _make(path: String) -> EfpEffect:
	if effect_factory.is_valid():
		return effect_factory.call(path)
	return EfpEffect.create(path, _particles)

## The first Skeleton3D under a body that is not on its way out, or null.
static func skeleton_of(host: Node) -> Skeleton3D:
	if host == null or not is_instance_valid(host):
		return null
	if host is Skeleton3D and not host.is_queued_for_deletion():
		return host
	for n in host.find_children("*", "Skeleton3D", true, false):
		if is_instance_valid(n) and not (n as Node).is_queued_for_deletion():
			return n as Skeleton3D
	return null

## Puts `fx` on `host` at `bone` + `offset` (see the header): a child of the
## body, placed each frame in its current skeleton's frame.
static func attach(fx: EfpEffect, host: Node3D, bone: String, offset: Vector3) -> void:
	host.add_child(fx)
	fx.follow_host(host, bone, offset)

## Plays `skill_id`'s effects of one phase now. Returns the effects started.
## (Round 620's play_phase stopped the caster's READY loops on any later
## phase; the cast sequencer does that at SHOT's start instead.)
static func play_phase(skill_id: int, ani_type: int, start_event: int, caster: Node3D,
		target: Node3D = null, what: String = "") -> Array:
	var started: Array = []
	for r in rows_for(skill_id, ani_type, start_event):
		var act := int(r["act"])
		var host := host_for(act, caster, target)
		if not _valid(host):
			continue
		if not wants_effect(caster, target, host):
			continue
		var fx := _make(String(r["path"]))
		if fx == null:
			print("EFFECTS skill %d %s/%d: %s did not load (%s)" % [skill_id,
				SkillAudio._phase_name(ani_type), start_event, r["path"], EfpEffect.last_error])
			continue
		if fx.draw_count() == 0 and fx.sim != null and fx.sim.template != null \
				and _draws_nothing(fx):
			print("EFFECTS skill %d %s/%d: %s draws nothing (skipped: %s)" % [skill_id,
				SkillAudio._phase_name(ani_type), start_event, r["path"], ", ".join(fx.skipped)])
			fx.free()
			continue
		fx.reserved = own_body != null and (host == own_body or caster == own_body)
		var looping := act == AT_LOOP or act == AT_STOP
		if looping and (ani_type == SkillAudio.READY or ani_type == SkillAudio.WAIT):
			fx.loop = true
			fx.max_life = READY_LOOP_MAX
			if caster != null and _casts.has(caster.get_instance_id()):
				(_casts[caster.get_instance_id()]["loops"] as Array).append(fx)
		attach(fx, host, String(r["bone"]), r["offset"])
		started.append(fx)
		print("EFFECTS skill %d %s/%d: %s %s at %s (%d nodes drawn%s) %s" % [skill_id,
			SkillAudio._phase_name(ani_type), start_event, ACT_TYPES[act] if act >= 0 else "?",
			r["path"], r["bone"], fx.draw_count(),
			", skipped: " + ", ".join(fx.skipped) if not fx.skipped.is_empty() else "", what])
	return started

## An effect with no drawn node is still worth running only if a child file
## could draw -- never, here: every node is either drawn or skipped.
static func _draws_nothing(fx: EfpEffect) -> bool:
	return fx.draw_count() == 0

# --- the cast sequencer ----------------------------------------------------------

## The sequencer's clock: scene time, the same time the effects simulate in
## (a movie render runs slower than the wall clock; so may a hitch).
static var _clock_ms := 0.0

static func _now() -> int:
	return int(_clock_ms)

## Advances the clock by a frame's `delta` seconds and runs `process`.
## World3D calls it every physics frame.
static func tick(delta: float) -> void:
	_clock_ms += maxf(delta, 0.0) * 1000.0
	process()

## Starts a cast's effect phases (see the header). `timings` may carry
## "prep_ms" and "cast_ms" (default: the skilldata columns) and "now_ms" (the
## clock, for tests). A cast already running on the caster is cancelled.
## Returns the READY effects started.
static func cast(skill_id: int, caster: Node3D, target: Node3D = null, timings: Dictionary = {}) -> Array:
	if caster == null:
		return []
	warm()
	cancel_cast(caster)
	var t: Array = _timings.get(skill_id, [0, 0])
	var now := int(timings.get("now_ms", _now()))
	var c := {"skill": skill_id, "caster": caster, "target": target, "t0": now,
		"prep": maxi(int(timings.get("prep_ms", t[0])), 0),
		"cast": maxi(int(timings.get("cast_ms", t[1])), 0),
		"phase": SkillAudio.READY, "shot_at": -1, "loops": []}
	_casts[caster.get_instance_id()] = c
	var fx := play_phase(skill_id, SkillAudio.READY, -1, caster, target, "cast")
	process(now)
	return fx

## The server answered: a cast held in WAIT goes to SHOT now.
static func shot(caster: Node3D, now_ms: int = -1) -> void:
	if caster == null or not _casts.has(caster.get_instance_id()):
		return
	var c: Dictionary = _casts[caster.get_instance_id()]
	c["shot_at"] = now_ms if now_ms >= 0 else _now()
	process(int(c["shot_at"]))

## The blow's hit event: SHOT/1 and later rows, now (SHOT starts first if it
## has not). Without a running cast, `skill_id` names the skill.
static func hit(caster: Node3D, target: Node3D = null, skill_id: int = 0, now_ms: int = -1) -> Array:
	if caster != null and _casts.has(caster.get_instance_id()):
		var c: Dictionary = _casts[caster.get_instance_id()]
		if int(c["phase"]) < SkillAudio.SHOT:
			_start_shot(c)
		skill_id = int(c["skill"])
		if target == null:
			target = c["target"]
	if skill_id == 0:
		return []
	var out: Array = []
	for ev in _events_from(skill_id, SkillAudio.SHOT, 1):
		out.append_array(play_phase(skill_id, SkillAudio.SHOT, ev, caster, target, "hit"))
	return out

## The skill acts on `target` (for a buff: it is applied): ACT_S now, and
## ACT_L one cycle when `with_aura` (no buff token will hold it).
static func act(skill_id: int, caster: Node3D, target: Node3D, with_aura: bool = false) -> Array:
	var out := play_phase(skill_id, SkillAudio.ACT_S, -1, caster, target, "act")
	if with_aura:
		out.append_array(play_phase(skill_id, SkillAudio.ACT_L, -1, caster, target, "act"))
	return out

## Ends the caster's running cast: nothing more fires; its loops end.
static func cancel_cast(caster: Node3D) -> void:
	if caster == null:
		return
	var key := caster.get_instance_id()
	if not _casts.has(key):
		return
	_stop_all(_casts[key]["loops"])
	_casts.erase(key)

## The phase the caster's cast is in (-1: none). Tests and logs.
static func cast_phase(caster: Node3D) -> int:
	if caster == null or not _casts.has(caster.get_instance_id()):
		return -1
	return int(_casts[caster.get_instance_id()]["phase"])

static func _events_from(skill_id: int, ani: int, first: int) -> Array:
	var evs: Array = []
	for r in rows_for(skill_id, ani, -1):
		var ev := int(r["event"])
		if ev >= first and not evs.has(ev):
			evs.append(ev)
	evs.sort()
	return evs

static func _start_shot(c: Dictionary) -> void:
	_stop_all(c["loops"])
	c["loops"] = []
	c["phase"] = SkillAudio.SHOT
	var caster = c["caster"]
	if _valid(caster):
		play_phase(int(c["skill"]), SkillAudio.SHOT, 0, caster, c["target"] if _valid(c["target"]) else null, "shot")

static func _stop_all(fxs: Array) -> void:
	for fx in fxs:
		if is_instance_valid(fx):
			(fx as EfpEffect).stop()

## Runs the due phases of every cast, ends expired auras, and forgets freed
## bodies. World3D calls it every frame.
static func process(now_ms: int = -1) -> void:
	var now := now_ms if now_ms >= 0 else _now()
	for key in _casts.keys():
		var c: Dictionary = _casts[key]
		if not _valid(c["caster"]):
			_stop_all(c["loops"])
			_casts.erase(key)
			continue
		var skill := int(c["skill"])
		var t_wait := int(c["t0"]) + int(c["prep"])
		if int(c["phase"]) == SkillAudio.READY and now >= t_wait:
			c["phase"] = SkillAudio.WAIT
			var started := play_phase(skill, SkillAudio.WAIT, -1, c["caster"], c["target"] if _valid(c["target"]) else null, "wait")
			if rows_for(skill, SkillAudio.WAIT).is_empty():
				_start_shot(c)
			else:
				var _unused := started
		if int(c["phase"]) == SkillAudio.WAIT:
			var due := t_wait + int(c["cast"])
			if (int(c["shot_at"]) >= 0 and now >= int(c["shot_at"])) or now >= due:
				_start_shot(c)
		if int(c["phase"]) >= SkillAudio.SHOT:
			# The cast's own phases are done; hit/act come from the caller.
			_casts.erase(key)
	for key in _auras.keys():
		var a: Dictionary = _auras[key]
		var alive: Array = []
		for fx in a["fx"]:
			if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion():
				alive.append(fx)
		if alive.is_empty():
			_auras.erase(key)
		elif int(a["expires"]) >= 0 and now >= int(a["expires"]):
			print("EFFECTS aura %s: no end arrived %d ms after its time -- ending it" % [key, AURA_GRACE_MS])
			_stop_all(alive)
			_auras.erase(key)
		else:
			a["fx"] = alive

static func _aura_key(owner_key: String, token: int) -> String:
	return "%s|%d" % [owner_key, token]

## Starts `skill_id`'s ACT_L AT_LOOP effects on `host` as the aura of buff
## `token`, kept until detach_aura -- or, given the buff's `remaining_ms`
## (> 0), until AURA_GRACE_MS past it (OURS). A second start for the same
## token replaces the first. Returns the effects started.
static func attach_aura(owner_key: String, token: int, skill_id: int, host: Node3D,
		remaining_ms: int = -1, now_ms: int = -1) -> Array:
	detach_aura(owner_key, token)
	var started: Array = []
	if not _valid(host) or not wants_effect(null, null, host):
		return started
	for r in rows_for(skill_id, SkillAudio.ACT_L, -1):
		var fx := _make(String(r["path"]))
		if fx == null:
			continue
		if fx.draw_count() == 0 and _draws_nothing(fx):
			fx.free()
			continue
		fx.loop = int(r["act"]) == AT_LOOP or int(r["act"]) == AT_STOP
		fx.reserved = own_body != null and host == own_body
		attach(fx, host, String(r["bone"]), r["offset"])
		started.append(fx)
	if not started.is_empty():
		var now := now_ms if now_ms >= 0 else _now()
		_auras[_aura_key(owner_key, token)] = {"fx": started, "host": host, "skill": skill_id,
			"expires": now + remaining_ms + AURA_GRACE_MS if remaining_ms > 0 else -1}
		print("EFFECTS aura on %s token %d: skill %d, %d effect(s)" % [owner_key, token, skill_id, started.size()])
	return started

## Whether buff `token`'s aura is live on `host`: held, of `skill_id`, with at
## least one of its effects still drawing under that body (round 646).
static func has_aura_on(owner_key: String, token: int, skill_id: int, host: Node3D) -> bool:
	var a: Dictionary = _auras.get(_aura_key(owner_key, token), {})
	if a.is_empty() or not _valid(host) or a.get("host") != host or int(a.get("skill", -1)) != skill_id:
		return false
	for fx in a["fx"]:
		if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion() and host.is_ancestor_of(fx):
			return true
	return false

## attach_aura, unless the same buff's aura already draws on this body
## (round 646): a re-sent start (a zone change's replay, a body's re-attach
## from BuffRoster) keeps the running effects -- the retail client's spawned
## buff skips its start effect too (FUN_00a53850 with arg4 1, READ) -- and
## only moves its time bound. Returns the effects started (none when kept).
static func ensure_aura(owner_key: String, token: int, skill_id: int, host: Node3D,
		remaining_ms: int = -1, now_ms: int = -1) -> Array:
	if has_aura_on(owner_key, token, skill_id, host):
		var now := now_ms if now_ms >= 0 else _now()
		_auras[_aura_key(owner_key, token)]["expires"] = now + remaining_ms + AURA_GRACE_MS if remaining_ms > 0 else -1
		return []
	return attach_aura(owner_key, token, skill_id, host, remaining_ms, now_ms)

## Ends the aura of buff `token` at once. Returns how many effects it stopped.
static func detach_aura(owner_key: String, token: int) -> int:
	var key := _aura_key(owner_key, token)
	var n := 0
	if _auras.has(key):
		for fx in _auras[key]["fx"]:
			if is_instance_valid(fx):
				(fx as EfpEffect).stop()
				n += 1
	_auras.erase(key)
	return n

## Ends every aura of an owner (it left view, or the world unloads).
static func detach_owner(owner_key: String) -> int:
	var n := 0
	for key in _auras.keys():
		if String(key).begins_with(owner_key + "|"):
			n += detach_aura(owner_key, int(String(key).get_slice("|", 1)))
	return n

## How many auras are held (tests, logs).
static func aura_count() -> int:
	return _auras.size()

## How many casts and phase loops are tracked (tests: pruning).
static func tracked_count() -> int:
	return _casts.size() + _auras.size()

## Ends every live effect this class tracks and forgets every body (a world
## teardown or relog); the tables stay loaded.
static func clear_live() -> void:
	for key in _auras.keys():
		_stop_all(_auras[key]["fx"])
	_auras.clear()
	for key in _casts.keys():
		_stop_all(_casts[key]["loops"])
	_casts.clear()
	own_body = null

## Clears every table and live reference (tests, a world reload).
static func reset() -> void:
	if _warm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_warm_task)
		_warm_task = -1
	clear_live()
	_rows = {}
	_timings = {}
	_loaded = false
	effect_factory = Callable()
