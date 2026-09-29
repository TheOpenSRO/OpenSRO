extends SceneTree

## Dev tool (round 643): does every model the map places load and draw?
##
## Reads a model list -- `<keys>\t<undrawn keys>\t<path>` lines, written by
## `server/cmd/mapobjcensus -dumpmodels` over every region's `.o2` -- and
## prepares each model through ObjectLoader.prepare_object, the path the
## world takes (World3D._objects_prepare). For each it records:
##
##   LOAD_FAILED    prepare_object returned no node, with the reason found
##                  by re-reading the chain: the model file missing, the
##                  `.bsr` or `.cpd` refused by its reader, every mesh piece
##                  missing or refused (with the `.bms` header's version)
##   MESH_LESS      a `.bsr` naming no mesh at all (a particle marker)
##   PIECE_MISSING  some of its pieces not found or refused (the rest drawn)
##   ZERO_TRIS      a piece built with no triangle
##   NO_MATERIAL    a piece with no material (no `.bmt`, or no layer)
##   NO_TEXTURE     a layer whose texture is missing or did not decode
##   HEADER_SCAN    a `.bsr` whose section table does not chain, so its
##                  meshes came from the forward scan (possibly too few)
##   CUT_AWAY       a piece whose alpha-tested texture keeps under 1 % of its
##                  texels at the rule's reference (the material rule would
##                  cut the piece to nothing)
##   OK             everything above clear
##
## Classes count models and the placements (keys) behind them, so a failure
## on grass placed 1,000 times weighs more than one on a lone prop.
##
## Usage (the box, after a sync):
##   remote_godot.sh script res://tools/map_object_census.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --models=/var/tmp/invisobj/models.tsv [--verbose] [--match=bridge]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
		if a == flag:
			return "1"
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var list := FileAccess.get_file_as_string(_arg("--models"))
	if data == null or list == "":
		printerr("usage: --pk2=<Data.pk2> --models=<models.tsv>")
		quit(2)
		return
	var verbose := _arg("--verbose") != ""
	var match_text := _arg("--match").to_lower()
	var classes := {}
	var models := 0
	var keys := 0
	var tris := 0
	for line in list.split("\n", false):
		var cols := line.split("\t")
		if cols.size() < 3:
			continue
		var path: String = cols[2]
		if match_text != "" and not path.to_lower().contains(match_text):
			continue
		var n := int(cols[0])
		models += 1
		keys += n
		var result := _census(data, path)
		tris += int(result["tris"])
		for c in result["classes"]:
			if not classes.has(c):
				classes[c] = {"models": 0, "keys": 0, "examples": []}
			classes[c]["models"] += 1
			classes[c]["keys"] += n
			if (classes[c]["examples"] as Array).size() < 8:
				(classes[c]["examples"] as Array).append("%s (%d)" % [path.get_file(), n])
			if verbose or match_text != "":
				print("MODEL %-10s keys=%d tris=%d pieces=%d %s -- %s" % [c, n, result["tris"], result["pieces"], path, result["why"]])
	print("CENSUS %d models, %d keys, %d triangles over one of each" % [models, keys, tris])
	var names := classes.keys()
	names.sort()
	for c in names:
		print("CLASS %-14s models=%d keys=%d e.g. %s" % [c, classes[c]["models"], classes[c]["keys"], ", ".join(classes[c]["examples"])])
	quit(0)

func _census(data: Pk2Reader, path: String) -> Dictionary:
	var out := {"classes": [], "tris": 0, "pieces": 0, "why": ""}
	var textures := {}
	var prepared := ObjectLoader.prepare_object(data, path, {}, textures)
	var root = prepared["root"]
	if root == null:
		out["classes"] = ["LOAD_FAILED"]
		out["why"] = _why_failed(data, path, prepared)
		return out
	var classes := {}
	var whys: Array[String] = []
	_walk(data, root, textures, classes, whys, out)
	# A `.bsr` whose header section table does not chain is read by the
	# forward scan, which can return fewer meshes than the file holds (round
	# 625: the swaying trees lost their leaves that way).
	for bsr_path in _bsr_paths(data, path):
		var entry := ObjectLoader.find_file(data, bsr_path)
		if entry != null and BsrReader.parse_sections(data.read_file(entry)) == null:
			classes["HEADER_SCAN"] = true
			whys.append("%s: the header table does not chain; read by the forward scan" % bsr_path.get_file())
	if classes.is_empty():
		classes["OK"] = true
	out["classes"] = classes.keys()
	out["why"] = "; ".join(whys)
	return out

