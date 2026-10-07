extends RefCounted
class_name CrowdGpu

## Round 747 (crowd scale A5, docs/protocol/crowd_gpu.md): far other players
## drawn as GPU instances. The spec is crowd_gpu.md; the measurements are in
## docs/rounds/r747.md. Labels: READ, MEASURED, COMPUTED, INFERRED, OURS.
##
## **Why.** After rounds 738/739 a standing crowd of 1000 cost about 95 ms a
## frame: about 8 draws a body (Godot does not instance skinned meshes), each
## posed body's Skeleton3D update and its re-skin, and the clip tick visiting
## every body (round 739's combined table, MEASURED).
##
## **What (OURS throughout).** A far body's skeleton is hidden and left
## unposed; its entry leaves World3D's clip tick; each of its visible mesh
## parts becomes one instance of a MultiMesh per (mesh, material, layers,
## sorting offset), shared by every far body. The part's material is a twin of
## the body's own: the same shader code with the skin added at the top of
## vertex() (twin_shader: crowd_gpu.gdshaderinc, crowd_gpu_vertex.gdshaderinc),
## the same parameters. The vertex shader skins from three textures:
## - **the bones**, one per skeleton layout (MonsterCrowd.META_LAYOUT): a row
##   per baked frame of each clip -- CrowdAnim's own A3 frames at
##   CrowdAnim.QUANTUM_MS, so a far body shows exactly the frame a near body
##   would -- with every bone's skin matrix pose_global x inverse(global rest),
##   which is the shared skin's bind (Skeleton3DBuilder.canonical_skin), as
##   Godot's skeleton writes it (pose_global * bind, skeleton_3d.cpp, READ);
## - **the bodies**: 4 texels a body, its skeleton's global transform and its
##   clip (first row, frame count, duration, the body's offset into it). The
##   clip time comes from one global uniform, srr_crowd_clock: no per-body
##   clip tick, no per-body upload unless the body moved or changed clip;
## - **Volume**: per layout, a row per Volume variant skin in use, each bone's
##   rest x variant bind (CharacterAppearance.volume_skin), so a variant's
##   skin is the baked matrix times it.
## Items with their own skeleton (weapons, shields, shoulder pieces) and
## rigid pieces hang from a body bone through a BoneAttachment3D; their
## vertices are moved once into that bone's rest space (rigid_mesh) and
## skinned to it alone, which is the attachment's composition (round 141,
## SkinnedBsrAssembler.attach_item_from_archive) with the bone's pose from the
## same texture.
##
## World3D decides which bodies are far (the K nearest the camera, in view or
## not, stay near) and
## when a body must come back (a one-shot, berserk, an aura, Detail's shadow,
## a fade): CrowdGpu only draws.

## Off: every body is drawn as before. The player's config (VideoOptions
## `gpu_crowd`, OURS: retail has no such option; World3D applies it) unless
## QA sets it (OPENSRO_QA_CROWD_GPU=0/1, and QaCrowdProbe's `anim=` steps, "5").
static var enabled := OS.get_environment("OPENSRO_QA_CROWD_GPU") != "0"
## How many bodies nearest the camera stay on the full path (OURS;
## OPENSRO_QA_CROWD_NEAR=<n> for the QA A/B). The far path draws the same
## pixels as the near one (round 747's parity probe and `ab` step), a far
## weapon's particles are placed from its body's GPU frame (item_frame), and
## Detail's casters, a fading, berserk or effect-carrying body stay near
## whatever their rank (World3D._crowd_eligible), and a far body within
## hearing plays its clip sounds from the CPU (World3D._crowd_sound_step). So
## the number decides only who is posed on the CPU. 16 (MEASURED in r747.md
## against 64: about 5 ms a frame at 1000).
static var near_count := int(OS.get_environment("OPENSRO_QA_CROWD_NEAR")) if OS.get_environment("OPENSRO_QA_CROWD_NEAR").is_valid_int() else 16
## A near body goes far only once it is no longer among this factor times
## near_count nearest the camera, in view or not (OURS: by rank, not distance, so the near set
## stays at most 1.25 x near_count in a dense crowd), so a body on the line
## does not change path every cycle.
const NEAR_HYSTERESIS := 1.25
## The near set is re-chosen every this many frames, from a scan spread over
## them (OURS, as EquipFx.RESELECT_FRAMES).
const RESELECT_FRAMES := 10
## Round 757 (OURS): World3D's near/far scan reads at most this many bodies a
## frame; past 2,000 bodies a cycle takes longer than RESELECT_FRAMES (7,000:
## 35 frames, about 0.6 s at 60 fps).
const SCAN_PER_FRAME_MAX := 200
## Bodies switched to the GPU a frame at most, and the time they may take
## (OURS): a switch walks the body's parts and adds an instance per part
## (docs/rounds/r747.md has what one costs).
const SWITCH_BUDGET := 128
const SWITCH_BUDGET_USEC := 3000
## Baking: frames composed a frame at most, by time (OURS). A clip of 188
## frames bakes over a few frames; a body waiting on its clip stays near.
const BAKE_BUDGET_USEC := 4000
## Every far body's transform is re-read at least every this many frames (OURS),
## besides the moves World3D reports (moved()). Round 757: 15 -> 60. Every
## path that moves a holder reports it (World3D._other_moved), so the spread
## re-read is a safety net; at 7,000 far bodies 15 frames was 467 re-reads a
## frame (part of `g_flush`'s 1.7 ms, MEASURED).
const REFRESH_FRAMES := 60
const SLOTS_PER_ROW := 256
const TEXELS_PER_BODY := 4
const FLOATS_PER_BODY := TEXELS_PER_BODY * 4
## The clock's epoch moves every this many seconds (OURS): the shader's clip
## time is a float, and at 60,000 ms its step is 0.004 ms against the
## quantum's 8.3.
const EPOCH_SECONDS := 60.0
## Rows a layout's bone texture may hold (Godot's and Vulkan's 2-D limit).
const MAX_ROWS := 16384
## Rows a page of a layout's bone store holds (crowd_gpu.gdshaderinc's
## SRR_CG_PAGE_ROWS): one layer of its Texture2DArray (OURS).
const PAGE_ROWS := 1024
## While clips are baking, a layout's bone texture goes up at most every this
## many frames (OURS): each upload is the whole texture, up to ~16 MB.
const UPLOAD_FRAMES := 15
## Floats a MultiMesh instance takes: a 3 x 4 transform and the custom data.
const INSTANCE_FLOATS := 16
## A group empty for this many cycles (RESELECT_FRAMES each) is freed (OURS:
## about 5 s at 60 fps, so a body walking across a light level and back does
## not re-make its groups).
const GROUP_EMPTY_CYCLES := 30
const IDENTITY_ROWS := [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0]

const VERTEX_INCLUDE := "res://scripts/world/crowd_gpu_vertex.gdshaderinc"
const HEAD_INCLUDE := "res://scripts/world/crowd_gpu.gdshaderinc"
## Meta on a far body's skeleton: the CrowdGpu drawing it.
const META_FAR := &"opensro_crowd_far"

