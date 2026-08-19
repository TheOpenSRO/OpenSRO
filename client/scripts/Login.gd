extends Control

## Login screen: connects to the Go server and sends OpLogin/OpRegister via
## the NetClient autoload, then moves to character select on success.

const SERVER_HOST := "127.0.0.1"
const SERVER_PORT := 15779

@onready var username_edit: LineEdit = $VBoxContainer/UsernameEdit
@onready var password_edit: LineEdit = $VBoxContainer/PasswordEdit
@onready var login_button: Button = $VBoxContainer/LoginButton
@onready var register_button: Button = $VBoxContainer/RegisterButton
@onready var status_label: Label = $VBoxContainer/StatusLabel

var _pending_action := "" # "login" or "register", sent once connected

func _ready() -> void:
	login_button.pressed.connect(_on_login_pressed)
	register_button.pressed.connect(_on_register_pressed)
	NetClient.connected.connect(_on_connected)
	NetClient.connection_failed.connect(_on_connection_failed)
	NetClient.login_result.connect(_on_login_result)
	NetClient.register_result.connect(_on_register_result)

func _on_login_pressed() -> void:
	_pending_action = "login"
	_connect_and_send()

func _on_register_pressed() -> void:
	_pending_action = "register"
	_connect_and_send()

func _connect_and_send() -> void:
	if NetClient.is_connected_to_server():
		_send_pending_action()
		return
	status_label.text = "Connecting..."
	NetClient.connect_to_server(SERVER_HOST, SERVER_PORT)

func _on_connected() -> void:
	_send_pending_action()

func _send_pending_action() -> void:
	var username := username_edit.text
	var password := password_edit.text
	if username.is_empty() or password.is_empty():
		status_label.text = "Username and password are required."
		return
	if _pending_action == "login":
		status_label.text = "Logging in..."
		NetClient.login(username, password)
	elif _pending_action == "register":
		status_label.text = "Registering..."
		NetClient.register_account(username, password)

func _on_connection_failed() -> void:
	status_label.text = "Could not connect to server."

func _on_login_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Login OK."
		get_tree().change_scene_to_file("res://scenes/CharacterSelect.tscn")
	else:
		status_label.text = "Login failed: %s" % reason

func _on_register_result(ok: bool, reason: String) -> void:
	if ok:
		status_label.text = "Registered — you can log in now."
	else:
		status_label.text = "Registration failed: %s" % reason
