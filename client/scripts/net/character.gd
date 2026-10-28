extends RefCounted
class_name CharacterNet

## The Gender strings the world wire still carries (EnterWorldResult.gender,
## EntitySnapshot.gender) until lane W draws bodies from RefObjID and scale --
## server/internal/character's GenderChinaMan/GenderChinaWoman. Since round
## 682 the server derives the string from the body a character was made from,
## and offers Europe too (europe_man / europe_woman), which World3D draws with
## its DEFAULT_GENDER until then.
##
## The character list, create and delete that lived here (our own
## 0x0010-0x0015) are the retail lobby now: LobbyNet (net/lobby.gd).

const GENDER_CHINA_MAN := "china_man"
const GENDER_CHINA_WOMAN := "china_woman"
const GENDER_EUROPE_MAN := "europe_man"
const GENDER_EUROPE_WOMAN := "europe_woman"

## The body, armour set and weapon today's create screen sends for a sex
## (round 682): CHAR_CH_MAN_FIGHTER / CHAR_CH_WOMAN_FIGHTER, the China Clothes
## set and the Copper Sword -- what every character was made in before the
## lobby, the body World3D draws for the two China strings, and one of the
## choices the retail customize screen offers (Protector 3, Weapon 1). OURS,
## the interim until round 685's customize screen sends the player's own
## choices. Ids are references (charselect.md section 4), scale 0x22 the
## sliders' middle (READ).
const INTERIM_KIT := {
	"china_man": {"model": 1909, "chest": 3643, "legs": 3644, "feet": 3645, "weapon": 3632},
	"china_woman": {"model": 1923, "chest": 3652, "legs": 3653, "feet": 3654, "weapon": 3632},
	# Round 838 (QA sign-in only, OPENSRO_QA_GENDER=europe_man): CHAR_EU_MAN_NOBLE,
	# the Europe clothes set and the sword, all creatable (the chargen table).
	"europe_man": {"model": 14875, "chest": 11623, "legs": 11624, "feet": 11625, "weapon": 10888},
}
const DEFAULT_SCALE := 0x22

## The gender string of a listed body, for the screens that still pick a
## preview by it: the two China fighters' ids name their sex; any other body
## is drawn as its sex's China fighter until round 683's appearance builder.
## Europe's ids are 14875-14900 (MEASURED), men first.
static func gender_of_model(ref_obj_id: int) -> String:
	if ref_obj_id >= 14875 and ref_obj_id <= 14887:
		return GENDER_EUROPE_MAN
	if ref_obj_id >= 14888 and ref_obj_id <= 14900:
		return GENDER_EUROPE_WOMAN
	if ref_obj_id >= 1920 and ref_obj_id <= 1932:
		return GENDER_CHINA_WOMAN
	return GENDER_CHINA_MAN
