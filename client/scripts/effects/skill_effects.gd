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
##   Round 826 (READ, FUN_00a51bc0 case 3): an AT_TARGET row whose
##   MovTypeSpeed second number is not 0 is a mover that falls from the
##   target's position + StartOffset to its position + TargetOffset and lands
##   the group's hit there (is_target_mover).
## - THE CAMERA SHAKE (round 826, READ; CameraShake has the numbers): a row's
##   Script SCT_SHAKECAM0..3 shakes when the row plays, SCT_SHAKECAM_MOV0..3
##   when its mover arrives, unless the caster is another player
##   (shake_hook). Rows of no effect are kept for it (has_effect).
## - A KEPT DECORATION'S COLOUR (round 856, READ): IDecoSkill::FUN_00a513a0,
##   playing a decoration's rows, hands a row whose Script is SCT_MAT (flag
##   0x800) to the object's compound +0x48 -- colour 1 the bytes +0x82..0x80,
##   colour 2 +0x86..0x84 over 255, the ms +0x88 -- and keeps the row
##   (+0x180); the decoration's destructor CIDecoSkill::FUN_00a53dd0 calls
##   +0x4c when it kept one (skipped only for the hwan decoration while the
##   body mode is still 1, FUN_009c7b20). No guard: the body mode and kind
##   bytes guard the state bits' colour alone (StateLook). So a buff's or a
##   state's ACT_L row with SCT_MAT -- 22 rows in skilleffect.txt (MEASURED):
##   PARAM_STONE, the Roc's frenzy, the petrify attacks, two Cleric rebirth
##   buffs, the flame master's and the event thieves' marks, besides berserk's
##   three (BerserkLook) -- puts its colour in the body's one slot (BodyPulse,
##   DECO_WHO) while its aura lives, and its end takes the slot off whoever
##   set it, once the aura's end fade is over (INFERRED: the decoration is
##   freed at its fade's end, the rows' Fade; 0 is at once).
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
##   frees them at once (EfpEffect.stop). Round 847 (READ, the same
##   FUN_00a4db00): before it clears the keep flag it starts the copy's alpha
##   fade over the row's Fade first value (FUN_00a48690 -> FUN_00a48190,
##   ms / 1000.0), and the decoration's update (CIDecoSkill::vslot_014,
##   0x00a503f0) steps that fade each frame, hands the alpha to the effect
##   (slot 0x24) and frees the effect (slot 2) once the fade is done at
##   alpha 0. So an aura whose row has a Fade (every PARAM_ state row: 300)
##   is gone that many ms after its end -- `_end_kept`; round 785's release
##   alone let it play out for 0.5-4 s, and a state whose loop never dies by
##   itself (confusion's status_bad_temptation) for ONESHOT_MAX_LIFE, 30 s
##   (MEASURED, tools/state_aura_release_probe.gd). A row with no Fade is let
##   go as before. With the buff's remaining
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
## Round 809 (the header's own names first, these the fallback; MEASURED, the
## section's `//` line): Scale 6, CreateCnt 11, Fade 12, Act Option 16,
## ObjName2 23.
const C_SCALE := 6
const C_CNT := 11
const C_FADE := 12
const C_OPT := 16
const C_OBJ2 := 23
## Round 826: Script (the camera shakes' SCT_ name; MEASURED, the `//` line).
const C_SCRIPT := 25

## Round 809: the row's object kind, its ObjName's extension through the
## client's name map (READ, 0xec7180..0xec7400, record +0x37): none 0, bsr 1,
## efp 2, wav 3, ddj 4. Rows of kind bsr and efp are kept.
const KIND_BSR := 1
const KIND_EFP := 2
const AT_MOV_OPTION := 8
## Scale (record +4; READ, the same name map): none 0, CHAR_BASE 1, MOB_BASE 2.
static var SCALE_KINDS := {"none": 0, "CHAR_BASE": 1, "MOB_BASE": 2}

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
		"dmg": C_DMG, "mov": C_MOV, "tbone": C_TBONE, "toffset": C_TOFFSET, "rotate": C_ROTATE,
		"scale": C_SCALE, "cnt": C_CNT, "fade": C_FADE, "opt": C_OPT, "obj2": C_OBJ2, "script": C_SCRIPT}
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
				"MovTypeSpeed": "mov", "TargetBone": "tbone", "TargetOffset": "toffset", "Rotate": "rotate",
				"Scale": "scale", "CreateCnt": "cnt", "Fade": "fade", "Act Option": "opt", "ObjName2": "obj2",
				"Script": "script"}
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
		var kind := object_kind(obj)
		var script := script_flag(_cell(cols, int(col["script"])))
		# Round 826: a row of no effect is kept only for its camera shake
		# (READ: every row reaches the shake test, a sound's and a none's
		# too; rows_in leaves these out unless asked).
		# Round 856: and a row of no effect for its colour (SCT_MAT).
		if kind != KIND_EFP and kind != KIND_BSR and script & (SHAKE_FLAGS | SCT_MAT) == 0:
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
			"kind": kind,
			"mov_a": parse_mov_delay(_cell(cols, int(col["mov"]))),
			"mov_b": parse_mov_speed(_cell(cols, int(col["mov"]))),
			"script": script,
			"scale": int(SCALE_KINDS.get(_cell(cols, int(col["scale"])), 0)),
			"cnt": maxi(int(_cell(cols, int(col["cnt"]))), 1) if _cell(cols, int(col["cnt"])).is_valid_int() else 1,
			"fade": parse_pair(_cell(cols, int(col["fade"]))),
			"opt": parse_option(_cell(cols, int(col["opt"]))),
			"obj2": _obj2(_cell(cols, int(col["obj2"]))),
			"mat": parse_mat(_cell(cols, int(col["script"]))) if script & SCT_MAT != 0 else {},
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

## Round 809: an ObjName's object kind (READ, the name map: by extension;
## "none" or empty 0).
static func object_kind(obj: String) -> int:
	var o := obj.strip_edges().to_lower()
	if o == "" or o == "none":
		return 0
	match o.get_extension():
		"bsr":
			return KIND_BSR
		"efp":
			return KIND_EFP
		"wav":
			return 3
		"ddj":
			return 4
	return 0

