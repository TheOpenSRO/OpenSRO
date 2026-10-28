extends RefCounted
class_name SpiritAbilities

## A devil's spirit's skills by its plus level (round 838), read from the
## client's own tables as sro_client.exe reads them (READ: the loader files
## refabilitybyitemoptleveldata / refskillbyitemoptleveldata, and CIFEquipment
## c:0x6ae5b0 looks the worn spirit's ability up by (RefItemID, OptLevel),
## c:0x9371f0, then its skills, c:0x937250, into the four slots of
## GDR_AVATAR_SKILL_WND, CIFEquipSkillSlotWnd c:0x6aec30). The server grants
## the same skills while the spirit is worn and awake (session/avatarstats.go,
## spiritSkillGranted).
##
## OPEN: the client lists only skills whose refskill +0x61 is 1 or 2 and
## orders them by +0xfc; those columns are not identified, so every skill
## row is listed in the table's order (OURS).

const ABILITY_PATH := "server_dep\\silkroad\\textdata\\refabilitybyitemoptleveldata.txt"
const SKILL_PATH := "server_dep\\silkroad\\textdata\\refskillbyitemoptleveldata.txt"

## (RefItemID, OptLevel) key -> ability id.
var _ability := {}
## ability id -> PackedInt32Array of skill ids.
var _skills := {}

static func _key(ref_id: int, opt_level: int) -> int:
	return ref_id * 256 + opt_level

## Fills the table from the two files' text (UTF-16 or UTF-8 decoded).
func parse(ability_text: String, skill_text: String) -> SpiritAbilities:
	for line in ability_text.split("\n", false):
		var c := line.strip_edges().trim_prefix(char(0xFEFF)).split("\t")
		if c.size() < 4 or not c[0].is_valid_int() or int(c[0]) == 0:
			continue
		if c[1].is_valid_int() and c[2].is_valid_int() and c[3].is_valid_int():
			_ability[_key(int(c[2]), int(c[3]))] = int(c[1])
	for line in skill_text.split("\n", false):
		var c := line.strip_edges().trim_prefix(char(0xFEFF)).split("\t")
		if c.size() < 2 or not c[0].is_valid_int() or not c[1].is_valid_int():
			continue
		var a := int(c[0])
		var list: PackedInt32Array = _skills.get(a, PackedInt32Array())
		list.append(int(c[1]))
		_skills[a] = list
	return self

## The skills of the spirit `ref_id` at `opt_level` (at most four).
func skills_for(ref_id: int, opt_level: int) -> PackedInt32Array:
	var a: int = _ability.get(_key(ref_id, opt_level), -1)
	if a < 0:
		return PackedInt32Array()
	var out: PackedInt32Array = _skills.get(a, PackedInt32Array())
	return out.slice(0, 4)

func size() -> int:
	return _ability.size()

## Reads both files from the media archive (null archive: an empty table).
static func from_archive(archive: Pk2Reader) -> SpiritAbilities:
	var t := SpiritAbilities.new()
	if archive == null:
		return t
	var read := func(path: String) -> String:
		var entry := ObjectLoader.find_file(archive, path)
		if entry == null:
			return ""
		var bytes := archive.read_file(entry)
		if bytes.size() >= 2 and bytes[0] == 0xff and bytes[1] == 0xfe:
			return TextDecode.utf16(bytes.slice(2))
		return bytes.get_string_from_utf8()
	return t.parse(read.call(ABILITY_PATH), read.call(SKILL_PATH))
