extends RefCounted
class_name DevTools

## Round 848: whether this client shows its developer tools -- the Shift+F3
## debug panel, the one native-widget window left in the world (Godot's own
## buttons, sliders and line edits, dev-only by design). A player's release
## build has none: Shift+F3 is then retail's F3 (KeyMap.resolve; retail reads
## no modifier on an F key), and the panel is never built.
##
## On when any of these holds (OURS):
##   - OPENSRO_DEV is set and not "0" ("0" turns them off anywhere);
##   - the settings file has `[dev] tools=true` (ClientSettings), so a tester
##     on a release build can turn them on without a launcher change;
##   - this is a debug build (OS.is_debug_build: a run from source or the
##     editor, every QA run on the render box). Releases are exported with
##     --export-release (.github/workflows/release.yml), a release build.

const SECTION := "dev"
const KEY_TOOLS := "tools"

## Test seam: -1 asks the environment, 0 forces off, 1 forces on.
static var override := -1

static func enabled() -> bool:
	if override >= 0:
		return override == 1
	var env := OS.get_environment("OPENSRO_DEV")
	if env != "":
		return env != "0"
	if bool(ClientSettings.get_value(SECTION, KEY_TOOLS, false)):
		return true
	return OS.is_debug_build()