## MovTypeSpeed's first number, the delay in ms (record +0x10, READ: the
## object neither shows nor moves for it), whatever the kind, MOV_NONE too.
static func parse_mov_delay(cell: String) -> int:
	var p := cell.strip_edges().split(",")
	if p.size() < 2 or not String(p[1]).strip_edges().is_valid_int():
		return 0
	return maxi(int(p[1]), 0)

## Round 826: MovTypeSpeed's second number (record +0x12, READ: the row
## parser reads the four cells into +0xf, +0x10, +0x12, +0x14), whatever the
## kind. An AT_TARGET row with it non-zero is a mover (IDecoSkill::
## FUN_00a51bc0's case 3).
static func parse_mov_speed(cell: String) -> int:
	var p := cell.strip_edges().split(",")
	if p.size() < 3 or not String(p[2]).strip_edges().is_valid_int():
		return 0
	return int(p[2])

## Round 826: the Script cell's SCT_ flag (READ, the name table at 0x00ec7378:
## the name up to the first comma; "none" and anything unknown 0).
static func script_flag(cell: String) -> int:
	var name := cell.strip_edges().get_slice(",", 0).strip_edges()
	return int(SCT_NAMES.get(name, 0))

## The SCT_ name table (READ, 0x00ec7378: (name, flag) pairs).
const SCT_NAMES := {"none": 0, "SCT_ARROW": 0x1, "SCT_RUT": 0x2, "SCT_MOVER": 0x4,
	"SCT_SHAKECAM0": 0x8, "SCT_SHAKECAM1": 0x10, "SCT_SHAKECAM_MOV0": 0x20, "SCT_SHAKECAM_MOV1": 0x40,
	"SCT_SHAKECAM2": 0x80, "SCT_SHAKECAM3": 0x100, "SCT_SHAKECAM_MOV2": 0x200, "SCT_SHAKECAM_MOV3": 0x400,
	"SCT_MAT": 0x800, "SCT_CHAR_SCALE": 0x1000, "SCT_EFFECT_SCALE": 0x2000}
## Round 856: the colour script (READ, the table above).
const SCT_MAT := 0x800
## BodyPulse's name for a kept decoration's colour.
const DECO_WHO := "deco"

## `SCT_MAT,r1,g1,b1,r2,g2,b2,ms` -> {"c1", "c2": Color, "ms": int} (READ,
## FUN_00a9d0f0 packs the bytes, FUN_00a513a0 divides them by 255), {} for
## any other cell.
static func parse_mat(cell: String) -> Dictionary:
	var p := cell.strip_edges().split(",")
	if p.size() < 8 or String(p[0]).strip_edges() != "SCT_MAT":
		return {}
	var b := func(i: int) -> int: return clampi(int(String(p[i]).strip_edges()), 0, 255)
	return {"c1": Color8(b.call(1), b.call(2), b.call(3)), "c2": Color8(b.call(4), b.call(5), b.call(6)),
		"ms": maxi(int(String(p[7]).strip_edges()), 0)}

## The colour a decoration's rows put on the body: the last row with
## SCT_MAT (FUN_00a513a0 calls +0x48 per row, so the last wins), or {}.
static func mat_of(rows: Array) -> Dictionary:
	var out := {}
	for r in rows:
		var m: Dictionary = r.get("mat", {})
		if not m.is_empty():
			out = m
	return out

## Every camera shake flag, at the row's play and at its mover's arrival.
const SHAKE_FLAGS := 0x8 | 0x10 | 0x20 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400

## "a,b" -> [a, b] (Fade: record +0xa, +0xc), [0, 0] for anything else.
static func parse_pair(cell: String) -> Array:
	var p := cell.strip_edges().split(",")
	if p.size() != 2 or not String(p[0]).strip_edges().is_valid_int() or not String(p[1]).strip_edges().is_valid_int():
		return [0, 0]
	return [int(p[0]), int(p[1])]

## Act Option `flag,angle,dist,spacing,u16,bool` (READ, FUN_00a9d0f0: record
## +0x24 the flag, +0x28 the angle in degrees made radians -- / 360.0 x
## 6.2831854, 0xdde7a8 / 0xd81930 -- +0x2c the distance, +0x30 the spacing;
## +0x34 and +0x36 are read by nothing found, OPEN) -> {} when the flag is
## false or the cell does not parse.
static func parse_option(cell: String) -> Dictionary:
	var p := cell.strip_edges().split(",")
	if p.size() != 6 or String(p[0]).strip_edges().to_lower() != "true":
		return {}
	for k in range(1, 5):
		if not String(p[k]).strip_edges().is_valid_float():
			return {}
	return {"angle": float(p[1]) / 360.0 * TAU, "dist": float(p[2]), "spacing": float(p[3]),
		"w5": int(float(p[4])), "b6": String(p[5]).strip_edges().to_lower() == "true"}

## ObjName2 (record +0x74): the effect made where a mover arrives; "" for none.
static func _obj2(cell: String) -> String:
	var o := cell.strip_edges()
	return "" if o == "" or o.to_lower() == "none" else o

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
		start_event: int = -1, bare := false) -> Array:
	var out: Array = []
	for r in SkillAudio.effect_rows_in(skills, rows, skill_id):
		if not bare and not has_effect(r):
			continue
		if int(r["ani"]) == ani_type and (start_event < 0 or int(r["event"]) == start_event):
			out.append(r)
	return out

## Whether a row makes an effect (.efp or .bsr); round 826 keeps the others
## for their shakes alone (`bare`).
static func has_effect(r: Dictionary) -> bool:
	var k := int(r.get("kind", KIND_EFP))
	return k == KIND_EFP or k == KIND_BSR

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

## Every .efp path a skill's rows name (ObjName2 included, round 809).
static func paths_for(skill_id: int) -> PackedStringArray:
	warm()
	var out := PackedStringArray()
	for r in SkillAudio.effect_rows_in(SkillAudio._skills, _rows, skill_id):
		var ps: Array = [String(r.get("obj2", ""))]
		if int(r.get("kind", KIND_EFP)) == KIND_EFP:
			ps.append(String(r["path"]))
		for p in ps:
			if p != "" and p.to_lower().ends_with(".efp") and not out.has(p):
				out.append(p)
	return out

