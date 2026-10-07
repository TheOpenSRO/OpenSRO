extends SceneTree
## Round 760: does the main thread's wait for pool tasks that build rendering resources deadlock?
## Round 754's `threads` probe, rebuilt: 6 pool tasks x 20 builds x ROUNDS rounds (a Node3D with a
## MeshInstance3D, an ArrayMesh, a StandardMaterial3D and a ShaderMaterial on a compiled Shader,
## an ImageTexture, a Skeleton3D, each duplicated on the worker, and the material's uniform list
## read back), the main thread waiting for them at once and then building the same, then
## everything added to the tree and drawn.
## The main thread waits for the round's tasks with WorkerThreadPool's own wait (`plain`, round
## 754: Forward+ on the default render thread hung 4 of 4) or with PoolWait (`pool`).
##
## Windowed, Forward+ (it needs a real RenderingDevice), under a time limit:
##   timeout 300 xwl_run.sh <godot> --rendering-method forward_plus --rendering-driver vulkan \
##     --path <client> --script res://tools/pool_wait_probe.gd -- --mode=plain|pool [--rounds=30]
## Prints `POOLWAIT <mode> round <i> ...` a round and `POOLWAIT <mode> DONE <s>` at the end; a
## hang shows as the last round line and no DONE.
const TASKS := 6
const BUILDS := 20
var mode := "pool"
var rounds := 30
var shader: Shader
var _out_mutex := Mutex.new()
var _made: Array = []

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			mode = a.substr(7)
		elif a.begins_with("--rounds="):
			rounds = int(a.substr(9))
	shader = Shader.new()
	shader.code = "shader_type spatial;\nuniform vec4 tint : source_color = vec4(1.0);\nuniform sampler2D tex;\nvoid fragment() { ALBEDO = tint.rgb * texture(tex, UV).rgb; }\n"
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 30)
	root.add_child(cam)
	_run.call_deferred()

func _build(seed_i: int) -> Node3D:
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(3):
		st.set_uv(Vector2(k, k % 2))
		st.add_vertex(Vector3(k, (k * 7 + seed_i) % 3, 0))
	var mesh := st.commit()
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(float(seed_i % 7) / 7.0, 0.5, 0.5))
	var tex := ImageTexture.create_from_image(img)
	var sm := ShaderMaterial.new()
	sm.shader = shader
	sm.set_shader_parameter("tex", tex)
	sm.set_shader_parameter("tint", Color(1, 0.5, 0.25))
	# A synchronous RenderingServer read: the uniform list (RS shader_get_shader_parameter_list).
	var _plist := shader.get_shader_uniform_list()
	var std := StandardMaterial3D.new()
	std.albedo_texture = tex
	mesh.surface_set_material(0, sm if seed_i % 2 == 0 else std)
	mi.mesh = mesh
	n.add_child(mi)
	var sk := Skeleton3D.new()
	sk.add_bone("a")
	n.add_child(sk)
	var copy := n.duplicate() as Node3D
	n.free()
	copy.position = Vector3(float(seed_i % 40) - 20.0, float(seed_i / 40 % 20) - 10.0, 0)
	return copy

func _task(t: int) -> void:
	var mine: Array = []
	for b in range(BUILDS):
		mine.append(_build(t * 1000 + b))
	_out_mutex.lock()
	_made.append_array(mine)
	_out_mutex.unlock()

func _run() -> void:
	var t0 := Time.get_ticks_msec()
	print("POOLWAIT %s start (%s, rounds %d)" % [mode, str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), rounds])
	for r in range(rounds):
		var ids: Array[int] = []
		for t in range(TASKS):
			ids.append(WorkerThreadPool.add_task(_task.bind(t), true, "poolwait probe"))
		# The main thread waits at once, as the game's waits do (a teardown, a build that needs
		# its template now): any RenderingServer call of its own would serve the workers' queue.
		for id in ids:
			if mode == "plain":
				WorkerThreadPool.wait_for_task_completion(id) # pool-wait: the probe's negative
			else:
				PoolWait.task(id)
		var local: Array = []
		for b in range(BUILDS):
			local.append(_build(99000 + b))
		_out_mutex.lock()
		local.append_array(_made)
		_made = []
		_out_mutex.unlock()
		for n in local:
			root.add_child(n)
		await process_frame
		await process_frame
		for n in local:
			n.queue_free()
		print("POOLWAIT %s round %d nodes %d at %d ms" % [mode, r, local.size(), Time.get_ticks_msec() - t0])
	print("POOLWAIT %s DONE %.1f s" % [mode, float(Time.get_ticks_msec() - t0) / 1000.0])
	quit()
