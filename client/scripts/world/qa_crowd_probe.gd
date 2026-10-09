extends Node
class_name QaCrowdProbe

## QA only (round 736): the crowd's cost split. QaLineup spawns N other-player
## bodies through World3D._spawn_or_update_other (the path a server's
## OpEntityEntered takes); this node then steps through a list of switches, one
## at a time, and prints one `QA CROWD` line per step: the frame time and what
## the engine says the frame went on, with that one part of every lineup body
## switched off. Never runs in play: QaLineup makes it only when
## OPENSRO_QA_CROWD_STEPS is set.
##
##   OPENSRO_QA_CROWD_STEPS="base,pose,sound,mesh,labels,collide,fx,shadow,
##                           blobs,overlay,run,move,gone,base"
##   OPENSRO_QA_CROWD_SECONDS=<s>    each step's length (6); its first SETTLE
##                                   seconds are not measured
##   OPENSRO_QA_CROWD_QUIT=1         quit after the last step
##   OPENSRO_QA_CROWD_DELAY=<s>      wait before the first step (4: the bodies'
##                                   2 s appear fade and the build's hitch pass)
##
## Round 756: before the arrival line, `QA CROWD visible` -- the frames and
## seconds from the first packet until every lineup body was drawn (dressed,
## or a CrowdGpu ghost), their worst frame and how many were over 100 ms --
## and with QaLineup's walk-up one `QA CROWD page` line per block's group
## spawn (until its last body was drawn). The arrival line itself still runs
## until the last body is dressed.
##
## The switches (each applies to the lineup bodies only, unless said):
##   base     nothing off
##   pose     no clip posed (World3D's _qa_split_off "pose": the player and the
##            NPCs too -- a few dozen bodies, the same in every step)
##   sound    no clip sound track advanced (the same caveat)
##   mesh     every MeshInstance3D of the bodies hidden (still posed)
##   labels   the name plates off every layer
##   collide  the click bodies out of the tree
##   fx       the EquipFx driver stopped and its holders hidden
##   shadow   no body casts a shadow-map shadow (only shows under Detail)
##   blobs    the bodies out of CharacterBlobs' group (Circle's ten nearest)
##   overlay  the OverlayView SubViewport (the plates' second render) stopped
##            -- every overlay, not the bodies' only
##   run      every body plays its run loop in place (a different clip)
##   move     every body walks to a new spot within 8 units every second
##   net      every body sent a position packet once a second (OPENSRO_QA_CROWD_NET_RATE
##            a body a second, 1; `net20` sends 20 a body a second), through NetClient's own dispatch: the client's
##            share of a moving crowd's traffic (decode, handler, turn, walk)
##   dest     (round 749) as net, but each packet is retail's 0xB021 to a spot
##            within 8 units of the body's home: the walk is OtherWalk's leg
##            (`dest20`: 20 a body a second)
##   away     the camera turned 180 degrees: the crowd behind it, none in view
##            (what an off-screen crowd costs)
##   gone     every body out of the tree (kept in memory): the scene without them
##   nodraw   mesh + labels + fx + blobs + overlay together
##   ab       (round 747) the same frame drawn with A5 on, then off: the clip,
##            glow and texture clocks held, EquipFx's particles hidden, each
##            frame saved to OPENSRO_QA_CROWD_SHOTS (ab_<n>_gpu.png, then
##            ab_<n>_gpu2.png on the same path as many frames later -- the
##            noise floor -- then ab_<n>_near.png)
##            with the near and far bodies' screen boxes printed (`QA CROWD ab`)
##            for client/tools/frame_ab.py
##   anim=<s> (round 738) CrowdAnim's switches for the step, back on after it:
##            "1" A1 (pose only what is in view), "i" the indexed pose, "3" A3
##            (baked poses), "4" A4 (the far bodies' LOD); "anim=-" all off,
##            which poses another player exactly as before the round. The
##            skins (A2) are the boot's (OPENSRO_QA_CROWD_SKINS=own: per piece)
##   rezone   (round 760) a real zone change to OPENSRO_QA_REZONE (Hotan) and
##            back at the step's end, the crowd leaving and arriving again
##   leave    (round 762) every lineup body leaves in one call, as a group
##            despawn takes them (World3D._on_entity_left each); kept
##   back     (round 762) the kept bodies arrive again as one group spawn
##            (bracketed), and a `QA CROWD back visible` line when every one
##            is drawn
##   half     (round 762's review) the east half of the lineup (x over the
##            median) leaves as one group despawn; kept for `cross`
##   cross    (round 762's review, F4) a walk across a block line: the bodies
##            still here leave as one group despawn and the kept ones arrive as
##            one group spawn, in one batch (the despawn read first, then the
##            spawn, as NetClient reads them), and a `QA CROWD back visible`
##            line when every arrival is drawn
##   walk=<dx>/<dz>, deck=<dx>/<dz>  (round 762) a ground (or deck) click that
##            far from the player at the step's start (World3D._qa_click): the
##            live walk out of the crowd's blocks and back
##
## Round 762: OPENSRO_QA_FRAME_LOG=<path> writes one line a frame from the
## probe's start (the clock, the frame's ms, the step, the bodies held, not
## drawn, ghosts, far, to dress, fading, held in a page, departures queued and
## to free, the bytes and packets received, and the frame's FrameSplit timers
## in FRAME_LOG_SPLIT): the arrival and the departure frame by frame.
##
## Round 759 (the live crowd): with OPENSRO_QA_LINEUP=none QaLineup makes the
## probe over the SERVER's other players (`live`): it waits
## OPENSRO_QA_CROWD_LIVE_WAIT seconds (90) for them to arrive and dress, then
## takes every other player then in the world as its bodies and runs the steps.
## OPENSRO_QA_CROWD_PERSEC=1 (on in live mode) prints one `QA LIVE` line a
## second from the start: the frames, their mean / worst ms, the engine's
## monitors, the frame's phases and the received packets (FrameSplit), the
## crowd's far groups (CrowdGpu.batch_census), EquipFx and the plates.

const SETTLE := 1.5
## Round 757: with the render on its own thread, the RenderingServer getters are
## read one frame in this many (FrameSplit.render_threaded).
const RS_SAMPLE_EVERY := 30
var _threaded := FrameSplit.render_threaded()

var world: Node
var bodies: Array = []        # [{id, node}]
var steps: PackedStringArray = PackedStringArray()
var seconds := 6.0
var quit := false
var delay := 4.0

var _i := -1
var _t := 0.0
var _on := false
var _acc := {}
var _last_us := 0
var _frame_ms: PackedFloat32Array = PackedFloat32Array()
var _removed: Dictionary = {}  # node -> [parent, child] for collide / gone
var _homes: Dictionary = {}    # id -> Vector3
var _hidden_meshes: Array = []  # the meshes the mesh switch hid
var _shadowed: Array = []  # [mesh, its cast_shadow] the shadow switch turned off
var _move_t := 0.0
var _rng := RandomNumberGenerator.new()
var _net_due := 0.0
var _net_next := 0
var _net_us := 0
var _net_sent := 0
var net_rate := 1.0
var _split: FrameSplit = null
var _split_at: Dictionary = {}
var _arrival_split_at: Dictionary = {}
var _arrival_prof_at: Dictionary = {}
var _prof_at: Dictionary = {}
## The switches the boot started with (CrowdAnim.switches()), given back after
## each `anim=` step (round 747: "5" is A5, CrowdGpu).
var _boot_switches := ""

## Round 759: the server's crowd (QaLineup "none"), not a lineup.
var live := false
var _live_wait := 90.0
var _live_t := 0.0
var _persec := false
var _ps_last_us := 0
var _ps_prev_us := 0
var _ps_frames := 0
var _ps_max_ms := 0.0
var _ps_sum := {}
var _ps_split := {}
var _ps_ops := {}
var _ps_n := 0

static func wanted() -> bool:
	return OS.get_environment("OPENSRO_QA_CROWD_STEPS") != ""

## Round 739: the arrival, measured from the spawn (QaLineup's start) until
## the last body is dressed (World3D._pump_other_builds): one `QA CROWD
## arrival` line with every frame's wall time in it -- the worst, the p95, how
## many were over 100 ms -- before the census and the steps.
var _arriving := true
var _arrival_last_us := 0
var _arrival_start_us := 0
var _arrival_ms: PackedFloat32Array = PackedFloat32Array()
var _arrival_n := 0
## Round 756: every lineup id, and when each was first drawn -- dressed, or a
## ghost (CrowdGpu.add_ghost) -- from the first packet: `visible_s` in the
## arrival line is the moment the last one was; `QA CROWD page` lines the
## same per page (QaLineup's walk-up: one group spawn per block).
var _ids: Array = []
var _shown := {}
var _visible_us := -1
var _vis_at := 0
var _visible_frames := 0
## Each frame until then: "<frame ms>/<bodies drawn by its end>".
var _visible_trace := PackedStringArray()
## [ids, start usec, frames, worst ms, done usec (-1 until every id is drawn)]
var _pages: Array = []

## Round 756 (QaLineup's walk-up): a page of `ids` was just spawned.
func page_started(ids: Array) -> void:
	_pages.append([ids, Time.get_ticks_usec(), 0, 0.0, -1])

## Whether lineup body `id` is drawn: dressed (no longer waiting), or a
## ghost. Read through `get`, so a base without ghosts measures too.
func _drawn(id: int) -> bool:
	var node = _bodies_now.get(id)
	if node == null or not is_instance_valid(node):
		return false
	if not _args_now.has(id):
		return true
	# Round 762: a ghost held with its page (alpha 0) is not drawn yet.
	return _ghosts_now != null and bool(_ghosts_now.call("is_ghost", node)) \
		and not (_ghosts_now.has_method("is_held") and bool(_ghosts_now.call("is_held", node)))

## The world's maps and its CrowdGpu (when it draws ghosts), read once a frame.
var _bodies_now: Dictionary = {}
var _args_now: Dictionary = {}
var _ghosts_now: Object = null

func _read_world() -> void:
	_bodies_now = world._other_bodies
	_args_now = world._other_build_args
	var crowd = world.get("_crowd_gpu")
	_ghosts_now = crowd if crowd != null and (crowd as Object).has_method("is_ghost") else null

func _resolve_bodies() -> void:
	bodies.clear()
	for id in _ids:
		var node: Node3D = world._other_bodies.get(id)
		if node != null:
			bodies.append({"id": id, "node": node})
			if not _homes.has(id):
				_homes[id] = node.position

