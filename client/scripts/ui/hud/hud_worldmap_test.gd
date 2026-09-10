extends SceneTree

## Exercises the world map window's geometry, run headless:
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_worldmap_test.gd
##
## The window itself needs a real archive -- its frame comes from
## resinfo\ginterface.txt and its tiles from Media.pk2 -- so what is checked
## here is the arithmetic that decides *which* tiles are built and where the
## map may be dragged to. That is the part that would be wrong silently:
## an off-by-one in the tile range leaves a blank column at one edge of the
## window, which looks like missing artwork rather than a bug.
##
## The numbers are the real world map's: 33 x 11 tiles of 128 pixels drawn
## at 4224 x 1408, inside a 652 x 424 window whose frame leaves 572 x 308.

const HudWorldmap = preload("res://scripts/ui/hud/hud_worldmap.gd")

const TILE := Vector2(128, 128)
const ACROSS := 33
const DOWN := 11
const CANVAS := Vector2(4224, 1408)
## 652 - 40 - 40 by 424 - 68 - 48, the mframe_wnd_ pieces' own sizes.
const VIEWPORT := Vector2(572, 308)

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _range(canvas_pos: Vector2, margin := 0.0) -> Rect2i:
	return HudWorldmap.visible_tile_range(canvas_pos, VIEWPORT, TILE, ACROSS, DOWN, margin)

func _init() -> void:
	# At the top-left corner with no margin, the viewport shows columns
	# 0..4 (572 / 128 = 4.47) and rows 0..2 (308 / 128 = 2.4).
	var span := _range(Vector2.ZERO)
	_check(span == Rect2i(0, 0, 5, 3),
		"the top-left corner shows 5 x 3 tiles (got %s)" % str(span))

	# The margin adds a ring, but never past the map's own edges.
	span = _range(Vector2.ZERO, HudWorldmap.TILE_MARGIN)
	_check(span == Rect2i(0, 0, 6, 4),
		"a tile of margin adds one column and one row, and no negative index (got %s)"
			% str(span))

	# Scrolled to the far corner, the range stops at the last tile rather
	# than naming one past it -- which would ask the archive for a file that
	# does not exist, every frame.
	var far := -(CANVAS - VIEWPORT)
	span = _range(far, HudWorldmap.TILE_MARGIN)
	_check(span.end.x == ACROSS and span.end.y == DOWN,
		"the far corner stops at the last tile (got end %s of %d x %d)"
			% [str(span.end), ACROSS, DOWN])

	# A scroll that starts exactly on a tile boundary shows that tile, not
	# the one before it.
	span = _range(Vector2(-TILE.x, -TILE.y))
	_check(span.position == Vector2i(1, 1),
		"a scroll of exactly one tile starts at index 1 (got %s)" % str(span.position))

	# Scrolled entirely past the map, nothing is built.
	span = _range(Vector2(-CANVAS.x - 1000.0, 0.0))
	_check(span.size == Vector2i.ZERO,
		"scrolled off the end there is nothing to build (got %s)" % str(span))

	# A degenerate map builds nothing rather than dividing by zero.
	_check(HudWorldmap.visible_tile_range(Vector2.ZERO, VIEWPORT, Vector2.ZERO, 0, 0) == Rect2i(),
		"a map with no tiles builds nothing")

	# --- scrolling ---------------------------------------------------------
	# The world map is much larger than the window, so it clamps at both
	# ends and nothing beyond the map may be dragged into view.
	_check(HudWorldmap.clamp_scroll(Vector2(200, 200), CANVAS, VIEWPORT) == Vector2.ZERO,
		"the map cannot be dragged past its own top-left")
	var slack := -(CANVAS - VIEWPORT)
	_check(HudWorldmap.clamp_scroll(Vector2(-9999, -9999), CANVAS, VIEWPORT) == slack,
		"nor past its bottom-right (got %s, want %s)"
			% [str(HudWorldmap.clamp_scroll(Vector2(-9999, -9999), CANVAS, VIEWPORT)), str(slack)])

	# A city's own map is 1024 x 768 -- larger than the viewport on both
	# axes, so it clamps on both too.
	var city := Vector2(1024, 768)
	var at := HudWorldmap.clamp_scroll(Vector2(500, 500), city, VIEWPORT)
	_check(at == Vector2.ZERO, "a city map clamps on both axes (got %s)" % str(at))
	at = HudWorldmap.clamp_scroll(Vector2(-9999, -9999), city, VIEWPORT)
	_check(at == -(city - VIEWPORT),
		"and at its far corner shows its own bottom-right (got %s)" % str(at))
	var short := Vector2(400, 200)
	at = HudWorldmap.clamp_scroll(Vector2(0, 0), short, VIEWPORT)
	_check(is_equal_approx(at.x, (VIEWPORT.x - short.x) / 2.0)
		and is_equal_approx(at.y, (VIEWPORT.y - short.y) / 2.0),
		"a map smaller than the window is centred, not pinned to a corner (got %s)" % str(at))

	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		push_error("%d failure(s)" % _failures)
		quit(1)
