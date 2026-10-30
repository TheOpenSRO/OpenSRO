extends PartyMatchBox
class_name GuildWarRequestBox

## Round 844 (lane V): CIFRequestGuildWar ("RequestGuildWar", 0x79bbb0;
## the state +0x7b0 set by 0x71b620), READ in sro_client.exe and MEASURED in
## its resinfo files (docs/protocol/guild_war.md):
##
## - **State 1, input** (0x71b070): 350x257, UIIT_STT_INPUT_BOX,
##   ifguildwarrequest.txt's Create, Condition, Message and InputGuild: the
##   victory points (combo 23: "Unlimited", then 5000 .. 300000; default
##   index 2), the wager (money button 28 -> the gold box; 40 shows it
##   grouped), the period (combos 24 day "00Day".."30Day", 25 hour
##   "00Hour".."23Hour", 26 minute "00Minute".."50Minute" by ten, each ending
##   with "Unlimited"; defaults 1 day, 0, 0), the name (edit 55, 12
##   characters, focused). OK (0x71c480 state 1) refuses, each as a system
##   line and the GDR_WARNING_WND banner: an empty name HGN_INPUT; the own
##   guild's SELFWAR; a length outside 2..12 GUILDERR_INVALID_GUILDNAME_LEN;
##   the name filter ERRINPUT; over 500,000,000 LIMIT_COMPENSATION with
##   "500,000,000". Otherwise this box closes and state 2 opens.
## - **State 2, confirm** (0x71aad0): 350x222, UIIT_STT_CONFIRM_BOX,
##   ifguildwarconfirm.txt: SANCTIONWAR_01 with the name, _02, and the points,
##   the period ("%s %s %s" or "Unlimited") and the wager read-only. OK sends
##   0x7110.
## - **State 3, agree** (0x71a9b0): 350x222, UIIT_STT_AGREEMENT_BOX,
##   ifguildwaragree.txt: CONSENTWAR_01 with the declarer's guild, _02 and the
##   same three; OK (5) disabled while the master's own gold is below the
##   wager. OK / Cancel answer 0x3080 {1, 1 / 0}.

enum State { INPUT = 1, CONFIRM = 2, AGREE = 3 }

const REQUEST_LAYOUT := "resinfo\\ifguildwarrequest.txt"
const CONFIRM_LAYOUT := "resinfo\\ifguildwarconfirm.txt"
const AGREE_LAYOUT := "resinfo\\ifguildwaragree.txt"
const INPUT_SIZE := Vector2(350, 257)
const BOX_SIZE := Vector2(350, 222)
const NAME_MAX := 12

var state := State.INPUT
var guild_name := ""
var point_index := 2
var day := 1
var hour := 0
var minute_index := 0
var gold := 0
## The proclaimed-on master's gold (state 3's OK rule).
var own_gold := 0

var _point_combo: OptionButton
var _day_combo: OptionButton
var _hour_combo: OptionButton
var _minute_combo: OptionButton
var _name_edit: LineEdit

## State 1's OK passed (name, point index, packed period, gold).
signal proclaim(name: String, point_index: int, period: int, gold: int)
## State 1's OK refused: the text key and its values.
signal refused(key: String, args: Array)
## State 1's money button: the gold box is wanted.
signal gold_wanted()
## State 3's answer.
signal answered(accept: bool)

