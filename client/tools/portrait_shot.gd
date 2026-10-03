extends SceneTree

## Dev tool: renders the player-block portrait (PlayerPortrait, round 635) for
## any player body from the player's own archives, and the block itself with
## the portrait in its circle, and saves them as PNGs -- the check against
## retail's screenshots. Needs a real GL context (not --headless); on the
## render box run it the way qa_shot.sh runs the client (xvfb + vglrun).
##
##   godot4 --path client --script res://tools/portrait_shot.gd -- \
##     --out=/var/tmp/portrait/shots \
##     --body="CHAR_CH_MAN_FIGHTER:3643,3644,3645,3632" \
##     --body="CHAR_CH_WOMAN_FIGHTER:3652,3653,3654,3632"
##   --env=<EnvironmentID> lights the portrait with that environment.ifo
##   record's zone light (channels 2 and 3 at World3D's reference time 0.5,
##   from OPENSRO_MAP_PK2_PATH); --list-env prints every record's two.
##   (items by id or by exact code name; --list=<substring> prints matching
##   item code names and quits; --cost=<code> times the frame with the
##   portrait idle and re-rendering every frame)
##
## Archives from OPENSRO_PK2_PATH / OPENSRO_MEDIA_PK2_PATH. Writes, per body:
## <code>_raw128.png (the 128x128 buffer), <code>_block.png (the player block
## with the portrait, 3x) and prints the dress's CPU cost and the viewport's
## measured render time.

var _data: Pk2Reader
var _media: Pk2Reader
var _bodies := {}
var _items := {}          # id -> Item
var _by_code := {}        # code_name -> id
var _env: EnvironmentReader.ParsedFile = null
var _zone: Array = []     # [channel 2, channel 3] of --env

func _args(flag: String) -> Array:
	var out := []
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

func _init() -> void:
	_data = Pk2Reader.open(OS.get_environment("OPENSRO_PK2_PATH"))
	_media = Pk2Reader.open(OS.get_environment("OPENSRO_MEDIA_PK2_PATH"))
	if _data == null or _media == null:
		printerr("portrait_shot: set OPENSRO_PK2_PATH and OPENSRO_MEDIA_PK2_PATH")
		quit(2)
		return
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(_media, path)
		if entry != null:
			_bodies = NpcTableReader.parse_models_by_code(_media.read_file(entry), _bodies)
	for path in ItemTableReader.TABLE_PATHS:
		var entry := ObjectLoader.find_file(_media, path)
		if entry != null:
			for item in ItemTableReader.parse(_media.read_file(entry)).values():
				_items[item.id] = item
				_by_code[item.code_name] = item.id
	var map_pk2 := Pk2Reader.open(OS.get_environment("OPENSRO_MAP_PK2_PATH"))
	if map_pk2 != null:
		var env_bytes := AssetSource.read_bytes("environment.ifo", map_pk2)
		if not env_bytes.is_empty():
			_env = EnvironmentReader.parse(env_bytes)
	if not _args("--list-env").is_empty() and _env != null:
		for rec in _env.records:
			var d := EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_DIFFUSE_COLOR, 0.5)
			var a := EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_OBJECT_AMBIENT_COLOR, 0.5)
			print("ENV %d %s diffuse %s ambient %s" % [rec.key, rec.name1, str(d), str(a)])
		quit(0)
		return
	var envs := _args("--env")
	if not envs.is_empty() and _env != null:
		for rec in _env.records:
			if rec.key == int(envs[0]):
				_zone = [EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_DIFFUSE_COLOR, 0.5),
					EnvironmentReader.sample_color_channel(rec, EnvironmentReader.CHANNEL_OBJECT_AMBIENT_COLOR, 0.5)]
				print("ZONE %d %s: diffuse channel %s ambient channel %s" % [rec.key, rec.name1, str(_zone[0]), str(_zone[1])])
	var lists := _args("--list")
	if not lists.is_empty():
		for code in _by_code.keys():
			for pat in lists:
				if String(code).contains(pat) and (_items[_by_code[code]] as ItemTableReader.Item).model_path != "":
					print("%s %d %s" % [code, _by_code[code], (_items[_by_code[code]] as ItemTableReader.Item).model_path])
		quit(0)
		return
	var outs := _args("--out")
	var out_dir: String = outs[0] if not outs.is_empty() else "/var/tmp/portrait/shots"
	DirAccess.make_dir_recursive_absolute(out_dir)
	await process_frame
	var builder := UiBuilder.new(_media, null)
	await _calibrate(out_dir)
	for spec in _args("--body"):
		await _shoot(String(spec), out_dir, builder)
	if not _args("--cost").is_empty():
		await _cost(String(_args("--cost")[0]))
	quit(0)

