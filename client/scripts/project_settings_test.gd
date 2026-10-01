extends SceneTree

## The settings in client/project.godot are the ones the engine applies.
##
## Godot 4.2.2 reads project.godot with VariantParser::parse_tag_assign_eof
## (core/variant/variant_parser.cpp, 4.2.2-stable), where only `;` starts a
## comment. A `#` line is not one: its characters are folded into the next
## key, and a quoted phrase in it restarts the key. From 2026-08-25 to round
## 581 three `#` comment blocks did exactly that, and the three settings
## under them never took effect -- the Compatibility renderer the project
## chose, the file logging switch and the font oversampling switch -- while
## the file read as if they had. Every player ran Forward+ on Vulkan.
##
## So this reads what the ENGINE made of the file, not the file's text: the
## rendering method it starts from, the values ProjectSettings holds,
## and the root window's oversampling flag. The text is only checked for the
## symptom (a key no one would write: over 120 characters, or holding a `#`
## or whitespace) and the cause (a `#` line).
##
## Run headless with no --rendering-driver or --rendering-method, as
## `client/tools/remote_godot.sh tests` and CI do: either flag would override
## the method under test.
##
## `godot4 --headless --path client --script res://scripts/project_settings_test.gd`

const PROJECT_FILE := "res://project.godot"
## Longer than any real setting name, measured on the box: 42 characters in
## this file (rendering/renderer/rendering_method.mobile), 81 in the engine's
## whole list (rendering/lights_and_shadows/directional_shadow/
## soft_shadow_filter_quality.mobile). The swallowed keys were 180, 296 and
## 400.
const KEY_LENGTH_LIMIT := 120

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## `_initialize`, not `_init`: `_init` runs when Main::start sets this script
## on the main loop, before Main::start hands the oversampling setting to the
## root window (main/main.cpp, 4.2.2), and an exit code set there is reset
## by the `os.set_exit_code(EXIT_SUCCESS)` that follows Main::start
## (platform/linuxbsd/godot_linuxbsd.cpp) -- CI reads the exit code.
func _initialize() -> void:
	# The value the engine starts its renderer from: main/main.cpp,
	# Main::setup, `rendering_method = GLOBAL_GET("rendering/renderer/
	# rendering_method")` when no flag names one, and GLOBAL_GET is
	# get_setting_with_override (core/config/project_settings.h, 4.2.2).
	# Godot 4.2 gives a script no call for the method actually running.
	var method: Variant = ProjectSettings.get_setting_with_override("rendering/renderer/rendering_method")
	_check(method == "gl_compatibility", "the engine starts the Compatibility renderer on this platform (got %s)" % var_to_str(method))
	_setting_is("rendering/renderer/rendering_method", "gl_compatibility")
	_setting_is("rendering/renderer/rendering_method.mobile", "gl_compatibility")

	_setting_is("debug/file_logging/enable_file_logging", true)
	_setting_is("debug/file_logging/log_path", "user://logs/srrevamp.log")
	_setting_is("debug/file_logging/max_log_files", 10)

	# On (round 672): glyphs are rasterised at the UI scale, every scale, and
	# the flag is on from start-up so it never toggles (ClientSettings.
	# apply_ui_scale has why a toggle is harmful).
	_setting_is("gui/fonts/dynamic_fonts/use_oversampling", true)
	# Main::start hands the setting to the root window (main/main.cpp,
	# `set_use_font_oversampling`); this is what Window::_update_viewport_size
	# reads.
	_check(get_root().is_using_font_oversampling(), "the root window drives font oversampling")

	var long_names: Array[String] = []
	for prop in ProjectSettings.get_property_list():
		var name: String = prop["name"]
		if name.length() > KEY_LENGTH_LIMIT:
			long_names.append("%d chars: %s..." % [name.length(), name.substr(0, 60)])
	_check(long_names.is_empty(), "no project setting is named with over %d characters %s" % [KEY_LENGTH_LIMIT, long_names])

	# ConfigFile parses with the same parse_tag_assign_eof, so its keys are
	# the keys the engine read.
	var cfg := ConfigFile.new()
	var err := cfg.load(PROJECT_FILE)
	_check(err == OK, "project.godot parses (error %d)" % err)
	var odd: Array[String] = []
	var key_count := 0
	for section in cfg.get_sections():
		for key in cfg.get_section_keys(section):
			key_count += 1
			var full := "%s/%s" % [section, key] if section != "" else key
			if full.length() > KEY_LENGTH_LIMIT or key.contains("#") or _has_whitespace(key):
				odd.append("%d chars: %s..." % [full.length(), full.substr(0, 60)])
	_check(key_count > 0, "project.godot has keys (%d)" % key_count)
	_check(odd.is_empty(), "every key in project.godot is a plain name %s" % [odd])
	for expected in [["rendering", "renderer/rendering_method"], ["debug", "file_logging/enable_file_logging"], ["gui", "fonts/dynamic_fonts/use_oversampling"]]:
		_check(cfg.has_section_key(expected[0], expected[1]), "project.godot sets %s/%s itself" % expected)

	var text := FileAccess.get_file_as_string(PROJECT_FILE)
	var hash_lines: Array[int] = []
	var lines := text.split("\n")
	for i in lines.size():
		if lines[i].strip_edges().begins_with("#"):
			hash_lines.append(i + 1)
	_check(hash_lines.is_empty(), "no line of project.godot starts with '#', which is not a comment there (lines %s)" % [hash_lines])

	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _setting_is(name: String, want: Variant) -> void:
	var has := ProjectSettings.has_setting(name)
	var got: Variant = ProjectSettings.get_setting(name) if has else null
	_check(has and typeof(got) == typeof(want) and got == want, "%s = %s (got %s)" % [name, var_to_str(want), var_to_str(got)])

static func _has_whitespace(s: String) -> bool:
	for c in [" ", "\t", "\n", "\r"]:
		if s.contains(c):
			return true
	return false
