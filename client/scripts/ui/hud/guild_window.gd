extends HudWindow
class_name GuildWindow

## The retail Guild / Community window, `CNIFGuildWnd`, built from the
## client's own `res_ui\*.2dt` files the way its classes assemble it. Every
## address is `sro_client.exe`'s; docs/protocol/2DT_FORMAT.md has the format
## and docs/RE_COMPLETION.md this window's round. Each fact below is read
## unless it says otherwise.
##
## **One window, two views.** `guild.2dt` is `CNIFGuildWnd`, a CNIFMainFrame
## (621x434). Its OnCreate (0x5b57c0) loads `guild_r.2dt` (the relations pane,
## 164) and `guild_w.2dt` (the war pane, 548) under itself and moves both onto
## its info pane 47 (11, 63), then loads `cumunity_friend.2dt`, the community
## window `CNIFCommunityWnd` (177), under itself too. The community's OnCreate
## (0x58ec70) loads `cumunity_cut.2dt` (blocking, 59) and `cumunity_note.2dt`
## (letters, 700) under itself, moves them onto its friend pane 646 (11, 63),
## and moves itself to the guild window's origin. So the community is a child
## of the guild window, laid exactly over it: its three tabs sit on the
## guild's three (23/100/176, 41, 72x24) and its panes on the guild's panes.
##
## **Switching** (0x5b48e0 / 0x5b4930): the guild view hides the community and
## captions the window UIIT_STT_GUILDVIEW; the community view shows it and
## captions UIIT_STT_COMMUNITY. The community's ShowWindow (0x58ec40) first
## tells the guild window (0x5b3ba0) to show its own panes when the community
## hides and to hide them when it shows; showing them re-checks the guild's
## first tab, which leaves only the info pane up. U (0x5b4980) and the menu's
## community item (0x5b49c0) set their view and then toggle the window
## (`IsVisible` 0xb8f530: hide if shown, show if hidden). The window's own
## left-menu buttons 220 and 221 switch views (message map 0xeb2690 /
## 0xeb26b8).

const TwoDtBuilder = preload("res://scripts/ui/twodt_builder.gd")

const GUILD_2DT := "res_ui\\guild.2dt"
const GUILD_R_2DT := "res_ui\\guild_r.2dt"
const GUILD_W_2DT := "res_ui\\guild_w.2dt"
const FRIEND_2DT := "res_ui\\cumunity_friend.2dt"
const CUT_2DT := "res_ui\\cumunity_cut.2dt"
const NOTE_2DT := "res_ui\\cumunity_note.2dt"

const ID_GUILD := 176
const ID_INFO := 47
const ID_RELATIONS := 164
const ID_WAR := 548
const ID_COMMUNITY := 177
const ID_FRIEND := 646
const ID_BLOCK := 59
const ID_LETTER := 700
## The three tabs, in each view (0x48, 0x49, 0x4a).
const TABS := [72, 73, 74]
const ID_MENU_GUILD := 220
const ID_MENU_COMMUNITY := 221

const CAPTION_GUILD := "UIIT_STT_GUILDVIEW"
const CAPTION_COMMUNITY := "UIIT_STT_COMMUNITY"

## Hover strings the OnCreates attach with style bit 0x80 (0x46d840 /
## 0x46d880, then 0x46d7d0), as [path from the guild window, text key]. The
## string is read; that the client shows it on hover is **inferred**
## (0x46d7d0 stores it and calls vslot 0xb0 only when bit 7 is set), so it
## becomes the control's tooltip.
const GUILD_TOOLTIPS := [
	[[164, 87], "UIIT_STT_GUILD_RESPECT_ALLY"],
	[[164, 88], "UIIT_STT_GUILD_RESPECT_WAR"],
	[[72], "UIIT_STT_GUILD_INFO"],
	[[73], "UIIT_CTL_GUILD_RESPECT"],
	[[74], "UIIT_CTL_WARSIT_WARSITUATION"],
	[[548, 87], "UIIT_CTL_WARSIT_GUILDWAR"],
	[[220], "UIIT_CTL_WK_GUILD"],
	[[221], "UIIT_STT_SILKMALL_COMMUNITY"],
	[[47, 250], "UIIT_MSG_GUILD_SP_GP_TOOLTIP"],
]
## The same, from the community window (0x58ed59..0x58ee2a) and the blocking
## pane's own OnCreate (0x587ab2), as paths from the community window.
const COMMUNITY_TOOLTIPS := [
	[[72], "UIIT_CTL_FRIEND"],
	[[73], "UIIT_STT_BLOCKMAN_BLOCK"],
	[[74], "UIIT_CTL_LETTER"],
	[[59, 395], "UIIT_STT_CHATING_SHUT_SAVE_SERVER"],
	[[59, 396], "UIIT_STT_CHATING_SHUT_SAVE_PC"],
	[[59, 337], "UIIT_STT_CHATING_SHUT_SAVE_SERVER_HELP"],
]

