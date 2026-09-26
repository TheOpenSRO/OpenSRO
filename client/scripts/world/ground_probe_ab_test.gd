extends SceneTree

## /groundprobe's A/B checks (round 579), run headless:
##   godot4 --headless --path client --script res://scripts/world/ground_probe_ab_test.gd
##
## ground_probe_test.gd holds the read-only half to account with the probe
## outside the tree; this suite puts the probe IN the tree, beside a small
## stand-in world, and walks the A/B state machine (GroundProbe._process) by
## hand -- after one frame for the tree to go live, nothing yields, so every
## step is called, not waited for. What is held to account is the promise the checks make to a
## player: whatever a step changes on the ground is put back, whether the
## sequence runs to its end or stops because the region's terrain left the
## tree half way. A restore that regressed would leave a player's terrain
## tinted, transparent, textured from a copy or without its mesh for the rest
## of the session, and the only other evidence the restore works is a live
## run's `final` step.
##
## The world is a stand-in (a Node3D with the few members the probe reads:
## the sun, the ground-tile cache, the .ddj decode, the chat log), not
## World3D, whose _ready loads the game. Its terrain is two groups covering
## the player's spot, built by MapmTerrainBuilder from synthetic cells --
## never game data -- so the `duplicates_hidden` step runs too.
##
## The probe is reached through load() and call(), never its class name, so
## on a tree without it this suite FAILS instead of failing to parse.

const WORLD_SOURCE := """extends Node3D
var directional_light: DirectionalLight3D
var _ground_texture_cache := {}
var decoded := 0
var logged: Array = []

func _open_map_pk2_if_set():
	return self

func _decode_ground_image(_filename: String, _archive) -> Image:
	decoded += 1
	var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
	img.fill(Color8(20, 180, 40))
	return img

func _log_system(text: String) -> void:
	logged.append(text)
"""

const GROUP_NAMES := ["RealTerrain_97_168", "RealTerrain_97_168_b"]
const FOCUS := Vector3(30.0, 0.0, 30.0)

var _failures := 0
var _world_script: GDScript
var _files: PackedStringArray = []

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var P := load("res://scripts/world/ground_probe.gd") as GDScript
	_check(P != null and P.can_instantiate(), "ground_probe.gd loads and can instantiate (absent before round 579)")
	if P == null or not P.can_instantiate():
		_finish()
		return
	_world_script = GDScript.new()
	_world_script.source_code = WORLD_SOURCE
	_check(_world_script.reload() == OK, "the stand-in world compiles")
	# The root enters the tree only after _initialize returns (a probe
	# outside the tree never arms its steps). After this one await nothing
	# yields: the steps below are all called by hand, in order, before the
	# engine processes another node.
	await process_frame
	_test_the_full_sequence_puts_everything_back(P)
	_test_a_stop_half_way_puts_the_step_back(P)
	_test_fresh_textures_skips_a_pass_cleared_meanwhile(P)
	_test_sorted_by_rid(P)
	for path in _files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_finish()

