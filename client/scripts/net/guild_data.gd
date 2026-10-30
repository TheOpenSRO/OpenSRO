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
## Round 822: the guild's piecewise changes (NetProcessInInterface::
## FUN_00887330; GuildOpsNet has the types and masks).
const OP_UPDATE := 0x38F5
## Round 842: the union record (UnionData).
const OP_UNION_INFO := UnionData.OP_UNION_INFO
const SERVER_OPCODES := [OP_BEGIN, OP_CHUNK, OP_END, OP_UPDATE, OP_UNION_INFO]

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
	## Record +0x27: the logged-on line was shown (FUN_005bb1b0's bit 0x02).
	var announced := false

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
## Round 842: the guild's union (0x3102, 0x38F5 types 0x0d / 0x12), which
## guild lines are coloured by (GuildLineColour).
var union := UnionData.new()

## The buffer between 0x34B3 and 0x34B4.
var _buffer := PackedByteArray()

## A parse changed the record (World3D and the guild window redraw).
signal changed()
## Round 822: a line for the system message window, as 0x38F5's handler
## writes it with 0x7781b0(0, text): the text's key and its %s / %d values.
signal line(key: String, args: Array)
## Round 822: a line for a centre banner as well: "notice" is GDR_NOTICE
## (0x777bf0), "warning" GDR_WARNING_WND (0x77b580).
signal banner(where: String, key: String, args: Array)

## The player's own character name (the owner sets it): 0x38F5's handler
## compares member names with it (0xeef5ec -> 0x9d6580, 0x4e9530).
var own_name := ""
## The name the last type 2 added (0xeeef70 FUN_009a2e30): its first
## "online" update says "joined" rather than "logged on".
var _just_joined := ""

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
		OP_UPDATE:
			apply_update(data)
		OP_UNION_INFO:
			if not union.parse_info(data):
				print("GuildData: malformed union record (%d bytes)" % data.size())

## One 0x38F5 (FUN_00887330's switch on the u8 type; READ, docs/protocol/
## guild.md "Membership (round 822)"). Types it does not know, and any
## update while the player is in no guild, change nothing. A short message
## changes what it read up to the shortfall and stops.
func apply_update(data: PackedByteArray) -> void:
	var r := _Reader.new(data)
	var kind := r.u8()
	if not r.ok or (not in_guild and kind != GuildOpsNet.UPDATE_DISBANDED):
		return
	match kind:
		GuildOpsNet.UPDATE_REFRESH:
			changed.emit()
		GuildOpsNet.UPDATE_DISBANDED:
			if not in_guild:
				return
			# 0x8873c5: BREAK_RESULT with the own guild's name, to the log
			# and to 0x777bf0; then FUN_009990f0 clears everything.
			var gname := guild_name
			line.emit("UIIT_MSG_GUILD_BREAK_RESULT", [gname])
			banner.emit("notice", "UIIT_MSG_GUILD_BREAK_RESULT", [gname])
			clear()
		GuildOpsNet.UPDATE_MEMBER_ADD:
			var m := _read_member(r)
			if not r.ok:
				return
			# 0x88768c pushes ebx = 0 for the siege byte: a member added
			# this way has none, whatever the wire says.
			m.siege_authority = 0
			var old := member(m.character_id)
			if old != null:
				members.erase(old)
			members.append(m)
			_just_joined = m.member_name
			changed.emit()
		GuildOpsNet.UPDATE_MEMBER_OUT:
			_member_out(r)
		GuildOpsNet.UPDATE_GUILD:
			_guild_fields(r)
		GuildOpsNet.UPDATE_MEMBER:
			_member_fields(r)
		GuildOpsNet.UPDATE_PERMISSIONS:
			_permissions(r)
		GuildOpsNet.UPDATE_MEMBERS_FIELD:
			_members_fields(r)
		UnionData.UPDATE_JOINED:
			# Round 842: a guild joined the union (FUN_00580650's line).
			var joined := union.apply_joined(r)
			if joined != "":
				line.emit("UIIT_MSG_GUILD_ALLY_JOIN_RESULT", [joined])
		UnionData.UPDATE_OUT:
			# Round 842: one left, was expelled, or the union broke.
			var said := union.apply_out(r, guild_name)
			if not said.is_empty():
				line.emit(String(said[0]), said[1] as Array)

## Type 3: u32 id, u8 reason (read after the removal, 0x8877fe).
func _member_out(r: _Reader) -> void:
	var id := r.u32()
	var reason := r.u8()
	if not r.ok:
		return
	var m := member(id)
	if m == null:
		return
	var me := m.member_name == own_name
	var gname := guild_name
	if me:
		clear()
	else:
		members.erase(m)
		changed.emit()
	match reason:
		GuildOpsNet.REMOVED_LEFT:
			# Someone else's leave says nothing (0x887856).
			if me:
				line.emit("UIIT_MSG_GUILD_EXIT_RESULT", [gname])
		GuildOpsNet.REMOVED_EXPELLED:
			# The member's name, whether it is the player or not.
			line.emit("UIIT_MSG_GUILD_EXPULSION_RESULT", [m.member_name])

