extends RefCounted
class_name StructureWorld

## The runtime structures in the world (round 869, lane C1): the Dimension
## hole's gate (CITeleportGate) and the trigger doors (CIEventRuntimeObj),
## built from NetClient's structure records (StructureSpawnNet) under their
## region's terrain group, as World3D builds its NPCs. READ addresses are
## sro_client.exe's.
##
## THE GATE (CITeleportGate::vslot_025, c:0x9e9eb0): its model is its
## teleportbuilding row's .bsr (column 52; MEASURED for 19556 INS_QUEST_TELEPORT
## in our archive: Bldg\North Africa\Alexandria\alex_raid_portal.bsr) with the
## model's ambient effects (as the town gates', AmbientParticles); its pick box
## is the row's bounding box, min (-r, -h, -r) max (r, h, r) with r = ref
## +0x118 and h = +0x114 (TB_BC_RADIUS / TB_BC_HEIGHT, as _gate_pick_node);
## and a gate this player may not use builds nothing (gate_visible). The
## talk lines it keeps for its window (+0x2e4 party master, +0x31c level,
## +0x338 grade; GameWorldNet.gate_lines) come from the hole (+0x25c).
##
## THE DOOR (CIEventRuntimeObj::FUN_00535750, c:0x535750): at state 0 the model
## is built from the event zone (+0x280) -> eventzonedata's object codename
## (RefData_eventzonedata::FUN_00750040, +0x50) -> that object's .bsr
## (characterdata, CCharacterData::FUN_00971210 +0x124), placed at the record's
## position and angle (FUN_009c4260(+0x10c)); at state 1 it is removed
## (FUN_009c4160(2)). 0x351E sets the state (c:0x89a7b0 -> FUN_005359c0).
## MEASURED: the 37 POS_STRUCTURE_GOD_* zones (ids 251..) name the
## STRUCTURE_GOD_* objects of characterdata_37000 (togui_door01/02.bsr,
## flame_lroom_door.bsr, flame_event_block/break.bsr, wreck_event_door/
## block.bsr).

const EVENTZONE_TABLE := "server_dep\\silkroad\\textdata\\eventzonedata.txt"
const GROUP_CONFIG_TABLE := "server_dep\\silkroad\\textdata\\groupworld_config_forclient.txt"
## A gate holder's meta: its uid (it is talked to like a server NPC).
const META_STRUCTURE := "structure_uid"
const META_GATE := "structure_gate"

## World3D (untyped: World3D's own class would make a cycle).
var w: Node
## uid -> StructureSpawnNet.Record, every structure in view.
var records: Dictionary = {}
## uid -> the holder built for it (a gate drawn, a door at state 0).
var holders: Dictionary = {}
## teleportbuilding rows by RefObjID: {"code", "name_strid", "model", "r",
## "h", "kind"}, read once.
var _buildings: Dictionary = {}
var _buildings_read := false
## eventzonedata: zone id -> object codename.
var _zones: Dictionary = {}
var _zones_read := false
## characterdata codename -> RefObjID (from World3D's _npc_codes).
var _ids_by_code: Dictionary = {}
var _group_config: Dictionary = {}
var _group_config_read := false

func _init(world: Node) -> void:
	w = world

# --- Tables --------------------------------------------------------------------

func _read_media(path: String) -> PackedByteArray:
	var archive: Pk2Reader = w._open_media_pk2_if_set()
	if archive == null:
		return PackedByteArray()
	var e := ObjectLoader.find_file(archive, path)
	return archive.read_file(e) if e != null else PackedByteArray()

## RefObjID -> kind for every teleportbuilding row of TypeID 4/1 or 4/2 (the
## spawn reader's class test).
func structure_kinds() -> Dictionary:
	_read_buildings()
	var out := {}
	for id in _buildings:
		var k := int(_buildings[id]["kind"])
		if k != StructureSpawnNet.KIND_NONE:
			out[id] = k
	return out

