extends Node3D
class_name EquipFx

## The kept particle effects of glowing equipment (round 734), drawn at a
## cost per effect TYPE, not per weapon: the user's target is 1000+ players
## on screen (2026-10-06), and one EfpEffect per weapon cost ~0.13 ms a frame
## each (MEASURED: 20 bodies at +13, 40 effects, +5.1 ms at the Jangan spawn).
##
## **How (OURS throughout).** One driver per viewport. For each (efp, scale)
## in use it keeps ONE master EfpEffect, simulated at the world origin and
## never moved, whose own draws are hidden; every weapon showing that effect
## gets a holder (an EfpEffect with no simulation, so AppearFade, BerserkLook
## and EquipGlow pass it by as an effect) whose MultiMeshInstance3D and Link
## children SHARE the master's MultiMesh and meshes. The driver puts each
## holder at its bone's position, scaled by the row's col3/100, every frame.
## The master's billboards face the camera in world axes, and a holder has no
## rotation, so they face it under every weapon.
##
## **What this changes against retail, all OURS:**
## - every weapon with the same effect shows the same particles, in step;
## - the particles follow the bone's position only: retail simulates each
##   effect in world space with the host's motion as its placement, so a
##   running weapon leaves its free particles behind and the followers turn
##   with it (EfpEffect's follow levels); here they move with the weapon
##   rigidly and do not turn;
## - a budget: only the VISIBLE_BUDGET weapons nearest the camera within
##   MAX_DISTANCE and inside the view show their particles, re-chosen every
##   RESELECT_FRAMES frames. Retail's own limits are not READ: Effect
##   Quality's reader and Character Sight Range's (round 694: none found) are
##   OPEN, and so is FUN_00c43780's gate (weapon_glow.md OPEN 6, 11).
## The glow itself is untouched (a material, no per-frame work).

const MAX_DISTANCE := 800.0
const VISIBLE_BUDGET := 64
const RESELECT_FRAMES := 10
## How long a master with no weapon showing it is kept before it is freed.
const IDLE_FRAMES := 600

const DRIVER_META := "opensro_equip_fx_driver"

class Host:
	var skel: Skeleton3D
	var bone: int
	var key: String
	var scale: float
	var holder: EfpEffect = null

class Kind:
	var key: String
	var master: EfpEffect
	var active := 0
	var idle := 0

var particles: Pk2Reader
var _hosts: Dictionary = {}   # "skel id|bone" -> Host
var _kinds: Dictionary = {}   # key -> Kind
var _frame := 0
var _shown: Array = []        # the hosts drawing their effect, placed every frame
## Counts for the QA line and the tests.
var stats := {"hosts": 0, "shown": 0, "kinds": 0}

## A child of an item's skeleton carrying its rows: it registers them with
## its viewport's driver whenever it enters a tree and takes them off when it
## leaves, so a body built detached (CharacterAppearance) or moved between
## viewports needs nothing else.
class Marker extends Node:
	var rows: Array = []   # [{efp, bone, scale, archive}]
	func _enter_tree() -> void:
		var skel := get_parent() as Skeleton3D
		if skel == null or rows.is_empty() or get_viewport() == null:
			return
		var d := EquipFx.driver_for(get_viewport())
		for e in rows:
			d.add_host(skel, String(e["bone"]), String(e["efp"]), float(e["scale"]), e["archive"])
	func _exit_tree() -> void:
		var skel := get_parent() as Skeleton3D
		var vp := get_viewport()
		if skel != null and vp != null and vp.has_meta(EquipFx.DRIVER_META):
			var d = vp.get_meta(EquipFx.DRIVER_META)
			if is_instance_valid(d):
				(d as EquipFx).remove_skel(skel)

## Puts `rows` (ItemGlowTables.ParticleRow) on `skel`, an item's own
## skeleton, through a Marker. Returns how many rows found their bone (READ:
## a row whose bone the item lacks makes no effect).
static func attach(skel: Skeleton3D, rows: Array, archive: Pk2Reader) -> int:
	var list: Array = []
	for r in rows:
		var row := r as ItemGlowTables.ParticleRow
		if skel.find_bone(row.bone) < 0:
			continue
		list.append({"efp": row.efp, "bone": row.bone, "scale": row.scale, "archive": archive})
	if list.is_empty():
		return 0
	var m := Marker.new()
	m.name = "EquipFxMarker"
	m.rows = list
	m.set_meta(EquipGlow.FX_META, true)
	skel.add_child(m)
	return list.size()

## The driver of `vp`, made on first use.
static func driver_for(vp: Viewport) -> EquipFx:
	if vp.has_meta(DRIVER_META):
		var d: EquipFx = vp.get_meta(DRIVER_META)
		if is_instance_valid(d):
			return d
	var nd := EquipFx.new()
	nd.name = "EquipFx"
	vp.add_child(nd)
	vp.set_meta(DRIVER_META, nd)
	return nd

