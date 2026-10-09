extends RefCounted
class_name EquipFxBatch

## Round 764 (OURS; docs/rounds/r764.md sections 2 and 8): the weapon effects of
## a crowd -- every ghost's and, natively, every dressed body's but the player's
## own -- drawn in one MultiMesh draw per (effect, master draw node), instead of
## a holder node per weapon for the 64 nearest in view.
##
## **Why.** EquipFx drew a weapon's effect through a holder: a node per weapon
## sharing its master's MultiMesh, placed on the CPU every frame, a draw call a
## master draw node. Only the 64 hosts nearest the camera inside the frustum had
## one, chosen again every cycle: in the swarm 10,898 hosts were within 720
## units and in view and 64 drew, and which changed as the camera turned (the
## user's "the seal effects appear and disappear and it seems like it's based
## off camera angle", v0.1.516). Retail steps and draws a character's effects
## while its LOD -- camera distance / 800 -- is under 0.9: within 720 units,
## with no count limit (READ: FUN_00c43780, GlobalDataManager::FUN_009c4aa0;
## the review of round 764).
##
## **How, natively (SrEfpHosts, native/src/core/efp_hosts.rs).** Each frame the
## library chooses the hosts (their body shown, within 720 units and Character
## Sight Range, among the host_budget nearest in any direction -- 0: every one,
## retail's rule), culls them to the view, places each (EquipFx.place's frame:
## for a ghost from CrowdGpu's own body data and bone pages, for a dressed body
## from the frame EquipFx gives it) and packs the drawn hosts' frames into one
## texture (fxb_frames, 3 texels a host), each batch's start in another
## (fxb_offsets); it sets each draw's visible instances (hosts drawn x the
## node's stride) and its bounds (the drawn bodies', for the transparent sort).
## A particle's vertex reads its host's frame and its own transform, colour and
## custom data (fxb_parts, the master's draw buffer: 5 texels an instance).
##
## **Without the library (the fallback).** The ghosts' hosts are drawn as round
## 764 first drew them: a batch per (effect, four skeleton layouts), a host
## table EquipFx's scan chooses (the host_budget nearest), and the shader
## composing each host's frame from CrowdGpu's textures in every vertex.
## Dressed bodies keep EquipFx's holders.

## OPENSRO_QA_EQUIPFX_BATCH=0: ghosts' particles through holders, as before.
static var enabled := OS.get_environment("OPENSRO_QA_EQUIPFX_BATCH") != "0"
## OPENSRO_QA_EQUIPFX_NATIVE=0: the fallback even with the library.
static var native_wanted := OS.get_environment("OPENSRO_QA_EQUIPFX_NATIVE") != "0"
## The most hosts drawn, the nearest the camera in any direction (OURS). 0:
## every host within 720 units, as retail draws them (the review's F1: READ,
## no count limit). OPENSRO_QA_EQUIPFX_HOSTS=<n> sets it. The default stays 500
## until the user chooses (r764.md section 8).
const HOST_BUDGET := 500
static var host_budget := int(OS.get_environment("OPENSRO_QA_EQUIPFX_HOSTS")) if OS.get_environment("OPENSRO_QA_EQUIPFX_HOSTS").is_valid_int() else HOST_BUDGET
## QA: OPENSRO_QA_EQUIPFX_RANGE=<units> draws within that distance only.
static var qa_range := float(OS.get_environment("OPENSRO_QA_EQUIPFX_RANGE")) if OS.get_environment("OPENSRO_QA_EQUIPFX_RANGE").is_valid_float() else 0.0

const HOST_TEXELS := 7
const HOSTS_PER_ROW := 256
const HOST_FLOATS := HOST_TEXELS * 4
## Native: frames a frames-texture row holds (gd_efp_hosts.rs FRAMES_PER_ROW).
const FRAMES_PER_ROW := 64
const DIRECT_FLOATS := 16
## Fallback: tables rebuilt a frame while this lasts (one at least).
const REBUILD_BUDGET_USEC := 600
## The fallback's draws' bounds until their hosts' are known.
const BATCH_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))
const LAYOUTS_PER_BATCH := 4
## Empty steps before a node's draw is hidden (OURS: half a second).
const LIVE_STEPS := 10
## Tables taking new hosts are rebuilt one frame in this many (OURS); a host
## leaving rebuilds its table at once (the review's F4).
const REBUILD_EVERY := 6
## The particle texture's widest row (texels): Godot's and Vulkan's 2-D limit
## (the review's F10). 3,276 particles a node; MAX_PARTICLES is 300 an effect.
const MAX_PARTS_WIDTH := 16384
## Natively, the layouts a host table can name (efp_hosts.rs LAYOUT_MASK).
const MAX_NATIVE_LAYOUTS := 16

## Meta on a batch's draw node.
const DRAW_META := &"opensro_equipfx_batch"
## A frame's margin around the view, units (OURS, EquipFx.ALWAYS_NEAR).
const NEAR := 30.0

## A kind's particles as one texture: a row per master draw node, texel 0 its
## count, then 5 texels an instance (Godot's MultiMesh layout); updated when
## its master steps.
class Parts:
	var tex: ImageTexture = null
	var img: Image = null
	var width := 0
	var rows := 0
	var counts := PackedInt32Array()
	## Per node, the instances a host is given (grow-only): the draws'
	## fxb_per_host, so a step's new particle count changes no material and
	## no MultiMesh.
	var strides := PackedInt32Array()
	var zero := PackedInt32Array()
	var live := PackedByteArray()
	var nodes := -1

class Batch:
	var key: String
	var kind_key: String
	## Native: its id (fxb_bid), its dressed hosts, the hosts its MultiMeshes
	## have room for.
	var id := -1
	var direct: Array = []
	var direct_sent := false
	var cap_hosts := 0
	## Fallback: the layout group.
	var group := 0
	var hosts: Array = []
	var host_tex: ImageTexture = null
	var host_rows := 0
	var shown := 0
	var drawn: Array = []
	var host_data := PackedFloat32Array()
	var bounds_sent := AABB()
	## [MultiMeshInstance3D, ShaderMaterial, 0 a plate node / 1 a link, the
	## master draw (or link) index, the instances shown, the stride bound]
	var draws: Array = []
	var bones_texs: Array = [null, null, null, null]
	var built_for: Object = null
	var parts_tex: Texture = null

