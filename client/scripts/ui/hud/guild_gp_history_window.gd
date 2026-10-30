extends HudWindow
class_name GuildGPHistoryWindow

## Round 844 lane G (part 2): CNIFGPHistoryWnd, the GP usage history
## (res_ui\guild_gp.2dt, window 0xba, 464 x 311 on mframe_wnd_). READ
## (c:0x885c20, 0x5b9b30, 0x5b9d70):
## - opened by B501's success (the guild manager's line 0x43 sends 0x7501),
##   cleared and shown, each entry appended to the text box 955 as
##   UIIT_MSG_GUILD_GP_HISTORY "[%s] has spent [%d] GP for [%s]. (%d/%d/%d
##   %d:%d)" -- the name, the GP, the kind's text, then the year, month,
##   day, hour and minute of the local time (minutes not zero-padded) --
##   followed by an empty line; the scroll back at the top;
## - Confirm 954 (UIIS_CTL_CONFIRM) hides it; the scroll 953 moves the text.
## The caption is UIIT_STT_GUILD_GP_HISTORY ("GP Usage History").
## OURS: the text box is a RichTextLabel with its own scroll in place of 953.

const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")
const FILE := "res_ui\\guild_gp.2dt"
const ID_TEXT := 955
const ID_OK := 954
const ID_SCROLL := 953

var _twodt: TwoDtBuilder
var root: Control
var text_box: RichTextLabel
## The lines shown (tests and QA).
var lines: PackedStringArray = []

func build_history(builder: UiBuilder) -> bool:
	_builder = builder
	if builder == null:
		return false
	var file := builder.load_2dt(FILE)
	if file == null or file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(builder)
	root = _twodt.build(file, FILE)
	panel_root = root
	var sz := Vector2(file.root().rect.size)
	custom_minimum_size = sz
	size = sz
	mouse_filter = Control.MOUSE_FILTER_STOP
	name = "GuildGPHistory"
	add_child(root)
	_add_title_bar(builder.resolve_text("UIIT_STT_GUILD_GP_HISTORY"))
	var host := TwoDtBuilder.child(root, ID_TEXT)
	if host != null:
		text_box = RichTextLabel.new()
		text_box.name = "HistoryText"
		text_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		text_box.scroll_active = true
		text_box.bbcode_enabled = false
		if builder.font_at(0) != null:
			text_box.add_theme_font_override("normal_font", builder.font_at(0))
		text_box.add_theme_font_size_override("normal_font_size", UiBuilder.FONT_SIZES[0])
		host.add_child(text_box)
	var bar := TwoDtBuilder.child(root, ID_SCROLL)
	if bar != null:
		bar.visible = false
	var ok := TwoDtBuilder.child(root, ID_OK) as BaseButton
	if ok != null:
		_twodt.set_text(ok, builder.resolve_text("UIIS_CTL_CONFIRM"))
		ok.pressed.connect(func() -> void:
			fill([])
			hide())
	return true

## The entries ({time, name, gp, kind}), newest first as they come.
func fill(entries: Array) -> void:
	lines = PackedStringArray()
	for e in entries:
		lines.append(format_entry(e))
	if text_box != null:
		var parts: PackedStringArray = []
		for l in lines:
			parts.append(l)
			parts.append("")
		text_box.text = "\n".join(parts)
		text_box.scroll_to_line(0)

## One entry's line (0x5b9b30).
func format_entry(e: Dictionary) -> String:
	var fmt := _builder.resolve_text("UIIT_MSG_GUILD_GP_HISTORY") if _builder != null else ""
	if fmt == "" or fmt == "UIIT_MSG_GUILD_GP_HISTORY":
		fmt = "[%s] has spent [%d] GP for [%s]. (%d/%d/%d %d:%d)"
	var k := int(e.get("kind", 8))
	var kind_text := ""
	if k >= 0 and k < GuildPart2Net.GP_KIND_KEYS.size():
		kind_text = _builder.resolve_text(GuildPart2Net.GP_KIND_KEYS[k]) if _builder != null else ""
		if kind_text == "" or kind_text == GuildPart2Net.GP_KIND_KEYS[k]:
			kind_text = GuildPart2Net.GP_KIND_FALLBACK[k]
	var t := Time.get_datetime_dict_from_unix_time(int(e.get("time", 0)) + _tz_offset())
	var vals := [String(e.get("name", "")), int(e.get("gp", 0)), kind_text, int(t.year), int(t.month), int(t.day), int(t.hour), int(t.minute)]
	var out := fmt
	for v in vals:
		var ps := out.find("%s")
		var pd := out.find("%d")
		var at := ps if ps >= 0 and (pd < 0 or ps < pd) else pd
		if at < 0:
			break
		out = out.substr(0, at) + str(v) + out.substr(at + 2)
	return out

## localtime's offset (the client formats the local time, READ).
static func _tz_offset() -> int:
	var tz := Time.get_time_zone_from_system()
	return int(tz.get("bias", 0)) * 60
