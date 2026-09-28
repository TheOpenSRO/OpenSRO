extends RefCounted
class_name CombatAudio

## The code-fired combat sounds (round 614): a blow's hit sound, a shield's
## block, a defensive skill's absorb and a skill's activation -- the keys the
## retail client builds for them, and one call per event that plays the first
## key the effect table has. Pure key builders, so a headless test can pin
## every key against synthetic rows.
##
## Labels as in docs/protocol/SOUND_FORMAT.md: READ (from sro_client.exe),
## MEASURED, INFERRED, OURS.
##
## WHO FIRES THEM (READ). All four go through the handle dispatcher
## CGEffSoundBody::vslot_009 (0xa72a70) as (handle, object, skill):
## - CIDecoDamageEffect::FUN_00a49780 -- the damage decoration's start:
##   `snd_cridmg` when the hit record's flag `& 2` is set, falling back to
##   `snd_dmg` when that handler returns 0; `snd_ddmg` instead when the
##   decoration's +100 flag is set. The object is `FUN_00517250(deco+0x70)`
##   (deco+0x74 for snd_ddmg); the skill is deco+0x6c.
## - FUN_00a47bf0 -- `snd_blocking` on the struck object when the damage
##   record's byte +9 is 2 (the block), skill 0.
## - FUN_00a53850 -- the skill decoration's activation (the same function
##   triggers the skilleffectset ACT_S/ACT_L rows): `snd_activate` on the
##   caster with the skill.
## WHICH SIDE deco+0x70 is: INFERRED the ATTACKER. The monster rows under
## snd_dmg are keyed by that monster's OWN attack skill
## (`MOB_MANGNYANG SND_DMG MSKILL_CH_MANGNYANG_ATTACK01`, MEASURED: all 212
## non-player snd_dmg rows carry a skill), and the player rows by the weapon
## and the skill group -- the striker's, not the struck's.
## WHERE IT PLAYS (READ): every one of these handlers plays at its object's
## own position (`FUN_00a64900(out, obj+0x90, ...)` in 0xa708f0, 0xa70410,
## 0xa70280, 0xa71c10). So a hit sounds at the ATTACKER (the inferred side
## above), a block at the blocker, an activation at the caster.
##
## THE KEYS (READ; handlers 0xa70410, 0xa708f0, 0xa70f30, 0xa70280, 0xa71c10):
## "PLAYER" is the object for a character whose refobj TypeID is a player
## character (bits &2, &0x1c==4, &0x60==0x20); anything else keys by its
## sound object, obj+0x664 (skilleffect.txt characterInfo, SoundTable.
## sound_object). `<group>` / `<code>` are the skill's Basic_Group /
## Basic_Code after its Basic_Original chain (GEffSound::FUN_00a65180;
## SkillAudio.context_for), "-" with no skill (the function's default,
## DAT_00d81ea0 = L"-", READ).
##   snd_cridmg  player:  PLAYER:snd_cridmg:-:-:-:-     (hwan: PLAYER:snd_cridmg:-:HWAN:-:-)
##               other:   <obj>:snd_cridmg:<code>:-:-:-
##   snd_dmg     player:  PLAYER:snd_dmg:<group>:-:-:-, and only when that
##                        key has no row, PLAYER:snd_dmg:<WEAPON>:-:NORMAL
##                        (hwan: PLAYER:snd_dmg:-:HWAN:-:-, alone)
##               other:   <obj>:snd_dmg:<code>:-:-:-
##   snd_ddmg    the same shapes as snd_dmg with handle snd_ddmg (0xa70f30)
##   snd_blocking player only: PLAYER:snd_blocking:-:-:<NORMAL|CRITYCAL>:-
##   snd_activate player only: PLAYER:snd_activate:<group>:-:-:-
## THE WEAPON KEY HAS FIVE TOKENS (READ, asm 0xa70b10-0xa70b43): it is the
## prefix "PLAYER:snd_dmg:" + FUN_00a648d0's token + ":-:NORMAL" (the wide
## literal at 0xde6534 is exactly ":-:NORMAL"), with no "-" for the skill
## column, so it is `PLAYER:snd_dmg:SWORD:-:NORMAL`. The table's weapon rows
## load as `PLAYER:snd_dmg:-:SWORD:-:NORMAL` (six tokens joined by ':', the
## loader 0xa75020), so the weapon fallback never finds a row, and the
## `- HWAN <weapon> -` rows are unreachable the same way. INFERRED from those
## reads: in retail every blow carries a skill -- the plain swing is the
## weapon's base-attack skill (BASE_ATTACK_SKILL) -- so the group key is what
## sounds, and the dead fallback went unnoticed. This client builds the keys
## exactly as retail does, dead ones included (audio_spec 5 and sec_B wrote
## the weapon key with six tokens; the asm says five).
## "Has no row" is exact: the play-by-key routine FUN_00a6f7f0 returns 0 only
## when the key is missing from the table; a culled or blank-skipped trigger
## returns 1 (READ), so it does not fall through.
## `hwan` is the berserk state, obj+0x2c2 == 1 (READ). `<WEAPON>` is the item
## in equipment slot 6 through FUN_00a64560 on its TypeID4, `PUNCH` with the
## slot empty (FUN_00a648d0) -- WEAPON_TOKENS below, READ; a TypeID4 the
## switch does not name gives "" (DAT_00e17460, READ).
## CRITYCAL on a block is chosen by `obj+0x441 & 2` (FUN_00a63560, READ);
## that this bit is the blocked blow's critical flag is INFERRED (the damage
## record's critical is the same bit 2 of its flags, CIDecoDamageEffect
## +0x78 and FUN_00a49290's camera shake).

