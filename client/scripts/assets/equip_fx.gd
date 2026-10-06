extends Node3D
class_name EquipFx

## The kept particle effects of glowing equipment (round 734), drawn at a
## cost per effect TYPE, not per weapon: the user's target is 1000+ players
## on screen (2026-10-06), and one EfpEffect per weapon cost ~0.13 ms a frame
## each (MEASURED: 20 bodies at +13, 40 effects, +5.1 ms at the Jangan spawn).
##
## **How (OURS throughout).** One driver per viewport. For each effect file
## in use (round 748: not per row scale, kind_key) it keeps ONE master
## EfpEffect, simulated at the world origin and
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
##   world space with the host's motion as its placement. Every node of the
##   74 equipment files follows its parent in position and orbit (MEASURED,
##   rounds 741 and its review), so rigid is retail's motion -- EXCEPT for a
##   command whose vector or rotation is along the WORLD's axes (round 746,
##   world_commands: SetConeVel space 0, SetRVelocity, a per-axis
##   SetSpherePos; 35 of the 74 files, client/tools/census_equip_world.gd).
##   Turned with the holder, those point along the bone. So on the
##   OWN_BUDGET nearest weapons (one: the player's own) such an effect runs
##   its own world-space simulation (the per-weapon path); elsewhere it draws
##   the shared master turned (OURS);
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
## The most holders drawn at once (round 746: whole weapons only, see
## _finish_cycle). OURS.
const VISIBLE_BUDGET := 64
## Round 746 (OURS): how many WEAPONS carrying a world-axis effect (Kind.own),
## nearest the camera, run those effects on their own world-space simulation,
## as retail does; the rest draw the shared master turned with their bone.
## One: the nearest weapon, which is the player's own while the camera follows
## the player -- the weapon the player looks at. MEASURED (profile_equip_crowd.gd,
## 200 Sun spears, headless): 4 own weapons cost 3.7 ms a frame of script
## (place, simulate, redraw and rebuild the pipes every frame as the hand
## moves), and the 200-spear gate went 21.9 -> 28.4 ms with 4.
## OPENSRO_QA_EQUIPFX_OWN=<n> (QA, round 746) sets it, for a gate's A/B.
static var OWN_BUDGET := int(OS.get_environment("OPENSRO_QA_EQUIPFX_OWN")) if OS.get_environment("OPENSRO_QA_EQUIPFX_OWN").is_valid_int() else 1
const RESELECT_FRAMES := 10
## A weapon this close to the camera shows its effect even outside the view
## (OURS: so an effect larger than its host does not drop when the host's
## origin leaves the frustum at the screen's edge).
const ALWAYS_NEAR := 30.0
## How long a master with no weapon showing it is kept before it is freed.
const IDLE_FRAMES := 600

const DRIVER_META := "opensro_equip_fx_driver"
## The driver's process_priority (round 748's review, F6, OURS): after the
## world's _process at 0.
const PROCESS_PRIORITY := 100

class Host:
	var id: String
	var skel: Skeleton3D
	var bone: int
	var key: String
	var scale: float
	var holder: EfpEffect = null
	## A world-axis kind's own simulation (Kind.own), while this host is
	## among the OWN_BUDGET nearest; then `holder` is hidden.
	var own_fx: EfpEffect = null
	## Its distance from the camera at the last scan.
	var dist := 0.0
	## The cycle that last chose it (_finish_cycle).
	var shown_cycle := -1

class Kind:
	var key: String
	var master: EfpEffect
	## Round 746 (the review's finding 1): an effect with a world-axis
	## command (world_commands > 0). The OWN_BUDGET nearest of its shown
	## hosts run their own EfpEffect on the per-weapon path, simulated in the
	## world with the bone's frame as its placement, as retail does; the rest
	## draw the shared master, turned (OURS: the departure the review found,
	## kept only beyond the nearest weapons). `efp` is its file.
	var own := false
	var efp := ""
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
	# After every default-priority _process (round 748's review, F6): the
	# world poses its player in its own _process now, and a driver made by
	# the select screen sits before the world in tree order, so it placed the
	# player's holders from the last frame's pose.
	nd.process_priority = PROCESS_PRIORITY
	vp.add_child(nd)
	vp.set_meta(DRIVER_META, nd)
	return nd