## Every step, applied, is visible while it is held; after the last step,
## every material, override, texture, colour, priority, transparency, mesh,
## group and the sun are what they were before the probe started.
func _test_the_full_sequence_puts_everything_back(P: GDScript) -> void:
	var w := _make_world()
	var groups := _groups(w)
	var before := _snapshot(w, groups)
	var probe := _start(P, w)
	var chat: PackedStringArray = probe.get_meta("chat")
	_check(probe.call("is_running"), "a full run in the tree arms the A/B steps")
	var names := _step_names(probe)
	_check(names == ["after_readback", "sun_off", "tint", "base_first", "opaque_as_alpha", "fresh_materials",
			"unfix_inverted", "unfix_inverted_tint", "duplicates_hidden", "fresh_textures", "retex", "remesh", "final"],
		"the steps, duplicates_hidden included when two groups cover the spot (got %s)" % str(names))
	_check(chat.size() == 2 and chat[1].contains("until the 'done' line") and not chat[1].contains("second"),
		"the chat asks the player to hold still until the done line, with no time promised (got %s)" % str(chat))
	_check(OS.get_environment(P.get_script_constant_map()["CHECKS_FROM_ENV"]).to_int() > 0,
		"arming records when this process's first A/B checks began (the shader cache's split)")

	var sun: DirectionalLight3D = w.get("directional_light")
	var a: Array = _passes(groups[0])
	var b: Array = _passes(groups[1])
	var base: BaseMaterial3D = a[0]
	var opaque: BaseMaterial3D = a[1]
	var overlay: BaseMaterial3D = a[2]
	var patch_a := groups[0].get_node("SubPatch") as MeshInstance3D
	var patch_b := groups[1].get_node("SubPatch") as MeshInstance3D
	var tex7: Texture2D = opaque.albedo_texture

	_check(_step_to(probe, "sun_off", "measure") and not sun.visible, "sun_off hides the sun while it is measured")
	_check(_step_to(probe, "tint", "measure") and opaque.albedo_color == Color(1, 0, 0, 1) and base.albedo_color == Color(1, 0, 1, 1)
			and overlay.albedo_color.b == 1.0 and overlay.albedo_color.r == 0.0 and (b[1] as BaseMaterial3D).albedo_color == Color(1, 0, 0, 1),
		"tint paints the opaque passes red, the bases magenta and the overlays blue, in every region")
	_check(sun.visible, "and the sun is back by then")
	_check(_step_to(probe, "base_first", "measure") and base.render_priority == -1 and (b[0] as BaseMaterial3D).render_priority == -1,
		"base_first puts every base at render_priority -1")
	_check(_step_to(probe, "opaque_as_alpha", "measure") and opaque.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA,
		"opaque_as_alpha makes the opaque passes alpha-blended")
	_check(_step_to(probe, "fresh_materials", "measure") and patch_a.get_surface_override_material(0) != null
			and patch_a.get_surface_override_material(1) != null and patch_a.get_surface_override_material(2) == null,
		"fresh_materials puts copies on the base and the opaque pass as surface overrides, not on the overlay")
	var fresh_note := String((probe.get("_saved") as Dictionary).get("note", ""))
	_check(fresh_note.begins_with("with the fix: 2 of 2 regions draw their base first by render priority")
			and (patch_a.get_surface_override_material(0) as Material).render_priority == -1,
		"on the fixed build fresh_materials says it runs with the fix, and the base's copy keeps priority -1 (note: %s)" % fresh_note)
	# The fix undone on purpose: copies on every base and opaque pass, the
	# base's at the pre-fix priority 0, the passes' at theirs, the overlay
	# and the originals untouched. (The headless renderer allocates no
	# material RIDs, so the inverted RID order is held by sorted_by_rid's
	# own check below and measured live, not here.)
	var unfix_ok := _step_to(probe, "unfix_inverted", "measure")
	var wrong := PackedStringArray()
	for patch in [patch_a, patch_b]:
		var mesh: Mesh = patch.mesh
		var ob := mesh.surface_get_material(0) as BaseMaterial3D
		var oo := mesh.surface_get_material(1) as BaseMaterial3D
		var cb := patch.get_surface_override_material(0) as BaseMaterial3D
		var co := patch.get_surface_override_material(1) as BaseMaterial3D
		if cb == null or co == null or cb == ob or co == oo:
			wrong.append("%s: no copies" % patch.get_parent().name)
			continue
		if cb.render_priority != 0 or co.render_priority != 0:
			wrong.append("priorities %d/%d" % [cb.render_priority, co.render_priority])
		if co.albedo_texture != tex7 or cb.albedo_texture != null:
			wrong.append("textures")
		if cb.shading_mode != ob.shading_mode or cb.ao_texture != ob.ao_texture or cb.vertex_color_use_as_albedo != ob.vertex_color_use_as_albedo:
			wrong.append("base settings")
		if int(cb.get_meta("terrain_texture_key", -2)) != -1 or int(co.get_meta("terrain_texture_key", -2)) != 7:
			wrong.append("metadata %s/%s" % [str(cb.get_meta("terrain_texture_key", -2)), str(co.get_meta("terrain_texture_key", -2))])
		if patch.get_surface_override_material(2) != null:
			wrong.append("overlay overridden")
	var copies_ok := wrong.is_empty()
	var unfix_note := String((probe.get("_saved") as Dictionary).get("note", ""))
	_check(unfix_ok and copies_ok and base.render_priority == -1 and unfix_note.begins_with("with the fix: 2 of 2"),
		"unfix_inverted draws every base and opaque pass from a copy, the base's at the pre-fix priority 0, and leaves the originals and the overlay alone (wrong: %s; base %d; note: %s)" % [", ".join(wrong), base.render_priority, unfix_note])
	var tint_ok := _step_to(probe, "unfix_inverted_tint", "measure")
	var cbt := patch_b.get_surface_override_material(0) as BaseMaterial3D
	var cot := patch_b.get_surface_override_material(1) as BaseMaterial3D
	_check(tint_ok and cbt != null and cot != null and cbt.albedo_color == Color(1, 0, 1, 1) and cbt.render_priority == 0
			and cot.albedo_color == Color(1, 0, 0, 1) and (b[2] as BaseMaterial3D).albedo_color.b == 1.0
			and (b[2] as BaseMaterial3D).albedo_color.r == 0.0 and opaque.albedo_color != Color(1, 0, 0, 1),
		"unfix_inverted_tint tints the copies (base magenta, pass red) and the overlays blue, not the originals")
	_check(_step_to(probe, "duplicates_hidden", "measure") and groups[0].visible and not groups[1].visible,
		"duplicates_hidden hides the second group covering the spot")
	_check(_step_to(probe, "fresh_textures", "measure") and opaque.albedo_texture != null and opaque.albedo_texture != tex7
			and int(w.get("decoded")) == 1,
		"fresh_textures gives the opaque passes a tile decoded again, once per file (decoded %d)" % int(w.get("decoded")))
	_check(_step_to(probe, "retex", "mid") and opaque.albedo_texture == null, "retex clears the opaque passes' texture")
	_check(_step_to(probe, "remesh", "mid") and patch_a.mesh == null and patch_b.mesh == null, "remesh clears every region's mesh")

	_run_out(probe)
	_check(not probe.call("is_running"), "the sequence runs to its end")
	var diff := _diff(before, _snapshot(w, groups))
	_check(diff.is_empty(), "after the last step the ground is exactly as it was (differs: %s)" % ", ".join(diff))
	var text := "\n".join(probe.get("_lines") as PackedStringArray)
	for name in names:
		_check(text.contains(" ab %s:" % name), "the run printed its `ab %s` line" % name)
	_check(text.contains(" summary:"), "and the summary")
	_check(str(w.get("logged")).contains("done -- saved to"), "the world's chat gets the done line")
	_files.append(String(probe.get("_file_path")))
	w.free()

