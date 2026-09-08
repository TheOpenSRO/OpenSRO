extends SceneTree

## Dev tool: checks that a region's `.m` heightmap and the `.nvm` this
## project pairs with it describe the same place.
##
## The navmesh filename encodes a region id, and which way the two region
## coordinates pack into it is a convention that has to be right: the wrong
## packing still names a real file that parses cleanly and describes a
## completely different region. This compares both candidate packings
## against the region's own heightmap and says which one agrees.
##
## The comparison is between each `.nvm` plane cell's own height and the
## mean `.m` heightmap height over that cell's footprint. Water cells are
## skipped -- a water plane's height is its surface, not its ground.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_navmesh_pairing.gd -- \
##     --pk2=/path/Data.pk2 --map=/path/Map.pk2 --regions=98/168,97/168,96/167

const NAVMESH_PATH_FORMAT := "navmesh\\nv_%04x.nvm"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

## Mean heightmap height over one plane cell's footprint.
func _mean_ground(region: MapmReader.ParsedRegion, pcol: int, prow: int) -> float:
	var cell := 1920.0 / float(NvmReader.PLANE_MAP_SIDE)
	var total := 0.0
	var n := 0
	for i in range(5):
		for j in range(5):
			var x := (float(pcol) + (float(i) + 0.5) / 5.0) * cell
			var z := (float(prow) + (float(j) + 0.5) / 5.0) * cell
			var h := MapmTerrainBuilder.height_at(region, x, z)
			if is_nan(h):
				continue
			total += h
			n += 1
	return total / float(n) if n > 0 else NAN

## Mean absolute difference between a navmesh's plane heights and the
## heightmap's, over the non-water cells both describe.
func _disagreement(nvm: NvmReader.ParsedRegion, m: MapmReader.ParsedRegion) -> Array:
	var side := NvmReader.PLANE_MAP_SIDE
	if nvm == null or nvm.plane_heights.size() < side * side:
		return [NAN, 0]
	var total := 0.0
	var n := 0
	for prow in range(side):
		for pcol in range(side):
			if nvm.plane_types[prow * side + pcol] == NvmWater.PLANE_TYPE_WATER:
				continue
			var ground := _mean_ground(m, pcol, prow)
			if is_nan(ground):
				continue
			total += absf(nvm.plane_heights[prow * side + pcol] - ground)
			n += 1
	return [total / float(n) if n > 0 else NAN, n]

func _initialize() -> void:
	var data_path := _arg("--pk2")
	var map_path := _arg("--map")
	var regions := _arg("--regions")
	if data_path == "" or map_path == "" or regions == "":
		printerr("usage: --pk2=<Data.pk2> --map=<Map.pk2> --regions=98/168,...")
		quit(2)
		return
	var data := Pk2Reader.open(data_path)
	var map := Pk2Reader.open(map_path)
	if data == null or map == null:
		printerr("could not open the archives")
		quit(1)
		return

	print("%-9s  %-14s %10s %6s   %-14s %10s %6s" % [
		"region", "(x<<8)|y", "disagree", "cells", "(y<<8)|x", "disagree", "cells"])
	for spec in regions.split(","):
		var parts := spec.strip_edges().split("/")
		if parts.size() != 2:
			continue
		var rx := int(parts[0])
		var ry := int(parts[1])
		var mbytes := AssetSource.read_bytes("%d\\%d.m" % [rx, ry], map)
		if mbytes.is_empty():
			print("%-9s  no .m" % spec)
			continue
		var m := MapmReader.parse(mbytes)
		var out := "%-9s " % spec
		for key in [(rx << 8) | ry, (ry << 8) | rx]:
			var nvm_bytes := AssetSource.read_bytes(NAVMESH_PATH_FORMAT % key, data)
			if nvm_bytes.is_empty():
				out += " %-14s %10s %6s  " % ["nv_%04x (none)" % key, "-", "-"]
				continue
			var nvm := NvmReader.parse(nvm_bytes)
			var r := _disagreement(nvm, m)
			out += " %-14s %10.2f %6d  " % ["nv_%04x" % key, r[0], r[1]]
		print(out)
	quit(0)