var native := false
var _hn: Object = null
var _batches: Dictionary = {}
var _by_kind: Dictionary = {}
var _layouts: Array = []
var _parts: Dictionary = {}
var _kind_seen: Dictionary = {}
var _dirty: Dictionary = {}
var _dirty_now := false
## Native: batches whose hosts may have outgrown their draws' room.
var _dirty_room := {}
var _pending: Array = []
var _parent: Node3D
var _crowd: Object = null
var _frame := 0
var _selected := 0
var _next_id := 0
var _clip_gen := -1
var _bodies_tex: Texture = null
var _sight := -1.0
## Native: the frames and offsets textures and their Images.
var _frames_tex: ImageTexture = null
var _frames_rows := 0
var _frames_img: Image = null
var _off_tex: ImageTexture = null
var _off_w := 0
var _off_img: Image = null
## The kinds with a host drawn (natively, each frame; their masters step).
var live_kinds := {}
var stats := {"batches": 0, "hosts": 0, "instances": 0, "draws": 0, "pending": 0, "rebuilds": 0,
	"in_reach": 0, "chosen": 0, "drawn": 0, "direct": 0}

func _init(parent: Node3D) -> void:
	_parent = parent
	if native_wanted and ClassDB.class_exists(&"SrEfpHosts"):
		_hn = ClassDB.instantiate(&"SrEfpHosts")
		native = _hn != null

## The class of the hosts' choice: whether the library chooses and places them.
static func native_available() -> bool:
	return native_wanted and ClassDB.class_exists(&"SrEfpHosts")

## A ghost's host joins its batch (when its ghost has a slot).
func add(h) -> void:
	h.batch = null
	_pending.append(h)

## A host leaves.
func remove(h) -> void:
	var b: Batch = h.batch
	if b != null:
		b.hosts.erase(h)
		if native:
			# Its slot freed says "faded out" and a new body there has another
			# stamp (CrowdGpu, the review's F4): the table waits its turn.
			_dirty[b] = true
		elif h.sel:
			_dirty[b] = true
			_dirty_now = true
		if h.sel:
			_selected -= 1
		h.sel = false
		h.batch = null
	else:
		_pending.erase(h)

## Native: a dressed body's host, drawn by its kind's batch from the frame
## EquipFx gives it each frame (direct_frames).
func add_direct(h) -> void:
	var b := _native_batch(h.key)
	_dirty_room[b] = true
	b.direct.append(h)
	h.batch = b

func remove_direct(h) -> void:
	var b: Batch = h.batch
	if b != null:
		b.direct.erase(h)
		h.batch = null

## Fallback: whether host `h` is drawn (EquipFx's choice).
func select(h, on: bool, crowd: Object = null) -> void:
	var b: Batch = h.batch
	if b != null and crowd != null and on:
		var sl: Array = crowd.call("ghost_slot_layout", h.anchor)
		if sl.is_empty() or int(sl[0]) != h.batch_slot or sl[1] != h.blayout:
			remove(h)
			add(h)
			return
	if b == null or h.sel == on:
		return
	h.sel = on
	_selected += 1 if on else -1
	_dirty[b] = true

## The hosts chosen now: the fallback's selection, the library's last choice.
func selected_count() -> int:
	return int(stats["chosen"]) if native else _selected

## Every batch, layout and texture freed (the world left; the review's F6).
func clear() -> void:
	for b in _batches.values():
		_free_draws(b)
		for h in b.hosts:
			h.batch = null
			h.sel = false
		for h in b.direct:
			h.batch = null
	_batches.clear()
	_by_kind.clear()
	_layouts.clear()
	_parts.clear()
	_kind_seen.clear()
	_dirty.clear()
	_pending.clear()
	_selected = 0
	_clip_gen = -1
	_crowd = null
	_bodies_tex = null
	_sight = -1.0
	_frames_tex = null
	_frames_rows = 0
	_off_tex = null
	_off_w = 0
	live_kinds.clear()
	_drawn_ids = PackedInt64Array()
	_fresh.clear()
	_dirty_room.clear()
	if _hn != null:
		_hn.call("clear")
	for k in ["batches", "hosts", "instances", "draws", "pending", "in_reach", "chosen", "drawn", "direct"]:
		stats[k] = 0

## Each frame, after the masters stepped. `crowd` is the CrowdGpu, `kinds`
## EquipFx's, `cam` the viewport's camera, `own` the node whose weapons are not
## drawn here (the player's: EquipFx.prefer_root).
func step(crowd: Object, kinds: Dictionary, cam: Camera3D = null, own: Node = null, stepped: Dictionary = {}) -> void:
	if crowd != _crowd:
		# Another CrowdGpu (a world entered again): nothing of the old one's.
		var keep_pending := _pending.duplicate()
		var keep_direct: Array = []
		for b in _batches.values():
			keep_direct.append_array(b.direct)
			keep_pending.append_array(b.hosts)
		clear()
		_crowd = crowd
		if crowd == null:
			return
		for h in keep_pending:
			add(h)
		if native:
			for h in keep_direct:
				add_direct(h)
	if crowd == null:
		return
	var t0 := Time.get_ticks_usec()
	_frame += 1
	if native and bool(_hn.call("broken")):
		_go_fallback(crowd)
	if native:
		_step_native(crowd, kinds, cam, own, stepped)
		# A step that panicked: the fallback from now on, this frame already.
		if bool(_hn.call("broken")):
			_go_fallback(crowd)
	else:
		_step_fallback(crowd, kinds)
	stats["pending"] = _pending.size()
	if FrameSplit.on:
		FrameSplit.add("fx_batch", Time.get_ticks_usec() - t0)

## The library's step panicked: the GDScript fallback from now on, every
## ghost host placed again and every dressed host back on EquipFx's holders
## (the re-review's R1).
func _go_fallback(crowd: Object) -> void:
	push_warning("EquipFxBatch: the native hosts failed -- the GDScript fallback from now on")
	var again: Array = _pending.duplicate()
	for b in _batches.values():
		again.append_array(b.hosts)
		for h in b.direct:
			h.direct = false
			h.batch = null
		b.direct.clear()
	native = false
	clear()
	_crowd = crowd
	for h in again:
		add(h)

# --- native ------------------------------------------------------------------------

func _native_batch(kind_key: String) -> Batch:
	var b: Batch = _batches.get(kind_key)
	if b == null:
		b = Batch.new()
		b.key = kind_key
		b.kind_key = kind_key
		b.id = _next_id
		_next_id += 1
		_batches[kind_key] = b
		_by_kind[kind_key] = [b]
		stats["batches"] = _batches.size()
		_fresh[b] = true
	return b