## The region's terrain leaves the tree half way through a step (a streamed
## unload): the step's change is put back -- the steps change every loaded
## region, and the others are still drawn; a hidden sun would stay hidden --
## and the run stops with a line saying where.
func _test_a_stop_half_way_puts_the_step_back(P: GDScript) -> void:
	for cut in [["sun_off", "measure"], ["tint", "measure"], ["base_first", "measure"], ["opaque_as_alpha", "measure"],
			["fresh_materials", "measure"], ["unfix_inverted", "measure"], ["unfix_inverted_tint", "measure"],
			["duplicates_hidden", "measure"], ["fresh_textures", "measure"],
			["retex", "mid"], ["remesh", "mid"]]:
		var w := _make_world()
		var groups := _groups(w)
		var name: String = cut[0]
		if name == "base_first":
			# The fixed builder's bases are at -1 already, where base_first
			# puts them; as a pre-fix build's (0) the step changes them, and
			# its restore is what is tested.
			for group in groups:
				(_passes(group)[0] as Material).render_priority = 0
		var before := _snapshot(w, groups)
		var probe := _start(P, w)
		var reached := _step_to(probe, name, cut[1])
		_check(reached and not _diff(before, _snapshot(w, groups)).is_empty(),
			"stop test: `%s` is in effect when the terrain leaves" % name)
		w.remove_child(probe.get("_group"))
		_run_out(probe)
		_check(not probe.call("is_running"), "stop test: the run ends once the terrain has left (%s)" % name)
		var text := "\n".join(probe.get("_lines") as PackedStringArray)
		_check(text.contains("stopped at step %s:" % name), "stop test: the run says it stopped at %s" % name)
		var diff := _diff(before, _snapshot(w, groups))
		_check(diff.is_empty(), "stop test: `%s` is put back (differs: %s)" % [name, ", ".join(diff)])
		_files.append(String(probe.get("_file_path")))
		(groups[0] as Node).free()
		w.free()

