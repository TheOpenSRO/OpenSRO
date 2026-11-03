extends RefCounted
class_name SystemEffects

## Round 859 (lane B): the original's system decorations and the hit's blood,
## the rules only (pure). World3D carries them out. Labels: READ
## (sro_client.exe, addresses with c:), MEASURED, INFERRED, OURS, OPEN.
##
## THE SYSTEM DECORATIONS (READ). A system effect is started like a skill's,
## by FUN_00a54020(obj, id, ...) with an id 0x80000000 + n; the name table at
## c:0x00ec73f8 ({wchar name, id} pairs, 37 of them) gives each id the
## skilleffect.txt row it plays: 0x80000006 SYSTEM_LEVELUP, 0x80000021
## SYSTEM_PET_APPEAR, 0x80000022 SYSTEM_PET_LEVEL_UP, ... (every pair is in
## WORLD_ISSUES round 859). FUN_00a53850's stack arguments are (obj, row,
## skipStart, endNow, phase): with skipStart 0 it plays the row's ACT_S group,
## then its ACT_L group, and with endNow set it ends the decoration at once
## (c:0x00a53bfb -> FUN_00a53120): its kept (AT_LOOP) rows are let go and play
## their last cycle out. The level-up (c:0x8a7020), the pet's level-up and the
## pet's summon (c:0x9c5d20) all pass endNow 1, so they are one-shots.
const LEVELUP := "SYSTEM_LEVELUP"
const PET_LEVEL_UP := "SYSTEM_PET_LEVEL_UP"
const PET_APPEAR := "SYSTEM_PET_APPEAR"

## 0x3054's handler c:0x8a7020 (READ): u32 an object's unique id; nothing
## when the object is not in view. A COS (IsKindOf CICCos, the class link
## c:0xeef6f0) plays SYSTEM_PET_LEVEL_UP, anything else SYSTEM_LEVELUP.
static func level_up_effect(is_cos: bool) -> String:
	return PET_LEVEL_UP if is_cos else LEVELUP

## The same handler's sound (READ): snd_levup through the name dispatcher
## (+0x24), only for this player's own body (FUN_009d4990: the object is
## DAT_00eef5ec) or, for a COS, one of this player's own COS (FUN_009a0b80 on
## the uid finds it in this player's COS list). Everyone else's level-up is
## silent here.
static func level_up_sounds(is_cos: bool, is_own_player: bool, is_own_cos: bool) -> bool:
	return is_own_cos if is_cos else is_own_player

## OURS: a level-up of this player is told twice by a server of this round --
## its own OpLevelUp (the banner, round 639) and retail's 0x3054 to everyone
## in view -- and once by an older one (OpLevelUp alone). The effect and the
## sound play for whichever comes first; the other, within this many ms, is
## the same level-up.
const OWN_LEVEL_UP_DEDUPE_MS := 2000

static func own_level_up_is_new(last_ms: int, now_ms: int) -> bool:
	return last_ms < 0 or now_ms - last_ms >= OWN_LEVEL_UP_DEDUPE_MS

## CICCos::vslot_026 c:0x9c5d20 (READ): the byte after a 0x3015 COS record;
## 1 on a pet -- CIFTargetWindowCommonEnemy::FUN_0069a420: a COS whose
## TypeID4 is 3 (growth) or 4 (ability) -- plays SYSTEM_PET_APPEAR (endNow 1)
## and snd_cos_summon. A ride, a transport or a soldier plays nothing.
static func pet_summon_plays(kind: int, spawn_type: int) -> bool:
	return spawn_type == 1 and (kind == 3 or kind == 4)

## snd_cos_summon's row (MEASURED, effectsound.txt: `UI SND_COS_SUMMON - - - -
## skill\ csk_heal_ready_a.wav 60`): a UI key, played with no position as the
## dispatcher's other UI keys are (UiSounds' header).
const KEY_COS_SUMMON := "UI:snd_cos_summon:-:-:-:-"

# --- the hit's blood -----------------------------------------------------------

## The hit's blood (READ, FUN_00a49290, the apply of one hit entry, called
## from IDecoSkill::FUN_00a4bdd0 for a skill's DMG group): inside the block
## that draws the skill's DamageEfp -- run only when the display row's byte
## +0xd is not 0 (INFERRED the Effect Quality option, SkillEffects.quality),
## the decoration has a DamageEfp and an attacker -- a second effect is made
## with the same placement when the call's blood argument is set (cleared for
## a kind-7 wall entry, c:0x00a492fc): the TARGET's characterInfo record
## (obj+0x728) +0x1c, or +0x20 when the option byte +0x12e is 0.
## UI_ALCHEMYBOX::FUN_00a9ae80 (the characterInfo parser) fills +0x1c with
## `hiteffect\<BloodType>.efp` (column 9) and +0x20 with
## `hiteffect\hit_2_greenblood.efp` for every row whose BloodType is not
## "none". The blood argument is the skillaniset2 row's +0xfa (the loader
## c:0x00a9c470 stores the row's last column, "피 나올래?" -- "blood?" -- as
## `!= 0`; FUN_00a4bdd0 passes 1 when the decoration has no row); the end-of-cast
## apply of hits not yet shown (IDecoSkill::FUN_00a4f720) passes 1.
## MEASURED (skilleffect.txt): BloodType hit_2_redblood 862 rows, none 262,
## greenblood 116, stone 114, wood 63, ice 27, metal 27, blueblood 6, sand 2,
## fire 2, illusion 1, redblood_down 1; skillaniset2's blood column 1 on 3,046
## rows and 0 on 76 (118 rows of the older layout carry no such column).
const GREEN_BLOOD := "hiteffect\\hit_2_greenblood.efp"

## The record's blood path (+0x1c) from a BloodType cell: "" for none.
static func blood_path_of(blood_type: String) -> String:
	var b := blood_type.strip_edges()
	if b == "" or b.to_lower() == "none":
		return ""
	return "hiteffect\\" + b + ".efp"

## Which blood the option byte picks: +0x1c (the row's own) when +0x12e is
## set, else +0x20, the green -- for a row that names any.
static func blood_for(own_path: String, option_on: bool) -> String:
	if own_path == "":
		return ""
	return own_path if option_on else GREEN_BLOOD

## Whether a hit draws its target's blood (READ, see above): effects not off,
## the skill draws a DamageEfp, the row asks for blood, not a wall entry.
static func blood_plays(quality: int, has_damage_efp: bool, row_blood: bool, wall: bool) -> bool:
	return quality > 0 and has_damage_efp and row_blood and not wall