func setup(w: Node, lineup_bodies: Array, spawn_usec: int = 0) -> void:
	world = w
	_arrival_start_us = spawn_usec if spawn_usec > 0 else Time.get_ticks_usec()
	_arrival_last_us = _arrival_start_us
	# Round 756: the ids, whose nodes may not exist yet (QaLineup's walk-up
	# spawns them a page at a time); the nodes are read once all have come.
	for b in lineup_bodies:
		_ids.append(int(b["id"]))
	_resolve_bodies()
	steps = OS.get_environment("OPENSRO_QA_CROWD_STEPS").split(",", false)
	var s := OS.get_environment("OPENSRO_QA_CROWD_SECONDS")
	if s.is_valid_float():
		seconds = maxf(float(s), SETTLE + 1.0)
	quit = OS.get_environment("OPENSRO_QA_CROWD_QUIT") != ""
	var nr := OS.get_environment("OPENSRO_QA_CROWD_NET_RATE")
	if nr.is_valid_float():
		net_rate = float(nr)
	var dl := OS.get_environment("OPENSRO_QA_CROWD_DELAY")
	if dl.is_valid_float():
		delay = float(dl)
	var lw := OS.get_environment("OPENSRO_QA_CROWD_LIVE_WAIT")
	if lw.is_valid_float():
		_live_wait = float(lw)
	# Round 762: OPENSRO_QA_LIVE_PERSEC=0 turns the live lines off (their
	# census is itself a long frame now and then, and the frame log has the rest).
	_persec = (live and OS.get_environment("OPENSRO_QA_LIVE_PERSEC") != "0") or OS.get_environment("OPENSRO_QA_CROWD_PERSEC") != ""
	_open_frame_log()
	_rng.seed = 736
	_boot_switches = CrowdAnim.switches()
	RenderingServer.viewport_set_measure_render_time(world.get_viewport().get_viewport_rid(), true)
	# Round 748: the frame's phases and the per-body systems' own timers
	# (FrameSplit; `QA CROWD split` after each step line).
	_split = FrameSplit.new()
	_split.name = "FrameSplit"
	add_child(_split)
	_split.install(world.get_tree().root)
	EfpEffect.profile = true
	_arrival_split_at = FrameSplit.snapshot()
	_arrival_prof_at = EfpEffect.prof.duplicate()
	# The pose and sound switches go through the frame split's own (round 664).
	if world._qa_split == null:
		world._qa_split = MonsterCrowd.Split.new(1 << 30)
	print("QA CROWD: %d bodies, steps %s, %.1f s each (%.1f settle), first after %.1f s; render thread %s, physics thread %s" % [bodies.size(), ",".join(steps), seconds, SETTLE, delay,
		"separate" if _threaded else "main", str(ProjectSettings.get_setting("physics/3d/run_on_separate_thread", false))])

## The arrival's frames (round 739), then the census once every body is dressed.
func _arrival_frame() -> void:
	if live:
		_live_arrival()
		return
	var now := Time.get_ticks_usec()
	var ms := float(now - _arrival_last_us) / 1000.0
	_arrival_ms.append(ms)
	_arrival_last_us = now
	_read_world()
	# Round 757's merge (QA): while ghosts are drawn, every 60 arrival frames,
	# how many lie outside the far groups' shared bounds (culled with them, S3)
	# and the far sounds they have played (S1).
	_arrival_n += 1
	if _arrival_n % 60 == 0:
		var cg = world.get("_crowd_gpu")
		if cg != null and (cg as CrowdGpu).ghost_count() > 0:
			var d := (cg as CrowdGpu).describe()
			print("QA CROWD ghostcheck frame=%d %s" % [_arrival_n, d.substr(0, d.find(" far="))] + " ghosts=%d" % (cg as CrowdGpu).ghost_count())
	if _visible_us < 0:
		_visible_frames += 1
		# Round 762 (QA): from the first id not yet seen drawn, up to the next
		# one not drawn -- not every id every frame (4,000 checks a frame were
		# the probe's own milliseconds in the frames it measures).
		while _vis_at < _ids.size():
			var id: int = _ids[_vis_at]
			if not _shown.has(id):
				if not _drawn(id):
					break
				_shown[id] = true
			_vis_at += 1
		_visible_trace.append("%.0f/%d" % [ms, _shown.size()])
		if _vis_at >= _ids.size():
			# Every id seen drawn once: all drawn now, unless one went away.
			var all := true
			for id in _ids:
				if not _drawn(id):
					all = false
					_vis_at = _ids.find(id)
					break
			if all:
				_visible_us = now
	for pg in _pages:
		if int(pg[4]) >= 0:
			continue
		pg[2] = int(pg[2]) + 1
		pg[3] = maxf(float(pg[3]), ms)
		var done := true
		for id in pg[0]:
			if not _shown.has(id) and not _drawn(id):
				done = false
				break
		if done:
			pg[4] = now
			print("QA CROWD page %d n=%d visible_ms=%.1f frames=%d worst_ms=%.1f" % [_pages.find(pg), (pg[0] as Array).size(),
				float(now - int(pg[1])) / 1000.0, int(pg[2]), float(pg[3])])
	var queue = world.get("_other_builds")
	# Round 762: a queue left with only ghosts beyond the dressing's reach is
	# done -- and (its review, F11) one of DRESS_NEAREST bodies or fewer left
	# with only drawn ghosts (their dressing is background work, not the
	# arrival; the `settled` cut needs more bodies than the dressing's reach).
	if (queue != null and not queue.is_empty() and not (queue.get("settled") == true) and not _only_ghosts_left(queue)) or _visible_us < 0:
		return
	for pg in _pages:
		if int(pg[4]) < 0:
			return
	_arriving = false
	_resolve_bodies()
	# Round 756: the frames until every body was drawn, apart.
	var vis := _arrival_ms.slice(0, _visible_frames)
	vis.sort()
	var vover := 0
	for v in vis:
		if v > 100.0:
			vover += 1
	print("QA CROWD visible n=%d frames=%d seconds=%.3f worst_ms=%.1f over100=%d" % [_ids.size(), vis.size(),
		float(_visible_us - _arrival_start_us) / 1e6, vis[-1] if not vis.is_empty() else 0.0, vover])
	print("QA CROWD visible trace (frame ms/drawn): %s" % " ".join(_visible_trace.slice(0, 200)))
	var sorted := _arrival_ms.duplicate()
	sorted.sort()
	var over := 0
	for v in sorted:
		if v > 100.0:
			over += 1
	print("QA CROWD arrival n=%d frames=%d seconds=%.2f worst_ms=%.1f p50=%.1f p95=%.1f over100=%d" % [
		bodies.size(), sorted.size(), float(now - _arrival_start_us) / 1e6, sorted[-1] if not sorted.is_empty() else 0.0,
		sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0,
		sorted[mini(int(sorted.size() * 0.95), sorted.size() - 1)] if not sorted.is_empty() else 0.0, over])
	# Round 748: where the arrival's frames went (ms a frame over its frames).
	print(split_line("arrival", _arrival_split_at, FrameSplit.snapshot(), _arrival_prof_at, EfpEffect.prof, float(sorted.size())))
	_census()

## Round 759 (live): the server's crowd arrives as it will; after
## `_live_wait` seconds every other player then in the world is a body.
## Round 762's review, F11: whether every body still queued for the dressing
## is a drawn ghost (looked at only for a queue of 96 or fewer).
func _only_ghosts_left(queue) -> bool:
	if int(queue.size()) > 96:
		return false
	var ghosts = world.get("_ghost_ids")
	if ghosts == null:
		return false
	for id in queue.ids():
		if not (ghosts as Dictionary).has(id):
			return false
	return true

func _live_arrival() -> void:
	_live_t += get_process_delta_time()
	if _live_t < _live_wait:
		return
	_arriving = false
	_ids = world._other_bodies.keys()
	_resolve_bodies()
	print("QA CROWD live: %d other players after %.0f s, %d still to dress" % [_ids.size(), _live_t, world._other_builds.size()])
	var cg = world.get("_crowd_gpu")
	if cg != null:
		print("QA CROWD groups split: %s" % (cg as CrowdGpu).split_census())
	_census()

const PERSEC_PHASES := ["phys_cb", "phys_engine", "proc_cb", "post_flush", "draw", "post_tail", "net_read", "net_dispatch",
	"p_world", "w_world", "fx_driver", "fx_effects", "w_pump", "ghosts"]

