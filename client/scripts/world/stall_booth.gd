extends RefCounted
class_name StallBooth

## The model a player's stall is drawn as (round 838). READ from
## sro_client.exe, FUN_009dd040(1) -- called by the 0x30B8 stall-open handler
## (NetProcessInInner::FUN_00873c10, which keeps the stall's u32 decoration at
## +0x790) and by the post-spawn restore of a stalling player
## (FUN_009ca320) -- when the character has no booth model yet (+0x78c):
##
## - a CCObjAnimation (0x30 bytes, ctor 0xa5b3a0);
## - the decoration's ref (GlobalDataManager::FUN_0093f5f0(+0x790)) found:
##   its ref+0x124, AssocFileObj128 -- itemdata column 53, the item's own
##   `.bsr` (`item\Avatar\booth_mob_mangyang.bsr`; ItemTableReader's
##   model_path);
## - else the character ref's race byte +0x9c: 0 `res\item\china\item\
##   cj_store.bsr`, 1 `res\item\europe\item\euro_streetstall01.bsr`;
## - the model put at the character's own world transform every frame
##   (CICUser::vslot_010 0x9dd350), its animation ticked (vslot_009).
##
## OPEN, the gap: OpenSRO has no player stall yet (no 0x70B1 / 0x30B8, no
## stall window), so nothing in the world calls this but the QA hook
## (OPENSRO_QA_STALL_BOOTH, World3D); the server keeps the decoration for the
## stall to send (session.StallDecorationOf). The booth's own animation
## (`prim\ani\avatar\booth_*.ban`) is not played: ObjectLoader draws the
## pieces as they stand.

const CHINA_DEFAULT := "res\\item\\china\\item\\cj_store.bsr"
const EUROPE_DEFAULT := "res\\item\\europe\\item\\euro_streetstall01.bsr"

## The `.bsr` a stall shows: the decoration item's own model when the item
## table knows it (decoration 0 or an unknown id: none), else the default of
## `race` (the character's Country: 0 China, 1 Europe). Any other race has no
## default (the original's switch has only the two cases): "".
static func model_path(decoration: ItemTableReader.Item, race: int) -> String:
	if decoration != null and decoration.model_path != "":
		var p := decoration.model_path
		return p if p.to_lower().begins_with("res\\") else "res\\" + p
	match race:
		0:
			return CHINA_DEFAULT
		1:
			return EUROPE_DEFAULT
	return ""

## The booth's model out of the archive, or null.
static func build(archive: Pk2Reader, path: String) -> Node3D:
	if archive == null or path == "":
		return null
	var model := ObjectLoader.load_object(archive, path)
	if model != null:
		model.name = "StallBooth"
	return model
