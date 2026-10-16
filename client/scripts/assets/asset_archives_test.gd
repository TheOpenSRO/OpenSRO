extends SceneTree

## Exercises the round 789 archive set (AssetArchives, LayeredArchive,
## Pk2Config's source mode) against synthetic archives written here, in
## user:// (never real game data), run headless:
## `godot --headless --path client --script res://scripts/assets/asset_archives_test.gd`
## Runs on the GDScript readers, and again on the native ones when the
## library is loaded.

const Z := preload("res://scripts/pk2/pk3_test_archives.gd")
const ROOT := "user://asset_archives_test"

var _failures := 0
var _mode := ""

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  [%s] %s" % [_mode, msg])
	else:
		print("FAIL [%s] %s" % [_mode, msg])
		_failures += 1

func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)

func _touch(path: String) -> void:
	Z.write(path, PackedByteArray())

func _test_discovery() -> void:
	var d := ROOT + "/discover"
	for f in ["assets.pk3", "Z_assets.pk2", "z_assets.pk3", "B.zip", "data.pk3", "Media.PK2", "readme.txt", "assets.pk2", "music.zip"]:
		_touch(d + "/" + f)
	var names := func(paths: PackedStringArray) -> Array:
		var out := []
		for p in paths:
			out.append(p.get_file())
		return out
	_check(names.call(AssetArchives.discover_packs(_abs(d), "mixed")) == ["assets.pk2", "assets.pk3", "B.zip", "Z_assets.pk2", "z_assets.pk3"],
		"mixed: by name, case ignored, .pk3 over .pk2 of one name, the base names left out (%s)" % [names.call(AssetArchives.discover_packs(_abs(d), "mixed"))])
	_check(names.call(AssetArchives.discover_packs(_abs(d), "pk3")) == ["assets.pk3", "B.zip", "z_assets.pk3"], "pk3: no .pk2 pack")
	_check(names.call(AssetArchives.discover_packs(_abs(d), "pk2")) == ["assets.pk2", "Z_assets.pk2"], "pk2: only the .pk2 packs")
	_check(AssetArchives.discover_packs(_abs(ROOT + "/nowhere"), "mixed").is_empty(), "a missing folder: no pack")

## The layered fixture: a pk2 Data and a pk3 Media at the bottom, two .pk3
## packs and a .pk2 pack, and custom/ with branding beside an overlay file.
func _build_layers() -> Dictionary:
	var d := ROOT + "/layers"
	Z.write_pk2(d + "/base/Data.pk2", {
		"Prim/Mtrl/a.ddj": Z.text("base-a"), "Prim/Mtrl/b.ddj": Z.text("base-b"),
		"Prim/Snd/x.wav": Z.text("base-x"), "readme.txt": Z.text("base-readme"), "object.ifo": Z.text("data-ifo"),
	})
	# Map holds an object.ifo of its own (rule 3: the volumes are not one namespace).
	Z.write_pk2(d + "/base/Map.pk2", {"object.ifo": Z.text("map-ifo"), "97/168.m": Z.text("terrain")})
	Z.write_zip(d + "/base/Media.pk3", [Z.item("textdata/t.txt", Z.text("media-t"), true)])
	Z.write_zip(d + "/packs/assets.pk3", [
		Z.item("prim/mtrl/a.ddj", Z.text("assets-a")), Z.item("prim/mtrl/new.ddj", Z.text("assets-new"), true),
		Z.item("textdata/t.txt", Z.text("assets-t")), Z.item("fonts/x.ttf", Z.text("font")),
	])
	Z.write_zip(d + "/packs/z_assets.pk3", [Z.item("PRIM\\MTRL\\A.DDJ", Z.text("z-a"))], true)
	Z.write_pk2(d + "/packs/m_extra.pk2", {"prim/mtrl/b.ddj": Z.text("pk2pack-b")})
	Z.write(d + "/custom/prim/mtrl/new.ddj", Z.text("custom-new"))
	Z.write(d + "/custom/theme.json", Z.text("{}"))
	Z.write(d + "/custom/frontend/logo.png", Z.text("png"))
	# A symbolic link in custom/ is refused (rule 6); made only where the OS lets us.
	var da := DirAccess.open(_abs(d + "/custom"))
	if da != null and not FileAccess.file_exists(d + "/custom/link.ddj"):
		da.create_link(_abs(d + "/base/Data.pk2"), _abs(d + "/custom/link.ddj"))
	return {
		"base_paths": {"Data": _abs(d + "/base/Data.pk2"), "Media": _abs(d + "/base/Media.pk3"), "Map": _abs(d + "/base/Map.pk2"), "Music": "", "Particles": ""},
		"pack_dir": _abs(d + "/packs"), "custom_dir": _abs(d + "/custom"),
	}

