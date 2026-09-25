extends PanelContainer
class_name DebugPanel

## The debug panel, F3 in the world: everything a tester would otherwise
## have to be asked for, on one screen, with a Copy button.
##
## What it shows is what has settled this project's bug reports so far --
## which build is running (a screenshot of an old release against a new
## server looks like six unrelated bugs), where the player is in region
## terms, what every nearby entity resolved to and from which archive,
## what failed to load, and how long a frame takes. What it changes is
## the handful of things a player at a TV wants to change: UI scale, chat
## font, how near a name shows. Those three are remembered
## (ClientSettings); the draw mode, free camera and teleport are not.
##
## It reads World3D's state directly, underscored members included: this
## is a view of that scene, not a component with a contract of its own.

const REFRESH_SECONDS := 0.5
const SLOT_NAMES := {0: "helm", 1: "mail", 2: "shoulder", 3: "gauntlet", 4: "pants", 5: "boots", 6: "weapon", 7: "shield", 8: "extra"}
const DRAW_MODES := [
	["Normal", Viewport.DEBUG_DRAW_DISABLED],
	["Wireframe", Viewport.DEBUG_DRAW_WIREFRAME],
	["Unshaded", Viewport.DEBUG_DRAW_UNSHADED],
	["Overdraw", Viewport.DEBUG_DRAW_OVERDRAW],
	["Lighting", Viewport.DEBUG_DRAW_LIGHTING],
]
const NEAREST_PLATES_SHOWN := 10
## The original's three views, by the names its Option window uses.
const CAMERA_VIEWS := [
	["Free Movement View", "free"],
	["Third Person View", "third_person"],
	["Quarter Angle View", "quarter"],
]
## The token probed in the object name table, to show which language
## column the player's archive yields: "Mangyang" on an English column.
const NAME_PROBE_TOKEN := "SN_MOB_CH_MANGNYANG"

var _world: Node3D
var _text: RichTextLabel
var _since_refresh := 0.0
var _range_slider: HSlider
var _range_value: Label
var _scale_slider: HSlider
var _scale_value: Label
var _chat_font: SpinBox
var _draw_mode: OptionButton
var _view_mode: OptionButton
var _teleport_edit: LineEdit
var _free_camera: CheckButton
var _camera_mask := 0
var _build_line := ""
var _wireframes_generated := false

func _init(world: Node3D) -> void:
	_world = world
	name = "DebugPanel"
	visible = false
	_build_line = build_description()
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_left = 0.0
	anchor_top = 0.13
	anchor_right = 0.46
	anchor_bottom = 0.96
	offset_left = 8.0
	offset_right = -8.0
	var column := VBoxContainer.new()
	add_child(column)
	column.add_child(_build_button_row())
	column.add_child(_build_slider_row())
	column.add_child(_build_tools_row())
	column.add_child(_build_town_row())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = false
	_text.fit_content = true
	_text.scroll_active = false
	_text.selection_enabled = true
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.add_theme_font_size_override("normal_font_size", 13)
	scroll.add_child(_text)

func _build_button_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	var title := Label.new()
	title.text = "Debug"
	row.add_child(title)
	row.add_child(_button("Copy", _copy))
	row.add_child(_button("Save", _save))
	row.add_child(_button("Log folder", _open_log_folder))
	row.add_child(_button("Attack nearest", func(): _world._qa_attack_nearest()))
	row.add_child(_button("Hide UI", func(): _world._toggle_ui_visibility()))
	row.add_child(_button("Close", func(): visible = false))
	return row

func _build_slider_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(_label("Names within"))
	_range_slider = HSlider.new()
	_range_slider.min_value = 0.0
	_range_slider.max_value = 400.0
	_range_slider.step = 5.0
	_range_slider.value = _world._name_plate_range
	_range_slider.custom_minimum_size.x = 110.0
	_range_slider.value_changed.connect(_on_range_changed)
	row.add_child(_range_slider)
	_range_value = _label("%d" % int(_world._name_plate_range))
	row.add_child(_range_value)
	row.add_child(_label("  UI scale"))
	_scale_slider = HSlider.new()
	_scale_slider.min_value = 0.5
	_scale_slider.max_value = 3.0
	_scale_slider.step = 0.05
	_scale_slider.value = ClientSettings.ui_scale()
	_scale_slider.custom_minimum_size.x = 110.0
	_scale_slider.value_changed.connect(_on_scale_changed)
	row.add_child(_scale_slider)
	_scale_value = _label("%.2f" % ClientSettings.ui_scale())
	row.add_child(_scale_value)
	row.add_child(_label("  Chat font"))
	_chat_font = SpinBox.new()
	_chat_font.min_value = 0
	_chat_font.max_value = 72
	_chat_font.value = ClientSettings.chat_font_size()
	_chat_font.value_changed.connect(_on_chat_font_changed)
	row.add_child(_chat_font)
	return row

