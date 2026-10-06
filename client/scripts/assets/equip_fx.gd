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
## holder in its bone's frame -- position AND rotation (round 741, READ:
## CRTModParticle::FUN_00c81190 hands the effect the bone's matrix times the
## world's; holder_transform) -- scaled by the row's col3/100, every frame.
## The billboards still face the camera because the master's plates are
## drawn on EfpEffect's shared-turn shader (EfpEffect.use_shared_turn), which
## builds each billboard from the camera in the vertex stage rather than
## baking it into the shared instances. Round 734 placed holders at the bone's
## position only: the effect's offsets then ran along fixed world axes, a
## column of sparks beside the weapon that lined up with it at one heading.
##
## **What this changes against retail, all OURS:**
## - every weapon with the same effect shows the same particles, in step;
## - the particles follow the bone rigidly. Retail simulates each effect in
##   world space with the host's motion as its placement, so a particle that
##   does not follow the effect stays behind. Every node of the 16 enchant
##   files follows its parent in position, orbit and rotation (u2 = u3 = u6
##   = 1 at every depth, MEASURED round 741), so for them rigid IS retail's
##   motion; only an effect with a free node would differ;
## - a budget: only the VISIBLE_BUDGET weapons nearest the camera within
##   MAX_DISTANCE and inside the view (or within ALWAYS_NEAR of it, in view
##   or not) show their particles, re-chosen every RESELECT_FRAMES frames
##   from a scan spread over those frames. Retail's own limits are not READ: Effect
##   Quality's reader and Character Sight Range's (round 694: none found) are
##   OPEN, and so is FUN_00c43780's gate (weapon_glow.md OPEN 6, 11).
## - the particles take the host's uniform scale (the body's height factor)
##   times the row's col3/100, as the per-weapon path did; retail's further
##   global factor in CEFEffect::vslot_010 (`*(this+4)+0x264`, weapon_glow.md
##   §8 item 5) is applied by neither path: what it holds is OPEN.
## The glow itself is untouched (a material, no per-frame work).

const MAX_DISTANCE := 800.0
const VISIBLE_BUDGET := 64
const RESELECT_FRAMES := 10
## A weapon this close to the camera shows its effect even outside the view
## (OURS: so an effect larger than its host does not drop when the host's
## origin leaves the frustum at the screen's edge).
const ALWAYS_NEAR := 30.0
## How long a master with no weapon showing it is kept before it is freed.
const IDLE_FRAMES := 600

const DRIVER_META := "opensro_equip_fx_driver"

class Host:
	var id: String
	var skel: Skeleton3D
	var bone: int
	var key: String
	var scale: float
	var holder: EfpEffect = null
	## The cycle that last chose it (_finish_cycle).
	var shown_cycle := -1

class Kind:
	var key: String
	var master: EfpEffect
	var active := 0
	var idle := 0
	## Hosts registered with this effect, shown or not.
	var hosts := 0

var particles: Pk2Reader
var _hosts: Dictionary = {}   # "skel id|bone|efp key" -> Host
var _kinds: Dictionary = {}   # key -> Kind
var _frame := 0
var _shown: Array = []        # the hosts drawing their effect, placed every frame
# The spread re-selection (_begin_cycle): this cycle's host ids, how far the
# scan is, the candidates found with their distances, the frame it began on
# and the hosts measured a frame.
var _scan: Array = []
var _scan_at := 0
var _cand: Array = []
var _cand_d := PackedFloat32Array()
var _cycle := 0
var _cycle_frame := 0
var _per_frame := 0
var _paused := false
var _hurry := false
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
	var key := "%s|%s" % [efp.to_lower(), str(snappedf(scale, 0.0001))]
	# One host per (bone, effect), not per bone (round 741): a seal weapon has
	# its itemrare.txt row and, from +8, its itemoptionefp.txt row on the same
	# bone (Sun spear 4118: raretype_a_step3 and enchant_a_01, both ai_end),
	# and retail makes a mod for each entry (FUN_00a5f3e0's loop, READ). Keyed
	# by bone alone, the second was dropped. The same file at the same scale
	# twice on one bone is drawn once (OURS; no item has that, MEASURED by
	# round 740: no itemoptionefp row lands in a list that already has it).
	var id := "%d|%d|%s" % [skel.get_instance_id(), b, key]
	if _hosts.has(id):
		return
	if particles == null:
		particles = archive
	if not _kinds.has(key):
		var m := EfpEffect.create(efp, archive)
		if m == null:
			return
		m.loop = true
		m.auto_free = false
		m.top_level = true
		# The holders turn with their bones (round 741); the billboards are
		# built in the shader so they still face the camera.
		m.use_shared_turn()
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
	h.id = id
	h.skel = skel
	h.bone = b
	h.key = key
	h.scale = scale
	_hosts[id] = h
	(_kinds[key] as Kind).hosts += 1
	# Measured in the cycle under way (its slices are fixed at its start, and
	# the cycle's last frame scans whatever is left); while the hosts fit the
	# budget, a whole cycle runs next frame, so the select screen's and the
	# equipment window's few bodies show theirs at once (OURS).
	_scan.append(id)
	if _hosts.size() <= VISIBLE_BUDGET:
		_hurry = true

