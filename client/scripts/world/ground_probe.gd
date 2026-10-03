extends Node
class_name GroundProbe

## /groundprobe (round 579): a player-runnable record of the WHITE GROUND a
## tester sees after a disconnect + reconnect in one client process
## (reported 2026-09-25 and 2026-09-26; never reproduced on the render box,
## docs/RE_COMPLETION.md rounds 558-560). A player on a Windows release build
## cannot set OPENSRO_QA_* variables, so what round 558's QA ENTRY /
## QA TEXPROBE lines measure has to be something they can type at the moment
## they see it: `/groundprobe` in the chat line, or the F3 panel's
## "Ground probe" button (both reach World3D._run_ground_probe).
##
## It prints `GROUNDPROBE <entry>.<run> <section>: key=value ...` lines to the
## log, writes the same lines to user://logs/groundprobe-*.txt, and puts a
## short summary in chat. What it records, in this order:
## - the frame FIRST (`frame baseline`), before anything below binds a
##   texture: statistics of the rendered picture over FRAME_BOX;
## - the build, the GL adapter and driver, the renderer settings that the
##   investigators' hypotheses turn on (depth prepass, shader cache, ANGLE
##   fallback), this World3D's entry number in the process and what the
##   previous one left behind (OPENSRO_WORLD_ENTRY / OPENSRO_WORLD_LAST_EXIT,
##   process environment -- never a static, statics are what a reconnect
##   changes);
## - the viewport, the renderer's memory and draw counts, the environment and
##   light the terrain was baked with, the world's caches;
## - the region under the player (not only the grid centre): what its commit
##   recorded (World3D._terrain_commit's "ground_probe" meta), how many
##   terrain groups cover the spot, and one line per surface material of its
##   terrain mesh -- round 558's TEXPROBE fields plus the material's RID index
##   (the GLES3 opaque sort key's last field), the texture's GL name
##   (RenderingServer.texture_get_native_handle) and whether the RenderingServer
##   material's own `texture_albedo` parameter is the texture's RID;
## - one line per loaded region, three nearby object materials for contrast,
##   the region's water, a GL-name audit of every ground / lightmap / water
##   texture (against the previous entry's names), the GLES3 shader cache's
##   files rewritten by this process, and a count of the log lines each
##   hypothesis predicts;
## - then (full mode, in the tree) a sequence of A/B steps on every loaded
##   region's terrain, each held for SETTLE_FRAMES, measured with the same
##   frame statistics (plus how much of the picture changed against the
##   baseline) and put back: the sun hidden, the terrain materials tinted,
##   the bases drawn first, the opaque passes made transparent, fresh copies
##   of the materials, a duplicate terrain hidden, freshly decoded textures,
##   the textures re-assigned, the meshes re-assigned. Which of them changes
##   the white is what tells the hypotheses apart (docs/RE_COMPLETION.md, the
##   round's table). The last two are not undone: they put back what was
##   there.
## - since the fix (MapmTerrainBuilder.BASE_RENDER_PRIORITY, round 580: every
##   base drawn before its passes by priority, not RID order), two more steps
##   undo it on purpose -- `unfix_inverted` and `unfix_inverted_tint` redraw
##   the terrain with new materials whose RID indices put each base AFTER its
##   passes, the base at the pre-fix priority -- so a run on the fixed build
##   still shows whether the mechanism flattens the ground on the player's
##   own machine, while `fresh_materials` (the copies keep the fix) shows
##   that the fix holds there.
##
## Every value is read from the running client; nothing here is a constant
## of the original game. FRAME_BOX and the pixel classes below are this
## probe's own definitions, printed with the numbers they produce.

const PREFIX := "GROUNDPROBE"
## World entries in this process (World3D._ready bumps it).
const ENTRY_ENV := "OPENSRO_WORLD_ENTRY"
## What the previous World3D said when it left the tree (record_exit).
const LAST_EXIT_ENV := "OPENSRO_WORLD_LAST_EXIT"
## The previous World3D's ground / lightmap / water GL names (record_exit).
const PREV_GL_ENV := "OPENSRO_GROUNDPROBE_PREV_GL"
## Probe runs in this process, so two runs' lines never share a tag.
const RUNS_ENV := "OPENSRO_GROUNDPROBE_RUNS"
## The unix time the first A/B sequence of this process started
## (_arm_steps): its steps can compile shaders of their own
## (`opaque_as_alpha` gives the passes' StandardMaterial3D a different
## shader), and GLES3 saves a shader version it did not find in its cache
## (drivers/gles3/shader_gles3.cpp, ShaderGLES3::_initialize_version,
## 4.2.2-stable) -- so a later run's `shadercache` line counts the files
## written before it apart.
const CHECKS_FROM_ENV := "OPENSRO_GROUNDPROBE_CHECKS_FROM"
const LOG_PATH := "user://logs/opensro.log"
const REGION_SPAN := 1920.0
## Frames an A/B change is held before its frame is measured, and frames
## after it is undone before the next one.
const SETTLE_FRAMES := 4
const RESTORE_FRAMES := 2
const OBJECT_MATERIALS := 3
## The base's render priority before round 580's fix: the Material default,
## the same as every opaque pass's. `unfix_inverted` draws the bases at it.
const PRE_FIX_BASE_PRIORITY := 0
## The picture statistics' box, as fractions of the viewport: 35% to 80% of
## the width and 60% to 84% of the height -- under the player at the default
## camera, clear of the underbar and of the chat window. The underbar is 68
## pixels tall (round 598): 10.5% of a 648-tall view, 15.7% at UI scale 1.5,
## so the box ends above 84.3%. The chat reached 11% of the width in the
## tester's 1280x675 screenshot and 32% in a render box frame at its default
## UI scale. The probe's own choice, not a measurement of anything.
const FRAME_BOX := Rect2(0.35, 0.60, 0.45, 0.24)
## Every FRAME_STRIDE-th pixel in x and y.
const FRAME_STRIDE := 4
## A pixel is "neutral" when max(r,g,b) - min(r,g,b) <= NEUTRAL_SPREAD (0-255),
## "bright neutral" when it is neutral and its mean is >= BRIGHT_NEUTRAL. The
## investigators measured the tester's white flats at 205-227 on their JPEG,
## and the box draws the 0.5 grey base at 161 under GL Compatibility; 180 sits
## between them. Our cut, and a GL-only one: under Forward+ a calculation
## (Filmic tonemap, docs/RE_COMPLETION.md round 579) puts the same base at
## ~217, above 180, so there `bright_neutral` cannot tell a base drawn over
## the passes from a pass sampling a white texture. `tint` can on either
## renderer (magenta = a base, red = an opaque pass), and `neutral_p50` can
## when read against that renderer's own base value.
const NEUTRAL_SPREAD := 6
const BRIGHT_NEUTRAL := 180
## Red / magenta / blue pixels for the TINT step: the named channels each
## exceed the others by TINT_MARGIN (0-255). Our cut.
const TINT_MARGIN := 60
## A pixel an A/B step "changed": |dr|+|dg|+|db| against the baseline picture
## above this (0-765). Our cut.
const CHANGED_SUM := 24
## Log lines the investigators' hypotheses predict, counted in this entry's
## part of the log and in the whole log (key, text searched for).
const LOG_PATTERNS := [
	["not_in_lookup", "is not in the lookup"],
	["invalid_image", "Invalid image"],
	["image_data_size", "Expected Image data size"],
	["nothing_resolved", "NOTHING resolved"],
	["shader_param_null", "Parameter \"shader\" is null"],
	["cached_shader_failed", "Failed to load cached shader"],
	["shader_compile_failed", "shader failed to compile"],
	["shader_error", "SHADER ERROR"],
	["compilation_failed", "compilation failed"],
	["unable_to_bind", "unable to bind shader"],
	["uninitialized_rid", "uninitialized RID"],
	["previously_freed", "previously freed"],
	["texture_allocs_cache", "texture_allocs_cache"],
	["gl_error", "GL ERROR"],
	["script_error", "SCRIPT ERROR"],
	["pk2_could_not_open", "pk2: could not open"],
	["terrain_loaded", "loaded real terrain from"],
	["left_the_tree", "World3D: left the tree"],
]
## The most of the log the log scan reads (its tail).
const LOG_SCAN_BYTES := 16 * 1024 * 1024
## The line World3D._ready prints once per entry; the log after the last one
## is this entry's.
const ENTRY_MARKER := "character/item/NPC tables loaded"

var _world: Node
var _entry := 0
var _run := 0
var _tag := ""
var _mode := "full"
var _lines: PackedStringArray = []
var _file_path := ""
var _running := false
var _baseline: Dictionary = {}
var _focus := Vector3.ZERO
## The region under the player, as the read-only half found it.
var _group: Node3D
var _patch: MeshInstance3D
var _covering: Array[Node3D] = []
## One Dictionary per surface of _patch's mesh: i, mat, kind, key, tex.
var _surfaces: Array = []
## Every loaded region's terrain surfaces, for the A/B steps (_collect_targets).
var _targets: Array = []
## The A/B sequence and where it is.
var _steps: Array = []
var _step_index := -1
var _phase := ""
var _wait := 0
var _saved := {}
var _results: Array = []

## True while the A/B sequence is still stepping.
func is_running() -> bool:
	return _running

