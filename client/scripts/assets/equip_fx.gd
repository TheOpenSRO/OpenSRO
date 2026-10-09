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

## Round 762's review, F1: 720 units (READ, round 761: retail's
## CRTModParticle steps and draws a character's effects only while its LOD,
## the camera distance / 800 (GlobalDataManager::FUN_009c4aa0), is under the
## particle mod's 0.9 (FUN_00c43780, CRTModParticle::FUN_00c779c0). Before,
## 800 (OURS, round 734).
const MAX_DISTANCE := 720.0
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

## Round 747 (CrowdGpu, World3D sets them): a weapon's item skeleton -> its
## frame (Transform3D) while its body is drawn far on the GPU, else null; and
## the place the choice of the nearest measures it at.
static var far_frame: Callable = Callable()
static var far_origin: Callable = Callable()

static func _far(skel: Node3D):
	return far_frame.call(skel) if far_frame.is_valid() else null

## Round 762's review, F1 (OURS; World3D sets them): a ghost (CrowdGpu's body
## drawn from its kind's recipe, no nodes) carries its weapon's particles
## without being dressed. Its hosts hang from its holder node (`anchor`); the
## item skeleton's frame in the world is ghost_frame(anchor, body bone, the
## item skeleton's transform under its attachment) -- the GPU clip frame, as
## item_frame for a far dressed body (round 747) -- or null when the anchor is
## no ghost now; ghost_origin(anchor) is its place for the choice of the
## nearest (INF while its page is held or it fades out), or null.
static var ghost_frame: Callable = Callable()
static var ghost_origin: Callable = Callable()
## Round 764 (EquipFxBatch): the CrowdGpu drawing the ghosts (World3D sets
## it), whose textures the batched particles read their hosts' frames from.
static var ghost_gpu: Callable = Callable()

class Host:
	var id: String
	var skel: Skeleton3D
	var skel_id := 0
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
	## Round 762's review, F1: a ghost's host (add_ghost_host). `anchor` is
	## the ghost's holder node, `skel` the item's TEMPLATE skeleton (never in
	## a tree; its bone's pose is `pose`), `att_bone` the body bone the item
	## hangs from and `chain` the item skeleton's transform under that
	## attachment. Null anchor: a built item skeleton's host.
	var anchor: Node3D = null
	var att_bone := -1
	var chain := Transform3D()
	var pose := Transform3D()
	## The weapon it belongs to (one distance a weapon, _finish_cycle): its
	## item skeleton's id, or a ghost's "anchor id|wear".
	var wkey = 0
	## Round 764: a ghost's host drawn by EquipFxBatch -- its batch and its
	## ghost's body slot.
	var batch = null
	var batch_slot := -1
	var sel := false
	var rows := PackedFloat32Array()
	var blayout: Object = null

	## The node it hangs from: the item skeleton, or a ghost's holder.
	func node() -> Node3D:
		return anchor if anchor != null else skel

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
	## Round 762's review, F1: the archive its master is made from (a lazy
	## kind's master comes later: _make_masters), and whether it failed.
	var archive: Pk2Reader = null
	var failed := false

var particles: Pk2Reader
var _hosts: Dictionary = {}   # "skel id|bone|efp key" -> Host
## Round 762: skeleton instance id -> its hosts' ids (remove_skel).
var _by_skel: Dictionary = {}
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
## Round 762's review, F1: the hosts on ghosts (add_ghost_host).
var _ghost_hosts := 0
## Round 764: the ghosts' hosts drawn in batches (EquipFxBatch.enabled), and
## the kinds a ghost host within MAX_DISTANCE keeps stepping (kind key -> the
## cycle it was last found in).
var _batch: EquipFxBatch = null
var _batch_live := {}
## Round 764: the distances of this cycle's ghost hosts within reach, and the
## cut the last cycle found: the host_budget-th nearest (INF while fewer).
var _batch_d := PackedFloat32Array()
var _batch_cut := INF
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
	if not _kind_for(key, efp, archive):
		return
	var h := Host.new()
	h.id = id
	h.skel = skel
	h.skel_id = skel.get_instance_id()
	h.wkey = h.skel_id
	h.bone = b
	h.key = key
	h.scale = scale
	_register(h)