func _read(a: Pk2Reader, path: String) -> String:
	var e := ObjectLoader.find_file(a, path)
	if e == null:
		return "<none>"
	if e.is_dir:
		return "<dir>"
	return a.read_file(e).get_string_from_utf8()

func _test_layers(opts: Dictionary) -> void:
	var o := opts.duplicate()
	o["mode"] = "mixed"
	o["generation"] = 7
	var s := AssetArchives.open_set(o)
	_check(s.pack_paths.size() == 3, "three packs open")
	var data := s.view("Data")
	_check(data is LayeredArchive, "Data is seen through the packs")
	_check(_read(data, "prim\\mtrl\\a.ddj") == "z-a", "the later pack wins (z_assets over assets over the base)")
	_check(_read(data, "Prim/Mtrl/B.ddj") == "pk2pack-b", "an extra .pk2 pack overrides the base")
	_check(_read(data, "PRIM/MTRL/NEW.DDJ") == "custom-new", "custom/ wins over every pack")
	_check(_read(data, "prim\\snd\\x.wav") == "base-x", "a path only the base holds reads from it")
	_check(_read(data, "readme.txt") == "base-readme", "the base's root file reads")
	_check(_read(data, "textdata\\t.txt") == "assets-t", "a pack's path shows in every view (textdata in Data)")
	_check(_read(data, "theme.json") == "{}" and _read(data, "frontend/logo.png") == "png", "custom/ is one overlay, round 678's branding files included (rule 1)")
	_check(_read(data, "link.ddj") == "<none>", "a symbolic link in custom/ is refused")
	_check(_read(data, "\\prim\\\\mtrl/a.ddj\\") == "z-a", "empty segments are skipped (rule 4)")
	_check(_read(data, "prim/../readme.txt") == "<none>" and _read(data, "c:readme.txt") == "<none>", "an unsafe lookup finds nothing")
	_check(_read(data, "object.ifo") == "data-ifo" and _read(s.view("Map"), "OBJECT.IFO") == "map-ifo", "each volume answers from its own base (rule 3)")
	_check(_read(data, "prim/mtrl/missing.ddj") == "<none>", "a path no layer holds is null")
	_check(AssetSource.read_bytes("prim\\mtrl\\a.ddj", data).get_string_from_utf8() == "z-a", "AssetSource reads through the view")
	var mtrl := ObjectLoader.find_file(data, "prim\\mtrl")
	_check(mtrl != null and mtrl.is_dir, "a folder the packs share is found")
	var listed := {}
	if mtrl != null:
		for e in data.read_dir_at(mtrl):
			listed[e.name.to_lower()] = data.read_file(e).get_string_from_utf8()
	_check(listed == {"a.ddj": "z-a", "b.ddj": "pk2pack-b", "new.ddj": "custom-new"}, "the merged listing holds every layer's names, each read from its winner (%s)" % [listed])
	var root := []
	for e in data.read_dir():
		root.append(e.name.to_lower())
	root.sort()
	_check(root == ["fonts", "frontend", "object.ifo", "prim", "readme.txt", "textdata", "theme.json"], "the root merges too (%s)" % [root])
	var snd := ObjectLoader.find_file(data, "prim/snd")
	_check(snd != null and snd._layer == 0 and data.read_dir_at(snd).size() == 1, "a folder only the base has lists as the base's own")
	var fonts := ObjectLoader.find_file(data, "fonts")
	_check(fonts != null and fonts.is_dir and data.read_dir_at(fonts).size() == 1, "a folder only a pack has lists (the font scan's case)")
	_check(ObjectLoader.find_file(data, "prim\\snd\\x.wav\\ ") == null, "the audio warm-up's probe still answers null")
	_check(data.cache_key().ends_with("|set7") and data.cache_key().begins_with(_abs(ROOT + "/layers/base/Data.pk2")), "the cache key names the file and the set (%s)" % data.cache_key())
	var media := s.view("Media")
	_check(media is LayeredArchive and _read(media, "textdata/t.txt") == "assets-t", "a pack overrides a .pk3 base too")
	_check(_read(media, "prim/mtrl/a.ddj") == "z-a", "and its prim paths show in Media")
	_check(s.view("Music") == null, "a missing base gives no view, packs or not")
	_check(s.view("Data") == data, "a view is made once")
	var w := s.which("prim\\mtrl\\a.ddj")
	_check(w["served_by"] == "z_assets.pk3" and Array(w["also_in"]) == ["assets.pk3", "base Data.pk2"], "which: the winner and the layers under it (%s)" % AssetArchives.describe_which(w))
	w = s.which("prim/mtrl/new.ddj")
	_check(w["served_by"] == "custom/", "which: custom/ (%s)" % AssetArchives.describe_which(w))
	w = s.which("prim/snd/x.wav")
	_check(w["served_by"] == "base Data.pk2" and (w["also_in"] as PackedStringArray).is_empty(), "which: the base (%s)" % AssetArchives.describe_which(w))
	w = s.which("object.ifo")
	_check(w["served_by"] == "base Data.pk2" and Array(w["also_in"]) == ["base Map.pk2"], "which: every base file holding it (%s)" % AssetArchives.describe_which(w))
	_check(s.which("nope.txt")["served_by"] == "", "which: nothing")
	_check(s.describe().size() >= 8, "describe lists the set")
	# Threads: the views are read from WorkerThreadPool tasks.
	var bad := [0]
	var lock := Mutex.new()
	var tasks := []
	for n in range(6):
		tasks.append(WorkerThreadPool.add_task(func():
			var b := 0
			for k in range(100):
				if _read(data, ["prim/mtrl/a.ddj", "prim/mtrl/b.ddj", "prim/snd/x.wav", "prim/mtrl/new.ddj"][(n + k) % 4]) == "<none>":
					b += 1
			lock.lock()
			bad[0] += b
			lock.unlock()))
	for t in tasks:
		WorkerThreadPool.wait_for_task_completion(t)
	_check(bad[0] == 0, "six tasks read the view at once")

