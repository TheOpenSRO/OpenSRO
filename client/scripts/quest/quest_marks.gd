extends RefCounted
class_name QuestMarks

## The quest marks over NPCs and the tracked quest's minimap signs (round
## 785).
##
## **Over an NPC (READ, GlobalDataManager::FUN_009c75e0 and the system-effect
## table at 0xec73f8):** 0x30D6's mark type picks the effect drawn over the
## object -- 0, 1 and anything else SYSTEM_EXCLAMATION_START, 2
## SYSTEM_EXCLAMATION_GOING, 3 SYSTEM_EXCLAMATION_END, 4 SYSTEM_QUEST_MARK2.
## The files (MEASURED in Data.pk2): `Res\etc\ex_mark_start.bsr`,
## `ex_mark_going.bsr`, `ex_mark_end.bsr`, `ex_mark_start_r.bsr` (which
## effect row names which file is INFERRED from the names). The mark stays
## with the object id, so an NPC spawned later carries a mark that arrived
## before it (FUN_009d17e0).
## OURS: the .bsr is drawn as a still object (ObjectLoader.load_object), not
## played with its ex_mark_stand animation, and it stands a little above the
## name plate (the effect's own attachment point is not read).
##
## **On the minimap (READ, CIFMinimap::vslot_013):** only the tracked quest's
## NPC list (0x30D5 flags & 0x40) is drawn; each NPC's spot comes from the
## client's own npcpos table; within 47.0 map pixels `mm_sign_questnpc.ddj`,
## beyond it `mm_sign_questarrow.ddj` on the rim, turned toward the NPC
## (PartyMapMarks' geometry, the same 47.0).

const MARK_NODE := "QuestMark"
const NPC_SIGN_DDJ := "interface\\minimap\\mm_sign_questnpc.ddj"
const ARROW_DDJ := "interface\\minimap\\mm_sign_questarrow.ddj"
## OURS: the mark's height over the name plate, as a fraction of it.
const ABOVE_PLATE := 1.12

static func mark_path(mark_type: int) -> String:
	match mark_type:
		QuestNet.MARK_GOING:
			return "res\\etc\\ex_mark_going.bsr"
		QuestNet.MARK_END:
			return "res\\etc\\ex_mark_end.bsr"
		4:
			return "res\\etc\\ex_mark_start_r.bsr"
	return "res\\etc\\ex_mark_start.bsr"

## Puts (or removes) the mark of every holder in `holders` (uid -> Node3D)
## to match `marks` (object id -> QuestNet.Mark). `models` caches one loaded
## model per path; `load` makes a model from a path (null when it cannot).
static func apply(holders: Dictionary, marks: Dictionary, models: Dictionary, loader: Callable) -> int:
	var shown := 0
	for uid in holders:
		var holder = holders[uid]
		if holder == null or not is_instance_valid(holder):
			continue
		if apply_one(holder as Node3D, marks.get(int(uid)) as QuestNet.Mark, models, loader):
			shown += 1
	return shown

static func apply_one(holder: Node3D, mark: QuestNet.Mark, models: Dictionary, loader: Callable) -> bool:
	var existing := holder.get_node_or_null(MARK_NODE) as Node3D
	var want := mark_path(mark.mark_type) if mark != null else ""
	if existing != null and str(existing.get_meta("mark_path", "")) == want:
		return want != ""
	if existing != null:
		holder.remove_child(existing)
		existing.queue_free()
	if want == "":
		return false
	if not models.has(want):
		models[want] = loader.call(want)
	var model = models[want]
	var node: Node3D
	if model is Node3D:
		node = (model as Node3D).duplicate() as Node3D
	else:
		node = Node3D.new()
	node.name = MARK_NODE
	node.set_meta("mark_path", want)
	var plate := holder.get_node_or_null("Name") as Node3D
	node.position = Vector3(0.0, plate.position.y * ABOVE_PLATE if plate != null else 20.0, 0.0)
	holder.add_child(node)
	return true

## npcpos rows by NPC id: the first row's [region word, local position]
## (region word (x << 8) | y, as the spawn records carry it).
static func index_positions(spawns: Array) -> Dictionary:
	var out := {}
	for s in spawns:
		var sp := s as NpcTableReader.Spawn
		if sp == null or out.has(sp.npc_id):
			continue
		out[sp.npc_id] = [(sp.region_x << 8) | sp.region_y, sp.local_position]
	return out

## The tracked quest's NPCs in the player's region-local frame.
static func targets_local(npc_ids: PackedInt64Array, here_region: Vector2i, index: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for id in npc_ids:
		var row = index.get(int(id))
		if row == null:
			continue
		var p: Vector3 = row[1]
		out.append(PartyMapMarks.record_local(here_region, int(row[0]), p.x, p.z))
	return out