## The renderer, as a player's log must carry it: the GL adapter and driver,
## and the settings the hypotheses turn on. Printed by World3D at every entry
## (entry_line) and by the probe's `gpu` line. Godot 4.2.2 binds no
## OS.get_current_rendering_driver_name (ClassDB's OS method list on the render
## box), so the renderer actually running is read off the RenderingDevice --
## present under Forward+ / Mobile (Vulkan), absent under GL Compatibility --
## and the adapter's API string (a Vulkan version, a GL version, or ANGLE's).
## `project_method` is the project's setting as the engine read it: until
## round 581 this project's project.godot never set it (round 579: its `#`
## comment lines, which Godot 4.2's ConfigFile parser does not treat as
## comments, folded into the key), so it read forward_plus and a plain launch
## ran Vulkan Forward+; since round 581 it reads gl_compatibility.
##
## `driver_info` (OS.get_video_adapter_driver_info) only when asked -- the
## probe's `gpu` line, not the once-per-entry line: on Windows, Godot 4.2.2
## answers it with a synchronous WMI query, `SELECT * FROM
## Win32_PnPSignedDriver WHERE DeviceName = ...`, waiting up to 5 s in
## IEnumWbemClassObject::Next, on the calling (main) thread, and caches the
## answer only once it returns (platform/windows/os_windows.cpp,
## OS_Windows::get_video_adapter_driver_info, 4.2.2-stable). Read from source,
## not measured on Windows; either way a player's world entry does not pay it.
static func renderer_fields(with_driver_info: bool = true) -> String:
	var info := PackedStringArray(["(not queried at entry: /groundprobe's gpu line has it)"])
	if with_driver_info:
		info = PackedStringArray(OS.get_video_adapter_driver_info())
	return "running=%s adapter=\"%s\" vendor=\"%s\" type=%d api=\"%s\" driver_info=\"%s\" angle=%s rendering_device=%s project_method=%s gl_driver=%s gl_driver_windows=%s fallback_to_angle=%s depth_prepass=%s depth_prepass_disable_for=\"%s\" shader_cache=%s thread_model=%s verbose=%s" % [
		"RenderingDevice(Forward+/Mobile)" if RenderingServer.get_rendering_device() != null else "GL-Compatibility",
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_video_adapter_type(), RenderingServer.get_video_adapter_api_version(),
		" / ".join(info), str(RenderingServer.get_video_adapter_api_version().contains("ANGLE")),
		"present" if RenderingServer.get_rendering_device() != null else "none",
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")),
		str(ProjectSettings.get_setting("rendering/gl_compatibility/driver", "?")),
		str(ProjectSettings.get_setting("rendering/gl_compatibility/driver.windows", "?")),
		str(ProjectSettings.get_setting("rendering/gl_compatibility/fallback_to_angle", "?")),
		str(ProjectSettings.get_setting("rendering/driver/depth_prepass/enable", "?")),
		str(ProjectSettings.get_setting("rendering/driver/depth_prepass/disable_for_vendors", "?")),
		str(ProjectSettings.get_setting("rendering/shader_compiler/shader_cache/enabled", "?")),
		str(ProjectSettings.get_setting("rendering/driver/threads/thread_model", "?")),
		# --verbose: GLES3 then installs the ARB debug-output callback and logs
		# `GL ERROR:` lines (drivers/gles3/rasterizer_gles3.cpp, 4.2.2-stable).
		str(OS.is_stdout_verbose())]

## How this entry was reached: the first in the process, or after what the
## previous World3D recorded when it left (record_exit).
static func reached_text(entry: int) -> String:
	if entry <= 1:
		return "the first world entry of this process"
	var last := OS.get_environment(LAST_EXIT_ENV)
	return "re-entered after: %s" % (last if last != "" else "(no exit recorded)")

## World3D._ready's once-per-entry line, so any log a player sends carries
## the renderer without the command.
static func entry_line(entry: int, instance_id: int) -> String:
	return "World3D: entry %d (instance %d, %s) -- %s | Godot %s | %s %s" % [
		entry, instance_id, reached_text(entry), renderer_fields(false),
		Engine.get_version_info().string, OS.get_name(), OS.get_version()]

## Bumps and returns this process's world-entry count (ENTRY_ENV).
static func next_entry() -> int:
	var entry := OS.get_environment(ENTRY_ENV).to_int() + 1
	OS.set_environment(ENTRY_ENV, str(entry))
	return entry

## World3D._exit_tree calls this before it clears its caches: one line on how
## this entry ended, and its textures' GL names, both into the process
## environment for the next entry's probe.
static func record_exit(world: Node, connected: bool) -> void:
	OS.set_environment(LAST_EXIT_ENV, "entry %d (instance %d) exited at frame %d, connected=%s, grid builds %d" % [
		int(_member(world, "_world_entry", 0)), world.get_instance_id(), Engine.get_frames_drawn(),
		str(connected), int(_member(world, "_grid_builds", 0))])
	# Arrays, not PackedStringArrays: a packed array read out of a Dictionary
	# is a copy, and appending to it leaves the stored one empty.
	var by_kind := {}
	for row in gl_audit(world):
		var kind: String = row[0]
		if not by_kind.has(kind):
			by_kind[kind] = []
		(by_kind[kind] as Array).append(str(row[3]))
	var parts := PackedStringArray()
	for kind in by_kind:
		parts.append("%s:%s" % [kind, ",".join(PackedStringArray(by_kind[kind]))])
	OS.set_environment(PREV_GL_ENV, ";".join(parts))

## Every ground, lightmap and water-frame texture this world holds, as
## [kind, name, RID, GL name]: the ground-tile cache, each loaded region's
## lightmap (its terrain materials' detail_albedo since round 610, their
## ao_texture before) and the water frames. Kinds
## "ground", "lightmap", "water". The GL name is
## RenderingServer.texture_get_native_handle -- the GLES3 Texture's tex_id
## (drivers/gles3/storage/texture_storage.cpp, TextureStorage::
## texture_get_native_handle, 4.2.2-stable); 0 under the headless renderer.
## Under Forward+ / Mobile the same call returns the texture's VkImage handle
## (drivers/vulkan/rendering_device_vulkan.cpp, RenderingDeviceVulkan::
## texture_get_native_handle, 4.2.2-stable), not a GL name: the audit's
## "names" then mean nothing about GL, and its line says which it read
## (handle_kind).
static func gl_audit(world: Node) -> Array:
	var rows: Array = []
	var seen := {}
	var cache = _member(world, "_ground_texture_cache", {})
	if cache is Dictionary:
		for filename in cache:
			var tex = cache[filename]
			if tex is Texture2D:
				_audit_row(rows, seen, "ground", String(filename), tex)
	for group in terrain_groups(world):
		var patch := group.get_node_or_null("SubPatch") as MeshInstance3D
		if patch == null or patch.mesh == null:
			continue
		for i in range(patch.mesh.get_surface_count()):
			var mat := patch.mesh.surface_get_material(i) as BaseMaterial3D
			if mat != null and mat.detail_albedo != null:
				_audit_row(rows, seen, "lightmap", String(group.name), mat.detail_albedo)
			elif mat != null and mat.ao_texture != null:
				_audit_row(rows, seen, "lightmap", String(group.name), mat.ao_texture)
	var frames = _member(world, "_water_frames_cache", [])
	if frames is Array:
		for i in range((frames as Array).size()):
			var tex = frames[i]
			if tex is Texture2D:
				_audit_row(rows, seen, "water", "frame %d" % i, tex)
	return rows

static func _audit_row(rows: Array, seen: Dictionary, kind: String, name: String, tex: Texture2D) -> void:
	var rid := tex.get_rid()
	if seen.has(rid.get_id()):
		return
	seen[rid.get_id()] = true
	rows.append([kind, name, rid, RenderingServer.texture_get_native_handle(rid)])