func remove_skel(skel: Skeleton3D) -> void:
	var sid := "%d|" % skel.get_instance_id()
	for id in _hosts.keys():
		if String(id).begins_with(sid):
			_drop(id)

func _drop(id: String) -> void:
	var h: Host = _hosts[id]
	if h.holder != null and is_instance_valid(h.holder):
		h.holder.queue_free()
	if _kinds.has(h.key):
		(_kinds[h.key] as Kind).hosts -= 1
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
	var paused := _viewport_paused()
	if paused != _paused or _hurry:
		# The equipment window opened or closed (round 734's review, F5): a
		# whole cycle at once, so its particles show, or stop, this frame.
		_paused = paused
		_hurry = false
		_begin_cycle()
		_scan_slice(cam, _scan.size())
		_finish_cycle()
		_begin_cycle()
	else:
		_scan_slice(cam, _per_frame)
		if _frame - _cycle_frame >= RESELECT_FRAMES:
			_scan_slice(cam, _scan.size())
			_finish_cycle()
			_begin_cycle()
	for h in _shown:
		if not is_instance_valid(h.holder) or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
			continue
		h.holder.global_transform = holder_transform(h.skel, h.bone, h.scale)
	if _qa_log_every > 0 and _frame % _qa_log_every == 0:
		_qa_log(cam)
	if EfpEffect.profile:
		EfpEffect.prof["driver"] = int(EfpEffect.prof.get("driver", 0)) + Time.get_ticks_usec() - t0

## Where a host's holder goes (round 741): the bone's whole frame in the world
## -- READ, CRTModParticle::FUN_00c81190 places the effect at the bone's
## matrix times the world's (`0xc811c5`..`0xc81288`, then CEFEffect::vslot_007)
## -- with its rotation (and a mirror, if the frame has one) kept, its own
## scale replaced by the row's col3/100 times the host's uniform scale. Round
## 734 placed the holder at the bone's position only, so the effect's
## SetPosition offsets (enchant_a_01: 0, -1.2 .. -4.8 along the effect's X,
## in its parent's frame, space 7) pointed along fixed world axes: the
## column of sparks beside the spear, lined up with it at one heading only.
static func holder_transform(skel: Skeleton3D, bone: int, row_scale: float) -> Transform3D:
	var g: Transform3D = skel.global_transform
	var at: Transform3D = g * skel.get_bone_global_pose(bone)
	var b := at.basis.orthonormalized()
	return Transform3D(b * (row_scale * _uniform_scale(g.basis)), at.origin)

## OPENSRO_QA_EQUIPFX_LOG=<frames> (round 741): every that many frames, one
## line per shown host measuring where its drawn particles are against its
## weapon's own bones -- the measurement, not a picture:
##   QA EQUIPFX <efp> bone <b> heading <deg> at (x,y,z) particles <n>
##     centroid (x,y,z) | axis <ai_end -> other bone> span [<min>, <max>] along,
##     off max <d> mean <d> | was (position-only placement) off max <d>
##     | screen tip (x,y) centroid (x,y)
## `along` and `off` are each drawn particle's distance along and from the line
## from the row's bone to the item skeleton's other end bone (ai_start for
## ai_end and back; Bone03 for Bone01 and back), in world units; `was` is the
## same measure for round 734's placement (the bone's position, the effect's
## axes along the world's).
static var _qa_log_every := int(OS.get_environment("OPENSRO_QA_EQUIPFX_LOG")) if OS.get_environment("OPENSRO_QA_EQUIPFX_LOG").is_valid_int() else 0

