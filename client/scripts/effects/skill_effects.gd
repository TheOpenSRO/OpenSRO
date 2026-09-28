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
## WHEN A PHASE FIRES -- exactly where SkillAudio.play_phase is called
## (World3D): READY and SHOT/0 at cast start, SHOT/1 when the blow lands, and
## ACT_S and ACT_L when the server accepts the cast (INFERRED timing, see
## SkillAudio's header).
##
## ON WHOM (ActType, the row's +0xe byte, READ in IDecoSkill::FUN_00a51bc0:
## 0 AT_ONE_FOLLOW, 1 AT_LOOP, 2 AT_STOP are the vocabulary's first three):
## - AT_ONE_FOLLOW plays once and follows the body (READ: the decoration is
##   created with its keep flag 0 and handed to the one-shot list,
##   FUN_00a4ddc0).
## - AT_LOOP and AT_STOP are created with the keep flag 1 (READ); AT_LOOP here
##   restarts whenever its file's particles run out (INFERRED from the flag:
##   the "keep" efps are 20-frame one-shots, MEASURED), until detached.
## - AT_TARGET, AT_TARGET_F and AT_DMG_POS play on the target (INFERRED from
##   the names); everything else on the caster.
## - AT_MOV_* (projectiles) play at the caster without the flight (OURS; the
##   flight is OPEN).
## For ACT_S and ACT_L the World3D caller passes the object the skill acts on
## as both caster and target when it is the caster's own buff.
##
## HOW LONG:
## - ACT_L / AT_LOOP is the buff's aura: attach_aura keeps it per (owner,
##   token) until detach_aura -- World3D drives these from NetClient's
##   buff_started / buff_ended (rounds 616-618), behind has_signal so a build
##   without them plays ACT_L once (OURS) through play_phase instead.
## - READY / WAIT AT_LOOP (the charge glow) loops until the same caster's next
##   phase fires, or READY_LOOP_MAX seconds (OURS).
##
## WHERE (StartBone, StartOffset): at the named bone of the body's skeleton,
## following its position, turned with the body (OURS: the bone's own
## rotation is not applied); "none", "*" and "#..." (OPEN) and a missing bone
## put it at the skeleton's origin. StartOffset is added in the body's own
## native units (INFERRED). The effect sits under the skeleton, whose units
## are the effect's.

const SKILLEFFECT_PATH := "server_dep\\silkroad\\textdata\\skilleffect.txt"
const SECTION := "skilleffectset"
const READY_LOOP_MAX := 4.0 ## OURS: seconds a READY/WAIT loop may run unattended

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

## SkillEffectID -> Array of Dictionary {ani, event, act, path, bone, offset}.
static var _rows: Dictionary = {}
static var _loaded := false
static var _particles: Pk2Reader = null
## (owner key|token) -> Array of EfpEffect: the live buff auras.
static var _auras: Dictionary = {}
## caster instance id -> Array of EfpEffect: READY/WAIT loops.
static var _phase_loops: Dictionary = {}
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

## The archive effects load from; tables load from Media.pk2 on first use.
static func set_archive(particles: Pk2Reader) -> void:
	_particles = particles

static func warm() -> void:
	if _loaded:
		return
	_loaded = true
	SkillAudio.warm()
	var t0 := Time.get_ticks_msec()
	_rows = parse_rows(AudioBank.read_table("media", SKILLEFFECT_PATH))
	var n := 0
	for k in _rows:
		n += (_rows[k] as Array).size()
	print("EFFECTS skills: %d effect rows under %d effect ids (%d ms)" % [n, _rows.size(),
		Time.get_ticks_msec() - t0])

## Test seam: these rows instead of the archive's (SkillAudio.set_tables sets
## the skill table).
static func set_rows(rows: Dictionary) -> void:
	_rows = rows
	_loaded = true

static func rows_for(skill_id: int, ani_type: int, start_event: int = -1) -> Array:
	warm()
	return rows_in(SkillAudio._skills, _rows, skill_id, ani_type, start_event)

# --- playing -------------------------------------------------------------------

static func _valid(n) -> bool:
	return n != null and is_instance_valid(n) and n is Node3D

static func _make(path: String) -> EfpEffect:
	if effect_factory.is_valid():
		return effect_factory.call(path)
	return EfpEffect.create(path, _particles)