## Children each slot class hides in its OnCreate, by class name. Every
## entry is a `ShowWindow(0)` on a child the handler fetches by id:
## CNIFGuildUserSlot 0x5b9870 (64, 68, 69, 70, 71 -- it keeps 231),
## CNIFAllianceSlot 0x57fdc0 and CNIFHostileSlot 0x5be5f0 (127, 128, 131),
## CNIFContributionSlot 0x5b2fe0 (503, 504, 505), CNIFGuildWarSlot 0x5b2fa0
## (518), CNIFMultiLetterSlot 0x5cc020 (75, 76, 341). The other named
## classes here fetch without hiding: CNIFGuildNotifySlot (0x5b3e40 returns),
## CNIFGuildGrantPowSlot 0x5ad290, CNIFFriendSlot 0x5a9400, CNIFBlockSlot
## 0x588320, CNIFLetterSlot 0x5c4110.
const SLOT_HIDDEN_AT_CREATE := {
	"CNIFGuildUserSlot": [64, 68, 69, 70, 71],
	"CNIFAllianceSlot": [127, 128, 131],
	"CNIFHostileSlot": [127, 128, 131],
	"CNIFContributionSlot": [503, 504, 505],
	"CNIFGuildWarSlot": [518],
	"CNIFMultiLetterSlot": [75, 76, 341],
}

## A friend row's parts, fetched by CNIFFriendSlot's OnCreate (0x5a9400):
## 52 the contact lamp (+0x4e4), 341 the name (+0x4e8), 51 the race icon
## (+0x4ec).
const FRIEND_LAMP := 52
const FRIEND_NAME := 341
const FRIEND_RACE := 51
## The lamp's two pieces, set by the row's fill (0x5a7990) from a state byte
## of the entry: 0 -> 0xd919d0, 1 -> 0xd8dae8. Which of our `online` values
## is which state is **inferred** from the names.
const FRIEND_LAMP_ON := "interface\\guild\\gil_contact_on.ddj"
const FRIEND_LAMP_OFF := "interface\\guild\\gil_contact_off.ddj"
## CNIFBlockSlot's OnCreate sets its row's lamp (46) to this (0x588364).
## 46 is the row's lamp (+0x4e4) and 400 its name (+0x4e8).
const BLOCK_LAMP := 46
const BLOCK_NAME := 400
## The friend count beside the pane's "Friend" label: 646 -> 18 (FriendWnd
## +0x78c), printed by the pane's refresh 0x5a97b0 with this format (UTF-16
## at 0xd8d998) and the literal 20 (`push 0x14` at 0x5a9982) as the second
## number.
const FRIEND_COUNT := 18
const FRIEND_COUNT_FORMAT := ": %d / %d"
const FRIEND_COUNT_MAX := 20

## The guild information fields CNIFGuildWnd binds in its OnCreate
## (0x5b5b5b..0x5b5c33, 47 -> id stored at the offset) and its refresh
## 0x5b5eb0 writes: 120 the GP gauge (+0x7b0), 66 the name line (+0x7b8),
## 115 (+0x7bc), 150 the race mark (+0x7c0), 124 (+0x7c4), 126 (+0x7c8),
## 121 (+0x7cc), 116 (+0x7d4).
const INFO_GAUGE := 120
const INFO_NAME := 66
const INFO_RACE := 150
const INFO_CLEARED := [115, 124, 126, 121, 116]
## The master's name line (the in-guild branch's +0x34 string, 0x5b6015).
const INFO_MASTER := 124
## With no guild, 0x5b5eb0 (0x5b6223..) puts this on 66 (UTF-16 at 0xd92b3c).
const NO_GUILD_TEXT := "UIIT_STT_NO_GUILD"
## The five command buttons (47 -> 37..41, +0x7e8..+0x7f8) and the notice
## slot's edit button (47 -> 222 -> 81, +0x7fc).
const COMMAND_BUTTONS := [37, 38, 39, 40, 41]
const NOTICE_EDIT := [ID_INFO, 222, 81]
## The notice line inside the notice slot, cleared by 0x5b54c0 (222 -> 117).
const NOTICE_TEXT := [ID_INFO, 222, 117]
## A member row's parts that its fill 0x5b6b40 hides for a row past the list
## (0x5b6b87..0x5b6bd9): 64, 68, 69, 70, 71 and 231.
const MEMBER_ROW_PARTS := [64, 68, 69, 70, 71, 231]

