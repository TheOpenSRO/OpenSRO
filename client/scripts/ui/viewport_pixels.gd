extends Node
class_name ViewportPixels

## Keeps a SubViewport rendering at the size its picture is drawn on screen,
## in physical pixels (round 695).
##
## The UI is drawn at the window's content scale (ClientSettings.
## apply_ui_scale: the canvas is the window's size divided by the UI scale,
## and the window's stretch transform scales it back up). A 3D preview drawn
## through a TextureRect -- the equipment window's paper doll, the player
## block's portrait, the customize screen's model -- was rendered at the
## rect's size in UI units, so at UI scale 2.0 every rendered pixel was
## magnified to 2 x 2 screen pixels (the user's "much lower resolution than
## the game", 2026-10-02, playing at 3840 x 2019 and scale 2.0). Its camera
## keeps its height (KEEP_HEIGHT) or is framed by height, so a larger buffer
## shows the same picture with more pixels.
##
## Added as a child of the TextureRect (attach); it follows the rect's size,
## the window's size and content scale (the viewport's size_changed, which
## Window::_update_viewport_size emits for both), and the rect's showing.
## `fit` turns the physical size into the buffer's (default: as is), e.g. the
## portrait's square of at least its READ 128 x 128.

## Emitted after the SubViewport's size changed, with the new size.
signal pixels_changed(size: Vector2i)

## The largest buffer side (OURS: a 3D preview over 8192 pixels is not a
## screen this client runs on).
const MAX_SIDE := 8192

var target: SubViewport = null
var fit: Callable = Callable()
var _watched: Viewport = null

## Physical pixels per UI unit along each axis for `c`'s local space: its
## canvas transform, the viewport's global canvas transform and the window's
## stretch (content scale).
static func scale_of(c: CanvasItem) -> Vector2:
	if c == null or not c.is_inside_tree():
		return Vector2.ONE
	var xf := c.get_viewport().get_final_transform() * c.get_global_transform_with_canvas()
	return xf.get_scale().abs()

## The size `c` covers on screen in physical pixels (at least 1 x 1).
static func physical_size(c: Control) -> Vector2i:
	var s := scale_of(c)
	return Vector2i(maxi(roundi(c.size.x * s.x), 1), maxi(roundi(c.size.y * s.y), 1))

## Makes `view` keep `vp` at its physical size; returns the follower (one per
## view: a second call retargets it).
static func attach(view: Control, vp: SubViewport, fit_size: Callable = Callable()) -> ViewportPixels:
	var f := view.get_node_or_null("ViewportPixels") as ViewportPixels
	if f == null:
		f = ViewportPixels.new()
		f.name = "ViewportPixels"
		f.target = vp
		f.fit = fit_size
		view.add_child(f)
	else:
		f.target = vp
		f.fit = fit_size
		f.refresh()
	return f

func _enter_tree() -> void:
	var view := get_parent() as Control
	if view == null:
		return
	view.resized.connect(refresh)
	view.visibility_changed.connect(refresh)
	_watched = get_viewport()
	_watched.size_changed.connect(refresh)
	refresh.call_deferred()

func _exit_tree() -> void:
	var view := get_parent() as Control
	if view != null:
		if view.resized.is_connected(refresh):
			view.resized.disconnect(refresh)
		if view.visibility_changed.is_connected(refresh):
			view.visibility_changed.disconnect(refresh)
	if _watched != null and is_instance_valid(_watched) and _watched.size_changed.is_connected(refresh):
		_watched.size_changed.disconnect(refresh)
	_watched = null

## The buffer size for the rect as it is now.
func wanted() -> Vector2i:
	var view := get_parent() as Control
	if view == null or not view.is_inside_tree():
		return Vector2i.ZERO
	var px := physical_size(view)
	if fit.is_valid():
		px = fit.call(px)
	return px.clamp(Vector2i(2, 2), Vector2i(MAX_SIDE, MAX_SIDE))

func refresh() -> void:
	if target == null or not is_instance_valid(target):
		return
	var view := get_parent() as Control
	if view == null or not view.is_inside_tree() or view.size.x <= 0.0 or view.size.y <= 0.0:
		return
	var px := wanted()
	if px != target.size:
		var was := target.size
		target.size = px
		# One line per change (rare: a dress, a resize, a scale change), so
		# a tester's log says what the preview renders at.
		print("ViewportPixels: %s %s -> %s for %s UI units x %s on screen (drawn with filter %s)" % [
			target.name, was, px, view.size, scale_of(view), effective_filter(view)])
		pixels_changed.emit(px)

## The texture filter `ci` draws with: its own, or the nearest canvas-item
## ancestor's that is not "inherit", or -- at the top of the canvas-item
## chain -- its viewport's default.
static func effective_filter(ci: CanvasItem) -> String:
	var names := ["inherit", "nearest", "linear", "nearest_mipmap", "linear_mipmap", "nearest_mipmap_aniso", "linear_mipmap_aniso"]
	var n: Node = ci
	while n is CanvasItem:
		if (n as CanvasItem).texture_filter != CanvasItem.TEXTURE_FILTER_PARENT_NODE:
			return names[(n as CanvasItem).texture_filter]
		n = n.get_parent()
	var vp_names := ["nearest", "linear", "linear_mipmap", "nearest_mipmap"]
	var d := int(ci.get_viewport().canvas_item_default_texture_filter) if ci.is_inside_tree() else 1
	return vp_names[clampi(d, 0, 3)] + " (the viewport's default)"
