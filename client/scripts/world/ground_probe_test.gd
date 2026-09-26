extends SceneTree

## /groundprobe (round 579), run headless:
##   godot4 --headless --path client --script res://scripts/world/ground_probe_test.gd
##
## What is held to account: the chat console routes /groundprobe (and
## "/groundprobe quick") to World3D's host entry for any player; World3D's
## console host has that entry; the probe runs on a bare World3D carrying a
## synthetic terrain group (RealTerrain_97_168/SubPatch built by
## MapmTerrainBuilder from synthetic cells -- never game data -- plus one
## object mesh) and prints every section the round's record names, with the
## values the synthetic world implies; the entry counter and the exit record
## live in the process environment; and the frame statistics count what a
## synthetic picture holds.
##
## The probe is reached through load() and call(), never its class name, so
## on a tree without it this suite FAILS instead of failing to parse (round
## 563's pattern). Under the headless renderer there is no picture and GL
## names read 0; what is checked is that the fields are there.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## World3D.gd needs the NetClient autoload registered before it compiles,
## which is the case in _initialize and not in _init (world3d_reentry_test.gd).
func _initialize() -> void:
	_test_console_routes_the_command()
	var P := load("res://scripts/world/ground_probe.gd") as GDScript
	_check(P != null and P.can_instantiate(), "ground_probe.gd loads and can instantiate (absent before round 579)")
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if P == null or S == null or not P.can_instantiate() or not S.can_instantiate():
		_finish()
		return
	_test_frame_statistics(P)
	_test_entry_and_exit_records(P, S)
	_test_probe_on_a_synthetic_world(P, S)
	_finish()

## Any player's chat line reaches the probe: the console runs it itself (no
## server round trip), passes "full" or "quick", refuses anything else, and
## lists it in the help line.
func _test_console_routes_the_command() -> void:
	var calls: Array = []
	var logged: PackedStringArray = []
	var c := Console.new({
		"log": func(t: String) -> void: logged.append(t),
		"ground_probe": func(mode: String) -> PackedStringArray:
			calls.append(mode)
			return PackedStringArray(["probe ran %s" % mode]),
		"forward_gm": func(line: String) -> void: calls.append("gm:" + line),
	})
	c.submit("/groundprobe")
	c.submit("/GroundProbe quick")
	_check(calls == ["full", "quick"], "/groundprobe runs the host's ground_probe, full by default and quick on request (got %s)" % str(calls))
	_check("\n".join(logged).contains("probe ran full") and "\n".join(logged).contains("probe ran quick"),
		"the probe's chat lines are logged by the console")
	calls.clear()
	logged.clear()
	c.submit("/groundprobe everything")
	_check(calls.is_empty() and "\n".join(logged).contains("Usage: /groundprobe"),
		"an unknown mode gets the usage line and runs nothing")
	_check(c.help_line().contains("/groundprobe") and not c.is_gm, "the non-GM help line lists /groundprobe")

func _test_frame_statistics(P: GDScript) -> void:
	# A picture whose measured box is bright neutral grey and whose top is
	# sky blue: only the box counts.
	var img := Image.create(200, 100, false, Image.FORMAT_RGBA8)
	img.fill(Color8(80, 140, 230))
	img.fill_rect(Rect2i(0, 50, 200, 50), Color8(220, 220, 218))
	var m: Dictionary = P.call("measure_image", img)
	_check(m.get("ok", false) and is_equal_approx(float(m["bright_neutral"]), 1.0) and int(m["p50"]) == 219,
		"a white-grey box reads bright_neutral 1.0 and a neutral median of 219 (got %s)" % str(m))
	_check(is_equal_approx(float(m["blue"]), 0.0) and is_equal_approx(float(m["neutral"]), 1.0),
		"the sky above the box is not counted in the box")
	var full: Dictionary = m.get("full", {})
	_check(float(full.get("blue", 0.0)) > 0.4 and float(full.get("blue", 1.0)) < 0.6,
		"the whole-frame figures count the sky: about half blue (got %s)" % str(full))
	var red := Image.create(100, 100, false, Image.FORMAT_RGB8)
	red.fill(Color8(200, 40, 40))
	var r: Dictionary = P.call("measure_image", red)
	_check(is_equal_approx(float(r["red"]), 1.0) and is_equal_approx(float(r["bright_neutral"]), 0.0) and int(r["p50"]) == -1,
		"a red picture reads red 1.0, no neutral pixel (got %s)" % str(r))
	# Against a reference, `changed` counts what moved: the sky repainted
	# grey changes the top half of the whole frame and none of the box.
	var ref: Image = m["rgb"]
	var repainted := img.duplicate() as Image
	repainted.fill_rect(Rect2i(0, 0, 200, 50), Color8(120, 120, 120))
	var c: Dictionary = P.call("measure_image", repainted, ref)
	_check(is_equal_approx(float(c["changed"]), 0.0) and float(c["full"]["changed"]) > 0.4 and float(c["full"]["changed"]) < 0.6,
		"`changed` against the baseline picture: none of the box, about half of the whole frame (got %s / %s)" % [c["changed"], c["full"]["changed"]])
	_check(float(m["changed"]) < 0.0, "a picture with no reference reports no `changed` figure")
	_check(String(P.call("frame_text", {"ok": false, "why": "headless"})).contains("unavailable (headless)"),
		"an unreadable picture says why")