## Emitted when the window's own left-menu buttons (220 / 221) switch the
## view, so the owner can ask for that view's data.
signal view_changed(view: String)
## Round 814: OK on the grant-name box -- the player's own grant name (""
## clears it).
signal grant_name_submitted(nickname: String)

## Round 814: the grant-name button, CNIFGuildWnd's fourth command button (47
## -> 40; READ, the dispatcher 0x5b63e0's index 3 opens UI_SILKMALL
## 0x641f40's grant-name box for the member selected at +0x79c). OURS: a
## member names only themselves, so it opens for the player's own name with
## no row chosen (this client fills no member rows yet, OPEN), and it is the
## one command button enabled -- whenever the player is in a guild.
const GRANT_NAME_BUTTON := 40
var grant_box: HudCosBox
## The player's own name, for the box's title (the owner sets it).
var own_name := ""

var _twodt: TwoDtBuilder
## The guild window's own node (176). panel_root is the same node.
var guild_root: Control
## The community window (177), a child of guild_root.
var community_root: Control
var _community_view := false
## Whether the player is in a guild, as the last guild_info reply said.
## Until one arrives the window takes 0x5b5eb0's no-guild branch; that the
## client's own guild record starts without its flag is **inferred**.
var _has_guild := false
var _guild_name := ""
var _guild_master := ""
## The window's own visible flag as last seen, so a show is acted on only
## when the window itself goes from hidden to shown -- not when an ancestor
## (the HUD, hidden with F10) is hidden and shown again, which Godot also
## reports as a visibility change.
var _shown_flag := false
## The friend list the rows are drawn from (0x5a85c0 reads the pane's own
## list; this is the last friend list this client received).
var _friends: Array = []

## Builds the window from the archive's `.2dt` files, in the order the
## client's classes do, and leaves it in the state their OnCreates leave it.
## False, with nothing built, if guild.2dt is missing or does not parse; a
## missing second file only leaves that pane out.
func build_guild(builder: UiBuilder) -> bool:
	_builder = builder
	if builder == null:
		return false
	var guild_file := builder.load_2dt(GUILD_2DT)
	if guild_file == null or guild_file.records.is_empty():
		return false
	_twodt = TwoDtBuilder.new(builder)
	guild_root = _twodt.build(guild_file, GUILD_2DT)
	panel_root = guild_root
	var window_size := Vector2(guild_file.root().rect.size)
	custom_minimum_size = window_size
	size = window_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(guild_root)

	# 0x5b57c0: guild_r and guild_w under the guild window, moved onto pane
	# 47 (0x5b5804..0x5b5843); then the community under it (0x5b5848).
	var info := TwoDtBuilder.child(guild_root, ID_INFO)
	for path in [GUILD_R_2DT, GUILD_W_2DT]:
		var pane := _load_under(builder, path, guild_root)
		if pane != null and info != null:
			_place(pane, info.position)
	community_root = _load_under(builder, FRIEND_2DT, guild_root)
	if community_root != null:
		# 0x58ec70: cut and note under the community, moved onto its friend
		# pane 646 (0x58eca0..0x58ece2); then the community moves itself to
		# the guild window's origin (0x58ee2f..0x58ee5b) and its children go
		# with it -- inferred (docs/protocol/2DT_FORMAT.md), and the authored
		# offsets agree: its tabs land on the guild's.
		var friend := TwoDtBuilder.child(community_root, ID_FRIEND)
		for path in [CUT_2DT, NOTE_2DT]:
			var pane := _load_under(builder, path, community_root)
			if pane != null and friend != null:
				_place(pane, friend.position)
		_place(community_root, Vector2.ZERO)

	_apply_create_state()
	_add_title_bar(builder.resolve_text(CAPTION_GUILD))
	var bar := get_node_or_null("TitleBar") as Label
	if bar != null:
		# The caption's text-object slot 6 is 0 (0x479c0b): top.
		bar.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_wire()
	_settle()
	return true

func _load_under(builder: UiBuilder, path: String, parent: Control) -> Control:
	var file := builder.load_2dt(path)
	if file == null:
		push_warning("GuildWindow: %s not built" % path)
		return null
	var node := _twodt.build(file, path)
	parent.add_child(node, true)
	return node