## Round 759: one `QA LIVE` line a second (the header).
func _persec_frame() -> void:
	var now := Time.get_ticks_usec()
	if _ps_last_us == 0:
		_ps_last_us = now
		_ps_prev_us = now
		_ps_split = FrameSplit.snapshot()
		_ps_ops = FrameSplit.ops.duplicate(true)
		_ps_sum = {}
		_ps_frames = 0
		_ps_max_ms = 0.0
		return
	var ms := float(now - _ps_prev_us) / 1000.0
	_ps_prev_us = now
	_ps_frames += 1
	_ps_max_ms = maxf(_ps_max_ms, ms)
	_ps_sum["draws"] = float(_ps_sum.get("draws", 0.0)) + Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_ps_sum["objects"] = float(_ps_sum.get("objects", 0.0)) + Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	_ps_sum["prims"] = float(_ps_sum.get("prims", 0.0)) + Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	if not _threaded:
		var vp := world.get_viewport().get_viewport_rid()
		_ps_sum["rcpu"] = float(_ps_sum.get("rcpu", 0.0)) + RenderingServer.viewport_get_measured_render_time_cpu(vp)
		_ps_sum["rgpu"] = float(_ps_sum.get("rgpu", 0.0)) + RenderingServer.viewport_get_measured_render_time_gpu(vp)
		_ps_sum["rs_setup"] = float(_ps_sum.get("rs_setup", 0.0)) + RenderingServer.get_frame_setup_time_cpu()
	if now - _ps_last_us < 1000000:
		return
	var f := maxf(float(_ps_frames), 1.0)
	var secs := float(now - _ps_last_us) / 1e6
	var after := FrameSplit.snapshot()
	var ph := PackedStringArray()
	for k in PERSEC_PHASES:
		ph.append("%s=%.2f" % [k, float(int(after.get(k, 0)) - int(_ps_split.get(k, 0))) / 1000.0 / f])
	var pk := int(after.get("net_packets_calls", 0)) - int(_ps_split.get("net_packets_calls", 0))
	var others: int = world._other_bodies.size()
	var near := others
	var cg := ""
	var crowd = world.get("_crowd_gpu")
	if crowd != null:
		var c := crowd as CrowdGpu
		var bc := c.batch_census()
		near = others - c.body_count()
		cg = " far=%d ghosts=%d groups=%d live_groups=%d instances=%d g_meshes=%d g_materials=%d g_shaders=%d g_ones=%d g_le3=%d g_most=%d" % [
			c.body_count() - c.ghost_count(), c.ghost_count(), int(bc["groups"]), int(bc["live"]), int(bc["instances"]), int(bc["meshes"]),
			int(bc["materials"]), int(bc["shaders"]), int(bc["ones"]), int(bc["le3"]), int(bc["most"])]
	var fx := ""
	var vp0 := world.get_viewport()
	if vp0.has_meta(EquipFx.DRIVER_META) and is_instance_valid(vp0.get_meta(EquipFx.DRIVER_META)):
		var d: EquipFx = vp0.get_meta(EquipFx.DRIVER_META)
		fx = " fx_hosts=%d fx_shown=%d fx_kinds=%d fx_ghost_hosts=%d fx_ghost_shown=%d fx_ghost_far=%.0f" % [int(d.stats.get("hosts", 0)), int(d.stats.get("shown", 0)), int(d.stats.get("kinds", 0)),
			int(d.stats.get("ghost_hosts", 0)), int(d.stats.get("ghost_shown", 0)), float(d.stats.get("ghost_shown_far", 0.0))]
	var pl := ""
	var pb = world.get("_plate_batch")
	if pb != null:
		pl = " plates=%d" % (pb as NamePlateBatch).size()
	_ps_n += 1
	print("QA LIVE sec=%d fps=%.1f frame_ms=%.1f max_ms=%.1f draws=%.0f objects=%.0f prims=%.0f rs_cpu=%.2f rs_gpu=%.2f rs_setup=%.2f time_process=%.1f time_physics=%.1f %s packets=%d packets_per_frame=%.1f others=%d near_or_undressed=%d to_dress=%d%s%s%s nodes=%d" % [
		_ps_n, f / secs, secs * 1000.0 / f, _ps_max_ms, float(_ps_sum.get("draws", 0.0)) / f, float(_ps_sum.get("objects", 0.0)) / f,
		float(_ps_sum.get("prims", 0.0)) / f, float(_ps_sum.get("rcpu", 0.0)) / f, float(_ps_sum.get("rgpu", 0.0)) / f,
		float(_ps_sum.get("rs_setup", 0.0)) / f,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		" ".join(ph), pk, float(pk) / f, others, near, world._other_builds.size(), cg, fx, pl, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	if _ps_n % 60 == 0 and crowd != null:
		print("QA LIVE groups split sec=%d %s" % [_ps_n, (crowd as CrowdGpu).split_census()])
	if _ps_n % 5 == 0:
		print("QA LIVE ops (5 s, by dispatch time): %s" % FrameSplit.ops_line(_ps_ops))
		_ps_ops = FrameSplit.ops.duplicate(true)
	_ps_last_us = now
	_ps_split = after
	_ps_sum = {}
	_ps_frames = 0
	_ps_max_ms = 0.0

## What one other player is made of, and how much of it is shared: one line
## for the first body and one for all of them.
func _census() -> void:
	var tot := {"nodes": 0, "meshes": 0, "visible_meshes": 0, "skinned": 0, "surfaces": 0, "shadow": 0, "skeletons": 0, "bones": 0,
		"labels": 0, "bodies3d": 0, "fx": 0, "multimesh": 0, "visible_materials": 0}
	var mats := {}
	var meshes := {}
	var skins := {}
	var first := ""
	for b in bodies:
		var c := {"nodes": 0, "meshes": 0, "visible_meshes": 0, "skinned": 0, "surfaces": 0, "shadow": 0, "skeletons": 0, "bones": 0,
			"labels": 0, "bodies3d": 0, "fx": 0, "multimesh": 0, "visible_materials": 0}
		# Round 739 (B5's write-up): the distinct materials among a body's
		# visible surfaces -- the draws a body would make if its meshes were
		# merged one per material.
		var own_mats := {}
		var stack: Array[Node] = [b["node"]]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			c["nodes"] += 1
			for ch in n.get_children():
				stack.append(ch)
			if n is Skeleton3D:
				c["skeletons"] += 1
				c["bones"] += (n as Skeleton3D).get_bone_count()
			elif n is MeshInstance3D:
				var mi := n as MeshInstance3D
				c["meshes"] += 1
				if mi.visible:
					c["visible_meshes"] += 1
				if mi.skin != null:
					c["skinned"] += 1
					skins[mi.skin.get_instance_id()] = true
				if mi.mesh != null:
					c["surfaces"] += mi.mesh.get_surface_count()
					meshes[mi.mesh.get_instance_id()] = true
					for i in mi.mesh.get_surface_count():
						var m := mi.get_active_material(i)
						if m != null:
							mats[m.get_instance_id()] = true
							if mi.visible:
								own_mats[m.get_instance_id()] = true
				if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and mi.visible:
					c["shadow"] += 1
			elif n is MultiMeshInstance3D:
				c["multimesh"] += 1
			elif n is Label3D:
				c["labels"] += 1
			elif n is CollisionObject3D:
				c["bodies3d"] += 1
			if n is EfpEffect:
				c["fx"] += 1
		c["visible_materials"] = own_mats.size()
		for k in c:
			tot[k] += c[k]
		if first == "":
			first = str(c)
	print("QA CROWD census: first body %s" % first)
	print("QA CROWD census: all %d bodies %s; distinct meshes %d, materials %d, skins %d" % [bodies.size(), str(tot), meshes.size(), mats.size(), skins.size()])
	# Round 738 (A2): what one pose of a body skeleton writes -- every bind of
	# every distinct skin registered on it (Godot 4.2.2 skeleton_3d.cpp:245-297).
	var regs := 0
	var binds := 0
	var posed_skels := 0
	var shown := false
	for b in bodies:
		for sk in (b["node"] as Node).find_children("*", "Skeleton3D", true, false):
			var on := {}
			for mi in CharacterAppearance._skinned_to(sk as Skeleton3D):
				if not on.has(mi.skin):
					on[mi.skin] = []
				(on[mi.skin] as Array).append(String(mi.name))
			if (sk as Skeleton3D).has_meta(MonsterCrowd.META_LAYOUT):
				posed_skels += 1
				regs += on.size()
				for skin in on:
					binds += (skin as Skin).get_bind_count()
				if not shown:
					shown = true
					var parts := PackedStringArray()
					for skin in on:
						parts.append("%d binds: %s" % [(skin as Skin).get_bind_count(), ",".join(PackedStringArray(on[skin]))])
					print("QA CROWD census: the first body skeleton's skins (%d bones): %s" % [(sk as Skeleton3D).get_bone_count(), " | ".join(parts)])
	# Round 748: the equipment effects' kinds (EquipFx: one master each).
	var vpk := world.get_viewport()
	if vpk.has_meta(EquipFx.DRIVER_META) and is_instance_valid(vpk.get_meta(EquipFx.DRIVER_META)):
		var dk: EquipFx = vpk.get_meta(EquipFx.DRIVER_META)
		var per_kind := PackedStringArray()
		for key in dk._kinds:
			var kk: EquipFx.Kind = dk._kinds[key]
			per_kind.append("%s(%d hosts%s)" % [key, kk.hosts, ", own" if kk.own else ""])
		print("QA CROWD census: equipment effect kinds %d: %s" % [dk._kinds.size(), " ".join(per_kind)])
	# Round 757: which nodes run a callback in every physics step or every
	# frame (their own or the engine's internal one), by class, over the whole
	# tree: the physics callbacks FrameSplit's phys_cb times beyond World3D's.
	var phys := {}
	var proc := {}
	var stack2: Array[Node] = [world.get_tree().root]
	while not stack2.is_empty():
		var nd: Node = stack2.pop_back()
		for ch in nd.get_children():
			stack2.append(ch)
		if nd.is_physics_processing() or nd.is_physics_processing_internal():
			phys[nd.get_class()] = int(phys.get(nd.get_class(), 0)) + 1
		if nd.is_processing() or nd.is_processing_internal():
			proc[nd.get_class()] = int(proc.get(nd.get_class(), 0)) + 1
	print("QA CROWD census: physics-processing nodes by class %s" % str(phys))
	print("QA CROWD census: processing nodes by class %s" % str(proc))
	print("QA CROWD census: body skeletons %d, skins registered on them %d (%.1f a body), binds written per pose %d (%.1f a body)" % [
		posed_skels, regs, float(regs) / maxf(float(posed_skels), 1.0), binds, float(binds) / maxf(float(posed_skels), 1.0)])

## Round 762 (QA): OPENSRO_QA_FRAME_LOG=<path> writes one line a frame from
## the probe's start: the clock (ms), the frame's wall ms, the step, the other
## players held, those not drawn yet (waiting, not a ghost), the ghosts, the
## far bodies, those still to dress, the bodies fading (AppearFade's and
## CrowdGpu's), the bytes and packets received (NetClient's QA counters) and
## the frame's packet dispatch ms -- the arrival and departure frame by frame.
var _frame_log: FileAccess = null
## The FrameSplit timers each frame-log line carries (ms in the frame).
const FRAME_LOG_SPLIT := ["proc_cb", "phys_cb", "post_flush", "w_world", "w_pump", "ghosts_ms", "dress", "g_add", "g_activate", "w_depart",
	"w_depart_free", "w_fades", "w_plates", "fx_driver", "fx_effects", "g_flush", "rs_setup", "tmpl_adopt", "dep_teardown", "dep_fade", "k_new", "k_paths", "k_efps", "p_world", "p_lineup", "p_step", "p_ticks",
	"p_player", "p_stream", "p_heights", "p_mobpump", "w_others", "w_blobs", "w_light", "w_selfpose", "o_legs", "fx_masters", "draw", "pp_order", "pp_cam", "pp_qa", "pp_move", "pp_ray", "qa_probe", "pp_navstep", "pp_setpos", "g_rigid", "g_recipe", "g_geo_clip", "g_light", "g_holder", "plate_add", "sp_node", "sp_pre", "sp_post", "pt_skill", "pt_texani", "dress_calls", "ga_geo", "ga_lit", "ga_parts", "gf_bake", "gf_upload", "ga_twin", "ga_uniforms", "ga_addpart", "gu_tex", "gu_push", "tw_shader", "tw_assign", "tw_params", "tw_texani", "tw_new", "tw_set", "tw_first_set_calls"]
var _fl_last_us := 0
var _fl_start_us := 0
var _fl_rs := OS.get_environment("OPENSRO_QA_FRAME_LOG_RS") == "1"
var _fl_split := {}

func _open_frame_log() -> void:
	var path := OS.get_environment("OPENSRO_QA_FRAME_LOG")
	if path == "":
		return
	_frame_log = FileAccess.open(path, FileAccess.WRITE)
	if _frame_log != null:
		var cols := "t_ms frame_ms step others undrawn ghosts far to_dress fading rx_bytes rx_packets dispatch_ms left_ms held depart_q free_q"
		for k in FRAME_LOG_SPLIT:
			cols += " " + k
		cols += " budget_ms budget_own_ms budget_spent_ms max_op_ms max_opcode"
		if _fl_rs:
			cols += " rs_cpu rs_setup_ms pc_mesh pc_surface pc_draw pc_spec"
		_frame_log.store_line(cols)
		_fl_start_us = Time.get_ticks_usec()
		_fl_last_us = _fl_start_us

func _log_frame() -> void:
	var now := Time.get_ticks_usec()
	var ms := float(now - _fl_last_us) / 1000.0
	_fl_last_us = now
	var cg = world.get("_crowd_gpu")
	var ghosts := 0
	var far := 0
	var fading := 0
	if cg != null:
		ghosts = (cg as CrowdGpu).ghost_count()
		far = (cg as CrowdGpu).body_count() - ghosts
		fading = (cg as CrowdGpu).fading_count() if (cg as Object).has_method("fading_count") else 0
	var af = world.get("_appear_fades")
	if af != null:
		fading += (af as AppearFade.Fades).running()
	var snap := FrameSplit.snapshot()
	var disp := float(int(snap.get("net_dispatch", 0)) - int(_fl_split.get("net_dispatch", 0))) / 1000.0
	var left := float(int(snap.get("w_left", 0)) - int(_fl_split.get("w_left", 0))) / 1000.0
	var extra := ""
	for k in FRAME_LOG_SPLIT:
		var sk: String = "ghosts" if k == "ghosts_ms" else k
		extra += " %.2f" % (float(int(snap.get(sk, 0)) - int(_fl_split.get(sk, 0))) / 1000.0)
	_fl_split = snap
	var held := 0
	if world.has_method("qa_held_count"):
		held = int(world.call("qa_held_count"))
	else:
		var hs = world.get("_hold_slot")
		if hs != null and int(hs) >= 0 and cg != null and (cg as CrowdGpu).hold_pending(int(hs)):
			held = (world.get("_hold_ids") as Array).size()
	var undrawn: int = world._other_build_args.size() - world._ghost_ids.size() + held
	var bc: Array = world.call("qa_budget_cols") if world.has_method("qa_budget_cols") else [0.0, 0.0, 0.0]
	extra += " %.2f %.2f %.2f" % bc
	# The longest single dispatch of the frame and its opcode (round 762).
	extra += " %.2f %d" % [float(NetClient.qa_max_op_usec) / 1000.0, NetClient.qa_max_opcode]
	NetClient.qa_max_op_usec = 0
	if _fl_rs:
		# QA diagnostics (OPENSRO_QA_FRAME_LOG_RS=1): the render thread's last
		# frame (its viewport's CPU time and the scene update) and the pipeline
		# compilations so far -- each read waits for the render thread.
		var vp := world.get_viewport().get_viewport_rid()
		extra += " %.2f %.2f %d %d %d %d" % [RenderingServer.viewport_get_measured_render_time_cpu(vp), RenderingServer.get_frame_setup_time_cpu(),
			int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH)), int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE)),
			int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW)), int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION))]
	var dq = world.get("_depart_ids")
	var fq = world.get("_depart_free")
	_frame_log.store_line("%.1f %.2f %s %d %d %d %d %d %d %d %d %.2f %.2f %d %d %d" % [float(now - _fl_start_us) / 1000.0, ms,
		steps[_i] if _i >= 0 and _i < steps.size() else ("arrival" if _arriving else "wait"), world._other_bodies.size(), undrawn,
		ghosts, far, world._other_builds.size(), fading, NetClient.qa_rx_bytes, NetClient.qa_rx_packets, disp, left, held,
		(dq as Array).size() - int(world.get("_depart_ids_at")) if dq != null else 0, (fq as Array).size() - int(world.get("_depart_free_at")) if fq != null else 0] + extra)