## The entry count and the previous entry's exit record live in the process
## environment, so a second World3D reads the first's.
func _test_entry_and_exit_records(P: GDScript, S: GDScript) -> void:
	var entry_env: String = P.get_script_constant_map()["ENTRY_ENV"]
	var exit_env: String = P.get_script_constant_map()["LAST_EXIT_ENV"]
	var gl_env: String = P.get_script_constant_map()["PREV_GL_ENV"]
	OS.set_environment(entry_env, "")
	_check(int(P.call("next_entry")) == 1 and int(P.call("next_entry")) == 2 and OS.get_environment(entry_env) == "2",
		"next_entry counts entries in SRREVAMP_WORLD_ENTRY")
	_check(String(P.call("reached_text", 1)).contains("first world entry"), "entry 1 is the first of the process")
	var w: Node = S.new()
	w._world_entry = 1
	w._ground_texture_cache["a.ddj"] = ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGB8))
	P.call("record_exit", w, false)
	_check(OS.get_environment(exit_env).contains("entry 1") and OS.get_environment(exit_env).contains("connected=false"),
		"record_exit leaves how the entry ended in SRREVAMP_WORLD_LAST_EXIT (got %s)" % OS.get_environment(exit_env))
	_check(OS.get_environment(gl_env).begins_with("ground:") and OS.get_environment(gl_env).length() > "ground:".length(),
		"and the ground textures' GL names, one per texture (got %s)" % OS.get_environment(gl_env))
	_check(String(P.call("reached_text", 2)).contains(OS.get_environment(exit_env)), "entry 2 names what entry 1 left")
	_check(String(P.call("entry_line", 2, 42)).contains("World3D: entry 2 (instance 42") and String(P.call("entry_line", 2, 42)).contains("adapter=")
		and String(P.call("entry_line", 2, 42)).contains("not queried at entry"),
		"the once-per-entry line carries the entry and the renderer")
	w.free()

