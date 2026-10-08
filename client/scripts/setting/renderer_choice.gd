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
##   picks the renderer there, and the file wins at every start (OURS). It
##   cannot rescue a machine without Vulkan on its own: Boot never runs there
##   unless the start already fell back (below).
## - a start that is RUNNING Compatibility while nothing is recorded and the
##   project's default is Forward+ (OURS): it got there through the native
##   Vulkan fallback, the Compatibility launcher (`opensro-compatibility.bat`
##   / `.sh`, `--rendering-driver opengl3`) or a hand-typed flag, and the
##   choice is written so that plain starts, and the auto-updater's relaunch
##   (which passes no arguments), start on Compatibility directly. The
##   command line cannot tell: Godot 4.2.2's Main::setup consumes
##   `--rendering-driver` / `--rendering-method` (main/main.cpp 1020-1035),
##   so OS.get_cmdline_args() never holds them -- the round-693 review
##   MEASURED this, and the first cut, which looked there, never wrote the
##   file. The renderer RUNNING is what decides (running()).
##
## Why: Godot 4.2.2 has NO automatic fall back from Vulkan to OpenGL (READ,
## platform/windows/display_server_windows.cpp,
## DisplayServerWindows::create_func: a failed Vulkan start shows "Unable to
## initialize Vulkan video driver" -- naming `--rendering-driver opengl3` --
## and the engine exits; main/main.cpp has no `fallback_to_opengl3`, which
## arrived in Godot 4.3). The native library supplies one (native/src/
## vk_fallback.rs, round 693's review): at its Core initialisation, before
## Main reads the renderer, it asks the system's Vulkan loader for an
## instance and a physical device, and if there is none it starts the game
## again with `--rendering-driver opengl3` (OPENSRO_VK_PROBE carries what it
## found, and Boot logs it). Without the library (a player who deleted the
## DLL) there is no automatic fall back: the launcher is the way in.
##
## A source run (the editor binary, the render box) reads `override.cfg` from
## the project folder instead, so nothing here writes outside an exported
## build; OPENSRO_OVERRIDE_CFG names a file to use instead (tests, QA).

const FORWARD_PLUS := "forward_plus"
const COMPATIBILITY := "gl_compatibility"
const SECTION := "rendering"
const KEY := "renderer/rendering_method"
## Round 760: the render thread model a Compatibility install starts with --
## the default (1), not the project's separate thread (2). MEASURED on 4.7.2
## (GL Compatibility, the swarm lineup at 3,000): the separate thread crashed 3
## of 5 crowd boots (`FATAL: Index p_index = 0 is out of bounds` on a pool
## thread, then signal 4), the default 0 of 2; Forward+'s separate thread ran
## 15 x 300 s and 20+ crowd boots without one. The thread model is read in
## Main::setup, before the renderer, so it is chosen here with the renderer.
const THREAD_KEY := "driver/threads/thread_model"
const THREAD_SAFE := 1
## The project.godot default (client/project.godot, round 693).
const PROJECT_DEFAULT := FORWARD_PLUS

const HEADER := "; Written by OpenSRO (round 693): the renderer this install starts with.\n; Delete this file to start with the default (Forward+).\n"

static func override_path() -> String:
	var env := OS.get_environment("OPENSRO_OVERRIDE_CFG")
	if env != "":
		return env
	return OS.get_executable_path().get_base_dir().path_join("override.cfg")

## Whether this build reads override_path() at all: an exported game does;
## a run from source does not (it reads the project folder's).
static func applies_here() -> bool:
	return OS.get_environment("OPENSRO_OVERRIDE_CFG") != "" or OS.has_feature("template")

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
		if cfg.has_section_key(SECTION, THREAD_KEY) and int(cfg.get_value(SECTION, THREAD_KEY)) == THREAD_SAFE:
			cfg.erase_section_key(SECTION, THREAD_KEY)
		if cfg.get_sections().is_empty():
			return DirAccess.remove_absolute(p)
	else:
		cfg.set_value(SECTION, KEY, method)
		cfg.set_value(SECTION, THREAD_KEY, THREAD_SAFE)
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

static func _has_thread_key(path: String) -> bool:
	var cfg := ConfigFile.new()
	return cfg.load(path) == OK and cfg.has_section_key(SECTION, THREAD_KEY)

## What boot should record, given config.yaml's word ("" when unset), the
## renderer running (running()) and the current choice: the method to write,
## or "" for nothing. Pure, so the tests can walk every case.
static func boot_decision(config_word: String, running_now: String, current: String) -> String:
	var want := normalise(config_word)
	if want != "":
		var effective := current if current != "" else PROJECT_DEFAULT
		return want if want != effective else ""
	if current == "" and running_now == COMPATIBILITY and PROJECT_DEFAULT == FORWARD_PLUS:
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
	# What the native library's Vulkan probe found (vk_fallback.rs): "ok ..."
	# or "fallback to OpenGL: <why>"; unset without the library.
	var probe := OS.get_environment("OPENSRO_VK_PROBE")
	line += " vulkan_probe=\"%s\"" % (probe if probe != "" else "(none: no native library, or a named renderer)")
	if not here:
		line += " override=(not read by a source run)"
		print(line)
		return line
	line += " override=%s chosen=%s" % [path, current if current != "" else "(none)"]
	line += " render_thread=%s" % ("separate" if FrameSplit.render_threaded() else "main")
	var write := boot_decision(config_word, running(), current)
	# Round 760: a Compatibility choice recorded before the thread key existed
	# gets it now (the next start runs the default thread).
	if write == "" and current == COMPATIBILITY and not _has_thread_key(path):
		write = COMPATIBILITY
	if write != "":
		var err := choose(write, path)
		if err == OK:
			line += " -> recorded %s for the next start" % write
		else:
			# A folder the game cannot write (Program Files): the choice is not
			# kept, and the next plain start asks the native fall back again.
			line += " -> could NOT record %s in %s (error %d: is the game's folder writable?); the next start decides again" % [write, path, err]
	print(line)
	return line
