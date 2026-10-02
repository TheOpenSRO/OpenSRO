extends RefCounted
class_name CharSelectQa

## QA measurements for the select screen (round 688, OURS, QA only -- every
## hook is off unless its environment variable is set):
##
## - SRREVAMP_QA_SELECT_RACE=1: once the list intro ends, Create is pressed,
##   so a run reaches the race table without input.
## - SRREVAMP_QA_LIZARD_PROBE=<seconds>: from the lizard's arrival, one line a
##   frame about it (`lizard_sample`), then the client quits.
## - SRREVAMP_QA_SELECT_LUMA=1: when the list is up and the models have faded
##   in, the frame's mean luminance over the 3D band and over the characters
##   (`luma_report`), with the light the backdrop was given.
##
## Nothing here changes what a player sees.

## The lizard as the renderer would see it this frame:
##   - `vis`: every mesh under the lizard visible in the tree;
##   - `cpu`: its skinned vertices (each MeshInstance3D skinned on the CPU
##     exactly as Godot skins it -- the Skin's bind poses times the bones'
##     global poses, weighted), as the screen rectangle they cover, clipped to
##     the viewport, and the share of vertices inside the camera's frustum;
##   - `cull`: the box Godot 4.2.2's GLES3 MeshStorage::mesh_get_aabb gives
##     the instance (each bone's `bone_aabbs` entry through that bone's skin
##     matrix, merged; READ, drivers/gles3/storage/mesh_storage.cpp 610-727),
##     and whether the frustum test keeps it;
##   - `root`: the skeleton's first bone in world space (root motion).
static func lizard_sample(lizard: Node3D, cam: Camera3D, viewport: Vector2) -> Dictionary:
	var out := {"meshes": 0, "visible": 0, "verts": 0, "inside": 0, "rect": Rect2(), "cull_kept": 0,
		"cull_meshes": 0, "root": Vector3.ZERO}
	if lizard == null or cam == null:
		return out
	var planes := cam.get_frustum()
	var screen := Rect2(Vector2.ZERO, viewport)
	var have_rect := false
	var rect := Rect2()
	var stack: Array[Node] = [lizard]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is Skeleton3D and out["root"] == Vector3.ZERO and (n as Skeleton3D).get_bone_count() > 0:
			var sk := n as Skeleton3D
			out["root"] = sk.global_transform * sk.get_bone_global_pose(0).origin
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		out["meshes"] += 1
		if mi.is_visible_in_tree():
			out["visible"] += 1
		var points := skinned_points(mi)
		for p in points:
			out["verts"] += 1
			if _inside(planes, p):
				out["inside"] += 1
			if cam.is_position_behind(p):
				continue
			var s := cam.unproject_position(p)
			if not screen.has_point(s):
				continue
			if have_rect:
				rect = rect.expand(s)
			else:
				rect = Rect2(s, Vector2.ZERO)
				have_rect = true
		var box := cull_aabb(mi)
		if box.size != Vector3.ZERO or box.position != Vector3.ZERO:
			out["cull_meshes"] += 1
			if not _culled(planes, mi.global_transform * box):
				out["cull_kept"] += 1
	out["rect"] = rect
	return out