func add_host(skel: Skeleton3D, bone: String, efp: String, scale: float, archive: Pk2Reader) -> void:
	var b := skel.find_bone(bone)
	if b < 0:
		return
	var id := "%d|%d" % [skel.get_instance_id(), b]
	if _hosts.has(id):
		return
	if particles == null:
		particles = archive
	var key := "%s|%s" % [efp.to_lower(), str(snappedf(scale, 0.0001))]
	if not _kinds.has(key):
		var m := EfpEffect.create(efp, archive)
		if m == null:
			return
		m.loop = true
		m.auto_free = false
		m.top_level = true
		m.name = "master_%d" % _kinds.size()
		for c in m.get_children():
			if c is GeometryInstance3D:
				(c as GeometryInstance3D).visible = false
		add_child(m)
		m.global_transform = Transform3D.IDENTITY
		var k := Kind.new()
		k.key = key
		k.master = m
		_kinds[key] = k
	var h := Host.new()
	h.skel = skel
	h.bone = b
	h.key = key
	h.scale = scale
	_hosts[id] = h

func remove_skel(skel: Skeleton3D) -> void:
	var sid := "%d|" % skel.get_instance_id()
	for id in _hosts.keys():
		if String(id).begins_with(sid):
			_drop(id)

func _drop(id: String) -> void:
	var h: Host = _hosts[id]
	if h.holder != null and is_instance_valid(h.holder):
		h.holder.queue_free()
	_hosts.erase(id)

## A holder sharing `master`'s draws (see the header).
static func _holder_for(master: EfpEffect) -> EfpEffect:
	var hold := EfpEffect.new()
	hold.name = "EquipFxHolder"
	hold.set_meta(EquipGlow.FX_META, true)
	hold.top_level = true
	for c in master.get_children():
		if c is MultiMeshInstance3D:
			var src := c as MultiMeshInstance3D
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = src.multimesh
			mmi.material_override = src.material_override
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.custom_aabb = src.custom_aabb
			hold.add_child(mmi)
		elif c is MeshInstance3D:
			var src := c as MeshInstance3D
			var mi := MeshInstance3D.new()
			mi.mesh = src.mesh
			mi.material_override = src.material_override
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.custom_aabb = src.custom_aabb
			hold.add_child(mi)
	return hold

func _process(_delta: float) -> void:
	_frame += 1
	var t0 := Time.get_ticks_usec() if EfpEffect.profile else 0
	var cam := get_viewport().get_camera_3d()
	if _frame % RESELECT_FRAMES == 1 or RESELECT_FRAMES <= 1:
		_reselect(cam)
	for h in _shown:
		if not is_instance_valid(h.holder) or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
			continue
		var at: Vector3 = h.skel.global_transform * h.skel.get_bone_global_pose(h.bone).origin
		h.holder.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * h.scale), at)
	if EfpEffect.profile:
		EfpEffect.prof["driver"] = int(EfpEffect.prof.get("driver", 0)) + Time.get_ticks_usec() - t0

## Chooses the hosts that show their effect: valid, in view, within
## MAX_DISTANCE, the VISIBLE_BUDGET nearest. Masters with none pause.
func _reselect(cam: Camera3D) -> void:
	var cands: Array = []
	var gone: Array = []
	for id in _hosts:
		var h: Host = _hosts[id]
		if not is_instance_valid(h.skel) or h.skel.is_queued_for_deletion():
			gone.append(id)
			continue
		if not h.skel.is_inside_tree() or not h.skel.is_visible_in_tree():
			cands.append([INF, id])
			continue
		var p := h.skel.global_position
		var d := cam.global_position.distance_to(p) if cam != null else 0.0
		if cam != null and (d > MAX_DISTANCE or not cam.is_position_in_frustum(p)) and d > 30.0:
			d = INF
		cands.append([d, id])
	for id in gone:
		_drop(id)
	cands.sort_custom(func(a, b): return a[0] < b[0])
	for k in _kinds.values():
		(k as Kind).active = 0
	var shown := 0
	_shown.clear()
	for i in cands.size():
		var h: Host = _hosts[cands[i][1]]
		var on: bool = shown < VISIBLE_BUDGET and cands[i][0] < INF
		if on:
			shown += 1
			_shown.append(h)
			var k: Kind = _kinds[h.key]
			k.active += 1
			if h.holder == null or not is_instance_valid(h.holder):
				h.holder = _holder_for(k.master)
				h.skel.add_child(h.holder)
			h.holder.visible = true
		elif h.holder != null and is_instance_valid(h.holder):
			h.holder.visible = false
	for key in _kinds.keys():
		var k: Kind = _kinds[key]
		k.master.set_process(k.active > 0)
		k.idle = 0 if k.active > 0 else k.idle + RESELECT_FRAMES
		if k.idle > IDLE_FRAMES and not _uses(key):
			k.master.queue_free()
			_kinds.erase(key)
	stats["hosts"] = _hosts.size()
	stats["shown"] = shown
	stats["kinds"] = _kinds.size()

func _uses(key: String) -> bool:
	for id in _hosts:
		if (_hosts[id] as Host).key == key:
			return true
	return false