func build_box(builder: UiBuilder, which: int, values: Dictionary = {}) -> bool:
	state = which
	guild_name = String(values.get("guild_name", ""))
	point_index = int(values.get("point_index", 2))
	gold = int(values.get("gold", 0))
	own_gold = int(values.get("own_gold", 0))
	var period := int(values.get("period", GuildWarNet.pack_period(1, 0, 0)))
	_given_period = period
	var parts := GuildWarNet.unpack_period(period)
	if not parts.is_empty():
		day = int(parts["day"])
		hour = int(parts["hour"])
		minute_index = int(parts["minute"]) / 10
	else:
		day = GuildWarNet.DAY_ROWS
		hour = GuildWarNet.HOUR_ROWS
		minute_index = GuildWarNet.MINUTE_ROWS
	name = "RequestGuildWar"
	var layout := REQUEST_LAYOUT
	var caption_key := "UIIT_STT_INPUT_BOX"
	var box_size := INPUT_SIZE
	if which == State.CONFIRM:
		layout = CONFIRM_LAYOUT
		caption_key = "UIIT_STT_CONFIRM_BOX"
		box_size = BOX_SIZE
	elif which == State.AGREE:
		layout = AGREE_LAYOUT
		caption_key = "UIIT_STT_AGREEMENT_BOX"
		box_size = BOX_SIZE
	if not build_shell(builder, box_size, caption_key, caption_key, layout, "Create"):
		return false
	var parsed: UiLayoutParser.LayoutDef = builder.load_layout(layout)
	var sections := ["Condition", "Message"]
	if which == State.INPUT:
		sections.append("InputGuild")
	for sec in sections:
		var extra := builder.build_section(parsed, sec)
		if extra == null:
			continue
		# One root for every section's controls, so node() finds them all.
		for c in extra.get_children():
			extra.remove_child(c)
			root.add_child(c)
		extra.free()
	UiBuilder.settle_authored_rects(root)
	var ok := button("GDR_REQUEST_GUILDWAR_BUTTON_OK")
	var cancel := button("GDR_REQUEST_GUILDWAR_BUTTON_CANCEL")
	if ok != null:
		ok.pressed.connect(_on_ok)
	if cancel != null:
		cancel.pressed.connect(_on_cancel)
	match which:
		State.INPUT:
			_build_input(builder)
		State.CONFIRM:
			_fill_read_only("UIIT_MSG_GUILDWAR_SANCTIONWAR_01", period)
		State.AGREE:
			_fill_read_only("UIIT_MSG_GUILDWAR_CONSENTWAR_01", period)
			if ok != null:
				ok.disabled = own_gold < gold
	return true

func _unlimited() -> String:
	return text("UIIT_CTL_GUILDWAR_UNLIMITED", "Unlimited")

func _build_input(builder: UiBuilder) -> void:
	_point_combo = OptionVideoPage.make_combo(builder, node("GDR_REQUEST_GUILDWAR_POINT_COMBOBOX"))
	if _point_combo != null:
		_point_combo.add_item(_unlimited(), 0)
		for i in range(1, GuildWarNet.VICTORY_POINTS.size()):
			_point_combo.add_item("%d" % int(GuildWarNet.VICTORY_POINTS[i]), i)
		_point_combo.select(point_index)
		_point_combo.item_selected.connect(func(i: int) -> void: point_index = i)
	var day_word := text("PARAM_DAY", "Day")
	var hour_word := text("PARAM_HOUR", "Hour")
	var minute_word := text("PARAM_MINUTE", "Minute")
	_day_combo = _period_combo("GDR_REQUEST_GUILDWAR_PERIOD_DAY_COMBOBOX", GuildWarNet.DAY_ROWS, 1, day_word, day)
	if _day_combo != null:
		_day_combo.item_selected.connect(func(i: int) -> void: day = i)
	_hour_combo = _period_combo("GDR_REQUEST_GUILDWAR_PERIOD_HOUR_COMBOBOX", GuildWarNet.HOUR_ROWS, 1, hour_word, hour)
	if _hour_combo != null:
		_hour_combo.item_selected.connect(func(i: int) -> void: hour = i)
	_minute_combo = _period_combo("GDR_REQUEST_GUILDWAR_PERIOD_MIN_COMBOBOX", GuildWarNet.MINUTE_ROWS, 10, minute_word, minute_index)
	if _minute_combo != null:
		_minute_combo.item_selected.connect(func(i: int) -> void: minute_index = i)
	set_gold(gold)
	var money := button("GDR_REQUEST_GUILDWAR_MONEY_BUTTON")
	if money != null:
		money.pressed.connect(func() -> void: gold_wanted.emit())
	_name_edit = setup_edit("GDR_REQUEST_GUILDWAR_INPUT_GUILD_NAME", NAME_MAX, guild_name)
	if _name_edit != null:
		_name_edit.text_changed.connect(func(t: String) -> void: guild_name = t)
		_name_edit.call_deferred("grab_focus")

