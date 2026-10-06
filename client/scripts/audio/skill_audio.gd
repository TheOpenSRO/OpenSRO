extends RefCounted
class_name SkillAudio

## A skill's sound identity and its cast sounds (round 614).
##
## 1. CONTEXT -- which Basic_Code and Basic_Group a skill keys its sounds by.
##    Every skill-keyed effectsound handler (snd_dmg, snd_cridmg, snd_activate,
##    snd_swing_s*, voc_shout*) asks GEffSound::FUN_00a65180 (READ): from the
##    skill record it follows the +0x5c link until that link is 0 and returns
##    the last record's Basic_Group (+0x44, arg 1) or Basic_Code (+0xc, arg 0),
##    or L"-" (DAT_00d81ea0) with no skill. The link is skilldata column 7
##    (1-based; Basic_Original): INFERRED -- GSKILL_CH_SWORD_BASE_001..005 carry
##    2, the id of SKILL_CH_SWORD_BASE_01, and every China mastery skill 0
##    (MEASURED on the box's six tables). Columns here are 0-based: 1 ID,
##    3 Basic_Code, 5 Basic_Group, 6 Basic_Original (the spec's 1-based 4 and 6
##    are these 3 and 5).
##
##    THE API FOR THE ANIMATION-FIRED SOUNDS (the audio_anim lane): a `.bsr`
##    track fires snd_swing_s1/2 and voc_shout1/2 on the playing clip, and those
##    handlers key by the object's CURRENT skill (vslot_009 with arg 0 uses
##    FUN_009ce0d0, the object's current skill, READ). World3D records it here
##    whenever the player starts a cast or a plain swing:
##      SkillAudio.set_current(obj: Object, skill_id: int)
##      SkillAudio.current_skill(obj: Object) -> int            # 0 = none
##      SkillAudio.context_for(skill_id: int) -> {"id", "code", "group"}
##      SkillAudio.context_of(obj: Object) -> the same, for the current skill
##    "code"/"group" are "-" when the skill is unknown or 0, exactly as retail
##    hands a handler L"-". A plain swing's skill is the weapon's base attack
##    (CombatAudio.base_attack_skill). Monsters: OpenSRO's server names no
##    monster attack skill, so nothing records one and a monster's context is
##    "-" (OPEN until the server sends it).
##
## 2. CAST SOUNDS -- skilleffect.txt `#section skilleffectset` (UTF-16,
##    Media.pk2 server_dep\silkroad\textdata\), one row per effect a skill
##    phase spawns. Columns (0-based, named by the file's own header line,
##    READ): 1 SkillEffectID, 2 AniType, 3 StartEvent, 26 SndBegin,
##    27 SndEnd. The loader (GlobalEffectManager::FUN_00a9d0f0, READ) files a
##    row under its skill at +0xbc + AniType*4 (AniType < 10, asserted as
##    `SETOE.m_byAniType < MAX_SKILL_EFF_TABLE`) and then by StartEvent.
##    The AniType names are the table at 0xec7158 (READ):
##      READY 0, WAIT 1, SHOT 2, ACT_OS 3, ACT_OL 4, ACT_OE 5, ACT_S 6,
##      ACT_L 7, DEACT 8, S_RETURN 9.
##    IDecoSkill::FUN_00a4fe70 plays a triggered row's +0x98 and then its
##    +0x9c path, in the same call, through the sound manager's play-a-file
##    slot (+0x30) at the caster (+0x58 -> +0x90) at volume 1.0 (0x3f800000)
##    when the row's ushort +0x10 is 0, and queues both on the decoration's
##    moving-object list with the caster's position when it is not -- READ.
##    +0x98/+0x9c are SndBegin/SndEnd (the last two dwords of the 0xa0-byte
##    row the loader fills in column order; review of round 614). So SndEnd is
##    NOT an "end of phase" sound: it plays with SndBegin, at the same moment.
##    Which column +0x10 is was not read; this client plays every row at once
##    (OURS).
##    A row counts when EITHER column names a file: 991 rows carry a
##    SndBegin, 187 a SndEnd, 150 of them with SndBegin "none" (MEASURED, rows
##    of a named AniType). Every one of the 179 distinct SndBegin and 20
##    distinct SndEnd values exists as Data.pk2 "prim\snd\" + the value.
##    WHICH SKILL A ROW BELONGS TO: the SkillEffectID is a skill's Basic_Group
##    for 249 of the 287 SKILL_CH_ ids and its Basic_Code for 4 (the _BASE_01
##    attacks); the rest name skills outside the six tables read (MEASURED).
##    So a skill's rows are looked up by its group, then by its code, after the
##    one +0x5c step FUN_00a95dc0 takes (INFERRED order; no id is both).
##    WHEN A PHASE FIRES in this client (INFERRED / OURS -- retail's per-phase
##    triggers run off the server's skill-action messages and the clip's
##    events, which OpenSRO does not have):
##      cast start (the cast clip starts and OpUseSkill is sent):
##          READY, and SHOT rows of StartEvent 0      (INFERRED)
##      the blow lands (the swing's hit event, when the number shows):
##          SHOT rows of StartEvent 1                  (INFERRED)
##      the server accepts the cast (the same moment):
##          ACT_S and ACT_L, beside snd_activate -- FUN_00a53850 triggers the
##          rows of AniType 3+s and 4+s with s = 3 (ACT_S/ACT_L) or 0
##          (ACT_OS/ACT_OL) and then fires snd_activate (READ); which s a
##          self-cast takes is INFERRED (ACT_S/ACT_L are 1,418 of the 1,452
##          rows of those four types, MEASURED)
##      left out, OPEN: WAIT (a charge phase), SHOT of StartEvent >= 2 (later
##          clip events, whose times this client does not know; no China
##          skill has one, MEASURED), ACT_OS/ACT_OL/ACT_OE, DEACT, S_RETURN.
##      A fired row plays its SndBegin and then its SndEnd (READ, above).

