extends Node
class_name WornItemFx

## Round 794: what a worn item's own `.bsr` plays on a character -- a
## talisman's glow particles, a Europe robe talisman's turning clip, a wing's
## flap, a fullset's shimmer -- READ from sro_client.exe (docs/protocol/
## CLOTH.md, "Worn items", has every address).
##
## - **Particles.** Attaching a part gives it its own FxModManager (vslot_067
##   0xc1fa90 -> CCompChar::FUN_00c32680 -> 0xc80140), and the equipment
##   refresh collects every part's `ambient` set (CCompChar::FUN_00c46ab0,
##   0xc46b26): the item's always-on particles, each on the named bone of the
##   part's OWN skeleton (CRTModParticle::FUN_00c818c0 -> 0xbf0580(part) ->
##   FUN_00c2c820) -- a China talisman's Bone04 and Bone06. The only gate is
##   the particle mod's 0.9 LOD test (0xc43780): EquipFx's 720 units, the
##   own player always. MEASURED: no item entry has the glow or night byte.
##   Here each entry is an EquipFx row on that skeleton (EquipFx.attach), as a
##   weapon's glow particles are; an entry whose bone is missing ends its mod
##   (CRTModParticle vslot_001, AmbientParticles.attach's rule). An entry
##   placed by offset (mode != 0: only the fairy wings' sets) is not drawn
##   here (OPEN).
## - **Clips.** Equipping plays the part's own clip of group `default`, action
##   type 0, at speed 1 (CObjCharacter::FUN_00a5bc20 from 0xa5f611), on the
##   part's own skeleton only (the binder 0xc758f0 matches tracks inside that
##   part). When the body plays stand, walk or run (0, 1, 7: slot 3 0xa5faf0
##   -> 0xa5e100), each part is asked again: a part with a different clip of
##   that type crosses to it over 200 ms (0xc8, [vt+0xb8] / [vt+0xbc]); one
##   with none, or the same, keeps playing. Other actions leave part clips
##   alone. A China talisman has no clip: its skeleton stays at its bind pose.
## - **Shimmer.** The part's TEXANI and MULTITEX mods (a fullset's `_ef`
##   mesh) are bound on its materials as a placed object's
##   (SkinnedBsrAssembler.attach_item_from_archive).

## The action types a part is asked again for (READ 0xa5faf0).
const CLIP_TYPES := [0, 1, 7]
## READ (0xc8): the cross between two clips of a part, in ms.
const BLEND_MS := 200.0
## On a worn item's template node: its AmbientParticles.ambient_entries.
const AMBIENT_META := &"opensro_item_ambient"
## On a worn item's template node and its own skeleton: action type -> clip.
const CLIPS_META := &"opensro_item_clips"
## On the EquipFx marker an item's ambient rows are on.
const MARKER_META := &"opensro_item_ambient_marker"
## On a body skeleton: the clip it plays now (AnimSounds.advance records it).
const BODY_CLIP_META := &"opensro_body_clip"
const GROUP := &"opensro_item_clips"

## Keeps what `attached` (SkinnedBsrAssembler.AttachedItem) carries on its
## template node, so every copy of it has it.
static func note_template(node: Node, attached) -> void:
	if node == null or attached == null:
		return
	if not (attached.ambient as Array).is_empty():
		node.set_meta(AMBIENT_META, attached.ambient)
	if not (attached.clips as Dictionary).is_empty():
		node.set_meta(CLIPS_META, attached.clips)

