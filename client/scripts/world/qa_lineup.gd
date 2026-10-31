extends RefCounted
class_name QaLineup

## QA (round 689): the creatable Figures drawn in the world through the OTHER
## PLAYER path -- World3D._spawn_or_update_other, exactly what a server's
## OpEntityEntered with a model builds -- and measured there.
##
##   OPENSRO_QA_LINEUP=all | <id>[:<scale>],... | none
##       which bodies (all = the 52); none spawns nothing and measures the
##       player and the other players a server put in the world
##   OPENSRO_QA_LINEUP_WEAPONS=rotate | each | none
##       rotate: Figure i holds its race's catalogue weapon i mod n (default);
##       each:   one body per Figure per weapon of its race (364 bodies);
##       none:   bare-handed
##   OPENSRO_QA_LINEUP_ACTIONS=stand,run,sit,attack   phases, in order
##   OPENSRO_QA_LINEUP_PHASE=<seconds>                each phase's length (8)
##   OPENSRO_QA_LINEUP_COLUMNS=<n>                    bodies a row (13)
##   OPENSRO_QA_LINEUP_DELAY=<seconds>                wait after the ground is there (3),
##                                                     so the QA camera has settled
##   OPENSRO_QA_LINEUP_QUIT=1                         quit when the last phase is measured
##   OPENSRO_QA_LINEUP_SHOTS=<dir>                    save the screen at each measure
##                                                     (<dir>/lineup_<phase>_<action>.png)
##   OPENSRO_QA_LINEUP_ASIDE=<units>                  first step the player that far to its
##                                                     right (a live pair then stands apart)
##   OPENSRO_QA_LINEUP_KITS="<slot>=<id>[+<plus>],..;.."  (round 734) one body per
##                                                     `;` part, each the FIRST lineup
##                                                     Figure in its kit with these slots
##                                                     put on at these pluses (the glow,
##                                                     EquipGlow): the weapon glow tiers
##                                                     side by side, or a crowd of them
##   OPENSRO_QA_LINEUP_SPACING=<x>[,<z>]              the gaps between bodies (14, 22)
##   OPENSRO_QA_LINEUP_COUNT=<n>                      (round 736) the body list cycled
##                                                     (or cut) to n bodies: a crowd
##   OPENSRO_QA_LINEUP_PLUS=<p>                       (round 736) every lineup weapon and
##                                                     shield at +p (the glow and, from +8,
##                                                     the particles); not with KITS
##   OPENSRO_QA_CROWD_STEPS=...                       (round 736) the crowd's cost split
##                                                     after the spawn (QaCrowdProbe's header)
##   OPENSRO_QA_LINEUP_TURNS=<deg>,<deg>,..           (round 741) body i turned by entry
##                                                     i mod n beyond facing the camera
##   OPENSRO_QA_LINEUP_WALKUP=<seconds>               (round 756) the walk-up: the lineup
##                                                     arrives one 320-unit message block
##                                                     at a time, nearest block first, each
##                                                     as one group spawn (World3D's
##                                                     0x3017..0x3018 bracket), a block
##                                                     every <seconds> -- what crossing
##                                                     block borders toward a crowd sends
##   OPENSRO_QA_LINEUP_BUFFS=1                         (round 756's review, F1) one OpBuffStart
##                                                     a body (skill 0: no aura drawn) through
##                                                     World3D._on_buff_started right after
##                                                     its page, as the server orders them
##                                                     (playerview.go); `QA BUFFS` times them
##   OPENSRO_QA_LINEUP_RUNAT=<s>                      (round 756's review, F3) every lineup body
##                                                     starts walking <s> s after the spawn (one
##                                                     server tick of moves); `QA RUNAT` times it
##                                                     and counts the ghosts before and after
##
## The kit is OURS for the picture: the race's `_A_DEF` weapon (CharCatalog's
## rule on World3D's item table), a shield beside ONE_HANDED_WITH_SHIELD, and the
## lowest-id `_A_DEF` chest, legs and feet of the body's race and sex.
##
## At the end of each phase every lineup body -- and the local player -- is
## measured and one line printed:
##   LINEUP <code> <id> scale <s> weapon <item> group <g> action <a> clip <file>
##          posed <yes|TPOSE> feet <lowest skinned point - ground>
## `posed` compares the skeleton's pose with its rest (the bind, arms out): a
## body no clip drives is still at rest -- the T-pose. `feet` is the lowest
## CPU-skinned vertex of the body (the sum the GPU does) against the walkable
## surface under the body (_ground_at), so + is floating and - is sunk. Then a summary per phase:
##   LINEUP SUMMARY action <a>: <n> bodies, <t> TPOSE, feet min/max, <f> beyond
##   the tolerance (OPENSRO_QA_LINEUP_TOLERANCE, 1.0 units)