func add_host(skel: Skeleton3D, bone: String, efp: String, scale: float, archive: Pk2Reader) -> void:
	var b := skel.find_bone(bone)
	if b < 0:
		return
	var key := kind_key(efp, scale)
	# One host per (bone, effect), not per bone (round 741): a seal weapon has
	# its itemrare.txt row and, from +8, its itemoptionefp.txt row on the same
	# bone (Sun spear 4118: raretype_a_step3 and enchant_a_01, both ai_end),
	# and retail makes a mod for each entry (FUN_00a5f3e0's loop, READ). Keyed
	# by bone alone, the second was dropped. The same file at the same scale
	# twice on one bone is drawn once (OURS; no item has that, MEASURED by
	# round 740: no itemoptionefp row lands in a list that already has it).
	var id := "%d|%d|%s|%s" % [skel.get_instance_id(), b, key, str(snappedf(scale, 0.0001))]
	if _hosts.has(id):
		return
	if particles == null:
		particles = archive
	if not _kinds.has(key):
		var qa_t0 := Time.get_ticks_usec() if FrameSplit.on else 0
		var m := EfpEffect.create(efp, archive)
		if m == null:
			return
		var qa_t1 := Time.get_ticks_usec() if FrameSplit.on else 0
		m.loop = true
		m.auto_free = false
		m.top_level = true
		# The holders turn with their bones (round 741); the billboards are
		# built in the shader so they still face the camera.
		m.use_shared_turn()
		if FrameSplit.on:
			print("QA EQUIPFX master %s: create %.1f ms, shared turn %.1f ms" % [efp, (qa_t1 - qa_t0) / 1000.0, (Time.get_ticks_usec() - qa_t1) / 1000.0])
		m.name = "master_%d" % _kinds.size()
		for c in m.get_children():
			if c is GeometryInstance3D:
				(c as GeometryInstance3D).visible = false
		add_child(m)
		m.global_transform = Transform3D.IDENTITY
		var k := Kind.new()
		k.key = key
		k.master = m
		k.efp = efp
		var tmpl := EfpEffect.template_for(efp, archive)
		k.own = tmpl != null and world_commands(tmpl) > 0
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

## The kind (one master) an effect file at a row's scale is drawn through.
## Round 748: the file alone. A master is simulated at the world origin with
## no scale (the holder carries the row's scale, holder_transform), so the
## 1000-body crowd's 13 (file, scale) kinds (QA CROWD census) are 6 masters.
## **What this changes, OURS (round 748's review, F7):** a master's random
## stream is its own (EfpSim._init randomizes), so before, weapons of one
## file at different row scales showed different particles; now every
## weapon showing a file shows the SAME particles at the same moment, each
## at its own scale and turned with its own bone -- in a crowd, identical
## sparks on every enchanted weapon of a file. (One master per file already
## did that for the weapons of one scale since round 734.) A per-holder phase
## into the shared stream would need a buffer of past frames per master and
## a MultiMesh swap per holder each step; not built.
static func kind_key(efp: String, _scale: float) -> String:
	return efp.to_lower()

func remove_skel(skel: Skeleton3D) -> void:
	var sid := "%d|" % skel.get_instance_id()
	for id in _hosts.keys():
		if String(id).begins_with(sid):
			_drop(id)

func _drop(id: String) -> void:
	var h: Host = _hosts[id]
	if h.holder != null and is_instance_valid(h.holder):
		h.holder.queue_free()
	if h.own_fx != null and is_instance_valid(h.own_fx):
		h.own_fx.queue_free()
	_own_parked.erase(id)
	if _kinds.has(h.key):
		(_kinds[h.key] as Kind).hosts -= 1
	_hosts.erase(id)

## Round 746's review, findings 4-5 (OURS): the node whose weapons run their
## own simulation first (World3D sets the player), the hysteresis margin, how
## long a parked own effect is kept, and the pre-roll a new or resumed one
## gets so it does not pop in empty.
var prefer_root: Node = null
const OWN_KEEP_MARGIN := 0.2
const OWN_FREE_CYCLES := 30
const OWN_PREROLL_STEPS := 10
var _own_prev := {}     # weapon (skeleton id) -> true: the own weapons last cycle
var _own_parked := {}   # host id -> the cycle its own effect was parked

