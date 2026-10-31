class_name LoadingScreen
extends Control

## The "NOW LOADING" screen over world entry, so the ~minute of region loading
## is not a black, frozen window. Real backdrop art (loading_default.ddj) from
## the player's own Media.pk2, with the client's loading_form, gauge_loading
## and nowloading art over it (round 848, below); the gauge fills as region
## cells stream in. Added as the top child of the HUD Control
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
## Every part is the client's own art, placed as the client places it (round
## 848, below). It animates while the loader yields the main thread
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
## the forced last repaint); the screen's caption never changes. The art is
## FUN_0084b6e0's choice (LoadingBackdrop, round 785's follow-up).
##
## Round 848: drawn with the client's own parts, no Godot styling left. READ,
## FUN_0084b6e0 (0x84bc60..0x84be1b): three windows made by gwnd::FUN_00ba20b0
## on the screen, in this order (each drawn over the one before), every rect
## in the front end's 1600x1200 design space and scaled to the screen by
## FUN_00849c70(window, 0) -- x and width by W/1600, y and height by H/1200
## (FrontEndFrame.design_scale):
##   0x65 CIFStatic (class 0xee9720)  241, 973, 1121 x 64  loading_form.ddj
##   0x64 CIFGauge  (class 0xee9560)  268, 985, 1064 x 20  gauge_loading.ddj,
##        both its values (+0x380, +0x384) zeroed; FUN_0084c060 sets both to
##        the load's thousandths / 1000.0 each update, and CIFGauge's draw
##        (0x6387d0 -> 0x653140) scales the drawn width AND the texture's U
##        by the value: the art is cut off at the right, never squashed
##   0x66 CIFStatic (class 0xee9720)  268, 1025, 252 x 35  nowloading.ddj
## The backdrop is psmission.txt's "First" section's GDR_BACK (id 1, 0, 0,
## 1600 x 1200), placed by FUN_00849c70(window, 1) (0x84b7ac..0x84b7ba): the
## 4:3 flag, so its width is the scaled height x 4 / 3, centred: x += (W - H
## * 4 / 3) / 2 in integers. Nothing else is drawn: the gold caption, the
## gold-edged trough and the vignette this screen had before were OURS and
## are gone. OPEN: what shows beside a 4:3 backdrop on a wider screen
## (psmission's GDR_MASK, id 2, Style 1, has no art); black here.

const DEFAULT_BACKDROP := "interface\\loading\\loading_default.ddj"
## The three parts (READ, above): art, design rect.
const FORM_DDJ := "interface\\loading\\loading_form.ddj"
const GAUGE_DDJ := "interface\\loading\\gauge_loading.ddj"
const NOWLOADING_DDJ := "interface\\loading\\nowloading.ddj"
const FORM_RECT := Rect2i(241, 973, 1121, 64)
const GAUGE_RECT := Rect2i(268, 985, 1064, 20)
const NOWLOADING_RECT := Rect2i(268, 1025, 252, 35)
const DESIGN_SIZE := Vector2(1600.0, 1200.0)

## A repaint inside a synchronous load waits until more than this many ms
## have passed since the last one (READ: FUN_00ba3fc0, `0x32 < GetTickCount()
## - last`), unless forced.
const PAINT_INTERVAL_MS := 50

