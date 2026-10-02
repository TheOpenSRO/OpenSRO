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
## --out (round 677) measures the way out instead: the model is added
## opaque, held OUT_HOLD_FRAMES frames, then despawned -- Fades.start_out,
## the 1.5 s CIDecoDisappear fade, after which the fade frees it; with
## --nofade it is freed at once, as before round 677. The coverage is taken
## against the last opaque frame and printed beside out_alpha_at / 255, with
## the frame the model is gone.
##
## Usage (render box only, windowed -- the headless renderer draws nothing):
##   xvfb-run -a -s "-screen 0 320x240x24" vglrun -d egl0 godot \
##     --rendering-driver opengl3 --resolution 320x240 --path <client> \
##     --script res://tools/measure_appear_fade.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2 \
##     [--code=MOB_CH_MANGNYANG | --model=mob\\china\\mangnyang.bsr] [--nofade] [--save=<last frame .png>]
##
## --instance (round 693) fades the model the select screen's way instead:
## GeometryInstance3D.transparency on every mesh instance, 1 - alpha_at / 255
## (CharSelectStage._apply_alpha), the materials untouched. GL Compatibility
## ignores that property (READ: stored by RenderGeometryInstanceBase::
## set_transparency, never read by the GLES3 renderer), Forward+ draws it --
## this measures what each renderer shows.
##
## --census instead assembles every model a `MOB_` row names (or the
## comma-separated --models=) and counts its
## surfaces' materials by kind, and how many have no fade twin
## (AppearFade.fade_twin returns null: that piece would pop in).

const STEP := 1.0 / 60.0
const BEFORE_FRAMES := 6
const AFTER_SECONDS := 2.5
const MASK_THRESHOLD := 8
const OUT_HOLD_FRAMES := 10
const OUT_AFTER_SECONDS := 2.0

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
var _usec: Array[int] = []
var _out := false
var _instance := false
## The frame the despawn starts (--out), and the first frame drawn without
## the model.
var _out_at := -1
var _gone_at := -1

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _initialize() -> void:
	_nofade = OS.get_cmdline_user_args().has("--nofade")
	_out = OS.get_cmdline_user_args().has("--out")
	_instance = OS.get_cmdline_user_args().has("--instance")
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
		AppearFade.instances_of(_model).size(), height,
		("despawn, NO fade (freed at once)" if _nofade else "despawn, AppearFade fade-out") if _out
		else ("GeometryInstance3D.transparency (the select screen's fade)" if _instance else ("NO fade (the pop)" if _nofade else "AppearFade"))])

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
	# --warm: World3D's loading-time warm-up (AppearFade.warm) in the frames
	# before the model.
	if OS.get_cmdline_user_args().has("--warm"):
		print("MEASURE warming %d fade shader(s) before the model" % AppearFade.warm(cam))
	RenderingServer.frame_post_draw.connect(_on_drawn)

func _process(_delta: float) -> bool:
	if _done:
		return true
	if _out:
		if _frame == BEFORE_FRAMES:
			root.add_child(_model)
			_added_at = _frame
		elif _frame == BEFORE_FRAMES + OUT_HOLD_FRAMES:
			_out_at = _frame
			if _nofade:
				_model.queue_free()
			else:
				_fades.start_out(_model)
		elif _out_at >= 0:
			_elapsed += STEP
			_fades.step(STEP)
		return false
	if _frame == BEFORE_FRAMES:
		for mi in AppearFade.instances_of(_model):
			var m := mi.material_override
			_shaders[mi.get_instance_id()] = (m as ShaderMaterial).shader if m is ShaderMaterial else null
		root.add_child(_model)
		_added_at = _frame
		if _instance:
			_set_instance_alpha(0)
		elif not _nofade:
			_fades.start(_model)
	elif _added_at >= 0:
		_elapsed += STEP
		if _instance:
			_set_instance_alpha(AppearFade.alpha_at(_elapsed))
		else:
			_fades.step(STEP)
	return false

func _set_instance_alpha(a: int) -> void:
	for mi in AppearFade.instances_of(_model):
		mi.transparency = clampf(1.0 - a / 255.0, 0.0, 1.0)

