extends RefCounted
class_name NamePlateBatch

## Round 757: other players' name plates drawn as a few batched meshes instead
## of one Label3D each.
##
## **Why.** A Label3D makes its own RenderingServer mesh and its own material
## per surface (Godot 4.2.2 `scene/3d/label_3d.cpp` l. 352-392, READ:
## `material_create()` for every label's every glyph-texture surface), so 7,000
## plates are 14,000 draw calls with 14,000 materials in the overlay pass
## (OverlayView), none instanced. MEASURED (round 757, 7,000 standing at the
## Jangan spawn, all within 300 of the player): the overlay's render took 14.1
## ms of CPU a frame, and the probe's `labels` step at 1,000 took the frame from
## 18-21 to 14.5 ms.
##
## **What is drawn is the Label3D's own.** Each plate is shaped with the same
## TextServer calls Label3D::_shape makes, with the Label3D's own settings
## (text, font, font size, pixel size, outline, colours, alignment centred), and
## each glyph becomes the same quad with the same UVs into the same font-cache
## texture (`_generate_glyph_surfaces`). The material is the one Label3D asks
## for (BaseMaterial3D.get_material_for_2d's flags: unshaded, alpha, billboard
## keeping scale, fixed size, no depth test, the label's texture filter),
## written out from Godot 4.2.2's generator (`shader_code`), with one change:
## the billboard's origin is the plate's point read from an anchor texture by
## the vertex's plate slot (UV2.x), not the instance's MODEL_MATRIX[3]. So a
## plate moves by a texel write, and a standing crowd writes nothing.
##
## **The 300 rule** (NamePlates, READ round 673) is applied in the vertex
## shader: a plate whose owner is not strictly within `range` of the player
## (uniform) collapses to a point. It is exact every frame, where the Sweep
## re-tests a sixth of the plates a frame.
##
## OURS, disclosed:
##   - Draw order. Label3D sorts every plate back to front (each is its own
##     transparent instance); here all outlines draw before all texts as there
##     (render priority -1 against 1), but within a pass the plates draw in slot
##     order. Where two plates overlap on screen, the farther may be drawn over
##     the nearer.
##   - A plate is placed at its owner's position plus the label's height, both
##     in world space (the owner's rotation and scale are not applied: a body's
##     holder is never scaled, and its rotation is about the vertical axis the
##     label's offset lies on).
##   - The material's code is a copy of 4.2.2's generator for these flags, not
##     read back from the engine (4.2 does not expose it to scripts): a later
##     engine's StandardMaterial3D may differ. `shader_code` names every line.

const ANCHOR_W := 256
const CHUNK := 256
const HIDDEN := -1.0e9


class Plate:
	var slot := -1
	var label: Label3D
	var owner: Node3D
	## Surface key -> [verts PackedVector3Array, uvs PackedVector2Array,
	## colors PackedColorArray, uv2s PackedVector2Array]
	var parts := {}
	## Round 762: added since its chunk was last rebuilt: its glyphs are not in
	## the chunk's mesh yet (its slot may still hold another plate's), so its
	## anchor stays hidden until the rebuild.
	var pending := false

class Chunk:
	var mesh := RID()
	var inst := RID()
	var dirty := false
	## Round 762: the frame it was first marked dirty since its last rebuild,
	## and the last frame it was marked.
	var dirty_since := -1
	var touched := -1
	var keys: Array = []

var ok := false
var scenario := RID()
var layers := 0
var range := NamePlates.RANGE
var _shader_code := ""
var _shaders := {}         # msdf bool -> Shader
var _materials := {}       # surface key -> material RID
var _plates := {}          # Label3D -> Plate
var _by_slot: Array = []   # slot -> Plate or null
var _free: Array[int] = []
var _chunks: Array = []    # Chunk
var _anchors := PackedFloat32Array()
var _anchor_tex: ImageTexture = null
var _anchor_dirty := false
var _anchor_rows := 0
var _player := Vector3.ZERO
## Counts for the QA line and the tests.
var stats := {"plates": 0, "glyphs": 0, "rebuilds": 0, "uploads": 0}

## A change of the fonts' caches (ClientSettings' UI scale refresh): every
## plate is shaped again at the next flush (round 672: the glyph textures it
## pointed at are gone).
static var generation := 0
var _generation := 0