## The frame cost: the same frame drawn with the portrait's viewport idle
## (retail's steady state: it renders only when dirtied) and re-rendering
## every frame, timed around RenderingServer.force_draw with vsync off, plus
## the renderer's own measured times for the portrait's viewport.
func _cost(code: String) -> void:
	var bsr: String = _bodies.get(code, "")
	var assembled := SkinnedBsrAssembler.assemble_from_archive(_data, bsr, false)
	var p := PlayerPortrait.new()
	root.add_child(p)
	var pose_path := assembled.parsed.animation_for(PlayerPortrait.ANI_POSE, "default")
	var pose: BanReader.ParsedAnimation = BanReader.parse(AssetSource.read_bytes(pose_path, _data))
	p.set_character(assembled.skeleton, pose)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for i in range(5):
		await process_frame
	var rid := p.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var n := 200
	var times := {}
	for mode in ["idle", "every_frame", "idle"]:
		p.render_target_update_mode = SubViewport.UPDATE_DISABLED if mode == "idle" else SubViewport.UPDATE_ALWAYS
		RenderingServer.force_draw(false)
		var t0 := Time.get_ticks_usec()
		for i in range(n):
			RenderingServer.force_draw(false)
		times[mode] = float(Time.get_ticks_usec() - t0) / float(n)
		print("COST %s: %.1f us per frame (%d frames); portrait viewport measured cpu %.4f ms gpu %.4f ms" % [
			mode, times[mode], n, RenderingServer.viewport_get_measured_render_time_cpu(rid),
			RenderingServer.viewport_get_measured_render_time_gpu(rid)])
	p.queue_free()

func _shoot(spec: String, out_dir: String, builder: UiBuilder) -> void:
	var parts := spec.split(":")
	var code := parts[0]
	var bsr: String = _bodies.get(code, "")
	if bsr == "":
		printerr("portrait_shot: no body for %s" % code)
		return
	var assembled := SkinnedBsrAssembler.assemble_from_archive(_data, bsr, false)
	if assembled == null:
		printerr("portrait_shot: %s did not assemble" % code)
		return
	var weapon_group := "default"
	if parts.size() > 1:
		for tok in parts[1].split(",", false):
			var id := int(tok) if tok.is_valid_int() else int(_by_code.get(tok, 0))
			var item: ItemTableReader.Item = _items.get(id)
			if item == null or item.model_path == "":
				print("portrait_shot: item %s has no worn model" % tok)
				continue
			SkinnedBsrAssembler.attach_item_from_archive(_data, assembled.skeleton, item.model_path)
	var pose_path := assembled.parsed.animation_for(PlayerPortrait.ANI_POSE, weapon_group)
	var pose: BanReader.ParsedAnimation = null
	if pose_path != "":
		var bytes := AssetSource.read_bytes(pose_path, _data)
		if bytes.is_empty():
			bytes = AssetSource.read_bytes("res\\" + pose_path, _data)
		pose = BanReader.parse(bytes) if not bytes.is_empty() else null

	var pmi := HudPlayerInfo.new(builder)
	var layer := CanvasLayer.new()
	root.add_child(layer)
	layer.add_child(pmi)
	pmi.position = Vector2(4, 7)
	pmi.setup()
	pmi.set_character("Portrait", 1)
	pmi.set_hp(214, 214)
	pmi.set_mp(214, 214)
	pmi.set_race(1 if code.begins_with("CHAR_EU") else 0)
	if _zone.size() == 2:
		pmi.set_portrait_zone_light(_zone[0], _zone[1])
	pmi.set_portrait(assembled.skeleton, pose)
	var p := pmi.portrait()
	RenderingServer.viewport_set_measure_render_time(p.get_viewport_rid(), true)
	for i in range(4):
		await process_frame
	var raw := p.get_texture().get_image()
	var tag: String = code + ("_env%s" % _args("--env")[0] if not _args("--env").is_empty() else "")
	raw.save_png("%s/%s_raw128.png" % [out_dir, tag])
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(p.get_viewport_rid())
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(p.get_viewport_rid())
	var shot := root.get_texture().get_image()
	var block := shot.get_region(Rect2i(0, 0, 230, 90))
	block.resize(690, 270, Image.INTERPOLATE_NEAREST)
	block.save_png("%s/%s_block.png" % [out_dir, tag])
	# The centre texel of the buffer, as a number (the face under the camera).
	var c := raw.get_pixel(64, 64)
	var lum := 0.0
	var lit := 0
	for y in range(raw.get_height()):
		for x in range(raw.get_width()):
			var px := raw.get_pixel(x, y)
			lum += (px.r + px.g + px.b) / 3.0
			if px.r + px.g + px.b > 0.03:
				lit += 1
	print("PORTRAIT %s: pose %s, dress %d us, %d unmapped, render cpu %.3f ms gpu %.3f ms, centre %s, mean %.3f, %d/16384 non-black texels, renders requested %d" % [
		code, pose_path, p.last_build_usec, p.unmapped_materials, cpu, gpu, str(c),
		lum / float(raw.get_width() * raw.get_height()), lit, p.renders_requested])
	layer.queue_free()
	await process_frame