## The kind `key` draws through, its master made on first use. False when the
## effect does not build. Round 762's review, F1: with `lazy` (a ghost's host)
## the kind is noted and its master made later, a frame's share at a time
## (_make_masters): a ghost's weapon and shield name up to eight effect files,
## and a page's first ghosts made their masters in one frame (MEASURED: 28 ms
## of one ghost pump, 0.1-2.5 ms a master).
func _kind_for(key: String, efp: String, archive: Pk2Reader, lazy: bool = false) -> bool:
	if particles == null:
		particles = archive
	if not _kinds.has(key):
		var k := Kind.new()
		k.key = key
		k.efp = efp
		k.archive = archive
		if lazy:
			_kinds[key] = k
			_masters_due.append(key)
			return true
		if not _make_master(k):
			return false
		_kinds[key] = k
	return true

## Kinds whose master is still to be made (_kind_for's `lazy`), oldest first.
var _masters_due: Array = []
## The masters made a frame (round 762's review, F1, OURS): one at least, then
## while MASTERS_BUDGET_USEC lasts.
const MASTERS_BUDGET_USEC := 1000

func _make_masters() -> void:
	if _masters_due.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var made := 0
	while not _masters_due.is_empty() and (made == 0 or Time.get_ticks_usec() - t0 < MASTERS_BUDGET_USEC):
		var key: String = _masters_due.pop_front()
		var k: Kind = _kinds.get(key)
		if k == null or (k.master != null and is_instance_valid(k.master)) or k.failed:
			continue
		made += 1
		if not _make_master(k):
			k.failed = true
	if FrameSplit.on:
		FrameSplit.add("fx_new_masters", Time.get_ticks_usec() - t0)

## `k`'s master: one EfpEffect simulated at the origin, its own draws hidden
## (the header). False when the effect does not build.
func _make_master(k: Kind) -> bool:
	var efp := k.efp
	var archive: Pk2Reader = k.archive if k.archive != null else particles
	var qa_t0 := Time.get_ticks_usec() if FrameSplit.on else 0
	var m := EfpEffect.create(efp, archive)
	if m == null:
		return false
	var qa_t1 := Time.get_ticks_usec() if FrameSplit.on else 0
	m.loop = true
	m.auto_free = false
	m.top_level = true
	# The holders turn with their bones (round 741); the billboards are
	# built in the shader so they still face the camera.
	m.use_shared_turn()
	# Round 764: its draw buffers for the batches (the GDScript path keeps
	# them; the native one has them).
	m.keep_draw_buffers = EquipFxBatch.enabled
	# Round 763: simulated in Rust when the library has it (EfpSimNative).
	m.use_native_sim()
	if FrameSplit.on:
		print("QA EQUIPFX master %s: create %.1f ms, shared turn %.1f ms" % [efp, (qa_t1 - qa_t0) / 1000.0, (Time.get_ticks_usec() - qa_t1) / 1000.0])
	m.name = "master_%d" % _kinds.size()
	for c in m.get_children():
		if c is GeometryInstance3D:
			(c as GeometryInstance3D).visible = false
	add_child(m)
	m.global_transform = Transform3D.IDENTITY
	# Round 759: stepped by the driver (_step_masters), not its own _process.
	m.set_process(false)
	# Round 762's review (OURS): each master's 50 ms frames at its own phase
	# (the golden-ratio sequence over the masters made), so masters made
	# together -- a crowd's kinds arrive in one page -- do not all step in the
	# same rendered frame (MEASURED at 4,000 ghosts: fx_masters 3.2 ms a frame
	# on average, 12.4 at its p95, the steps bunched).
	_masters_made += 1
	if m.sim != null:
		m.sim.set_phase(EfpSim.FRAME_SEC * fposmod(float(_masters_made) * 0.6180339887, 1.0))
	k.master = m
	var tmpl := EfpEffect.template_for(efp, archive)
	k.own = tmpl != null and world_commands(tmpl) > 0
	return true

