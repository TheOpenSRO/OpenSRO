extends RefCounted
class_name UpdateChecker

## Pure, testable logic behind the auto-updater (see AutoUpdater for the
## actual HTTP/file-system side) -- version comparison and picking which
## real release asset matches the running platform. Kept separate from
## AutoUpdater specifically so this part can be unit tested headlessly
## without a real network call.

## This build's own version -- compared against a real GitHub release's
## "tag_name". Bumped by hand per real tagged release; nothing in this
## project auto-generates it. "v0.0.0" (older than any real "vX.Y.Z" tag)
## is the honest default for a dev/editor run that was never built from a
## tagged release at all.
const CLIENT_VERSION := "v0.0.0"

## Parses a "vMAJOR.MINOR.PATCH" real tag string into [major, minor, patch],
## or [] if it doesn't match that real shape (e.g. a real pre-release tag
## with extra suffix, or a malformed string) -- callers treat [] as "can't
## compare, don't claim an update either way" rather than guessing.
static func parse_version(tag: String) -> Array:
	var s := tag.strip_edges()
	if s.begins_with("v"):
		s = s.substr(1)
	var parts := s.split(".")
	if parts.size() != 3:
		return []
	var nums := []
	for p in parts:
		if not p.is_valid_int():
			return []
		nums.append(p.to_int())
	return nums

## True only if latest_tag parses as a real version strictly greater than
## CLIENT_VERSION (component-wise major/minor/patch comparison) -- false
## for anything unparseable, equal, or older, so a malformed/unexpected
## real tag never falsely claims an update is available.
static func is_newer_version(current_tag: String, latest_tag: String) -> bool:
	var current := parse_version(current_tag)
	var latest := parse_version(latest_tag)
	if current.is_empty() or latest.is_empty():
		return false
	for i in range(3):
		if latest[i] > current[i]:
			return true
		if latest[i] < current[i]:
			return false
	return false # exactly equal

## Real release asset filenames this project's own release.yml actually
## produces (see .github/workflows/release.yml) -- "" for a real platform
## this project doesn't build for (e.g. macOS), so a caller can report
## "no update available for your platform" honestly instead of guessing a
## filename that doesn't exist.
static func asset_name_for_os(os_name: String) -> String:
	match os_name:
		"Windows":
			return "srrevamp-windows.zip"
		"Linux":
			return "srrevamp-linux.zip"
		_:
			return ""

## Finds the real download URL for asset_name within a real GitHub release
## API response's "assets" array (each {"name": ..., "browser_download_url":
## ...}), or "" if no real asset with that exact name is present.
static func find_asset_url(assets: Array, asset_name: String) -> String:
	if asset_name == "":
		return ""
	for asset in assets:
		if asset is Dictionary and asset.get("name", "") == asset_name:
			return asset.get("browser_download_url", "")
	return ""