class Layout:
	var key: String
	var bones := 0
	## Texels a row: 3 a bone.
	var width := 0
	var binds: Array[Transform3D] = []
	var rests: Array[Transform3D] = []
	## A copy of a body skeleton of this layout, no children: where frames are
	## composed.
	var scratch: Skeleton3D
	## CrowdAnim.Frames -> Vector3i(first row, frame count, duration ms), baked.
	var clips := {}
	## Clips baked whose rows are not on the GPU yet: the same.
	var uploading := {}
	var last_upload := -1000
	## Clips being baked: [Frames, next frame, first row].
	var pending: Array = []
	var queued := {}
	## The baked rows in pages of PAGE_ROWS (round 747's review, F3): one
	## PackedFloat32Array a page, one layer of a Texture2DArray each, so a new
	## clip uploads the pages it wrote (2.2 MB at most) rather than the whole
	## store (16.5 MB at the catalogue's 8192 rows: 12 ms of main thread,
	## MEASURED by the review).
	var pages: Array = []
	var dirty_pages := {}
	var rows := 0
	var tex: Texture2DArray = null
	var tex_layers := 0
	var dirty := false
	## Volume variant Skin -> row.
	var vol_rows := {}
	var vol_data := PackedFloat32Array()
	var vol_count := 0
	var vol_tex: ImageTexture = null
	var vol_dirty := false
	## The twin materials drawing with this layout's textures.
	var twins: Array[ShaderMaterial] = []

class Group:
	var key: String
	var mesh: Mesh
	var material: ShaderMaterial
	var mm: RID
	var inst: RID
	var buf := PackedFloat32Array()
	var count := 0
	var cap := 0
	## Each instance's part record ([Group, index, Body]), in instance order.
	var owners: Array = []
	var dirty := false
	## Cycles (collect()) it has been empty; its twin's key.
	var empty_cycles := 0
	var twin_key := ""

class Body:
	var node: Node3D
	var skel: Skeleton3D
	var slot := -1
	var layout: Layout
	## Its World3D._animated entry: [skeleton, anim, frames, phase, loops, ...].
	var entry: Array
	var frames: CrowdAnim.Frames
	var parts: Array = []
	## The MeshInstance3Ds its instances stand for, hidden while it is far.
	var hidden: Array = []
	## Clip -> its frames on this body's layout (set_clip).
	var by_clip := {}
	## Within hearing of the listener (World3D's scan), and the clip time
	## (World3D._idle_anim_time) its clip sounds are next due (F2).
	var heard := false
	var sound_due := INF
	var xf := Transform3D()
	## The skeleton's own transform under its holder, kept while it is
	## top_level (add()).
	var local := Transform3D()

var scenario: RID
var _layouts := {}            # layout key -> Layout
var _groups := {}             # group key -> Group
var _bodies := {}             # Skeleton3D -> Body
var _by_node := {}            # Node3D -> Body
var _twin_shaders := {}       # Shader -> Shader
var _twins := {}              # "material id|layout" -> ShaderMaterial
var _twin_sources := {}       # the same key -> WeakRef to the source material (its id is the key)
var _twin_users := {}         # the same key -> groups drawing with it
var _rigid := {}              # "mesh id|layout|bone" -> ArrayMesh
var _free_slots: Array[int] = []
var _slots := 0
var _slot_cap := 0
var _body_data := PackedFloat32Array()
var _body_tex: ImageTexture = null
var _body_dirty := false
var _moved := {}              # Body -> true
var _epoch := 0.0
var _range := 0.0
var _aabb := AABB()
var _aabb_set := false
var _frame := 0
## The clip time of the last flush (item_frame).
var _last_time := 0.0
var _keys: Array = []
var _keys_dirty := true
var _ring := 0
## Counts for the QA line and the tests.
var stats := {"far": 0, "groups": 0, "instances": 0, "baked_clips": 0, "baked_frames": 0, "bake_usec": 0,
	"added": 0, "removed": 0, "refused": 0, "uploads": 0}

func _init(world_scenario: RID = RID()) -> void:
	scenario = world_scenario

## The RIDs go with the object (inline: a RefCounted's own methods cannot be
## called while it is deleted -- CharacterAppearance's note).
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	for k in _groups:
		var g: Group = _groups[k]
		if g.inst.is_valid():
			RenderingServer.free_rid(g.inst)
		if g.mm.is_valid():
			RenderingServer.free_rid(g.mm)
	_groups.clear()
	for k in _layouts:
		var l: Layout = _layouts[k]
		if l.scratch != null and is_instance_valid(l.scratch):
			l.scratch.free()
	_layouts.clear()

# --- bodies -----------------------------------------------------------------------

func has(skel: Skeleton3D) -> bool:
	return _bodies.has(skel)

func body_count() -> int:
	return _bodies.size()

## The entry a far skeleton plays ([skeleton, anim, frames, phase, loops, ...]), or [].
func entry_of(skel: Skeleton3D) -> Array:
	var b: Body = _bodies.get(skel)
	return b.entry if b != null else []

## Every far skeleton.
func skeletons() -> Array:
	return _bodies.keys()

## The far body record of `skel`, or null (World3D's sound step).
func body_of(skel: Skeleton3D) -> Body:
	return _bodies.get(skel)

## The far bodies within hearing (World3D._crowd_sound_step), kept as their
## `heard` flags change.
func heard_bodies() -> Array:
	if _heard_dirty:
		_heard_dirty = false
		_heard.clear()
		for skel in _bodies:
			var b: Body = _bodies[skel]
			if b.heard:
				_heard.append(b)
	return _heard

func set_heard(b: Body, on: bool) -> void:
	if b.heard != on:
		b.heard = on
		_heard_dirty = true

var _heard: Array = []
var _heard_dirty := true

## Whether `entry`'s clip can be drawn here now: a loop whose frames are baked
## on `skel`'s layout. A clip not baked yet is queued (bake_step), so a later
## call answers true.
func can_draw(skel: Skeleton3D, entry: Array) -> bool:
	if not enabled or skel == null or not skel.has_meta(MonsterCrowd.META_LAYOUT):
		return false
	if entry.size() < 5 or not bool(entry[4]):
		return false
	var anim: BanReader.ParsedAnimation = entry[1]
	if anim == null or anim.duration_ms <= 0 or anim.key_times.is_empty():
		return false
	var l := _layout_for(skel)
	if l == null:
		return false
	var fr := CrowdAnim.frames_for(l.scratch, anim)
	if l.clips.has(fr):
		return true
	_queue_bake(l, fr)
	return false

## Queues `anim`'s frames on `skel`'s layout (World3D: a far body's run, so
## its first step does not bring it back). Nothing when baked or queued.
func prebake(skel: Skeleton3D, anim: BanReader.ParsedAnimation) -> void:
	if anim == null or anim.duration_ms <= 0 or anim.key_times.is_empty():
		return
	var l := _layout_for(skel)
	if l != null:
		_queue_bake(l, CrowdAnim.frames_for(l.scratch, anim), false)

