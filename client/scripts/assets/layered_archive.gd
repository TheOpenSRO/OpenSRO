extends Pk2Reader
class_name LayeredArchive

## One base archive seen through the asset packs above it (round 789; OURS:
## retail has only .pk2). AssetArchives hands one out per base archive --
## Data, Map, Media, Music, Particles -- when anything overlays them; to
## every caller it is the archive it asked for (a Pk2Reader: find_file,
## read_file, read_dir, read_dir_at), and no caller knows which layer a file
## came from.
##
## A lookup checks, highest priority first, and the first layer that has the
## path serves it (docs/protocol/asset_packs.md, "Rules"):
##   1. the loose custom/ folder (a path overlay: custom/prim/mtrl/x.ddj is
##      prim\mtrl\x.ddj);
##   2. the packs, the later name first (AssetArchives.discover_packs);
##   3. this view's volume -- its base layers, highest first (`Data.pk3` over
##      `Data.pk2` when both are read), always the bottom. The five volumes
##      are not one namespace (rule 3: Data and Map each hold an object.ifo).
## Lookups go through Pk2Reader.clean_path (rule 4: empty segments skipped,
## an unsafe path served by no layer).
## The overlay -- the custom/ files and every pack's paths -- is one index
## built once per set and shared by the five views: a pack's `prim\...`
## overrides Data's, its `textdata\...` Media's, and a new path appears in
## every view.
##
## An Entry remembers its layer (`_layer`): read_file sends it back there. A
## folder present in the overlay is a merged folder (`_path` holds its key):
## read_dir_at lists the base's entries with the overlay's laid over them,
## the base's order first, then the overlay's new names in its own order. A
## folder only the base has comes back as the base's own Entry and lists as
## before. With two base layers every folder is a merged one.

const LAYER_CUSTOM := -1
const LAYER_MERGED_DIR := -2

## The overlay shared by every view of one AssetArchives set.
class Overlay:
	## Index = layer id: [0] is null (the base, which differs per view), then
	## the packs, lowest priority first.
	var layers: Array = [null]
	## Same index: the pack's file name ("" for 0).
	var layer_names := PackedStringArray([""])
	## Lower-cased `/` path of every overlay FILE -> the layer that serves it
	## (a pack's id, or LAYER_CUSTOM).
	var index := {}
	## custom/ files: lower-cased path -> [absolute path, size, name].
	var custom := {}
	## Every overlay folder ("" the root) -> {lower child name: [name, is_dir]},
	## in the order first seen.
	var dirs := {}

	func is_empty() -> bool:
		return index.is_empty()

	## Records `path` (as written, `/`-separated) under layer `lid`; returns the
	## layer it replaced (0 when new). Folders on the way are added.
	func put(path: String, lid: int) -> int:
		var key := path.to_lower()
		var before: int = index.get(key, 0)
		index[key] = lid
		var segs := path.split("/")
		var parent := ""
		for i in range(segs.size()):
			var seg := segs[i]
			var low := seg.to_lower()
			var kids: Dictionary = dirs.get(parent, {})
			if not dirs.has(parent):
				dirs[parent] = kids
			var is_dir := i < segs.size() - 1
			if not kids.has(low):
				kids[low] = [seg, is_dir]
			elif is_dir:
				kids[low][1] = true
			parent = low if parent == "" else parent + "/" + low
		return before


## The base archive(s) of this view's volume, highest first (asset_packs.md
## rule 3): one in the usual case; `Data.pk3` above `Data.pk2` when both are
## read. The last is `base`: its entries carry layer 0. The ones above it are
## stamped LAYER_UPPER_BASE - i (Pk2Reader.layer_id) by AssetArchives.
var label := ""
var bases: Array = []
var base: Pk2Reader = null
## The set's generation (AssetArchives): part of cache_key().
var generation := 0
var _ov: Overlay = null
var _merged := {}

## An upper base layer's id: LAYER_UPPER_BASE - its index in `bases`.
const LAYER_UPPER_BASE := -10

static func make(label_: String, bases_: Array, overlay: Overlay, generation_: int) -> LayeredArchive:
	var v := LayeredArchive.new()
	v.label = label_
	v.bases = bases_
	v.base = bases_[bases_.size() - 1]
	v._ov = overlay
	v.generation = generation_
	v.source_path = v.base.source_path
	return v

## A lookup path's key: Pk2Reader.clean_path lower-cased ("" when unsafe or
## empty: no layer serves it).
static func key_of(path: String) -> String:
	return Pk2Reader.clean_path(path).to_lower()

func is_native() -> bool:
	return base.is_native()

## The set owns every handle: a view is never closed by a caller (AudioBank's
## clear, a scene's exit), only dropped.
func close() -> void:
	pass

func cache_key() -> String:
	return "%s|set%d" % [(bases[0] as Pk2Reader).cache_key(), generation]