## The world's RealTerrain_* groups, in child order.
static func terrain_groups(world: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	if world == null:
		return out
	for child in world.get_children():
		if child is Node3D and String(child.name).begins_with("RealTerrain"):
			out.append(child)
	return out

## Whether `point` (in the world's own space) lies inside `group`'s region:
## a terrain group's local space IS its region's [0, 1920) coordinate space
## (World3D._where_report). Transforms, not global_transform, so it also
## works on a world outside the tree (the headless suite).
static func covers(group: Node3D, point: Vector3) -> bool:
	var local := group.transform.affine_inverse() * point
	return local.x >= 0.0 and local.x < REGION_SPAN and local.z >= 0.0 and local.z < REGION_SPAN

## The picture statistics of `img` (values 0-255): over FRAME_BOX (the keys
## at the top level), over the whole frame (`full`, HUD included -- where the
## TINT colours land if the box missed the terrain), and the mean of the lower
## 40% (`lower40`, round 558's measurement). With a `reference` picture of the
## same size (the probe's baseline), `changed` in each is the fraction of
## sampled pixels whose |dr|+|dg|+|db| against it exceeds CHANGED_SUM: what an
## A/B step did to the picture wherever it happened. `rgb` is the RGB8 copy,
## kept as the next reference.
static func measure_image(img: Image, reference: Image = null) -> Dictionary:
	var out := {"ok": false}
	if img == null or img.is_empty():
		out["why"] = "no image"
		return out
	var rgb := img.duplicate() as Image
	if rgb.is_compressed():
		rgb.decompress()
	if rgb.get_format() != Image.FORMAT_RGB8:
		rgb.convert(Image.FORMAT_RGB8)
	var ref := PackedByteArray()
	if reference != null and reference.get_size() == rgb.get_size() and reference.get_format() == Image.FORMAT_RGB8:
		ref = reference.get_data()
	var box := _pixel_stats(rgb, FRAME_BOX, FRAME_STRIDE, ref)
	if int(box["samples"]) == 0:
		out["why"] = "empty box (%dx%d image)" % [rgb.get_width(), rgb.get_height()]
		return out
	out.merge(box)
	out["ok"] = true
	out["rgb"] = rgb
	out["frame"] = Engine.get_frames_drawn()
	out["size"] = "%dx%d" % [rgb.get_width(), rgb.get_height()]
	out["full"] = _pixel_stats(rgb, Rect2(0.0, 0.0, 1.0, 1.0), FRAME_STRIDE, ref)
	out["lower40"] = _pixel_stats(rgb, Rect2(0.0, 0.6, 1.0, 0.4), FRAME_STRIDE)["mean"]
	return out

## Every stride-th pixel of `rect` (fractions of the image) of an RGB8 image;
## `ref` (the same image size's RGB8 bytes, or empty) adds `changed`.
static func _pixel_stats(rgb: Image, rect: Rect2, stride: int, ref: PackedByteArray = PackedByteArray()) -> Dictionary:
	var w := rgb.get_width()
	var h := rgb.get_height()
	var data := rgb.get_data()
	var compare := ref.size() == data.size()
	var changed := 0
	var hist := PackedInt32Array()
	hist.resize(256)
	var n := 0
	var neutral := 0
	var bright := 0
	var red := 0
	var magenta := 0
	var blue := 0
	var sum_r := 0
	var sum_g := 0
	var sum_b := 0
	for y in range(int(h * rect.position.y), int(h * rect.end.y), stride):
		var row := y * w * 3
		for x in range(int(w * rect.position.x), int(w * rect.end.x), stride):
			var o := row + x * 3
			var r: int = data[o]
			var g: int = data[o + 1]
			var b: int = data[o + 2]
			n += 1
			if compare and absi(r - ref[o]) + absi(g - ref[o + 1]) + absi(b - ref[o + 2]) > CHANGED_SUM:
				changed += 1
			sum_r += r
			sum_g += g
			sum_b += b
			var hi: int = maxi(r, maxi(g, b))
			var lo: int = mini(r, mini(g, b))
			if hi - lo <= NEUTRAL_SPREAD:
				neutral += 1
				var luma: int = (r + g + b) / 3
				hist[luma] += 1
				if luma >= BRIGHT_NEUTRAL:
					bright += 1
			if r >= g + TINT_MARGIN and r >= b + TINT_MARGIN:
				red += 1
			elif r >= g + TINT_MARGIN and b >= g + TINT_MARGIN:
				magenta += 1
			elif b >= r + TINT_MARGIN and b >= g + TINT_MARGIN:
				blue += 1
	var d := float(maxi(n, 1))
	return {
		"samples": n,
		"mean": Vector3(sum_r, sum_g, sum_b) / d,
		"neutral": neutral / d,
		"bright_neutral": bright / d,
		"p5": _percentile(hist, neutral, 0.05),
		"p50": _percentile(hist, neutral, 0.50),
		"p95": _percentile(hist, neutral, 0.95),
		"red": red / d,
		"magenta": magenta / d,
		"blue": blue / d,
		"changed": changed / d if compare else -1.0,
	}

static func _percentile(hist: PackedInt32Array, total: int, q: float) -> int:
	if total <= 0:
		return -1
	var want := int(ceil(q * total))
	var acc := 0
	for v in range(256):
		acc += hist[v]
		if acc >= maxi(want, 1):
			return v
	return 255

## A frame-statistics Dictionary as one `key=value` string. `frame` is
## Engine.get_frames_drawn() when the picture was read; the picture is the
## frame drawn before it (qa_shot.sh's movie file f<frame - 1>): an A/B step
## is measured in _process and undone in the same call, so the file named by
## `frame` itself already shows it undone.
static func frame_text(m: Dictionary) -> String:
	if not m.get("ok", false):
		return "unavailable (%s)" % m.get("why", "?")
	var mean: Vector3 = m["mean"]
	var lower: Vector3 = m["lower40"]
	var full: Dictionary = m["full"]
	var fmean: Vector3 = full["mean"]
	return "frame=%d box=%s of %s samples=%d mean=(%.1f, %.1f, %.1f) neutral=%.3f bright_neutral=%.3f neutral_p5/p50/p95=%d/%d/%d red=%.3f magenta=%.3f blue=%.3f changed=%.3f | full_frame mean=(%.1f, %.1f, %.1f) neutral=%.3f neutral_p50/p95=%d/%d bright_neutral=%.3f red=%.3f magenta=%.3f blue=%.3f changed=%.3f | lower40_mean=(%.1f, %.1f, %.1f)" % [
		int(m.get("frame", -1)), str(FRAME_BOX), m["size"], m["samples"], mean.x, mean.y, mean.z, m["neutral"], m["bright_neutral"],
		m["p5"], m["p50"], m["p95"], m["red"], m["magenta"], m["blue"], float(m["changed"]),
		fmean.x, fmean.y, fmean.z, full["neutral"], full["p50"], full["p95"], full["bright_neutral"],
		full["red"], full["magenta"], full["blue"], float(full["changed"]), lower.x, lower.y, lower.z]

static func _member(obj: Object, name: String, default: Variant = null) -> Variant:
	if obj == null:
		return default
	var v = obj.get(name)
	return default if v == null else v

static func _rid_index(rid: RID) -> int:
	return rid.get_id() & 0xFFFFFFFF

# --- The run -------------------------------------------------------------

## Runs the read-only probe at once and, in "full" mode with this node in the
## tree, arms the A/B sequence (_process). Returns the lines for chat.
## `context` carries what only World3D knows cheaply: "connected", "zone".
func start(world: Node, entry: int, mode: String, focus: Vector3, context: Dictionary = {}) -> PackedStringArray:
	_world = world
	_entry = entry
	_mode = mode
	_focus = focus
	_run = OS.get_environment(RUNS_ENV).to_int() + 1
	OS.set_environment(RUNS_ENV, str(_run))
	_tag = "%s %d.%d" % [PREFIX, _entry, _run]
	# The picture first: nothing below has bound a texture yet.
	_baseline = _measure_frame()
	_emit("begin", "mode=%s entry=%d run=%d world_instance=%d frame=%d fps=%.1f ticks_ms=%d time=%s focus=%s" % [
		_mode, _entry, _run, world.get_instance_id(), Engine.get_frames_drawn(), Engine.get_frames_per_second(),
		Time.get_ticks_msec(), Time.get_datetime_string_from_system(), str(focus)])
	_emit("frame baseline", frame_text(_baseline))
	_emit("build", "client=\"%s\" engine=\"%s\" os=\"%s %s\" distribution=\"%s\" cpu=\"%s\" cores=%d" % [
		DebugPanel.build_description(), Engine.get_version_info().string, OS.get_name(), OS.get_version(),
		OS.get_distribution_name(), OS.get_processor_name(), OS.get_processor_count()])
	_emit("gpu", renderer_fields())
	_emit("entry", "entry=%d reached=\"%s\" grid_builds_this_entry=%d zone=%s connected=%s initial_load_done=%s cells_queued=%d cells_preparing=%d" % [
		_entry, reached_text(_entry), int(_member(world, "_grid_builds", 0)), str(context.get("zone", _member(world, "_current_zone_name", "?"))),
		str(context.get("connected", "?")), str(_member(world, "_initial_load_done", "?")),
		(_member(world, "_load_queue", []) as Array).size(), (_member(world, "_cell_jobs", []) as Array).size()])
	_probe_viewport()
	_probe_render()
	_probe_environment()
	_probe_caches()
	var summary := _probe_region()
	_probe_regions()
	_probe_objects()
	_probe_water()
	_probe_gl_names()
	_probe_shader_cache()
	_probe_log()
	_file_path = _write_file()
	var chat := PackedStringArray()
	chat.append("Ground probe %d.%d: %s | %s | picture: %s" % [_entry, _run,
		RenderingServer.get_video_adapter_name(), summary,
		"%.0f%% neutral grey-white" % (100.0 * float(_baseline["full"]["neutral"])) if _baseline.get("ok", false) else "not readable here"])
	if _mode == "full" and is_inside_tree() and _patch != null:
		_arm_steps()
		# Not a time: every step reads the whole frame back and walks it in
		# GDScript, which grows with the screen (about 88k samples a step at
		# 720p, 9x that at 4K), so the chat's "done" line is the signal.
		chat.append("Running %d quick checks -- hold still until the 'done' line; the ground may flash red, magenta, blue or flat grey." % _steps.size())
	else:
		chat.append("Saved to %s -- please send that file (or the log)." % ProjectSettings.globalize_path(_file_path))
		_finish_quietly()
	return chat

func _emit(section: String, body: String) -> void:
	var line := "%s %s: %s" % [_tag, section, body]
	print(line)
	_lines.append(line)

func _measure_frame() -> Dictionary:
	if not is_inside_tree():
		return {"ok": false, "why": "the probe is not in the scene tree"}
	var vp := get_viewport()
	if vp == null or vp.get_texture() == null:
		return {"ok": false, "why": "no viewport texture"}
	var reference: Image = _baseline.get("rgb") if _baseline.get("ok", false) else null
	return measure_image(vp.get_texture().get_image(), reference)

func _probe_viewport() -> void:
	# The root viewport either way: the world draws into it, and a probe
	# outside the tree (the headless suite) still has one to read.
	var vp: Viewport = get_viewport() if is_inside_tree() else (Engine.get_main_loop() as SceneTree).root
	if vp == null:
		_emit("viewport", "none")
		return
	_emit("viewport", "size=%s debug_draw=%d msaa_3d=%d screen_space_aa=%d scaling_3d_mode=%d scaling_3d_scale=%.2f mipmap_bias=%.2f debanding=%s transparent_bg=%s" % [
		str(vp.get_visible_rect().size), vp.debug_draw, vp.msaa_3d, vp.screen_space_aa, vp.scaling_3d_mode,
		vp.scaling_3d_scale, vp.texture_mipmap_bias, str(vp.use_debanding), str(vp.transparent_bg)])

func _probe_render() -> void:
	_emit("render", "tex_mem=%d buf_mem=%d video_mem=%d draw_calls_in_frame=%d objects_in_frame=%d primitives_in_frame=%d objects=%d nodes=%d orphans=%d resources=%d static_mem=%d" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		int(Performance.get_monitor(Performance.MEMORY_STATIC))])