## Round 762 (QA): the `leave` step's kits (every lineup body leaves as a
## group despawn would take it: _on_entity_left for each in one frame), and
## the `back` step's arrival (every body back as one group spawn, bracketed
## as NetClient brackets a 0x3017..0x3018 page) until every body is drawn.
var _leave_kits: Array = []
var _back_ids: Array = []
var _back_us := 0
var _back_frames := 0
var _back_worst := 0.0
var _back_last_us := 0

func _leave_all(east_half: bool = false) -> void:
	var tk := Time.get_ticks_usec()
	_leave_kits = []
	# Round 762's review (`half`): only the bodies east of the median x.
	var cut := -INF
	if east_half:
		var xs := PackedFloat32Array()
		for b in bodies:
			var nd = world._other_bodies.get(int(b["id"]))
			if nd != null and is_instance_valid(nd):
				xs.append((nd as Node3D).position.x)
		xs.sort()
		cut = xs[xs.size() / 2] if not xs.is_empty() else -INF
	for b in bodies:
		var id := int(b["id"])
		var node = world._other_bodies.get(id)
		if node == null or not is_instance_valid(node):
			continue
		if east_half and (node as Node3D).position.x <= cut:
			continue
		var gait: Dictionary = world._other_gaits.get(id, {})
		var args: Dictionary = world._other_build_args.get(id, {})
		_leave_kits.append([id, String((node as Node).get_meta("character_name", "")), (node as Node3D).position,
			(world._other_equipped.get(id, args.get("equipped", {})) as Dictionary).duplicate(), String((node as Node).get_meta("body", "")),
			int(gait.get("scale", args.get("scale", CharacterAppearance.DEFAULT_SCALE))), (world._other_pluses.get(id, {}) as Dictionary).duplicate(),
			(node as Node3D).rotation.y])
	var t0 := Time.get_ticks_usec()
	# OPENSRO_QA_LINEUP_STEP_MS: handed over a frame's share at a time, as
	# NetClient reads a group despawn since round 762 (_despawn_step); else in
	# this one call, as before.
	var sm := OS.get_environment("OPENSRO_QA_LINEUP_STEP_MS")
	if sm.is_valid_float():
		_leave_step_usec = int(float(sm) * 1000.0)
		_leave_ids = []
		for k in _leave_kits:
			_leave_ids.append(int(k[0]))
		_leave_at = 0
		_leave_frames = 0
		_leave_t0 = t0
		_leave_hand_over()
		print("QA CROWD leave: %d bodies leaving as one group despawn, the first share in %.1f ms (and %.1f ms of the probe's own: their kits kept for `back`)" % [
			_leave_kits.size(), (Time.get_ticks_usec() - t0) / 1000.0, (t0 - tk) / 1000.0])
		return
	for k in _leave_kits:
		world._on_entity_left(int(k[0]))
	_world_usec += Time.get_ticks_usec() - t0
	print("QA CROWD leave: %d bodies left in one call, %.1f ms (and %.1f ms of the probe's own: their kits kept for `back`)" % [
		_leave_kits.size(), (Time.get_ticks_usec() - t0) / 1000.0, (t0 - tk) / 1000.0])

var _leave_ids: Array = []
var _leave_at := 0
var _leave_step_usec := 0
var _leave_frames := 0
var _leave_t0 := 0

## Round 762 (QA): the leaving group's next share, as NetClient._despawn_step.
func _leave_hand_over() -> void:
	if _leave_at >= _leave_ids.size():
		return
	var t0 := Time.get_ticks_usec()
	var first := _leave_at
	_leave_frames += 1
	var step := int(world.call("qa_group_step_usec", _leave_step_usec)) if world.has_method("qa_group_step_usec") else _leave_step_usec
	while _leave_at < _leave_ids.size():
		if _leave_at > first and Time.get_ticks_usec() - t0 >= step:
			break
		world._on_entity_left(int(_leave_ids[_leave_at]))
		_leave_at += 1
	if world.has_method("qa_budget_spend"):
		world.call("qa_budget_spend", Time.get_ticks_usec() - t0)
	_world_usec += Time.get_ticks_usec() - t0
	if _leave_at >= _leave_ids.size():
		print("QA CROWD leave: the group despawn read over %d frame(s), %.1f ms" % [_leave_frames, (Time.get_ticks_usec() - _leave_t0) / 1000.0])
		_leave_ids = []
		_leave_at = 0

## Round 762's review, F4 (`cross`): a walk across a block line -- the bodies
## here leave as one group despawn and the kept (`half`) ones arrive as one
## group spawn in the same batch; the spawn is handed over once the despawn
## is read (_back_hand_over waits for it), as NetClient reads one group after
## the other.
func _cross() -> void:
	if _leave_kits.is_empty():
		return
	var arriving := _leave_kits
	_leave_all()
	var leaving := _leave_kits
	_leave_kits = arriving
	_come_back()
	_leave_kits = leaving

func _come_back() -> void:
	if _leave_kits.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	_back_ids = []
	for k in _leave_kits:
		_back_ids.append(int(k[0]))
	_back_us = t0
	_back_frames = 0
	_back_kits = _leave_kits
	_back_at = 0
	_leave_kits = []
	# OPENSRO_QA_LINEUP_STEP_MS: handed over a frame's share at a time, as
	# NetClient hands a group over since round 762; else in this one call.
	var sm := OS.get_environment("OPENSRO_QA_LINEUP_STEP_MS")
	_back_step_usec = int(float(sm) * 1000.0) if sm.is_valid_float() else (1 << 40)
	_back_hand_over()
	_back_last_us = Time.get_ticks_usec()
	_back_worst = float(_back_last_us - t0) / 1000.0
	print("QA CROWD back: %d bodies arriving as one group, the first share spawned in %.1f ms" % [_back_ids.size(), _back_worst])

var _back_kits: Array = []
var _back_at := 0
var _back_step_usec := 0

