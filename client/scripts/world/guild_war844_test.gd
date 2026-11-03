extends SceneTree

## Round 844 (lane V): guild war on the client, READ in sro_client.exe
## (docs/protocol/guild_war.md): the wire (GuildWarNet: 0x7110, the period
## word, 0x3080 kind 10, the replies), the hostile map (HostileData: 0x3109
## and 0x38F5 types 0x19 / 0x1a / 0x1c / 0x1d / 0x1f / 0x23 / 0x32, the same
## bytes server/internal/guild/round844_test.go pins), the red line
## (GuildLineColour), IsEnemy without Alt and the level waiver, and -- against
## the real Media.pk2 -- the guild window's Hostility and Combat panes
## (guild_r.2dt / guild_w.2dt) and the request box's three states
## (ifguildwarrequest / confirm / agree.txt).
##   client/tools/remote_godot.sh script res://scripts/world/guild_war844_test.gd
##
## NEGATIVE (by construction): before round 844 nothing fed the hostile map,
## so the red-line check, the panes' names and the boxes all fail.

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0
var _ends := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var watchdog := create_timer(120.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	_test_wire()
	_test_hostile()
	_test_rules()
	await _test_real()
	_check(_ends == 3, "every part ran to its end (a script error stops one silently): %d of 3" % _ends)
	print("guild_war844_test: %s (%d failure(s))" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _str(s: String) -> PackedByteArray:
	var b := PackedByteArray([s.length() & 0xff, 0])
	b.append_array(s.to_utf8_buffer())
	return b

## E (s:0x5cfd30) as the server's guild.appendWarEntry writes it.
func _entry(id: int, remain: int, idx: int, gold: int, a: int, b: int, pa: int, pb: int) -> PackedByteArray:
	var out := _u32(id)
	out.append_array(_u32(remain))
	out.append(idx)
	for v in [gold, a, b, pa, pb]:
		out.append_array(_u32(v))
	return out

func _test_wire() -> void:
	_check(GuildWarNet.pack_period(1, 0, 1) == (0x400 | (10 << 20)), "the period word: day << 10 | minutes << 20 (0x71a810)")
	_check(GuildWarNet.pack_period(GuildWarNet.DAY_ROWS, 0, 0) == GuildWarNet.UNLIMITED, "an Unlimited part: 0x7fffffff")
	var parts := GuildWarNet.unpack_period(GuildWarNet.pack_period(2, 3, 5))
	_check(int(parts["day"]) == 2 and int(parts["hour"]) == 3 and int(parts["minute"]) == 50, "unpacked: 2d 3h 50m")
	var dec := GuildWarNet.encode_declare("Beta", 10 << 20, 1, 100000)
	var want := _str("Beta")
	want.append(0)
	want.append_array(_u32(10 << 20))
	want.append(1)
	want.append_array(_u32(100000))
	_check(dec == want, "0x7110: str, u8 0, u32 period, u8 index, u32 stake (c:0x824a30)")
	var proc := PackedByteArray([10])
	proc.append_array(_u32(0x11))
	proc.append_array(_str("Alpha"))
	proc.append(0)
	proc.append_array(_u32(10 << 20))
	proc.append(1)
	proc.append_array(_u32(100000))
	var info := GuildWarNet.decode_proclamation(proc)
	_check(String(info.get("guild_name", "")) == "Alpha" and int(info["gold"]) == 100000 and int(info["victory_index"]) == 1
		and int(info["declarer"]) == 0x11, "0x3080 kind 10 decoded (0x885920)")
	_check(GuildWarNet.encode_answer(true) == PackedByteArray([1, 1]) and GuildWarNet.encode_answer(false) == PackedByteArray([1, 0]),
		"the answer {1, 1 / 0} (c:0x820450)")
	var r := GuildWarNet.decode_result(GuildWarNet.OP_ASK_REWARD_RESULT, PackedByteArray([1, 0x40, 0x0d, 3, 0]))
	_check(bool(r["ok"]) and int(r["amount"]) == 200000, "B114 {1, u32}")
	r = GuildWarNet.decode_result(GuildWarNet.OP_DECLARE_RESULT, PackedByteArray([2, 0x3a, 0x4c]))
	_check(not bool(r["ok"]) and int(r["code"]) == 0x4c3a, "B110 {2, 0x4c3a}")

func _guild() -> GuildData:
	var gd := GuildData.new()
	gd.in_guild = true
	gd.guild_id = 3
	gd.guild_name = "Alpha"
	gd.own_name = "Aria"
	var m := GuildData.Member.new()
	m.character_id = 1
	m.member_name = "Aria"
	m.member_class = GuildData.CLASS_MASTER
	gd.members.append(m)
	var m2 := GuildData.Member.new()
	m2.character_id = 5
	m2.member_name = "Cato"
	gd.members.append(m2)
	return gd

func _list_bytes() -> PackedByteArray:
	var b := PackedByteArray([1])
	b.append_array(_entry(7, 90, 2, 200000, 3, 4, 100, 15))
	b.append_array(_str("Beta"))
	return b

func _test_hostile() -> void:
	var gd := _guild()
	var h := gd.hostile
	var banners: Array = []
	var boxes: Array = []
	var countdowns: Array = []
	h.banner.connect(func(k: String, a: Array) -> void: banners.append([k, a]))
	h.box.connect(func(t: String, k: Array, a: Array) -> void: boxes.append([t, k, a]))
	h.countdown.connect(func(s: int) -> void: countdowns.append(s))
	_check(h.parse_list(_list_bytes(), gd.guild_id), "0x3109 parses")
	var w := h.war(7)
	_check(w != null and w.name == "Beta" and w.other_id == 4 and w.own_points == 100 and w.their_points == 15 and w.gold == 200000
		and w.remain == 90 and w.victory_index == 2, "the entry: own side by guild A (0x999260)")
	_check(h.is_hostile("Beta") and not h.is_hostile("Alpha") and not h.is_hostile(""), "is_hostile (0x992a90)")
	h.parse_list(_list_bytes(), gd.guild_id)
	_check(h.count() == 1, "0x3109 only adds; the same war twice is one")
	# 0x19 a second war, Gamma's, as guild B.
	var started := PackedByteArray([0x19])
	started.append_array(_entry(8, 0x7fffffff, 0, 0, 9, 3, 7, 0))
	started.append_array(_str("Gamma"))
	gd.apply_update(started)
	var w8 := h.war(8)
	_check(w8 != null and w8.own_points == 0 and w8.their_points == 7 and w8.remain == 0x7fffffff, "0x19: as guild B, A's points are theirs")
	_check(banners.size() > 0 and banners[-1][0] == "UIIT_MSG_GUILDWAR_GOTOWAR" and banners[-1][1] == ["Alpha", "Gamma"], "GOTOWAR (own, theirs) on the banner")
	# 0x1d: Cato killed Beta's Bram for 115.
	var kill := PackedByteArray([0x1d, 1])
	kill.append_array(_u32(7))
	kill.append_array(_u32(115))
	kill.append_array(_u32(5))
	kill.append_array(_str("Bram"))
	gd.apply_update(kill)
	_check(w.own_points == 215 and gd.member(5).war_kill == 1 and gd.member(5).contribution == 115, "0x1d side 1: points, kills, contribution")
	_check(banners[-1][0] == "UIIT_MSG_GUILDWAR_KILLNEWS" and banners[-1][1] == ["Cato", "Bram", "Bram"], "KILLNEWS")
	var cos := PackedByteArray([0x1d, 2])
	cos.append_array(_u32(7))
	cos.append_array(_u32(1))
	cos.append_array(_u32(1))
	cos.append_array(_str(""))
	cos.append_array(_str("Bram"))
	gd.apply_update(cos)
	_check(w.their_points == 16 and gd.member(1).war_killed == 1 and banners[-1][1][1] == "*Bram", "0x1d side 2, an empty name then the owner: '*' + owner")
	var tick := PackedByteArray([0x1f])
	tick.append_array(_u32(7))
	tick.append_array(_u32(30))
	gd.apply_update(tick)
	_check(w.remain == 30, "0x1f: the seconds left")
	var ren := PackedByteArray([0x23])
	ren.append_array(_u32(9))
	ren.append_array(_str("Gamma2"))
	gd.apply_update(ren)
	_check(w8.name == "Gamma2" and h.is_hostile("Gamma2"), "0x23: a hostile guild renamed")
	var ending := PackedByteArray([0x1b])
	ending.append_array(_u32(7))
	gd.apply_update(ending)
	_check(h.ending and countdowns == [60] and boxes[-1][1] == ["UIIT_CTL_GUILDWAR_ENDCOUNT"] and boxes[-1][2] == ["Alpha", "Beta"],
		"0x1b: ENDCOUNT in a box and the 60 s countdown")
	var ended := PackedByteArray([0x1c])
	ended.append_array(_u32(7))
	ended.append_array(_u32(3))
	gd.apply_update(ended)
	_check(h.war(7) == null and not h.is_hostile("Beta") and not h.ending, "0x1c: the war gone")
	_check(boxes[-1][0] == "UIIT_STT_EVENTGUIDE" and boxes[-1][1] == ["UIIT_MSG_GUILDWAR_WINERGUILD"] and boxes[-1][2] == ["Beta"], "won (0x5b25a0)")
	var lost := PackedByteArray([0x1c])
	lost.append_array(_u32(8))
	lost.append_array(_u32(9))
	gd.apply_update(lost)
	_check(boxes[-1][1] == ["UIIT_MSG_GUILDWAR_LOSEGUILD"] and h.count() == 0, "lost")
	h.pending = 1
	var lines: Array = []
	h.line.connect(func(k: String, a: Array) -> void: lines.append(k))
	var out := PackedByteArray([0x32, 2])
	out.append_array(_str("Beta"))
	gd.apply_update(out)
	_check(lines == ["UIIT_MSG_GUILDWARERR_REQUISITION_TIME_OUT"] and h.pending == 0, "0x32 sub 2 to the declarer: TIME_OUT")
	gd.clear()
	_check(h.count() == 0, "the guild cleared, the wars too")
	_ends += 1

func _test_rules() -> void:
	var hostile := func(n: String) -> bool: return n == "Beta"
	_check(GuildLineColour.colour_for("Beta", "Alpha", Callable(), hostile) == Color8(0xff, 0, 0), "a hostile guild's line: 0xffff0000")
	_check(GuildLineColour.colour_for("Delta", "Alpha", Callable(), hostile) == GuildLineColour.OTHER, "another guild's: blue")
	_check(JobPvpNet.is_enemy(4, 4, false, false, true) and not JobPvpNet.is_enemy(4, 4, false, false, false),
		"IsEnemy: a hostile guild's member without Alt (0x9de780)")
	_check(not JobPvpNet.is_enemy(1, 3, false, true, true), "two job suits: no enemy even at war")
	_check(JobPvpNet.player_click(true, false, true, false, 10, true) == "attack" and JobPvpNet.player_click(true, false, true, false, 10) == "level",
		"the level-20 rule waived at war (0x988a70)")
	_check(GuildWarPanes.group_digits(200000) == "200,000" and GuildWarPanes.time_left(3725, "U") == "01 : 02 : 05"
		and GuildWarPanes.time_left(0x7fffffff, "U") == "U", "the pane's number and time formats")
	_check(GuildWarRequestBox.check_input("", "Alpha", 0) == ["UIIT_MSG_GUILDWAR_HGN_INPUT", []]
		and String(GuildWarRequestBox.check_input("Alpha", "Alpha", 0)[0]) == "UIIT_MSG_GUILDWARERR_SELFWAR"
		and String(GuildWarRequestBox.check_input("B", "Alpha", 0)[0]) == "UIIT_MSG_GUILDERR_INVALID_GUILDNAME_LEN"
		and String(GuildWarRequestBox.check_input("Beta", "Alpha", 500000001)[0]) == "UIIT_MSG_GUILDWARERR_LIMIT_COMPENSATION"
		and GuildWarRequestBox.check_input("Beta", "Alpha", 500000000).is_empty(), "state 1's refusals in 0x71c480's order")
	_ends += 1

func _text(n: Node) -> String:
	if n == null:
		return "<none>"
	if n is Label:
		return (n as Label).text
	var t := TwoDtBuilder.text_of(n)
	if t != "":
		return t
	var l := n.get_node_or_null("Text") as Label
	return l.text if l != null else ""

func _test_real() -> void:
	if not FileAccess.file_exists(MEDIA):
		print("SKIP the real-archive part (no %s)" % MEDIA)
		# A skip is this part's end (CI has no archives, docs/LEGAL.md); without
		# this the end count read 2 of 3 on every CI run since round 844.
		_ends += 1
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
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	var gw: GuildWindow = panels.call("_guild_window")
	_check(gw != null, "the guild window builds from the archive")
	if gw == null:
		return
	var gd := _guild()
	gw.data = gd
	gw.own_name = "Aria"
	var panes := GuildWarPanes.new(gw)
	panes.refresh()
	var c := func(path: Array) -> Control: return gw.control(path)
	_check(c.call([548, 62]).visible and not c.call([548, 541]).visible, "no war: <No hostile Guild> (62), the values hidden")
	_check(_text(c.call([548, 62])) == "<No hostile Guild>", "62's text from the archive")
	_check(not (c.call([164, 2000, 52]) as BaseButton).disabled and (c.call([164, 2000, 53]) as BaseButton).disabled,
		"the master: Declare enabled, End disabled with no war (0x5bca80)")
	_check(_text(c.call([164, 2000, 52])) == "Request to start the war" and _text(c.call([164, 2000, 53])) == "Request to end the war",
		"52 / 53's captions")
	gd.hostile.parse_list(_list_bytes(), gd.guild_id)
	panes.refresh()
	_check(_text(c.call([164, 2000, 225, 127])) == "Beta" and _text(c.call([164, 2000, 225, 128])) == "-"
		and not c.call([164, 2000, 231, 127]).visible, "the hostility rows: the name, '-', an empty row hidden (0x5bd740)")
	_check(c.call([164, 2000, 135]).visible and not c.call([164, 2000, 155]).visible, "nothing selected: 135 shown, the details hidden")
	panes.selected = 7
	panes.refresh()
	_check(_text(c.call([164, 2000, 155])) == "Beta" and _text(c.call([164, 2000, 148])) == "Unconfirmed"
		and _text(c.call([164, 2000, 160])) == "Unconfirmed" and not c.call([164, 2000, 135]).visible,
		"a war selected: the name, the leader and count Unconfirmed (0x5bcb80)")
	_check(not (c.call([164, 2000, 53]) as BaseButton).disabled, "End enabled with a war")
	_check(_text(c.call([548, 257, 518])) == "Beta" and _text(c.call([548, 541])) == "Beta" and _text(c.call([548, 542])) == "100"
		and _text(c.call([548, 543])) == "15" and _text(c.call([548, 544])) == "10000",
		"the combat pane: name, own points, theirs, victory points (0x5af160)")
	_check(_text(c.call([548, 545])).begins_with("200,000 ") and _text(c.call([548, 546])) == "00 : 01 : 30",
		"the wager grouped with UIIT_STT_GOLD and the time left (%s / %s)" % [_text(c.call([548, 545])), _text(c.call([548, 546]))])
	_check(not c.call([548, 62]).visible, "62 hidden with a war")
	gd.member(5).contribution = 300
	panes.refresh()
	_check(_text(c.call([548, 250, 503])) == "Cato" and _text(c.call([548, 250, 505])) == "300" and _text(c.call([548, 250, 504])) == "1",
		"the contribution rows (OURS order: by points)")
	gd.hostile.ending = true
	panes.refresh()
	_check((c.call([164, 2000, 53]) as BaseButton).disabled, "End disabled while the countdown runs (+0x7c8)")
	gd.members[0].member_class = GuildData.CLASS_MEMBER
	panes.refresh()
	_check((c.call([164, 2000, 52]) as BaseButton).disabled, "not the master: Declare disabled")

	# The request box, its three states from the archive's resinfo files.
	var box := GuildWarRequestBox.new()
	_check(box.build_box(builder, GuildWarRequestBox.State.INPUT, {}), "state 1 builds (ifguildwarrequest.txt)")
	root.add_child(box)
	await process_frame
	_check(box.size == Vector2(350, 257) and box.caption.text == "Input window", "350x257, UIIT_STT_INPUT_BOX")
	var point := box.node("GDR_REQUEST_GUILDWAR_POINT_COMBOBOX").find_children("*", "OptionButton", true, false)
	var pc: OptionButton = point[0] if not point.is_empty() else null
	_check(pc != null and pc.item_count == 8 and pc.get_item_text(0) == "Unlimited" and pc.get_item_text(7) == "300000" and pc.selected == 2,
		"the points combo: Unlimited, 5000 .. 300000, index 2")
	var days := box.node("GDR_REQUEST_GUILDWAR_PERIOD_DAY_COMBOBOX").find_children("*", "OptionButton", true, false)
	var dc: OptionButton = days[0] if not days.is_empty() else null
	_check(dc != null and dc.item_count == 32 and dc.get_item_text(0) == "00Day" and dc.get_item_text(31) == "Unlimited" and dc.selected == 1,
		"the day combo: 00Day .. 30Day, Unlimited, 1 chosen")
	var mins := box.node("GDR_REQUEST_GUILDWAR_PERIOD_MIN_COMBOBOX").find_children("*", "OptionButton", true, false)
	var mc: OptionButton = mins[0] if not mins.is_empty() else null
	_check(mc != null and mc.item_count == 7 and mc.get_item_text(5) == "50Minute", "the minute combo by ten")
	var got: Array = []
	box.proclaim.connect(func(n: String, i: int, p: int, g: int) -> void: got.append_array([n, i, p, g]))
	box.guild_name = "Beta"
	box.set_gold(150000)
	box.own_guild_name = "Alpha"
	box.button("GDR_REQUEST_GUILDWAR_BUTTON_OK").pressed.emit()
	_check(got == ["Beta", 2, GuildWarNet.pack_period(1, 0, 0), 150000], "OK passes the name, index, period and wager (got %s)" % [got])
	var confirm := GuildWarRequestBox.new()
	_check(confirm.build_box(builder, GuildWarRequestBox.State.CONFIRM, {"guild_name": "Beta", "point_index": 0,
		"period": GuildWarNet.pack_period(0, 0, 1), "gold": 150000}), "state 2 builds (ifguildwarconfirm.txt)")
	_check(_text(confirm.node("GDR_REQUEST_GUILDWAR_MSG_01")) == "Proclaim war against [Beta]guild."
		and _text(confirm.node("GDR_REQUEST_GUILDWAR_POINT")) == "Unlimited"
		and _text(confirm.node("GDR_REQUEST_GUILDWAR_PERIOD")) == "00Day 00Hour 10Minute"
		and _text(confirm.node("GDR_REQUEST_GUILDWAR_MONEY")) == "150,000",
		"state 2: SANCTIONWAR_01 with the name and the read-only terms")
	var agree := GuildWarRequestBox.new()
	_check(agree.build_box(builder, GuildWarRequestBox.State.AGREE, {"guild_name": "Alpha", "point_index": 1,
		"period": GuildWarNet.UNLIMITED, "gold": 150000, "own_gold": 1000}), "state 3 builds (ifguildwaragree.txt)")
	_check(_text(agree.node("GDR_REQUEST_GUILDWAR_MSG_01")) == "[Alpha]guild has proclaimed war."
		and _text(agree.node("GDR_REQUEST_GUILDWAR_PERIOD")) == "Unlimited" and agree.caption.text == "Agreement window",
		"state 3: CONSENTWAR_01 with the declarer's guild")
	_check(agree.button("GDR_REQUEST_GUILDWAR_BUTTON_OK").disabled, "state 3: OK disabled while the master's gold is below the wager")
	var answers: Array = []
	agree.answered.connect(func(a: bool) -> void: answers.append(a))
	agree.button("GDR_REQUEST_GUILDWAR_BUTTON_CANCEL").pressed.emit()
	_check(answers == [false], "state 3's Cancel refuses")
	confirm.free()
	panels.queue_free()
	await process_frame
	_ends += 1
