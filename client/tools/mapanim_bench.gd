extends SceneTree

## Dev tool (round 645): what map-object animation costs a frame, measured
## apart from the renderer and from other work on a shared box.
##
## Loads each --models path from Data.pk2 through ObjectLoader (the world's
## own template path), places --count copies of each in a grid, registers
## them with a MapAnimation.Driver, and times idle frames three ways:
## every clip running, every clip paused (the driver's out-of-range state)
## and no copies at all. The difference is the per-frame cost of the clips.
##
## Usage (on the render box, via remote_godot.sh script):
##   res://tools/mapanim_bench.gd -- --pk2=Data.pk2 --count=60 \
##     --models='res\nature\common\tree\tre_maple03.bsr,...' [--frames=300]

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	if data == null:
		printerr("usage: --pk2=<Data.pk2> --models=a.bsr,b.bsr [--count=N] [--frames=N]")
		quit(2)
		return
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	OS.low_processor_usage_mode_sleep_usec = 0
	var count := int(_arg("--count", "50"))
	var frames := int(_arg("--frames", "300"))
	var holder := Node3D.new()
	root.add_child(holder)
	await process_frame
	var none := await _time(frames)
	var driver := MapAnimation.Driver.new()
	var placed := 0
	var tracks := 0
	for path in _arg("--models").split(","):
		var template := ObjectLoader.load_object(data, path)
		if template == null or MapAnimation.players_of(template).is_empty():
			print("BENCH %s does not animate -- skipped" % path)
			continue
		for p in MapAnimation.players_of(template):
			tracks += (p as AnimationPlayer).get_animation(MapAnimation.CLIP_NAME).get_track_count()
		for i in range(count):
			var copy := template.duplicate() as Node3D
			if _arg("--noskin") != "":
				for mi in copy.find_children("*", "MeshInstance3D", true, false):
					(mi as MeshInstance3D).skin = null
					(mi as MeshInstance3D).skeleton = NodePath()
			if _arg("--nomesh") != "":
				for mi in copy.find_children("*", "MeshInstance3D", true, false):
					mi.free()
			if _arg("--det") != "":
				for p in MapAnimation.players_of(copy):
					(p as AnimationPlayer).deterministic = true
			copy.position = Vector3((placed % 40) * 30.0, 0, (placed / 40) * 30.0)
			holder.add_child(copy)
			driver.add(copy, false)
			placed += 1
		template.free()
	print("BENCH %d copies, %d tracks per template set" % [placed, tracks])
	driver.tick(Vector3.ZERO, [], true)
	await process_frame
	var on := await _time(frames)
	driver.tick(Vector3(1e6, 0, 0), [], true)
	await process_frame
	var paused := await _time(frames)
	print("BENCH frame us: none %.1f, %d clips running %.1f (+%.1f, %.2f us a clip), all paused %.1f (+%.1f)" % [
		none, placed, on, on - none, (on - none) / maxf(placed, 1), paused, paused - none])
	quit(0)

## Mean wall-clock microseconds per frame over `frames` idle frames, with
## the frame cap and low-processor sleep off (_initialize), so a frame
## costs what its work costs.
func _time(frames: int) -> float:
	var t0 := Time.get_ticks_usec()
	for _i in range(frames):
		await process_frame
	return float(Time.get_ticks_usec() - t0) / frames