## Moves a loaded file's root to `at` in its parent, keeping the settling
## pass on the same spot.
static func _place(node: Control, at: Vector2) -> void:
	node.position = at
	node.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(at, node.size))

## The state the OnCreates leave. **They run in reverse file order.** The
## loader queues each named record with a push_front (0x48fc09..0x48fc2b: a
## node whose next is the list's first, 0x46bf60 {next, prev, value}) --
## the root list beside it is a push_back (0x48fb1f) -- and the send loop
## walks from the front (0x48fc84..0x48fcbd). So in each file the last named
## record gets 0x8065 first and record 0, the window itself, last; the
## guild window's own handler runs after every other guild.2dt class's, and
## loads the other files from inside it, each of which runs its own queue
## the same way when its load ends.
func _apply_create_state() -> void:
	# guild.2dt's queue, last record first: CNIFGuildNotifyView (0x5a9d00,
	# an edit box's settings only), the grant-power rows (fetch only), then
	# CNIFGuildGrantPow (0x5a9ae0): moved onto 47 -> 85 (0x5a9b01..0x5a9b2c)
	# and hidden (0x5a9b37).
	var grant := _at([ID_INFO, 1000])
	var anchor := _at([ID_INFO, 85])
	if grant != null:
		if anchor != null:
			_place(grant, anchor.position)
		grant.visible = false
	# Then the member rows, the notice slot, and every slot class of the
	# files the guild window loads: each hides its own children
	# (SLOT_HIDDEN_AT_CREATE); a slot's children are its own, so where in
	# the queue it runs changes nothing.
	for node in _named(guild_root):
		var cls := str(node.get_meta(TwoDtBuilder.META_CLASS))
		for id in SLOT_HIDDEN_AT_CREATE.get(cls, []):
			var c := TwoDtBuilder.child(node, int(id))
			if c != null:
				c.visible = false
		if cls == "CNIFBlockSlot":
			_set_texture(TwoDtBuilder.child(node, BLOCK_LAMP), FRIEND_LAMP_OFF)

	# The guild window's OnCreate (0x5b57c0), last of its file. Inside it:
	# guild_r and guild_w (their slots above; CNIFAllianceGuild's refresh
	# 0x57c6f0 is not run -- see the record), then cumunity_friend, whose
	# queue runs the friend rows (registering with the pane), CNIFFriendWnd
	# and, last, CNIFCommunityWnd.
	if community_root != null:
		# CNIFFriendWnd 0x5a9a00: +0x78c = 18, +0x798 = the scroll, then
		# 0x5a97b0 -> 0x5a94f0 -> the rows' refresh 0x5a85c0 (0x5a9777):
		# with no list, every row cleared, and the count printed.
		refresh_friends()
		# CNIFCommunityWnd 0x58ec70: cumunity_cut, whose queue ends with
		# CNIFBlockWnd 0x587a50 -- sub-tab 395 checked (0x587aad; no pane),
		# then 0x5877a0 -> 0x586aa0, which fills or clears each row with
		# 0x586130: a row with no name hides its lamp 46 and its name 400
		# (0x58614e..0x586172). This client has no block list, so every row
		# is cleared.
		var block := TwoDtBuilder.child(community_root, ID_BLOCK)
		if block != null:
			TwoDtBuilder.set_tab_checked(TwoDtBuilder.child(block, 395), true)
			for row in block.get_children():
				if row is Control and str(row.get_meta(TwoDtBuilder.META_CLASS, "")) == "CNIFBlockSlot":
					for id in [BLOCK_LAMP, BLOCK_NAME]:
						var part := TwoDtBuilder.child(row, id)
						if part != null:
							part.visible = false
		# cumunity_note, whose queue ends with CNIFLetter 0x5c4a70: 800
		# hidden (0x5c4abc), and 0x5bec70 hides 900, CNIFMultiLetter, which
		# its own OnCreate (0x5c9080) had hidden as well -- after moving
		# itself to its parent's position + (0x11, 0x20) (0x5c90a3..0x5c90d1,
		# vslot 0x9c -> 0x98, an absolute SetPos: 0x46cfa0 -> 0x46cfc0 ->
		# 0xb90d90 -> 0xb90cf0). Its parent is the letter pane, so it sits at
		# (17, 32) in it.
		var letter := TwoDtBuilder.child(community_root, ID_LETTER)
		var multi := TwoDtBuilder.child(letter, 900) if letter != null else null
		if multi != null:
			_place(multi, Vector2(0x11, 0x20))
		if letter != null:
			for id in [800, 900]:
				var c := TwoDtBuilder.child(letter, id)
				if c != null:
					c.visible = false
		# Back in 0x58ec70: friend tab on, the other two off. SetCheck(72)
		# shows the friend pane, whose ShowWindow (0x5a9a40) refreshes it
		# again (0x5a9a4c) -- the pane's visibility hook below.
		_check_tabs(community_root, 0)
		_tooltips(community_root, COMMUNITY_TOOLTIPS)

	# The rest of 0x5b57c0.
	_set_community_shown(false)                        # 0x5b5866
	_hide([ID_INFO, 1200])                             # 0x5b588c: CNIFGuildNotifyView
	TwoDtBuilder.set_tab_checked(_at([ID_RELATIONS, 87]), true)    # 0x5b58a7
	TwoDtBuilder.set_tab_checked(_at([ID_RELATIONS, 88]), false)   # 0x5b58c5
	_check_tabs(guild_root, 0)                         # 0x5b58d7..0x5b58fb
	_tooltips(guild_root, GUILD_TOOLTIPS)
	# 0x5b5c69: colour 0xffffd953 on 47 -> 115 (0x475ce0 writes the same
	# text-object colour words the record's colour goes to).
	var c115 := _at([ID_INFO, 115])
	if c115 != null:
		_twodt.set_text(c115, TwoDtBuilder.text_of(c115)).add_theme_color_override(
			"font_color", TwoDtBuilder.argb(0xffffd953))
	# 0x5b5460(1) sets +0x798 = 1 and calls 0x5b5150. The grant window is
	# already hidden (its OnCreate ran first), so 0x5b518e takes 0x5b51b4:
	# the command buttons are shown and disabled.
	_command_buttons()

