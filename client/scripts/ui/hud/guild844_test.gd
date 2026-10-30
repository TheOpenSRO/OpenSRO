extends SceneTree

## Round 844 (lane G): the guild window's member highlight, order, name
## modes and scroll; the notice bar and its view; the permission pane; the
## command buttons' rules; the notice write window. Against the real
## Media.pk2's guild.2dt and resinfo\ifguildnotifywrite.txt (READ notes in
## GuildWindow and GuildNoticeWrite).
##   godot4 --headless --path client --script res://scripts/ui/hud/guild844_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const SELECT_MID := "interface\\ifcommon\\com_bar01select_mid.ddj"
const PLAIN_MID := "interface\\ifcommon\\com_bar01_mid.ddj"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _member(id: int, n: String, cls: int, lv: int, gp: int, perm: int = 0, nick: String = "", siege: int = 0) -> GuildData.Member:
	var m := GuildData.Member.new()
	m.character_id = id
	m.member_name = n
	m.member_class = cls
	m.level = lv
	m.gp_donation = gp
	m.permission = perm
	m.nickname = nick
	m.siege_authority = siege
	m.online = true
	return m

func _data(own: String) -> GuildData:
	var d := GuildData.new()
	d.in_guild = true
	d.guild_id = 7
	d.guild_name = "OFWS"
	d.level = 5
	d.gp = 100
	d.notice_title = "Raid tonight"
	d.notice_body = "Meet at Jangan west gate.\nBring potions."
	d.own_name = own
	var list: Array[GuildData.Member] = [
		_member(1, "Pain", GuildData.CLASS_MASTER, 90, 500, 0xffffffff, "Boss", 1),
		_member(2, "Tobi", GuildData.CLASS_MEMBER, 40, 900, GuildData.PERM_INVITE, "Pengis", 0x20),
		_member(3, "Ann", GuildData.CLASS_MEMBER, 70, 20, 0, "Zed"),
		_member(4, "Zoe", GuildData.CLASS_MEMBER, 70, 300, GuildData.PERM_UNION_CHAT, "Ace"),
		_member(5, "Bob", GuildData.CLASS_MEMBER, 10, 0),
		_member(6, "Cid", GuildData.CLASS_MEMBER, 55, 5),
		_member(7, "Dee", GuildData.CLASS_MEMBER, 56, 6),
		_member(8, "Eve", GuildData.CLASS_MEMBER, 57, 7),
	]
	d.members = list
	return d

## The textures a row bar draws (left, mid, right), by resource path.
func _bar_mid(row: Control) -> String:
	var bar := row.get_node_or_null("RowBar")
	if bar == null:
		return ""
	for c in bar.get_children():
		if c is TextureRect and (c as TextureRect).texture != null:
			var p := (c as TextureRect).texture.resource_path
			if p.contains("_mid"):
				return p
	# load_texture keys the art by archive path in a meta when it has no path.
	for c in bar.get_children():
		if c is TextureRect and (c as TextureRect).texture != null:
			return str((c as TextureRect).texture.get_meta("pk2_path", ""))
	return ""

func _names(w: GuildWindow) -> Array:
	var out: Array = []
	for row in w.member_rows():
		var n := TwoDtBuilder.child(row, GuildWindow.ROW_NAME)
		out.append(TwoDtBuilder.text_of(n) if n != null and n.visible else "")
	return out