## "%0.2d%s" rows (0x71b8a0), the last "Unlimited".
func _period_combo(control_name: String, rows: int, step: int, word: String, chosen: int) -> OptionButton:
	var combo := OptionVideoPage.make_combo(_builder, node(control_name))
	if combo == null:
		return null
	for i in rows:
		combo.add_item("%02d%s" % [i * step, word], i)
	combo.add_item(_unlimited(), rows)
	combo.select(clampi(chosen, 0, rows))
	return combo

## 40: the wager grouped (0x8c1d50(.., 3, 0)).
func set_gold(amount: int) -> void:
	gold = amount
	set_static("GDR_REQUEST_GUILDWAR_MONEY", GuildWarPanes.group_digits(amount))

func period() -> int:
	return GuildWarNet.pack_period(day, hour, minute_index)

func _period_text(word_period: int) -> String:
	var parts := GuildWarNet.unpack_period(word_period)
	if parts.is_empty():
		return _unlimited()
	return "%02d%s %02d%s %02d%s" % [int(parts["day"]), text("PARAM_DAY", "Day"),
		int(parts["hour"]), text("PARAM_HOUR", "Hour"), int(parts["minute"]), text("PARAM_MINUTE", "Minute")]

func _fill_read_only(first_key: String, word_period: int) -> void:
	var fmt := text(first_key, first_key)
	set_static("GDR_REQUEST_GUILDWAR_MSG_01", fmt.replace("%s", guild_name) if fmt.count("%s") == 1 else fmt)
	var vp := GuildWarNet.victory_points(point_index)
	set_static("GDR_REQUEST_GUILDWAR_POINT", _unlimited() if vp == 0 else "%d" % vp)
	set_static("GDR_REQUEST_GUILDWAR_PERIOD", _period_text(word_period))
	set_static("GDR_REQUEST_GUILDWAR_MONEY", GuildWarPanes.group_digits(gold))

## State 1's checks (0x71c480), in order; "" passes. `own_guild` the
## player's guild's name, `allowed` the name filter (0x8c3de0).
static func check_input(target: String, own_guild: String, wager: int, allowed: Callable = Callable()) -> Array:
	if target == "":
		return ["UIIT_MSG_GUILDWAR_HGN_INPUT", []]
	if target == own_guild:
		return ["UIIT_MSG_GUILDWARERR_SELFWAR", []]
	var n := target.to_utf8_buffer().size()
	if n < 2 or n > NAME_MAX:
		return ["UIIT_MSG_GUILDERR_INVALID_GUILDNAME_LEN", []]
	if allowed.is_valid() and not bool(allowed.call(target)):
		return ["UIIT_MSG_GUILDWARERR_ERRINPUT", []]
	if wager > GuildWarNet.MAX_WAGER:
		return ["UIIT_MSG_GUILDWARERR_LIMIT_COMPENSATION", [GuildWarPanes.group_digits(GuildWarNet.MAX_WAGER)]]
	return []

var own_guild_name := ""
var name_allowed: Callable
var _given_period := 0

func _on_ok() -> void:
	match state:
		State.INPUT:
			var why := check_input(guild_name, own_guild_name, gold, name_allowed)
			if not why.is_empty():
				refused.emit(String(why[0]), why[1] as Array)
				return
			proclaim.emit(guild_name, point_index, period(), gold)
			close()
		State.CONFIRM:
			proclaim.emit(guild_name, point_index, _given_period, gold)
			close()
		State.AGREE:
			answered.emit(true)
			close()

func _on_cancel() -> void:
	if state == State.AGREE:
		answered.emit(false)
	close()
