extends SceneTree

## Round 729: the world camera's near plane is retail's 1.0 (READ, round 648:
## `fld1` in `FUN_00bae0a0`), and the near plane's corners stay inside the
## camera arm's collision sphere at any common aspect -- so nothing with a
## collider can come close enough to be clipped by it. Run headless:
## `godot4 --headless --path client --script res://scripts/world/camera_near_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var near := CameraPlanes.near()
	_check(is_equal_approx(near, 1.0), "the world camera's near plane is retail's 1.0 (got %s)" % near)

	# Read from the scene's text: loading World3D.tscn would compile
	# World3D.gd, which needs the game's autoloads.
	var text := FileAccess.get_file_as_string("res://scenes/World3D.tscn")
	var radius := -1.0
	var fov := -1.0
	var re_radius := RegEx.create_from_string("id=\"SphereShape3D_cameraarm\"\\]\\s*radius = ([0-9.]+)")
	var m := re_radius.search(text)
	if m != null:
		radius = float(m.get_string(1))
	var re_fov := RegEx.create_from_string("name=\"Camera3D\" type=\"Camera3D\"[^\\[]*fov = ([0-9.]+)")
	m = re_fov.search(text)
	if m != null:
		fov = float(m.get_string(1))
	_check(radius > 0.0 and fov > 0.0, "the scene's camera arm sphere and fov are found (radius %s, fov %s)" % [radius, fov])
	# Camera3D's fov is vertical (keep_aspect HEIGHT, the default). The near
	# plane's corner lies sqrt(1 + h^2 + (h*aspect)^2) * near from the eye,
	# with h = tan(fov / 2).
	for aspect in [4.0 / 3.0, 16.0 / 9.0, 3840.0 / 2004.0, 21.0 / 9.0]:
		var h := tan(deg_to_rad(fov) / 2.0)
		var corner := near * sqrt(1.0 + h * h + (h * aspect) * (h * aspect))
		_check(corner < radius, "at aspect %.2f the near plane's corner (%.2f) lies inside the arm's sphere (%.1f)" % [aspect, corner, radius])

	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
