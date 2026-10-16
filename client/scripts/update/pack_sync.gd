extends Node
class_name PackSync

## Gets a server's packs onto the disk and into the archive set before the
## login goes out (round 789, lane U; OURS, docs/protocol/asset_packs.md
## "Server packs"). Added as a child by whoever logs in (Login on Connect,
## QaSignIn), started with the server's address, it:
##
## 1. asks the server (PackQuery). No answer -- an older server, or none at
##    that address -- or an answer naming no packs: the player's own set
##    (ServerPacks.apply(null)), finished ok. A list that does not decode:
##    finished with the reason, nothing changed.
## 2. plans against what the server's folder holds (PackStore.plan), after
##    removing what the list no longer names (PackStore.sweep): a pack
##    verified before (size and modified time unchanged since) is ready at
##    once; one on disk but not verified since it changed is hashed; the rest
##    are downloaded (PackDownload), one after the other.
## 3. layers exactly the list's packs (ServerPacks.apply), reopening the
##    archive set when that changed it, and finishes ok.
##
## progress(text) carries one line for the login screen's message line; every
## step is logged as a `PACKS:` line.

signal progress(text: String)
signal finished(ok: bool, why: String)

## OURS: room kept free beyond the packs themselves.
const DISK_MARGIN := 64 << 20
## OURS: hashing per frame (a slice of a large pack).
const HASH_BUDGET := 48 << 20
const PROGRESS_EVERY_MS := 200

## Addresses that accepted the connection but never answered the request in
## this run (servers from before round 789): not asked again until restart.
static var _no_list := {}

var host := ""
var port := 0
var manifest: PackManifest = null
var store: PackStore = null
var steps: Array = []
var fetched := 0
var hashed := 0
var reused := 0
var done := false
var ok := false
var why := ""
## How long the question waits (a test shortens it).
var query_timeout_ms := PackQuery.TIMEOUT_MS

var _query: PackQuery = null
var _i := 0
var _hasher: PackStore.FileHasher = null
var _dl: PackDownload = null
var _last_progress_ms := 0
var _started_ms := 0

func _ready() -> void:
	set_process(false)

func start(p_host: String, p_port: int) -> void:
	host = p_host
	port = p_port
	_started_ms = Time.get_ticks_msec()
	var key := "%s:%d" % [host, port]
	if _no_list.has(key):
		_finish.call_deferred(true, "%s did not answer the pack question earlier in this run -- an older server; the player's own packs" % key, null)
		return
	_query = PackQuery.new()
	_query.timeout_ms = query_timeout_ms
	_query.name = "PackQuery"
	add_child(_query)
	_query.finished.connect(_on_list, CONNECT_ONE_SHOT)
	print("PACKS: asking %s for the packs it needs" % key)
	progress.emit("Checking the server's packs...")
	_query.start(host, port)

func _on_list(m: PackManifest, answer: String) -> void:
	var key := "%s:%d" % [host, port]
	if m == null:
		if _query != null and _query.connected:
			_no_list[key] = true
		_finish(true, "no pack list from %s (%s) -- the player's own packs" % [key, answer], null)
		return
	if m.error != "":
		_finish(false, "The server's pack list cannot be read (%s)." % m.error, null, false)
		return
	manifest = m
	print("PACKS: %s names %s (%s)" % [key, m.describe(), answer])
	if not m.required:
		_finish(true, "%s names no packs -- the player's own packs" % key, null)
		return
	# Every pack needs a source this client takes (PackManifest.url_allowed).
	for p in m.packs:
		var pk := p as PackManifest.Pack
		if allowed_sources(m, pk, host).is_empty():
			var refused := PackedStringArray()
			for s in m.sources(pk, host):
				refused.append(PackManifest.url_allowed(s, host))
			_finish(false, "The server's pack %s has no download address this client accepts (%s)." % [pk.name, "; ".join(refused)], null, false)
			return
	store = PackStore.for_server(host, port)
	if not store.ensure_dir():
		_finish(false, "Cannot create the folder for the server's packs: %s" % store.dir, null, false)
		return
	var removed := store.sweep(m)
	if not removed.is_empty():
		print("PACKS: removed what %s no longer names: %s" % [key, ", ".join(removed)])
	steps = store.plan(m)
	var need := 0
	for st in steps:
		print("PACKS: %s: %s (%s)" % [(st["pack"] as PackManifest.Pack).name, st["action"], st["why"]])
		if st["action"] == "fetch":
			var pk := st["pack"] as PackManifest.Pack
			need += pk.size - maxi(0, PackStore._size(store.partial_of(pk.name, pk.sha256)))
	var free := store.space_left()
	if need > 0 and free >= 0 and free < need + DISK_MARGIN:
		_finish(false, "Not enough free disk space for the server's packs: %s needed, %s free." % [mb(need), mb(free)], null, false)
		return
	_i = 0
	set_process(true)

