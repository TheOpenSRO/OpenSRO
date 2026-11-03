extends RefCounted
class_name ItemUseEffect

## What using an item looks and sounds like (round 859): the red swirl of an
## HP potion, the blue of an MP potion, the vigor potion's, the pills' water
## cure, a scroll's ring, a pet potion's -- on the user's body, for the user
## and for every player around, and the potion's sound for the user.
## Labels: READ (sro_client.exe / SR_GameServer.exe), MEASURED (the box's
## Media.pk2), INFERRED, OURS, OPEN. docs/protocol/item_use_effects.md has the
## whole record.
##
## WHO IS TOLD (READ, server): Item_HandleUseItem (s:0x510980) sends, after
## every accepted 0xB04C, 0x305C {u32 the user's uid, u32 the item's RefItemID}
## through GObjPC::FUN_00484d90 -- every PC in the user's 3 x 3, the user
## included. Nothing gates it by kind. A pet potion used from the bag goes the
## same way, so its 0x305C names the PLAYER: the original draws a pet potion's
## effect on the player, not on the pet.
##
## WHICH EFFECT (READ, client: 0x305C's handler NetProcessInInner::
## FUN_008735d0). It reads the two u32s and returns at once when the item is
## ITEM_ETC_AUTOMOB (the ref the loader keeps at DAT_00eeeb7c, c:0x83b197) or
## the uid names no object. Then, in order:
##  1. FUN_0095d950(2, code name): itemeffect.txt's `#section itemcodename`
##     rows of state 2 (use) for the item's code name -- when one matches, its
##     effect is started (FUN_00a950a0 -> FUN_00a54020) and nothing else is.
##  2. by the type word (FUN_00666d70 / 666de0 / 666e10 / 666ce0 and
##     FUN_00871e20 / 60 / a0, all `TypeID1 3, TypeID2 3` tests):
##       3/3/3 (any scroll)            0x80000004 SYSTEM_RETURNSCROLL
##       3/3/1/1 HP potions            0x80000001 SYSTEM_HPPOTION
##       3/3/1/2 MP potions            0x80000002 SYSTEM_MPPOTION
##       3/3/1/3 vigor potions         0x80000003 SYSTEM_LIFE
##       3/3/1/4 COS HP potions        0x80000023 SYSTEM_COS_HPPOTION
##       3/3/1/5                       0x80000024 SYSTEM_COS_MPPOTION
##       3/3/1/9 the HGP potion        0x80000025 SYSTEM_COS_HGPPOTION
##       3/3/2/1 or 6 (the pills)      "PARAM_CURE_ALL" (FUN_00a950a0)
##       3/3/2/7 the pet's pill        "STATUS_CURE_COS"
##     (the ids' names: the client's table at 0x00ec73f8, READ);
##  3. 3/3/6 (the fireworks): FUN_00ba36d0 makes a firework object -- not an
##     effect on the body (OPEN here: OpenSRO's server does not use fireworks);
##  4. otherwise, when step 2 started nothing: the item's own code name as an
##     effect id (FUN_00a950a0(code)) -- the hwan potions' and scrolls' rows.
## A name the effect table does not hold starts nothing.
##
## HOW IT PLAYS (READ): FUN_00a54020(0, obj, key, 0, 1, 0) -> FUN_00a53850
## starts the effect's ACT_S (start) and ACT_L (sustained) rows on the object,
## fires snd_activate with the negative key (no effectsound row, silent), and,
## for its fifth argument 1 (c:0xa53bfb `cmp [esp+0x48],edi`), ends the
## decoration at once (FUN_00a53120): an AT_LOOP row's effect is let go
## (EfpEffect.release, slot 4 with 0) and plays its cycle out. Each started row
## plays its SndBegin and SndEnd at the body (IDecoSkill::FUN_00a4fe70, round
## 614) -- the potions' rows have none (MEASURED); the hwan rows play
## UI\HyanGet.wav, the Nasrun ones Avatar_Nasrun1_Awake1.wav.
##
## THE POTION SOUND is not the effect's: Item_OnUseItemResult (0xB04C,
## c:0x87ac14) plays snd_potion for an accepted 3/3/1 or 3/3/2 -- the user's
## own client only (UiSounds.use_replied, round 615).

const ITEMEFFECT_PATH := "server_dep\\silkroad\\textdata\\itemeffect.txt"
const SECTION_CODE := "itemcodename"
## itemeffect.txt's state column: 0 equip, 1 unequip, 2 use, 3 time-out
## (MEASURED: the Nasrun rows' _EQUIP / _UNEQUIP / _AWAKE / _TIMEOUT names);
## 0x305C asks for 2 (FUN_0095d950(2, ...), READ).
const STATE_USE := 2
## The item 0x305C's handler ignores (READ, c:0x83b0f5 names it).
const AUTOMOB_CODE := "ITEM_ETC_AUTOMOB"

const RETURN_SCROLL := "SYSTEM_RETURNSCROLL"
const BY_POTION := {1: "SYSTEM_HPPOTION", 2: "SYSTEM_MPPOTION", 3: "SYSTEM_LIFE",
	4: "SYSTEM_COS_HPPOTION", 5: "SYSTEM_COS_MPPOTION", 9: "SYSTEM_COS_HGPPOTION"}
