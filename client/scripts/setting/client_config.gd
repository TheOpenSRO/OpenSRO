extends RefCounted
class_name ClientConfig

## The client's general configuration file, `setting/config.yaml` beside the
## executable (round 679, OURS) -- the folder where, as in retail's own
## client folder (whose `setting\` holds SROptionSet.dat, wndpos.dat and the
## rest, MEASURED in the box's retail install), the client's own settings and
## save data live. A private server ships it with the client to point the
## login screen at its servers and pick the title intro, without rebuilding
## or re-signing anything: the folder holds DATA only. Nothing in it is ever
## loaded as code.
##
## The shape (YamlLite reads it; every key optional):
##
##   global:
##     loginScreen: constantinople     # the title intro (FrontEndTheme.intro)
##     region: US                      # kept, reserved (see below)
##   display:
##     renderer: compatibility         # or forward_plus (round 693, RendererChoice)
##   servers:
##     MyServer:                       # the name the login screen shows
##       type: opensro                 # REQUIRED: opensro or legacy
##       gateway: { address: login.example.com, port: 15779 }
##       agent:   { address: agent.example.com, port: 15884 }
##     Other:
##       type: legacy
##       gateway: { address: 203.0.113.7 }   # port defaults to 15779
##
## - `servers` present and non-empty: the login screen's Server field shows
##   the chosen server's NAME, read-only, with a LIST button to choose
##   another; the client connects to its gateway. Absent or empty: today's
##   editable host:port field.
## - `type` (round 681, OURS, required) is the protocol the server speaks:
##   `opensro`, this project's own (the status is asked with 0x0007), or
##   `legacy`, the original gateway protocol (the status is the gateway's own
##   shard list, asked the way the retail client asks: ServerStatus,
##   RetailGatewayClient). An entry without a type, or with another word, is
##   skipped with a warning. Once this project's server also speaks the
##   original protocol (the superset plan, docs/protocol/PROTOCOL_DECISION.md),
##   `opensro` will mean "also has our extensions" rather than another wire.
## - `gateway` is where the client connects (address + port), as retail's
##   DIVISIONINFO.TXT host list and GATEPORT.TXT port are (README).
## - `agent` is parsed and kept, not used yet: retail's gateway hands the
##   client its agent server's address in the login reply, and this server is
##   one process with no such hand-off. When the hand-off exists, a
##   configured agent will stand in for the address the gateway names -- a
##   proxy or private-server feature (OURS).
## - `display.renderer` (round 693, OURS): `forward_plus` (the default) or
##   `compatibility`. Godot picks its renderer before any script runs, so
##   Boot records the word in `override.cfg` beside the game
##   (RendererChoice) and it takes effect at the NEXT start. Unset, the
##   choice already recorded there stands. It cannot rescue a machine
##   without Vulkan by itself -- Boot never runs there -- the native
##   library's fall back does (RendererChoice's header).
## - `global.region` is parsed and kept, reserved: what it may drive is in
##   deploy/README.md ("Configuring the client").
##
## A file that does not parse is reported (with its line) in the log and
## ignored whole, as if absent; a server entry that is incomplete is skipped
## with a warning, the others kept; an unknown key is a warning only, so a
## newer file still loads in an older client.

const FILE_NAME := "config.yaml"
const DEFAULT_PORT := 15779
## OURS: what the login screen's 86-px server slot can show, and a bound on
## a file nobody should need to scroll.
const NAME_MAX := 32
const SERVERS_MAX := 64
## Round 681: the values of a server's `type`.
const TYPES := ["opensro", "legacy"]
## Round 704: the project was called srrevamp until 2026-10-04, and a
## config.yaml written before then names this project's servers
## `type: srrevamp`. The file lives beside the game, untouched by the update,
## so the old word is still read as `opensro`, with a warning to rename it.
const OLD_TYPE_NAME := "srrevamp"

class ServerEntry:
	var name := ""
	var gateway_host := ""
	var gateway_port := DEFAULT_PORT
	## "opensro" or "legacy" (TYPES).
	var type := "opensro"
	var agent_host := ""
	var agent_port := 0
	## The YAML line the entry starts on is not tracked; its order is.
	var index := 0

	func gateway_address() -> String:
		return "%s:%d" % [gateway_host, gateway_port]

var login_screen := ""
var region := ""
## display.renderer, normalised (RendererChoice.normalise): "forward_plus",
## "gl_compatibility", or "" when the file does not set it.
var renderer := ""
var servers: Array = [] # of ServerEntry, in the file's order
## Where it was read from ("" when no file).
var source := ""

