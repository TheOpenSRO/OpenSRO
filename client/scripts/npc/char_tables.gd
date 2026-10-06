extends RefCounted
class_name CharTables

## Round 746: the characterdata tables the world reads, from EVERY part the
## archive's own index names, parsed on worker threads.
##
## **Which parts.** The client loads the parts `textdata\characterdata.txt`
## names, in its order (MEASURED on the retail Media.pk2: CharacterData_1000
## .. CharacterData_63000, 63 names). The world read a hand-kept list of
## seven (the index file itself and _5000 .. _30000; now
## NpcTableReader.LEGACY_MODEL_TABLE_PATHS, the fallback for an archive with
## no index). That left 4,576 codes with a model unread, 670 of them `MOB_`
## (MEASURED, round 741's probe_table_parts): those monsters and NPCs drew as
## placeholders. The same bug round 741 fixed for itemdata.
##
## **Off the main thread.** The index's parts are 2.6 times the bytes (25.3 MB
## against 9.6 MB), and the world runs some eleven readers over them; the four
## boot readers alone went from 484 to 1,193 ms in GDScript (MEASURED). So two
## worker tasks, started at the top of World3D._ready (preload_async), each
## reading the parts itself:
## - the BOOT task: walk and run speeds and Country (the CHAR_ rows) and the
##   bodies' catalogue (CharCatalog.from_tables), what _load_character_assets
##   needs at once and waits for (boot);
## - the ENTRY task: BCRadius and DecayTime (every row; read at boot before,
##   used only once characters and monsters spawn), the NPC tables (models,
##   codes, names) and the monster tables (models by code, Org codes, models
##   by name) with the object-name table they join through, which the world
##   takes when the NPC or monster loaders first ask or the entry's grid is
##   in (entry) -- by then it has usually finished.
## Every reader is the one the world called before, on the same bytes; only
## the part list and the thread changed. Results are shared per archive path
## (Pk2Reader.source_path) and read-only to their callers.

class Boot:
	var parts := 0
	var bytes := 0
	var usec := 0
	var speeds := {}
	var country := {}
	var bodies: CharCatalog = null

class Entry:
	var usec := 0
	var names: UiTextTable = null
	var bc_radius := {}
	var decay := {}
	var npc_models := {}
	var npc_codes := {}
	var npc_names := {}
	var mob_models_by_code := {}
	var mob_org := {}
	var mob_models_by_name := {}

## Every characterdata part `media` holds, as archive paths, in its index's
## order; the legacy list when the archive has no index.
static func table_paths(media: Pk2Reader) -> PackedStringArray:
	var out := PackedStringArray()
	for name in CharCatalog.index_part_names(media, CharCatalog.CHAR_INDEX):
		out.append(CharCatalog.TEXTDATA_DIR + name)
	if out.is_empty():
		out = PackedStringArray(NpcTableReader.LEGACY_MODEL_TABLE_PATHS)
	return out

static var _key := ""
static var _boot: Boot = null
static var _entry: Entry = null
static var _boot_task := -1
static var _entry_task := -1
static var _boot_box: Array = [null]
static var _entry_box: Array = [null]
## How long the last boot()/entry() waited for its task, microseconds.
static var last_boot_wait_usec := 0
static var last_entry_wait_usec := 0

static func _key_of(media: Pk2Reader) -> String:
	return media.source_path if media.source_path != "" else str(media.get_instance_id())

## Starts both tasks for `media` unless its tables are shared or under way.
static func preload_async(media: Pk2Reader) -> void:
	if media == null:
		return
	var key := _key_of(media)
	if key == _key or _boot_task >= 0 or _entry_task >= 0:
		return
	wait_pending()
	_key = key
	_boot = null
	_entry = null
	var bb: Array = [null]
	var eb: Array = [null]
	_boot_box = bb
	_entry_box = eb
	_boot_task = WorkerThreadPool.add_task(func() -> void:
		bb[0] = CharTables.read_boot(media), false, "characterdata boot")
	_entry_task = WorkerThreadPool.add_task(func() -> void:
		eb[0] = CharTables.read_entry(media), false, "characterdata entry")

