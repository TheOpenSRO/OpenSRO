class_name LoadingScreen
extends Control

## The "NOW LOADING" screen over world entry, so the ~minute of region loading
## is not a black, frozen window. Real backdrop art (loading_default.ddj) from
## the player's own Media.pk2, a "NOW LOADING..." caption and a gold gauge that
## fills as region cells stream in. Added as the top child of the HUD Control
## (so it renders over everything) and freed when the load is done.
##
## Since round 562 World3D puts it up BEFORE the centre cell is built and
## before the HUD exists (World3D._ready -> _show_loading_screen; until then
## _drain_initial_load created it after the synchronous centre cell, so for
## the first seconds of every login the window kept whatever it had drawn
## last -- round 561's baseline: `cell 97/168 built in 5373 ms at frame 13`
## with no screen before it; round 562's runs: the screen at frame 13, the
## centre cell at 14, measured on the frames as well as in the log). The
## HUD is then added to the same parent after the screen, and CanvasItem draw
## order is child order, so the caller moves the screen back over the HUD
## with `cover_siblings()` once the HUD is built. The same round lets the
## caller hand in the Media.pk2 it already holds: until then every screen --
## every login and every teleport -- opened a reader of its own through
## FrontEndUi.open_media(). `_ready` prints which it did and what it cost.
##
## The gauge and caption are our styling, disclosed; the backdrop is the
## client's own art. It animates while the loader yields the main thread
## (World3D pumps the region queue with awaits), and since round 785 a phase
## that does not yield -- a dungeon's build -- repaints it as it goes with
## `paint`, as the client repaints its loading screen through a synchronous
## world load (below).
##
## Round 785, the teleport's flicker. Until then a dungeon's build ran in
## one frame (277 ms for the tomb's lv.1 in the user's log, 1.4-1.8 s for its
## lv.2) and the screen held the frame drawn before it, the gauge empty; the
## gauge then jumped to full, and the caption to "Entering the world...", in
## the two frames left before the lift (the user's log: `up at frame
## 620190`, `region grid loaded ... at frame 620192`, `lifted at frame
## 620193`, a 547 ms gap; MEASURED on the box's real-time grabs, docs/
## WORLD_ISSUES.md round 785): a full bright bar for two frames, a few ms
## each at the user's frame rate, then the world. The client's own screen
## (READ, sro_client.exe):
##   - CPSMission's loading state (+0xe4) is raised with the screen by
##     UI_ALCHEMYBOX::FUN_0084b6e0 (from OnResetClient 0x86dab0, the
##     teleport's reset): the zone's backdrop art on a window it already has,
##     and three it creates -- 0x65 loading_form.ddj, 0x64 gauge_loading.ddj
##     and 0x66 nowloading.ddj. While it is up the world is neither updated
##     nor drawn (CPSMission::vslot_012 0x84c300 runs FUN_0084c060 and
##     returns; vslot_013 0x84ac70 draws the world only when +0xe4 is clear).
##   - The world load (SWorld::vslot_000 0xa2acd0) holds the thread and
##     reports progress in thousandths to FUN_00ba3fc0 after each part (a
##     field's 31 x 31 = 961 cells, i * 1000 / 961, or a dungeon's parts,
##     i * 1000 / count), which stores it (+0x44, read by FUN_0084c060 / 1000.0
##     into gauge 0x64) and calls the screen object's slot 0x24 -- a repaint
##     (INFERRED from what it is gated by) -- only when more than 50 ms
##     (GetTickCount, 0x32) have passed since the last; the load ends with
##     FUN_00ba3fc0(1000, 1), forced.
##   - +0xe5 is then set (0x84ab50, called from FUN_008ab0e0, which builds
##     the player -- the character data's handler, INFERRED), and the next
##     update's FUN_0084c060 closes windows 0x64, 0x65 and 0x66 and clears
##     +0xe4: the world draws from that frame. No timer, no fade, no minimum
##     time.
## So: the gauge fills as the load goes, rests at 100 % for a repaint, and the
## screen goes on the next frame. `paint` is FUN_00ba3fc0 (the 50 ms rule,
## the forced last repaint); the screen's caption never changes. OPEN: the
## zone's own backdrop art (FUN_0084b6e0 picks loading_<zone>.ddj by region,
## e.g. loading_royalmausoleum.ddj for 0x8002-0x8007) -- this screen still
## shows loading_default.ddj everywhere.

const DEFAULT_BACKDROP := "interface\\loading\\loading_default.ddj"

## A repaint inside a synchronous load waits until more than this many ms
## have passed since the last one (READ: FUN_00ba3fc0, `0x32 < GetTickCount()
## - last`), unless forced.
const PAINT_INTERVAL_MS := 50
## The gauge's fill colour (OURS, as the trough's; the client's gauge is
## gauge_loading.ddj, not drawn here).
const FILL_COLOR := Color(0.86, 0.66, 0.20)

var _backdrop_path: String
## The Media.pk2 handed in by the caller, or null to open one in _ready.
var _media: Pk2Reader
## The gauge's fill, a canvas item of the trough's drawn straight through the
## RenderingServer (round 785): a Control's size reaches the server only at
## its deferred redraw, so a fill set inside a synchronous load would not be
## in a repaint made there (`paint`). Freed with the screen.
var _fill_item := RID()
var _bar_width := 0.0
var _caption: Label
## The gauge's fill, 0..1, as last set.
var progress := 0.0
## Repaints `paint` made (round 785), and the last one's time (ms ticks).
var paints := 0
var _last_paint_ms := -1000000