func _build_tools_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(_label("View"))
	_view_mode = OptionButton.new()
	for view in CAMERA_VIEWS:
		_view_mode.add_item(view[0])
		if view[1] == _world._camera_view:
			_view_mode.select(_view_mode.item_count - 1)
	_view_mode.item_selected.connect(_on_view_selected)
	row.add_child(_view_mode)
	row.add_child(_label("  Draw"))
	_draw_mode = OptionButton.new()
	# Reads the viewport's mode rather than assuming "Normal": debug_draw is
	# the root Window's, set by _on_draw_mode_selected and put back to
	# DEBUG_DRAW_DISABLED when the world leaves the tree (World3D._exit_tree,
	# round 560) -- it is not reset when this panel closes, because a draw
	# mode is chosen to look at the world with the panel out of the way.
	var viewport := _world.get_viewport()
	var current: int = viewport.debug_draw if viewport != null else Viewport.DEBUG_DRAW_DISABLED
	for mode in DRAW_MODES:
		_draw_mode.add_item(mode[0])
		if mode[1] == current:
			_draw_mode.select(_draw_mode.item_count - 1)
	_draw_mode.item_selected.connect(_on_draw_mode_selected)
	row.add_child(_draw_mode)
	_free_camera = CheckButton.new()
	_free_camera.text = "Camera through walls"
	_free_camera.toggled.connect(_on_free_camera_toggled)
	row.add_child(_free_camera)
	row.add_child(_label("  Teleport local x,z"))
	_teleport_edit = LineEdit.new()
	_teleport_edit.placeholder_text = "1002,917"
	_teleport_edit.custom_minimum_size.x = 100.0
	_teleport_edit.text_submitted.connect(func(_t): _teleport())
	row.add_child(_teleport_edit)
	row.add_child(_button("Go", _teleport))
	return row

## The towns, as the zone box's own `x/y@localX,localZ` targets -- the
## same strings that were being typed by hand, each a spot on the town's
## walkable graph. Travel goes through the server like any zone change.
const TOWNS := [
	["Jangan", "97/168@969,1369"],
	["Donwhang", "102/153@957,1508"],
	["Hotan", "92/135@1138,153"],
	["Constantinople", "105/79@950,1070"],
	["Samarkand", "106/108@270,1421"],
	["Alexandria", "90/48@663,526"],
]

func _build_town_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(_label("Go to"))
	for town in TOWNS:
		var target: String = town[1]
		row.add_child(_button(town[0], func() -> void:
			_world.zone_input.text = target
			_world._on_change_zone_pressed()
			_world._log_system("Travelling to %s (%s)" % [town[0], target])))
	return row

func _button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(on_pressed)
	return button

func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label

func _process(delta: float) -> void:
	if not visible:
		return
	_since_refresh += delta
	if _since_refresh < REFRESH_SECONDS:
		return
	_since_refresh = 0.0
	_text.text = diagnostics()

func toggle() -> void:
	visible = not visible
	if visible:
		_text.text = diagnostics()

## This build, as precisely as it can be named: the release tag for a
## downloaded build, and for a run from source the branch and commit read
## out of the checkout's own .git -- the one line that would have said an
## old release was talking to a new server.
static func build_description() -> String:
	var git := _git_head()
	if git != "":
		return "%s from source, %s" % [UpdateChecker.CLIENT_VERSION, git]
	return "%s (release build)" % UpdateChecker.CLIENT_VERSION

static func _git_head() -> String:
	var root := ProjectSettings.globalize_path("res://")
	var head := FileAccess.open(root.path_join("../.git/HEAD"), FileAccess.READ)
	if head == null:
		return ""
	var ref := head.get_as_text().strip_edges()
	if not ref.begins_with("ref: "):
		return ref.substr(0, 9)
	var branch := ref.substr(5)
	var hash := ""
	var ref_file := FileAccess.open(root.path_join("../.git/" + branch), FileAccess.READ)
	if ref_file != null:
		hash = ref_file.get_as_text().strip_edges()
	else:
		var packed := FileAccess.open(root.path_join("../.git/packed-refs"), FileAccess.READ)
		if packed != null:
			for line in packed.get_as_text().split("\n"):
				if line.ends_with(" " + branch):
					hash = line.split(" ")[0]
					break
	if hash == "":
		return branch.get_file()
	return "%s@%s" % [branch.get_file(), hash.substr(0, 9)]

