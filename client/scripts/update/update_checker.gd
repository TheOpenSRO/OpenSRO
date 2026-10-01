extends RefCounted
class_name UpdateChecker

## Pure, testable logic behind the auto-updater (see AutoUpdater for the
## actual HTTP/file-system side) -- version comparison and picking which
## real release asset matches the running platform. Kept separate from
## AutoUpdater specifically so this part can be unit tested headlessly
## without a real network call.

## This build's own version -- compared against a real GitHub release's
## "tag_name". "v0.0.0" (older than any real "vX.Y.Z" tag) is the honest
## default for a dev/editor run, or any build not made from a real tagged
## release. release.yml rewrites this exact line to the real pushed tag
## (via sed) before exporting whenever the workflow is triggered by an
## actual "v*" tag push (not a plain workflow_dispatch test build) -- so a
## real downloaded release build always reports its own real version, and
## never mistakes itself (or an older tag) for a newer one.
const CLIENT_VERSION := "v0.0.0"

## Real fine-grained GitHub PAT (contents: read-only, this one repo only --
## see docs/WORLD_ISSUES.md's "private repo + embedded token" entry for the
## real tradeoff this represents) letting a downloaded client read this
## project's real, private GitHub Releases API. Empty by default (a dev/
## editor run, or any build not made from a real tagged release, simply
## can't check for updates against a private repo -- an honest "no access"
## rather than a guessed/fake value). release.yml sed-replaces this exact
## line with the real secret value at build time, the same mechanism
## CLIENT_VERSION already uses, so the raw token is never committed to
## this tracked source file.
const GITHUB_TOKEN := ""

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
## ...}), or "" if no real asset with that exact name is present. Only
## works unauthenticated for a real *public* repo's release.
static func find_asset_url(assets: Array, asset_name: String) -> String:
	if asset_name == "":
		return ""
	for asset in assets:
		if asset is Dictionary and asset.get("name", "") == asset_name:
			return asset.get("browser_download_url", "")
	return ""

## Same real lookup as find_asset_url, but returns the asset's real API
## "url" field instead of "browser_download_url" -- the one real endpoint
## that supports an authenticated download (Authorization header +
## "Accept: application/octet-stream") for a real *private* repo's
## release, which the plain browser_download_url doesn't.
static func find_asset_api_url(assets: Array, asset_name: String) -> String:
	if asset_name == "":
		return ""
	for asset in assets:
		if asset is Dictionary and asset.get("name", "") == asset_name:
			return asset.get("url", "")
	return ""

## The asset's SHA-256 as GitHub's Releases API reports it ("digest":
## "sha256:<hex>"; MEASURED on v0.1.464's two assets, round 668), lower-case
## hex, or "" when the asset has no digest of that kind.
static func find_asset_digest(assets: Array, asset_name: String) -> String:
	if asset_name == "":
		return ""
	for asset in assets:
		if asset is Dictionary and asset.get("name", "") == asset_name:
			var digest := str(asset.get("digest", ""))
			if digest.begins_with("sha256:") and digest.length() == 7 + 64:
				return digest.substr(7).to_lower()
			return ""
	return ""

## "" when the downloaded file's SHA-256 matches the release's, otherwise why
## not. An empty expected digest is reported, not failed: older releases and a
## QA endpoint may list none (AutoUpdater logs it as unverified).
static func digest_problem(actual_hex: String, expected_hex: String) -> String:
	if expected_hex == "":
		return ""
	if actual_hex.to_lower() != expected_hex.to_lower():
		return "the download's SHA-256 is %s, the release says %s" % [actual_hex.to_lower(), expected_hex.to_lower()]
	return ""
