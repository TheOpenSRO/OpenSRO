extends RefCounted
class_name WorldAmbientFx

## Every placed map object's `ambient` particle effects (round 786): the
## fountains' sprays and splashes, the waterfalls' mist and foam, the
## lanterns, burners and torches -- played as the original plays them.
## docs/protocol/teleport_effects.md has the mechanism; round 720 played it
## for the teleport structures only (AmbientParticles), round 774 for the
## dungeons, and this for every other placed object.
##
## READ (sro_client.exe):
## - Which effects: the entries of a `.bsr`'s mod set named `ambient`
##   (ModPalette::FUN_00c0b060 gives it set kind 2; FxModManager::
##   FUN_00c7fa40 routes kind 2 into the palette's own slot, the set an
##   object plays with no clip running -- AmbientParticles has the
##   addresses). Every placed object's compound runs them: the factory builds
##   CCompChar / CCompBldg / CCompSimple for every object type, all sharing
##   the update and draw slots (BSR_FORMAT.md, "How a map object animates"),
##   and the slot that ends in the ambient collector is shared too -- slot 27
##   of all four compound vtables (0xc306c0) jumps to CCompChar::FUN_00c46ab0
##   at 0xc307da, which takes the palette's `ambient` slot at 0xc46b26.
## - The LOD gate (0xc43780: the mod's +0x3c, 0.9, against the host's LOD
##   +0x7c) passes for a placed object: its LOD starts at 0.0 -- slot 73 of
##   every compound type (0xc2edc0, CCompChar / CCompBldg / CCompSimple /
##   CCompoundObj), which the object build calls (0xc331ae, in
##   ResourceMgr::FUN_00c32e50), stores fldz into +0x7c (asm
##   0xc2f056..0xc2f05e) -- and only the game-object LOD change writes it
##   after (CCompChar::FUN_00c25620, slot 2; its one caller
##   GlobalDataManager::FUN_009c4aa0). Round 720 had it INFERRED.
## - When an object runs (SWorld::vslot_004, 0xa2cf60, the decompile's
##   lines 270-390): only the sectors the view touches are visited (their
##   +0xba2 flag). A sector's +0x14 list (`.o2` lists[1]) is tested against
##   `DAT_00ec54b0 - 480.0` (MapAnimation.object_range, 2020 by default) and
##   its +0x24 list (`.o2` lists[2]) against **480** (the float at
##   0xde4f64, read from the exe's bytes) -- and the +0x24 list only in the
##   first 9 sectors of the frame's sector list (`if (iVar15 < 9)`). An
##   object is in range while its camera distance less its radius is below
##   the range (SWorld::FUN_00a38a50); its update (and so its mods' effects)
##   runs only then, and it is drawn only then (Map::FUN_00a1e530). The
##   effects draw as their object draws (CRTModParticle::FUN_00c81450).
##   MEASURED (client/tools/water_census.gd): the lamps and burners are
##   lists[2] objects (`cj_lamp01` 40 of 40, `alex_burner` 85 of 85), the
##   waterfalls and fountains lists[1] (`cj_waterfall02` 0 of 94 in lists[2]).
##
## INFERRED: the first 9 sectors of the frame's list are the 3 x 3 around
## the camera's sector (the list is built nearest first); here a lists[2]
## host plays only while its sector's centre is within 1.5 sectors of the
## camera on both axes (NEAR_SECTORS), which is that block.
##
## OURS:
## - An effect is built the first time its host comes in range, not with the
##   object (the original's runtime exists from the object's creation but is
##   not updated until then, so the first frames look the same), and kept
##   until the host goes. Its files are decoded on WorkerThreadPool first
##   (EfpEffect.preload_paths), and at most BUILD_BUDGET_USEC of building is
##   done a frame.
## - "A sector listing it is in view" is the object's own box (its meshes and
##   its effects' cull boxes) against the frustum: the `.o2` lists a big
##   object in every sector it reaches (MAPO2_FORMAT.md, round 643), so the
##   original visits it while any of them is in view -- Alexandria's library
##   (3,445 units across) stands with its origin 800 units from its fountain.
##   "Drawn" is Godot's own culling of each draw. A host out of range is
##   hidden and its effects paused; in range but out of view, its effects are
##   paused and left drawn (Godot culls them), as the original leaves an
##   unvisited sector's objects as they were.
## - The range is decided every RETEST_MS, not every frame (the original's
##   per frame): a host crosses the edge up to that late.
## - The effects step once a rendered frame as one batch (EfpSimBatch, in Rust
##   when the library is there), as the dungeons' do (round 774).
## - The teleport structures and walk-in portals keep round 720's / 774's
##   path (World3D._attach_gate_effects, always running); a host one of the
##   two paths has built is skipped by the other.

