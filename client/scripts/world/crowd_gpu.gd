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
## Round 759: a fifth texel, the body's object colour (_write_light), so a
## character's light levels share one group per mesh (crowd_gpu.gdshaderinc).
const TEXELS_PER_BODY := 5
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
	## Round 759: a set (twin -> true), not an Array: collect() drops one per
	## freed twin, and an Array's erase is a search through thousands.
	var twins := {}

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
	## Round 762: the material its twin is of (its fade twin is made from it),
	## the layout, and the fade instance: the same MultiMesh drawn with the
	## fade twin, which draws only the fading bodies (crowd_gpu_vertex).
	var src: Material = null
	var layout: Layout = null
	var layers := 1
	var sort := 0.0
	var fade_inst := RID()
	var fade_mat: ShaderMaterial = null
	var fade_tried := false
	## Its instances whose body is fading (in, out or held), and of those the
	## ones held in each hold slot (slot -> count); the two instances' shown
	## state as last sent.
	var n_fade := 0
	var held := {}
	var shown_o := true
	var shown_f := false

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
	## Round 756: a body drawn from its kind's recipe before it is built
	## (add_ghost): no skeleton; `key` is its holder node (a built body's is
	## its skeleton), the key of `_bodies` and of its clip sounds.
	var ghost := false
	var key: Object
	var recipe: CharacterAppearance.FarRecipe
	## The object colour it is drawn at (-1: the materials as they are), and
	## the lit materials its parts draw with, held (ObjectLight keeps its
	## copies weakly).
	var light := -1.0
	var mats: Array = []
	## Its fade on the GPU (round 756): 0 none, FADE_IN, FADE_OUT, and the
	## clip time (World3D._idle_anim_time) it began at.
	var fade := 0
	var fade_start := 0.0
	## Round 759: the object colour its lit parts draw at (texel 4; -1 none),
	## the value its level copy of a material would carry (ObjectLight).
	var objc := -1.0
	## Round 762: the hold slot of the page it arrived in (-1 none) until its
	## fade-in is over, and the fade's cohort (FadeCohort) while it fades.
	var hold := -1
	var cohort = null

## Round 762: bodies whose fade began together (one frame, one way), or a held
## page (a hold slot) until its reveal: their fade ends together, and the
## work that follows (each body's texel and counts) is spread over frames
## (FADE_END_BUDGET_USEC).
class FadeCohort:
	var kind := 0
	var start := INF
	var slot := -1
	var bodies: Array = []
	var next := 0

var scenario: RID
var _layouts := {}            # layout key -> Layout
var _groups := {}             # group key -> Group
## Round 759: the groups whose instances changed since the last push, and the
## instances in every group (kept as they come and go).
var _dirty_groups := {}       # Group -> true
var _instances := 0
var _bodies := {}             # Skeleton3D -> Body
var _by_node := {}            # Node3D -> Body
var _twin_shaders := {}       # Shader -> Shader
var _twins := {}              # "material id|layout" -> ShaderMaterial
var _twin_sources := {}       # the same key -> WeakRef to the source material (its id is the key)
var _twin_users := {}         # twin ShaderMaterial -> groups drawing with it
var _rigid := {}              # "mesh id|layout|bone" -> ArrayMesh
var _free_slots: Array[int] = []
var _slots := 0
var _slot_cap := 0
## Round 762: the body texture's first size, in bodies (_take_slot).
var first_slot_cap := SLOTS_PER_ROW * 16
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
		if g.fade_inst.is_valid():
			RenderingServer.free_rid(g.fade_inst)
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
	return skel != null and _bodies.has(skel)

## Round 756: whether `node` (another player's holder) is drawn as a ghost.
func is_ghost(node: Object) -> bool:
	var b: Body = _bodies.get(node) if node != null else null
	return b != null and b.ghost

## Every ghost's holder node.
func ghosts() -> Array:
	var out: Array = []
	for k in _bodies:
		if (_bodies[k] as Body).ghost:
			out.append(k)
	return out

## How many bodies are ghosts.
func ghost_count() -> int:
	return _ghost_count

var _ghost_count := 0

func body_count() -> int:
	return _bodies.size()

## The entry a far skeleton plays ([skeleton, anim, frames, phase, loops, ...]), or [].
func entry_of(skel: Object) -> Array:
	var b: Body = _bodies.get(skel)
	return b.entry if b != null else []

## Every far skeleton.
func skeletons() -> Array:
	var out: Array = []
	for k in _bodies:
		if not (_bodies[k] as Body).ghost:
			out.append(k)
	return out

## The far body record of `skel`, or null (World3D's sound step).
func body_of(skel: Object) -> Body:
	return _bodies.get(skel) if skel != null else null

## Round 762: the far body whose holder is `node` (a ghost's or a built one's).
func body_by_node(node: Object) -> Body:
	return _by_node.get(node) if node != null else null

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
##
## Round 762: `fade_from` (a clip time), when given, is a fade-in it goes on
## with (a ghost's, handed over to its built skeleton).
func add(node: Node3D, skel: Skeleton3D, entry: Array, idle_time: float, fade_from: float = NAN, hold: int = -1) -> bool:
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
	b.objc = _parts_objc(parts)
	_write_light(b)
	if hold_pending(hold):
		# Round 762: dressed while its page is held: held with it.
		_begin_fade(b, FADE_IN, INF, hold)
	elif not is_nan(fade_from):
		_begin_fade(b, FADE_IN, fade_from)
	else:
		_write_fade(b)
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
##
## Round 762: `departing`, a body whose holder is about to be freed after its
## fade-out (World3D's departures): its meshes stay hidden and its skeleton
## as it is, which nothing will draw again.
func remove(skel: Object, push: bool = true, departing: bool = false) -> Array:
	var b: Body = _bodies.get(skel) if skel != null else null
	if b == null:
		return []
	if b.ghost:
		_ghost_count -= 1
	for p in b.parts:
		_remove_part(p)
	b.parts.clear()
	if b.fade != 0:
		_fade_count -= 1
		b.fade = 0
		b.hold = -1
		b.cohort = null
	if push:
		_push_groups()
	_bodies.erase(skel)
	_keys_dirty = true
	_heard_dirty = true
	if _by_node.get(b.node) == b:
		_by_node.erase(b.node)
	_moved.erase(b)
	# Out of hearing as it leaves (round 757's review F1, round 756's S4):
	# World3D's sound wheel drops a record that is not heard, or not its
	# skeleton's (a ghost's: its holder's) current one.
	b.heard = false
	b.sound_due = INF
	_free_slots.append(b.slot)
	# A freed slot draws nothing: no instance names it. Its fade texel is
	# cleared for the next body to take it.
	if b.slot >= 0:
		_body_data[b.slot * FLOATS_PER_BODY + 17] = 0.0
	if departing:
		b.hidden.clear()
		stats["removed"] += 1
		return b.entry
	_unhide(b)
	if not b.ghost and is_instance_valid(skel):
		var sk := skel as Skeleton3D
		sk.top_level = false
		sk.transform = b.local
		sk.remove_meta(META_FAR)
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
func set_clip(skel: Object, anim: BanReader.ParsedAnimation, frames: int, idle_time: float) -> bool:
	var b: Body = _bodies.get(skel) if skel != null else null
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
		if b.ghost:
			_ghost_waits_bake = true
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
	# A ghost has no meshes to re-read (round 756): its light is ghost_light's.
	if b == null or b.ghost:
		return true
	_unhide(b)
	var parts = _parts_of(b.skel, b.layout)
	if parts == null:
		return false
	b.objc = _parts_objc(parts)
	_write_light(b)
	for p in b.parts:
		_remove_part(p)
	b.parts.clear()
	for p in parts:
		_add_part(b, p)
	_hide(b, parts)
	return true

# --- ghosts (round 756) -------------------------------------------------------------

## Round 756 (OURS; docs/rounds/r756.md): an arriving body drawn at once,
## before it is built. Retail creates every character of a group spawn, its
## meshes loaded, inside the one 0x3018 call, and draws them all from that
## frame, fading in together (READ, r756.md section 1); this client builds a
## dressed body in 1.5-3.5 ms (MEASURED), so a page of 1000 dressed at once
## would be a multi-second frame and was dressed one or a few a frame
## instead (round 739's pump). A ghost is the body as CrowdGpu would draw it
## far, made straight from its kind's recipe (CharacterAppearance.far_recipe:
## the template meshes, the glow and Volume build() would give them) without a
## node: a body slot, a clip texel, an instance a part. World3D dresses it
## later, nearest first, and hands the dressed skeleton over in the same
## frame (remove, then add with the same entry): the same meshes, materials,
## clip and phase, so the same pixels.
##
## The fade (READ: every character fades in over 2.0 s from its spawn, out
## over 1.5 s on a despawn, AppearFade): a fading ghost's parts draw from
## groups of their own with the blended fade twin of their material
## (AppearFade.fade_twin, with the skin), whose alpha the vertex shader works
## out per instance from the clock and the fade's start in INSTANCE_CUSTOM.w
## (crowd_gpu.gdshaderinc's srr_cg_fade: AppearFade.alpha_at's truncated byte),
## so no material changes as fades run and one twin a material serves every
## fade; they move to the shared groups when it ends. The instances of a fade
## group are not sorted against each other (one MultiMesh, OURS approximation
## for the 2 s; the fade twins write depth, as the near ones do).

## Baking budget a frame while a ghost waits on a clip not baked yet (OURS):
## the arrival of a kind whose stand loop is new waits on its frames.
const GHOST_BAKE_BUDGET_USEC := 16000
const BAKE_MIN_USEC := 500
const FADE_IN := 1
const FADE_OUT := 2

var _ghost_waits_bake := false
## Bumped whenever baked clips become drawable (_upload): a ghost that waited
## on its clip may be drawn now (World3D asks again only then).
var clip_generation := 0
var _ghost_waits_upload := false
## recipe key -> [Layout, [[part, material, overridden], ...]], or null when
## a piece is not drawable far (the body is dressed instead).
var _recipe_geo := {}
## "recipe key|light level" -> the parts with their lit materials (no twins:
## review F2), and per recipe its levels in the order they were made (F5).
var _recipe_lit := {}
var _recipe_lit_order := {}
const LIT_LEVELS_PER_RECIPE := 4
const LIT_CACHE_CAP := 4096
## Lit material id -> [WeakRef to it, its fade twin source] (_fade_src).
var _fade_srcs := {}
const FADE_SRC_CAP := 4096
## Round 762: the fade cohorts (FadeCohort), those begun this frame by kind
## and start, each hold slot's cohort (null: free) and the groups its bodies
## draw from, the slots' reveal clocks (ms; REVEAL_HELD while held), the
## groups whose instances' shown state is to be worked out again, and how
## many bodies fade.
var _cohorts: Array = []
var _open_cohorts := {}
var _slot_cohort: Array = [null, null, null, null]
var _slot_groups: Array = [{}, {}, {}, {}]
var _reveal := PackedFloat32Array([REVEAL_HELD, REVEAL_HELD, REVEAL_HELD, REVEAL_HELD])
var _vis_dirty := {}
var _fade_count := 0

