extends RefCounted
class_name UnionWorld

## Round 844 (lane U): the union's requests and boxes between NetClient's
## UnionOps, the HUD (the guild window's union pane and box 0x1d) and the
## chat (a union line's guild prefix), so World3D carries one line for it.
## READ facts are UnionOps's and UnionPane's; this file only joins them.

var world: Node

func _init(w: Node) -> void:
	world = w
	var ops := NetClient.union_ops
	# Refusals through category 0x10, as the guild's (0x778190).
	ops.notice.connect(func(key: String, args: Array, code: int) -> void:
		print("UNION notice %s code 0x%x" % [key, code])
		world._on_guild_ops_notice(key, args, code))
	ops.result.connect(func(op: int, ok: bool, code: int) -> void:
		print("UNION result 0x%04x ok=%s code=0x%x" % [op, ok, code]))
	ops.request_box.connect(_on_request_box)
	var hud = world._hud_panels
	if hud != null:
		hud.union_request_requested.connect(_on_apply)
		hud.union_leave_requested.connect(func() -> void:
			print("UNION leave: 0x70FC")
			NetClient.union_ops.leave())
		hud.union_expel_requested.connect(func(id: int) -> void:
			print("UNION expel: 0x70FD guild %d" % id)
			NetClient.union_ops.expel(id))
	var chat = world._hud_chat
	if chat != null:
		chat.union_guild = func() -> String: return NetClient.guild_data.guild_name
	NetClient.guild_data.union.changed.connect(func() -> void:
		var u := NetClient.guild_data.union
		print("UNION record: id %d lead %d guilds %s" % [u.union_id, u.leader_guild_id, _names(u)]))

static func _names(u: UnionData) -> String:
	var out: PackedStringArray = []
	for e in u.guilds.values():
		out.append("%s(Lv%d,%s,%d)" % [(e as UnionData.Entry).guild_name, (e as UnionData.Entry).level,
			(e as UnionData.Entry).master, (e as UnionData.Entry).members])
	return ",".join(out)

## Apply (51, c:0x8201b0): the selected player (nothing without one).
func _on_apply() -> void:
	var target: int = world._party_selected_target()
	if target == 0:
		print("UNION apply: no player selected")
		return
	print("UNION apply: 0x70FB for %d" % target)
	NetClient.union_ops.request(target, NetClient.own_character_id)

## 0x3080 kind 6: box 0x1d with the requester's guild name.
func _on_request_box(requester_uid: int, guild_name: String) -> void:
	print("UNION request box from %d [%s]" % [requester_uid, guild_name])
	var hud = world._hud_panels
	var box: GuildMsgBox = hud.show_union_request(guild_name) if hud != null else null
	if box == null:
		return
	box.accepted.connect(func(_t: String) -> void:
		print("UNION request answered yes")
		NetClient.union_ops.answer(true))
	box.cancelled.connect(func() -> void:
		print("UNION request answered no")
		NetClient.union_ops.answer(false))
	box.expired.connect(func() -> void: NetClient.union_ops.forget_request())
