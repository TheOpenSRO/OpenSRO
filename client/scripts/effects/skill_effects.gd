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
## WHEN A PHASE FIRES (round 785): SkillDeco runs the cast's phases from the
## body's own clips, as the client's decoration does (its header has the
## READ), and fires each phase's effect groups -- StartEvent 0 when the phase
## starts, StartEvent n at the clip's n-th hit event -- through play_phase.
## ACT_S / ACT_L fire when the skill acts on its object (act, FUN_00a53850,
## from the server's result; round 614).
##
## ON WHOM (ActType, the row's +0xe byte). Its values are READ (round 785)
## from the name table the row parser looks the column up in: the (name,
## value) pairs at 0x00ec7280 -- AT_STOP 0, AT_ONE_FOLLOW 1, AT_LOOP 2,
## AT_TARGET 3, AT_TARGET_F 4, AT_SOURCE 5, AT_DMG_POS 6, AT_MOV_1TAR 7 ...
## AT_MOV_PIERCE 11 -- made a map by FUN_00a9ac70 (the static initialiser at
## 0x00d785a0) and read by GlobalEffectManager::FUN_00a9d0f0 at 0x00a9d679.
## Rounds 620-784 had 0 AT_ONE_FOLLOW, 1 AT_LOOP, 2 AT_STOP (the strings'
## order in memory), so AT_STOP was played as AT_LOOP. What each does is
## READ in IDecoSkill::FUN_00a513a0 (the phase's rows played) and
## CIDecoSkill::vslot_014 (the decoration's frame):
## - AT_LOOP (2): created with the keep flag 1 (slot 4 with 1 for +0xe == 2
##   alone), which sets the effect's keep flag (+0x49, CEFEffect::vslot_004):
##   its root particles are revived at age 0 instead of dying
##   (CEFEffect::vslot_000, READ in round 623), so the children cycle on and
##   the aura never blinks out, until its owner ends it (EfpEffect.stop,
##   which drops every particle at once, READ). EfpEffect.loop is that flag.
##   Placed on the body every frame (the entry's follow flag 1: vslot_014
##   calls FUN_00a4ddc0 for it each frame).
## - AT_ONE_FOLLOW (1): plays once (keep flag 0) and is placed on the body
##   every frame, as AT_LOOP.
## - AT_STOP (0): plays once and is placed ONCE, when it is made (its entry's
##   follow flag is 0 and FUN_00a513a0 places it then): it stays where it was
##   cast (EfpEffect.static_host). 35 effect rows (MEASURED): monster dust and
##   stuns, and the fireworks.
## - AT_TARGET, AT_TARGET_F and AT_DMG_POS play on the target (INFERRED from
##   the names); everything else on the caster, placed every frame (OURS for
##   the ActTypes past AT_LOOP: FUN_00a513a0 plays them on other paths).
## - AT_MOV_* (projectiles, round 785): the effect leaves the caster at its
##   StartBone + StartOffset and flies to the target's TargetBone +
##   TargetOffset; the hit it carries lands when it arrives (`on_arrive`).
##   MovTypeSpeed `MOV_x,a,b,c` (MEASURED: b and c are 100..800 on every
##   row) is read as the start and end speed in units a second, the flight
##   at their mean, in a straight line for every MOV_ kind (INFERRED; the
##   mover was not read, OPEN: MOV_UPR's arc, MOV_ROUND, MOV_PIERCE).
##
## HOW LONG:
## - ACT_L / AT_LOOP is the buff's aura: attach_aura keeps it per (owner,
##   token) until detach_aura -- World3D drives these from NetClient's
##   buff_started / buff_ended (rounds 616-618). Round 785 (READ): the end lets
##   the aura go as retail's decoration does (EfpEffect.release: the keep flag
##   cleared, its last cycle plays out; FUN_00a53120 -> FUN_00a4ffe0 ->
##   FUN_00a4db00), and so does a cast's end or cancel; a world teardown
##   frees them at once (EfpEffect.stop). With the buff's remaining
##   time it also ends by itself AURA_GRACE_MS after that time runs out, in
##   case the end never arrives (OURS).
## - A cast's AT_LOOP rows of ANY phase (READY, WAIT, SHOT -- 260 SHOT and 12
##   ACT_S rows, the effects lane's MEASURED count): kept until the cast's
##   phases are done (READ: FUN_00a534d0 past phase 2 ends the decoration;
##   SkillDeco "stop_loops" at its end) or it is cancelled, then let go; a
##   kept row played outside a decoration is bounded by READY_LOOP_MAX (OURS).
##   The release when a later row's group matches (FUN_00a4fe10) is not
##   modelled (OPEN).
##
## WHERE (StartBone, StartOffset, Rotate; READ round 785 -- the row parser
## GlobalEffectManager::FUN_00a9d0f0, the placement IDecoSkill::FUN_00a4a680
## and FUN_00a4ddc0): at the named bone of the body's current skeleton,
## turned with the BONE (a plain name gets the placement flags 2, which keep
## the bone's rotation; rounds 620-784 turned it with the body); '@name' at
## the bone along the world's axes (flags 0); "none" at the body, turned with
## it. StartOffset is turned by the body (not the bone) and added to the
## bone's position (the post-pass at 0x00a95310 points the row at it when it
## is not zero). Rotate turns the effect in its own frame after the
## placement: 1-360 about Y by that many degrees (FUN_0043cda0), 361-720
## about X by value - 360 (FUN_009ecc10), above 720 about Z by value - 720
## (FUN_00a4d820) -- 284 effect rows (MEASURED). "*" (flags 3: the body's
## turn and a height) and "#..." (flags 6: another object's bone) and a
## missing bone put it at the skeleton's origin, turned with the body (OPEN). The effect is a child of the body and re-finds its skeleton
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