func find_entry(path: String) -> Pk2Reader.Entry:
	var key := key_of(path)
	if key == "":
		return null
	var lid: int = _ov.index.get(key, 0)
	if lid == LAYER_CUSTOM:
		return _custom_entry(key)
	if lid > 0:
		var e: Pk2Reader.Entry = (_ov.layers[lid] as Pk2Reader).find_entry(key)
		if e != null:
			return e
	elif _ov.dirs.has(key):
		return _dir_entry(key, "")
	for b in bases:
		var e: Pk2Reader.Entry = (b as Pk2Reader).find_entry(path)
		if e != null:
			if e.is_dir and bases.size() > 1:
				return _dir_entry(key, e.name)
			return e
	return null

## The first of this volume's base layers holding `path` (the override
## census, AssetArchives.which), or null.
func find_in_bases(path: String) -> Pk2Reader.Entry:
	for b in bases:
		var e: Pk2Reader.Entry = (b as Pk2Reader).find_entry(path)
		if e != null:
			return e
	return null

func find_native(path: String) -> Pk2Reader.Entry:
	return find_entry(path)

func walk_find(path: String) -> Pk2Reader.Entry:
	return find_entry(path)

func read_dir() -> Array[Pk2Reader.Entry]:
	return _merged_dir("")

func read_dir_at(dir: Pk2Reader.Entry) -> Array[Pk2Reader.Entry]:
	if not dir.is_dir:
		push_error("pk2: %s is not a folder" % dir.name)
		return []
	if dir._layer == LAYER_MERGED_DIR:
		return _merged_dir(dir._path)
	return _reader_of(dir._layer).read_dir_at(dir)

func read_file(file: Pk2Reader.Entry) -> PackedByteArray:
	if file._layer == LAYER_CUSTOM:
		return _read_custom(file)
	if file._layer == LAYER_MERGED_DIR:
		push_error("pk2: %s is a folder, not a file" % file.name)
		return PackedByteArray()
	return _reader_of(file._layer).read_file(file)

## The handle an entry's layer id names.
func _reader_of(lid: int) -> Pk2Reader:
	if lid > 0:
		return _ov.layers[lid]
	if lid <= LAYER_UPPER_BASE:
		return bases[LAYER_UPPER_BASE - lid]
	return base

func file_paths() -> PackedStringArray:
	return base.file_paths()

func _dir_entry(key: String, name: String) -> Pk2Reader.Entry:
	var e := Pk2Reader.Entry.new()
	e.name = name if name != "" else key.get_file()
	e.is_dir = true
	e.size = 0
	e._offset = -1
	e._layer = LAYER_MERGED_DIR
	e._path = key
	return e

func _custom_entry(key: String) -> Pk2Reader.Entry:
	var info: Array = _ov.custom[key]
	var e := Pk2Reader.Entry.new()
	e.name = info[2]
	e.is_dir = false
	e.size = info[1]
	e._offset = 0
	e._layer = LAYER_CUSTOM
	e._path = info[0]
	return e

func _read_custom(e: Pk2Reader.Entry) -> PackedByteArray:
	var f := FileAccess.open(e._path, FileAccess.READ)
	if f == null:
		push_error("pk2: custom file %s could not be read" % e._path)
		return PackedByteArray()
	var n := f.get_length()
	if n > Pk3Reader.MAX_ENTRY_BYTES:
		push_error("pk2: custom file %s is larger than the %d-byte entry cap" % [e._path, Pk3Reader.MAX_ENTRY_BYTES])
		return PackedByteArray()
	return f.get_buffer(n)

## A merged folder's listing, made once (the layers never change in a set):
## the base layers' entries (the highest first; of one name the first is
## kept), the overlay's laid over them, then the overlay's new names.
func _merged_dir(key: String) -> Array[Pk2Reader.Entry]:
	_lock.lock()
	if _merged.has(key):
		var hit: Array[Pk2Reader.Entry] = _merged[key]
		_lock.unlock()
		return hit
	_lock.unlock()
	var kids: Dictionary = _ov.dirs.get(key, {})
	var multi := bases.size() > 1
	var out: Array[Pk2Reader.Entry] = []
	var seen := {}
	for b in bases:
		var list: Array[Pk2Reader.Entry] = []
		if key == "":
			list = (b as Pk2Reader).read_dir()
		else:
			var bd := (b as Pk2Reader).find_entry(key)
			if bd != null and bd.is_dir:
				list = (b as Pk2Reader).read_dir_at(bd)
		for e in list:
			var low := e.name.to_lower()
			if seen.has(low):
				continue
			seen[low] = true
			if kids.has(low):
				var child := _overlay_child(key, low, kids[low], e.name)
				if child != null:
					out.append(child)
			elif e.is_dir and multi:
				out.append(_dir_entry(low if key == "" else key + "/" + low, e.name))
			else:
				out.append(e)
	for low in kids:
		if not seen.has(low):
			seen[low] = true
			var child := _overlay_child(key, low, kids[low], "")
			if child != null:
				out.append(child)
	_lock.lock()
	if not _merged.has(key):
		_merged[key] = out
	out = _merged[key]
	_lock.unlock()
	return out

func _overlay_child(parent: String, low: String, info: Array, base_name: String) -> Pk2Reader.Entry:
	var child_key := low if parent == "" else parent + "/" + low
	if info[1]:
		return _dir_entry(child_key, base_name if base_name != "" else str(info[0]))
	return find_entry(child_key)
