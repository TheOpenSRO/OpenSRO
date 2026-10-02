extends SceneTree

## setting/config.yaml (round 679, OURS): the YAML subset reader, the client
## config built from it, and where its loginScreen sits in the front-end
## theme's order.
##   - YamlLite: the user's own example shape (flow maps under block maps),
##     scalars, comments, lists; refusals that name their line; nothing
##     guessed.
##   - ClientConfig: servers in file order with their gateway and agent,
##     a bad entry skipped with the others kept, a broken file ignored whole,
##     a missing file empty, the remembered server picked while listed.
##   - Round 681: every server's `type` (srrevamp or legacy) is required; an
##     entry without one, or with another word, is skipped with a warning
##     naming the server and the allowed values. NEGATIVE: before round 681
##     ServerEntry has no `type` and the entries are kept -- those checks
##     fail.
##   - The order: preview > server (else cache) > setting > custom > default.
##
## NEGATIVE: before round 679 neither YamlLite nor ClientConfig exists -- this
## suite does not parse.

var _failures := 0
var _dir := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_dir = OS.get_user_data_dir().path_join("client_config_test_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_dir)
	_yaml_valid()
	_yaml_invalid()
	_config()
	_files()
	_precedence()
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(f))
	DirAccess.remove_absolute(_dir)
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES %d" % _failures)
	quit()

## The user's example's shape, with placeholder hosts (no real host names in
## the repo).
const EXAMPLE := """global:
  loginScreen: constantinople
  region: US
servers:
  FirstServer:
    type: srrevamp
    gateway: { address: login.example.com, port: 15779 }
    agent:   { address: agent.example.com, port: 15884 }
  Second:
    type: legacy
    gateway: { address: gateway.example.org, port: 15779 }
    agent:   { address: agent.example.org, port: 15884 }
"""

func _yaml_valid() -> void:
	var r := YamlLite.parse(EXAMPLE)
	_check(not r.has("error"), "the example parses (%s)" % r.get("error", ""))
	var d: Dictionary = r.get("data", {})
	_check(d.get("global", {}).get("loginScreen") == "constantinople", "a nested scalar")
	var servers: Dictionary = d.get("servers", {})
	_check(servers.keys() == ["FirstServer", "Second"], "map keys keep the file's order: %s" % [servers.keys()])
	var gw = servers.get("FirstServer", {}).get("gateway", {})
	_check(gw is Dictionary and gw.get("address") == "login.example.com" and gw.get("port") == 15779 and gw.get("port") is int,
		"a flow map's values: %s" % [gw])

	r = YamlLite.parse("""---
# a comment line
a: "quoted # not a comment"   # a trailing comment
b: 'it''s'
c: "tab\\there"
d: ~
e:
f: true
g: -3
h: 0815
i: [1, two, "three, four", { x: 1 }]
j:
  - one
  - { k: v }
  -
k:
- x
- y
url: http://example.com:15779/path#frag
""")
	_check(not r.has("error"), "the rest of the subset parses (%s)" % r.get("error", ""))
	d = r.get("data", {})
	_check(d.get("a") == "quoted # not a comment", "a '#' inside quotes is text")
	_check(d.get("b") == "it's", "'' inside single quotes is one quote")
	_check(d.get("c") == "tab\there", "\\t in double quotes")
	_check(d.has("d") and d["d"] == null and d.has("e") and d["e"] == null, "~ and nothing are null")
	_check(d.get("f") == true and d.get("g") == -3, "booleans and negative integers")
	_check(d.get("h") == "0815", "a leading zero stays text (not octal, not 815)")
	_check(d.get("i") == [1, "two", "three, four", {"x": 1}], "a flow list: %s" % [d.get("i")])
	_check(d.get("j") == ["one", {"k": "v"}, null], "a block list: %s" % [d.get("j")])
	_check(d.get("k") == ["x", "y"], "a list at its key's own indentation")
	_check(d.get("url") == "http://example.com:15779/path#frag", "':' and '#' without a space are text: %s" % d.get("url"))
	_check(YamlLite.parse("").get("data") == {}, "an empty file is an empty map")
	_check(YamlLite.parse("\ufeffa: 1\r\nb: 2\r\n").get("data") == {"a": 1, "b": 2}, "a BOM and CRLF line ends")

func _err_line(text: String) -> int:
	var r := YamlLite.parse(text)
	if not r.has("error"):
		return -1
	return int(r.get("line", 0))

