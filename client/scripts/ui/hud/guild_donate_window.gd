extends PartyMatchBox
class_name GuildDonateWindow

## Round 844: CIFGuildPointUp, the GP donation window -- a member turns skill
## points into the guild's GP. READ in sro_client.exe:
## - opened by the guild window's donation button 47 -> 250
##   (com_donation_button, tooltip UIIT_MSG_GUILD_SP_GP_TOOLTIP; message map
##   0xfa -> 0x5b68a0), in a guild only: child 1500 of 47, 360 x 240
##   (`0x168`, `0xf0`), msgbox2_window_, centred on the screen;
## - Create (0x70bdf0): resinfo\ifguildpointup.txt; the edit 609 takes 12
##   characters (0x634f80(0xc)); 608 shows the player's SP ("%d");
## - the texts: 602 UIIT_STT_GP_SUBSCRIPION_ADD, 612..615 the explanation
##   lines, 607 UIIT_MSG_GUILD_GP_SUBSCRIPION_CHANGE_GP, 610
##   UIIT_MSG_GUILD_GP_SUBSCRIPION_CHANGE_GP_RESULT.
## The OK's checks before the request are in GuildManageNet's notes.

const LAYOUT := "resinfo\\ifguildpointup.txt"
const SIZE := Vector2(360, 240)
const EDIT := "GDR_GUILD_POINT_UP_EDIT"
const SP_NOW := "GDR_GUILD_POINT_UP_STA1_NUM"
const GUILD_NAME := "GDR_GUILD_POINT_UP_STRING_GUILD_NAME_STA"
const BTN_OK := "GDR_GUILD_POINT_UP_BTN_OK"
const BTN_CANCEL := "GDR_GUILD_LEVEL_UP_BTN_CANCEL"
const EDIT_MAX := 12

## OK with a count the player has: the owner sends the donation.
signal submitted(sp: int)
## A local refusal for the system window (a code the owner shows).
signal refused(code: int)

## The player's skill points when the window opened.
var sp := 0

func build_donate(builder: UiBuilder, guild_name: String, player_sp: int) -> bool:
	name = "GuildDonate"
	sp = player_sp
	if not build_shell(builder, SIZE, "", "", LAYOUT):
		return false
	caption.visible = false
	var e := setup_edit(EDIT, EDIT_MAX, "")
	if e != null:
		e.text_changed.connect(func(t: String) -> void:
			var digits := ""
			for ch in t:
				if ch >= "0" and ch <= "9":
					digits += ch
			if digits != t:
				e.text = digits
				e.caret_column = digits.length())
	set_static(SP_NOW, "%d" % sp)
	set_static(GUILD_NAME, guild_name)
	var ok := button(BTN_OK)
	if ok != null:
		ok.pressed.connect(press_ok)
	var cancel := button(BTN_CANCEL)
	if cancel != null:
		cancel.pressed.connect(close)
	return true

func amount() -> int:
	var e := node(EDIT) as LineEdit
	return int(e.text) if e != null and e.text.is_valid_int() else 0

func set_amount(n: int) -> void:
	var e := node(EDIT) as LineEdit
	if e != null:
		e.text = str(n)

## OK: a count above 0 and no more than the player's SP.
func press_ok() -> void:
	var n := amount()
	if n <= 0:
		return
	if n > sp:
		refused.emit(GuildManageNet.LOCAL_SP_SHORT)
		return
	submitted.emit(n)
	close()
