extends SceneTree

## Dev tool (round 626): for every item model the item table names, the flag
## word of its ENVMAP mod (BsrReader.ParsedObject.env_map_flags; -1 none) and,
## for every alpha-test (0x200) layer of its material, whether that mod
## overrides it -- no test (flag word without bit 1), a test at ALPHAREF 1
## (with bit 1), or none (the layer's own 0x80 test stands); a layer an MTRL
## mod governs is counted apart (bit9_mtrl). Prints each
## layer left to its own test as NOENV <bmt> <layer>, then the totals.
## Headless; ~10 minutes (it reads every item .bsr and .bmt):
##   godot4 --headless --path client --script res://tools/census_item_envmap.gd
##   (reads /opt/sro-files/client/{Data,Media}.pk2, the render box's layout)
func _initialize() -> void:
	var data := Pk2Reader.open("/opt/sro-files/client/Data.pk2")
	var media := Pk2Reader.open("/opt/sro-files/client/Media.pk2")
	var items := {}
	for path in ItemTableReader.TABLE_PATHS:
		var e := ObjectLoader.find_file(media, path)
		if e != null:
			ItemTableReader.parse(media.read_file(e), items)
	var seen := {}
	var mtrl_items := 0
	var two_pass_items := 0
	var env_shapes := {}
	var hist := {}
	var layers := {"bit9_env_none": 0, "bit9_env_test": 0, "bit9_env_notest": 0, "bit9_mtrl": 0}
	for id in items:
		for m in items[id].model_paths:
			var p := String(m).to_lower()
			if seen.has(p):
				continue
			seen[p] = true
			var b := SkinnedBsrAssembler._read(data, m)
			if b.is_empty():
				continue
			var o := BsrReader.parse(b)
			if o == null or not o.is_item():
				continue
			var f := o.env_map_flags
			hist[f] = int(hist.get(f, 0)) + 1
			# What else governs the draw: an MTRL mod or the two-pass flag.
			for mm in o.material_mods:
				if int(mm["kind"]) == BsrReader.MOD_MTRL:
					mtrl_items += 1
					break
			if o.two_pass():
				two_pass_items += 1
			for mm in o.material_mods:
				if int(mm["kind"]) == BsrReader.MOD_ENVMAP:
					var key := "set%d_w1_%d_mat%s" % [int(mm["set_kind"]), int(mm["w1"]), "all" if int(mm["material"]) == 0xFFFFFFFF else "n"]
					env_shapes[key] = int(env_shapes.get(key, 0)) + 1
			var mat := ObjectLoader.load_material(data, o.material_path) if o.material_path != "" else null
			if mat == null:
				continue
			for li in range(mat.layers.size()):
				var l: BmtReader.Layer = mat.layers[li]
				if l.unknown & 0x200 == 0:
					continue
				# A layer an MTRL mod governs takes the mod's states, not the
				# flag word's or the env map's (ObjectLoader.layer_draw_rule).
				if not o.mtrl_mod_for(li).is_empty():
					layers["bit9_mtrl"] += 1
					continue
				var k := "bit9_env_none" if f < 0 else ("bit9_env_test" if f & 2 != 0 else "bit9_env_notest")
				layers[k] += 1
				if f < 0:
					print("NOENV\t%s\t%s" % [o.material_path, l.layer_name])
	print("ITEM BSRS by env flag word: ", hist)
	print("BIT9 LAYERS: ", layers)
	print("ENVMAP MOD SHAPES (set kind, header word 1, material): ", env_shapes)
	print("ITEMS WITH AN MTRL MOD: %d, TWO-PASS ITEMS: %d" % [mtrl_items, two_pass_items])
	quit(0)
