extends SceneTree

## Exercises AssetSource against a synthetic loose file and a synthetic pk2
## archive (never real game data), run headless:
## `godot4 --headless --path client --script res://scripts/assets/asset_source_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## Writes a minimal, unencrypted, synthetic pk2 archive (never real game
## data) with one root-level file, "testfile.bin".
func _build_minimal_archive(path: String) -> void:
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in range(magic.size()):
		header[i] = magic[i]
	# header[0x22] left 0 -- unencrypted.

	var file_data := PackedByteArray([5, 6, 7, 8, 9])
	var root_off := Pk2Reader.HEADER_SIZE
	var file_off := root_off + Pk2Reader.BLOCK_SIZE

	var root_block := PackedByteArray()
	root_block.resize(Pk2Reader.BLOCK_SIZE)

	var write_entry := func(block: PackedByteArray, i: int, entry_type: int, name: String, offset: int, size: int) -> void:
		var base := i * Pk2Reader.ENTRY_SIZE
		block[base] = entry_type
		var nb := name.to_ascii_buffer()
		for j in range(nb.size()):
			block[base + Pk2Reader.ENTRY_OFF_NAME + j] = nb[j]
		var pos_base := base + Pk2Reader.ENTRY_OFF_POSITION
		for j in range(4):
			block[pos_base + j] = (offset >> (8 * j)) & 0xFF
		var size_base := base + Pk2Reader.ENTRY_OFF_SIZE
		for j in range(4):
			block[size_base + j] = (size >> (8 * j)) & 0xFF

	write_entry.call(root_block, 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", root_off, 0)
	write_entry.call(root_block, 1, Pk2Reader.ENTRY_TYPE_FILE, "testfile.bin", file_off, file_data.size())

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	f.store_buffer(root_block)
	f.store_buffer(file_data)
	f.close()

func _init() -> void:
	# Loose file.
	var loose_path := "user://asset_source_test_loose.bin"
	var f := FileAccess.open(loose_path, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([1, 2, 3, 4]))
	f.close()

	var loose_result := AssetSource.read_bytes(loose_path)
	_check(loose_result == PackedByteArray([1, 2, 3, 4]), "reads a real loose file (got %s)" % [loose_result])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(loose_path))

	_check(AssetSource.read_bytes("").is_empty(), "empty path returns empty bytes")
	_check(AssetSource.read_bytes("user://definitely_does_not_exist.bin").is_empty(), "nonexistent loose path returns empty bytes")

	# In-archive fallback: a path that isn't a real loose file, but exists
	# inside a synthetic pk2 archive.
	var archive_path := "user://asset_source_test.pk2"
	_build_minimal_archive(archive_path)
	var archive := Pk2Reader.open(archive_path)
	_check(archive != null, "opens the synthetic archive")
	if archive != null:
		var found := AssetSource.read_bytes("testfile.bin", archive)
		_check(found == PackedByteArray([5, 6, 7, 8, 9]), "falls back to reading a real path inside the archive (got %s)" % [found])
		var missing := AssetSource.read_bytes("nope.bin", archive)
		_check(missing.is_empty(), "a path missing from both loose disk and the archive returns empty bytes")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(archive_path))

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
