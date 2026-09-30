extends SceneTree

## Round 657: the unique monster notices -- UniqueNoticeNet's framing against
## server/internal/session/uniquenotice.go, the line 0x874ea0 picks for each
## named unique and the generic one, and the blue GDR_WARNING_WND banner.
## Loaded by path and driven through call(), so against a client without
## the handler it reports FAIL lines instead of failing to compile.
##
## The text table here is SYNTHETIC: each UIIT_ key maps to a made-up
## template that names the key, so a line shows which key was chosen.

const NET_PATH := "res://scripts/net/unique_notice.gd"
const NOTICE_PATH := "res://scripts/ui/hud/hud_notice.gd"
const WORLD_PATH := "res://scripts/World3D.gd"
const CLIENT_PATH := "res://scripts/net/net_client.gd"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Synthetic templates: "<key>" plus a %s where the real row takes one.
const TEXT := {
	"UIIT_MSG_APPEAR_TIGER_GIRL": "<APPEAR_TIGER_GIRL>",
	"UIIT_MSG_APPEAR_IYUTARU": "<APPEAR_IYUTARU>",
	"UIIT_MSG_APPEAR_URRUCHI": "<APPEAR_URRUCHI>",
	"UIIT_MSG_APPEAR_BONELORD": "<APPEAR_BONELORD>",
	"UIIT_MSG_APPEAR_TAHOMET": "<APPEAR_TAHOMET>",
	"UIIT_MSG_APPEAR_UNIC": "<APPEAR_UNIC %s>",
	"UIIT_MSG_DEAD_TIGER_GIRL": "<DEAD_TIGER_GIRL>",
	"UIIT_MSG_DEAD_IYUTARU": "<DEAD_IYUTARU>",
	"UIIT_MSG_DEAD_URRUCHI": "<DEAD_URRUCHI>",
	"UIIT_MSG_DEAD_BONELORD": "<DEAD_BONELORD>",
	"UIIT_MSG_DEAD_UNIC": "<DEAD_UNIC [%s]>",
	"UIIT_MSG_ANYONE_DEAD_TIGER_GIRL": "<ANYONE_DEAD_TIGER_GIRL [%s]>",
	"UIIT_MSG_ANYONE_DEAD_IYUTARU": "<ANYONE_DEAD_IYUTARU [%s]>",
	"UIIT_MSG_ANYONE_DEAD_URRUCHI": "<ANYONE_DEAD_URRUCHI [%s]>",
	"UIIT_MSG_ANYONE_DEAD_BONELORD": "<ANYONE_DEAD_BONELORD [%s]>",
	"UIIT_MSG_ANYONE_DEAD_TAHOMET": "<ANYONE_DEAD_TAHOMET [%s]>",
	"UIIT_MSG_ANYONE_DEAD_UNIC": "<ANYONE_DEAD_UNIC [%s] [%s]>",
}

func _payload(kind: int, ref_id: int, killer: String = "", with_name: bool = false) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(6)
	out.encode_u16(0, kind)
	out.encode_u32(2, ref_id)
	if with_name:
		var b := killer.to_utf8_buffer()
		var n := PackedByteArray()
		n.resize(2)
		n.encode_u16(0, b.size())
		out.append_array(n)
		out.append_array(b)
	return out

