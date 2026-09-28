extends SceneTree

## CombatAudio's keys for a hit, a critical, a block and an activation, against
## synthetic rows written here (never the game's table), run headless:
## `godot4 --headless --path client --script res://scripts/audio/combat_audio_test.gd`
##
## Loaded by path, so a checkout without the scripts prints FAIL lines.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var ca: GDScript = load("res://scripts/audio/combat_audio.gd")
	var st: GDScript = load("res://scripts/audio/sound_table.gd")
	_check(ca != null, "scripts/audio/combat_audio.gd exists (CombatAudio, the code-fired combat keys)")
	if ca == null or st == null:
		_wiring()
		_finish()
		return

	# The weapon token (FUN_00a64560) and the plain swing's skill.
	_check(ca.weapon_token(2) == "SWORD" and ca.weapon_token(7) == "SWORD", "TypeID4 2 and 7 are SWORD")
	_check(ca.weapon_token(6) == "BOW" and ca.weapon_token(15) == "WAND" and ca.weapon_token(16) == "HAMMER",
		"6 BOW, 15 WAND, 16 HAMMER")
	_check(ca.weapon_token(0, false) == "PUNCH", "an empty weapon slot is PUNCH")
	_check(ca.weapon_token(99) == "", "a TypeID4 the switch does not name gives \"\"")
	_check(ca.base_attack_skill(2) == 2 and ca.base_attack_skill(3) == 2, "sword and blade swing with skill 2")
	_check(ca.base_attack_skill(0) == 1, "an empty hand swings with skill 1 (TypeID4 1)")
	_check(ca.base_attack_skill(6) == 70 and ca.base_attack_skill(99) == 0, "a bow swings with 70; an unnamed type with none")

	# A plain hit by a player: the skill group first, then the weapon key.
	var hit: PackedStringArray = ca.hit_keys(false, "PLAYER", false, "TEST_SWING_BASE", "TEST_SWING_BASE_01", "TESTWPN")
	_check(hit.size() == 2 and hit[0] == "PLAYER:snd_dmg:TEST_SWING_BASE:-:-:-",
		"a hit tries PLAYER:snd_dmg:<group>:-:-:- first (%s)" % ",".join(hit))
	_check(hit.size() == 2 and hit[1] == "PLAYER:snd_dmg:TESTWPN:-:NORMAL",
		"then the weapon key, five tokens as the asm builds it (%s)" % (hit[1] if hit.size() > 1 else "none"))
	var no_skill: PackedStringArray = ca.hit_keys(false, "PLAYER", false, "", "", "TESTWPN")
	_check(no_skill.size() > 0 and no_skill[0] == "PLAYER:snd_dmg:-:-:-:-", "no skill keys the group as '-'")

	# A critical: snd_cridmg first, then the whole snd_dmg chain.
	var crit: PackedStringArray = ca.hit_keys(true, "PLAYER", false, "TEST_SWING_BASE", "TEST_SWING_BASE_01", "TESTWPN")
	_check(crit.size() == 3 and crit[0] == "PLAYER:snd_cridmg:-:-:-:-" and crit[1] == hit[0] and crit[2] == hit[1],
		"a critical tries PLAYER:snd_cridmg:-:-:-:- and then the hit's keys (%s)" % ",".join(crit))
	var hwan_crit: PackedStringArray = ca.hit_keys(true, "PLAYER", true, "TEST_SWING_BASE", "TEST_SWING_BASE_01", "TESTWPN")
	_check(hwan_crit.size() == 2 and hwan_crit[0] == "PLAYER:snd_cridmg:-:HWAN:-:-" and hwan_crit[1] == "PLAYER:snd_dmg:-:HWAN:-:-",
		"in berserk the critical and the hit use the HWAN keys alone (%s)" % ",".join(hwan_crit))

	# Anything that is not a player character keys by its sound object and
	# its skill's Basic_Code.
	var mob: PackedStringArray = ca.hit_keys(true, "TEST_MOB", false, "TEST_MOB_GROUP", "TEST_MOB_ATTACK01", "")
	_check(mob.size() == 2 and mob[0] == "TEST_MOB:snd_cridmg:TEST_MOB_ATTACK01:-:-:-" and mob[1] == "TEST_MOB:snd_dmg:TEST_MOB_ATTACK01:-:-:-",
		"a monster's critical keys <obj>:snd_cridmg:<code>, then <obj>:snd_dmg:<code> (%s)" % ",".join(mob))
	_check(ca.hit_keys(false, "", false, "-", "-", "").is_empty(), "no sound object, no key")

	# The block and the activation.
	_check(ca.block_key("PLAYER", false) == "PLAYER:snd_blocking:-:-:NORMAL:-", "a block is PLAYER:snd_blocking:-:-:NORMAL:-")
	_check(ca.block_key("PLAYER", true) == "PLAYER:snd_blocking:-:-:CRITYCAL:-", "a critical block uses the table's CRITYCAL")
	_check(ca.block_key("TEST_MOB", false) == "", "only a player character's block sounds")
	_check(ca.activate_key("PLAYER", "TEST_BUFF_A") == "PLAYER:snd_activate:TEST_BUFF_A:-:-:-", "activation keys by the group")
	_check(ca.activate_key("TEST_MOB", "TEST_BUFF_A") == "", "only a player character's activation sounds")
	var dd: PackedStringArray = ca.dmg_keys("snd_ddmg", "PLAYER", false, "TEST_WALL_A", "TEST_WALL_A_01", "TESTWPN")
	_check(dd.size() == 2 and dd[0] == "PLAYER:snd_ddmg:TEST_WALL_A:-:-:-", "snd_ddmg has snd_dmg's shapes (%s)" % ",".join(dd))

	# Against a table loaded by the real parser from synthetic rows: which key
	# plays. The weapon row loads with six tokens, so the five-token key the
	# handler builds never finds it -- the group row is what sounds.
	var text := ""
	text += "\tPLAYER\tSND_DMG\tTEST_SWING_BASE\t-\t-\t-\t0\tt\\\thit_group.wav\t100\r\n"
	text += "\tPLAYER\tSND_DMG\t-\tTESTWPN\t-\tNORMAL\t0\tt\\\thit_weapon.wav\t100\r\n"
	text += "\tPLAYER\tSND_CRIDMG\t-\t-\t-\t-\t0\tt\\\tcrit.wav\t100\r\n"
	text += "\tPLAYER\tSND_BLOCKING\t-\t-\tNORMAL\t-\t0\tt\\\tblock1.wav\t100\r\n"
	text += "\tPLAYER\tSND_BLOCKING\t-\t-\tCRITYCAL\t-\t0\tt\\\tblock2.wav\t100\r\n"
	text += "\tTEST_MOB\tSND_DMG\tTEST_MOB_ATTACK01\t-\t-\t-\t0\tt\\\tmob.wav\t100\r\n"
	var table: Dictionary = st.parse(text.to_ascii_buffer())
	var has := func(k: String) -> bool: return table.has(k)
	_check(ca.first_present(hit, has) == "PLAYER:snd_dmg:TEST_SWING_BASE:-:-:-", "a plain hit plays the group row")
	_check(ca.first_present(crit, has) == "PLAYER:snd_cridmg:-:-:-:-", "a critical plays the snd_cridmg row")
	_check(ca.first_present(no_skill, has) == "", "with no skill the weapon row is unreachable: silent")
	var crit_no_row: PackedStringArray = ca.hit_keys(true, "PLAYER", false, "TEST_SWING_BASE", "", "TESTWPN")
	table.erase("PLAYER:snd_cridmg:-:-:-:-")
	_check(ca.first_present(crit_no_row, has) == "PLAYER:snd_dmg:TEST_SWING_BASE:-:-:-",
		"a critical with no snd_cridmg row falls back to the hit")
	_check(ca.first_present(PackedStringArray([ca.block_key("PLAYER", true)]), has) == "PLAYER:snd_blocking:-:-:CRITYCAL:-",
		"the block key finds its row")
	_check(ca.first_present(mob, has) == "TEST_MOB:snd_dmg:TEST_MOB_ATTACK01:-:-:-", "a monster's hit finds its skill row")
	_check(ca.first_present(ca.hit_keys(false, "TEST_MOB", false, "-", "-", ""), has) == "",
		"a monster's hit with no skill finds nothing (the server names none)")
	_wiring()
	_finish()

## World3D fires them: the hooks the round added are in the source.
func _wiring() -> void:
	var f := FileAccess.open("res://scripts/World3D.gd", FileAccess.READ)
	var src := f.get_as_text() if f != null else ""
	for needle in ["SkillAudio.warm()", "_audio_cast_start(skill_id)", "_audio_blow_lands(blow_audio, dealt, monster)",
			"_audio_block(player, result.monster_critical", "_audio_monster_blow(monster, attacked.critical"]:
		_check(src.contains(needle), "World3D calls %s" % needle)

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
