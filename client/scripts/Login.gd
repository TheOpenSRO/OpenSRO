extends Control

## Login screen: connects to the Go server and sends OpLogin/OpRegister via
## the NetClient autoload, then moves to character select on success.
##
## Server address is now user-entered (server_address_edit), not a fixed
## constant -- added 2026-08-26 so a friend on the same local network can
## type in the host's real LAN IP (e.g. "192.168.1.23:15779") instead of
## only ever being able to reach a server on the same machine. Defaults to
## "127.0.0.1:15779" (localhost, the same fixed value this project always
## used before) so existing single-machine setups keep working unchanged.

const DEFAULT_SERVER_PORT := 15779

@onready var server_address_edit: LineEdit = $VBoxContainer/ServerAddressEdit
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
	# The server that last answered, and the account name, come back from
	# the previous run (ClientSettings) so a tester on someone else's server
	# is not retyping "host:port" every launch. The password never does.
	var remembered_address := ClientSettings.server_address()
	if remembered_address != "":
		server_address_edit.text = remembered_address
	var remembered_username := ClientSettings.username()
	if remembered_username != "":
		username_edit.text = remembered_username

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
	var address := _parse_server_address(server_address_edit.text)
	if address.is_empty():
		status_label.text = "Enter a valid server address, e.g. 192.168.1.23:15779"
		return
	status_label.text = "Connecting..."
	NetClient.connect_to_server(address["host"], address["port"])

## Parses a user-entered "host" or "host:port" string into {"host", "port"}
## (port defaults to DEFAULT_SERVER_PORT if not given). Returns {} for an
## empty host or a non-numeric port, so the caller can show a real error
## instead of silently trying to connect somewhere wrong.
func _parse_server_address(text: String) -> Dictionary:
	text = text.strip_edges()
	if text.is_empty():
		return {}
	var host := text
	var port := DEFAULT_SERVER_PORT
	var colon := text.rfind(":")
	if colon != -1:
		host = text.substr(0, colon)
		var port_str := text.substr(colon + 1)
		if not port_str.is_valid_int():
			return {}
		port = port_str.to_int()
	if host.is_empty():
		return {}
	return {"host": host, "port": port}

func _on_connected() -> void:
	# Remembered only once the server has actually answered, so a typo is
	# not what greets the next launch.
	ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_ADDRESS, server_address_edit.text.strip_edges())
	ClientSettings.set_value(ClientSettings.SECTION_SERVER, ClientSettings.KEY_USERNAME, username_edit.text)
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