## 0x5b5150 with +0x798 = 1 and the grant window hidden: each command
## button 47 -> 37..41 shown (vslot 0x5c, 1) and disabled (0x471dc0(0),
## 0x5b51c8..0x5b51e2), and the notice's edit button 47 -> 222 -> 81
## disabled (0x5b51f9). With no guild (0x9870e0 false, 0x5b521d) nothing is
## enabled again (0x5b536e -> 0x5b5433). A disabled button draws its
## `_disable` piece (0x471dee..0x471e06: +0x160 = +0x37c).
##
## **Open:** for a guild member the client enables some of them by the
## member's rights (0x5b531b..0x5b5433); this client does not carry the
## rights, so they stay disabled for everyone.
func _command_buttons() -> void:
	for id in COMMAND_BUTTONS:
		var b := _at([ID_INFO, id])
		if b != null:
			b.visible = true
			if b is BaseButton:
				(b as BaseButton).disabled = true
	var edit := _at(NOTICE_EDIT) as BaseButton
	if edit != null:
		edit.disabled = true
	var grant := _at([ID_INFO, GRANT_NAME_BUTTON]) as BaseButton
	if grant != null:
		grant.disabled = not _has_guild

## The guild window's ShowWindow (CNIFGuildWnd::vslot_023, 0x5bb150), for
## a show: 0x5bb0a0 first -- the grant window hidden (0x5bb0bf), the command
## buttons shown through 0x5b5480(1) and 0x5b5150, the member list's
## refresh (0x5bab70 -> 0x5ba310 -> 0x5b8580: a row past the list gets
## 0x5b6b40(0), which hides MEMBER_ROW_PARTS), the guild information
## (0x5b5eb0) and the relations and war refreshes -- then the window is
## centred on the screen (0x798c50(0xb0) at 0x5bb16c).
func _on_shown() -> void:
	var grant := _at([ID_INFO, 1000])
	if grant != null:
		grant.visible = false
	_command_buttons()
	for node in _named(guild_root):
		if str(node.get_meta(TwoDtBuilder.META_CLASS)) != "CNIFGuildUserSlot":
			continue
		for id in MEMBER_ROW_PARTS:
			var part := TwoDtBuilder.child(node, id)
			if part != null:
				part.visible = false
	_guild_info()
	place_centred()