const SKILLEFFECT_PATH := "server_dep\\silkroad\\textdata\\skilleffect.txt"
const EFFECT_SECTION := "skilleffectset"
const SOUND_PREFIX := "prim\\snd\\"
const NONE := "-"

## AniType values (the name table at 0xec7158, READ).
const READY := 0
const WAIT := 1
const SHOT := 2
const ACT_OS := 3
const ACT_OL := 4
const ACT_OE := 5
const ACT_S := 6
const ACT_L := 7
const DEACT := 8
const S_RETURN := 9
const ANI_TYPES := {
	"READY": READY, "WAIT": WAIT, "SHOT": SHOT, "ACT_OS": ACT_OS, "ACT_OL": ACT_OL,
	"ACT_OE": ACT_OE, "ACT_S": ACT_S, "ACT_L": ACT_L, "DEACT": DEACT, "S_RETURN": S_RETURN,
}

## skilldata columns, 0-based.
const S_ID := 1
const S_BASIC_CODE := 3
const S_BASIC_GROUP := 5
const S_BASIC_ORIGINAL := 6

## skilleffectset columns, 0-based; SndBegin is re-read from the header line.
const E_ID := 1
const E_ANI_TYPE := 2
const E_START_EVENT := 3
const E_SND_BEGIN := 26
const E_SND_END := 27

# The tables, loaded once on first use from Media.pk2 (set_tables in tests).
static var _skills: Dictionary = {}          # id -> PackedStringArray [code, group, original]
static var _effects: Dictionary = {}         # SkillEffectID -> Array of [ani_type, start_event, path]
static var _loaded := false
static var _current: Dictionary = {}         # object instance id -> skill id

# --- parsing (pure) ---------------------------------------------------------

## skilldata_*.txt bytes -> id -> [Basic_Code, Basic_Group, Basic_Original].
## Rows whose ID is not a number (headers, comments) are skipped.
static func parse_skills(bytes: PackedByteArray, into: Dictionary = {}) -> Dictionary:
	for line in _utf16_lines(bytes):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t", true, S_BASIC_ORIGINAL + 1)
		if cols.size() <= S_BASIC_ORIGINAL:
			continue
		var id_text := cols[S_ID].strip_edges()
		if not id_text.is_valid_int():
			continue
		into[int(id_text)] = PackedStringArray([cols[S_BASIC_CODE].strip_edges(),
			cols[S_BASIC_GROUP].strip_edges(), cols[S_BASIC_ORIGINAL].strip_edges()])
	return into