var _masters_made := 0

## Round 764: whether ghosts' hosts go to batches (made on first use).
func _batching() -> bool:
	if not EquipFxBatch.enabled:
		return false
	if _batch == null:
		_batch = EquipFxBatch.new(self)
	return true

## Round 762's review, F1 (OURS): the particles of a ghost's weapon (CrowdGpu
## draws the body from its kind's recipe; nothing is built). `row` is one of
## the recipe's particle rows (CharacterAppearance.FarRecipe.fx): its effect
## file, scale, the item's template skeleton and its bone, the body bone the
## item hangs from and the item skeleton's transform under that attachment.
## The holder is placed from ghost_frame every frame, as a far dressed body's
## from item_frame (round 747), and hangs from `anchor`, the ghost's holder.
## Taken off by remove_node(anchor) (the ghost dressed, gone or drawn again).
func add_ghost_host(anchor: Node3D, row: Dictionary, archive: Pk2Reader) -> void:
	var efp := String(row["efp"])
	var scale := float(row["scale"])
	var key := kind_key(efp, scale)
	var id := "%d|g%d|%d|%s|%s" % [anchor.get_instance_id(), int(row["wear"]), int(row["bone"]), key, str(snappedf(scale, 0.0001))]
	if _hosts.has(id) or not _kind_for(key, efp, archive, true):
		return
	var h := Host.new()
	h.id = id
	h.anchor = anchor
	h.skel = row["skel"]
	h.skel_id = anchor.get_instance_id()
	h.wkey = "%d|%d" % [h.skel_id, int(row["wear"])]
	h.bone = int(row["bone"])
	h.pose = row["pose"]
	h.att_bone = int(row["att_bone"])
	h.chain = row["chain"]
	h.key = key
	h.scale = scale
	_register(h)

func _register(h: Host) -> void:
	var id := h.id
	_hosts[id] = h
	var sid := h.skel_id
	if not _by_skel.has(sid):
		_by_skel[sid] = []
	(_by_skel[sid] as Array).append(id)
	(_kinds[h.key] as Kind).hosts += 1
	if h.anchor != null:
		_ghost_hosts += 1
		if _batching():
			_batch.add(h)
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
	remove_node(skel)

## Every host hanging from `n` (an item skeleton, or a ghost's holder: round
## 762's review, F1).
func remove_node(n: Node) -> void:
	# Round 762: by the skeleton's own list, not a pass over every host (each
	# item skeleton of a crowd leaving made one: 4,000 bodies' weapons against
	# thousands of hosts in one frame).
	var ids = _by_skel.get(n.get_instance_id())
	if ids == null:
		return
	for id in (ids as Array).duplicate():
		if _hosts.has(id):
			_drop(id)
	_by_skel.erase(n.get_instance_id())

## Round 762's review, F1: whether `n` (a ghost's holder) has hosts.
func has_node_hosts(n: Node) -> bool:
	return n != null and _by_skel.has(n.get_instance_id())