## The guild information, 0x5b5eb0. Its two branches write the same fields,
## so each undoes the other. `0x9870d0`'s record, flag +4, picks the branch.
##
## **No guild** (flag clear, 0x5b5ef2 -> 0x5b6223): 66 reads
## UIIT_STT_NO_GUILD, 115, 124, 126, 121 and 116 are set to "" (0xe17460),
## the race mark 150 is hidden (0x5b6266..0x5b6272), the GP gauge 120 set to
## 0 (+0x368 / +0x36c), and the notice line 222 -> 117 set to "" (0x5b54c0).
##
## **In a guild** (0x5b5eff..0x5b61d6), with what a guild_info reply carries:
## - 66: the record's std::wstring at +0x18 (buffer at +0x1c; 0x5b5f0d).
##   That it is the guild's name is read: 0x5b6390 assigns record+0x18 from
##   the packet's guild name (via 0x88a420 / 0x5b7b80) and puts it on 66.
##   Ours is the reply's guild name.
## - 124: the record's string at +0x34 (0x5b6015), the name the race lookup
##   looks a member up by (0x5b5f6a..0x5b5f77), beside the "Guild master"
##   label 122: the master's name (**inferred**); ours is the reply's leader.
## - 150: shown (0x5b5f47), its art set from that member's character record
##   (0x9960a0 -> 0x93f370 -> 0x98caa0); when the lookup fails the art is set
##   to "" (0x5b5fcf..0x5b6005). Our reply carries no character record, so
##   it is shown with no art, as the client does on a failed lookup.
## - 115 "Level %d" (0xd92bb0, byte +5), 126 "%d / %d" (0xd92ba0: members,
##   0x988a40, over the level's cap, [level*4 + 0xd92384]: 15, 20, 25, 35,
##   50 for levels 1..5), 116 "%d / %d" (GP +0xc over [level*4 + 0xd92398]:
##   5400, 50400, 135000, 378000, 0 for levels 1..5), 121 "%d%%" (0xd8a948) and the gauge
##   120 (their ratio), and the notice 222 -> 117 (the record's +0x50, or
##   UIIT_MSG_GUILD_COMMON_NOTEXIST when it is empty): the guild_info reply
##   carries no level, points or notice, so these are left blank ("" and 0)
##   rather than filled with a guess. **Open.**
func _guild_info() -> void:
	var name_node := _at([ID_INFO, INFO_NAME])
	if name_node != null:
		_twodt.set_text(name_node, _guild_name if _has_guild else _builder.resolve_text(NO_GUILD_TEXT))
	for id in INFO_CLEARED:
		var c := _at([ID_INFO, id])
		if c == null:
			continue
		var text := _guild_master if (_has_guild and id == INFO_MASTER) else ""
		if text != "" or TwoDtBuilder.text_of(c) != "" or c.get_node_or_null(TwoDtBuilder.TEXT_NODE) != null:
			_twodt.set_text(c, text)
	var race := _at([ID_INFO, INFO_RACE])
	if race != null:
		race.visible = _has_guild
		if _has_guild:
			_set_texture(race, "")
	var gauge := _at([ID_INFO, INFO_GAUGE]) as Range
	if gauge != null:
		gauge.value = 0
	var notice := _at(NOTICE_TEXT)
	if notice != null and notice.get_node_or_null(TwoDtBuilder.TEXT_NODE) != null:
		_twodt.set_text(notice, "")

## The player's guild as the last guild reply said (guild_info, create or
## join; a leave sets it to none): whether they are in one, its name and its
## master's name. Redraws the information at once if the window is up.
func set_guild(in_guild: bool, guild_name: String = "", master_name: String = "") -> void:
	_has_guild = in_guild
	_guild_name = guild_name if in_guild else ""
	_guild_master = master_name if in_guild else ""
	if visible:
		_guild_info()
		_command_buttons()

## Round 814: the grant-name box for the player's own name (any open one is
## closed first). Does nothing outside a guild or without the layout.
func open_grant_name_box() -> void:
	if not _has_guild or _builder == null:
		return
	if grant_box != null and is_instance_valid(grant_box):
		grant_box.queue_free()
	grant_box = HudCosBox.new()
	if not grant_box.build_grant_name_input(_builder, own_name):
		grant_box.free()
		grant_box = null
		return
	grant_box.accepted.connect(func(nick: String) -> void: grant_name_submitted.emit(nick))
	var host: Node = get_parent() if get_parent() != null else self
	host.add_child(grant_box)
	grant_box.centre_on(get_viewport_rect().size)

## 0x798c50: the window moved so that x = (screen width >> 1) - (width >> 1)
## and y = (screen height >> 1) - (height >> 1) -- integer halves, read from
## the `cdq / sub / sar 1` pairs -- through vslot 0x9c, on every show. The
## screen here is the viewport in the UI's own units (what the UI scale
## changes). **Ours:** the result is kept inside the viewport's top-left
## corner, so the caption and close button stay reachable when the window is
## larger than the view (621x434 in a 1152x648 view at UI scale 1.5, 768x432,
## would start at y = -1).
func place_centred() -> void:
	var view := get_viewport_rect().size
	var x := int(view.x) / 2 - int(size.x) / 2
	var y := int(view.y) / 2 - int(size.y) / 2
	position = Vector2(clampi(x, 0, maxi(0, int(view.x) - int(size.x))),
		clampi(y, 0, maxi(0, int(view.y) - int(size.y))))