const COLUMNS := 13
## OURS, for the kit only: the weapons drawn with the race's shield beside them
## (sword, blade, one-handed sword, dark staff, cleric rod).
const ONE_HANDED_WITH_SHIELD := [2, 3, 7, 10, 15]
const SPACING_X := 14.0
const SPACING_Z := 22.0

var world: Node
var specs: Array = []          # [{ref, scale, weapon}]
var actions: PackedStringArray = PackedStringArray(["stand"])
var phase_seconds := 8.0
var columns := COLUMNS
var tolerance := 1.0
var bodies: Array = []         # [{id, ref, code, scale, weapon, skeleton}]
var _t := 0.0
var _wait := 0.0
var spawn_delay := 3.0
var spacing_x := SPACING_X
var spacing_z := SPACING_Z
var _phase := -1
var _spawned := false
var _done := false
## Round 756 (walk-up): the pages still to spawn ([[spawn args], ...] each),
## the seconds between them and until the next.
var _pages: Array = []
var _page_every := 0.0
var _page_wait := 0.0
var _probe: QaCrowdProbe = null
## Round 756's review hooks: seconds since the spawn, and the run's time.
var _since_spawn := 0.0
var _run_at := -1.0

static func from_env(w: Node) -> QaLineup:
	var spec := OS.get_environment("OPENSRO_QA_LINEUP")
	if spec == "":
		return null
	var q := QaLineup.new()
	q.world = w
	var a := OS.get_environment("OPENSRO_QA_LINEUP_ACTIONS")
	if a != "":
		q.actions = a.split(",", false)
	var ph := OS.get_environment("OPENSRO_QA_LINEUP_PHASE")
	if ph.is_valid_float():
		q.phase_seconds = float(ph)
	var c := OS.get_environment("OPENSRO_QA_LINEUP_COLUMNS")
	if c.is_valid_int():
		q.columns = maxi(1, int(c))
	var dl := OS.get_environment("OPENSRO_QA_LINEUP_DELAY")
	if dl.is_valid_float():
		q.spawn_delay = float(dl)
	var tol := OS.get_environment("OPENSRO_QA_LINEUP_TOLERANCE")
	if tol.is_valid_float():
		q.tolerance = float(tol)
	var sp := OS.get_environment("OPENSRO_QA_LINEUP_SPACING").split(",", false)
	if sp.size() >= 1 and sp[0].is_valid_float():
		q.spacing_x = float(sp[0])
	if sp.size() >= 2 and sp[1].is_valid_float():
		q.spacing_z = float(sp[1])
	return q

## OPENSRO_QA_LINEUP_KITS (round 734): [[equipped overrides, pluses], ...],
## one per `;` part (EquipGlow.parse_loadout); [] when unset.
static func parse_kits(spec: String) -> Array:
	var out: Array = []
	for part in spec.split(";", false):
		out.append(EquipGlow.parse_loadout(part))
	return out

var _probe_steps := OS.get_environment("OPENSRO_QA_CROWD_STEPS") != ""

## Called every physics frame by World3D once the player's body is built.
func step(delta: float) -> void:
	if _spawned and _run_at >= 0.0:
		_since_spawn += delta
		if _since_spawn >= _run_at:
			_run_at = -1.0
			_qa_run_all()
	if _done:
		return
	var appearance: CharacterAppearance = world._appearance
	if appearance == null or world._player_skeleton == null or not world._grid_has_origin:
		return
	if not _spawned:
		if not _ground_ready():
			return
		# The QA camera hooks (OPENSRO_QA_YAW/_PITCH/_DIST) settle in the
		# first ticks; the lineup is laid out in front of where they leave
		# the camera.
		_wait += delta
		if _wait < spawn_delay:
			return
		_spawned = true
		var aside := OS.get_environment("OPENSRO_QA_LINEUP_ASIDE")
		if aside.is_valid_float():
			var b: Basis = world.player.global_transform.basis
			world.player.global_position += b.x.normalized() * float(aside)
			print("LINEUP: the player stepped %s aside to %s" % [aside, str(world.player.global_position.round())])
		_spawn(appearance)
		_t = 0.0
		return
	if _direct_at < _direct.size():
		_spawn_direct_step()
		return
	# Round 756 (walk-up): the next block's group spawn when it is due.
	if not _pages.is_empty():
		_page_wait -= delta
		if _page_wait <= 0.0:
			_page_wait = _page_every
			_spawn_page(_pages.pop_front())
		return
	# Round 762 (QA): with QaCrowdProbe measuring (its steps), the lineup's
	# own phases never start: their first walked every body again in the
	# frame the dressing queue emptied -- a crowd's leave emptied it (8.9 ms
	# of p_lineup in a departure frame, MEASURED r762.md).
	if _probe_steps:
		return
	# Round 739: the bodies are dressed over frames (World3D._pump_other_builds);
	# the first phase starts once every one is.
	if _phase < 0:
		if not world._other_builds.is_empty():
			return
		_refresh_bodies()
		_t = 0.0
		_phase = 0
		_start_phase()
		return
	_t += delta
	if _t >= phase_seconds:
		_measure()
		_t = 0.0
		_phase += 1
		if _phase >= actions.size():
			_done = true
			print("LINEUP DONE")
			if OS.get_environment("OPENSRO_QA_LINEUP_QUIT") != "":
				world.get_tree().quit()
			return
		_start_phase()