## Draws `node` (another player's holder, in the tree) as the body `recipe`
## names, playing `entry` (World3D._animated's shape, entry[0] the node), its
## skeleton at `local` under the holder, at object colour `light` (-1: the
## materials as they are), fading in from nothing when `fade`. False, nothing
## changed, when it cannot yet (its clip is still baking: queued first) or
## cannot at all (refusals; the caller dresses it instead: can_ghost).
func add_ghost(node: Node3D, recipe: CharacterAppearance.FarRecipe, entry: Array, local: Transform3D, light: float,
		idle_time: float, fade: bool, hold: int = -1) -> bool:
	if not enabled or node == null or recipe == null or _bodies.has(node) or not node.is_inside_tree():
		return false
	var q0 := Time.get_ticks_usec() if FrameSplit.on else 0
	var geo = _recipe_geometry(recipe)
	if geo == null or geo is String:
		return false
	var l: Layout = geo[0]
	if entry.size() < 5 or not bool(entry[4]):
		return false
	var anim: BanReader.ParsedAnimation = entry[1]
	if not ghost_clip_ready(recipe, anim):
		return false
	var q1 := Time.get_ticks_usec() if FrameSplit.on else 0
	if _lit_parts(recipe, l, light).is_empty():
		return false
	if FrameSplit.on:
		# QA (round 762): add_ghost's phases.
		var q2 := Time.get_ticks_usec()
		FrameSplit.add("ga_geo", q1 - q0)
		FrameSplit.add("ga_lit", q2 - q1)
	# A mirrored holder, as add() refuses one (review F9; none is mirrored).
	if (node.global_transform * local).basis.determinant() < 0.0:
		_refuse("mirrored")
		return false
	var b := Body.new()
	b.ghost = true
	b.key = node
	b.node = node
	b.layout = l
	b.entry = entry
	b.frames = CrowdAnim.frames_for(l.scratch, anim)
	b.recipe = recipe
	b.light = light
	b.slot = _take_slot()
	b.local = local
	_bodies[node] = b
	_by_node[node] = b
	_keys_dirty = true
	_ghost_count += 1
	_write_transform(b)
	_write_clip(b, idle_time)
	# Round 762: held with its page (`hold`, a slot from hold_open) until the
	# page is revealed, or fading in from now.
	if fade and hold_pending(hold):
		_begin_fade(b, FADE_IN, INF, hold)
	elif fade:
		_begin_fade(b, FADE_IN, idle_time)
	else:
		_write_fade(b)
	var q3 := Time.get_ticks_usec() if FrameSplit.on else 0
	_add_ghost_parts(b)
	if FrameSplit.on:
		FrameSplit.add("ga_parts", Time.get_ticks_usec() - q3)
	_grow_aabb(b.xf.origin)
	stats["ghosts"] = int(stats.get("ghosts", 0)) + 1
	return true

## Round 759: a ghost's object colour, the value its lit parts' level copies
## would carry (ObjectLight.object_color_at), or -1 when none is lit.
func _ghost_objc(b: Body) -> float:
	if b.light < 0.0:
		return -1.0
	for e in _lit_parts(b.recipe, b.layout, b.light):
		if bool(e["lit_on"]):
			return ObjectLight.object_color_at(e["lit"], b.light)
	return -1.0

## Whether `anim` is drawable on `recipe`'s layout now (baked and up); a clip
## not baked is queued first. A ghost asks this before anything else.
func ghost_clip_ready(recipe: CharacterAppearance.FarRecipe, anim: BanReader.ParsedAnimation) -> bool:
	var geo = _recipe_geometry(recipe)
	if geo == null or geo is String or anim == null or anim.duration_ms <= 0 or anim.key_times.is_empty():
		return false
	var l: Layout = geo[0]
	var fr := CrowdAnim.frames_for(l.scratch, anim)
	if l.clips.has(fr):
		return true
	if l.uploading.has(fr):
		_ghost_waits_upload = true
	else:
		_queue_bake(l, fr)
		_ghost_waits_bake = true
	return false

## Queues `anim`'s frames on `recipe`'s layout (World3D: a ghost's run, so
## its first step finds it baked; review F3). Nothing when baked or queued.
func prebake_recipe(recipe: CharacterAppearance.FarRecipe, anim: BanReader.ParsedAnimation) -> void:
	var geo = _recipe_geometry(recipe) if recipe != null else null
	if geo == null or geo is String or anim == null or anim.duration_ms <= 0 or anim.key_times.is_empty():
		return
	var l: Layout = geo[0]
	_queue_bake(l, CrowdAnim.frames_for(l.scratch, anim), false)

## Whether `recipe` can be drawn far at all (its pieces pass the far path's
## rules); its parts are worked out once.
func can_ghost(recipe: CharacterAppearance.FarRecipe) -> bool:
	# A recipe whose rigid pieces are still being made can (it waits).
	return enabled and recipe != null and _recipe_geometry(recipe) != null

## A ghost's object colour changed (CharacterLight): its parts take the
## level's materials.
func ghost_light(node: Object, light: float) -> void:
	var b: Body = _bodies.get(node) if node != null else null
	if b == null or not b.ghost or roundi(b.light * ObjectLight.VARIANT_STEPS) == roundi(light * ObjectLight.VARIANT_STEPS):
		return
	var was_lit := b.light >= 0.0
	b.light = light
	# Round 759: a new level is the body's texel; its parts and groups stay.
	if was_lit != (light >= 0.0):
		_reparts(b)
		return
	b.objc = _ghost_objc(b)
	_write_light(b)

## A ghost drawn again (a new kind, World3D._ghost_other) goes on with the
## fade-in it was in, from `start` (a clip time).
func continue_fade_in(node: Object, start: float) -> void:
	var b: Body = _bodies.get(node) if node != null else null
	if b == null or b.fade != 0:
		return
	_begin_fade(b, FADE_IN, start)

## The body's place in its fade-in, seconds (-1: not fading in; 0 while its
## page is held).
func fade_elapsed(node: Object) -> float:
	var b: Body = _by_node.get(node) if node != null else null
	if b == null:
		b = _bodies.get(node) if node != null else null
	if b == null or b.fade != FADE_IN:
		return -1.0
	if is_inf(b.fade_start):
		return 0.0
	return maxf(_last_time - b.fade_start, 0.0)

## The clip time `node`'s fade-in began at (its page's reveal), NAN when it is
## not fading in or its page is still held.
func fade_start_of(node: Object) -> float:
	var b: Body = _by_node.get(node) if node != null else null
	if b == null or b.fade != FADE_IN or is_inf(b.fade_start):
		return NAN
	return b.fade_start

## The hold slot `node`'s body arrived in (-1: none, or its fade is over).
func hold_of(node: Object) -> int:
	var b: Body = _by_node.get(node) if node != null else null
	return b.hold if b != null else -1

## Whether the far body keyed `key` (a skeleton, or a ghost's holder) fades.
func is_fading(key: Object) -> bool:
	var b: Body = _bodies.get(key) if key != null else null
	return b != null and b.fade != 0

## Whether `node`'s body waits in a held page (drawn at alpha 0).
func is_held(node: Object) -> bool:
	var b: Body = _by_node.get(node) if node != null else null
	return b != null and b.fade == FADE_IN and is_inf(b.fade_start)

## A departing far body (a ghost or a built one -- round 762: a built far body
## too, which before was brought back to the CPU path to fade) fades out over
## AppearFade.DISAPPEAR_SECONDS from now, drawn by its groups' fade
## instances, then draws nothing until its owner removes it (remove(...,
## departing)). A body still fading in fades out from full, as
## AppearFade.start_out does; one whose page is still held is gone at once
## (alpha 0). False when `node` holds no far body here.
func fade_out(node: Object) -> bool:
	var b: Body = _by_node.get(node) if node != null else null
	if b == null:
		return false
	if b.fade == FADE_OUT:
		return true
	var start := _last_time
	if b.fade == FADE_IN and is_inf(b.fade_start):
		start = _last_time - AppearFade.DISAPPEAR_SECONDS - 1.0
	_begin_fade(b, FADE_OUT, start)
	return true

## Round 762: `b` begins to fade (`kind`) from clip time `start` -- INF and a
## hold slot for a held page -- in the cohort that began this frame the same
## way. Its instances move from its groups' opaque instances to their fade
## instances: counts only, the shader reads the texel.
func _begin_fade(b: Body, kind: int, start: float, hold: int = -1) -> void:
	var was := b.fade
	var was_hold := b.hold
	if was == 0:
		_fade_count += 1
	b.fade = kind
	b.fade_start = start
	b.hold = hold
	var co: FadeCohort = null
	if hold >= 0:
		co = _slot_cohort[hold]
	else:
		var key := Vector2i(kind, int(start * 1000.0))
		co = _open_cohorts.get(key)
		if co == null or co.start != start:
			co = FadeCohort.new()
			co.kind = kind
			co.start = start
			_cohorts.append(co)
			_open_cohorts[key] = co
	b.cohort = co
	co.bodies.append(b)
	for rec in b.parts:
		var g: Group = rec[0]
		if was == 0:
			g.n_fade += 1
		if was_hold >= 0:
			g.held[was_hold] = int(g.held.get(was_hold, 0)) - 1
		if hold >= 0:
			g.held[hold] = int(g.held.get(hold, 0)) + 1
			(_slot_groups[hold] as Dictionary)[g] = true
		_vis_dirty[g] = true
	_write_fade(b)

## Round 762: `b`'s fade-in is over: its instances go back to the opaque ones.
func _end_fade(b: Body) -> void:
	if b.fade == 0:
		return
	for rec in b.parts:
		var g: Group = rec[0]
		g.n_fade -= 1
		if b.hold >= 0:
			g.held[b.hold] = int(g.held.get(b.hold, 0)) - 1
		_vis_dirty[g] = true
	_fade_count -= 1
	b.fade = 0
	b.hold = -1
	b.cohort = null
	stats["fades_done"] = int(stats.get("fades_done", 0)) + 1
	_write_fade(b)

