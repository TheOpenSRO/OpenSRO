extends RefCounted
class_name FrontEndTheme

## The operator's branding of the front-end (round 678, OURS): which intro the
## title flies, its music, the logo, the copyright line and the band art --
## and two reserved slots, `charselect` and `create`, for the character
## select and creation scenes of later rounds (retail's are fixed scenes, not
## tied to the intro; making them choosable is OURS).
##
## One structure everywhere: the server's answer (OpFrontEndTheme, 0x0006,
## a JSON object), the copy of it cached in the settings file, and an
## operator's `custom/theme.json` next to the executable:
##   {"v":1, "intro":"", "bgm":"", "logo":"", "copyright":"",
##    "band_top":"", "band_bottom":"", "charselect":null, "create":null}
## An empty string is "not set": the next source decides, and in the end
## retail's own default -- option.txt's IntroName and IntroBGM, the archive's
## logo and band art, no extra copyright line.
##
## Which source wins, per field (OURS; docs/protocol/intro_script.md, deploy/
## README.md "Branding your front-end"):
##   1. SRREVAMP_LOGIN_* preview variables (a developer or operator trying a
##      theme on their own machine, no server needed);
##   2. the server's answer, if it arrived before the title started -- or, when
##      it did not, the last answer cached from an earlier launch, per server
##      address (the two are one layer: a fresh answer replaces the cache
##      whole, so a field the operator cleared is not brought back from it);
##   3. setting/config.yaml's `global` keys (round 679, ClientConfig: so far
##      only loginScreen, the intro) -- the client's general config file;
##   4. custom/theme.json (a client shipped pre-branded);
##   5. retail's defaults.
## Why the server before the local files (round 679, OURS): the answer is the
## branding of the server being connected to, which its operator controls; a
## client config may list several servers, and its `global` choice is the
## fallback for the ones that set nothing. setting/ before custom/: it is the
## general config file a player or operator edits first; theme.json remains
## for the branding images that only it can name.
##
## Names never reach outside the folders they name a file in (custom/intro,
## custom/frontend) or Media.pk2's script\intro: see is_safe_name and
## friends. A name that fails is logged and ignored, as if unset.

const FIELDS: Array[String] = ["intro", "bgm", "logo", "copyright", "band_top", "band_bottom"]
const RESERVED: Array[String] = ["charselect", "create"]
const VERSION := 1
const COPYRIGHT_MAX := 200

## The settings file's cache of the last server answer.
const SETTINGS_SECTION := "frontend"
const SETTINGS_KEY := "server_theme"

## The intro scripts retail ships (Media.pk2 script\intro\, round 678's
## census; "china_whatf" is a real misspelt file, byte-identical to roc and
## egypt in the archives measured).
const RETAIL_INTROS: Array[String] = ["roc", "egypt", "china_whatf", "china_wharf",
	"constantinople", "rm", "rmzh", "jupiter_login", "ruby_baghdad"]

var intro := ""
var bgm := ""
var logo := ""
var copyright := ""
var band_top := ""
var band_bottom := ""
## Reserved for later rounds; always null this round.
var charselect = null
var create = null
## Field -> where its value came from ("preview", "server", "cache",
## "setting", "custom", or "" for unset/default), filled by resolve().
var origin := {}

func get_field(field: String) -> String:
	return str(get(field))

func is_empty() -> bool:
	for f in FIELDS:
		if get_field(f) != "":
			return false
	return true

func to_json() -> String:
	var d := {"v": VERSION}
	for f in FIELDS:
		d[f] = get_field(f)
	d["charselect"] = charselect
	d["create"] = create
	return JSON.stringify(d)

func describe() -> String:
	var parts := PackedStringArray()
	for f in FIELDS:
		var v := get_field(f)
		parts.append("%s=%s%s" % [f, v if v != "" else "(default)",
			" [%s]" % origin[f] if origin.has(f) and v != "" else ""])
	return " ".join(parts)

## A theme from JSON text, or null when the text is not a JSON object. Each
## field is checked (sanitize); an unknown key is ignored, a bad value is
## dropped with a line in `warnings`.
static func from_json(text: String, warnings: PackedStringArray = PackedStringArray()) -> FrontEndTheme:
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		warnings.append("not a JSON object")
		return null
	var t := FrontEndTheme.new()
	for f in FIELDS:
		var v = parsed.get(f, "")
		if v == null:
			v = ""
		if not (v is String):
			warnings.append("%s is not a string" % f)
			continue
		var clean := sanitize(f, v, warnings)
		t.set(f, clean)
	return t

## A field's value if it is acceptable, else "" (with a warning).
static func sanitize(field: String, value: String, warnings: PackedStringArray) -> String:
	var v := value.strip_edges()
	if v == "":
		return ""
	match field:
		"intro":
			if is_safe_name(v) or is_archive_intro_path(v):
				return v
		"bgm":
			# Only .ogg (round 678's review): the music archive's root is where a
			# bare name is looked for, and only .ogg names route there
			# (AudioBank.is_music_path).
			if is_safe_file(v, ["ogg"], true):
				return v
		"logo", "band_top", "band_bottom":
			if is_safe_file(v, ["png", "ddj"], false):
				return v
		"copyright":
			var out := ""
			for c in v:
				var code := c.unicode_at(0)
				if code >= 0x20 and code != 0x7f:
					out += c
			if out.length() > COPYRIGHT_MAX:
				warnings.append("copyright longer than %d characters, cut" % COPYRIGHT_MAX)
				out = out.substr(0, COPYRIGHT_MAX)
			return out
	warnings.append("%s '%s' is not an acceptable name -- ignored" % [field, value])
	return ""

static var _name_re: RegEx = null
static var _intro_path_re: RegEx = null