func _ground_ready() -> bool:
	return not is_nan(_ground_at(world.player.global_position))

## The walkable surface under p: terrain and placed objects (layer 1 -- the
## town's paving stands above the terrain: the Jangan spawn's is 13.8 over it,
## MEASURED), cast from GROUND_PROBE_ABOVE over p so a roof overhead is not
## taken for the ground. Characters (layers 2, 8) are not hit.
const GROUND_PROBE_ABOVE := 30.0
func _ground_at(p: Vector3) -> float:
	var hit := TerrainCollision.vertical_ray(world.get_world_3d().direct_space_state, p.x, p.z,
		p.y + GROUND_PROBE_ABOVE, p.y - 1000.0, 1, [world.player.get_rid()])
	return NAN if hit.is_empty() else float(hit.position.y)

# --- the bodies ----------------------------------------------------------------

func _spawn(appearance: CharacterAppearance) -> void:
	var cat := appearance.catalog()
	var ids: Array = []
	var spec := OS.get_environment("OPENSRO_QA_LINEUP")
	if spec == "none":
		# Spawn nothing: measure the player and the other players a server
		# put in the world (the live test, round 689).
		print("LINEUP: measuring the player and the server's other players, actions %s, %.1f s each" % [",".join(actions), phase_seconds])
		# Round 759: the crowd probe over the server's crowd (QaCrowdProbe.live).
		if QaCrowdProbe.wanted():
			_probe = QaCrowdProbe.new()
			_probe.name = "QaCrowdProbe"
			_probe.live = true
			world.add_child(_probe)
			_probe.setup(world, [], Time.get_ticks_usec())
		return
	if spec == "swarm":
		_swarm_specs(cat)
	elif spec == "all":
		for r in [CharCatalog.RACE_CHINA, CharCatalog.RACE_EUROPE]:
			for s in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
				for f in cat.figures(r, s):
					ids.append([f.id, CharacterAppearance.DEFAULT_SCALE])
	else:
		for part in spec.split(",", false):
			var kv := String(part).split(":")
			if kv[0].is_valid_int():
				ids.append([int(kv[0]), _int_of(kv[1]) if kv.size() > 1 else CharacterAppearance.DEFAULT_SCALE])
	var mode := OS.get_environment("OPENSRO_QA_LINEUP_WEAPONS")
	if mode == "":
		mode = "rotate"
	var kits := parse_kits(OS.get_environment("OPENSRO_QA_LINEUP_KITS"))
	if not kits.is_empty() and not ids.is_empty():
		var e0 := cat.get_entry(int(ids[0][0]))
		for kit in kits:
			specs.append({"ref": int(ids[0][0]), "scale": int(ids[0][1]), "weapon": int((kit[0] as Dictionary).get(EquipmentNet.SLOT_WEAPON, 0)),
				"race": e0.race if e0 != null else 0, "woman": e0 != null and e0.sex == CharCatalog.SEX_WOMAN,
				"kit": kit[0], "pluses": kit[1]})
		mode = "kits"
		ids = []
	var k := 0
	for pair in ids:
		var e := cat.get_entry(int(pair[0]))
		var race := e.race if e != null else 0
		var woman := e != null and e.sex == CharCatalog.SEX_WOMAN
		var weapons := _weapons(race)
		var picks: Array = []
		match mode:
			"none":
				picks = [0]
			"each":
				picks = weapons if not weapons.is_empty() else [0]
			_:
				picks = [weapons[k % weapons.size()] if not weapons.is_empty() else 0]
		for w in picks:
			specs.append({"ref": int(pair[0]), "scale": int(pair[1]), "weapon": int(w), "race": race, "woman": woman})
		k += 1
	# Round 736: a crowd of n, the list cycled; every weapon and shield at +p.
	var count := OS.get_environment("OPENSRO_QA_LINEUP_COUNT")
	if count.is_valid_int() and int(count) > 0 and not specs.is_empty():
		var cycled: Array = []
		for i in range(int(count)):
			cycled.append((specs[i % specs.size()] as Dictionary).duplicate())
		specs = cycled
	var plus := OS.get_environment("OPENSRO_QA_LINEUP_PLUS")
	if plus.is_valid_int() and mode != "kits" and spec != "swarm":
		for sp in specs:
			sp["pluses"] = {EquipmentNet.SLOT_WEAPON: int(plus), EquipmentNet.SLOT_SHIELD: int(plus)}
	var spawn_t0 := Time.get_ticks_usec()
	var base: Vector3 = world.player.global_position
	# In front of the camera, facing it (so a picture sees their fronts).
	var fwd := Vector3(0.0, 0.0, 1.0)
	var cam: Camera3D = world.get_viewport().get_camera_3d() if world.get_viewport() != null else null
	if cam != null:
		var f := -cam.global_transform.basis.z
		f.y = 0.0
		if f.length() > 0.01:
			fwd = f.normalized()
	var yaw := atan2(fwd.x, fwd.z)
	var right := Vector3(fwd.z, 0.0, -fwd.x)
	# Round 739: the kits once per (race, sex, weapon), and the QA-only work
	# (kits, ground rays) timed apart, so the probe's arrival frame is the
	# spawn path's own: _kit walks the whole item table, about 5 s for 1000
	# bodies (MEASURED, round 739).
	var kit_cache := {}
	var qa_usec := 0
	# OPENSRO_QA_LINEUP_TURNS="0,45,90,..." (round 741): body i turned that
	# many more degrees (i mod the list), so one run sees a weapon at many
	# headings.
	var turns: Array = []
	for t in OS.get_environment("OPENSRO_QA_LINEUP_TURNS").split(",", false):
		turns.append(float(t))
	var walkup := OS.get_environment("OPENSRO_QA_LINEUP_WALKUP")
	var by_block := {}
	var direct: Array = []
	for i in range(specs.size()):
		var sp: Dictionary = specs[i]
		var qa_t0 := Time.get_ticks_usec()
		var col := i % columns
		var row := i / columns
		var at := base + fwd * (40.0 + row * spacing_z) + right * ((col - (columns - 1) * 0.5) * spacing_x)
		var gy := _ground_at(at)
		if not is_nan(gy):
			at.y = gy
		var kit_key := "%d:%s:%d" % [int(sp["race"]), str(sp["woman"]), int(sp["weapon"])]
		# Round 759: a swarm body wears its own gear only, as a bot does.
		if not kit_cache.has(kit_key):
			kit_cache[kit_key] = _kit(sp) if spec != "swarm" else {}
		var equipped: Dictionary = (kit_cache[kit_key] as Dictionary).duplicate()
		if sp.has("kit"):
			equipped.merge(sp["kit"], true)
		qa_usec += Time.get_ticks_usec() - qa_t0
		var id := 990000 + i
		var code: String = world._body_key_for(int(sp["ref"]), "")
		var turn := yaw + PI + (deg_to_rad(float(turns[i % turns.size()])) if not turns.is_empty() else 0.0)
		var args := [id, code, at, equipped, sp, turn]
		bodies.append({"id": id, "ref": int(sp["ref"]), "code": code, "scale": int(sp["scale"]), "weapon": int(sp["weapon"]),
			"group": "", "skeleton": null})
		if walkup.is_valid_float():
			# Its 320-unit block (round 664's message blocks), in world units.
			var bk := "%d,%d" % [floori(at.x / 320.0), floori(at.z / 320.0)]
			if not by_block.has(bk):
				by_block[bk] = []
			(by_block[bk] as Array).append(args)
			continue
		direct.append(args)
	# Round 762: the lineup arrives as one group spawn (bracketed as NetClient
	# brackets a 0x3017..0x3018), as a world entry's window does, not as
	# 1,000 single arrivals each pumping.
	# OPENSRO_QA_LINEUP_STEP_MS=<ms>: handed over a frame's share at a time,
	# as NetClient hands a group over since round 762 (GROUP_STEP_USEC).
	var step_ms := OS.get_environment("OPENSRO_QA_LINEUP_STEP_MS")
	if not direct.is_empty() and step_ms.is_valid_float():
		_direct = direct
		_direct_step_usec = int(float(step_ms) * 1000.0)
		_direct_t0 = Time.get_ticks_usec()
		_spawn_direct_step()
	elif not direct.is_empty():
		var g0 := Time.get_ticks_usec()
		var was_on := FrameSplit.on
		FrameSplit.on = true
		var fs0 := FrameSplit.snapshot()
		world._on_user_group_begin()
		for args in direct:
			_spawn_one(args)
		world._on_user_group_end()
		var fs1 := FrameSplit.snapshot()
		FrameSplit.on = was_on
		print("LINEUP: %d bodies spawned as one group in %.1f ms (books and pluses %.1f, holders %.1f, queues %.1f)" % [direct.size(),
			(Time.get_ticks_usec() - g0) / 1000.0, (int(fs1.get("sp_pre", 0)) - int(fs0.get("sp_pre", 0))) / 1000.0,
			(int(fs1.get("sp_node", 0)) - int(fs0.get("sp_node", 0))) / 1000.0, (int(fs1.get("sp_post", 0)) - int(fs0.get("sp_post", 0))) / 1000.0])
	if walkup.is_valid_float():
		# Nearest block first, as a walk toward the crowd brings them.
		var block_keys := by_block.keys()
		var at0: Vector3 = base
		block_keys.sort_custom(func(a, b) -> bool:
			var pa: Array = (by_block[a] as Array)[0]
			var pb: Array = (by_block[b] as Array)[0]
			return (pa[2] as Vector3).distance_squared_to(at0) < (pb[2] as Vector3).distance_squared_to(at0))
		for bk2 in block_keys:
			_pages.append(by_block[bk2])
		_page_every = float(walkup)
		_page_wait = _page_every
		print("LINEUP: walk-up -- %d bodies in %d block group spawns, one every %.1f s (%d ms of QA kits and ground)" % [
			bodies.size(), _pages.size(), _page_every, qa_usec / 1000])
	else:
		print("LINEUP: %d bodies (%s weapons) in rows of %d in front of the player at %s, actions %s, %.1f s each; built in %d ms (%d of it the QA kits and ground; %d still queued to dress, round 739)" % [
			bodies.size(), mode, columns, str(base.round()), ",".join(actions), phase_seconds, (Time.get_ticks_usec() - spawn_t0) / 1000,
			qa_usec / 1000, world._other_builds.size()])
	spawn_t0 += qa_usec
	if walkup.is_valid_float():
		spawn_t0 = Time.get_ticks_usec()
	var ra := OS.get_environment("OPENSRO_QA_LINEUP_RUNAT")
	if ra.is_valid_float():
		_run_at = float(ra)
	if QaCrowdProbe.wanted():
		_probe = QaCrowdProbe.new()
		_probe.name = "QaCrowdProbe"
		world.add_child(_probe)
		_probe.setup(world, bodies, spawn_t0)
	if walkup.is_valid_float():
		_spawn_page(_pages.pop_front())
	elif OS.get_environment("OPENSRO_QA_LINEUP_BUFFS") != "":
		var all_ids: Array = []
		for b in bodies:
			all_ids.append(int(b["id"]))
		_qa_buffs(all_ids)