## Texel 4's y: the body's fade as crowd_gpu.gdshaderinc's srr_cg_fade reads it.
func _write_fade(b: Body) -> void:
	var v := 0.0
	if b.fade != 0:
		if b.hold >= 0:
			v = HOLD_CODE + float(b.hold)
		else:
			var ms := (b.fade_start - _epoch) * 1000.0
			v = FADE_CODE + ms if b.fade == FADE_IN else -(FADE_CODE + ms)
	var o := b.slot * FLOATS_PER_BODY + 17
	if _body_data[o] == v:
		return
	_body_data[o] = v
	_body_dirty = true

## Round 762: how many bodies are fading (in, out, or held).
func fading_count() -> int:
	return _fade_count

const FADE_CODE := 1.0e6
const HOLD_CODE := 4.0e6
## Hold slots (crowd_gpu.gdshaderinc's srr_crowd_reveal: a vec4).
const HOLD_SLOTS := 4
## The fades' end work a frame at most (OURS): a page of 4,000 ends its
## fade-in together, and each body's end is its texel and a count a part.
const FADE_END_BUDGET_USEC := 1500
const REVEAL_HELD := 1.0e9

## Round 762 (OURS; r762.md): a page arriving is held -- its ghosts made over
## frames at alpha 0 -- and revealed in one frame, every body fading in
## together, as retail creates a group spawn's characters in one call (READ,
## r756.md). A free slot for a held page, or -1 when all four are in use (the
## caller fades its bodies in at once instead).
func hold_open() -> int:
	for k in range(HOLD_SLOTS):
		if _slot_cohort[k] == null:
			var co := FadeCohort.new()
			co.kind = FADE_IN
			co.slot = k
			_slot_cohort[k] = co
			_slot_groups[k] = {}
			_cohorts.append(co)
			_reveal[k] = REVEAL_HELD
			_send_reveal()
			return k
	return -1

## Whether slot `k` holds a page not revealed yet.
func hold_pending(k: int) -> bool:
	return k >= 0 and k < HOLD_SLOTS and _slot_cohort[k] != null and is_inf((_slot_cohort[k] as FadeCohort).start)

## Reveals slot `k`'s page: every body in it begins its fade-in at clip time
## `idle_time`, in this frame (one shader parameter, and the shown state of
## the groups it draws from). Returns how many bodies it revealed.
func reveal(k: int, idle_time: float) -> int:
	if not hold_pending(k):
		return 0
	var co: FadeCohort = _slot_cohort[k]
	co.start = idle_time
	_reveal[k] = float((idle_time - _epoch) * 1000.0)
	_send_reveal()
	var n := 0
	for b in co.bodies:
		if (b as Body).cohort == co:
			(b as Body).fade_start = idle_time
			n += 1
	for g in _slot_groups[k]:
		_vis_dirty[g] = true
	return n

func _send_reveal() -> void:
	RenderingServer.global_shader_parameter_set(&"srr_crowd_reveal", Vector4(_reveal[0], _reveal[1], _reveal[2], _reveal[3]))

## The fades that ended by `idle_time` (flush): a fade-in's bodies go back to
## the opaque instances, FADE_END_BUDGET_USEC a frame; a fade-out's bodies
## draw nothing from then (their owner removes them); a held slot is free
## again once its page's fade-in is over for every body in it.
func _step_fades(idle_time: float) -> void:
	_open_cohorts.clear()
	if _cohorts.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var keep: Array = []
	for c in _cohorts:
		var co: FadeCohort = c
		if is_inf(co.start):
			keep.append(co)
			continue
		var e := idle_time - co.start
		if co.kind == FADE_OUT:
			if not AppearFade.out_done_at(e, AppearFade.DISAPPEAR_SECONDS):
				keep.append(co)
			continue
		if not AppearFade.done_at(e, AppearFade.APPEAR_SECONDS):
			keep.append(co)
			continue
		while co.next < co.bodies.size() and Time.get_ticks_usec() - t0 < FADE_END_BUDGET_USEC:
			var b: Body = co.bodies[co.next]
			co.next += 1
			if b.cohort == co:
				_end_fade(b)
		if co.next < co.bodies.size():
			keep.append(co)
			continue
		if co.slot >= 0 and _slot_cohort[co.slot] == co:
			_slot_cohort[co.slot] = null
			(_slot_groups[co.slot] as Dictionary).clear()
			_reveal[co.slot] = REVEAL_HELD
			_send_reveal()
	_cohorts = keep

## A ghost's parts again (its light changed): off its groups, then on the
## ones it draws from now.
func _reparts(b: Body) -> void:
	for p in b.parts:
		_remove_part(p)
	b.parts.clear()
	_add_ghost_parts(b)

## A ghost's parts on its meshes' shared groups (round 762: a fading one's
## too; its fade is its texel and its groups' fade instances).
func _add_ghost_parts(b: Body) -> void:
	var parts := _lit_parts(b.recipe, b.layout, b.light)
	b.objc = _ghost_objc(b)
	_write_light(b)
	b.mats.clear()
	var l := b.layout
	for p in parts:
		var lit: Material = p["lit"]
		b.mats.append(lit)
		# The twin is looked up on every add, never cached with the part
		# (round 756's review, F2): collect() frees a twin with its last
		# group, and a cached one would no longer be given the crowd's
		# textures as they grow.
		var tk: String = p["tk"]
		var twin: ShaderMaterial = null
		var glow := -1
		var tw0 := Time.get_ticks_usec() if FrameSplit.on else 0
		# Round 759: a glow material draws from its item's one glow twin,
		# the row per instance.
		if EquipGlow.is_glow(lit):
			var gt := _glow_twin(lit, l)
			twin = gt[0]
			tk = gt[1]
			glow = _glow_row(lit)
		else:
			twin = _live_twin(lit, tk, l)
		if FrameSplit.on:
			FrameSplit.add("ga_twin", Time.get_ticks_usec() - tw0)
		if twin == null:
			continue
		# The group key, kept per twin by id (never the twin itself, F2).
		var gk = p.get("gk")
		if gk == null or int(gk[0]) != twin.get_instance_id():
			gk = [twin.get_instance_id(), "%d|%d|%d|%.4f" % [(p["mesh"] as Mesh).get_instance_id(), twin.get_instance_id(), int(p["layers"]), float(p["sort"])]]
			p["gk"] = gk
		var q := {"mesh": p["mesh"], "material": twin, "layers": p["layers"], "sort": p["sort"], "vol": p["vol"], "centre": p["centre"],
			"twin_key": tk, "gkey": gk[1], "src": lit}
		if bool(p.get("lit_on", false)):
			q["objc"] = b.objc
		if glow >= 0:
			q["glow"] = glow
		var ap0 := Time.get_ticks_usec() if FrameSplit.on else 0
		_add_part(b, q)
		if FrameSplit.on:
			FrameSplit.add("ga_addpart", Time.get_ticks_usec() - ap0)

## `m`'s twin as _twin answers, without re-making its key: the live one in
## _twins when it is still `m`'s (its source checked by the weak reference),
## else _twin's.
func _live_twin(m: Material, tk: String, l: Layout) -> ShaderMaterial:
	var got: ShaderMaterial = _twins.get(tk)
	if got != null:
		var src = _twin_sources.get(tk)
		if src != null and (src as WeakRef).get_ref() == m:
			return got
	return _twin(m as ShaderMaterial, l)

## The blended fade twin of `lit` (AppearFade.fade_twin), or null when it
## has none (the part pops). Made once a material, held while that material
## lives (checked by a weak reference, so a new material that takes a freed
## one's id is not given its fade); the cache is dropped whole past
## FADE_SRC_CAP entries (they are remade on demand).
func _fade_src(lit: Material) -> Material:
	var id := lit.get_instance_id()
	var got = _fade_srcs.get(id)
	if got != null and (got[0] as WeakRef).get_ref() == lit:
		return got[1]
	if _fade_srcs.size() >= FADE_SRC_CAP:
		_fade_srcs.clear()
	var src: Material = AppearFade.fade_twin(lit)
	_fade_srcs[id] = [weakref(lit), src]
	return src

## The recipe's parts as the far path reads a built body (_part_for), once
## per recipe; null when one is not drawable far.
## Round 762: what _recipe_geometry (and _part_for under it) answer while a
## rigid piece's mesh is still being made: not a refusal, a wait.
const RECIPE_PENDING := "pending"
var _recipe_sliced := false

func _recipe_geometry(recipe: CharacterAppearance.FarRecipe):
	if _recipe_geo.has(recipe.key):
		return _recipe_geo[recipe.key]
	var l := _layout_for(recipe.skeleton, recipe.layout_key)
	if l == null:
		_recipe_geo[recipe.key] = null
		return null
	var parts: Array = []
	var pending := false
	for piece in recipe.pieces:
		var mi: MeshInstance3D = piece[0]
		var top: Node = piece[6]
		if mi.mesh == null or not _shown_under(mi, top.get_parent()):
			continue
		var to_body := bool(piece[7])
		var identity := true
		if to_body:
			var at: Node = mi
			while at != null and at != top.get_parent():
				if at is Node3D and not (at as Node3D).transform.is_equal_approx(Transform3D.IDENTITY):
					identity = false
					break
				at = at.get_parent()
		_recipe_sliced = true
		var p = _part_for(mi, piece[1], piece[3], to_body, identity, String(piece[4]), piece[5], l, false)
		_recipe_sliced = false
		if p is String:
			# Round 762: a rigid piece still being made (step_rigid_jobs): the
			# recipe waits, every other piece's mesh started too.
			pending = true
			continue
		if p == null:
			_recipe_geo[recipe.key] = null
			return null
		parts.append([p, piece[1], bool(piece[2])])
	if pending:
		return RECIPE_PENDING
	# Nothing to draw (a body with no mesh): it is dressed instead.
	if parts.is_empty():
		_recipe_geo[recipe.key] = null
		return null
	var got := [l, parts]
	_recipe_geo[recipe.key] = got
	return got

