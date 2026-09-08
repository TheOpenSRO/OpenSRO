extends SceneTree

## Dev tool: reports how well a real `.ban` animation's bone tracks line up
## with a real `.bsk` skeleton's bones.
##
## Applying an animation only poses the bones it has tracks for; any bone it
## misses keeps its rest transform. In a hierarchy that mixes the two, the
## composed global transforms diverge and a rigidly-attached character comes
## apart -- which is what enabling animation playback still does. This says
## whether that is the reason.
##
## Usage:
##   godot4 --headless --path client --script res://tools/check_ban_bones.gd -- \
##     --pk2=/path/Data.pk2 \
##     --bsk="Prim\\Ani\\Char\\China\\man\\chinaman.bsk" \
##     --ban="Prim\\Ani\\Char\\China\\man\\chinaman_fighter_standcity.ban"

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _initialize() -> void:
	var pk2_path := _arg("--pk2")
	var bsk_path := _arg("--bsk")
	var ban_path := _arg("--ban")
	if pk2_path == "" or bsk_path == "" or ban_path == "":
		printerr("usage: --pk2=<Data.pk2> --bsk=<path> --ban=<path>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return

	var skel := BskReader.parse(AssetSource.read_bytes(bsk_path, archive))
	if skel == null:
		printerr("could not read the skeleton at ", bsk_path)
		quit(1)
		return
	var anim := BanReader.parse(AssetSource.read_bytes(ban_path, archive))
	if anim == null:
		printerr("could not read the animation at ", ban_path)
		quit(1)
		return

	# Against the *built* skeleton, not the parsed bone list: the builder
	# adds a bone for the file's root name on top of the bones the reader
	# returns, so comparing against the reader's list alone understates the
	# match and invents a missing root.
	var skeleton := Skeleton3DBuilder.build_skeleton3d(skel)
	var bone_names := {}
	for i in range(skeleton.get_bone_count()):
		bone_names[skeleton.get_bone_name(i)] = true
	var matched := 0
	var unmatched: Array = []
	for track in anim.bones:
		if bone_names.has(track.bone_name):
			matched += 1
		else:
			unmatched.append(track.bone_name)

	var track_names := {}
	for track in anim.bones:
		track_names[track.bone_name] = true
	var untracked: Array = []
	for i in range(skeleton.get_bone_count()):
		if not track_names.has(skeleton.get_bone_name(i)):
			untracked.append(skeleton.get_bone_name(i))

	print("skeleton %s: %d parsed bone(s), %d in the built Skeleton3D (root %s)" % [
		bsk_path.get_file(), skel.bones.size(), skeleton.get_bone_count(), skel.root_name])
	print("animation %s: %d track(s), %d keyframe(s) on track 0" % [
		ban_path.get_file(), anim.bones.size(),
		anim.bones[0].keyframes.size() if not anim.bones.is_empty() else 0])
	print("tracks matching a real bone: %d of %d" % [matched, anim.bones.size()])
	if not unmatched.is_empty():
		print("  tracks with no such bone (%d): %s" % [unmatched.size(), unmatched.slice(0, 8)])
	print("bones with no track: %d of %d" % [untracked.size(), skeleton.get_bone_count()])
	if not untracked.is_empty():
		print("  %s" % [untracked.slice(0, 12)])
	print("\nskeleton bones, in file order (name <- parent):")
	for i in range(mini(skel.bones.size(), 10)):
		var b = skel.bones[i]
		print("  %2d  %-22s <- %s" % [i, b.bone_name, b.parent_name if b.parent_name != "" else "(root)"])
	print("\nanimation tracks, in file order:")
	for i in range(mini(anim.bones.size(), 10)):
		print("  %2d  %s" % [i, anim.bones[i].bone_name])
	quit(0)
