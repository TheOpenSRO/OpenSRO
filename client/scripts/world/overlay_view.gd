extends CanvasLayer
class_name OverlayView

## The world's screen-space overlays -- name plates, damage numbers, party
## marks and name boxes -- drawn AFTER the bloom (round 702 rework review).
##
## **READ.** The original draws its world, then the bloom
## (`SWorld::vslot_005` -> `Map::FUN_00a1d790`), then the lens flare
## (`Map::FUN_00a21280`); names and numbers are 2D text over the finished
## frame. RetailBloom samples the frame Godot's 3D view leaves, so every
## Label3D / Sprite3D in it was bloomed with it: a name plate's (1.0, 0.94,
## 0.72) came out near (204, 191, 148) / 255 (MEASURED by the review).
##
## **Here (OURS method).** Those nodes are put on their own render layer
## (BIT), which the main camera leaves out; a transparent SubViewport the
## size of the window, sharing the world, renders that layer alone through a
## camera that copies the main one every frame, and this layer shows it above
## the bloom (layer 0: RetailBloom is -1, the world's UI 1). They are all
## drawn with no depth test, so leaving the scene's depth behind changes
## nothing about what hides them. Their colours go through a linear tone map
## here (the original draws text colours as they are; under the world's
## Filmic they were lifted). The lens-flare sun sprite stays in the 3D view:
## it is depth-tested against the scene and is bloomed (OURS, disclosed).

const BIT := 1 << 16
const LAYER_INDEX := 0

var _viewport: SubViewport
var _camera: Camera3D
var _rect: TextureRect
var _source: Camera3D = null

func _init() -> void:
	name = "OverlayView"
	layer = LAYER_INDEX
	_viewport = SubViewport.new()
	_viewport.name = "Overlays"
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	_camera = Camera3D.new()
	_camera.cull_mask = BIT
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_camera.environment = env
	_viewport.add_child(_camera)
	add_child(_viewport)
	_rect = TextureRect.new()
	_rect.name = "Show"
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The texture is the window in physical pixels; under a UI scale other than
	# 1 that is bigger than the full rect in UI units, so the rect must not
	# take the texture's size as its minimum (round 702 final review: at 2.0 it
	# showed the overlay doubled from the top-left corner).
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	# The viewport's colour over a transparent clear is premultiplied.
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	_rect.material = m
	add_child(_rect)

func _ready() -> void:
	_rect.texture = _viewport.get_texture()
	process_priority = 1000

## The camera whose view the overlays follow; it stops drawing them.
func follow(source: Camera3D) -> void:
	_source = source
	if source != null:
		source.cull_mask &= ~BIT

## Stops (or resumes) rendering the overlay viewport: the front-end's 3D
## backdrop has nothing on the overlay layer (round 702 final review, L1).
func set_rendering(on: bool) -> void:
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	_rect.visible = on

## The rect the overlay is shown in, for the test.
func shown_rect() -> Control:
	return _rect

## Puts a node (and every visual under it) on the overlay layer.
static func adopt(node: Node) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = BIT
	for c in node.get_children():
		adopt(c)

func _process(_delta: float) -> void:
	if _source == null or not is_instance_valid(_source):
		return
	var size := get_viewport().get_window().size if get_viewport().get_window() != null else Vector2i(get_viewport().get_visible_rect().size)
	if _viewport.size != size:
		_viewport.size = size
	_camera.global_transform = _source.global_transform
	_camera.fov = _source.fov
	_camera.near = _source.near
	_camera.far = _source.far
	_camera.keep_aspect = _source.keep_aspect
	_camera.projection = _source.projection
	_camera.size = _source.size
	_camera.h_offset = _source.h_offset
	_camera.v_offset = _source.v_offset