## Draws `skel`'s body (under `node`) as instances from now on, playing
## `entry` (World3D._animated's, a loop). Hides its meshes. False, with
## nothing changed, when it cannot: its clip is not baked (it is queued), a
## part is not one this path draws (a material that is not a ShaderMaterial,
## a piece hung some other way), or no layout.
func add(node: Node3D, skel: Skeleton3D, entry: Array, idle_time: float) -> bool:
	if _bodies.has(skel):
		return true
	# The skeleton hangs straight from its holder (World3D._dress_other): its
	# place while far is the holder's times its own transform.
	if skel.get_parent() != node or not can_draw(skel, entry):
		return false
	# A mirrored body would draw with the wrong winding (round 747's review,
	# F9): Godot flips a mirrored instance's cull from its transform, and a far
	# part's instance transform is the identity. None is mirrored in the world.
	if node.is_inside_tree() and (node.global_transform * skel.transform).basis.determinant() < 0.0:
		_refuse("mirrored")
		return false
	var l := _layout_for(skel)
	var parts = _parts_of(skel, l)
	if parts == null:
		stats["refused"] += 1
		return false
	var b := Body.new()
	b.node = node
	b.skel = skel
	b.layout = l
	b.entry = entry
	b.frames = CrowdAnim.frames_for(l.scratch, entry[1])
	b.slot = _take_slot()
	b.local = skel.transform
	_bodies[skel] = b
	_keys_dirty = true
	_by_node[node] = b
	_write_transform(b)
	_write_clip(b, idle_time)
	for p in parts:
		_add_part(b, p)
	_hide(b, parts)
	# Out of its holder's transform propagation while far: a walking body
	# would otherwise send every hidden piece's transform to the server each
	# frame (Node3D._propagate_transform_changed skips a top_level child;
	# VisualInstance3D sends instance_set_transform on every change, shown or
	# not: node_3d.cpp:113, visual_instance_3d.cpp:58-61, 4.2.2, READ). Its
	# place is read from the holder (_write_transform).
	skel.top_level = true
	skel.set_meta(META_FAR, true)
	_grow_aabb(b.xf.origin)
	stats["added"] += 1
	return true

## Takes `skel` off the instances and shows it again; returns its entry (or
## [] when it was not here). The caller poses it and puts the entry back in
## its clip tick. `push`: its groups are sent to the server now, so a body
## brought back between two flushes (a hook in another node's frame) is never
## drawn twice; release_all sends once for all.
func remove(skel: Skeleton3D, push: bool = true) -> Array:
	var b: Body = _bodies.get(skel)
	if b == null:
		return []
	for p in b.parts:
		_remove_part(p)
	b.parts.clear()
	if push:
		_push_groups()
	_bodies.erase(skel)
	_keys_dirty = true
	_heard_dirty = true
	if _by_node.get(b.node) == b:
		_by_node.erase(b.node)
	_moved.erase(b)
	# Round 757's review, F1: off the far sounds (World3D's wheel drops a
	# record that is not heard, or not its skeleton's current one).
	b.heard = false
	b.sound_due = INF
	_free_slots.append(b.slot)
	# A freed slot draws nothing: no instance names it.
	_unhide(b)
	if is_instance_valid(skel):
		skel.top_level = false
		skel.transform = b.local
		skel.remove_meta(META_FAR)
	stats["removed"] += 1
	return b.entry

## The far body `skel` changes loop (World3D._swap_other_loop): `anim` with
## `frames`, in its entry (as MonsterMotion.swap_loop does), when its frames
## are baked. False when they are not (queued): the caller brings the body
## near and swaps there.
##
## Cheap, since a walking crowd changes gait in bursts (every body that gets a
## new target starts running in the same frame): the clip's frames are looked
## up once per body and clip.
func set_clip(skel: Skeleton3D, anim: BanReader.ParsedAnimation, frames: int, idle_time: float) -> bool:
	var b: Body = _bodies.get(skel)
	if b == null or anim == null:
		return false
	if anim == b.entry[1]:
		b.entry[2] = frames
		return true
	if anim.duration_ms <= 0 or anim.key_times.is_empty():
		return false
	var fr: CrowdAnim.Frames = b.by_clip.get(anim)
	if fr == null:
		fr = CrowdAnim.frames_for(b.layout.scratch, anim)
		b.by_clip[anim] = fr
	if not b.layout.clips.has(fr):
		_queue_bake(b.layout, fr)
		return false
	b.entry[1] = anim
	b.entry[2] = frames
	b.frames = fr
	_write_clip(b, idle_time)
	return true

## Reports that `node` (a far body's holder) moved or turned: its transform is
## re-read at the next flush.
func moved(node: Node3D) -> void:
	var b: Body = _by_node.get(node)
	if b != null:
		_moved[b] = true

## Re-reads a far body's parts (its materials changed: CharacterLight's level
## copy). False when it can no longer be drawn here (the caller brings it near).
func refresh(node: Node3D) -> bool:
	var b: Body = _by_node.get(node)
	if b == null:
		return true
	_unhide(b)
	var parts = _parts_of(b.skel, b.layout)
	if parts == null:
		return false
	for p in b.parts:
		_remove_part(p)
	b.parts.clear()
	for p in parts:
		_add_part(b, p)
	_hide(b, parts)
	return true

## The parts' own meshes hidden while their instances draw them: each mesh,
## not the skeleton, so what else hangs from it (EquipFx's particle holders
## on a weapon) still draws, placed from item_frame.
func _hide(b: Body, parts: Array) -> void:
	for p in parts:
		var mi: MeshInstance3D = p["mi"]
		mi.visible = false
		b.hidden.append(mi)

func _unhide(b: Body) -> void:
	for mi in b.hidden:
		if is_instance_valid(mi):
			(mi as MeshInstance3D).visible = true
	b.hidden.clear()

## Where the item skeleton `item_skel` (a weapon's, hung from a far body's
## bone through a BoneAttachment3D) is now: the body's transform times its
## bone's pose this frame (the baked skin matrix times the bone's rest, the
## frame the vertex shader draws) times the item skeleton's own transform
## under the attachment. Null when its body is not far. EquipFx places a far
## weapon's particles by it (EquipFx.far_frame).
func item_frame(item_skel: Node3D):
	var att := item_skel.get_parent() as BoneAttachment3D if item_skel != null else null
	if att == null:
		return null
	var b: Body = _bodies.get(att.get_parent())
	if b == null:
		return null
	var bone := att.get_bone_idx()
	if bone < 0 or bone >= b.layout.bones:
		return null
	var clip: Vector3i = b.layout.clips.get(b.frames, Vector3i(0, 1, 1))
	var row := clip.x + frame_of(b.skel, _last_time)
	var k := _bone_xf(b.layout, row, bone)
	return b.xf * k * b.layout.rests[bone] * item_skel.transform

## A far weapon's place for EquipFx's choice of the nearest: its body's (OURS:
## the choice is by distance; the frame is item_frame's). Null when not far.
func item_origin(item_skel: Node3D):
	var att := item_skel.get_parent() as BoneAttachment3D if item_skel != null else null
	if att == null:
		return null
	var b: Body = _bodies.get(att.get_parent())
	return b.xf.origin if b != null else null

## Character Sight Range (0: none) for every far part.
func set_range(r: float) -> void:
	if is_equal_approx(r, _range):
		return
	_range = r
	for k in _twins:
		(_twins[k] as ShaderMaterial).set_shader_parameter("crowd_range", r)

## Every body back (their entries returned, skeletons shown), every instance
## gone. The caller re-registers the entries it gets.
func release_all() -> Array:
	var out: Array = []
	for skel in _bodies.keys():
		var e := remove(skel, false)
		if not e.is_empty():
			out.append(e)
	_push_groups()
	return out

