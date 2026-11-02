extends Node

# Entry point. Nothing is bundled with the client -- players point it at
# their own legally-owned pk2 files (not needed yet for the login/character
# select flow, only once real asset rendering exists). See Pk2Config for
# how those files are found: a real "pk2" folder next to the executable,
# or the OPENSRO_*_PK2_PATH environment variables for development.
#
# Real auto-update check (2026-08-26, see docs/WORLD_ISSUES.md and
# AutoUpdater's own top comment for the honest scope: the check/download/
# relaunch mechanism hasn't been live-verified against a real published
# release yet). Runs once at boot, before Login -- a real newer build
# found is offered as an opt-in prompt, never applied silently.

var _updater: AutoUpdater

func _ready() -> void:
	print("OpenSRO boot: no bundled game data -- put your own *.pk2 files in the 'pk2' folder next to this executable.")
	print("OpenSRO log file: %s" % ProjectSettings.globalize_path("user://logs/opensro.log"))
	print("OpenSRO version: %s" % UpdateChecker.CLIENT_VERSION)
	# The renderer running, and the one recorded for the next start: an
	# exported game brings override.cfg in line with setting/config.yaml's
	# display.renderer, or records the Compatibility launcher's choice
	# (round 693, RendererChoice).
	RendererChoice.apply_at_boot(ClientConfig.load_default().renderer)
	# Round 760's review, F1: Compatibility on the separate render thread
	# restarts at once on the default one (RendererChoice).
	if RendererChoice.restarting:
		return
	# The native readers' state, once, at startup (round 668): ON, OFF because
	# the library is missing or refused, or forced OFF. A tester's log always
	# says which reader loaded their world.
	NativeAssets.available()
	# Round 789: the archive set -- the source mode, the asset packs over the
	# archives, any refused entries -- logged once at startup, on the main
	# thread (AssetArchives; the base archives open when first asked for).
	AssetArchives.current()
	# Round 763: whether EquipFx's effect masters simulate in Rust (the same
	# library), and on how many threads.
	EfpSimNative.available()
	# Whether a DXT1's transparent texels need RGBA8 here (round 695: Forward+
	# drops DXT1's alpha), decided once on the main thread and logged.
	print("DdjReader: DXT1 with transparent texels %s" % [
		"decoded to RGBA8 (a RenderingDevice renderer drops DXT1's alpha)" if DdjReader.dxt1_needs_alpha_format() else "kept as DXT1"])
	# A previous update's summary and leftovers (round 668, UpdateInstaller).
	AutoUpdater.after_update_startup()
	# Before any screen draws, so the login screen is already the size the
	# player asked for last time (the debug panel changes it live).
	# Round 854: the saved scale as far as the size the saved Resolution will
	# give the window allows (UiScaleChoices), so the display below places
	# the window for that scale and never raises a saved size for a larger
	# one; apply_saved after it fits the result.
	var saved_video := VideoOptions.in_force()
	var scale_target := get_window().size
	if not saved_video.fullscreen and saved_video.resolution.x > 0:
		scale_target = saved_video.resolution
	ClientSettings.apply_ui_scale(get_window(), UiScaleChoices.effective(UiScaleChoices.saved_percent(), scale_target) / 100.0)
	# The game's cursor from the first screen on (round 697): retail's first
	# process state sets resource cursor 0x95 before the login screen
	# (CPSVersionCheck::vslot_011 0x86d150, READ), read here from the
	# player's own sro_client.exe (GameCursor; the log names the file or
	# every path tried).
	GameCursor.load_once()
	GameCursor.show(CursorSet.ID_NORMAL, get_window())
	# Round 780: the game's own icon on the window and the taskbar, from the
	# same exe, in memory only (GameIcon).
	GameIcon.apply_once()
	# The Option window's Video tab (round 694): the window mode and size and
	# the brightness pass from the start, the login screen included; the
	# world applies the rest when it loads.
	var video := VideoOptions.in_force()
	VideoOptions.apply_display(get_window(), video)
	# Round 854: the saved UI scale, or the largest of the Option window's
	# list that fits the window the display left (UiScaleChoices); re-fitted
	# whenever the window changes size from now on.
	UiScaleChoices.apply_saved(get_window())
	VideoOptions.apply_brightness(get_tree().root, video.current().brightness)
	print("OpenSRO video: graphic %d, quality %d, brightness %d, fullscreen %s, resolution %s" % [
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
	print("OpenSRO: update check failed (%s) -- continuing without one" % reason)
	_proceed_to_login()

func _on_update_failed(reason: String) -> void:
	printerr("OpenSRO: update failed (%s) -- continuing with the current version" % reason)
	_proceed_to_login()

func _on_update_available(tag: String, download_url: String) -> void:
	# QA hook (round 668): accept without the dialog, for an unattended update
	# test against OPENSRO_QA_UPDATE_URL. OURS.
	if OS.get_environment("OPENSRO_QA_UPDATE_ACCEPT") == "1":
		print("OpenSRO: downloading update %s (accepted by OPENSRO_QA_UPDATE_ACCEPT)..." % tag)
		_updater.begin_download(download_url)
		return
	# Round 848: the question in the client's own message box (FrontMessageBox,
	# MsgBoxINIF's art and YES / NO), not Godot's ConfirmationDialog. OURS:
	# the retail client has no update prompt.
	var layer := CanvasLayer.new()
	layer.name = "UpdatePrompt"
	add_child(layer)
	# OURS: black under the box (Godot's grey clear colour showed before).
	layer.add_child(FrontEndUi.ground(Color.BLACK))
	var media := AssetArchives.media()
	var box := FrontMessageBox.new()
	layer.add_child(box)
	box.build(media, FrontMessageBox.load_text_table(media),
		UPDATE_LINE_1 % tag, UPDATE_LINE_2)
	UiSounds.play("snd_window_open", "update prompt")
	print("OpenSRO: update %s offered (FrontMessageBox)" % tag)
	box.accepted.connect(func():
		print("OpenSRO: downloading update %s..." % tag)
		layer.queue_free()
		_updater.begin_download(download_url))
	box.declined.connect(func():
		print("OpenSRO: update %s declined" % tag)
		layer.queue_free()
		_proceed_to_login())

## The update prompt's two lines (OURS).
const UPDATE_LINE_1 := "A new version (%s) is available."
const UPDATE_LINE_2 := "Download and restart now?"

func _proceed_to_login() -> void:
	# QA hook (round 668): stop here instead of opening Login, so an
	# unattended update test's relaunched client exits by itself and its log
	# is complete. OURS.
	if OS.get_environment("OPENSRO_QA_QUIT_AT_LOGIN") == "1":
		print("OpenSRO: quitting before Login (OPENSRO_QA_QUIT_AT_LOGIN)")
		get_tree().quit.call_deferred()
		return
	# Deferred: calling change_scene_to_file directly from _ready() fights
	# the scene tree's own in-progress node-addition for this node,
	# producing "Parent node is busy adding/removing children" errors.
	get_tree().change_scene_to_file.call_deferred("res://scenes/Login.tscn")
