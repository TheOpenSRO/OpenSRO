extends RefCounted
class_name Pk2Reader

## Read-only reader for the pk2 (JMXVFS) archive container format.
## See docs/protocol/PK2_FORMAT.md for the on-disk layout. Mirrors
## server/internal/pk2's Go implementation; keep the two in sync if the
## format understanding changes.
##
## This project never writes or re-encrypts pk2 archives — only opens
## user-supplied ones to stream assets out of them at runtime.

const HEADER_SIZE := 256
const ENTRY_SIZE := 128
const ENTRIES_PER_BLOCK := 20
const BLOCK_SIZE := ENTRY_SIZE * ENTRIES_PER_BLOCK

const ENTRY_TYPE_EMPTY := 0
const ENTRY_TYPE_FOLDER := 1
const ENTRY_TYPE_FILE := 2

# Field offsets within a 128-byte directory entry. See
# docs/protocol/PK2_FORMAT.md for how these were derived.
const ENTRY_OFF_NAME := 0x01
const ENTRY_NAME_LEN := 89
const ENTRY_OFF_POSITION := 0x6A
const ENTRY_OFF_SIZE := 0x72
## Only meaningful on the last (20th) entry slot of a block: the file
## offset of the block continuing this directory's entry list, or 0 if
## this block holds the directory's last entries. See
## docs/protocol/PK2_FORMAT.md for how this was found and confirmed.
const ENTRY_OFF_NEXT_BLOCK := 0x76
## Bounds how many continuation blocks _read_block_chain will follow for
## one directory -- a cycle/corruption guard, not a real observed limit
## (the largest real chain found while confirming this had 3 blocks).
const MAX_CHAIN_BLOCKS := 100000

# See docs/protocol/PK2_FORMAT.md: long-published default key for the
# format's directory-table obfuscation, not a secret protecting first-party
# asset bytes.
const DEFAULT_KEY := "169841"

# Fixed, format-constant byte table the reference client XORs against the
# raw key string before running it through the standard Blowfish key
# schedule. Only the bytes up to the key's length are ever used; the table
# is zero beyond what's shown here (verified against a real archive).
const KEY_XOR_TABLE: PackedByteArray = [0x03, 0xf8, 0xe4, 0x44, 0x88, 0x99, 0x3f, 0x64, 0xfe, 0x35]

static func _effective_key(key: PackedByteArray) -> PackedByteArray:
	var eff := PackedByteArray()
	eff.resize(key.size())
	for i in range(key.size()):
		var x := 0
		if i < KEY_XOR_TABLE.size():
			x = KEY_XOR_TABLE[i]
		eff[i] = key[i] ^ x
	return eff

class Entry:
	var name: String
	var is_dir: bool
	var size: int
	var _offset: int

var _file: FileAccess
var _encrypted: bool
var _cipher: Blowfish
var _root_offset: int

## Real, significant fix (2026-08-26, see docs/WORLD_ISSUES.md): caches
## each directory's parsed entries by its chain-start file offset. Without
## this, every single real asset lookup (ObjectLoader.find_file walks one
## read_dir()/read_dir_at() call per path segment, from the root down) fully
## re-reads and re-decrypts that directory's blocks from disk -- and a real
## region load resolves the same handful of real folders (Prim\Mesh\...,
## Prim\Mtrl\..., Tile2D\, etc.) over and over for every object/texture it
## needs. A real playtest reported ~3 minutes to load into the game; this
## cache is the direct fix, since a pk2 archive's directory contents never
## change during a session (this reader is read-only, see the file's own
## top comment) so caching them is always safe.
var _dir_cache := {}

## One lock per handle (round 565), taken by every method that touches the
## two things above that a read shares: `_file`'s seek position (read_file is
## a seek then a get_buffer, _read_block_chain a seek then a get_buffer per
## block) and `_dir_cache`. Until round 565 every read ran on the main
## thread; World3D now reads a region's terrain files on a WorkerThreadPool
## task while the main thread keeps reading scenery, NPC and UI assets
## through the same handle, and two threads interleaving seek and get_buffer
## each read the other's bytes. Godot's Mutex is reentrant, so read_dir and
## read_dir_at need no lock of their own: all they share is behind
## _read_block_chain's. Reads are short and sequential, so one lock costs
## little; pk2_reader_test.gd's concurrent-read case is the regression guard.
var _lock := Mutex.new()

## Opens path for reading. Returns null (and pushes an error) on failure.
static func open(path: String) -> Pk2Reader:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("pk2: could not open %s: %s" % [path, FileAccess.get_open_error()])
		return null

	var header := f.get_buffer(HEADER_SIZE)
	if header.size() < HEADER_SIZE:
		push_error("pk2: %s is too small to be a pk2 archive" % path)
		return null

	var magic := header.slice(0, 30).get_string_from_ascii().rstrip(char(0))
	if not magic.begins_with("JoyMax File Manager"):
		push_error("pk2: %s is not a pk2 archive (bad magic)" % path)
		return null

	var reader := Pk2Reader.new()
	reader._file = f
	reader._encrypted = header[0x22] != 0
	reader._root_offset = HEADER_SIZE
	if reader._encrypted:
		reader._cipher = Blowfish.new(_effective_key(DEFAULT_KEY.to_ascii_buffer()))
	return reader