func _test_modes(opts: Dictionary) -> void:
	var o := opts.duplicate()
	o["mode"] = "pk2"
	var s := AssetArchives.open_set(o)
	var data := s.view("Data")
	_check(s.pack_paths.size() == 1 and data is LayeredArchive, "pk2: the .pk2 pack alone")
	_check(_read(data, "prim/mtrl/a.ddj") == "base-a" and _read(data, "prim/mtrl/b.ddj") == "pk2pack-b", "pk2: .pk3 packs ignored, the .pk2 pack read")
	_check(_read(data, "prim/mtrl/new.ddj") == "custom-new", "custom/ is read in every mode")
	o["mode"] = "pk3"
	s = AssetArchives.open_set(o)
	data = s.view("Data")
	_check(s.pack_paths.size() == 2, "pk3: the .pk2 pack is not read")
	_check(_read(data, "prim/mtrl/b.ddj") == "base-b" and _read(data, "prim/mtrl/a.ddj") == "z-a", "pk3: the .pk3 packs layer, the .pk2 one does not")
	o["mode"] = "mixed"
	o["pack_dir"] = _abs(ROOT + "/empty_packs")
	o["custom_dir"] = ""
	DirAccess.make_dir_recursive_absolute(o["pack_dir"])
	s = AssetArchives.open_set(o)
	data = s.view("Data")
	_check(not (data is LayeredArchive), "mixed with an empty pack folder: the base archive itself, no layer in between")
	_check(_read(data, "prim/mtrl/a.ddj") == "base-a", "and it reads as before")

