extends SceneTree

## Measurement (round 676): a real monster appearing, drawn by the GL
## Compatibility renderer, and how much of it is on screen each frame.
##
## A species' model is assembled from the player's own Data.pk2 (the
## monster path's SkinnedBsrAssembler), held still in its rest pose, and
## added in front of a plain background; AppearFade.Fades fades it in with a
## fixed 1/60 s step, as World3D does each frame. Every drawn frame is read
## back. The measured coverage of frame k is
##
##   sum over the model's pixels of |frame_k - background|
##   / sum over the same pixels of |opaque - background|
##
## (the model's pixels: where the last, opaque frame differs from the
## background by more than 8 of 255 in any channel). It is what fraction of
## the model the frame shows -- 0 before the monster, 1 when it is opaque --
## printed beside the alpha AppearFade asked for, alpha_at / 255, and the
## alpha the model's first piece is drawn with (its twin's).
## --nofade adds the model with no fade: the pop this round removes.
##
## Usage (render box only, windowed -- the headless renderer draws nothing):
##   xvfb-run -a -s "-screen 0 320x240x24" vglrun -d egl0 godot \
##     --rendering-driver opengl3 --resolution 320x240 --path <client> \
##     --script res://tools/measure_appear_fade.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 \
##     [--code=MOB_CH_MANGNYANG | --model=mob\\china\\mangnyang.bsr] [--nofade] [--save=<last frame .png>]
##
## --census instead assembles every model a `MOB_` row names and counts its
## surfaces' materials by kind, and how many have no fade twin
## (AppearFade.fade_twin returns null: that piece would pop in).

const STEP := 1.0 / 60.0
const BEFORE_FRAMES := 3
const AFTER_SECONDS := 2.5
const MASK_THRESHOLD := 8

var _model: Node3D
var _fades := AppearFade.Fades.new()
var _frames: Array[Image] = []
var _alphas: Array[int] = []
var _transp: Array[float] = []
var _added_at := -1
var _elapsed := 0.0
var _nofade := false
var _frame := 0
var _done := false
var _shaders := {}

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _initialize() -> void:
	_nofade = OS.get_cmdline_user_args().has("--nofade")
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> [--code=MOB_CH_...] [--nofade]")
		quit(2)
		return
	var code := _arg("--code")
	if code == "":
		code = "MOB_CH_MANGNYANG"
	var models := {}
	var orgs := {}
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry == null:
			continue
		var bytes := media.read_file(entry)
		models = NpcTableReader.parse_models_by_code(bytes, models, "")
		orgs = NpcTableReader.parse_org_codes(bytes, orgs)
	if OS.get_cmdline_user_args().has("--census"):
		_census(data, models)
		quit(0)
		return
	var model_path := NpcTableReader.model_with_org(code, models, orgs)
	if _arg("--model") != "":
		model_path = _arg("--model")
		code = model_path.get_file()
	var assembled := SkinnedBsrAssembler.assemble_from_archive(data, model_path, true) if model_path != "" else null
	if assembled == null:
		printerr("MEASURE %s: no model (%s)" % [code, model_path])
		quit(2)
		return
	_model = assembled.skeleton
	var height := maxf(MonsterDraw.label_height(_model), 1.0)
	print("MEASURE %s -> %s, %d meshes, %.1f tall, %s" % [code, model_path,
		AppearFade.instances_of(_model).size(), height, "NO fade (the pop)" if _nofade else "AppearFade"])

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.25, 0.45, 0.65)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.6)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.look_at_from_position(Vector3(0.0, height * 0.5, height * 2.2), Vector3(0.0, height * 0.5, 0.0))
	cam.current = true
	root.add_child(cam)
	RenderingServer.frame_post_draw.connect(_on_drawn)

func _process(_delta: float) -> bool:
	if _done:
		return true
	if _frame == BEFORE_FRAMES:
		for mi in AppearFade.instances_of(_model):
			var m := mi.material_override
			_shaders[mi.get_instance_id()] = (m as ShaderMaterial).shader if m is ShaderMaterial else null
		root.add_child(_model)
		_added_at = _frame
		if not _nofade:
			_fades.start(_model)
	elif _added_at >= 0:
		_elapsed += STEP
		_fades.step(STEP)
	return false