## A MeshInstance3D's vertices in world space, skinned as Godot skins them
## (the instance's own transform after the skin's matrices).
static func skinned_points(mi: MeshInstance3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var mesh := mi.mesh
	var skel := mi.get_node_or_null(mi.skeleton) as Skeleton3D if mi.skin != null else null
	var mats: Array[Transform3D] = []
	if skel != null:
		for i in range(mi.skin.get_bind_count()):
			var b := mi.skin.get_bind_bone(i)
			if b < 0:
				b = skel.find_bone(mi.skin.get_bind_name(i))
			mats.append(skel.get_bone_global_pose(b) * mi.skin.get_bind_pose(i) if b >= 0 else Transform3D.IDENTITY)
	for s in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones = arrays[Mesh.ARRAY_BONES]
		var weights = arrays[Mesh.ARRAY_WEIGHTS]
		var per := 0
		if skel != null and bones is PackedInt32Array and weights is PackedFloat32Array and verts.size() > 0:
			per = (bones as PackedInt32Array).size() / verts.size()
		for v in range(verts.size()):
			var p := verts[v]
			if per > 0:
				var acc := Vector3.ZERO
				var wsum := 0.0
				for k in range(per):
					var w: float = weights[v * per + k]
					var bi: int = bones[v * per + k]
					if w <= 0.0 or bi < 0 or bi >= mats.size():
						continue
					acc += (mats[bi] * p) * w
					wsum += w
				if wsum > 0.0:
					p = acc / wsum
			out.append(mi.global_transform * p)
	return out

## READ (Godot 4.2.2, GLES3 MeshStorage::mesh_get_aabb): the box the scene
## cull uses for a skinned instance -- per surface, every used bone's
## `bone_aabbs` entry through that bone's skin matrix, merged; a surface
## with none falls back to its own box. In the mesh's space.
static func cull_aabb(mi: MeshInstance3D) -> AABB:
	var mesh := mi.mesh
	var skel := mi.get_node_or_null(mi.skeleton) as Skeleton3D if mi.skin != null else null
	if skel == null:
		return mesh.get_aabb()
	var total := AABB()
	for s in range(mesh.get_surface_count()):
		var data := RenderingServer.mesh_get_surface(mesh.get_rid(), s)
		var surface_box: AABB = data.get("aabb", AABB())
		var boxes: Array = data.get("bone_aabbs", [])
		var laabb := AABB()
		var found := false
		for j in range(mini(boxes.size(), mi.skin.get_bind_count())):
			var bb: AABB = boxes[j]
			if bb.size == Vector3(-1, -1, -1):
				continue
			var b := mi.skin.get_bind_bone(j)
			if b < 0:
				b = skel.find_bone(mi.skin.get_bind_name(j))
			var m := skel.get_bone_global_pose(b) * mi.skin.get_bind_pose(j) if b >= 0 else Transform3D.IDENTITY
			var t := m * bb
			laabb = t if not found else laabb.merge(t)
			found = true
		if laabb.size == Vector3.ZERO:
			laabb = surface_box
		total = laabb if s == 0 else total.merge(laabb)
	return total

static func _inside(planes: Array[Plane], p: Vector3) -> bool:
	for pl in planes:
		if pl.is_point_over(p):
			return false
	return true

## The scene cull's frustum test: a box is dropped when all its corners lie
## outside one plane.
static func _culled(planes: Array[Plane], box: AABB) -> bool:
	for pl in planes:
		var all_out := true
		for i in range(8):
			if not pl.is_point_over(box.get_endpoint(i)):
				all_out = false
				break
		if all_out:
			return true
	return false

## Mean Rec. 709 luma (0..255, of the sRGB values as drawn) of `img` inside
## `rect`, skipping the pixels inside any of `exclude`. -1 when none counted.
static func mean_luma(img: Image, rect: Rect2i, exclude: Array = [], step: int = 2) -> float:
	var sum := 0.0
	var count := 0
	var r := rect.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	for y in range(r.position.y, r.end.y, step):
		for x in range(r.position.x, r.end.x, step):
			var skip := false
			for e in exclude:
				if (e as Rect2i).has_point(Vector2i(x, y)):
					skip = true
					break
			if skip:
				continue
			var c := img.get_pixel(x, y)
			sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			count += 1
	return sum / count * 255.0 if count > 0 else -1.0

## A node's box (local `box`) on screen, or an empty rect.
static func screen_rect(cam: Camera3D, xf: Transform3D, box: AABB) -> Rect2i:
	var have := false
	var r := Rect2()
	for i in range(8):
		var p := xf * box.get_endpoint(i)
		if cam.is_position_behind(p):
			continue
		var s := cam.unproject_position(p)
		if have:
			r = r.expand(s)
		else:
			r = Rect2(s, Vector2.ZERO)
			have = true
	return Rect2i(r.position.floor(), r.size.ceil()) if have else Rect2i()

## Every shown button under `root` with its words: where the button is and
## where its text is drawn, in canvas units (round 688, the "Name Check"
## overflow). The text's box is the string's own advance width and the
## font's height, placed as its Label (a TextureButton's "Text" child) or
## its Button aligns it. `over` is how far the text pokes out of the button
## on each side (left, top, right, bottom; 0 = inside), `off` its centre's
## distance from the button's centre.
static func button_report(root: Node, hidden_too: bool = false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var b := n as BaseButton
		if b == null or not (hidden_too or b.is_visible_in_tree()):
			continue
		var r := text_rect(b)
		if r.size == Vector2.ZERO:
			continue
		var br := b.get_global_rect()
		out.append({"name": String(b.name) + ("" if b.is_visible_in_tree() else " (hidden)"), "text": button_text(b), "button": br, "text_rect": r,
			"over": Rect2(maxf(0.0, br.position.x - r.position.x), maxf(0.0, br.position.y - r.position.y),
				maxf(0.0, r.end.x - br.end.x), maxf(0.0, r.end.y - br.end.y)),
			"off": r.get_center() - br.get_center()})
	return out

static func button_text(b: BaseButton) -> String:
	if b is Button:
		return (b as Button).text
	var l := b.get_node_or_null("Text") as Label
	return l.text if l != null else ""

## Where a button's words are drawn (global canvas units), or an empty rect.
static func text_rect(b: BaseButton) -> Rect2:
	var text := button_text(b)
	if text == "":
		return Rect2()
	var holder: Control = b
	var halign := HORIZONTAL_ALIGNMENT_CENTER
	var valign := VERTICAL_ALIGNMENT_CENTER
	if not (b is Button):
		var l := b.get_node("Text") as Label
		holder = l
		halign = l.horizontal_alignment
		valign = l.vertical_alignment
	var font := holder.get_theme_font(&"font")
	var fs := holder.get_theme_font_size(&"font_size")
	if font == null:
		return Rect2()
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var h := font.get_height(fs)
	var hr := holder.get_global_rect()
	var x := hr.position.x + (hr.size.x - w) * (0.0 if halign == HORIZONTAL_ALIGNMENT_LEFT else (1.0 if halign == HORIZONTAL_ALIGNMENT_RIGHT else 0.5))
	var y := hr.position.y + (hr.size.y - h) * (0.0 if valign == VERTICAL_ALIGNMENT_TOP else (1.0 if valign == VERTICAL_ALIGNMENT_BOTTOM else 0.5))
	return Rect2(x, y, w, h)

static func button_line(d: Dictionary) -> String:
	var br: Rect2 = d["button"]
	var tr: Rect2 = d["text_rect"]
	var o: Rect2 = d["over"]
	var off: Vector2 = d["off"]
	return "%s '%s' button (%.1f, %.1f, %.1f x %.1f) text (%.1f, %.1f, %.1f x %.1f) over L%.1f T%.1f R%.1f B%.1f centre off (%.1f, %.1f)" % [
		d["name"], d["text"], br.position.x, br.position.y, br.size.x, br.size.y, tr.position.x, tr.position.y,
		tr.size.x, tr.size.y, o.position.x, o.position.y, o.size.x, o.size.y, off.x, off.y]