## skilleffect.txt bytes -> SkillEffectID -> Array of [ani_type, start_event,
## SndBegin path, SndEnd path] ("prim\snd\..." lowercased, "" for none), only
## rows of `#section skilleffectset` where either column names a file.
static func parse_effect_sounds(bytes: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	var in_section := false
	var begin_col := E_SND_BEGIN
	var end_col := E_SND_END
	for raw in _utf16_lines(bytes):
		var line: String = raw
		if line.begins_with("#section"):
			var parts := line.replace("\t", " ").split(" ", false)
			in_section = parts.size() >= 2 and parts[1] == EFFECT_SECTION
			continue
		if not in_section:
			continue
		if line.begins_with("//"):
			var header := line.substr(2).split("\t")
			var at := header.find("SndBegin")
			if at >= 0:
				begin_col = at
				var at_end := header.find("SndEnd")
				end_col = at_end if at_end >= 0 else at + 1
			continue
		var cols := line.split("\t")
		if cols.size() <= begin_col:
			continue
		var id := cols[E_ID].strip_edges()
		var ani := cols[E_ANI_TYPE].strip_edges()
		var begin := _sound_path(cols[begin_col])
		var end := _sound_path(cols[end_col]) if cols.size() > end_col else ""
		if id == "" or not ANI_TYPES.has(ani) or (begin == "" and end == ""):
			continue
		var start_text := cols[E_START_EVENT].strip_edges()
		var start_event := int(start_text) if start_text.is_valid_int() else 0
		if not out.has(id):
			out[id] = []
		(out[id] as Array).append([int(ANI_TYPES[ani]), start_event, begin, end])
	return out

## A sound column as a Data.pk2 path, or "" for an empty or "none" cell.
static func _sound_path(cell: String) -> String:
	var v := cell.strip_edges()
	if v == "" or v.to_lower() == "none":
		return ""
	return (SOUND_PREFIX + v).to_lower()

static func _utf16_lines(bytes: PackedByteArray) -> PackedStringArray:
	if bytes.is_empty():
		return PackedStringArray()
	var raw := bytes
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
		return raw.get_string_from_utf16().replace("\r", "").split("\n")
	return raw.get_string_from_utf8().replace("\r", "").split("\n")

# --- lookups (pure, against given tables) -----------------------------------

## The record FUN_00a65180 ends on, as it walks (READ): while the id is not
## negative and names a record, take that record's link; a link of 0 ends
## the walk on that record. An id that is negative or names no record --
## the start or any link on the way -- ends it with L"-", here -1. So a
## skill whose Basic_Original dangles keys as "-", not by its own names.
## A cycle would never end in retail; the guard here gives -1 (OURS).
static func root_id(skills: Dictionary, id: int) -> int:
	var at := id
	for _i in range(16):
		if at < 0 or not skills.has(at):
			return -1
		var link_text: String = (skills[at] as PackedStringArray)[2]
		var link := int(link_text) if link_text.is_valid_int() else 0
		if link == 0:
			return at
		at = link
	return -1

## {"id", "code", "group"} for a skill id against `skills`; "-" for unknown.
static func context_in(skills: Dictionary, skill_id: int) -> Dictionary:
	var root := root_id(skills, skill_id) if skill_id > 0 else -1
	if root < 0:
		return {"id": skill_id, "code": NONE, "group": NONE}
	var row: PackedStringArray = skills[root]
	return {"id": skill_id, "code": row[0] if row[0] != "" else NONE,
		"group": row[1] if row[1] != "" else NONE}

## The paths of `skill_id`'s rows of one phase (and StartEvent, or any with
## -1): each row's SndBegin, then its SndEnd, in file order.
static func sounds_in(skills: Dictionary, effects: Dictionary, skill_id: int, ani_type: int,
		start_event: int = -1) -> PackedStringArray:
	var out := PackedStringArray()
	for row in effect_rows_in(skills, effects, skill_id):
		if int(row[0]) == ani_type and (start_event < 0 or int(row[1]) == start_event):
			for i in [2, 3]:
				if String(row[i]) != "":
					out.append(String(row[i]))
	return out

## All sound rows (SndBegin and/or SndEnd) for a skill: by its group, else its code, after one
## Basic_Original step (FUN_00a95dc0).
static func effect_rows_in(skills: Dictionary, effects: Dictionary, skill_id: int) -> Array:
	if not skills.has(skill_id):
		return []
	var id := skill_id
	var link_text: String = (skills[id] as PackedStringArray)[2]
	if link_text.is_valid_int() and int(link_text) != 0 and skills.has(int(link_text)):
		id = int(link_text)
	var row: PackedStringArray = skills[id]
	if effects.has(row[1]):
		return effects[row[1]]
	if effects.has(row[0]):
		return effects[row[0]]
	return []

# --- the loaded tables -------------------------------------------------------

## Loads the tables from Media.pk2 if not yet loaded. Cheap after the first
## call; World3D calls it while the world loads so the first blow does not
## pay for it.
static func warm() -> void:
	if _warm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_warm_task)
		_warm_task = -1
	if _loaded:
		return
	_warm_now()