## A bare name: letters, digits, '_' and '-' only, 1-64 of them -- so it
## cannot name a folder, a drive or a parent.
static func is_safe_name(s: String) -> bool:
	if _name_re == null:
		_name_re = RegEx.create_from_string("^[A-Za-z0-9_-]{1,64}$")
	return _name_re.search(s) != null

## Media.pk2's own `script\intro\<name>.txt`, nothing above or below it.
static func is_archive_intro_path(s: String) -> bool:
	if _intro_path_re == null:
		_intro_path_re = RegEx.create_from_string("(?i)^script\\\\intro\\\\[A-Za-z0-9_ -]{1,64}\\.txt$")
	return _intro_path_re.search(s) != null and not s.contains("..")

## `<safe name>.<one of exts>`; `allow_spaces_dots` lets a music file keep the
## archive's own spellings (retail's "maintheme_cut.ogg").
static func is_safe_file(s: String, exts: Array, allow_spaces_dots: bool) -> bool:
	if s.contains("..") or s.contains("/") or s.contains("\\") or s.contains(":"):
		return false
	var dot := s.rfind(".")
	if dot <= 0:
		return false
	var ext := s.substr(dot + 1).to_lower()
	if not exts.has(ext):
		return false
	var stem := s.substr(0, dot)
	if stem.length() > 64:
		return false
	for c in stem:
		var ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "-"
		if not ok and allow_spaces_dots and (c == " " or c == "."):
			ok = true
		if not ok:
			return false
	return true

## The layered theme (see the header for the order). `server` is the fresh
## answer or null; `cached` the settings copy or null; `custom` the folder's
## theme.json or null; `preview` the SRREVAMP_LOGIN_* variables or null;
## `setting` setting/config.yaml's share (ClientConfig.to_theme) or null.
static func resolve(preview: FrontEndTheme, server: FrontEndTheme, cached: FrontEndTheme, custom: FrontEndTheme,
		setting: FrontEndTheme = null) -> FrontEndTheme:
	var out := FrontEndTheme.new()
	var server_layer: FrontEndTheme = server if server != null else cached
	var server_name := "server" if server != null else "cache"
	for f in FIELDS:
		for layer in [[preview, "preview"], [server_layer, server_name], [setting, "setting"], [custom, "custom"]]:
			var t: FrontEndTheme = layer[0]
			if t != null and t.get_field(f) != "":
				out.set(f, t.get_field(f))
				out.origin[f] = layer[1]
				break
	return out

## The SRREVAMP_LOGIN_* preview variables (the same names the server's flags
## read: SRREVAMP_LOGIN_INTRO, _BGM, _LOGO, _COPYRIGHT, _BAND_TOP,
## _BAND_BOTTOM), or null when none is set.
static func from_environment(warnings: PackedStringArray = PackedStringArray()) -> FrontEndTheme:
	var t := FrontEndTheme.new()
	var any := false
	for f in FIELDS:
		var v := OS.get_environment("SRREVAMP_LOGIN_" + f.to_upper())
		if v != "":
			t.set(f, sanitize(f, v, warnings))
			any = true
	return t if any else null

## The last answer from the server at `address` ("host:port"), from the
## settings file, or null. Kept per server (round 678's review): a player
## who uses two servers sees each one's own branding.
static func cached(address: String) -> FrontEndTheme:
	var text := str(ClientSettings.get_value(SETTINGS_SECTION, cache_key(address), ""))
	if text == "":
		return null
	return from_json(text)

static func store_cache(theme: FrontEndTheme, address: String) -> void:
	ClientSettings.set_value(SETTINGS_SECTION, cache_key(address), theme.to_json() if theme != null else "")

## The settings key for an address: letters, digits, '.', '-' and '_' kept,
## anything else '_'.
static func cache_key(address: String) -> String:
	var key := SETTINGS_KEY + "_"
	for c in address.strip_edges().to_lower():
		var ok := (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "." or c == "-" or c == "_"
		key += c if ok else "_"
	return key

# --- The operator's folder ----------------------------------------------------

## `<executable's folder>/custom`, or SRREVAMP_CUSTOM_DIR (a developer's or a
## QA run's own folder).
static func custom_dir() -> String:
	var env := OS.get_environment("SRREVAMP_CUSTOM_DIR")
	if env != "":
		return env
	return OS.get_executable_path().get_base_dir().path_join("custom")

## custom/theme.json, or null (with why in `warnings` when it exists but is
## unusable).
static func from_custom_folder(dir: String, warnings: PackedStringArray = PackedStringArray()) -> FrontEndTheme:
	var path := dir.path_join("theme.json")
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	var t := from_json(text, warnings)
	if t == null:
		warnings.append("%s is not a JSON object -- ignored" % path)
	return t

## custom/intro/<name>.txt when `name` is a safe bare name and the file is
## there, else "".
static func custom_intro_path(dir: String, name: String) -> String:
	if not is_safe_name(name):
		return ""
	var path := dir.path_join("intro").path_join(name + ".txt")
	return path if FileAccess.file_exists(path) else ""

## custom/frontend/<file> when `file` is a safe image name and it is there,
## else "".
static func custom_image_path(dir: String, file: String) -> String:
	if not is_safe_file(file, ["png", "ddj"], false):
		return ""
	var path := dir.path_join("frontend").path_join(file)
	return path if FileAccess.file_exists(path) else ""

## The archive path a theme's intro names: a bare retail-style name becomes
## `script\intro\<name>.txt`; an archive path stays; anything else is "".
static func archive_intro_path(name: String) -> String:
	if is_archive_intro_path(name):
		return name
	if is_safe_name(name):
		return "script\\intro\\%s.txt" % name
	return ""