func _walk(data: Pk2Reader, node: Dictionary, textures: Dictionary, classes: Dictionary, whys: Array[String], out: Dictionary) -> void:
	if node["kind"] == "cpd":
		for child in node["children"]:
			_walk(data, child, textures, classes, whys, out)
		return
	var pieces: Array = node["pieces"]
	if pieces.is_empty():
		classes["MESH_LESS"] = true
		whys.append("%s names no mesh" % node["name"])
		return
	for piece in pieces:
		out["pieces"] += 1
		var arrays: Array = piece["arrays"]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var t := indices.size() / 3
		out["tris"] += t
		if t == 0:
			classes["ZERO_TRIS"] = true
			whys.append("%s has no triangle" % piece["name"])
		var plan = piece["material"]
		if plan == null:
			classes["NO_MATERIAL"] = true
			whys.append("%s has no material" % piece["name"])
			continue
		var key: String = plan["texture_key"]
		if key == "" or not textures.has(key):
			classes["NO_TEXTURE"] = true
			whys.append("%s: layer %s texture '%s' missing or undecodable" % [piece["name"], (plan["layer"] as BmtReader.Layer).layer_name, (plan["layer"] as BmtReader.Layer).texture_path])
			continue
		var ref := int(plan["alpha_ref"])
		if ref > 0:
			var kept := _kept(textures[key]["image"], ref)
			if kept < 0.01:
				classes["CUT_AWAY"] = true
				whys.append("%s: %.2f%% of %s (%s) kept at alpha %d%s" % [piece["name"], kept * 100.0, key.get_file(),
					textures[key]["four_cc"], ref, " (an MTRL mod governs it: its stage ops, not only the texture, set the alpha)" if (plan["rule"] as Dictionary).get("mtrl", false) else ""])

## The `.bsr` files behind a model: itself, or a compound's members.
func _bsr_paths(data: Pk2Reader, path: String) -> Array[String]:
	var out: Array[String] = []
	if not path.to_lower().ends_with(".cpd"):
		out.append(path)
		return out
	var entry := ObjectLoader.find_file(data, path)
	if entry == null:
		return out
	var compound := CpdReader.parse(data.read_file(entry))
	if compound != null:
		out.append_array(compound.bsr_paths)
	return out

## The fraction of texels at or above `ref`: what the alpha test keeps.
func _kept(source: Image, ref: int) -> float:
	if source == null:
		return 1.0
	var image := source.duplicate() as Image
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var bytes := image.get_data()
	var kept := 0
	var i := 3
	while i < bytes.size():
		if bytes[i] >= ref:
			kept += 1
		i += 4
	return float(kept) / float(maxi(bytes.size() / 4, 1))

func _why_failed(data: Pk2Reader, path: String, prepared: Dictionary) -> String:
	var missing: Array = prepared["missing"]
	var entry := ObjectLoader.find_file(data, path)
	if entry == null:
		return "the model file is not in the archive"
	var bytes := data.read_file(entry)
	var magic := bytes.slice(0, 12).get_string_from_ascii()
	if path.to_lower().ends_with(".cpd"):
		var compound := CpdReader.parse(bytes)
		if compound == null:
			return "CpdReader refused it (%s)" % magic
		var parts: Array[String] = []
		for sub in compound.bsr_paths:
			parts.append("%s: %s" % [sub.get_file(), _why_failed(data, sub, {"missing": []}) if ObjectLoader.prepare_object(data, sub)["root"] == null else "loads"])
		return "compound of %d: %s" % [compound.bsr_paths.size(), "; ".join(parts)]
	var obj := BsrReader.parse(bytes)
	if obj == null:
		return "BsrReader refused it (%s, %d bytes)" % [magic, bytes.size()]
	var meshes: Array[String] = []
	if obj.mesh_path != "":
		meshes.append(obj.mesh_path)
	meshes.append_array(obj.sub_mesh_paths)
	var reasons: Array[String] = []
	for m in meshes:
		var me := ObjectLoader.find_file(data, m)
		if me == null:
			reasons.append("%s not found" % m)
			continue
		var mb := data.read_file(me)
		reasons.append("%s refused (%s, %d bytes)" % [m.get_file(), mb.slice(0, 12).get_string_from_ascii(), mb.size()])
	return "%d mesh(es): %s; missing: %s" % [meshes.size(), "; ".join(reasons), ", ".join(missing)]