func _read_buildings() -> void:
	if _buildings_read:
		return
	_buildings_read = true
	var bytes := _read_media(TeleportReader.BUILDING_TABLE)
	for line in TextDecode.utf16(bytes).split("\n"):
		var cols := line.strip_edges(false, true).split("\t")
		if cols.size() <= 52 or not cols[1].strip_edges().is_valid_int():
			continue
		var t1 := int(cols[9].strip_edges()) if cols[9].strip_edges().is_valid_int() else 0
		var t2 := int(cols[10].strip_edges()) if cols[10].strip_edges().is_valid_int() else 0
		var model := cols[52].strip_edges()
		_buildings[int(cols[1].strip_edges())] = {"code": cols[2].strip_edges(), "name_strid": cols[5].strip_edges(),
			"model": "" if model == "xxx" else model, "kind": StructureSpawnNet.kind_of_type(t1, t2),
			"h": float(cols[TeleportReader.TB_BC_HEIGHT].strip_edges()), "r": float(cols[TeleportReader.TB_BC_RADIUS].strip_edges())}
	print("StructureWorld: %d teleportbuilding row(s), %d structure class(es)" % [_buildings.size(), structure_kinds_count()])

func structure_kinds_count() -> int:
	var n := 0
	for id in _buildings:
		if int(_buildings[id]["kind"]) != StructureSpawnNet.KIND_NONE:
			n += 1
	return n

func building(ref_id: int) -> Dictionary:
	_read_buildings()
	return _buildings.get(ref_id, {})

## eventzonedata.txt: column 1 the id, column 3 the kind (OBJECT), column 9
## the object's codename (MEASURED rows: "1 251 POS_STRUCTURE_GOD_BIG_GATE_
## FLAME_1 OBJECT 4 2 0 0 0 STRUCTURE_GOD_BIG_GATE_FLAME_1 ...").
func zone_object(zone_id: int) -> String:
	if not _zones_read:
		_zones_read = true
		for line in TextDecode.utf16(_read_media(EVENTZONE_TABLE)).split("\n"):
			var cols := line.strip_edges(false, true).split("\t")
			if cols.size() > 9 and cols[1].strip_edges().is_valid_int() and cols[3].strip_edges() == "OBJECT":
				_zones[int(cols[1].strip_edges())] = cols[9].strip_edges()
	return String(_zones.get(zone_id, ""))

## The .bsr of characterdata row `code` ("" when the table lacks it).
func model_of_code(code: String) -> String:
	if _ids_by_code.is_empty():
		var codes: Dictionary = w._npc_codes
		for id in codes:
			_ids_by_code[String(codes[id]).to_upper()] = id
	var id = _ids_by_code.get(code.to_upper())
	if id == null:
		return ""
	return String((w._npc_models as Dictionary).get(id, ""))

## groupworld_config_forclient.txt (GameWorldNet.parse_group_config).
func group_config(group: int) -> Dictionary:
	if not _group_config_read:
		_group_config_read = true
		_group_config = GameWorldNet.parse_group_config(_read_media(GROUP_CONFIG_TABLE))
	return _group_config.get(group, {})

# --- Records -----------------------------------------------------------------

func on_spawned(rec: StructureSpawnNet.Record) -> void:
	if rec == null:
		return
	remove_holder(rec.uid)
	records[rec.uid] = rec
	print("StructureWorld: %s uid=%d ref=%d region %d/%d at %.1f,%.1f,%.1f angle %d state %d access %d owner '%s'/%d hole %d zone %d" % [
		"gate" if rec.kind == StructureSpawnNet.KIND_GATE else "event object", rec.uid, rec.ref_id, rec.region_x, rec.region_y,
		rec.local_position.x, rec.local_position.y, rec.local_position.z, rec.angle, rec.state, rec.access, rec.owner_name,
		rec.owner_id, rec.hole_ref, rec.zone_id])
	place(rec)

func on_despawned(uid: int) -> void:
	remove_holder(uid)
	if records.erase(uid):
		print("StructureWorld: uid=%d despawned" % uid)

## 0x351E (c:0x89a7b0 -> 0x5359c0): the state set and the model redrawn.
func on_event_state(uid: int, state: int) -> void:
	var rec: StructureSpawnNet.Record = records.get(uid)
	if rec == null:
		print("StructureWorld: 0x351E for uid=%d, not in view" % uid)
		return
	rec.state = state
	print("StructureWorld: 0x351E uid=%d state %d" % [uid, state])
	# READ CIEventRuntimeObj::FUN_00535750: 0 builds the model, 1 removes it
	# (FUN_009c4160(2)), any other value leaves the object as it is.
	if state == StructureSpawnNet.STATE_DRAWN:
		if not _standing(uid):
			place(rec)
	elif state == StructureSpawnNet.STATE_REMOVED:
		remove_holder(uid)

## Every record of region (rx, ry), once its group stands (World3D calls it
## where it places the region's NPCs).
func place_region(rx: int, ry: int) -> void:
	for uid in records:
		var rec: StructureSpawnNet.Record = records[uid]
		if rec.region_x == rx and rec.region_y == ry and not _standing(uid):
			place(rec)