## The +0x24 list's range (READ, the float at 0xde4f64).
const NEAR_RANGE := 480.0
## How far a lists[2] host's sector centre may lie from the camera, per axis,
## and still be one of the 9 nearest sectors (INFERRED, above): 1.5 sectors.
const NEAR_SECTORS := 1.5
## How often the hosts' range is decided (OURS).
const RETEST_MS := 100
## How long the effects built in one frame may take (OURS).
const BUILD_BUDGET_USEC := 2000
## The meta a host's node carries once its effects are built here.
const META_BUILT := "opensro_world_fx"
## World3D._attach_gate_effects' mark (its META_GATE_EFFECTS).
const META_GATE := "gate_effects"

## One host: a node carrying `ambient` entries (a placed object or a compound
## child of one), where it stands, and its effects once built.
class Host:
	extends RefCounted
	var node: Node3D
	var entries: Array = []
	var paths := PackedStringArray()
	var origin := Vector3.ZERO
	var radius := 0.0
	var near := false
	## In range (drawn), and in range in a sector in view.
	var on := false
	var seen := false
	## Its meshes' world box, and with its effects' cull boxes once built
	## (view_box_of): the visit test and the per-frame view test.
	var box := AABB()
	var view_box := AABB()
	var built := false
	var asked := false
	var effects: Array = []
	var sector: Sector = null

## The hosts of one `.o2` sector cell, with the bounds the range decision
## skips whole sectors by (as MapAnimation.Driver's).
class Sector:
	extends RefCounted
	var centre := Vector3.ZERO
	var hosts: Array = []
	var rho := 0.0
	var rmax := 0.0
	## Every host off as of the last decision.
	var quiet := true

## Where the effects come from, and the glow pass they join.
var particles: Pk2Reader = null
var ambient: AmbientParticles = null
## Whether `ambient`'s Light Effect is to be set before a build (World3D).
var light_effect := true

var _sectors := {}
var _count := 0
var _next_ms := 0
var _changed := true
var _last_eye := Vector3.INF
## The hosts in range in a sector in view, as of the last decision, and the
## effects stepping this frame (theirs whose draw box is in view).
var _seen: Array = []
var _stepping: Array = []
## Hosts waiting to be built, in the order they came in range.
var _to_build: Array = []

## For the QA line: hosts, in range, stepping, built, effects stepping, and
## the last frame's cost (us): the decision, the build, the step.
var hosts_on := 0
var hosts_built := 0
var effects_built := 0
var decide_usec := 0
var build_usec := 0
var step_usec := 0
## The step's split (us): placement, simulation, draws.
var step_split := Vector3i.ZERO

func size() -> int:
	return _count

