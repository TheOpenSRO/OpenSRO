extends SceneTree

## Round 847 lane B: how long an abnormal state's PARAM_ aura (and a buff's
## ACT_L aura) keeps drawing after it is let go the way round 785 let it go
## (EfpEffect.release: the keep flag cleared, the particles play out), against
## the original's end -- IDecoSkill::FUN_00a4db00 -> FUN_00a48690 ->
## FUN_00a48190 starts an alpha fade over the row's Fade first value, and
## CIDecoSkill::vslot_014 frees the effect (slot 2) when the alpha reaches 0.
## Every file is stepped kept for --hold seconds at --fps, then released, and
## stepped until the sim has finished (cap --cap seconds). Reads the user's
## archives at run time; prints statistics only.
##   godot --headless --path <client> --script res://tools/state_aura_release_probe.gd -- \
##     --pk2dir=/opt/sro-files/client [--files=battle\status_bad_poison.efp,...] [--hold=6] [--fps=30]

func _arg(flag: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def

const STATE_FILES := ["status_bad_stun.efp", "status_bad_blind.efp", "status_bad_hide.efp", "status_bad_sleep.efp",
	"status_bad_temptation.efp", "status_bad_confusion.efp", "status_bad_myopia.efp", "status_bad_panic.efp",
	"status_bad_burn.efp", "status_bad_eshock.efp", "status_bad_frostbite.efp", "status_bad_poison.efp",
	"status_bad_zombie.efp", "status_bad_bleeding.efp", "status_bad_disease.efp", "status_bad_icing_on.efp",
	"status_bad_root.efp", "status_bad_stone_on.efp", "status_bad_blunt.efp"]

func _initialize() -> void:
	var dir := _arg("--pk2dir", "/opt/sro-files/client")
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	var files: Array = []
	for f in _arg("--files", "").split(",", false):
		files.append(f)
	if files.is_empty():
		for f in STATE_FILES:
			files.append("battle\\" + f)
	var hold := float(_arg("--hold", "6"))
	var fps := float(_arg("--fps", "30"))
	var cap := float(_arg("--cap", "60"))
	var delta := 1.0 / fps
	for f in files:
		var t := EfpEffect.template_for(String(f), particles)
		if t == null:
			print("AURAPROBE %s: no template" % f)
			continue
		var sim := EfpSim.new(t, 1234)
		sim.keep = true
		var held := 0.0
		while held < hold:
			sim.advance(delta)
			held += delta
		var at_release := sim.count()
		sim.keep = false
		var after := 0.0
		var peak := at_release
		var drawn_half := -1.0
		while not sim.finished() and after < cap:
			sim.advance(delta)
			after += delta
			peak = maxi(peak, sim.count())
			if drawn_half < 0.0 and sim.count() * 2 <= at_release:
				drawn_half = after
		print("AURAPROBE %s: %d particle(s) at release, finished %s after %.2f s (half gone at %.2f s)" % [f,
			at_release, "yes" if sim.finished() else "NO", after, drawn_half])
		sim.clear()
	quit(0)