## Batches made, or whose draws are to be made again, since the last frame.
var _fresh := {}

func _step_native(crowd: Object, kinds: Dictionary, cam: Camera3D, own: Node, stepped: Dictionary) -> void:
	# The layouts' bone pages, again whenever a clip went up.
	var gen := int(crowd.get("clip_generation"))
	if gen != _clip_gen:
		_clip_gen = gen
		for i in _layouts.size():
			var l = _layouts[i]
			_hn.call("set_layout", i, int(l.get("width")), l.get("pages"))
	# Hosts whose ghost has a slot join their kind's batch.
	if not _pending.is_empty():
		var keep: Array = []
		for h in _pending:
			if h.anchor == null or not is_instance_valid(h.anchor):
				continue
			var sl: Array = crowd.call("ghost_slot_layout", h.anchor)
			if sl.is_empty():
				keep.append(h)
				continue
			var gi := _layouts.find(sl[1])
			if gi < 0:
				if _layouts.size() >= MAX_NATIVE_LAYOUTS:
					# The re-review's R5: a host names one of 16 layouts (4
					# bits); another layout's hosts are not drawn (none seen:
					# the swarm has 2).
					continue
				gi = _layouts.size()
				_layouts.append(sl[1])
				_hn.call("set_layout", gi, int(sl[1].get("width")), sl[1].get("pages"))
			var b := _native_batch(h.key)
			_dirty_room[b] = true
			h.batch = b
			h.batch_slot = int(sl[0])
			h.blayout = sl[1]
			# Natively the layout and the slot's stamp ride together (layout
			# + 16 x stamp: CrowdGpu.SLOT_STAMPS keeps it under 2^24).
			h.rows = _host_rows(h, sl[1], gi + 16 * int(sl[2]), true)
			b.hosts.append(h)
			_dirty[b] = true
		_pending = keep
	# The tables: at once after a host left (its slot may be another body's
	# soon), else one frame in REBUILD_EVERY.
	if not _dirty.is_empty() and (_dirty_now or _frame % REBUILD_EVERY == 0):
		for b in _dirty.keys():
			var data := PackedFloat32Array()
			for h in b.hosts:
				data.append_array(h.rows)
			_hn.call("set_ghosts", b.id, data)
			stats["rebuilds"] = int(stats["rebuilds"]) + 1
		_dirty.clear()
		_dirty_now = false
	# The dressed bodies' frames (EquipFx.place of their item skeleton).
	var from := cam.global_position if cam != null else Vector3.ZERO
	var nd := 0
	for key in _batches:
		var b: Batch = _batches[key]
		if b.direct.is_empty():
			if b.direct_sent:
				_hn.call("set_direct", b.id, PackedFloat32Array())
				b.direct_sent = false
			continue
		var data := PackedFloat32Array()
		for h in b.direct:
			var sk: Skeleton3D = h.skel
			if not is_instance_valid(sk) or not sk.is_inside_tree() or not sk.is_visible_in_tree():
				continue
			if own != null and is_instance_valid(own) and own.is_ancestor_of(sk):
				continue
			var o = EquipFx.far_origin.call(sk) if EquipFx.far_origin.is_valid() else null
			var p: Vector3 = o if o != null else sk.global_position
			if p.distance_to(from) > EquipFx.MAX_DISTANCE:
				continue
			var f := EquipFx.holder_transform(sk, h.bone, h.scale, EquipFx._far(sk))
			var at := data.size()
			data.resize(at + DIRECT_FLOATS)
			_put_rows(data, at, f)
			data[at + 12] = p.x
			data[at + 13] = p.y
			data[at + 14] = p.z
			nd += 1
		_hn.call("set_direct", b.id, data)
		b.direct_sent = true
	stats["direct"] = nd
	var t_pt := Time.get_ticks_usec() if FrameSplit.on else 0
	# The particles, the draws and their room: only the kinds whose master
	# stepped this frame (EquipFx), the batches made since the last, and those
	# whose hosts outgrew their room (the review's F9: nothing for the rest).
	var todo := _fresh.duplicate()
	_fresh.clear()
	for key in stepped:
		var sb: Batch = _batches.get(key)
		if sb != null:
			todo[sb] = true
	for b in _dirty_room:
		todo[b] = true
	_dirty_room.clear()
	for bb in todo:
		var b: Batch = bb
		var key := b.key
		var k = kinds.get(b.kind_key)
		if k == null or k.master == null or not is_instance_valid(k.master):
			continue
		var m: EfpEffect = k.master
		var grew := false
		if b.built_for != m:
			_build_draws(b, m)
			grew = true
		if int(_kind_seen.get(key, -1)) != m.draw_updates:
			_kind_seen[key] = m.draw_updates
			grew = _upload_parts(key, m) or grew
		var pt: Parts = _parts.get(key)
		if pt != null and pt.tex != b.parts_tex:
			b.parts_tex = pt.tex
			for d in b.draws:
				if int(d[2]) == 0:
					(d[1] as ShaderMaterial).set_shader_parameter("fxb_parts", pt.tex)
		if b.built_for != m:
			_fresh[b] = true
		var n: int = b.hosts.size() + b.direct.size()
		if n > b.cap_hosts:
			b.cap_hosts = maxi(n, ceili(b.cap_hosts * 1.5))
			grew = true
		if grew:
			_native_draws(b)
	if FrameSplit.on:
		FrameSplit.add("fxb_parts", Time.get_ticks_usec() - t_pt)
	var t_rs := Time.get_ticks_usec() if FrameSplit.on else 0
	# Choose, cull, place.
	var vp := Transform3D()
	var sx := 1.0
	var sy := 1.0
	var ortho := false
	if cam != null:
		vp = cam.global_transform.affine_inverse()
		var pr := cam.get_camera_projection()
		sx = absf(pr.x.x)
		sy = absf(pr.y.y)
		ortho = cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	# The re-review's R6: room for every host that may be drawn this frame,
	# before the step (a texture made after it would be drawn empty once).
	var could := 0
	for b in _batches.values():
		could += b.hosts.size() + b.direct.size()
	if host_budget > 0:
		could = mini(could, host_budget)
	could = maxi(could, int(_hn.call("needed_frames")))
	if _frames_tex == null or could > _frames_rows * FRAMES_PER_ROW:
		_grow_frames(maxi(could, FRAMES_PER_ROW * 4))
	var reach := qa_range if qa_range > 0.0 else EquipFx.MAX_DISTANCE
	var bytes: PackedByteArray = _hn.call("step", crowd.call("body_data"), float(crowd.call("clock_ms")), crowd.call("reveal_clocks"),
		vp, from, sx, sy, ortho, reach, float(crowd.call("sight_range")), NEAR, host_budget, _frames_rows,
		EfpSimNative.threads)
	if bytes.size() == _frames_rows * FRAMES_PER_ROW * 3 * 16:
		_frames_img.set_data(FRAMES_PER_ROW * 3, _frames_rows, false, Image.FORMAT_RGBAF, bytes)
		_frames_tex.update(_frames_img)
	if FrameSplit.on:
		FrameSplit.add("fxb_native", Time.get_ticks_usec() - t_rs)
	var tot: PackedInt64Array = _hn.call("totals")
	stats["in_reach"] = tot[0]
	stats["chosen"] = tot[1]
	stats["drawn"] = tot[2]
	if FrameSplit.on and _frame % 600 == 0:
		print("QA FXBATCH frame %d: hosts within reach %d, chosen %d (budget %d), drawn %d, direct %d, batches %d, frames rows %d" % [
			_frame, tot[0], tot[1], host_budget, tot[2], int(stats["direct"]), _batches.size(), _frames_rows])
	# Each batch's start, and the kinds drawn.
	if _off_tex == null or _next_id > _off_w:
		_off_w = maxi(16, nearest_po2(_next_id))
		_off_img = Image.create_empty(_off_w, 1, false, Image.FORMAT_RF)
		_off_tex = ImageTexture.create_from_image(_off_img)
		for b in _batches.values():
			for d in b.draws:
				(d[1] as ShaderMaterial).set_shader_parameter("fxb_offsets", _off_tex)
	_off_img.set_data(_off_w, 1, false, Image.FORMAT_RF, _hn.call("offsets_bytes", _off_w))
	_off_tex.update(_off_img)
	var ids: PackedInt64Array = _hn.call("drawn_ids")
	if ids != _drawn_ids:
		_drawn_ids = ids
		live_kinds.clear()
		var byid := {}
		for b in _batches.values():
			byid[b.id] = b
		for id in ids:
			var b: Batch = byid.get(int(id))
			if b != null:
				live_kinds[b.kind_key] = true
	stats["hosts"] = int(stats["drawn"])
	stats["instances"] = tot[3]
	stats["draws"] = tot[4]