func _init(world_scenario: RID = RID(), layer_mask: int = 0) -> void:
	scenario = world_scenario
	layers = layer_mask
	_generation = generation
	ok = _make_shader_code()

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	for c in _chunks:
		var ch: Chunk = c
		if ch.inst.is_valid():
			RenderingServer.free_rid(ch.inst)
		if ch.mesh.is_valid():
			RenderingServer.free_rid(ch.mesh)
	_chunks.clear()
	for k in _materials:
		RenderingServer.free_rid(_materials[k])
	_materials.clear()

## Godot 4.2.2's StandardMaterial3D code for a Label3D surface, as
## BaseMaterial3D::_update_shader writes it for get_material_for_2d's flags
## (material.cpp l. 603-1420, READ: unshaded, TRANSPARENCY_ALPHA, double-sided,
## sRGB vertex colour used as albedo, no depth test, fixed size, billboard
## keeping scale, the label's texture filter with repeat), written out with the
## lines that do nothing unshaded (metallic, roughness, specular) left out, and
## the billboard's origin moved to the plate's point. Godot does not expose a
## material's generated code to scripts in 4.2 (no get_shader_rid binding).
func _make_shader_code() -> bool:
	return true

static func shader_code(msdf: bool, filter: int) -> String:
	var tf := "filter_linear_mipmap"
	match filter:
		BaseMaterial3D.TEXTURE_FILTER_NEAREST: tf = "filter_nearest"
		BaseMaterial3D.TEXTURE_FILTER_LINEAR: tf = "filter_linear"
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS: tf = "filter_nearest_mipmap"
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC: tf = "filter_nearest_mipmap_anisotropic"
		BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC: tf = "filter_linear_mipmap_anisotropic"
	tf += ",repeat_enable"
	var c := "shader_type spatial;\nrender_mode blend_mix,depth_draw_opaque,cull_disabled,diffuse_burley,specular_schlick_ggx,unshaded,depth_test_disabled;\n"
	c += "uniform vec4 albedo : source_color;\n"
	c += "uniform sampler2D texture_albedo : source_color," + tf + ";\n"
	if msdf:
		c += "uniform float msdf_pixel_range;\nuniform float msdf_outline_size;\n"
	c += "uniform vec3 uv1_scale;\nuniform vec3 uv1_offset;\nuniform vec3 uv2_scale;\nuniform vec3 uv2_offset;\n"
	c += "uniform sampler2D plate_anchors : filter_nearest;\nuniform vec3 plate_player = vec3(0.0);\nuniform float plate_range = 300.0;\n\n"
	c += "void vertex() {\n"
	c += "\tint plate_slot = int(UV2.x + 0.5);\n"
	c += "\tvec4 plate_a = texelFetch(plate_anchors, ivec2(plate_slot %% %d, plate_slot / %d), 0);\n" % [ANCHOR_W, ANCHOR_W]
	c += "\tvec3 plate_point = plate_a.xyz + vec3(0.0, plate_a.w, 0.0);\n"
	c += "\tif (plate_a.w < -1.0e8 || distance(plate_a.xyz, plate_player) >= plate_range) { VERTEX = vec3(0.0); }\n"
	c += "\tif (!OUTPUT_IS_SRGB) {\n\t\tCOLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));\n\t}\n"
	c += "\tUV=UV*uv1_scale.xy+uv1_offset.xy;\n"
	c += "\tMODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], vec4(plate_point, 1.0));\n"
	c += "\tMODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));\n"
	c += "\tMODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);\n"
	c += "\tif (PROJECTION_MATRIX[3][3] != 0.0) {\n\t\tfloat h = abs(1.0 / (2.0 * PROJECTION_MATRIX[1][1]));\n\t\tfloat sc = (h * 2.0);\n\t\tMODELVIEW_MATRIX[0]*=sc;\n\t\tMODELVIEW_MATRIX[1]*=sc;\n\t\tMODELVIEW_MATRIX[2]*=sc;\n"
	c += "\t} else {\n\t\tfloat sc = -(MODELVIEW_MATRIX)[3].z;\n\t\tMODELVIEW_MATRIX[0]*=sc;\n\t\tMODELVIEW_MATRIX[1]*=sc;\n\t\tMODELVIEW_MATRIX[2]*=sc;\n\t}\n"
	c += "}\n\n"
	if msdf:
		c += "float msdf_median(float r, float g, float b, float a) {\n\treturn min(max(min(r, g), min(max(r, g), b)), a);\n}\n\n"
	c += "void fragment() {\n\tvec2 base_uv = UV;\n\tvec4 albedo_tex = texture(texture_albedo,base_uv);\n"
	if msdf:
		c += "\t{\n\t\talbedo_tex.rgb = mix(vec3(1.0 + 0.055) * pow(albedo_tex.rgb, vec3(1.0 / 2.4)) - vec3(0.055), vec3(12.92) * albedo_tex.rgb.rgb, lessThan(albedo_tex.rgb, vec3(0.0031308)));\n"
		c += "\t\tvec2 msdf_size = vec2(msdf_pixel_range) / vec2(textureSize(texture_albedo, 0));\n\t\tvec2 dest_size = vec2(1.0) / fwidth(base_uv);\n"
		c += "\t\tfloat px_size = max(0.5 * dot(msdf_size, dest_size), 1.0);\n\t\tfloat d = msdf_median(albedo_tex.r, albedo_tex.g, albedo_tex.b, albedo_tex.a) - 0.5;\n"
		c += "\t\tif (msdf_outline_size > 0.0) {\n\t\t\tfloat cr = clamp(msdf_outline_size, 0.0, msdf_pixel_range / 2.0) / msdf_pixel_range;\n\t\t\talbedo_tex.a = clamp((d + cr) * px_size, 0.0, 1.0);\n"
		c += "\t\t} else {\n\t\t\talbedo_tex.a = clamp(d * px_size + 0.5, 0.0, 1.0);\n\t\t}\n\t\talbedo_tex.rgb = vec3(1.0);\n\t}\n"
	c += "\talbedo_tex *= COLOR;\n\tALBEDO = albedo.rgb * albedo_tex.rgb;\n\tALPHA *= albedo.a * albedo_tex.a;\n}\n"
	return c

