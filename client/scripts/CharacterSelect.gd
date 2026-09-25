extends Control

## Character select: lists the account's characters, shows an honest stat
## panel for the selected one (name, level, and an HP bar -- the only
## per-character stats the server tracks; there is no MP / EXP / stat-point
## system yet, so none is shown rather than an invented value), and enters
## the world, deletes, or creates.
##
## The look is the original's, over real backdrop art from the player's own
## Media.pk2 (see FrontEndUi / docs/FRONTEND.md). The layout constants are
## ours, disclosed. The 3D character standing on the dock is a later pass;
## for now the stat panel carries the selection.

const BACKDROP_DDJ := "interface\\loading\\loading_constantinople.ddj"

var _summaries: Array = [] # of CharacterNet.Summary
var _selected := -1

var _list_box: VBoxContainer
var _list_group := ButtonGroup.new()
var _name_label: Label
var _level_label: Label
var _hp_bar: ProgressBar
var _hp_text: Label
var _status: Label
var _start_button: Button
var _delete_button: Button

func _ready() -> void:
	_build_ui()
	NetClient.character_list_result.connect(_on_list_result)
	NetClient.character_delete_result.connect(_on_delete_result)
	NetClient.enter_world_result.connect(_on_enter_world_result)
	# QA render hook: with no logged-in session this screen would list
	# nothing, so a render can inject clearly-fake sample characters to show
	# the populated layout. Off in real play; never shipped data.
	if OS.get_environment("SRREVAMP_QA_FAKECHARS") != "":
		_on_list_result(_qa_sample_characters(), "")
		return
	NetClient.list_characters()

func _qa_sample_characters() -> Array:
	var out: Array = []
	for spec in [["QA_Aria", CharacterNet.GENDER_CHINA_WOMAN, 1, 100], ["QA_Bram", CharacterNet.GENDER_CHINA_MAN, 1, 62], ["QA_Wei", CharacterNet.GENDER_CHINA_MAN, 1, 100]]:
		var s := CharacterNet.Summary.new()
		s.char_name = spec[0]
		s.gender = spec[1]
		s.level = spec[2]
		s.hp = spec[3]
		s.max_hp = 100
		out.append(s)
	return out

# --- Building the screen ---------------------------------------------------

func _build_ui() -> void:
	add_child(FrontEndUi.ground())
	var media := FrontEndUi.open_media()
	FrontEndUi.apply_client_font(self, media)
	var bg := FrontEndUi.backdrop(media, BACKDROP_DDJ)
	if bg != null:
		add_child(bg)
	add_child(FrontEndUi.vignette())
	add_child(FrontEndUi.header("CHARACTER SELECT"))

	# Left: the character list, in a plate below the header.
	var list_plate := FrontEndUi.plate()
	list_plate.position = Vector2(28, 78)
	list_plate.custom_minimum_size = Vector2(280, 460)
	list_plate.size = Vector2(280, 460)
	add_child(list_plate)
	var list_col := VBoxContainer.new()
	list_col.add_theme_constant_override("separation", 8)
	list_plate.add_child(list_col)
	var list_title := FrontEndUi.label("Characters", 16)
	list_col.add_child(list_title)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_col.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 4)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)

	# Right: the stat panel. Plain top-left coordinates in the 1280-wide
	# space (the root is full-rect); mixing an anchor preset with an absolute
	# position pushed it off-screen.
	var screen := get_viewport_rect().size
	var stat_plate := FrontEndUi.plate()
	stat_plate.position = Vector2(screen.x - 340, 78)
	stat_plate.custom_minimum_size = Vector2(300, 220)
	stat_plate.size = Vector2(300, 220)
	add_child(stat_plate)
	var stat_col := VBoxContainer.new()
	stat_col.add_theme_constant_override("separation", 12)
	stat_plate.add_child(stat_col)
	_name_label = FrontEndUi.label("-", 24)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stat_col.add_child(_name_label)
	_level_label = FrontEndUi.label("Level -", 16, Color(0.86, 0.82, 0.7))
	stat_col.add_child(_level_label)
	# HP bar (real). No MP/EXP bar -- not tracked; not faked.
	stat_col.add_child(FrontEndUi.label("HP", 13, Color(0.86, 0.82, 0.7)))
	var hp_row := Control.new()
	hp_row.custom_minimum_size = Vector2(0, 22)
	stat_col.add_child(hp_row)
	_hp_bar = ProgressBar.new()
	_hp_bar.show_percentage = false
	_hp_bar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hp_bar.add_theme_stylebox_override("background", FrontEndUi.plate_style(Color(0.12, 0.04, 0.04, 1.0), FrontEndUi.GOLD_EDGE))
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.78, 0.12, 0.10)
	fill.set_corner_radius_all(3)
	_hp_bar.add_theme_stylebox_override("fill", fill)
	hp_row.add_child(_hp_bar)
	_hp_text = FrontEndUi.label("-", 13)
	_hp_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_row.add_child(_hp_text)

	# Bottom-right: the actions.
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	buttons.position = Vector2(screen.x - 500, screen.y - 66)
	add_child(buttons)
	_start_button = FrontEndUi.button("Start", Vector2(110, 40))
	_start_button.pressed.connect(_on_enter_pressed)
	buttons.add_child(_start_button)
	var create_button := FrontEndUi.button("Create", Vector2(110, 40))
	create_button.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/CharacterCreate.tscn"))
	buttons.add_child(create_button)
	_delete_button = FrontEndUi.button("Delete", Vector2(110, 40))
	_delete_button.pressed.connect(_on_delete_pressed)
	buttons.add_child(_delete_button)
	var cancel_button := FrontEndUi.button("Cancel", Vector2(110, 40))
	cancel_button.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/Login.tscn"))
	buttons.add_child(cancel_button)

	_status = FrontEndUi.label("", 14, Color(0.6, 1.0, 0.6))
	_status.position = Vector2(28, screen.y - 30)
	add_child(_status)

