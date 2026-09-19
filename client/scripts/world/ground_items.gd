extends Node3D
class_name GroundItems

## The items lying on the ground in the player's zone, as the server
## reports them (GroundItemsNet): one node per dropped stack, drawn with the
## item's own drop model out of Data.pk2 (itemdata's drop `.bsr`, the same
## art the original shows on the ground), a name plate, and a click collider
## on GROUND_ITEM_COLLISION_LAYER so a left click can pick it out. Nothing
## here decides anything: what lies where, who may take it and whether a pick
## succeeded are all the server's answers; this only draws them.

## Layer 7: ground items only. Layers 1/4 are terrain, 5 navmesh walls and
## NPCs, 6 monsters (World3D's constants).
const GROUND_ITEM_COLLISION_LAYER := 0b1000000

## A drop whose model could not be loaded is still drawn, as a small plain
## box, so a missing model reads as "an item with no art" and not as "no
## drop" -- the same call ObjectLoader makes for scenery. Own design, and
## visibly so.
const FALLBACK_BOX_SIZE := 2.0

var _archive: Pk2Reader
## item id -> the drop model path from the item table (may be "").
var _drop_models: Dictionary = {}
## Resolves an item id to its display name: (int) -> String.
var _name_for: Callable
## Builds a name plate the way World3D does for monsters: (text, above) -> Label3D.
var _plate_for: Callable
## Snaps a position to the terrain: (Vector3) -> float height.
var _height_at: Callable
## ground item id -> its node.
var _nodes: Dictionary = {}
## ground item id -> its latest snapshot.
var _items: Dictionary = {}

func setup(archive: Pk2Reader, drop_models: Dictionary, name_for: Callable, plate_for: Callable, height_at: Callable) -> void:
	_archive = archive
	_drop_models = drop_models
	_name_for = name_for
	_plate_for = plate_for
	_height_at = height_at

func count() -> int:
	return _nodes.size()

func has(ground_id: int) -> bool:
	return _nodes.has(ground_id)

func snapshot(ground_id: int) -> GroundItemsNet.Snapshot:
	return _items.get(ground_id)

func position_of(ground_id: int) -> Vector3:
	var node: Node3D = _nodes.get(ground_id)
	return node.global_position if node != null else Vector3.INF

## The id of the item nearest to pos, or -1.
func nearest_id(pos: Vector3) -> int:
	var best := -1
	var best_d := INF
	for id in _nodes:
		var d: float = (_nodes[id] as Node3D).global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = id
	return best

## Replaces everything with the server's list (what a zone entry sends).
func apply_list(items: Array) -> void:
	var seen := {}
	for s in items:
		var snap := s as GroundItemsNet.Snapshot
		seen[snap.id] = true
		spawn(snap)
	for id in _nodes.keys():
		if not seen.has(id):
			remove(id)

func spawn(snap: GroundItemsNet.Snapshot) -> void:
	_items[snap.id] = snap
	var pos := Vector3(snap.x, snap.y, snap.z)
	if _height_at.is_valid():
		pos.y = _height_at.call(pos)
	if _nodes.has(snap.id):
		(_nodes[snap.id] as Node3D).position = pos
		return
	var body := Node3D.new()
	body.name = "GroundItem_%d" % snap.id
	body.position = pos
	body.set_meta("ground_item_id", snap.id)

	var model: Node3D = null
	var model_path: String = _drop_models.get(snap.item_id, "")
	if _archive != null and model_path != "":
		# itemdata's drop paths are relative to `res\` (`item\etc\drop_ch_bag.bsr`
		# is `Res\Item\Etc\drop_ch_bag.bsr` in the archive -- measured with
		# pk2list, round 211's log), so try that first: the loader prints a
		# "not found" for every miss, and trying the bare path first logged one
		# for every drop that then drew fine.
		if not model_path.to_lower().begins_with("res\\"):
			model = ObjectLoader.load_object(_archive, "res\\" + model_path)
		if model == null:
			model = ObjectLoader.load_object(_archive, model_path)
	var top := FALLBACK_BOX_SIZE
	if model != null:
		body.add_child(model)
		top = maxf(_top_of(model), 0.5)
	else:
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3.ONE * FALLBACK_BOX_SIZE
		mesh.mesh = box
		mesh.position.y = FALLBACK_BOX_SIZE * 0.5
		body.add_child(mesh)
		print("GroundItems: item %d has no drop model%s -- drawn as a box" % [
			snap.item_id, "" if model_path == "" else " (%s failed to load)" % model_path])

	var text := label_text(snap)
	if _plate_for.is_valid() and text != "":
		var label: Label3D = _plate_for.call(text, top)
		label.name = "Label"
		body.add_child(label)

	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(top, 2.0), maxf(top, 2.0), maxf(top, 2.0))
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = shape.size.y * 0.5
	var sb := StaticBody3D.new()
	sb.name = "ClickBody"
	sb.collision_layer = GROUND_ITEM_COLLISION_LAYER
	sb.collision_mask = 0
	sb.add_child(collider)
	body.add_child(sb)

	add_child(body)
	_nodes[snap.id] = body

func remove(ground_id: int) -> void:
	var node: Node3D = _nodes.get(ground_id)
	if node != null:
		node.queue_free()
	_nodes.erase(ground_id)
	_items.erase(ground_id)

## The item's 30 s window has passed: anyone may pick it now. Recorded on
## the snapshot; nothing visual is claimed for it (whether the original
## recolours a freed drop's name has not been read).
func release_owner(ground_id: int) -> void:
	var snap: GroundItemsNet.Snapshot = _items.get(ground_id)
	if snap != null:
		snap.owner_id = 0

## "57 Gold", "HP Recovery Herb x2", or the bare name. A plate shows the
## client's own name for the item or nothing at all -- never an id, and never
## the archive's mangled column-3 text (the resolver decides that; see
## ItemTableReader.Item.display_name). With no name the plate is left empty,
## so a nameless stack still shows its count when there is one.
func label_text(snap: GroundItemsNet.Snapshot) -> String:
	if snap.gold:
		return "%d Gold" % snap.quantity
	var text: String = str(_name_for.call(snap.item_id)) if _name_for.is_valid() else ""
	if snap.quantity > 1:
		text = ("%s x%d" % [text, snap.quantity]) if text != "" else ("x%d" % snap.quantity)
	return text

## Highest point of a loaded model's meshes, in the model's own space.
static func _top_of(model: Node3D) -> float:
	var top := 0.0
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D and (current as MeshInstance3D).mesh != null:
			var mi := current as MeshInstance3D
			var box: AABB = mi.transform * mi.mesh.get_aabb()
			top = maxf(top, box.end.y)
		for child in current.get_children():
			stack.append(child)
	return top