func _qa_log(cam: Camera3D) -> void:
	for h in _shown:
		if not is_instance_valid(h.holder) or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
			continue
		var k: Kind = _kinds.get(h.key)
		if k == null:
			continue
		var m := measure(h, k)
		if m.is_empty():
			continue
		var scr := ""
		var tip: Vector3 = m["tip"]
		if cam != null and not cam.is_position_behind(tip):
			scr = " | screen tip %s centroid %s" % [str(cam.unproject_position(tip).round()), str(cam.unproject_position(m["centroid"]).round())]
		print("QA EQUIPFX %s bone %s heading %.0f at %s particles %d centroid %s | axis %s->%s len %.2f span [%.2f, %.2f] along, off max %.3f mean %.3f | was off max %.3f%s" % [
			k.key.get_slice("|", 0), m["bone"], m["heading"], str(tip.snapped(Vector3.ONE * 0.01)), m["particles"],
			str((m["centroid"] as Vector3).snapped(Vector3.ONE * 0.01)), m["bone"], m["other"], m["axis"], m["lo"], m["hi"],
			m["off_max"], m["off_mean"], m["was_max"], scr])

## Where `h`'s drawn particles are against its weapon (the QA log and
## tools/measure_equip_fx_turn.gd): each drawn particle of the kind's master,
## placed by holder_transform as the holders are, measured along and off the
## line from the row's bone to the item's other end bone (ai_start <-> ai_end,
## Bone01 <-> Bone03); `was_max` is the same for round 734's placement (the
## bone's position, the effect's axes along the world's). Empty when nothing
## is drawn or the item has no other end bone.
static func measure(h: Host, k: Kind) -> Dictionary:
	if k.master == null or k.master.sim == null or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
		return {}
	var g: Transform3D = h.skel.global_transform
	var tip: Vector3 = g * h.skel.get_bone_global_pose(h.bone).origin
	var name: String = h.skel.get_bone_name(h.bone)
	# The other end: its pair (ai_start <-> ai_end, Bone01 <-> Bone03), else
	# the first of the item's named bones that is not this one (a shield has
	# Bone01 and no Bone03).
	var other_name := "ai_start" if name == "ai_end" else ("ai_end" if name == "ai_start" else ("Bone03" if name == "Bone01" else "Bone01"))
	var ob: int = h.skel.find_bone(other_name)
	if ob < 0:
		for cand in ["ai_start", "ai_end", "Bone01", "Bone02", "Bone03"]:
			var ci := h.skel.find_bone(cand)
			if ci >= 0 and ci != h.bone:
				ob = ci
				other_name = cand
				break
	if ob < 0:
		return {}
	var axis: Vector3 = g * h.skel.get_bone_global_pose(ob).origin - tip
	var axis_len := axis.length()
	if axis_len < 1e-6:
		return {}
	var dir := axis / axis_len
	var drawn := {}
	for d in k.master._draws:
		drawn[int(d[0])] = true
	for l in k.master._links:
		drawn[int(l[0])] = true
	var ht := holder_transform(h.skel, h.bone, h.scale)
	var old := Transform3D(Basis.from_scale(Vector3.ONE * (h.scale * _uniform_scale(g.basis))), tip)
	var n := 0
	var sum := Vector3.ZERO
	var lo := INF
	var hi := -INF
	var off_max := 0.0
	var off_sum := 0.0
	var was_max := 0.0
	var was_sum := Vector3.ZERO
	for p in k.master.sim.particles:
		if not drawn.has(p.tpl):
			continue
		var w := ht * p.pos
		n += 1
		sum += w
		var along := (w - tip).dot(dir)
		lo = minf(lo, along)
		hi = maxf(hi, along)
		var off := ((w - tip) - dir * along).length()
		off_max = maxf(off_max, off)
		off_sum += off
		var wo := old * p.pos
		was_sum += wo
		var along_o := (wo - tip).dot(dir)
		was_max = maxf(was_max, ((wo - tip) - dir * along_o).length())
	if n == 0:
		return {}
	return {"tip": tip, "bone": name, "other": other_name, "axis": axis_len, "particles": n, "centroid": sum / n,
		"lo": lo, "hi": hi, "off_max": off_max, "off_mean": off_sum / n, "was_max": was_max, "was_centroid": was_sum / n,
		"heading": rad_to_deg(atan2(g.basis.z.x, g.basis.z.z))}

