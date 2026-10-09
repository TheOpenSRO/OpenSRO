extends RefCounted
class_name EquipFxBatch

## Round 764 (OURS; docs/rounds/r764.md section 4): the particles of every
## ghost's weapons, drawn in one MultiMesh draw per (effect, draw node, body
## skeleton layout) -- every ghost within 720 units, as retail draws them --
## instead of a holder node per weapon for the 64 nearest in view.
##
## **Why.** EquipFx drew a weapon's effect through a holder: a node per weapon
## sharing its master's MultiMesh, placed on the CPU every frame, a draw call a
## master draw node. That cost ~1 ms of render thread for 64 holders (1,120 of
## the frame's draws, MEASURED at 4,000), so only the 64 nearest hosts in the
## view had one (EquipFx.VISIBLE_BUDGET, OURS), chosen again every cycle by
## their body's origin in the frustum. In the swarm 10,898 hosts were within
## 720 units and in view; 64 drew. Which 64 changed as the camera turned: the
## user's "the seal effects appear and disappear and it seems like it's based
## off camera angle" (v0.1.516). Retail steps and draws a character's effects
## while its LOD -- camera distance / 800 -- is under 0.9, every character
## (READ, round 761: CRTModParticle::FUN_00c779c0, FUN_00c43780).
##
## **How.** A batch's MultiMesh has (hosts x particles) instances and no
## instance data of its own. Its shader (batch_shader: the node's own shader,
## its vertex stage replaced) takes instance i as host i / P and particle
## i % P (P = fxb_per_host); finds the host's ghost in CrowdGpu's textures
## (crowd_gpu.gdshaderinc: the body's transform, its clip frame's bone, as the
## ghost's own parts are skinned), composes EquipFx.place's holder frame from
## it (the bone's frame x the item's rest, chain and pose, orthonormalised,
## scaled by the row's col3/100 x the body's uniform scale), and the particle's
## transform, colour and custom data from the master's draw buffer (fxb_parts,
## the 20 floats an instance of Godot's MultiMesh layout, 5 texels). What a
## holder drew, then, for every ghost at once, with nothing placed on the CPU.
## A ghost whose page is held or that fades out, or farther than 720 units
## (EquipFx.MAX_DISTANCE) or past Character Sight Range, draws none. A Link
## node's strips: one instance a host (fxb_per_host 1), the strip mesh itself.
##
## A batch's host table (fxb_hosts) changes only when a ghost's weapons come
## or go: 7 texels a host -- (slot, bone, row scale, on), the item's rest x
## chain (3), and that x the bone's pose (3).
##
## Dressed bodies (the player's own, a body dressed near the camera) keep
## EquipFx's holders and its budget.

const HOST_TEXELS := 7
const HOSTS_PER_ROW := 256
## Bytes a host's texels take.
const HOST_FLOATS := HOST_TEXELS * 4
## Batches whose host table is rebuilt a frame (OURS): a page of ghosts arrives
## in bursts; one table at least, then while this lasts.
const REBUILD_BUDGET_USEC := 600
## The batch draws' bounds (OURS): they are never culled as a whole; the shader
## places every vertex.
const BATCH_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

## OPENSRO_QA_EQUIPFX_BATCH=0: ghosts' particles through holders, as before.
static var enabled := OS.get_environment("OPENSRO_QA_EQUIPFX_BATCH") != "0"
## Round 764 (OURS): the most ghosts' hosts drawn, the nearest the camera in
## any direction (EquipFx's cut, chosen each cycle): every ghost within 720
## units while there are fewer, as retail draws them. MEASURED (r764.md 4.3):
## drawing all 11,600 hosts of the 4,000 swarm cost 3 ms of the RX 7600's
## GPU a frame at 1080p. OPENSRO_QA_EQUIPFX_HOSTS=<n> sets it (0: no cap).
static var host_budget := int(OS.get_environment("OPENSRO_QA_EQUIPFX_HOSTS")) if OS.get_environment("OPENSRO_QA_EQUIPFX_HOSTS").is_valid_int() else HOST_BUDGET
const HOST_BUDGET := 500
## QA: OPENSRO_QA_EQUIPFX_RANGE=<units> draws the batches' particles within
## that distance only (the GPU's share by distance).
static var qa_range := float(OS.get_environment("OPENSRO_QA_EQUIPFX_RANGE")) if OS.get_environment("OPENSRO_QA_EQUIPFX_RANGE").is_valid_float() else 0.0