## Everything, as plain text: what Copy and Save hand over.
func diagnostics() -> String:
	var lines := PackedStringArray()
	var p: Vector3 = _world.player.global_position
	lines.append("== build")
	lines.append("client %s" % _build_line)
	lines.append("Godot %s on %s | gpu %s | api %s" % [
		Engine.get_version_info().string, OS.get_name(),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version()])
	lines.append("log %s" % ProjectSettings.globalize_path("user://logs/srrevamp.log"))
	lines.append("settings %s" % ProjectSettings.globalize_path(ClientSettings.PATH))

	lines.append("== server")
	lines.append("%s:%d, %s | character %s | zone %s" % [
		NetClient.server_host, NetClient.server_port,
		"connected" if NetClient.is_connected_to_server() else "not connected",
		NetClient.current_character_name, _world._current_zone_name])

	lines.append("== player")
	lines.append("world %.1f, %.1f, %.1f | ground %.1f" % [p.x, p.y, p.z, _world._terrain_height_at(p)])
	var pair: Array = _world._nav_graph_for(p)
	if pair.size() >= 2 and pair[1] is Node3D:
		var group: Node3D = pair[1]
		var local: Vector3 = group.to_local(p)
		lines.append("region node %s | local %.1f, %.1f, %.1f" % [group.name, local.x, local.y, local.z])
	else:
		lines.append("region: not streamed in yet")
	var arm: SpringArm3D = _world.camera_arm
	lines.append("camera yaw %.0f pitch %.0f dist %.0f | gender %s | weapon group %s | names within %d" % [
		arm.rotation_degrees.y, arm.rotation_degrees.x, arm.spring_length,
		_world._player_gender, _world._player_weapon_group, int(_world._name_plate_range)])

	lines.append("== equipment (slot: item -> model)")
	# The last answer the server gave, not a fresh request: asking is a
	# coroutine, and this runs twice a second.
	var equipped: Dictionary = _world._player_equipped_last
	if equipped.is_empty():
		lines.append("nothing worn, or the equipment list has not arrived")
	var slots: Array = equipped.keys()
	slots.sort()
	for slot in slots:
		var item_id: int = int(equipped[slot])
		lines.append("%s: %d -> %s" % [SLOT_NAMES.get(slot, str(slot)), item_id,
			str(_world._item_models.get(item_id, "(no model in the item table)"))])

	lines.append("== other players (%d)" % _world._other_bodies.size())
	for id in _world._other_bodies:
		var body: Node3D = _world._other_bodies[id]
		var plate := body.get_node_or_null("Name") as Label3D
		var gait: Dictionary = _world._other_gaits.get(id, {})
		var worn: Dictionary = _world._other_equipped.get(id, {})
		lines.append("%s (id %d) %.0f away | %s, %s | worn %s" % [
			plate.text if plate != null else "?", id, body.global_position.distance_to(p),
			str(gait.get("gender", "?")), str(gait.get("group", "?")), str(worn)])

	lines.append("== monsters (%d)" % _world._monster_bodies.size())
	for id in _world._monster_bodies:
		var body: Node3D = _world._monster_bodies[id]
		var snap = _world._monster_snapshots.get(id)
		if snap == null:
			lines.append("id %d %.0f away" % [id, body.global_position.distance_to(p)])
			continue
		lines.append("%s (%s) %d/%d hp, %.0f away -> %s" % [
			snap.monster_name, snap.code_name if snap.code_name != "" else "no code",
			snap.hp, snap.max_hp, body.global_position.distance_to(p),
			_world._monster_model_path(snap.code_name, snap.monster_name)])

	var placed := 0
	for region in _world._npc_spawns_by_region:
		placed += (_world._npc_spawns_by_region[region] as Array).size()
	lines.append("== npcs: %d placed in %d region(s), %d named, %d with models" % [
		placed, _world._npc_spawns_by_region.size(), _world._npc_names.size(), _world._npc_models.size()])

	lines.append("== nearest name plates")
	var plates: Array = []
	for node in get_tree().get_nodes_in_group("name_plates"):
		var label := node as Label3D
		if label != null and label.is_inside_tree():
			plates.append([label.global_position.distance_to(p), label.text])
	plates.sort_custom(func(a, b): return a[0] < b[0])
	for i in range(mini(plates.size(), NEAREST_PLATES_SHOWN)):
		lines.append("%5.0f  %s" % [plates[i][0], plates[i][1]])

	lines.append("== archives")
	for entry in [["Data", Pk2Config.data_path()], ["Map", Pk2Config.map_path()], ["Media", Pk2Config.media_path()]]:
		var path: String = entry[1]
		var size_text := "missing"
		if path != "" and FileAccess.file_exists(path):
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				size_text = "%.1f MB" % (file.get_length() / 1048576.0)
		lines.append("%s %s (%s)" % [entry[0], path if path != "" else "(not set)", size_text])
	lines.append("species by code %d, by name %d" % [_world._monster_models_by_code.size(), _world._monster_models_by_name.size()])
	var names: UiTextTable = _world._object_name_table
	if names != null:
		lines.append("%s reads \"%s\" in this archive" % [NAME_PROBE_TOKEN, names.get_text(NAME_PROBE_TOKEN)])

	lines.append("== loading: %d failure(s)" % ObjectLoader.missing_count)
	for what in ObjectLoader.missing_recent:
		lines.append("  " + what)

	lines.append("== performance")
	lines.append("%d fps | frame %.1f ms, physics %.1f ms | draw calls %d | primitives %d | objects %d" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))])
	lines.append("video memory %.0f MB | static memory %.0f MB | nodes %d (%d orphaned)" % [
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))])

	# The tail of the log and the session's script errors, so a pasted report
	# carries what a tester would otherwise have to attach the log file for.
	var log_lines := _tail_log_lines(20)
	var errors: PackedStringArray = []
	for line in _tail_log_lines(400):
		if line.contains("SCRIPT ERROR") or line.begins_with("ERROR") or line.contains("Parse Error"):
			errors.append(line)
	if errors.size() > 20:
		errors = errors.slice(errors.size() - 20)
	lines.append("== script errors (%d)" % errors.size())
	for e in errors:
		lines.append("  " + e)
	lines.append("== last %d log lines" % log_lines.size())
	for l in log_lines:
		lines.append("  " + l)

	return "\n".join(lines)