# --- the frame --------------------------------------------------------------------

## Once a rendered frame, after the bodies have moved: the clock, the moved
## bodies' transforms, the baking, and every upload due.
func flush(idle_time: float) -> void:
	_frame += 1
	_last_time = idle_time
	if idle_time - _epoch > EPOCH_SECONDS or idle_time < _epoch:
		_rebase(idle_time)
	RenderingServer.global_shader_parameter_set(&"srr_crowd_clock", float((idle_time - _epoch) * 1000.0))
	for b in _moved:
		_update_transform(b)
	_moved.clear()
	# The spread re-read: a body moved by a path that did not report it, a
	# share of them a frame, round the ring.
	if _keys_dirty:
		_keys = _bodies.keys()
		_keys_dirty = false
	var due := ceili(float(_keys.size()) / float(REFRESH_FRAMES))
	for i in range(due):
		_ring = (_ring + 1) % _keys.size()
		var b: Body = _bodies.get(_keys[_ring])
		if b == null:
			continue
		if not is_instance_valid(b.skel) or not is_instance_valid(b.node):
			remove(_keys[_ring])
			continue
		_update_transform(b)
	bake_step(BAKE_BUDGET_USEC)
	_upload()

## Bakes queued clips for up to `budget_usec`. Returns the frames composed.
func bake_step(budget_usec: int) -> int:
	var t0 := Time.get_ticks_usec()
	var made := 0
	for k in _layouts:
		var l: Layout = _layouts[k]
		while not l.pending.is_empty():
			var job: Array = l.pending[0]
			var fr: CrowdAnim.Frames = job[0]
			var f: int = job[1]
			_bake_frame(l, fr, f, int(job[2]) + f)
			made += 1
			job[1] = f + 1
			if f + 1 >= fr.count:
				l.pending.pop_front()
				l.queued.erase(fr)
				# Drawn from once its rows are on the GPU (_upload).
				l.uploading[fr] = Vector3i(int(job[2]), fr.count, fr.duration_ms)
				l.dirty = true
				stats["baked_clips"] += 1
			if Time.get_ticks_usec() - t0 >= budget_usec:
				break
		if Time.get_ticks_usec() - t0 >= budget_usec:
			break
	stats["baked_frames"] += made
	stats["bake_usec"] += Time.get_ticks_usec() - t0
	return made

## Every queued clip baked now (tests, the probe).
func bake_all() -> void:
	while true:
		var left := 0
		for k in _layouts:
			left += (_layouts[k] as Layout).pending.size()
		if left == 0:
			_upload(true)
			return
		bake_step(1 << 30)

func _rebase(idle_time: float) -> void:
	_epoch = idle_time
	for skel in _bodies:
		_write_clip(_bodies[skel], idle_time)

func _upload(force: bool = false) -> void:
	if _body_dirty and _slot_cap > 0:
		_body_dirty = false
		var img := Image.create_from_data(SLOTS_PER_ROW * TEXELS_PER_BODY, _slot_cap / SLOTS_PER_ROW, false,
			Image.FORMAT_RGBAF, _body_data.to_byte_array())
		if _body_tex == null or _body_tex.get_height() != img.get_height():
			_body_tex = ImageTexture.create_from_image(img)
			for k in _twins:
				(_twins[k] as ShaderMaterial).set_shader_parameter("crowd_bodies", _body_tex)
		else:
			_body_tex.update(img)
		stats["uploads"] += 1
	for k in _layouts:
		var l: Layout = _layouts[k]
		# The pages written go up (a layer each: ImageTextureLayered.update_layer),
		# at most every UPLOAD_FRAMES while clips are baking, at once when the
		# last is done; a new page re-makes the array (rare: a layout's 8th at most).
		if l.dirty and not l.pages.is_empty() and (force or l.pending.is_empty() or _frame - l.last_upload >= UPLOAD_FRAMES):
			var t0 := Time.get_ticks_usec()
			l.dirty = false
			l.last_upload = _frame
			l.clips.merge(l.uploading, true)
			l.uploading.clear()
			if l.tex == null or l.tex_layers != l.pages.size():
				var imgs: Array[Image] = []
				for p in l.pages:
					imgs.append(Image.create_from_data(l.width, PAGE_ROWS, false, Image.FORMAT_RGBAF, (p as PackedFloat32Array).to_byte_array()))
				l.tex = Texture2DArray.new()
				l.tex.create_from_images(imgs)
				l.tex_layers = l.pages.size()
				for t in l.twins:
					t.set_shader_parameter("crowd_bones", l.tex)
			else:
				for pi in l.dirty_pages:
					l.tex.update_layer(Image.create_from_data(l.width, PAGE_ROWS, false, Image.FORMAT_RGBAF,
						(l.pages[pi] as PackedFloat32Array).to_byte_array()), int(pi))
			l.dirty_pages.clear()
			stats["uploads"] += 1
			var spent := Time.get_ticks_usec() - t0
			stats["upload_usec"] = int(stats.get("upload_usec", 0)) + spent
			stats["upload_max_usec"] = maxi(int(stats.get("upload_max_usec", 0)), spent)
		if l.vol_dirty:
			l.vol_dirty = false
			var rows := maxi(l.vol_count, 1)
			if l.vol_data.size() < rows * l.width * 4:
				l.vol_data.resize(rows * l.width * 4)
			var vimg := Image.create_from_data(l.width, rows, false, Image.FORMAT_RGBAF, l.vol_data.to_byte_array())
			if l.vol_tex == null or l.vol_tex.get_height() != rows:
				l.vol_tex = ImageTexture.create_from_image(vimg)
				for t in l.twins:
					t.set_shader_parameter("crowd_volume", l.vol_tex)
			else:
				l.vol_tex.update(vimg)
	_push_groups()
	stats["far"] = _bodies.size()
	stats["groups"] = _groups.size()

## Every group whose instances changed, to the server.
func _push_groups() -> void:
	var instances := 0
	for k in _groups:
		var g: Group = _groups[k]
		instances += g.count
		if not g.dirty:
			continue
		g.dirty = false
		RenderingServer.multimesh_set_buffer(g.mm, g.buf)
		RenderingServer.multimesh_set_visible_instances(g.mm, g.count)
	stats["instances"] = instances

## The bounds every far instance is culled by (one for all: a MultiMesh is
## drawn or not as a whole). Grown as bodies arrive and move, re-measured by
## reset_aabb (World3D, once a cycle).
func _grow_aabb(at: Vector3) -> void:
	var box := AABB(at - Vector3(12.0, 2.0, 12.0), Vector3(24.0, 26.0, 24.0))
	if _aabb_set and _aabb.encloses(box):
		return
	_aabb = box if not _aabb_set else _aabb.merge(box)
	# Grown with a margin, so a walking crowd does not reset every group often.
	_aabb = _aabb.grow(16.0)
	_aabb_set = true
	if _qa_log:
		printerr("QA CROWDGPU aabb grown: %d groups" % _groups.size())
	for k in _groups:
		RenderingServer.instance_set_custom_aabb((_groups[k] as Group).inst, _aabb)