## Checks the tab at `index` of TABS under `root` and unchecks the others,
## each SetCheck showing or hiding its pane.
static func _check_tabs(root: Control, index: int) -> void:
	for i in TABS.size():
		TwoDtBuilder.set_tab_checked(TwoDtBuilder.child(root, TABS[i]), i == index)

func _named(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	for n in root.find_children("*", "Control", true, false):
		if n.has_meta(TwoDtBuilder.META_CLASS) and str(n.get_meta(TwoDtBuilder.META_CLASS)) != "":
			out.append(n)
	return out

func _at(path: Array) -> Control:
	return TwoDtBuilder.find_path(guild_root, path)

func _hide(path: Array) -> void:
	var c := _at(path)
	if c != null:
		c.visible = false

func _tooltips(root: Control, table: Array) -> void:
	for entry in table:
		var node := TwoDtBuilder.find_path(root, entry[0])
		if node == null:
			continue
		node.tooltip_text = _builder.resolve_text(entry[1])
		if node.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			node.mouse_filter = Control.MOUSE_FILTER_PASS

func _set_texture(node: Control, path: String) -> void:
	if node is TextureRect:
		(node as TextureRect).texture = _builder.load_texture(path) if path != "" else null

func _wire() -> void:
	var to_guild := _at([ID_MENU_GUILD]) as BaseButton
	if to_guild != null:
		to_guild.pressed.connect(func() -> void:
			show_guild_view()
			view_changed.emit("guild"))
	var to_community := _at([ID_MENU_COMMUNITY]) as BaseButton
	if to_community != null:
		to_community.pressed.connect(func() -> void:
			show_community_view()
			view_changed.emit("community"))
	var grant := _at([ID_INFO, GRANT_NAME_BUTTON]) as BaseButton
	if grant != null:
		grant.pressed.connect(open_grant_name_box)
	# The window's ShowWindow(1) (0x5bb150).
	visibility_changed.connect(func() -> void:
		if visible and not _shown_flag:
			_on_shown()
		_shown_flag = visible)
	if community_root != null:
		# The friend pane's ShowWindow(1) refreshes its rows (0x5a9a40 ->
		# 0x5a97b0, at 0x5a9a4c).
		var friend := TwoDtBuilder.child(community_root, ID_FRIEND)
		if friend != null:
			friend.visibility_changed.connect(func() -> void:
				if friend.visible:
					refresh_friends())
	if community_root != null:
		# The community's message map sends the letter tab's click (id 74) to
		# 0x58ef20, which clears the letter pane's +0x790 and hides 900 again
		# (0x5bed20(0)). The tab's own click has run first.
		var letter_tab := TwoDtBuilder.child(community_root, 74) as BaseButton
		if letter_tab != null:
			letter_tab.pressed.connect(func() -> void:
				var multi := TwoDtBuilder.find_path(community_root, [ID_LETTER, 900])
				if multi != null:
					multi.visible = false)

## The community's ShowWindow (0x58ec40): the guild window's panes first
## (0x5b3ba0 with the opposite flag), then the community itself.
func _set_community_shown(shown: bool) -> void:
	_show_guild_panes(not shown)
	if community_root != null:
		community_root.visible = shown
	_community_view = shown

## 0x5b3ba0: 164, 548 and 47 shown or hidden; when shown, the guild's first
## tab checked and the other two not, which leaves only 47 up.
func _show_guild_panes(shown: bool) -> void:
	for id in [ID_RELATIONS, ID_WAR, ID_INFO]:
		var pane := TwoDtBuilder.child(guild_root, id)
		if pane != null:
			pane.visible = shown
	if shown:
		_check_tabs(guild_root, 0)

## 0x5b48e0: the community hidden, the guild caption.
func show_guild_view() -> void:
	_set_community_shown(false)
	set_title(_builder.resolve_text(CAPTION_GUILD))

## 0x5b4930: the community shown, the community caption. The community's
## own tabs are not reset (0x58ec40 does not touch them).
func show_community_view() -> void:
	_set_community_shown(true)
	set_title(_builder.resolve_text(CAPTION_COMMUNITY))

func is_community_view() -> bool:
	return _community_view

## U (0x5b4980): the guild view, then the window toggled.
func toggle_guild_view() -> void:
	var was_visible := visible
	show_guild_view()
	visible = not was_visible

## The menu's community item (0x5b49c0): the community view, then toggled.
func toggle_community_view() -> void:
	var was_visible := visible
	show_community_view()
	visible = not was_visible

## A control of the guild window by its GetChild path, for a caller filling
## it (`[646, 339, 341]` is the first friend row's name).
func control(path: Array) -> Control:
	return _at(path)

## The friend rows (CNIFFriendSlot, in file order: the order they register
## with the friend pane, 0x5a92b0).
func friend_rows() -> Array[Control]:
	var out: Array[Control] = []
	if community_root == null:
		return out
	var pane := TwoDtBuilder.child(community_root, ID_FRIEND)
	if pane == null:
		return out
	for c in pane.get_children():
		if c is Control and str(c.get_meta(TwoDtBuilder.META_CLASS, "")) == "CNIFFriendSlot":
			out.append(c)
	return out

## Keeps the friend list and redraws the rows from it (refresh_friends).
## Each entry is an object with `friend_name` and `online`
## (FriendNet.FriendEntry).
func fill_friends(friends: Array) -> void:
	_friends = friends.duplicate()
	refresh_friends()

## The friend pane's refresh (0x5a85c0, reached from 0x5a97b0 -> 0x5a94f0):
## row i shows entry (scroll offset + i), and a row past the list is
## cleared. The scroll bar is not built, so the offset is 0 and a longer
## list shows its first rows. The rows are in file order: each row's
## OnCreate pushes it to the front of the pane's list (0x5a92b0), and the
## OnCreates run last row first, so the list ends in file order.
##
## A filled row (0x5a7990): the lamp set on or off, the race icon set from
## the friend's character record, the name set, and all three shown. Our
## friend list carries no character record, so the race icon is set to
## nothing -- what the client sets when its lookup fails (0x5a7abe). A
## cleared row hides all three (0x5a79d3..0x5a79fb).
##
## 0x5a97b0 then prints the count on 646 -> 18: FRIEND_COUNT_FORMAT with the
## list's size and 20 (0x5a997a..0x5a9991).
func refresh_friends() -> void:
	var rows := friend_rows()
	for i in rows.size():
		var row := rows[i]
		var lamp := TwoDtBuilder.child(row, FRIEND_LAMP)
		var name_node := TwoDtBuilder.child(row, FRIEND_NAME)
		var race := TwoDtBuilder.child(row, FRIEND_RACE)
		if i >= _friends.size():
			for part in [lamp, name_node, race]:
				if part != null:
					part.visible = false
			continue
		var entry: Variant = _friends[i]
		var online := bool(entry.get("online")) if entry is Object and "online" in entry else false
		var who := str(entry.get("friend_name")) if entry is Object and "friend_name" in entry else str(entry)
		_set_texture(lamp, FRIEND_LAMP_ON if online else FRIEND_LAMP_OFF)
		_set_texture(race, "")
		if name_node != null:
			_twodt.set_text(name_node, who)
		for part in [lamp, name_node, race]:
			if part != null:
				part.visible = true
	var count := TwoDtBuilder.find_path(community_root, [ID_FRIEND, FRIEND_COUNT]) if community_root != null else null
	if count != null:
		_twodt.set_text(count, FRIEND_COUNT_FORMAT % [_friends.size(), FRIEND_COUNT_MAX])

## CNIFMainFrame's chrome (0x479a50): caption (10, 12, W-21, 12), drag area
## (10, 0, W-21, 34), close button (W-26, 10, 16, 16) on com_windowclose.ddj.
## The same numbers as CIFMainFrame's (HudWindow.MAINFRAME_*).
func _place_title_bar(bar: Control) -> void:
	var rect := Rect2(Vector2(MAINFRAME_CAPTION_X, MAINFRAME_CAPTION_Y),
		Vector2(size.x - MAINFRAME_STRIP_WIDTH_LESS, MAINFRAME_CAPTION_HEIGHT))
	bar.set_meta(UiBuilder.AUTHORED_RECT_META, rect)
	bar.position = rect.position
	bar.size = rect.size

func _close_position() -> Vector2:
	return Vector2(size.x - MAINFRAME_CLOSE_INSET, MAINFRAME_CLOSE_Y)

func in_drag_strip(local: Vector2) -> bool:
	return Rect2(MAINFRAME_CAPTION_X, 0.0, size.x - MAINFRAME_STRIP_WIDTH_LESS,
		MAINFRAME_DRAG_HEIGHT).has_point(local)
