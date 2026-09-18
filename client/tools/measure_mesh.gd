extends SceneTree
func _arg(f):
	for a in OS.get_cmdline_user_args():
		if a.begins_with(f+"="): return a.substr(f.length()+1)
	return ""
func _bounds(ar, path):
	var e = ObjectLoader.find_file(ar, path)
	if e == null: return "NOT FOUND"
	var m = BmsReader.parse(ar.read_file(e))
	if m == null: return "PARSE FAIL"
	var lo := Vector3(1e9,1e9,1e9); var hi := Vector3(-1e9,-1e9,-1e9)
	for vtx in m.vertices:
		var v: Vector3 = vtx.position
		lo.x=minf(lo.x,v.x); lo.y=minf(lo.y,v.y); lo.z=minf(lo.z,v.z)
		hi.x=maxf(hi.x,v.x); hi.y=maxf(hi.y,v.y); hi.z=maxf(hi.z,v.z)
	return "n=%d lo=%v hi=%v centre=%v skinned=%s" % [m.vertices.size(), lo.round(), hi.round(), ((lo+hi)*0.5).round(), str(m.is_skinned())]
func _initialize():
	var ar := Pk2Reader.open(_arg("--pk2"))
	for p in Array(_arg("--meshes").split(",", false)):
		print(p.get_file(), ": ", _bounds(ar, p))
	quit(0)
