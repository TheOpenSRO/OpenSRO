extends Node

## Round 678's review: the process's resident memory through Login and into
## the world, so a front-end that leaves memory behind shows as a number.
## Instances res://scenes/Login.tscn (unless MEASURE_SKIP_LOGIN=1), lets it
## run MEASURE_LOGIN_S seconds (default 8), frees it, then instances
## res://scenes/World3D.tscn (an offline QA entry: OPENSRO_MAPM_PATH names the
## centre) and samples VmRSS and Godot's own counters every 2 s for
## MEASURE_WORLD_S seconds (default 40). Runs against any revision with those
## scenes. OURS.
##
##   xvfb-run godot --path client res://tools/measure_rss.tscn

var _t0 := 0
var _phase := "login"
var _login: Node = null
var _world: Node = null
var _next_sample := 0.0

static func rss_mb() -> float:
	# /proc files report a length of 0 to FileAccess; ask grep.
	var out: Array = []
	OS.execute("grep", ["VmRSS", "/proc/%d/status" % OS.get_process_id()], out)
	if out.is_empty():
		return -1.0
	var parts := str(out[0]).split(":")
	if parts.size() < 2:
		return -1.0
	return float(parts[1].strip_edges().split(" ")[0]) / 1024.0

func _sample(tag: String) -> void:
	print("MEASURE rss %s t=%.1f s: VmRSS %.1f MB, static %.1f MB, objects %d, video %.1f MB" % [
		tag, (Time.get_ticks_msec() - _t0) / 1000.0, rss_mb(), OS.get_static_memory_usage() / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])

func _ready() -> void:
	_t0 = Time.get_ticks_msec()
	_sample("start")
	if OS.get_environment("MEASURE_SKIP_LOGIN") == "1":
		_to_world()
		return
	_login = (load("res://scenes/Login.tscn") as PackedScene).instantiate()
	add_child(_login)

func _to_world() -> void:
	if _login != null:
		_sample("login end")
		_login.queue_free()
		_login = null
	await get_tree().process_frame
	await get_tree().process_frame
	_sample("login freed")
	_phase = "world"
	_world = (load("res://scenes/World3D.tscn") as PackedScene).instantiate()
	add_child(_world)
	_next_sample = (Time.get_ticks_msec() - _t0) / 1000.0 + 2.0

func _process(_d: float) -> void:
	var t := (Time.get_ticks_msec() - _t0) / 1000.0
	var login_s := float(OS.get_environment("MEASURE_LOGIN_S")) if OS.get_environment("MEASURE_LOGIN_S") != "" else 8.0
	var world_s := float(OS.get_environment("MEASURE_WORLD_S")) if OS.get_environment("MEASURE_WORLD_S") != "" else 40.0
	if _phase == "login" and _login != null and t >= login_s:
		_phase = "switching"
		_to_world()
	elif _phase == "world":
		if t >= _next_sample:
			_next_sample += 4.0
			_sample("world")
		if t >= login_s + world_s:
			_sample("end")
			get_tree().quit()
