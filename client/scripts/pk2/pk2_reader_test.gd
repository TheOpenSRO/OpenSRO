extends SceneTree

## Exercises Pk2Reader against synthetic archives (never real game data), run
## headless: `godot4 --headless --path client --script res://scripts/pk2/pk2_reader_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _write_entry(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE
	block[base] = entry_type
	var name_bytes := name.to_ascii_buffer()
	for j in range(name_bytes.size()):
		block[base + 0x01 + j] = name_bytes[j]
	block[base + 0x5A] = offset & 0xFF
	block[base + 0x5B] = (offset >> 8) & 0xFF
	block[base + 0x5C] = (offset >> 16) & 0xFF
	block[base + 0x5D] = (offset >> 24) & 0xFF
	block[base + 0x5E] = size & 0xFF
	block[base + 0x5F] = (size >> 8) & 0xFF
	block[base + 0x60] = (size >> 16) & 0xFF
	block[base + 0x61] = (size >> 24) & 0xFF

func _build_simple_archive(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer() # header[i] beyond this stays 0
	for i in range(magic.size()):
		header[i] = magic[i]
	# header[0x22] stays 0 => unencrypted

	var block := PackedByteArray()
	block.resize(Pk2Reader.BLOCK_SIZE)
	_write_entry(block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", Pk2Reader.HEADER_SIZE, 0)
	var file_data := "hello silkroad".to_ascii_buffer()
	var file_offset := Pk2Reader.HEADER_SIZE + Pk2Reader.BLOCK_SIZE
	_write_entry(block, 1, Pk2Reader.ENTRY_TYPE_FILE, "hello.txt", file_offset, file_data.size())

	f.store_buffer(header)
	f.store_buffer(block)
	f.store_buffer(file_data)
	f.close()

func _init() -> void:
	var path := "user://srrevamp_test.pk2"
	_build_simple_archive(path)

	var reader := Pk2Reader.open(path)
	_check(reader != null, "opens synthetic archive")

	var entries := reader.read_dir()
	_check(entries.size() == 1, "root dir has 1 entry (got %d)" % entries.size())
	if entries.size() == 1:
		_check(entries[0].name == "hello.txt", "entry name is hello.txt (got %s)" % entries[0].name)
		_check(not entries[0].is_dir, "entry is a file")
		var contents := reader.read_file(entries[0])
		_check(contents.get_string_from_ascii() == "hello silkroad", "file contents match (got %s)" % contents.get_string_from_ascii())

	reader.close()
	DirAccess.remove_absolute(path)

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
