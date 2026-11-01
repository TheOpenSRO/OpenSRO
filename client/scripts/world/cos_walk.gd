class_name CosWalk
extends RefCounted

## Round 851: a COS's drawn leg (World3D._cos_step) walks the navigation graph
## and stops at the first wall, as the original client walks every mover.
##
## READ (sro_client.exe): the mover's tick FUN_009e0e60 hands each step to the
## collision query CRegionManagerBody::vslot_012 (c:0x9e0fca) and ends the
## movement on its blocked bit, for every mover it draws -- the flag it passes
## is 1 for the own player and the own COS (IsKindOf CICPlayer 0xef1b44, or
## CICCos 0xeef6f0 whose owner is the player, c:0x9e0f45..0x9e0fc3) and 0 for
## the rest. READ (SR_GameServer.exe, s:0x485740): the server's collision for
## a COS is a player's -- the same edges, no radius, no slide (session/
## navkind.go). So a pet, a horse or a trade transport walking after its owner
## stops at a tree or a wall where the server stops it, and is drawn there:
## no walking into the trunk and being pulled back by the server's stop.
##
## OURS: the footing (terrain or an object) is settled from the height at the
## leg's first step and carried from frame to frame, as the own player's walk
## carries it (World3D._move_on_nav_graph); the original carries a cell.

## One frame of a COS's leg `st` ({"pos": Vector2, "dest": Vector2, "speed":
## float, "moving": bool}, World3D._cos_motion's entry) at world height `y`:
## the straight step toward the destination (MonsterMotion.step) walked on
## `graph` with no slide. `xf` is the graph's terrain group's global transform
## (region-local -> world). graph null: no graph under it, the straight step.
## st["pos"] is the new ground position; true when a wall stopped the leg this
## frame (st["moving"] is then false).
static func advance(st: Dictionary, graph: NavGraph, xf: Transform3D, y: float, delta: float) -> bool:
	var from: Vector2 = st["pos"]
	var next := MonsterMotion.step(from, st["dest"], float(st["speed"]), delta)
	if graph == null or next == from:
		st["pos"] = next
		return false
	var inv := xf.affine_inverse()
	var lf := inv * Vector3(from.x, y, from.y)
	var ln := inv * Vector3(next.x, y, next.y)
	var on := NavGraph.ON_TERRAIN
	if st.has("on") and st.get("graph") == graph:
		on = int(st["on"])
	else:
		on = graph.surface_at(lf.x, lf.z, lf.y).object_index
	var r := graph.step_tracked(lf, Vector2(ln.x - lf.x, ln.z - lf.z), on, false)
	st["on"] = r.standing_on
	st["graph"] = graph
	var w := xf * r.position
	st["pos"] = Vector2(w.x, w.z)
	if r.blocked:
		st["moving"] = false
		return true
	return false