func _back_hand_over() -> void:
	if _back_at >= _back_kits.size():
		return
	# `cross`: after the despawn read before it.
	if _leave_at < _leave_ids.size():
		return
	var t0 := Time.get_ticks_usec()
	var first := _back_at
	# Round 762: as NetClient._group_step, the share the frame's crowd budget
	# leaves (when handed over in shares).
	var step := _back_step_usec
	if _back_step_usec < (1 << 40) and world.has_method("qa_group_step_usec"):
		step = int(world.call("qa_group_step_usec", _back_step_usec))
	world._on_user_group_begin()
	while _back_at < _back_kits.size():
		if _back_at > first and Time.get_ticks_usec() - t0 >= step:
			break
		var k: Array = _back_kits[_back_at]
		_back_at += 1
		world._spawn_or_update_other(int(k[0]), String(k[1]), k[2], k[3], String(k[4]), NAN, int(k[5]), k[6])
		var node = world._other_bodies.get(int(k[0]))
		if node != null:
			(node as Node3D).rotation.y = float(k[7])
	if world.has_method("qa_budget_spend"):
		world.call("qa_budget_spend", Time.get_ticks_usec() - t0)
	world._on_user_group_end()
	_world_usec += Time.get_ticks_usec() - t0
	if _back_at >= _back_kits.size():
		for b in bodies:
			var fresh = world._other_bodies.get(int(b["id"]))
			if fresh != null:
				b["node"] = fresh

func _back_frame() -> void:
	_back_hand_over()
	var now := Time.get_ticks_usec()
	_back_worst = maxf(_back_worst, float(now - _back_last_us) / 1000.0)
	_back_last_us = now
	_back_frames += 1
	_read_world()
	for id in _back_ids:
		if not _drawn(id):
			return
	print("QA CROWD back visible n=%d ms=%.1f frames=%d worst_ms=%.1f" % [_back_ids.size(), float(now - _back_us) / 1000.0, _back_frames, _back_worst])
	_back_ids = []

func _next() -> void:
	if _i >= 0:
		_switch(steps[_i], false)
	_i += 1
	_t = 0.0
	_on = false
	if _i >= steps.size():
		print("QA CROWD DONE")
		set_process(false)
		if quit:
			world.get_tree().quit()
		return
	print("QA CROWD begin %s" % steps[_i])
	_switch(steps[_i], true)

func _process(delta: float) -> void:
	if world == null:
		return
	if _frame_log != null:
		_log_frame()
	var qt := Time.get_ticks_usec()
	_world_usec = 0
	_probe_process(delta)
	# QA (round 762): the probe's own time in the frame (its checks of every
	# body, its census lines), less its calls into the world (the leave and
	# back hand-overs: the client's work, as NetClient's reading of a group
	# is), so the frame log can tell the client's frame from the probe's.
	FrameSplit.add("qa_probe", Time.get_ticks_usec() - qt - _world_usec)

## QA (round 762): the probe's calls into the world this frame (usec).
var _world_usec := 0

func _probe_process(delta: float) -> void:
	if _leave_at < _leave_ids.size():
		_leave_hand_over()
	if not _back_ids.is_empty():
		_back_frame()
	if _persec:
		_persec_frame()
	if _arriving:
		_arrival_frame()
		return
	if _i < 0:
		delay -= delta
		if delay <= 0.0:
			_next()
		return
	if _i >= steps.size():
		return
	_t += delta
	var now := Time.get_ticks_usec()
	# Round 757: each part of a combined step ("dest0.02+churn0.01") at its rate.
	if _pool_busy:
		_pool_busy_step()
	for part in steps[_i].split("+", false):
		if part.begins_with("net"):
			_net_step(delta, float(part.substr(3)) if part.substr(3).is_valid_float() else net_rate)
		elif part.begins_with("dest"):
			_net_step(delta, float(part.substr(4)) if part.substr(4).is_valid_float() else net_rate, true)
		for kind in ["churn", "redress", "reglow"]:
			if part.begins_with(kind):
				var r := part.substr(kind.length())
				_event_step(kind, delta, float(r) if r.is_valid_float() else 0.02)
	if steps[_i].split("+")[0] == "move":
		_move_t += delta
		if _move_t >= 1.0:
			_move_t = 0.0
			_scatter()
	if not _on and _t >= SETTLE:
		_on = true
		_frame_ms = PackedFloat32Array()
		_acc = {"frames": 0, "cpu": 0.0, "gpu": 0.0, "proc": 0.0, "phys": 0.0, "draws": 0, "objects": 0, "prims": 0,
			"pose_us": world._qa_split.pose_usec, "sound_us": world._qa_split.sound_usec,
			"idle_us": world._qa_split.idle_usec, "minimap_us": world._qa_split.minimap_usec, "posed": world._qa_split.posed,
			"crowd_us": world._qa_split.crowd_usec, "others_us": world._qa_split.others_usec,
			"steps": world._qa_split.steps, "start_us": now, "net_us": _net_us, "net_sent": _net_sent,
			"unix0": Time.get_unix_time_from_system()}
		_split_at = FrameSplit.snapshot()
		_prof_at = EfpEffect.prof.duplicate()
		_last_us = now
		return
	if _on:
		var vp := world.get_viewport().get_viewport_rid()
		_frame_ms.append(float(now - _last_us) / 1000.0)
		_last_us = now
		_acc["frames"] += 1
		# Round 757: with the render on its own thread a getter waits for that
		# thread to finish its frame, so the render's own numbers are read on
		# one frame in RS_SAMPLE_EVERY and counted for all of them.
		var rs_read := not _threaded or int(_acc["frames"]) % RS_SAMPLE_EVERY == 0
		var rs_w := 1.0 if not _threaded else float(RS_SAMPLE_EVERY)
		if rs_read:
			_acc["cpu"] += RenderingServer.viewport_get_measured_render_time_cpu(vp) * rs_w
			_acc["gpu"] += RenderingServer.viewport_get_measured_render_time_gpu(vp) * rs_w
		_acc["proc"] += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_acc["phys"] += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_acc["draws"] += int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		_acc["objects"] += int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		_acc["prims"] += int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		# Round 757: the engine's own monitors (the physics server's objects and
		# pairs, the navigation step).
		_acc["phys_active"] = int(_acc.get("phys_active", 0)) + int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
		_acc["phys_pairs"] = int(_acc.get("phys_pairs", 0)) + int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
		_acc["phys_islands"] = int(_acc.get("phys_islands", 0)) + int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))
		_acc["nav_ms"] = float(_acc.get("nav_ms", 0.0)) + Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
		# Round 748: the draw's scene update and the overlay's own render.
		if rs_read:
			FrameSplit.add("rs_setup", int(RenderingServer.get_frame_setup_time_cpu() * 1000.0 * rs_w))
			var ov = world._overlay_view
			if ov != null and is_instance_valid(ov) and ov._viewport != null:
				var orid: RID = (ov._viewport as SubViewport).get_viewport_rid()
				RenderingServer.viewport_set_measure_render_time(orid, true)
				FrameSplit.add("rs_overlay_cpu", int(RenderingServer.viewport_get_measured_render_time_cpu(orid) * 1000.0 * rs_w))
			FrameSplit.add("rs_main_cpu", int(RenderingServer.viewport_get_measured_render_time_cpu(vp) * 1000.0 * rs_w))
	if _t >= seconds:
		_report()
		_next()

func _report() -> void:
	var f := maxf(float(_acc.get("frames", 0)), 1.0)
	var wall := float(Time.get_ticks_usec() - int(_acc["start_us"])) / 1000.0 / f
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var p50 := sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0
	var p95 := sorted[mini(int(sorted.size() * 0.95), sorted.size() - 1)] if not sorted.is_empty() else 0.0
	var sp: MonsterCrowd.Split = world._qa_split
	var cam: Camera3D = world.get_viewport().get_camera_3d()
	var in_view := 0
	for b in bodies:
		var raw = b["node"]
		if not is_instance_valid(raw):
			continue
		var n: Node3D = raw
		if cam != null and n.is_inside_tree() and cam.is_position_in_frustum(n.global_position + Vector3(0, 8, 0)):
			in_view += 1
	var fx_line := ""
	var vp0 := world.get_viewport()
	if vp0.has_meta(EquipFx.DRIVER_META) and is_instance_valid(vp0.get_meta(EquipFx.DRIVER_META)):
		var d: EquipFx = vp0.get_meta(EquipFx.DRIVER_META)
		fx_line = " fx_hosts=%d fx_shown=%d fx_kinds=%d fx_ghost_hosts=%d fx_ghost_shown=%d fx_ghost_far=%.0f fx_in_view=%d" % [int(d.stats["hosts"]), int(d.stats["shown"]), int(d.stats["kinds"]),
			int(d.stats.get("ghost_hosts", 0)), int(d.stats.get("ghost_shown", 0)), float(d.stats.get("ghost_shown_far", 0.0)), int(d.stats.get("in_view", 0))] \
			+ " fx_batch_hosts=%d fx_batch_draws=%d fx_batch_instances=%d fx_batch_live=%d" % [int(d.stats.get("batch_hosts", 0)),
			int(d.stats.get("batch_draws", 0)), int(d.stats.get("batch_instances", 0)), int(d.stats.get("batch_live", 0))]
	var gpu_line := ""
	var crowd = world.get("_crowd_gpu")
	if crowd != null:
		gpu_line = " gpu: " + (crowd as CrowdGpu).describe() + " gpu_ms=%.2f" % (float(sp.crowd_usec - int(_acc["crowd_us"])) / 1000.0 / f)
	gpu_line += " others_ms=%.2f" % (float(sp.others_usec - int(_acc["others_us"])) / 1000.0 / f)
	# Round 757: the step's wall-clock window, so a box-side sampler's
	# per-thread CPU and GPU lines (tools/crowd_threads.py) can be matched to it.
	var unix_line := " max_ms=%.2f" % (sorted[-1] if not sorted.is_empty() else 0.0)
	unix_line += " phys_active=%d phys_pairs=%d phys_islands=%d nav_ms=%.2f objects_total=%d unix=%.3f,%.3f" % [
		int(_acc.get("phys_active", 0)) / int(f), int(_acc.get("phys_pairs", 0)) / int(f), int(_acc.get("phys_islands", 0)) / int(f),
		float(_acc.get("nav_ms", 0.0)) / f, int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		float(_acc.get("unix0", 0.0)), Time.get_unix_time_from_system()]
	print("QA CROWD step %-8s n=%d in_view=%d frames=%d frame_ms=%.2f p50=%.2f p95=%.2f render_cpu_ms=%.2f render_gpu_ms=%.2f process_ms=%.2f physics_ms=%.2f idle_ms=%.2f pose_ms=%.2f sound_ms=%.2f minimap_ms=%.2f posed_per_frame=%.0f steps_per_frame=%.2f draws=%d objects=%d prims=%d nodes=%d anim=%s baked=%d static_mb=%.1f%s%s" % [
		steps[_i], bodies.size(), in_view, int(f), wall, p50, p95,
		_acc["cpu"] / f, _acc["gpu"] / f, _acc["proc"] / f, _acc["phys"] / f,
		float(sp.idle_usec - int(_acc["idle_us"])) / 1000.0 / f,
		float(sp.pose_usec - int(_acc["pose_us"])) / 1000.0 / f,
		float(sp.sound_usec - int(_acc["sound_us"])) / 1000.0 / f,
		float(sp.minimap_usec - int(_acc["minimap_us"])) / 1000.0 / f,
		float(sp.posed - int(_acc["posed"])) / f,
		float(sp.steps - int(_acc["steps"])) / f,
		int(_acc["draws"] / f), int(_acc["objects"] / f), int(_acc["prims"] / f),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), CrowdAnim.switches(), CrowdAnim.baked_frames,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, fx_line, gpu_line + unix_line])
	print(split_line(steps[_i], _split_at, FrameSplit.snapshot(), _prof_at, EfpEffect.prof, f))
	var pb = world.get("_plate_batch")
	if pb != null:
		# And the other players' plates drawn as Label3Ds (not batched).
		var drawn_labels := 0
		var bodies_with_plate := 0
		for id in world._other_bodies:
			var ob = world._other_bodies[id]
			if ob == null or not is_instance_valid(ob):
				continue
			var lab := (ob as Node).get_node_or_null("Name") as Label3D
			if lab != null:
				bodies_with_plate += 1
				if lab.visible:
					drawn_labels += 1
		print("QA CROWD plates %-8s %s bodies_with_plate=%d label3d_drawn=%d" % [steps[_i], (pb as NamePlateBatch).describe(), bodies_with_plate, drawn_labels])
	if OS.get_environment("OPENSRO_QA_CROWD_ATTACH_AUDIT") != "":
		print("QA CROWD attach %-8s %s" % [steps[_i], attach_audit(world)])
	if steps[_i].contains("net") or steps[_i].contains("dest"):
		var sent := _net_sent - int(_acc["net_sent"])
		print("QA CROWD net: %d packets in %d frames, %.2f ms a frame in NetClient._dispatch, %.1f us a packet" % [
			sent, int(f), float(_net_us - int(_acc["net_us"])) / 1000.0 / f, float(_net_us - int(_acc["net_us"])) / maxf(float(sent), 1.0)])

