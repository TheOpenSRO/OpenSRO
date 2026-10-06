extends SceneTree

## Round 746: which equipment effects take a vector or a rotation along the
## WORLD's axes (EquipFx.world_commands), so cannot be simulated once and
## turned per weapon -- the review of round 741's finding 1. Every particle
## file the two tables name (resinfo\itemrare.txt, resinfo\itemoptionefp.txt,
## through ItemGlowTables), each counted by command kind and space. Headless:
##   remote_godot.sh script res://tools/census_equip_world.gd -- --pk2dir=/opt/sro-files/client

const KIND_NAMES := {
	EfpSim.K_POS: "SetPosition", EfpSim.K_BANPOS: "SetBANPos", EfpSim.K_CONEPOS: "SetConePos",
	EfpSim.K_VEL: "SetVelocity", EfpSim.K_FORCE: "Force", EfpSim.K_CONEVEL: "SetConeVel",
	EfpSim.K_CONEFORCE: "ConeForce", EfpSim.K_ROT: "SetRotation*", EfpSim.K_BANROT: "SetBANRot",
	EfpSim.K_RVEL: "SetRVelocity*", EfpSim.K_SPHERE: "SetSpherePos",
}

func _initialize() -> void:
	var dir := "/opt/sro-files/client"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pk2dir="):
			dir = a.substr(9)
	var media := Pk2Reader.open(dir.path_join("Media.pk2"))
	var particles := Pk2Reader.open(dir.path_join("Particles.pk2"))
	var t := ItemGlowTables.for_archive(media)
	var files := {}
	for call in t._particle_calls:
		for pair in call:
			files[(pair[1] as ItemGlowTables.ParticleRow).efp.to_lower()] = true
	var names := files.keys()
	names.sort()
	var world_files := 0
	var total := {}
	for f in names:
		var tmpl := EfpEffect.template_for(f, particles)
		if tmpl == null:
			print("WORLD %s: does not decode" % f)
			continue
		var by := {}
		for tp in tmpl.tpls:
			for frame in tp.schedule:
				if not (frame is Array):
					continue
				for c in frame:
					if c is Array and (c as Array).size() >= 3 and EquipFx._is_world(int(c[0]), int(c[1]), c[2]):
						var k := "%s space %d" % [KIND_NAMES.get(int(c[0]), str(c[0])), int(c[1])]
						by[k] = int(by.get(k, 0)) + 1
						total[k] = int(total.get(k, 0)) + 1
						if int(c[0]) == EfpSim.K_SPHERE and c[2] is Vector3:
							var w: Vector3 = c[2]
							var lo := minf(w.x, minf(w.y, w.z))
							var hi := maxf(w.x, maxf(w.y, w.z))
							print("WORLD   %s sphere %s, axis ratio %.2f" % [f, str(w), hi / lo if lo > 0.0 else INF])
		if not by.is_empty():
			world_files += 1
			print("WORLD %s: %s" % [f, str(by)])
	print("WORLD %d of %d file(s) take a world-axis command; in all: %s" % [world_files, names.size(), str(total)])
	quit(0)