func _shader_for(msdf: bool, filter: int) -> Shader:
	var key := "%s|%d" % [msdf, filter]
	var sh: Shader = _shaders.get(key)
	if sh != null:
		return sh
	sh = Shader.new()
	sh.code = shader_code(msdf, filter)
	_shaders[key] = sh
	return sh

func _material_for(label: Label3D, tex: RID, outline: bool, outline_size: int, font_rid: RID, msdf: bool) -> RID:
	var key := "%d|%d|%d" % [tex.get_id(), 1 if outline else 0, label.texture_filter]
	var mat: RID = _materials.get(key, RID())
	if mat.is_valid():
		return mat
	mat = RenderingServer.material_create()
	RenderingServer.material_set_shader(mat, _shader_for(msdf, label.texture_filter).get_rid())
	# Label3D's own parameters (label_3d.cpp l. 356-372).
	RenderingServer.material_set_param(mat, "albedo", Color(1, 1, 1, 1))
	RenderingServer.material_set_param(mat, "specular", 0.5)
	RenderingServer.material_set_param(mat, "metallic", 0.0)
	RenderingServer.material_set_param(mat, "roughness", 1.0)
	RenderingServer.material_set_param(mat, "uv1_offset", Vector3(0, 0, 0))
	RenderingServer.material_set_param(mat, "uv1_scale", Vector3(1, 1, 1))
	RenderingServer.material_set_param(mat, "uv2_offset", Vector3(0, 0, 0))
	RenderingServer.material_set_param(mat, "uv2_scale", Vector3(1, 1, 1))
	RenderingServer.material_set_param(mat, "alpha_scissor_threshold", label.alpha_scissor_threshold)
	RenderingServer.material_set_param(mat, "alpha_hash_scale", label.alpha_hash_scale)
	RenderingServer.material_set_param(mat, "alpha_antialiasing_edge", label.alpha_antialiasing_edge)
	if msdf:
		var ts := TextServerManager.get_primary_interface()
		RenderingServer.material_set_param(mat, "msdf_pixel_range", ts.font_get_msdf_pixel_range(font_rid))
		RenderingServer.material_set_param(mat, "msdf_outline_size", outline_size)
	RenderingServer.material_set_param(mat, "texture_albedo", tex)
	RenderingServer.material_set_render_priority(mat, label.outline_render_priority if outline else label.render_priority)
	_anchor_bind(mat)
	_materials[key] = mat
	return mat

# --- plates -------------------------------------------------------------------

func has(label: Label3D) -> bool:
	return _plates.has(label)

func size() -> int:
	return _plates.size()

