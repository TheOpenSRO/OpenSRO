extends SceneTree

## How far a model's clips carry it (round 688, a dev tool): for a `.bsr`
## character model in the player's Data.pk2, each clip's bones in model
## space at every key -- where the skeleton's bones are at the first and
## last key, and the largest distance any bone's model-space position moves
## over the clip. A clip whose bones end where they started plays in place;
## one whose root walks away carries root motion.
##
##   remote_godot.sh script res://tools/probe_ban_motion.gd -- \
##       --bsr=res\\interface\\interface_lizard.bsr
##
## Needs OPENSRO_PK2_PATH (Data.pk2). Prints, reads nothing else.

func _init() -> void:
	var bsr_path := "res\\interface\\interface_lizard.bsr"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bsr="):
			bsr_path = a.substr(6)
	var data := Pk2Reader.open(Pk2Config.data_path())
	if data == null:
		print("PROBE: no Data.pk2")
		quit(1)
		return
	var a := SkinnedBsrAssembler.assemble_from_archive(data, bsr_path, false)
	if a == null:
		print("PROBE: %s did not assemble" % bsr_path)
		quit(1)
		return
	var sk := a.skeleton
	print("PROBE: %s -- %d bones, %d clip(s)" % [bsr_path, sk.get_bone_count(), a.animation_paths.size()])
	for i in range(sk.get_bone_count()):
		print("PROBE: bone %d %s parent %d rest %s" % [i, sk.get_bone_name(i), sk.get_bone_parent(i), sk.get_bone_global_rest(i).origin])
	for p in a.animation_paths:
		var entry := ObjectLoader.find_file(data, p)
		var anim := BanReader.parse(data.read_file(entry)) if entry != null else null
		if anim == null:
			print("PROBE: %s did not parse" % p)
			continue
		print("PROBE: clip %s -- %d keys, %d ms, cyclic %s, %d tracks" % [anim.animation_name, anim.key_times.size(), anim.duration_ms, anim.cyclic, anim.bones.size()])
		var first := {}
		var lo := {}
		var hi := {}
		for k in range(anim.key_times.size()):
			Skeleton3DBuilder.apply_ban_pose(sk, anim, k)
			for b in range(sk.get_bone_count()):
				var o := sk.get_bone_global_pose(b).origin
				if k == 0:
					first[b] = o
					lo[b] = o
					hi[b] = o
				else:
					var l: Vector3 = lo[b]
					lo[b] = Vector3(minf(l.x, o.x), minf(l.y, o.y), minf(l.z, o.z))
					var h: Vector3 = hi[b]
					hi[b] = Vector3(maxf(h.x, o.x), maxf(h.y, o.y), maxf(h.z, o.z))
		for b in range(sk.get_bone_count()):
			var last := sk.get_bone_global_pose(b).origin
			var span: Vector3 = (hi[b] as Vector3) - (lo[b] as Vector3)
			if span.length() > 1.0 or b <= 2:
				print("PROBE:   bone %d %-14s first %s last %s first->last %.2f span %s" % [b, sk.get_bone_name(b), first[b], last, (last - (first[b] as Vector3)).length(), span])
		for t in anim.bones:
			var track: BanReader.Bone = t
			if track.keyframes.size() > 1 and sk.find_bone(track.bone_name) <= 2:
				var p0 := track.keyframes[0].position
				var p1 := track.keyframes[track.keyframes.size() - 1].position
				print("PROBE:   track %s local position key0 %s last %s" % [track.bone_name, p0, p1])
	sk.free()
	quit(0)
