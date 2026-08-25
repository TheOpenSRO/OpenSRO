extends SceneTree

## Exercises UpdateChecker's pure version-comparison/asset-selection logic,
## run headless:
## `godot4 --headless --path client --script res://scripts/update/update_checker_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	_check(UpdateChecker.parse_version("v1.2.3") == [1, 2, 3], "parses a real vMAJOR.MINOR.PATCH tag")
	_check(UpdateChecker.parse_version("1.2.3") == [1, 2, 3], "parses without a leading v too")
	_check(UpdateChecker.parse_version("v1.2") == [], "rejects a tag with too few components")
	_check(UpdateChecker.parse_version("v1.2.3.4") == [], "rejects a tag with too many components")
	_check(UpdateChecker.parse_version("v1.2.x") == [], "rejects a non-numeric component")
	_check(UpdateChecker.parse_version("") == [], "rejects an empty tag")

	_check(UpdateChecker.is_newer_version("v1.0.0", "v1.0.1"), "patch bump is newer")
	_check(UpdateChecker.is_newer_version("v1.0.0", "v1.1.0"), "minor bump is newer")
	_check(UpdateChecker.is_newer_version("v1.0.0", "v2.0.0"), "major bump is newer")
	_check(not UpdateChecker.is_newer_version("v1.0.0", "v1.0.0"), "identical version is not newer")
	_check(not UpdateChecker.is_newer_version("v1.5.0", "v1.4.9"), "older patch is not newer")
	_check(not UpdateChecker.is_newer_version("v2.0.0", "v1.9.9"), "older major is not newer")
	_check(not UpdateChecker.is_newer_version("v1.0.0", "not-a-version"), "unparseable latest tag never claims an update")
	_check(not UpdateChecker.is_newer_version("not-a-version", "v1.0.0"), "unparseable current tag never claims an update")

	_check(UpdateChecker.asset_name_for_os("Windows") == "srrevamp-windows.zip", "real Windows asset name (got %s)" % UpdateChecker.asset_name_for_os("Windows"))
	_check(UpdateChecker.asset_name_for_os("Linux") == "srrevamp-linux.zip", "real Linux asset name (got %s)" % UpdateChecker.asset_name_for_os("Linux"))
	_check(UpdateChecker.asset_name_for_os("macOS") == "", "no real asset name for a platform this project doesn't build for")

	var assets := [
		{"name": "srrevamp-windows.zip", "browser_download_url": "https://example.com/windows.zip"},
		{"name": "srrevamp-linux.zip", "browser_download_url": "https://example.com/linux.zip"},
	]
	_check(UpdateChecker.find_asset_url(assets, "srrevamp-windows.zip") == "https://example.com/windows.zip", "finds the real matching asset's URL")
	_check(UpdateChecker.find_asset_url(assets, "srrevamp-macos.zip") == "", "no real URL for an asset that isn't present")
	_check(UpdateChecker.find_asset_url(assets, "") == "", "empty asset name never matches")
	_check(UpdateChecker.find_asset_url([], "srrevamp-windows.zip") == "", "no real assets at all -> no URL")

	if _failures == 0:
		print("ALL PASS")
	quit()
