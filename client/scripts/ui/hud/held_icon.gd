class_name HeldIcon
extends Node

## The icon on the cursor: click to pick it up, click again to put it down
## (round 652). One controller for every icon window -- the bag, the paper
## doll, the warehouse, an NPC's store, the skill window and the quick slots.
##
## READ, retail's engine (sro_client.exe; docs/protocol/held_icon.md):
## - The held window is one global, 0x0110f604. FUN_00b9db10(wnd) sets it:
##   the old one is told it was let go (vslot 26, +0x68), the new one is
##   asked whether it may be picked up (vslot 25, +0x64) and is dropped again
##   if it says no. CIFSlotWithHelp's answer (0x667fa0) is no for an empty
##   slot (0x667ab0: +0x174 == 0), else its window's.
## - The pick-up is a LEFT BUTTON RELEASE on the slot (CIFWnd's message
##   handler 0x652540, case 0x202), only when the cursor is the normal one
##   (0x00eb6a48, cleared by 0x777e70 while a command cursor is up), none of
##   Ctrl, Shift or Alt is held (GetKeyState 0x11/0x10/0x12 -- those clicks
##   go to the slot's own handler instead, vslot 29 at 0x680fa0), and no
##   window has the mouse captured. The slot's press (vslot 30) and its mouse
##   move (vslot 35) do nothing (0x46fd60 / 0x46fd10 return 0): there is no
##   press-drag-release. Every CIFSlotWithHelp is created pickable
##   (0x673cf4: push 1 -> FUN_00b9daf0).
## - While something is held, the message pump (0xba4450) offers every mouse
##   message to it first (vslot 18, CIFWnd's 0x6523d0):
##     * a mouse move (0x200) and the keys (0x100/0x101/0x104/0x105) pass on;
##     * a left PRESS (0x201) is swallowed, unless the control under the
##       cursor is a CIFButton (0xee9828) or a CIFSelectableArea (0xee96c0,
##       the bag's page tabs) -- so a page can be turned while holding;
##     * a left RELEASE (0x202) over such a control passes on too; anywhere
##       else it offers the held window to the control under the cursor and
##       then each of its parents (vslot 28, +0x70) until one takes it, and
##       then lets go of it whatever the answer;
##     * a right PRESS (0x204) lets go of it: the cancel;
##     * everything else (double clicks, the right release, the wheel) is
##       swallowed.
## - The held slot is drawn centred on the cursor each frame (CGame
##   0x8423d0: held->vslot 24 at mouse - size/2).
## - The world takes a drop too (CGInterface::vslot_028, 0x78abe0): a bag
##   item there asks "drop it?" (UIIT_MSG_DROP_WARNING_1/2), a worn item
##   says UIIT_MSG_STRGERR_CANT_DROP_EQUIPED_ITEM_DIRECTLY (0x186d).
##
## OURS: the source icon is dimmed while held, and the ghost is 85% opaque --
## how retail draws the slot left behind is not read.

## Where the held icon came from. `kind` is one of "bag", "worn", "storage",
## "shop", "skill", "quickslot"; the rest depends on it (slot, item_id, qty,
## skill_id, code). Empty while nothing is held.
var payload: Dictionary = {}

## Called with (payload, at) when the held icon is put down somewhere; the
## host resolves what is under the cursor. The icon is let go afterwards
## whatever the host did (0x6523d0 releases after the offer).
var drop_handler: Callable = Callable()
## Called with (at) -> bool: whether a left click there goes to the control
## under the cursor rather than to the held icon (the tabs and the buttons).
var passes_through: Callable = Callable()

## Emitted after a pick-up and after a release ("dropped" or "cancelled"),
## for the log a live run reads.
signal changed(payload: Dictionary, what: String)

const GHOST_SIZE := Vector2(32, 32)

var _ghost: TextureRect = null
var _source: CanvasItem = null
var _source_modulate := Color.WHITE

## The control the held icon came from (dimmed while held), or null.
func source() -> CanvasItem:
	return _source if _source != null and is_instance_valid(_source) else null

func is_holding() -> bool:
	return not payload.is_empty()

func kind() -> String:
	return String(payload.get("kind", ""))