func clear() -> void:
	for uid in holders.keys():
		remove_holder(uid)
	records.clear()

func remove_holder(uid: int) -> void:
	var h = holders.get(uid)
	holders.erase(uid)
	if h != null and is_instance_valid(h):
		(h as Node).queue_free()

func _standing(uid: int) -> bool:
	return holders.has(uid) and is_instance_valid(holders[uid]) and not (holders[uid] as Node).is_queued_for_deletion()

## Whether this player may see gate `rec` (StructureSpawnNet.gate_visible).
func gate_visible(rec: StructureSpawnNet.Record) -> bool:
	var party: PartyState = NetClient.party
	return StructureSpawnNet.gate_visible(rec, NetClient.current_character_name, party.party_id if party.in_party else 0)

## Builds rec's holder under its region's group; null when nothing is drawn.
func place(rec: StructureSpawnNet.Record) -> Node3D:
	var group := w.get_node_or_null("RealTerrain_%d_%d" % [rec.region_x, rec.region_y]) as Node3D
	if group == null:
		return null
	var model := ""
	var name_text := ""
	var b := building(rec.ref_id)
	if rec.kind == StructureSpawnNet.KIND_GATE:
		if not gate_visible(rec):
			print("StructureWorld: gate uid=%d not built: access %d is not this player's (READ c:0x9e9eb0)" % [rec.uid, rec.access])
			return null
		model = String(b.get("model", ""))
		var names: UiTextTable = w._object_names()
		var strid := String(b.get("name_strid", ""))
		name_text = names.get_text(strid).strip_edges() if names != null and strid != "" else ""
		if name_text == strid:
			name_text = ""
	elif rec.kind == StructureSpawnNet.KIND_EVENT:
		if rec.state != StructureSpawnNet.STATE_DRAWN:
			return null
		var code := zone_object(rec.zone_id)
		model = model_of_code(code) if code != "" else ""
		if model == "":
			print("StructureWorld: door uid=%d zone %d ('%s') has no model -- nothing drawn" % [rec.uid, rec.zone_id, code])
			return null
	var holder := Node3D.new()
	holder.name = "Structure_%d_%d" % [rec.ref_id, rec.uid]
	var local := rec.local_position
	var height := local.y
	var pair: Array = w._grid.nav_graph_for_region(rec.region_x, rec.region_y)
	if not pair.is_empty():
		height = (pair[0] as NavGraph).landing_height_at(local.x, local.z, local.y)
	holder.position = Vector3(local.x, height, local.z)
	# The angle as every CIGIDObject's (FUN_009c3a70 -> FUN_009c40b0, the
	# holder set by FUN_009c4260), the NPCs' formula.
	holder.rotation.y = NpcSpawnNet.holder_yaw(NpcSpawnNet.heading_of(rec.angle))
	holder.set_meta(META_STRUCTURE, rec.uid)
	# A skinned model (MEASURED: our archive's alex_raid_portal.bsr has a .bsk
	# and a .ban -- the same model NPC_INS_EXIT_TELEPORT wears) is assembled as
	# the NPCs' bodies are (SkinnedBsrAssembler, its idle playing); a static one
	# through the scenery templates below.
	var model_path := model
	var skinned := _skinned_body(model) if model != "" else null
	if skinned != null:
		skinned.name = "Model"
		holder.add_child(skinned)
		model = ""
	if model != "":
		if w._object_templates == null:
			w._object_templates = ObjectTemplateCache.new(w._load_object_template)
		# The tables name models below res\ (as the ground items' and the
		# stall booths' .bsr: "res\\" + path).
		var full := model if model.to_lower().begins_with("res\\") else "res\\" + model
		var body: Node3D = (w._object_templates as ObjectTemplateCache).instance(full, "structure")
		if body != null:
			body.name = "Model"
			holder.add_child(body)
		else:
			print("StructureWorld: uid=%d model %s did not build" % [rec.uid, model])
	if rec.kind == StructureSpawnNet.KIND_GATE:
		holder.set_meta(META_GATE, true)
		holder.set_meta("npc_uid", rec.uid)
		holder.set_meta("npc_name", name_text)
		holder.set_meta("npc_code", String(b.get("code", "")))
		holder.set_meta("npc_id", rec.ref_id)
		var r := float(b.get("r", 0.0))
		var h := float(b.get("h", 0.0))
		if r > 0.0 and h > 0.0:
			var pick := StaticBody3D.new()
			pick.name = "PickBox"
			pick.collision_layer = w.GATE_PICK_COLLISION_LAYER
			pick.collision_mask = 0
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(r * 2.0, h * 2.0, r * 2.0)
			shape.shape = box
			pick.add_child(shape)
			holder.add_child(pick)
	group.add_child(holder)
	if skinned != null:
		w._light_character(holder)
		var idle = skinned.get_meta(META_IDLE, null)
		if idle != null:
			w._animate_skeleton(skinned, idle)
	holders[rec.uid] = holder
	_attach_effects(holder)
	print("StructureWorld: %s uid=%d built '%s' (%s, %s) in %d/%d at %.1f,%.1f,%.1f" % [
		"gate" if rec.kind == StructureSpawnNet.KIND_GATE else "door", rec.uid, name_text, model_path,
		"skinned" if skinned != null else "static", rec.region_x, rec.region_y,
		holder.position.x, holder.position.y, holder.position.z])
	return holder