## `<executable's folder>/setting`, or OPENSRO_SETTING_DIR (a developer's or
## a QA run's own folder), as custom_dir and the pk2 folder are found.
static func setting_dir() -> String:
	var env := OS.get_environment("OPENSRO_SETTING_DIR")
	if env != "":
		return env
	return OS.get_executable_path().get_base_dir().path_join("setting")

static func config_path() -> String:
	return setting_dir().path_join(FILE_NAME)

## The config at the usual place: never null (an empty config when the file
## is missing or unusable, with why in `warnings`).
static func load_default(warnings: PackedStringArray = PackedStringArray()) -> ClientConfig:
	return load_file(config_path(), warnings)

static func load_file(path: String, warnings: PackedStringArray = PackedStringArray()) -> ClientConfig:
	if not FileAccess.file_exists(path):
		return ClientConfig.new()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		warnings.append("%s could not be read (error %d) -- ignored" % [path, FileAccess.get_open_error()])
		return ClientConfig.new()
	# The size before the read (round 679's review): a huge file is not read.
	if f.get_length() > YamlLite.MAX_BYTES:
		warnings.append("%s is %d bytes, more than %d -- ignored" % [path, f.get_length(), YamlLite.MAX_BYTES])
		return ClientConfig.new()
	var text := f.get_as_text()
	f.close()
	var c := from_text(text, path, warnings)
	return c

## A config from YAML text. `where` names it in warnings.
static func from_text(text: String, where: String, warnings: PackedStringArray = PackedStringArray()) -> ClientConfig:
	var c := ClientConfig.new()
	var parsed := YamlLite.parse(text)
	if parsed.has("error"):
		warnings.append("%s %s -- the whole file is ignored" % [where, parsed["error"]])
		return c
	c.source = where
	var root: Dictionary = parsed["data"]
	for k in root.keys():
		if not (str(k) in ["global", "servers", "display"]):
			warnings.append("%s: unknown top-level key '%s' -- ignored" % [where, k])
	var g = root.get("global", null)
	if g != null and not (g is Dictionary):
		warnings.append("%s: 'global' is not a map -- ignored" % where)
	elif g is Dictionary:
		for k in g.keys():
			if not (str(k) in ["loginScreen", "region"]):
				warnings.append("%s: unknown key 'global.%s' -- ignored" % [where, k])
		var intro = g.get("loginScreen", null)
		if intro != null:
			var clean := FrontEndTheme.sanitize("intro", str(intro), warnings)
			c.login_screen = clean
		var region = g.get("region", null)
		if region != null:
			var r := str(region).strip_edges()
			if r.length() <= 16 and FrontEndTheme.is_safe_name(r):
				c.region = r
			else:
				warnings.append("%s: global.region '%s' is not a short code -- ignored" % [where, region])
	var d = root.get("display", null)
	if d != null and not (d is Dictionary):
		warnings.append("%s: 'display' is not a map -- ignored" % where)
	elif d is Dictionary:
		for k in d.keys():
			if not (str(k) in ["renderer"]):
				warnings.append("%s: unknown key 'display.%s' -- ignored" % [where, k])
		var rw = d.get("renderer", null)
		if rw != null:
			var rn := RendererChoice.normalise(str(rw))
			if rn == "":
				warnings.append("%s: display.renderer '%s' is not forward_plus or compatibility -- ignored" % [where, rw])
			else:
				c.renderer = rn
	var s = root.get("servers", null)
	if s != null and not (s is Dictionary):
		warnings.append("%s: 'servers' is not a map of name -> server -- ignored" % where)
	elif s is Dictionary:
		var seen := {}
		for name in s.keys():
			# Two keys that are one name once trimmed ("A " and "A"): the
			# first stands (round 679's review).
			var trimmed := str(name).strip_edges()
			if seen.has(trimmed):
				warnings.append("%s: server '%s' is listed twice -- the second is ignored" % [where, trimmed])
				continue
			seen[trimmed] = true
			if c.servers.size() >= SERVERS_MAX:
				warnings.append("%s: more than %d servers -- the rest are ignored" % [where, SERVERS_MAX])
				break
			var e := _entry(str(name), s[name], where, warnings)
			if e != null:
				e.index = c.servers.size()
				c.servers.append(e)
	return c