const PLAYER := "PLAYER"
const NONE := "-"
const PUNCH := "PUNCH"

## FUN_00a64560's weapon switch (READ): equipment TypeID4 -> the event token.
## EUSWORD, which the table also names, is never produced, so its rows are
## dead (INFERRED, sec_B).
const WEAPON_TOKENS := {
	2: "SWORD", 7: "SWORD",
	3: "BLADE",
	4: "SPEAR",
	5: "TBLADE",
	6: "BOW",
	8: "TSWORD",
	9: "DUELAXE",
	10: "WAND", 15: "WAND",
	11: "STAFF",
	12: "CROSSBOW",
	13: "DAGGER",
	14: "HARP",
	16: "HAMMER",
}

## A plain swing's skill, by the weapon's TypeID4 (1 = bare hand): the retail
## SERVER's table g_DefaultAttackSkillByTID4, read by
## SkillBook::DefaultAttackSkillIDForWeaponTID (0x0059e650) -- READ in round
## 256 and kept in server/internal/combat/baseattack.go (BaseAttackSkillFor),
## which this mirrors. The server resolves the swing to this skill and the
## client's damage decoration carries it, so a plain hit keys by its
## Basic_Group (SKILL_CH_SWORD_BASE). srrevamp's OpAttackResult names no skill,
## so the client resolves it the same way from the weapon in hand.
const BASE_ATTACK_SKILL := {
	1: 1,  # SKILL_PUNCH_01
	2: 2, 3: 2,  # SKILL_CH_SWORD_BASE_01
	4: 40, 5: 40,  # SKILL_CH_SPEAR_BASE_01
	6: 70,  # SKILL_CH_BOW_BASE_01
	7: 8419,  # SKILL_EU_SWORD_BASE_01
	8: 8420,  # SKILL_EU_TSWORD_BASE_01
	9: 8421,  # SKILL_EU_AXE_BASE_01
	10: 10625,  # SKILL_EU_WAND_WARLOCK_BASE_01
	11: 9944,  # SKILL_EU_STAFF_BASE_01
	12: 9354,  # SKILL_EU_CROSSBOW_BASE_01
	13: 9355,  # SKILL_EU_DAGGER_BASE_01
	14: 11162,  # SKILL_EU_HARP_BASE_01
	15: 11526,  # SKILL_EU_WAND_CLERIC_BASE_01
}
## The TypeID4 the engine reports for an empty hand (baseattack.go).
const BARE_HAND_TYPE_ID4 := 1

## The plain swing's skill id for a weapon TypeID4 (0 = no weapon), or 0.
static func base_attack_skill(type_id4: int) -> int:
	return int(BASE_ATTACK_SKILL.get(type_id4 if type_id4 != 0 else BARE_HAND_TYPE_ID4, 0))

## The weapon token for the item in slot 6: `type_id4` of it, or PUNCH with
## no weapon (`has_weapon` false). An unnamed TypeID4 gives "".
static func weapon_token(type_id4: int, has_weapon: bool = true) -> String:
	if not has_weapon:
		return PUNCH
	return str(WEAPON_TOKENS.get(type_id4, ""))

## The keys a blow tries, in order: the first the table has is played and the
## rest are not. `critical` picks snd_cridmg first; `attacker_obj` is "PLAYER"
## for a player character, else its sound object; `group`/`code` are the
## skill's ("-" for none).
static func hit_keys(critical: bool, attacker_obj: String, hwan: bool, group: String,
		code: String, weapon: String) -> PackedStringArray:
	var out := PackedStringArray()
	if critical:
		out.append_array(cridmg_keys(attacker_obj, hwan, code))
	out.append_array(dmg_keys("snd_dmg", attacker_obj, hwan, group, code, weapon))
	return out

