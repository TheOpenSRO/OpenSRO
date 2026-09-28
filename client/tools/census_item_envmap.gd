extends SceneTree

## Dev tool (round 626): for every item model the item table names, the flag
## word of its ENVMAP mod (BsrReader.ParsedObject.env_map_flags; -1 none) and,
## for every alpha-test (0x200) layer of its material, whether that mod
## overrides it -- no test (flag word without bit 1), a test at ALPHAREF 1
## (with bit 1), or none (the layer's own 0x80 test stands). Prints each
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
	var hist := {}
	var layers := {"bit9_env_none": 0, "bit9_env_test": 0, "bit9_env_notest": 0}
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
			var mat := ObjectLoader.load_material(data, o.material_path) if o.material_path != "" else null
			if mat == null:
				continue
			for l in mat.layers:
				if l.unknown & 0x200 == 0:
					continue
				var k := "bit9_env_none" if f < 0 else ("bit9_env_test" if f & 2 != 0 else "bit9_env_notest")
				layers[k] += 1
				if f < 0:
					print("NOENV\t%s\t%s" % [o.material_path, l.layer_name])
	print("ITEM BSRS by env flag word: ", hist)
	print("BIT9 LAYERS: ", layers)
	quit(0)