## A volume with both its converted .pk3 and its .pk2: the .pk3 above (rule 3).
func _test_volume_chain() -> void:
	var d := ROOT + "/volume"
	Z.write_pk2(d + "/Data.pk2", {"prim/a.ddj": Z.text("pk2-a"), "prim/only2.ddj": Z.text("only-in-pk2"), "x.txt": Z.text("pk2-x")})
	Z.write_zip(d + "/Data.pk3", [Z.item("Prim/A.ddj", Z.text("pk3-a"), true), Z.item("prim/only3.ddj", Z.text("only-in-pk3"))])
	var s := AssetArchives.open_set({"mode": "mixed", "base_paths": {"Data": PackedStringArray([_abs(d + "/Data.pk3"), _abs(d + "/Data.pk2")])},
		"pack_dir": "", "custom_dir": ""})
	var data := s.view("Data")
	_check(data is LayeredArchive, "two base files: a layered view without any pack")
	_check(_read(data, "prim/a.ddj") == "pk3-a", "Data.pk3 above Data.pk2")
	_check(_read(data, "prim/only2.ddj") == "only-in-pk2" and _read(data, "prim/only3.ddj") == "only-in-pk3", "each base file's own paths read")
	var prim := ObjectLoader.find_file(data, "prim")
	var names := {}
	for e in data.read_dir_at(prim):
		names[e.name.to_lower()] = data.read_file(e).get_string_from_utf8()
	_check(names == {"a.ddj": "pk3-a", "only3.ddj": "only-in-pk3", "only2.ddj": "only-in-pk2"}, "a folder in both lists the union, each from its winner (%s)" % [names])
	var w := s.which("prim/a.ddj")
	_check(w["served_by"] == "base Data.pk3" and Array(w["also_in"]) == ["base Data.pk2"], "which names both base files (%s)" % AssetArchives.describe_which(w))
	_check(Array(Pk2Config.chain_in(_abs(d), "Data", "mixed")) == [_abs(d + "/Data.pk3"), _abs(d + "/Data.pk2")], "Pk2Config finds the chain")

func _test_resolution() -> void:
	var d := _abs(ROOT + "/resolve")
	_touch(ROOT + "/resolve/both/Data.pk2")
	_touch(ROOT + "/resolve/both/Data.pk3")
	_touch(ROOT + "/resolve/pk2only/Data.pk2")
	_touch(ROOT + "/resolve/both/Data.zip")
	_check(Array(Pk2Config.chain_in(d + "/both", "Data", "mixed")) == [d + "/both/Data.pk3", d + "/both/Data.zip", d + "/both/Data.pk2"], "mixed: .pk3 > .zip > .pk2")
	_check(Array(Pk2Config.chain_in(d + "/both", "Data", "pk2")) == [d + "/both/Data.pk2"], "pk2 takes the .pk2")
	_check(Array(Pk2Config.chain_in(d + "/both", "Data", "pk3")) == [d + "/both/Data.pk3", d + "/both/Data.zip"], "pk3 takes the .pk3 and the .zip")
	_check(Array(Pk2Config.chain_in(d + "/pk2only", "Data", "mixed")) == [d + "/pk2only/Data.pk2"], "mixed falls back to the .pk2")
	_check(Pk2Config.chain_in(d + "/pk2only", "Data", "pk3").is_empty(), "pk3 finds no .pk2")
	_check(Array(Pk2Config.chain_from_env(d + "/both/Data.pk2", "pk2")) == [d + "/both/Data.pk2"], "pk2: the env value as set")
	_check(Array(Pk2Config.chain_from_env(d + "/both/Data.pk2", "mixed")) == [d + "/both/Data.pk3", d + "/both/Data.zip", d + "/both/Data.pk2"], "mixed: the env value's volume")
	_check(Array(Pk2Config.chain_from_env(d + "/pk2only/Data.pk2", "mixed")) == [d + "/pk2only/Data.pk2"], "mixed: the env value when no sibling")
	_check(Array(Pk2Config.chain_from_env(d + "/pk2only/Data.pk2", "pk3")) == [d + "/pk2only/Data.pk3"], "pk3: the .pk3 sibling, there or not")
	_check(Pk2Config.normalise_mode(" PK3 ") == "pk3" and Pk2Config.normalise_mode("zip") == "", "mode words")
	var w := PackedStringArray()
	var c := ClientConfig.from_text("assets:\n  source: pk3\n", "t", w)
	_check(c.asset_source == "pk3" and w.is_empty(), "config.yaml assets.source")
	w = PackedStringArray()
	c = ClientConfig.from_text("assets:\n  source: zip\n  other: 1\n", "t", w)
	_check(c.asset_source == "" and w.size() == 2, "a bad assets.source and an unknown key warn (%s)" % [w])
	OS.set_environment("OPENSRO_ASSET_SOURCE", "pk2")
	Pk2Config.reset_source_mode()
	_check(Pk2Config.source_mode() == "pk2" and Pk2Config.source_mode_origin() == "OPENSRO_ASSET_SOURCE", "the env override")
	OS.unset_environment("OPENSRO_ASSET_SOURCE")
	Pk2Config.reset_source_mode()