func _yaml_invalid() -> void:
	var cases := [
		["a: 1\n\tb: 2\n", 2, "a tab in the indentation"],
		["a: 1\na: 2\n", 2, "a key given twice"],
		["a:\n  b: 1\n c: 2\n", 3, "an indentation matching no open block"],
		["a: 1\n  b: 2\n", 2, "indented under a key that has a value"],
		["a: { b: 1\n", 1, "a flow map left open"],
		["a: [1, 2\n", 1, "a flow list left open"],
		["a: \"open\n", 1, "a quote left open"],
		["x: 1\ny: 2\nz: &anchor 3\n", 3, "an anchor"],
		["x: *alias\n", 1, "an alias"],
		["x: !tag 1\n", 1, "a tag"],
		["x: |\n  text\n", 1, "a block scalar"],
		["- a\n- b\n", 1, "a list at the top"],
		["a: 1\nb c\n", 2, "a line with no ':'"],
		["a:\n  - x\n  y: 1\n", 3, "a key among list items"],
		["a:\n  - k: v\n", 2, "a block map inside a list item"],
		["a: { b: 1, b: 2 }\n", 1, "a key twice in a flow map"],
		["a: \"bad \\q escape\"\n", 1, "an unknown escape"],
		["a: { b: 1 } extra\n", 1, "text after a flow map"],
		["  a: 1\n", 1, "an indented first line"],
	]
	for c in cases:
		var got := _err_line(c[0])
		_check(got == c[1], "refused with its line, %s: line %d (want %d)" % [c[2], got, c[1]])
	var r := YamlLite.parse("a: 1\n\tb: 2\n")
	_check(str(r.get("error", "")).begins_with("line 2: "), "the error text starts with its line: '%s'" % r.get("error", ""))

func _config() -> void:
	var w := PackedStringArray()
	var c := ClientConfig.from_text(EXAMPLE, "config.yaml", w)
	_check(w.is_empty(), "the example loads without warnings: %s" % [w])
	_check(c.login_screen == "constantinople" and c.region == "US", "global keys")
	_check(c.servers.size() == 2, "two servers")
	var a: ClientConfig.ServerEntry = c.servers[0]
	var b: ClientConfig.ServerEntry = c.servers[1]
	_check(a.name == "FirstServer" and b.name == "Second", "the names are the keys, in order")
	_check(a.gateway_host == "login.example.com" and a.gateway_port == 15779 and a.gateway_address() == "login.example.com:15779", "the gateway")
	_check(a.agent_host == "agent.example.com" and a.agent_port == 15884, "the agent is kept")
	_check(a.type == "srrevamp" and b.type == "legacy", "each server's type: %s, %s" % [a.type, b.type])
	_check(c.pick_server("Second") == b, "the remembered server while listed")
	_check(c.pick_server("Gone") == a and c.pick_server("") == a, "else the file's first")
	_check(ClientConfig.new().pick_server("x") == null, "no servers, no pick")
	_check(c.to_theme() != null and c.to_theme().intro == "constantinople", "loginScreen is the theme's intro")

	# Bad entries: skipped with a warning, the good ones kept.
	w = PackedStringArray()
	c = ClientConfig.from_text("""servers:
  Good:
    type: srrevamp
    gateway: { address: 192.0.2.10 }
  NoGateway:
    type: srrevamp
    agent: { address: a.example.com, port: 1 }
  BadPort:
    type: srrevamp
    gateway: { address: x.example.com, port: 70000 }
  BadHost:
    type: srrevamp
    gateway: { address: "http://x.example.com/" }
  TextPort:
    type: srrevamp
    gateway: { address: x.example.com, port: abc }
  NoType:
    gateway: { address: n.example.com }
  BadType:
    type: retail
    gateway: { address: b.example.com }
  BadAgent:
    type: legacy
    gateway: { address: y.example.com, port: 15779 }
    agent: { address: z.example.com }
  NotAMap: 1
global:
  loginScreen: ../../evil
  colour: red
""", "t.yaml", w)
	_check(c.servers.size() == 2 and c.servers[0].name == "Good" and c.servers[1].name == "BadAgent", "only the usable entries: %s" % [c.describe()])
	_check(c.servers[0].gateway_port == ClientConfig.DEFAULT_PORT, "a gateway without a port takes %d" % ClientConfig.DEFAULT_PORT)
	_check(c.servers[1].agent_host == "" and c.servers[1].agent_port == 0, "an agent without a port is dropped, the server kept")
	_check(c.login_screen == "", "an unsafe intro name is refused")
	var joined := "\n".join(w)
	for frag in ["NoGateway", "BadPort", "BadHost", "TextPort", "BadAgent", "NotAMap", "global.colour", "loginScreen"]:
		_check(joined.contains(frag) or (frag == "loginScreen" and joined.contains("evil")), "a warning names %s" % frag)
	_check(joined.contains("server 'NoType' has no type (one of: srrevamp, legacy) -- skipped"), "a server without a type is skipped, the warning names it and the values")
	_check(joined.contains("server 'BadType' type 'retail' is not one of: srrevamp, legacy -- skipped"), "a server with an unknown type is skipped likewise")
	_check(c.server_named("NoType") == null and c.server_named("BadType") == null, "neither is listed")

	# A broken file: ignored whole, the line in the warning.
	w = PackedStringArray()
	c = ClientConfig.from_text("servers:\n  A:\n    type: srrevamp\n    gateway: { address: a.example.com\n", "broken.yaml", w)
	_check(not c.has_servers() and c.source == "", "a file that does not parse is ignored whole")
	_check(w.size() == 1 and w[0].contains("broken.yaml line 4:"), "its warning names the file and line: %s" % [w])

	w = PackedStringArray()
	c = ClientConfig.from_text("servers:\n  \"A \":\n    type: srrevamp\n    gateway: { address: a.example.com }\n  A:\n    type: srrevamp\n    gateway: { address: b.example.com }\n", "dup.yaml", w)
	_check(c.servers.size() == 1 and c.servers[0].gateway_host == "a.example.com", "'A ' and 'A' are one name: the first stands (%s)" % c.describe())
	_check("\n".join(w).contains("listed twice"), "and the second is warned about: %s" % [w])

	_check(ClientConfig.is_valid_host("login.example.com") and ClientConfig.is_valid_host("192.0.2.1") and ClientConfig.is_valid_host("::1"), "host names and IP literals")
	_check(not ClientConfig.is_valid_host("a b") and not ClientConfig.is_valid_host("x.example.com:15779") and not ClientConfig.is_valid_host(""), "no spaces, ports or empties in a host")