## Starts drawing `label` (a Label3D configured as World3D._name_plate makes
## it) over `owner`; the label itself is never drawn.
func add(label: Label3D, owner: Node3D) -> bool:
	if not ok or label == null or owner == null:
		return false
	if _plates.has(label):
		return true
	var p := Plate.new()
	p.label = label
	p.owner = owner
	p.slot = _take_slot()
	_by_slot[p.slot] = p
	_plates[label] = p
	_shape(p)
	label.visible = false
	p.pending = true
	_write_anchor(p)
	_mark(p.slot)
	stats["plates"] = _plates.size()
	return true

func remove(label: Label3D) -> void:
	var p: Plate = _plates.get(label)
	if p == null:
		return
	_plates.erase(label)
	_held.erase(label)
	_by_slot[p.slot] = null
	_free.append(p.slot)
	# Round 762: its anchor hidden is enough (the shader draws nothing at a
	# hidden anchor); its glyphs go when the chunk is next rebuilt -- a
	# slot taken again marks it -- not a rebuild a frame while a crowd of
	# thousands leaves (MEASURED r762.md: 2-7 ms a frame).
	_hide_slot(p.slot)
	stats["plates"] = _plates.size()

## Round 762: a plate made for a body whose page is held: drawn nothing
## (its anchor hidden) until released at the page's reveal -- the shaping and
## the slot are done while the page is held, so the reveal is an anchor write.
var _held := {}

func hold(label: Label3D) -> void:
	var p: Plate = _plates.get(label)
	if p == null:
		return
	_held[label] = true
	_hide_slot(p.slot)

func release(label: Label3D) -> void:
	if not _held.has(label):
		return
	_held.erase(label)
	var p: Plate = _plates.get(label)
	if p != null:
		_write_anchor(p)

## The owner moved, turned, was hidden or shown: its plate's point again.
func moved(label: Label3D) -> void:
	var p: Plate = _plates.get(label)
	if p != null:
		_write_anchor(p)

## The label's text or look changed: shaped again.
func reshape(label: Label3D) -> void:
	var p: Plate = _plates.get(label)
	if p != null:
		_shape(p)
		_mark(p.slot)

## Round 762: the chunk holding `slot` is to be rebuilt.
func _mark(slot: int) -> void:
	var ch := _chunk_of(slot)
	var f := Engine.get_process_frames()
	if not ch.dirty:
		ch.dirty = true
		ch.dirty_since = f
	ch.touched = f

func _take_slot() -> int:
	if not _free.is_empty():
		return _free.pop_back()
	var s := _by_slot.size()
	_by_slot.append(null)
	var rows := ceili(float(s + 1) / float(ANCHOR_W))
	if rows > _anchor_rows:
		_anchor_rows = maxi(rows, _anchor_rows * 2)
		var old := _anchors.size()
		_anchors.resize(_anchor_rows * ANCHOR_W * 4)
		for i in range(old / 4, _anchor_rows * ANCHOR_W):
			_anchors[i * 4 + 3] = HIDDEN
		_anchor_tex = null
	return s

func _hide_slot(slot: int) -> void:
	_anchors[slot * 4 + 3] = HIDDEN
	_anchor_dirty = true

func _write_anchor(p: Plate) -> void:
	var o := p.slot * 4
	if p.pending or not is_instance_valid(p.owner) or not p.owner.is_inside_tree() or not p.owner.is_visible_in_tree() or _held.has(p.label):
		if _anchors[o + 3] != HIDDEN:
			_anchors[o + 3] = HIDDEN
			_anchor_dirty = true
		return
	var at := p.owner.global_position
	var h := p.label.position.y
	# Only a change goes up (the spread re-read finds most plates where they were).
	if _anchors[o] == at.x and _anchors[o + 1] == at.y and _anchors[o + 2] == at.z and _anchors[o + 3] == h:
		return
	_anchors[o] = at.x
	_anchors[o + 1] = at.y
	_anchors[o + 2] = at.z
	_anchors[o + 3] = h
	_anchor_dirty = true

