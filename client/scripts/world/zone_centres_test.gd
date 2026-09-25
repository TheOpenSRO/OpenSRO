extends SceneTree

## Every town's centre is the same on the server and the client (round 569):
## World3D._resolve_zone_region gives, for each label the server knows, the
## region server/internal/worldmap's ZoneCentre gives -- worldmap_test.go's
## TestZoneCentresAreTheTownsOwnRegions holds the server to the same rows.
## Run headless:
##   godot4 --headless --path client --script res://scripts/world/zone_centres_test.gd
##
## The rows are the game's own tables, measured on the render box on
## 2026-09-25 from /var/tmp/tables (npcpos.txt joined to characterdata on the
## first column, counted by the town's NPC code, against teleportdata.txt's
## GATE_<code> row; docs/RE_COMPLETION.md, round 569):
##   jangan 97/168          NPC_CH_ 18 of 67, GATE_CH 97/168
##   dunhuang, donwhang     NPC_WC_ 15 of 26, GATE_WC 102/153
##     102/153
##   constantinople 105/79  NPC_EU_ 10 of 33, GATE_EU 105/79
##   hotan 92/135           NPC_KT_ 6 of 29, GATE_KT 92/135
##   samarkand 106/107      UNRESOLVED, disclosed: NPC_CA_ 5/4/4/3 over the
##                          four regions at the 106-107/107-108 corner,
##                          GATE_CA 106/108; the client's constant, kept
## Until round 569 the client said dunhuang 98/157 and constantinople 104/80,
## and did not resolve "donwhang" at all (the label came back unchanged, so
## _zone_paths gave {} and a /goto donwhang left the placeholder ground):
## those rows fail here.
##
## World3D.gd is reached through load() and call(), so a missing function
## FAILS instead of failing to parse (round 563's pattern).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## World3D.gd needs the NetClient autoload registered before it compiles,
## which is the case in _initialize and not in _init (world3d_reentry_test.gd).
func _initialize() -> void:
	var S := load("res://scripts/World3D.gd") as GDScript
	_check(S != null and S.can_instantiate(), "World3D.gd loads and can instantiate headless")
	if S == null or not S.can_instantiate():
		_finish()
		return
	var w: Node = S.new()
	var want := {
		"jangan": "97/168",
		"dunhuang": "102/153",
		"donwhang": "102/153",
		"constantinople": "105/79",
		"hotan": "92/135",
		"samarkand": "106/107",
	}
	for zone in want:
		var got: String = w.call("_resolve_zone_region", zone)
		_check(got == want[zone], "%s resolves to %s, the server's ZoneCentre (got %s)" % [zone, want[zone], got])
	# The label is case-insensitive, like every other one.
	_check(w.call("_resolve_zone_region", "Donwhang") == "102/153", "Donwhang (capitalised) resolves too")

	# The server's "donwhang" builds a grid: _zone_paths names the town's own
	# region files and _parse_region_coords the region, which is what
	# _reload_zone_assets needs to load anything at all.
	var paths: Dictionary = w.call("_zone_paths", "donwhang")
	_check(paths.get("m", "") == "102\\153.m" and paths.get("o", "") == "102\\153.o",
		"donwhang's zone paths are 102\\153.m / .o (got %s)" % str(paths))
	var coords: Dictionary = w.call("_parse_region_coords", w.call("_resolve_zone_region", "donwhang"))
	_check(coords.get("x", -1) == 102 and coords.get("y", -1) == 153,
		"donwhang parses to region x 102, y 153 (got %s)" % str(coords))

	# A label the server does not name still passes through unchanged, for
	# _zone_paths to take as a raw "x/y" (the debug panel's town buttons).
	_check(w.call("_resolve_zone_region", "106/108") == "106/108", "a raw x/y label passes through")
	w.free()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
