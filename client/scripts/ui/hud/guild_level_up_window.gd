extends PartyMatchBox
class_name GuildLevelUpWindow

## Round 844: CIFGuildLevelUp, the guild manager's level-up window
## (GDR_GUILD_LEVEL_UP, ginterface id 49: 360 x 220 on msgbox2_window_;
## resinfo\ifguildlevelup.txt). READ in sro_client.exe (Create c:0x707da0):
## - opened by the master's talk line 0x17 (UIIT_MSG_GUILD_LEVEL_UP);
## - 4 the guild mark (interface\guild\gil_mark01.ddj), 5 the guild's name,
##   6 UIIT_STT_LV_LEVEL ("Lv. %d") with the level, 7
##   UIIT_MSG_GUILD_LEVEL_UP_CONDITION with the next level, 8 "%s :  %d GP"
##   with UIIT_STT_NEED_GP and the GP table (c:0xdafa44 by the current
##   level), 9 "%s :  %d %s" with UIIT_STT_CIRCULATION_NEEDMONEY, the gold
##   table (c:0xdafa58) and UIIT_STT_GOLD, 10
##   UIIT_MSG_QUESTION_GUILD_LEVEL_UP with the name and the next level;
## - Confirm (2) sends 0x70FA {u32 NPC} (c:0x81fdc0); Cancel (3) closes.
## OURS: the mark and the name keep their authored rects (the original fits
## the mark beside the name's measured width, c:0x707fe9..0x70806c, not
## re-measured here); the numbers are printed plain, as "%d" prints them.

const LAYOUT := "resinfo\\ifguildlevelup.txt"
const SIZE := Vector2(360, 220)
const MARK := "GDR_GUILD_LEVEL_UP_GUILD_MARK"
const NAME := "GDR_GUILD_LEVEL_UP_GUILD_NAME"
const LEVEL := "GDR_GUILD_LEVEL_UP_GUILD_LEVEL"
const CONDITION := "GDR_GUILD_LEVEL_UP_CONDITION"
const NEED_GP := "GDR_GUILD_LEVEL_UP_NEED_GP"
const NEED_GOLD := "GDR_GUILD_LEVEL_UP_NEED_GOLD"
const QUESTION := "GDR_GUILD_LEVEL_UP_STATIC"
const BTN_OK := "GDR_GUILD_LEVEL_UP_BTN_OK"
const BTN_CANCEL := "GDR_GUILD_LEVEL_UP_BTN_CANCEL"
const MARK_ART := "interface\\guild\\gil_mark01.ddj"

## Confirm: the owner sends 0x70FA with this NPC.
signal confirmed(npc_uid: int)

var npc := 0

func build_level_up(builder: UiBuilder, npc_uid: int, guild_name: String, level: int) -> bool:
	name = "GuildLevelUp"
	npc = npc_uid
	if not build_shell(builder, SIZE, "", "", LAYOUT):
		return false
	caption.visible = false
	var mark := node(MARK)
	if mark != null:
		var pic := TextureRect.new()
		pic.name = "Art"
		pic.texture = builder.load_texture(MARK_ART)
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.add_child(pic)
	set_static(NAME, guild_name)
	set_static(LEVEL, GuildWindow.format_d(text("UIIT_STT_LV_LEVEL", "Lv. %d"), [level]))
	set_static(CONDITION, GuildWindow.format_d(text("UIIT_MSG_GUILD_LEVEL_UP_CONDITION", "Guild [%d]LV requirements"), [level + 1]))
	var i := clampi(level - 1, 0, GuildManageNet.LEVEL_UP_GP.size() - 1)
	set_static(NEED_GP, "%s :  %d GP" % [text("UIIT_STT_NEED_GP", "Required guild point (GP)"), int(GuildManageNet.LEVEL_UP_GP[i])])
	set_static(NEED_GOLD, "%s :  %d %s" % [text("UIIT_STT_CIRCULATION_NEEDMONEY", "Required Amount"),
		int(GuildManageNet.LEVEL_UP_GOLD[i]), text("UIIT_STT_GOLD", "Gold")])
	var q := text("UIIT_MSG_QUESTION_GUILD_LEVEL_UP", "Will you promote [%s]guild to [%d]LV?")
	q = q.replace("%s", guild_name)
	set_static(QUESTION, GuildWindow.format_d(q, [level + 1]))
	var ok := button(BTN_OK)
	if ok != null:
		ok.pressed.connect(press_ok)
	var cancel := button(BTN_CANCEL)
	if cancel != null:
		cancel.pressed.connect(close)
	return true

func press_ok() -> void:
	confirmed.emit(npc)
	close()

## The text a static shows (tests and QA).
func shown(control_name: String) -> String:
	var n := node(control_name)
	if n is Label:
		return (n as Label).text
	var l := n.get_node_or_null("Text") as Label if n != null else null
	return l.text if l != null else ""