static func cridmg_keys(obj: String, hwan: bool, code: String) -> PackedStringArray:
	if obj == PLAYER:
		return PackedStringArray([SoundTable.make_key(PLAYER, "snd_cridmg", NONE, "HWAN" if hwan else NONE)])
	if obj == "":
		return PackedStringArray()
	return PackedStringArray([SoundTable.make_key(obj, "snd_cridmg", _token(code))])

## snd_dmg and snd_ddmg (0xa708f0 / 0xa70f30 build the same shapes).
static func dmg_keys(handle: String, obj: String, hwan: bool, group: String, code: String,
		weapon: String) -> PackedStringArray:
	if obj == PLAYER:
		if hwan:
			return PackedStringArray([SoundTable.make_key(PLAYER, handle, NONE, "HWAN")])
		return PackedStringArray([
			SoundTable.make_key(PLAYER, handle, _token(group)),
			weapon_dmg_key(handle, weapon),
		])
	if obj == "":
		return PackedStringArray()
	return PackedStringArray([SoundTable.make_key(obj, handle, _token(code))])

## Retail's weapon fallback, five tokens as built (see the header): the
## handle lowercased like every key the handlers build.
static func weapon_dmg_key(handle: String, weapon: String) -> String:
	return "%s:%s:%s:-:NORMAL" % [PLAYER, handle.to_lower(), weapon]

## The block key, or "" for a blocker that is not a player character (the
## handler plays nothing for one, READ).
static func block_key(blocker_obj: String, critical: bool) -> String:
	if blocker_obj != PLAYER:
		return ""
	return SoundTable.make_key(PLAYER, "snd_blocking", NONE, NONE, "CRITYCAL" if critical else "NORMAL")

## The activation key, or "" for a caster that is not a player character.
static func activate_key(caster_obj: String, group: String) -> String:
	if caster_obj != PLAYER:
		return ""
	return SoundTable.make_key(PLAYER, "snd_activate", _token(group))

## The first of `keys` the table has, or "" when it has none. `has` is the
## table lookup (SoundTable.has_key in the game, a dictionary in tests).
static func first_present(keys: PackedStringArray, has: Callable) -> String:
	for k in keys:
		if bool(has.call(k)):
			return k
	return ""

static func _token(s: String) -> String:
	return s if s != "" else NONE

# --- Firing (the game path) -------------------------------------------------

## Plays a blow's hit sound at the attacker and logs it. Returns the key that
## played, or "" when the table has none of the chain (logged too).
static func play_hit(critical: bool, attacker_obj: String, hwan: bool, group: String, code: String,
		weapon: String, at: Node3D, what: String) -> String:
	var keys := hit_keys(critical, attacker_obj, hwan, group, code, weapon)
	return _fire("crit" if critical else "hit", keys, at, what)

## A shield block on `blocker` (a player character).
static func play_block(blocker_obj: String, critical: bool, at: Node3D, what: String) -> String:
	var key := block_key(blocker_obj, critical)
	return _fire("block", PackedStringArray([key]) if key != "" else PackedStringArray(), at, what)

## A defensive skill that absorbed a blow (snd_ddmg). Nothing calls this yet:
## srrevamp's server has no absorbing skill, so the client never learns of
## such a blow (OPEN until one exists).
static func play_ddmg(defender_obj: String, hwan: bool, group: String, code: String, weapon: String,
		at: Node3D, what: String) -> String:
	return _fire("ddmg", dmg_keys("snd_ddmg", defender_obj, hwan, group, code, weapon), at, what)

## A skill's activation on its caster.
static func play_activate(caster_obj: String, group: String, at: Node3D, what: String) -> String:
	var key := activate_key(caster_obj, group)
	return _fire("activate", PackedStringArray([key]) if key != "" else PackedStringArray(), at, what)

static func _fire(kind: String, keys: PackedStringArray, at: Node3D, what: String) -> String:
	var key := first_present(keys, func(k: String) -> bool: return SoundTable.has_key(k))
	if key == "":
		AudioLog.line("%s:none:%s" % [kind, ",".join(keys)],
			"AUDIO %s: none of [%s] in the table -- silent (%s)" % [kind, ", ".join(keys), what])
		return ""
	SoundTable.play_key(key, null, at)
	AudioLog.line("%s:%s" % [kind, key], "AUDIO %s: %s at %s (%s)" % [kind, key, _where(at), what])
	return key

static func _where(at: Node3D) -> String:
	if at == null or not is_instance_valid(at) or not at.is_inside_tree():
		return "2-D"
	var p := at.global_position
	return "(%.0f, %.0f, %.0f)" % [p.x, p.y, p.z]
