extends SceneTree

## Dev probe (round 785): for every player skill's skillaniset2 record, does
## the body find the clip each phase of its decoration asks for? The record's
## READY / WAIT / SHOT entries are action types in its AniGroup; the body's
## .bsr resolves them through BsrReader.animation_entry_for (the group, else
## `default`), as World3D._deco_clip_info does. Prints one line per miss and a
## summary per body. Reads the player's own archives; prints, stores nothing.
##
## Usage:
##   godot4 --headless --path client --script res://tools/probe_skill_deco_coverage.gd -- \
##     --data=/path/Data.pk2 --media=/path/Media.pk2 [--show=SKILL_CH_FIRE_GIGONGSUL_E,...]

const BODIES := {
	"CH": ["char\\china\\chinaman_fighter.bsr", "char\\china\\chinawoman_fighter.bsr"],
	"EU": ["char\\europe\\europeman_warrior.bsr", "char\\europe\\europewoman_warrior.bsr"],
}

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var data := Pk2Reader.open(_arg("--data"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("need --data= and --media=")
		quit(2)
		return
	var se := ObjectLoader.find_file(media, "server_dep\\silkroad\\textdata\\skilleffect.txt")
	var sets: Dictionary = SkillEffectReader.parse_aniset(media.read_file(se))
	var show := _arg("--show").split(",", false)
	for race in BODIES:
		for path in BODIES[race]:
			var entry := ObjectLoader.find_file(data, path)
			if entry == null:
				entry = ObjectLoader.find_file(data, "res\\" + path)
			if entry == null:
				print("BODY %s: not in the archive" % path)
				continue
			var body = BsrReader.parse(data.read_file(entry))
			var rows := 0
			var none := 0
			var phases := 0
			var found := 0
			var misses := {}
			for code in sets:
				if not String(code).begins_with("SKILL_%s_" % race):
					continue
				rows += 1
				var row: Dictionary = sets[code]
				var plan := SkillDeco.plan(row, 0)
				if String(plan["kind"]) == "none":
					none += 1
					continue
				var group := String(plan["group"])
				for k in ["ready", "wait", "shot"]:
					var t := int(plan[k])
					if t < 0:
						continue
					phases += 1
					var e = body.animation_entry_for(t, group)
					if e != null:
						found += 1
						if show.has(String(code)):
							print("SHOW %s %s %s: type %d in group '%s' -> %s (%d hit events)" % [path.get_file(), code, k, t,
								group, String(e.path).get_file(), e.events.filter(func(v): return (v as PackedInt32Array)[1] == 1).size()])
					else:
						var key := "%s:%d" % [group, t]
						misses[key] = int(misses.get(key, 0)) + 1
						if show.has(String(code)):
							print("SHOW %s %s %s: type %d in group '%s' -> NONE" % [path.get_file(), code, k, t, group])
			print("BODY %s: %d records, %d draw nothing, %d phase clips asked, %d found, %d missing" % [path.get_file(),
				rows, none, phases, found, phases - found])
			var keys := misses.keys()
			keys.sort()
			for key in keys:
				print("  MISS %s x%d" % [key, int(misses[key])])
	quit(0)