## ActType vocabulary (the client's own UTF-16 strings, spec §1.1), each at
## its value: READ, round 785, the name table at 0x00ec7280 (see the header).
static var ACT_TYPES := ["AT_STOP", "AT_ONE_FOLLOW", "AT_LOOP", "AT_TARGET", "AT_TARGET_F",
	"AT_SOURCE", "AT_DMG_POS", "AT_MOV_1TAR", "AT_MOV_OPTION", "AT_MOV_APIECE",
	"AT_MOV_SPLASH", "AT_MOV_PIERCE"]
const AT_STOP := 0
const AT_ONE_FOLLOW := 1
const AT_LOOP := 2
const AT_TARGET := 3
const AT_TARGET_F := 4
const AT_DMG_POS := 6
const AT_MOV_1TAR := 7

# Fallback column indices (0-based, spec §1.1).
const C_ID := 1
const C_ANI := 2
const C_EVENT := 3
const C_ACT := 13
const C_PATH := 17
const C_NAME := 18
const C_BONE := 19
const C_OFFSET := 20
const C_ROTATE := 24 ## round 785: "Rotate" (the header's own name is looked for first)
const C_DMG := 4
const C_MOV := 14
const C_TBONE := 21
const C_TOFFSET := 22

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
	var col := {"act": C_ACT, "path": C_PATH, "name": C_NAME, "bone": C_BONE, "offset": C_OFFSET,
		"dmg": C_DMG, "mov": C_MOV, "tbone": C_TBONE, "toffset": C_TOFFSET, "rotate": C_ROTATE}
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
				"StartBone": "bone", "StartOffset": "offset", "DMG Event": "dmg",
				"MovTypeSpeed": "mov", "TargetBone": "tbone", "TargetOffset": "toffset", "Rotate": "rotate"}
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
			"dmg": _cell(cols, int(col["dmg"])).to_upper() == "TRUE",
			"mov": parse_mov(_cell(cols, int(col["mov"]))),
			"tbone": _cell(cols, int(col["tbone"])),
			"toffset": parse_offset(_cell(cols, int(col["toffset"]))),
			"rotate": int(_cell(cols, int(col["rotate"]))) if _cell(cols, int(col["rotate"])).is_valid_int() else 0,
		}
		if not out.has(id):
			out[id] = []
		(out[id] as Array).append(row)
	return out