func _probe_environment() -> void:
	var sun := _member(_world, "directional_light") as DirectionalLight3D
	var we := _member(_world, "world_environment") as WorldEnvironment
	var env: Environment = we.environment if we != null else null
	var line := "light_ready=%s light_diffuse=%s terrain_ambient=%s" % [
		str(_member(_world, "_env_light_ready", "?")), str(_member(_world, "_env_light_diffuse", "?")), str(_member(_world, "_env_terrain_ambient", "?"))]
	if sun != null:
		line += " sun_visible=%s sun_energy=%.3f sun_color=%s sun_shadows=%s sun_rotation_deg=%s" % [
			str(sun.visible), sun.light_energy, str(sun.light_color), str(sun.shadow_enabled), str(sun.rotation_degrees)]
	else:
		line += " sun=none"
	if env != null:
		line += " background=%d tonemap=%d exposure=%.3f white=%.3f ambient_source=%d ambient_color=%s ambient_energy=%.3f fog=%s fog_color=%s fog_density=%s adjustment=%s glow=%s" % [
			env.background_mode, env.tonemap_mode, env.tonemap_exposure, env.tonemap_white, env.ambient_light_source,
			str(env.ambient_light_color), env.ambient_light_energy, str(env.fog_enabled), str(env.fog_light_color),
			str(env.fog_density), str(env.adjustment_enabled), str(env.glow_enabled)]
	else:
		line += " environment=none"
	_emit("env", line)

func _probe_caches() -> void:
	var cache = _member(_world, "_ground_texture_cache", {})
	var nulls := 0
	if cache is Dictionary:
		for tex in cache.values():
			if tex == null:
				nulls += 1
	var commits = _member(_world, "_terrain_commits", {})
	var commit_total := 0
	var commit_max := 0
	if commits is Dictionary:
		for path in commits:
			commit_total += int(commits[path])
			commit_max = maxi(commit_max, int(commits[path]))
	var templates = _member(_world, "_object_templates")
	_emit("caches", "ground_textures=%d ground_nulls=%d water_frames=%d water_attempted=%s env_table=%s object_templates=%d object_textures=%d terrain_groups=%d terrain_commits=%d max_commits_of_one_region=%d" % [
		(cache as Dictionary).size() if cache is Dictionary else -1, nulls,
		(_member(_world, "_water_frames_cache", []) as Array).size(), str(_member(_world, "_water_frames_load_attempted", "?")),
		"loaded" if _member(_world, "_environment_table") != null else ("attempted" if _member(_world, "_environment_load_attempted", false) else "none"),
		templates.call("size") if templates != null and templates.has_method("size") else 0,
		(_member(_world, "_object_textures", {}) as Dictionary).size(),
		terrain_groups(_world).size(), commit_total, commit_max])

## The region under the player and every surface of its terrain mesh. Returns
## the chat summary's middle part.
func _probe_region() -> String:
	_covering.clear()
	for group in terrain_groups(_world):
		if covers(group, _focus):
			_covering.append(group)
	var centre = _member(_world, "_grid_centre_region", Vector2i.ZERO)
	if _covering.is_empty():
		_emit("region", "none: no loaded terrain group covers %s (grid centre %s, %d groups loaded)" % [
			str(_focus), str(centre), terrain_groups(_world).size()])
		return "no region under the player"
	_group = _covering[0]
	var local := _group.transform.affine_inverse() * _focus
	var parts := String(_group.name).split("_")
	var same_name := 0
	for group in terrain_groups(_world):
		if String(group.name).begins_with(String(_group.name)):
			same_name += 1
	var subpatches := 0
	for child in _group.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("SubPatch"):
			subpatches += 1
	_emit("region", "group=%s region=%s/%s local=(%.1f, %.1f) grid_centre=%s groups_covering_here=%d groups_named_alike=%d subpatches=%d" % [
		_group.name, parts[1] if parts.size() > 1 else "?", parts[2] if parts.size() > 2 else "?",
		local.x, local.z, str(centre), _covering.size(), same_name, subpatches])
	var meta: Dictionary = _group.get_meta("ground_probe", {})
	if meta.is_empty():
		_emit("commit", "not recorded (this group carries no ground_probe meta)")
	else:
		var commits = _member(_world, "_terrain_commits", {})
		var path: String = meta.get("mapm_path", "")
		_emit("commit", "mapm=%s commit=%s of %s in this world textured=%s baked=%s light_dir=%s light_diffuse=%s light_ambient=%s ids=%s resolved=%s decoded=%s no_entry=%s unreadable=%s uploaded=%s lightmap=%s at_frame=%s threaded=%s" % [
			path, str(meta.get("commit", "?")), str((commits as Dictionary).get(path, "?")) if commits is Dictionary else "?",
			str(meta.get("textured", "?")), str(meta.get("baked", "?")), str(meta.get("light_dir", "?")),
			str(meta.get("light_diffuse", "?")), str(meta.get("light_ambient", "?")),
			str(meta.get("ids", "?")), str(meta.get("resolved", "?")), str(meta.get("decoded", "?")),
			str(meta.get("no_entry", "?")), str(meta.get("unreadable", "?")), str(meta.get("uploaded", "?")),
			str(meta.get("lightmap", "?")), str(meta.get("frame", "?")), str(meta.get("threaded", "?"))])
	_patch = _group.get_node_or_null("SubPatch") as MeshInstance3D
	if _patch == null or _patch.mesh == null:
		_emit("surfaces", "none: %s has no SubPatch mesh" % _group.name)
		return "region %s: no terrain mesh" % _group.name
	var mesh := _patch.mesh
	var files := _texture_files()
	var texels := {}
	_surfaces.clear()
	var textured := 0
	var bound := 0
	for i in range(mesh.get_surface_count()):
		var mat := mesh.surface_get_material(i)
		var base_mat := mat as BaseMaterial3D
		var key := -2
		if mat != null and mat.has_meta("terrain_texture_key"):
			key = int(mat.get_meta("terrain_texture_key"))
		var kind := surface_kind(base_mat, i)
		_surfaces.append({"i": i, "mat": mat, "kind": kind, "key": key,
			"tex": base_mat.albedo_texture if base_mat != null else null})
		var line := "kind=%s key=%s %s %s" % [kind, str(key) if key != -2 else "?",
			material_fields(mat, files, texels, true), _vertex_fields(mesh, i)]
		if base_mat != null and base_mat.albedo_texture != null:
			textured += 1
			if _param_matches(base_mat):
				bound += 1
		_emit("surface %d" % i, line)
	if _patch.material_override != null:
		_emit("surface override", material_fields(_patch.material_override, files, texels, true))
	_probe_order()
	return "region %s: %d terrain surfaces, %d textured, %d with the texture in the renderer's material" % [
		_group.name, mesh.get_surface_count(), textured, bound]

## ground-tile filename by texture RID id, from the world's cache.
func _texture_files() -> Dictionary:
	var out := {}
	var cache = _member(_world, "_ground_texture_cache", {})
	if cache is Dictionary:
		for filename in cache:
			var tex = cache[filename]
			if tex is Texture2D:
				out[(tex as Texture2D).get_rid().get_id()] = String(filename)
	return out

## A terrain surface's part in MapmTerrainBuilder._textured_surfaces_from_cells:
## surface 0 the flat base, then one opaque pass per dominant tile ID
## ("opaque_flat" when it has no texture: the quads whose ID did not resolve),
## then the alpha overlays.
static func surface_kind(mat: BaseMaterial3D, i: int) -> String:
	if mat == null:
		return "other"
	if mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return "overlay"
	if mat.albedo_texture != null:
		return "opaque"
	return "base" if i == 0 else "opaque_flat"

static func _param_matches(mat: BaseMaterial3D) -> bool:
	if mat.albedo_texture == null:
		return false
	var param = RenderingServer.material_get_param(mat.get_rid(), "texture_albedo")
	return param is RID and param == mat.albedo_texture.get_rid()

## One material's fields: round 558's TEXPROBE set plus the RenderingServer's
## view of it. `texels` caches read-backs by texture RID within a run.
## The read-back (`readback`) is Texture2D.get_image, which is
## RenderingServer.texture_2d_get: under GLES3 it binds the texture's GL name
## on unit 0 and reads it with glGetCompressedTexImage / glGetTexImage
## (texture_storage.cpp, TextureStorage::texture_2d_get, 4.2.2-stable) -- so
## it proves the GL object's CONTENT, not what a draw call binds.
static func material_fields(mat: Material, files: Dictionary, texels: Dictionary, readback: bool) -> String:
	if mat == null:
		return "material=none"
	var line := "class=%s mat_rid=%d mat_rid_valid=%s priority=%d next_pass=%s" % [
		mat.get_class(), _rid_index(mat.get_rid()), str(mat.get_rid().is_valid()), mat.render_priority,
		str(mat.next_pass != null)]
	var bm := mat as BaseMaterial3D
	if bm == null:
		var sm := mat as ShaderMaterial
		if sm != null and sm.shader != null:
			line += " shader=%s" % sm.shader.resource_path
		return line
	line += " shading=%d transparency=%d depth_draw=%d cull=%d vcol_albedo=%s vcol_srgb=%s albedo=%s filter=%d repeat=%s uv1_scale=%s ao=%s" % [
		bm.shading_mode, bm.transparency, bm.depth_draw_mode, bm.cull_mode, str(bm.vertex_color_use_as_albedo),
		str(bm.vertex_color_is_srgb), str(bm.albedo_color), bm.texture_filter, str(bm.texture_repeat),
		str(bm.uv1_scale), str(bm.ao_enabled)]
	if bm.ao_enabled and bm.ao_texture != null:
		line += " ao_gl=%d" % RenderingServer.texture_get_native_handle(bm.ao_texture.get_rid())
	if bm.detail_enabled and bm.detail_albedo != null:
		line += " lightmap_detail_gl=%d" % RenderingServer.texture_get_native_handle(bm.detail_albedo.get_rid())
	var param = RenderingServer.material_get_param(bm.get_rid(), "texture_albedo")
	var tex := bm.albedo_texture
	if tex == null:
		line += " tex=false rs_albedo_param=%s" % (("rid %d" % _rid_index(param)) if param is RID and (param as RID).is_valid() else "none")
		return line
	var rid := tex.get_rid()
	line += " tex=true tex_class=%s file=%s tex_rid=%d rid_valid=%s gl=%d rs_format=%d param_match=%s size=%dx%d" % [
		tex.get_class(), files.get(rid.get_id(), "(not in the ground cache)"), _rid_index(rid), str(rid.is_valid()),
		RenderingServer.texture_get_native_handle(rid), RenderingServer.texture_get_format(rid),
		str(param is RID and param == rid), tex.get_width(), tex.get_height()]
	if readback:
		if not texels.has(rid.get_id()):
			texels[rid.get_id()] = texel_fields(tex)
		line += " " + String(texels[rid.get_id()])
	return line