## Round 757 (the user's live log: 30,382 engine errors "Attempt to disconnect
## a nonexistent connection from 'Skeleton:<Skeleton3D#..>'. Signal:
## 'bone_pose_changed'"): every BoneAttachment3D in the tree is connected to its
## parent skeleton's bone_pose_changed once while it is bound (Godot 4.2.2
## bone_attachment_3d.cpp l. 143-183, READ), and errors when it leaves the
## tree without that connection. This counts, over every other player's body,
## the attachments in the tree and the skeletons' connections of that signal;
## a skeleton with fewer connections than attachments is the bug's state.
static func attach_audit(w: Node) -> String:
	var attachments := 0
	var connections := 0
	var short := 0
	var extra := 0
	for id in w._other_bodies:
		var body = w._other_bodies[id]
		if body == null or not is_instance_valid(body):
			continue
		for sk in (body as Node).find_children("*", "Skeleton3D", true, false):
			var n_att := 0
			for c in (sk as Node).get_children():
				if c is BoneAttachment3D and (c as Node).is_inside_tree():
					n_att += 1
			var n_con := (sk as Object).get_signal_connection_list("bone_pose_changed").size()
			attachments += n_att
			connections += n_con
			if n_con < n_att:
				short += 1
			elif n_con > n_att:
				extra += 1
	return "attachments=%d connections=%d skeletons_short=%d skeletons_extra=%d" % [attachments, connections, short, extra]

## Round 748: one step's `QA CROWD split` line -- every FrameSplit counter's
## change over the step, in ms a frame (the phases first), and EfpEffect's own
## profile (place, sim, draws). `frames` is the step's measured frames.
static func split_line(step: String, before: Dictionary, after: Dictionary, prof_before: Dictionary, prof_after: Dictionary, frames: float) -> String:
	var f := maxf(frames, 1.0)
	var parts := PackedStringArray()
	var keys := after.keys()
	keys.sort()
	var phases := ["phys_cb", "phys_engine", "proc_cb", "post_flush", "draw", "post_tail"]
	for k in phases:
		parts.append("%s=%.2f" % [k, float(int(after.get(k, 0)) - int(before.get(k, 0))) / 1000.0 / f])
	for k in keys:
		if k in phases:
			continue
		var d := int(after[k]) - int(before.get(k, 0))
		if String(k).ends_with("_calls"):
			parts.append("%s=%.1f" % [k, float(d) / f])
		else:
			parts.append("%s=%.2f" % [k, float(d) / 1000.0 / f])
	for k in ["place", "sim", "draws", "links", "steps", "draw_calls"]:
		var d := int(prof_after.get(k, 0)) - int(prof_before.get(k, 0))
		if k == "steps" or k == "draw_calls":
			parts.append("efp_%s=%.1f" % [k, float(d) / f])
		else:
			parts.append("efp_%s=%.2f" % [k, float(d) / 1000.0 / f])
	return "QA CROWD split %-8s %s" % [step, " ".join(parts)]

func _meshes(node: Node) -> Array:
	return node.find_children("*", "MeshInstance3D", true, false)

## Round 757: a live crowd's own events at `rate` of the bodies a second
## (OURS model), round robin over the lineup -- what the lineup's steady steps
## never do, and what a swarm of real players does all the time:
##   churn    the body leaves (0x3016's path, World3D._on_entity_left) and comes
##            straight back (0x3015's, _spawn_or_update_other) with what it wore
##   redress  the body is rebuilt in what it wears (0x3038's path, _redress_other)
##   reglow   its pluses change, every plused slot 13 <-> 12 (_reglow_other)
var _event_due := 0.0
var _event_next := 0
var events := 0

## The `rezone` step's kits (round 760): one per lineup body, taken as it leaves.
var _rezone_kits: Array = []
var rezones := 0

func _rezone(off: bool) -> void:
	if off:
		_rezone_kits = []
		for b in bodies:
			var id := int(b["id"])
			var node = world._other_bodies.get(id)
			if node == null or not is_instance_valid(node):
				continue
			var gait: Dictionary = world._other_gaits.get(id, {})
			_rezone_kits.append([id, String((node as Node).get_meta("character_name", "")), (node as Node3D).position,
				(world._other_equipped.get(id, {}) as Dictionary).duplicate(), String((node as Node).get_meta("body", "")),
				int(gait.get("scale", CharacterAppearance.DEFAULT_SCALE)), (world._other_pluses.get(id, {}) as Dictionary).duplicate()])
		world._replace_others_for_arrival([], [])
		var away := OS.get_environment("OPENSRO_QA_REZONE")
		world._reload_zone_assets(away if away != "" else "hotan")
		print("QA CROWD rezone: left with %d bodies, grid for %s" % [_rezone_kits.size(), away if away != "" else "hotan"])
		return
	var home := String(OS.get_environment("OPENSRO_MAPM_PATH")).replace("\\", "/").trim_suffix(".m")
	world._reload_zone_assets(home)
	var at := OS.get_environment("OPENSRO_QA_AT").split(",")
	var coords: Dictionary = world._parse_region_coords(home)
	if at.size() == 2 and not coords.is_empty():
		world._place_at_region_local(int(coords["x"]), int(coords["y"]), float(at[0]), float(at[1]))
	for k in _rezone_kits:
		world._spawn_or_update_other(int(k[0]), String(k[1]), k[2], k[3], String(k[4]), NAN, int(k[5]), k[6])
	for b in bodies:
		var fresh = world._other_bodies.get(int(b["id"]))
		if fresh != null:
			b["node"] = fresh
	rezones += 1
	print("QA CROWD rezone: back to %s, %d bodies arriving again (rezone %d)" % [home, _rezone_kits.size(), rezones])
	_rezone_kits = []

func _event_step(kind: String, delta: float, rate: float) -> void:
	_event_due += delta * rate * bodies.size()
	while _event_due >= 1.0 and not bodies.is_empty():
		_event_due -= 1.0
		var b: Dictionary = bodies[_event_next % bodies.size()]
		_event_next += 1
		var id := int(b["id"])
		var node = world._other_bodies.get(id)
		if node == null or not is_instance_valid(node):
			continue
		events += 1
		match kind:
			"churn":
				var equipped: Dictionary = (world._other_equipped.get(id, {}) as Dictionary).duplicate()
				var pluses: Dictionary = (world._other_pluses.get(id, {}) as Dictionary).duplicate()
				var gait: Dictionary = world._other_gaits.get(id, {})
				var body_code := String((node as Node).get_meta("body", ""))
				var who := String((node as Node).get_meta("character_name", ""))
				var at: Vector3 = (node as Node3D).position
				var scale := int(gait.get("scale", CharacterAppearance.DEFAULT_SCALE))
				world._on_entity_left(id)
				world._spawn_or_update_other(id, who, at, equipped, body_code, NAN, scale, pluses)
				var fresh = world._other_bodies.get(id)
				if fresh != null:
					b["node"] = fresh
			"redress":
				world._forget_other_kind(id)
				world._redress_other(id)
			"reglow":
				var pl: Dictionary = (world._other_pluses.get(id, {}) as Dictionary).duplicate()
				for slot in pl.keys():
					pl[slot] = 12 if int(pl[slot]) == 13 else 13
				world._other_pluses[id] = pl
				world._reglow_other(id, pl)

