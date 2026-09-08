extends SceneTree

## Dev tool: checks whether the navmesh this project pairs with a region
## actually describes that region, by asking two independent sources the
## same question -- how much water is here?
##
## The navmesh's plane map marks cells as water. The region's own authored
## minimap art paints water blue. Those are produced by different pipelines
## from the same ground truth, so across many regions they should rise and
## fall together. If a region whose art is entirely dry has a navmesh
## claiming a third of it is water, the two are not describing the same
## place and the navmesh filename key is wrong.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_water_vs_minimap.gd -- \
##     --pk2=/path/Data.pk2 --media=/path/Media.pk2 --regions=97/168,96/168,...

const NAVMESH_PATH_FORMAT := "navmesh\\nv_%04x.nvm"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

## Share of a minimap's pixels that read as water: noticeably bluer than
## they are red, and not near-black (unpainted border).
func _blue_share(image: Image) -> float:
	var blue := 0
	var total := 0
	for y in range(0, image.get_height(), 2):
		for x in range(0, image.get_width(), 2):
			var c := image.get_pixel(x, y)
			if c.r + c.g + c.b < 0.15:
				continue
			total += 1
			if c.b > c.r + 0.08 and c.b > 0.20:
				blue += 1
	return float(blue) / float(maxi(total, 1))

func _initialize() -> void:
	var data_path := _arg("--pk2")
	var media_path := _arg("--media")
	var regions := _arg("--regions")
	if data_path == "" or media_path == "" or regions == "":
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2> --regions=97/168,...")
		quit(2)
		return
	var data := Pk2Reader.open(data_path)
	var media := Pk2Reader.open(media_path)

	print("%-9s %14s %14s" % ["region", "navmesh water", "minimap blue"])
	for spec in regions.split(","):
		var parts := spec.strip_edges().split("/")
		if parts.size() != 2:
			continue
		var rx := int(parts[0])
		var ry := int(parts[1])

		var water := "-"
		var nvm_bytes := AssetSource.read_bytes(NAVMESH_PATH_FORMAT % ((rx << 8) | ry), data)
		if not nvm_bytes.is_empty():
			var region := NvmReader.parse(nvm_bytes)
			if region != null:
				var n := 0
				for t in region.plane_types:
					if t == NvmWater.PLANE_TYPE_WATER:
						n += 1
				water = "%5.1f%%" % (100.0 * float(n) / float(region.plane_types.size()))

		var blue := "-"
		# The real minimap filename is <y>x<x>.ddj -- see _zone_paths.
		var mm_bytes := AssetSource.read_bytes("minimap\\%dx%d.ddj" % [ry, rx], media)
		if not mm_bytes.is_empty():
			var parsed := DdjReader.parse(mm_bytes)
			if parsed != null:
				var tex := DdjReader.to_texture(parsed)
				if tex != null:
					var img := tex.get_image()
					img.decompress()
					blue = "%5.1f%%" % (100.0 * _blue_share(img))

		print("%-9s %14s %14s" % [spec, water, blue])
	quit(0)