## A kind's particles as one texture: a row per master draw node, 5 texels
## an instance (Godot's MultiMesh layout), shared by every layout's batch of
## the kind; updated when its master steps.
class Parts:
	var tex: ImageTexture = null
	var width := 0
	var rows := 0
	var counts := PackedInt32Array()
	## Per node, the instances a host is given (grow-only, a power of two):
	## the draws' fxb_per_host, so a step's new particle count changes no
	## material and no MultiMesh -- the count rides in the row's texel 0.
	var strides := PackedInt32Array()
	## Per node, the steps in a row it had no particle, and whether it is
	## drawn (hidden after LIVE_STEPS empty steps: an idle emitter's draw is a
	## draw call for nothing; shown again at its next particle).
	var zero := PackedInt32Array()
	var live := PackedByteArray()
	## The master's draw nodes (batch_nodes), counted once.
	var nodes := -1

## One kind's ghosts of up to LAYOUTS_PER_BATCH skeleton layouts: its hosts
## and, per master draw node, its draw.
class Batch:
	var key: String
	var kind_key: String
	## The layout group (CrowdGpu layouts in the order first seen, four a
	## group): its layouts' bone textures go to crowd_bones, crowd_bones1..3.
	var group := 0
	var hosts: Array = []
	var host_tex: ImageTexture = null
	var host_rows := 0
	## The hosts the uploaded table holds (the selected ones, in its order),
	## and its floats (tests).
	var shown := 0
	var drawn: Array = []
	var host_data := PackedFloat32Array()
	## [MultiMeshInstance3D, ShaderMaterial, 0 a plate node / 1 a link, the
	## master draw (or link) index, the instances shown, the particles a host
	## bound]
	var draws: Array = []
	var bones_texs: Array = [null, null, null, null]
	var built_for: Object = null
	var parts_tex: Texture = null

var _batches: Dictionary = {}   # "kind|layout group" -> Batch
## The CrowdGpu layouts seen, in order (a host's layout index).
var _layouts: Array = []
const LAYOUTS_PER_BATCH := 4
## Empty steps before a node's draw is hidden (OURS: 10 steps, half a second).
const LIVE_STEPS := 10
## Host tables are rebuilt one frame in this many (OURS).
const REBUILD_EVERY := 6
var _frame := 0
var _dirty_wait := false
var _by_kind: Dictionary = {}   # kind key -> [Batch]
var _parts: Dictionary = {}     # kind key -> Parts
var _kind_seen: Dictionary = {} # kind key -> its master's draw_updates last taken
var _dirty: Dictionary = {}     # Batch -> true: its host table to rebuild
## Hosts waiting for their ghost's slot and layout (made a ghost later).
var _pending: Array = []
var _parent: Node3D
var _bodies_tex: Texture = null
var _sight := -1.0
var stats := {"batches": 0, "hosts": 0, "instances": 0, "draws": 0, "pending": 0, "rebuilds": 0}

func _init(parent: Node3D) -> void:
	_parent = parent

## A ghost's host joins its batch (or waits for its ghost's slot).
func add(h) -> void:
	h.batch = null
	_pending.append(h)

## A host leaves its batch.
func remove(h) -> void:
	var b: Batch = h.batch
	if b != null:
		b.hosts.erase(h)
		if h.sel:
			_selected -= 1
			_dirty[b] = true
		h.sel = false
		h.batch = null
	else:
		_pending.erase(h)

## The hosts drawn now (selected).
var _selected := 0

## Whether host `h` is drawn (EquipFx's choice, each cycle): its batch's table
## is rebuilt when that changes. A host whose ghost has another body slot now
## (CrowdGpu made its body again) is placed again first.
func select(h, on: bool, crowd: Object = null) -> void:
	var b: Batch = h.batch
	# Only a drawn host's slot matters (and is checked: a call a host).
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

## Every batch freed (the driver leaves).
func clear() -> void:
	for b in _batches.values():
		_free_draws(b)
	_batches.clear()
	_by_kind.clear()
	_parts.clear()
	_kind_seen.clear()
	_dirty.clear()
	_pending.clear()
	_selected = 0

