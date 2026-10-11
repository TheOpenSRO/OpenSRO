extends SceneTree

## Dev tool (round 778): every place a dungeon's walk stops a mover at a room's
## outline although the floor goes on -- the "invisible wall" census. For each
## room's open outline edge (no 0x02/0x10, so the in-object walk calls it an
## exit) it samples points along the edge, pushes each CONTACT_PUSH outward
## and asks the graph's seam hand-off for a room there at the edge's height,
## as `NavGraph.step_tracked` does. A miss is a wall. Each miss is then
## classed by what lies a little further out: another room's surface within
## `--reach` in plan and SURFACE_REACH_UP in height (a seam gap: the floor
## goes on, OURS stops), a surface at another height (a step), or nothing (the
## dungeon's edge). Prints counts and dungeon-space positions only:
##   godot --headless --path client --script res://tools/dungeon_wall_census.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --rid=32773 [--reach=4] [--list=40] [--near=x,z,r]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2", "/opt/sro-files/client/Data.pk2"))
	if data == null:
		printerr("no Data.pk2")
		quit(1)
		return
	var reach := float(_arg("--reach", "4"))
	var list := int(_arg("--list", "40"))
	var near := _arg("--near", "")
	var near_p := Vector2.INF
	var near_r := 0.0
	if near != "":
		var parts := near.split(",")
		near_p = Vector2(float(parts[0]), float(parts[1]))
		near_r = float(parts[2])
	for tok in _arg("--rid", "32773").split(",", false):
		_census(data, int(tok), reach, list, near_p, near_r)
	quit(0)