func _files() -> void:
	var w := PackedStringArray()
	var c := ClientConfig.load_file(_dir.path_join("missing.yaml"), w)
	_check(c != null and not c.has_servers() and w.is_empty(), "a missing file: an empty config, no warning")
	var path := _dir.path_join("config.yaml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(EXAMPLE)
	f.close()
	c = ClientConfig.load_file(path, w)
	_check(c.servers.size() == 2 and c.source == path, "read from a file")
	var big := _dir.path_join("big.yaml")
	var bf := FileAccess.open(big, FileAccess.WRITE)
	bf.store_string("# " + "x".repeat(YamlLite.MAX_BYTES) + "\n")
	bf.close()
	w = PackedStringArray()
	c = ClientConfig.load_file(big, w)
	_check(not c.has_servers() and w.size() == 1 and w[0].contains("bytes, more than"), "a file over %d bytes is not read: %s" % [YamlLite.MAX_BYTES, w])
	OS.set_environment("SRREVAMP_SETTING_DIR", _dir)
	_check(ClientConfig.setting_dir() == _dir and ClientConfig.config_path() == _dir.path_join("config.yaml"), "SRREVAMP_SETTING_DIR overrides the folder")
	_check(ClientConfig.load_default().servers.size() == 2, "load_default reads <setting dir>/config.yaml")
	OS.set_environment("SRREVAMP_SETTING_DIR", "")
	_check(ClientConfig.setting_dir() == OS.get_executable_path().get_base_dir().path_join("setting"), "else setting/ beside the executable")

func _theme(intro: String) -> FrontEndTheme:
	var t := FrontEndTheme.new()
	t.intro = intro
	return t

func _precedence() -> void:
	var r := FrontEndTheme.resolve(null, _theme("roc"), null, _theme("rm"), _theme("constantinople"))
	_check(r.intro == "roc" and r.origin.get("intro") == "server", "the server's answer before setting/config.yaml")
	r = FrontEndTheme.resolve(null, null, _theme("egypt"), _theme("rm"), _theme("constantinople"))
	_check(r.intro == "egypt" and r.origin.get("intro") == "cache", "the cached answer before setting/config.yaml")
	r = FrontEndTheme.resolve(null, null, null, _theme("rm"), _theme("constantinople"))
	_check(r.intro == "constantinople" and r.origin.get("intro") == "setting", "setting/config.yaml before custom/theme.json")
	r = FrontEndTheme.resolve(null, null, null, _theme("rm"), null)
	_check(r.intro == "rm" and r.origin.get("intro") == "custom", "custom/theme.json when the config sets none")
	r = FrontEndTheme.resolve(_theme("jupiter_login"), _theme("roc"), null, null, _theme("constantinople"))
	_check(r.intro == "jupiter_login", "the preview variable before everything")
	r = FrontEndTheme.resolve(null, null, null, null, null)
	_check(r.intro == "", "nothing set: retail's default")
