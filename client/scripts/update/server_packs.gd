extends RefCounted
class_name ServerPacks

## Which server's packs the archive set layers now (round 789, lane U; OURS,
## docs/protocol/asset_packs.md "Server packs"), and the switch between sets.
##
## Purity, the default: while the client is connected to a server that names
## its packs, AssetArchives layers EXACTLY those packs, in the server's order,
## over the base archives; the player's own packs and the custom/ path
## overlay are set aside (logged), so a modified local pack cannot change
## content the server assumes (walls, navmesh, item tables). A server that
## allows local extras (its FLAG_LOCAL_EXTRAS) gets the player's own packs
## below its own and custom/ on top, as rule 1 has it. A server that names no
## packs -- or an older server, or a legacy one -- leaves the player's set as
## it is. Round 678's branding files in custom/ are read by FrontEndTheme by
## their own paths, so setting the overlay aside never touches them.
##
## The server packs are read in every source mode (they are .pk3/.zip by the
## wire's rule; a server that requires them is not asking the player's
## preference).

class Selection:
	var key := ""
	var dir := ""
	## Lowest first: the manifest's order.
	var paths := PackedStringArray()
	var local_extras := false

	func signature() -> String:
		return "%s|%s|%s" % [key, local_extras, "|".join(paths)]

static var _active: Selection = null
static var _lock := Mutex.new()
## The last switch, for the log and the debug panel.
static var last_change := ""

static func active() -> Selection:
	_lock.lock()
	var s := _active
	_lock.unlock()
	return s

## Makes `sel` (null: none) the active selection; true when that changed it.
static func set_selection(sel: Selection) -> bool:
	_lock.lock()
	var before := _active.signature() if _active != null else ""
	var after := sel.signature() if sel != null else ""
	_active = sel
	_lock.unlock()
	return before != after

## Switches to `sel` (null: the player's own set) and, when that changes the
## layers, reopens the archive set and drops what was read from the old one.
## Call it where no scene holds archive handles it must see change: the
## login screen does, before the login goes out (asset_archives.gd's
## reopen()). True when the set was reopened.
static func apply(sel: Selection, why: String) -> bool:
	if not set_selection(sel):
		return false
	last_change = why
	print("PACKS: the archive set changes -- %s" % why)
	AssetArchives.reopen()
	drop_caches()
	return true

## What AssetArchives opens with the selection in force (called from its
## _config_opts): {"packs": paths lowest first, "custom_dir", "set_aside":
## lines for the log, "origin"}; {} when no server names packs.
static func layer_opts(local_pack_dir: String, mode: String, custom_dir: String) -> Dictionary:
	var sel := active()
	if sel == null:
		return {}
	var local := AssetArchives.discover_packs(local_pack_dir, mode)
	var packs := PackedStringArray()
	var aside := PackedStringArray()
	var custom := custom_dir
	if sel.local_extras:
		packs.append_array(local)
	else:
		for p in local:
			aside.append("pack %s" % p.get_file())
		if custom_dir != "" and DirAccess.dir_exists_absolute(custom_dir):
			aside.append("custom/ %s" % custom_dir)
		custom = ""
	packs.append_array(sel.paths)
	return {"packs": packs, "custom_dir": custom, "set_aside": aside,
		"origin": "server %s (%d pack(s)%s)" % [sel.key, sel.paths.size(), ", local extras allowed" if sel.local_extras else ""]}

## The parsed tables the process keeps in statics that do not key on the
## archive set (Pk2Reader.cache_key and AudioBank's set generation do):
## forgotten after a switch, so the next use reads the new set. Reached only
## from the login screen, before the login: no world, no select screen.
## NOT dropped (OPEN, asset_packs.md "Server packs"): the effect and particle
## caches keyed by path (EfpEffect, AmbientParticles), which worker threads
## fill under their own locks; they are filled in the world, which a first
## login reaches only after the switch, so they matter only for a second
## server with other packs in the same run.
static func drop_caches() -> void:
	AudioBank.clear()
	# The autoload by path, so a headless test without one runs this too.
	var tree := Engine.get_main_loop() as SceneTree
	var net: Node = tree.root.get_node_or_null("NetClient") if tree != null and tree.root != null else null
	if net != null:
		net.set("lobby_text", null)
	NameFilter._shared = null
	QuestTables._shared = null
	MagicOptionTable.shared = null
	ItemGlowTables.shared = null
	DamageText._art.clear()
	DamageText._art_loaded = false
