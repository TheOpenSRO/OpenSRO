extends SceneTree

## RendererChoice (round 693): the renderer an install starts with, recorded
## in override.cfg beside the game; config.yaml's display.renderer and the
## Compatibility launcher write it at boot.
##
## `godot4 --headless --path client --script res://scripts/setting/renderer_choice_test.gd`

var _failures := 0
var _dir := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_dir = OS.get_user_data_dir().path_join("renderer_choice_test_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_dir)
	_words()
	_file()
	_decision()
	_config_yaml()
	_godot_reads_it()
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(f))
	DirAccess.remove_absolute(_dir)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _words() -> void:
	for w in ["forward_plus", "Forward+", " vulkan "]:
		_check(RendererChoice.normalise(w) == RendererChoice.FORWARD_PLUS, "'%s' is Forward+" % w)
	for w in ["compatibility", "GL_Compatibility", "opengl"]:
		_check(RendererChoice.normalise(w) == RendererChoice.COMPATIBILITY, "'%s' is Compatibility" % w)
	for w in ["", "mobile", "d3d12", "fast"]:
		_check(RendererChoice.normalise(w) == "", "'%s' is no renderer" % w)
	_check(RendererChoice.PROJECT_DEFAULT == ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		"PROJECT_DEFAULT is project.godot's own rendering_method (%s)" % ProjectSettings.get_setting("rendering/renderer/rendering_method"))

func _file() -> void:
	var p := _dir.path_join("override.cfg")
	_check(RendererChoice.chosen(p) == "", "no file: nothing chosen")
	_check(RendererChoice.choose(RendererChoice.FORWARD_PLUS, p) == OK and not FileAccess.file_exists(p),
		"choosing the default with no file writes no file")
	_check(RendererChoice.choose(RendererChoice.COMPATIBILITY, p) == OK, "Compatibility is recorded")
	_check(RendererChoice.chosen(p) == RendererChoice.COMPATIBILITY, "and read back")
	var text := FileAccess.get_file_as_string(p)
	_check(text.begins_with("; Written by SRRevamp"), "the file says whose it is")
	_check(text.contains("[rendering]") and text.contains("renderer/rendering_method=\"gl_compatibility\""),
		"in the section and key Godot reads: %s" % text.c_escape())
	_check(RendererChoice.choose("mobile", p) == ERR_INVALID_PARAMETER, "only the two renderers are accepted")
	# A tester's own key is kept through both writes.
	var cfg := ConfigFile.new()
	cfg.load(p)
	cfg.set_value("rendering", "shader_compiler/shader_cache/enabled", false)
	cfg.save(p)
	_check(RendererChoice.choose(RendererChoice.FORWARD_PLUS, p) == OK and RendererChoice.chosen(p) == "",
		"choosing the default removes the key")
	cfg = ConfigFile.new()
	_check(cfg.load(p) == OK and cfg.get_value("rendering", "shader_compiler/shader_cache/enabled", true) == false,
		"and keeps the tester's own key")
	cfg.erase_section_key("rendering", "shader_compiler/shader_cache/enabled")
	cfg.save(p)
	RendererChoice.choose(RendererChoice.COMPATIBILITY, p)
	_check(RendererChoice.choose(RendererChoice.FORWARD_PLUS, p) == OK and not FileAccess.file_exists(p),
		"a file left empty is deleted")
	var junk := FileAccess.open(p, FileAccess.WRITE)
	junk.store_string("[rendering]\nrenderer/rendering_method=\"mobile\"\n")
	junk.close()
	_check(RendererChoice.chosen(p) == "", "a value other than the two reads as no choice")
	DirAccess.remove_absolute(p)

func _decision() -> void:
	var F := RendererChoice.FORWARD_PLUS
	var C := RendererChoice.COMPATIBILITY
	var H := "none (headless)"
	# [config word, running, current, expected]
	var cases := [
		["", F, "", ""],                    # Forward+ running, nothing set: nothing written
		["", C, C, ""],                     # a recorded choice stands
		["compatibility", F, "", C],        # the file asks for Compatibility
		["compatibility", C, C, ""],        # already recorded
		["forward_plus", C, C, F],          # the file wins over the record
		["forward_plus", F, "", ""],        # the default needs no record
		["forward_plus", C, "", ""],        # the file wins over the running renderer
		["", C, "", C],                     # running Compatibility (fall back / launcher), first time: recorded
		["", C, F, ""],                     # an explicit Forward+ record is never overwritten by it
		["", H, "", ""],                    # headless runs nothing: nothing written
		["bogus", C, "", C],                # an unusable word is no word
	]
	for c in cases:
		var got := RendererChoice.boot_decision(c[0], c[1], c[2])
		_check(got == c[3], "config '%s', running '%s', current '%s' -> '%s' (got '%s')" % [c[0], c[1], c[2], c[3], got])
	_check(not FileAccess.get_file_as_string("res://scripts/setting/renderer_choice.gd").contains("OS.get_cmdline_args()\n") \
		and not FileAccess.get_file_as_string("res://scripts/setting/renderer_choice.gd").contains("boot_decision(config_word, OS.get_cmdline_args()"),
		"boot never decides from OS.get_cmdline_args() (Godot consumes the renderer flags, round 693's review)")

func _config_yaml() -> void:
	var w := PackedStringArray()
	var c := ClientConfig.from_text("display:\n  renderer: compatibility\n", "config.yaml", w)
	_check(w.is_empty() and c.renderer == RendererChoice.COMPATIBILITY, "display.renderer: compatibility (%s)" % [w])
	w = PackedStringArray()
	c = ClientConfig.from_text("display:\n  renderer: Forward+\n", "config.yaml", w)
	_check(w.is_empty() and c.renderer == RendererChoice.FORWARD_PLUS, "display.renderer: Forward+")
	w = PackedStringArray()
	c = ClientConfig.from_text("display:\n  renderer: d3d12\n  vsync: on\n", "config.yaml", w)
	_check(c.renderer == "" and w.size() == 2, "an unknown renderer and an unknown key warn and are ignored: %s" % [w])
	w = PackedStringArray()
	c = ClientConfig.from_text("global:\n  region: US\n", "config.yaml", w)
	_check(c.renderer == "" and w.is_empty(), "no display section: no renderer")

## The file RendererChoice writes is one Godot itself loads over the project:
## ProjectSettings::_load_settings_text is what reads override.cfg, and
## ConfigFile parses with the same VariantParser (round 581's test says why),
## so the section/key it reads back is the setting's own path.
func _godot_reads_it() -> void:
	var p := _dir.path_join("override.cfg")
	RendererChoice.choose(RendererChoice.COMPATIBILITY, p)
	var cfg := ConfigFile.new()
	_check(cfg.load(p) == OK, "Godot's parser reads the written file")
	var full := "%s/%s" % [RendererChoice.SECTION, RendererChoice.KEY]
	_check(full == "rendering/renderer/rendering_method" and ProjectSettings.has_setting(full),
		"its section/key is the engine's own setting (%s)" % full)
	DirAccess.remove_absolute(p)