## Each frame, after the masters stepped: hosts placed in their batches, then
## only what changed -- a kind's particles when its master stepped, a host
## table when its hosts changed, CrowdGpu's textures when they were made
## again -- and those draws' instance counts. `crowd` is the CrowdGpu (null:
## nothing drawn), `kinds` EquipFx's.
func step(crowd: Object, kinds: Dictionary) -> void:
	if crowd == null:
		return
	var t0 := Time.get_ticks_usec()
	_place_pending(crowd)
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
		var stepped := int(_kind_seen.get(key, -1)) != m.draw_updates
		var grew := false
		if stepped:
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
	# Round 764 (OURS): the tables a sixth of the frames at most. While a page
	# arrives its hosts come every frame and every table was rebuilt (and
	# uploaded) every frame: +0.3 ms of main thread and +0.2 of render thread a
	# frame of a 4,000 arrival (MEASURED); a held page shows nothing anyway,
	# and a host chosen waits at most REBUILD_EVERY frames for its particles.
	_frame += 1
	if _frame % REBUILD_EVERY != 0:
		_dirty_wait = true
	for b in (_dirty.keys() if not _dirty_wait else []):
		if rebuilt > 0 and Time.get_ticks_usec() - t0 >= REBUILD_BUDGET_USEC:
			break
		_dirty.erase(b)
		_upload_hosts(b)
		touched[b] = true
		rebuilt += 1
	_dirty_wait = false
	stats["rebuilds"] = int(stats["rebuilds"]) + rebuilt
	for b in touched:
		_apply_counts(b)
	stats["pending"] = _pending.size()
	if FrameSplit.on:
		FrameSplit.add("fx_batch", Time.get_ticks_usec() - t0)

## A batch's draws' instance counts: its table's hosts x its kind's particles
## on each node (a Link: one a host), and the totals in `stats`.
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

## Hosts whose ghost now has a slot and a layout go to their batch.
func _place_pending(crowd: Object) -> void:
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
		h.rows = _host_rows(h, layout, gi % LAYOUTS_PER_BATCH)
		b.hosts.append(h)
		# Drawn at once while the budget has room (the next cycle chooses).
		h.sel = host_budget <= 0 or _selected < host_budget
		if h.sel:
			_selected += 1
			_dirty[b] = true
	_pending = keep

## The host table: HOST_TEXELS texels a host, HOSTS_PER_ROW hosts a row.
func _upload_hosts(b: Batch) -> void:
	var drawn: Array = []
	for h in b.hosts:
		if h.sel:
			drawn.append(h)
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