static func _cell(cols: PackedStringArray, i: int) -> String:
	return cols[i].strip_edges() if i >= 0 and i < cols.size() else ""

## MovTypeSpeed `MOV_x,a,b,c` -> [kind, a, b, c] ([] for MOV_NONE or
## anything else).
static func parse_mov(cell: String) -> Array:
	var p := cell.strip_edges().split(",")
	if p.size() != 4 or not p[0].begins_with("MOV_") or p[0] == "MOV_NONE":
		return []
	for k in range(1, 4):
		if not String(p[k]).strip_edges().is_valid_int():
			return []
	return [p[0], int(p[1]), int(p[2]), int(p[3])]

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

## Whether a row's effect is kept (retail's keep flag: AT_LOOP alone, READ,
## see the header).
static func kept_act(act: int) -> bool:
	return act == AT_LOOP

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
		PoolWait.task(_warm_task)
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
		PoolWait.task(_warm_task)
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

## Puts `fx` on `host` at `bone` + `offset`, turned by the row's `rotate`
## (see the header): a child of the body, placed each frame in its current
## skeleton's frame.
static func attach(fx: EfpEffect, host: Node3D, bone: String, offset: Vector3, rotate: int = 0) -> void:
	host.add_child(fx)
	var b := bone.strip_edges()
	var named := b != "" and b.to_lower() != "none" and b != "*" and not b.begins_with("#")
	fx.follow_bone_turn = named and not b.begins_with("@")
	fx.follow_world_turn = named and b.begins_with("@")
	fx.follow_basis = rotate_basis(rotate)
	fx.follow_host(host, bone, offset)

## The row's Rotate as the turn it gives the effect (READ, see the header):
## the client's row-vector matrices read as bases whose columns are their
## rows (EfpSim.basis_of), so a D3D `v * M` is `basis * v` here.
static func rotate_basis(rotate: int) -> Basis:
	if rotate == 0:
		return Basis.IDENTITY
	var axis := 0
	var deg := rotate
	if rotate > 720:
		axis = 2
		deg = rotate - 720
	elif rotate > 360:
		axis = 1
		deg = rotate - 360
	var a := float(deg) / 360.0 * TAU
	var c := cos(a)
	var sn := sin(a)
	match axis:
		1: # FUN_009ecc10: rows (1,0,0) (0,c,s) (0,-s,c)
			return Basis(Vector3(1, 0, 0), Vector3(0, c, sn), Vector3(0, -sn, c))
		2: # FUN_00a4d820: rows (c,s,0) (-s,c,0) (0,0,1)
			return Basis(Vector3(c, sn, 0), Vector3(-sn, c, 0), Vector3(0, 0, 1))
	# FUN_0043cda0: rows (c,0,s) (0,1,0) (-s,0,c)
	return Basis(Vector3(c, 0, sn), Vector3(0, 1, 0), Vector3(-sn, 0, c))