## Label3D::_shape and _generate_glyph_surfaces (label_3d.cpp l. 328-626, READ)
## for one line of text, centred both ways, offset 0, line spacing 0.
func _shape(p: Plate) -> void:
	p.parts.clear()
	var label := p.label
	var ts := TextServerManager.get_primary_interface()
	var font: Font = label.font if label.font != null else ThemeDB.fallback_font
	if font == null:
		return
	var txt := TranslationServer.translate(label.text)
	if label.uppercase:
		txt = ts.string_to_upper(txt, label.language)
	var shaped := ts.create_shaped_text()
	ts.shaped_text_set_direction(shaped, label.text_direction)
	ts.shaped_text_add_string(shaped, txt, font.get_rids(), label.font_size, font.get_opentype_features(), label.language)
	ts.shaped_text_set_bidi_override(shaped, ts.parse_structured_text(label.structured_text_bidi_override, label.structured_text_bidi_override_options, txt))
	var breaks := ts.shaped_text_get_line_breaks(shaped, label.width, 0, TextServer.BREAK_MANDATORY | TextServer.BREAK_TRIM_EDGE_SPACES)
	var lines: Array[RID] = []
	var i := 0
	while i + 1 < breaks.size():
		lines.append(ts.shaped_text_substr(shaped, breaks[i], breaks[i + 1] - breaks[i]))
		i += 2
	var px := label.pixel_size
	# Round 811: the box behind the name (NamePlates.box_rect), as the
	# label's NameBox Sprite3D draws it: one quad of the white texel in the
	# box colour, one render priority under the text.
	if bool(label.get_meta(NamePlates.BOX_META, false)) and label.text != "":
		_box_quad(p, NamePlates.box_rect(label), px)
	var total_h := 0.0
	for line in lines:
		total_h += (ts.shaped_text_get_size(line).y + label.line_spacing) * px
	var vbegin := (total_h - label.line_spacing * px) / 2.0
	var offset := Vector2(0.0, vbegin + label.offset.y * px)
	var glyphs := 0
	for line in lines:
		var gl: Array = ts.shaped_text_get_glyphs(line)
		var line_w := ts.shaped_text_get_width(line) * px
		offset.x = -line_w / 2.0 + label.offset.x * px
		offset.y -= ts.shaped_text_get_ascent(line) * px
		if label.outline_modulate.a != 0.0 and label.outline_size > 0:
			var ol := offset
			for g in gl:
				ol = _glyph(p, ts, g, ol, label.outline_modulate, true, label.outline_size, px)
				glyphs += 1
		var off := offset
		for g in gl:
			off = _glyph(p, ts, g, off, label.modulate, false, 0, px)
			glyphs += 1
		offset.y -= (ts.shaped_text_get_descent(line) + label.line_spacing) * px
	for line in lines:
		ts.free_rid(line)
	ts.free_rid(shaped)
	stats["glyphs"] = int(stats["glyphs"]) + glyphs

## Round 811: a plate's box, `r` in its font pixels (centre, size).
func _box_quad(p: Plate, r: Rect2, px: float) -> void:
	var key := _box_key(p.label)
	var part: Array = p.parts.get(key, [])
	if part.is_empty():
		part = [PackedVector3Array(), PackedVector2Array(), PackedColorArray(), PackedVector2Array()]
		p.parts[key] = part
	var x0 := (r.position.x - r.size.x * 0.5) * px
	var x1 := (r.position.x + r.size.x * 0.5) * px
	var y0 := (r.position.y - r.size.y * 0.5) * px
	var y1 := (r.position.y + r.size.y * 0.5) * px
	var v0 := Vector3(x0, y1, 0.0)
	var v1 := Vector3(x1, y1, 0.0)
	var v2 := Vector3(x1, y0, 0.0)
	var v3 := Vector3(x0, y0, 0.0)
	var uv := Vector2(0.5, 0.5)
	append_quad(part, PackedVector3Array([v0, v1, v2, v0, v2, v3]), PackedVector2Array([uv, uv, uv, uv, uv, uv]), NamePlates.BOX_COLOUR, p.slot)

## The one white texel every box samples.
static var _white: ImageTexture = null

static func white_texture() -> ImageTexture:
	if _white == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_white = ImageTexture.create_from_image(img)
	return _white