## The process's own set, from the environment, and reopen().
func _test_current(opts: Dictionary) -> void:
	var saved := {}
	var env := {
		"OPENSRO_PK2_PATH": opts["base_paths"]["Data"], "OPENSRO_MEDIA_PK2_PATH": opts["base_paths"]["Media"],
		"OPENSRO_PACK_DIR": opts["pack_dir"], "OPENSRO_CUSTOM_DIR": opts["custom_dir"], "OPENSRO_ASSET_SOURCE": "mixed",
	}
	for k in env:
		saved[k] = OS.get_environment(k)
		OS.set_environment(k, env[k])
	var g0 := AssetArchives.current_generation()
	var data := AssetArchives.data()
	_check(AssetArchives.current_generation() > g0, "the environment's set is built")
	_check(data is LayeredArchive and _read(data, "prim/mtrl/a.ddj") == "z-a", "AssetArchives.data() reads through the packs")
	_check(AssetArchives.data() == data, "asked again, the same view")
	var g1 := AssetArchives.current_generation()
	Z.write_zip(opts["pack_dir"] + "/zz_late.pk3", [Z.item("prim/mtrl/a.ddj", Z.text("late-a"))])
	_check(_read(AssetArchives.data(), "prim/mtrl/a.ddj") == "z-a", "a pack added later is not seen before reopen()")
	AssetArchives.reopen()
	_check(AssetArchives.current_generation() == g1 + 1, "reopen() makes a new set")
	_check(_read(AssetArchives.data(), "prim/mtrl/a.ddj") == "late-a", "after reopen() the new pack wins")
	_check(_read(data, "prim/mtrl/a.ddj") == "z-a", "a handle taken before reads the set it came from")
	DirAccess.remove_absolute(opts["pack_dir"] + "/zz_late.pk3")
	OS.set_environment("OPENSRO_ASSET_SOURCE", "pk2")
	var g2 := AssetArchives.current_generation()
	_check(_read(AssetArchives.data(), "prim/mtrl/a.ddj") == "base-a" and AssetArchives.current_generation() == g2 + 1
		and AssetArchives.current().mode == "pk2", "a changed environment rebuilds the set (pk2: the .pk3 packs are not read)")
	for k in saved:
		if saved[k] == "":
			OS.unset_environment(k)
		else:
			OS.set_environment(k, saved[k])
	Pk2Config.reset_source_mode()
	AssetArchives.reopen()

func _all() -> void:
	_test_discovery()
	var opts := _build_layers()
	_test_layers(opts)
	_test_modes(opts)
	_test_volume_chain()
	_test_resolution()
	_test_current(opts)

func _init() -> void:
	_mode = "gdscript"
	NativeAssets.force_gdscript = true
	_all()
	NativeAssets.force_gdscript = false
	if NativeAssets.available():
		_mode = "native"
		_all()
	else:
		print("native library not available -- GDScript only")
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURE(S)" % _failures)
		quit(1)