## Format, mip count and the mean of 64 texels (8x8 grid) of `tex`, read back
## from the renderer and decompressed -- round 558's _qa_texel_mean, with the
## image's own format and mip count in front.
static func texel_fields(tex: Texture2D) -> String:
	var img := tex.get_image()
	if img == null or img.is_empty():
		return "readback=no-image"
	var head := "img_format=%d mips=%d" % [img.get_format(), img.get_mipmap_count()]
	if img.is_compressed() and img.decompress() != OK:
		return head + " texel_mean=undecompressable"
	var sum := Color(0.0, 0.0, 0.0, 0.0)
	for gy in range(8):
		for gx in range(8):
			sum += img.get_pixel(gx * img.get_width() / 8, gy * img.get_height() / 8)
	return head + " texel_mean=(%.2f, %.2f, %.2f)" % [sum.r / 64.0, sum.g / 64.0, sum.b / 64.0]

## The min and mean luma and the mean alpha of a surface's vertex colours --
## the baked light the unshaded terrain multiplies its texture by.
static func _vertex_fields(mesh: Mesh, i: int) -> String:
	var arrays := mesh.surface_get_arrays(i)
	var colors := PackedColorArray()
	if arrays.size() > Mesh.ARRAY_COLOR and arrays[Mesh.ARRAY_COLOR] != null:
		colors = arrays[Mesh.ARRAY_COLOR]
	var vmin := 1.0
	var vsum := 0.0
	var asum := 0.0
	for c: Color in colors:
		var luma: float = (c.r + c.g + c.b) / 3.0
		vmin = minf(vmin, luma)
		vsum += luma
		asum += c.a
	var count := maxi(colors.size(), 1)
	return "vcol_min=%.3f vcol_mean=%.3f vcol_alpha_mean=%.3f verts=%d" % [vmin, vsum / count, asum / count, colors.size()]

## The GLES3 opaque list sorts by priority, depth layer, flags, shader, then
## the material RID's local index (drivers/gles3/rasterizer_scene_gles3.h,
## the sort key, 4.2.2-stable, as the investigators read it); coplanar
## surfaces then resolve under GL_LEQUAL by draw order. So the base's index
## against the opaque passes' is printed, with no claim about the shader ids,
## which a script cannot read -- and, since round 580's fix, the priorities,
## which come first: `base_first_by_priority=true` (the base's priority
## below every opaque pass's) makes the RID order moot.
func _probe_order() -> void:
	var base := -1
	var base_priority := 0
	var opaque: Array[int] = []
	var opaque_priorities: Array[int] = []
	var overlay: Array[int] = []
	for s in _surfaces:
		var mat: Material = s["mat"]
		if mat == null:
			continue
		var idx := _rid_index(mat.get_rid())
		match String(s["kind"]):
			"base":
				base = idx
				base_priority = mat.render_priority
			"opaque":
				opaque.append(idx)
				opaque_priorities.append(mat.render_priority)
			"opaque_flat":
				opaque_priorities.append(mat.render_priority)
			"overlay":
				overlay.append(idx)
	var before := 0
	for idx in opaque:
		if base >= 0 and idx < base:
			before += 1
	var by_priority: bool = base >= 0 and not opaque_priorities.is_empty() and base_priority < int(opaque_priorities.min())
	_emit("order", "base_rid=%d opaque_rids=%s..%s overlay_rids=%s..%s opaque_below_base=%d of %d base_after_all_opaque=%s base_priority=%d opaque_priorities=%s..%s base_first_by_priority=%s" % [
		base, str(opaque.min()) if not opaque.is_empty() else "-", str(opaque.max()) if not opaque.is_empty() else "-",
		str(overlay.min()) if not overlay.is_empty() else "-", str(overlay.max()) if not overlay.is_empty() else "-",
		before, opaque.size(), str(not opaque.is_empty() and before == opaque.size()), base_priority,
		str(opaque_priorities.min()) if not opaque_priorities.is_empty() else "-",
		str(opaque_priorities.max()) if not opaque_priorities.is_empty() else "-", str(by_priority)])

## One compact line per loaded region, no read-backs: whether the state the
## region under the player is in is everyone's.
func _probe_regions() -> void:
	for group in terrain_groups(_world):
		var patch := group.get_node_or_null("SubPatch") as MeshInstance3D
		if patch == null or patch.mesh == null:
			_emit("regions", "%s: no SubPatch mesh" % group.name)
			continue
		var opaque := 0
		var overlays := 0
		var matched := 0
		var zero_gl := 0
		var base := -1
		var below := 0
		var base_priority := 0
		var pass_priority := 128
		var opaque_rids: Array[int] = []
		for i in range(patch.mesh.get_surface_count()):
			var mat := patch.mesh.surface_get_material(i) as BaseMaterial3D
			if mat == null:
				continue
			if mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				overlays += 1
			elif mat.albedo_texture != null:
				opaque += 1
				opaque_rids.append(_rid_index(mat.get_rid()))
				pass_priority = mini(pass_priority, mat.render_priority)
			elif i == 0:
				base = _rid_index(mat.get_rid())
				base_priority = mat.render_priority
			else:
				pass_priority = mini(pass_priority, mat.render_priority)
			if mat.albedo_texture != null:
				if _param_matches(mat):
					matched += 1
				if RenderingServer.texture_get_native_handle(mat.albedo_texture.get_rid()) == 0:
					zero_gl += 1
		for idx in opaque_rids:
			if base >= 0 and idx < base:
				below += 1
		var meta: Dictionary = group.get_meta("ground_probe", {})
		_emit("regions", "%s: here=%s surfaces=%d opaque=%d overlays=%d param_match=%d/%d gl_zero=%d opaque_below_base=%d base_first_by_priority=%s baked=%s commit=%s at_frame=%s resolved=%s/%s" % [
			group.name, str(_covering.has(group)), patch.mesh.get_surface_count(), opaque, overlays, matched,
			opaque + overlays, zero_gl, below, str(base >= 0 and pass_priority < 128 and base_priority < pass_priority),
			str(meta.get("baked", "?")), str(meta.get("commit", "?")),
			str(meta.get("frame", "?")), str(meta.get("resolved", "?")), str(meta.get("ids", "?"))])

## The nearest OBJECT_MATERIALS scenery materials to the player, for contrast:
## the buildings in the tester's picture are textured.
func _probe_objects() -> void:
	if _group == null:
		_emit("objects", "none: no region under the player")
		return
	var found: Array = [] # [distance, node, material, surface]
	# Scenery only (the region's RealMapObjects* containers): NPC bodies are
	# parented under the region too.
	var candidates: Array[Node] = []
	for child in _group.get_children():
		if String(child.name).begins_with("RealMapObjects"):
			candidates.append_array(child.find_children("*", "MeshInstance3D", true, false))
	for node in candidates:
		var mi := node as MeshInstance3D
		if mi == null or mi == _patch or mi.mesh == null or String(mi.name) == "Water":
			continue
		var mat: Material = mi.material_override
		var surface := -1
		if mat == null:
			for s in range(mi.mesh.get_surface_count()):
				mat = mi.get_surface_override_material(s)
				if mat == null:
					mat = mi.mesh.surface_get_material(s)
				if mat != null:
					surface = s
					break
		if mat == null:
			continue
		var at := _in_world(mi).origin
		found.append([at.distance_to(_focus), mi, mat, surface])
	found.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	if found.is_empty():
		_emit("objects", "none: no object mesh in %s" % _group.name)
		return
	var files := _texture_files()
	var texels := {}
	for k in range(mini(OBJECT_MATERIALS, found.size())):
		var row: Array = found[k]
		var mi: MeshInstance3D = row[1]
		_emit("object %d" % k, "node=%s distance=%.1f surface=%d %s" % [
			String(mi.get_parent().name) + "/" + String(mi.name), float(row[0]), int(row[3]),
			material_fields(row[2], files, texels, true)])