## Round 746: warm() on a worker. The skilldata parts are now every one the
## index names (47, 47.5 MB against 26.0 MB), so the read leaves the main
## thread; warm() waits for it.
static func warm_async() -> void:
	if _loaded or _warm_task >= 0:
		return
	_warm_task = WorkerThreadPool.add_task(func() -> void:
		SkillAudio._warm_now(), false, "skill audio tables")

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
	var skills: Dictionary = {}
	# Both races' skill files (round 691): a Europe cast keys its sound and
	# effect rows by its id like a China one, so its rows must be read too.
	# Every part the archive's skilldata.txt names (round 746).
	for path in SkillDataReader.all_tables(AudioBank._archive("media")):
		parse_skills(AudioBank.read_table("media", path), skills)
	_skills = skills
	_effects = parse_effect_sounds(AudioBank.read_table("media", SKILLEFFECT_PATH))
	var rows := 0
	for k in _effects:
		rows += (_effects[k] as Array).size()
	print("AUDIO skills: %d skill rows, %d sound rows (SndBegin/SndEnd) under %d effect ids (%d ms)" % [
		_skills.size(), rows, _effects.size(), Time.get_ticks_msec() - t0])

## Test seam: use these tables instead of the archive's.
static func set_tables(skills: Dictionary, effects: Dictionary) -> void:
	_skills = skills
	_effects = effects
	_loaded = true
	_current.clear()

static func context_for(skill_id: int) -> Dictionary:
	warm()
	return context_in(_skills, skill_id)

static func sounds_for(skill_id: int, ani_type: int, start_event: int = -1) -> PackedStringArray:
	warm()
	return sounds_in(_skills, _effects, skill_id, ani_type, start_event)

static func effect_rows(skill_id: int) -> Array:
	warm()
	return effect_rows_in(_skills, _effects, skill_id)

## Records `skill_id` as the object's current skill (0 clears it).
static func set_current(obj: Object, skill_id: int) -> void:
	if obj == null:
		return
	if skill_id == 0:
		_current.erase(obj.get_instance_id())
	else:
		_current[obj.get_instance_id()] = skill_id

static func current_skill(obj: Object) -> int:
	return int(_current.get(obj.get_instance_id(), 0)) if obj != null else 0

static func context_of(obj: Object) -> Dictionary:
	return context_for(current_skill(obj))

# --- firing ------------------------------------------------------------------

## Plays the SndBegin, then the SndEnd, of `skill_id`'s rows of one phase at `caster`, each as
## a file at volume 1.0, and logs each. `start_event` -1 = every StartEvent.
## Returns the paths played.
static func play_phase(skill_id: int, ani_type: int, start_event: int, caster: Node3D,
		what: String) -> PackedStringArray:
	var paths := sounds_for(skill_id, ani_type, start_event)
	var name := _phase_name(ani_type)
	for p in paths:
		SoundTable.play_file(p, caster.global_position if caster != null and is_instance_valid(caster) \
			and caster.is_inside_tree() else null)
		AudioLog.line("cast:%d:%s:%s" % [skill_id, name, p], "AUDIO cast %s/%d: %s for skill %d %s (%s)" % [
			name, start_event, p, skill_id, str(context_for(skill_id)["group"]), what])
	return paths

## The rows this client never fires (see the header), for one log line per
## skill so a run shows what was left out.
static func unplayed_rows(skill_id: int) -> Array:
	var out: Array = []
	for row in effect_rows(skill_id):
		var ani := int(row[0])
		var fired := ani == READY or ani == ACT_S or ani == ACT_L or (ani == SHOT and int(row[1]) <= 1)
		if not fired:
			var paths := PackedStringArray()
			for i in [2, 3]:
				if String(row[i]) != "":
					paths.append(String(row[i]))
			out.append("%s/%d %s" % [_phase_name(ani), int(row[1]), " + ".join(paths)])
	return out

static func _phase_name(ani_type: int) -> String:
	for k in ANI_TYPES:
		if int(ANI_TYPES[k]) == ani_type:
			return k
	return str(ani_type)