## Registers `root` (a placed object, in the tree at its final transform) and
## its compound children that carry `ambient` entries (ObjectLoader keeps them
## under AmbientParticles.META_ENTRIES). `near`: the placement came from
## `.o2` lists[2] (the 480 range). Returns how many hosts were added.
func add(root: Node3D, near: bool) -> int:
	var added := 0
	var nodes: Array = [root]
	for child in root.get_children():
		if child is Node3D and not (child is MeshInstance3D):
			nodes.append(child)
	for n_v in nodes:
		var node := n_v as Node3D
		if not node.has_meta(AmbientParticles.META_ENTRIES):
			continue
		var entries: Array = node.get_meta(AmbientParticles.META_ENTRIES)
		var paths := PackedStringArray()
		for entries_v in entries:
			for e_v in entries_v:
				var e := e_v as BsrReader.ParticleEntry
				if e != null and e.efp != "" and AmbientParticles.shows(e) and not paths.has(e.efp):
					paths.append(e.efp)
		if paths.is_empty():
			continue
		var h := Host.new()
		h.node = node
		h.entries = entries
		h.paths = paths
		h.near = near
		h.origin = root.global_position
		h.radius = object_radius(root)
		h.box = AmbientParticles._host_box(root)
		h.view_box = h.box
		var centre := sector_centre(root)
		var key := "%d:%d" % [roundi(centre.x), roundi(centre.z)]
		var s: Sector = _sectors.get(key)
		if s == null:
			s = Sector.new()
			s.centre = centre
			_sectors[key] = s
		h.sector = s
		s.hosts.append(h)
		s.rho = maxf(s.rho, Vector2(h.origin.x - centre.x, h.origin.z - centre.z).length())
		s.rmax = maxf(s.rmax, h.radius)
		s.quiet = false
		added += 1
	_count += added
	if added > 0:
		_changed = true
	return added

## Half the X-Z diagonal of a placed object's mesh bounds, in its own frame,
## times its scale (READ: the radius SWorld::FUN_00a38a50's test takes, asm
## 0xa389f0, as MapAnimation's).
static func object_radius(root: Node3D) -> float:
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var b := mi.transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		return 0.0
	var scale := absf(root.global_transform.basis.get_scale().x) if root.is_inside_tree() else 1.0
	return Vector2(box.size.x * 0.5, box.size.z * 0.5).length() * scale

## The world centre of the `.o2` sector cell `root` stands in: its parent's
## frame is its region's (MapAnimation.sector_of).
static func sector_centre(root: Node3D) -> Vector3:
	var parent := root.get_parent() as Node3D
	var to_world := parent.global_transform if parent != null and parent.is_inside_tree() else Transform3D.IDENTITY
	return MapAnimation.sector_of(root.position, to_world)[1]

## Whether a host is in range of `eye` (READ, the class comment): its camera
## distance less its radius below the range -- 480 and one of the 3 x 3
## sectors around the camera for a lists[2] host, the object range for the
## rest.
static func in_range(origin: Vector3, radius: float, near: bool, sector_centre_at: Vector3, eye: Vector3,
		far_range: float) -> bool:
	if near:
		var reach := NEAR_SECTORS * MapAnimation.SECTOR_SIZE
		if absf(sector_centre_at.x - eye.x) >= reach or absf(sector_centre_at.z - eye.z) >= reach:
			return false
		return origin.distance_to(eye) - radius < NEAR_RANGE
	return origin.distance_to(eye) - radius < far_range

## Drops everything (a zone change: the hosts go with their regions).
func reset() -> void:
	_sectors.clear()
	_seen.clear()
	_stepping.clear()
	_to_build.clear()
	_count = 0
	_changed = true
	hosts_on = 0
	hosts_built = 0
	effects_built = 0

## One rendered frame: the range decided every RETEST_MS (or at once when
## hosts came or the camera jumped), builds within the budget, and the
## stepping effects stepped as one batch.
func tick(delta: float, eye: Vector3, planes: Array, now_ms: int) -> void:
	if _count == 0:
		return
	var t0 := Time.get_ticks_usec()
	if _changed or now_ms >= _next_ms or eye.distance_to(_last_eye) > MapAnimation.SECTOR_SIZE:
		_decide(eye, planes)
		_next_ms = now_ms + RETEST_MS
		_changed = false
		_last_eye = eye
	_choose_stepping(planes)
	var t1 := Time.get_ticks_usec()
	decide_usec = t1 - t0
	_build_some(t1)
	var t2 := Time.get_ticks_usec()
	build_usec = t2 - t1
	_step(delta)
	step_usec = Time.get_ticks_usec() - t2