var _drawn_ids := PackedInt64Array()

## A batch's draws' room (its hosts x each node's stride) and their strides,
## told to the library.
func _native_draws(b: Batch) -> void:
	var pt: Parts = _parts.get(b.kind_key)
	var mms: Array = []
	var strides := PackedInt32Array()
	var insts: Array = []
	for d in b.draws:
		var mmi: MultiMeshInstance3D = d[0]
		var per := 1
		if int(d[2]) == 0:
			var ni := int(d[3])
			per = pt.strides[ni] if pt != null and ni < pt.strides.size() and pt.live[ni] == 1 else 0
			if per > 0 and int(d[5]) != per:
				(d[1] as ShaderMaterial).set_shader_parameter("fxb_per_host", per)
		d[5] = per
		var want: int = b.cap_hosts * per
		if mmi.multimesh.instance_count < want:
			mmi.multimesh.instance_count = want
		mmi.multimesh.visible_instance_count = 0
		mmi.visible = per > 0
		mms.append(mmi.multimesh.get_rid())
		strides.append(per)
		insts.append(mmi.get_instance())
	_hn.call("set_draws", b.id, mms, strides, insts)

## The frames texture, room for `frames` hosts (a quarter more), bound again.
func _grow_frames(frames: int) -> void:
	_frames_rows = maxi(ceili(frames * 1.25 / FRAMES_PER_ROW), 4)
	_frames_img = Image.create_empty(FRAMES_PER_ROW * 3, _frames_rows, false, Image.FORMAT_RGBAF)
	_frames_tex = ImageTexture.create_from_image(_frames_img)
	for b in _batches.values():
		for d in b.draws:
			(d[1] as ShaderMaterial).set_shader_parameter("fxb_frames", _frames_tex)

# --- the fallback --------------------------------------------------------------------

