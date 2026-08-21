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
		block[base + Pk2Reader.ENTRY_OFF_NAME + j] = name_bytes[j]
	var pos_base := base + Pk2Reader.ENTRY_OFF_POSITION
	block[pos_base] = offset & 0xFF
	block[pos_base + 1] = (offset >> 8) & 0xFF
	block[pos_base + 2] = (offset >> 16) & 0xFF
	block[pos_base + 3] = (offset >> 24) & 0xFF
	var size_base := base + Pk2Reader.ENTRY_OFF_SIZE
	block[size_base] = size & 0xFF
	block[size_base + 1] = (size >> 8) & 0xFF
	block[size_base + 2] = (size >> 16) & 0xFF
	block[size_base + 3] = (size >> 24) & 0xFF

func _write_next_block(block: PackedByteArray, i: int, next_offset: int) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE + Pk2Reader.ENTRY_OFF_NEXT_BLOCK
	block[base] = next_offset & 0xFF
	block[base + 1] = (next_offset >> 8) & 0xFF
	block[base + 2] = (next_offset >> 16) & 0xFF
	block[base + 3] = (next_offset >> 24) & 0xFF

## Builds a synthetic (never real game data) directory spanning two chained
## blocks -- the real client's own continuation mechanism (only the last
## entry slot of a block carries a next-block offset), confirmed
## empirically -- see docs/protocol/PK2_FORMAT.md.
func _build_chained_archive(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]

	var block1_offset := Pk2Reader.HEADER_SIZE
	var block2_offset := block1_offset + Pk2Reader.BLOCK_SIZE
	var file_offset := block2_offset + Pk2Reader.BLOCK_SIZE

	var block1 := PackedByteArray()
	block1.resize(Pk2Reader.BLOCK_SIZE)
	_write_entry(block1, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", block1_offset, 0)
	for i in range(1, Pk2Reader.ENTRIES_PER_BLOCK):
		_write_entry(block1, i, Pk2Reader.ENTRY_TYPE_FILE, "block1_file%02d.txt" % i, file_offset, 4)
	_write_next_block(block1, Pk2Reader.ENTRIES_PER_BLOCK - 1, block2_offset)

	var block2 := PackedByteArray()
	block2.resize(Pk2Reader.BLOCK_SIZE)
	_write_entry(block2, 0, Pk2Reader.ENTRY_TYPE_FILE, "block2_file00.txt", file_offset, 4)
	_write_entry(block2, 1, Pk2Reader.ENTRY_TYPE_FILE, "block2_file01.txt", file_offset, 4)
	# Remaining slots stay empty; block 2's own last slot's next-block
	# field is left at 0, correctly signaling "no more blocks".

	f.store_buffer(header)
	f.store_buffer(block1)
	f.store_buffer(block2)
	f.store_buffer("data".to_ascii_buffer())
	f.close()

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

	var chained_path := "user://srrevamp_chained_test.pk2"
	_build_chained_archive(chained_path)
	var chained_reader := Pk2Reader.open(chained_path)
	_check(chained_reader != null, "opens synthetic chained archive")
	if chained_reader != null:
		var chained_entries := chained_reader.read_dir()
		var want := Pk2Reader.ENTRIES_PER_BLOCK - 1 + 2
		_check(chained_entries.size() == want, "root dir spans both chained blocks (want %d, got %d)" % [want, chained_entries.size()])
		var names := {}
		for e in chained_entries:
			names[e.name] = true
		_check(names.has("block1_file01.txt") and names.has("block2_file00.txt") and names.has("block2_file01.txt"), "entries from both blocks present")
		chained_reader.close()
	DirAccess.remove_absolute(chained_path)

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