## The recipe's parts as drawn with object colour `light`: each overridden
## object material (CharacterLight.set_on's rule) marked `lit_on`, so it takes
## the body's level from its texel (round 759: before, each level swapped in
## its own material copy, a twin and a group per level); with `light` < 0 the
## materials as they are. Once per recipe and the two cases, the twins left
## to each add (F2). Empty when a material has no twin (twin_shader: the body
## is dressed instead).
##
## Bounded (round 756's review, F5): a recipe keeps its last
## LIT_LEVELS_PER_RECIPE entries and the whole cache is dropped past
## LIT_CACHE_CAP entries.
func _lit_parts(recipe: CharacterAppearance.FarRecipe, l: Layout, light: float) -> Array:
	var key := "%s|%d" % [recipe.key, 1 if light >= 0.0 else 0]
	var got = _recipe_lit.get(key)
	if got != null:
		return got
	var out: Array = []
	for g in (_recipe_geo[recipe.key] as Array)[1]:
		var p: Dictionary = g[0]
		var mat: Material = g[1]
		if twin_shader((mat as ShaderMaterial).shader) == null:
			return []
		out.append({"mesh": p["mesh"], "layers": p["layers"], "sort": p["sort"], "vol": p["vol"], "centre": p["centre"], "lit": mat,
			"tk": "%d|%s" % [mat.get_instance_id(), l.key],
			"lit_on": light >= 0.0 and bool(g[2]) and ObjectLight.is_object_material(mat)})
	if _recipe_lit.size() >= LIT_CACHE_CAP:
		_recipe_lit.clear()
		_recipe_lit_order.clear()
	var order: Array = _recipe_lit_order.get(recipe.key, [])
	order.append(key)
	while order.size() > LIT_LEVELS_PER_RECIPE:
		_recipe_lit.erase(order.pop_front())
	_recipe_lit_order[recipe.key] = order
	_recipe_lit[key] = out
	return out

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
	if b != null and (b.fade == FADE_OUT or (b.fade == FADE_IN and is_inf(b.fade_start))):
		# Round 762: a departing body's weapon shows no particles (EquipFx
		# finds it out of reach: its fade-out is drawn here, not on its
		# nodes), nor a body whose page is still held.
		return Vector3(INF, INF, INF)
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
		var ghost := (_bodies[skel] as Body).ghost
		var e := remove(skel, false)
		if not e.is_empty() and not ghost:
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
	_step_fades(idle_time)
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
		if not is_instance_valid(b.node) or (not b.ghost and not is_instance_valid(b.skel)):
			remove(_keys[_ring])
			continue
		_update_transform(b)
	# Round 762: within what the frame's crowd budget leaves (OtherCrowd.
	# FrameBudget), BAKE_MIN_USEC at least, so a crowd arriving with new
	# clips does not add 16 ms of baking to frames it already fills.
	var bt := Time.get_ticks_usec()
	bake_step(clampi(OtherCrowd.FrameBudget.left(), BAKE_MIN_USEC, GHOST_BAKE_BUDGET_USEC if _ghost_waits_bake else BAKE_BUDGET_USEC))
	# Round 762: the rigid pieces a ghost's recipe waits for, in the same share.
	step_rigid_jobs(clampi(OtherCrowd.FrameBudget.left(), BAKE_MIN_USEC, BAKE_BUDGET_USEC))
	var bu := Time.get_ticks_usec()
	OtherCrowd.FrameBudget.spend(bu - bt)
	_ghost_waits_bake = false
	_upload(_ghost_waits_upload)
	_ghost_waits_upload = false
	if FrameSplit.on:
		# QA (round 762): the flush's baking and its uploads and pushes.
		FrameSplit.add("gf_bake", bu - bt)
		FrameSplit.add("gf_upload", Time.get_ticks_usec() - bu)

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
	var old_epoch := _epoch
	_epoch = idle_time
	for skel in _bodies:
		_write_clip(_bodies[skel], idle_time)
	# A fading body's start is ms since the epoch (its texel, round 762), and
	# so is a revealed slot's clock.
	var shift := (idle_time - old_epoch) * 1000.0
	for c in _cohorts:
		for b in (c as FadeCohort).bodies:
			if (b as Body).cohort == c:
				_write_fade(b)
	for k in range(HOLD_SLOTS):
		if _reveal[k] < REVEAL_HELD:
			_reveal[k] -= shift
	_send_reveal()

func _upload(force: bool = false) -> void:
	var u0 := Time.get_ticks_usec() if FrameSplit.on else 0
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
			if not l.uploading.is_empty():
				clip_generation += 1
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
	var u1 := Time.get_ticks_usec() if FrameSplit.on else 0
	_push_groups()
	if FrameSplit.on:
		# QA (round 762): the textures' uploads, and the groups' pushes.
		FrameSplit.add("gu_tex", u1 - u0)
		FrameSplit.add("gu_push", Time.get_ticks_usec() - u1)
	stats["far"] = _bodies.size()
	stats["groups"] = _groups.size()

## Every group whose instances changed, to the server.
func _push_groups() -> void:
	if _aabb_dirty:
		_aabb_dirty = false
		stats["aabb_pushes"] = int(stats.get("aabb_pushes", 0)) + 1
		# Round 762: the groups take the new bounds AABB_PUSH_GROUPS a frame,
		# not all in one: each is a culling-tree update on the render thread
		# (RendererSceneCull::update_dirty_instances), and a push to some
		# 2,000 groups and their fade instances was a 50-60 ms scene setup on
		# the render thread (MEASURED r762.md, rs_setup), which the next
		# frame's sync waits for (post_flush). A group still on the old bounds
		# keeps them a few frames: a shrink is safe (larger bounds never cull
		# wrongly); a growth can leave a part at the new edge culled with its
		# group for those frames, when the camera sees the new edge but not
		# the old box (OURS, disclosed).
		_aabb_push = _groups.values()
		_aabb_push_at = 0
	if _aabb_push_at < _aabb_push.size():
		var end := mini(_aabb_push_at + AABB_PUSH_GROUPS, _aabb_push.size())
		for i in range(_aabb_push_at, end):
			var g: Group = _aabb_push[i]
			if not g.inst.is_valid():
				continue
			RenderingServer.instance_set_custom_aabb(g.inst, _aabb)
			if g.fade_inst.is_valid():
				RenderingServer.instance_set_custom_aabb(g.fade_inst, _aabb)
		_aabb_push_at = end
		if _aabb_push_at >= _aabb_push.size():
			_aabb_push = []
			_aabb_push_at = 0
	# Round 759: the groups marked dirty, not a pass over every group a frame
	# (6,703 live, MEASURED: part of `g_flush`'s 5.9 ms).
	for g in _dirty_groups:
		(g as Group).dirty = false
		RenderingServer.multimesh_set_buffer((g as Group).mm, (g as Group).buf)
		RenderingServer.multimesh_set_visible_instances((g as Group).mm, (g as Group).count)
	_dirty_groups.clear()
	# Round 762: each group's two instances shown as its bodies fade -- the
	# opaque one while a body in it does not fade, the fade one while a body
	# in it fades and is not in a held page.
	for g in _vis_dirty:
		_show_group(g as Group)
	_vis_dirty.clear()
	stats["instances"] = _instances

func _show_group(g: Group) -> void:
	var held := 0
	for k in g.held:
		if hold_pending(int(k)):
			held += int(g.held[k])
	var want_f := g.n_fade - held > 0
	# Made while its page is still held, not when it is revealed: a cold
	# crowd's reveal would otherwise make every group's fade twin in one frame.
	if g.n_fade > 0 and not g.fade_inst.is_valid() and not g.fade_tried:
		_make_fade_inst(g)
	var want_o := g.count > g.n_fade or g.fade_mat == null and g.fade_tried
	# Round 762: shown and hidden by the layer mask, not instance_set_visible:
	# a visibility change takes the instance out of the scenario's culling
	# tree and puts it back on the render thread (READ, Godot 4.7.2
	# RendererSceneCull::instance_set_visible -> _unpair_instance /
	# _instance_queue_update with its AABB), and a page's reveal showed some
	# 2,000 fade instances at once: a 62-65 ms render-thread frame (MEASURED
	# r762.md, post_flush). The mask is a field the cull tests (LAYER_CHECK);
	# Forward+ pairs geometry with VoxelGI only (geometry_instance_get_pair_mask),
	# so a mask change unpairs nothing.
	if want_o != g.shown_o:
		g.shown_o = want_o
		RenderingServer.instance_set_layer_mask(g.inst, g.layers if want_o else 0)
	want_f = want_f and g.fade_inst.is_valid()
	if want_f != g.shown_f:
		g.shown_f = want_f
		RenderingServer.instance_set_layer_mask(g.fade_inst, g.layers if want_f else 0)

