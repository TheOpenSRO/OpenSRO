extends Control
class_name PartyInvitePopup

## The party invitation box the invitee sees (round 711, lane C1;
## docs/protocol/party_gui.md §1b). READ from sro_client.exe unless marked:
##
## - The 0x3080 handler (c:0x88aa60) queues HUD request kind 6 for both party
##   kinds (2 form, 3 join; jump table c:0x88b1d4 sends both to 0x88ad8a)
##   with the inviter's name (CICPlayer +0x110) and the flags repacked as
##   anyone << 2 | exp << 1 | item.
## - The request is a CIFMessageBox (c:0x6ec5d0 -> 0x643c20(1): the
##   `MsgBoxINIF` section of `resinfo\ifmessagebox.txt`, frame
##   `interface\messagebox\msgbox2_window_`, docs/protocol/message_box.md).
## - Kind 6's purpose (UI_SILKMALL::FUN_00644c90, case 6/8, 0x645c5c..0x646027):
##   title UIIT_STT_CONFIRM_BOX; the box 300x176 (+0x54(0x12c, 0xb0));
##   +0x840 at (16, 48) UIIT_STT_PARTY_SOMEUSER with the name; +0x844 at
##   (16, 64) UIIT_STT_PARTY_PROPOSAL_ASK; +0x848 at (44, 93) and +0x84c at
##   (156, 93) on `msgbox_blackbox.ddj` at its own size, text inset
##   (3, 7, 3, 6), holding UIIT_STT_PARTY_EXP_SHARE / _EXP_SELF (flag 2) and
##   UIIT_STT_PARTY_ITEM_SHARE / _ITEM_SELF (flag 1); +0x850 at (6, 121)
##   UIIT_STT_PARTY_JOIN_ANYONE (flag 4) or empty; +0x800 at (72, 139)
##   UIIT_STT_ACCEPT, +0x804 at (152, 139) UIIT_STT_REFUSE, +0x808 hidden.
## - Which MsgBoxINIF control each of +0x840..+0x850 is was not traced: they
##   are taken as MESSAGE1..MESSAGE5 in ID order, with those controls'
##   authored sizes and centring (INFERRED), and +0x800 / +0x804 as the
##   section's OK and CANCEL buttons (INFERRED from message_box.md's +0x800
##   OK).
## - The box arms timer 10 (0x644650): 10 s for a box of type 4, 15 s for
##   type 8, 30 s otherwise -- 30 s here, if "simple_msgbox_type" is the
##   request kind (INFERRED). What the timer does when it fires was not read;
##   this box only closes then, without answering, and the server's own 30 s
##   wait answers both sides with 0x2c10 (party_protocol.md, Timers).

const LAYOUT := "resinfo\\ifmessagebox.txt"
const SECTION := "MsgBoxINIF"
const FRAME := "interface\\messagebox\\msgbox2_window_"
const BOX_SIZE := Vector2(300, 176)
const BLACKBOX := "interface\\messagebox\\msgbox_blackbox.ddj"
const TIMEOUT_SEC := 30.0

## The player answered: accept or refuse.
signal answered(accept: bool)

var _builder: UiBuilder
var _timer: SceneTreeTimer
var inviter_name := ""
var flags := 0