## Where the backdrop's archive came from, set in _ready: "reused" (the
## handle the caller already held), "opened" (this screen opened Media.pk2
## itself -- the path every screen took before round 562, kept for a caller
## with no handle) or "none" (no Media.pk2 configured, or it failed to open).
var media_source := ""
## What the open in _ready cost in milliseconds; 0 when the handle was
## reused. Measured, not assumed: Pk2Reader.open reads the 256-byte header
## and walks directories lazily, so this is the open alone.
var media_open_ms := 0

func _init(backdrop_ddj: String = DEFAULT_BACKDROP, media: Pk2Reader = null) -> void:
	_backdrop_path = backdrop_ddj
	_media = media

func _ready() -> void:
	var t_start := Time.get_ticks_msec()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var screen := get_viewport().get_visible_rect().size

	var ground := ColorRect.new()
	ground.color = Color.BLACK
	ground.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(ground)

	var media := _media
	if media != null:
		media_source = "reused"
	else:
		var t_open := Time.get_ticks_msec()
		media = FrontEndUi.open_media()
		media_open_ms = Time.get_ticks_msec() - t_open
		media_source = "opened" if media != null else "none"
	var t_backdrop := Time.get_ticks_msec()
	var bg := FrontEndUi.backdrop(media, _backdrop_path)
	var backdrop_ms := Time.get_ticks_msec() - t_backdrop
	if bg != null:
		add_child(bg)
	add_child(FrontEndUi.vignette())

	var bar_w := 760.0
	_caption = FrontEndUi.label("NOW LOADING...", 22)
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.size = Vector2(400, 30)
	_caption.position = Vector2(screen.x * 0.5 - 200, screen.y - 118)
	add_child(_caption)

	var trough := Panel.new()
	trough.add_theme_stylebox_override("panel", FrontEndUi.plate_style(Color(0.05, 0.05, 0.06, 0.95), FrontEndUi.GOLD_EDGE))
	trough.size = Vector2(bar_w, 26)
	trough.position = Vector2(screen.x * 0.5 - bar_w * 0.5, screen.y - 80)
	add_child(trough)
	_bar_width = bar_w - 8.0
	_fill_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_fill_item, trough.get_canvas_item())
	_draw_fill()
	# The frame this screen joined the tree in (it is drawn from the next one
	# on), how its archive was come by, and what the screen itself cost --
	# the line a load log is read by (client/tools/README.md, "Load
	# benchmark").
	print("LoadingScreen: up at frame %d (media %s, %d ms; backdrop %s, %d ms; built in %d ms)" % [
		Engine.get_frames_drawn(), media_source, media_open_ms,
		"decoded" if bg != null else "missing", backdrop_ms, Time.get_ticks_msec() - t_start])

## Puts this screen over every sibling added after it. CanvasItem draw order
## is child order, so a screen put up before the HUD is built (World3D._ready
## since round 562) would otherwise be drawn under the minimap, underbar,
## panels and chat that ui_control gains after it. No-op without a parent.
func cover_siblings() -> void:
	var parent := get_parent()
	if parent == null:
		return
	parent.move_child(self, parent.get_child_count() - 1)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _fill_item.is_valid():
		RenderingServer.free_rid(_fill_item)
		_fill_item = RID()

## Sets the gauge fill, `fraction` in 0..1. It reaches the RenderingServer at
## once (the fill is its own canvas item), so the next frame -- or a `paint`
## -- draws it.
func set_progress(fraction: float) -> void:
	progress = clampf(fraction, 0.0, 1.0)
	_draw_fill()

## The fill's width in pixels as drawn.
func fill_width() -> float:
	return _bar_width * progress

func _draw_fill() -> void:
	if not _fill_item.is_valid():
		return
	RenderingServer.canvas_item_clear(_fill_item)
	if progress > 0.0:
		RenderingServer.canvas_item_add_rect(_fill_item, Rect2(4, 4, _bar_width * progress, 18), FILL_COLOR)

## The gauge at `fraction`, repainted now from inside a load that does not
## yield the main thread (round 785; the client's FUN_00ba3fc0): when more
## than PAINT_INTERVAL_MS have passed since the last repaint, or `force`, the
## screen is drawn and presented at once (RenderingServer.force_draw, queued
## to the render thread when it has its own). The world is not drawn in that
## repaint -- the viewport's 3D is off for it and back as it was after -- as
## the client draws no world under its loading screen (CPSMission::vslot_013).
## Returns whether it repainted.
func paint(fraction: float, force: bool = false) -> bool:
	set_progress(fraction)
	if not is_inside_tree():
		return false
	var now := Time.get_ticks_msec()
	if not force and now - _last_paint_ms <= PAINT_INTERVAL_MS:
		return false
	_last_paint_ms = now
	var vp := get_viewport()
	var vp_rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_disable_3d(vp_rid, true)
	RenderingServer.force_draw(true, 0.0)
	RenderingServer.viewport_set_disable_3d(vp_rid, vp.disable_3d)
	paints += 1
	if _qa_framelog:
		print("QA PAINT %d at %.3f unix %.3f%s" % [paints, progress, Time.get_unix_time_from_system(), " (forced)" if force else ""])
	return true

## OPENSRO_QA_FRAMELOG=1 (round 785, World3D's per-frame line): each repaint
## `paint` makes is logged too, on the same clock.
static var _qa_framelog := OS.get_environment("OPENSRO_QA_FRAMELOG") != ""

func set_caption(text: String) -> void:
	if _caption != null:
		_caption.text = text