## Round 757 (QA): the AABB writes logged, to place the engine's
## `!is_geometry_instance` errors (40 a boot, from instance_set_custom_aabb).
static var _qa_log := OS.get_environment("OPENSRO_QA_CROWDGPU_LOG") != ""

## Re-measures the bounds from every far body (World3D's cycle end).
func reset_aabb() -> void:
	if _bodies.is_empty():
		return
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for skel in _bodies:
		var p: Vector3 = (_bodies[skel] as Body).xf.origin
		lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
		hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
	reset_aabb_to(lo, hi)

## Round 757: the bounds from the far bodies' places as the caller's cycle
## scanned them (World3D: one cycle's scan reads every body anyway), so the
## cycle's end does not walk every far body again. A body that moved since is
## inside the grown margin, or grows the box itself (_grow_aabb).
func reset_aabb_to(lo: Vector3, hi: Vector3) -> void:
	if _bodies.is_empty():
		return
	var box := AABB(lo - Vector3(12.0, 2.0, 12.0), hi - lo + Vector3(24.0, 26.0, 24.0)).grow(16.0)
	if _aabb_set and _aabb.encloses(box) and _aabb.get_volume() < box.get_volume() * 4.0:
		return
	_aabb = box
	_aabb_set = true
	if _qa_log:
		printerr("QA CROWDGPU aabb reset: %d groups" % _groups.size())
	for k in _groups:
		RenderingServer.instance_set_custom_aabb((_groups[k] as Group).inst, _aabb)

# --- the body texture --------------------------------------------------------------

func _take_slot() -> int:
	if not _free_slots.is_empty():
		return _free_slots.pop_back()
	var s := _slots
	_slots += 1
	if _slots > _slot_cap:
		_slot_cap = maxi(SLOTS_PER_ROW, _slot_cap * 2)
		_body_data.resize(_slot_cap * FLOATS_PER_BODY)
	return s

func _update_transform(b: Body) -> void:
	if not is_instance_valid(b.node) or not b.node.is_inside_tree():
		return
	if (b.node.global_transform * b.local).is_equal_approx(b.xf):
		return
	_write_transform(b)
	_grow_aabb(b.xf.origin)

## The skeleton's place in the world: its holder's, times its own transform
## under it (the skeleton is top_level while far, so its global transform is
## not kept up).
func _write_transform(b: Body) -> void:
	var t := b.node.global_transform * b.local if b.node.is_inside_tree() else b.local
	b.xf = t
	var o := b.slot * FLOATS_PER_BODY
	_body_data[o] = t.basis.x.x
	_body_data[o + 1] = t.basis.y.x
	_body_data[o + 2] = t.basis.z.x
	_body_data[o + 3] = t.origin.x
	_body_data[o + 4] = t.basis.x.y
	_body_data[o + 5] = t.basis.y.y
	_body_data[o + 6] = t.basis.z.y
	_body_data[o + 7] = t.origin.y
	_body_data[o + 8] = t.basis.x.z
	_body_data[o + 9] = t.basis.y.z
	_body_data[o + 10] = t.basis.z.z
	_body_data[o + 11] = t.origin.z
	_body_dirty = true

## The clip texel: (first row, frame count, duration ms, offset ms), the
## offset being where the body's clock (`idle_time` + phase) stands in the
## loop at the epoch, so the shader's mod(clock + offset, duration) is
## CrowdAnim.frame_index's fposmod(ms, duration).
func _write_clip(b: Body, idle_time: float) -> void:
	var clip: Vector3i = b.layout.clips.get(b.frames, Vector3i(0, 1, 1))
	var phase := float(b.entry[3])
	var duration := float(clip.z)
	var o := b.slot * FLOATS_PER_BODY + 12
	_body_data[o] = float(clip.x)
	_body_data[o + 1] = float(clip.y)
	_body_data[o + 2] = duration
	_body_data[o + 3] = float(fposmod((_epoch + phase) * 1000.0, duration)) if duration > 0.0 else 0.0
	_body_dirty = true

## What the shader computes for `b` at `idle_time`: the baked frame's index
## in its clip (tests: held to CrowdAnim.frame_index).
func frame_of(skel: Skeleton3D, idle_time: float) -> int:
	var b: Body = _bodies.get(skel)
	if b == null:
		return -1
	var o := b.slot * FLOATS_PER_BODY + 12
	var clock := float(idle_time - _epoch) * 1000.0
	var ms := fposmod(clock + _body_data[o + 3], maxf(_body_data[o + 2], 1.0))
	return int(ms / CrowdAnim.QUANTUM_MS + 0.5) % maxi(int(_body_data[o + 1]), 1)

# --- layouts and baking -----------------------------------------------------------

func _layout_for(skel: Skeleton3D) -> Layout:
	var key := String(skel.get_meta(MonsterCrowd.META_LAYOUT, ""))
	if key == "":
		return null
	var l: Layout = _layouts.get(key)
	if l != null:
		return l
	var base: Skin = null
	for mi in CharacterAppearance._skinned_to(skel):
		base = CharacterAppearance.canonical_base(mi.skin)
		if base != null:
			break
	if base == null or base.get_bind_count() != skel.get_bone_count():
		return null
	l = Layout.new()
	l.key = key
	l.bones = skel.get_bone_count()
	l.width = l.bones * 3
	for i in range(l.bones):
		if base.get_bind_bone(i) != i:
			return null
		l.binds.append(base.get_bind_pose(i))
		l.rests.append(skel.get_bone_global_rest(i))
	# Round 757: the bones alone (CharacterAppearance._bare_skeleton: names,
	# parents, rests, every pose at rest, the transform), not a duplicate of the
	# live body. Node.duplicate() copied the body's children too -- among them
	# its weapons' particle nodes, whose `custom_aabb` it sets before their
	# `multimesh` (base-class properties first), so the RenderingServer refused
	# each with "!is_geometry_instance" (renderer_scene_cull.cpp l. 1019, READ):
	# the 40 engine errors of every crowd boot, 20 a layout (MEASURED: traced
	# with unbuffered QA prints, round 757).
	var scratch := CharacterAppearance._bare_skeleton(skel)
	scratch.set_meta(MonsterCrowd.META_LAYOUT, key)
	l.scratch = scratch
	_layouts[key] = l
	return l

## `first`: a clip a body waits on goes before the ones baked ahead (prebake).
func _queue_bake(l: Layout, fr: CrowdAnim.Frames, first: bool = true) -> void:
	if l.queued.has(fr) or l.clips.has(fr) or l.uploading.has(fr):
		return
	if l.rows + fr.count > MAX_ROWS:
		return
	var row0 := l.rows
	l.rows += fr.count
	while l.pages.size() * PAGE_ROWS < l.rows:
		var page := PackedFloat32Array()
		page.resize(PAGE_ROWS * l.width * 4)
		l.pages.append(page)
		l.dirty = true
	l.queued[fr] = true
	var job := [fr, 0, row0]
	# Never ahead of the clip being baked now (its job is pending[0]).
	if first and l.pending.size() > 1:
		l.pending.insert(1, job)
	else:
		l.pending.append(job)

