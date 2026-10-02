extends RefCounted
class_name GatePickProbe

## Measures a town gate's click against what is drawn (round 690).
##
## The user (2026-10-02): "the teleport hit zone was off to the right and not
## on the actual stone or around so I couldn't easily click it". A picture
## cannot settle where a click lands, so this fires the rays the client's own
## pickers fire and counts them:
##
## - `aabbs` -- the gate's drawn box (the union of its MeshInstance3D boxes)
##   against the box of the bodies a click can take it through (its
##   StaticBody3D shapes, which _tag_gate puts on the talk layer), both in
##   world space;
## - `sweep` -- from an eye, a grid of rays across the drawn box: a ray is
##   DRAWN when the first visible geometry it meets (the default layer: the
##   terrain, every placed object, the gate itself) is the gate's own, and
##   TALK when the talk ray -- World3D._try_talk_to_npc's, the talk layer
##   only, walking up to the `npc_name` tag -- resolves to the gate. A drawn
##   ray that does not talk names what took it instead (`blockers`); a talk
##   ray that is not drawn is a click on empty screen that opens the gate.
##
## The talk ray is passed in (`talk`), so the probe measures whichever picker
## the client runs. All static; nothing here changes the world.

## The union of every MeshInstance3D box under `node` (itself included), in
## world space. An empty AABB when it draws nothing.
static func visual_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var meshes: Array = node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		meshes.append(node)
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var box := mi.global_transform * mi.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out

## The union of the faces of every concave shape on a StaticBody3D under
## `node` whose layer has any bit of `layer_mask`, in world space.
static func body_aabb(node: Node3D, layer_mask: int) -> AABB:
	var out := AABB()
	var first := true
	var bodies: Array = node.find_children("*", "StaticBody3D", true, false)
	if node is StaticBody3D:
		bodies.append(node)
	for b in bodies:
		var body := b as StaticBody3D
		if body.collision_layer & layer_mask == 0:
			continue
		for c in body.get_children():
			var cs := c as CollisionShape3D
			if cs == null or cs.disabled:
				continue
			var xf := cs.global_transform
			var points := PackedVector3Array()
			if cs.shape is ConcavePolygonShape3D:
				points = (cs.shape as ConcavePolygonShape3D).get_faces()
			elif cs.shape is BoxShape3D:
				var half := (cs.shape as BoxShape3D).size * 0.5
				for i in 8:
					points.append(Vector3(half.x if i & 1 else -half.x, half.y if i & 2 else -half.y, half.z if i & 4 else -half.z))
			for v in points:
				var p: Vector3 = xf * v
				if first:
					out = AABB(p, Vector3.ZERO)
					first = false
				else:
					out = out.expand(p)
	return out

## Whether `collider` is `node` or under it.
static func is_under(collider: Object, node: Node) -> bool:
	var n := collider as Node
	while n != null:
		if n == node:
			return true
		n = n.get_parent()
	return false

## Fires a `steps` x `steps` grid of rays from `eye` across `box` (the plane
## through its centre facing the eye, 1.5 times its extent so the rays around
## it count too) and classifies each. A ray is drawn when the first thing on
## `drawn_mask` (the visible geometry's layer) it meets is under `node`, the
## drawn gate; it talks when `talk` -- a Callable(from: Vector3, to: Vector3)
## -> Dictionary, {"node": the tagged node or null, "collider": what the ray
## hit first or null} -- resolves to `talk_node`. Returns the counts, the two
## centroids (world) and the blockers by name.
static func sweep(space: PhysicsDirectSpaceState3D, node: Node3D, talk_node: Node, eye: Vector3, box: AABB,
		steps: int, drawn_mask: int, talk: Callable, exclude: Array = []) -> Dictionary:
	var centre := box.get_center()
	var forward := (centre - eye).normalized()
	var right := forward.cross(Vector3.UP).normalized()
	if right.length() < 0.5:
		right = Vector3.RIGHT
	var up := right.cross(forward).normalized()
	var half := maxf(box.size.length() * 0.75, 1.0)
	var out := {"drawn": 0, "talk": 0, "both": 0, "drawn_only": 0, "talk_only": 0,
		"drawn_sum": Vector3.ZERO, "talk_sum": Vector3.ZERO, "blockers": {},
		"right": right, "up": up}
	for i in steps:
		for j in steps:
			var u: float = (float(i) + 0.5) / float(steps) * 2.0 - 1.0
			var v: float = (float(j) + 0.5) / float(steps) * 2.0 - 1.0
			var target := centre + right * (u * half) + up * (v * half)
			var to := eye + (target - eye).normalized() * ((target - eye).length() + 4000.0)
			var q := PhysicsRayQueryParameters3D.create(eye, to)
			q.collision_mask = drawn_mask
			q.exclude = exclude
			var hit := space.intersect_ray(q)
			var drawn := not hit.is_empty() and is_under(hit["collider"], node)
			var t: Dictionary = talk.call(eye, to)
			var talks: bool = t.get("node") == talk_node
			if drawn:
				out["drawn"] += 1
				out["drawn_sum"] += target
			if talks:
				out["talk"] += 1
				out["talk_sum"] += target
			if drawn and talks:
				out["both"] += 1
			elif drawn:
				out["drawn_only"] += 1
				var blocker = t.get("collider")
				var key := "nothing" if blocker == null else String((blocker as Node).name)
				out["blockers"][key] = int(out["blockers"].get(key, 0)) + 1
			elif talks:
				out["talk_only"] += 1
	out["drawn_centroid"] = out["drawn_sum"] / maxf(1.0, float(out["drawn"]))
	out["talk_centroid"] = out["talk_sum"] / maxf(1.0, float(out["talk"]))
	return out

## One line of a sweep, the centroid offset in the eye's own right/up axes
## (positive right is the viewer's right).
static func describe(label: String, s: Dictionary) -> String:
	var d: Vector3 = s["talk_centroid"] - s["drawn_centroid"]
	var r: float = d.dot(s["right"])
	var u: float = d.dot(s["up"])
	return "%s: drawn %d, talk %d, both %d, drawn-not-talk %d %s, talk-not-drawn %d; talk centroid - drawn centroid = %.1f right, %.1f up" % [
		label, s["drawn"], s["talk"], s["both"], s["drawn_only"], str(s["blockers"]), s["talk_only"], r, u]