## The box's surface key: its own material, under the text's priority.
func _box_key(label: Label3D) -> String:
	var key := "box|0|%d|%d" % [label.texture_filter, label.render_priority]
	if not _materials.has(key):
		var mat := RenderingServer.material_create()
		RenderingServer.material_set_shader(mat, _shader_for(false, label.texture_filter).get_rid())
		RenderingServer.material_set_param(mat, "albedo", Color(1, 1, 1, 1))
		RenderingServer.material_set_param(mat, "uv1_offset", Vector3(0, 0, 0))
		RenderingServer.material_set_param(mat, "uv1_scale", Vector3(1, 1, 1))
		RenderingServer.material_set_param(mat, "uv2_offset", Vector3(0, 0, 0))
		RenderingServer.material_set_param(mat, "uv2_scale", Vector3(1, 1, 1))
		RenderingServer.material_set_param(mat, "texture_albedo", white_texture().get_rid())
		RenderingServer.material_set_render_priority(mat, label.render_priority - 1)
		_anchor_bind(mat)
		_materials[key] = mat
	return key

## One glyph's quads (its `repeat` of them), as _generate_glyph_surfaces: two
## triangles (Label3D indexes 0,1,2 0,2,3 of its four corners), written out.
func _glyph(p: Plate, ts: TextServer, g: Dictionary, at: Vector2, colour: Color, outline: bool, outline_size: int, px: float) -> Vector2:
	var font_rid: RID = g.get("font_rid", RID())
	var size := Vector2i(int(g.get("font_size", 0)), outline_size)
	var index := int(g.get("index", 0))
	var repeat := int(g.get("repeat", 1))
	var advance := float(g.get("advance", 0.0))
	for _r in range(repeat):
		if font_rid.is_valid():
			var gi := _glyph_info(p.label, ts, font_rid, size, index, outline, outline_size)
			if not gi.is_empty():
				var key: String = gi[0]
				var goff: Vector2 = g.get("offset", Vector2.ZERO)
				var gl_of: Vector2 = ((gi[1] as Vector2) + goff) * px
				var gl_sz: Vector2 = (gi[2] as Vector2) * px
				var part: Array = p.parts.get(key, [])
				if part.is_empty():
					part = [PackedVector3Array(), PackedVector2Array(), PackedColorArray(), PackedVector2Array()]
					p.parts[key] = part
				var v0 := Vector3(at.x + gl_of.x, at.y - gl_of.y, 0.0)
				var v1 := Vector3(at.x + gl_of.x + gl_sz.x, at.y - gl_of.y, 0.0)
				var v2 := Vector3(at.x + gl_of.x + gl_sz.x, at.y - gl_of.y - gl_sz.y, 0.0)
				var v3 := Vector3(at.x + gl_of.x, at.y - gl_of.y - gl_sz.y, 0.0)
				append_quad(part, PackedVector3Array([v0, v1, v2, v0, v2, v3]), gi[3], colour, p.slot)
		at.x += advance * px
	return at

## Round 757's merge: a glyph's texture, metrics and UVs, asked of the
## TextServer once per (font, size, outline, glyph) and kept -- a ghost page
## makes hundreds of plates in a frame (round 756), and each glyph took six
## TextServer calls (MEASURED: about 0.3 ms a plate at 3,000). [] when the glyph
## has no texture (Label3D draws nothing for it either). Kept until the fonts'
## caches change (`generation`, the UI scale): a glyph's place in its cache
## texture does not move until then (TextServer adds textures, it does not
## repack them).
var _glyphs := {}

func _glyph_info(label: Label3D, ts: TextServer, font_rid: RID, size: Vector2i, index: int, outline: bool, outline_size: int) -> Array:
	var ck := "%d|%d|%d|%d|%d" % [font_rid.get_id(), size.x, size.y, index, label.texture_filter]
	var hit = _glyphs.get(ck)
	if hit != null:
		return hit
	var info: Array = []
	var tex := ts.font_get_glyph_texture_rid(font_rid, size, index)
	if tex.is_valid():
		var uv := ts.font_get_glyph_uv_rect(font_rid, size, index)
		var texs := ts.font_get_glyph_texture_size(font_rid, size, index)
		var u0 := Vector2(uv.position.x / texs.x, uv.position.y / texs.y)
		var u1 := Vector2((uv.position.x + uv.size.x) / texs.x, uv.position.y / texs.y)
		var u2 := Vector2((uv.position.x + uv.size.x) / texs.x, (uv.position.y + uv.size.y) / texs.y)
		var u3 := Vector2(uv.position.x / texs.x, (uv.position.y + uv.size.y) / texs.y)
		var msdf := ts.font_is_multichannel_signed_distance_field(font_rid)
		info = [_key(label, tex, outline, outline_size, font_rid, msdf), ts.font_get_glyph_offset(font_rid, size, index),
			ts.font_get_glyph_size(font_rid, size, index), PackedVector2Array([u0, u1, u2, u0, u2, u3])]
	# A glyph not yet rasterised has no texture: not kept, asked again next time.
	if not info.is_empty():
		_glyphs[ck] = info
	return info

