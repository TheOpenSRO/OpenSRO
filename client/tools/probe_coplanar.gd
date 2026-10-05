extends SceneTree

## Dev tool (round 729): how far a model's overlay meshes (windows, doors,
## dark insets) stand off the structural surface behind them, measured from
## the meshes' own triangles -- the separation the depth buffer has to tell
## apart, which decides whether two layers z-fight.
##
## For every triangle of an overlay mesh it finds the structural triangles
## that are parallel (|n.n'| > 0.999), within --max units along the normal,
## and overlapping in the plane (the overlay triangle's centroid inside the
## structural triangle), and keeps the nearest separation. Prints, per
## overlay mesh, how many of its triangles have a structural twin and the
## min / median / max separation.
##
## Usage (the render box):
##   godot4 --headless --path client --script res://tools/probe_coplanar.gd -- \
##     --pk2=/path/Data.pk2 --dir='Prim\Mesh\Bldg\...\minga' --model=alex_minga02 \
##     --overlay=window,window_alpha,dark,dark01,door01,door02,door03 [--max=2.0]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _tris(mesh: BmsReader.ParsedMesh) -> Array:
	var p := mesh.positions()
	var idx := mesh.indices
	var out: Array = []
	for t in range(0, idx.size() - 2, 3):
		var a := p[idx[t]]
		var b := p[idx[t + 1]]
		var c := p[idx[t + 2]]
		var n := (b - a).cross(c - a)
		if n.length() < 1e-6:
			continue
		n = n.normalized()
		out.append({"a": a, "b": b, "c": c, "n": n, "d": n.dot(a), "g": (a + b + c) / 3.0})
	return out

## Whether point q (on t's plane) lies inside triangle t (barycentric).
func _inside(t: Dictionary, q: Vector3) -> bool:
	var a: Vector3 = t["a"]
	var v0: Vector3 = t["c"] - a
	var v1: Vector3 = t["b"] - a
	var v2: Vector3 = q - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-9:
		return false
	var v := (d11 * d20 - d01 * d21) / den
	var w := (d00 * d21 - d01 * d20) / den
	return v >= -0.001 and w >= -0.001 and v + w <= 1.001

func _init() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	# The default is alex_minga02's folder (the user's Alexandria building); a
	# path with spaces does not survive remote_godot.sh's ssh quoting, so
	# --dir takes "|" for a space.
	var dir := _arg("--dir").replace("|", " ")
	if dir == "":
		dir = "Prim\\Mesh\\Bldg\\north africa\\alexandria\\minga"
	var model := _arg("--model")
	var overlays := _arg("--overlay").split(",", false)
	var max_sep := float(_arg("--max")) if _arg("--max") != "" else 2.0
	var structural := ["wall01", "wall02", "wall03", "wall04", "wall05", "wall07", "wall08",
		"arch01", "arch02", "arch03", "column01", "column02", "bottom", "roof", "inside01", "inside03"]
	var struct_tris: Array = []
	for s in structural:
		var e := ObjectLoader.find_file(data, "%s\\%s_%s.bms" % [dir, model, s])
		if e == null:
			continue
		var m := BmsReader.parse(data.read_file(e))
		if m != null:
			for t in _tris(m):
				t["mesh"] = s
				struct_tris.append(t)
	print("PROBE structural triangles: %d" % struct_tris.size())
	for o in overlays:
		var e := ObjectLoader.find_file(data, "%s\\%s_%s.bms" % [dir, model, o])
		if e == null:
			print("PROBE %s: not found" % o)
			continue
		var m := BmsReader.parse(data.read_file(e))
		var tris := _tris(m)
		var seps: Array = []
		var against := {}
		for t in tris:
			var best := INF
			var best_mesh := ""
			for s in struct_tris:
				if absf((t["n"] as Vector3).dot(s["n"])) < 0.999:
					continue
				var sep := absf((s["n"] as Vector3).dot(t["g"]) - float(s["d"]))
				if sep > max_sep or sep >= best:
					continue
				var q: Vector3 = t["g"] - (s["n"] as Vector3) * ((s["n"] as Vector3).dot(t["g"]) - float(s["d"]))
				if _inside(s, q):
					best = sep
					best_mesh = s["mesh"]
			if best < INF:
				seps.append(best)
				against[best_mesh] = int(against.get(best_mesh, 0)) + 1
		seps.sort()
		if seps.is_empty():
			print("PROBE %s: %d triangle(s), none within %.2f of a parallel structural face" % [o, tris.size(), max_sep])
		else:
			print("PROBE %s: %d/%d triangle(s) over a structural face; separation min %.4f median %.4f max %.4f; against %s" % [
				o, seps.size(), tris.size(), seps[0], seps[seps.size() / 2], seps[seps.size() - 1], str(against)])
	quit()