## Plays `skill_id`'s effects of one phase now. Returns the effects started.
## READY / WAIT AT_LOOP rows loop (EfpEffect.loop) until the caller stops
## them -- SkillDeco's "stop_loops" at SHOT -- or READY_LOOP_MAX (OURS
## guard). An AT_MOV_* row flies to `target` (see the header) and, when the
## row carries the DMG event, calls `on_arrive` once it lands (the first such
## row of the group only).
static func play_phase(skill_id: int, ani_type: int, start_event: int, caster: Node3D,
		target: Node3D = null, what: String = "", on_arrive: Callable = Callable()) -> Array:
	var started: Array = []
	var arrive := on_arrive
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
		# Round 785: AT_LOOP of any phase is kept (the caller lets it go --
		# SkillDeco's end); AT_STOP is placed once, where it is cast (READ).
		fx.static_host = act == AT_STOP
		if kept_act(act):
			fx.loop = true
			fx.max_life = READY_LOOP_MAX
		var flies := act >= AT_MOV_1TAR and _valid(target) and target != caster and _valid(caster)
		if flies:
			var carries: Callable = arrive if bool(r.get("dmg", false)) else Callable()
			if carries.is_valid():
				arrive = Callable()
			_fly(fx, caster, target, r, carries)
		else:
			attach(fx, host, String(r["bone"]), r["offset"], int(r.get("rotate", 0)))
		started.append(fx)
		print("EFFECTS skill %d %s/%d: %s %s at %s (%d nodes drawn%s) %s%s" % [skill_id,
			SkillAudio._phase_name(ani_type), start_event, ACT_TYPES[act] if act >= 0 else "?",
			r["path"], r["bone"], fx.draw_count(),
			", skipped: " + ", ".join(fx.skipped) if not fx.skipped.is_empty() else "", what,
			" -- flies to the target" if flies else ""])
	return started

## Whether effect group `start_event` of a phase carries the DMG event (a
## row with DMG Event TRUE): the group that shows the cast's next hit (READ,
## FUN_00a52fe0: a group whose flag is set takes the next hit entry,
## IDecoSkill::FUN_00a4efc0, the counter +0xba). Rows are filed by
## StartEvent (GlobalEffectManager::FUN_00a9d0f0), so a group's flag is set
## by any of its rows (INFERRED from the shape: the per-row flag is read,
## the per-group byte is what the fire tests).
static func group_dmg(skill_id: int, ani_type: int, start_event: int) -> bool:
	for r in rows_for(skill_id, ani_type, start_event):
		if bool(r.get("dmg", false)):
			return true
	return false

## Whether the group's DMG row is a projectile (its hit lands on arrival).
static func group_dmg_flies(skill_id: int, ani_type: int, start_event: int) -> bool:
	for r in rows_for(skill_id, ani_type, start_event):
		if bool(r.get("dmg", false)) and int(r["act"]) >= AT_MOV_1TAR:
			return true
	return false

## The highest StartEvent among a phase's rows (0 when none): how many
## groups the phase can fire.
static func last_event(skill_id: int, ani_type: int) -> int:
	var n := 0
	for r in rows_for(skill_id, ani_type, -1):
		n = maxi(n, int(r["event"]))
	return n

## An effect with no drawn node is still worth running only if a child file
## could draw -- never, here: every node is either drawn or skipped.
static func _draws_nothing(fx: EfpEffect) -> bool:
	return fx.draw_count() == 0

# --- projectiles (round 785) -----------------------------------------------------

## The flights in the air: {carrier, fx, target, tbone, toffset, speed,
## on_arrive, age}.
static var _flights: Array = []
## OURS: a flight still in the air after this long lands where it is.
const FLIGHT_MAX_S := 5.0

## The world point of `body`'s `bone` + `offset` (the effect attachment's own
## rule, EfpEffect._place: the skeleton's frame, the bone's origin).
static func bone_point(body: Node3D, bone: String, offset: Vector3) -> Vector3:
	var skel := skeleton_of(body)
	if skel == null or not skel.is_inside_tree():
		return body.global_transform * offset
	var at := offset
	var b := bone.strip_edges()
	if b != "" and b.to_lower() != "none" and b != "*" and not b.begins_with("#"):
		var i := skel.find_bone(b)
		if i >= 0:
			at += skel.get_bone_global_pose(i).origin
	return skel.global_transform * at

static func _fly(fx: EfpEffect, caster: Node3D, target: Node3D, row: Dictionary, on_arrive: Callable) -> void:
	var carrier := Node3D.new()
	carrier.name = "SkillFlight"
	var parent := caster.get_parent() if caster.get_parent() != null else caster
	parent.add_child(carrier)
	carrier.global_position = bone_point(caster, String(row["bone"]), row["offset"])
	var mov: Array = row.get("mov", [])
	var speed := (float(mov[2]) + float(mov[3])) * 0.5 if mov.size() == 4 else 0.0
	carrier.add_child(fx)
	fx.follow_host(carrier, "none", Vector3.ZERO)
	var f := {"carrier": carrier, "fx": fx, "target": target, "tbone": String(row.get("tbone", "none")),
		"toffset": row.get("toffset", Vector3.ZERO), "speed": maxf(speed, 1.0), "on_arrive": on_arrive,
		"age": 0.0}
	_flights.append(f)
	_aim(carrier, _flight_goal(f))

