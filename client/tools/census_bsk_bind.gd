extends SceneTree

## Dev tool (round 648): for every `.bsk` under a Data.pk2 folder, how far
## the rest this client composes (Skeleton3DBuilder: the bones' parent-
## relative LOCAL transforms chained from the root) lands from the WORLD
## bind the file stores beside it (the record's second transform,
## BSK_FORMAT.md "Confirmed from the client's own loader"). The skin's bind
## is the inverse of the composed rest, so a skeleton whose two disagree
## is skinned from the wrong place -- the Dunhuang reeds' `[root]` stores
## a local translation of 3.7e24 and was drawn as streaks to infinity.
##
## Prints one line per skeleton that disagrees (worst bone, its position
## and rotation error, and the root's stored local translation), then a
## tally. Measured, headless.
##
## Usage:
##   godot4 --headless --path client --script res://tools/census_bsk_bind.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 [--dir=prim/skel] [--tol=0.05]

var _archive: Pk2Reader
var _tol := 0.05
var _files := 0
var _bad := 0
var _bad_root := 0
var _unparsed := 0
var _implied_total := 0
var _implied_identity := 0
var _implied_matches_root := 0
var _implied_differs := 0
var _max_sane_root := 0.0
var _max_sane_path := ""

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _initialize() -> void:
	_archive = Pk2Reader.open(_arg("--pk2"))
	var dir := _arg("--dir")
	if dir == "":
		dir = "prim/skel"
	if _arg("--tol") != "":
		_tol = float(_arg("--tol"))
	var entry := ObjectLoader.find_file(_archive, dir.replace("/", "\\"))
	if _archive == null or entry == null:
		print("usage: --pk2=Data.pk2 [--dir=prim/skel]")
		quit(1)
		return
	_walk(entry, dir.replace("/", "\\"))
	print("CENSUS %d skeleton(s): %d with a bone off its stored world bind by more than %.2f (%d of them with a root local translation over 1e6), %d unparsed" % [
		_files, _bad, _tol, _bad_root, _unparsed])
	print("CENSUS %d skeleton(s) with bones on the root: %d whose children agree on an identity root; sane roots: %d where the children imply the stored root local, %d where they do not" % [_implied_total, _implied_identity, _implied_matches_root, _implied_differs])
	print("CENSUS the largest root local translation under 1e6: %.3f (%s)" % [_max_sane_root, _max_sane_path])
	quit(0)

func _walk(dir: Pk2Reader.Entry, path: String) -> void:
	for child in _archive.read_dir_at(dir):
		if child.name == "." or child.name == "..":
			continue
		var p := "%s\\%s" % [path, child.name]
		if child.is_dir:
			_walk(child, p)
		elif child.name.to_lower().ends_with(".bsk"):
			_check(p, _archive.read_file(child))

## The record's second (quaternion, vector): the world bind. A 92-byte
## record (empty parent name) carries 4 more leading bytes.
static func world_bind(b: BskReader.Bone) -> Transform3D:
	var o := 4 if b.transform.size() > BskReader.BONE_TRANSFORM_LEN else 0
	var t := b.transform
	var q := Quaternion(t.decode_float(o + 0x1c), t.decode_float(o + 0x20), t.decode_float(o + 0x24), t.decode_float(o + 0x28))
	return Transform3D(Basis(q.normalized()), Vector3(t.decode_float(o + 0x2c), t.decode_float(o + 0x30), t.decode_float(o + 0x34)))

func _check(path: String, data: PackedByteArray) -> void:
	var skel := BskReader.parse(data)
	if skel == null or skel.bones.is_empty():
		_unparsed += 1
		return
	_files += 1
	var s := Skeleton3DBuilder.build_skeleton3d(skel)
	var worst := 0.0
	var worst_rot := 0.0
	var worst_name := ""
	for b in skel.bones:
		var i := s.find_bone(b.bone_name)
		if i == -1:
			continue
		var composed := s.get_bone_global_rest(i)
		var stored := world_bind(b)
		var d := composed.origin.distance_to(stored.origin)
		var r := rad_to_deg(composed.basis.get_rotation_quaternion().angle_to(stored.basis.get_rotation_quaternion()))
		if not is_finite(d):
			d = INF
		if d > worst or (d == worst and r > worst_rot):
			worst = d
			worst_rot = r
			worst_name = b.bone_name
	var root_t := Vector3.ZERO
	if not skel.root_transform.is_empty():
		var rb := BskReader.Bone.new()
		rb.transform = skel.root_transform
		root_t = SkeletonPose.bone_local_position(rb)
	# The root the children's STORED world binds imply: W_stored(c) *
	# inverse(L_c) for each bone hung straight off the root.
	var implied := ""
	var implied_agree := true
	var first := Transform3D()
	var have := false
	for b in skel.bones:
		var i := s.find_bone(b.bone_name)
		if i == -1 or s.get_bone_parent(i) != 0:
			continue
		var r := world_bind(b) * s.get_bone_rest(i).affine_inverse()
		if not have:
			first = r
			have = true
		elif r.origin.distance_to(first.origin) > _tol:
			implied_agree = false
	if have:
		implied = " | children imply root at %s (%s)" % [str(first.origin), "all agree" if implied_agree else "children DISAGREE"]
		_implied_total += 1
		if implied_agree and first.origin.length() < _tol:
			_implied_identity += 1
		if root_t.length() < 1.0e6:
			if root_t.length() > _max_sane_root:
				_max_sane_root = root_t.length()
				_max_sane_path = path
			if implied_agree and first.origin.distance_to(root_t) <= _tol:
				_implied_matches_root += 1
			else:
				_implied_differs += 1
				print("ROOT %s: stored root local %s, children imply %s (%s)" % [path, str(root_t), str(first.origin), "agree" if implied_agree else "DISAGREE"])
	s.free()
	if worst > _tol or worst_rot > 1.0:
		_bad += 1
		var insane := not (root_t.length() < 1.0e6)
		if insane:
			_bad_root += 1
		print("BIND %s: worst bone %s off by %s units, %.2f deg; root local translation %s%s%s" % [
			path, worst_name, str(worst), worst_rot, str(root_t), " (garbage)" if insane else "", implied])