const META_IDLE := "structure_idle"
## Assembled skinned templates by model path (as World3D's NPC model cache).
var _skinned_templates: Dictionary = {}

## A skinned model's skeleton (its idle clip in META_IDLE), or null when the
## model has no skeleton to assemble (a static .bsr).
func _skinned_body(model: String) -> Skeleton3D:
	var archive: Pk2Reader = w._open_pk2_if_set()
	if archive == null:
		return null
	var template = _skinned_templates.get(model)
	if template == null and not _skinned_templates.has(model):
		_skinned_templates[model] = null
		var parsed := BsrReader.parse(SkinnedBsrAssembler._read(archive, model))
		if parsed != null and parsed.skeleton_path != "":
			template = SkinnedBsrAssembler.assemble_from_archive(archive, model, true, false, 0, true)
			_skinned_templates[model] = template
	if template == null:
		return null
	var skeleton := (template as SkinnedBsrAssembler.AssembledCharacter).skeleton.duplicate() as Skeleton3D
	if skeleton == null:
		return null
	BodyMirror.apply(skeleton)
	skeleton.set_meta(META_IDLE, (template as SkinnedBsrAssembler.AssembledCharacter).idle_animation)
	return skeleton

## The model's ambient particle sets (AmbientParticles, as a town gate's).
func _attach_effects(holder: Node3D) -> void:
	if OS.get_environment("OPENSRO_QA_AMBIENT") == "off":
		return
	var body := holder.get_node_or_null("Model") as Node3D
	if body == null or not body.has_meta(AmbientParticles.META_ENTRIES):
		return
	var particles: Pk2Reader = w._open_particles_pk2_if_set()
	if particles == null:
		return
	var made: Array = (w._ambient as AmbientParticles).attach(body, body.get_meta(AmbientParticles.META_ENTRIES), particles)
	print("StructureWorld: %s plays %d ambient effect(s)" % [holder.name, made.size()])

## The holder of a gate uid, or null.
func gate_holder(uid: int) -> Node3D:
	var h = holders.get(uid)
	if h == null or not is_instance_valid(h):
		return null
	return h as Node3D

func is_gate(uid: int) -> bool:
	var rec: StructureSpawnNet.Record = records.get(uid)
	return rec != null and rec.kind == StructureSpawnNet.KIND_GATE

# --- The gate's talk window --------------------------------------------------

## The window's gate lines for gate `uid` (GameWorldNet.gate_lines): the
## party master's name (type 7: the party's leader), the hole's band and grade.
func gate_lines(uid: int, text: Callable) -> Array:
	var rec: StructureSpawnNet.Record = records.get(uid)
	if rec == null:
		return []
	var master := ""
	if rec.owned == 1 and rec.access == StructureSpawnNet.ACCESS_PARTY:
		master = _party_leader_name()
	var band := Vector2i.ZERO
	var grade := 0
	var rows: Dictionary = w._item_rows
	var it = rows.get(rec.hole_ref)
	if it != null:
		band = Vector2i(int(it.param3), int(it.param4))
		grade = int(it.param1)
	return GameWorldNet.gate_lines(text, master, band, grade)

## The party leader's name (CharacterDependentData::FUN_009921e0(party +0x14),
## c:0x9e9f3b).
func _party_leader_name() -> String:
	var party: PartyState = NetClient.party
	if party == null or not party.in_party:
		return ""
	var leader: PartyNet.Member = party.leader()
	return leader.member_name if leader != null else ""