## The first Skeleton3D under a body, or null.
static func skeleton_of(host: Node) -> Skeleton3D:
	if host == null:
		return null
	if host is Skeleton3D:
		return host
	var found := host.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null

## Puts `fx` on `host` at `bone` + `offset` (see the header).
static func attach(fx: EfpEffect, host: Node3D, bone: String, offset: Vector3) -> void:
	var skel := skeleton_of(host)
	var parent: Node3D = skel if skel != null else host
	parent.add_child(fx)
	fx.position = offset
	var b := bone.strip_edges()
	if skel != null and b != "" and b.to_lower() != "none" and b != "*" and not b.begins_with("#"):
		var idx := skel.find_bone(b)
		if idx >= 0:
			fx.follow(skel, idx, offset)

## Plays `skill_id`'s effects of one phase. Returns the effects started.
static func play_phase(skill_id: int, ani_type: int, start_event: int, caster: Node3D,
		target: Node3D = null, what: String = "") -> Array:
	var started: Array = []
	if ani_type != SkillAudio.READY and ani_type != SkillAudio.WAIT and caster != null:
		stop_phase_loops(caster)
	for r in rows_for(skill_id, ani_type, start_event):
		var act := int(r["act"])
		var host := host_for(act, caster, target)
		if not _valid(host):
			continue
		var fx := _make(String(r["path"]))
		if fx == null:
			print("EFFECTS skill %d %s/%d: %s did not load (%s)" % [skill_id,
				SkillAudio._phase_name(ani_type), start_event, r["path"], EfpEffect.last_error])
			continue
		var looping := act == AT_LOOP or act == AT_STOP
		if looping and (ani_type == SkillAudio.READY or ani_type == SkillAudio.WAIT):
			fx.loop = true
			fx.max_life = READY_LOOP_MAX
			var key := caster.get_instance_id() if caster != null else 0
			if not _phase_loops.has(key):
				_phase_loops[key] = []
			(_phase_loops[key] as Array).append(fx)
		attach(fx, host, String(r["bone"]), r["offset"])
		started.append(fx)
		print("EFFECTS skill %d %s/%d: %s %s at %s (%d nodes drawn%s) %s" % [skill_id,
			SkillAudio._phase_name(ani_type), start_event, ACT_TYPES[act] if act >= 0 else "?",
			r["path"], r["bone"], fx.draw_count(),
			", skipped: " + ", ".join(fx.skipped) if not fx.skipped.is_empty() else "", what])
	return started

## Stops the READY/WAIT loops running on `caster` (they finish their cycle).
static func stop_phase_loops(caster: Node3D) -> void:
	var key := caster.get_instance_id()
	for fx in _phase_loops.get(key, []):
		if is_instance_valid(fx):
			(fx as EfpEffect).stop()
	_phase_loops.erase(key)

static func _aura_key(owner_key: String, token: int) -> String:
	return "%s|%d" % [owner_key, token]

## Starts `skill_id`'s ACT_L AT_LOOP effects on `host` as the aura of buff
## `token`, kept until detach_aura. A second start for the same token
## replaces the first. Returns the effects started.
static func attach_aura(owner_key: String, token: int, skill_id: int, host: Node3D) -> Array:
	detach_aura(owner_key, token)
	var started: Array = []
	if not _valid(host):
		return started
	for r in rows_for(skill_id, SkillAudio.ACT_L, -1):
		var fx := _make(String(r["path"]))
		if fx == null:
			continue
		fx.loop = int(r["act"]) == AT_LOOP or int(r["act"]) == AT_STOP
		attach(fx, host, String(r["bone"]), r["offset"])
		started.append(fx)
	if not started.is_empty():
		_auras[_aura_key(owner_key, token)] = started
		print("EFFECTS aura on %s token %d: skill %d, %d effect(s)" % [owner_key, token, skill_id, started.size()])
	return started

## Ends the aura of buff `token` (each effect finishes its cycle and frees).
## Returns how many effects it stopped.
static func detach_aura(owner_key: String, token: int) -> int:
	var key := _aura_key(owner_key, token)
	var n := 0
	for fx in _auras.get(key, []):
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

## Clears every table and live reference (tests, a world reload).
static func reset() -> void:
	_rows = {}
	_loaded = false
	_auras.clear()
	_phase_loops.clear()
	effect_factory = Callable()