## Whether `event` is the click that picks an icon up: a left RELEASE with
## none of Ctrl, Shift or Alt down (0x652540, READ).
static func is_pick_click(event: InputEvent) -> bool:
	if not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	return mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed \
		and not mb.ctrl_pressed and not mb.shift_pressed and not mb.alt_pressed

## Picks an icon up. Refused (false) while one is already held: the click
## that would pick up is the one that drops the held icon first.
func pick_up(what: Dictionary, icon: Texture2D, source: CanvasItem, at: Vector2) -> bool:
	if is_holding() or what.is_empty():
		return false
	payload = what.duplicate()
	_source = source
	if _source != null and is_instance_valid(_source):
		_source_modulate = _source.modulate
		_source.modulate = Color(1, 1, 1, 0.35)
	if icon != null:
		_ghost = TextureRect.new()
		_ghost.name = "HeldIconGhost"
		_ghost.texture = icon
		_ghost.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_ghost.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_ghost.custom_minimum_size = GHOST_SIZE
		_ghost.size = GHOST_SIZE
		_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ghost.top_level = true
		_ghost.z_index = 4096
		_ghost.modulate = Color(1, 1, 1, 0.85)
		add_child(_ghost)
		follow(at)
	print("HeldIcon: picked up %s" % describe(payload))
	changed.emit(payload, "picked")
	return true

## The source's control changed under the held icon (a bag page turn
## redraws the cells): dim the new one instead.
func retarget_source(node: CanvasItem) -> void:
	if not is_holding() or node == _source:
		return
	if _source != null and is_instance_valid(_source):
		_source.modulate = _source_modulate
	_source = node
	if _source != null:
		_source_modulate = _source.modulate
		_source.modulate = Color(1, 1, 1, 0.35)

## The icon drawn at the cursor, or null (nothing held, or no texture).
func ghost() -> Control:
	return _ghost

## Keeps the ghost centred on the cursor.
func follow(at: Vector2) -> void:
	if _ghost != null:
		_ghost.global_position = at - GHOST_SIZE * 0.5

## Lets go of the held icon without putting it anywhere (the right click, or
## a window closing under it).
func cancel() -> void:
	if not is_holding():
		return
	var was := payload
	_clear()
	print("HeldIcon: cancelled %s" % describe(was))
	changed.emit(was, "cancelled")

## Offers one input event to the held icon. True when it took the event (the
## caller marks it handled, so nothing under the cursor sees it).
func handle(event: InputEvent) -> bool:
	if not is_holding():
		return false
	if event is InputEventMouseMotion:
		follow((event as InputEventMouseMotion).global_position)
		return false
	if not (event is InputEventMouseButton):
		return false  # keys pass on (0x100/0x101/0x104/0x105)
	var mb := event as InputEventMouseButton
	var at := mb.global_position
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if _passes(at):
			return false
		if mb.pressed:
			return true
		var was := payload
		print("HeldIcon: put down %s at %s" % [describe(was), str(at.round())])
		if drop_handler.is_valid():
			drop_handler.call(was, at)
		# Let go after the offer, whatever it answered. A handler that
		# picked something else up (none does) keeps it.
		if payload == was:
			_clear()
			changed.emit(was, "dropped")
		return true
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		cancel()
		return true
	return true

func _passes(at: Vector2) -> bool:
	return passes_through.is_valid() and bool(passes_through.call(at))

func _clear() -> void:
	payload = {}
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
	if _source != null and is_instance_valid(_source):
		_source.modulate = _source_modulate
	_source = null

## "bag:12 (item 4842 x1)" and the like, for the log.
static func describe(what: Dictionary) -> String:
	if what.is_empty():
		return "nothing"
	var k := String(what.get("kind", "?"))
	match k:
		"skill":
			return "skill %d (%s)" % [int(what.get("skill_id", 0)), String(what.get("code", ""))]
		"quickslot":
			return "quickslot:%d" % int(what.get("slot", -1))
		"shop":
			return "shop item %d" % int(what.get("item_id", 0))
	return "%s:%d (item %d x%d)" % [k, int(what.get("slot", -1)), int(what.get("item_id", 0)), int(what.get("qty", 1))]
