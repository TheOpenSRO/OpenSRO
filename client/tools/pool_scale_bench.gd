extends SceneTree

## Round 761: which GDScript constructs slow down when 5 WorkerThreadPool
## threads run them at once -- each mode's loop 5 times on the main thread,
## then once on each of 5 pool threads; prints the speed-up (5 is perfect).
## On the box's Godot 4.7.2 (an editor build) plain arithmetic, a Vector3 /
## Basis and a PackedFloat32Array scale (3.8-4.6) while every GDScript
## function call -- static or not, own script or another's -- and every
## object created do not (0.4-1.4): docs/rounds/r761.md.
##   godot --headless --path <client> --script res://tools/pool_scale_bench.gd

class Blob:
	var a := 0
	var b := Vector3.ZERO

var mode := ""
static var sv := 3

static func own_i32(v: int) -> int:
	return ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000

func inst_i32(v: int) -> int:
	return ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000
var iters := 200000

func work(_i: int) -> void:
	var acc := 0
	match mode:
		"arith":
			for k in range(iters):
				acc += ((k * 7 + 0x80000000) & 0xFFFFFFFF) - 0x80000000
		"static_other":
			for k in range(iters):
				acc += EfpReader.i32(k * 7)
		"f32":
			for k in range(iters / 4):
				acc += int(EfpReader.f32(float(k) * 0.3))
		"new_inner":
			for k in range(iters / 4):
				var o := Blob.new()
				o.a = k
				acc += o.a
		"new_particle":
			for k in range(iters / 4):
				var o := EfpSim.Particle.new()
				o.age = k
				acc += o.age
		"vec":
			var v := Vector3.ONE
			var bs := Basis.IDENTITY
			for k in range(iters / 4):
				v = bs * v + Vector3(0.1, 0.2, 0.3)
			acc += int(v.x)
		"static_self":
			for k in range(iters):
				acc += own_i32(k * 7)
		"inst_call":
			for k in range(iters):
				acc += inst_i32(k * 7)
		"static_var_self":
			for k in range(iters):
				acc += sv + k
		"pfa":
			var a := PackedFloat32Array([0.0])
			for k in range(iters / 4):
				a[0] = float(k) * 0.3
				acc += int(a[0])
		"static_var":
			for k in range(iters):
				acc += EfpSim.interval_mul + k
		"array_obj":
			var arr: Array = []
			for k in range(64):
				arr.append(Blob.new())
			for k in range(iters):
				var o: Blob = arr[k & 63]
				acc += o.a
	if acc == 12345678:
		print("x")

func _initialize() -> void:
	for m in ["arith", "vec", "pfa", "static_var_self", "static_var", "static_self", "inst_call", "static_other", "f32", "array_obj", "new_inner", "new_particle"]:
		mode = m
		var t0 := Time.get_ticks_usec()
		for i in range(5):
			work(i)
		var serial := Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		var g := WorkerThreadPool.add_group_task(work, 5, 5, true)
		WorkerThreadPool.wait_for_group_task_completion(g) # pool-wait: resource-free (bench)
		var par := Time.get_ticks_usec() - t0
		print("SCALE %-14s serial %7.1f ms  5 threads %7.1f ms  speedup %.2f" % [m, serial / 1000.0, par / 1000.0, float(serial) / par])
	quit()
