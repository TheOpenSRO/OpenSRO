extends Node

# Entry point. Nothing is bundled with the client -- players point it at
# their own legally-owned pk2 files (not needed yet for the login/character
# select flow, only once real asset rendering exists). See Pk2Config for
# how those files are found: a real "pk2" folder next to the executable,
# or the SRREVAMP_*_PK2_PATH environment variables for development.
#
# Real auto-update check (2026-08-26, see docs/WORLD_ISSUES.md and
# AutoUpdater's own top comment for the honest scope: the check/download/
# relaunch mechanism hasn't been live-verified against a real published
# release yet). Runs once at boot, before Login -- a real newer build
# found is offered as an opt-in prompt, never applied silently.

var _updater: AutoUpdater

func _ready() -> void:
	print("SRRevamp boot: no bundled game data -- put your own *.pk2 files in the 'pk2' folder next to this executable.")
	print("SRRevamp log file: %s" % ProjectSettings.globalize_path("user://logs/srrevamp.log"))
	print("SRRevamp version: %s" % UpdateChecker.CLIENT_VERSION)
	# Before any screen draws, so the login screen is already the size the
	# player asked for last time (the debug panel changes it live).
	ClientSettings.apply_ui_scale(get_window(), ClientSettings.ui_scale())

	_updater = AutoUpdater.new()
	add_child(_updater)
	_updater.update_available.connect(_on_update_available)
	_updater.up_to_date.connect(_proceed_to_login)
	_updater.check_failed.connect(_on_update_check_failed)
	_updater.update_failed.connect(_on_update_failed)
	_updater.check_for_update()

func _on_update_check_failed(reason: String) -> void:
	# A real update check failing (no network, GitHub unreachable, etc.)
	# should never block a player from actually playing -- log it and
	# continue exactly as if no update were available.
	print("SRRevamp: update check failed (%s) -- continuing without one" % reason)
	_proceed_to_login()

func _on_update_failed(reason: String) -> void:
	printerr("SRRevamp: update failed (%s) -- continuing with the current version" % reason)
	_proceed_to_login()

func _on_update_available(tag: String, download_url: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Update available"
	dialog.dialog_text = "A new version (%s) is available. Download and restart now?" % tag
	add_child(dialog)
	dialog.confirmed.connect(func():
		print("SRRevamp: downloading update %s..." % tag)
		_updater.begin_download(download_url))
	dialog.canceled.connect(_proceed_to_login)
	dialog.popup_centered()

func _proceed_to_login() -> void:
	# Deferred: calling change_scene_to_file directly from _ready() fights
	# the scene tree's own in-progress node-addition for this node,
	# producing "Parent node is busy adding/removing children" errors.
	get_tree().change_scene_to_file.call_deferred("res://scenes/Login.tscn")