func _run() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var w := GuildWindow.new()
	root.add_child(w)
	_check(w.build_guild(builder), "guild.2dt builds")
	w.data = _data("Pain")
	w.own_name = "Pain"
	w.hide()
	await process_frame
	w.show()
	await process_frame
	var rows := w.member_rows()
	_check(rows.size() == 6, "six member rows (got %d)" % rows.size())

	# 1. The highlight: the row's own bar art becomes com_bar01select_.
	var sel_tex := builder.load_texture(SELECT_MID)
	var plain_tex := builder.load_texture(PLAIN_MID)
	_check(sel_tex != null and plain_tex != null, "both bar arts load from the archive")
	var mid_of := func(row: Control) -> Texture2D:
		var bar := row.get_node_or_null("RowBar")
		return (bar.get_child(1) as TextureRect).texture if bar != null and bar.get_child_count() > 1 else null
	_check(rows.all(func(r: Control) -> bool: return mid_of.call(r) == plain_tex), "no row selected: every bar com_bar01_")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	rows[1].gui_input.emit(press)
	var id1 := int(rows[1].get_meta("guild_member", 0))
	_check(w.selected_member == id1 and id1 != 0, "a left press selects the row's member (%d)" % id1)
	_check(mid_of.call(rows[1]) == sel_tex, "the selected row draws com_bar01select_")
	_check(GuildWindow.row_selected(rows[1]) and not GuildWindow.row_selected(rows[0]), "only that row is marked")
	var bar1 := rows[1].get_node_or_null("RowBar")
	_check(bar1 != null and bar1.get_index() == 0, "the bar stays under the row's texts (index 0)")
	# The frame is (255, 178, 82) at inset 2 (MEASURED): read it off the art.
	var img := sel_tex.get_image() if sel_tex != null else null
	if img != null:
		if img.is_compressed():
			img.decompress()
		var c := img.get_pixel(2, 2)
		_check(c.r8 == 255 and c.g8 == 178 and c.b8 == 82, "the select art's frame is (255, 178, 82) (got %s)" % [c])
		var inside := img.get_pixel(5, 12)
		_check(inside.r8 == 0 and inside.g8 == 0 and inside.b8 == 0, "and it is a frame: black inside (got %s)" % [inside])
	rows[3].gui_input.emit(press)
	_check(mid_of.call(rows[3]) == sel_tex and mid_of.call(rows[1]) == plain_tex, "another press moves the highlight")
	var hover := InputEventMouseMotion.new()
	rows[4].gui_input.emit(hover)
	_check(mid_of.call(rows[4]) == plain_tex, "hover changes nothing (CNIFGuildUserSlot handles 0x201 only)")
	var keep := w.selected_member
	w.fill_members()
	_check(w.selected_member == keep and rows.filter(func(r: Control) -> bool: return GuildWindow.row_selected(r)).size() == 1,
		"a refill keeps the selection on its member (0x5b8580)")

	# 2. The order (0x5ba310): name asc, level desc, class (master first), GP desc.
	_check(_names(w) == ["Ann", "Bob", "Cid", "Dee", "Eve", "Pain"], "name order (got %s)" % [_names(w)])
	w.press_sort(GuildWindow.SORT_LEVEL)
	_check(_names(w) == ["Pain", "Ann", "Zoe", "Eve", "Dee", "Cid"], "level order, highest first (got %s)" % [_names(w)])
	w.press_sort(GuildWindow.SORT_CLASS)
	_check(_names(w)[0] == "Pain", "class order: the master first (got %s)" % [_names(w)])
	w.press_sort(GuildWindow.SORT_GP)
	_check(_names(w) == ["Tobi", "Pain", "Zoe", "Ann", "Eve", "Dee"], "GP order, most first (got %s)" % [_names(w)])
	var hdr := w.control([GuildWindow.ID_INFO, 402]) as BaseButton
	if hdr != null:
		hdr.pressed.emit()
	_check(w.sort_mode == GuildWindow.SORT_CLASS, "the Grade header (402) sorts by class")
	w.press_sort(GuildWindow.SORT_NAME)

	# 3. The name modes (0x5ba970): name, grant name, fortress position.
	var mode_btn := w.control([GuildWindow.ID_INFO, GuildWindow.NAME_MODE_BUTTON]) as BaseButton
	_check(mode_btn != null, "the name-mode button 23 exists")
	if mode_btn != null:
		mode_btn.pressed.emit()
	# A member with no grant name shows "" and sorts first (the multimap's key
	# is the shown text, 0x5ba310 case 0 with +0x7a1 = 1).
	_check(w.name_mode == 1 and _names(w) == ["", "", "", "", "Ace", "Boss"], "mode 1 shows grant names, ordered by them (got %s)" % [_names(w)])
	var h400 := w.control([GuildWindow.ID_INFO, 400])
	_check(TwoDtBuilder.text_of(h400) == builder.resolve_text("UIIT_STT_TITLE"), "header 400 reads UIIT_STT_TITLE")
	w.press_name_mode()
	var tobi := w.data.member(2)
	_check(w.name_mode == 2 and w.shown_name(tobi) == builder.resolve_text("UIIT_STT_FORT_GUILD_ENGINEER")
		and w.shown_name(w.data.member(1)) == builder.resolve_text("UIIT_STT_FORT_GUILD_COMMANDER")
		and w.shown_name(w.data.member(3)) == "", "mode 2 shows the fortress positions (role 0x20 %s)" % w.shown_name(tobi))
	w.press_name_mode()
	_check(w.name_mode == 0 and TwoDtBuilder.text_of(h400) == builder.resolve_text("UIIT_STT_GUILDSMAN"), "back to names")

	# 4. The scroll: 8 members, 6 rows.
	w.member_scroll_to(2)
	_check(w.member_scroll_line() == 2 and _names(w)[0] == "Cid", "the scroll moves the rows (got %s)" % [_names(w)])
	w.member_scroll_to(0)

	# 5. The notice bar and its view.
	var view := w.control([GuildWindow.ID_INFO, GuildWindow.ID_NOTICE_VIEW])
	_check(view != null and not view.visible, "the notice view starts hidden")
	var slot := w.control([GuildWindow.ID_INFO, GuildWindow.ID_NOTICE_SLOT])
	slot.gui_input.emit(press)
	_check(w.notice_open and view.visible, "a press on the bar opens the view")
	_check(w.notice_body_shown().begins_with("Meet at Jangan"), "the view shows the body (got %s)" % w.notice_body_shown())
	_check((slot as TextureRect).texture == builder.load_texture(GuildWindow.NOTICE_ON_ART), "the bar's art turns on")
	var ok := w.control([GuildWindow.ID_INFO, GuildWindow.ID_NOTICE_VIEW, GuildWindow.NOTICE_VIEW_OK]) as BaseButton
	if ok != null:
		ok.pressed.emit()
	_check(not w.notice_open and not view.visible and (slot as TextureRect).texture == builder.load_texture(GuildWindow.NOTICE_OFF_ART),
		"the view's Confirm closes it and the bar's art turns off")
	var title_node := w.control(GuildWindow.NOTICE_TEXT)
	_check(TwoDtBuilder.text_of(title_node) == "Raid tonight", "the bar shows the title")

	# 6. The buttons (0x5b5150): the master.
	var b := func(id: int) -> BaseButton: return w.control([GuildWindow.ID_INFO, id]) as BaseButton
	_check(not b.call(37).disabled and not b.call(39).disabled and not b.call(38).disabled, "the master: invite, ban, permissions on")
	_check(TwoDtBuilder.text_of(b.call(38)) == builder.resolve_text("UIIT_CTL_GUILD_UNION_CHAT_GRANT"), "38 reads Give authority for the master")
	var pencil := w.control(GuildWindow.NOTICE_EDIT) as BaseButton
	_check(pencil != null and not pencil.disabled, "the master's pencil is on")
	var asked := [false]
	w.notice_write_requested.connect(func() -> void: asked[0] = true)
	pencil.pressed.emit()
	_check(asked[0], "the pencil asks for the write window")

	# 7. The permission pane, as the master.
	b.call(38).pressed.emit()
	_check(w.permission_pane_open(), "38 opens the permission pane")
	_check(not b.call(37).visible, "the command buttons hide while it is up")
	var grows := w.grant_rows()
	_check(grows.size() == 6, "six permission rows (got %d)" % grows.size())
	var first_name := TwoDtBuilder.text_of(TwoDtBuilder.child(grows[0], GuildWindow.GRANT_ROW_NAME))
	_check(first_name == "Ann", "the rows are the members but the master, by name (got %s)" % first_name)
	var tobi_row: Control = null
	for r in grows:
		if TwoDtBuilder.text_of(TwoDtBuilder.child(r, GuildWindow.GRANT_ROW_NAME)) == "Tobi":
			tobi_row = r
	if tobi_row == null:
		w._grant_scroll.scroll_to(2)
		for r in w.grant_rows():
			if TwoDtBuilder.text_of(TwoDtBuilder.child(r, GuildWindow.GRANT_ROW_NAME)) == "Tobi":
				tobi_row = r
	_check(tobi_row != null, "Tobi's row is reachable")
	if tobi_row != null:
		var c0 := TwoDtBuilder.child(tobi_row, 105) as BaseButton
		_check(c0 != null and c0.button_pressed and not c0.disabled, "Tobi's join check shows his 0x01, editable")
		w.set_grant(2, 4, true)
		w.set_grant(2, 0, false)
	_check(w.permission_changes() == [[2, GuildData.PERM_NOTICE]], "the change list holds Tobi's new bits (got %s)" % [w.permission_changes()])
	var header := w.control([GuildWindow.ID_INFO, GuildWindow.ID_GRANT_PANE, GuildWindow.GRANT_UNION_HEADER])
	_check(header != null and header.tooltip_text == GuildWindow.format_d(builder.resolve_text("UIIT_MSG_GUILD_UNION_CHAT_TOOLTIP"), [3, 12]),
		"the union header's tooltip counts Pain and Zoe, + 1 (got %s)" % (header.tooltip_text if header != null else ""))
	var sent: Array = []
	w.permissions_submitted.connect(func(ch: Array) -> void: sent.append(ch))
	var gok := w.control([GuildWindow.ID_INFO, GuildWindow.ID_GRANT_PANE, GuildWindow.GRANT_OK]) as BaseButton
	if gok != null:
		gok.pressed.emit()
	_check(sent.size() == 1 and sent[0] == [[2, GuildData.PERM_NOTICE]], "Confirm sends the changed rows (got %s)" % [sent])
	_check(not w.permission_pane_open() and b.call(37).visible, "and closes the pane, the buttons back")

	# 8. A member: no ban, read-only pane, Check authority.
	w.data = _data("Ann")
	w.own_name = "Ann"
	w.refresh_guild()
	_check(b.call(37).disabled and b.call(39).disabled, "Ann (no bits): invite and ban off")
	_check(TwoDtBuilder.text_of(b.call(38)) == builder.resolve_text("UIIT_CTL_GUILD_UNION_CHAT_CONFIRM") and not b.call(38).disabled,
		"38 reads Check authority for a member, on")
	_check(pencil.disabled, "no 0x10: the pencil is off")
	b.call(38).pressed.emit()
	var c105 := TwoDtBuilder.child(w.grant_rows()[0], 105) as BaseButton
	_check(c105 != null and c105.disabled, "a member's pane is read-only")
	w.close_permission_pane()

	# 9. The notice write window (resinfo\ifguildnotifywrite.txt).
	var nw := GuildNoticeWrite.new()
	root.add_child(nw)
	_check(nw.build_write(builder), "ifguildnotifywrite builds")
	_check(nw.size == Vector2(439, 307), "439 x 307 (ginterface GDR_GUILD_NOTIFY_WRITE)")
	var t := nw.node(GuildNoticeWrite.TITLE_EDIT) as LineEdit
	_check(t != null and t.max_length == 0x7f, "the title takes 0x7f characters")
	var refused: Array = []
	var got: Array = []
	nw.refused.connect(func(code: int) -> void: refused.append(code))
	nw.submitted.connect(func(tt: String, bb: String) -> void: got.append([tt, bb]))
	nw.press_ok()
	_check(refused == [0x4c22], "an empty title is 0x4c22")
	nw.set_texts("Hello", "")
	nw.press_ok()
	_check(refused == [0x4c22, 0x4c23], "an empty body is 0x4c23")
	nw.set_texts("Hello", "x".repeat(2000))
	_check(nw.body_text().length() == 0x3ff, "the body stops at 0x3ff (got %d)" % nw.body_text().length())
	var count_line := nw.node(GuildNoticeWrite.COUNT_LINE)
	var count_text := ""
	if count_line is Label:
		count_text = (count_line as Label).text
	elif count_line != null and count_line.get_node_or_null("Text") is Label:
		count_text = (count_line.get_node("Text") as Label).text
	_check(count_text.contains("1023/") and count_text.contains("1023"), "the count line shows the body's length (got %s)" % count_text)
	nw.set_texts("Hello", "World")
	nw.press_ok()
	_check(got == [["Hello", "World"]], "Completed sends the title and body (got %s)" % [got])

	# 10. The level-up window (resinfo\ifguildlevelup.txt).
	var lw := GuildLevelUpWindow.new()
	root.add_child(lw)
	_check(lw.build_level_up(builder, 77, "OFWS", 2), "ifguildlevelup builds")
	_check(lw.size == Vector2(360, 220), "360 x 220 (ginterface GDR_GUILD_LEVEL_UP)")
	_check(lw.shown(GuildLevelUpWindow.NEED_GP).ends_with(":  50400 GP"), "level 2 needs 50400 GP (got %s)" % lw.shown(GuildLevelUpWindow.NEED_GP))
	_check(lw.shown(GuildLevelUpWindow.NEED_GOLD).contains(":  9000000 "), "and 9000000 gold (got %s)" % lw.shown(GuildLevelUpWindow.NEED_GOLD))
	_check(lw.shown(GuildLevelUpWindow.QUESTION).contains("OFWS") and lw.shown(GuildLevelUpWindow.QUESTION).contains("3"),
		"the question names the guild and level 3 (got %s)" % lw.shown(GuildLevelUpWindow.QUESTION))
	var lv_sent: Array = []
	lw.confirmed.connect(func(n: int) -> void: lv_sent.append(n))
	lw.press_ok()
	_check(lv_sent == [77], "Confirm sends the NPC")

	# 11. The hand-over window (resinfo\ifguildmasterleave.txt).
	var mw := GuildMasterLeaveWindow.new()
	root.add_child(mw)
	_check(mw.build_master_leave(builder, 77, _data("Pain"), "Pain"), "ifguildmasterleave builds")
	_check(mw.size == Vector2(249, 315), "249 x 315 (ginterface GDR_GUILDMASTER_LEAVE)")
	var refused2: Array = []
	var asked2: Array = []
	mw.refused.connect(func(k: String) -> void: refused2.append(k))
	mw.confirm_wanted.connect(func(n: int, id: int, who: String) -> void: asked2.append([n, id, who]))
	mw.choose_name("Pain")
	mw.press_ok()
	_check(refused2 == ["UIIT_MSG_MLEAVEERR_USERNOTEXIST"], "the master's own name is refused")
	mw.choose_name("Tobi")
	mw.press_ok()
	_check(asked2 == [[77, 2, "Tobi"]], "a member asks the confirm (got %s)" % [asked2])

	# 12. The donation window (resinfo\ifguildpointup.txt).
	var dw := GuildDonateWindow.new()
	root.add_child(dw)
	_check(dw.build_donate(builder, "OFWS", 100), "ifguildpointup builds")
	var dsent: Array = []
	var drefused: Array = []
	dw.submitted.connect(func(n: int) -> void: dsent.append(n))
	dw.refused.connect(func(c: int) -> void: drefused.append(c))
	dw.set_amount(101)
	dw.press_ok()
	_check(drefused == [GuildManageNet.LOCAL_SP_SHORT] and dsent.is_empty(), "more than the SP is refused")
	dw.set_amount(40)
	dw.press_ok()
	_check(dsent == [40], "40 SP sent")

	# 13. 0x38F5 types 0x14 and 0x16 (GuildData).
	var d := _data("Pain")
	var b14 := PackedByteArray([0x14, 1])
	b14.append_array(GuildOpsNet._u32(3))
	b14.append_array(GuildOpsNet._u32(0x18))
	d.apply_update(b14)
	_check(d.member(3).permission == 0x18, "type 0x14 sets Ann's permission")
	var b16 := PackedByteArray([0x16, 2, 0x54])
	b16.append_array(GuildOpsNet._u32(2))
	b16.append_array(PackedByteArray([0, 0xff, 0xff, 0xff, 0xff, 1]))
	b16.append_array(GuildOpsNet._u32(1))
	b16.append_array(PackedByteArray([10, 0, 0, 0, 0, 0]))
	d.apply_update(b16)
	_check(d.master() != null and d.master().member_name == "Tobi" and d.member(1).member_class == 10
		and d.member(1).permission == 0 and d.member(2).siege_authority == 1, "type 0x16 mask 0x54: the hand-over")
	# The window follows: Tobi is now master, Pain's buttons go.
	w.data = d
	w.own_name = "Pain"
	w.refresh_guild()
	_check(not w.is_master() and b.call(37).disabled, "the old master loses the master's buttons")