## Round 759 (OPENSRO_QA_LINEUP=swarm): OPENSRO_QA_LINEUP_COUNT bodies (1,000
## unless set) dressed as the live swarm dresses its bots (QaSwarmGear: its
## looks, its gear catalogue from the item table, its pluses).
## OPENSRO_QA_LINEUP_SWARM_SEED picks another crowd of the same mix.
func _swarm_specs(cat: CharCatalog) -> void:
	var gear := QaSwarmGear.new()
	var sd := OS.get_environment("OPENSRO_QA_LINEUP_SWARM_SEED")
	if sd.is_valid_int():
		gear.seed = int(sd)
	var t0 := Time.get_ticks_usec()
	gear.build(world._item_rows)
	var count := OS.get_environment("OPENSRO_QA_LINEUP_COUNT")
	var n := int(count) if count.is_valid_int() and int(count) > 0 else 1000
	var figs := {}
	for i in range(n):
		var lk := gear.look(i)
		var key := "%d|%d" % [lk["race"], lk["sex"]]
		if not figs.has(key):
			figs[key] = cat.figures(int(lk["race"]), int(lk["sex"]))
		var fl: Array = figs[key]
		if fl.is_empty():
			continue
		var e: CharCatalog.Entry = fl[int(lk["figure"]) % fl.size()]
		var lo := gear.loadout(i, int(lk["race"]), int(lk["sex"]))
		var kit: Dictionary = lo[0]
		specs.append({"ref": e.id, "scale": int(lk["scale"]), "weapon": int(kit.get(EquipmentNet.SLOT_WEAPON, 0)),
			"race": int(lk["race"]), "woman": int(lk["sex"]) == QaSwarmGear.SEX_WOMAN, "kit": kit, "pluses": lo[1]})
	print("LINEUP: swarm gear -- %s; %d bodies in %d ms" % [gear.summary(), specs.size(), (Time.get_ticks_usec() - t0) / 1000])