## The worn item's particles and clips, on `nodes` hung from `body_skel`.
## Returns how many particle rows found their bone. Safe to call again (a
## reglow): an item whose rows are on already is left as it is.
static func apply(nodes: Array, body_skel: Skeleton3D, particles: Pk2Reader, label: String = "") -> int:
	var made := 0
	for node_v in nodes:
		var node := node_v as Node
		if node == null or not is_instance_valid(node):
			continue
		var own := item_skeleton(node)
		if node.has_meta(AMBIENT_META):
			made += _attach_ambient(node, own if own != null else body_skel, particles, label)
		if node.has_meta(CLIPS_META) and own != null:
			own.set_meta(CLIPS_META, node.get_meta(CLIPS_META))
			own.add_to_group(GROUP)
			if own.is_inside_tree():
				driver_for(own.get_viewport())
			elif not own.tree_entered.is_connected(_on_entered.bind(own)):
				own.tree_entered.connect(_on_entered.bind(own), CONNECT_ONE_SHOT)
	return made

static func _on_entered(skel: Skeleton3D) -> void:
	if is_instance_valid(skel) and skel.is_inside_tree():
		driver_for(skel.get_viewport())

## The item's own skeleton under `node` (a BoneAttachment3D's), or null for
## an item weighted onto the body.
static func item_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		if c is Skeleton3D:
			return c
	return null

## The EquipFx rows of `node`'s ambient entries whose bones `host` has, in
## file order; an entry whose bone is missing ends its mod (CRTModParticle
## vslot_001, AmbientParticles.attach's rule).
static func ambient_rows(node: Node, host: Skeleton3D, label: String = "") -> Array:
	var rows: Array = []
	if host == null or not node.has_meta(AMBIENT_META):
		return rows
	for entries in node.get_meta(AMBIENT_META):
		for e_v in entries:
			var e := e_v as BsrReader.ParticleEntry
			# Night-only entries (MEASURED round 806: no item carries one).
			if e == null or e.efp == "" or AmbientParticles.night_only(e):
				continue
			if e.mode != 0:
				if label != "":
					print("WornItemFx %s: %s placed by offset -- not drawn (OPEN)" % [label, e.efp])
				continue
			if host.find_bone(e.bone) < 0:
				if label != "":
					print("WornItemFx %s: no bone '%s' for %s -- the rest of its mod is not built" % [label, e.bone, e.efp])
				break
			var r := ItemGlowTables.ParticleRow.new()
			r.efp = e.efp
			r.bone = e.bone
			rows.append(r)
	return rows

static func _attach_ambient(node: Node, host: Skeleton3D, particles: Pk2Reader, label: String) -> int:
	if host == null or particles == null:
		return 0
	for c in host.get_children():
		if c.has_meta(MARKER_META) and c.get_meta(MARKER_META) == node.get_instance_id():
			return 0
	var rows := ambient_rows(node, host, label)
	if rows.is_empty():
		return 0
	var n := EquipFx.attach(host, rows, particles)
	if ClothDriver._qa_log:
		var names := PackedStringArray()
		for r in rows:
			names.append("%s@%s" % [(r as ItemGlowTables.ParticleRow).efp, (r as ItemGlowTables.ParticleRow).bone])
		print("QA WORN %s: %d particle row(s) on %s: %s" % [label, n, host.name, ", ".join(names)])
	if n > 0:
		host.get_child(host.get_child_count() - 1).set_meta(MARKER_META, node.get_instance_id())
	return n

# --- The clips ---------------------------------------------------------------------------

class Play:
	var clip: BanReader.ParsedAnimation = null
	var ms := 0.0
	var from: BanReader.ParsedAnimation = null
	var from_ms := 0.0
	var blend := BLEND_MS

var _plays := {} # skeleton instance id -> Play
var posed := 0
var _qa_frames := 0

static func driver_for(viewport: Viewport) -> WornItemFx:
	const META := &"opensro_worn_item_fx"
	if viewport.has_meta(META):
		var d = viewport.get_meta(META)
		if is_instance_valid(d):
			return d
	var drv := WornItemFx.new()
	drv.name = "WornItemFx"
	# After the bodies are posed this frame (the body's clip is known).
	drv.process_priority = 90
	if viewport.is_inside_tree() and not viewport.is_node_ready():
		viewport.add_child.call_deferred(drv)
	else:
		viewport.add_child(drv)
	viewport.set_meta(META, drv)
	return drv

