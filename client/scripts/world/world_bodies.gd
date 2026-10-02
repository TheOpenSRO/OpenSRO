extends RefCounted
class_name WorldBodies

## Which body the world draws a character with (round 689, charselect.md lane
## W): its own model -- the RefObjID the world messages carry (WorldNet's
## models tails) -- when the catalogue holds it as a body, else the body its
## gender was migrated to. A "body key" is the body row's characterdata code
## name (CHAR_EU_MAN_NOBLE): the key the sound, speed, BCRadius and Country
## tables use too.

## The body a character is drawn with when the server names only its gender --
## an older server, whose messages carry no model: the body round 682's
## migration gave every character made before models existed
## (character.LegacyModelFor: 1909 / 1923, OURS, "fighter" for both, what the
## world drew until then). A gender not listed -- europe_man / europe_woman
## from a round-682 server that sends no model yet, or anything unknown --
## draws DEFAULT_GENDER's.
const LEGACY_BODY_CODE := {
	"china_man": "CHAR_CH_MAN_FIGHTER",
	"china_woman": "CHAR_CH_WOMAN_FIGHTER",
}
## Matches character.DefaultGender server-side.
const DEFAULT_GENDER := "china_man"

## The body key for a character: its model's code when `ref_obj_id` is a body
## in `catalog`, else its gender's legacy body, else the default gender's.
static func body_key(catalog: CharCatalog, ref_obj_id: int, gender: String) -> String:
	if catalog != null and ref_obj_id > 0:
		var e := catalog.get_entry(ref_obj_id)
		if e != null and e.is_body and e.code != "":
			return e.code
	return String(LEGACY_BODY_CODE.get(gender, LEGACY_BODY_CODE[DEFAULT_GENDER]))