func _drop(id: String) -> void:
	var h: Host = _hosts[id]
	if h.holder != null and is_instance_valid(h.holder):
		# A ghost's holder hangs from the player's holder node, which stays:
		# taken off it now (round 762's review, F1), so the body dressed in the
		# same frame is not taken for one carrying an effect
		# (World3D._crowd_eligible) and kept near.
		if h.anchor != null and h.holder.get_parent() != null:
			h.holder.get_parent().remove_child(h.holder)
		h.holder.queue_free()
	if h.own_fx != null and is_instance_valid(h.own_fx):
		h.own_fx.queue_free()
	_own_parked.erase(id)
	if h.anchor != null:
		_ghost_hosts -= 1
		if _batch != null:
			_batch.remove(h)
	if _kinds.has(h.key):
		(_kinds[h.key] as Kind).hosts -= 1
	_hosts.erase(id)
	var sid := h.skel_id
	var list = _by_skel.get(sid)
	if list != null:
		(list as Array).erase(id)
		if (list as Array).is_empty():
			_by_skel.erase(sid)

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
			# Round 757: EfpEffect gives its nodes their bounds on the server, not
			# as a stored property (efp_effect.gd's note), and so does the holder.
			if mmi.multimesh != null:
				RenderingServer.instance_set_custom_aabb(mmi.get_instance(), EfpEffect.DRAW_AABB)
			hold.add_child(mmi)
		elif c is MeshInstance3D:
			var src := c as MeshInstance3D
			var mi := MeshInstance3D.new()
			mi.mesh = src.mesh
			mi.material_override = src.material_override
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if mi.mesh != null:
				RenderingServer.instance_set_custom_aabb(mi.get_instance(), EfpEffect.DRAW_AABB)
			hold.add_child(mi)
	return hold

func _process(_delta: float) -> void:
	_frame += 1
	_make_masters()
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
		if _frame - _cycle_frame >= _cycle_frames:
			_scan_slice(cam, _scan.size())
			_finish_cycle()
			_begin_cycle()
	var ghosts_shown := 0
	for h in _shown:
		var n: Node3D = (h as Host).node()
		if h.holder == null or not is_instance_valid(h.holder) or not h.holder.visible or not is_instance_valid(n) or not n.is_inside_tree():
			continue # an own simulation places itself (EfpEffect.follow_host)
		# A hidden weapon shows nothing until the next cycle chooses again.
		if not n.is_visible_in_tree():
			h.holder.visible = false
			continue
		if h.anchor != null:
			# A ghost's weapon (round 762's review, F1): the GPU clip frame of
			# the bone it hangs from, then the item's template bone.
			var g = ghost_frame.call(h.anchor, h.att_bone, h.chain) if ghost_frame.is_valid() else null
			if g == null:
				h.holder.visible = false
				continue
			h.holder.global_transform = place(g, h.pose, h.scale)
			ghosts_shown += 1
			continue
		# A weapon on a far body (round 747, CrowdGpu): its skeleton is not
		# posed, so its frame is the one the GPU draws the body at.
		h.holder.global_transform = holder_transform(h.skel, h.bone, h.scale, _far(h.skel))
	stats["ghost_placed"] = ghosts_shown
	if _qa_log_every > 0 and _frame % _qa_log_every == 0:
		_qa_log(cam)
	_step_masters(_delta)
	if _batch != null:
		_batch.step(ghost_gpu.call() if ghost_gpu.is_valid() else null, _kinds)
		stats["batch_hosts"] = int(_batch.stats["hosts"])
		stats["batch_draws"] = int(_batch.stats["draws"])
		stats["batch_instances"] = int(_batch.stats["instances"])
	if EfpEffect.profile:
		EfpEffect.prof["driver"] = int(EfpEffect.prof.get("driver", 0)) + Time.get_ticks_usec() - t0
		if FrameSplit.on:
			FrameSplit.add("fx_driver", Time.get_ticks_usec() - t0)

## Round 759: whether `k`'s master is stepped this frame (_step_masters): a
## shown weapon draws through it.
func steps_master(k: Kind) -> bool:
	return k.active > 0 and is_instance_valid(k.master)