## The range decision for every sector that could hold a host in range.
func _decide(eye: Vector3, planes: Array) -> void:
	var far_range := MapAnimation.object_range
	var reach := maxf(far_range, NEAR_RANGE) + MapAnimation.BOUND_MARGIN
	var dead := false
	var seen_hosts: Array = []
	var on_count := 0
	for key in _sectors:
		var s: Sector = _sectors[key]
		var d := Vector2(s.centre.x - eye.x, s.centre.z - eye.z).length()
		# 3D distance >= the X-Z one: every host of the sector is out of range.
		if s.quiet and d - s.rho - s.rmax >= reach:
			continue
		var quiet := true
		for h_v in s.hosts:
			var h := h_v as Host
			if not is_instance_valid(h.node) or h.node.is_queued_for_deletion():
				dead = true
				continue
			# An unvisited sector's objects keep their state (READ): only
			# their stepping stops.
			var seen := box_in_view(h.view_box, planes)
			var on := h.on
			if seen:
				on = in_range(h.origin, h.radius, h.near, s.centre, eye, far_range)
			if on:
				quiet = false
				on_count += 1
			_set_on(h, on, seen and on)
			if h.seen:
				seen_hosts.append(h)
			if not h.effects.is_empty():
				h.view_box = h.box.merge(view_box_of(h.effects))
		s.quiet = quiet
	_seen = seen_hosts
	hosts_on = on_count
	if dead:
		_prune()

func _set_on(h: Host, on: bool, seen: bool) -> void:
	if on and not h.built and not h.asked:
		h.asked = true
		_to_build.append(h)
		EfpEffect.preload_paths(h.paths, particles)
	h.on = on
	h.seen = seen
	for fx_v in h.effects:
		if not is_instance_valid(fx_v):
			continue
		var fx := fx_v as EfpEffect
		fx.culled = not on
		# A glow shows by its own fade (EfpEffect.set_glow_alpha): kept hidden
		# while culled, left to the glow pass once back (as the dungeons').
		var shown := on and (not fx._glow_on or fx._glow_alpha > 0)
		if fx.visible != shown:
			fx.visible = shown

## Builds the waiting hosts whose files are decoded, within the budget.
func _build_some(start_usec: int) -> void:
	if _to_build.is_empty() or ambient == null or (particles == null and not AmbientParticles.effect_factory.is_valid()):
		return
	var waiting: Array = []
	var i := 0
	while i < _to_build.size():
		var h := _to_build[i] as Host
		i += 1
		if not is_instance_valid(h.node) or h.node.is_queued_for_deletion():
			continue
		if Time.get_ticks_usec() - start_usec > BUILD_BUDGET_USEC or not _ready(h):
			waiting.append(h)
			continue
		_build(h)
	_to_build = waiting

static func _ready(h: Host) -> bool:
	for p in h.paths:
		if not EfpEffect.has_template(p) or EfpEffect.is_preloading(p):
			return false
	return true

func _build(h: Host) -> void:
	h.built = true
	if h.node.has_meta(META_GATE):
		# Round 720's path plays it already (always running).
		return
	h.node.set_meta(META_BUILT, true)
	ambient.set_light_effect(light_effect)
	var animated := h.node.has_meta(MapAnimation.META_ANIMATED) or (h.node.get_parent() != null and h.node.get_parent().has_meta(MapAnimation.META_ANIMATED))
	for fx_v in ambient.attach(h.node, h.entries, particles):
		var fx := fx_v as EfpEffect
		# Stepped by _step as a batch, not by its own _process.
		fx.process_mode = Node.PROCESS_MODE_DISABLED
		# A still object's effects are placed once (round 774); an animated
		# one's may follow a bone.
		fx.static_host = not animated
		fx.use_native_sim()
		h.effects.append(fx)
		effects_built += 1
	if not h.effects.is_empty():
		h.view_box = h.box.merge(view_box_of(h.effects))
	hosts_built += 1
	_set_on(h, h.on, h.seen)