func close() -> void:
	_lock.lock()
	if _file != null:
		_file.close()
	_lock.unlock()

## Returns the entries of the root directory.
func read_dir() -> Array[Entry]:
	return _read_block_chain(_root_offset)

## Returns the entries of a folder Entry previously returned by
## read_dir()/read_dir_at(). Errors (returns []) if given a file Entry.
func read_dir_at(dir: Entry) -> Array[Entry]:
	if not dir.is_dir:
		push_error("pk2: %s is not a folder" % dir.name)
		return []
	return _read_block_chain(dir._offset)

## Returns the raw contents of a file Entry.
func read_file(file: Entry) -> PackedByteArray:
	if file.is_dir:
		push_error("pk2: %s is a folder, not a file" % file.name)
		return PackedByteArray()
	_lock.lock()
	_file.seek(file._offset)
	var bytes := _file.get_buffer(file.size)
	_lock.unlock()
	return bytes

## Reads a directory's full entry list, following the real "next block"
## continuation mechanism: only the last (20th) entry slot of a block
## carries a next-block file offset (confirmed to be 0 on every entry
## except a real block's final slot, which holds it whenever more entries
## follow) -- a directory with more than ENTRIES_PER_BLOCK real entries is
## simply a linked chain of these blocks, not one fixed-size block as this
## reader originally (incorrectly) assumed. Confirmed by decompiling the
## real client's own directory-read function (GFXFileManager.dll) and
## cross-checking the exact field it reads against real block bytes in a
## real 3.8GB Data.pk2 whose root directory turned out to need 3 chained
## blocks -- see docs/protocol/PK2_FORMAT.md for the full derivation. No
## decompiler output is stored in this repo, only the resulting fact about
## the field layout. MAX_CHAIN_BLOCKS bounds the walk as a
## cycle/corruption guard, not a real observed limit.
func _read_block_chain(offset: int) -> Array[Entry]:
	_lock.lock()
	var out := _read_block_chain_locked(offset)
	_lock.unlock()
	return out

## _read_block_chain's body, run under `_lock` -- split out so every return
## path unlocks in one place.
func _read_block_chain_locked(offset: int) -> Array[Entry]:
	var cache_key := offset
	if _dir_cache.has(cache_key):
		return _dir_cache[cache_key]

	var out: Array[Entry] = []

	for _chain_step in range(MAX_CHAIN_BLOCKS):
		_file.seek(offset)
		var block := _file.get_buffer(BLOCK_SIZE)
		if _encrypted:
			_decrypt_block_pk2(block)

		var next_offset := 0
		for i in range(ENTRIES_PER_BLOCK):
			var raw := block.slice(i * ENTRY_SIZE, (i + 1) * ENTRY_SIZE)
			var entry_type := raw[0]

			if entry_type == ENTRY_TYPE_FOLDER or entry_type == ENTRY_TYPE_FILE:
				var name := _null_terminated(raw.slice(ENTRY_OFF_NAME, ENTRY_OFF_NAME + ENTRY_NAME_LEN))
				if name != "." and name != "..":
					var e := Entry.new()
					e.name = name
					e.is_dir = entry_type == ENTRY_TYPE_FOLDER
					e._offset = _le_u32(raw, ENTRY_OFF_POSITION)
					e.size = _le_u32(raw, ENTRY_OFF_SIZE)
					out.append(e)
			if i == ENTRIES_PER_BLOCK - 1:
				next_offset = _le_u32(raw, ENTRY_OFF_NEXT_BLOCK)

		if next_offset == 0:
			break
		offset = next_offset

	_dir_cache[cache_key] = out
	return out

## Returns the bytes up to (not including) the first NUL, decoded as ASCII.
## Reused directory-entry slots can carry stale bytes after a still-valid
## NUL terminator, so trimming only trailing NULs isn't enough.
func _null_terminated(b: PackedByteArray) -> String:
	var nul_at := b.find(0)
	if nul_at >= 0:
		b = b.slice(0, nul_at)
	return b.get_string_from_ascii()

## Decrypts one directory block in place. The reference client's Blowfish
## usage here isn't quite textbook ECB: each 4-byte half of every 8-byte
## block is byte-order-reversed before being handed to a standard
## (big-endian) Blowfish block decrypt, and reversed back on the way out --
## equivalent to the client treating each half as a little-endian, rather
## than big-endian, 32-bit word. Verified against a real archive's
## directory table. See docs/protocol/PK2_FORMAT.md.
func _decrypt_block_pk2(data: PackedByteArray) -> void:
	var off := 0
	while off + 8 <= data.size():
		var swapped := PackedByteArray()
		swapped.resize(8)
		swapped[0] = data[off + 3]
		swapped[1] = data[off + 2]
		swapped[2] = data[off + 1]
		swapped[3] = data[off + 0]
		swapped[4] = data[off + 7]
		swapped[5] = data[off + 6]
		swapped[6] = data[off + 5]
		swapped[7] = data[off + 4]
		var out := _cipher.decrypt_block(swapped)
		data[off + 0] = out[3]
		data[off + 1] = out[2]
		data[off + 2] = out[1]
		data[off + 3] = out[0]
		data[off + 4] = out[7]
		data[off + 5] = out[6]
		data[off + 6] = out[5]
		data[off + 7] = out[4]
		off += 8

func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
