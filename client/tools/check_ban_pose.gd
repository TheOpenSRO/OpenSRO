extends SceneTree

## Dev tool: builds a real skeleton, applies a real animation frame to it,
## and reports where the bones actually end up.
##
## This bisects a wrong-looking animated character into its two halves. If
## the *skeleton* puts the hands below the shoulders and the animation
## still renders with arms overhead, the fault is in how meshes are
## attached to bones. If the skeleton itself puts the hands above the head,
## the fault is in the pose maths and the attachment is innocent.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_ban_pose.gd -- \
##     --pk2=/path/Data.pk2 --bsk="Prim\\Skel\\..." --ban="Prim\\Ani\\..." [--frame=0]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _report(skeleton: Skeleton3D, label: String, names: Array) -> void:
	print("  %s" % label)
	for n in names:
		var idx := skeleton.find_bone(n)
		if idx == -1:
			print("    %-22s (no such bone)" % n)
			continue
		var p: Vector3 = skeleton.get_bone_global_pose(idx).origin
		print("    %-22s (%8.2f, %8.2f, %8.2f)" % [n, p.x, p.y, p.z])

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var bsk_path := _arg("--bsk")
	var ban_path := _arg("--ban")
	var frame := int(_arg("--frame")) if _arg("--frame") != "" else 0
	if pk2_path == "" or bsk_path == "" or ban_path == "":
		printerr("usage: --pk2=<Data.pk2> --bsk=<path> --ban=<path> [--frame=N]")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	var skel := BskReader.parse(AssetSource.read_bytes(bsk_path, archive))
	var anim := BanReader.parse(AssetSource.read_bytes(ban_path, archive))
	if skel == null or anim == null:
		printerr("could not read the skeleton or the animation")
		quit(1)
		return

	var skeleton := Skeleton3DBuilder.build_skeleton3d(skel)
	get_root().add_child(skeleton)
	var names := [
		"Bip01", "Bip01 Pelvis", "Bip01 Spine", "Bip01 Head",
		"Bip01 L UpperArm", "Bip01 L Forearm", "Bip01 L Hand",
		"Bip01 R Hand", "Bip01 L Foot", "Bip01 R Foot"]

	skeleton.reset_bone_poses()
	Skeleton3DBuilder.refresh_global_poses(skeleton)
	print("bind pose (global positions):")
	_report(skeleton, "", names)

	Skeleton3DBuilder.apply_ban_pose(skeleton, anim, frame)
	print("\nafter applying frame %d:" % frame)
	_report(skeleton, "", names)

	var head := skeleton.find_bone("Bip01 Head")
	var hand := skeleton.find_bone("Bip01 L Hand")
	if head != -1 and hand != -1:
		var hy: float = skeleton.get_bone_global_pose(head).origin.y
		var ay: float = skeleton.get_bone_global_pose(hand).origin.y
		print("\nleft hand is %.2f %s the head" % [absf(ay - hy), "ABOVE" if ay > hy else "below"])
	quit(0)