static func _flight_goal(f: Dictionary) -> Vector3:
	var t = f["target"]
	if _valid(t):
		f["last_goal"] = bone_point(t, String(f["tbone"]), f["toffset"])
	var carrier = f["carrier"]
	return f.get("last_goal", (carrier as Node3D).global_position if _valid(carrier) else Vector3.ZERO)

static func _aim(carrier: Node3D, goal: Vector3) -> void:
	var d := goal - carrier.global_position
	if d.length_squared() > 1e-6 and not d.normalized().cross(Vector3.UP).is_zero_approx():
		carrier.look_at(goal, Vector3.UP)

## Moves every flight by `delta` seconds; a flight that reaches its target
## (or outlives FLIGHT_MAX_S, OURS) lands: its effect ends and its hit lands.
static func step_flights(delta: float) -> void:
	if _flights.is_empty():
		return
	var flights := _flights
	_flights = []
	var keep: Array = []
	for f in flights:
		var carrier = f["carrier"]
		# OURS: a flight whose carrier or target is gone lands where it is.
		if not _valid(carrier) or not _valid(f["target"]):
			_land(f)
			continue
		var c: Node3D = carrier
		var goal := _flight_goal(f)
		var step := float(f["speed"]) * delta
		f["age"] = float(f["age"]) + delta
		var d := goal - c.global_position
		if d.length() <= step or float(f["age"]) >= FLIGHT_MAX_S:
			c.global_position = goal
			_land(f)
			continue
		c.global_position += d.normalized() * step
		_aim(c, goal)
		keep.append(f)
	keep.append_array(_flights)
	_flights = keep

static func _land(f: Dictionary) -> void:
	var cb: Callable = f["on_arrive"]
	if is_instance_valid(f["fx"]):
		(f["fx"] as EfpEffect).stop()
	var carrier = f["carrier"]
	if _valid(carrier):
		(carrier as Node).queue_free()
	if cb.is_valid():
		cb.call()

static func flight_count() -> int:
	return _flights.size()

# --- the clock -------------------------------------------------------------------

## The clock: scene time, the same time the effects simulate in (a movie
## render runs slower than the wall clock; so may a hitch).
static var _clock_ms := 0.0

static func _now() -> int:
	return int(_clock_ms)

## Advances the clock by a frame's `delta` seconds, moves the projectiles and
## runs `process`. World3D calls it every physics frame.
static func tick(delta: float) -> void:
	_clock_ms += maxf(delta, 0.0) * 1000.0
	step_flights(maxf(delta, 0.0))
	process()

## The skill acts on `target` (for a buff: it is applied): ACT_S now, and
## ACT_L one cycle when `with_aura` (no buff token will hold it).
static func act(skill_id: int, caster: Node3D, target: Node3D, with_aura: bool = false) -> Array:
	var out := play_phase(skill_id, SkillAudio.ACT_S, -1, caster, target, "act")
	if with_aura:
		out.append_array(play_phase(skill_id, SkillAudio.ACT_L, -1, caster, target, "act"))
	return out

## Lets the effects in `fxs` go (a cast's kept loops at its end).
static func stop_all(fxs: Array) -> void:
	_release_all(fxs)

## Round 785: lets the effects go (EfpEffect.release, READ: retail's
## decoration ends its effects through slot 4 with 0, not at once).
static func _release_all(fxs: Array) -> void:
	for fx in fxs:
		if is_instance_valid(fx):
			(fx as EfpEffect).release()

