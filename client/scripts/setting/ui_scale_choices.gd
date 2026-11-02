extends RefCounted
class_name UiScaleChoices

## The UI scale as a list of percentages (round 854, OURS: the user's
## request, "Let's make UI scale a dropdown in the graphics settings. Let's
## use the same percentages that Windows supports"). The Option window's
## Video tab lists them in its "UI Scale" row (OptionVideoPage); /uiscale
## and the debug panel snap to them. The scale itself is still the window's
## content scale (ClientSettings.apply_ui_scale, round 672).
##
## **The list (OURS, Windows' display-scale steps):** 100, 125, 150, 175,
## 200, 225, 250, 300, 350, 400, 450 and 500 %. 100 % is the original's size
## and the default, and the smallest: nothing below it is offered (the
## original draws its interface 1:1 and never smaller; a saved value below
## 1.0 from the old /uiscale 0.5..3 reads as 100 %).
##
## **Only the scales that fit are offered, as Windows offers only those whose
## effective resolution stays at or above its minimum.** The minimum here is
## the game's own: a view (the window's size over the scale) of at least
## VideoOptions.MIN_VIEW, 800 x 600 -- READ, the Video tab's resolution list
## keeps only modes with width > 799 and height > 599 (c:0x5fef70,
## `799 < w && 599 < h`), so 800 x 600 is the smallest screen the original
## lays its interface out on. The original's windows take their places at
## run time, not from a design resolution (MEASURED: all 92 window records
## of `resinfo\ginterface.txt` carry zero rects, but for three of 2..12
## pixels), and its largest windows fit 800 x 600 (the item mall,
## GDR_RENEWAL_ITEM_MALL, 800 x 600; this Option window 700 x 500). The
## same minimum already decides which resolutions the tab lists at the
## scale in force (VideoOptions.resolution_choices, round 696).
##
## The saved choice is kept when the window shrinks under it: the largest
## scale that fits is used meanwhile (`effective`), and the saved one comes
## back when the window is large enough again (`apply_saved` watches the
## window's size).

const PERCENTS := [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]
const DEFAULT_PERCENT := 100
## Set on a window whose scale follows the saved choice (apply_saved): only
## then does a resize re-fit it, so a QA run's OPENSRO_QA_UI_SCALE, which
## saves nothing, is left alone.
const MANAGED_META := &"ui_scale_managed"
const WATCH_META := &"ui_scale_watch"

static var _refitting := false

## Whether `percent` leaves a view of at least MIN_VIEW in a window of
## `size` pixels. Exact in integers: 1280 x 720 at 120 % would be a view of
## exactly 1066.67 x 600 and fits; at 125 % (576 tall) it does not. An
## unknown size (zero) fits 100 % only.
static func fits(percent: int, size: Vector2i) -> bool:
	if size.x <= 0 or size.y <= 0:
		return percent <= DEFAULT_PERCENT
	return size.x * 100 >= VideoOptions.MIN_VIEW.x * percent and size.y * 100 >= VideoOptions.MIN_VIEW.y * percent

## The percentages offered for a window of `size`, smallest first; never
## empty (100 % always, as Windows always offers it).
static func offered(size: Vector2i) -> Array:
	var out: Array = []
	for p in PERCENTS:
		if fits(p, size):
			out.append(p)
	if out.is_empty():
		out.append(DEFAULT_PERCENT)
	return out

## The listed percentage nearest a scale factor (1.0 = 100 %). Below 100 %
## gives 100 %, above 500 % gives 500 %; halfway between two steps gives the
## smaller (1.125 -> 100, 2.75 -> 250). A non-number gives the default.
static func snap(scale: float) -> int:
	if is_nan(scale) or is_inf(scale) or scale <= 0.0:
		return DEFAULT_PERCENT
	var pct := scale * 100.0
	var best: int = PERCENTS[0]
	for p in PERCENTS:
		if absf(float(p) - pct) < absf(float(best) - pct) - 0.0001:
			best = p
	return best

## The percentage used for the saved `percent` in a window of `size`: the
## saved one when it fits, else the largest that does.
static func effective(percent: int, size: Vector2i) -> int:
	var p := snap(percent / 100.0)
	if fits(p, size):
		return p
	return int(offered(size)[-1])

## "125%".
static func label(percent: int) -> String:
	return "%d%%" % percent

## The saved choice, snapped to the list (an older build's 1.3 reads as 125 %).
static func saved_percent() -> int:
	return snap(float(ClientSettings.get_value(ClientSettings.SECTION_UI, ClientSettings.KEY_UI_SCALE, ClientSettings.DEFAULT_UI_SCALE)))

## Saves a choice (snapped) as its factor, the key's format since round 672.
static func save_percent(percent: int) -> void:
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_UI_SCALE, snap(percent / 100.0) / 100.0)

## Puts the saved choice in force on `window` -- or the largest that fits it
## -- and from then on re-fits it whenever the window changes size. Returns
## the percentage in force.
static func apply_saved(window: Window) -> int:
	if window == null:
		return 0
	window.set_meta(MANAGED_META, true)
	_watch(window)
	return _refit(window)

## Stops re-fitting `window` on a resize (tests and tools that set a scale
## by hand after an Apply).
static func release(window: Window) -> void:
	if window != null:
		window.set_meta(MANAGED_META, false)

## The percentage in force on `window` (its content scale).
static func in_force(window: Window) -> int:
	return snap(window.content_scale_factor) if window != null else DEFAULT_PERCENT

## One line for the log and the console: what is saved and what is used.
static func describe(saved: int, used: int, size: Vector2i) -> String:
	if saved == used:
		return "UI scale %s." % label(used)
	return "UI scale %s saved; a %dx%d window fits up to %s, so %s is used until the window is larger." % [
		label(saved), size.x, size.y, label(used), label(used)]

static func _watch(window: Window) -> void:
	if window.has_meta(WATCH_META):
		return
	window.set_meta(WATCH_META, true)
	window.size_changed.connect(func() -> void: _on_resized(window))

static func _on_resized(window: Window) -> void:
	if _refitting or not is_instance_valid(window) or not bool(window.get_meta(MANAGED_META, false)):
		return
	_refit(window)

static func _refit(window: Window) -> int:
	var saved := saved_percent()
	var used := effective(saved, window.size)
	if not is_equal_approx(window.content_scale_factor, used / 100.0):
		_refitting = true
		ClientSettings.apply_ui_scale(window, used / 100.0)
		_refitting = false
		print("UiScale: %s (window %dx%d, view %dx%d)" % [describe(saved, used, window.size), window.size.x, window.size.y,
			int(window.size.x * 100 / used), int(window.size.y * 100 / used)])
	return used
