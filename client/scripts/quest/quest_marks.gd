extends RefCounted
class_name QuestMarks

## The quest marks over NPCs and the tracked quest's minimap signs (round
## 785).
##
## **Over an NPC (READ, GlobalDataManager::FUN_009c75e0 and the system-effect
## table at 0xec73f8):** 0x30D6's mark type picks the effect drawn over the
## object -- 0, 1 and anything else SYSTEM_EXCLAMATION_START, 2
## SYSTEM_EXCLAMATION_GOING, 3 SYSTEM_EXCLAMATION_END, 4 SYSTEM_QUEST_MARK2.
## The files (MEASURED in Data.pk2): `Res\etc\ex_mark_start.bsr`,
## `ex_mark_going.bsr`, `ex_mark_end.bsr`, `ex_mark_start_r.bsr` (which
## effect row names which file is INFERRED from the names). The mark stays
## with the object id, so an NPC spawned later carries a mark that arrived
## before it (FUN_009d17e0).
## **How it is drawn (round 785's client review, finding 3).** The ex_mark
## files have no mesh: each is a `.bmt`, a `.bsk` and one particle mod --
## its `ambient` set's one entry, mode 1 (at an offset, no bone),
## `system\system_questmark_<kind>.efp` at (0, 1.208, 0) (MEASURED,
## tools/dump_bsr_particles.gd on the four files). Drawn as a still object
## (rounds before), the mark showed nothing. READ (data): skilleffect.txt's
## SYSTEM_EXCLAMATION_START / _GOING / _END and SYSTEM_QUEST_MARK2 rows play
## the .bsr as ACT_L AT_LOOP at StartBone `*`, StartOffset (0, 5, 0); READ
## (the effects lane, FUN_00a9d0f0 / FUN_009c7730): `*` is the body's turn
## plus a height, the object's +0x228; for a character that height is
## FUN_009c7740 x 20.0 (CICharactor slot 28, 0x9c7780; the double at
## 0x00e1b830) -- INFERRED the body's own height, which this client has as
## the model's bounds (HEIGHT_META). So the mark holder stands at the body's
## height + 5 and plays the .bsr's ambient effects at their offsets
## (AmbientParticles' placement for a mode-1 entry), looping.
## OURS: the .bsr's ex_mark_stand clip is not played (its .bsk drives no
## mesh; whether it moves the mod's point was not read).
## **The flicker (round 843, the user's report).** The scroll's glow jumped
## between bright and dim from frame to frame. MEASURED (efpcensus -show):
## system_questmark_start.efp is a holder, then `quest_sign_shine.ddj`
## (SRCALPHA/ONE, its alpha keyed 140 -> 72 -> 140 over 30 frames: the
## original's slow pulse) and `quest_sign_a.ddj` (SRCALPHA/INVSRCALPHA, scale
## (5, 5, 1)), both billboards at one point. READ: the original draws the
## newer-born particle's group first -- the scroll, then the shine added over
## it, in every frame (EfpEffect.DRAW_ORDER_STEP has the addresses). Here the
## two nodes tied in Godot's transparent sort and came out in either order:
## shine over (bright) or under the scroll (dim, the scroll's ink and rolled
## ends showing). Each node now has a fixed order (EfpEffect's sorting
## offset), the original's; the slow pulse stays, as the file keys it. No
## occlusion test or glow pass touches the mark (it is a plain effect, not an
## object's ambient glow); its fog fade (round 807) holds still with the
## camera.

## **On the minimap (READ, CIFMinimap::vslot_013):** only the tracked quest's
## NPC list (0x30D5 flags & 0x40) is drawn; each NPC's spot comes from the
## client's own npcpos table; within 47.0 map pixels `mm_sign_questnpc.ddj`,
## beyond it `mm_sign_questarrow.ddj` on the rim, turned toward the NPC
## (PartyMapMarks' geometry, the same 47.0).

const MARK_NODE := "QuestMark"
const NPC_SIGN_DDJ := "interface\\minimap\\mm_sign_questnpc.ddj"
const ARROW_DDJ := "interface\\minimap\\mm_sign_questarrow.ddj"
## The holder's meta for the body's height (World3D sets it from the model's
## bounds as it builds the NPC).
const HEIGHT_META := "body_height"
## READ (data): the SYSTEM_EXCLAMATION_* rows' StartOffset (0, 5, 0).
const START_OFFSET := Vector3(0.0, 5.0, 0.0)

