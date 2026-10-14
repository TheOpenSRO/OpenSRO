extends Node3D
class_name QaAlphaStir

## QA only (round 786, the ground flicker; OURS): OPENSRO_QA_ALPHA_STIR=<n>
## scatters n invisible transparent quads over the view, as walkers on the
## ground (within 700 units ahead of the camera), and walks each of them a
## little every frame, from a fixed seed; now and then one leaves the view or
## comes back. They draw nothing (ALPHA 0), but they are in Godot's
## transparent list as the walking monsters, other players and their effects
## of a real session are, and change it every frame the way those do -- which
## a still-camera movie render otherwise lacks.
##
## Why that matters: Godot sorts the transparent list with an unstable sort
## (SortArray, an introsort) on (render priority, then the instance's depth)
## only (READ, 4.7.2 render_forward_clustered.h
## `SortByReverseDepthAndPriority`), so two surfaces of ONE mesh at one
## priority tie, and their order follows whatever else is in the list. A
## measurement aid only; nothing in the game creates it.

const ENV := "OPENSRO_QA_ALPHA_STIR"
const SEED := 786
## How far a walker moves a frame (units), and the chance a frame that one
## is hidden or shown.
const STEP := 0.5
const TOGGLE := 0.02

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"""

var _camera: Camera3D
var _quads: Array[MeshInstance3D] = []
var _rng := RandomNumberGenerator.new()
var _placed := false

## Adds the stirrer under `parent` when the variable asks for it.
static func install(parent: Node, camera: Camera3D) -> QaAlphaStir:
	# "<n>[,<step>[,<toggle>[,<spread>]]]"
	var parts := OS.get_environment(ENV).split(",")
	var n := parts[0]
	if not n.is_valid_int() or int(n) <= 0 or camera == null:
		return null
	var stir := QaAlphaStir.new()
	stir.name = "QaAlphaStir"
	stir._camera = camera
	if parts.size() > 1 and parts[1].is_valid_float():
		stir._step = float(parts[1])
	if parts.size() > 2 and parts[2].is_valid_float():
		stir._toggle = float(parts[2])
	if parts.size() > 3 and parts[3].is_valid_float():
		stir._spread = float(parts[3])
	stir._build(int(n))
	parent.add_child(stir)
	print("QA ALPHA STIR: %d invisible transparent walkers, step %.2f toggle %.3f spread %.0f, seed %d" % [
		int(n), stir._step, stir._toggle, stir._spread, SEED])
	return stir

var _step := STEP
var _toggle := TOGGLE
var _spread := 700.0

func _build(n: int) -> void:
	_rng.seed = SEED
	var sh := Shader.new()
	sh.code = SHADER
	# OPENSRO_QA_ALPHA_STIR_SHOW=1: draw them (red, half alpha), to see where
	# they are.
	if OS.get_environment("OPENSRO_QA_ALPHA_STIR_SHOW") == "1":
		sh.code = SHADER.replace("ALBEDO = vec3(0.0);", "ALBEDO = vec3(1.0, 0.0, 0.0);").replace("ALPHA = 0.0;", "ALPHA = 0.5;")
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	mesh.material = mat
	for i in n:
		var q := MeshInstance3D.new()
		q.mesh = mesh
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		q.top_level = true
		# In the scene from the start, far below the world (out of view):
		# built in _ready, before any region, so they take early places in
		# the scenario's instance array -- as a session's long-lived bodies
		# do once regions have streamed in and out around them (Godot culls
		# that array in index order, and a removal moves the last instance
		# into the freed place: READ, 4.7.2 renderer_scene_cull.cpp
		# _scene_cull / _unpair_instance). A fresh QA boot otherwise builds
		# every region first, so they lead the transparent list.
		q.position = Vector3(0.0, -100000.0, 0.0)
		add_child(q)
		_quads.append(q)

func _process(_delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var t := _camera.global_transform
	if not _placed:
		# Once the camera has its place (the QA hooks set it a few frames in):
		# spread the walkers ahead of it on its ground plane.
		if Engine.get_process_frames() < 30:
			return
		_placed = true
		var fwd := -t.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
		var right := fwd.cross(Vector3.UP)
		for q in _quads:
			var d := _rng.randf_range(10.0, _spread)
			var s := _rng.randf_range(-0.6, 0.6) * d
			q.global_position = Vector3(t.origin.x, t.origin.y - 20.0, t.origin.z) + fwd * d + right * s
			q.visible = true
		return
	for q in _quads:
		if _rng.randf() < _toggle:
			q.visible = not q.visible
		var a := _rng.randf() * TAU
		q.global_position += Vector3(cos(a), 0.0, sin(a)) * _step
