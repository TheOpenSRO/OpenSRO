extends RefCounted
class_name DevTools

## Round 848: whether this client shows its developer tools -- the Shift+F3
## debug panel, the one native-widget window left in the world (Godot's own
## buttons, sliders and line edits, dev-only by design). With them off the
## panel is never built and Shift+F3 is retail's F3 (KeyMap.resolve; retail
## reads no modifier on an F key).
##
## Round 849: on by default in every build, release downloads included --
## every build is a developer's build for now (the user's call). Off when
## either of these holds (OURS):
##   - OPENSRO_DEV is "0" (any other value forces them on);
##   - the settings file has `[dev] tools=false` (ClientSettings).
## When the game ships to players, flip DEFAULT_ON to false (a release
## build then has none unless OPENSRO_DEV or `[dev] tools=true` asks).

## The default when neither OPENSRO_DEV nor the settings key says (round 849).
const DEFAULT_ON := true

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
	return bool(ClientSettings.get_value(SECTION, KEY_TOOLS, DEFAULT_ON))