func _process(delta: float) -> void:
	var dt := delta * 1000.0
	var seen := {}
	posed = 0
	for node in get_tree().get_nodes_in_group(GROUP):
		var skel := node as Skeleton3D
		if skel == null or skel.get_viewport() != get_viewport():
			continue
		var id := skel.get_instance_id()
		seen[id] = true
		var clips: Dictionary = skel.get_meta(CLIPS_META, {})
		var p: Play = _plays.get(id)
		if p == null:
			p = Play.new()
			p.clip = clips.get(0)
			_plays[id] = p
		var want = body_action(skel)
		if want != null and clips.has(want) and clips[want] != p.clip:
			p.from = p.clip
			p.from_ms = p.ms
			p.blend = 0.0
			p.clip = clips[want]
			p.ms = 0.0
		p.ms += dt
		p.from_ms += dt
		p.blend += dt
		if p.clip == null or not skel.is_visible_in_tree():
			continue
		pose(skel, p)
		posed += 1
	for id in _plays.keys():
		if not seen.has(id):
			_plays.erase(id)
	_qa_frames += 1
	if ClothDriver._qa_log and _qa_frames % 100 == 0:
		for id in _plays:
			var pl: Play = _plays[id]
			var sk := instance_from_id(id) as Skeleton3D
			var b4 := sk.find_bone("Bone04") if sk != null else -1
			print("QA WORN clip %s: %s at %.0f ms, %d bones, Bone04 %s" % [sk.name if sk != null else "?",
				pl.clip.get_meta(SkinnedBsrAssembler.CLIP_PATH_META, "?") if pl.clip != null else "none", pl.ms,
				sk.get_bone_count() if sk != null else 0,
				str(sk.get_bone_pose_rotation(b4).get_euler() * 180.0 / PI) if b4 >= 0 else "none"])

## The body's action type now, when it is one parts are asked again for (the
## body's clip as AnimSounds was last given it); null otherwise.
static func body_action(item_skel: Node) -> Variant:
	var at := item_skel.get_parent()
	while at != null and not at is Skeleton3D:
		at = at.get_parent()
	if at == null:
		return null
	var anim = at.get_meta(BODY_CLIP_META, null)
	if anim == null or not is_instance_valid(anim):
		return null
	var tag = (anim as Object).get_meta(BsrReader.CLIP_META, null)
	if tag == null or not CLIP_TYPES.has(int(tag[0])):
		return null
	return int(tag[0])

## The clip at its time; crossing from the last one over BLEND_MS.
static func pose(skel: Skeleton3D, p: Play) -> void:
	if p.from == null or p.blend >= BLEND_MS:
		Skeleton3DBuilder.apply_ban_pose_at(skel, p.clip, p.ms / 1000.0, true)
		return
	Skeleton3DBuilder.apply_ban_pose_at(skel, p.from, p.from_ms / 1000.0, true)
	var n := skel.get_bone_count()
	var rots: Array[Quaternion] = []
	var poss: Array[Vector3] = []
	for b in range(n):
		rots.append(skel.get_bone_pose_rotation(b))
		poss.append(skel.get_bone_pose_position(b))
	Skeleton3DBuilder.apply_ban_pose_at(skel, p.clip, p.ms / 1000.0, true)
	var w := clampf(p.blend / BLEND_MS, 0.0, 1.0)
	for b in range(n):
		skel.set_bone_pose_rotation(b, rots[b].slerp(skel.get_bone_pose_rotation(b), w))
		skel.set_bone_pose_position(b, poss[b].lerp(skel.get_bone_pose_position(b), w))
	Skeleton3DBuilder.refresh_global_poses(skel)

func describe() -> String:
	return "%d item skeleton(s) with clips, %d posed last frame" % [_plays.size(), posed]
