extends SceneTree

## Round 746: what a crowd of glowing weapons costs the CPU per frame, split
## by EquipFx's paths. Dresses N bodies through CharacterAppearance with the
## loadout, sways their hands (the hosts move, as in an idle), runs F frames
## and prints the engine's process time a frame and EfpEffect.profile's
## parts -- once with EquipFx.OWN_BUDGET as given, once with 0 (no own
## simulations), so the own-simulation cost is the difference. Headless (the
## draw cost is not here: perf_gate measures that):
##   remote_godot.sh script res://tools/profile_equip_crowd.gd -- --pk2dir=/opt/sro-files/client \
##     --bodies=200 --frames=300 --loadout='6=4118+9' --own=4

var _bodies: Array = []
var _frame := 0
var _frames := 300
var _proc := 0.0
var _pass := 0
var _owns := [4, 0]
var _app: CharacterAppearance
var _items: Array = []
var _vp: SubViewport

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _initialize() -> void:
	var dir := _arg("--pk2dir", "/opt/sro-files/client")
	_app = CharacterAppearance.from_archives(Pk2Reader.open(dir.path_join("Data.pk2")), Pk2Reader.open(dir.path_join("Media.pk2")))
	_app.particles = Pk2Reader.open(dir.path_join("Particles.pk2"))
	_frames = int(_arg("--frames", "300"))
	_owns = [int(_arg("--own", "4"))]
	var lo := EquipGlow.parse_loadout(_arg("--loadout", "6=4118+9"))
	for slot in lo[0]:
		_items.append({"id": lo[0][slot], "plus": int((lo[1] as Dictionary).get(slot, 0))})
	await process_frame
	_start_pass()

func _start_pass() -> void:
	EquipFx.OWN_BUDGET = int(_owns[_pass])
	if _vp != null:
		_vp.free()
	_bodies.clear()
	_vp = SubViewport.new()
	_vp.size = Vector2i(640, 360)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	root.add_child(_vp)
	var cam := Camera3D.new()
	_vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 60, -60), Vector3(0, 0, 80))
	cam.current = true
	var n := int(_arg("--bodies", "200"))
	for i in n:
		var b := _app.build(1907, CharacterAppearance.DEFAULT_SCALE, _items)
		b.position = Vector3((i % 20 - 9.5) * 14.0, 0, (i / 20) * 22.0)
		_vp.add_child(b)
		_bodies.append(b)
	_frame = 0
	_proc = 0.0
	for k in EfpEffect.prof:
		EfpEffect.prof[k] = 0
	EfpEffect.profile = true

func _process(_delta: float) -> bool:
	if _bodies.is_empty():
		return false
	_frame += 1
	var t := float(_frame) * 0.1
	for b in _bodies:
		var sk: Skeleton3D = (b as CharacterAppearance.Body).skeleton
		for nm in ["Bip01 R Hand", "Bip01 L Hand"]:
			var i := sk.find_bone(nm)
			if i >= 0:
				sk.set_bone_pose_rotation(i, sk.get_bone_rest(i).basis.get_rotation_quaternion() * Quaternion(Vector3.UP, 0.05 * sin(t)))
	if _frame == 60:
		for k in EfpEffect.prof:
			EfpEffect.prof[k] = 0
		_proc = 0.0
	elif _frame > 60:
		_proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	if _frame == _frames + 60:
		var f := float(_frames)
		var p := EfpEffect.prof
		var d := EquipFx.driver_for(_vp)
		print("CROWDPROF own %d: process %.3f ms a frame; driver %.3f, own effects: place %.3f, sim %.3f, draws %.3f (%.1f updates), links in draws; shown %d holders on %d weapons, %d own" % [
			EquipFx.OWN_BUDGET, _proc / f, float(p.get("driver", 0)) / f / 1000.0, p["place"] / f / 1000.0, p["sim"] / f / 1000.0,
			p["draws"] / f / 1000.0, p["draw_calls"] / f, int(d.stats.get("shown", 0)), int(d.stats.get("weapons", 0)), int(d.stats.get("own", 0))])
		_pass += 1
		if _pass >= _owns.size():
			quit(0)
		else:
			_start_pass()
	return false
