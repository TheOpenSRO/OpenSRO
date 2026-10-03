extends RefCounted
class_name NpcFacing

## Which way a town NPC faces -- a DISCLOSED STAND-IN, not the game's value.
##
## Since round 708 this is the FALLBACK only: the server spawns every NPC with
## its nest's wInitialDir (NpcSpawnNet, docs/protocol/npc_spawn.md), and the
## client turns it by that. This walk faces only the NPCs the server names in
## OpNpcFacingUnknown -- an npcpos row its database has no nest for, or a
## server with no database -- and the QA-only OPENSRO_QA_LOCAL_NPCS records.
## The history below is why it was written.
##
## The game's own answer is data this project does not have. The server
## spawns every NPC facing the direction stored in its nest row:
## `Nest_Hatch` (`0x005607b0` in SR_GameServer.exe) reads the row's u16 at
## +0x1c -- `Tab_RefNest.wInitialDir` -- and turns it into radians as
## `wInitialDir / 65535.0 * 360.0 * 0.017453292` (`fdiv [0xb45c28]`,
## `fmul [0xb45c30]`, `fmul [0xb45e00]` at `0x5609ce`/`0x560a2a`; doubles
## 65535.0, 360.0, pi/180). Monsters instead roll a random facing, except
## rarity 3. `Tab_RefNest` lives in the server's database, and no file the
## client or the server package ships carries it: `npcpos.txt` has exactly
## five columns (id, region, x, y, z) on all 12,367 rows. Until that table
## is available, every NPC would face whichever way its model was authored,
## which is the same way for all of them (reported from a playtest,
## 2026-09-23).
##
## So this faces an NPC toward the most open space around it, measured on
## the region's own navigation graph -- the same walk a character makes
## (`NavGraph.step_tracked`), so walls, doorways and the objects it stands on
## count exactly as they do for a player. A shopkeeper with a wall at their
## back faces the room or the street; one in a doorway faces out of it. It is
## a heuristic: an NPC the game turns toward a wall, or sideways along a
## street, will not match. Replace it with the real `wInitialDir` the day the
## table is imported.

## How many headings are probed around the NPC (every 15 degrees).
const HEADINGS := 24
## The walk's step, in world units. `step_tracked` tests every edge a step
## crosses, so a longer step cannot jump a wall; the half-step progress rule
## below is what keeps a wall's slide from counting as open. 20 halves the
## cost of 10 (measured on the render box: 708 ms for Jangan's 18 NPCs at
## 10, 404 ms at 20) for the same choice at this resolution.
const STEP := 20.0
## Probe ranges, tried in order until the headings disagree -- a small room
## is settled at the first, an NPC on an open square needs the longer ones.
const RANGES := [80.0, 160.0, 320.0]
## Half-width, in headings, of the sector a heading is scored over (+-30
## degrees), so a narrow gap does not win over a wide open side.
const SECTOR := 2

## The region-local X/Z direction (unit length) the NPC at `start`, standing
## on `standing_on` (NavGraph.ON_TERRAIN or an object index), should face;
## Vector2.ZERO when every heading is equally open at the longest range,
## which says nothing about a facing.
static func open_direction(graph: NavGraph, start: Vector3, standing_on: int) -> Vector2:
	for range_units in RANGES:
		var free := PackedFloat32Array()
		free.resize(HEADINGS)
		for h in range(HEADINGS):
			free[h] = _free_distance(graph, start, standing_on, _heading(h), range_units)
		var all_open := true
		var scores := PackedFloat32Array()
		scores.resize(HEADINGS)
		var best_score := -1.0
		for h in range(HEADINGS):
			if free[h] < range_units - 0.001:
				all_open = false
			var score := 0.0
			for k in range(-SECTOR, SECTOR + 1):
				score += free[posmod(h + k, HEADINGS)]
			scores[h] = score
			best_score = maxf(best_score, score)
		if not all_open:
			return _heading(_middle_of_best_run(scores, best_score))
	return Vector2.ZERO

## Every heading whose sector is fully open scores the same maximum, so the
## first maximum would be the EDGE of the open side. Face the middle of the
## longest run of tied best headings instead (circularly; the lower middle
## for an even run, the earliest run when two are equally long).
static func _middle_of_best_run(scores: PackedFloat32Array, best_score: float) -> int:
	var n := scores.size()
	var is_best: Array[bool] = []
	for h in range(n):
		is_best.append(scores[h] >= best_score - 0.001)
	# Start the scan just after a non-best heading so a run is never split
	# by the wrap; if every heading ties, there is nothing to prefer.
	var start := -1
	for h in range(n):
		if not is_best[h]:
			start = (h + 1) % n
			break
	if start < 0:
		return 0
	var best_mid := -1
	var best_len := 0
	var run_start := -1
	var run_len := 0
	for i in range(n + 1):
		var h := (start + i) % n
		if i < n and is_best[h]:
			if run_len == 0:
				run_start = h
			run_len += 1
		else:
			if run_len > best_len:
				best_len = run_len
				best_mid = (run_start + (run_len - 1) / 2) % n
			run_len = 0
	return best_mid

## The holder rotation (Godot `rotation.y`) that points an assembled NPC body
## along a region-local direction. The body's visual front is its own local
## -Z (the playtest-settled convention World3D's player body uses, where it is
## turned 180 degrees instead), and Basis(UP, a) sends -Z to
## (-sin a, 0, -cos a); so `a = atan2(-dir.x, -dir.z)`.
static func holder_yaw(dir: Vector2) -> float:
	return atan2(-dir.x, -dir.y)

static func _heading(h: int) -> Vector2:
	var a := TAU * float(h) / float(HEADINGS)
	return Vector2(sin(a), cos(a))

## How far a character can walk from `start` along `dir` before a wall stops
## it, up to `range_units`: each step must make at least half a step of
## progress along `dir` (a wall slides the mover sideways, which is not
## progress).
static func _free_distance(graph: NavGraph, start: Vector3, standing_on: int, dir: Vector2, range_units: float) -> float:
	var pos := start
	var on := standing_on
	var travelled := 0.0
	while travelled < range_units - 0.001:
		var step := minf(STEP, range_units - travelled)
		var res := graph.step_tracked(pos, dir * step, on)
		var moved := Vector2(res.position.x - pos.x, res.position.z - pos.z)
		var progress := moved.dot(dir)
		if progress < step * 0.5:
			return travelled + maxf(progress, 0.0)
		travelled += progress
		pos = res.position
		on = res.standing_on
	return range_units