## One baked frame: the layout's scratch skeleton at the clip's frame `f` --
## every channel the clip has from its first key (CrowdAnim.pose_cached's
## first pose of a clip), the moving ones from the frame, every other bone at
## rest (a body is built at rest: Skeleton3DBuilder.build_skeleton3d) -- and
## each bone's skin matrix into `row`.
func _bake_frame(l: Layout, fr: CrowdAnim.Frames, f: int, row: int) -> void:
	var sk := l.scratch
	sk.reset_bone_poses()
	var bones := fr.bones
	for k in range(bones.size()):
		sk.set_bone_pose_rotation(bones[k], fr.static_rot[k])
		sk.set_bone_pose_position(bones[k], fr.static_pos[k])
	var got: Array = fr.frame(f, true)
	var rots: Array = got[0]
	var rb := fr.moving_rot_bones
	for n in range(rb.size()):
		sk.set_bone_pose_rotation(rb[n], rots[n])
	var poss: Array = got[1]
	var pb := fr.moving_pos_bones
	for n in range(pb.size()):
		sk.set_bone_pose_position(pb[n], poss[n])
	# Out of the tree a pose change does not mark the skeleton dirty
	# (skeleton_3d.cpp:575, READ), so its globals are composed here, once.
	sk.force_update_all_bone_transforms()
	# The page is taken out of the Array while it is written, so the writes
	# do not copy it (a packed array shared by two holders copies on write).
	var pi := row / PAGE_ROWS
	var data: PackedFloat32Array = l.pages[pi]
	l.pages[pi] = PackedFloat32Array()
	var base := (row % PAGE_ROWS) * l.width * 4
	for b in range(l.bones):
		var m: Transform3D = sk.get_bone_global_pose(b) * l.binds[b]
		var o := base + b * 12
		data[o] = m.basis.x.x
		data[o + 1] = m.basis.y.x
		data[o + 2] = m.basis.z.x
		data[o + 3] = m.origin.x
		data[o + 4] = m.basis.x.y
		data[o + 5] = m.basis.y.y
		data[o + 6] = m.basis.z.y
		data[o + 7] = m.origin.y
		data[o + 8] = m.basis.x.z
		data[o + 9] = m.basis.y.z
		data[o + 10] = m.basis.z.z
		data[o + 11] = m.origin.z
	l.pages[pi] = data
	l.dirty_pages[pi] = true

## The row of a Volume variant skin (rest x variant bind per bone, so that
## base bind x it is the variant's bind), -1 for the base skin itself.
func _volume_row(l: Layout, skin: Skin, base: Skin) -> int:
	if skin == base:
		return -1
	if l.vol_rows.has(skin):
		return l.vol_rows[skin]
	var row := l.vol_count
	l.vol_count += 1
	l.vol_data.resize(l.vol_count * l.width * 4)
	var o0 := row * l.width * 4
	for b in range(l.bones):
		var m: Transform3D = l.rests[b] * skin.get_bind_pose(b) if b < skin.get_bind_count() else Transform3D.IDENTITY
		var o := o0 + b * 12
		l.vol_data[o] = m.basis.x.x
		l.vol_data[o + 1] = m.basis.y.x
		l.vol_data[o + 2] = m.basis.z.x
		l.vol_data[o + 3] = m.origin.x
		l.vol_data[o + 4] = m.basis.x.y
		l.vol_data[o + 5] = m.basis.y.y
		l.vol_data[o + 6] = m.basis.z.y
		l.vol_data[o + 7] = m.origin.y
		l.vol_data[o + 8] = m.basis.x.z
		l.vol_data[o + 9] = m.basis.y.z
		l.vol_data[o + 10] = m.basis.z.z
		l.vol_data[o + 11] = m.origin.z
	l.vol_rows[skin] = row
	l.vol_dirty = true
	return row

# --- parts --------------------------------------------------------------------------

## Whether `n` and every node between it and `top` are visible (the skeleton
## itself is hidden while far, so is_visible_in_tree cannot say), and `n` is
## not part of an effect: an EfpEffect under a weapon (EquipGlow's world-axis
## seal, EquipFx's own simulation) draws itself and is not a body part.
static func _shown_under(n: Node, top: Node) -> bool:
	var at := n
	while at != null and at != top:
		if at is EfpEffect or (at is Node3D and not (at as Node3D).visible):
			return false
		at = at.get_parent()
	return at == top

## Whether every node from `n` up to `top` sits at the identity: a mesh
## skinned to the body draws in the skeleton's space only then (Godot draws a
## skinned instance at its own transform).
static func _identity_under(n: Node, top: Node) -> bool:
	var at := n
	while at != null and at != top:
		if at is Node3D and not (at as Node3D).transform.is_equal_approx(Transform3D.IDENTITY):
			return false
		at = at.get_parent()
	return at == top

## Each visible mesh under `skel`, as {mesh, material, layers, sort, vol,
## centre}; null when one cannot be drawn here.
func _parts_of(skel: Skeleton3D, l: Layout):
	var out: Array = []
	for n in skel.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not _shown_under(mi, skel) or mi.mesh == null:
			continue
		if mi.mesh.get_surface_count() != 1 or mi.transparency > 0.0:
			_refuse("surfaces")
			return null
		var mat := mi.get_active_material(0) as ShaderMaterial
		if mat == null or mat.shader == null or mat.next_pass != null:
			_refuse("material")
			return null
		# A blended part (an MTRL mod's blend) is not drawn far (round 747's
		# review, F8): a MultiMesh's instances are not sorted against each
		# other, and every far group shares one AABB, so blended parts would
		# sort as one object. The body stays near, drawn as before.
		if blended(mat.shader):
			_refuse("blended")
			return null
		var target: Node = mi.get_node_or_null(mi.skeleton) if mi.skin != null else null
		var p := {"layers": mi.layers, "sort": mi.sorting_offset, "mi": mi}
		if target == skel:
			var base := CharacterAppearance.canonical_base(mi.skin)
			if base == null or not _identity_under(mi, skel):
				_refuse("skin")
				return null
			p["mesh"] = mi.mesh
			p["vol"] = _volume_row(l, mi.skin, base)
			p["centre"] = mi.mesh.get_aabb().get_center().y
		else:
			var att: BoneAttachment3D = null
			var chain := Transform3D.IDENTITY
			var at: Node = mi
			while at != null and at != skel:
				if at is BoneAttachment3D and at.get_parent() == skel:
					att = at
					break
				if at is Node3D:
					chain = (at as Node3D).transform * chain
				at = at.get_parent()
			if att == null:
				_refuse("hung")
				return null
			var bone := skel.find_bone(att.bone_name)
			if bone < 0:
				_refuse("hung")
				return null
			var made := rigid_mesh(mi, l.key, bone, l.rests[bone] * chain)
			if made == null:
				_refuse("rigid")
				return null
			p["mesh"] = made
			p["vol"] = -1
			p["centre"] = (l.rests[bone] * chain * mi.mesh.get_aabb().get_center()).y
		p["material"] = _twin(mat, l)
		p["twin_key"] = "%d|%s" % [mat.get_instance_id(), l.key]
		if p["material"] == null:
			_refuse("shader")
			return null
		out.append(p)
	return out

## Why a body was refused, counted (QA: describe()).
var refusals := {}
## The last cycle's bodies World3D kept near by reason (its _crowd_eligible).
var ineligible := {}

func _refuse(why: String) -> void:
	refusals[why] = int(refusals.get(why, 0)) + 1