## Round 809: every .bsr object a skill's rows name.
static func bsr_paths_for(skill_id: int) -> PackedStringArray:
	warm()
	var out := PackedStringArray()
	for r in SkillAudio.effect_rows_in(SkillAudio._skills, _rows, skill_id):
		if int(r.get("kind", KIND_EFP)) == KIND_BSR and not out.has(String(r["path"])):
			out.append(String(r["path"]))
	return out

## Decodes a skill's effect files off the main thread (see the header), and
## starts assembling its .bsr objects (round 809, BsrEffect).
static func preload_skill(skill_id: int) -> int:
	for p in bsr_paths_for(skill_id):
		BsrEffect.preload_path(p)
	return EfpEffect.preload_paths(paths_for(skill_id), _particles)

## Round 809: preload_skill once per skill id (a monster's swing asks every
## time; only its first asks the workers).
static var _preloaded := {}
static func preload_skill_once(skill_id: int) -> void:
	if skill_id == 0 or _preloaded.has(skill_id):
		return
	_preloaded[skill_id] = true
	preload_skill(skill_id)

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
	var named := b != "" and b.to_lower() != "none" and b != "*"
	# Round 838 (READ, EfpEffect.follow_bone_point): '#' places the offset in
	# the bone's frame along the world's axes, and skips the Rotate.
	var point := named and b.begins_with("#")
	fx.follow_bone_point = point
	fx.follow_bone_turn = named and not point and not b.begins_with("@")
	fx.follow_world_turn = named and b.begins_with("@")
	fx.follow_basis = Basis.IDENTITY if point else rotate_basis(rotate)
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
	warm()
	for r in rows_in(SkillAudio._skills, _rows, skill_id, ani_type, start_event, true):
		var act := int(r["act"])
		# Round 826: a row of no effect (a sound's, a none's) is kept for its
		# shake alone (READ: such a row reaches the shake test).
		if not has_effect(r):
			_shake_at_play(r, caster)
			continue
		var host := host_for(act, caster, target)
		if not _valid(host):
			continue
		var option_mover := is_option_mover(r) and _valid(caster)
		var drop := is_target_mover(r)
		var flies := option_mover or drop or (act >= AT_MOV_1TAR and _valid(target) and target != caster and _valid(caster))
		if not wants_effect(caster, target, host):
			# READ: the Effect Quality refusal is the effect's maker's
			# (FUN_00a51120, FUN_00a557f0): an AT_STOP / AT_ONE_FOLLOW /
			# AT_LOOP row then skips the shake test (0xa52eec); every other
			# row still reaches it, and a mover still flies, unseen, to land
			# its hit and its shake (round 826).
			if act > AT_LOOP:
				_shake_at_play(r, caster)
			if flies:
				var carries_q: Callable = arrive if bool(r.get("dmg", false)) else Callable()
				if carries_q.is_valid():
					arrive = Callable()
				_fly_row(null, caster, target, host, r, carries_q, "", drop, true)
			continue
		# Round 809: a .bsr object (BsrEffect), never in the returned list
		# (its life is its clip's or its mover's).
		if int(r.get("kind", KIND_EFP)) == KIND_BSR:
			var carries_b: Callable = arrive if bool(r.get("dmg", false)) else Callable()
			if drop:
				_fly_row(null, caster, target, host, r, carries_b, String(r["path"]), true)
				if carries_b.is_valid():
					arrive = Callable()
			elif _play_bsr(r, act, caster, target, host, option_mover, carries_b, skill_id, ani_type, start_event) \
					and carries_b.is_valid():
				arrive = Callable()
			_shake_at_play(r, caster)
			continue
		var fx := _make(String(r["path"]))
		if fx == null:
			print("EFFECTS skill %d %s/%d: %s did not load (%s)" % [skill_id,
				SkillAudio._phase_name(ani_type), start_event, r["path"], EfpEffect.last_error])
			# READ: no effect made skips the shake for AT_STOP..AT_LOOP.
			if act > AT_LOOP:
				_shake_at_play(r, caster)
			continue
		_shake_at_play(r, caster)
		if fx.draw_count() == 0 and fx.sim != null and fx.sim.template != null \
				and _draws_nothing(fx):
			print("EFFECTS skill %d %s/%d: %s draws nothing (skipped: %s)" % [skill_id,
				SkillAudio._phase_name(ani_type), start_event, r["path"], ", ".join(fx.skipped)])
			fx.free()
			fx = null
			if not flies:
				continue
		if fx != null:
			fx.reserved = own_body != null and (host == own_body or caster == own_body)
			# Round 785: AT_LOOP of any phase is kept (the caller lets it go --
			# SkillDeco's end); AT_STOP is placed once, where it is cast (READ).
			fx.static_host = act == AT_STOP
			if kept_act(act):
				fx.loop = true
				fx.max_life = READY_LOOP_MAX
		if flies:
			var carries: Callable = arrive if bool(r.get("dmg", false)) else Callable()
			if carries.is_valid():
				arrive = Callable()
			_fly_row(fx, caster, target, host, r, carries, "", drop)
		else:
			attach(fx, host, String(r["bone"]), r["offset"], int(r.get("rotate", 0)))
		if fx == null:
			continue
		started.append(fx)
		print("EFFECTS skill %d %s/%d: %s %s at %s (%d nodes drawn%s) %s%s" % [skill_id,
			SkillAudio._phase_name(ani_type), start_event, ACT_TYPES[act] if act >= 0 else "?",
			r["path"], r["bone"], fx.draw_count(),
			", skipped: " + ", ".join(fx.skipped) if not fx.skipped.is_empty() else "", what,
			(" -- falls on the target" if drop else " -- flies to the target") if flies else ""])
	return started

## Round 826: an AT_TARGET row whose MovTypeSpeed second number is not 0 is a
## mover (READ, IDecoSkill::FUN_00a51bc0 case 3, `row+0x12 != 0`): it goes
## from the target's position plus StartOffset to the target's position plus
## TargetOffset -- both on the world's axes, the target's turn not applied
## (the case adds the row's offset vectors, +0x40 and +0x58, to the target's
## +0x80 position) -- and lands the hit the group carries there
## (FUN_00a4d430 takes it). Before round 826 such a row was placed on the
## target at StartBone + StartOffset and never fell (231 rows, MEASURED).
static func is_target_mover(r: Dictionary) -> bool:
	return int(r["act"]) == AT_TARGET and int(r.get("mov_b", 0)) != 0

