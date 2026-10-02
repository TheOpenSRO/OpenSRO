extends RefCounted
class_name RendererChoice

## Which renderer the game starts with, chosen per install (round 693).
##
## project.godot's default is Forward+ (Vulkan). The other choice is the
## Compatibility renderer (OpenGL 3.3). Godot reads the renderer before any
## script runs, so a choice can only take effect at the next start, through
## the one file Godot 4.2.2 reads for that: `override.cfg` beside the
## executable (READ, core/config/project_settings.cpp, ProjectSettings::_setup:
## an exported game loads `res://override.cfg`, then
## `<executable's folder>/override.cfg`, over project.godot). The key is
## `[rendering] renderer/rendering_method`.
##
## **override.cfg is where the choice lives** -- the Options window reads it
## with `chosen()` and writes it with `choose()`; nothing else stores it. Two
## things write it as well, at boot (`apply_at_boot`, exported builds only):
## - `setting/config.yaml`'s `display.renderer` (`forward_plus` or
##   `compatibility`), when the file sets it: a private server or a player
##   picks the renderer there, and the file wins at every start (OURS).
## - a start on the command line's `--rendering-driver opengl3` (the
##   Compatibility launcher in the release zip, `srrevamp-compatibility.bat`
##   / `.sh`) with no choice recorded yet: the choice is written, so a plain
##   start, and the auto-updater's relaunch (which passes no arguments), stay
##   on Compatibility (OURS).
##
## Why the second: Godot 4.2.2 has NO automatic fall back from Vulkan to
## OpenGL (READ, platform/windows/display_server_windows.cpp,
## DisplayServerWindows::create_func: a failed Vulkan start shows "Unable to
## initialize Vulkan video driver" -- naming `--rendering-driver opengl3` --
## and the engine exits; main/main.cpp has no `fallback_to_opengl3`, which
## arrived in Godot 4.3). No script of ours runs on such a machine, so the
## launcher is its way in, once.
##
## A source run (the editor binary, the render box) reads `override.cfg` from
## the project folder instead, so nothing here writes outside an exported
## build; SRREVAMP_OVERRIDE_CFG names a file to use instead (tests, QA).

const FORWARD_PLUS := "forward_plus"
const COMPATIBILITY := "gl_compatibility"
const SECTION := "rendering"
const KEY := "renderer/rendering_method"
## The project.godot default (client/project.godot, round 693).
const PROJECT_DEFAULT := FORWARD_PLUS

const HEADER := "; Written by SRRevamp (round 693): the renderer this install starts with.\n; Delete this file to start with the default (Forward+).\n"

static func override_path() -> String:
	var env := OS.get_environment("SRREVAMP_OVERRIDE_CFG")
	if env != "":
		return env
	return OS.get_executable_path().get_base_dir().path_join("override.cfg")

## Whether this build reads override_path() at all: an exported game does;
## a run from source does not (it reads the project folder's).
static func applies_here() -> bool:
	return OS.get_environment("SRREVAMP_OVERRIDE_CFG") != "" or OS.has_feature("template")

## The renderer actually running. Godot 4.2.2 binds no call that names it;
## a RenderingDevice exists under Forward+ and Mobile, never under
## Compatibility (the same test as GroundProbe.renderer_fields).
## "none (headless)" under --headless.
static func running() -> String:
	# --headless draws nothing: the dummy rasterizer, under either setting.
	if DisplayServer.get_name() == "headless":
		return "none (headless)"
	return FORWARD_PLUS if RenderingServer.get_rendering_device() != null else COMPATIBILITY

## "forward_plus", "gl_compatibility", or "" when the file sets none.
static func chosen(path: String = "") -> String:
	var p := path if path != "" else override_path()
	var cfg := ConfigFile.new()
	if cfg.load(p) != OK:
		return ""
	var v := str(cfg.get_value(SECTION, KEY, ""))
	return v if v in [FORWARD_PLUS, COMPATIBILITY] else ""

## Normalises a word from a file or a window: "forward_plus"/"forward+"/
## "vulkan" and "compatibility"/"gl_compatibility"/"opengl"; "" otherwise.
static func normalise(word: String) -> String:
	var w := word.strip_edges().to_lower()
	if w in ["forward_plus", "forward+", "forwardplus", "vulkan"]:
		return FORWARD_PLUS
	if w in ["compatibility", "gl_compatibility", "opengl", "opengl3", "gl"]:
		return COMPATIBILITY
	return ""

## Records `method` for the next start. The default (Forward+) is recorded by
## removing the key; other keys a tester put in the file are kept, and a file
## left with nothing in it is deleted. Returns OK, or why it could not.
static func choose(method: String, path: String = "") -> Error:
	if not (method in [FORWARD_PLUS, COMPATIBILITY]):
		return ERR_INVALID_PARAMETER
	var p := path if path != "" else override_path()
	var cfg := ConfigFile.new()
	var had := cfg.load(p) == OK
	if method == PROJECT_DEFAULT:
		if not had or not cfg.has_section_key(SECTION, KEY):
			return OK
		cfg.erase_section_key(SECTION, KEY)
		if cfg.get_sections().is_empty():
			return DirAccess.remove_absolute(p)
	else:
		cfg.set_value(SECTION, KEY, method)
	var err := cfg.save(p)
	if err != OK:
		return err
	# ConfigFile writes no comments; the header says whose file it is.
	var text := FileAccess.get_file_as_string(p)
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(HEADER + text)
	f.close()
	return OK

## Whether the command line asked for the Compatibility renderer.
static func cmdline_asks_compatibility(args: PackedStringArray) -> bool:
	for i in args.size():
		var a := args[i]
		var v := ""
		if a in ["--rendering-driver", "--rendering-method"] and i + 1 < args.size():
			v = args[i + 1]
		elif a.begins_with("--rendering-driver=") or a.begins_with("--rendering-method="):
			v = a.get_slice("=", 1)
		if v.begins_with("opengl3") or v == COMPATIBILITY:
			return true
	return false

## What boot should record, given config.yaml's word ("" when unset), the
## command line, and the current choice: the method to write, or "" for
## nothing. Pure, so the tests can walk every case.
static func boot_decision(config_word: String, args: PackedStringArray, current: String) -> String:
	var want := normalise(config_word)
	if want != "":
		var effective := current if current != "" else PROJECT_DEFAULT
		return want if want != effective else ""
	if current == "" and cmdline_asks_compatibility(args):
		return COMPATIBILITY
	return ""

## Boot's part: one log line with the renderer running and the choice
## recorded, and the record brought in line with config.yaml / the launcher
## (see the header). Returns the line printed.
static func apply_at_boot(config_word: String) -> String:
	var here := applies_here()
	var path := override_path()
	var current := chosen(path) if here else ""
	var line := "RENDERER: running=%s adapter=\"%s\" api=\"%s\" project_default=%s" % [
		running(), RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_api_version(), PROJECT_DEFAULT]
	if not here:
		line += " override=(not read by a source run)"
		print(line)
		return line
	line += " override=%s chosen=%s" % [path, current if current != "" else "(none)"]
	var write := boot_decision(config_word, OS.get_cmdline_args(), current)
	if write != "":
		var err := choose(write, path)
		line += " -> recorded %s for the next start (%s)" % [write, "ok" if err == OK else "error %d" % err]
	print(line)
	return line