## Hides and pauses `h`'s own effect, noting when (it is freed after
## OWN_FREE_CYCLES cycles parked).
func _park_own(h: Host) -> void:
	if h.own_fx == null or not is_instance_valid(h.own_fx) or not h.own_fx.visible:
		return
	# A hidden weapon's own simulation pauses (OURS: retail's limits are not
	# READ, as for the budget).
	h.own_fx.visible = false
	h.own_fx.set_process(false)
	_own_parked[h.id] = _cycle

## Starts `fx` (an own effect) at its current placement and steps it
## OWN_PREROLL_STEPS frames (0.5 s), so it shows particles at once: from
## empty when `restart`.
static func _preroll(fx: EfpEffect, restart: bool) -> void:
	if fx == null or fx.sim == null:
		return
	if restart:
		fx.sim.restart()
	for i in OWN_PREROLL_STEPS:
		fx.sim.step()

## A host's own effect for a world-space kind (Kind.own, round 746): the
## per-weapon path, as round 734 built it before EquipFx -- EfpEffect.create,
## kept (the row's `1`, READ), at the row's scale (CEFEffect::vslot_010, READ),
## placed every frame at the bone's whole frame (follow_bone_full: READ,
## CRTModParticle::FUN_00c81190) and simulated in a space that does not turn
## with it, so a space-0 vector points along the world's axes as in retail.
func _own_holder(h: Host, k: Kind) -> EfpEffect:
	var fx: EfpEffect = own_factory.call(k.efp) if own_factory.is_valid() else EfpEffect.create(k.efp, particles)
	if fx == null:
		return null
	fx.name = "EquipFxOwn"
	fx.set_meta(EquipGlow.FX_META, true)
	fx.loop = true
	fx.auto_free = false
	fx.effect_scale = h.scale
	fx.follow_bone_full = true
	h.skel.add_child(fx)
	fx.follow_host(h.skel, h.skel.get_bone_name(h.bone), Vector3.ZERO)
	_preroll(fx, false)
	return fx

## Tests only: makes an own simulation's effect from its file name instead of
## the archive.
static var own_factory := Callable()

## How many of a template's commands take a vector or a rotation along the
## WORLD's axes (round 746, the review's finding 1; rules READ, EFP_FORMAT.md
## "What the space selects"): a position command with r = 0 (space < 3:
## SetPosition, SetConePos, SetBANPos), a velocity, cone velocity, force or
## cone force with space 0 (no frame), SetRotation / SetBANRot with space 0
## (an absolute rotation), any SetRVelocity (applied after the rotation, in
## the outer frame), and a SetSpherePos whose scale differs per axis (a
## world-axis ellipsoid; space 0 always). A zero vector counts for nothing.
## Such an effect cannot be simulated once and turned per holder.
static func world_commands(t: EfpSim.Template) -> int:
	var n := 0
	for tp in t.tpls:
		for frame in tp.schedule:
			if not (frame is Array):
				continue
			for c in frame:
				if not (c is Array) or (c as Array).size() < 3:
					continue
				if _is_world(int(c[0]), int(c[1]), c[2]):
					n += 1
	return n