## A row offset (the original's x, y, z) on the world's axes here: z mirrored
## (UserSpawnNet.world_xz).
static func world_offset(o: Vector3) -> Vector3:
	return Vector3(o.x, o.y, -o.z)

## Flies one row: an AT_TARGET mover (`drop`) CreateCnt times from above the
## target (READ: case 3's loop; the hit goes with the first), any other from
## the caster (_fly).
static func _fly_row(fx: EfpEffect, caster: Node3D, target: Node3D, host: Node3D, r: Dictionary,
		carries: Callable, bsr_path: String, drop: bool, unseen := false) -> void:
	if not drop:
		_fly(fx, caster, target, r, carries, bsr_path)["unseen"] = unseen
		return
	var on: Node3D = target if _valid(target) else host
	var base := on.global_position
	var from := base + world_offset(r["offset"])
	var to := base + world_offset(r.get("toffset", Vector3.ZERO))
	for i in int(r.get("cnt", 1)):
		var one := fx if i == 0 else (_make(String(r["path"])) if fx != null else null)
		_fly(one, caster if _valid(caster) else on, null, r, carries if i == 0 else Callable(), bsr_path, from, to)["unseen"] = unseen

## Round 826: the camera shake hook -- Callable(flags: int, caster: Node3D,
## at_arrival: bool) -- World3D's (it holds the camera and knows who is
## another player). Unset: no shake.
static var shake_hook: Callable = Callable()

## The shake test when a row plays (READ, FUN_00a51bc0 at 0xa52e5f): the
## caster (the decoration's owner) is not another player, and the row has a
## SHAKECAM0..3 flag. A row played with no caster in view starts none (the
## original has no decoration for it).
static func _shake_at_play(r: Dictionary, caster: Node3D) -> void:
	var flags := int(r.get("script", 0)) & (0x8 | 0x10 | 0x80 | 0x100)
	if flags != 0 and _valid(caster) and shake_hook.is_valid():
		shake_hook.call(flags, caster, false)

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

## Whether the group's DMG row is a projectile (its hit lands on arrival) --
## an AT_TARGET mover's too (round 826, is_target_mover).
static func group_dmg_flies(skill_id: int, ani_type: int, start_event: int) -> bool:
	for r in rows_for(skill_id, ani_type, start_event):
		if bool(r.get("dmg", false)) and (int(r["act"]) >= AT_MOV_1TAR or is_target_mover(r)):
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
	if b.begins_with("#") and b.length() > 1:
		# Round 838 (READ, EfpEffect.follow_bone_point): the offset in the
		# bone's frame.
		var j := skel.find_bone(b.substr(1))
		if j >= 0:
			return skel.global_transform * (skel.get_bone_global_pose(j) * offset)
	elif b != "" and b.to_lower() != "none" and b != "*":
		var i := skel.find_bone(b.trim_prefix("@"))
		if i >= 0:
			at += skel.get_bone_global_pose(i).origin
	return skel.global_transform * at

## Round 809: whether a row is a mover sent along the caster's heading rather
## than at a target -- AT_MOV_OPTION, and AT_MOV_1TAR with its Act Option
## flag set (READ, FUN_00a4cc70: the goal override does not test the ActType;
## the Cold Bingpan A/C/E rows).
static func is_option_mover(r: Dictionary) -> bool:
	var act := int(r.get("act", -1))
	return not (r.get("opt", {}) as Dictionary).is_empty() and (act == AT_MOV_OPTION or act == AT_MOV_1TAR)

## Round 809: the heading of a body's drawn model, the client's +0x8c: its
## front is the model's -Z (MonsterMotion.MODEL_FRONT; another player's
## skeleton is turned PI under its root, so the same holds), and heading h
## faces RemoteFacing.facing_of(h) = (sin h, cos h) in world x, z.
static func heading_of(body: Node3D) -> float:
	var sk := skeleton_of(body)
	var n: Node3D = sk if sk != null and sk.is_inside_tree() else body
	var front := -(n.global_transform.basis.z if n.is_inside_tree() else n.transform.basis.z)
	if Vector2(front.x, front.z).is_zero_approx():
		return 0.0
	return RemoteFacing.wrap_heading(atan2(front.x, front.z))

## Round 809: the goal of an option mover (READ, FUN_00a4cc70 with the option
## flag: the caster's heading plus the row's angle, the distance along it on
## the ground -- (sin h, 0, -cos h) in the client's region frame, whose z the
## world mirrors: RemoteFacing.facing_of).
static func option_goal(start: Vector3, heading: float, opt: Dictionary) -> Vector3:
	var dir := RemoteFacing.facing_of(heading + float(opt.get("angle", 0.0)))
	return start + Vector3(dir.x, 0.0, dir.y) * float(opt.get("dist", 0.0))

## A mover's speed (READ, FUN_00a481f0 -> FUN_009ec9a0(b, c): b when c <= b;
## OPEN what it does when c > b, taken here as their mean, as rounds 785-808
## took every row).
static func mover_speed(mov: Array) -> float:
	if mov.size() != 4:
		return 1.0
	var b := float(mov[2])
	var c := float(mov[3])
	return maxf(b if c <= b else (b + c) * 0.5, 1.0)