## A bare World3D with one synthetic region under the player, probed quick
## (no A/B: the probe is not in the tree).
func _test_probe_on_a_synthetic_world(P: GDScript, S: GDScript) -> void:
	var w: Node = S.new()
	var host: Dictionary = w.call("_console_host")
	_check(host.has("ground_probe"), "World3D's console host has ground_probe (absent before round 579)")
	var names := {}
	for m in S.get_script_method_list():
		names[m["name"]] = true
	_check(names.has("_run_ground_probe"), "World3D.gd has _run_ground_probe")
	if not names.has("_run_ground_probe"):
		w.free()
		return

	var tex7 := ImageTexture.create_from_image(_solid(Color8(90, 110, 60)))
	var tex9 := ImageTexture.create_from_image(_solid(Color8(120, 100, 80)))
	var lightmap := ImageTexture.create_from_image(_solid(Color8(200, 200, 200)))
	w._ground_texture_cache = {"t7.ddj": tex7, "t9.ddj": tex9, "gone.ddj": null}
	w._world_entry = 2
	var player := CharacterBody3D.new()
	player.position = Vector3(30.0, 0.0, 30.0)
	w.add_child(player)
	w.player = player

	# 3 x 3 vertices: ID 7 everywhere but one corner, ID 9 -- so a base, one
	# opaque pass (7) and one overlay (9), unshaded with a baked light.
	var ids := [[7, 7, 7], [7, 9, 7], [7, 7, 7]]
	var cells: Array = []
	for r in range(3):
		var row: Array = []
		for c in range(3):
			var extra := PackedByteArray()
			extra.resize(2)
			extra.encode_u16(0, int(ids[r][c]))
			row.append([0.0, extra])
		cells.append(row)
	var lookup := {7: tex7, 9: tex9}
	var surfaces: Array = MapmTerrainBuilder._textured_surfaces_from_cells(cells, 3, 3, lookup, Vector3(0.3, 1.0, 0.2),
		Color(0.7, 0.7, 0.7), Color(0.3, 0.3, 0.3))
	var group := Node3D.new()
	group.name = "RealTerrain_97_168"
	group.set_meta("ground_probe", {"mapm_path": "97\\168.m", "commit": 1, "textured": true, "baked": true,
		"ids": 2, "resolved": 2, "decoded": 2, "no_entry": 0, "unreadable": 0, "uploaded": 2, "lightmap": true, "frame": 7, "threaded": false})
	w.add_child(group)
	var patch := MeshInstance3D.new()
	patch.name = "SubPatch"
	patch.mesh = MapmTerrainBuilder.surfaces_to_mesh(surfaces, lookup, lightmap)
	group.add_child(patch)
	# One placed object, for the contrast lines.
	var objects := Node3D.new()
	objects.name = "RealMapObjects_97_168"
	group.add_child(objects)
	var wall := MeshInstance3D.new()
	wall.name = "wall"
	wall.position = Vector3(40.0, 0.0, 30.0)
	var box := BoxMesh.new()
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_texture = tex9
	box.material = wall_mat
	wall.mesh = box
	objects.add_child(wall)

	var chat: PackedStringArray = w.call("_run_ground_probe", "quick")
	var probe = w.get("_ground_probe")
	_check(probe != null and is_instance_valid(probe), "the run left its probe node for the world to hold")
	if probe == null or not is_instance_valid(probe):
		w.free()
		return
	var lines: PackedStringArray = probe.get("_lines")
	var text := "\n".join(lines)
	var run := OS.get_environment(P.get_script_constant_map()["RUNS_ENV"])
	var tag := "GROUNDPROBE 2.%s " % run
	for section in ["begin", "frame baseline", "build", "gpu", "entry", "viewport", "render", "env", "caches",
			"region", "commit", "surface 0", "surface 1", "surface 2", "order", "regions", "object 0", "water",
			"glnames", "shadercache", "logscan"]:
		_check(text.contains(tag + section + ":"), "the probe prints its `%s` line" % section)
	for key in ["mode=quick", "running=", "adapter=", "api=", "depth_prepass=", "shader_cache=", "entry=2", "reached=",
			"debug_draw", "tex_mem=", "video_mem=", "orphans=", "light_ready=", "terrain_ambient=",
			"ground_textures=3 ground_nulls=1", "region=97/168", "groups_covering_here=1", "mapm=97\\168.m",
			"mat_rid=", "rid_valid=", "gl=", "param_match=", "rs_format=", "texel_mean=", "shading=", "vcol_albedo=",
			"transparency=", "albedo=", "filter=", "repeat=", "uv1_scale=", "vcol_min=", "base_rid=",
			"opaque_below_base=", "shared_by_two_rids=", "previous_entry_names="]:
		_check(text.contains(key), "the probe's lines carry `%s`" % key)
	_check(_line(lines, tag + "surface 0:").contains("kind=base key=-1") and _line(lines, tag + "surface 0:").contains("tex=false"),
		"surface 0 is the untextured base")
	_check(_line(lines, tag + "surface 1:").contains("kind=opaque key=7") and _line(lines, tag + "surface 1:").contains("file=t7.ddj"),
		"surface 1 is ID 7's opaque pass, its file named from the world's cache (%s)" % _line(lines, tag + "surface 1:"))
	_check(_line(lines, tag + "surface 2:").contains("kind=overlay key=9") and _line(lines, tag + "surface 2:").contains("file=t9.ddj"),
		"surface 2 is ID 9's overlay")
	_check(_line(lines, tag + "surface 1:").contains("shading=0") and _line(lines, tag + "surface 1:").contains("ao=true"),
		"the baked pass is unshaded and carries the lightmap")
	_check(_line(lines, tag + "object 0:").contains("wall") and _line(lines, tag + "object 0:").contains("file=t9.ddj"),
		"the nearest object's material is reported for contrast")
	_check(_line(lines, tag + "regions:").contains("RealTerrain_97_168: here=true surfaces=3 opaque=1 overlays=1"),
		"one compact line per loaded region (%s)" % _line(lines, tag + "regions:"))
	_check(chat.size() == 2 and chat[0].begins_with("Ground probe 2.") and chat[0].contains("3 terrain surfaces, 2 textured")
			and chat[1].contains("groundprobe-e2-"),
		"chat gets a two-line summary naming the saved file (got %s)" % str(chat))
	var path := String(probe.get("_file_path"))
	_check(FileAccess.file_exists(path) and FileAccess.get_file_as_string(path).contains(tag + "surface 1:"),
		"the lines are saved to %s" % path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	w.free()

func _line(lines: PackedStringArray, head: String) -> String:
	for l in lines:
		if l.begins_with(head):
			return l
	return ""

func _solid(c: Color) -> Image:
	var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
	img.fill(c)
	return img

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
