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
	# The renderer running, and the one recorded for the next start: an
	# exported game brings override.cfg in line with setting/config.yaml's
	# display.renderer, or records the Compatibility launcher's choice
	# (round 693, RendererChoice).
	RendererChoice.apply_at_boot(ClientConfig.load_default().renderer)
	# The native readers' state, once, at startup (round 668): ON, OFF because
	# the library is missing or refused, or forced OFF. A tester's log always
	# says which reader loaded their world.
	NativeAssets.available()
	# Whether a DXT1's transparent texels need RGBA8 here (round 695: Forward+
	# drops DXT1's alpha), decided once on the main thread and logged.
	print("DdjReader: DXT1 with transparent texels %s" % [
		"decoded to RGBA8 (a RenderingDevice renderer drops DXT1's alpha)" if DdjReader.dxt1_needs_alpha_format() else "kept as DXT1"])
	# A previous update's summary and leftovers (round 668, UpdateInstaller).
	AutoUpdater.after_update_startup()
	# Before any screen draws, so the login screen is already the size the
	# player asked for last time (the debug panel changes it live).
	ClientSettings.apply_ui_scale(get_window(), ClientSettings.ui_scale())
	# The game's cursor from the first screen on (round 697): retail's first
	# process state sets resource cursor 0x95 before the login screen
	# (CPSVersionCheck::vslot_011 0x86d150, READ), read here from the
	# player's own sro_client.exe (GameCursor; the log names the file or
	# every path tried).
	GameCursor.load_once()
	GameCursor.show(CursorSet.ID_NORMAL, get_window())
	# The Option window's Video tab (round 694): the window mode and size and
	# the brightness pass from the start, the login screen included; the
	# world applies the rest when it loads.
	var video := VideoOptions.in_force()
	VideoOptions.apply_display(get_window(), video)
	VideoOptions.apply_brightness(get_tree().root, video.current().brightness)
	print("SRRevamp video: graphic %d, quality %d, brightness %d, fullscreen %s, resolution %s" % [
		video.active + 1, video.current().quality, video.current().brightness, str(video.fullscreen),
		VideoOptions.format_resolution(video.resolution) if video.resolution.x > 0 else "(as started)"])

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
	# QA hook (round 668): accept without the dialog, for an unattended update
	# test against SRREVAMP_QA_UPDATE_URL. OURS.
	if OS.get_environment("SRREVAMP_QA_UPDATE_ACCEPT") == "1":
		print("SRRevamp: downloading update %s (accepted by SRREVAMP_QA_UPDATE_ACCEPT)..." % tag)
		_updater.begin_download(download_url)
		return
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
	# QA hook (round 668): stop here instead of opening Login, so an
	# unattended update test's relaunched client exits by itself and its log
	# is complete. OURS.
	if OS.get_environment("SRREVAMP_QA_QUIT_AT_LOGIN") == "1":
		print("SRRevamp: quitting before Login (SRREVAMP_QA_QUIT_AT_LOGIN)")
		get_tree().quit.call_deferred()
		return
	# Deferred: calling change_scene_to_file directly from _ready() fights
	# the scene tree's own in-progress node-addition for this node,
	# producing "Parent node is busy adding/removing children" errors.
	get_tree().change_scene_to_file.call_deferred("res://scenes/Login.tscn")