static func _fly(fx: EfpEffect, caster: Node3D, target: Node3D, row: Dictionary, on_arrive: Callable,
		bsr_path: String = "", from = null, to = null) -> Dictionary:
	var carrier := Node3D.new()
	carrier.name = "SkillFlight"
	var parent := caster.get_parent() if caster.get_parent() != null else caster
	parent.add_child(carrier)
	# Round 826: an AT_TARGET mover starts and ends at given points.
	var start: Vector3 = from if from != null else bone_point(caster, String(row["bone"]), row["offset"])
	carrier.global_position = start
	if fx != null:
		# Round 809 (READ, FUN_00a4cc70): a mover's effect is made kept
		# ((+0x10)(1)); its arrival lets it go or fades it (_land).
		fx.loop = true
		carrier.add_child(fx)
		fx.follow_host(carrier, "none", Vector3.ZERO)
	var f := {"carrier": carrier, "fx": fx, "target": target, "tbone": String(row.get("tbone", "none")),
		"toffset": row.get("toffset", Vector3.ZERO), "speed": mover_speed(row.get("mov", [])), "on_arrive": on_arrive,
		"age": 0.0, "row": row, "trail": [], "since": 0.0, "wait": float(row.get("mov_a", 0)) / 1000.0,
		"heading": heading_of(caster), "caster": caster}
	if to != null:
		f["goal"] = to
		f["target"] = null
	if is_option_mover(row):
		f["heading"] = RemoteFacing.wrap_heading(float(f["heading"]) + float((row["opt"] as Dictionary).get("angle", 0.0)))
		f["goal"] = option_goal(start, heading_of(caster), row["opt"])
		f["target"] = null
	# READ: neither shown nor moved for MovTypeSpeed a ms.
	if float(f["wait"]) > 0.0:
		carrier.visible = false
		if fx != null:
			fx.process_mode = Node.PROCESS_MODE_DISABLED
	if bsr_path != "":
		BsrEffect.spawn(bsr_path, {"parent": carrier, "local": true, "types": [BsrEffect.TYPE_FIRST],
			"until_freed": true})
	_flights.append(f)
	_aim(carrier, _flight_goal(f))
	return f

static func _flight_goal(f: Dictionary) -> Vector3:
	if f.has("goal"):
		return f["goal"]
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
		# OURS: a flight whose carrier or target is gone lands where it is
		# (an option mover has no target: its goal is a point).
		if not _valid(carrier) or (not f.has("goal") and not _valid(f["target"])):
			_land(f)
			continue
		var c: Node3D = carrier
		if float(f["wait"]) > 0.0:
			f["wait"] = float(f["wait"]) - delta
			if float(f["wait"]) > 0.0:
				keep.append(f)
				continue
			c.visible = true
			if is_instance_valid(f["fx"]):
				(f["fx"] as Node).process_mode = Node.PROCESS_MODE_INHERIT
		var goal := _flight_goal(f)
		var step := float(f["speed"]) * delta
		f["age"] = float(f["age"]) + delta
		var d := goal - c.global_position
		if d.length() <= step or float(f["age"]) >= FLIGHT_MAX_S:
			_trail(f, minf(d.length(), step))
			c.global_position = goal
			_land(f)
			continue
		c.global_position += d.normalized() * step
		_aim(c, goal)
		_trail(f, step)
		keep.append(f)
	keep.append_array(_flights)
	_flights = keep

## Round 809, the option mover's trail (READ, CIDecoMoveObj::vslot_009 at
## 0xa4d25c): the distance moved is summed (+0x17c) and, past the option's
## spacing (+0x30), reset to 0 while a new copy of the row's .efp -- kept
## (keep flag 1), at the mover's position, turned by its heading
## (FUN_0043cda0) -- joins the mover's list.
static func _trail(f: Dictionary, moved: float) -> void:
	var row: Dictionary = f["row"]
	var opt: Dictionary = row.get("opt", {})
	var spacing := float(opt.get("spacing", 0.0))
	if spacing <= 0.0 or int(row.get("kind", KIND_EFP)) != KIND_EFP:
		return
	f["since"] = float(f["since"]) + moved
	if float(f["since"]) <= spacing:
		return
	f["since"] = 0.0
	var c: Node3D = f["carrier"]
	var copy := _place_static(String(row["path"]), c.global_position, float(f["heading"]), c.get_parent(), true)
	if copy != null:
		(f["trail"] as Array).append(copy)

## An effect left in the world at `at`, turned by heading `h` (a -Z-front
## model's turn, RemoteFacing.yaw_of(h, PI)): an anchor node holding it,
## placed once. `kept`: it loops until let go. Null when it does not load.
static func _place_static(path: String, at: Vector3, h: float, parent: Node, kept: bool) -> EfpEffect:
	if path == "" or parent == null or not is_instance_valid(parent):
		return null
	var fx := _make(path)
	if fx == null:
		return null
	var anchor := Node3D.new()
	anchor.name = "SkillMark"
	parent.add_child(anchor)
	anchor.global_position = at
	anchor.rotation.y = RemoteFacing.yaw_of(h, PI)
	anchor.add_child(fx)
	fx.loop = kept
	fx.static_host = true
	fx.follow_host(anchor, "none", Vector3.ZERO)
	# The anchor goes with its effect.
	fx.tree_exited.connect(func() -> void:
		if is_instance_valid(anchor) and not anchor.is_queued_for_deletion():
			anchor.queue_free(), CONNECT_ONE_SHOT)
	return fx

## Round 809's arrival (READ, FUN_00a4c380): ObjName2, when set, is made at
## the point; then by Fade's second value (+0xc) the head and its trail
## copies go -- below 0 at once, 0 let go (the keep flag cleared, they play
## out), above 0 faded 255 -> 0 over Fade's first value (+0xa,
## FUN_00a48690 -> FUN_00a48190) and deleted when it reaches 0 (round 810,
## READ FUN_00a48760: a copy whose fade is done is freed through slot 8 and
## dropped). Round 809 had no effect alpha: it held them at full strength
## for the fade's length and then let them play out (Hashade's shards ~0.55 s
## more, MEASURED), which the user saw hang around too long. A mover carrying
## a .bsr object is removed on arrival (its carrier freed).
static func _land(f: Dictionary) -> void:
	var cb: Callable = f["on_arrive"]
	var carrier = f["carrier"]
	var row: Dictionary = f.get("row", {})
	var fade: Array = row.get("fade", [0, 0])
	var at: Vector3 = (carrier as Node3D).global_position if _valid(carrier) else Vector3.ZERO
	if _valid(carrier) and String(row.get("obj2", "")) != "" and not bool(f.get("unseen", false)):
		_place_static(String(row["obj2"]), at, float(f.get("heading", 0.0)), (carrier as Node).get_parent(), false)
	# Round 826 (READ, FUN_00a4c380 -> FUN_00a4bf00): the arrival's shake,
	# SHAKECAM_MOV0..3, when the caster -- looked up again by id, so one gone
	# from view passes -- is not another player.
	var mov_flags := int(row.get("script", 0)) & (0x20 | 0x40 | 0x200 | 0x400)
	if mov_flags != 0 and shake_hook.is_valid():
		var c = f.get("caster")
		shake_hook.call(mov_flags, c if _valid(c) else null, true)
	var fxs: Array = []
	if is_instance_valid(f["fx"]):
		fxs.append(f["fx"])
	for t in f.get("trail", []):
		if is_instance_valid(t):
			fxs.append(t)
	var second := int(fade[1])
	if second < 0 or fxs.is_empty():
		_stop_all(fxs)
		if _valid(carrier):
			(carrier as Node).queue_free()
	else:
		var head = f["fx"]
		if is_instance_valid(head):
			(head as Node).process_mode = Node.PROCESS_MODE_INHERIT
		var fade_ms := int(fade[0]) if second > 0 else 0
		# READ: FUN_00a48190 starts no fade for a first value of 0; OPEN what
		# then ends the copies -- let go at once, as round 809 did.
		if second == 0 or fade_ms <= 0:
			_release_all(fxs)
		_lingers.append({"fx": fxs, "carrier": carrier, "fade_from": _now(), "fade_ms": fade_ms,
			"until": _now() + LINGER_MAX_MS})
	if cb.is_valid():
		cb.call()