## One lineup body through the other-player arrival path, facing `args[5]`.
func _spawn_one(args: Array) -> void:
	var sp: Dictionary = args[4]
	var code: String = args[1]
	world._spawn_or_update_other(int(args[0]), "%s" % code.trim_prefix("CHAR_"), args[2], args[3], code, NAN, int(sp["scale"]),
		sp.get("pluses", {}))
	var node: Node3D = world._other_bodies.get(int(args[0]))
	if node != null:
		node.rotation.y = float(args[5])

## Round 756's review hook (F1): one OpBuffStart a body of `ids`, as the
## server sends each arriving player's buffs after its page.
func _qa_buffs(ids: Array) -> void:
	var t0 := Time.get_ticks_usec()
	var token := 760000
	for id in ids:
		var b := SkillNet.BuffStart.new()
		b.owner_id = int(id)
		b.skill_id = 0
		token += 1
		b.token = token
		b.owner_kind = SkillNet.OWNER_CHARACTER
		world._on_buff_started(b)
	print("QA BUFFS %d buff start(s) after the page in %.1f ms" % [ids.size(), (Time.get_ticks_usec() - t0) / 1000.0])

## Round 756's review hook (F3): every lineup body starts walking at once.
func _qa_run_all() -> void:
	var crowd = world.get("_crowd_gpu")
	var before := int((crowd as CrowdGpu).ghost_count()) if crowd != null else 0
	var t0 := Time.get_ticks_usec()
	for b in bodies:
		world._set_other_gait(int(b["id"]), true)
	print("QA RUNAT %d bodies set walking %.1f s after the spawn in %.1f ms; ghosts %d before, %d after" % [bodies.size(), _since_spawn,
		(Time.get_ticks_usec() - t0) / 1000.0, before, int((crowd as CrowdGpu).ghost_count()) if crowd != null else 0])