## `node`'s transform in the world's own space, by walking up to it -- works
## outside the tree too.
func _in_world(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != _world:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t

func _probe_water() -> void:
	var frames = _member(_world, "_water_frames_cache", [])
	var nulls := 0
	if frames is Array:
		for f in frames:
			if f == null:
				nulls += 1
	var water: MeshInstance3D = null
	if _group != null:
		water = _group.get_node_or_null("Water") as MeshInstance3D
	if water == null:
		_emit("water", "region_water=none frames_cached=%d frame_nulls=%d" % [(frames as Array).size() if frames is Array else -1, nulls])
		return
	var mat := water.material_override as BaseMaterial3D
	var anim: AnimatedTexture = null
	if mat != null:
		anim = mat.albedo_texture as AnimatedTexture
	var line := "region_water=present visible=%s frames_cached=%d frame_nulls=%d" % [str(water.visible), (frames as Array).size(), nulls]
	if mat != null:
		line += " transparency=%d albedo=%s" % [mat.transparency, str(mat.albedo_color)]
	if anim != null:
		var cur := anim.get_frame_texture(anim.current_frame)
		line += " anim_frames=%d current=%d proxy_rid_valid=%s proxy_gl=%d current_frame_gl=%d" % [
			anim.frames, anim.current_frame, str(anim.get_rid().is_valid()),
			RenderingServer.texture_get_native_handle(anim.get_rid()),
			RenderingServer.texture_get_native_handle(cur.get_rid()) if cur != null else -1]
	_emit("water", line)

## Every ground / lightmap / water GL name: any shared by two live RIDs (a GL
## name aliased), any 0 (no GL object), and how many the previous entry held
## too -- names are recycled after glDeleteTextures, so a match is only
## interesting beside other evidence. GL Compatibility only: under Forward+ /
## Mobile the handles are VkImages (gl_audit), and `handle_kind` says so.
func _probe_gl_names() -> void:
	var rows := gl_audit(_world)
	var by_name := {}
	var kinds := {}
	var zero := 0
	for row in rows:
		var handle: int = row[3]
		kinds[row[0]] = int(kinds.get(row[0], 0)) + 1
		if handle == 0:
			zero += 1
			continue
		if not by_name.has(handle):
			by_name[handle] = []
		(by_name[handle] as Array).append("%s:%s" % [row[0], row[1]])
	var shared := PackedStringArray()
	for handle in by_name:
		if (by_name[handle] as Array).size() > 1:
			shared.append("%d=%s" % [handle, "+".join(PackedStringArray(by_name[handle]))])
	var previous := {}
	var prev_raw := OS.get_environment(PREV_GL_ENV)
	for part in prev_raw.split(";", false):
		var kv := part.split(":", false)
		if kv.size() == 2:
			for name in kv[1].split(",", false):
				previous[name.to_int()] = kv[0]
	var recycled := {}
	for handle in by_name:
		if previous.has(handle):
			var was: String = previous[handle]
			recycled[was] = int(recycled.get(was, 0)) + 1
	_emit("glnames", "handle_kind=%s audited=%d kinds=%s gl_zero=%d shared_by_two_rids=%d%s previous_entry_names=%d recycled_from_previous=%s" % [
		"VkImage(not-GL-names)" if RenderingServer.get_rendering_device() != null else "GL-name",
		rows.size(), str(kinds), zero, shared.size(),
		(" [" + "; ".join(shared.slice(0, 8)) + "]") if not shared.is_empty() else "",
		previous.size(), str(recycled)])

## The GLES3 program-binary cache: files under user://shader_cache and how
## many this process has written (drivers/gles3/shader_gles3.cpp,
## ShaderGLES3::_save_to_cache; the directory from rasterizer_gles3.cpp,
## 4.2.2-stable). H5's precondition: session 2 loading binaries session 1
## re-exported in-process. A probe's own A/B steps can write to it too
## (CHECKS_FROM_ENV), so the files this process wrote before the first of
## them are counted apart (`written_before_probe_checks`, to the second:
## mtimes are whole seconds) -- on a second /groundprobe that, not
## `written_by_this_process`, is H5's number.
func _probe_shader_cache() -> void:
	var root := "user://shader_cache"
	if not DirAccess.dir_exists_absolute(root):
		_emit("shadercache", "dir=absent (%s)" % ProjectSettings.globalize_path(root))
		return
	var started := int(Time.get_unix_time_from_system() - Time.get_ticks_msec() / 1000.0)
	var checks_from := OS.get_environment(CHECKS_FROM_ENV).to_int()
	var per_top := {}
	var totals := [0, 0, 0, 0] # files, written by this process, newest mtime, written before the probe's checks
	_walk_cache(root, "", started, checks_from, per_top, totals, 0)
	var tops := PackedStringArray()
	for top in per_top:
		tops.append("%s=%d/%d" % [top, per_top[top][0], per_top[top][1]])
	_emit("shadercache", "dir=%s files=%d written_by_this_process=%d written_before_probe_checks=%d probe_checks_from_unix=%s newest_age_s=%d process_started_unix=%d per_shader(files/written)=%s" % [
		ProjectSettings.globalize_path(root), totals[0], totals[1], totals[3],
		str(checks_from) if checks_from > 0 else "none-yet",
		int(Time.get_unix_time_from_system()) - int(totals[2]) if totals[0] > 0 else -1, started, " ".join(tops)])

func _walk_cache(dir: String, top: String, started: int, checks_from: int, per_top: Dictionary, totals: Array, depth: int) -> void:
	if depth > 4:
		return
	for f in DirAccess.get_files_at(dir):
		var path := dir.path_join(f)
		var mtime := FileAccess.get_modified_time(path)
		totals[0] += 1
		var key := top if top != "" else "(root)"
		if not per_top.has(key):
			per_top[key] = [0, 0]
		per_top[key][0] += 1
		if mtime >= started:
			totals[1] += 1
			per_top[key][1] += 1
			if checks_from <= 0 or mtime < checks_from:
				totals[3] += 1
		totals[2] = maxi(int(totals[2]), mtime)
	for d in DirAccess.get_directories_at(dir):
		_walk_cache(dir.path_join(d), top if top != "" else d, started, checks_from, per_top, totals, depth + 1)

## The log lines the hypotheses predict, counted in this entry and in the whole
## log so far (print output may still be buffered, so the newest lines can be
## missing), and this region's own `ground textures for` line echoed.
func _probe_log() -> void:
	if not FileAccess.file_exists(LOG_PATH):
		_emit("logscan", "no log file at %s" % ProjectSettings.globalize_path(LOG_PATH))
		return
	var f := FileAccess.open(LOG_PATH, FileAccess.READ)
	if f == null:
		_emit("logscan", "cannot open %s" % ProjectSettings.globalize_path(LOG_PATH))
		return
	# A long session's log can run to many megabytes: its last LOG_SCAN_BYTES
	# are enough for the entries a reconnect report is about.
	var length := f.get_length()
	var scanned := "whole file"
	if length > LOG_SCAN_BYTES:
		f.seek(length - LOG_SCAN_BYTES)
		scanned = "last %d of %d bytes" % [LOG_SCAN_BYTES, length]
	var lines := f.get_buffer(mini(length, LOG_SCAN_BYTES)).get_string_from_utf8().split("\n")
	var entry_start := 0
	var entries := 0
	for i in range(lines.size()):
		if lines[i].contains(ENTRY_MARKER):
			entry_start = i
			entries += 1
	var here := {}
	var all := {}
	var examples := PackedStringArray()
	for i in range(lines.size()):
		var line := lines[i]
		if line.begins_with(PREFIX):
			continue
		for p in LOG_PATTERNS:
			if line.contains(p[1]):
				all[p[0]] = int(all.get(p[0], 0)) + 1
				if i >= entry_start:
					here[p[0]] = int(here.get(p[0], 0)) + 1
					if examples.size() < 4 and p[0] != "terrain_loaded" and p[0] != "left_the_tree":
						examples.append(line.strip_edges().left(240))
	var keys := PackedStringArray()
	for p in LOG_PATTERNS:
		keys.append("%s=%d/%d" % [p[0], int(here.get(p[0], 0)), int(all.get(p[0], 0))])
	_emit("logscan", "log_lines=%d (%s) entry_blocks=%d (this entry/whole log) %s" % [lines.size(), scanned, entries, " ".join(keys)])
	for e in examples:
		_emit("logscan example", e)
	var meta: Dictionary = _group.get_meta("ground_probe", {}) if _group != null else {}
	var path: String = meta.get("mapm_path", "")
	if path != "":
		for i in range(lines.size() - 1, entry_start - 1, -1):
			if lines[i].contains("ground textures for " + path):
				_emit("logscan ground", lines[i].strip_edges().left(300))
				break

func _write_file() -> String:
	var dir := "user://logs"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := dir.path_join("groundprobe-e%d-r%d-%s.txt" % [_entry, _run, Time.get_datetime_string_from_system().replace(":", "-")])
	if _file_path != "":
		path = _file_path
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("%s: could not write %s" % [_tag, path])
		return path
	file.store_string("\n".join(_lines) + "\n")
	file.close()
	return path

func _finish_quietly() -> void:
	_running = false
	if is_inside_tree():
		queue_free()

# --- The A/B sequence ----------------------------------------------------

func _arm_steps() -> void:
	# The first A/B sequence in this process: what the shader cache held
	# before any probe's steps compiled a variant (_probe_shader_cache).
	if OS.get_environment(CHECKS_FROM_ENV).to_int() <= 0:
		OS.set_environment(CHECKS_FROM_ENV, str(int(Time.get_unix_time_from_system())))
	_collect_targets()
	_steps = [
		{"name": "after_readback", "what": "nothing changed: the frame after the read-backs above, which bound textures on unit 0"},
		{"name": "sun_off", "what": "the directional light hidden (a baked, unshaded pass does not change; a shaded one does)",
			"apply": _ab_sun_off, "restore": _ab_sun_restore},
		{"name": "tint", "what": "every loaded region's terrain albedo_color: opaque textured passes red, bases magenta, overlays blue (white staying white = those surfaces ignore their material; magenta = a base drawn over the passes)",
			"apply": _ab_tint, "restore": _ab_tint_restore},
		{"name": "base_first", "what": "every region's base surface at render_priority -1, so it sorts before its opaque passes (on a build with the fix they are there already)",
			"apply": _ab_priority, "restore": _ab_priority_restore},
		{"name": "opaque_as_alpha", "what": "every opaque textured pass switched to TRANSPARENCY_ALPHA (drawn in the alpha pass)",
			"apply": _ab_alpha, "restore": _ab_alpha_restore},
		{"name": "fresh_materials", "what": "every region's base and opaque passes drawn with duplicate StandardMaterial3Ds (surface overrides): new RenderingServer materials, new RID indices; the copies keep the bases' render priority, so on a build with the fix this is the fix holding under new RID order",
			"apply": _ab_newmat, "restore": _ab_newmat_restore},
		{"name": "unfix_inverted", "what": "the fix undone on purpose: every region's base and opaque passes drawn with new materials whose RID indices put each base AFTER its passes, the base at the pre-fix render_priority %d (the mechanism on demand; flat ground here and not in fresh_materials = the fix is what keeps it textured)" % PRE_FIX_BASE_PRIORITY,
			"apply": _ab_unfix, "restore": _ab_unfix_restore},
		{"name": "unfix_inverted_tint", "what": "unfix_inverted again, tinted as `tint` does (opaque passes red, bases magenta, overlays blue): magenta = the base drawn over the passes",
			"apply": _ab_unfix_tint, "restore": _ab_unfix_restore},
	]
	if _covering.size() > 1:
		_steps.append({"name": "duplicates_hidden", "what": "every other terrain group covering this spot hidden",
			"apply": _ab_hide_dups, "restore": _ab_hide_dups_restore})
	_steps.append_array([
		{"name": "fresh_textures", "what": "every opaque pass given its tile decoded again from the .ddj (new texture objects)",
			"apply": _ab_fresh, "restore": _ab_fresh_restore},
		{"name": "retex", "what": "every opaque pass's albedo_texture set to null, then the same texture a frame later (kept)",
			"apply": _ab_retex, "mid": _ab_retex_mid},
		{"name": "remesh", "what": "every region's SubPatch mesh set to null, then the same mesh a frame later (kept)",
			"apply": _ab_remesh, "mid": _ab_remesh_mid},
		{"name": "final", "what": "nothing changed: after every step above"},
	])
	_step_index = 0
	_phase = "apply"
	_wait = 0
	_running = true
	_emit("ab", "armed %d steps, each held %d frames and measured like the baseline" % [_steps.size(), SETTLE_FRAMES])

func _process(_delta: float) -> void:
	if not _running:
		return
	if _wait > 0:
		_wait -= 1
		return
	var step: Dictionary = _steps[_step_index]
	if not is_instance_valid(_patch) or not _patch.is_inside_tree():
		# Put back what the step changed (a hidden sun would stay hidden).
		if _phase == "mid":
			_call_step(step, "mid")
		if _phase == "mid" or _phase == "measure":
			_call_step(step, "restore")
		_emit("ab", "stopped at step %s: the region's terrain left the tree" % step["name"])
		_finish()
		return
	match _phase:
		"apply":
			var note := _call_step(step, "apply")
			if note != "":
				_saved["note"] = note
			_phase = "mid"
			_wait = 1
		"mid":
			_call_step(step, "mid")
			_phase = "measure"
			_wait = SETTLE_FRAMES
		"measure":
			var m := _measure_frame()
			m.erase("rgb")
			_results.append([step["name"], m])
			var delta := ""
			if m.get("ok", false) and _baseline.get("ok", false):
				delta = " bright_neutral_vs_baseline=%+.3f" % (float(m["bright_neutral"]) - float(_baseline["bright_neutral"]))
			_emit("ab %s" % step["name"], "%s%s | %s%s" % [frame_text(m), delta, step["what"],
				(" | " + String(_saved["note"])) if _saved.has("note") else ""])
			_saved.erase("note")
			_call_step(step, "restore")
			_phase = "next"
			_wait = RESTORE_FRAMES
		"next":
			_step_index += 1
			_phase = "apply"
			if _step_index >= _steps.size():
				_finish()

func _call_step(step: Dictionary, which: String) -> String:
	if not step.has(which):
		return ""
	var result = (step[which] as Callable).call()
	return String(result) if result is String else ""

## The summary: per step, how much of the whole picture changed against the
## baseline and how much of it is then neutral grey-white, with that grey's
## median -- the columns the hypotheses' table is read in.
func _finish() -> void:
	_running = false
	var parts := PackedStringArray()
	for r in _results:
		var m: Dictionary = r[1]
		if m.get("ok", false):
			var full: Dictionary = m["full"]
			parts.append("%s=%.3f/%.3f/%d" % [r[0], float(full["changed"]), float(full["neutral"]), int(full["p50"])])
		else:
			parts.append("%s=n/a" % r[0])
	var base_text := "n/a"
	if _baseline.get("ok", false):
		var bfull: Dictionary = _baseline["full"]
		base_text = "%.3f/%d" % [float(bfull["neutral"]), int(bfull["p50"])]
	# The tinted steps' magenta (the bases' tint) over the whole frame: a base
	# drawn over the passes shows as magenta there.
	var magenta := PackedStringArray()
	for r in _results:
		var m: Dictionary = r[1]
		if String(r[0]).contains("tint") and m.get("ok", false):
			magenta.append("%s=%.3f" % [r[0], float((m["full"] as Dictionary)["magenta"])])
	_emit("summary", "whole frame, changed-vs-baseline/neutral/neutral_p50 per step: baseline neutral/p50=%s %s | magenta: %s | %s" % [
		base_text, " ".join(parts), " ".join(magenta) if not magenta.is_empty() else "-", _fix_state()])
	_write_file()
	var text := "Ground probe %d.%d done -- saved to %s. Please send that file (or /log opens the folder)." % [
		_entry, _run, ProjectSettings.globalize_path(_file_path)]
	print("%s: %s" % [_tag, text])
	if is_instance_valid(_world) and _world.has_method("_log_system"):
		_world.call("_log_system", text)
	queue_free()

## Every terrain surface of every loaded region, for the A/B steps: the
## picture shows more than the region under the player.
func _collect_targets() -> void:
	_targets.clear()
	for group in terrain_groups(_world):
		var patch := group.get_node_or_null("SubPatch") as MeshInstance3D
		if patch == null or patch.mesh == null:
			continue
		for i in range(patch.mesh.get_surface_count()):
			var mat := patch.mesh.surface_get_material(i) as BaseMaterial3D
			if mat != null:
				_targets.append({"patch": patch, "i": i, "mat": mat, "kind": surface_kind(mat, i)})

func _materials_of(kinds: Array) -> Array:
	var out: Array = []
	for t in _targets:
		if kinds.has(t["kind"]) and is_instance_valid(t["patch"]):
			out.append(t)
	return out

func _ab_sun_off() -> String:
	var sun := _member(_world, "directional_light") as DirectionalLight3D
	if sun == null:
		return "no directional light"
	_saved["sun"] = sun.visible
	sun.visible = false
	return ""

func _ab_sun_restore() -> void:
	var sun := _member(_world, "directional_light") as DirectionalLight3D
	if sun != null and _saved.has("sun"):
		sun.visible = _saved["sun"]

func _ab_tint() -> String:
	var n := 0
	for t in _materials_of(["base", "opaque", "opaque_flat", "overlay"]):
		var mat: BaseMaterial3D = t["mat"]
		t["tint"] = mat.albedo_color
		n += 1
		match String(t["kind"]):
			"opaque":
				mat.albedo_color = Color(1.0, 0.0, 0.0, 1.0)
			"overlay":
				mat.albedo_color = Color(0.0, 0.0, 1.0, mat.albedo_color.a)
			_:
				mat.albedo_color = Color(1.0, 0.0, 1.0, 1.0)
	return "%d materials in %d regions" % [n, terrain_groups(_world).size()]

func _ab_tint_restore() -> void:
	for t in _targets:
		if t.has("tint"):
			(t["mat"] as BaseMaterial3D).albedo_color = t["tint"]
			t.erase("tint")

func _ab_priority() -> String:
	var n := 0
	var already := 0
	for t in _materials_of(["base"]):
		t["priority"] = (t["mat"] as Material).render_priority
		if int(t["priority"]) == -1:
			already += 1
		(t["mat"] as Material).render_priority = -1
		n += 1
	return "%d bases, %d of them at -1 already" % [n, already]

## Whether this build draws its bases first by priority (round 580's fix):
## per loaded region, the base's render priority against its opaque
## passes' (textured or flat). "with the fix" when every region's base is
## below all of its passes, "WITHOUT the fix" when none is.
func _fix_state() -> String:
	var base := {}
	var lowest := {}
	for t in _targets:
		if not is_instance_valid(t["patch"]):
			continue
		var key: int = (t["patch"] as Node).get_instance_id()
		var p := (t["mat"] as Material).render_priority
		match String(t["kind"]):
			"base":
				base[key] = p
			"opaque", "opaque_flat":
				lowest[key] = mini(int(lowest.get(key, p)), p)
	var fixed := 0
	var regions := 0
	for key in base:
		if not lowest.has(key):
			continue
		regions += 1
		if int(base[key]) < int(lowest[key]):
			fixed += 1
	var verdict := "with the fix" if regions > 0 and fixed == regions else ("WITHOUT the fix" if fixed == 0 else "partly fixed")
	return "%s: %d of %d regions draw their base first by render priority" % [verdict, fixed, regions]

func _ab_priority_restore() -> void:
	for t in _targets:
		if t.has("priority"):
			(t["mat"] as Material).render_priority = t["priority"]
			t.erase("priority")

func _ab_alpha() -> String:
	var n := 0
	for t in _materials_of(["opaque"]):
		t["alpha"] = (t["mat"] as BaseMaterial3D).transparency
		(t["mat"] as BaseMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		n += 1
	return "%d passes" % n

func _ab_alpha_restore() -> void:
	for t in _targets:
		if t.has("alpha"):
			(t["mat"] as BaseMaterial3D).transparency = t["alpha"]
			t.erase("alpha")

## Duplicates are new RenderingServer materials with the same settings. Their
## RID indices come from the allocator's free list as it stands, so the note
## says, per region, whether the new base landed above the new opaque passes
## -- the order the GLES3 / Forward+ opaque sort draws coplanar surfaces in.
func _ab_newmat() -> String:
	var base_rid := {}
	var opaque_rids := {}
	for t in _materials_of(["base", "opaque", "opaque_flat"]):
		var patch: MeshInstance3D = t["patch"]
		t["override"] = patch.get_surface_override_material(t["i"])
		var copy := (t["mat"] as Material).duplicate() as Material
		patch.set_surface_override_material(t["i"], copy)
		var idx := _rid_index(copy.get_rid())
		var key := patch.get_instance_id()
		if t["kind"] == "base":
			base_rid[key] = idx
		elif t["kind"] == "opaque":
			if not opaque_rids.has(key):
				opaque_rids[key] = []
			(opaque_rids[key] as Array).append(idx)
	var below := 0
	var total := 0
	for key in opaque_rids:
		for idx in opaque_rids[key]:
			total += 1
			if base_rid.has(key) and int(idx) < int(base_rid[key]):
				below += 1
	return "%s; new materials: %d of %d opaque passes got an RID index below their region's new base" % [_fix_state(), below, total]

## `mats` sorted by their RID's local index, lowest first (`index_of` maps a
## material to its index; the default reads the RID). The order the opaque
## sort draws same-priority, same-shader materials in.
static func sorted_by_rid(mats: Array, index_of: Callable = Callable()) -> Array:
	var f := index_of
	if not f.is_valid():
		f = func(m) -> int:
			return _rid_index((m as Material).get_rid())
	var out := mats.duplicate()
	out.sort_custom(func(a, b) -> bool: return int(f.call(a)) < int(f.call(b)))
	return out

## Every property and metadata entry of `src` copied onto `dst`, a material
## that already has its RID. Not only the PROPERTY_USAGE_STORAGE ones that
## Resource.duplicate copies: on an unshaded StandardMaterial3D the ao_*
## properties are listed with usage 0, and duplicate() drops the terrain's
## lightmap AO (measured headless on the box: a duplicate of an unshaded
## material with ao_enabled and an ao_texture has neither) -- which would
## also give the copy a different shader from the original's.
static func copy_material(src: Material, dst: Material) -> void:
	var skip := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
	for p in src.get_property_list():
		if (int(p["usage"]) & skip) != 0:
			continue
		var name: String = p["name"]
		if name == "script" or name == "resource_path":
			continue
		# Only what differs from the blank: setting a property to the value
		# it already has is not free -- BaseMaterial3D rejects
		# emission_intensity with an engine ERROR whenever physical light
		# units are off (scene/resources/material.cpp, 4.2.2-stable), which
		# put ~412 identical ERROR lines into every /groundprobe log and
		# pushed real errors out of /errors and /copy.
		var value = src.get(name)
		if typeof(value) == typeof(dst.get(name)) and value == dst.get(name):
			continue
		dst.set(name, value)
	for m in src.get_meta_list():
		dst.set_meta(m, src.get_meta(m))

## The fix undone, on purpose and deterministically: per region, one blank
## material per base and opaque pass is created FIRST, the blanks sorted by
## RID index, and each pass takes one of the lowest while the base takes the
## highest -- so the base sorts after every pass whatever the allocator's
## free list held (fresh_materials' duplicates get whatever order the free
## list gives). Each blank becomes a copy of its surface's material, set as
## the surface override; the base's copy is put back at the pre-fix
## priority. The originals are not touched. `tinted` colours the copies as
## `tint` does, and the overlays (originals, restored by _ab_tint_restore).
func _ab_unfix_apply(tinted: bool) -> String:
	var by_patch := {}
	for t in _materials_of(["base", "opaque", "opaque_flat"]):
		var key: int = (t["patch"] as Node).get_instance_id()
		if not by_patch.has(key):
			by_patch[key] = []
		(by_patch[key] as Array).append(t)
	var regions := 0
	var inverted := 0
	var passes := 0
	for key in by_patch:
		var rows: Array = by_patch[key]
		var ordered: Array = []
		var base_row = null
		for t in rows:
			if t["kind"] == "base":
				base_row = t
			else:
				ordered.append(t)
		if base_row != null:
			ordered.append(base_row)
		var blanks: Array = []
		for t in ordered:
			blanks.append(ClassDB.instantiate((t["mat"] as Material).get_class()))
		blanks = sorted_by_rid(blanks)
		var top_pass := -1
		for n in range(ordered.size()):
			var t: Dictionary = ordered[n]
			var copy: Material = blanks[n]
			copy_material(t["mat"], copy)
			if t["kind"] == "base":
				copy.render_priority = PRE_FIX_BASE_PRIORITY
			else:
				passes += 1
				top_pass = maxi(top_pass, _rid_index(copy.get_rid()))
			if tinted:
				(copy as BaseMaterial3D).albedo_color = Color(1.0, 0.0, 0.0, 1.0) if t["kind"] == "opaque" else Color(1.0, 0.0, 1.0, 1.0)
			var patch: MeshInstance3D = t["patch"]
			t["override"] = patch.get_surface_override_material(t["i"])
			patch.set_surface_override_material(t["i"], copy)
		regions += 1
		if base_row != null and _rid_index((base_row["patch"] as MeshInstance3D).get_surface_override_material(base_row["i"]).get_rid()) > top_pass:
			inverted += 1
	if tinted:
		for t in _materials_of(["overlay"]):
			var mat: BaseMaterial3D = t["mat"]
			t["tint"] = mat.albedo_color
			mat.albedo_color = Color(0.0, 0.0, 1.0, mat.albedo_color.a)
	return "%s (the originals); these copies: %d passes in %d regions, the base's copy at render_priority %d with an RID index above all its passes' in %d of %d regions" % [
		_fix_state(), passes, regions, PRE_FIX_BASE_PRIORITY, inverted, regions]

func _ab_unfix() -> String:
	return _ab_unfix_apply(false)

func _ab_unfix_tint() -> String:
	return _ab_unfix_apply(true)

func _ab_unfix_restore() -> void:
	_ab_newmat_restore()
	_ab_tint_restore()

func _ab_newmat_restore() -> void:
	for t in _targets:
		if t.has("override"):
			if is_instance_valid(t["patch"]):
				(t["patch"] as MeshInstance3D).set_surface_override_material(t["i"], t["override"])
			t.erase("override")

func _ab_hide_dups() -> String:
	var saved := []
	for k in range(1, _covering.size()):
		var g: Node3D = _covering[k]
		saved.append([g, g.visible])
		g.visible = false
	_saved["dups"] = saved
	return "%d hidden" % saved.size()

func _ab_hide_dups_restore() -> void:
	for row in _saved.get("dups", []):
		if is_instance_valid(row[0]):
			(row[0] as Node3D).visible = row[1]

## New ImageTextures from the archive for every opaque pass's tile, through
## World3D's own decode (_decode_ground_image) -- new RIDs and new GL objects
## holding the same bytes.
func _ab_fresh() -> String:
	var files := _texture_files()
	var archive = _world.call("_open_map_pk2_if_set") if _world.has_method("_open_map_pk2_if_set") else null
	if archive == null:
		return "no Map.pk2 open -- nothing decoded"
	var fresh := {}
	var passes := 0
	var gls := PackedStringArray()
	for t in _materials_of(["opaque"]):
		var mat: BaseMaterial3D = t["mat"]
		var old := mat.albedo_texture
		# Something other than the probe may have cleared it since
		# _collect_targets; such a pass is left as it is.
		if old == null:
			continue
		var filename: String = files.get(old.get_rid().get_id(), "")
		if filename == "":
			continue
		if not fresh.has(filename):
			var img = _world.call("_decode_ground_image", filename, archive)
			fresh[filename] = ImageTexture.create_from_image(img) if img is Image else null
			if fresh[filename] != null and gls.size() < 4:
				gls.append("%s=%d" % [filename, RenderingServer.texture_get_native_handle((fresh[filename] as Texture2D).get_rid())])
		if fresh[filename] != null:
			t["fresh_old"] = old
			mat.albedo_texture = fresh[filename]
			passes += 1
	return "%d passes re-textured from %d decoded files; new GL names %s" % [passes, fresh.size(), ", ".join(gls)]

func _ab_fresh_restore() -> void:
	for t in _targets:
		if t.has("fresh_old"):
			(t["mat"] as BaseMaterial3D).albedo_texture = t["fresh_old"]
			t.erase("fresh_old")

func _ab_retex() -> String:
	var n := 0
	for t in _materials_of(["opaque"]):
		t["retex"] = (t["mat"] as BaseMaterial3D).albedo_texture
		(t["mat"] as BaseMaterial3D).albedo_texture = null
		n += 1
	return "%d passes" % n

func _ab_retex_mid() -> void:
	for t in _targets:
		if t.has("retex"):
			(t["mat"] as BaseMaterial3D).albedo_texture = t["retex"]
			t.erase("retex")

func _ab_remesh() -> String:
	var meshes := {}
	for t in _targets:
		var patch: MeshInstance3D = t["patch"]
		if is_instance_valid(patch) and not meshes.has(patch.get_instance_id()):
			meshes[patch.get_instance_id()] = [patch, patch.mesh]
			patch.mesh = null
	_saved["meshes"] = meshes
	return "%d regions" % meshes.size()

func _ab_remesh_mid() -> void:
	var meshes: Dictionary = _saved.get("meshes", {})
	for key in meshes:
		var row: Array = meshes[key]
		if is_instance_valid(row[0]):
			(row[0] as MeshInstance3D).mesh = row[1]
	_saved.erase("meshes")
