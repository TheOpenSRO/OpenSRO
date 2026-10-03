extends SceneTree

## NativeAssets' startup line (round 668), one per outcome: what a tester's
## log and the Shift+F3 debug panel say. docs/NATIVE_ON_WINDOWS.md quotes these.
##
##   godot4 --headless --path client --script res://scripts/pk2/native_status_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var dll := "C:/Games/opensro/opensro_native.dll"
	var on := NativeAssets.describe(true, "", false, "opensro_native 0.1.0, API 2", dll, true)
	print("  " + on)
	_check(on.begins_with("NativeAssets: native readers ON (library loaded, opensro_native 0.1.0, API 2, "), "ON names the library's version and API")
	var missing := NativeAssets.describe(false, "not loaded", false, "", dll, false)
	print("  " + missing)
	_check(missing == "NativeAssets: native readers OFF (library not found: %s) -- using the GDScript readers" % dll,
		"a missing or renamed library says where it was looked for")
	var broken := NativeAssets.describe(false, "not loaded", false, "", dll, true)
	print("  " + broken)
	_check(broken.begins_with("NativeAssets: native readers OFF (library failed to load: ") and broken.ends_with("-- using the GDScript readers"),
		"a library that is there but did not load says so")
	var forced := NativeAssets.describe(true, "", true, "opensro_native 0.1.0, API 2", dll, true)
	print("  " + forced)
	_check(forced == "NativeAssets: native readers OFF (forced off by OPENSRO_NATIVE=0; the library is loaded but unused) -- using the GDScript readers",
		"OPENSRO_NATIVE=0 says it forced the switch")
	_check(NativeAssets.describe(false, "not loaded", true, "", dll, false).contains("not loaded either"), "forced off without a library says that too")
	# A stale library a partial update left next to a newer client (round 667's
	# API check): refused with the two numbers.
	var stale := NativeAssets.describe(true, NativeAssets.api_verdict(0), false, "", dll, true)
	print("  " + stale)
	_check(stale == "NativeAssets: native readers OFF (library REFUSED: API 0, this client needs API %d -- a stale library, rebuild it with native/build.sh) -- using the GDScript readers" % NativeAssets.NATIVE_API,
		"a library speaking another API is refused, naming both numbers")
	var all := [on, missing, broken, forced, stale]
	for i in range(all.size()):
		for j in range(i + 1, all.size()):
			_check(all[i] != all[j], "outcomes %d and %d read differently" % [i, j])
	# This process: the line exists once available() has run.
	NativeAssets.available()
	_check(NativeAssets.status.begins_with("NativeAssets: native readers "), "available() sets the status line")
	if _failures == 0:
		print("ALL PASS")
	quit(1 if _failures > 0 else 0)
