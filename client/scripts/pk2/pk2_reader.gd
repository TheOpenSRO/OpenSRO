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

# See docs/protocol/PK2_FORMAT.md: long-published default key for the
# format's directory-table obfuscation, not a secret protecting first-party
# asset bytes.
const DEFAULT_KEY := "169841"

class Entry:
	var name: String
	var is_dir: bool
	var size: int
	var _offset: int

var _file: FileAccess
var _encrypted: bool
var _cipher: Blowfish
var _root_offset: int

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
		reader._cipher = Blowfish.new(DEFAULT_KEY.to_ascii_buffer())
	return reader

func close() -> void:
	if _file != null:
		_file.close()

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
	_file.seek(file._offset)
	return _file.get_buffer(file.size)

func _read_block_chain(start_offset: int) -> Array[Entry]:
	var out: Array[Entry] = []
	var offset := start_offset

	while offset != 0:
		_file.seek(offset)
		var block := _file.get_buffer(BLOCK_SIZE)
		if _encrypted:
			_cipher.decrypt_ecb_in_place(block)

		var next := 0
		for i in range(ENTRIES_PER_BLOCK):
			var raw := block.slice(i * ENTRY_SIZE, (i + 1) * ENTRY_SIZE)
			var entry_type := raw[0]

			if entry_type == ENTRY_TYPE_FOLDER or entry_type == ENTRY_TYPE_FILE:
				var name := raw.slice(0x01, 0x01 + 81).get_string_from_ascii().rstrip(char(0))
				if name != "." and name != "..":
					var e := Entry.new()
					e.name = name
					e.is_dir = entry_type == ENTRY_TYPE_FOLDER
					e._offset = _le_u32(raw, 0x5A)
					e.size = _le_u32(raw, 0x5E)
					out.append(e)

			# Last slot of the block carries the next-block pointer for this
			# directory's chain (0 = end of chain). See
			# docs/protocol/PK2_FORMAT.md and server/internal/pk2/pk2.go.
			if i == ENTRIES_PER_BLOCK - 1:
				next = _le_u64(raw, 0x62)

		offset = next

	return out

func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)

func _le_u64(b: PackedByteArray, off: int) -> int:
	var lo := _le_u32(b, off)
	var hi := _le_u32(b, off + 4)
	return lo | (hi << 32)
