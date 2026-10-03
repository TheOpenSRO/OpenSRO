extends SceneTree

## Dev tool (round 685): what one opening of the customize screen leaves
## behind. Builds a piece, lets it run, frees it, and prints the engine's
## object count and static memory after each cycle -- so a growth per cycle
## can be pinned to the piece that leaks it.
##
##   godot4 --headless --path client --script res://tools/measure_create_cycles.gd -- \
##     --mode=screen|backdrop|appearance|preview|swaps|camera [--cycles=6] [--race=china|europe]
##
## screen: CharacterCreate.tscn as the game opens it; backdrop: only its
## FrontEndBackdrop (98/168 or 105/79); appearance: CharacterAppearance built
## and a body made; preview: CharCreatePreview showing that body. Needs the
## OPENSRO_*_PK2_PATH variables like any run against real archives.
##
## swaps: the slider swap latency instead -- one CharCreatePreview walks every
## Figure of both sexes, every weapon and every armour set twice, and prints
## each pass's show_character times (the first pass builds the templates, the
## second reuses them) and the scale-only swaps.

func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback

func _init() -> void:
	_run.call_deferred()

func _wait(frames: int) -> void:
	for i in range(frames):
		await process_frame

func _counts() -> Array:
	return [int(Performance.get_monitor(Performance.OBJECT_COUNT)), Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))]

func _stats(xs: Array) -> String:
	if xs.is_empty():
		return "none"
	var s := xs.duplicate()
	s.sort()
	return "n %d median %.2f ms max %.2f ms" % [s.size(), s[s.size() / 2] / 1000.0, s[s.size() - 1] / 1000.0]

func _swaps(data: Pk2Reader, media: Pk2Reader, race: int) -> void:
	var a := CharacterAppearance.from_archives(data, media)
	var p := CharCreatePreview.new()
	p.appearance = a
	p.size = Vector2i(320, 240)
	root.add_child(p)
	var C := CharCreateModel.Ctl
	for pass_i in range(2):
		var figure_us: Array = []
		var item_us: Array = []
		var scale_us: Array = []
		for sex in [CharCatalog.SEX_MAN, CharCatalog.SEX_WOMAN]:
			var m := CharCreateModel.create(a.catalog(), race)
			m.set_sex(sex)
			for f in range(1, m.slider_range(C.FIGURE).y + 1):
				m.set_value(C.FIGURE, f)
				var t0 := Time.get_ticks_usec()
				p.show_character(m.model_id(), m.scale_byte(), m.preview_items(), true)
				figure_us.append(Time.get_ticks_usec() - t0)
			for w in range(1, m.slider_range(C.WEAPON).y + 1):
				m.set_value(C.WEAPON, w)
				for pr in range(m.slider_range(C.PROTECTOR).x, m.slider_range(C.PROTECTOR).y + 1):
					m.set_value(C.PROTECTOR, pr)
					var t0 := Time.get_ticks_usec()
					p.show_character(m.model_id(), m.scale_byte(), m.preview_items(), false)
					item_us.append(Time.get_ticks_usec() - t0)
			for h in range(5):
				var t0 := Time.get_ticks_usec()
				p.set_scale_byte(CharCreateModel.scale_of(h, 4 - h))
				scale_us.append(Time.get_ticks_usec() - t0)
			await process_frame
		print("SWAPS %s pass %d: figure %s; weapon/armour %s; height/volume %s" % [
			"china" if race == CharCatalog.RACE_CHINA else "europe", pass_i + 1, _stats(figure_us), _stats(item_us), _stats(scale_us)])
	p.release()
	p.queue_free()

func _run() -> void:
	var mode := _arg("mode", "screen")
	var cycles := int(_arg("cycles", "6"))
	var race := CharCatalog.RACE_EUROPE if _arg("race", "china") == "europe" else CharCatalog.RACE_CHINA
	var data := Pk2Reader.open(Pk2Config.data_path())
	var media := Pk2Reader.open(Pk2Config.media_path())
	if mode == "swaps":
		await _swaps(data, media, race)
		quit(0)
		return
	if mode == "camera":
		# Round 685's review: the backdrop's camera, posed once and left --
		# how far it moves by itself over 240 frames (the spring arm).
		var b := FrontEndBackdrop.new()
		root.add_child(b)
		b.begin(CharCreateView.BACKDROP[race]["region"], 1, 0.25)
		b.show_pose(CharCreateView.backdrop_pose(race, 0))
		var start := b.camera().global_position
		await _wait(240)
		print("CAMERA drift after 240 frames without show_pose: %.3f units (at %s, from %s)" % [
			b.camera().global_position.distance_to(start), b.camera().global_position, start])
		b.queue_free()
		await _wait(5)
		quit(0)
		return
	var prev: Array = []
	for i in range(cycles):
		match mode:
			"screen":
				CharSelectHandoff.race = race
				change_scene_to_file("res://scenes/CharacterCreate.tscn")
				await _wait(240)
				var blank := Node.new()
				var empty := PackedScene.new()
				empty.pack(blank)
				blank.free()
				change_scene_to_packed(empty)
				await _wait(30)
			"backdrop":
				var holder := Node.new()
				root.add_child(holder)
				var b := FrontEndBackdrop.new()
				holder.add_child(b)
				b.begin(CharCreateView.BACKDROP[race]["region"], 1, 0.25)
				b.show_pose(CharCreateView.backdrop_pose(race, 0))
				await _wait(240)
				holder.queue_free()
				await _wait(30)
			"world_only", "begin_now":
				var holder := Node.new()
				root.add_child(holder)
				var b := FrontEndBackdrop.new()
				holder.add_child(b)
				if mode == "world_only":
					var packed := load(FrontEndBackdrop.WORLD_SCENE) as PackedScene
					var w := packed.instantiate()
					w.set("title_mode", true)
					holder.add_child(w)
				else:
					b.begin(CharCreateView.BACKDROP[race]["region"], 1, 0.25)
				await _wait(2)
				holder.queue_free()
				await _wait(30)
			"appearance":
				var a := CharacterAppearance.from_archives(data, media)
				var m := CharCreateModel.create(a.catalog(), race)
				m.set_value(CharCreateModel.Ctl.WEAPON, 1)
				var body := a.build(m.model_id(), m.scale_byte(), m.preview_items())
				await _wait(5)
				body.free()
				a = null
				await _wait(5)
			"preview":
				var a := CharacterAppearance.from_archives(data, media)
				var m := CharCreateModel.create(a.catalog(), race)
				m.set_value(CharCreateModel.Ctl.WEAPON, 1)
				var p := CharCreatePreview.new()
				p.appearance = a
				p.size = Vector2i(320, 240)
				root.add_child(p)
				p.show_character(m.model_id(), m.scale_byte(), m.preview_items(), true)
				await _wait(30)
				p.release()
				p.queue_free()
				a = null
				await _wait(10)
		var c := _counts()
		var d := "" if prev.is_empty() else " (%+d objects, %+.2f MB)" % [c[0] - prev[0], c[1] - prev[1]]
		print("CYCLE %s %d: objects %d static %.2f MB nodes %d resources %d%s" % [mode, i + 1, c[0], c[1], c[2], c[3], d])
		prev = c
	quit(0)