## Round 759: every master a shown weapon draws (Kind.active), stepped here
## rather than in its own _process (masters do not process): the placement and
## the draws on the main thread, the simulations together on WorkerThreadPool
## (EfpSimBatch). MEASURED live before: 33 active masters, 14.8 ms a frame of
## `efp_sim` on the main thread at 15 fps (a 50 ms step about 0.33 ms each).
func _step_masters(delta: float) -> void:
	var t0 := Time.get_ticks_usec() if FrameSplit.on else 0
	var list: Array = []
	for key in _kinds:
		var k: Kind = _kinds[key]
		if k.active <= 0 or not is_instance_valid(k.master) or k.master.sim == null or k.master.is_queued_for_deletion():
			continue
		if k.master.step_pre(delta):
			list.append(k.master)
	EfpSimBatch.run(list, delta)
	for m in list:
		if is_instance_valid(m):
			(m as EfpEffect).step_post()
	if FrameSplit.on:
		FrameSplit.add("fx_masters", Time.get_ticks_usec() - t0)
		FrameSplit.add("fx_masters_calls", list.size())
		# Round 761 (QA): EfpSimBatch's ordered cap -- spawns that waited for
		# the effects before theirs and the thread time waited, the bounds'
		# thread time, and the particles alive after the batch.
		var last: Dictionary = EfpSimBatch.last
		FrameSplit.add("fx_cap_waits_calls", int(last.get("waits", 0)))
		FrameSplit.add("fx_cap_wait", int(last.get("wait_usec", 0)))
		FrameSplit.add("fx_cap_bounds", int(last.get("bounds_usec", 0)))
		# Round 763: the particles alive after the batch, GDScript's and the
		# native masters' (uncapped, counted apart: EfpSimNative.live_native).
		FrameSplit.add("fx_cap_live_calls", EfpSim.live_total + EfpSimNative.live_native)
		# Round 763's review, L2: the native batch's work (particle-steps) and
		# whether it used the pool (EfpSimNative.pool_min_work).
		FrameSplit.add("fx_batch_work_calls", int(last.get("work", 0)))
		FrameSplit.add("fx_batch_pooled_calls", 1 if bool(last.get("threaded", false)) else 0)

## Where a host's holder goes (round 741): the bone's whole frame in the world
## -- READ, CRTModParticle::FUN_00c81190 places the effect at the bone's
## matrix times the world's (`0xc811c5`..`0xc81288`, then CEFEffect::vslot_007)
## -- with its rotation (and a mirror, if the frame has one) kept, its own
## scale replaced by the row's col3/100 times the host's uniform scale. Round
## 734 placed the holder at the bone's position only, so the effect's
## SetPosition offsets (enchant_a_01: 0, -1.2 .. -4.8 along the effect's X,
## in its parent's frame, space 7) pointed along fixed world axes: the
## column of sparks beside the spear, lined up with it at one heading only.
static func holder_transform(skel: Skeleton3D, bone: int, row_scale: float, frame = null) -> Transform3D:
	var g: Transform3D = frame if frame != null else skel.global_transform
	return place(g, skel.get_bone_global_pose(bone), row_scale)

## holder_transform from the item skeleton's frame `g` and its bone's global
## pose `pose` (round 762's review, F1: a ghost's, from its template).
static func place(g: Transform3D, pose: Transform3D, row_scale: float) -> Transform3D:
	var at: Transform3D = g * pose
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
		if h.anchor != null or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
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
	if h.anchor != null or not is_instance_valid(h.skel) or not h.skel.is_inside_tree():
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
	for p in fx.sim.particle_list():
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
## Round 757 (OURS): a cycle reads at most SCAN_PER_FRAME_MAX hosts a frame,
## so it lasts RESELECT_FRAMES or, with more hosts, longer (MEASURED at 7,000
## bodies, 9,693 hosts: the 10-frame cycle scanned 970 hosts a frame, 7.7 ms of
## the driver). There the 64 nearest are chosen again about every 49 frames
## (0.8 s at 60 fps) instead of every 10.
const SCAN_PER_FRAME_MAX := 200

## Round 764 (QA): the hosts a cycle found within MAX_DISTANCE and in view
## (or ALWAYS_NEAR), before the budget's cut -- what retail would draw.
var _cand_seen := 0

func _begin_cycle() -> void:
	_cand_seen = 0
	_batch_d.clear()
	_scan = _hosts.keys()
	_scan_at = 0
	_cand.clear()
	_cand_d.clear()
	_cycle_frame = _frame
	_cycle_frames = maxi(RESELECT_FRAMES, ceili(float(_scan.size()) / float(SCAN_PER_FRAME_MAX)))
	_per_frame = ceili(float(_scan.size()) / float(maxi(_cycle_frames, 1)))