## Builds the box for an invitation from `who` with the 0x3080 flags byte
## (exp 1, item 2, anyone 4). Returns false without its layout.
func build(builder: UiBuilder, who: String, party_flags: int) -> bool:
	_builder = builder
	inviter_name = who
	# The box tests the repacked bits (exp 2, item 1, anyone 4); testing the
	# wire byte's own bits here shows the same three texts.
	flags = party_flags
	name = "PartyInvitation"
	size = BOX_SIZE
	custom_minimum_size = BOX_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	var frame_def := UiLayoutParser.ControlDef.new()
	frame_def.name = "Frame"
	frame_def.type = "CIFFrame"
	frame_def.ddj = FRAME
	frame_def.rect = Rect2i(Vector2i.ZERO, Vector2i(BOX_SIZE))
	var frame := builder.build_control(frame_def)
	if frame != null:
		add_child(frame)
	var caption := Label.new()
	caption.name = "Caption"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.text = _text("UIIT_STT_CONFIRM_BOX", "Confirmation window")
	# The title's placement on this frame is INFERRED: as CIFSetPartyMode's
	# caption static on the same msgbox2 frame (10, 11, width - 21, 12).
	caption.position = Vector2(10, 11)
	caption.size = Vector2(BOX_SIZE.x - 21, 12)
	add_child(caption)
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(LAYOUT)
	if layout == null:
		return false
	# CIFMessageBox::Create builds the file's "Create" (the background tile,
	# GDR_MSGBOX_BG 16,40,284,122) before the mode's section
	# (docs/protocol/message_box.md). Kind 6 resizes only the box; that the
	# tile keeps its authored size is INFERRED.
	# (get_section falls back to the first section: build "Create" only when
	# the file has one.)
	var base: Control = builder.build_section(layout, "Create") if layout.sections.has("Create") else null
	if base != null:
		add_child(base)
		UiBuilder.settle_authored_rects(base)
	var root := builder.build_section(layout, SECTION)
	if root == null:
		return false
	add_child(root)
	UiBuilder.settle_authored_rects(root)
	var exp_on := (flags & PartyNet.FLAG_EXP_SHARE) != 0
	var item_on := (flags & PartyNet.FLAG_ITEM_SHARE) != 0
	var anyone_on := (flags & PartyNet.FLAG_ANYONE_INVITE) != 0
	var some := _text("UIIT_STT_PARTY_SOMEUSER", "[%s]")
	_place(root, "GDR_MBIN_STATIC_MESSAGE1", Vector2(16, 48),
		some.replace("%s", who) if some.contains("%s") else "%s %s" % [some, who])
	_place(root, "GDR_MBIN_STATIC_MESSAGE2", Vector2(16, 64),
		_text("UIIT_STT_PARTY_PROPOSAL_ASK", "invites you to a party. Accept?"))
	_black_box(root, "GDR_MBIN_STATIC_MESSAGE3", Vector2(44, 93),
		_text("UIIT_STT_PARTY_EXP_SHARE" if exp_on else "UIIT_STT_PARTY_EXP_SELF",
			"Exp Auto Share" if exp_on else "Exp Free-For-All"))
	_black_box(root, "GDR_MBIN_STATIC_MESSAGE4", Vector2(156, 93),
		_text("UIIT_STT_PARTY_ITEM_SHARE" if item_on else "UIIT_STT_PARTY_ITEM_SELF",
			"Item Auto Share" if item_on else "Item Free-For-All"))
	_place(root, "GDR_MBIN_STATIC_MESSAGE5", Vector2(6, 121),
		_text("UIIT_STT_PARTY_JOIN_ANYONE", "Invitation of party member available") if anyone_on else "")
	var ok := root.get_node_or_null("GDR_MBIN_BTN_OK") as BaseButton
	if ok != null:
		ok.position = Vector2(72, 139)
		ok.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2(72, 139), ok.size))
		_button_text(ok, _text("UIIT_STT_ACCEPT", "Accept"))
		ok.pressed.connect(func() -> void: _answer(true))
	var cancel := root.get_node_or_null("GDR_MBIN_BTN_CANCEL") as BaseButton
	if cancel != null:
		cancel.position = Vector2(152, 139)
		cancel.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(Vector2(152, 139), cancel.size))
		_button_text(cancel, _text("UIIT_STT_REFUSE", "Refuse"))
		cancel.pressed.connect(func() -> void: _answer(false))
	var certify := root.get_node_or_null("GDR_MBIN_BTN_CERTIFY") as CanvasItem
	if certify != null:
		certify.visible = false
	var pml := root.get_node_or_null("GDR_MBIN_STATIC_MESSAGE_PML") as CanvasItem
	if pml != null:
		pml.visible = false
	return true

## Starts the box's 30 s timer once it is in the tree.
func _ready() -> void:
	if is_inside_tree():
		_timer = get_tree().create_timer(TIMEOUT_SEC)
		_timer.timeout.connect(close)

func _place(root: Control, control_name: String, at: Vector2, text: String) -> void:
	var n := root.get_node_or_null(control_name) as Control
	if n == null:
		return
	var r: Rect2 = n.get_meta(UiBuilder.AUTHORED_RECT_META, Rect2(n.position, n.size))
	n.set_meta(UiBuilder.AUTHORED_RECT_META, Rect2(at, r.size))
	n.position = at
	_builder.set_static_text(n, text)

func _black_box(root: Control, control_name: String, at: Vector2, text: String) -> void:
	var n := root.get_node_or_null(control_name) as Control
	if n == null:
		return
	n.visible = false
	var box := TextureRect.new()
	box.name = control_name + "_Box"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.texture = _builder.load_texture(BLACKBOX)
	box.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	box.position = at
	box.size = box.texture.get_size() if box.texture != null else Vector2(100, 24)
	var label := Label.new()
	label.name = "Text"
	# The static's own alignment (MsgBoxINIF's MESSAGE3/4: HAlign 1, no VAlign
	# so 0, top) in the inset 0x6527d0 is given: left 3, top 7, right 3,
	# bottom 6.
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.position = Vector2(3, 7)
	label.size = Vector2(maxf(0.0, box.size.x - 6.0), maxf(0.0, box.size.y - 13.0))
	box.add_child(label)
	root.add_child(box)

func _button_text(btn: Control, text: String) -> void:
	var l := btn.get_node_or_null("ButtonLabel") as Label
	if l != null:
		l.text = text

func _answer(accept: bool) -> void:
	answered.emit(accept)
	close()

## Hidden now, freed next frame (the box is an ancestor of the pressed
## button; round 631).
func close() -> void:
	if is_queued_for_deletion():
		return
	visible = false
	queue_free()

func _text(key: String, fallback: String) -> String:
	if _builder == null:
		return fallback
	var t := _builder.resolve_text(key)
	return fallback if t == "" or t == key else t