func _initialize() -> void:
	var net: Script = load(NET_PATH)
	if net == null:
		_check(false, "UniqueNoticeNet exists (%s)" % NET_PATH)
		_finish()
		return
	var consts: Dictionary = net.get_script_constant_map()
	_check(consts.get("OP_UNIQUE_NOTICE") == 0x0110, "the opcode is the server's 0x0110")
	_check(consts.get("KIND_SPAWN") == 0x0C05 and consts.get("KIND_KILL") == 0x0C06, "the words are 0x300C's 0x0C05 / 0x0C06")
	_check(consts.get("SYSTEM_TYPE") == 0, "the system line is type 0 (0x7781b0 with 0)")

	# Decoding: the server's exact bytes (TestUniqueNoticeWire).
	var s = net.call("decode", PackedByteArray([0x05, 0x0c, 0xa2, 0x07, 0, 0]))
	_check(s != null and s.kind == 0x0C05 and s.ref_obj_id == 1954, "a spawn decodes to 0x0C05 and the RefObjID")
	var k = net.call("decode", PackedByteArray([0x06, 0x0c, 0xa2, 0x07, 0, 0, 4, 0, 65, 114, 105, 97]))
	_check(k != null and k.kind == 0x0C06 and k.ref_obj_id == 1954 and k.killer == "Aria", "a kill decodes the killer's name")
	for bad in [PackedByteArray([5, 12, 1]), PackedByteArray([7, 12, 1, 0, 0, 0]), PackedByteArray([6, 12, 1, 0, 0, 0]),
			PackedByteArray([6, 12, 1, 0, 0, 0, 5, 0, 65]), PackedByteArray([5, 12, 1, 0, 0, 0, 9])]:
		_check(net.call("decode", bad) == null, "malformed %s decodes to null" % [bad])

	# The line for each unique the handler names, and the generic one.
	var text := func(key: String) -> String: return TEXT.get(key, "")
	var cases := [
		# [name key, spawn line, "???" kill line, killer kill line]
		["SN_MOB_CH_TIGERWOMAN", "<APPEAR_TIGER_GIRL>", "<DEAD_TIGER_GIRL>", "<ANYONE_DEAD_TIGER_GIRL [Aria]>"],
		["SN_MOB_KK_ISYUTARU", "<APPEAR_IYUTARU>", "<DEAD_IYUTARU>", "<ANYONE_DEAD_IYUTARU [Aria]>"],
		["SN_MOB_OA_URUCHI", "<APPEAR_URRUCHI>", "<DEAD_URRUCHI>", "<ANYONE_DEAD_URRUCHI [Aria]>"],
		["SN_MOB_TK_BONELORD", "<APPEAR_BONELORD>", "<DEAD_BONELORD>", "<ANYONE_DEAD_BONELORD [Aria]>"],
		# Tahomet has no DEAD_ line: "???" takes DEAD_UNIC with its name.
		["SN_MOB_RM_TAHOMET", "<APPEAR_TAHOMET>", "<DEAD_UNIC [Mob]>", "<ANYONE_DEAD_TAHOMET [Aria]>"],
		# Any other unique: the generic lines, with the monster's name.
		["SN_MOB_EU_KERBEROS", "<APPEAR_UNIC Mob>", "<DEAD_UNIC [Mob]>", "<ANYONE_DEAD_UNIC [Aria] [Mob]>"],
		# An _L2 row is not the named one (the comparison is exact).
		["SN_MOB_CH_TIGERWOMAN_L2", "<APPEAR_UNIC Mob>", "<DEAD_UNIC [Mob]>", "<ANYONE_DEAD_UNIC [Aria] [Mob]>"],
	]
	for c in cases:
		var sp = net.call("decode", _payload(0x0C05, 1))
		var nobody = net.call("decode", _payload(0x0C06, 1, "???", true))
		var by = net.call("decode", _payload(0x0C06, 1, "Aria", true))
		var got := [net.call("line_for", sp, c[0], "Mob", text), net.call("line_for", nobody, c[0], "Mob", text),
			net.call("line_for", by, c[0], "Mob", text)]
		_check(got[0] == c[1] and got[1] == c[2] and got[2] == c[3],
			"%s: appeared / killed by ??? / killed by Aria -> %s (want %s)" % [c[0], got, c.slice(1)])

	_check(net.call("sprintf", "[%s] has killed [%s]. 100%%", ["A", "B"]) == "[A] has killed [B]. 100%", "swprintf's %s in order and %%")
	_check(net.call("sprintf", "[%s]", []) == "[]", "a missing argument prints nothing")

	# The banner: GDR_WARNING_WND's own y, frame and fill (0x78cbed, 0x78cc0d.., 0x78cd00..).
	var hn: Script = load(NOTICE_PATH)
	var hconsts: Dictionary = hn.get_script_constant_map()
	var warn = hconsts.get("STYLE_WARNING")
	_check(warn is Dictionary and warn["y"] == 130 and (warn["fill"] as Color).to_html(false) == "00345c"
		and String(warn["corner"]).ends_with("com_warning_corner.ddj") and String(warn["edge"]).ends_with("com_warning_edge.ddj")
		and String(warn["edge2"]).ends_with("com_warning_edge2.ddj"),
		"GDR_WARNING_WND: y 130, com_warning_* frame, fill (0, 52, 92) (got %s)" % [warn])
	var note = hconsts.get("STYLE_NOTICE")
	_check(note is Dictionary and note["y"] == 100 and (note["fill"] as Color).to_html(false) == "802d43", "GDR_NOTICE: y 100, fill (128, 45, 67)")
	var has_fill := false
	for d in hn.get_script_method_list():
		if d["name"] == "fill_alpha_for":
			has_fill = true
	if has_fill:
		_check(hn.call("fill_alpha_for", 255) == 128 and hn.call("fill_alpha_for", 0) == 1 and hn.call("fill_alpha_for", 127) == 64,
			"the fill's alpha is -0x80 - (0xff - a) / 2: 128 at full, 1 at none")
		var b: Control = hn.new()
		root.add_child(b)
		b.call("setup", null, warn)
		b.call("show_notice", "<ANYONE_DEAD_TIGER_GIRL [Aria]>")
		_check(b.visible and b.position.y == 130.0 and b.call("remaining_ms") == 7000 and b.call("alpha") == 255,
			"the banner shows at y 130 for 7000 ms at full alpha")
		_check(b.call("style_name") == "GDR_WARNING_WND" and (b.call("fill_color") as Color).to_html(false) == "00345c", "and fills dark blue")
		b.call("advance", 6000)
		_check(b.call("alpha") == 1000 * 255 / 2000, "then fades: %d at 1000 ms left" % b.call("alpha"))
		b.call("advance", 1000)
		_check(not b.visible, "and is gone after 7000 ms")
		b.free()
	else:
		_check(false, "HudNotice has fill_alpha_for (the class's fill)")

	# The wiring: the signal, the handler, the warning banner's style.
	var client_src := FileAccess.get_file_as_string(CLIENT_PATH)
	_check(client_src.contains("UniqueNoticeNet.OP_UNIQUE_NOTICE") and client_src.contains("signal unique_notice"),
		"NetClient dispatches OP_UNIQUE_NOTICE to unique_notice")
	var world_src := FileAccess.get_file_as_string(WORLD_PATH)
	_check(world_src.contains("NetClient.unique_notice.connect(_on_unique_notice)")
		and world_src.contains("_hud_warning.setup(_ui_builder, HudNotice.STYLE_WARNING)"),
		"World3D shows it on GDR_WARNING_WND in its own style")
	_check(world_src.contains("_log_system(line, UniqueNoticeNet.SYSTEM_TYPE)"), "and writes the system line")
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