## The size of the host's own scale (round 734's review, F4): the body's height
## factor (CharacterAppearance.HEIGHT_FACTORS) reaches the particles as it did
## on the per-weapon path (EfpEffect.scale_basis on the anchor). Its magnitude
## only, the cube root of |det| (OURS): the master's billboards face the
## camera in world axes, so a holder takes no mirror (the select screen's
## root is scaled (1, 1, -1)) and no rotation.
static func _uniform_scale(b: Basis) -> float:
	return pow(absf(b.determinant()), 1.0 / 3.0)

## Whether this driver's viewport draws nothing now: the equipment window's
## SubViewport keeps its nodes and camera while closed, at UPDATE_DISABLED
## (PaperDoll.set_active), and its hosts would keep the masters simulating
## unseen (round 734's review, F5).
func _viewport_paused() -> bool:
	var vp := get_viewport()
	return vp is SubViewport and (vp as SubViewport).render_target_update_mode == SubViewport.UPDATE_DISABLED

## The re-selection is spread over RESELECT_FRAMES frames (round 734's review,
## F3, OURS): each frame measures a slice of the hosts, and the cycle's last
## frame picks the nearest VISIBLE_BUDGET of those found. A host added during a
## cycle joins it (add_host).
func _begin_cycle() -> void:
	_scan = _hosts.keys()
	_scan_at = 0
	_cand.clear()
	_cand_d.clear()
	_cycle_frame = _frame
	_per_frame = ceili(float(_scan.size()) / float(maxi(RESELECT_FRAMES, 1)))

## Measures up to `count` more hosts of this cycle: a host is a candidate when
## valid, drawn, and in the view within MAX_DISTANCE -- or within ALWAYS_NEAR
## of the camera, in view or not.
func _scan_slice(cam: Camera3D, count: int) -> void:
	var end := mini(_scan_at + count, _scan.size())
	var from := cam.global_position if cam != null else Vector3.ZERO
	while _scan_at < end:
		var id: String = _scan[_scan_at]
		_scan_at += 1
		var h: Host = _hosts.get(id)
		if h == null:
			continue
		if not is_instance_valid(h.skel) or h.skel.is_queued_for_deletion():
			_drop(id)
			continue
		if _paused or not h.skel.is_inside_tree() or not h.skel.is_visible_in_tree():
			continue
		var d := 0.0
		if cam != null:
			var p := h.skel.global_position
			d = from.distance_to(p)
			if d > ALWAYS_NEAR and (d > MAX_DISTANCE or not cam.is_position_in_frustum(p)):
				continue
		_cand.append(h)
		_cand_d.append(d)

## The cycle's choice: the VISIBLE_BUDGET nearest candidates show their
## effect, every other holder hides, and masters with none pause. No sort while
## the candidates fit the budget; past it, only their distances are sorted
## (natively) for the budget's cut.
func _finish_cycle() -> void:
	_cycle += 1
	var limit := INF
	if _cand.size() > VISIBLE_BUDGET:
		var sorted := _cand_d.duplicate()
		sorted.sort()
		limit = sorted[VISIBLE_BUDGET - 1]
	for k in _kinds.values():
		(k as Kind).active = 0
	var before := _shown
	_shown = []
	for i in _cand.size():
		if _shown.size() >= VISIBLE_BUDGET:
			break
		var h: Host = _cand[i]
		if _cand_d[i] > limit or _hosts.get(h.id) != h or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
			continue
		h.shown_cycle = _cycle
		_shown.append(h)
		var k: Kind = _kinds[h.key]
		k.active += 1
		if h.holder == null or not is_instance_valid(h.holder):
			h.holder = _holder_for(k.master)
			h.skel.add_child(h.holder)
			# A holder only draws what its master simulates: no _process of
			# its own (the review, F3). After add_child, whose ready would
			# turn it back on.
			h.holder.set_process(false)
		h.holder.visible = true
	for h in before:
		if (h as Host).shown_cycle != _cycle and h.holder != null and is_instance_valid(h.holder):
			h.holder.visible = false
	_cand.clear()
	_cand_d.clear()
	for key in _kinds.keys():
		var k: Kind = _kinds[key]
		k.master.set_process(k.active > 0)
		k.idle = 0 if k.active > 0 else k.idle + maxi(_frame - _cycle_frame, 1)
		if k.idle > IDLE_FRAMES and k.hosts <= 0:
			k.master.queue_free()
			_kinds.erase(key)
	stats["hosts"] = _hosts.size()
	stats["shown"] = _shown.size()
	stats["kinds"] = _kinds.size()