## The art this screen shows (LoadingBackdrop picks it; DEFAULT_BACKDROP when
## the caller names none, or the named one is not in the archive).
var _backdrop_path: String
## The Media.pk2 handed in by the caller, or null to open one in _ready.
var _media: Pk2Reader
## The gauge's fill, a canvas item of the gauge's drawn straight through the
## RenderingServer (round 785): a Control's size reaches the server only at
## its deferred redraw, so a fill set inside a synchronous load would not be
## in a repaint made there (`paint`). Freed with the screen.
var _fill_item := RID()
## The gauge's full width on screen (GAUGE_RECT scaled).
var _bar_width := 0.0
## The parts as built (round 848): the backdrop, loading_form, the gauge's
## holder and nowloading -- each null when the archive lacks its art (the
## gauge's holder is always made).
var _backdrop: TextureRect = null
var _form: TextureRect = null
var _gauge: Control = null
var _gauge_tex: Texture2D = null
var _nowloading: TextureRect = null
## The art this screen shows (after any fallback).
func backdrop_path() -> String:
	return _backdrop_path

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
	var bg := _art(media, _backdrop_path)
	# An archive without the zone's art (LoadingBackdrop's choice) falls back
	# to the default (OURS), so the screen is never bare.
	if bg == null and _backdrop_path != DEFAULT_BACKDROP and media != null:
		print("LoadingScreen: %s not in Media.pk2 -- %s instead" % [_backdrop_path, DEFAULT_BACKDROP])
		_backdrop_path = DEFAULT_BACKDROP
		bg = _art(media, _backdrop_path)
	var backdrop_ms := Time.get_ticks_msec() - t_backdrop
	_backdrop = bg
	if bg != null:
		bg.name = "Back"
		add_child(bg)
	# READ (FUN_0084b6e0): loading_form, then the gauge, then nowloading.
	_form = _art(media, FORM_DDJ)
	if _form != null:
		_form.name = "Form"
		add_child(_form)
	_gauge = Control.new()
	_gauge.name = "Gauge"
	_gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_gauge)
	_gauge_tex = FrontEndUi.load_ddj(media, GAUGE_DDJ) if media != null else null
	_nowloading = _art(media, NOWLOADING_DDJ)
	if _nowloading != null:
		_nowloading.name = "NowLoading"
		add_child(_nowloading)
	_fill_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_fill_item, _gauge.get_canvas_item())
	_relayout(screen)
	resized.connect(func() -> void: _relayout(size))
	# The frame this screen joined the tree in (it is drawn from the next one
	# on), how its archive was come by, and what the screen itself cost --
	# the line a load log is read by (client/tools/README.md, "Load
	# benchmark").
	print("LoadingScreen: up at frame %d (media %s, %d ms; backdrop %s %s, %d ms; form %s, gauge %s, nowloading %s; built in %d ms)" % [
		Engine.get_frames_drawn(), media_source, media_open_ms, _backdrop_path.get_file(),
		"decoded" if bg != null else "missing", backdrop_ms, "drawn" if _form != null else "missing",
		"drawn" if _gauge_tex != null else "missing", "drawn" if _nowloading != null else "missing",
		Time.get_ticks_msec() - t_start])

## A part's art as a TextureRect scaled to the rect it is given, or null.
static func _art(media: Pk2Reader, path: String) -> TextureRect:
	var tex := FrontEndUi.load_ddj(media, path) if media != null else null
	if tex == null:
		return null
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

## READ (FUN_00849c70 with its 4:3 flag off): a design rect on a screen of
## `screen` pixels, x and width by W / 1600, y and height by H / 1200, each
## made whole (FUN_00b42d10).
static func scaled_rect(rect: Rect2i, screen: Vector2) -> Rect2:
	var k := Vector2(screen.x / DESIGN_SIZE.x, screen.y / DESIGN_SIZE.y)
	return Rect2(roundf(rect.position.x * k.x), roundf(rect.position.y * k.y),
		roundf(rect.size.x * k.x), roundf(rect.size.y * k.y))

## READ (FUN_00849c70 with its 4:3 flag on, 0x849cb4..0x849cd0): the backdrop
## (0, 0, 1600 x 1200 scaled) made 4:3 from its height and centred: d = (w -
## h * 4 / 3) / 2 in integer division, x + d, width w - 2d.
static func backdrop_rect(screen: Vector2) -> Rect2:
	var r := scaled_rect(Rect2i(0, 0, 1600, 1200), screen)
	var w := int(r.size.x)
	var h := int(r.size.y)
	@warning_ignore("integer_division")
	var d: int = (w - (h * 4) / 3) / 2
	return Rect2(r.position.x + d, r.position.y, w - 2 * d, h)

func _relayout(screen: Vector2) -> void:
	if screen.x <= 0.0 or screen.y <= 0.0 or _gauge == null:
		return
	if _backdrop != null:
		var b := backdrop_rect(screen)
		_backdrop.position = b.position
		_backdrop.size = b.size
	if _form != null:
		var f := scaled_rect(FORM_RECT, screen)
		_form.position = f.position
		_form.size = f.size
	var g := scaled_rect(GAUGE_RECT, screen)
	_gauge.position = g.position
	_gauge.size = g.size
	_bar_width = g.size.x
	if _nowloading != null:
		var n := scaled_rect(NOWLOADING_RECT, screen)
		_nowloading.position = n.position
		_nowloading.size = n.size
	_draw_fill()

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

## READ (CIFGauge 0x6387d0 -> 0x653140): the drawn width and the texture's U
## both scale by the value, so gauge_loading.ddj is cut at the fill's edge.
func _draw_fill() -> void:
	if not _fill_item.is_valid():
		return
	RenderingServer.canvas_item_clear(_fill_item)
	if progress > 0.0 and _gauge_tex != null and _gauge != null:
		var tex_size := _gauge_tex.get_size()
		RenderingServer.canvas_item_add_texture_rect_region(_fill_item,
			Rect2(0, 0, _bar_width * progress, _gauge.size.y), _gauge_tex.get_rid(),
			Rect2(0, 0, tex_size.x * progress, tex_size.y))

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

## Kept for callers: the client's screen has no caption text (its "NOW
## LOADING" is nowloading.ddj's art, READ above), so this only logs.
func set_caption(text: String) -> void:
	print("LoadingScreen: caption '%s' not drawn (the client's screen has none)" % text)