func _on_drawn() -> void:
	if _done:
		return
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	_frames.append(img)
	var a := -1
	var t := -1.0
	if _added_at >= 0:
		a = 255 if _nofade else (AppearFade.alpha_at(_elapsed) if _fades.running() > 0 else 255)
		var mis := AppearFade.instances_of(_model)
		t = -1.0
		if not mis.is_empty():
			var m := mis[0].material_override
			if m is ShaderMaterial and (m as ShaderMaterial).get_shader_parameter("appear_alpha") != null:
				t = float((m as ShaderMaterial).get_shader_parameter("appear_alpha"))
			elif m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				t = (m as BaseMaterial3D).albedo_color.a
			else:
				t = 1.0
	_alphas.append(a)
	_transp.append(t)
	_frame += 1
	if _added_at >= 0 and _elapsed >= AFTER_SECONDS:
		_done = true
		_report()
		quit(0)

func _report() -> void:
	var bg: Image = _frames[BEFORE_FRAMES - 1]
	var last: Image = _frames[_frames.size() - 1]
	# --save=<png>: the last frame, to diff a fade's end against --nofade's.
	if _arg("--save") != "":
		last.save_png(_arg("--save"))
	var w := bg.get_width()
	var h := bg.get_height()
	var mask: Array[Vector2i] = []
	var full := 0.0
	for y in range(h):
		for x in range(w):
			var b := bg.get_pixel(x, y)
			var o := last.get_pixel(x, y)
			var d := maxf(maxf(absf(o.r - b.r), absf(o.g - b.g)), absf(o.b - b.b)) * 255.0
			if d > MASK_THRESHOLD:
				mask.append(Vector2i(x, y))
				full += absf(o.r - b.r) + absf(o.g - b.g) + absf(o.b - b.b)
	print("MEASURE model pixels: %d of %d (%.1f%%), opaque difference %.1f" % [mask.size(), w * h, 100.0 * mask.size() / (w * h), full])
	if mask.is_empty() or full <= 0.0:
		print("MEASURE FAIL: the model drew no pixels")
		return
	var worst := 0.0
	for k in range(BEFORE_FRAMES - 1, _frames.size()):
		var f: Image = _frames[k]
		var s := 0.0
		for p in mask:
			var b := bg.get_pixel(p.x, p.y)
			var c := f.get_pixel(p.x, p.y)
			s += absf(c.r - b.r) + absf(c.g - b.g) + absf(c.b - b.b)
		var cover := s / full
		var asked := float(_alphas[k]) / 255.0 if _alphas[k] >= 0 else 0.0
		worst = maxf(worst, absf(cover - asked))
		var t := (k - BEFORE_FRAMES) * STEP if k >= BEFORE_FRAMES else 0.0
		print("MEASURE frame %3d t=%.3f asked alpha %3d (%.3f) drawn alpha %.3f -> covered %.3f" % [
			k, t, maxi(_alphas[k], 0), asked, _transp[k], cover])
	var opaque_back := true
	for mi in AppearFade.instances_of(_model):
		if mi.has_meta(AppearFade.ORIGINAL_META) or (mi.material_override is BaseMaterial3D and (mi.material_override as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED) \
				or (mi.material_override is ShaderMaterial and (mi.material_override as ShaderMaterial).shader != _shaders[mi.get_instance_id()]):
			opaque_back = false
	print("MEASURE worst |covered - asked| = %.3f over %d frames; fades running at the end: %d; own materials back: %s; unfadable pieces: %d" % [
		worst, _frames.size(), _fades.running(), opaque_back, _fades.unfadable()])

func _census(data: Pk2Reader, models: Dictionary) -> void:
	var paths := {}
	for code in models:
		if String(code).begins_with("MOB_"):
			paths[models[code]] = true
	var keys := paths.keys()
	keys.sort()
	var kinds := {}
	var no_twin := 0
	var assembled := 0
	for p in keys:
		var a := SkinnedBsrAssembler.assemble_from_archive(data, String(p), true)
		if a == null:
			continue
		assembled += 1
		for mi in AppearFade.instances_of(a.skeleton):
			if mi.mesh == null:
				continue
			for s in range(mi.mesh.get_surface_count()):
				var m := mi.get_active_material(s)
				var k := "none"
				if m is ShaderMaterial:
					var sh := (m as ShaderMaterial).shader
					k = sh.resource_path.get_file() if sh != null and sh.resource_path != "" else "MTRL mod shader"
				elif m != null:
					k = m.get_class()
				kinds[k] = int(kinds.get(k, 0)) + 1
				if m == null or AppearFade.fade_twin(m) == null:
					no_twin += 1
		a.skeleton.free()
	print("CENSUS %d monster models assembled (of %d the MOB_ rows name): surfaces by material %s; with no fade twin: %d" % [
		assembled, keys.size(), str(kinds), no_twin])
