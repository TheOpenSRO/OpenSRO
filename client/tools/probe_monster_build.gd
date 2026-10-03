extends SceneTree

## Dev probe (round 655): what one monster body costs to build from the
## player's own archives -- assembled from its `.bsr` (the path every body
## took before this round) against duplicated from its species' template
## (MonsterDraw.Templates, the path now) -- and how many characterdata rows
## the Org rule gives a model (NpcTableReader.model_with_org).
##
## The species are the ones OPENSRO_QA_MOBS spawns (World3D._qa_mobs_step:
## every k-th of the sorted `MOB_CH_` codes with a model of their own, 24 of
## them) plus the four roster `_CLON`s. Each is assembled once, cold, and
## then duplicated DUPS times.
##
## Usage (render box only -- never run Godot on the developer's machine):
##   client/tools/remote_godot.sh sync
##   client/tools/remote_godot.sh script res://tools/probe_monster_build.gd -- \
##     --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2

const SPECIES := 24
const DUPS := 20
const CLONS := ["MOB_CH_BIGEYEGHOST_CLON", "MOB_CH_GYO_CLON", "MOB_CH_WATERGHOST_CLON", "MOB_CH_TOMBSTONE_CLON"]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var data := Pk2Reader.open(_arg("--pk2"))
	var media := Pk2Reader.open(_arg("--media"))
	if data == null or media == null:
		printerr("usage: --pk2=<Data.pk2> --media=<Media.pk2>")
		quit(2)
		return
	var models := {}
	var orgs := {}
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry == null:
			continue
		var bytes := media.read_file(entry)
		models = NpcTableReader.parse_models_by_code(bytes, models, "")
		orgs = NpcTableReader.parse_org_codes(bytes, orgs)
	# The Org rule over the whole table.
	var mob_rows := 0
	var mob_own := 0
	var mob_org := 0
	var clon_rows := 0
	var clon_org := 0
	var codes := {}
	for code in models:
		codes[code] = true
	for code in orgs:
		codes[code] = true
	for code in codes:
		var c := String(code)
		if not c.begins_with("MOB_"):
			continue
		mob_rows += 1
		if models.has(c):
			mob_own += 1
		elif NpcTableReader.model_with_org(c, models, orgs) != "":
			mob_org += 1
		if c.ends_with("_CLON"):
			clon_rows += 1
			if not models.has(c) and NpcTableReader.model_with_org(c, models, orgs) != "":
				clon_org += 1
	print("PROBE rows: %d MOB_ codes with a model or an Org; %d with their own model, %d more through their Org row; %d end in _CLON, %d of them take their Org's model" % [
		mob_rows, mob_own, mob_org, clon_rows, clon_org])
	for c in CLONS:
		print("PROBE org %s -> %s -> '%s'" % [c, orgs.get(c, "(none)"), NpcTableReader.model_with_org(c, models, orgs)])

	var pick: Array = []
	var sorted: Array = []
	for code in models:
		if String(code).begins_with("MOB_CH_"):
			sorted.append(code)
	sorted.sort()
	var step := maxi(sorted.size() / SPECIES, 1)
	for i in range(0, sorted.size(), step):
		if pick.size() < SPECIES:
			pick.append(sorted[i])
	pick.append_array(CLONS)

	var total_assemble := 0
	var total_dup := 0
	var assembled := 0
	var dups := 0
	for code in pick:
		var model := NpcTableReader.model_with_org(String(code), models, orgs)
		if model == "":
			print("PROBE %s: no model" % code)
			continue
		var t0 := Time.get_ticks_usec()
		var template := SkinnedBsrAssembler.assemble_from_archive(data, model, true)
		var assemble_usec := Time.get_ticks_usec() - t0
		if template == null:
			print("PROBE %s: %s did not assemble (%.1f ms)" % [code, model, assemble_usec / 1000.0])
			continue
		assembled += 1
		total_assemble += assemble_usec
		var t1 := Time.get_ticks_usec()
		var made: Array = []
		for i in range(DUPS):
			made.append(MonsterDraw.instance_of(template))
		var dup_usec := Time.get_ticks_usec() - t1
		total_dup += dup_usec
		dups += DUPS
		print("PROBE %s: %s assembled in %.1f ms; a template duplicate %.3f ms (%d bones, %d pieces)" % [
			code, model, assemble_usec / 1000.0, dup_usec / 1000.0 / DUPS,
			template.skeleton.get_bone_count(), template.skeleton.get_child_count()])
		for m in made:
			(m as SkinnedBsrAssembler.AssembledCharacter).skeleton.free()
		template.skeleton.free()
	if assembled > 0:
		var per_assemble := total_assemble / 1000.0 / assembled
		var per_dup := total_dup / 1000.0 / maxi(dups, 1)
		print("PROBE per body: assembled %.2f ms, duplicated %.3f ms (%.0fx); 500 bodies of %d species: %.0f ms uncached against %.0f ms cached" % [
			per_assemble, per_dup, per_assemble / maxf(per_dup, 0.0001), assembled,
			500.0 * per_assemble, assembled * per_assemble + (500 - assembled) * per_dup])
	quit(0)