var _cycle_frames := RESELECT_FRAMES

## Measures up to `count` more hosts of this cycle: a host is a candidate when
## valid, drawn, and in the view within MAX_DISTANCE -- or within ALWAYS_NEAR
## of the camera, in view or not.
func _scan_slice(cam: Camera3D, count: int) -> void:
	var end := mini(_scan_at + count, _scan.size())
	var from := cam.global_position if cam != null else Vector3.ZERO
	# Round 757: the frustum's planes once a slice (Camera3D.is_position_in_frustum
	# builds them again on every call), and the cheap tests first: the distance
	# culls most of a big crowd before the walk up the tree is_visible_in_tree
	# makes.
	var planes: Array = cam.get_frustum() if cam != null else []
	var have_planes := planes.size() == 6
	# Round 764: the batches' CrowdGpu, once a slice.
	var gpu = ghost_gpu.call() if _batch != null and ghost_gpu.is_valid() else null
	while _scan_at < end:
		var id: String = _scan[_scan_at]
		_scan_at += 1
		var h: Host = _hosts.get(id)
		if h == null:
			continue
		var n := h.node()
		if not is_instance_valid(n) or n.is_queued_for_deletion():
			_drop(id)
			continue
		if _paused or not n.is_inside_tree():
			continue
		var d := 0.0
		if h.anchor != null:
			# A ghost's weapon (round 762's review, F1): its body's place, null
			# once it is no ghost (World3D takes its hosts off then).
			var go = ghost_origin.call(h.anchor) if ghost_origin.is_valid() else null
			if go == null:
				continue
			if _batch != null:
				# Round 764: drawn by its batch whatever the view: among the
				# EquipFxBatch.host_budget nearest within reach, in any
				# direction (the last cycle's distance cut, _batch_cut), so
				# turning the camera changes nothing; its kind steps while one
				# is drawn.
				var gd := from.distance_to(go) if cam != null else 0.0
				if is_inf(gd) or is_nan(gd):
					# Held in its page or fading out: the shader draws none
					# then; kept as chosen, so it shows with its reveal.
					continue
				var sel := gd <= MAX_DISTANCE and gd <= _batch_cut
				if gd <= MAX_DISTANCE:
					_batch_d.append(gd)
					_cand_seen += 1
				if sel:
					_batch_live[h.key] = _cycle + 1
				_batch.select(h, sel, gpu)
				continue
			if cam != null:
				d = from.distance_to(go)
				if d > MAX_DISTANCE:
					continue
				if d > ALWAYS_NEAR:
					if have_planes:
						var inside_g := true
						for pl in planes:
							if (pl as Plane).is_point_over(go):
								inside_g = false
								break
						if not inside_g:
							continue
					elif not cam.is_position_in_frustum(go):
						continue
		elif cam != null:
			var p: Vector3
			# A far body's weapon (round 747): its body's place.
			var o = far_origin.call(h.skel) if far_origin.is_valid() else null
			p = o if o != null else h.skel.global_position
			d = from.distance_to(p)
			if d > ALWAYS_NEAR:
				if d > MAX_DISTANCE:
					continue
				if have_planes:
					var inside := true
					for pl in planes:
						if (pl as Plane).is_point_over(p):
							inside = false
							break
					if not inside:
						continue
				elif not cam.is_position_in_frustum(p):
					continue
		if not n.is_visible_in_tree():
			continue
		_cand_seen += 1
		_cand.append(h)
		_cand_d.append(d)
		if _cand.size() >= CAND_PRUNE_AT:
			_prune_candidates()