static func mark_path(mark_type: int) -> String:
	match mark_type:
		QuestNet.MARK_GOING:
			return "res\\etc\\ex_mark_going.bsr"
		QuestNet.MARK_END:
			return "res\\etc\\ex_mark_end.bsr"
		4:
			return "res\\etc\\ex_mark_start_r.bsr"
	return "res\\etc\\ex_mark_start.bsr"

## Puts (or removes) the mark of every holder in `holders` (uid -> Node3D)
## to match `marks` (object id -> QuestNet.Mark). `models` caches each path's
## effect list; `loader` makes it from a path -- [[efp path, offset], ...],
## the .bsr's ambient entries (entries_of), [] when it has none -- and
## `make_fx` builds an effect from an efp path (null when it cannot).
static func apply(holders: Dictionary, marks: Dictionary, models: Dictionary, loader: Callable,
		make_fx: Callable = Callable()) -> int:
	var shown := 0
	for uid in holders:
		var holder = holders[uid]
		if holder == null or not is_instance_valid(holder):
			continue
		if apply_one(holder as Node3D, marks.get(int(uid)) as QuestNet.Mark, models, loader, make_fx):
			shown += 1
	return shown

static func apply_one(holder: Node3D, mark: QuestNet.Mark, models: Dictionary, loader: Callable,
		make_fx: Callable = Callable()) -> bool:
	var existing := holder.get_node_or_null(MARK_NODE) as Node3D
	var want := mark_path(mark.mark_type) if mark != null else ""
	if existing != null and str(existing.get_meta("mark_path", "")) == want:
		return want != ""
	if existing != null:
		holder.remove_child(existing)
		existing.queue_free()
	if want == "":
		return false
	if not models.has(want):
		models[want] = loader.call(want)
	var node := Node3D.new()
	node.name = MARK_NODE
	node.set_meta("mark_path", want)
	node.position = Vector3(0.0, height_of(holder), 0.0) + START_OFFSET
	holder.add_child(node)
	var entries = models[want]
	if entries is Array and make_fx.is_valid():
		for e in entries:
			var fx = make_fx.call(String(e[0]))
			if fx == null or not (fx is EfpEffect):
				continue
			var ef := fx as EfpEffect
			ef.loop = true
			ef.auto_free = false
			SkillEffects.attach(ef, node, "none", e[1])
	return true

## The body's height the mark stands over: HEIGHT_META, else the name plate's
## height less its clearance, else 20 (OURS, a body with neither).
static func height_of(holder: Node3D) -> float:
	if holder.has_meta(HEIGHT_META):
		return float(holder.get_meta(HEIGHT_META))
	var plate := holder.get_node_or_null("Name") as Node3D
	return plate.position.y / 1.12 if plate != null else 20.0

## A mark .bsr's effects: [[efp path, offset], ...] for each entry of its
## `ambient` sets (AmbientParticles.ambient_entries) that is not night-only --
## the mode-1 entries at their offsets; a mode-0 (bone) entry has no body to
## stand on here and is left out.
static func entries_of(bsr_data: PackedByteArray) -> Array:
	var out: Array = []
	var obj := BsrReader.parse(bsr_data)
	if obj == null:
		return out
	for entries in AmbientParticles.ambient_entries(obj.particle_mods):
		for e_v in entries:
			var e := e_v as BsrReader.ParticleEntry
			# Night-only entries (MEASURED round 806: no mark carries one).
			if e == null or e.efp == "" or e.mode == 0 or AmbientParticles.night_only(e):
				continue
			out.append([e.efp, e.offset])
	return out

## npcpos rows by NPC id: the first row's [region word, local position]
## (region word (x << 8) | y, as the spawn records carry it).
static func index_positions(spawns: Array) -> Dictionary:
	var out := {}
	for s in spawns:
		var sp := s as NpcTableReader.Spawn
		if sp == null or out.has(sp.npc_id):
			continue
		out[sp.npc_id] = [(sp.region_x << 8) | sp.region_y, sp.local_position]
	return out

## The tracked quest's NPCs in the player's region-local frame.
static func targets_local(npc_ids: PackedInt64Array, here_region: Vector2i, index: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for id in npc_ids:
		var row = index.get(int(id))
		if row == null:
			continue
		var p: Vector3 = row[1]
		out.append(PartyMapMarks.record_local(here_region, int(row[0]), p.x, p.z))
	return out
