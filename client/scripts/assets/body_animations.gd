extends RefCounted
class_name BodyAnimations

## A player body's clip for an action, the way the client picks it (round 689).
## The one lookup the world, the select and create screens and the skill
## casting share -- every one of the 52 creatable Figures, China and Europe,
## men and women:
##
##   var anims := BodyAnimations.new(data_pk2)
##   var group := BodyAnimations.group_for_weapon(weapon_type_id4, race)
##   var clip := anims.clip_for(assembled, BsrReader.AnimationEntry.TYPE_RUN, group)
##
## `assembled` is the body's SkinnedBsrAssembler.AssembledCharacter (the world's
## and CharacterAppearance's templates both are); its parsed `.bsr` holds the
## body's own animation groups. docs/protocol/charselect.md, "Animations per
## body", is the contract.
##
## **The rule (READ, sro_client.exe):**
## - **The group.** `CObjCharacter::RefreshAnimationGroup` 0xa5bd10: no weapon in
##   visual slot 6 -> `default`; else `FUN_00a5a7d0(weapon TypeID4, race)` --
##   WEAPON_GROUPS below, with the fortress weapon (16) `sword` for race 0 (China)
##   and `onehand_sword` for race 1 (Europe); the race is the character data's
##   +0x9c byte (the body's Country). No sex test anywhere. While pulling a
##   transport the group is `cart` (not modelled: srrevamp has no transports).
## - **The entry.** `CCObjAnimation::FUN_00a5b550` -> `CCompChar::FUN_00c2bbb0` ->
##   `AniMixer::FUN_00c551a0`: the group by name, the entry by action type, and a
##   non-null clip; failing any, the same type in `default`; failing that,
##   nothing plays. Of two entries of one type the last wins, and an entry
##   naming no file holds a null clip and so falls back (BsrReader.ParsedObject.
##   animation_for implements exactly this).
## - **Nothing race-specific beyond that.** A Europe body's `default` group names
##   China clips (`chinaman_fighter_standcity`, `chinaman_a_sitground`, ...;
##   MEASURED, round 684's review and round 689) and retail plays them: the chain
##   above reads only the body's own maps. All 52 Figures share the two Europe
##   skeletons (charselect.md section 2), so those clips drive every bone.
## - **Sitting** (`0xa5a270`, `0xa5a160`) goes through the same lookup: type 14
##   (and 13 from standing), type 15 back up.
## - The avatar group (CObjCharacter +0x190, tried first with no fallback when
##   set, INFERRED to be the visual-change group) is not modelled: OPEN.
##
## The table and the fortress rule are the only data here; the rest is the
## body's own `.bsr`.

## TypeID4 of the weapon in hand -> the body's animation group (READ,
## FUN_00a5a7d0's switch). 16, the fortress weapon, depends on the race:
## group_for_weapon.
const WEAPON_GROUPS := {
	2: "sword", 3: "sword",  # sword, blade
	4: "spear", 5: "spear",  # spear, glaive
	6: "bow", 12: "bow",  # bow, crossbow
	7: "onehand_sword",
	8: "twohand_sword",
	9: "dual_axe",
	10: "onehand_staff", 15: "onehand_staff",  # dark staff, cleric rod
	11: "twohand_staff",
	13: "dagger",
	14: "harf",  # the harp, as the client spells it
}
const GROUP_DEFAULT := "default"
## The fortress weapon's TypeID4 and its groups by race (READ, FUN_00a5a7d0:
## race 0 `sword`, race 1 `onehand_sword`, any other race byte `sword`).
const FORTRESS_WEAPON := 16
const RACE_CHINA := 0
const RACE_EUROPE := 1

## The core actions every Figure must play (BsrReader.AnimationEntry.TYPE_*).
const CORE_ACTIONS := {
	"stand": 0, "walk": 1, "attack": 2, "hit": 3, "die": 4, "run": 7,
	"sit_down": 13, "sit": 14, "stand_up": 15,
}

var _data: Pk2Reader

func _init(data_pk2: Pk2Reader = null) -> void:
	_data = data_pk2

## The animation group a weapon of TypeID4 `type_id4` selects on a body of
## `race` (0 China, 1 Europe); `default` for no weapon (0) or a TypeID4 the
## switch does not list (the client asserts there).
static func group_for_weapon(type_id4: int, race: int = RACE_CHINA) -> String:
	if type_id4 == FORTRESS_WEAPON:
		return "onehand_sword" if race == RACE_EUROPE else "sword"
	return String(WEAPON_GROUPS.get(type_id4, GROUP_DEFAULT))

## The groups the weapons a race can hold select (the catalogue's weapons and
## the shop's: China swords, blades, spears, glaives, bows; Europe the rest),
## for probes and tests: every one must give every core action a clip.
static func race_groups(race: int) -> Array:
	if race == RACE_EUROPE:
		return ["onehand_sword", "twohand_sword", "dual_axe", "bow", "onehand_staff", "twohand_staff", "dagger", "harf"]
	return ["sword", "spear", "bow"]

## The entry `action_type` plays in `group` on a body (with the `default`
## fallback), or null when the body has none.
static func entry_for(parsed: BsrReader.ParsedObject, action_type: int, group: String = GROUP_DEFAULT) -> BsrReader.AnimationEntry:
	if parsed == null:
		return null
	return parsed.animation_entry_for(action_type, group)

## The clip's path, "" when the body has none.
func path_for(assembled: SkinnedBsrAssembler.AssembledCharacter, action_type: int, group: String = GROUP_DEFAULT) -> String:
	if assembled == null or assembled.parsed == null:
		return ""
	return assembled.parsed.animation_for(action_type, group)

## The group the clip is found in (`group` or `default`), "" when none.
func group_found(assembled: SkinnedBsrAssembler.AssembledCharacter, action_type: int, group: String = GROUP_DEFAULT) -> String:
	if assembled == null or assembled.parsed == null:
		return ""
	return assembled.parsed.animation_group_for(action_type, group)

## The parsed clip, read once per body template and shared (the template's
## animation cache), tagged with the entry it was found as for its sound
## tracks (BsrReader.CLIP_META). Null when the body has none or it does not
## parse.
func clip_for(assembled: SkinnedBsrAssembler.AssembledCharacter, action_type: int, group: String = GROUP_DEFAULT) -> BanReader.ParsedAnimation:
	if _data == null:
		return null
	return SkinnedBsrAssembler.animation_for(_data, assembled, action_type, group)