## Type 5: u8 mask, then the fields in bit order (FUN_005b7b80).
func _guild_fields(r: _Reader) -> void:
	var mask := r.u8()
	if mask & GuildOpsNet.GUILD_FIELD_NAME:
		# The one wide string: u16 characters, then UTF-16LE (FUN_005b5e50).
		var n := r.u16()
		if r.need(n * 2):
			guild_name = TextDecode.utf16(r.d.slice(r.at, r.at + n * 2))
			r.at += n * 2
	if mask & GuildOpsNet.GUILD_FIELD_LEVEL:
		var lv := r.u8()
		if r.ok:
			level = lv
			line.emit("UIIT_MSG_GUILD_LEVEL_UP_RESULT", [lv])
	if mask & GuildOpsNet.GUILD_FIELD_GP:
		var pts := r.u32()
		if r.ok:
			gp = pts
	if mask & GuildOpsNet.GUILD_FIELD_NOTICE:
		var title := r.s()
		var body := r.s()
		if r.ok:
			notice_title = title
			notice_body = body
			banner.emit("warning", "UIIT_MSG_GUILD_COMMON_KNOW_REMIND_UPDATE", [])
	if mask & GuildOpsNet.GUILD_FIELD_SOLDIER:
		var f := r.u8()
		if r.ok:
			# 0 clears it; anything else is ORed in.
			soldier_flags = 0 if f == 0 else soldier_flags | f
	changed.emit()

## Round 844: type 0x14 {u8 n, n x {u32 id, u32 mask}} -- every listed
## member's permission, silently (c:0x887330's table, READ; the server's
## s:0x5caa20 after a 0x7104).
func _permissions(r: _Reader) -> void:
	var n := r.u8()
	for i in n:
		var id := r.u32()
		var p := r.u32()
		if not r.ok:
			return
		var m := member(id)
		if m != null:
			m.permission = p
	changed.emit()

## Round 844: type 0x16 {u8 n, u8 mask, n x {u32 id, the mask's fields}} --
## several members' fields, each as type 6 reads them (0x5bb1b0 per member;
## the hand-over's mask 0x54, the permission list's 0x10).
func _members_fields(r: _Reader) -> void:
	var n := r.u8()
	var mask := r.u8()
	for i in n:
		var id := r.u32()
		if not r.ok:
			return
		var m := member(id)
		if m == null:
			# Its fields cannot be skipped without knowing it; the original
			# asserts here too.
			return
		_fields_of(m, mask, r)
		if not r.ok:
			return
	changed.emit()

## Type 6: u32 id, u8 mask, then the fields in bit order (FUN_005bb1b0).
func _member_fields(r: _Reader) -> void:
	var id := r.u32()
	var mask := r.u8()
	var m := member(id)
	if not r.ok or m == null:
		# The original asserts "Illigal Guild Member : %d" here.
		return
	_fields_of(m, mask, r)
	changed.emit()

## One member's fields by mask, in bit order (0x5bb1b0).
func _fields_of(m: Member, mask: int, r: _Reader) -> void:
	if mask & GuildOpsNet.MEMBER_FIELD_LEVEL:
		var lv := r.u8()
		if r.ok:
			m.level = lv
	if mask & GuildOpsNet.MEMBER_FIELD_OFFLINE:
		var off := r.u8()
		if r.ok:
			_presence(m, off == 0)
	if mask & GuildOpsNet.MEMBER_FIELD_CLASS:
		var c := r.u8()
		if r.ok:
			m.member_class = c
	if mask & GuildOpsNet.MEMBER_FIELD_GP:
		var g := r.u32()
		if r.ok:
			m.gp_donation = g
	if mask & GuildOpsNet.MEMBER_FIELD_PERMISSION:
		var p := r.u32()
		if r.ok:
			m.permission = p
	if mask & GuildOpsNet.MEMBER_FIELD_NAME:
		var nm := r.s()
		if r.ok:
			m.member_name = nm
	if mask & GuildOpsNet.MEMBER_FIELD_SIEGE:
		var sa := r.u8()
		if r.ok:
			m.siege_authority = sa

## Bit 0x02 of type 6: the online lines (FUN_005bb1b0, READ).
func _presence(m: Member, online: bool) -> void:
	m.online = online
	if online:
		if _just_joined != "" and m.member_name == _just_joined:
			line.emit("UIIT_MSG_GUILD_JOIN_RESULT", [m.member_name])
			_just_joined = ""
		elif not m.announced:
			line.emit("UIIT_MSG_GUILD_CONNECT", [m.member_name])
		if m.member_name == own_name and notice_title != "":
			line.emit("UIIT_MSG_GUILD_CONNECT_NOTICE", [notice_title])
		m.announced = true
	else:
		if m.member_name != own_name:
			line.emit("UIIT_MSG_GUILD_DISCONNECT", [m.member_name])
		m.announced = false

## Forgets the guild (the player left it, or another character came in).
func clear() -> void:
	_just_joined = ""
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
	# Round 842: no guild, no union (FUN_009990f0 clears the whole record).
	union.clear()
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
	func u16() -> int:
		if not need(2):
			return 0
		at += 2
		return d.decode_u16(at - 2)
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
		list.append(_read_member(r))
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

## One member record, in the block's order (FUN_009965e0; 0x38F5 type 2 uses
## the same 13 fields, 0x8874ac..0x887739). +0x27, "logged on announced",
## starts as (offline flag == 0) (FUN_009961a0, 0x99630x).
static func _read_member(r: _Reader) -> Member:
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
	m.announced = m.online
	return m

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