## Round 762: the direct group's next share (OPENSRO_QA_LINEUP_STEP_MS), one
## body at least, bracketed.
var _direct: Array = []
var _direct_at := 0
var _direct_step_usec := 0
var _direct_t0 := 0
var _direct_frames := 0
var _direct_frame_seen := -1

func _spawn_direct_step() -> void:
	if _direct_at >= _direct.size():
		return
	# Once a rendered frame, as NetClient reads a group from its _process: the
	# lineup steps from the physics tick, which runs several times in a long
	# frame (round 762's first offline runs handed over 2-4 shares a frame).
	var f := Engine.get_process_frames()
	if f == _direct_frame_seen:
		return
	_direct_frame_seen = f
	var t0 := Time.get_ticks_usec()
	var first := _direct_at
	_direct_frames += 1
	# As NetClient._group_step: the share the frame's crowd budget leaves.
	var step := int(world.call("qa_group_step_usec", _direct_step_usec)) if world.has_method("qa_group_step_usec") else _direct_step_usec
	world._on_user_group_begin()
	while _direct_at < _direct.size():
		if _direct_at > first and Time.get_ticks_usec() - t0 >= step:
			break
		_spawn_one(_direct[_direct_at])
		_direct_at += 1
	if world.has_method("qa_budget_spend"):
		world.call("qa_budget_spend", Time.get_ticks_usec() - t0)
	world._on_user_group_end()
	if _direct_at >= _direct.size():
		print("LINEUP: %d bodies handed over in %d frame(s), %.1f ms" % [_direct.size(), _direct_frames, (Time.get_ticks_usec() - _direct_t0) / 1000.0])

## Round 756 (walk-up): one block's bodies as one group spawn, bracketed as
## NetClient brackets a 0x3017..0x3018 page (World3D._on_user_group_begin /
## _end), so the page arrives whole.
func _spawn_page(page: Array) -> void:
	var ids: Array = []
	for args in page:
		ids.append(int(args[0]))
	if _probe != null:
		_probe.page_started(ids)
	var t0 := Time.get_ticks_usec()
	world._on_user_group_begin()
	for args in page:
		_spawn_one(args)
	world._on_user_group_end()
	if OS.get_environment("OPENSRO_QA_LINEUP_BUFFS") != "":
		_qa_buffs(ids)
	print("LINEUP: walk-up page of %d bodies spawned in %.1f ms (%d page(s) left)" % [page.size(), (Time.get_ticks_usec() - t0) / 1000.0, _pages.size()])

## Each body's skeleton and group as dressed (round 739: dressed after the
## spawn, over frames).
func _refresh_bodies() -> void:
	for b in bodies:
		var gait: Dictionary = world._other_gaits.get(b["id"], {})
		b["group"] = String(gait.get("group", ""))
		b["skeleton"] = gait.get("skeleton")

func _int_of(t: String) -> int:
	t = t.strip_edges()
	if t.begins_with("0x"):
		return t.substr(2).hex_to_int()
	return int(t) if t.is_valid_int() else CharacterAppearance.DEFAULT_SCALE

## The race's catalogue weapons from World3D's item table: `_A_DEF`, TypeID
## 3/1/6, the race's Country (or 3), in id order.
func _weapons(race: int) -> Array:
	var out: Array = []
	for id in world._item_rows:
		var it: ItemTableReader.Item = world._item_rows[id]
		if not it.code_name.ends_with("_A_DEF") or it.type_ids.size() < 4:
			continue
		if it.type_ids[0] == 3 and it.type_ids[1] == 1 and it.type_ids[2] == 6 and (it.country == race or it.country == 3):
			out.append(int(id))
	out.sort()
	return out