static func _is_world(kind: int, space: int, v) -> bool:
	match kind:
		EfpSim.K_POS, EfpSim.K_BANPOS:
			return space < 3 and v is Vector3 and (v as Vector3) != Vector3.ZERO
		EfpSim.K_CONEPOS:
			return space < 3 and v is Vector3 and (v as Vector3) != Vector3.ZERO
		EfpSim.K_VEL, EfpSim.K_FORCE, EfpSim.K_CONEVEL, EfpSim.K_CONEFORCE:
			return space == 0 and v is Vector3 and (v as Vector3) != Vector3.ZERO
		EfpSim.K_ROT, EfpSim.K_BANROT:
			return space == 0 and v is Basis and not (v as Basis).is_equal_approx(Basis.IDENTITY)
		EfpSim.K_RVEL:
			return v is Basis and not (v as Basis).is_equal_approx(Basis.IDENTITY)
		EfpSim.K_SPHERE:
			if space == 0:
				return true
			if v is Vector3:
				var w := v as Vector3
				return not (is_equal_approx(w.x, w.y) and is_equal_approx(w.y, w.z))
	return false

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
		if h.holder == null or not is_instance_valid(h.holder) or not h.holder.visible or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
			continue # an own simulation places itself (EfpEffect.follow_host)
		h.holder.global_transform = holder_transform(h.skel, h.bone, h.scale)
	if _qa_log_every > 0 and _frame % _qa_log_every == 0:
		_qa_log(cam)
	if EfpEffect.profile:
		EfpEffect.prof["driver"] = int(EfpEffect.prof.get("driver", 0)) + Time.get_ticks_usec() - t0
		if FrameSplit.on:
			FrameSplit.add("fx_driver", Time.get_ticks_usec() - t0)

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
		if not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
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
	if not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
		return {}
	# The effect whose particles are measured: the shared master, or the
	# host's own simulation while it runs (its particles in its anchor's space).
	var own := h.own_fx != null and is_instance_valid(h.own_fx) and h.own_fx.visible
	var fx: EfpEffect = h.own_fx if own else k.master
	if fx == null or not is_instance_valid(fx) or fx.sim == null:
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
	for d in fx._draws:
		drawn[int(d[0])] = true
	for l in fx._links:
		drawn[int(l[0])] = true
	# A shared master's particles are placed as the holders place them; an
	# own effect's are in its anchor's space already (its global transform).
	var ht := fx.global_transform if own else holder_transform(h.skel, h.bone, h.scale)
	var old := Transform3D(Basis.from_scale(Vector3.ONE * (h.scale * _uniform_scale(g.basis))), tip)
	var n := 0
	var sum := Vector3.ZERO
	var lo := INF
	var hi := -INF
	var off_max := 0.0
	var off_sum := 0.0
	var was_max := 0.0
	var was_sum := Vector3.ZERO
	for p in fx.sim.particles:
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
		"heading": rad_to_deg(atan2(g.basis.z.x, g.basis.z.z)), "own": own}

## The size of the host's own scale (round 734's review, F4): the body's height
## factor (CharacterAppearance.HEIGHT_FACTORS) reaches the particles as it did
## on the per-weapon path (EfpEffect.scale_basis on the anchor). Its magnitude
## only, the cube root of |det| (OURS); the rotation and any mirror come from
## the bone's frame (holder_transform, round 741).
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