## Two triangles into a part ([verts, uvs, colours, uv2 slots]). Packed arrays
## are values: each is taken out, grown and put back -- an append on `part[0]`
## itself grows a copy and leaves the part empty (round 757's first build drew
## no plate that way).
static func append_quad(part: Array, verts6: PackedVector3Array, uvs6: PackedVector2Array, colour: Color, slot: int) -> void:
	var verts: PackedVector3Array = part[0]
	verts.append_array(verts6)
	part[0] = verts
	var uvs: PackedVector2Array = part[1]
	uvs.append_array(uvs6)
	part[1] = uvs
	var cols: PackedColorArray = part[2]
	var sv := Vector2(float(slot), 0.0)
	var slots: PackedVector2Array = part[3]
	for _k in range(verts6.size()):
		cols.append(colour)
		slots.append(sv)
	part[2] = cols
	part[3] = slots

## Every part of `parts` (each [verts, uvs, colours, slots]) joined into one.
static func concat(parts: Array) -> Array:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var slots := PackedVector2Array()
	for src in parts:
		verts.append_array(src[0])
		uvs.append_array(src[1])
		cols.append_array(src[2])
		slots.append_array(src[3])
	return [verts, uvs, cols, slots]

## A surface key: one material, so one draw a chunk.
func _key(label: Label3D, tex: RID, outline: bool, outline_size: int, font_rid: RID, msdf: bool) -> String:
	var key := "%d|%d|%d" % [tex.get_id(), 1 if outline else 0, label.texture_filter]
	if not _materials.has(key):
		_material_for(label, tex, outline, outline_size, font_rid, msdf)
	return key

## Census for the QA line: plates, glyph vertices by pass, materials, chunks.
func describe() -> String:
	var outline := 0
	var text := 0
	for k in _plates:
		var p: Plate = _plates[k]
		for key in p.parts:
			var n := (p.parts[key][0] as PackedVector3Array).size()
			if String(key).split("|")[1] == "1":
				outline += n
			else:
				text += n
	var hidden := 0
	for k in _plates:
		if _anchors[(_plates[k] as Plate).slot * 4 + 3] < -1.0e8:
			hidden += 1
	return "plates=%d hidden=%d outline_vertices=%d text_vertices=%d materials=%d chunks=%d rebuilds=%d uploads=%d range=%.0f player=%s" % [
		_plates.size(), hidden, outline, text, _materials.size(), _chunks.size(), int(stats["rebuilds"]), int(stats["uploads"]), range, str(_player.round())]

# --- the frame ----------------------------------------------------------------

func _chunk_of(slot: int) -> Chunk:
	var c := slot / CHUNK
	while _chunks.size() <= c:
		_chunks.append(Chunk.new())
	return _chunks[c]

## Once a frame: the player's place, the anchors up when any changed, and the
## chunks whose plates changed rebuilt.
func flush(player: Vector3) -> void:
	if not ok:
		return
	if _generation != generation:
		_generation = generation
		_glyphs.clear()
		for k in _plates:
			var p: Plate = _plates[k]
			if is_instance_valid(p.label):
				_shape(p)
				_mark(p.slot)
	if player != _player:
		_player = player
		for k in _materials:
			RenderingServer.material_set_param(_materials[k], "plate_player", player)
	# Round 762: one chunk rebuilt a frame at most, and a chunk still being
	# added to waits until it settles (REBUILD_SETTLE frames without a change)
	# or has waited REBUILD_WAIT frames: a crowd's plates come a few a frame,
	# and each rebuilt their whole chunk (256 plates' glyphs) every frame
	# (MEASURED r762.md: w_plates 5-7 ms a frame while a page was held).
	var f := Engine.get_process_frames()
	var pick := -1
	for ci in range(_chunks.size()):
		var ch: Chunk = _chunks[ci]
		if not ch.dirty:
			continue
		if f - ch.touched < REBUILD_SETTLE and f - ch.dirty_since < REBUILD_WAIT:
			continue
		if pick < 0 or ch.dirty_since < (_chunks[pick] as Chunk).dirty_since:
			pick = ci
	if pick >= 0:
		var ch: Chunk = _chunks[pick]
		ch.dirty = false
		ch.dirty_since = -1
		_rebuild(pick, ch)
		# Its new plates' glyphs are drawn now: their anchors shown.
		for sl in range(pick * CHUNK, mini((pick + 1) * CHUNK, _by_slot.size())):
			var p: Plate = _by_slot[sl]
			if p != null and p.pending:
				p.pending = false
				_write_anchor(p)
	if _anchor_dirty and _anchor_rows > 0:
		_anchor_dirty = false
		var img := Image.create_from_data(ANCHOR_W, _anchor_rows, false, Image.FORMAT_RGBAF, _anchors.to_byte_array())
		if _anchor_tex == null or _anchor_tex.get_height() != _anchor_rows:
			_anchor_tex = ImageTexture.create_from_image(img)
			for k in _materials:
				_anchor_bind(_materials[k])
		else:
			_anchor_tex.update(img)
		stats["uploads"] = int(stats["uploads"]) + 1