## Every frame: of the hosts in range in a sector in view, the effects of
## those whose draw box is in the view step (OURS: an effect Godot does not
## draw -- its draws cull by the same box -- changes nothing seen, and resumes
## where it stood when it comes into view).
func _choose_stepping(planes: Array) -> void:
	_stepping.clear()
	for h_v in _seen:
		var h := h_v as Host
		if h.effects.is_empty() or not box_in_view(view_box_of(h.effects), planes):
			continue
		for fx_v in h.effects:
			if is_instance_valid(fx_v):
				_stepping.append(fx_v)

## Where a host's effects draw, in the world: each draw's own cull box
## (EfpEffect._draw_boxes -- DRAW_AABB grown to hold its particles, the box
## Godot culls it by) through its effect's transform, merged.
static func view_box_of(effects: Array) -> AABB:
	var out := AABB()
	var first := true
	for fx_v in effects:
		if not is_instance_valid(fx_v):
			continue
		var fx := fx_v as EfpEffect
		var xf := fx.global_transform if fx.is_inside_tree() else Transform3D.IDENTITY
		var boxes: Array = fx._draw_boxes if not fx._draw_boxes.is_empty() else [EfpEffect.DRAW_AABB]
		for b_v in boxes:
			var b: AABB = xf * (b_v as AABB)
			out = b if first else out.merge(b)
			first = false
	return out

## Whether an AABB reaches inside every frustum plane (Camera3D.get_frustum:
## normals outward): its corner nearest each plane's inside is not outside.
## Empty `planes` passes.
static func box_in_view(box: AABB, planes: Array) -> bool:
	for p_v in planes:
		var p := p_v as Plane
		var c := box.position
		if p.normal.x < 0.0:
			c.x += box.size.x
		if p.normal.y < 0.0:
			c.y += box.size.y
		if p.normal.z < 0.0:
			c.z += box.size.z
		if p.distance_to(c) > 0.0:
			return false
	return true

## The stepping effects, as World3D._step_dungeon_effects steps a dungeon's.
func _step(delta: float) -> void:
	if _stepping.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var list: Array = []
	for fx_v in _stepping:
		if not is_instance_valid(fx_v):
			continue
		var fx := fx_v as EfpEffect
		if fx.sim != null and fx.step_pre(delta):
			list.append(fx)
	var t1 := Time.get_ticks_usec()
	EfpSimBatch.run(list, delta)
	var t2 := Time.get_ticks_usec()
	for fx_v in list:
		if is_instance_valid(fx_v):
			(fx_v as EfpEffect).step_post()
	step_split = Vector3i(t1 - t0, t2 - t1, Time.get_ticks_usec() - t2)

## Hosts whose node has gone (a region streamed out) leave.
func _prune() -> void:
	for key in _sectors.keys():
		var s: Sector = _sectors[key]
		var keep: Array = []
		for h_v in s.hosts:
			var h := h_v as Host
			if is_instance_valid(h.node) and not h.node.is_queued_for_deletion():
				keep.append(h)
		_count -= s.hosts.size() - keep.size()
		s.hosts = keep
		if keep.is_empty():
			_sectors.erase(key)

## The hosts (tests, the QA log).
func hosts() -> Array:
	var out: Array = []
	for key in _sectors:
		out.append_array((_sectors[key] as Sector).hosts)
	return out

## Every effect stepping this frame (tests).
func stepping() -> Array:
	return _stepping

## The QA line.
func describe() -> String:
	var names := {}
	for fx_v in _stepping:
		if is_instance_valid(fx_v):
			var k := String((fx_v as EfpEffect).path).get_file()
			names[k] = int(names.get(k, 0)) + 1
	return "%d host(s) in %d sector(s), %d in range, %d built (%d effects), %d effects stepping %s, waiting %d; decide %d us, build %d us, step %d us (place %d, sim %d, draw %d)" % [
		_count, _sectors.size(), hosts_on, hosts_built, effects_built, _stepping.size(), str(names), _to_build.size(),
		decide_usec, build_usec, step_usec, step_split.x, step_split.y, step_split.z]
