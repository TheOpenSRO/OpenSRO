extends SceneTree

## What round 583's seasonal filter leaves out of real regions, measured
## against the user's own archives: for each region, World3D's own objects
## job and prepare (_objects_job, _objects_prepare) run headless, and the
## prepare's per-set hidden count (job["seasonal_hid"]) is printed. Also
## counts, in each region's own `.nvm`, the object records whose id is
## seasonal -- navigation would need changing if any were.
##
## The prepare is run without Data.pk2, so it stops right after the filter
## and the ownership step (the "SRREVAMP_PK2_PATH not set" early return)
## instead of reading every model. With --full it runs to the end and the
## seasonal pieces among the placements it hands the commit are counted
## (`DRAWN`), by set.
##
##   client/tools/remote_godot.sh script res://tools/probe_seasonal.gd -- \
##     --map=/opt/sro-files/client/Map.pk2 --data=/opt/sro-files/client/Data.pk2 \
##     [--seasonal=christmas] [--region=97/168 ...] [--full=1]
##
## --seasonal is SRREVAMP_SEASONAL (set here because the remote runner does
## not pass the environment through). Default regions: Jangan's nine,
## 96-98 / 167-169.

func _args(flag: String) -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			out.append(a.substr(flag.length() + 1))
	return out

func _initialize() -> void:
	var maps := _args("--map")
	var datas := _args("--data")
	if maps.is_empty() or datas.is_empty():
		printerr("usage: --map=<Map.pk2> --data=<Data.pk2> [--seasonal=<list>] [--region=<y>/<x> ...]")
		quit(2)
		return
	var seasonal := _args("--seasonal")
	OS.set_environment("SRREVAMP_SEASONAL", seasonal[0] if not seasonal.is_empty() else "")
	var regions := _args("--region")
	if regions.is_empty():
		for y in [96, 97, 98]:
			for x in [167, 168, 169]:
				regions.append("%d/%d" % [y, x])

	var map_pk2 := Pk2Reader.open(maps[0])
	var data_pk2 := Pk2Reader.open(datas[0])
	if map_pk2 == null or data_pk2 == null:
		printerr("could not open the archives")
		quit(1)
		return
	var S := load("res://scripts/World3D.gd") as GDScript
	var w: Node = S.new()
	w._map_pk2 = map_pk2
	w._data_pk2 = data_pk2
	var data_index := ObjidxReader.parse(AssetSource.read_bytes("navmesh\\object.ifo", data_pk2))
	print("SEASONAL enabled=%s" % str(SeasonalObjects.enabled_from_environment().keys()))
	var totals := {}
	for r in regions:
		var yx := r.split("/")
		var y := int(yx[0])
		var x := int(yx[1])
		var job: Dictionary = w.call("_objects_job", "%d\\%d.o" % [y, x], Vector3.ZERO, "_probe_%d_%d" % [y, x])
		if r == regions[0]:
			var hidden: Dictionary = job["seasonal_hidden"]
			var per := {}
			for id in hidden:
				per[hidden[id]] = int(per.get(hidden[id], 0)) + 1
			print("SEASONAL hidden type ids: %d %s" % [hidden.size(), str(per)])
		if _args("--full").is_empty():
			job["data_pk2"] = null
		w.call("_objects_prepare", job)
		# With --full the prepare runs to the end (every model read) and the
		# placements it hands the commit are counted by set: what is drawn.
		if job.has("placements"):
			var table: ObjidxReader.Table = job["object_index"]
			var drawn := {}
			for p in job["placements"]:
				var e := table.lookup(p["type_id"])
				var s := SeasonalObjects.classify(e.path) if e != null else ""
				if s != "":
					drawn[s] = int(drawn.get(s, 0)) + 1
			print("DRAWN %s: %d placements, seasonal %s" % [r, (job["placements"] as Array).size(), str(drawn)])
		var hid: Dictionary = job.get("seasonal_hid", {})
		var total := 0
		for s in hid:
			total += int(hid[s])
			totals[s] = int(totals.get(s, 0)) + int(hid[s])
		for line in job["log"]:
			if str(line[1]).contains("seasonal"):
				print(line[1])
		print("SEASONAL %s hid=%d christmas=%d halloween=%d obt=%d summer=%d (.o2 records %d, lists 1 and 2 since round 643)" % [
			r, total, int(hid.get("christmas", 0)), int(hid.get("halloween", 0)), int(hid.get("obt", 0)),
			int(hid.get("summer", 0)), int(job.get("objects_o2", -1))])
		# The region's navmesh: nv_<yyxx>.nvm, hex.
		var nvm_bytes := AssetSource.read_bytes("navmesh\\nv_%02x%02x.nvm" % [y, x], data_pk2)
		var nvm := NvmReader.parse(nvm_bytes) if not nvm_bytes.is_empty() else null
		if nvm == null:
			print("NVM %s: no navmesh read" % r)
		else:
			var seasonal_records := 0
			for obj in nvm.objects:
				var e: ObjidxReader.Entry = data_index.lookup(obj.resource_id) if data_index != null else null
				var by_map: Dictionary = job["seasonal_hidden"]
				if by_map.has(obj.resource_id) or (e != null and SeasonalObjects.classify(e.path) != ""):
					seasonal_records += 1
			print("NVM %s: %d object records, %d seasonal" % [r, nvm.objects.size(), seasonal_records])
	print("SEASONAL total %s" % str(totals))
	w.free()
	quit(0)