## A host's texels (HOST_TEXELS): (slot, bone, row scale, 1 + its layout's
## index in the batch), the item's
## rest x chain, and that x the bone's pose -- fixed while it is a member.
static func _host_rows(h, layout: Object, layout_index: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(HOST_FLOATS)
	out[0] = float(h.batch_slot)
	out[1] = float(h.att_bone)
	out[2] = h.scale
	# On, and its layout's place in the batch (1 + index: 0 is off).
	out[3] = 1.0 + float(layout_index)
	var rests: Array = layout.get("rests")
	var r: Transform3D = rests[h.att_bone] * h.chain if h.att_bone >= 0 and h.att_bone < rests.size() else h.chain
	_put_rows(out, 4, r)
	_put_rows(out, 16, r * h.pose)
	return out

## A Transform3D's three rows (basis row and origin) at `o`: crowd_gpu's
## srr_cg_mat layout.
static func _put_rows(data: PackedFloat32Array, o: int, t: Transform3D) -> void:
	for r in 3:
		data[o + r * 4] = t.basis.x[r]
		data[o + r * 4 + 1] = t.basis.y[r]
		data[o + r * 4 + 2] = t.basis.z[r]
		data[o + r * 4 + 3] = t.origin[r]

## A kind's particles: every master draw node's buffer, a row each.
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
	# The counts first (natively: no buffer copied yet), the rows after.
	var counts := master.draw_count_list()
	counts.resize(n)
	var widest := 1
	if pt.strides.size() != n:
		pt.strides.resize(n)
	for i in n:
		var c := counts[i]
		pt.zero[i] = 0 if c > 0 else pt.zero[i] + 1
		pt.live[i] = 1 if pt.zero[i] < LIVE_STEPS else 0
		if pt.strides[i] < c:
			# Grow-only, a quarter over (OURS): few changes, little padding.
			pt.strides[i] = maxi(ceili(c * 1.25 / 4.0) * 4, 4)
		widest = maxi(widest, pt.strides[i])
	var rows := maxi(n, 1)
	var width := pt.width
	if 1 + widest * 5 > width:
		width = maxi(1 + widest * 5, width * 2)
	# Natively in one call (gd_efp.rs draw_rows); else built here: texel 0
	# the particles this step, then 5 texels a particle, zeros to the row's end.
	var data := master.draw_rows(width, rows)
	if data.size() != width * rows * 4:
		data = PackedFloat32Array()
		for i in rows:
			var c := float(counts[i]) if i < counts.size() else 0.0
			data.append_array(PackedFloat32Array([c, 0.0, 0.0, 0.0]))
			if i < n:
				data.append_array(master.draw_buffer(i))
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
		mat.shader = batch_shader(src_mat.shader)
		for u in ["tex", "c_op", "c_a1", "c_a2", "a_op", "a_a1", "a_a2"]:
			var v = src_mat.get_shader_parameter(u)
			if v != null:
				mat.set_shader_parameter(u, v)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.custom_aabb = BATCH_AABB
		if e[0] == 0:
			mm.mesh = ((src as MultiMeshInstance3D).multimesh).mesh
		else:
			mm.mesh = (src as MeshInstance3D).mesh
		mm.instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "EquipFxBatch"
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.top_level = true
		_parent.add_child(mmi)
		mmi.global_transform = Transform3D.IDENTITY
		RenderingServer.instance_set_custom_aabb(mmi.get_instance(), BATCH_AABB)
		if b.host_tex != null:
			mat.set_shader_parameter("fxb_hosts", b.host_tex)
		mat.set_shader_parameter("fxb_per_host", 1)
		mat.set_shader_parameter("fxb_row", int(e[2]) if e[0] == 0 else 0)
		mat.set_shader_parameter("fxb_range", qa_range if qa_range > 0.0 else EquipFx.MAX_DISTANCE)
		mmi.visible = false
		b.draws.append([mmi, mat, 0 if e[0] == 0 else 1, int(e[2]), 0, 1])
	b.parts_tex = null
	b.bones_texs = [null, null, null, null]

func _free_draws(b: Batch) -> void:
	for d in b.draws:
		stats["instances"] = int(stats["instances"]) - int(d[4])
		stats["draws"] = int(stats["draws"]) - (1 if int(d[4]) > 0 else 0)
		if is_instance_valid(d[0]):
			(d[0] as Node).queue_free()
	b.draws.clear()

## Tests: host `i` of batch `b`'s holder frame as the shader composes it, in
## GDScript from the same data -- its table's floats, the ghost's body
## transform and clip frame (CrowdGpu's) -- or null when its ghost is gone.
static func cpu_hold(crowd: CrowdGpu, b: Batch, i: int):
	var o := i * HOST_FLOATS
	if i < 0 or i >= b.drawn.size() or o + HOST_FLOATS > b.host_data.size():
		return null
	var hd := b.host_data
	var slot := int(hd[o] + 0.5)
	var bone := int(hd[o + 1] + 0.5)
	var body := CrowdGpu._row_xf(crowd._body_data, slot * CrowdGpu.FLOATS_PER_BODY)
	var h = b.drawn[i]
	var row := -1
	var cb: CrowdGpu.Body = crowd._bodies.get(h.anchor)
	if cb == null:
		return null
	var clip: Vector3i = cb.layout.clips.get(cb.frames, Vector3i(0, 1, 1))
	row = clip.x + crowd.frame_of(h.anchor, crowd._last_time)
	var k: Transform3D = body * CrowdGpu._bone_xf(h.blayout, row, bone)
	var g: Transform3D = k * CrowdGpu._row_xf(hd, o + 4)
	var a: Transform3D = k * CrowdGpu._row_xf(hd, o + 16)
	var s := hd[o + 2] * pow(absf(g.basis.determinant()), 1.0 / 3.0)
	return Transform3D(a.basis.orthonormalized() * s, a.origin)

# --- the shader -------------------------------------------------------------------

static var _shaders: Dictionary = {}

## The vertex stage's head: the host's holder frame (`fxb_hold`) from its
## ghost's body and clip frame, whether it draws (`fxb_off`), and the
## particle's transform, colour and custom data (`fxb_model`, COLOR,
## `fxb_cus`). EquipFx.place's composition: at = G x pose, G = body x bone x
## rest x chain; the basis orthonormalised (Basis.orthonormalized's
## Gram-Schmidt over the columns) and scaled by the row's scale x
## cbrt(|det G|) (EquipFx._uniform_scale).
const HEAD := """
	int fxb_n = max(fxb_per_host, 1);
	int fxb_h = INSTANCE_ID / fxb_n;
	int fxb_p = INSTANCE_ID % fxb_n;
	ivec2 fxb_at = ivec2((fxb_h % 256) * 7, fxb_h / 256);
	// A host's instances past its node's live particles (the stride's
	// padding) do nothing else.
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
		// Whether this host draws: its page shown and not fading out
		// (EquipFx's ghost_origin rule), within fxb_range (720: retail's LOD
		// 0.9 x 800) and Character Sight Range of the camera, and its body
		// within FXB_NEAR of the view's frustum (a sphere test in view space;
		// OURS, EquipFx.ALWAYS_NEAR).
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
		fxb_model = fxb_model * srr_cg_mat(texelFetch(fxb_parts, fxb_pa, 0), texelFetch(fxb_parts, fxb_pa + ivec2(1, 0), 0),
			texelFetch(fxb_parts, fxb_pa + ivec2(2, 0), 0));
		COLOR *= texelFetch(fxb_parts, fxb_pa + ivec2(3, 0), 0);
		fxb_cus = texelFetch(fxb_parts, fxb_pa + ivec2(4, 0), 0);
"""

## A node drawn with Godot's own transform (no shared turn): the vertex by the
## composed model matrix into view space.
const PLAIN := """
	VERTEX = (VIEW_MATRIX * fxb_model * vec4(VERTEX, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
"""

## The tail: a host that draws nothing puts its vertices behind the camera
## (clipped, no fragment).
const TAIL := """
	if (fxb_off) {
		VERTEX = vec3(0.0, 0.0, 1.0);
	}
"""

const UNIFORMS := """
#include "res://scripts/world/crowd_gpu.gdshaderinc"
uniform sampler2D fxb_hosts : filter_nearest, repeat_disable;
uniform sampler2D fxb_parts : filter_nearest, repeat_disable;
uniform int fxb_per_host = 1;
uniform int fxb_row = 0;
uniform float fxb_range = 720.0;
const float FXB_NEAR = 30.0;
// The batch's other layouts' bone stores (crowd_bones is the first's).
uniform sampler2DArray crowd_bones1 : filter_nearest, repeat_disable;
uniform sampler2DArray crowd_bones2 : filter_nearest, repeat_disable;
uniform sampler2DArray crowd_bones3 : filter_nearest, repeat_disable;
// srr_cg_bone from the host's layout's store.
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

## `sh` (a master draw node's shader: EfpEffect's template, its shared-turn
## twin, a Link's or its pipe-turn twin) with its vertex stage replaced by the
## batch's: the same body as the node's own, its MODEL_MATRIX the host's
## holder frame times the particle's, its INSTANCE_CUSTOM the particle's.
static func batch_shader(sh: Shader) -> Shader:
	var key := sh.get_instance_id()
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
	# A plate node's live particles: its row's texel 0 (a Link's: one a host).
	var head := HEAD.replace("FXB_COUNT", "int(texelFetch(fxb_parts, ivec2(0, fxb_row), 0).x + 0.5)" if plate else "1")
	var vtx := "void vertex() {" + head.replace("{PARTICLE}", PARTICLE if plate else "")
	if body.contains("VIEW_MATRIX"):
		# A shared-turn plate or a pipe-turn link: its own stage, on the
		# composed matrix and the particle's custom data.
		vtx += body.replace("MODEL_MATRIX", "fxb_model").replace("INSTANCE_CUSTOM", "fxb_cus")
	else:
		# The template's own stage (the instance UV rectangle, or nothing).
		vtx += body.replace("INSTANCE_CUSTOM", "fxb_cus") + PLAIN
	vtx += TAIL + "}"
	code = code.substr(0, at) + vtx + code.substr(end + 2)
	if not code.contains("skip_vertex_transform"):
		code = code.replace("render_mode unshaded,", "render_mode unshaded, skip_vertex_transform,")
	var nl := code.find("\n", code.find("render_mode"))
	code = code.substr(0, nl + 1) + UNIFORMS + code.substr(nl + 1)
	var out := Shader.new()
	out.code = code
	_shaders[key] = out
	return out
