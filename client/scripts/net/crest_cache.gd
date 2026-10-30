extends RefCounted
class_name CrestCache

## Round 824: each guild's crest as this client knows it -- the original's
## crest cache map (0xeeef70, keyed by guild name: the guild and union ids and
## revisions, and a texture for each; FUN_009a4780) -- and the crests'
## pictures. READ unless marked (CrestNet has the layouts).
##
## Who tells it: a player's spawn record and 0x30FF (the guild block's crest
## revision), 0x3257 (a crest registered or deleted), and the own guild's
## block. A revision of 0 clears the picture (0x9a48f0).
##
## OURS: the bytes are asked of the game server (CrestNet.OP_CREST_GET) and
## kept under user://crest/ as <kind letter><id>.rd -- the 256 bytes and the
## u32 revision -- the way the original keeps RD\G<shard>_<id>.rd with its
## revision as the file's last four bytes (FUN_004f9fd0), so a crest is asked
## for once per revision.

const DISK_DIR := "user://crest"

## A guild's crest picture came, changed or went.
signal changed(guild_name: String)

## silk.dat's 768 bytes (the owner reads them from Media.pk2).
var palette := PackedByteArray()
## Sends a message (op, payload); unset: nothing is asked.
var send: Callable

## guild name -> {"id": guild id, "rev": crest revision}
var _guilds := {}
## "<kind>_<id>" -> {"rev": int, "texture": Texture2D}
var _pictures := {}
## "<kind>_<id>_<rev>" asked and not answered.
var _asked := {}
## Round 844: guild name -> {"id": union id, "rev": the union's crest
## revision} -- the cache entry's union half (0x9a4780's fourth and fifth
## arguments; c:0x895810's type 2 sets it for each guild it names).
var _unions := {}

func clear() -> void:
	_guilds.clear()
	_unions.clear()
	_asked.clear()

## Round 844: a guild's union and its crest revision (a spawn, 0x30FF, or
## 0x3257 type 2). Lines are remade when it changes.
func note_union(guild_name: String, union_id: int, rev: int) -> void:
	if guild_name == "":
		return
	var old: Dictionary = _unions.get(guild_name, {})
	if int(old.get("id", -1)) == union_id and int(old.get("rev", -1)) == rev:
		return
	_unions[guild_name] = {"id": union_id, "rev": rev}
	if rev != 0 or int(old.get("rev", 0)) != 0:
		changed.emit(guild_name)

## Round 844: the union crest drawn beside a guild's line (the entry's +0x38),
## or null -- none, or asked for (CrestNet.KIND_UNION) and not here yet.
func union_texture_for(guild_name: String) -> Texture2D:
	var u: Dictionary = _unions.get(guild_name, {})
	var rev := int(u.get("rev", 0))
	var id := int(u.get("id", 0))
	if rev == 0 or id == 0:
		return null
	var t := _picture(CrestNet.KIND_UNION, id, rev)
	if t != null:
		return t
	var px := _load(CrestNet.KIND_UNION, id, rev)
	if px.size() == CrestNet.BYTES:
		return _store(CrestNet.KIND_UNION, id, rev, px)
	var key := "%d_%d_%d" % [CrestNet.KIND_UNION, id, rev]
	if not _asked.has(key) and send.is_valid():
		_asked[key] = true
		send.call(CrestNet.OP_CREST_GET, CrestNet.encode_get(CrestNet.KIND_UNION, id, rev))
	return null

## A guild's id and crest revision, as a spawn, 0x30FF or the block says.
func note_guild(guild_name: String, guild_id: int, rev: int) -> void:
	if guild_name == "":
		return
	var old: Dictionary = _guilds.get(guild_name, {})
	if int(old.get("id", -1)) == guild_id and int(old.get("rev", -1)) == rev:
		return
	_guilds[guild_name] = {"id": guild_id, "rev": rev}
	# A guild's entry is new or changed once, not once per member (the same
	# id and revision return above), so its lines are remade once: a plate
	# drawn before the guild was known (the own one at world entry) gets the
	# picture too. A first note of no crest changes nothing.
	if rev != 0 or not old.is_empty():
		changed.emit(guild_name)