## The last `n` lines of the session log (user://logs/srrevamp.log), or empty
## if it cannot be read -- for the Copy payload above.
func _tail_log_lines(n: int) -> PackedStringArray:
	var path := "user://logs/srrevamp.log"
	if not FileAccess.file_exists(path):
		return PackedStringArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedStringArray()
	var all := f.get_as_text().split("\n", false)
	if all.size() > n:
		return all.slice(all.size() - n)
	return all

func _copy() -> void:
	DisplayServer.clipboard_set(diagnostics())
	_world._log_system("Diagnostics copied to the clipboard")

func _save() -> void:
	var dir := ProjectSettings.globalize_path("user://logs")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("diag-%s.txt" % Time.get_datetime_string_from_system().replace(":", "-"))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_world._log_system("Could not write %s" % path)
		return
	file.store_string(diagnostics() + "\n")
	file.close()
	_world._log_system("Diagnostics saved to %s" % path)

func _open_log_folder() -> void:
	OS.shell_open(ProjectSettings.globalize_path("user://logs"))

func _on_range_changed(value: float) -> void:
	_world.set_name_plate_range(value)
	_range_value.text = "%d" % int(value)
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_NAME_PLATE_RANGE, value)

func _on_scale_changed(value: float) -> void:
	ClientSettings.apply_ui_scale(get_window(), value)
	_scale_value.text = "%.2f" % value
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_UI_SCALE, value)

func _on_chat_font_changed(value: float) -> void:
	# A click on the spinner's arrows grabs its inner line's focus (Godot 4.2
	# spin_box.cpp), and a focused line counts as typing (World3D._is_typing),
	# which stops movement. Hand the keyboard back once the value is set, so
	# a step with the arrows does not leave WASD dead (round 522).
	_chat_font.get_line_edit().release_focus()
	var size := int(value)
	var chat: RichTextLabel = _world.chat_log
	if size > 0:
		chat.add_theme_font_size_override("normal_font_size", size)
	else:
		chat.remove_theme_font_size_override("normal_font_size")
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_CHAT_FONT_SIZE, size)

func _on_view_selected(index: int) -> void:
	var view: String = CAMERA_VIEWS[index][1]
	_world.set_camera_view(view)
	ClientSettings.set_value(ClientSettings.SECTION_UI, ClientSettings.KEY_CAMERA_VIEW, view)

func _on_draw_mode_selected(index: int) -> void:
	var mode: int = DRAW_MODES[index][1]
	if mode == Viewport.DEBUG_DRAW_WIREFRAME and not _wireframes_generated:
		# Wireframes exist only for meshes created after this is switched
		# on, so the first choice of it shows the regions loaded from now.
		RenderingServer.set_debug_generate_wireframes(true)
		_wireframes_generated = true
		_world._log_system("Wireframes are generated for meshes loaded from now on; move to a new region to see them")
	get_viewport().debug_draw = mode

func _on_free_camera_toggled(on: bool) -> void:
	var arm: SpringArm3D = _world.camera_arm
	if on:
		_camera_mask = arm.collision_mask
		arm.collision_mask = 0
	else:
		arm.collision_mask = _camera_mask

func _teleport() -> void:
	var parts := _teleport_edit.text.split(",")
	if parts.size() < 2 or not parts[0].strip_edges().is_valid_float() or not parts[1].strip_edges().is_valid_float():
		_world._log_system("Teleport wants region-local \"x,z\", e.g. 1002,917")
		return
	if not _world._teleport_local(float(parts[0]), float(parts[1])):
		_world._log_system("Cannot teleport: this region has not streamed in yet")
