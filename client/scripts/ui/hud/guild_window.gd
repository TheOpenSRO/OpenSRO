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
const BLOCK_LAMP := 46

var _twodt: TwoDtBuilder
## The guild window's own node (176). panel_root is the same node.
var guild_root: Control
## The community window (177), a child of guild_root.
var community_root: Control
var _community_view := false

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

## The state the OnCreates leave, in the order they run: each file's named
## records get 0x8065 after that file loads, in file order (0x48fca9), and
## the guild window's own handler runs first and loads the others.
func _apply_create_state() -> void:
	# The slots' own hides (see SLOT_HIDDEN_AT_CREATE); a slot's children are
	# its own, so its OnCreate running before or after its window's changes
	# nothing here.
	for node in _named(guild_root):
		var hidden: Array = SLOT_HIDDEN_AT_CREATE.get(str(node.get_meta(TwoDtBuilder.META_CLASS)), [])
		for id in hidden:
			var c := TwoDtBuilder.child(node, int(id))
			if c != null:
				c.visible = false
		if str(node.get_meta(TwoDtBuilder.META_CLASS)) == "CNIFBlockSlot":
			_set_texture(TwoDtBuilder.child(node, BLOCK_LAMP), FRIEND_LAMP_OFF)

	if community_root != null:
		var block := TwoDtBuilder.child(community_root, ID_BLOCK)
		if block != null:
			# CNIFBlockWnd 0x587a50: its first sub-tab checked (0x587aad);
			# the pair has no pane (0x390 = -1), so only the look changes.
			TwoDtBuilder.set_tab_checked(TwoDtBuilder.child(block, 395), true)
		var letter := TwoDtBuilder.child(community_root, ID_LETTER)
		if letter != null:
			# CNIFLetter 0x5c4a70: the write frame 800 hidden (0x5c4abc), and
			# 0x5bec70 hides 900, CNIFMultiLetter, whose own OnCreate
			# (0x5c9080) hides it as well.
			for id in [800, 900]:
				var c := TwoDtBuilder.child(letter, id)
				if c != null:
					c.visible = false
		# CNIFCommunityWnd 0x58ec70: friend tab on, the other two off.
		_check_tabs(community_root, 0)
		_tooltips(community_root, COMMUNITY_TOOLTIPS)

	# CNIFGuildWnd 0x5b57c0.
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
	# 0x5b5460(1) -> 0x5b5150: CNIFGuildGrantPow (47 -> 1000) is still visible
	# (windows start visible, 0xb9e284, and its own OnCreate runs later), so
	# 0x5b5480(0) hides the five command buttons 47 -> 37..41 (+0x7e8..0x7f8,
	# bound at 0x5b5d20..0x5b5d3f).
	var grant := _at([ID_INFO, 1000])
	if grant != null and grant.visible:
		for id in range(37, 42):
			_hide([ID_INFO, id])
	# CNIFGuildGrantPow's OnCreate (0x5a9ae0), later in guild.2dt's queue:
	# moved onto 47 -> 85 (0x5a9b01..0x5a9b2c) and hidden (0x5a9b37).
	var anchor := _at([ID_INFO, 85])
	if grant != null:
		if anchor != null:
			_place(grant, anchor.position)
		grant.visible = false

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
		to_guild.pressed.connect(show_guild_view)
	var to_community := _at([ID_MENU_COMMUNITY]) as BaseButton
	if to_community != null:
		to_community.pressed.connect(show_community_view)
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

## Fills the friend rows the way the friend pane's refresh does (0x5a85c0):
## row i shows entry (scroll offset + i), and a row past the list is
## cleared. The scroll bar is not built, so the offset is 0 and a longer
## list shows its first rows. Each entry is an object with `friend_name`
## and `online` (FriendNet.FriendEntry).
##
## A filled row (0x5a7990): the lamp set on or off, the race icon set from
## the friend's character record, the name set, and all three shown. Our
## friend list carries no character record, so the race icon is set to
## nothing -- what the client sets when its lookup fails (0x5a7abe). A
## cleared row hides all three (0x5a79d3..0x5a79fb).
func fill_friends(friends: Array) -> void:
	var rows := friend_rows()
	for i in rows.size():
		var row := rows[i]
		var lamp := TwoDtBuilder.child(row, FRIEND_LAMP)
		var name_node := TwoDtBuilder.child(row, FRIEND_NAME)
		var race := TwoDtBuilder.child(row, FRIEND_RACE)
		if i >= friends.size():
			for part in [lamp, name_node, race]:
				if part != null:
					part.visible = false
			continue
		var entry: Variant = friends[i]
		var online := bool(entry.get("online")) if entry is Object and "online" in entry else false
		var who := str(entry.get("friend_name")) if entry is Object and "friend_name" in entry else str(entry)
		_set_texture(lamp, FRIEND_LAMP_ON if online else FRIEND_LAMP_OFF)
		_set_texture(race, "")
		if name_node != null:
			_twodt.set_text(name_node, who)
		for part in [lamp, name_node, race]:
			if part != null:
				part.visible = true

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