## Round 809: effects left after their mover arrived -- {fx, carrier,
## fade_from (ms), fade_ms (0: let go, no fade), until (OURS cap)}; their
## carrier is freed once none of them is left. Round 810: a fading one's
## alpha runs 255 -> 0 linearly over fade_ms (READ FUN_00a47d20: t += dt /
## length, alpha = lerp(start, 0, t)), and at 0 they are stopped.
static var _lingers: Array = []
## OURS: an arrived mover's effects are stopped this long after at the most.
const LINGER_MAX_MS := 12000

static func _step_lingers(now: int) -> void:
	if _lingers.is_empty():
		return
	var keep: Array = []
	for l in _lingers:
		var alive: Array = []
		for fx in l["fx"]:
			if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion():
				alive.append(fx)
		l["fx"] = alive
		var fade_ms := int(l["fade_ms"])
		if fade_ms > 0:
			var t := float(now - int(l["fade_from"])) / float(fade_ms)
			if t >= 1.0:
				_stop_all(alive)
				alive.clear()
			else:
				var a := int(round(255.0 * (1.0 - clampf(t, 0.0, 1.0))))
				for fx in alive:
					(fx as EfpEffect).set_alpha(a)
		if now >= int(l["until"]):
			_stop_all(alive)
			alive.clear()
		if alive.is_empty():
			if _valid(l["carrier"]):
				(l["carrier"] as Node).queue_free()
			continue
		keep.append(l)
	_lingers = keep

static func linger_count() -> int:
	return _lingers.size()

# --- .bsr objects (round 809, BsrEffect) -------------------------------------------

## Plays a .bsr row (BsrEffect's header has the READ): on the target's
## TargetBone point (AT_TARGET, AT_TARGET_F, AT_DMG_POS -- the last two
## OURS), facing the caster, unscaled, type 0 then type 2, CreateCnt of them,
## after MovTypeSpeed a; on the caster (every other non-mover ActType) at
## StartBone + StartOffset, scaled by the body, type 0, following it (AT_STOP
## placed once); as a mover's object. True when a mover took `carries`.
static func _play_bsr(r: Dictionary, act: int, caster: Node3D, target: Node3D, host: Node3D, option_mover: bool,
		carries: Callable, skill_id: int, ani_type: int, start_event: int) -> bool:
	var p := String(r["path"])
	var what := "EFFECTS skill %d %s/%d: %s %s" % [skill_id, SkillAudio._phase_name(ani_type), start_event,
		ACT_TYPES[act] if act >= 0 and act < ACT_TYPES.size() else "?", p]
	var flies := option_mover or (act >= AT_MOV_1TAR and _valid(target) and target != caster and _valid(caster))
	if flies:
		_fly(null, caster, target, r, carries, p)
		print(what + " flies")
		return true
	var turn_from: Node3D = caster if _valid(caster) else host
	var parent := host.get_parent() if host.get_parent() != null else host
	if act == AT_TARGET or act == AT_TARGET_F or act == AT_DMG_POS:
		var on: Node3D = target if _valid(target) else host
		for i in int(r.get("cnt", 1)):
			BsrEffect.spawn(p, {"parent": parent, "at": bone_point(on, String(r.get("tbone", "none")), r.get("toffset", Vector3.ZERO)),
				"basis": BsrEffect.host_turn(turn_from), "scale": 1.0,
				"types": [BsrEffect.TYPE_FIRST, BsrEffect.TYPE_TARGET], "delay_ms": int(r.get("mov_a", 0))})
		print(what + " at the target")
		return false
	var sk := skeleton_of(host)
	var body_scale := absf((sk as Node3D).global_transform.basis.get_scale().x) if sk != null and sk.is_inside_tree() else 1.0
	BsrEffect.spawn(p, {"parent": parent, "at": bone_point(host, String(r["bone"]), r["offset"]),
		"basis": BsrEffect.host_turn(host), "scale": body_scale, "types": [BsrEffect.TYPE_FIRST],
		"host": host, "bone": String(r["bone"]), "offset": r["offset"], "follow": act != AT_STOP,
		"place_once": act == AT_STOP})
	print(what + " on the caster")
	return false

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
	BsrEffect.tick(maxf(delta, 0.0))
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

## Round 847: the ms a row's effect fades out over when its decoration ends
## -- the Fade column's first value (READ: FUN_00a48690 hands the row's +0xa
## word to FUN_00a48190, which starts no fade for 0).
static func end_fade_ms_of(r: Dictionary) -> int:
	var fade: Array = r.get("fade", [0, 0])
	return maxi(int(fade[0]), 0) if fade.size() >= 1 else 0

