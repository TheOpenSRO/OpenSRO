extends Control

## Character create: name the character, pick a body (China Man / China
## Woman -- the two the server supports), see a live 3D preview of it, and
## confirm. The preview is the real assembled body (CharacterPreview).
##
## Appearance sliders (figure / height / weapon / cloth) the original shows
## are deliberately absent: the server stores only the gender, and the client
## renders the body from that alone, so a slider here would change nothing --
## it goes in when there is a system behind it. Race is Chinese only for the
## same honesty reason: there are no European body assets yet. See
## docs/FRONTEND_CHECKLIST.md.

const BACKDROP_DDJ := "interface\\loading\\loading_charactercustom.ddj"

var _preview: CharacterPreview
var _name_edit: LineEdit
var _gender := CharacterNet.GENDER_CHINA_MAN
var _status: Label
var _man_button: Button
var _woman_button: Button

func _ready() -> void:
	_build_ui()
	NetClient.character_create_result.connect(_on_create_result)
	_preview.set_gender(_gender)

func _build_ui() -> void:
	add_child(FrontEndUi.ground())
	var media := FrontEndUi.open_media()
	var bg := FrontEndUi.backdrop(media, BACKDROP_DDJ)
	if bg != null:
		add_child(bg)
	add_child(FrontEndUi.header("CREATE A CHARACTER"))
	var screen := get_viewport_rect().size

	# Centre: the live 3D body.
	_preview = CharacterPreview.new(Vector2i(360, 680))
	_preview.custom_minimum_size = Vector2(360, 680)
	_preview.size = Vector2(360, 680)
	_preview.position = Vector2(screen.x * 0.5 - 180, 80)
	add_child(_preview)

	# Left: name and sex.
	var panel := FrontEndUi.plate()
	panel.position = Vector2(40, 100)
	panel.custom_minimum_size = Vector2(300, 320)
	panel.size = Vector2(300, 320)
	add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	panel.add_child(col)

	col.add_child(FrontEndUi.label("Name", 16))
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Character name"
	col.add_child(_name_edit)

	col.add_child(FrontEndUi.label("Sex", 16))
	var sex_row := HBoxContainer.new()
	sex_row.add_theme_constant_override("separation", 10)
	col.add_child(sex_row)
	var group := ButtonGroup.new()
	_man_button = _sex_button("Man", CharacterNet.GENDER_CHINA_MAN, group)
	_man_button.button_pressed = true
	sex_row.add_child(_man_button)
	_woman_button = _sex_button("Woman", CharacterNet.GENDER_CHINA_WOMAN, group)
	sex_row.add_child(_woman_button)

	var note := FrontEndUi.label("Appearance options arrive with the system\nbehind them.", 12, Color(0.7, 0.66, 0.55))
	col.add_child(note)

	# Bottom-right: Confirm / Cancel.
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	buttons.position = Vector2(screen.x - 260, screen.y - 66)
	add_child(buttons)
	var confirm := FrontEndUi.button("Confirm", Vector2(110, 40))
	confirm.pressed.connect(_on_confirm)
	buttons.add_child(confirm)
	var cancel := FrontEndUi.button("Cancel", Vector2(110, 40))
	cancel.pressed.connect(_back_to_select)
	buttons.add_child(cancel)

	_status = FrontEndUi.label("", 14, Color(0.6, 1.0, 0.6))
	_status.position = Vector2(40, screen.y - 30)
	add_child(_status)

	if not _preview.has_archives():
		_status.text = "No game data found -- the body preview needs your Data.pk2 / Media.pk2."

func _sex_button(text: String, gender: String, group: ButtonGroup) -> Button:
	var b := FrontEndUi.button(text, Vector2(120, 38))
	b.toggle_mode = true
	b.button_group = group
	b.pressed.connect(func():
		_gender = gender
		_preview.set_gender(gender))
	return b

func _on_confirm() -> void:
	var char_name := _name_edit.text.strip_edges()
	if char_name.is_empty():
		_status.text = "Enter a name first."
		return
	_status.text = "Creating..."
	NetClient.create_character(char_name, _gender)

func _on_create_result(ok: bool, reason: String) -> void:
	if ok:
		_back_to_select()
	else:
		_status.text = "Create failed: %s" % reason

func _back_to_select() -> void:
	get_tree().change_scene_to_file("res://scenes/CharacterSelect.tscn")
