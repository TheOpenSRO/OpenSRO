extends RefCounted
class_name UnionData

## Round 842: the own guild's union as the original keeps it -- what a guild
## line is coloured green by (GuildLineColour; docs/protocol/guild_plate.md,
## "Colour"). READ from sro_client.exe unless marked:
## - 0x3102 (FUN_0087fd00 -> FUN_0099a810): u32 the union's id
##   (CharacterDependentData +0x248), u32 its crest revision (+0x244), u32
##   (+0x240; the server writes the first slot's guild, s:0x5b9260 --
##   INFERRED the leader), u8 n x {u32 guild id, str name, u8 level, str
##   master, u32 (INFERRED the master's model), u8 (INFERRED the member
##   count)} -- each added to the alliance map CDD+0x148+0x94
##   (CharacterDependentData::FUN_00999120, which asserts
##   "!IsAllianceGuild(dwGuildID)"); then every guild line is recoloured
##   (FUN_009a4450) and the own line made again (FUN_009dc460).
##   OURS: a record replaces the last one (the original adds to its map),
##   and one with no guilds clears it -- the server's "no union".
## - 0x38F5 type 0x0d (the case at 0x887ae9): one more entry, the same
##   fields; UIIT_MSG_GUILD_ALLY_JOIN_RESULT with its name (FUN_00580650).
## - 0x38F5 type 0x12 (0x887e3b): u8 how -- 1 a guild left (u32 id,
##   UIIT_MSG_GUILD_ALLY_EXIT_RESULT), 2 expelled (u32 id,
##   UIIT_MSG_GUILD_RESPECT_ALLY_EXPEL_RESULT), 3 the union broken
##   (UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_BREAKUP). When the guild gone is
##   the own one (its entry's name against the own guild's, 0x4e9530), or
##   the map held fewer than two before it (0x988a60, the map's size +0x9c,
##   < 2), or how is 3, the whole union is cleared (0x580630); else that
##   guild alone (0x580720). Then every guild line is recoloured.

const OP_UNION_INFO := 0x3102
const UPDATE_JOINED := 0x0d
const UPDATE_OUT := 0x12
const OUT_LEFT := 1
const OUT_EXPELLED := 2
const OUT_BROKEN := 3

class Entry:
	var guild_id := 0
	var guild_name := ""
	var level := 0
	var master := ""
	var master_model := 0
	var members := 0

var union_id := 0
var crest_rev := 0
var leader_guild_id := 0
## The union's guilds by id (the own one too: the server's record lists every
## slot, s:0x5b8eb0).
var guilds := {}

## The union changed: World3D recolours every guild line (FUN_009a4450).
signal changed()

func in_union() -> bool:
	return not guilds.is_empty()

## Whether guild_name is one of the union's guilds (FUN_00996d60: the name
## against each entry's, case-sensitive as wcsncmp is).
func is_allied(guild_name: String) -> bool:
	if guild_name == "":
		return false
	for e in guilds.values():
		if (e as Entry).guild_name == guild_name:
			return true
	return false

func clear() -> void:
	var had := in_union() or union_id != 0
	union_id = 0
	crest_rev = 0
	leader_guild_id = 0
	guilds.clear()
	if had:
		changed.emit()

## 0x3102; false when malformed (nothing changes then).
func parse_info(data: PackedByteArray) -> bool:
	var r := GuildData._Reader.new(data)
	var uid := r.u32()
	var crest := r.u32()
	var leader := r.u32()
	var n := r.u8()
	var list: Array[Entry] = []
	for i in n:
		var e := read_entry(r)
		if not r.ok:
			return false
		list.append(e)
	if not r.ok:
		return false
	union_id = uid
	crest_rev = crest
	leader_guild_id = leader
	guilds.clear()
	for e in list:
		guilds[e.guild_id] = e
	if list.is_empty():
		union_id = 0
	changed.emit()
	return true

static func read_entry(r: GuildData._Reader) -> Entry:
	var e := Entry.new()
	e.guild_id = r.u32()
	e.guild_name = r.s()
	e.level = r.u8()
	e.master = r.s()
	e.master_model = r.u32()
	e.members = r.u8()
	return e

## 0x38F5 type 0x0d after its type byte; the joined guild's name, "" when
## malformed.
func apply_joined(r: GuildData._Reader) -> String:
	var e := read_entry(r)
	if not r.ok:
		return ""
	guilds[e.guild_id] = e
	changed.emit()
	return e.guild_name

## 0x38F5 type 0x12 after its type byte, with the own guild's name: the
## [key, args] of its system line, [] when malformed.
func apply_out(r: GuildData._Reader, own_guild_name: String) -> Array:
	var how := r.u8()
	if not r.ok:
		return []
	if how == OUT_BROKEN:
		clear()
		return ["UIIT_MSG_QUESTION_GUILD_RESPECT_ALLY_BREAKUP", []]
	if how != OUT_LEFT and how != OUT_EXPELLED:
		return []
	var gid := r.u32()
	if not r.ok:
		return []
	var e: Entry = guilds.get(gid)
	var gname := e.guild_name if e != null else ""
	var own := e != null and own_guild_name != "" and e.guild_name == own_guild_name
	# The count is the map's before the removal (0x988a60 = +0x9c, the
	# std::map's size), as the original tests it.
	if own or guilds.size() < 2:
		clear()
	elif e != null:
		guilds.erase(gid)
		changed.emit()
	var key := "UIIT_MSG_GUILD_ALLY_EXIT_RESULT" if how == OUT_LEFT else "UIIT_MSG_GUILD_RESPECT_ALLY_EXPEL_RESULT"
	return [key, [gname]]