func _switch(step: String, off: bool) -> void:
	# Round 747's review: two switches in one step ("net+sound").
	if step.contains("+"):
		for part in step.split("+", false):
			_switch(part, off)
		return
	if step.begins_with("net") or step.begins_with("dest"):
		step = "net"
	for kind in ["churn", "redress", "reglow"]:
		if step.begins_with(kind):
			step = kind
	# Round 762: `walk=<dx>/<dz>` and `deck=<dx>/<dz>`, a ground (or deck)
	# click that far from the player at the step's start (World3D._qa_click):
	# the live walk out of the crowd's blocks and back.
	if step.begins_with("walk=") or step.begins_with("deck="):
		if off:
			var d := step.substr(5).split("/")
			if d.size() == 2:
				print("QA CROWD %s: %s" % [step, world._qa_click(float(d[0]), float(d[1]), true, step.begins_with("deck="))])
		return
	if step.begins_with("anim="):
		CrowdAnim.set_switches(step.substr(5) if off else _boot_switches)
		return
	match step:
		"minimap":
			# Round 757: the minimap's signs and its refresh off (the HUD's
			# MinimapWindow hidden): what the crowd's signs cost.
			var mm = world._hud_minimap
			if mm != null and is_instance_valid(mm):
				(mm as CanvasItem).visible = not off
			world.set("_qa_minimap_off", off)
		"pose", "sound", "farsound":
			var arr: PackedStringArray = world._qa_split_off
			if off and not arr.has(step):
				arr.append(step)
			elif not off and arr.has(step):
				arr.remove_at(arr.find(step))
			world._qa_split_off = arr
		"mesh":
			# Only the meshes that were showing: a body hides the parts its
			# armour covers (CharacterAppearance), and those stay hidden.
			if off:
				_hidden_meshes.clear()
				for b in bodies:
					for mi in _meshes(b["node"]):
						if (mi as MeshInstance3D).visible:
							(mi as MeshInstance3D).visible = false
							_hidden_meshes.append(mi)
			else:
				for mi in _hidden_meshes:
					if is_instance_valid(mi):
						(mi as MeshInstance3D).visible = true
				_hidden_meshes.clear()
		"labels":
			for b in bodies:
				var plate := (b["node"] as Node).get_node_or_null("Name") as VisualInstance3D
				if plate != null:
					plate.layers = 0 if off else OverlayView.BIT
			# Round 757: the batched plates (NamePlateBatch) shown within 0.
			var batch = world.get("_plate_batch")
			if batch != null:
				(batch as NamePlateBatch).set_range(0.0 if off else float(world.get("_name_plate_range")))
		"collide":
			for b in bodies:
				var n: Node3D = b["node"]
				if off:
					var click := n.get_node_or_null("PlayerClickBody")
					if click != null:
						n.remove_child(click)
						_removed[click] = n
				else:
					for c in _removed.keys():
						if _removed[c] == n:
							n.add_child(c)
							_removed.erase(c)
		"fx":
			var vp := world.get_viewport()
			if vp.has_meta(EquipFx.DRIVER_META) and is_instance_valid(vp.get_meta(EquipFx.DRIVER_META)):
				var d: EquipFx = vp.get_meta(EquipFx.DRIVER_META)
				d.process_mode = Node.PROCESS_MODE_DISABLED if off else Node.PROCESS_MODE_INHERIT
				# Round 759: the masters never process themselves (the driver
				# steps them, EquipFx._step_masters); turning theirs on here
				# stepped each twice after the switch.
				for k in d._kinds.values():
					(k.master as Node).set_process(false)
				for h in d._hosts.values():
					if h.holder != null and is_instance_valid(h.holder):
						h.holder.visible = false if off else h.holder.visible
				# Round 764: the ghosts' batched particles too.
				if d._batch != null:
					for b in d._batch._batches.values():
						for dr in b.draws:
							if is_instance_valid(dr[0]):
								(dr[0] as Node3D).visible = false if off else int(dr[4]) > 0
		"shadow":
			# Only what was casting, and only that given back (round 739: the
			# first version turned every mesh's shadow on after, the EquipFx
			# particles' and Detail's switched-off ones included).
			if off:
				_shadowed.clear()
				for b in bodies:
					for gi in (b["node"] as Node).find_children("*", "GeometryInstance3D", true, false):
						if (gi as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
							_shadowed.append([gi, (gi as GeometryInstance3D).cast_shadow])
							(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else:
				for pair in _shadowed:
					if is_instance_valid(pair[0]):
						(pair[0] as GeometryInstance3D).cast_shadow = pair[1]
				_shadowed.clear()
		"blobs":
			for b in bodies:
				var n: Node = b["node"]
				if off:
					n.remove_from_group(CharacterBlobs.GROUP)
				else:
					n.add_to_group(CharacterBlobs.GROUP)
		"overlay":
			var ov = world._overlay_view
			if ov != null and is_instance_valid(ov):
				(ov._viewport as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED if off else SubViewport.UPDATE_ALWAYS
		"run":
			for b in bodies:
				world._set_other_gait(b["id"], off)
		"move", "net":
			if step == "net":
				_net_due = 0.0
				if off:
					return
			if off:
				_move_t = 0.0
				_scatter()
			else:
				for b in bodies:
					world._other_body_targets[b["id"]] = _homes[b["id"]]
					_wake(b["id"])
					(b["node"] as Node3D).position = _homes[b["id"]]
					world._set_other_gait(b["id"], false)
		"away":
			var arm: Node3D = world.camera_arm
			arm.rotation_degrees.y += 180.0 if off else -180.0
		"gone":
			for b in bodies:
				var n: Node3D = b["node"]
				if off:
					_removed[n] = n.get_parent()
					n.get_parent().remove_child(n)
				elif _removed.has(n):
					(_removed[n] as Node).add_child(n)
					_removed.erase(n)
		"nodraw":
			for s in ["mesh", "labels", "fx", "blobs", "overlay"]:
				_switch(s, off)
		"base":
			pass
		"mute":
			# Round 747: every effect voice muted (AudioOptions.effect_muted):
			# the sounds' own playback cost, against the far step's advances.
			var svc := AudioService.instance()
			if svc != null and svc.options != null:
				svc.options.effect_muted = off
		"ab":
			if off:
				_ab.call_deferred()
		"fxab":
			if off:
				_fx_ab.call_deferred()
		"churn", "redress", "reglow":
			pass
		"plateab":
			if off:
				_plate_ab.call_deferred()
		"inlineh":
			# Round 757: the walkers' heights on the main thread (HeightBatch
			# inline) for the step, against the pool's.
			HeightBatch.threaded_min = (1 << 30) if off else HeightBatch.THREADED_MIN
		"poolbusy":
			# Round 757's review, F3: the pool kept busy for the step (as a
			# region crossing's cell prepares keep it), POOL_BUSY tasks of
			# POOL_BUSY_MS each always queued, high priority.
			_pool_busy = off
			if not off:
				for id in _pool_tasks:
					PoolWait.task(int(id))
				_pool_tasks.clear()
		"leave":
			if off:
				_leave_all()
		"half":
			if off:
				_leave_all(true)
		"cross":
			if off:
				_cross()
		"back":
			if off:
				_come_back()
		"leaveall":
			# Round 757: every lineup body leaves at once (0x3016's path): the
			# end of a crowd. Not given back; the steps after it have no bodies.
			if off:
				for b in bodies:
					world._on_entity_left(int(b["id"]))
		"zone":
			# Round 757: a zone change's arrival list with nobody in it
			# (_replace_others_for_arrival): every body freed in one frame.
			if off:
				world._replace_others_for_arrival([], [])
		"rezone":
			# Round 760: a real zone change and back, with the crowd: at the
			# step's start every body leaves with an empty arrival list and the
			# region grid is rebuilt for OPENSRO_QA_REZONE (Hotan unless set;
			# the zone change's own _reload_zone_assets: the cell prepares in
			# flight dropped, new ones started); at its end the grid is rebuilt
			# for the spawn's zone, the player stood on the spawn, and every body
			# arrives again with its kit (the arrival path: ghosts, dressing).
			_rezone(off)
		_:
			push_warning("QA CROWD: unknown step %s" % step)

## The `ab` step (round 747): one frame with the far bodies on the GPU, one
## with every body on the full path, at the same held clocks.
var _ab_n := 0

func _ab() -> void:
	var dir := OS.get_environment("OPENSRO_QA_CROWD_SHOTS")
	if dir == "":
		dir = "/var/tmp/qa_crowd_ab"
	DirAccess.make_dir_recursive_absolute(dir)
	_ab_n += 1
	var tag := "ab_%d" % _ab_n
	var tree := world.get_tree()
	var hold := func() -> void: RenderingServer.global_shader_parameter_set(EquipGlow.CLOCK_GLOBAL, EquipGlow.clock)
	world._qa_anim_hold = true
	EquipGlow.hold = true
	TexAni.hold = true
	tree.process_frame.connect(hold)
	_switch("fx", true)
	for i in range(3):
		await tree.process_frame
	var boxes := _ab_boxes()
	await RenderingServer.frame_post_draw
	var a := world.get_viewport().get_texture().get_image()
	var pa := dir.path_join(tag + "_gpu.png")
	a.save_png(pa)
	# The noise floor: the same path again after as many frames -- what moves
	# anyway (the sky, the trees, the local player, who is not held).
	for i in range(3):
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var a2 := world.get_viewport().get_texture().get_image()
	a2.save_png(dir.path_join(tag + "_gpu2.png"))
	CrowdGpu.enabled = false
	for i in range(3):
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var b := world.get_viewport().get_texture().get_image()
	var pb := dir.path_join(tag + "_near.png")
	b.save_png(pb)
	print("QA CROWD ab %s far=%d near=%d far_box=%s near_box=%s files %s %s" % [tag, int(boxes[0]), int(boxes[1]),
		_box_arg(boxes[2]), _box_arg(boxes[3]), pa, pb])
	CrowdGpu.enabled = true
	_switch("fx", false)
	tree.process_frame.disconnect(hold)
	TexAni.hold = false
	EquipGlow.hold = false
	world._qa_anim_hold = false

## Round 764's `fxab` step (EquipFxBatch): the same held frame -- clip,
## glow and texture clocks held, the effect masters frozen -- drawn four ways:
## the ghosts' particles by their batches (A), by a holder for each host the
## batches draw placed where EquipFx placed a ghost's holder (EquipFx.place of
## its GPU clip frame; B), with none (C), and by the batches again (A2, the
## noise floor). Prints each pair's mean absolute difference and the pixels
## differing by more than 8/255: the batches draw the holders' pixels when
## d(A,B) is near d(A,A2) and far under d(A,C). Frames fxab_<n>_*.png in
## OPENSRO_QA_CROWD_SHOTS.
func _fx_ab() -> void:
	var dir := OS.get_environment("OPENSRO_QA_CROWD_SHOTS")
	if dir == "":
		dir = "/var/tmp/qa_crowd_ab"
	DirAccess.make_dir_recursive_absolute(dir)
	_ab_n += 1
	var tag := "fxab_%d" % _ab_n
	var tree := world.get_tree()
	var vp := world.get_viewport()
	if not vp.has_meta(EquipFx.DRIVER_META):
		print("QA CROWD fxab: no EquipFx driver")
		return
	var d: EquipFx = vp.get_meta(EquipFx.DRIVER_META)
	if d._batch == null:
		print("QA CROWD fxab: no batches (OPENSRO_QA_EQUIPFX_BATCH=0?)")
		return
	var hold := func() -> void: RenderingServer.global_shader_parameter_set(EquipGlow.CLOCK_GLOBAL, EquipGlow.clock)
	world._qa_anim_hold = true
	EquipGlow.hold = true
	TexAni.hold = true
	tree.process_frame.connect(hold)
	d.process_mode = Node.PROCESS_MODE_DISABLED
	for i in range(3):
		await tree.process_frame
	var crowd = EquipFx.ghost_gpu.call() if EquipFx.ghost_gpu.is_valid() else null
	# The holders: one per drawn host, placed from its ghost's clip frame.
	var holders: Array = []
	var batch_draws: Array = []
	for b in d._batch._batches.values():
		for dr in b.draws:
			batch_draws.append(dr[0])
		var k = d._kinds.get(b.kind_key)
		if k == null or k.master == null:
			continue
		for h in b.drawn:
			var g = crowd.ghost_item_frame(h.anchor, h.att_bone, h.chain) if crowd != null else null
			if g == null:
				continue
			var hd := EquipFx._holder_for(k.master)
			world.add_child(hd)
			hd.set_process(false)
			hd.global_transform = EquipFx.place(g, h.pose, h.scale)
			hd.visible = false
			holders.append(hd)
	var shots := {}
	for which in ["batch", "holders", "none", "batch2"]:
		for n in batch_draws:
			if is_instance_valid(n):
				(n as Node3D).visible = which.begins_with("batch") and (n as MultiMeshInstance3D).multimesh.visible_instance_count > 0
		for hd in holders:
			(hd as Node3D).visible = which == "holders"
		for i in range(3):
			await tree.process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.save_png(dir.path_join("%s_%s.png" % [tag, which]))
		shots[which] = img
	var diff := func(x: Image, y: Image) -> Array:
		var n := 0
		var sum := 0.0
		var w := x.get_width()
		var hh := x.get_height()
		for yy in range(0, hh, 2):
			for xx in range(0, w, 2):
				var a := x.get_pixel(xx, yy)
				var c := y.get_pixel(xx, yy)
				var m := maxf(absf(a.r - c.r), maxf(absf(a.g - c.g), absf(a.b - c.b)))
				sum += m
				if m > 8.0 / 255.0:
					n += 1
		return [sum / float((w / 2) * (hh / 2)) * 255.0, n]
	var ab: Array = diff.call(shots["batch"], shots["holders"])
	var aa: Array = diff.call(shots["batch"], shots["batch2"])
	var ac: Array = diff.call(shots["batch"], shots["none"])
	print("QA CROWD fxab %s hosts=%d holders=%d d(A,B) mean %.4f px %d | d(A,A2) mean %.4f px %d | d(A,C) mean %.4f px %d (every 2nd pixel, /255)" % [
		tag, int(d._batch.stats["hosts"]), holders.size(), ab[0], ab[1], aa[0], aa[1], ac[0], ac[1]])
	for hd in holders:
		(hd as Node).queue_free()
	for n in batch_draws:
		if is_instance_valid(n):
			(n as Node3D).visible = (n as MultiMeshInstance3D).multimesh.visible_instance_count > 0
	d.process_mode = Node.PROCESS_MODE_INHERIT
	tree.process_frame.disconnect(hold)
	TexAni.hold = false
	EquipGlow.hold = false
	world._qa_anim_hold = false

## Round 757's `plateab` step: the same held frame with the other players'
## plates drawn batched (NamePlateBatch), batched again (the noise floor), and
## as Label3Ds -- `plates_<n>_batch.png`, `_batch2.png`, `_label.png` in
## OPENSRO_QA_CROWD_SHOTS, for client/tools/frame_ab.py.
func _plate_ab() -> void:
	var dir := OS.get_environment("OPENSRO_QA_CROWD_SHOTS")
	if dir == "":
		dir = "/var/tmp/qa_crowd_ab"
	DirAccess.make_dir_recursive_absolute(dir)
	_ab_n += 1
	var tag := "plates_%d" % _ab_n
	var tree := world.get_tree()
	var hold := func() -> void: RenderingServer.global_shader_parameter_set(EquipGlow.CLOCK_GLOBAL, EquipGlow.clock)
	world._qa_anim_hold = true
	EquipGlow.hold = true
	TexAni.hold = true
	tree.process_frame.connect(hold)
	_switch("fx", true)
	for i in range(3):
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var pa := dir.path_join(tag + "_batch.png")
	world.get_viewport().get_texture().get_image().save_png(pa)
	for i in range(3):
		await tree.process_frame
	await RenderingServer.frame_post_draw
	world.get_viewport().get_texture().get_image().save_png(dir.path_join(tag + "_batch2.png"))
	world._plate_batch_switch(false)
	# The sweep shows a plate within NamePlates.SWEEP_FRAMES frames of being added.
	for i in range(NamePlates.SWEEP_FRAMES + 3):
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var pb := dir.path_join(tag + "_label.png")
	world.get_viewport().get_texture().get_image().save_png(pb)
	world._plate_batch_switch(true)
	print("QA CROWD plateab %s files %s %s" % [tag, pa, pb])
	_switch("fx", false)
	tree.process_frame.disconnect(hold)
	TexAni.hold = false
	EquipGlow.hold = false
	world._qa_anim_hold = false

## [far count, near count, far bodies' screen Rect2, near bodies' screen Rect2]:
## each body's feet and a point 20 units above, through the camera.
func _ab_boxes() -> Array:
	var cam: Camera3D = world.get_viewport().get_camera_3d()
	var crowd = world.get("_crowd_gpu")
	var far := Rect2()
	var near := Rect2()
	var nf := 0
	var nn := 0
	for b in bodies:
		var n: Node3D = b["node"]
		var gait: Dictionary = world._other_gaits.get(b["id"], {})
		if cam == null or not is_instance_valid(n) or gait.is_empty() or not cam.is_position_in_frustum(n.global_position):
			continue
		var p0 := cam.unproject_position(n.global_position)
		var p1 := cam.unproject_position(n.global_position + Vector3(0, 20, 0))
		var r := Rect2(p0, Vector2.ZERO).expand(p1).grow(8.0)
		if crowd != null and (crowd as CrowdGpu).has(gait["skeleton"]):
			far = r if nf == 0 else far.merge(r)
			nf += 1
		else:
			near = r if nn == 0 else near.merge(r)
			nn += 1
	return [nf, nn, far, near]

static func _box_arg(r: Rect2) -> String:
	return "%d,%d,%d,%d" % [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)]

## The position packets due this frame, round robin over the bodies, each a
## new spot within 8 units of its home, through NetClient's own dispatch.
func _net_step(delta: float, rate: float, dest := false) -> void:
	_net_due += delta * rate * bodies.size()
	var t0 := Time.get_ticks_usec()
	# The 0xB021's frame: the connection's, else the grid's centre region
	# (an offline run has none; the client reads the packet back in it).
	if dest and NetClient._spawn_frame.x < 0:
		NetClient._spawn_frame = Vector2i(97, 168)
	while _net_due >= 1.0 and not bodies.is_empty():
		_net_due -= 1.0
		var b: Dictionary = bodies[_net_next % bodies.size()]
		_net_next += 1
		var home: Vector3 = _homes[b["id"]]
		if dest:
			var to := home + Vector3(_rng.randf_range(-8.0, 8.0), 0.0, _rng.randf_range(-8.0, 8.0))
			var l := DestMoveNet.local_of_world(to.x, to.z, NetClient._spawn_frame)
			var echo := PackedByteArray()
			echo.resize(14)
			echo.encode_u32(0, int(b["id"]) & 0xffffffff)
			echo[4] = DestMoveNet.KIND_DESTINATION
			echo.encode_u16(5, int(l["region"]))
			echo.encode_s16(7, int(float(l["lx"])))
			echo.encode_s16(9, int(home.y))
			echo.encode_s16(11, int(float(l["lz"])))
			echo[13] = 0
			NetClient._dispatch(Packet.new(DestMoveNet.OP_MOVEMENT_ECHO, echo))
			_net_sent += 1
			continue
		var payload := PackedByteArray()
		payload.resize(21)
		payload.encode_s64(0, int(b["id"]))
		payload.encode_float(8, home.x + _rng.randf_range(-8.0, 8.0))
		payload.encode_float(12, home.y)
		payload.encode_float(16, home.z + _rng.randf_range(-8.0, 8.0))
		payload[20] = 0
		NetClient._dispatch(Packet.new(WorldNet.OP_ENTITY_MOVED, payload))
		_net_sent += 1
	_net_us += Time.get_ticks_usec() - t0

## Round 757: World3D's eased walk looks only at awake bodies; a target the
## probe writes wakes its body (a base build without the set: nothing).
func _wake(id) -> void:
	var aw = world.get("_other_awake")
	if aw is Dictionary:
		(aw as Dictionary)[id] = true

## The `poolbusy` step's tasks (QA).
const POOL_BUSY := 8
const POOL_BUSY_MS := 30
var _pool_busy := false
var _pool_tasks: Array = []

static func _pool_busy_task() -> void:
	OS.delay_msec(POOL_BUSY_MS)

func _pool_busy_step() -> void:
	var keep: Array = []
	for id in _pool_tasks:
		if WorkerThreadPool.is_task_completed(int(id)):
			PoolWait.task(int(id))
		else:
			keep.append(id)
	_pool_tasks = keep
	while _pool_tasks.size() < POOL_BUSY:
		_pool_tasks.append(WorkerThreadPool.add_task(QaCrowdProbe._pool_busy_task, true, "QA pool busy"))

## Every body to a new spot within 8 units of its home (the interpolation walks
## it there with its run loop, as a server's position update does).
func _scatter() -> void:
	for b in bodies:
		var home: Vector3 = _homes[b["id"]]
		world._other_body_targets[b["id"]] = home + Vector3(_rng.randf_range(-8.0, 8.0), 0.0, _rng.randf_range(-8.0, 8.0))
		_wake(b["id"])