func _census(data: Pk2Reader, rid: int, reach: float, list: int, near_p: Vector2, near_r: float) -> void:
	var built := DungeonWorld.build(data, rid)
	if built == null:
		print("WALL 0x%x: no dungeon" % rid)
		return
	var g := built.graph
	if _arg("--nostitch", "") == "1":
		g.dungeon_links.clear()
	var counts := {"exit_edges": 0, "samples": 0, "ok": 0, "gap": 0, "step": 0, "edge": 0}
	var by_flags := {}
	var gaps: Array = []
	var hist := {}
	var walls: Array = []
	var reasons := {}
	var gap_rooms := {}
	var by_room := {}
	var seen_edges := {}
	for oi in g.objects:
		var po: NavGraph.PlacedObject = g.objects[oi]
		for e in po.edge_flags.size():
			if po.edge_outline[e] == 0:
				continue
			var flags := po.edge_flags[e]
			by_flags[flags] = int(by_flags.get(flags, 0)) + 1
			if (flags & (NavGraph.EDGE_BLOCKS_FROM_INSIDE | NavGraph.EDGE_IGNORED_FROM_OUTSIDE)) != 0:
				continue
			counts["exit_edges"] += 1
			var a: Vector2 = po.edges[e * 2]
			var b: Vector2 = po.edges[e * 2 + 1]
			var inside: Vector2 = po.edge_inside[e]
			var along := b - a
			if along.length() < 1.0e-4:
				continue
			var n := Vector2(-along.y, along.x).normalized()
			if n.dot(inside - a) > 0.0:
				n = -n
			var ya := po.vertices[po.edge_v0[e]].y
			var yb := po.vertices[po.edge_v1[e]].y
			var steps := maxi(2, int(along.length() / 5.0))
			for s in range(1, steps):
				var t := float(s) / float(steps)
				var p := a + along * t
				var y := lerpf(ya, yb, t)
				counts["samples"] += 1
				# The real step: from half a unit inside, straight out across
				# the edge, as a player walks.
				var start := p - n * 0.5
				var sy := NavGraph._surface_near(po, start.x, start.y, y)
				if not is_nan(sy):
					var st := g.step_tracked(Vector3(start.x, sy, start.y), n * 1.5, oi)
					counts["walked"] = int(counts.get("walked", 0)) + 1
					if st.blocked or st.standing_on == oi:
						counts["walk_stopped"] = int(counts.get("walk_stopped", 0)) + 1
						var key := Vector2i(oi, e)
						var rb: DofReader.Block = built.dof.blocks[oi]
						var rname: String = built.dof.room_names[rb.room_index] if rb.room_index >= 0 and rb.room_index < built.dof.room_names.size() else "?"
						by_room[rname] = int(by_room.get(rname, 0)) + 1
						var why := "stitched" if g.dungeon_links.has(key) else _nearest_linked(g, oi, e, built.dof.blocks[oi].neighbours)
						reasons[why.get_slice(" ", 0)] = int(reasons.get(why.get_slice(" ", 0), 0)) + 1
						if why.begins_with("unstitched"):
							var beyond := "nothing within 20"
							var dd := 0.25
							while dd <= 20.0:
								var r := p + n * dd
								var hit_any := false
								for oj in g.objects_at(r.x, r.y):
									if oj == oi:
										continue
									var hh := NavGraph._surface_near(g.objects[oj], r.x, r.y, y)
									if not is_nan(hh):
										beyond = "room %d at %.2f out, height %+.1f" % [oj, dd, hh - y]
										hit_any = true
										break
								if hit_any:
									break
								dd += 0.25
							why += "; beyond: " + beyond
						if not seen_edges.has(key) and walls.size() < list:
							seen_edges[key] = true
							walls.append([oi, e, p, y, st.position, st.standing_on, why])
				var q := p + n * NavGraph.CONTACT_PUSH
				if g._seam_object_at(q.x, q.y, y, oi) != NavGraph.ON_TERRAIN:
					counts["ok"] += 1
					continue
				# Missed: what lies further out?
				var kind := "edge"
				var found := -1
				var found_h := NAN
				var d := 0.02
				while d <= reach:
					var r := p + n * d
					var o := g._seam_object_at(r.x, r.y, y, oi)
					if o != NavGraph.ON_TERRAIN:
						kind = "gap"
						found = o
						found_h = NavGraph._surface_near(g.objects[o], r.x, r.y, y)
						break
					for oj in g.objects_at(r.x, r.y):
						if oj == oi:
							continue
						var h := NavGraph._surface_near(g.objects[oj], r.x, r.y, y)
						if not is_nan(h):
							kind = "step"
							found = oj
							found_h = h
							break
					if kind != "edge":
						break
					d += 0.02 if d < 1.0 else 0.25
				counts[kind] += 1
				if kind == "gap":
					var bucket := "%.2f" % snappedf(d, 0.02) if d < 1.0 else ">=1"
					hist[bucket] = int(hist.get(bucket, 0)) + 1
				if kind == "gap" or kind == "step":
					var gb: DofReader.Block = built.dof.blocks[oi]
					var gname: String = built.dof.room_names[gb.room_index] if gb.room_index >= 0 and gb.room_index < built.dof.room_names.size() else "?"
					gap_rooms[gname] = int(gap_rooms.get(gname, 0)) + 1
					gaps.append([kind, oi, e, flags, p, y, found, found_h, d])
	print("WALL 0x%x %s: %d rooms; outline flags %s" % [rid, built.path, built.dof.blocks.size(), by_flags])
	print("WALL 0x%x: %d open outline edges, %d samples: %d hand off, %d gap (floor beyond within %.1f), %d step (another height), %d edge (nothing beyond)" % [
		rid, counts["exit_edges"], counts["samples"], counts["ok"], counts["gap"], reach, counts["step"], counts["edge"]])
	print("WALL 0x%x: %d stitched edges; walked %d samples across, %d stopped" % [rid, g.dungeon_links.size(), int(counts.get("walked", 0)), int(counts.get("walk_stopped", 0))])
	for w in walls:
		var wp: Vector2 = w[2]
		print("  stopped room %d edge %d at (%.1f, %.1f, %.1f) -> ended at %s on %d: %s" % [w[0], w[1], wp.x, w[3], wp.y, w[4], w[5], w[6]])
	print("WALL 0x%x: stopped by reason %s" % [rid, reasons])
	print("WALL 0x%x: stopped by room name %s" % [rid, by_room])
	print("WALL 0x%x: round-773 rule's gaps by room name %s" % [rid, gap_rooms])
	var keys := hist.keys()
	keys.sort()
	for k in keys:
		print("  gap %s: %d" % [k, hist[k]])
	var shown := 0
	for gp in gaps:
		var p: Vector2 = gp[4]
		if near_p != Vector2.INF and p.distance_to(near_p) > near_r:
			continue
		if shown >= list:
			break
		shown += 1
		var bi: DofReader.Block = built.dof.blocks[gp[1]]
		print("  %s room %d (%s) edge %d flags 0x%x at (%.1f, %.1f, %.1f) -> room %d at h %.1f, %.2f out" % [
			gp[0], gp[1], bi.path.get_file(), gp[2], gp[3], p.x, gp[5], p.y, gp[6], gp[7], gp[8]])

## Why a linked edge has no partner: the nearest linked outline edge of any
## other room, by the larger of its two end distances, and whether that room
## is in the block's neighbour list.
func _nearest_linked(g: NavGraph, oi: int, e: int, nbs: PackedInt32Array) -> String:
	var po: NavGraph.PlacedObject = g.objects[oi]
	if (po.edge_flags[e] & NavGraph.EDGE_LINKED) == 0:
		return "unlinked flags 0x%x" % po.edge_flags[e]
	var a0: Vector3 = po.vertices[po.edge_v0[e]]
	var a1: Vector3 = po.vertices[po.edge_v1[e]]
	var best := INF
	var best_o := -1
	for oj in g.objects:
		if oj == oi:
			continue
		var other: NavGraph.PlacedObject = g.objects[oj]
		for f in other.edge_flags.size():
			if other.edge_outline[f] == 0 or (other.edge_flags[f] & NavGraph.EDGE_LINKED) == 0:
				continue
			var b0: Vector3 = other.vertices[other.edge_v0[f]]
			var b1: Vector3 = other.vertices[other.edge_v1[f]]
			var d := minf(maxf(a0.distance_to(b0), a1.distance_to(b1)), maxf(a0.distance_to(b1), a1.distance_to(b0)))
			if d < best:
				best = d
				best_o = oj
	return "unstitched nearest room %d at %.2f (%s neighbour list), edge length %.1f" % [best_o, best, "in" if best_o in nbs else "NOT in", Vector2(a0.x, a0.z).distance_to(Vector2(a1.x, a1.z))]
