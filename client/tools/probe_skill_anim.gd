extends SceneTree

## Dev probe: does the skill-cast animation chain have anything to play?
##
## Two questions the 2026-09-20 playtest raised and guessing could not settle:
##   1. how many skills have a cast clip of their own, per gender
##   2. whether the WEAPON-SWING fallback has a clip for each animation group,
##      since a skill with no clip falls back to it
##
## Usage:
##   godot4 --headless --path client --script res://tools/probe_skill_anim.gd -- \
##     --pk2=/path/to/Data.pk2

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
	if pk2_path == "":
		printerr("need --pk2=/path/to/Data.pk2")
		quit(2)
		return
	var pk2 := Pk2Reader.open(pk2_path)
	if pk2 == null:
		printerr("could not open %s" % pk2_path)
		quit(2)
		return
	for gender_dir in ["man", "woman"]:
		var dir_path: String = "Prim\\Ani\\Char\\China\\" + gender_dir
		var entry = ObjectLoader.find_file(pk2, dir_path)
		if entry == null:
			print("%s: MISSING %s" % [gender_dir, dir_path])
			continue
		var total: int = 0
		var skill_clips: int = 0
		var attack_clips: int = 0
		for child in pk2.read_dir_at(entry):
			if child.is_dir:
				continue
			var n: String = String(child.name).to_lower()
			if not n.ends_with(".ban"):
				continue
			total += 1
			if n.begins_with("skill_"):
				skill_clips += 1
			if n.find("attack") >= 0 or n.find("_base") >= 0:
				attack_clips += 1
		print("%s: %d .ban clips, %d skill_*, %d attack/base" % [gender_dir, total, skill_clips, attack_clips])
	quit(0)