## The boot tables of `media`: the preload's (waited for) or read now.
static func boot(media: Pk2Reader) -> Boot:
	last_boot_wait_usec = 0
	if media == null:
		return Boot.new()
	var key := _key_of(media)
	if key != _key:
		wait_pending()
		_key = key
		_boot = null
		_entry = null
	if _boot == null and _boot_task >= 0:
		var t := Time.get_ticks_usec()
		WorkerThreadPool.wait_for_task_completion(_boot_task)
		_boot_task = -1
		last_boot_wait_usec = Time.get_ticks_usec() - t
		_boot = _boot_box[0]
	if _boot == null:
		_boot = read_boot(media)
	return _boot

## The entry tables of `media`: the preload's (waited for) or read now.
static func entry(media: Pk2Reader) -> Entry:
	last_entry_wait_usec = 0
	if media == null:
		return Entry.new()
	var key := _key_of(media)
	if key != _key:
		wait_pending()
		_key = key
		_boot = null
		_entry = null
	if _entry == null and _entry_task >= 0:
		var t := Time.get_ticks_usec()
		WorkerThreadPool.wait_for_task_completion(_entry_task)
		_entry_task = -1
		last_entry_wait_usec = Time.get_ticks_usec() - t
		_entry = _entry_box[0]
	if _entry == null:
		_entry = read_entry(media)
	return _entry

## Waits for any task under way and keeps what it read (a world leaving the
## tree before it asked, World3D._exit_tree).
static func wait_pending() -> void:
	if _boot_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_boot_task)
		_boot_task = -1
		_boot = _boot_box[0]
	if _entry_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_entry_task)
		_entry_task = -1
		_entry = _entry_box[0]

## Drops the shared tables (tests).
static func clear_shared() -> void:
	wait_pending()
	_key = ""
	_boot = null
	_entry = null

static func _parts(media: Pk2Reader) -> Array:
	var out: Array = []
	for path in table_paths(media):
		var e := ObjectLoader.find_file(media, path)
		if e != null:
			out.append(media.read_file(e))
	return out

## The boot readers over every part (thread-safe: plain data).
static func read_boot(media: Pk2Reader) -> Boot:
	var t0 := Time.get_ticks_usec()
	var b := Boot.new()
	var parts := _parts(media)
	for bytes in parts:
		b.parts += 1
		b.bytes += (bytes as PackedByteArray).size()
		b.speeds = NpcTableReader.parse_speeds_by_code(bytes, b.speeds)
		b.country = NpcTableReader.parse_country_by_code(bytes, b.country)
	b.bodies = CharCatalog.from_tables(parts, [])
	b.usec = Time.get_ticks_usec() - t0
	return b

## The NPC and monster readers over every part, with the object-name table
## they join through (thread-safe: plain data).
static func read_entry(media: Pk2Reader) -> Entry:
	var t0 := Time.get_ticks_usec()
	var e := Entry.new()
	e.names = ItemTableReader.load_object_names(media)
	for bytes in _parts(media):
		e.bc_radius = NpcTableReader.parse_bc_radius_by_code(bytes, e.bc_radius)
		e.decay = NpcTableReader.parse_decay_by_code(bytes, e.decay)
		e.npc_models = NpcTableReader.parse_models(bytes, e.npc_models)
		e.npc_codes = NpcTableReader.parse_codes(bytes, e.npc_codes)
		e.mob_models_by_code = NpcTableReader.parse_models_by_code(bytes, e.mob_models_by_code, "")
		e.mob_org = NpcTableReader.parse_org_codes(bytes, e.mob_org)
		if e.names != null:
			e.npc_names = NpcTableReader.parse_names(bytes, e.names, e.npc_names)
			e.mob_models_by_name = NpcTableReader.parse_models_by_name(bytes, e.names, e.mob_models_by_name)
	e.usec = Time.get_ticks_usec() - t0
	return e
