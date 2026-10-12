extends SceneTree

## Round 786 (the second drift report): every node's LinkMode controller
## against the follow block of its body, over every .efp the skilleffectset
## rows name and the equipment glow files. READ (sro_client.exe):
## CEFCLinkMode::vslot_003 (0x00cbb0f0) reads the controller's four u32 at
## +0x14, +0x18, +0x1c, +0x20; CEFCLinkMode::vslot_005 (0x00cb9370) writes
## them into the node as u6 (+0x168), u2 (+0x158), u3 (+0x15c) and u4
## (+0x160) -- each clamped to the levels the node actually has above it, u3
## -1 kept -- and sets b1 (+0x155) on the node u6 names and b0 (+0x154) on
## the nodes u2, u3, u4 name; the body's block is FUN_00cc3500 (0x00cc3500).
## Prints a count of nodes whose block disagrees with the controller and
## examples. Headless:
##   remote_godot.sh script res://tools/efp_linkmode_census.gd -- --pk2dir=/opt/sro-files/client [--show=N] [--only=substr]

var _show := 20
var _only := ""

func _initialize() -> void:
	var dir := "/opt/sro-files/client"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2dir="):
			dir = a.substr(9)
		elif a.begins_with("--show="):
			_show = int(a.substr(7))
		elif a.begins_with("--only="):
			_only = a.substr(7).to_lower()
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	var files := {}
	var rows := SkillEffects.parse_rows(media.read_file(ObjectLoader.find_file(media, SkillEffects.SKILLEFFECT_PATH)))
	for id in rows:
		for r in rows[id]:
			files[String(r["path"]).to_lower()] = "skill"
	var gt := ItemGlowTables.for_archive(media)
	for call in gt._particle_calls:
		for pair in call:
			files[(pair[1] as ItemGlowTables.ParticleRow).efp.to_lower()] = "equip"
	var names := files.keys()
	names.sort()
	var t := {"files": 0, "nodes": 0, "with_link": 0, "without_link": 0, "u6_differs": 0, "levels_differ": 0,
		"flags_differ": 0, "files_differ": 0}
	var shown := 0
	for f in names:
		if _only != "" and String(f).find(_only) < 0:
			continue
		var data := AssetSource.read_bytes(f, particles)
		if data.is_empty():
			continue
		var ef := EfpReader.decode(data)
		if ef == null or ef.root == null:
			continue
		t["files"] += 1
		var nodes: Array = []
		_flatten(ef.root, null, nodes)
		var applied := _apply(nodes)
		var differs := false
		for i in range(nodes.size()):
			var n: EfpReader.EfpNode = nodes[i][0]
			t["nodes"] += 1
			var want: Dictionary = applied[i]
			if not want.get("has_link", false):
				t["without_link"] += 1
			else:
				t["with_link"] += 1
			var got := n.flags
			var lv_diff := false
			for k in ["u2", "u3", "u4", "u6"]:
				if EfpSim.signed32(int(got.get(k, 0))) != int(want[k]):
					lv_diff = true
			var fl_diff := int(got.get("b0", 0)) != int(want["b0"]) or int(got.get("b1", 0)) != int(want["b1"])
			if EfpSim.signed32(int(got.get("u6", 0))) != int(want["u6"]):
				t["u6_differs"] += 1
			if lv_diff:
				t["levels_differ"] += 1
			if fl_diff:
				t["flags_differ"] += 1
			if (lv_diff or fl_diff) and shown < _show:
				shown += 1
				print("LINK %s #%d %s depth %d: block b0 %d b1 %d u2 %d u3 %d u4 %d u6 %d -- LinkMode %s gives b0 %d b1 %d u2 %d u3 %d u4 %d u6 %d" % [
					f, i, n.name, nodes[i][2], int(got.get("b0", 0)), int(got.get("b1", 0)),
					EfpSim.signed32(int(got.get("u2", 0))), EfpSim.signed32(int(got.get("u3", 0))),
					EfpSim.signed32(int(got.get("u4", 0))), EfpSim.signed32(int(got.get("u6", 0))),
					str(want.get("raw", "none")), want["b0"], want["b1"], want["u2"], want["u3"], want["u4"], want["u6"]])
			differs = differs or lv_diff or fl_diff
		if differs:
			t["files_differ"] += 1
	print("LINK CENSUS %s" % str(t))
	quit(0)

## Preorder: [node, parent index, depth].
func _flatten(n: EfpReader.EfpNode, parent, out: Array, parent_i: int = -1, depth: int = 0) -> void:
	out.append([n, parent_i, depth])
	var me := out.size() - 1
	for c in n.children:
		_flatten(c, n, out, me, depth + 1)

## What CEFCLinkMode::vslot_005 leaves in each node, starting from the body's
## block (FUN_00cc3500) and applying each node's LinkMode (in preorder).
func _apply(nodes: Array) -> Array:
	var out: Array = []
	for e in nodes:
		var n: EfpReader.EfpNode = e[0]
		var d := {"b0": int(n.flags.get("b0", 0)), "b1": int(n.flags.get("b1", 0)),
			"u2": EfpSim.signed32(int(n.flags.get("u2", 0))), "u3": EfpSim.signed32(int(n.flags.get("u3", 0))),
			"u4": EfpSim.signed32(int(n.flags.get("u4", 0))), "u6": EfpSim.signed32(int(n.flags.get("u6", 0)))}
		out.append(d)
	for i in range(nodes.size()):
		var n: EfpReader.EfpNode = nodes[i][0]
		for c in n.controllers:
			if c.key != "LinkMode":
				continue
			var l: PackedInt64Array = c.data["link"]
			var raw := [EfpSim.signed32(int(l[0])), EfpSim.signed32(int(l[1])), EfpSim.signed32(int(l[2])), EfpSim.signed32(int(l[3]))]
			out[i]["has_link"] = true
			out[i]["raw"] = raw
			var u6 := _walk(nodes, i, raw[0], out, "b1")
			var u2 := _walk(nodes, i, raw[1], out, "b0")
			var u3: int = -1 if raw[2] == -1 else _walk(nodes, i, raw[2], out, "b0")
			var u4 := _walk(nodes, i, raw[3], out, "b0")
			out[i]["u6"] = u6
			out[i]["u2"] = u2
			out[i]["u3"] = u3
			out[i]["u4"] = u4
	return out

## The walk of 0x00cb9370 for one level: 0 names nothing; otherwise count
## steps up the node chain (node +0x20, the parent node) until `level` or
## the root's parent (none); the node reached gets `flag`. Returns the count.
func _walk(nodes: Array, i: int, level: int, out: Array, flag: String) -> int:
	if level == 0:
		return 0
	if level < 0:
		# `if (0 < level)` skips the walk: the count stays 0, the flag goes
		# on the node itself.
		out[i][flag] = 1
		return 0
	var cur := i
	var count := 0
	while true:
		count += 1
		var par: int = nodes[cur][1]
		if par < 0:
			break
		cur = par
		if count >= level:
			break
	out[cur][flag] = 1
	return count
