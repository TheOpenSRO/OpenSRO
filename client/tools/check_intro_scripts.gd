extends SceneTree

## Round 678: every intro script in the player's own Media.pk2, parsed by
## IntroScript and flown by IntroCameraPath, measured -- the runtime half of
## intro_script_test.gd (no game data in the repo, so the real files are only
## read here, from an archive on the machine that has one).
##
## Per script: keyframes, length, region, AREA=, [SCRIPT] lines, the regions
## retail preloads (FUN_0056c870) and the regions the camera's target actually
## crosses (sampled every 0.1 s), and the PATH ACCURACY -- the path sampled at
## each keyframe's time against that keyframe (position in units, angles in
## radians modulo 2 pi) -- plus the clamp at the end. A count that differs
## from round 678's census, or a keyframe the path misses by more than
## 1e-3, prints PARITY FAIL (remote_godot.sh then exits 1).
##
##   remote_godot.sh script res://tools/check_intro_scripts.gd -- --media=/opt/sro-files/client/Media.pk2

## Round 678's census of the archive measured (keyframes, length in s) --
## MEASURED by this tool's first run and the research before it.
const CENSUS := {
	"roc": [21, 40.0], "egypt": [21, 40.0], "china_whatf": [21, 40.0],
	"constantinople": [14, 53.0], "china_wharf": [8, 35.0], "rm": [7, 43.0],
	"rmzh": [7, 43.0], "jupiter_login": [7, 27.0], "ruby_baghdad": [6, 33.5],
}
const EXTRA := ["ruby_baghdad - kopie"]

var _fail := 0

func _initialize() -> void:
	var media_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--media="):
			media_path = a.substr(8)
	var media := Pk2Reader.open(media_path)
	if media == null:
		print("PARITY FAIL cannot open Media.pk2 at '%s'" % media_path)
		quit(1)
		return
	print("option.txt IntroName: '%s'" % TitleIntro.option_intro_name(media))
	var names: Array = CENSUS.keys() + EXTRA
	for name in names:
		_check_one(media, str(name))
	print("PARITY OK" if _fail == 0 else "PARITY FAIL %d" % _fail)
	quit()

func _check_one(media: Pk2Reader, name: String) -> void:
	var path := "script\\intro\\%s.txt" % name
	var entry := ObjectLoader.find_file(media, path)
	if entry == null:
		print("%s: not in this archive" % path)
		if CENSUS.has(name):
			print("PARITY FAIL %s missing" % path)
			_fail += 1
		return
	var bytes := media.read_file(entry)
	var p := IntroScript.parse(bytes)
	var origin := IntroScript.origin_region(p)
	var cam := IntroCameraPath.from_keyframes(p.keyframes)
	print("%s: %d bytes, %d keyframe(s), %.2f s, region %d/%d (single: %s), AREA='%s', %d [SCRIPT] line(s), %d other [CAMERA] line(s) %s" % [
		path, bytes.size(), p.keyframes.size(), cam.length, origin.x, origin.y, str(IntroScript.single_region(p)),
		p.area, p.script_lines.size(), p.skipped_camera_lines.size(), str(p.skipped_camera_lines)])
	if CENSUS.has(name):
		var want: Array = CENSUS[name]
		if p.keyframes.size() != int(want[0]) or not is_equal_approx(cam.length, float(want[1])):
			print("PARITY FAIL %s: %d keyframes / %.2f s, census says %d / %.2f" % [name, p.keyframes.size(), cam.length, want[0], want[1]])
			_fail += 1
	# Path accuracy at the keyframes.
	var worst_pos := 0.0
	var worst_ang := 0.0
	var worst_dist := 0.0
	var seen_times := {}
	for k in p.keyframes:
		if seen_times.has(k.time):
			continue # two keys at one time: the later one is inserted after
		seen_times[k.time] = true
		var pose := cam.sample(k.time)
		worst_pos = maxf(worst_pos, pose.target.distance_to(k.pos))
		for pair in [[pose.pitch, k.pitch], [pose.yaw, k.yaw], [pose.roll, k.roll]]:
			worst_ang = maxf(worst_ang, absf(wrapf(float(pair[0]) - float(pair[1]), -PI, PI)))
		worst_dist = maxf(worst_dist, absf(pose.distance - k.distance))
	print("  path at the keyframes: worst position error %.6f units, angle %.6f rad, distance %.6f" % [worst_pos, worst_ang, worst_dist])
	if worst_pos > 1e-3 or worst_ang > 1e-3 or worst_dist > 1e-3:
		print("PARITY FAIL %s: the path misses a keyframe" % name)
		_fail += 1
	# The clamp.
	cam.time = 0.0
	var end_pose := cam.advance(cam.length + 10.0)
	var last: IntroScript.Keyframe = p.keyframes[p.keyframes.size() - 1]
	var clamped := cam.finished() and is_equal_approx(cam.time, cam.length) and end_pose.target.distance_to(last.pos) < 1e-3
	print("  clamp: time %.2f of %.2f, finished %s, on the last keyframe %s" % [cam.time, cam.length, str(cam.finished()), str(clamped)])
	if not clamped:
		print("PARITY FAIL %s: does not clamp on its last keyframe" % name)
		_fail += 1
	# The regions: retail's preload set and what the target crosses.
	var crossed := {}
	var t := 0.0
	var min_y := INF
	var max_y := -INF
	while t <= cam.length + 1e-6:
		var pose := cam.sample(t)
		var r := Vector2i(origin.x + int(floorf(pose.target.z / IntroScript.REGION_SPAN)), origin.y + int(floorf(pose.target.x / IntroScript.REGION_SPAN)))
		crossed["%d/%d" % [r.x, r.y]] = true
		var eye: Vector3 = IntroCameraPath.sro_eye_target_up(pose)[0]
		min_y = minf(min_y, eye.y)
		max_y = maxf(max_y, eye.y)
		t += 0.1
	var pre := PackedStringArray()
	for r in IntroScript.preload_regions(p):
		pre.append("%d/%d" % [r.x, r.y])
	print("  retail preloads %s; the target crosses %s; the eye's height %.1f .. %.1f" % [
		", ".join(pre), ", ".join(PackedStringArray(crossed.keys())), min_y, max_y])