## `mi`'s mesh moved into the space of `bone`'s rest (by `to_bone`: the
## bone's global rest times the chain from its BoneAttachment3D down to the
## mesh), each vertex skinned to `bone` alone with weight 1. A mesh skinned to
## an item's own skeleton (never posed: round 738) is first put where that
## skin puts it at rest, as Godot's skinning pass would (the weighted matrix
## sum, its normal normalised). Cached per mesh, layout and bone.
func rigid_mesh(mi: MeshInstance3D, layout_key: String, bone: int, to_bone: Transform3D) -> ArrayMesh:
	var key := "%d|%s|%d" % [mi.mesh.get_instance_id(), layout_key, bone]
	if _rigid.has(key):
		return _rigid[key]
	var arrays := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nrm = arrays[Mesh.ARRAY_NORMAL]
	var xf: Array[Transform3D] = []
	var vb = null
	var vw = null
	var per := 0
	if mi.skin != null:
		var isk := mi.get_node_or_null(mi.skeleton) as Skeleton3D
		vb = arrays[Mesh.ARRAY_BONES]
		vw = arrays[Mesh.ARRAY_WEIGHTS]
		if isk == null or vb == null or vw == null or v.is_empty():
			return null
		for i in range(mi.skin.get_bind_count()):
			var bb := mi.skin.get_bind_bone(i)
			if bb < 0:
				bb = isk.find_bone(mi.skin.get_bind_name(i))
			xf.append(isk.get_bone_global_pose(bb) * mi.skin.get_bind_pose(i))
		per = int(vb.size() / v.size())
	var out_v := PackedVector3Array()
	out_v.resize(v.size())
	var out_n := PackedVector3Array()
	var has_n: bool = nrm is PackedVector3Array and (nrm as PackedVector3Array).size() == v.size()
	if has_n:
		out_n.resize(v.size())
	for k in range(v.size()):
		var p := v[k]
		var nn: Vector3 = (nrm as PackedVector3Array)[k] if has_n else Vector3.UP
		if per > 0:
			var sp := Vector3.ZERO
			var sn := Vector3.ZERO
			for j in range(per):
				var w: float = vw[k * per + j]
				if w <= 0.0:
					continue
				var m: Transform3D = xf[int(vb[k * per + j])]
				sp += (m * p) * w
				sn += (m.basis * nn) * w
			p = sp
			nn = sn.normalized()
		out_v[k] = to_bone * p
		if has_n:
			out_n[k] = (to_bone.basis * nn).normalized()
	arrays[Mesh.ARRAY_VERTEX] = out_v
	if has_n:
		arrays[Mesh.ARRAY_NORMAL] = out_n
	arrays[Mesh.ARRAY_TANGENT] = null
	var bones := PackedInt32Array()
	bones.resize(v.size() * 4)
	var weights := PackedFloat32Array()
	weights.resize(v.size() * 4)
	for k in range(v.size()):
		bones[k * 4] = bone
		weights[k * 4] = 1.0
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var am := ArrayMesh.new()
	var prim := (mi.mesh as ArrayMesh).surface_get_primitive_type(0) if mi.mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
	am.add_surface_from_arrays(prim, arrays)
	_rigid[key] = am
	return am

# --- groups -------------------------------------------------------------------------

func _add_part(b: Body, p: Dictionary) -> void:
	var mesh: Mesh = p["mesh"]
	var mat: ShaderMaterial = p["material"]
	var key := "%d|%d|%d|%.4f" % [mesh.get_instance_id(), mat.get_instance_id(), int(p["layers"]), float(p["sort"])]
	var g: Group = _groups.get(key)
	if g == null:
		g = Group.new()
		g.key = key
		g.mesh = mesh
		g.material = mat
		g.mm = RenderingServer.multimesh_create()
		RenderingServer.multimesh_set_mesh(g.mm, mesh.get_rid())
		g.inst = RenderingServer.instance_create2(g.mm, scenario)
		RenderingServer.instance_geometry_set_material_override(g.inst, mat.get_rid())
		RenderingServer.instance_geometry_set_cast_shadows_setting(g.inst, RenderingServer.SHADOW_CASTING_SETTING_OFF)
		RenderingServer.instance_set_layer_mask(g.inst, int(p["layers"]))
		RenderingServer.instance_set_pivot_data(g.inst, float(p["sort"]), true)
		if _aabb_set:
			if _qa_log:
				printerr("QA CROWDGPU aabb on a new group %s" % key)
			RenderingServer.instance_set_custom_aabb(g.inst, _aabb)
		g.twin_key = String(p["twin_key"])
		_twin_users[g.twin_key] = int(_twin_users.get(g.twin_key, 0)) + 1
		_groups[key] = g
	if g.count >= g.cap:
		g.cap = maxi(8, g.cap * 2)
		RenderingServer.multimesh_allocate_data(g.mm, g.cap, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true)
		g.buf.resize(g.cap * INSTANCE_FLOATS)
	var idx := g.count
	g.count += 1
	var o := idx * INSTANCE_FLOATS
	for i in range(12):
		g.buf[o + i] = IDENTITY_ROWS[i]
	g.buf[o + 12] = float(b.slot)
	g.buf[o + 13] = float(int(p["vol"]))
	g.buf[o + 14] = float(p["centre"])
	g.buf[o + 15] = 0.0
	var rec := [g, idx, b]
	g.owners.append(rec)
	b.parts.append(rec)
	g.dirty = true

func _remove_part(rec: Array) -> void:
	var g: Group = rec[0]
	var idx: int = rec[1]
	var last := g.count - 1
	if idx != last:
		var o := idx * INSTANCE_FLOATS
		var lo := last * INSTANCE_FLOATS
		for i in range(INSTANCE_FLOATS):
			g.buf[o + i] = g.buf[lo + i]
		var moved: Array = g.owners[last]
		moved[1] = idx
		g.owners[idx] = moved
	g.owners.pop_back()
	g.count = last
	g.dirty = true

# --- materials ----------------------------------------------------------------------

## The far twin of `src` on layout `l`: `src`'s shader with the skin added
## (twin_shader), each of `src`'s parameters set again by name
## (ObjectLight.copy_material's way: round 706's review measured a
## Resource.duplicate() drawing brighter), and the crowd's textures. Its
## TexAni (round 722) animates it with `src`.
func _twin(src: ShaderMaterial, l: Layout) -> ShaderMaterial:
	var key := "%d|%s" % [src.get_instance_id(), l.key]
	var got: ShaderMaterial = _twins.get(key)
	# Held weakly (F7): a twin whose source died answers for no new material
	# that took its id.
	if got != null and _twin_sources.has(key) and (_twin_sources[key] as WeakRef).get_ref() == src:
		return got
	var sh := twin_shader(src.shader)
	if sh == null:
		return null
	var t := ShaderMaterial.new()
	t.resource_name = src.resource_name
	t.shader = sh
	t.render_priority = src.render_priority
	for u in src.shader.get_shader_uniform_list():
		var n: String = u["name"]
		var val = src.get_shader_parameter(n)
		if val != null:
			t.set_shader_parameter(n, val)
	if _body_tex != null:
		t.set_shader_parameter("crowd_bodies", _body_tex)
	if l.tex != null:
		t.set_shader_parameter("crowd_bones", l.tex)
	if l.vol_tex != null:
		t.set_shader_parameter("crowd_volume", l.vol_tex)
	else:
		l.vol_dirty = true
	t.set_shader_parameter("crowd_range", _range)
	TexAni.bind_like(t, src)
	l.twins.append(t)
	_twins[key] = t
	_twin_sources[key] = weakref(src)
	return t

