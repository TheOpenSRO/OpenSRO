extends RefCounted
class_name GuildData

## The player's guild as the original keeps it (round 821): the guild block
## the server sends at world entry and after a change -- 0x34B3 begins the
## buffer (FUN_0087fcd0), 0x3101 appends to it (FUN_00883060 -> 0x833380),
## 0x34B4 parses it (FUN_00887300 -> 0x885550 ->
## CharacterDependentData::FUN_009965e0, READ) -- and the guild window draws
## from it (CNIFGuildWnd's refresh 0x5b5eb0, the member rows 0x5b6b40).

const OP_BEGIN := 0x34B3
const OP_CHUNK := 0x3101
const OP_END := 0x34B4
const SERVER_OPCODES := [OP_BEGIN, OP_CHUNK, OP_END]

## Member classes (the row fill 0x5b6b40, READ).
const CLASS_MASTER := 0
const CLASS_STAFF := 5
const CLASS_MEMBER := 10

## Permission bits (the server's HasPermission tests, s:0x5d0f80; the
## guild window's button rules 0x5b531b..0x5b5442).
const PERM_INVITE := 0x01
const PERM_EXPEL := 0x02
const PERM_UNION_CHAT := 0x04
const PERM_STORAGE := 0x08
const PERM_NOTICE := 0x10

## The member cap by level (0x5b5eb0's table at 0xd92384, READ) and the GP a
## level-up needs (0xd92398; 0 at the top level).
const MAX_MEMBERS := [15, 20, 25, 35, 50]
const LEVEL_UP_GP := [5400, 50400, 135000, 378000, 0]

class Member:
	var character_id := 0
	var member_name := ""
	## CLASS_MASTER, CLASS_STAFF or CLASS_MEMBER.
	var member_class := CLASS_MEMBER
	var level := 0
	var gp_donation := 0
	var permission := 0
	var contribution := 0
	var war_kill := 0
	var war_killed := 0
	var nickname := ""
	var ref_obj_id := 0
	var siege_authority := 0
	## Record +0x26: 0 online (gil_contact_on), 1 offline.
	var online := false

## Whether the player is in a guild (the record's flag +4, set by a parse).
var in_guild := false
var guild_id := 0
var guild_name := ""
var level := 0
var gp := 0
var notice_title := ""
var notice_body := ""
var crest_rev := 0
var soldier_flags := 0
var members: Array[Member] = []

## The buffer between 0x34B3 and 0x34B4.
var _buffer := PackedByteArray()

## A parse changed the record (World3D and the guild window redraw).
signal changed()

func register_with(net: Node) -> void:
	for op in SERVER_OPCODES:
		net.register_handler(op, handle.bind(op))

func handle(data: PackedByteArray, op: int) -> void:
	match op:
		OP_BEGIN:
			_buffer = PackedByteArray()
		OP_CHUNK:
			_buffer.append_array(data)
		OP_END:
			if parse(_buffer):
				changed.emit()
			else:
				print("GuildData: malformed guild block (%d bytes)" % _buffer.size())
			_buffer = PackedByteArray()

## Forgets the guild (the player left it, or another character came in).
func clear() -> void:
	in_guild = false
	guild_id = 0
	guild_name = ""
	level = 0
	gp = 0
	notice_title = ""
	notice_body = ""
	crest_rev = 0
	soldier_flags = 0
	members.clear()
	changed.emit()

class _Reader:
	var d: PackedByteArray
	var at := 0
	var ok := true
	func _init(b: PackedByteArray) -> void:
		d = b
	func need(n: int) -> bool:
		if not ok or at + n > d.size():
			ok = false
			return false
		return true
	func u8() -> int:
		if not need(1):
			return 0
		at += 1
		return d[at - 1]
	func u32() -> int:
		if not need(4):
			return 0
		at += 4
		return d.decode_u32(at - 4)
	func s() -> String:
		if not need(2):
			return ""
		var n := d.decode_u16(at)
		at += 2
		if not need(n):
			return ""
		at += n
		return d.slice(at - n, at).get_string_from_utf8()

## Parses a block (FUN_009965e0's order); false, the record unchanged, for a
## short one.
func parse(b: PackedByteArray) -> bool:
	var r := _Reader.new(b)
	var gid := r.u32()
	var gname := r.s()
	var lv := r.u8()
	var pts := r.u32()
	var title := r.s()
	var body := r.s()
	var crest := r.u32()
	var soldier := r.u8()
	var n := r.u8()
	var list: Array[Member] = []
	for i in n:
		var m := Member.new()
		m.character_id = r.u32()
		m.member_name = r.s()
		m.member_class = r.u8()
		m.level = r.u8()
		m.gp_donation = r.u32()
		m.permission = r.u32()
		m.contribution = r.u32()
		m.war_kill = r.u32()
		m.war_killed = r.u32()
		m.nickname = r.s()
		m.ref_obj_id = r.u32()
		m.siege_authority = r.u8()
		m.online = r.u8() == 0
		list.append(m)
	# The trailing list (FUN_0099d7e0): u8 n x {u32, u8, u32}, kept unread.
	var extra := r.u8()
	for i in extra:
		r.u32()
		r.u8()
		r.u32()
	if not r.ok:
		return false
	in_guild = true
	guild_id = gid
	guild_name = gname
	level = lv
	gp = pts
	notice_title = title
	notice_body = body
	crest_rev = crest
	soldier_flags = soldier
	members = list
	return true

## The member record for `character_id`, or null.
func member(character_id: int) -> Member:
	for m in members:
		if m.character_id == character_id:
			return m
	return null

## The master's record, or null.
func master() -> Member:
	for m in members:
		if m.member_class == CLASS_MASTER:
			return m
	return null

## The level's member cap (0 out of range).
func max_members() -> int:
	return int(MAX_MEMBERS[level - 1]) if level >= 1 and level <= MAX_MEMBERS.size() else 0

## The GP the next level needs (0 at the top, or out of range).
func level_up_gp() -> int:
	return int(LEVEL_UP_GP[level - 1]) if level >= 1 and level <= LEVEL_UP_GP.size() else 0
