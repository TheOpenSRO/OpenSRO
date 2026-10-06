extends SceneTree

## Dev tool (round 740): counts what the glow tables' OrgObjCodeName
## inheritance (ItemGlowTables.inherit, docs/protocol/weapon_glow.md §1.4)
## does over the player's own Media.pk2, through the client's own readers:
## the item rows as the world reads them (ItemTableReader.TABLE_PATHS) and as
## CharacterAppearance's full load does (every part itemdata.txt names), and
## the named items' types and particle rows. Prints counts and code names only.
##
## Usage:
##   godot4 --headless --path client --script res://tools/glow_inherit_probe.gd -- \
##     --media=/path/to/Media.pk2 [--code=ITEM_X ...]

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _show(t: ItemGlowTables, rows: Dictionary, code: String) -> void:
	var item: ItemTableReader.Item = null
	for id in rows:
		if (rows[id] as ItemTableReader.Item).code_name == code:
			item = rows[id]
			break
	var effs := PackedStringArray()
	for r in t.particle_rows(code, 0):
		effs.append("%s@+0" % (r as ItemGlowTables.ParticleRow).efp)
	for r in t.particle_rows(code, 8):
		var p := r as ItemGlowTables.ParticleRow
		if p.min_plus > 0:
			effs.append("%s@+%d..%d" % [p.efp, p.min_plus, p.max_plus])
	print("  %-42s id %6s org %-36s gate %-5s type %d  particles %s" % [code,
		str(item.id) if item != null else "-", (item.org_code_name if item != null and item.org_code_name != "" else "(none)"),
		str(ItemGlowTables.inherits_glow(item.cash_item, item.bionic, item.type_ids)) if item != null else "-",
		t.type_of(code), ", ".join(effs) if not effs.is_empty() else "none"])

func _init() -> void:
	var media_path := _arg("--media")
	if media_path == "":
		printerr("usage: --media=<Media.pk2> [--code=ITEM_X]")
		quit(2)
		return
	var media := Pk2Reader.open(media_path)
	if media == null:
		printerr("could not open ", media_path)
		quit(1)
		return
	var t := ItemGlowTables.for_archive(media)
	print("direct: %d typed code name(s), %d with particles" % [t.item_count(), t._particles.size()])
	# The world's seven parts first, as World3D hands them to CharacterAppearance.
	var world := {}
	for path in ItemTableReader.TABLE_PATHS:
		var entry := ObjectLoader.find_file(media, path)
		if entry != null:
			ItemTableReader.parse(media.read_file(entry), world)
	var t0 := Time.get_ticks_usec()
	t.inherit(world)
	print("world parts: %d row(s); inherit %.1f ms -> %d type(s), %d particle list(s) inherited" % [
		world.size(), (Time.get_ticks_usec() - t0) / 1000.0, t.inherited_types, t.inherited_particles])
	var full := {}
	for part in CharCatalog.index_parts(media, CharCatalog.ITEM_INDEX):
		ItemTableReader.parse(part, full)
	t0 = Time.get_ticks_usec()
	var added := t.inherit(full)
	print("every indexed part: %d row(s), %d member(s) added; inherit %.1f ms -> %d type(s), %d particle list(s) inherited" % [
		full.size(), added, (Time.get_ticks_usec() - t0) / 1000.0, t.inherited_types, t.inherited_particles])
	# Every inheritor, by its base's type.
	var by_type := {}
	var prefixes := {}
	for id in full:
		var it: ItemTableReader.Item = full[id]
		if it.org_code_name == "" or not ItemGlowTables.inherits_glow(it.cash_item, it.bionic, it.type_ids):
			continue
		var ty := t.type_of(it.code_name)
		if ty != 0 and t._direct_types.get(it.code_name.to_upper(), 0) == 0:
			by_type[ty] = int(by_type.get(ty, 0)) + 1
			var pre := "_".join(it.code_name.split("_").slice(0, 2))
			prefixes[pre] = int(prefixes.get(pre, 0)) + 1
	print("inherited types by type number: %s; by code prefix: %s" % [str(by_type), str(prefixes)])
	var codes := PackedStringArray(["ITEM_CH_SPEAR_11_A_RARE", "ITEM_CH_SPEAR_11_A_RARE_ACTIVE", "ITEM_CH_SWORD_11_A_RARE_ACTIVE",
		"ITEM_CH_BOW_10_C_RARE", "ITEM_EVENT_CH_BOW_10_C_RARE", "ITEM_CH_SWORD_08_A_RARE", "ITEM_EVENT_CH_SWORD_08_A_RARE"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--code="):
			codes.append(a.substr(7))
	# The ITEM_EVENT_*_11_A_RARE rows, whatever they are.
	for id in full:
		var c: String = (full[id] as ItemTableReader.Item).code_name
		if c.begins_with("ITEM_EVENT_") and c.ends_with("_11_A_RARE") and codes.size() < 12:
			codes.append(c)
	for c in codes:
		_show(t, full, c)
	quit(0)