static func _entry(name: String, v, where: String, warnings: PackedStringArray) -> ServerEntry:
	var n := name.strip_edges()
	if n == "" or n.length() > NAME_MAX or not _printable(n):
		warnings.append("%s: server name '%s' must be 1-%d printable characters -- skipped" % [where, name, NAME_MAX])
		return null
	if not (v is Dictionary):
		warnings.append("%s: server '%s' is not a map with a gateway -- skipped" % [where, n])
		return null
	for k in v.keys():
		if not (str(k) in ["type", "gateway", "agent"]):
			warnings.append("%s: unknown key 'servers.%s.%s' -- ignored" % [where, n, k])
	var t = v.get("type", null)
	if t == null:
		warnings.append("%s: server '%s' has no type (one of: %s) -- skipped" % [where, n, ", ".join(TYPES)])
		return null
	var type := str(t).strip_edges()
	if type == OLD_TYPE_NAME:
		warnings.append("%s: server '%s' type '%s' is the project's old name -- read as 'opensro'; rename it in the file" % [where, n, type])
		type = "opensro"
	if not (type in TYPES):
		warnings.append("%s: server '%s' type '%s' is not one of: %s -- skipped" % [where, n, type, ", ".join(TYPES)])
		return null
	var gw := _endpoint(v.get("gateway", null), DEFAULT_PORT)
	if gw.has("error"):
		warnings.append("%s: server '%s' gateway %s -- skipped" % [where, n, gw["error"]])
		return null
	var e := ServerEntry.new()
	e.name = n
	e.type = type
	e.gateway_host = gw["host"]
	e.gateway_port = gw["port"]
	if v.get("agent", null) != null:
		var ag := _endpoint(v["agent"], 0)
		if ag.has("error"):
			warnings.append("%s: server '%s' agent %s -- the agent is ignored" % [where, n, ag["error"]])
		else:
			e.agent_host = ag["host"]
			e.agent_port = ag["port"]
	return e

## {address, port} -> {"host", "port"} or {"error"}. `default_port` 0 means
## the port is required.
static func _endpoint(v, default_port: int) -> Dictionary:
	if v == null:
		return {"error": "is missing"}
	if not (v is Dictionary):
		return {"error": "is not { address: ..., port: ... }"}
	var a = v.get("address", null)
	var host := "" if a == null else str(a).strip_edges()
	if not is_valid_host(host):
		return {"error": "address '%s' is not a host name or IP address" % host}
	var p = v.get("port", null)
	var port := default_port
	if p != null:
		if not (p is int):
			return {"error": "port '%s' is not a number" % str(p)}
		port = p
	if port < 1 or port > 65535:
		return {"error": "port %d is not 1-65535" % port if p != null else "has no port"}
	return {"host": host, "port": port}

## A DNS name or an IPv4/IPv6 literal: no spaces, no scheme, no path.
static func is_valid_host(h: String) -> bool:
	if h == "" or h.length() > 253:
		return false
	if h.is_valid_ip_address():
		return true
	for label in h.split("."):
		if label == "" or label.length() > 63 or label.begins_with("-") or label.ends_with("-"):
			return false
		for ch in label:
			var ok := (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "-" or ch == "_"
			if not ok:
				return false
	return true

static func _printable(s: String) -> bool:
	for ch in s:
		var code := ch.unicode_at(0)
		if code < 0x20 or code == 0x7f:
			return false
	return true

func has_servers() -> bool:
	return not servers.is_empty()

func server_named(n: String) -> ServerEntry:
	for e in servers:
		if (e as ServerEntry).name == n:
			return e
	return null

## The server the login screen starts on: the one remembered last time if
## the file still lists it, else the file's first. Null without servers.
func pick_server(remembered: String) -> ServerEntry:
	if servers.is_empty():
		return null
	var e := server_named(remembered)
	return e if e != null else servers[0]

## This file's share of the front-end theme: only the intro so far
## (global.loginScreen). Null when it sets nothing.
func to_theme() -> FrontEndTheme:
	if login_screen == "":
		return null
	var t := FrontEndTheme.new()
	t.intro = login_screen
	return t

func describe() -> String:
	var names := PackedStringArray()
	for e in servers:
		names.append("%s=%s (%s)" % [(e as ServerEntry).name, (e as ServerEntry).gateway_address(), (e as ServerEntry).type])
	return "loginScreen=%s region=%s renderer=%s servers=[%s]" % [login_screen if login_screen != "" else "(unset)",
		region if region != "" else "(unset)", renderer if renderer != "" else "(unset)", ", ".join(names)]