## The colour pipeline measured: a flat quad of texture 0.5 grey, material
## 0.588, facing the light, must come out 2 x 0.5 x 0.588 x (0.3 + 0.7 n.l)
## in the buffer -- the client's gamma-space arithmetic, not Godot's linear
## lighting. n.l = cos(0.1): the avatar's yaw turns the quad off the light.
func _calibrate(out_dir: String) -> void:
	var sk := Skeleton3D.new()
	sk.add_bone("Bip01 Head")
	sk.set_bone_rest(0, Transform3D(Basis.IDENTITY, Vector3(0, -1, 0)))
	sk.reset_bone_poses()
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	# A quad at z = 0 facing -z (the camera's side in the file's coordinates),
	# wound for Godot's back-face cull under the mirror node.
	var v := PackedVector3Array([Vector3(-20, -20, 0), Vector3(20, -20, 0), Vector3(20, 20, 0), Vector3(-20, 20, 0)])
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, -1), Vector3(0, 0, -1), Vector3(0, 0, -1), Vector3(0, 0, -1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color8(128, 128, 128, 255))
	var sm := StandardMaterial3D.new()
	sm.albedo_texture = ImageTexture.create_from_image(img)
	sm.albedo_color = Color(0.588, 0.588, 0.588, 1)
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = sm
	sk.add_child(mi)
	var p := PlayerPortrait.new()
	root.add_child(p)
	p.set_character(sk, null)
	for i in range(3):
		await process_frame
	var raw := p.get_texture().get_image()
	var c := raw.get_pixel(64, 64)
	# The quad's normal (0,0,-1) after the avatar's yaw, against the zone
	# light's to-light (0.707, 0.707, 0), under the fallback channels (1.0).
	var n := Vector3(sin(0.1), 0.0, -cos(0.1))
	var ndl := n.dot(-PlayerPortrait.WORLD_LIGHT_DIRECTION)
	var want := PlayerPortrait.shade(128.0 / 255.0, 0.588, PlayerPortrait.OBJECT_COLOR, 1.0, PlayerPortrait.DIFFUSE_SCALE, ndl)
	print("CALIBRATE: centre %.4f %.4f %.4f (%d), expected %.4f (%d)" % [c.r, c.g, c.b, int(round(c.r * 255.0)), want, int(round(want * 255.0))])
	raw.save_png("%s/calibrate.png" % out_dir)
	p.queue_free()