# --- Data ------------------------------------------------------------------

func _on_list_result(characters: Array, error: String) -> void:
	if error != "":
		_status.text = "Error: %s" % error
		# The scripted reconnect stalls here too, with nothing in the log
		# (round 564's own review): say so, as the empty list below does.
		_qa_report(_status.text + " -- no list to start from, staying on the select screen")
		return
	_summaries = characters
	for child in _list_box.get_children():
		child.queue_free()
	for i in range(_summaries.size()):
		var summary = _summaries[i]
		var entry := Button.new()
		entry.toggle_mode = true
		entry.button_group = _list_group
		entry.text = summary.char_name
		entry.alignment = HORIZONTAL_ALIGNMENT_LEFT
		entry.add_theme_color_override("font_color", FrontEndUi.GOLD)
		entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var idx := i
		entry.pressed.connect(func(): _select(idx))
		_list_box.add_child(entry)
	if _summaries.is_empty():
		_status.text = "No characters yet -- Create one."
		# A scripted reconnect (round 558) has no one to start here and
		# stalls on this screen; say so in the log, which is all it can
		# read (round 558's review, landed in round 564). _qa_start reports
		# the other stall, a list without the QA character.
		_qa_report(_status.text + " -- nothing to start, staying on the select screen")
		_select(-1)
	else:
		# Keep the previous selection if still valid, else the first.
		var keep: int = _selected if _selected >= 0 and _selected < _summaries.size() else 0
		(_list_box.get_child(keep) as Button).button_pressed = true
		_select(keep)
		# SRREVAMP_QA_RECONNECT_VIA_LOGIN (round 558): a scripted reconnect
		# on the tester's route -- once the real list is in, start the QA
		# character the way a click on Start does.
		if OS.get_environment("SRREVAMP_QA_RECONNECT_VIA_LOGIN") != "":
			_qa_start(QaSignIn.character_name())

## SRREVAMP_QA_RECONNECT_VIA_LOGIN: select `who` in the list the server just
## sent and press Start. Says so when the name is not there rather than
## starting someone else.
func _qa_start(who: String) -> void:
	for i in range(_summaries.size()):
		if _summaries[i].char_name == who:
			(_list_box.get_child(i) as Button).button_pressed = true
			_select(i)
			print("QA RECONNECT: CharacterSelect starting %s at frame %d" % [who, Engine.get_frames_drawn()])
			_on_enter_pressed()
			return
	printerr("QA RECONNECT: CharacterSelect has no character named %s -- staying on the select screen" % who)

## Under SRREVAMP_QA_RECONNECT_VIA_LOGIN the status text also goes to the
## log, which is all a scripted run can read.
func _qa_report(text: String) -> void:
	if OS.get_environment("SRREVAMP_QA_RECONNECT_VIA_LOGIN") != "":
		print("QA RECONNECT: CharacterSelect: %s" % text)

func _select(index: int) -> void:
	_selected = index
	var has: bool = index >= 0 and index < _summaries.size()
	_start_button.disabled = not has
	_delete_button.disabled = not has
	if not has:
		_name_label.text = "-"
		_level_label.text = "Level -"
		_hp_bar.value = 0
		_hp_text.text = "-"
		return
	var s = _summaries[index]
	_name_label.text = s.char_name
	_level_label.text = "Level %d" % s.level
	_hp_bar.max_value = maxi(s.max_hp, 1)
	_hp_bar.value = s.hp
	_hp_text.text = "%d / %d" % [s.hp, s.max_hp]

func _selected_name() -> String:
	if _selected < 0 or _selected >= _summaries.size():
		return ""
	return _summaries[_selected].char_name

# --- Actions (NetClient wiring unchanged) ----------------------------------

func _on_delete_pressed() -> void:
	var char_name := _selected_name()
	if char_name.is_empty():
		_status.text = "Select a character first."
		return
	NetClient.delete_character(char_name)

func _on_delete_result(ok: bool, reason: String) -> void:
	if ok:
		_status.text = "Character deleted."
		_selected = -1
		NetClient.list_characters()
	else:
		_status.text = "Delete failed: %s" % reason

func _on_enter_pressed() -> void:
	var char_name := _selected_name()
	if char_name.is_empty():
		_status.text = "Select a character first."
		return
	_status.text = "Entering the world..."
	NetClient.enter_world(char_name)

func _on_enter_world_result(result: WorldNet.EnterWorldResult) -> void:
	if result.error != "":
		_status.text = "Malformed response: %s" % result.error
		_qa_report(_status.text)
		return
	if not result.ok:
		_status.text = "Enter world failed: %s" % result.reason
		_qa_report(_status.text)
		return
	_qa_report("entering the world at frame %d" % Engine.get_frames_drawn())
	get_tree().change_scene_to_file("res://scenes/World3D.tscn")