## The kit: the weapon, a shield beside a one-handed one, and the lowest-id
## `_A_DEF` chest, legs and feet of the race and sex (OURS, see the header).
func _kit(sp: Dictionary) -> Dictionary:
	var eq := {}
	var race: int = sp["race"]
	var want_sex := 0 if sp["woman"] else 1
	var pieces := {3: EquipmentNet.SLOT_MAIL, 4: EquipmentNet.SLOT_PANTS, 6: EquipmentNet.SLOT_BOOTS}
	var best := {}
	var shield := 0
	for id in world._item_rows:
		var it: ItemTableReader.Item = world._item_rows[id]
		if not it.code_name.ends_with("_A_DEF") or it.type_ids.size() < 4 or it.type_ids[0] != 3 or it.type_ids[1] != 1:
			continue
		if not (it.country == race or it.country == 3):
			continue
		if it.type_ids[2] == 4 and (it.type_ids[3] == 1 or it.type_ids[3] == 2):
			if shield == 0 or int(id) < shield:
				shield = int(id)
			continue
		if it.type_ids[2] in [1, 2, 3, 9, 10, 11] and pieces.has(it.type_ids[3]) and (it.req_gender == want_sex or it.req_gender == 2):
			var slot: int = pieces[it.type_ids[3]]
			if not best.has(slot) or int(id) < int(best[slot]):
				best[slot] = int(id)
	for slot in best:
		eq[slot] = best[slot]
	var w: int = sp["weapon"]
	if w != 0:
		eq[EquipmentNet.SLOT_WEAPON] = w
		var wit: ItemTableReader.Item = world._item_rows.get(w)
		if wit != null and shield != 0 and wit.type_ids.size() >= 4 and wit.type_ids[3] in ONE_HANDED_WITH_SHIELD:
			eq[EquipmentNet.SLOT_SHIELD] = shield
	return eq

# --- the phases --------------------------------------------------------------------

func _start_phase() -> void:
	var action := actions[_phase]
	# The local player too, through the same request its N key sends (a
	# server answers it with the motion, as for anyone else).
	var player_sits := bool(world._sit.sitting) if world._sit != null else false
	if (action == "sit") != player_sits and NetClient.is_connected_to_server():
		print("LINEUP: the player's sit toggle -> %s" % world._request_sit_toggle())
	for b in bodies:
		var id: int = b["id"]
		match action:
			"run":
				world._apply_other_motion(id, WorldNet.MOTION_STAND)
				world._set_other_gait(id, true)
			"sit":
				world._set_other_gait(id, false)
				world._apply_other_motion(id, WorldNet.MOTION_SIT)
			"attack":
				world._apply_other_motion(id, WorldNet.MOTION_STAND)
				world._set_other_gait(id, false)
				var gait: Dictionary = world._other_gaits.get(id, {})
				if not gait.is_empty():
					var clip: BanReader.ParsedAnimation = world._body_animation_for(String(gait["body"]), BsrReader.AnimationEntry.TYPE_ATTACK, String(gait["group"]))
					# Through World3D's own swap (round 747): a far body's entry is
					# CrowdGpu's, not _animated's.
					world._swap_other_loop(gait["skeleton"], clip)
			_:
				world._apply_other_motion(id, WorldNet.MOTION_STAND)
				world._set_other_gait(id, false)
	print("LINEUP PHASE %d: %s" % [_phase, action])

## The action type the phase plays, for the clip's name in the line.
func _action_type(action: String) -> int:
	match action:
		"run": return BsrReader.AnimationEntry.TYPE_RUN
		"sit": return BsrReader.AnimationEntry.TYPE_SITTING
		"attack": return BsrReader.AnimationEntry.TYPE_ATTACK
	return BsrReader.AnimationEntry.TYPE_STAND