## unfix_inverted gives each region's base the blank with the HIGHEST RID
## index and its passes the lower ones, whatever order the allocator handed
## them out in: sorted_by_rid, fed indices out of order (the headless
## renderer's materials have no RIDs to read).
func _test_sorted_by_rid(P: GDScript) -> void:
	var idx := {"a": 79, "b": 14, "c": 147, "d": 15}
	var out: Array = P.call("sorted_by_rid", ["a", "b", "c", "d"], func(k) -> int: return int(idx[k]))
	_check(out == ["b", "d", "a", "c"], "sorted_by_rid orders by RID index, lowest first, so the last (the base's) is the highest (got %s)" % str(out))

## A pass whose texture something else cleared after the probe listed it is
## skipped by fresh_textures (no error), and left cleared by its restore.
func _test_fresh_textures_skips_a_pass_cleared_meanwhile(P: GDScript) -> void:
	var w := _make_world()
	var groups := _groups(w)
	var probe := _start(P, w)
	var opaque_a: BaseMaterial3D = _passes(groups[0])[1]
	var opaque_b: BaseMaterial3D = _passes(groups[1])[1]
	var tex7: Texture2D = opaque_a.albedo_texture
	var reached := _step_to(probe, "fresh_textures", "apply")
	opaque_a.albedo_texture = null
	probe.call("_process", 0.0)
	var note := String((probe.get("_saved") as Dictionary).get("note", ""))
	_check(reached and note.begins_with("1 passes re-textured") and opaque_a.albedo_texture == null
			and opaque_b.albedo_texture != tex7,
		"fresh_textures re-textures the other region's pass and skips the cleared one (note: %s)" % note)
	_run_out(probe)
	_check(opaque_a.albedo_texture == null and opaque_b.albedo_texture == tex7,
		"its restore gives the other pass its own tile back and leaves the cleared one alone")
	_files.append(String(probe.get("_file_path")))
	_free_world(w, groups)

# --- The stand-in world ------------------------------------------------------

func _make_world() -> Node3D:
	var w: Node3D = _world_script.new()
	w.name = "ProbeABWorld"
	root.add_child(w)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	w.add_child(sun)
	w.set("directional_light", sun)
	var tex7 := ImageTexture.create_from_image(_solid(Color8(90, 110, 60)))
	var tex9 := ImageTexture.create_from_image(_solid(Color8(120, 100, 80)))
	var lightmap := ImageTexture.create_from_image(_solid(Color8(200, 200, 200)))
	w.set("_ground_texture_cache", {"t7.ddj": tex7, "t9.ddj": tex9})
	var lookup := {7: tex7, 9: tex9}
	# 3 x 3 vertices: ID 7 everywhere but one corner, ID 9 -- a base, one
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
	for group_name in GROUP_NAMES:
		var surfaces: Array = MapmTerrainBuilder._textured_surfaces_from_cells(cells, 3, 3, lookup, Vector3(0.3, 1.0, 0.2),
			Color(0.7, 0.7, 0.7), Color(0.3, 0.3, 0.3))
		var group := Node3D.new()
		group.name = group_name
		w.add_child(group)
		var patch := MeshInstance3D.new()
		patch.name = "SubPatch"
		patch.mesh = MapmTerrainBuilder.surfaces_to_mesh(surfaces, lookup, lightmap)
		group.add_child(patch)
	return w

