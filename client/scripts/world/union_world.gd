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
		print("UNION result 0x%04x ok=%s code=0x%x frame %d" % [op, ok, code, Engine.get_frames_drawn()]))
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
		print("UNION record: id %d lead %d guilds %s frame %d" % [u.union_id, u.leader_guild_id, _names(u),
			Engine.get_frames_drawn()]))

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
	print("UNION request box from %d [%s] frame %d" % [requester_uid, guild_name, Engine.get_frames_drawn()])
	var hud = world._hud_panels
	var box: GuildMsgBox = hud.show_union_request(guild_name) if hud != null else null
	if box == null:
		return
	_qa_answer(box)
	box.accepted.connect(func(_t: String) -> void:
		print("UNION request answered yes")
		NetClient.union_ops.answer(true))
	box.cancelled.connect(func() -> void:
		print("UNION request answered no")
		NetClient.union_ops.answer(false))
	box.expired.connect(func() -> void: NetClient.union_ops.forget_request())

## OPENSRO_QA_UNION_ANSWER="yes:<frames>" / "no:<frames>" (QA only): that many
## frames after box 0x1d opens, a real left click on its OK / Cancel.
func _qa_answer(box: GuildMsgBox) -> void:
	var spec := OS.get_environment("OPENSRO_QA_UNION_ANSWER")
	if spec == "":
		return
	var parts := spec.split(":")
	var wait := int(parts[1]) if parts.size() > 1 else 30
	for i in wait:
		await world.get_tree().process_frame
	if not is_instance_valid(box) or not box.is_visible_in_tree():
		print("QA UNION answer %s: no box open" % spec)
		return
	var b := box.node("GDR_MBIN_BTN_OK" if parts[0] == "yes" else "GDR_MBIN_BTN_CANCEL")
	if b == null:
		return
	var at := b.get_global_rect().get_center()
	print("QA UNION answer %s: clicking %s at %s frame %d" % [spec, b.name, at, Engine.get_frames_drawn()])
	world._qa_push_click(at, MOUSE_BUTTON_LEFT, true)