const BY_CURE := {1: "PARAM_CURE_ALL", 6: "PARAM_CURE_ALL", 7: "STATUS_CURE_COS"}
## What step 3 returns: the firework object, not drawn here (OPEN).
const FIREWORK := "<firework>"

## itemeffect.txt bytes -> {code name: effect id} of its `itemcodename` rows
## of `state` (the use rows by default).
static func parse_use_rows(bytes: PackedByteArray, state: int = STATE_USE) -> Dictionary:
	var out := {}
	var section := ""
	for raw in SkillAudio._utf16_lines(bytes):
		var line: String = raw.strip_edges(false, true)
		if line.begins_with("#section"):
			var parts := line.replace("\t", " ").split(" ", false)
			section = parts[1] if parts.size() >= 2 else ""
			continue
		if section != SECTION_CODE or line.begins_with("//") or line.strip_edges() == "":
			continue
		var cols := line.split("\t")
		if cols.size() < 3 or not cols[2].strip_edges().is_valid_int() or int(cols[2]) != state:
			continue
		var code := cols[0].strip_edges()
		if code != "" and not out.has(code):
			out[code] = cols[1].strip_edges()
	return out

## The effect id 0x305C's handler starts for an item (the header's steps), ""
## for none. `knows` answers whether an effect id names rows (FUN_00a950a0's
## lookup); `use_rows` is parse_use_rows' map; `automob` the
## ITEM_ETC_AUTOMOB ref (-1 unknown).
static func effect_id(types: PackedInt32Array, code: String, ref_id: int, automob: int,
		use_rows: Dictionary, knows: Callable) -> String:
	if ref_id == automob and automob >= 0:
		return ""
	if use_rows.has(code):
		var named := String(use_rows[code])
		return named if knows.call(named) else ""
	var id := ""
	if types.size() >= 4 and types[0] == 3 and types[1] == 3:
		match types[2]:
			3:
				id = RETURN_SCROLL
			1:
				id = String(BY_POTION.get(types[3], ""))
			2:
				id = String(BY_CURE.get(types[3], ""))
			6:
				return FIREWORK
	if id != "":
		return id if knows.call(id) else ""
	# Step 4: only when step 2 started nothing (the decoration's +0x60 empty,
	# c:0x8737c8) -- an id step 2 named that the table lacks
	# (SYSTEM_COS_MPPOTION, MEASURED: no rows) falls through too.
	return code if code != "" and knows.call(code) else ""

# --- the archive's tables ----------------------------------------------------

static var _use_rows: Dictionary = {}
static var _loaded := false

static func warm() -> void:
	if _loaded:
		return
	_loaded = true
	_use_rows = parse_use_rows(AudioBank.read_table("media", ITEMEFFECT_PATH))
	print("EFFECTS item use: %d itemeffect use row(s)" % _use_rows.size())

## Test seam.
static func set_use_rows(rows: Dictionary) -> void:
	_use_rows = rows
	_loaded = true

static func use_rows() -> Dictionary:
	warm()
	return _use_rows

## Whether an effect id names rows in skilleffect.txt: an effect row of the
## two phases FUN_00a53850 starts, or a sound row.
static func knows(effect: String) -> bool:
	if effect == "":
		return false
	if not SkillEffects.rows_named(effect, SkillAudio.ACT_S, true).is_empty() \
			or not SkillEffects.rows_named(effect, SkillAudio.ACT_L, true).is_empty():
		return true
	return not sounds_of(effect).is_empty()

## The SndBegin then SndEnd paths of an effect id's ACT_S and ACT_L rows, in
## row order (IDecoSkill::FUN_00a4fe70, READ: both at the start).
static func sounds_of(effect: String) -> PackedStringArray:
	SkillAudio.warm()
	var out := PackedStringArray()
	for row in SkillAudio._effects.get(effect, []):
		var ani := int(row[0])
		if ani != SkillAudio.ACT_S and ani != SkillAudio.ACT_L:
			continue
		for i in [2, 3]:
			if String(row[i]) != "":
				out.append(String(row[i]))
	return out

## Starts `effect` on `host` as FUN_00a54020(..., 0, 1, 0) does: the ACT_S and
## ACT_L rows, each let go at once (the decoration ends in the same call), and
## the rows' sounds at the body. Returns {"fx": effects started, "sounds":
## paths played}.
static func play(effect: String, host: Node3D, what: String = "") -> Dictionary:
	var fxs: Array = []
	var sounds := PackedStringArray()
	if effect == "" or effect == FIREWORK or host == null or not is_instance_valid(host):
		return {"fx": fxs, "sounds": sounds}
	fxs.append_array(SkillEffects.play_named(effect, SkillAudio.ACT_S, host))
	fxs.append_array(SkillEffects.play_named(effect, SkillAudio.ACT_L, host))
	for fx in fxs:
		if is_instance_valid(fx):
			(fx as EfpEffect).release()
	sounds = sounds_of(effect)
	for p in sounds:
		SoundTable.play_file(p, host.global_position if host.is_inside_tree() else null)
		AudioLog.line("itemuse:%s:%s" % [effect, p], "AUDIO item use %s: %s at %s (%s)" % [effect, p, host.name, what])
	return {"fx": fxs, "sounds": sounds}