static func _stop_all(fxs: Array) -> void:
	for fx in fxs:
		if is_instance_valid(fx):
			(fx as EfpEffect).stop()

## Ends expired auras and forgets freed bodies. World3D calls it every frame
## (through tick).
static func process(now_ms: int = -1) -> void:
	var now := now_ms if now_ms >= 0 else _now()
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
			_release_all(alive)
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
		fx.loop = kept_act(int(r["act"]))
		fx.static_host = int(r["act"]) == AT_STOP
		fx.reserved = own_body != null and host == own_body
		attach(fx, host, String(r["bone"]), r["offset"], int(r.get("rotate", 0)))
		started.append(fx)
	if not started.is_empty():
		var now := now_ms if now_ms >= 0 else _now()
		_auras[_aura_key(owner_key, token)] = {"fx": started, "host": host, "skill": skill_id,
			"expires": now + remaining_ms + AURA_GRACE_MS if remaining_ms > 0 else -1}
		print("EFFECTS aura on %s token %d: skill %d, %d effect(s)" % [owner_key, token, skill_id, started.size()])
	return started

## The rows of an effect id that is no skill's (a SYSTEM_ or PARAM_ decoration,
## StateLook) for one phase.
static func rows_named(effect_id: String, ani_type: int) -> Array:
	warm()
	var out: Array = []
	for r in _rows.get(effect_id, []):
		if int(r["ani"]) == ani_type:
			out.append(r)
	return out

## Plays an effect id's rows of one phase on `host` (each at its own bone):
## its AT_LOOP rows loop and are kept as the aura of (owner_key, token) when
## `owner_key` is given; the rest play once. Returns the effects started.
static func play_named(effect_id: String, ani_type: int, host: Node3D, owner_key: String = "",
		token: int = 0) -> Array:
	var started: Array = []
	if not _valid(host) or not wants_effect(null, null, host):
		return started
	var kept: Array = []
	for r in rows_named(effect_id, ani_type):
		var fx := _make(String(r["path"]))
		if fx == null:
			continue
		if fx.draw_count() == 0 and _draws_nothing(fx):
			fx.free()
			continue
		fx.loop = kept_act(int(r["act"]))
		fx.static_host = int(r["act"]) == AT_STOP
		fx.reserved = own_body != null and host == own_body
		attach(fx, host, String(r["bone"]), r["offset"], int(r.get("rotate", 0)))
		started.append(fx)
		if fx.loop:
			kept.append(fx)
	if owner_key != "" and not kept.is_empty():
		detach_aura(owner_key, token)
		_auras[_aura_key(owner_key, token)] = {"fx": kept, "host": host, "skill": -1, "expires": -1}
	if not started.is_empty():
		print("EFFECTS %s %s on %s: %d effect(s)" % [effect_id, SkillAudio._phase_name(ani_type),
			owner_key if owner_key != "" else str(host.name), started.size()])
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
				# Round 785 (READ, FUN_00a53120 -> FUN_00a4ffe0 -> FUN_00a4db00):
				# the buff's end lets its aura go; it fades over its last cycle.
				(fx as EfpEffect).release()
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

## How many auras and flights are tracked (tests: pruning).
static func tracked_count() -> int:
	return _auras.size() + _flights.size()

## Ends every live effect this class tracks and forgets every body (a world
## teardown or relog); the tables stay loaded.
static func clear_live() -> void:
	for key in _auras.keys():
		_stop_all(_auras[key]["fx"])
	_auras.clear()
	for f in _flights:
		if is_instance_valid(f["fx"]):
			(f["fx"] as EfpEffect).stop()
		if _valid(f["carrier"]):
			(f["carrier"] as Node).queue_free()
	_flights.clear()
	own_body = null

## Clears every table and live reference (tests, a world reload).
static func reset() -> void:
	if _warm_task >= 0:
		PoolWait.task(_warm_task)
		_warm_task = -1
	clear_live()
	_rows = {}
	_timings = {}
	_loaded = false
	effect_factory = Callable()