func _step_fallback(crowd: Object, kinds: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	_place_pending_fallback(crowd)
	var bodies_tex: Texture = crowd.call("body_texture")
	var sight: float = crowd.call("sight_range")
	var crowd_changed := bodies_tex != _bodies_tex or sight != _sight
	_bodies_tex = bodies_tex
	_sight = sight
	var touched := {}
	for key in _by_kind:
		var k = kinds.get(key)
		if k == null or k.master == null or not is_instance_valid(k.master):
			continue
		var m: EfpEffect = k.master
		var grew := false
		if int(_kind_seen.get(key, -1)) != m.draw_updates:
			_kind_seen[key] = m.draw_updates
			grew = _upload_parts(key, m)
		var pt: Parts = _parts.get(key)
		for b in _by_kind[key]:
			if b.built_for != m:
				_build_draws(b, m)
				crowd_changed = true
				touched[b] = true
			var rebind := crowd_changed
			for li in LAYOUTS_PER_BATCH:
				var gi: int = b.group * LAYOUTS_PER_BATCH + li
				var bones: Texture = _layouts[gi].get("tex") if gi < _layouts.size() else null
				if bones != b.bones_texs[li]:
					b.bones_texs[li] = bones
					rebind = true
			if rebind:
				for d in b.draws:
					var mat: ShaderMaterial = d[1]
					for li in LAYOUTS_PER_BATCH:
						if b.bones_texs[li] != null:
							mat.set_shader_parameter("crowd_bones" if li == 0 else "crowd_bones%d" % li, b.bones_texs[li])
					mat.set_shader_parameter("crowd_bodies", bodies_tex)
					mat.set_shader_parameter("crowd_range", sight)
			if pt != null and pt.tex != b.parts_tex:
				b.parts_tex = pt.tex
				for d in b.draws:
					if int(d[2]) == 0:
						(d[1] as ShaderMaterial).set_shader_parameter("fxb_parts", pt.tex)
			if grew:
				touched[b] = true
	var rebuilt := 0
	if _dirty_now or _frame % REBUILD_EVERY == 0:
		for b in _dirty.keys():
			if rebuilt > 0 and Time.get_ticks_usec() - t0 >= REBUILD_BUDGET_USEC:
				break
			_dirty.erase(b)
			_upload_hosts(b, crowd)
			touched[b] = true
			rebuilt += 1
		_dirty_now = false
	stats["rebuilds"] = int(stats["rebuilds"]) + rebuilt
	for b in touched:
		_apply_counts(b)
	stats["chosen"] = _selected

func _apply_counts(b: Batch) -> void:
	var pt: Parts = _parts.get(b.kind_key)
	for d in b.draws:
		var mmi: MultiMeshInstance3D = d[0]
		var per := 1
		if int(d[2]) == 0:
			var ni := int(d[3])
			per = pt.strides[ni] if pt != null and ni < pt.strides.size() and pt.live[ni] == 1 else 0
			if per > 0 and int(d[5]) != per:
				d[5] = per
				(d[1] as ShaderMaterial).set_shader_parameter("fxb_per_host", per)
		var want := b.shown * per
		if want == int(d[4]):
			continue
		stats["instances"] = int(stats["instances"]) + want - int(d[4])
		stats["draws"] = int(stats["draws"]) + (1 if want > 0 else 0) - (1 if int(d[4]) > 0 else 0)
		var mm := mmi.multimesh
		if want > mm.instance_count:
			mm.instance_count = maxi(want, mm.instance_count * 2)
		mm.visible_instance_count = want
		d[4] = want
		if mmi.visible != (want > 0):
			mmi.visible = want > 0

func _place_pending_fallback(crowd: Object) -> void:
	if _pending.is_empty():
		return
	var keep: Array = []
	for h in _pending:
		if h.anchor == null or not is_instance_valid(h.anchor):
			continue
		var sl: Array = crowd.call("ghost_slot_layout", h.anchor)
		if sl.is_empty():
			keep.append(h)
			continue
		var layout: Object = sl[1]
		var gi := _layouts.find(layout)
		if gi < 0:
			gi = _layouts.size()
			_layouts.append(layout)
		var group := gi / LAYOUTS_PER_BATCH
		var key := "%s|%d" % [h.key, group]
		var b: Batch = _batches.get(key)
		if b == null:
			b = Batch.new()
			b.key = key
			b.kind_key = h.key
			b.group = group
			_batches[key] = b
			if not _by_kind.has(h.key):
				_by_kind[h.key] = []
			(_by_kind[h.key] as Array).append(b)
			stats["batches"] = _batches.size()
		h.batch = b
		h.batch_slot = int(sl[0])
		h.blayout = layout
		h.rows = _host_rows(h, layout, gi % LAYOUTS_PER_BATCH, false)
		b.hosts.append(h)
		# Drawn at once while the budget has room (EquipFx's scan chooses).
		h.sel = host_budget <= 0 or _selected < host_budget
		if h.sel:
			_selected += 1
			_dirty[b] = true
	_pending = keep

## The fallback's table: the chosen hosts, HOST_TEXELS each; and the draws'
## bounds, their bodies' (the review's F7).
func _upload_hosts(b: Batch, crowd: Object) -> void:
	var drawn: Array = []
	var bounds := AABB()
	var first := true
	for h in b.hosts:
		if not h.sel:
			continue
		drawn.append(h)
		var p = crowd.call("ghost_origin", h.anchor) if crowd != null else null
		if p is Vector3 and (p as Vector3).is_finite():
			if first:
				bounds = AABB(p, Vector3.ZERO)
				first = false
			else:
				bounds = bounds.expand(p)
	var n := drawn.size()
	var rows := maxi(ceili(float(n) / HOSTS_PER_ROW), 1)
	var data := PackedFloat32Array()
	for h in drawn:
		data.append_array(h.rows)
	data.resize(rows * HOSTS_PER_ROW * HOST_FLOATS)
	b.drawn = drawn
	var img := Image.create_from_data(HOSTS_PER_ROW * HOST_TEXELS, rows, false, Image.FORMAT_RGBAF, data.to_byte_array())
	if b.host_tex == null or b.host_rows != rows:
		b.host_tex = ImageTexture.create_from_image(img)
		b.host_rows = rows
		for d in b.draws:
			(d[1] as ShaderMaterial).set_shader_parameter("fxb_hosts", b.host_tex)
	else:
		b.host_tex.update(img)
	stats["hosts"] = int(stats["hosts"]) + n - b.shown
	b.shown = n
	b.host_data = data
	if not first:
		var box := bounds.grow(40.0)
		if not box.is_equal_approx(b.bounds_sent) and (b.bounds_sent.size == Vector3.ZERO
				or (box.position - b.bounds_sent.position).length() > 16.0 or (box.end - b.bounds_sent.end).length() > 16.0):
			b.bounds_sent = box
			for d in b.draws:
				if is_instance_valid(d[0]):
					RenderingServer.instance_set_custom_aabb((d[0] as MultiMeshInstance3D).get_instance(), box)

# --- shared ------------------------------------------------------------------------

## A ghost host's texels (HOST_TEXELS): (slot, bone, row scale, its layout --
## natively its index in the library's list, in the fallback 1 + its index in
## the batch), the item's rest x chain, and that x the bone's pose.
static func _host_rows(h, layout: Object, layout_index: int, global: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(HOST_FLOATS)
	out[0] = float(h.batch_slot)
	out[1] = float(h.att_bone)
	out[2] = h.scale
	out[3] = float(layout_index) if global else 1.0 + float(layout_index)
	var rests: Array = layout.get("rests")
	var r: Transform3D = rests[h.att_bone] * h.chain if h.att_bone >= 0 and h.att_bone < rests.size() else h.chain
	_put_rows(out, 4, r)
	_put_rows(out, 16, r * h.pose)
	return out

static func _put_rows(data: PackedFloat32Array, o: int, t: Transform3D) -> void:
	for r in 3:
		data[o + r * 4] = t.basis.x[r]
		data[o + r * 4 + 1] = t.basis.y[r]
		data[o + r * 4 + 2] = t.basis.z[r]
		data[o + r * 4 + 3] = t.origin[r]

## A kind's particles: every master draw node's buffer, a row each. True when
## a node's stride or liveness changed.
func _upload_parts(kind_key: String, master: EfpEffect) -> bool:
	var pt: Parts = _parts.get(kind_key)
	if pt == null:
		pt = Parts.new()
		_parts[kind_key] = pt
	var before := pt.strides.duplicate()
	var live_before := pt.live.duplicate()
	if pt.nodes < 0:
		pt.nodes = master.batch_nodes().size()
	var n := pt.nodes
	if pt.zero.size() != n:
		pt.zero.resize(n)
		pt.live.resize(n)
	var counts := master.draw_count_list()
	counts.resize(n)
	var widest := 1
	if pt.strides.size() != n:
		pt.strides.resize(n)
	var max_stride := (MAX_PARTS_WIDTH - 1) / 5
	for i in n:
		var c := mini(counts[i], max_stride)
		counts[i] = c
		pt.zero[i] = 0 if c > 0 else pt.zero[i] + 1
		pt.live[i] = 1 if pt.zero[i] < LIVE_STEPS else 0
		if pt.strides[i] < c:
			# Grow-only, a quarter over (OURS); never past the texture's width.
			pt.strides[i] = mini(maxi(ceili(c * 1.25 / 4.0) * 4, 4), max_stride)
		widest = maxi(widest, pt.strides[i])
	var rows := maxi(n, 1)
	var width := pt.width
	if 1 + widest * 5 > width:
		width = mini(maxi(1 + widest * 5, width * 2), MAX_PARTS_WIDTH)
	# Natively the texture's bytes in one call (gd_efp.rs draw_rows_bytes).
	var bytes := master.draw_rows_bytes(width, rows)
	if bytes.size() == width * rows * 16:
		if pt.tex == null or width != pt.width or rows != pt.rows:
			pt.img = Image.create_from_data(width, rows, false, Image.FORMAT_RGBAF, bytes)
			pt.tex = ImageTexture.create_from_image(pt.img)
		else:
			pt.img.set_data(width, rows, false, Image.FORMAT_RGBAF, bytes)
			pt.tex.update(pt.img)
		pt.width = width
		pt.rows = rows
		pt.counts = counts
		return pt.strides != before or pt.live != live_before
	var data := master.draw_rows(width, rows)
	if data.size() != width * rows * 4:
		data = PackedFloat32Array()
		for i in rows:
			var c := float(counts[i]) if i < counts.size() else 0.0
			data.append_array(PackedFloat32Array([c, 0.0, 0.0, 0.0]))
			if i < n:
				var b := master.draw_buffer(i)
				if b.size() > (width - 1) * 4:
					b.resize((width - 1) * 4)
				data.append_array(b)
			data.resize((i + 1) * width * 4)
	var img := Image.create_from_data(width, rows, false, Image.FORMAT_RGBAF, data.to_byte_array())
	if pt.tex == null or width != pt.width or rows != pt.rows:
		pt.tex = ImageTexture.create_from_image(img)
	else:
		pt.tex.update(img)
	pt.width = width
	pt.rows = rows
	pt.counts = counts
	return pt.strides != before or pt.live != live_before

## A batch's draws for its kind's master: one per plate node, one per Link.
func _build_draws(b: Batch, master: EfpEffect) -> void:
	_free_draws(b)
	b.built_for = master
	var nodes := master.batch_nodes()
	for e in nodes:
		var src: GeometryInstance3D = e[1]
		var src_mat := src.material_override as ShaderMaterial
		if src_mat == null or src_mat.shader == null:
			continue
		# A new material with the node's uniforms (EfpEffect.material_for's),
		# not a duplicate(): ShaderMaterial's copy lists the shader's
		# parameters, a RenderingServer sync each.
		var mat := ShaderMaterial.new()
		mat.shader = batch_shader(src_mat.shader, native)
		for u in ["tex", "c_op", "c_a1", "c_a2", "a_op", "a_a1", "a_a2"]:
			var v = src_mat.get_shader_parameter(u)
			if v != null:
				mat.set_shader_parameter(u, v)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		if e[0] == 0:
			mm.mesh = ((src as MultiMeshInstance3D).multimesh).mesh
		else:
			mm.mesh = (src as MeshInstance3D).mesh
		mm.instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "EquipFxBatch"
		mmi.set_meta(DRAW_META, true)
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.top_level = true
		_parent.add_child(mmi)
		mmi.global_transform = Transform3D.IDENTITY
		RenderingServer.instance_set_custom_aabb(mmi.get_instance(), BATCH_AABB)
		mat.set_shader_parameter("fxb_per_host", 1)
		mat.set_shader_parameter("fxb_row", int(e[2]) if e[0] == 0 else 0)
		if native:
			mat.set_shader_parameter("fxb_bid", b.id)
			if _frames_tex != null:
				mat.set_shader_parameter("fxb_frames", _frames_tex)
			if _off_tex != null:
				mat.set_shader_parameter("fxb_offsets", _off_tex)
		else:
			if b.host_tex != null:
				mat.set_shader_parameter("fxb_hosts", b.host_tex)
			mat.set_shader_parameter("fxb_range", qa_range if qa_range > 0.0 else EquipFx.MAX_DISTANCE)
		mmi.visible = false
		b.draws.append([mmi, mat, 0 if e[0] == 0 else 1, int(e[2]), 0, 1])
	b.parts_tex = null
	b.bones_texs = [null, null, null, null]
	b.bounds_sent = AABB()

func _free_draws(b: Batch) -> void:
	for d in b.draws:
		if is_instance_valid(d[0]):
			(d[0] as Node).queue_free()
	b.draws.clear()
	b.built_for = null

## Tests (the fallback): host `i` of batch `b`'s holder frame as the shader
## composes it, in GDScript from the same data, or null.
static func cpu_hold(crowd: CrowdGpu, b: Batch, i: int):
	var o := i * HOST_FLOATS
	if i < 0 or i >= b.drawn.size() or o + HOST_FLOATS > b.host_data.size():
		return null
	var hd := b.host_data
	var slot := int(hd[o] + 0.5)
	var bone := int(hd[o + 1] + 0.5)
	var body := CrowdGpu._row_xf(crowd._body_data, slot * CrowdGpu.FLOATS_PER_BODY)
	var h = b.drawn[i]
	var cb: CrowdGpu.Body = crowd._bodies.get(h.anchor)
	if cb == null:
		return null
	var clip: Vector3i = cb.layout.clips.get(cb.frames, Vector3i(0, 1, 1))
	var row: int = clip.x + crowd.frame_of(h.anchor, crowd._last_time)
	var k: Transform3D = body * CrowdGpu._bone_xf(h.blayout, row, bone)
	var g: Transform3D = k * CrowdGpu._row_xf(hd, o + 4)
	var a: Transform3D = k * CrowdGpu._row_xf(hd, o + 16)
	var s := hd[o + 2] * pow(absf(g.basis.determinant()), 1.0 / 3.0)
	return Transform3D(a.basis.orthonormalized() * s, a.origin)

## Tests (native): host `h`'s frame as the library places it, or null.
func native_frame(crowd: CrowdGpu, h):
	if not native or h.batch == null or h.anchor == null:
		return null
	var cb: CrowdGpu.Body = crowd._bodies.get(h.anchor)
	if cb == null:
		return null
	var body := crowd._body_data.slice(cb.slot * CrowdGpu.FLOATS_PER_BODY, (cb.slot + 1) * CrowdGpu.FLOATS_PER_BODY)
	var f: PackedFloat32Array = _hn.call("qa_ghost_frame", body, h.rows, crowd.clock_ms(), int(h.rows[3]) % 16)
	if f.size() != 12:
		return null
	return CrowdGpu._row_xf(f, 0)

# --- the shaders ---------------------------------------------------------------------

static var _shaders: Dictionary = {}

## Natively: the host's frame from fxb_frames (its batch's start in
## fxb_offsets plus its index); every host drawn is chosen and in view.
const HEAD_NATIVE := """
	int fxb_n = max(fxb_per_host, 1);
	int fxb_h = INSTANCE_ID / fxb_n;
	int fxb_p = INSTANCE_ID % fxb_n;
	bool fxb_off = fxb_p >= FXB_COUNT;
	mat4 fxb_model = mat4(1.0);
	vec4 fxb_cus = vec4(0.0);
	if (!fxb_off) {
		int fxb_g = int(texelFetch(fxb_offsets, ivec2(fxb_bid, 0), 0).x + 0.5) + fxb_h;
		ivec2 fxb_at = ivec2((fxb_g % 64) * 3, fxb_g / 64);
		fxb_model = fxb_mat(texelFetch(fxb_frames, fxb_at, 0), texelFetch(fxb_frames, fxb_at + ivec2(1, 0), 0),
			texelFetch(fxb_frames, fxb_at + ivec2(2, 0), 0));
		{PARTICLE}
	}
"""

## The fallback: the host's frame composed from CrowdGpu's textures (the
## body's transform and clip frame's bone x the item's rest, chain and pose,
## orthonormalised, scaled by the row's scale x cbrt(|det G|)), and whether it
## draws (its page shown, not fading out, within 720 and Character Sight
## Range, within FXB_NEAR of the frustum).
const HEAD := """
	int fxb_n = max(fxb_per_host, 1);
	int fxb_h = INSTANCE_ID / fxb_n;
	int fxb_p = INSTANCE_ID % fxb_n;
	ivec2 fxb_at = ivec2((fxb_h % 256) * 7, fxb_h / 256);
	bool fxb_pad = fxb_p >= FXB_COUNT;
	bool fxb_off = true;
	vec4 fxb_m = vec4(0.0);
	ivec3 fxb_b = ivec3(0);
	mat4 fxb_body = mat4(1.0);
	if (!fxb_pad) {
		fxb_m = texelFetch(fxb_hosts, fxb_at, 0);
		int fxb_slot = int(fxb_m.x + 0.5);
		fxb_b = ivec3((fxb_slot % 256) * SRR_CG_TEXELS, 0, fxb_slot / 256);
		fxb_body = srr_cg_mat(texelFetch(crowd_bodies, fxb_b, 0), texelFetch(crowd_bodies, fxb_b + ivec3(1, 0, 0), 0),
			texelFetch(crowd_bodies, fxb_b + ivec3(2, 0, 0), 0));
		vec4 fxb_t4 = texelFetch(crowd_bodies, fxb_b + ivec3(4, 0, 0), 0);
		vec3 fxb_v = (VIEW_MATRIX * vec4(fxb_body[3].xyz, 1.0)).xyz;
		float fxb_d = length(fxb_v);
		float fxb_sx = PROJECTION_MATRIX[0][0];
		float fxb_sy = PROJECTION_MATRIX[1][1];
		fxb_off = fxb_m.w < 0.5 || fxb_t4.y < 0.0 || (fxb_t4.y >= 3.5e6 && srr_cg_fade(fxb_t4.y) <= 0.0)
			|| fxb_d > fxb_range || (crowd_range > 0.0 && fxb_d > crowd_range)
			|| (PROJECTION_MATRIX[3][3] < 0.5 && (-fxb_v.z + FXB_NEAR < 0.0
				|| abs(fxb_v.x) * fxb_sx > -fxb_v.z + FXB_NEAR * sqrt(fxb_sx * fxb_sx + 1.0)
				|| abs(fxb_v.y) * fxb_sy > -fxb_v.z + FXB_NEAR * sqrt(fxb_sy * fxb_sy + 1.0)));
	}
	mat4 fxb_model = mat4(1.0);
	vec4 fxb_cus = vec4(0.0);
	if (!fxb_off) {
		vec4 fxb_an = texelFetch(crowd_bodies, fxb_b + ivec3(3, 0, 0), 0);
		int fxb_count = max(int(fxb_an.y + 0.5), 1);
		float fxb_ms = mod(srr_crowd_clock + fxb_an.w, max(fxb_an.z, 1.0));
		int fxb_frame = int(fxb_an.x + 0.5) + int(fxb_ms / SRR_CG_QUANTUM_MS + 0.5) % fxb_count;
		mat4 fxb_k = fxb_body * fxb_bone(int(fxb_m.w + 0.5) - 1, int(fxb_m.y + 0.5), fxb_frame);
		mat4 fxb_g = fxb_k * srr_cg_mat(texelFetch(fxb_hosts, fxb_at + ivec2(1, 0), 0), texelFetch(fxb_hosts, fxb_at + ivec2(2, 0), 0),
			texelFetch(fxb_hosts, fxb_at + ivec2(3, 0), 0));
		mat4 fxb_a = fxb_k * srr_cg_mat(texelFetch(fxb_hosts, fxb_at + ivec2(4, 0), 0), texelFetch(fxb_hosts, fxb_at + ivec2(5, 0), 0),
			texelFetch(fxb_hosts, fxb_at + ivec2(6, 0), 0));
		vec3 fxb_x = normalize(fxb_a[0].xyz);
		vec3 fxb_y = normalize(fxb_a[1].xyz - fxb_x * dot(fxb_x, fxb_a[1].xyz));
		vec3 fxb_z = normalize(fxb_a[2].xyz - fxb_x * dot(fxb_x, fxb_a[2].xyz) - fxb_y * dot(fxb_y, fxb_a[2].xyz));
		float fxb_s = fxb_m.z * pow(abs(determinant(mat3(fxb_g))), 1.0 / 3.0);
		fxb_model = mat4(vec4(fxb_x * fxb_s, 0.0), vec4(fxb_y * fxb_s, 0.0), vec4(fxb_z * fxb_s, 0.0), vec4(fxb_a[3].xyz, 1.0));
		{PARTICLE}
	}
"""

## A plate node's particle (fxb_parts: its row, 5 texels an instance), on the
## holder frame.
const PARTICLE := """
		ivec2 fxb_pa = ivec2(1 + fxb_p * 5, fxb_row);
		fxb_model = fxb_model * fxb_mat(texelFetch(fxb_parts, fxb_pa, 0), texelFetch(fxb_parts, fxb_pa + ivec2(1, 0), 0),
			texelFetch(fxb_parts, fxb_pa + ivec2(2, 0), 0));
		COLOR *= texelFetch(fxb_parts, fxb_pa + ivec2(3, 0), 0);
		fxb_cus = texelFetch(fxb_parts, fxb_pa + ivec2(4, 0), 0);
"""

const PLAIN := """
	VERTEX = (VIEW_MATRIX * fxb_model * vec4(VERTEX, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
"""

## A host that draws nothing puts its vertices behind the camera.
const TAIL := """
	if (fxb_off) {
		VERTEX = vec3(0.0, 0.0, 1.0);
	}
"""

const MAT := """
// Three row texels as a mat4 (CrowdGpu's layout).
mat4 fxb_mat(vec4 r0, vec4 r1, vec4 r2) {
	return mat4(vec4(r0.x, r1.x, r2.x, 0.0), vec4(r0.y, r1.y, r2.y, 0.0), vec4(r0.z, r1.z, r2.z, 0.0), vec4(r0.w, r1.w, r2.w, 1.0));
}
"""

const UNIFORMS_NATIVE := """
uniform sampler2D fxb_frames : filter_nearest, repeat_disable;
uniform sampler2D fxb_offsets : filter_nearest, repeat_disable;
uniform sampler2D fxb_parts : filter_nearest, repeat_disable;
uniform int fxb_bid = 0;
uniform int fxb_per_host = 1;
uniform int fxb_row = 0;
"""

const UNIFORMS := """
#include "res://scripts/world/crowd_gpu.gdshaderinc"
uniform sampler2D fxb_hosts : filter_nearest, repeat_disable;
uniform sampler2D fxb_parts : filter_nearest, repeat_disable;
uniform int fxb_per_host = 1;
uniform int fxb_row = 0;
uniform float fxb_range = 720.0;
const float FXB_NEAR = 30.0;
uniform sampler2DArray crowd_bones1 : filter_nearest, repeat_disable;
uniform sampler2DArray crowd_bones2 : filter_nearest, repeat_disable;
uniform sampler2DArray crowd_bones3 : filter_nearest, repeat_disable;
mat4 fxb_bone(int fxb_l, int fxb_bi, int fxb_r) {
	ivec3 fxb_q = ivec3(fxb_bi * 3, fxb_r % SRR_CG_PAGE_ROWS, fxb_r / SRR_CG_PAGE_ROWS);
	if (fxb_l == 1) {
		return srr_cg_mat(texelFetch(crowd_bones1, fxb_q, 0), texelFetch(crowd_bones1, fxb_q + ivec3(1, 0, 0), 0), texelFetch(crowd_bones1, fxb_q + ivec3(2, 0, 0), 0));
	} else if (fxb_l == 2) {
		return srr_cg_mat(texelFetch(crowd_bones2, fxb_q, 0), texelFetch(crowd_bones2, fxb_q + ivec3(1, 0, 0), 0), texelFetch(crowd_bones2, fxb_q + ivec3(2, 0, 0), 0));
	} else if (fxb_l == 3) {
		return srr_cg_mat(texelFetch(crowd_bones3, fxb_q, 0), texelFetch(crowd_bones3, fxb_q + ivec3(1, 0, 0), 0), texelFetch(crowd_bones3, fxb_q + ivec3(2, 0, 0), 0));
	}
	return srr_cg_bone(fxb_bi, fxb_r);
}
"""

## `sh` (a master draw node's shader) with its vertex stage replaced by the
## batch's (natively or the fallback's): the same body as the node's own, its
## MODEL_MATRIX the host's frame times the particle's, its INSTANCE_CUSTOM the
## particle's.
static func batch_shader(sh: Shader, as_native: bool = false) -> Shader:
	var key := "%d|%s" % [sh.get_instance_id(), str(as_native)]
	if _shaders.has(key):
		return _shaders[key]
	var code := sh.code
	var at := code.find("void vertex() {")
	var end := code.find("\n}", at)
	if at < 0 or end < 0:
		return sh
	var body := code.substr(at + "void vertex() {".length(), end - at - "void vertex() {".length())
	var link := not code.contains(EfpEffect.UVMAP_INSTANCE) and not body.contains("srr_q = INSTANCE_CUSTOM")
	var plate := not link
	var head := (HEAD_NATIVE if as_native else HEAD).replace("FXB_COUNT",
		"int(texelFetch(fxb_parts, ivec2(0, fxb_row), 0).x + 0.5)" if plate else "1")
	var vtx := "void vertex() {" + head.replace("{PARTICLE}", PARTICLE if plate else "")
	if body.contains("VIEW_MATRIX"):
		vtx += body.replace("MODEL_MATRIX", "fxb_model").replace("INSTANCE_CUSTOM", "fxb_cus")
	else:
		vtx += body.replace("INSTANCE_CUSTOM", "fxb_cus") + PLAIN
	vtx += TAIL + "}"
	code = code.substr(0, at) + vtx + code.substr(end + 2)
	if not code.contains("skip_vertex_transform"):
		code = code.replace("render_mode unshaded,", "render_mode unshaded, skip_vertex_transform,")
	var nl := code.find("\n", code.find("render_mode"))
	code = code.substr(0, nl + 1) + (UNIFORMS_NATIVE if as_native else UNIFORMS) + MAT + code.substr(nl + 1)
	var out := Shader.new()
	out.code = code
	_shaders[key] = out
	return out