## The sources of `pk` this client fetches from, in order.
static func allowed_sources(m: PackManifest, pk: PackManifest.Pack, gateway_host: String) -> PackedStringArray:
	var out := PackedStringArray()
	for s in m.sources(pk, gateway_host):
		var why := PackManifest.url_allowed(s, gateway_host)
		if why == "":
			out.append(s)
		else:
			print("PACKS: %s: source %s refused: %s" % [pk.name, s, why])
	return out

func _process(_delta: float) -> void:
	if done:
		set_process(false)
		return
	while _i < steps.size():
		var st: Dictionary = steps[_i]
		var pk := st["pack"] as PackManifest.Pack
		match str(st["action"]):
			"ready":
				reused += 1
				_i += 1
				continue
			"hash":
				if _hasher == null:
					_hasher = PackStore.FileHasher.new(str(st["path"]))
				var over := _hasher.poll(HASH_BUDGET)
				_say_progress("Checking %s: %s of %s" % [pk.name, mb(_hasher.done), mb(pk.size)])
				if not over:
					return
				var h := _hasher
				_hasher = null
				hashed += 1
				if h.error == "" and h.hex == pk.sha256:
					store.remember(pk.name, pk.sha256)
					store.save_cache()
					print("PACKS: %s: hashed, the server's version (%d ms)" % [pk.name, Time.get_ticks_msec() - _started_ms])
					_i += 1
				else:
					print("PACKS: %s: %s -- downloading it" % [pk.name, h.error if h.error != "" else "another version here (sha256 %s...)" % h.hex.left(12)])
					st["action"] = "fetch"
				return
			"fetch":
				if _dl == null:
					_dl = PackDownload.new(pk, allowed_sources(manifest, pk, host), host, str(st["path"]), store.partial_of(pk.name, pk.sha256))
					_dl.start()
				var over := _dl.poll()
				if _dl.state == PackDownload.S_PREHASH:
					_say_progress("Checking the part of %s already here..." % pk.name)
				else:
					_say_progress("Downloading %s: %s of %s (%d%%)" % [pk.name, mb(_dl.received), mb(pk.size), int(100.0 * _dl.received / maxf(1.0, pk.size))])
				if not over:
					return
				var d := _dl
				_dl = null
				if d.state != PackDownload.S_DONE:
					_finish(false, "Could not download the server's pack %s: %s" % [pk.name, d.error], null, false)
					return
				store.remember(pk.name, pk.sha256)
				store.save_cache()
				fetched += 1
				_i += 1
				return
	# Every pack is in place and verified.
	var sel := ServerPacks.Selection.new()
	sel.key = PackStore.server_key(host, port)
	sel.dir = store.dir
	sel.paths = store.paths(manifest)
	sel.local_extras = manifest.local_extras
	_finish(true, "%d pack(s) of %s:%d ready: %d downloaded, %d checked, %d verified before (%d ms)" % [
		manifest.packs.size(), host, port, fetched, hashed, reused, Time.get_ticks_msec() - _started_ms], sel)

func _say_progress(text: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_progress_ms < PROGRESS_EVERY_MS:
		return
	_last_progress_ms = now
	progress.emit(text)

## Ends the sync. `apply`: switch the archive set to `sel` (null: the
## player's own); a failure leaves the set as it is.
func _finish(p_ok: bool, p_why: String, sel: ServerPacks.Selection, apply: bool = true) -> void:
	if done:
		return
	done = true
	ok = p_ok
	why = p_why
	set_process(false)
	if _dl != null:
		_dl.cancel()
		_dl = null
	print("PACKS: %s%s" % ["" if ok else "NOT READY: ", why])
	if ok and apply:
		var changed := ServerPacks.apply(sel, why)
		print("PACKS: the archive set %s (set %d)" % ["was reopened" if changed else "is unchanged", AssetArchives.current_generation()])
	finished.emit(ok, why)

func cancel() -> void:
	_finish(false, "cancelled", null, false)

## "12.3 MB" (OURS: decimal megabytes, one place).
static func mb(n: int) -> String:
	return "%.1f MB" % (n / 1000000.0)