const REBUILD_SETTLE := 3
const REBUILD_WAIT := 20

## Round 762 (QA, tests): every dirty chunk rebuilt now (flush's pacing aside).
func flush_all(player: Vector3) -> void:
	for ci in range(_chunks.size()):
		var ch: Chunk = _chunks[ci]
		if ch.dirty:
			ch.touched = -REBUILD_WAIT
			ch.dirty_since = -REBUILD_WAIT
	for i in range(_chunks.size() + 1):
		flush(player)

func set_range(r: float) -> void:
	range = r
	for k in _materials:
		RenderingServer.material_set_param(_materials[k], "plate_range", r)

func _anchor_bind(mat: RID) -> void:
	if _anchor_tex != null:
		RenderingServer.material_set_param(mat, "plate_anchors", _anchor_tex.get_rid())
	RenderingServer.material_set_param(mat, "plate_player", _player)
	RenderingServer.material_set_param(mat, "plate_range", range)

func _rebuild(ci: int, ch: Chunk) -> void:
	stats["rebuilds"] = int(stats["rebuilds"]) + 1
	# Each key's plates' parts, then each key's arrays grown in local
	# variables (a packed array is a value: grown through an Array element it
	# would be copied on every append).
	var lists := {}
	for s in range(ci * CHUNK, mini((ci + 1) * CHUNK, _by_slot.size())):
		var p: Plate = _by_slot[s]
		if p == null:
			continue
		for key in p.parts:
			if not lists.has(key):
				lists[key] = []
			(lists[key] as Array).append(p.parts[key])
	var by_key := {}
	for key in lists:
		by_key[key] = concat(lists[key])
	if not ch.mesh.is_valid():
		ch.mesh = RenderingServer.mesh_create()
	else:
		RenderingServer.mesh_clear(ch.mesh)
	var keys := by_key.keys()
	keys.sort()
	var surfaces := 0
	for key in keys:
		var a: Array = by_key[key]
		var n := (a[0] as PackedVector3Array).size()
		if n == 0:
			continue
		# No normals or tangents: the material is unshaded (Label3D writes a
		# constant (0, 0, 1) normal and (1, 0, 0, 1) tangent, which an unshaded
		# shader does not read).
		var arrays := []
		arrays.resize(RenderingServer.ARRAY_MAX)
		arrays[RenderingServer.ARRAY_VERTEX] = a[0]
		arrays[RenderingServer.ARRAY_COLOR] = a[2]
		arrays[RenderingServer.ARRAY_TEX_UV] = a[1]
		arrays[RenderingServer.ARRAY_TEX_UV2] = a[3]
		RenderingServer.mesh_add_surface_from_arrays(ch.mesh, RenderingServer.PRIMITIVE_TRIANGLES, arrays)
		RenderingServer.mesh_surface_set_material(ch.mesh, surfaces, _materials[key])
		surfaces += 1
	if not ch.inst.is_valid():
		ch.inst = RenderingServer.instance_create2(ch.mesh, scenario)
		RenderingServer.instance_set_layer_mask(ch.inst, layers)
		RenderingServer.instance_geometry_set_cast_shadows_setting(ch.inst, RenderingServer.SHADOW_CASTING_SETTING_OFF)
		RenderingServer.instance_set_custom_aabb(ch.inst, AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6)))
	ch.keys = keys