func _measure() -> void:
	var action := actions[_phase]
	var t := _action_type(action)
	var n := 0
	var tposes := 0
	var beyond := 0
	var lo := INF
	var hi := -INF
	var rows: Array = []
	for b in bodies:
		rows.append([b["code"], b["ref"], b["scale"], b["weapon"], b["group"], b["skeleton"], world._other_bodies.get(b["id"])])
	if bodies.is_empty():
		# The server's other players (spec "none").
		for id in world._other_gaits:
			var gait: Dictionary = world._other_gaits[id]
			var eq: Dictionary = world._other_worn(int(id))
			rows.append(["other:%s" % String(gait["body"]), int(id), int(gait.get("scale", 0)), int(eq.get(EquipmentNet.SLOT_WEAPON, 0)),
				String(gait["group"]), gait["skeleton"], world._other_bodies.get(id)])
	if world._player_skeleton != null:
		rows.append(["player:" + String(world._player_body), -1, world._player_scale, int(world._player_equipped_last.get(EquipmentNet.SLOT_WEAPON, 0)),
			world._player_weapon_group, world._player_skeleton, world.player])
	for r in rows:
		var skel: Skeleton3D = r[5]
		var node: Node3D = r[6]
		if skel == null or not is_instance_valid(skel) or node == null:
			continue
		var clip: String = world._body_animation_path(String(r[0]).trim_prefix("player:").trim_prefix("other:"), t, String(r[4]))
		# Pose it now, as the frame draws it (an off-screen body is not posed
		# by the idle tick): the entry driving it, at the current clock.
		_pose_current(skel)
		var posed := _posed(skel)
		var ground := _ground_at(node.global_position)
		var low := lowest_point(skel)
		var feet := low - ground if not is_nan(ground) else NAN
		n += 1
		if not posed:
			tposes += 1
		if not is_nan(feet):
			lo = minf(lo, feet)
			hi = maxf(hi, feet)
			if absf(feet) > tolerance:
				beyond += 1
		print("LINEUP %-28s %6d scale 0x%02x weapon %5d group %-14s action %-6s clip %-40s posed %-5s feet %+.3f" % [
			r[0], r[1], r[2], r[3], r[4], action, clip, "yes" if posed else "TPOSE", feet])
	print("LINEUP SUMMARY action %s: %d bodies, %d TPOSE, feet %+.3f .. %+.3f, %d beyond %.2f" % [action, n, tposes, lo, hi, beyond, tolerance])
	var dir := OS.get_environment("OPENSRO_QA_LINEUP_SHOTS")
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
		var img := world.get_viewport().get_texture().get_image()
		var path := dir.path_join("lineup_%d_%s.png" % [_phase, action])
		print("LINEUP SHOT %s (%s)" % [path, error_string(img.save_png(path)) if img != null else "no image"])

func _pose_current(skel: Skeleton3D) -> void:
	var entries: Array = world._animated
	# A far body's entry is CrowdGpu's (round 747): the hidden skeleton is posed
	# for the measure as a near one is.
	var crowd = world.get("_crowd_gpu")
	if crowd != null and (crowd as CrowdGpu).has(skel):
		entries = [(crowd as CrowdGpu).entry_of(skel)]
	for entry in entries:
		if entry[0] == skel and entry[1] != null:
			var anim: BanReader.ParsedAnimation = entry[1]
			var secs: float = world._idle_anim_time - float(entry[5]) + float(entry[3])
			Skeleton3DBuilder.apply_ban_pose_at(skel, anim, secs, bool(entry[4]))
			# Not CrowdAnim's baked frames: the next baked pose writes every
			# channel (round 738's review, F7).
			if skel.has_meta(CrowdAnim.META_LAST):
				skel.remove_meta(CrowdAnim.META_LAST)
			return
	if skel == world._player_skeleton:
		return # the player is posed every frame by its own tick

## Whether any bone of the skeleton is away from its rest (the bind pose):
## false is a body no clip drives -- the T-pose.
static func _posed(skel: Skeleton3D) -> bool:
	for i in range(skel.get_bone_count()):
		var rest := skel.get_bone_rest(i).basis.get_rotation_quaternion()
		var now := skel.get_bone_pose_rotation(i)
		if absf(rest.dot(now)) < 0.9999:
			return true
	return false

## The lowest CPU-skinned vertex of every visible mesh skinned to `skel`, in
## world space (the same sum the GPU does: weight x bone pose x bind x vertex,
## then the skeleton's global transform).
static func lowest_point(skel: Skeleton3D) -> float:
	Skeleton3DBuilder.refresh_global_poses(skel)
	var g := skel.global_transform
	var lo := INF
	for mi in CharacterAppearance._skinned_to(skel):
		if String(mi.name).ends_with("_front") or not mi.is_visible_in_tree():
			continue
		var skin: Skin = mi.skin
		var xf: Array[Transform3D] = []
		for i in range(skin.get_bind_count()):
			xf.append(skel.get_bone_global_pose(skin.get_bind_bone(i)) * skin.get_bind_pose(i))
		var mesh: Mesh = mi.mesh
		for sidx in range(mesh.get_surface_count()):
			var arr := mesh.surface_get_arrays(sidx)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones = arr[Mesh.ARRAY_BONES]
			var weights = arr[Mesh.ARRAY_WEIGHTS]
			if bones == null or weights == null or v.is_empty():
				continue
			var per := int(bones.size() / v.size())
			for k in range(v.size()):
				var p := Vector3.ZERO
				var wsum := 0.0
				for j in range(per):
					var w: float = weights[k * per + j]
					if w <= 0.0:
						continue
					var bi: int = bones[k * per + j]
					if bi < xf.size():
						p += (xf[bi] * v[k]) * w
						wsum += w
				if wsum > 0.0:
					lo = minf(lo, (g * (p / wsum)).y)
	return lo