## Round 762: the group's fade instance -- its MultiMesh drawn with the fade
## twin of its material (AppearFade.fade_twin: a glowing weapon fades on its
## plain material, READ round 734) -- made the first time a body in it fades.
## None when the material has no fade twin: its twin then draws its fading
## bodies opaque (`crowd_fades` false), as AppearFade leaves such a mesh.
func _make_fade_inst(g: Group) -> void:
	g.fade_tried = true
	var fsrc: Material = _fade_src(g.src) if g.src != null else null
	var ft: ShaderMaterial = null
	if fsrc is ShaderMaterial and g.layout != null:
		ft = _live_twin(fsrc, "%d|%s" % [fsrc.get_instance_id(), g.layout.key], g.layout)
	if ft == null:
		g.material.set_shader_parameter("crowd_fades", false)
		_vis_dirty[g] = true
		return
	g.fade_mat = ft
	_twin_users[ft] = int(_twin_users.get(ft, 0)) + 1
	g.fade_inst = RenderingServer.instance_create2(g.mm, scenario)
	RenderingServer.instance_geometry_set_material_override(g.fade_inst, ft.get_rid())
	RenderingServer.instance_geometry_set_cast_shadows_setting(g.fade_inst, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	# Hidden by its mask (0) until a body in it fades unheld (_show_group).
	RenderingServer.instance_set_layer_mask(g.fade_inst, 0)
	RenderingServer.instance_set_pivot_data(g.fade_inst, g.sort, true)
	if _aabb_set:
		RenderingServer.instance_set_custom_aabb(g.fade_inst, _aabb)
	g.shown_f = false

## The bounds every far instance is culled by (one for all: a MultiMesh is
## drawn or not as a whole). Grown as bodies arrive and move, re-measured by
## reset_aabb (World3D, once a cycle).
func _grow_aabb(at: Vector3) -> void:
	var box := AABB(at - Vector3(12.0, 2.0, 12.0), Vector3(24.0, 26.0, 24.0))
	if _aabb_set and _aabb.encloses(box):
		return
	_aabb = box if not _aabb_set else _aabb.merge(box)
	# Grown with a margin, so a walking crowd does not reset every group often.
	_aabb = snap_box(_aabb.grow(16.0))
	_aabb_set = true
	# Sent to the groups with their instances (_push_groups), once however
	# many bodies grew it (round 756: a page of ghosts, nearest first, grew it
	# body by body, a call per group each time).
	_aabb_dirty = true

var _aabb_dirty := false
## Round 762: the groups still to take the current bounds, and how many a frame.
var _aabb_push: Array = []
var _aabb_push_at := 0
const AABB_PUSH_GROUPS := 128

## Round 759: the bounds snapped outward to AABB_SNAP units, so a crowd that
## grows the box by a body's width does not move it (OURS). Every change is a
## custom AABB on every group, each a DynamicBVH update in the next draw's
## scene update: MEASURED (the live arrival, before, a symbolized build's main
## thread sampled) 14.9 % of the main thread in DynamicBVH::update under
## RendererSceneCull::update_dirty_instances, `rs_setup` 25-65 ms a frame.
const AABB_SNAP := 64.0
static func snap_box(b: AABB) -> AABB:
	var lo := (b.position / AABB_SNAP).floor() * AABB_SNAP
	var hi := (b.end / AABB_SNAP).ceil() * AABB_SNAP
	return AABB(lo, hi - lo)

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
	var box := snap_box(AABB(lo - Vector3(12.0, 2.0, 12.0), hi - lo + Vector3(24.0, 26.0, 24.0)).grow(16.0))
	if _aabb_set and _aabb.encloses(box) and _aabb.get_volume() < box.get_volume() * 4.0:
		return
	_aabb = box
	_aabb_set = true
	# With the instances (_push_groups), as a grown box is (round 756).
	_aabb_dirty = true

# --- the body texture --------------------------------------------------------------

func _take_slot() -> int:
	if not _free_slots.is_empty():
		return _free_slots.pop_back()
	var s := _slots
	_slots += 1
	if _slots > _slot_cap:
		# Round 762: 4,096 at first (320 KB), doubled past it: each growth is a
		# new texture bound to every twin (a material update each, on the
		# render thread), and a crowd of thousands arriving grew it 256 ->
		# 4,096 in four steps. Tests ask for a smaller first size.
		_slot_cap = maxi(first_slot_cap, _slot_cap * 2)
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

## Round 759: the body's object colour, texel 4 (x). A part drawn with a
## character's object material takes it in the vertex shader instead of the
## material's own `object_color` (its instances' INSTANCE_CUSTOM.y carries
## the lit bit, pack_y), so every light level of a material is ONE twin and one group
## per mesh: before, each level was its own material copy (ObjectLight.
## with_object_color), so its own twin and group -- a MultiMesh and its draws
## per (mesh, level). MEASURED live (round 759): 6,587 groups for 1,678 meshes.
func _write_light(b: Body) -> void:
	var o := b.slot * FLOATS_PER_BODY + 16
	if _body_data[o] == b.objc:
		return
	_body_data[o] = b.objc
	_body_dirty = true

## Round 759: INSTANCE_CUSTOM.y packs three integers, exactly in a float
## (below 2^24): ((glow row + 1) x VOL_SPAN + (Volume row + 1)) x 2 + lit --
## the part's Volume row (-1 none, as before), whether it takes the body's
## object colour (_write_light), and its glow row in the glow table (-1 none;
## _glow_row). crowd_gpu_vertex.gdshaderinc unpacks it.
const VOL_SPAN := 512

static func pack_y(vol: int, lit: bool, glow: int) -> float:
	return float(((glow + 1) * VOL_SPAN + (vol + 1)) * 2 + (1 if lit else 0))

## Round 760 (round 759's review, F2): GL Compatibility keeps a MultiMesh's
## custom data (and colour) as HALF floats (READ, 4.2.2 and 4.7.2-stable:
## drivers/gles3/storage/mesh_storage.cpp `make_half_float` on the buffer,
## scene.glsl `unpackHalf2x16(instance_color_custom_data...)`). A half holds
## every integer only up to 2048, so the body's slot was wrong above 2,048 far
## bodies there, and a glow row (1024 x (row + 1) in y) above 62 overflowed.
## So under Compatibility the slot and the glow row ride in the instance
## transform's origin, which GLES3 keeps as full floats (`instance_xform0..2`,
## highp vec4): x the slot, y the glow row + 1, z 0. The basis stays the
## identity, and crowd_gpu_vertex.gdshaderinc takes the origin back off VERTEX
## (`CURRENT_RENDERER == RENDERER_COMPATIBILITY`), so the drawn place is the
## same; INSTANCE_CUSTOM.y keeps the Volume row and the lit bit (at most 1024,
## exact). Forward+ keeps everything in INSTANCE_CUSTOM (32-bit floats), as
## before. `half_custom_override` (tests): -1 asks the renderer.
static var half_custom_override := -1

static func half_custom() -> bool:
	if half_custom_override >= 0:
		return half_custom_override == 1
	# A call by name: get_current_rendering_method is 4.3+, and the script
	# still parses on 4.2.2 (which has no CURRENT_RENDERER for the shader either).
	return RenderingServer.has_method("get_current_rendering_method") and str(RenderingServer.call("get_current_rendering_method")) == "gl_compatibility"

## The integers a part's instance carries, as the four floats that differ
## from Forward+'s layout: [origin x, origin y, custom x, custom y].
static func instance_ints(slot: int, vol: int, lit: bool, glow: int, half: bool) -> PackedFloat32Array:
	if half:
		return PackedFloat32Array([float(slot), float(glow + 1), 0.0, pack_y(vol, lit, -1)])
	return PackedFloat32Array([0.0, 0.0, float(slot), pack_y(vol, lit, glow)])

## [slot, Volume row, lit, glow row] of an instance's 16 floats at `o`.
static func instance_read(buf: PackedFloat32Array, o: int) -> Array:
	var y: Array = unpack_y(buf[o + 13])
	if buf[o + 3] != 0.0 or buf[o + 7] != 0.0:
		return [int(buf[o + 3] + 0.5), y[0], y[1], int(buf[o + 7] + 0.5) - 1]
	return [int(buf[o + 12] + 0.5), y[0], y[1], y[2]]

## [Volume row, lit, glow row] of a packed INSTANCE_CUSTOM.y.
static func unpack_y(y: float) -> Array:
	var v := int(y + 0.5)
	return [((v >> 1) % VOL_SPAN) - 1, (v & 1) == 1, (v >> 1) / VOL_SPAN - 1]

## The object colour of `parts`' lit ones (the first: CharacterLight sets one
## level on every lit mesh of a body), or -1 when none is lit.
static func _parts_objc(parts: Array) -> float:
	for p in parts:
		if (p as Dictionary).get("objc", -1.0) >= 0.0:
			return float(p["objc"])
	return -1.0

## What the shader computes for `b` at `idle_time`: the baked frame's index
## in its clip (tests: held to CrowdAnim.frame_index).
func frame_of(skel: Object, idle_time: float) -> int:
	var b: Body = _bodies.get(skel) if skel != null else null
	if b == null:
		return -1
	var o := b.slot * FLOATS_PER_BODY + 12
	var clock := float(idle_time - _epoch) * 1000.0
	var ms := fposmod(clock + _body_data[o + 3], maxf(_body_data[o + 2], 1.0))
	return int(ms / CrowdAnim.QUANTUM_MS + 0.5) % maxi(int(_body_data[o + 1]), 1)

# --- layouts and baking -----------------------------------------------------------

func _layout_for(skel: Skeleton3D, key_in: String = "") -> Layout:
	var key := key_in if key_in != "" else String(skel.get_meta(MonsterCrowd.META_LAYOUT, ""))
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
	# (skeleton_3d.cpp:575, READ), so its globals are composed here, once
	# (through refresh_global_poses since round 754: under Godot 4.4+ a bare
	# force_update_all_bone_transforms() out of the tree recomposed nothing,
	# and every baked frame was the first one).
	Skeleton3DBuilder.refresh_global_poses(sk)
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
		var target: Node = mi.get_node_or_null(mi.skeleton) if mi.skin != null else null
		var att: BoneAttachment3D = null
		var chain := Transform3D.IDENTITY
		if target != skel:
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
		var mat := mi.get_active_material(0)
		var p = _part_for(mi, mat, mi.skin, target == skel,
			target == skel and _identity_under(mi, skel), att.bone_name if att != null else "", chain, l, true, lit_by_body(mi, mat))
		if p == null:
			return null
		out.append(p)
	return out

## One drawn mesh as a part (round 756: split out of _parts_of, so a body
## that is not built -- CharacterAppearance.far_recipe's pieces -- is read by
## the same rules): `mat_in` is what it draws with, `skin` its skin, `to_body`
## whether it is skinned to the body skeleton (then `identity`: every node
## from it up to the skeleton sits at the identity), else `bone_name` is the
## body bone its BoneAttachment3D hangs from and `chain` the transforms from
## the mesh up to that attachment. Null (counted in `refusals`) when it cannot
## be drawn here.
func _part_for(mi: MeshInstance3D, mat_in: Material, skin: Skin, to_body: bool, identity: bool, bone_name: String,
		chain: Transform3D, l: Layout, with_twin: bool = true, lit: bool = false):
	if mi.mesh.get_surface_count() != 1 or mi.transparency > 0.0:
		_refuse("surfaces")
		return null
	var mat := mat_in as ShaderMaterial
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
	var p := {"layers": mi.layers, "sort": mi.sorting_offset, "mi": mi}
	if to_body:
		var base := CharacterAppearance.canonical_base(skin)
		if base == null or not identity:
			_refuse("skin")
			return null
		p["mesh"] = mi.mesh
		p["vol"] = _volume_row(l, skin, base)
		p["centre"] = mi.mesh.get_aabb().get_center().y
	else:
		var bone := l.scratch.find_bone(bone_name) if bone_name != "" else -1
		if bone < 0:
			_refuse("hung")
			return null
		var made: ArrayMesh = null
		if _recipe_sliced:
			rigid_pending = false
			made = rigid_mesh_sliced(mi, l.key, bone, l.rests[bone] * chain)
			if made == null and rigid_pending:
				return RECIPE_PENDING
		else:
			made = rigid_mesh(mi, l.key, bone, l.rests[bone] * chain)
		if made == null:
			_refuse("rigid")
			return null
		p["mesh"] = made
		p["vol"] = -1
		p["centre"] = (l.rests[bone] * chain * mi.mesh.get_aabb().get_center()).y
	# Round 756: a recipe's parts make their twin only for the material they
	# are drawn with (_lit_parts: often a light level's copy, not this one).
	if not with_twin:
		if twin_shader(mat.shader) == null:
			_refuse("shader")
			return null
		return p
	# Round 759: a lit part draws with its level copy's base, and the level
	# goes in the body's texel (_write_light): one twin for every level.
	if lit:
		p["objc"] = ObjectLight.object_color_of(mat)
		mat = ObjectLight.base_of(mat) as ShaderMaterial
	# Round 762: the material its twin is of (the group's fade twin's source).
	p["src"] = mat
	if EquipGlow.is_glow(mat):
		# Round 759: every glow row of the item on one twin, the row per
		# instance (_glow_twin, _glow_row).
		var gt := _glow_twin(mat, l)
		p["material"] = gt[0]
		p["twin_key"] = gt[1]
		p["glow"] = _glow_row(mat)
	else:
		p["material"] = _twin(mat, l)
		p["twin_key"] = "%d|%s" % [mat.get_instance_id(), l.key]
	if p["material"] == null:
		_refuse("shader")
		return null
	return p

## Round 759: whether `mat`, drawn by `mi`, is one CharacterLight puts a
## body's level on (CharacterLight.set_on's rule: an object material as the
## mesh's material_override or its surface override), so its far part takes
## the body's object colour.
static func lit_by_body(mi: MeshInstance3D, mat: Material) -> bool:
	if mat == null or not ObjectLight.is_object_material(mat):
		return false
	if mi.material_override == mat:
		return true
	return mi.get_surface_override_material_count() > 0 and mi.get_surface_override_material(0) == mat

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
	var rt := Time.get_ticks_usec() if FrameSplit.on else 0
	var job = _rigid_jobs.get(key)
	_rigid_jobs.erase(key)
	if job == null:
		job = _rigid_job_start(mi, bone, to_bone)
	var am: ArrayMesh = null
	if not (job as Dictionary).is_empty():
		_rigid_job_step(job, 1 << 40)
		am = _rigid_job_finish(job)
	if FrameSplit.on:
		# QA (round 762): the per-vertex loop's cost (a Rust candidate, r762.md).
		FrameSplit.add("g_rigid", Time.get_ticks_usec() - rt)
		FrameSplit.add("g_rigid_calls", 1)
	if am != null:
		_rigid[key] = am
	return am

## Round 762 (OURS): rigid_mesh for a ghost's recipe -- the mesh when it is
## made, else null, its vertices worked on a share at a time by
## step_rigid_jobs (the frame's crowd budget) and RIGID_PENDING set: a swarm
## shield's or weapon's loop was a 16.5 ms frame on its own (MEASURED
## r762.md, `g_rigid`). The same code as rigid_mesh, in slices.
var rigid_pending := false
const RIGID_SLICE_MIN := 1500
var _rigid_jobs := {}   # key -> the job (_rigid_job_start)

func rigid_mesh_sliced(mi: MeshInstance3D, layout_key: String, bone: int, to_bone: Transform3D) -> ArrayMesh:
	var key := "%d|%s|%d" % [mi.mesh.get_instance_id(), layout_key, bone]
	if _rigid.has(key):
		return _rigid[key]
	var job = _rigid_jobs.get(key)
	if job == null:
		job = _rigid_job_start(mi, bone, to_bone)
		if (job as Dictionary).is_empty():
			return null
		# A small piece (most: about 1-2 us a vertex) is made at once.
		if int(job["n"]) <= RIGID_SLICE_MIN:
			_rigid_job_step(job, 1 << 40)
			var small := _rigid_job_finish(job)
			if small != null:
				_rigid[key] = small
			return small
		_rigid_jobs[key] = job
	if int(job["k"]) >= int(job["n"]):
		_rigid_jobs.erase(key)
		var am := _rigid_job_finish(job)
		if am != null:
			_rigid[key] = am
		return am
	rigid_pending = true
	return null

## The jobs' vertices for up to `budget_usec` (one job's slice at least).
func step_rigid_jobs(budget_usec: int) -> void:
	if _rigid_jobs.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	for key in _rigid_jobs:
		var job: Dictionary = _rigid_jobs[key]
		if int(job["k"]) >= int(job["n"]):
			continue
		var left := budget_usec - (Time.get_ticks_usec() - t0)
		_rigid_job_step(job, maxi(left, 1))
		if int(job["k"]) >= int(job["n"]):
			# A ghost waiting on it (World3D: as on a clip) is looked at again.
			clip_generation += 1
		if Time.get_ticks_usec() - t0 >= budget_usec:
			break
	if FrameSplit.on:
		FrameSplit.add("g_rigid", Time.get_ticks_usec() - t0)

## What a rigid mesh is made from: the kept arrays, the skin's bind matrices
## (read here, on the main thread: the item skeleton's poses), the outputs.
## Empty when it cannot be made.
func _rigid_job_start(mi: MeshInstance3D, bone: int, to_bone: Transform3D) -> Dictionary:
	# Round 762: the arrays the mesh was built from, kept on it (BmsReader.
	# to_array_mesh's `keep`), rather than asked of the RenderingServer (a
	# wait for the render thread under the separate render thread).
	# (has_meta first: get_meta with a null default still errors on a miss.)
	var kept = mi.mesh.get_meta(BmsReader.KEPT_ARRAYS_META) if mi.mesh.has_meta(BmsReader.KEPT_ARRAYS_META) else null
	var arrays: Array = (kept as Array).duplicate() if kept is Array else mi.mesh.surface_get_arrays(0)
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
			return {}
		# A template's item skeleton (round 756, a ghost's recipe) is never in a
		# tree, where a pose change marks nothing dirty (skeleton_3d.cpp:575,
		# READ): its globals are composed here (at rest, as a built body's
		# never-posed item skeleton has them).
		if not isk.is_inside_tree():
			isk.force_update_all_bone_transforms()
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
	var prim := (mi.mesh as ArrayMesh).surface_get_primitive_type(0) if mi.mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
	return {"arrays": arrays, "v": v, "nrm": nrm, "xf": xf, "vb": vb, "vw": vw, "per": per, "has_n": has_n,
		"out_v": out_v, "out_n": out_n, "to_bone": to_bone, "bone": bone, "prim": prim, "k": 0, "n": v.size()}

## Vertices from job["k"] on, for up to `budget_usec` (checked every 64).
static func _rigid_job_step(job: Dictionary, budget_usec: int) -> void:
	var t0 := Time.get_ticks_usec()
	var v: PackedVector3Array = job["v"]
	var nrm = job["nrm"]
	var xf: Array[Transform3D] = job["xf"]
	var vb = job["vb"]
	var vw = job["vw"]
	var per: int = job["per"]
	var has_n: bool = job["has_n"]
	var out_v: PackedVector3Array = job["out_v"]
	var out_n: PackedVector3Array = job["out_n"]
	var to_bone: Transform3D = job["to_bone"]
	var k: int = job["k"]
	var n: int = job["n"]
	while k < n:
		if (k & 63) == 0 and k > int(job["k"]) and Time.get_ticks_usec() - t0 >= budget_usec:
			break
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
		k += 1
	# Packed arrays are values: the written copies go back into the job.
	job["out_v"] = out_v
	job["out_n"] = out_n
	job["k"] = k

static func _rigid_job_finish(job: Dictionary) -> ArrayMesh:
	var arrays: Array = job["arrays"]
	var n: int = job["n"]
	arrays[Mesh.ARRAY_VERTEX] = job["out_v"]
	if bool(job["has_n"]):
		arrays[Mesh.ARRAY_NORMAL] = job["out_n"]
	arrays[Mesh.ARRAY_TANGENT] = null
	var bones := PackedInt32Array()
	bones.resize(n * 4)
	var weights := PackedFloat32Array()
	weights.resize(n * 4)
	var bone: int = job["bone"]
	for k in range(n):
		bones[k * 4] = bone
		weights[k * 4] = 1.0
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(int(job["prim"]), arrays)
	return am

# --- groups -------------------------------------------------------------------------

func _add_part(b: Body, p: Dictionary) -> void:
	var mesh: Mesh = p["mesh"]
	var mat: ShaderMaterial = p["material"]
	var key: String = p["gkey"] if p.has("gkey") else "%d|%d|%d|%.4f" % [mesh.get_instance_id(), mat.get_instance_id(), int(p["layers"]), float(p["sort"])]
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
			RenderingServer.instance_set_custom_aabb(g.inst, _aabb)
		g.twin_key = String(p["twin_key"])
		g.src = p.get("src")
		g.layout = b.layout
		g.layers = int(p["layers"])
		g.sort = float(p["sort"])
		_twin_users[mat] = int(_twin_users.get(mat, 0)) + 1
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
	# Round 759's review, F2: a glow part is a hung weapon or shield, never
	# skinned to the body (Volume row -1) nor lit -- what keeps Forward+'s
	# packed y exact for every glow row; held here.
	assert(int(p.get("glow", -1)) < 0 or (int(p["vol"]) < 0 and not p.has("objc")), "CrowdGpu: a glow part with a Volume row or the lit bit")
	var ints := instance_ints(b.slot, int(p["vol"]), p.has("objc"), int(p.get("glow", -1)), half_custom())
	g.buf[o + 3] = ints[0]
	g.buf[o + 7] = ints[1]
	g.buf[o + 12] = ints[2]
	g.buf[o + 13] = ints[3]
	g.buf[o + 14] = float(p["centre"])
	g.buf[o + 15] = 0.0
	var rec := [g, idx, b]
	g.owners.append(rec)
	b.parts.append(rec)
	# Round 762: a fading body's instance is the fade instance's to draw.
	if b.fade != 0:
		g.n_fade += 1
		if b.hold >= 0:
			g.held[b.hold] = int(g.held.get(b.hold, 0)) + 1
			(_slot_groups[b.hold] as Dictionary)[g] = true
		_vis_dirty[g] = true
	elif not g.shown_o:
		_vis_dirty[g] = true
	g.dirty = true
	_dirty_groups[g] = true
	_instances += 1

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
	var ob: Body = rec[2]
	if ob.fade != 0:
		g.n_fade -= 1
		if ob.hold >= 0:
			g.held[ob.hold] = int(g.held.get(ob.hold, 0)) - 1
		_vis_dirty[g] = true
	g.dirty = true
	_dirty_groups[g] = true
	_instances -= 1

# --- materials ----------------------------------------------------------------------

## The far twin of `src` on layout `l`: `src`'s shader with the skin added
## (twin_shader), each of `src`'s parameters set again by name
## (ObjectLight.copy_material's way: round 706's review measured a
## Resource.duplicate() drawing brighter), and the crowd's textures. Its
## TexAni (round 722) animates it with `src`.
func _twin(src: ShaderMaterial, l: Layout, key_in: String = "") -> ShaderMaterial:
	var key := key_in if key_in != "" else "%d|%s" % [src.get_instance_id(), l.key]
	var got: ShaderMaterial = _twins.get(key)
	# Held weakly (F7): a twin whose source died answers for no new material
	# that took its id.
	if got != null and _twin_sources.has(key) and (_twin_sources[key] as WeakRef).get_ref() == src:
		return got
	var tws := Time.get_ticks_usec() if FrameSplit.on else 0
	var sh := twin_shader(src.shader)
	if sh == null:
		return null
	var un0 := Time.get_ticks_usec() if FrameSplit.on else 0
	if FrameSplit.on:
		FrameSplit.add("tw_shader", un0 - tws)
	if not _uniform_names.has(src.shader):
		var names0 := PackedStringArray()
		for u in src.shader.get_shader_uniform_list():
			names0.append(String(u["name"]))
		_uniform_names[src.shader] = names0
		if FrameSplit.on:
			# QA (round 762): a source shader's uniform list, asked of the
			# render server the first time (a wait for its compile).
			FrameSplit.add("ga_uniforms", Time.get_ticks_usec() - un0)
	var twa := Time.get_ticks_usec() if FrameSplit.on else 0
	var t := ShaderMaterial.new()
	t.resource_name = src.resource_name
	var twn := Time.get_ticks_usec() if FrameSplit.on else 0
	t.shader = sh
	if FrameSplit.on:
		FrameSplit.add("tw_new", twn - twa)
		FrameSplit.add("tw_set", Time.get_ticks_usec() - twn)
		if not _tw_seen.has(sh):
			_tw_seen[sh] = true
			FrameSplit.add("tw_first_set_calls", 1)
	t.render_priority = src.render_priority
	var twp := Time.get_ticks_usec() if FrameSplit.on else 0
	if FrameSplit.on:
		FrameSplit.add("tw_assign", twp - twa)
	# The uniform names once per shader (round 756: ghosts make twins in bursts,
	# and the list is built anew on every call).
	var names: PackedStringArray = _uniform_names.get(src.shader, PackedStringArray())
	if names.is_empty():
		for u in src.shader.get_shader_uniform_list():
			names.append(String(u["name"]))
		_uniform_names[src.shader] = names
	for n in names:
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
	if _glow_tex != null:
		t.set_shader_parameter("crowd_glow", _glow_tex)
	var twt := Time.get_ticks_usec() if FrameSplit.on else 0
	TexAni.bind_like(t, src)
	if FrameSplit.on:
		FrameSplit.add("tw_params", twt - twp)
		FrameSplit.add("tw_texani", Time.get_ticks_usec() - twt)
	l.twins[t] = true
	t.set_meta(&"opensro_twin_key", key)
	_twins[key] = t
	_twin_sources[key] = weakref(src)
	return t

# --- glow rows (round 759) ----------------------------------------------------------

## The parameters a glow row sets (EquipGlow.row_params, less alpha_scissor,
## which picks the glow shader's variant and stays the material's): per
## instance far, from the glow table, so an item worn at many pluses is one
## twin and one group per mesh. MEASURED live before (round 759): the glow's
## colours, period and scroll split most of the far groups.
const GLOW_ROW_PARAMS := ["glow_c1", "glow_c2", "glow_period", "glow_mul0", "glow_signed2x", "glow_uv_speed"]
## The glow table: 3 texels a row -- (c1, period), (c2, mul0), (uv speed,
## signed2x, texture slot + 1: 0 is the twin's own glow_texture) -- in
## `crowd_glow` (crowd_gpu.gdshaderinc).
const GLOW_TEXELS := 3
## The option textures a glow row may name per instance, as the glow twins'
## samplers crowd_glow_t0..3 (object.gdshaderinc). MEASURED live: the swarm's
## glows use 4 (three 256 x 256, one 1024 x 1024), so no Texture2DArray (one
## size); a fifth and later stay their twin's own glow_texture, in its key.
const GLOW_TEX_SLOTS := 4
var _glow_texs: Array = []
var _glow_index := {}         # the row's values (their bytes, hex) -> row
var _glow_data := PackedFloat32Array()
var _glow_count := 0
var _glow_tex: ImageTexture = null

static func _v3(v) -> Vector3:
	if v is Color:
		return Vector3((v as Color).r, (v as Color).g, (v as Color).b)
	if v is Vector3:
		return v
	return Vector3.ONE

## `glow`'s row in the glow table (added and uploaded when new: a few dozen
## rows in all, one a (plus, item type) row of the glow tables).
func _glow_row(glow: ShaderMaterial) -> int:
	var c1 := _v3(glow.get_shader_parameter("glow_c1"))
	var c2 := _v3(glow.get_shader_parameter("glow_c2"))
	var pv = glow.get_shader_parameter("glow_period")
	var mv = glow.get_shader_parameter("glow_mul0")
	var sv = glow.get_shader_parameter("glow_signed2x")
	var uvv = glow.get_shader_parameter("glow_uv_speed")
	# The shader's defaults where a row sets none (object.gdshaderinc).
	var period := float(pv) if pv != null else 1.0
	var mul0 := float(mv) if mv != null else 1.0
	var signed2x := float(sv) if sv != null else 0.0
	var uv: Vector2 = uvv if uvv is Vector2 else Vector2.ZERO
	var slot := _glow_tex_slot(glow.get_shader_parameter("glow_texture"))
	var vals := PackedFloat32Array([c1.x, c1.y, c1.z, period, c2.x, c2.y, c2.z, mul0, uv.x, uv.y, signed2x, float(slot + 1)])
	var key := vals.to_byte_array().hex_encode()
	var got = _glow_index.get(key)
	if got != null:
		return int(got)
	var row := _glow_count
	_glow_count += 1
	_glow_index[key] = row
	_glow_data.append_array(vals)
	_upload_glow()
	return row

## The slot (0..GLOW_TEX_SLOTS-1) of the option texture `tex` among the glow
## twins' samplers, taken when new and free (and set on every glow twin); -1
## when `tex` is none or the slots are full (its twin keeps it as its own).
func _glow_tex_slot(tex) -> int:
	if not (tex is Texture2D):
		return -1
	var i := _glow_texs.find(tex)
	if i >= 0 or _glow_texs.size() >= GLOW_TEX_SLOTS:
		return i
	_glow_texs.append(tex)
	i = _glow_texs.size() - 1
	for k in _twins:
		if String(k).begins_with("g|"):
			(_twins[k] as ShaderMaterial).set_shader_parameter("crowd_glow_t%d" % i, tex)
	return i

## The glow table to the GPU, on the twins when it is re-made (taller).
func _upload_glow() -> void:
	var h := 16
	while h < _glow_count:
		h *= 2
	var data := _glow_data.duplicate()
	data.resize(h * GLOW_TEXELS * 4)
	var img := Image.create_from_data(GLOW_TEXELS, h, false, Image.FORMAT_RGBAF, data.to_byte_array())
	if _glow_tex == null or _glow_tex.get_height() != h:
		_glow_tex = ImageTexture.create_from_image(img)
		for k in _twins:
			(_twins[k] as ShaderMaterial).set_shader_parameter("crowd_glow", _glow_tex)
	else:
		_glow_tex.update(img)

## The one twin of every glow material of an item on layout `l`: keyed by the
## glow material's shader and every parameter but the row's (GLOW_ROW_PARAMS:
## per instance), and made from the first such material seen (the others
## differ only in those). [twin, its key]; [null, ""] when it has none.
func _glow_twin(glow: ShaderMaterial, l: Layout) -> Array:
	var names: PackedStringArray = _uniform_names.get(glow.shader, PackedStringArray())
	if names.is_empty():
		for u in glow.shader.get_shader_uniform_list():
			names.append(String(u["name"]))
		_uniform_names[glow.shader] = names
	var sig := PackedStringArray([str(glow.shader.get_instance_id()), str(glow.render_priority)])
	# The option texture leaves the key when it has a slot (per instance).
	var slotted := _glow_tex_slot(glow.get_shader_parameter("glow_texture")) >= 0
	for n in names:
		if n in GLOW_ROW_PARAMS or n.begins_with("crowd_") or (slotted and n == "glow_texture"):
			continue
		var v = glow.get_shader_parameter(n)
		sig.append(str(v.get_instance_id()) if v is Object else str(v))
	var tk := "g|%s|%s" % ["|".join(sig).md5_text(), l.key]
	var got: ShaderMaterial = _twins.get(tk)
	if got != null:
		var src = _twin_sources.get(tk)
		var held = (src as WeakRef).get_ref() if src != null else null
		# A twin made from a glow material that is gone answers too: its
		# signature's textures are held by the twin itself.
		if held == null or (held is ShaderMaterial and (held as ShaderMaterial).shader == glow.shader):
			return [got, tk]
	var t := _twin(glow, l, tk)
	if t != null:
		for i in range(_glow_texs.size()):
			t.set_shader_parameter("crowd_glow_t%d" % i, _glow_texs[i])
	return [t, tk]

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
var _uniform_names := {}   # Shader -> its uniforms' names

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
	if FrameSplit.on:
		# QA (round 762): which shaders' twins are made, and when.
		print("QA TWIN shader made for %s (%d chars) at %d ms, %d made, prewarm %s" % [src.resource_path if src.resource_path != "" else "shader %d" % src.get_instance_id(),
			src.code.length(), Time.get_ticks_msec(), _twin_shaders.size() + 1, "seen" if _prewarmed.has(src) else "not seen"])
	var sh := Shader.new()
	sh.code = code
	_twin_shaders[src] = sh
	return sh

## Round 762 (OURS): the twin shaders (and the fade twins' sources and their
## twin shaders) of every material under `node` (a template just adopted),
## made now: a shader's code is compiled on the render thread when it is set,
## and the first ghost to draw a new one waited for that compile in its frame
## (MEASURED r762.md: a 33 ms g_add and a 27 ms flush for a page's first
## ghost). Seen shaders are skipped.
func prewarm_node(node: Node) -> void:
	if node == null:
		return
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if mi.material_override != null:
			_prewarm_material(mi.material_override)
		for si in range(mi.mesh.get_surface_count()):
			var m: Material = mi.get_surface_override_material(si)
			if m == null:
				m = mi.mesh.surface_get_material(si)
			_prewarm_material(m)

## Round 762 (OURS): the twins (and fade twins) of the shaders a character's
## materials are drawn with -- the object shaders, the glow shaders, the MTRL
## mod shaders made so far -- made on the render server now (the world's
## load), not in the first ghost's frame: MEASURED r762.md, a page's first
## ghost made ten twin shaders (`QA TWIN`) and its frame took 66-71 ms, of it
## 54 ms assigning them (RenderingServerDefault.shader_create_from_code
## compiles on the calling thread under the RenderingDevice, READ 4.7.2).
func prewarm_known() -> void:
	var shaders: Array = [ObjectLoader.OBJECT_SHADER, ObjectLoader.FOLIAGE_SHADER, ObjectLoader.FOLIAGE_SHADER_ONE_SIDED]
	for cull in ["back", "disabled"]:
		for alpha_test in [false, true]:
			shaders.append(EquipGlow.glow_shader(cull, alpha_test))
	for sh in ObjectLoader.mod_shaders_made():
		shaders.append(sh)
	for sh in shaders:
		_prewarm_shader(sh as Shader)

func _prewarm_shader(sh: Shader) -> void:
	if sh == null or _prewarmed.has(sh):
		return
	_prewarmed[sh] = true
	_prewarm_rid(twin_shader(sh))
	var fade := ObjectLoader.appear_fade_shader(sh)
	if fade != null and not _prewarmed.has(fade):
		_prewarmed[fade] = true
		_prewarm_rid(twin_shader(fade))
	stats["prewarmed_shaders"] = _prewarmed.size()

func _prewarm_material(m: Material) -> void:
	var sm := m as ShaderMaterial
	if sm == null or sm.shader == null or _prewarmed.has(sm.shader):
		return
	_prewarm_shader(sm.shader)
	# A glow material fades on its plain material (AppearFade._make_twin).
	var f := _fade_src(sm) as ShaderMaterial
	if f != null and f.shader != null and not _prewarmed.has(f.shader):
		_prewarmed[f.shader] = true
		_prewarm_rid(twin_shader(f.shader))

## The shader made on the render server now (Shader.get_rid creates it from the
## preprocessed code on first use): the first ghost's twin assignment waited
## for it (MEASURED r762.md: `tw_assign` 55 ms for a page's first ghost, 8 ms
## a new kind after).
static func _prewarm_rid(sh: Shader) -> void:
	if sh != null:
		sh.get_rid()

var _prewarmed := {}
var _tw_seen := {}

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
	# Round 756: a mod shader's fade twin takes its alpha per instance (a
	# ghost's fade, srr_cg_fade) instead of from its uniform.
	if out.contains("uniform float appear_alpha = 1.0;"):
		out = out.replace("uniform float appear_alpha = 1.0;", "varying float appear_alpha;\n#define SRR_CG_FADE")
	if out.contains("object.gdshaderinc"):
		return out
	# Round 759: a mod shader's oD0 (ObjectLight.OD0_LINE in its own vertex())
	# takes the body's object colour too (srr_cg_objc), as object.gdshaderinc's.
	if out.contains(ObjectLight.OD0_LINE):
		out = out.replace(ObjectLight.OD0_LINE, ObjectLight.OD0_LINE.replace("object_color,", "srr_cg_objc >= 0.0 ? vec3(srr_cg_objc) : object_color,"))
	if out.contains("void vertex() {"):
		return out.replace("void vertex() {", "void vertex() {\n#include \"%s\"\n" % VERTEX_INCLUDE)
	return out + "\nvoid vertex() {\n#include \"%s\"\n}\n" % VERTEX_INCLUDE

## Once a cycle (World3D._crowd_choose): a group empty for GROUP_EMPTY_CYCLES
## cycles goes -- its instance and MultiMesh freed -- and a twin no group
## uses any more with it (round 747's review, F7: a walking crowd's light
## levels made groups and twins without end, and the twins held every level
## copy ObjectLight keeps only weakly). Returns the groups freed.
##
## Round 759: at most COLLECT_MAX a call; the rest wait for the next cycles.
## MEASURED (the swarm lineup at 7,000, before): an arrival leaves thousands of
## groups empty at once (ghosts dressed, light levels left behind), and their
## collection over a few cycles made frames of 400-723 ms (13,468 -> 7,762
## groups), the twins' Array erase a search through thousands each time.
const COLLECT_MAX := 128
func collect() -> int:
	var freed := 0
	for key in _groups.keys():
		var g: Group = _groups[key]
		if g.count > 0:
			g.empty_cycles = 0
			continue
		g.empty_cycles += 1
		if g.empty_cycles < GROUP_EMPTY_CYCLES or freed >= COLLECT_MAX:
			continue
		RenderingServer.free_rid(g.inst)
		g.inst = RID()
		if g.fade_inst.is_valid():
			RenderingServer.free_rid(g.fade_inst)
			g.fade_inst = RID()
		RenderingServer.free_rid(g.mm)
		_groups.erase(key)
		_dirty_groups.erase(g)
		_vis_dirty.erase(g)
		freed += 1
		if g.fade_mat != null:
			_drop_twin_user(g.fade_mat)
			g.fade_mat = null
		_drop_twin_user(g.material)
	stats["groups_freed"] = int(stats.get("groups_freed", 0)) + freed
	return freed

## A group drawing with twin `t` is gone: the twin goes when no group uses it.
## Counted by the twin itself, not its key (round 756's review, F2): a twin
## re-made for the same material has the same key, and a stale group's
## collection must not take the live one's count.
func _drop_twin_user(t: ShaderMaterial) -> void:
	var users := int(_twin_users.get(t, 0)) - 1
	if users > 0:
		_twin_users[t] = users
		return
	_twin_users.erase(t)
	for key in _twin_keys_of(t):
		_twins.erase(key)
		_twin_sources.erase(key)
	for k in _layouts:
		(_layouts[k] as Layout).twins.erase(t)

## The keys `t` is filed under in _twins (one; read back by its key meta).
func _twin_keys_of(t: ShaderMaterial) -> Array:
	var key := String(t.get_meta(&"opensro_twin_key", ""))
	return [key] if key != "" and _twins.get(key) == t else []

## Round 759 (QA): what the far groups are made of -- the groups drawing at
## least one instance (`live`, each one MultiMesh and its draws), the distinct
## meshes, twin materials and shaders among them, and how thin they are (the
## groups of 1 and of at most 3 instances, the most in one).
func batch_census() -> Dictionary:
	var live := 0
	var inst := 0
	var ones := 0
	var threes := 0
	var most := 0
	var meshes := {}
	var mats := {}
	var shaders := {}
	for key in _groups:
		var g: Group = _groups[key]
		if g.count <= 0:
			continue
		live += 1
		inst += g.count
		if g.count == 1:
			ones += 1
		if g.count <= 3:
			threes += 1
		most = maxi(most, g.count)
		meshes[g.mesh] = true
		mats[g.material] = true
		if g.material != null:
			shaders[g.material.shader] = true
	return {"groups": _groups.size(), "live": live, "instances": inst, "meshes": meshes.size(), "materials": mats.size(),
		"shaders": shaders.size(), "ones": ones, "le3": threes, "most": most}

## Round 759 (QA): why one mesh is drawn by several groups -- how many live
## groups there would be if a group were keyed by (mesh, layers, sort) and its
## twin's shader and parameters LESS each set of parameters below, which a
## batch per mesh would then have to carry per instance:
##   now        every parameter (the live groups)
##   no_light   less `object_color` (the light level)
##   no_glow_v  that and the glow's scalars and colours (c1, c2, period, mul0,
##              signed2x, uv_speed)
##   no_glow    that and the glow texture
##   shader     the shader alone (no parameter: textures per instance)
##   mesh       the mesh alone (one shader for every part of it)
const GLOW_SCALARS := ["glow_c1", "glow_c2", "glow_period", "glow_mul0", "glow_signed2x", "glow_uv_speed"]
func split_census() -> String:
	var sets := {"now": [], "no_light": ["object_color"], "no_glow_v": ["object_color"] + GLOW_SCALARS,
		"no_glow": ["object_color", "glow_texture"] + GLOW_SCALARS}
	var keys := {}
	for k in sets:
		keys[k] = {}
	keys["shader"] = {}
	keys["mesh"] = {}
	for key in _groups:
		var g: Group = _groups[key]
		if g.count <= 0 or g.material == null:
			continue
		var head := "%d|%s" % [g.mesh.get_instance_id(), "|".join(g.key.split("|").slice(2))]
		var names: PackedStringArray = _uniform_names.get(g.material.shader, PackedStringArray())
		if names.is_empty():
			for u in g.material.shader.get_shader_uniform_list():
				names.append(String(u["name"]))
		var vals := {}
		for n in names:
			if not n.begins_with("crowd_"):
				vals[n] = g.material.get_shader_parameter(n)
		for k in sets:
			var sig := PackedStringArray([head, str(g.material.shader.get_instance_id())])
			for n in names:
				if vals.has(n) and not (n in sets[k]):
					var v = vals[n]
					sig.append("%s=%s" % [n, str(v.get_instance_id()) if v is Object else str(v)])
			(keys[k] as Dictionary)["|".join(sig)] = true
		(keys["shader"] as Dictionary)["%s|%d" % [head, g.material.shader.get_instance_id()]] = true
		(keys["mesh"] as Dictionary)[head] = true
	var parts := PackedStringArray()
	for k in ["now", "no_light", "no_glow_v", "no_glow", "shader", "mesh"]:
		parts.append("%s=%d" % [k, (keys[k] as Dictionary).size()])
	# The glow textures the live groups draw with, by size and format (a
	# Texture2DArray of them would take the glow texture out of the key).
	var gtex := {}
	for key in _groups:
		var g: Group = _groups[key]
		if g.count > 0 and g.material != null:
			var t = g.material.get_shader_parameter("glow_texture")
			if t is Texture2D:
				gtex[t] = "%dx%d" % [(t as Texture2D).get_width(), (t as Texture2D).get_height()]
	var sizes := {}
	for t in gtex:
		sizes[gtex[t]] = int(sizes.get(gtex[t], 0)) + 1
	return "groups if keyed by: " + " ".join(parts) + " glow_textures=%d by size %s" % [gtex.size(), str(sizes).replace(" ", "")]

## Census for the QA line.
func describe() -> String:
	var rows := 0
	var clips := 0
	for k in _layouts:
		var l: Layout = _layouts[k]
		rows += l.rows
		clips += l.clips.size()
	# Round 757's merge (QA): ghosts whose place the groups' shared bounds do
	# not hold (culled with them while the bounds are in view: S3), and the
	# far sounds the ghosts played (S1).
	var outside := 0
	for g in ghosts():
		if is_instance_valid(g) and _aabb_set and not _aabb.has_point((g as Node3D).global_position + Vector3(0.0, 5.0, 0.0)):
			outside += 1
	return ("ghosts_outside_aabb=%d ghost_sound_advances=%d " % [outside, int(stats.get("ghost_sound_advances", 0))]) + "far=%d ghosts=%d heard=%d groups=%d instances=%d layouts=%d clips=%d rows=%d twins=%d rigid=%d added=%d removed=%d switch_ms=%.0f bake_ms=%.0f upload_ms=%.1f upload_max_ms=%.1f sound_advances=%d groups_freed=%d aabb_pushes=%d refused=%s kept_near=%s" % [
		_bodies.size(), _ghost_count, heard_bodies().size(), _groups.size(), int(stats["instances"]), _layouts.size(), clips, rows, _twins.size(), _rigid.size(),
		int(stats["added"]), int(stats["removed"]), float(stats.get("switch_usec", 0)) / 1000.0, float(stats["bake_usec"]) / 1000.0,
		float(stats.get("upload_usec", 0)) / 1000.0, float(stats.get("upload_max_usec", 0)) / 1000.0,
		int(stats.get("sound_advances", 0)), int(stats.get("groups_freed", 0)), int(stats.get("aabb_pushes", 0)),
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
		var vol: int = unpack_y(g.buf[o + 13])[0]
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
