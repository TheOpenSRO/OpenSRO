extends SceneTree

## Round 711 (lane C1): the party window, the party settings dialog and the
## invitation box, against what the client does (docs/protocol/party_gui.md
## §1, §1b, §2). The layouts are synthetic but carry the authored names, IDs
## and rects of resinfo\ifparty.txt, ifpartyslot.txt, ifsetpartymode.txt
## and ifmessagebox.txt's MsgBoxINIF (no textures, no archive text: never real
## game data); the party state is driven with round 710's golden fixtures.
##
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_party_pane_test.gd

const FIX := "res://scripts/net/fixtures/party/"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _fx(name: String) -> PackedByteArray:
	var f := FileAccess.open(FIX + name + ".hex", FileAccess.READ)
	var out := PackedByteArray()
	if f == null:
		_check(false, "fixture %s is readable" % name)
		return out
	for tok in f.get_as_text().split(" ", false):
		if tok.strip_edges() != "":
			out.append(tok.strip_edges().hex_to_int())
	return out

func _c(control_name: String, type: String, rect: String, id: int, text: String = "",
		ddj: String = "", halign: int = 0, style: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"%d\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"%d\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, halign, id, rect, style, text]

func _layout(section: String, body: String) -> String:
	return "Interface Text\n\nSection = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section, body]