## Round 847: ends kept effects as the original's decoration end does (READ,
## IDecoSkill::FUN_00a4db00, for every effect of the decoration): the keep
## flag cleared (EfpEffect.release) and, when the effect's row has a Fade
## (end_fade_ms > 0), its alpha 255 -> 0 over that many ms and the effect
## freed when it reaches 0 (CIDecoSkill::vslot_014's fade step and slot 2;
## the fade is FUN_00a47d20's linear t, as an arrival's, `_step_lingers`).
## One without a Fade plays out (round 785).
static func _end_kept(fxs: Array, now_ms: int = -1) -> void:
	var by_ms := {}
	for fx in fxs:
		if not is_instance_valid(fx) or (fx as Node).is_queued_for_deletion():
			continue
		var e := fx as EfpEffect
		e.release()
		if e.is_queued_for_deletion() or e.end_fade_ms <= 0:
			continue
		if not by_ms.has(e.end_fade_ms):
			by_ms[e.end_fade_ms] = []
		(by_ms[e.end_fade_ms] as Array).append(e)
	var now := now_ms if now_ms >= 0 else _now()
	for ms in by_ms:
		_lingers.append({"fx": by_ms[ms], "carrier": null, "fade_from": now, "fade_ms": int(ms),
			"until": now + LINGER_MAX_MS})

## Ends expired auras and forgets freed bodies. World3D calls it every frame
## (through tick).
static func process(now_ms: int = -1) -> void:
	var now := now_ms if now_ms >= 0 else _now()
	_step_lingers(now)
	_step_colour_ends(now)
	for key in _auras.keys():
		var a: Dictionary = _auras[key]
		var alive: Array = []
		for fx in a["fx"]:
			if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion():
				alive.append(fx)
		var models := _alive_models(a)
		var coloured := not (a.get("mat", {}) as Dictionary).is_empty()
		if coloured and not _valid(a.get("host")):
			# Round 856: its body is gone, and its colour slot with it.
			_auras.erase(key)
		elif alive.is_empty() and models.is_empty() and not coloured:
			_auras.erase(key)
		elif int(a["expires"]) >= 0 and now >= int(a["expires"]):
			print("EFFECTS aura %s: no end arrived %d ms after its time -- ending it" % [key, AURA_GRACE_MS])
			_note_end(key, alive)
			_end_kept(alive, now)
			_release_models(models)
			_deco_colour_off(a, now)
			_auras.erase(key)
		else:
			a["fx"] = alive
			a["models"] = models

## Round 838: an aura's .bsr models (AuraModel) still drawing.
## Round 847: when an aura ended, and when each of its effects stopped
## drawing after (the log the lingering-state QA reads; frames are the
## engine's, the time the wall clock's).
static func _note_end(key: String, fxs: Array) -> void:
	var at := Time.get_ticks_msec()
	var live := 0
	for fx in fxs:
		if is_instance_valid(fx) and not (fx as Node).is_queued_for_deletion():
			live += 1
			(fx as Node).tree_exiting.connect(func() -> void:
				print("EFFECTS aura %s: an effect gone %d ms after its end (frame %d)" % [key,
					Time.get_ticks_msec() - at, Engine.get_frames_drawn()]), CONNECT_ONE_SHOT)
	print("EFFECTS aura %s ended: %d effect(s) drawing (frame %d)" % [key, live, Engine.get_frames_drawn()])

static func _alive_models(a: Dictionary) -> Array:
	var out: Array = []
	for m in a.get("models", []):
		if is_instance_valid(m) and not (m as Node).is_queued_for_deletion():
			out.append(m)
	return out

static func _release_models(models: Array) -> void:
	for m in models:
		if is_instance_valid(m):
			(m as AuraModel).release()

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
	var models: Array = []
	if not _valid(host):
		return started
	# Round 856: the decoration's colour (SCT_MAT) is no effect: the Effect
	# Quality option does not refuse it.
	warm()
	var mat := mat_of(rows_in(SkillAudio._skills, _rows, skill_id, SkillAudio.ACT_L, -1, true))
	var rows: Array = rows_for(skill_id, SkillAudio.ACT_L, -1) if wants_effect(null, null, host) else []
	for r in rows:
		# Round 838: an aura's .bsr rows (the mall balloons, 65 AT_LOOP rows,
		# and the archive's mall visuals, MEASURED) are models kept on the
		# bone until the buff ends (AuraModel; round 809 drew none).
		if int(r.get("kind", KIND_EFP)) == KIND_BSR:
			if kept_act(int(r["act"])):
				var m := AuraModel.spawn(String(r["path"]), host, String(r["bone"]), r["offset"])
				if m != null:
					models.append(m)
			continue
		if int(r.get("kind", KIND_EFP)) != KIND_EFP:
			continue
		var fx := _make(String(r["path"]))
		if fx == null:
			continue
		if fx.draw_count() == 0 and _draws_nothing(fx):
			fx.free()
			continue
		fx.loop = kept_act(int(r["act"]))
		fx.static_host = int(r["act"]) == AT_STOP
		fx.reserved = own_body != null and host == own_body
		fx.end_fade_ms = end_fade_ms_of(r)
		attach(fx, host, String(r["bone"]), r["offset"], int(r.get("rotate", 0)))
		started.append(fx)
	if not started.is_empty() or not models.is_empty() or not mat.is_empty():
		var now := now_ms if now_ms >= 0 else _now()
		_auras[_aura_key(owner_key, token)] = {"fx": started, "models": models, "host": host, "skill": skill_id,
			"expires": now + remaining_ms + AURA_GRACE_MS if remaining_ms > 0 else -1}
		_deco_colour_on(_auras[_aura_key(owner_key, token)], mat,
			rows_in(SkillAudio._skills, _rows, skill_id, SkillAudio.ACT_L, -1, true))
		print("EFFECTS aura on %s token %d: skill %d, %d effect(s), %d model(s)%s" % [owner_key, token, skill_id,
			started.size(), models.size(), ", colour %s -> %s every %d ms" % [mat["c1"], mat["c2"], mat["ms"]] if not mat.is_empty() else ""])
	return started

## Round 856: a kept decoration's colour goes on its body (+0x48, READ
## FUN_00a513a0; the header) and the aura `a` remembers it, with the ms its
## end fades over (the rows' longest Fade: the decoration is freed then).
static func _deco_colour_on(a: Dictionary, mat: Dictionary, rows: Array) -> void:
	if mat.is_empty():
		return
	var fade := 0
	for r in rows:
		fade = maxi(fade, end_fade_ms_of(r))
	a["mat"] = mat
	a["mat_fade"] = fade
	BodyPulse.start(a["host"], mat["c1"], mat["c2"], float(mat["ms"]), DECO_WHO)

