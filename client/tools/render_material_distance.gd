extends SceneTree
## Dev tool (round 625-626 material review follow-up; from the review's own
## probe): renders a .bsr through ObjectLoader in
## three variants -- "now" (the merged rule), "test" (the same plan with the
## MTRL blend dropped: the mod's alpha test only, foliage shader), and
## "argfix" (the mod material with every D3DTA arg set, including 0/DIFFUSE)
## -- from several yaws, and prints per-frame tree-pixel stats.
## --pk2=Data.pk2 --bsr=path --out=dir --dist=n --height=n

var _arch: Pk2Reader
var _paths: PackedStringArray
var _out := ""
var _dist := 30.0
var _h := 10.0
var _jobs: Array = []
var _job := -1
var _wait := 0
var _cam: Camera3D
var _holder: Node3D
var _bg := Color(0.45, 0.62, 0.85)

func _arg(flag: String, d: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return d

func _initialize() -> void:
	_arch = Pk2Reader.open(_arg("--pk2"))
	_paths = _arg("--bsr").split(";")
	_out = _arg("--out")
	_dist = float(_arg("--dist", "30"))
	_h = float(_arg("--height", "10"))
	DirAccess.make_dir_recursive_absolute(_out)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = _bg
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	_cam = Camera3D.new()
	root.add_child(_cam)
	_holder = Node3D.new()
	root.add_child(_holder)
	for p in _paths:
		for v in _arg("--variants", "now,test,argfix").split(","):
			for yaw in [0]:
				_jobs.append([p, v, yaw])

func _build(path: String, variant: String) -> Node3D:
	var prepared := ObjectLoader.prepare_object(_arch, path)
	var rules := []
	_collect(prepared["root"], variant, rules)
	var node := ObjectLoader.commit_object(prepared, {})
	if variant == "argfix":
		var i := 0
		for mi in _meshes(node):
			var m = mi.material_override
			while m is ShaderMaterial:
				if (m as ShaderMaterial).shader.code.find("An MTRL mod") >= 0 and i < rules.size():
					var r: Dictionary = rules[i]
					for k in ["color_op", "color_arg1", "color_arg2", "alpha_op", "alpha_arg1", "alpha_arg2"]:
						if int(r[k]) != 0 or k.ends_with("arg1") or k.ends_with("arg2"):
							m.set_shader_parameter(k, int(r[k]))
				m = m.next_pass
			i += 1
	return node

func _collect(n, variant: String, rules: Array) -> void:
	if n == null:
		return
	if n["kind"] == "cpd":
		for c in n["children"]:
			_collect(c, variant, rules)
		return
	for piece in n["pieces"]:
		var plan = piece["material"]
		if plan == null:
			rules.append({})
			continue
		var rule: Dictionary = plan.get("rule", {})
		rules.append(rule.duplicate())
		if variant == "test" and rule.get("blend", "") != "":
			rule["blend"] = ""
			plan["two_sided"] = rule["two_sided"]

func _meshes(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_meshes(c))
	return out

func _process(_d: float) -> bool:
	if _wait > 0:
		_wait -= 1
		if _wait == 0:
			_shoot()
		return false
	_job += 1
	if _job >= _jobs.size():
		quit(0)
		return true
	var j: Array = _jobs[_job]
	for c in _holder.get_children():
		c.queue_free()
	var n := _build(j[0], j[1])
	if n == null:
		print("RV null ", j[0])
		return false
	_holder.add_child(n)
	var aabb := AABB()
	var first := true
	for mi in _meshes(n):
		var b: AABB = mi.get_aabb()
		aabb = b if first else aabb.merge(b)
		first = false
	var c := aabb.get_center()
	var r := aabb.size.length() * 0.75 * float(_arg("--scale", "1"))
	var yaw := deg_to_rad(float(j[2]))
	_cam.position = c + Vector3(sin(yaw) * r, aabb.size.y * 0.1, cos(yaw) * r)
	_cam.look_at(c, Vector3.UP)
	_wait = 4
	return false

func _shoot() -> void:
	var j: Array = _jobs[_job]
	var img := root.get_viewport().get_texture().get_image()
	var name := "%s_%s_%d_s%s" % [String(j[0]).get_file().get_basename(), j[1], j[2], _arg("--scale", "1")]
	img.save_png(_out + "/" + name + ".png")
	var n := 0
	var sum := Vector3()
	var dark := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var p := img.get_pixel(x, y)
			if absf(p.r - _bg.r) + absf(p.g - _bg.g) + absf(p.b - _bg.b) < 0.03:
				continue
			n += 1
			sum += Vector3(p.r, p.g, p.b)
			if p.get_luminance() < 0.12:
				dark += 1
	var mean := sum / maxf(n, 1)
	print("RV %s pixels=%d mean=(%.3f,%.3f,%.3f) dark<0.12=%.3f" % [name, n, mean.x, mean.y, mean.z, float(dark) / maxf(n, 1)])