## ifparty.txt's controls at their authored rects (MEASURED from the archive,
## round 711), front to back as the file lists them.
func _ifparty() -> String:
	var b := ""
	b += _c("GDR_PTY_OPTION_ITEM_DECO", "CIFStatic", "45,312,12,12", 53, "", "interface\\ifcommon\\com_diamond.ddj", 1)
	b += _c("GDR_PTY_OPTION_EXP_DECO", "CIFStatic", "190,312,12,12", 52, "", "interface\\ifcommon\\com_diamond.ddj", 1)
	b += _c("GDR_PTY_PARTY_LEADER_RACE_MARK", "CIFStatic", "53,34,16,16", 15, "", "interface\\ifcommon\\com_kindred_china16.ddj", 0, 64)
	b += _c("GDR_PTY_PARTY_LEADER", "CIFStatic", "33,27,12,12", 14, "", "interface\\ifcommon\\com_pt_leader.ddj", 0, 64)
	b += _c("GDR_PTY_OPTION_ITEM", "CIFStatic", "57,312,114,17", 50, "", "", 1)
	b += _c("GDR_PTY_OPTION_EXP", "CIFStatic", "202,312,114,17", 49, "", "", 1)
	b += _c("GDR_PTYSLOT_BTN_EXITFROMPARTY", "CIFButton", "316,38,44,20", 48, "", "interface\\party\\pt_button.ddj", 1)
	b += _c("GDR_PTY_GAUGE_MPGAUGE", "CIFGauge", "54,57,136,4", 47, "", "interface\\party\\pt_mp.ddj")
	b += _c("GDR_PTY_GAUGE_HPGAUGE", "CIFGauge", "54,53,136,4", 46, "", "interface\\party\\pt_hp.ddj")
	b += _c("GDR_PTY_STATIC_GUILD", "CIFStatic", "201,46,104,17", 45, "", "", 1)
	b += _c("GDR_PTY_STATIC_LEVEL_DATA", "CIFStatic", "172,32,19,17", 44)
	b += _c("GDR_PTY_STATIC_LEVEL", "CIFStatic", "156,32,14,17", 43, "UIIT_STT_LEVEL_LV")
	b += _c("GDR_PTY_STATIC_NAME", "CIFStatic", "71,32,83,17", 42)
	b += _c("GDR_PTY_PICTURE", "CIFStaticWithPictureClip", "9,33,28,28", 41)
	for i in range(6, -1, -1):
		b += _c("GDR_PTY_PARTYSLOT_%d" % i, "CIFPartySlot", "2,%d,360,36" % (69 + 33 * i), 30 + i,
			"UIIT_CTL_LEAVE_PARTY", "interface\\party\\pt_slot.ddj")
	b += _c("GDR_PTY_BTN_MATCH", "CIFButton", "230,339,80,24", 22, "UIIT_CTL_PARTYMATCH_MAINBUTTEN", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_PTY_BTN_SETTING", "CIFButton", "143,339,80,24", 21, "UIIT_CTL_PARTY_SETTING", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_PTY_BTN_INVITE", "CIFButton", "56,339,80,24", 20, "UIIT_CTL_INVITE_PARTY", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_PARTY_FRAMEL", "CIFSubFrame", "0,0,364,303", 1, "UIIT_STT_PARTY_INFO", "interface\\frame\\sframe_wnd_")
	return _layout("Create", b)

func _ifpartyslot() -> String:
	var b := ""
	b += _c("GDR_PTYSLOT_BTN_EXITFROMPARTY", "CIFButton", "314,7,44,20", 18, "", "interface\\party\\pt_button.ddj", 1)
	b += _c("GDR_PTYSLOT_GAUGE_MPGAUGE", "CIFGauge", "43,26,136,4", 17, "", "interface\\party\\pt_mp.ddj")
	b += _c("GDR_PTYSLOT_GAUGE_HPGAUGE", "CIFGauge", "43,22,136,4", 16, "", "interface\\party\\pt_hp.ddj")
	b += _c("GDR_PTYSLOT_STATIC_GUILD_STATIC", "CIFStatic", "228,7,46,8", 15, "", "interface\\party\\pt_guildname_02.ddj", 1)
	b += _c("GDR_PTYSLOT_STATIC_GUILD", "CIFStatic", "199,14,104,17", 14, "", "", 1)
	b += _c("GDR_PTYSLOT_STATIC_LEVEL_DATA", "CIFStatic", "161,4,19,17", 13)
	b += _c("GDR_PTYSLOT_STATIC_LEVEL", "CIFStatic", "145,4,14,17", 12, "UIIT_STT_LEVEL_LV")
	b += _c("GDR_PTYSLOT_STATIC_NAME", "CIFStatic", "63,4,80,17", 11)
	b += _c("GDR_PTYSLOT_RACE", "CIFStatic", "44,5,16,16", 10)
	b += _c("GDR_PTYSLOT_PICTURE", "CIFStaticWithPictureClip", "2,4,28,28", 9)
	return _layout("Create", b)

func _ifsetpartymode() -> String:
	var b := ""
	b += _c("GDR_SETPARTYMODE_BTN_CANCEL", "CIFButton", "156,158,76,24", 21, "UIIT_CTL_NO", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_SETPARTYMODE_BTN_OK", "CIFButton", "68,158,76,24", 20, "UIIT_CTL_YES", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_SETPARTYMODE_ALLOW_INVITATION", "CIFStatic", "12,140,240,12", 18, "UIIT_STT_PARTY_INVITATION_ANYONE")
	b += _c("GDR_SETPARTYMODE_CB_ALLOW_INVITATION", "CIFCheckBox", "260,132,16,16", 17, "", "interface\\ifcommon\\com_radiobutton_off.ddj")
	b += _c("GDR_SETPARTYMODE_RBTN_ITEM", "CIFRadioButton", "155,76,120,44", 14)
	b += _c("GDR_SETPARTYMODE_RBTN_EXP", "CIFRadioButton", "24,76,120,44", 13)
	b += _c("GDR_SETPARTYMODE_STATIC_MESSAGE1", "CIFStatic", "7,42,285,20", 10, "UIIT_STT_SET_PARTY_INFO_MSG", "", 1)
	return _layout("Create", b)

func _ifmessagebox() -> String:
	var b := ""
	b += _c("GDR_MBIN_STATIC_MESSAGE5", "CIFStatic", "6,154,294,12", 8, "", "", 1)
	b += _c("GDR_MBIN_BTN_CERTIFY", "CIFButton", "112,99,76,24", 202, "UIIT_CTL_CONFIRM", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_MBIN_BTN_CANCEL", "CIFButton", "152,99,76,24", 201, "UIIT_CTL_NO", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_MBIN_BTN_OK", "CIFButton", "72,99,76,24", 200, "UIIT_CTL_YES", "interface\\ifcommon\\com_button.ddj", 1)
	b += _c("GDR_MBIN_STATIC_MESSAGE4", "CIFStatic", "6,66,288,12", 4, "", "", 1)
	b += _c("GDR_MBIN_STATIC_MESSAGE3", "CIFStatic", "6,66,288,12", 3, "", "", 1)
	b += _c("GDR_MBIN_STATIC_MESSAGE2", "CIFStatic", "6,70,300,12", 2, "", "", 1)
	b += _c("GDR_MBIN_STATIC_MESSAGE1", "CIFStatic", "0,52,300,12", 1, "", "", 1)
	return _layout("MsgBoxINIF", b)

## Synthetic text: every key reads as itself in brackets, so a check can tell
## which key a control shows.
func _text_table() -> UiTextTable:
	var rows := PackedStringArray()
	for k in ["UIIT_STT_PARTY_INFO", "UIIT_STT_PARTY_JOIN_ANYONE", "UIIT_STT_PARTY_EXP_SHARE",
			"UIIT_STT_PARTY_EXP_SELF", "UIIT_STT_PARTY_ITEM_SHARE", "UIIT_STT_PARTY_ITEM_SELF",
			"UIIT_STT_NO_PARTY_LEADER", "UIIT_STT_NO_GUILD", "UIIT_STT_PARTY_DISSOLVE",
			"UIIT_CTL_BAN_PARTY", "UIIT_CTL_LEAVE_PARTY", "UIIT_STT_LEVEL_LV", "UIIT_STT_CONFIRM_BOX",
			"UIIT_STT_PARTY_PROPOSAL_ASK", "UIIT_STT_ACCEPT", "UIIT_STT_REFUSE"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	rows.append("1\tUIIT_STT_PARTY_SOMEUSER\t\t\t\t\t\t\t[%s]")
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, _text_table())
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifparty.txt"] = UiLayoutParser.parse(_ifparty())
	cache["resinfo\\ifpartyslot.txt"] = UiLayoutParser.parse(_ifpartyslot())
	cache["resinfo\\ifsetpartymode.txt"] = UiLayoutParser.parse(_ifsetpartymode())
	cache["resinfo\\ifmessagebox.txt"] = UiLayoutParser.parse(_ifmessagebox())
	return builder

func _label_text(n: Node) -> String:
	if n is Label:
		return (n as Label).text
	if n == null:
		return "(null)"
	for child_name in ["Text", "ButtonLabel"]:
		var l := n.get_node_or_null(child_name) as Label
		if l != null:
			return l.text
	return "(no text)"

func _label_color(n: Node) -> Color:
	var l: Label = n as Label if n is Label else (n.get_node_or_null("Text") as Label if n != null else null)
	if l == null and n != null:
		l = n.get_node_or_null("ButtonLabel") as Label
	return l.get_theme_color("font_color") if l != null else Color.TRANSPARENT

func _make_pane(builder: UiBuilder, party: PartyState) -> Array:
	var pane := Control.new()
	pane.name = "GDR_PARTY"
	pane.size = Vector2(364, 337)
	root.add_child(pane)
	var built := builder.build_section(builder.load_layout("resinfo\\ifparty.txt"), "Create")
	pane.add_child(built)
	var p := HudPartyPane.new(builder, pane, party)
	return [pane, p]

# --- The window ----------------------------------------------------------------

func _test_geometry(builder: UiBuilder) -> void:
	var party := PartyState.new()
	var made := _make_pane(builder, party)
	var p: HudPartyPane = made[1]
	for pair in [["GDR_PTY_BTN_INVITE", Vector2(56, 339)], ["GDR_PTY_BTN_SETTING", Vector2(143, 339)],
			["GDR_PTY_BTN_MATCH", Vector2(230, 339)], ["GDR_PTYSLOT_BTN_EXITFROMPARTY", Vector2(316, 38)],
			["GDR_PTY_PARTYSLOT_0", Vector2(2, 69)], ["GDR_PTY_PARTYSLOT_6", Vector2(2, 267)]]:
		var n := p.node(pair[0])
		_check(n != null and n.position == pair[1], "%s at %s (ifparty.txt)" % pair)
	_check(p.row_node(0, "GDR_PTYSLOT_STATIC_NAME") != null and p.row_node(0, "GDR_PTYSLOT_STATIC_NAME").position == Vector2(63, 4),
		"each row carries ifpartyslot.txt: the name at 63,4 in the row")
	_check(p.row_node(3, "GDR_PTYSLOT_BTN_EXITFROMPARTY") != null and p.row_node(3, "GDR_PTYSLOT_BTN_EXITFROMPARTY").position == Vector2(314, 7),
		"... and its button at 314,7")
	var cap := UiBuilder.subframe_caption(p.node("GDR_PARTY_FRAMEL"))
	_check(cap != null and cap.position.x == 10.0 and cap.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
		"the subframe's caption static at x 10, centred (CIFSubFrame 0x81a530)")
	_check(cap != null and absf(cap.get_meta(UiBuilder.AUTHORED_RECT_META).size.x - 344.0) < 0.01,
		"... the frame's width less 20 wide")
	(made[0] as Node).queue_free()

func _test_out_of_party(builder: UiBuilder) -> void:
	var party := PartyState.new()
	party.set_preferences(1, 0, 0)
	var made := _make_pane(builder, party)
	var p: HudPartyPane = made[1]
	var cap := UiBuilder.subframe_caption(p.node("GDR_PARTY_FRAMEL"))
	_check(cap != null and cap.text == "<UIIT_STT_PARTY_INFO>", "caption: PARTY_INFO alone")
	party.set_preferences(1, 0, 1)
	_check(cap != null and cap.text == "<UIIT_STT_PARTY_INFO> (<UIIT_STT_PARTY_JOIN_ANYONE>)",
		"caption with anyone-may-invite: the suffix in brackets (0x6d5ef0)")
	_check(_label_text(p.node("GDR_PTY_OPTION_EXP")) == "<UIIT_STT_PARTY_EXP_SHARE>"
		and _label_text(p.node("GDR_PTY_OPTION_ITEM")) == "<UIIT_STT_PARTY_ITEM_SELF>",
		"type line from the preferences: Exp share, Item free-for-all")
	_check(_label_color(p.node("GDR_PTY_OPTION_EXP")) == Color8(167, 155, 122), "type line greyed out of a party")
	var name_l := p.node("GDR_PTY_STATIC_NAME") as Label
	_check(name_l.text == "<UIIT_STT_NO_PARTY_LEADER>" and name_l.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
		"name: NO_PARTY_LEADER, centred (0x6d6d00)")
	_check(not p.node("GDR_PTY_STATIC_LEVEL").visible and not p.node("GDR_PTY_STATIC_LEVEL_DATA").visible,
		"Lv and the level hidden")
	_check(_label_text(p.node("GDR_PTY_STATIC_GUILD")) == "<UIIT_STT_NO_GUILD>", "guild: NO_GUILD")
	_check((p.node("GDR_PTYSLOT_BTN_EXITFROMPARTY") as BaseButton).disabled, "Dismiss disabled")
	_check(not (p.node("GDR_PTY_BTN_INVITE") as BaseButton).disabled and not (p.node("GDR_PTY_BTN_SETTING") as BaseButton).disabled,
		"Invite and Set enabled")
	_check(not p.node("GDR_PTY_PARTY_LEADER").visible, "leader flag hidden")
	_check(not (p.row(0).get_node("PartySlot") as Control).visible, "every row cleared")
	_check((p.node("GDR_PTY_GAUGE_HPGAUGE") as TextureProgressBar).value == 100.0, "gauges full (on the disabled art)")
	# Buttons out of a party.
	var got: Array = []
	p.create_requested.connect(func(t: int) -> void: got.append(["create", t]))
	p.invite_requested.connect(func(t: int) -> void: got.append(["invite", t]))
	p.settings_requested.connect(func() -> void: got.append(["set"]))
	p.leave_requested.connect(func() -> void: got.append(["leave"]))
	p.press_invite()
	_check(got.is_empty(), "Invite with nothing selected sends nothing (0x778120 == 0)")
	p.selected_target = func() -> int: return 201
	p.press_invite()
	_check(got.size() == 1 and got[0] == ["create", 201], "Invite out of a party: create with 201 (0x7060)")
	p.press_set()
	_check(got.size() == 2 and got[1] == ["set"], "Set out of a party opens the dialog")
	p.press_dismiss()
	_check(got.size() == 2, "Dismiss out of a party does nothing")
	(made[0] as Node).queue_free()

func _test_in_party_leader(builder: UiBuilder) -> void:
	var party := PartyState.new()
	party.own_jid = 101
	party.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	var made := _make_pane(builder, party)
	var p: HudPartyPane = made[1]
	p.race_of_model = func(ref: int) -> int: return 1 if ref == 1908 else 0
	p.own_vitals = func() -> Array: return [50.0, 100.0, 25.0, 100.0]
	p.refresh()
	var name_l := p.node("GDR_PTY_STATIC_NAME") as Label
	_check(name_l.text == "Aria" and name_l.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT, "leader row: Aria, left-aligned")
	_check(_label_color(name_l) == Color8(255, 225, 148), "... in (255,225,148)")
	_check(_label_text(p.node("GDR_PTY_STATIC_LEVEL_DATA")) == "10" and p.node("GDR_PTY_STATIC_LEVEL").visible, "level 10 and Lv shown")
	_check(p.node("GDR_PTY_PARTY_LEADER").visible and p.node("GDR_PTY_PARTY_LEADER_RACE_MARK").visible, "leader flag and race mark shown")
	_check(absf((p.node("GDR_PTY_GAUGE_HPGAUGE") as TextureProgressBar).value - 50.0) < 0.01,
		"the leader is the player: live HP 50 of 100")
	_check(not (p.node("GDR_PTYSLOT_BTN_EXITFROMPARTY") as BaseButton).disabled, "Dismiss enabled for the leader")
	_check((p.node("GDR_PTY_BTN_SETTING") as BaseButton).disabled, "Set disabled in a party (screenshot 12)")
	_check(not (p.node("GDR_PTY_BTN_INVITE") as BaseButton).disabled, "Invite enabled for the leader")
	_check(_label_color(p.node("GDR_PTY_OPTION_EXP")) == Color8(240, 217, 165), "type line bright in a party")
	_check(_label_text(p.node("GDR_PTY_OPTION_ITEM")) == "<UIIT_STT_PARTY_ITEM_SHARE>", "type line from the party's flags (3)")
	_check((p.row(0).get_node("PartySlot") as Control).visible and _label_text(p.row_node(0, "GDR_PTYSLOT_STATIC_NAME")) == "Bram",
		"row 0: Bram")
	_check(_label_text(p.row_node(0, "GDR_PTYSLOT_STATIC_GUILD")) == "Wolves", "Bram's guild")
	_check(_label_text(p.row_node(0, "GDR_PTYSLOT_STATIC_LEVEL_DATA")) == "7", "Bram's level")
	_check(absf((p.row_node(0, "GDR_PTYSLOT_GAUGE_HPGAUGE") as TextureProgressBar).value - 100.0) < 0.01,
		"Bram's HP from his tenths (10/10)")
	var ban := p.row_node(0, "GDR_PTYSLOT_BTN_EXITFROMPARTY")
	_check(ban.visible and _label_text(ban) == "<UIIT_CTL_BAN_PARTY>", "the leader sees Banish on Bram's row")
	_check(not (p.row(1).get_node("PartySlot") as Control).visible, "row 1 empty")
	_check(_label_text(p.node("GDR_PTY_STATIC_GUILD")) == "<UIIT_STT_NO_GUILD>"
		and _label_color(p.node("GDR_PTY_STATIC_GUILD")) == Color8(153, 153, 153),
		"Aria (the player) with no guild: a grey NO_GUILD")
	var got: Array = []
	p.kick_requested.connect(func(j: int) -> void: got.append(["kick", j]))
	p.invite_requested.connect(func(t: int) -> void: got.append(["invite", t]))
	p.leave_requested.connect(func() -> void: got.append(["leave"]))
	p.settings_requested.connect(func() -> void: got.append(["set"]))
	(ban as BaseButton).pressed.emit()
	_check(got.size() == 1 and got[0] == ["kick", 201], "Banish sends 0x7063 for list index row + 1 (Bram, 201)")
	p.selected_target = func() -> int: return 301
	p.press_invite()
	_check(got.size() == 2 and got[1] == ["invite", 301], "Invite in a party, leading: 0x7062 for 301")
	p.press_set()
	_check(got.size() == 2, "Set in a party does nothing")
	p.press_dismiss()
	_check(got.size() == 3 and got[2] == ["leave"], "Dismiss is leave (0x6d5a00 -> 0x81cad0)")
	(made[0] as Node).queue_free()

func _test_in_party_member(builder: UiBuilder) -> void:
	var party := PartyState.new()
	party.own_jid = 201
	party.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	var made := _make_pane(builder, party)
	var p: HudPartyPane = made[1]
	_check((p.node("GDR_PTYSLOT_BTN_EXITFROMPARTY") as BaseButton).disabled, "a member's Dismiss is disabled")
	_check((p.node("GDR_PTY_BTN_INVITE") as BaseButton).disabled, "a member cannot invite without anyone-may-invite")
	var btn := p.row_node(0, "GDR_PTYSLOT_BTN_EXITFROMPARTY")
	_check(btn.visible and _label_text(btn) == "<UIIT_CTL_LEAVE_PARTY>", "the player's own row shows Leave")
	var got: Array = []
	p.leave_requested.connect(func() -> void: got.append("leave"))
	p.kick_requested.connect(func(j: int) -> void: got.append(j))
	p.invite_requested.connect(func(t: int) -> void: got.append(["invite", t]))
	(btn as BaseButton).pressed.emit()
	_check(got == ["leave"], "a member's row button leaves")
	p.selected_target = func() -> int: return 301
	p.press_invite()
	_check(got.size() == 1, "... and Invite sends nothing")
	(made[0] as Node).queue_free()
	# Anyone may invite (flags 7): the member's Invite works.
	var party2 := PartyState.new()
	party2.own_jid = 201
	var info := PartyNet.decode_party_info(_fx("3065_two_members"))
	info.flags = 0x07
	party2.handle(PartyNet.OP_PARTY_INFO, PartyNet.encode_party_info(info))
	var made2 := _make_pane(builder, party2)
	var p2: HudPartyPane = made2[1]
	_check(not (p2.node("GDR_PTY_BTN_INVITE") as BaseButton).disabled, "with anyone-may-invite a member's Invite is enabled")
	var got2: Array = []
	p2.invite_requested.connect(func(t: int) -> void: got2.append(t))
	p2.selected_target = func() -> int: return 301
	p2.press_invite()
	_check(got2 == [301], "... and sends 0x7062")
	(made2[0] as Node).queue_free()

func _test_job_party(builder: UiBuilder) -> void:
	var party := PartyState.new()
	party.own_jid = 101
	party.own_job_state = func() -> int: return 1
	party.handle(PartyNet.OP_PARTY_INFO, _fx("3065_two_members"))
	var made := _make_pane(builder, party)
	var p: HudPartyPane = made[1]
	_check(party.job_party, "a job-mode player's party is a job party (+0x0c = job != 4)")
	_check((p.node("GDR_PTY_STATIC_NAME") as Label).text == "*Aria" and _label_text(p.row_node(0, "GDR_PTYSLOT_STATIC_NAME")) == "*Bram",
		"names drawn *%s")
	_check(_label_text(p.row_node(0, "GDR_PTYSLOT_STATIC_GUILD")) == "<UIIT_STT_NO_GUILD>", "guilds hidden")
	(made[0] as Node).queue_free()

func _test_updates_refresh(builder: UiBuilder) -> void:
	var party := PartyState.new()
	party.own_jid = 101
	party.handle(PartyNet.OP_PARTY_INFO, _fx("3065_one_member"))
	var made := _make_pane(builder, party)
	var p: HudPartyPane = made[1]
	_check(not (p.row(0).get_node("PartySlot") as Control).visible, "alone: no rows")
	party.handle(PartyNet.OP_EVENT, _fx("3864_k2_joined"))
	_check((p.row(0).get_node("PartySlot") as Control).visible, "kind 2 fills row 0 at once")
	party.handle(PartyNet.OP_EVENT, _fx("3864_k3_left"))
	_check(not (p.row(0).get_node("PartySlot") as Control).visible, "kind 3 clears it")
	party.handle(PartyNet.OP_EVENT, _fx("3864_k1_dissolved"))
	_check((p.node("GDR_PTY_STATIC_NAME") as Label).text == "<UIIT_STT_NO_PARTY_LEADER>", "kind 1: back to the empty window")
	(made[0] as Node).queue_free()

# --- The settings dialog ---------------------------------------------------------

func _test_settings(builder: UiBuilder) -> void:
	var party := PartyState.new()
	party.set_preferences(1, 0, 1)
	var dlg := PartySettingsDialog.new()
	_check(dlg.build(builder, party), "the settings dialog builds from ifsetpartymode.txt")
	root.add_child(dlg)
	_check(dlg.position == Vector2(32, 85) and dlg.size == Vector2(300, 200), "child 70 at 32,85, 300x200")
	_check((dlg.get_node("Caption") as Label).text == "<UIIT_STT_CONFIRM_BOX>", "caption CONFIRM_BOX")
	var exp_group := dlg.find_child("GDR_SETPARTYMODE_RBTN_EXP", true, false) as Control
	var dot0 := exp_group.get_node_or_null("Item0") as Control
	var dot1 := exp_group.get_node_or_null("Item1") as Control
	var lab1 := exp_group.get_node_or_null("Label1") as Label
	_check(dot0 != null and dot0.position == Vector2(3, 4) and dot0.size == Vector2(16, 16), "radio item 0's dot at 3,4, 16x16")
	_check(dot1 != null and dot1.position == Vector2(3, 24), "item 1 a pitch of 20 below")
	_check(lab1 != null and lab1.position == Vector2(23, 27) and lab1.text == "<UIIT_STT_PARTY_EXP_SELF>",
		"item 1's label at the dot + (20, 3): EXP_SELF")
	_check(dlg.exp_choice == 0 and dlg.item_choice == 1, "opens on the block: exp share, item free-for-all")
	_check(dlg.anyone_box != null and dlg.anyone_box.button_pressed, "... and the anyone box checked")
	var got: Array = []
	dlg.confirmed.connect(func(e: int, i: int, a: int) -> void: got.append([e, i, a]))
	dlg.choose("exp", 1)
	dlg.choose("item", 0)
	dlg.anyone_box.button_pressed = false
	_check(not (dlg.anyone_box.get_node("GDR_STATIC_SELECTED") as CanvasItem).visible, "unchecking hides the check mark")
	var yes := dlg.find_child("GDR_SETPARTYMODE_BTN_OK", true, false) as BaseButton
	yes.pressed.emit()
	_check(got == [[0, 1, 0]], "Yes writes exp 0, item 1, anyone 0 (0x6d6470)")
	_check(not dlg.visible, "and closes")
	var dlg2 := PartySettingsDialog.new()
	dlg2.build(builder, party)
	root.add_child(dlg2)
	var got2: Array = []
	dlg2.confirmed.connect(func(e: int, i: int, a: int) -> void: got2.append(1))
	(dlg2.find_child("GDR_SETPARTYMODE_BTN_CANCEL", true, false) as BaseButton).pressed.emit()
	_check(got2.is_empty() and not dlg2.visible, "No only closes")

# --- The invitation box ------------------------------------------------------------

func _test_invitation(builder: UiBuilder) -> void:
	var box := PartyInvitePopup.new()
	_check(box.build(builder, "Aria", 0x05), "the invitation box builds on MsgBoxINIF")
	root.add_child(box)
	_check(box.size == Vector2(300, 176), "300x176 (kind 6's +0x54(0x12c, 0xb0))")
	var m1 := box.find_child("GDR_MBIN_STATIC_MESSAGE1", true, false) as Control
	_check(m1 != null and m1.position == Vector2(16, 48) and _label_text(m1) == "[Aria]", "SOMEUSER with the name at 16,48")
	var m2 := box.find_child("GDR_MBIN_STATIC_MESSAGE2", true, false) as Control
	_check(m2 != null and m2.position == Vector2(16, 64) and _label_text(m2) == "<UIIT_STT_PARTY_PROPOSAL_ASK>", "PROPOSAL_ASK at 16,64")
	var exp_box := box.find_child("GDR_MBIN_STATIC_MESSAGE3_Box", true, false) as Control
	var item_box := box.find_child("GDR_MBIN_STATIC_MESSAGE4_Box", true, false) as Control
	_check(exp_box != null and exp_box.position == Vector2(44, 93) and _label_text(exp_box) == "<UIIT_STT_PARTY_EXP_SHARE>",
		"flags 5: the exp box at 44,93 says share")
	_check(item_box != null and item_box.position == Vector2(156, 93) and _label_text(item_box) == "<UIIT_STT_PARTY_ITEM_SELF>",
		"... the item box at 156,93 says free-for-all")
	var m5 := box.find_child("GDR_MBIN_STATIC_MESSAGE5", true, false) as Control
	_check(m5 != null and m5.position == Vector2(6, 121) and _label_text(m5) == "<UIIT_STT_PARTY_JOIN_ANYONE>", "anyone may invite at 6,121")
	var ok := box.find_child("GDR_MBIN_BTN_OK", true, false) as BaseButton
	var no := box.find_child("GDR_MBIN_BTN_CANCEL", true, false) as BaseButton
	_check(ok.position == Vector2(72, 139) and _label_text(ok) == "<UIIT_STT_ACCEPT>", "Accept at 72,139")
	_check(no.position == Vector2(152, 139) and _label_text(no) == "<UIIT_STT_REFUSE>", "Refuse at 152,139")
	_check(not (box.find_child("GDR_MBIN_BTN_CERTIFY", true, false) as CanvasItem).visible, "the third button hidden")
	var got: Array = []
	box.answered.connect(func(a: bool) -> void: got.append(a))
	ok.pressed.emit()
	_check(got == [true] and not box.visible, "Accept answers yes and closes")

func _initialize() -> void:
	var builder := _builder()
	_test_geometry(builder)
	_test_out_of_party(builder)
	_test_in_party_leader(builder)
	_test_in_party_member(builder)
	_test_job_party(builder)
	_test_updates_refresh(builder)
	_test_settings(builder)
	_test_invitation(builder)
	if _failures == 0:
		print("hud_party_pane_test: all checks passed")
		quit(0)
	else:
		print("hud_party_pane_test: %d check(s) FAILED" % _failures)
		quit(1)
