extends SceneTree

## ViewportPixels (round 695): a SubViewport shown through a TextureRect
## renders at the rect's size on screen in physical pixels -- the rect's size
## times the UI scale (the window's content scale factor) -- and follows the
## rect's resizes and the scale's changes; a `fit` shapes it (the portrait's
## square of at least 128).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  ", msg)
	else:
		_failures += 1
		print("FAIL ", msg)

func _frames(n: int = 2) -> void:
	for i in range(n):
		await process_frame

func _initialize() -> void:
	await process_frame
	root.size = Vector2i(1920, 1080)
	var script := load("res://scripts/ui/viewport_pixels.gd") as GDScript
	_check(script != null, "ViewportPixels exists")
	if script == null:
		_finish()
		return
	var rect := TextureRect.new()
	rect.position = Vector2(30, 40)
	rect.size = Vector2(100, 50)
	root.add_child(rect)
	var vp := SubViewport.new()
	vp.size = Vector2i(7, 7)
	root.add_child(vp)
	var follower: Node = script.call("attach", rect, vp)
	var seen: Array = []
	follower.connect("pixels_changed", func(s: Vector2i) -> void: seen.append(s))
	await _frames()
	_check(vp.size == Vector2i(100, 50), "at scale 1.0 the buffer is the rect's 100x50 (got %s)" % vp.size)
	rect.size = Vector2(120, 60)
	await _frames()
	_check(vp.size == Vector2i(120, 60), "a resized rect resizes the buffer (got %s)" % vp.size)
	root.content_scale_factor = 2.0
	await _frames()
	_check(vp.size == Vector2i(240, 120), "at UI scale 2.0 it is 240x120 (got %s)" % vp.size)
	root.content_scale_factor = 1.95
	await _frames()
	_check(vp.size == Vector2i(234, 117), "at UI scale 1.95 it is 234x117 (got %s)" % vp.size)
	root.content_scale_factor = 1.0
	await _frames()
	_check(seen.size() >= 4 and seen[-1] == Vector2i(120, 60), "pixels_changed reports each new size (%s)" % [seen])
	# The portrait's fit: retail's 128 square, or larger.
	var sq := ViewportPixels.attach(rect, vp, PlayerPortrait.buffer_for)
	_check(sq == follower, "a second attach retargets the same follower")
	await _frames()
	_check(vp.size == Vector2i(128, 128), "the portrait fit keeps retail's 128x128 when the picture is smaller (got %s)" % vp.size)
	root.content_scale_factor = 2.5
	await _frames()
	_check(vp.size == Vector2i(300, 300), "and grows square with the picture's longer side at 2.5 (got %s)" % vp.size)
	root.content_scale_factor = 1.0
	# Freed with its rect: the window's signal is let go.
	var fid := follower.get_instance_id()
	rect.queue_free()
	await _frames()
	var dangling := 0
	for c in root.size_changed.get_connections():
		var cb: Callable = c["callable"]
		if cb.get_object_id() == fid:
			dangling += 1
	_check(dangling == 0, "a freed follower leaves no connection on the window")
	root.content_scale_factor = 1.5
	await _frames()
	# 128: its last size, set when the scale went back to 1.0 before the free.
	_check(vp.size == Vector2i(128, 128), "and no longer resizes the buffer (got %s)" % vp.size)
	root.content_scale_factor = 1.0
	vp.queue_free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