func _on_drawn() -> void:
	if _done:
		return
	if _out:
		_on_drawn_out()
		return
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	_frames.append(img)
	_usec.append(Time.get_ticks_usec())
	var a := -1
	var t := -1.0
	if _added_at >= 0:
		a = 255 if _nofade else (AppearFade.alpha_at(_elapsed) if _fades.running() > 0 else 255)
		var mis := AppearFade.instances_of(_model)
		t = -1.0
		if _instance:
			a = AppearFade.alpha_at(_elapsed)
			t = 1.0 - mis[0].transparency if not mis.is_empty() else -1.0
		elif not mis.is_empty():
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

func _on_drawn_out() -> void:
	var img := root.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	_frames.append(img)
	_usec.append(Time.get_ticks_usec())
	var a := -1
	var t := -1.0
	if _added_at >= 0:
		a = 255
		if _out_at >= 0:
			a = 0 if _nofade or AppearFade.out_done_at(_elapsed) else AppearFade.out_alpha_at(_elapsed)
		if is_instance_valid(_model) and not _model.is_queued_for_deletion():
			var mis := AppearFade.instances_of(_model)
			t = 1.0
			if not mis.is_empty():
				var m := mis[0].material_override
				if m is ShaderMaterial and (m as ShaderMaterial).get_shader_parameter("appear_alpha") != null:
					t = float((m as ShaderMaterial).get_shader_parameter("appear_alpha"))
				elif m is BaseMaterial3D and (m as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					t = (m as BaseMaterial3D).albedo_color.a
		elif _gone_at < 0:
			_gone_at = _frame
	_alphas.append(a)
	_transp.append(t)
	_frame += 1
	if _out_at >= 0 and _elapsed >= OUT_AFTER_SECONDS:
		_done = true
		_report_out()
		quit(0)

## The despawn's frames (--out): coverage against the last opaque frame.
func _report_out() -> void:
	var bg: Image = _frames[BEFORE_FRAMES - 1]
	var opaque: Image = _frames[_out_at - 1]
	var w := bg.get_width()
	var h := bg.get_height()
	var mask: Array[Vector2i] = []
	var full := 0.0
	for y in range(h):
		for x in range(w):
			var b := bg.get_pixel(x, y)
			var o := opaque.get_pixel(x, y)
			var d := maxf(maxf(absf(o.r - b.r), absf(o.g - b.g)), absf(o.b - b.b)) * 255.0
			if d > MASK_THRESHOLD:
				mask.append(Vector2i(x, y))
				full += absf(o.r - b.r) + absf(o.g - b.g) + absf(o.b - b.b)
	print("MEASURE OUT model pixels: %d of %d (%.1f%%), opaque difference %.1f" % [mask.size(), w * h, 100.0 * mask.size() / (w * h), full])
	if mask.is_empty() or full <= 0.0:
		print("MEASURE OUT FAIL: the model drew no pixels")
		return
	var worst := 0.0
	var last_seen := -1
	for k in range(_out_at - 1, _frames.size()):
		var f: Image = _frames[k]
		var s := 0.0
		for p in mask:
			var b := bg.get_pixel(p.x, p.y)
			var c := f.get_pixel(p.x, p.y)
			s += absf(c.r - b.r) + absf(c.g - b.g) + absf(c.b - b.b)
		var cover := s / full
		var asked := float(_alphas[k]) / 255.0
		worst = maxf(worst, absf(cover - asked))
		if cover > 0.002:
			last_seen = k
		print("MEASURE OUT frame %3d t=%.3f asked alpha %3d (%.3f) drawn alpha %.3f -> covered %.3f" % [
			k, maxf(float(k - _out_at) * STEP, 0.0), maxi(_alphas[k], 0), asked, _transp[k], cover])
	print("MEASURE OUT despawn at frame %d; the model's last frame with pixels %d (t=%.3f); the model is gone from frame %d (t=%.3f)" % [
		_out_at, last_seen, float(last_seen - _out_at) * STEP, _gone_at, float(_gone_at - _out_at) * STEP])
	print("MEASURE OUT worst |covered - asked| = %.3f over %d frames; fades running at the end: %d (freed %d); unfadable pieces: %d" % [
		worst, _frames.size() - _out_at + 1, _fades.running(), _fades.freed(), _fades.unfadable()])

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
	var at_one := BEFORE_FRAMES + int(round(1.0 / STEP))
	var at_two := BEFORE_FRAMES + int(round(AppearFade.APPEAR_SECONDS / STEP))
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
		if k == at_one:
			# Holes: model pixels showing under half the asked share of their
			# own opaque colour -- a texture alpha multiplied into the fade.
			var holes := 0
			for p in mask:
				var b := bg.get_pixel(p.x, p.y)
				var c := f.get_pixel(p.x, p.y)
				var o := last.get_pixel(p.x, p.y)
				var own := absf(o.r - b.r) + absf(o.g - b.g) + absf(o.b - b.b)
				var got := absf(c.r - b.r) + absf(c.g - b.g) + absf(c.b - b.b)
				if own > 0.0 and got / own < asked * 0.5:
					holes += 1
			print("MEASURE holes at t=%.3f: %d of %d model pixels (%.1f%%) show under half the asked alpha" % [
				t, holes, mask.size(), 100.0 * holes / mask.size()])
	# The twin at alpha 255 (the fade's last frame) against the opaque model.
	if at_two < _frames.size():
		var twin_frame: Image = _frames[at_two]
		var differ := 0
		var most := 0.0
		for p in mask:
			var c := twin_frame.get_pixel(p.x, p.y)
			var o := last.get_pixel(p.x, p.y)
			var d := maxf(maxf(absf(c.r - o.r), absf(c.g - o.g)), absf(c.b - o.b)) * 255.0
			most = maxf(most, d)
			if d > 2.0:
				differ += 1
		print("MEASURE the twin at alpha %d (frame %d) against the opaque model: %d of %d model pixels differ by more than 2/255, the most by %.0f" % [
			_alphas[at_two], at_two, differ, mask.size(), most])
	# Frame times: the first frame with the model draws its meshes, textures
	# and shaders for the first time; --nofade gives the same frame without
	# the fade's shaders.
	var first := (_usec[BEFORE_FRAMES] - _usec[BEFORE_FRAMES - 1]) / 1000.0
	var longest := 0.0
	var longest_k := -1
	for k in range(BEFORE_FRAMES, _usec.size()):
		var ms := (_usec[k] - _usec[k - 1]) / 1000.0
		if ms > longest:
			longest = ms
			longest_k = k
	var before := 0.0
	for k in range(1, BEFORE_FRAMES):
		before = maxf(before, (_usec[k] - _usec[k - 1]) / 1000.0)
	print("MEASURE frame time: the longest before the model %.1f ms; the model's first frame %.1f ms; the longest from then %.1f ms (frame %d)" % [
		before, first, longest, longest_k])
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
	if _arg("--models") != "":
		paths = {}
		for p in _arg("--models").split(",", false):
			paths[p] = true
	var keys := paths.keys()
	keys.sort()
	var kinds := {}
	var no_twin := 0
	var plain := 0
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
				if AppearFade.is_plain_standard(m):
					plain += 1
				# Texture alpha under a StandardMaterial3D: the opaque draw
				# ignores it; a blended twin that multiplied it in would not.
				if m is StandardMaterial3D and (m as StandardMaterial3D).albedo_texture != null:
					var img := (m as StandardMaterial3D).albedo_texture.get_image()
					if img != null:
						img = img.duplicate() as Image
						img.decompress()
						img.convert(Image.FORMAT_RGBA8)
						var texels := img.get_data()
						var total := 0.0
						var low := 0
						var n := texels.size() / 4
						for i in range(n):
							var av := texels[i * 4 + 3]
							total += av / 255.0
							if av < 128:
								low += 1
						if total / n < 0.999:
							print("CENSUS texture alpha %s %s: mean %.3f, %.1f%% of texels under 0.5" % [
								String(p), (m as StandardMaterial3D).albedo_texture.resource_name, total / n, 100.0 * low / n])
		a.skeleton.free()
	print("CENSUS %d models assembled (of %d): surfaces by material %s; plain StandardMaterial3D (the STANDARD_FADE_CODE twin): %d; with no fade twin: %d" % [
		assembled, keys.size(), str(kinds), plain, no_twin])