## Whether a shader blends: a `blend_` render mode (ObjectLoader._mod_shader's
## MTRL blends, AppearFade's fade twins). Cached per shader.
func blended(sh: Shader) -> bool:
	var got = _blended.get(sh)
	if got != null:
		return got
	var yes := false
	for line in sh.code.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("render_mode") and t.contains("blend_"):
			yes = true
			break
	_blended[sh] = yes
	return yes

var _blended := {}

## `src`'s code with CROWD_GPU defined and crowd_gpu.gdshaderinc included
## after its render_mode, and crowd_gpu_vertex.gdshaderinc at the top of its
## vertex() -- or, for the object shaders, where object.gdshaderinc's own
## vertex() includes it under CROWD_GPU. Cached per shader.
func twin_shader(src: Shader) -> Shader:
	if src == null:
		return null
	var got: Shader = _twin_shaders.get(src)
	if got != null:
		return got
	var code := twin_code(src.code)
	if code == "":
		return null
	var sh := Shader.new()
	sh.code = code
	_twin_shaders[src] = sh
	return sh

static func twin_code(code: String) -> String:
	if not code.contains("shader_type spatial"):
		return ""
	var lines := code.split("\n")
	var at := -1
	for i in range(lines.size()):
		if lines[i].strip_edges().begins_with("render_mode"):
			at = i
			break
	if at < 0:
		for i in range(lines.size()):
			if lines[i].strip_edges().begins_with("shader_type"):
				at = i
				break
	lines.insert(at + 1, "#define CROWD_GPU\n#include \"%s\"" % HEAD_INCLUDE)
	var out := "\n".join(lines)
	if out.contains("object.gdshaderinc"):
		return out
	if out.contains("void vertex() {"):
		return out.replace("void vertex() {", "void vertex() {\n#include \"%s\"\n" % VERTEX_INCLUDE)
	return out + "\nvoid vertex() {\n#include \"%s\"\n}\n" % VERTEX_INCLUDE

## Once a cycle (World3D._crowd_choose): a group empty for GROUP_EMPTY_CYCLES
## cycles goes -- its instance and MultiMesh freed -- and a twin no group
## uses any more with it (round 747's review, F7: a walking crowd's light
## levels made groups and twins without end, and the twins held every level
## copy ObjectLight keeps only weakly). Returns the groups freed.
func collect() -> int:
	var freed := 0
	for key in _groups.keys():
		var g: Group = _groups[key]
		if g.count > 0:
			g.empty_cycles = 0
			continue
		g.empty_cycles += 1
		if g.empty_cycles < GROUP_EMPTY_CYCLES:
			continue
		RenderingServer.free_rid(g.inst)
		RenderingServer.free_rid(g.mm)
		_groups.erase(key)
		freed += 1
		var users := int(_twin_users.get(g.twin_key, 0)) - 1
		if users > 0:
			_twin_users[g.twin_key] = users
			continue
		_twin_users.erase(g.twin_key)
		var t: ShaderMaterial = _twins.get(g.twin_key)
		_twins.erase(g.twin_key)
		_twin_sources.erase(g.twin_key)
		if t != null:
			for k in _layouts:
				(_layouts[k] as Layout).twins.erase(t)
	stats["groups_freed"] = int(stats.get("groups_freed", 0)) + freed
	return freed

## Census for the QA line.
func describe() -> String:
	var rows := 0
	var clips := 0
	for k in _layouts:
		var l: Layout = _layouts[k]
		rows += l.rows
		clips += l.clips.size()
	return "far=%d heard=%d groups=%d instances=%d layouts=%d clips=%d rows=%d twins=%d rigid=%d added=%d removed=%d switch_ms=%.0f bake_ms=%.0f upload_ms=%.1f upload_max_ms=%.1f sound_advances=%d groups_freed=%d refused=%s kept_near=%s" % [
		_bodies.size(), heard_bodies().size(), _groups.size(), int(stats["instances"]), _layouts.size(), clips, rows, _twins.size(), _rigid.size(),
		int(stats["added"]), int(stats["removed"]), float(stats.get("switch_usec", 0)) / 1000.0, float(stats["bake_usec"]) / 1000.0,
		float(stats.get("upload_usec", 0)) / 1000.0, float(stats.get("upload_max_usec", 0)) / 1000.0,
		int(stats.get("sound_advances", 0)), int(stats.get("groups_freed", 0)),
		str(refusals).replace(" ", ""), str(ineligible).replace(" ", "")]

# --- checks -------------------------------------------------------------------------

## The world positions of every vertex of a far body's parts at `idle_time`,
## computed on the CPU exactly as crowd_gpu_vertex.gdshaderinc computes them
## from the textures' data (tools/crowd_gpu_probe.gd and crowd_gpu_test hold
## them to the near path's own skin). One PackedVector3Array a part, in the
## order of its parts (the skeleton's visible meshes, find_children order).
func cpu_skin(skel: Skeleton3D, idle_time: float) -> Array:
	var b: Body = _bodies.get(skel)
	if b == null:
		return []
	var l := b.layout
	var clip: Vector3i = l.clips.get(b.frames, Vector3i(0, 1, 1))
	var row := clip.x + frame_of(skel, idle_time)
	var out: Array = []
	for rec in b.parts:
		var g: Group = rec[0]
		var o: int = int(rec[1]) * INSTANCE_FLOATS
		var vol := int(floor(g.buf[o + 13] + 0.5))
		var arrays := g.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var vb = arrays[Mesh.ARRAY_BONES]
		var vw = arrays[Mesh.ARRAY_WEIGHTS]
		var per := int(vb.size() / maxi(v.size(), 1))
		var pts := PackedVector3Array()
		pts.resize(v.size())
		for k in range(v.size()):
			var p := Vector3.ZERO
			for j in range(per):
				var w: float = vw[k * per + j]
				if w <= 0.0:
					continue
				var bone := int(vb[k * per + j])
				var m := _bone_xf(l, row, bone)
				if vol >= 0:
					m = m * _row_xf(l.vol_data, (vol * l.width + bone * 3) * 4)
				p += (m * v[k]) * w
			pts[k] = b.xf * p
		out.append(pts)
	return out

## The baked skin matrix of `bone` in `row` of layout `l`'s pages.
static func _bone_xf(l: Layout, row: int, bone: int) -> Transform3D:
	var page: PackedFloat32Array = l.pages[row / PAGE_ROWS]
	return _row_xf(page, ((row % PAGE_ROWS) * l.width + bone * 3) * 4)

## Three row texels at `o` as a Transform3D.
static func _row_xf(data: PackedFloat32Array, o: int) -> Transform3D:
	return Transform3D(Basis(Vector3(data[o], data[o + 4], data[o + 8]), Vector3(data[o + 1], data[o + 5], data[o + 9]),
		Vector3(data[o + 2], data[o + 6], data[o + 10])), Vector3(data[o + 3], data[o + 7], data[o + 11]))