## Frees a world whose terrain has been in the tree, holding its meshes until
## after: a MeshInstance3D freed while it holds the last reference to its mesh
## makes the headless (dummy) renderer print `Parameter "m" is null` from
## mesh_get_surface_count as it tears the instance down -- measured on this
## suite, independent of the probe (the other tests hold the meshes in their
## snapshots and print nothing).
func _free_world(w: Node3D, groups: Array[Node3D]) -> void:
	var keep: Array = []
	for group in groups:
		keep.append((group.get_node("SubPatch") as MeshInstance3D).mesh)
	w.free()
	keep.clear()

func _groups(w: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for group_name in GROUP_NAMES:
		out.append(w.get_node(NodePath(group_name)) as Node3D)
	return out

func _passes(group: Node3D) -> Array:
	var mesh := (group.get_node("SubPatch") as MeshInstance3D).mesh
	var out: Array = []
	for i in range(mesh.get_surface_count()):
		out.append(mesh.surface_get_material(i))
	return out

## A full run, the way World3D._run_ground_probe starts one: the probe a child
## of the world, the player at FOCUS. The chat lines are kept on the probe.
func _start(P: GDScript, w: Node3D) -> Node:
	var probe: Node = P.new()
	probe.name = "GroundProbe"
	w.add_child(probe)
	var chat: PackedStringArray = probe.call("start", w, 2, "full", FOCUS, {"connected": true, "zone": "test"})
	probe.set_meta("chat", chat)
	return probe

## Everything the steps touch, by group: the sun, each group's visibility and
## mesh, and each surface's material, override, colour, priority,
## transparency and texture.
func _snapshot(w: Node3D, groups: Array[Node3D]) -> Dictionary:
	var out := {}
	var sun: DirectionalLight3D = w.get("directional_light")
	out["sun.visible"] = sun.visible
	for group in groups:
		out[group.name + ".visible"] = group.visible
		var patch := group.get_node("SubPatch") as MeshInstance3D
		out[group.name + ".mesh"] = patch.mesh
		if patch.mesh == null:
			continue
		for i in range(patch.mesh.get_surface_count()):
			var k := "%s/%d" % [group.name, i]
			var mat := patch.mesh.surface_get_material(i) as BaseMaterial3D
			out[k + ".material"] = mat
			out[k + ".override"] = patch.get_surface_override_material(i)
			out[k + ".albedo_color"] = mat.albedo_color
			out[k + ".render_priority"] = mat.render_priority
			out[k + ".transparency"] = mat.transparency
			out[k + ".albedo_texture"] = mat.albedo_texture
	return out

func _diff(a: Dictionary, b: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for k in a:
		if not b.has(k) or b[k] != a[k]:
			out.append(k)
	for k in b:
		if not a.has(k):
			out.append(k)
	return out

func _step_names(probe: Node) -> Array:
	var out: Array = []
	for step in probe.get("_steps"):
		out.append(String(step["name"]))
	return out

## Calls the probe's _process until it stands just before `phase` of the step
## named `name` (_wait run down). False if the run ends first.
func _step_to(probe: Node, name: String, phase: String) -> bool:
	for _i in range(500):
		if not probe.call("is_running"):
			return false
		var steps: Array = probe.get("_steps")
		var idx: int = probe.get("_step_index")
		if idx >= 0 and idx < steps.size() and String(steps[idx]["name"]) == name \
				and String(probe.get("_phase")) == phase and int(probe.get("_wait")) == 0:
			return true
		probe.call("_process", 0.0)
	return false

func _run_out(probe: Node) -> void:
	for _i in range(500):
		if not probe.call("is_running"):
			return
		probe.call("_process", 0.0)

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