## 0x3257. Returns the update (the owner sets the own guild's revision).
func handle_update(data: PackedByteArray) -> CrestNet.Update:
	var u := CrestNet.decode_update(data)
	if u == null:
		return null
	if u.kind == CrestNet.KIND_GUILD:
		note_guild(u.guild_names[0], u.id, u.rev)
		if u.rev == 0:
			_pictures.erase("%d_%d" % [KIND_KEY_GUILD, u.id])
		else:
			texture_for(u.guild_names[0])
	elif u.kind == CrestNet.KIND_UNION:
		# Round 844: each named guild's entry takes the union's crest.
		if u.rev == 0:
			_pictures.erase("%d_%d" % [CrestNet.KIND_UNION, u.id])
		for n in u.guild_names:
			note_union(n, u.id, u.rev)
	return u

## 0x0131: a crest's bytes, kept and drawn.
func handle_data(data: PackedByteArray) -> void:
	var d := CrestNet.decode_data(data)
	if d == null:
		return
	_asked.erase("%d_%d_%d" % [d.kind, d.id, d.rev])
	if not d.ok:
		return
	_save(d.kind, d.id, d.rev, d.pixels)
	_store(d.kind, d.id, d.rev, d.pixels)
	for guild_name in _guilds:
		var g: Dictionary = _guilds[guild_name]
		if d.kind == KIND_KEY_GUILD and int(g["id"]) == d.id and int(g["rev"]) == d.rev:
			changed.emit(String(guild_name))
	if d.kind == CrestNet.KIND_UNION:
		for guild_name in _unions:
			var un: Dictionary = _unions[guild_name]
			if int(un["id"]) == d.id and int(un["rev"]) == d.rev:
				changed.emit(String(guild_name))

const KIND_KEY_GUILD := CrestNet.KIND_GUILD

## The guild's crest revision (0 none or unknown).
func rev_of(guild_name: String) -> int:
	return int((_guilds.get(guild_name, {}) as Dictionary).get("rev", 0))

## The guild's crest picture, or null -- none, or not here yet (it is then
## asked for, and `changed` says when it comes).
func texture_for(guild_name: String) -> Texture2D:
	var g: Dictionary = _guilds.get(guild_name, {})
	var rev := int(g.get("rev", 0))
	var id := int(g.get("id", 0))
	if rev == 0 or id == 0:
		return null
	var t := _picture(KIND_KEY_GUILD, id, rev)
	if t != null:
		return t
	var px := _load(KIND_KEY_GUILD, id, rev)
	if px.size() == CrestNet.BYTES:
		return _store(KIND_KEY_GUILD, id, rev, px)
	var key := "%d_%d_%d" % [KIND_KEY_GUILD, id, rev]
	if not _asked.has(key) and send.is_valid():
		_asked[key] = true
		send.call(CrestNet.OP_CREST_GET, CrestNet.encode_get(KIND_KEY_GUILD, id, rev))
	return null

func _picture(kind: int, id: int, rev: int) -> Texture2D:
	var p: Dictionary = _pictures.get("%d_%d" % [kind, id], {})
	return p.get("texture") if int(p.get("rev", -1)) == rev else null

func _store(kind: int, id: int, rev: int, pixels: PackedByteArray) -> Texture2D:
	var img := CrestNet.image_of(pixels, palette)
	if img == null:
		return null
	var tex := ImageTexture.create_from_image(img)
	_pictures["%d_%d" % [kind, id]] = {"rev": rev, "texture": tex}
	return tex

func _path(kind: int, id: int) -> String:
	return DISK_DIR.path_join("%s%d.rd" % ["G" if kind == KIND_KEY_GUILD else "A", id])

func _save(kind: int, id: int, rev: int, pixels: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DISK_DIR))
	var f := FileAccess.open(_path(kind, id), FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(pixels)
	f.store_32(rev)
	f.close()

## The kept bytes when the file's last four bytes are `rev` (FUN_004f9fd0's
## test), else nothing.
func _load(kind: int, id: int, rev: int) -> PackedByteArray:
	var f := FileAccess.open(_path(kind, id), FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(CrestNet.BYTES + 4)
	f.close()
	if b.size() != CrestNet.BYTES + 4 or b.decode_u32(CrestNet.BYTES) != rev:
		return PackedByteArray()
	return b.slice(0, CrestNet.BYTES)