## Round 856: a kept decoration ends: its colour goes off (+0x4c, whoever
## set it last; CIDecoSkill::FUN_00a53dd0) once its fade is over -- at once
## for a fade of 0 or a teardown (`now_ms` < 0 with `at_once`).
static func _deco_colour_off(a: Dictionary, now_ms: int, at_once: bool = false) -> void:
	if (a.get("mat", {}) as Dictionary).is_empty():
		return
	a["mat"] = {}
	var host = a.get("host")
	var fade := int(a.get("mat_fade", 0))
	if at_once or fade <= 0:
		BodyPulse.stop(host)
		return
	_colour_ends.append({"host": host, "at": now_ms + fade})

## Round 856: decoration colours whose end waits for their fade:
## {host, at (the clock's ms)}.
static var _colour_ends: Array = []

static func _step_colour_ends(now: int) -> void:
	var i := 0
	while i < _colour_ends.size():
		var e: Dictionary = _colour_ends[i]
		if now >= int(e["at"]):
			var host = e["host"]
			if host != null and is_instance_valid(host):
				BodyPulse.stop(host)
			_colour_ends.remove_at(i)
		else:
			i += 1

## The rows of an effect id that is no skill's (a SYSTEM_ or PARAM_ decoration,
## StateLook) for one phase.
static func rows_named(effect_id: String, ani_type: int, bare := false) -> Array:
	warm()
	var out: Array = []
	for r in _rows.get(effect_id, []):
		if int(r["ani"]) == ani_type and (bare or has_effect(r)):
			out.append(r)
	return out

## Plays an effect id's rows of one phase on `host` (each at its own bone):
## its AT_LOOP rows loop and are kept as the aura of (owner_key, token) when
## `owner_key` is given; the rest play once. Returns the effects started.
static func play_named(effect_id: String, ani_type: int, host: Node3D, owner_key: String = "",
		token: int = 0) -> Array:
	var started: Array = []
	if not _valid(host):
		return started
	# Round 856: a kept decoration's colour (SCT_MAT, PARAM_STONE's), not
	# refused by the Effect Quality option.
	var mat := mat_of(rows_named(effect_id, ani_type, true)) if owner_key != "" else {}
	var kept: Array = []
	for r in rows_named(effect_id, ani_type) if wants_effect(null, null, host) else []:
		# Round 809: a .bsr object is a cast's (play_phase), not a state's.
		if int(r.get("kind", KIND_EFP)) != KIND_EFP:
			continue
		var fx := _make(String(r["path"]))
		if fx == null:
			continue
		if fx.draw_count() == 0 and _draws_nothing(fx):
			fx.free()
			continue
		fx.loop = kept_act(int(r["act"]))
		fx.static_host = int(r["act"]) == AT_STOP
		fx.reserved = own_body != null and host == own_body
		fx.end_fade_ms = end_fade_ms_of(r)
		attach(fx, host, String(r["bone"]), r["offset"], int(r.get("rotate", 0)))
		started.append(fx)
		if fx.loop:
			kept.append(fx)
	if owner_key != "" and (not kept.is_empty() or not mat.is_empty()):
		detach_aura(owner_key, token)
		_auras[_aura_key(owner_key, token)] = {"fx": kept, "host": host, "skill": -1, "expires": -1}
		_deco_colour_on(_auras[_aura_key(owner_key, token)], mat, rows_named(effect_id, ani_type, true))
	if not started.is_empty() or not mat.is_empty():
		print("EFFECTS %s %s on %s: %d effect(s)%s" % [effect_id, SkillAudio._phase_name(ani_type),
			owner_key if owner_key != "" else str(host.name), started.size(),
			", colour %s -> %s every %d ms" % [mat["c1"], mat["c2"], mat["ms"]] if not mat.is_empty() else ""])
	return started

## Round 859 (lane B): a system decoration started with its end flag set
## (READ, FUN_00a53850's fifth argument: the level-up c:0x8a7020, the pet's
## level-up and summon c:0x9c5d20 pass 1): its ACT_S rows, then its ACT_L
## rows, play on `host`, and the decoration ends at once (c:0x00a53c03 ->
## FUN_00a53120), so a kept (AT_LOOP) row is let go there and plays its last
## cycle out, faded over its row's Fade (_end_kept). Returns the effects.
static func play_system(effect_id: String, host: Node3D) -> Array:
	var started := play_named(effect_id, SkillAudio.ACT_S, host)
	started.append_array(play_named(effect_id, SkillAudio.ACT_L, host))
	var kept: Array = []
	for fx in started:
		if is_instance_valid(fx) and (fx as EfpEffect).loop:
			kept.append(fx)
	if not kept.is_empty():
		_end_kept(kept)
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
	for m in _alive_models(a):
		if host.is_ancestor_of(m):
			return true
	# Round 856: a decoration whose colour is all it draws.
	return not (a.get("mat", {}) as Dictionary).is_empty()

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
		_note_end(key, _auras[key]["fx"])
		for fx in _auras[key]["fx"]:
			if is_instance_valid(fx):
				n += 1
		# Round 785 / 847 (READ, FUN_00a53120 -> FUN_00a4ffe0 ->
		# FUN_00a4db00): the buff's or the state's end lets its aura go and
		# fades it out over its row's Fade (_end_kept).
		_end_kept(_auras[key]["fx"])
		# Round 838: its models go with it (AuraModel).
		var models := _alive_models(_auras[key])
		_release_models(models)
		n += models.size()
		# Round 856: and its colour, once its fade is over.
		_deco_colour_off(_auras[key], _now())
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
		for m in _alive_models(_auras[key]):
			(m as Node).queue_free()
		_deco_colour_off(_auras[key], _now(), true)
	_auras.clear()
	for e in _colour_ends:
		if e["host"] != null and is_instance_valid(e["host"]):
			BodyPulse.stop(e["host"])
	_colour_ends.clear()
	for f in _flights:
		if is_instance_valid(f["fx"]):
			(f["fx"] as EfpEffect).stop()
		if _valid(f["carrier"]):
			(f["carrier"] as Node).queue_free()
		for t in f.get("trail", []):
			if is_instance_valid(t):
				(t as EfpEffect).stop()
	_flights.clear()
	for l in _lingers:
		_stop_all(l["fx"])
		if _valid(l["carrier"]):
			(l["carrier"] as Node).queue_free()
	_lingers.clear()
	BsrEffect.clear()
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