## The cycle's choice (round 746, the review's finding 2; OURS, the budget is
## not READ): the nearest WHOLE weapons whose effects together fit
## VISIBLE_BUDGET holders show them -- every effect of a chosen weapon, so a
## weapon's seal and +8 effects come and go together, and never more than
## VISIBLE_BUDGET holders drawn. (Measured: counting 64 WEAPONS instead let 200
## Sun spears draw 128 holders and cost +8 ms a frame, r746.md.) Every other
## holder hides, and masters with none pause. No sort while everything fits;
## past it, the weapons' distances are sorted natively for a first cut at
## VISIBLE_BUDGET weapons, and only those are ranked.
func _finish_cycle() -> void:
	_cycle += 1
	# One distance per weapon (an item skeleton): its hosts share it.
	var weapon_d := {}
	var weapon_n := {}
	for i in _cand.size():
		var wsid := (_cand[i] as Host).skel.get_instance_id()
		weapon_d[wsid] = _cand_d[i]
		weapon_n[wsid] = int(weapon_n.get(wsid, 0)) + 1
	var chosen := {}
	if _cand.size() <= VISIBLE_BUDGET:
		chosen = weapon_d
	else:
		var limit := INF
		if weapon_d.size() > VISIBLE_BUDGET:
			var sorted := PackedFloat32Array(weapon_d.values())
			sorted.sort()
			limit = sorted[VISIBLE_BUDGET - 1]
		var near: Array = []
		for wsid in weapon_d:
			if float(weapon_d[wsid]) <= limit:
				near.append(wsid)
		near.sort_custom(func(a, b): return float(weapon_d[a]) < float(weapon_d[b]))
		var n := 0
		for wsid in near:
			n += int(weapon_n[wsid])
			if n > VISIBLE_BUDGET:
				break
			chosen[wsid] = true
	for k in _kinds.values():
		(k as Kind).active = 0
	var before := _shown
	_shown = []
	var world_shown: Array = []
	for i in _cand.size():
		var h: Host = _cand[i]
		if _hosts.get(h.id) != h or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
			continue
		if not chosen.has(h.skel.get_instance_id()):
			continue
		h.dist = _cand_d[i]
		h.shown_cycle = _cycle
		_shown.append(h)
		if (_kinds[h.key] as Kind).own:
			world_shown.append(h)
	# The OWN_BUDGET weapons with a world-axis effect that run every such
	# effect on its own simulation (Kind.own), a weapon's effects together.
	# Round 746's review, finding 4 (OURS): the player's own weapon first
	# (prefer_root), then the weapons that already run one, whose distance
	# counts OWN_KEEP_MARGIN less (a hysteresis, so two weapons at about the
	# same distance do not trade the slot every cycle), then the nearest.
	var own_set := {}
	var own_weapons := {}
	if not world_shown.is_empty() and OWN_BUDGET > 0:
		var rank := func(h: Host) -> float:
			if prefer_root != null and is_instance_valid(prefer_root) and prefer_root.is_ancestor_of(h.skel):
				return -1.0
			return h.dist * (1.0 - OWN_KEEP_MARGIN) if _own_prev.has(h.skel.get_instance_id()) else h.dist
		world_shown.sort_custom(func(a, b): return rank.call(a) < rank.call(b))
		for wh in world_shown:
			var wsid := (wh as Host).skel.get_instance_id()
			if not own_weapons.has(wsid):
				if own_weapons.size() >= OWN_BUDGET:
					continue
				own_weapons[wsid] = true
			own_set[(wh as Host).id] = true
	_own_prev = own_weapons
	var owns := 0
	for h in _shown:
		var k: Kind = _kinds[h.key]
		if own_set.has(h.id):
			var fresh := h.own_fx == null or not is_instance_valid(h.own_fx)
			if fresh:
				h.own_fx = _own_holder(h, k)
			elif not h.own_fx.visible:
				# Resumed after a pause: its particles are where the weapon
				# was then. Start it over, pre-rolled (finding 4).
				_preroll(h.own_fx, true)
			if h.own_fx != null:
				h.own_fx.visible = true
				h.own_fx.set_process(true)
				_own_parked.erase(h.id)
				owns += 1
				if h.holder != null and is_instance_valid(h.holder):
					h.holder.visible = false
				continue
		# Drawn through the master: only these keep it stepping (finding 6).
		k.active += 1
		_park_own(h)
		if h.holder == null or not is_instance_valid(h.holder):
			h.holder = _holder_for(k.master)
			h.skel.add_child(h.holder)
			# A holder only draws what its master simulates: no _process of
			# its own (the review, F3). After add_child, whose ready would
			# turn it back on.
			h.holder.set_process(false)
		h.holder.visible = true
	for h in before:
		if (h as Host).shown_cycle == _cycle:
			continue
		if h.holder != null and is_instance_valid(h.holder):
			h.holder.visible = false
		_park_own(h)
	# Finding 5: an own effect parked for OWN_FREE_CYCLES cycles is freed.
	for id in _own_parked.keys():
		if _cycle - int(_own_parked[id]) < OWN_FREE_CYCLES:
			continue
		_own_parked.erase(id)
		var ph: Host = _hosts.get(id)
		if ph != null and ph.own_fx != null and is_instance_valid(ph.own_fx):
			ph.own_fx.queue_free()
			ph.own_fx = null
	_cand.clear()
	_cand_d.clear()
	for key in _kinds.keys():
		var k: Kind = _kinds[key]
		k.master.set_process(k.active > 0)
		k.idle = 0 if k.active > 0 else k.idle + maxi(_frame - _cycle_frame, 1)
		if k.idle > IDLE_FRAMES and k.hosts <= 0:
			k.master.queue_free()
			_kinds.erase(key)
	stats["weapons"] = chosen.size()
	stats["own"] = owns
	stats["hosts"] = _hosts.size()
	stats["shown"] = _shown.size()
	stats["kinds"] = _kinds.size()