## Round 757: the candidates a cycle keeps. _finish_cycle shows the nearest
## whole weapons whose hosts fit VISIBLE_BUDGET, so every host it can show is
## among the VISIBLE_BUDGET nearest hosts (a weapon's hosts share one
## distance). The scan keeps the list short: past CAND_PRUNE_AT it drops every
## host farther than the VISIBLE_BUDGET-th nearest (ties kept, so a weapon is
## never cut in two). MEASURED at 7,000 bodies: about 9,000 of 9,693 hosts are
## candidates, and the cycle's end walked all of them.
const CAND_PRUNE_AT := VISIBLE_BUDGET * 4

func _prune_candidates() -> void:
	var sorted := _cand_d.duplicate()
	sorted.sort()
	var cut := sorted[mini(VISIBLE_BUDGET, sorted.size()) - 1]
	var keep: Array = []
	var keep_d := PackedFloat32Array()
	for i in _cand.size():
		if _cand_d[i] <= cut:
			keep.append(_cand[i])
			keep_d.append(_cand_d[i])
	_cand = keep
	_cand_d = keep_d

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
		# A weapon freed since this cycle's scan measured it (a body freed
		# outright, not queued): skipped here as in the loop below (round
		# 748, MEASURED in the review's stress: 459-667 SCRIPT ERRORs a run).
		if not is_instance_valid((_cand[i] as Host).node()):
			continue
		var wsid = (_cand[i] as Host).wkey
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
	# Round 764: the next cycle's cut -- the host_budget-th nearest ghost
	# host within reach, INF while there are fewer (every one is drawn, as
	# retail draws every character within 720).
	if _batch != null:
		var budget := EquipFxBatch.host_budget
		if budget > 0 and _batch_d.size() > budget:
			_batch_d.sort()
			_batch_cut = _batch_d[budget - 1]
		else:
			_batch_cut = INF
		stats["batch_cut"] = _batch_cut
	# Round 764: a kind a batch draws within reach keeps stepping.
	for key in _batch_live.keys():
		if int(_batch_live[key]) < _cycle:
			_batch_live.erase(key)
		elif _kinds.has(key):
			(_kinds[key] as Kind).active += 1
	var before := _shown
	_shown = []
	var world_shown: Array = []
	for i in _cand.size():
		var h: Host = _cand[i]
		if _hosts.get(h.id) != h or not is_instance_valid(h.node()) or not h.node().is_inside_tree():
			continue
		if not chosen.has(h.wkey):
			continue
		# A kind whose master is still to be made (round 762's review, F1)
		# shows nothing yet.
		var hk: Kind = _kinds.get(h.key)
		if hk == null or hk.master == null or not is_instance_valid(hk.master):
			continue
		h.dist = _cand_d[i]
		h.shown_cycle = _cycle
		_shown.append(h)
		# A far body's weapon draws the shared master (round 747): an own
		# simulation follows the skeleton, which is not posed while far; nor
		# has a ghost's (round 762's review, F1) a posed skeleton.
		if h.anchor == null and (_kinds[h.key] as Kind).own and _far(h.skel) == null:
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
			h.node().add_child(h.holder)
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
		k.idle = 0 if k.active > 0 else k.idle + maxi(_frame - _cycle_frame, 1)
		if k.idle > IDLE_FRAMES and k.hosts <= 0:
			if k.master != null and is_instance_valid(k.master):
				k.master.queue_free()
			_kinds.erase(key)
	stats["in_view"] = _cand_seen
	stats["batch_live"] = _batch_live.size()
	stats["weapons"] = chosen.size()
	stats["own"] = owns
	stats["hosts"] = _hosts.size()
	stats["shown"] = _shown.size()
	stats["kinds"] = _kinds.size()
	# Round 762's review, F1 (QA): the shown holders on ghosts, and the
	# farthest of them from the camera.
	var gs := 0
	var gd := 0.0
	for h in _shown:
		if (h as Host).anchor != null:
			gs += 1
			gd = maxf(gd, (h as Host).dist)
	stats["ghost_shown"] = gs
	stats["ghost_hosts"] = _ghost_hosts
	stats["ghost_shown_far"] = gd
