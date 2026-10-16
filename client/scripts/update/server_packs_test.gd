extends SceneTree

## Round 789, lane U: purity -- which layers the archive set holds while a
## server's packs are in force (ServerPacks + AssetArchives), on synthetic
## archives written here in user:// (no game data):
## - no server packs: the player's own packs and custom/, as before;
## - a server that names its packs: exactly those over the base archives, the
##   player's packs and custom/ set aside (and logged);
## - a server that allows local extras: the player's packs below the
##   server's, custom/ on top;
## - the switch reopens the set (a new generation), only when it changes
##   anything, and back.

const Z := preload("res://scripts/pk2/pk3_test_archives.gd")
const ROOT := "user://server_packs_test"

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)

func _read(a: Pk2Reader, path: String) -> String:
	var e := ObjectLoader.find_file(a, path)
	if e == null:
		return "<none>"
	return a.read_file(e).get_string_from_utf8()

var base := ""
var local := ""
var custom := ""
var server_pack := ""

func _build() -> void:
	base = _abs(ROOT + "/pk2/Data.pk2")
	local = _abs(ROOT + "/pk2")
	custom = _abs(ROOT + "/custom")
	server_pack = _abs(ROOT + "/pk2/servers/127.0.0.1_15779/z_server.pk3")
	Z.write_pk2(ROOT + "/pk2/Data.pk2", {"prim/x.txt": Z.text("base"), "base_only.txt": Z.text("base")})
	Z.write_zip(ROOT + "/pk2/a_local.pk3", [Z.item("prim/x.txt", Z.text("local")), Z.item("only_local.txt", Z.text("local")),
		Z.item("both.txt", Z.text("local"))])
	Z.write(ROOT + "/custom/prim/x.txt", Z.text("custom"))
	Z.write(ROOT + "/custom/custom_only.txt", Z.text("custom"))
	Z.write_zip(ROOT + "/pk2/servers/127.0.0.1_15779/z_server.pk3", [Z.item("prim/x.txt", Z.text("server")),
		Z.item("server_only.txt", Z.text("server")), Z.item("both.txt", Z.text("server"))])

func _sel(extras: bool) -> ServerPacks.Selection:
	var s := ServerPacks.Selection.new()
	s.key = "127.0.0.1_15779"
	s.dir = server_pack.get_base_dir()
	s.paths = PackedStringArray([server_pack])
	s.local_extras = extras
	return s

func _set_from(opts: Dictionary) -> AssetArchives:
	var o := {"mode": "mixed", "base_paths": {"Data": base}, "pack_dir": local, "custom_dir": custom, "generation": 900}
	if not opts.is_empty():
		o["packs"] = opts["packs"]
		o["custom_dir"] = opts["custom_dir"]
		o["set_aside"] = opts["set_aside"]
		o["pack_origin"] = opts["origin"]
	return AssetArchives.open_set(o)

func _test_layer_opts() -> void:
	ServerPacks.set_selection(null)
	_check(ServerPacks.layer_opts(local, "mixed", custom).is_empty(), "no server: no change to the options")
	var plain := _set_from({})
	var d := plain.view("Data")
	_check(_read(d, "prim/x.txt") == "custom" and _read(d, "only_local.txt") == "local", "no server: custom/ over the player's packs, as before")
	_check(_read(d, "server_only.txt") == "<none>", "no server: a server folder's pack is not read (no subfolders)")

	ServerPacks.set_selection(_sel(false))
	var o := ServerPacks.layer_opts(local, "mixed", custom)
	_check(o["packs"] == PackedStringArray([server_pack]), "pure: exactly the server's packs (%s)" % [o["packs"]])
	_check(str(o["custom_dir"]) == "", "pure: custom/ set aside")
	var aside: PackedStringArray = o["set_aside"]
	_check(aside.size() == 2 and aside[0] == "pack a_local.pk3" and aside[1].begins_with("custom/"), "pure: what is set aside is named (%s)" % [aside])
	var pure := _set_from(o)
	d = pure.view("Data")
	_check(_read(d, "prim/x.txt") == "server", "pure: the server's pack serves over the base")
	_check(_read(d, "only_local.txt") == "<none>" and _read(d, "custom_only.txt") == "<none>", "pure: nothing of the player's packs or custom/")
	_check(_read(d, "base_only.txt") == "base", "pure: the base archive is still read under it")
	_check(str(pure.which("prim/x.txt")["served_by"]) == "z_server.pk3", "which(): the server's pack serves")
	var logged := "\n".join(pure.log_lines)
	_check(logged.contains("layers the packs of server 127.0.0.1_15779") and logged.contains("set aside while that server is connected: pack a_local.pk3"),
		"the log says whose packs and what is set aside")
	_check("\n".join(pure.describe()).contains("packs of server 127.0.0.1_15779"), "the debug panel names the server")

	ServerPacks.set_selection(_sel(true))
	o = ServerPacks.layer_opts(local, "mixed", custom)
	_check(o["packs"] == PackedStringArray([local.path_join("a_local.pk3"), server_pack]), "extras: the player's packs below the server's")
	var extras := _set_from(o)
	d = extras.view("Data")
	_check(_read(d, "prim/x.txt") == "custom", "extras: custom/ stays on top (rule 1)")
	_check(_read(d, "both.txt") == "server" and _read(d, "only_local.txt") == "local", "extras: the server's pack over the player's")
	# The mode does not filter the server's packs out.
	ServerPacks.set_selection(_sel(false))
	o = ServerPacks.layer_opts(local, "pk2", custom)
	_check(o["packs"] == PackedStringArray([server_pack]), "mode pk2: the server's .pk3 is layered all the same")

func _test_switch() -> void:
	OS.set_environment("OPENSRO_PK2_PATH", base)
	OS.set_environment("OPENSRO_PACK_DIR", local)
	OS.set_environment("OPENSRO_CUSTOM_DIR", custom)
	ServerPacks.set_selection(null)
	AssetArchives.reopen()
	var g0 := AssetArchives.current_generation()
	_check(_read(AssetArchives.data(), "prim/x.txt") == "custom", "the process's set: the player's own")
	_check(ServerPacks.apply(_sel(false), "test: a pure server"), "apply: the set changes")
	_check(AssetArchives.current_generation() == g0 + 1, "apply reopened the set (generation %d -> %d)" % [g0, AssetArchives.current_generation()])
	_check(_read(AssetArchives.data(), "prim/x.txt") == "server", "after the switch the shared set reads the server's pack")
	_check(not ServerPacks.apply(_sel(false), "test: the same again"), "the same selection again: nothing to do")
	_check(AssetArchives.current_generation() == g0 + 1, "and no reopen")
	_check(ServerPacks.apply(null, "test: back"), "back to the player's own")
	_check(_read(AssetArchives.data(), "prim/x.txt") == "custom", "the player's set again")

func _init() -> void:
	_build()
	_test_layer_opts()
	_test_switch()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
