extends SceneTree

## Profile (round 734): where a worn item's kept particle effect spends its
## frame. Dresses N bodies through CharacterAppearance with the loadout given,
## sways each body's hands every frame as an idle animation does (so the
## effects' hosts move, as in the world), runs F frames and prints
## EfpEffect.prof per frame: placement, simulation, MultiMesh writes, and the
## engine's own process time.
##   tools/xwl_run.sh godot --rendering-method forward_plus --rendering-driver vulkan \
##     --fixed-fps 60 --path client --script res://tools/profile_equip_fx.gd -- \
##     --pk2dir=/opt/sro-files/client --bodies=20 --frames=600 --loadout='6=101+13,7=281+13'

var _bodies: Array = []
var _frames := 600
var _frame := 0
var _proc := 0.0

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

func _initialize() -> void:
	var dir := _arg("--pk2dir", "")
	var data := Pk2Reader.open(dir.path_join("Data.pk2"))
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var app := CharacterAppearance.from_archives(data, media)
	app.particles = Pk2Reader.open(dir.path_join("Particles.pk2"))
	_frames = int(_arg("--frames", "600"))
	var lo := EquipGlow.parse_loadout(_arg("--loadout", "6=101+13,7=281+13"))
	var items: Array = []
	for slot in lo[0]:
		items.append({"id": lo[0][slot], "plus": int((lo[1] as Dictionary).get(slot, 0))})
	await process_frame
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	root.add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.look_at_from_position(Vector3(0, 30, -120), Vector3(0, 10, 0))
	cam.current = true
	var n := int(_arg("--bodies", "20"))
	for i in n:
		var b := app.build(1907, CharacterAppearance.DEFAULT_SCALE, items)
		b.position = Vector3((i % 10 - 4.5) * 14.0, 0, (i / 10) * 22.0)
		vp.add_child(b)
		_bodies.append(b)
	var fx := 0
	var parts := 0
	await process_frame
	for b in _bodies:
		for e in (b as Node).find_children("*", "EfpEffect", true, false):
			fx += 1
	print("FXPROF %d bodies, %d effects" % [n, fx])
	EfpEffect.profile = true

func _process(delta: float) -> bool:
	if not EfpEffect.profile:
		return false
	_frame += 1
	var t := float(_frame) * 0.1
	for b in _bodies:
		var sk: Skeleton3D = (b as CharacterAppearance.Body).skeleton
		for nm in ["Bip01 R Hand", "Bip01 L Hand", "Bip01 R Forearm", "Bip01 L Forearm"]:
			var i := sk.find_bone(nm)
			if i >= 0:
				sk.set_bone_pose_rotation(i, sk.get_bone_rest(i).basis.get_rotation_quaternion() * Quaternion(Vector3.UP, 0.05 * sin(t)))
	_proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	if _frame == 60:
		for k in EfpEffect.prof:
			EfpEffect.prof[k] = 0
		_proc = 0.0
	if _frame == _frames + 60:
		var f := float(_frames)
		var p := EfpEffect.prof
		var parts := 0
		for b in _bodies:
			for e in (b as Node).find_children("*", "EfpEffect", true, false):
				parts += (e as EfpEffect).sim.particles.size() if (e as EfpEffect).sim != null else 0
		print("FXPROF per frame over %d frames: driver %.3f ms, place %.3f ms, sim %.3f ms, draws %.3f ms (%.1f updates a frame), steps %.2f a frame, moved %.1f a frame; process %.3f ms; live particles now %d" % [
			_frames, float(p.get("driver", 0)) / f / 1000.0, p["place"] / f / 1000.0, p["sim"] / f / 1000.0, p["draws"] / f / 1000.0, p["draw_calls"] / f,
			p["steps"] / f, p["moved"] / f, _proc / f, parts])
		quit(0)
	return false
