extends RefCounted
class_name UpdateStager

## Unpacks a downloaded update into the staging folder, and refuses to go on
## unless every file arrived whole (round 668's review, H1). Nothing in the
## install is touched here: the installer's first rename happens only after
## stage() said ok.
##
## Why each check (READ, Godot 4.2.2):
## - FileAccess.store_buffer returns nothing, and a short fwrite on a full disk
##   only prints an ERROR (file_access_unix.cpp:257, file_access_windows.cpp:336),
##   so every staged file is reopened and its length compared;
## - ZIPReader.read_file returns an EMPTY array on a CRC, zlib or IO error
##   (zip_reader.cpp:98-124), which would otherwise be staged as a 0-byte file,
##   so every entry's data is compared with the size the zip's own central
##   directory records for it (ZIPReader does not expose it; zip_entry_sizes);
## - the SHA-256 check only covers the zip as downloaded.
## The review measured what happened without them, on a 120 MB tmpfs: every
## file "installed", the exe at 30.7 of 62.2 MB, three files at 0 bytes, and
## the next start crashed.
##
## The free-space margin on top of the unpacked size is OURS: room for the
## copy fallback and for the logs written meanwhile.
const SPACE_MARGIN := 32 * 1024 * 1024

var fs: UpdateFs
var lines := PackedStringArray()

func _init(p_fs: UpdateFs = null) -> void:
	fs = p_fs if p_fs != null else UpdateFs.new()

## {entry name: uncompressed size} from the zip's central directory, or {}
## when it cannot be read (no end record, a ZIP64 archive, a short file).
static func zip_entry_sizes(zip_path: String) -> Dictionary:
	var f := FileAccess.open(zip_path, FileAccess.READ)
	if f == null:
		return {}
	var length := f.get_length()
	var tail_len := mini(length, 65535 + 22)
	f.seek(length - tail_len)
	var tail := f.get_buffer(tail_len)
	var eocd := -1
	for i in range(tail.size() - 22, -1, -1):
		if tail.decode_u32(i) == 0x06054b50:
			eocd = i
			break
	if eocd < 0:
		return {}
	var count := tail.decode_u16(eocd + 10)
	var cd_size := tail.decode_u32(eocd + 12)
	var cd_offset := tail.decode_u32(eocd + 16)
	if count == 0xFFFF or cd_offset == 0xFFFFFFFF or cd_offset + cd_size > length:
		return {}
	f.seek(cd_offset)
	var cd := f.get_buffer(cd_size)
	var sizes := {}
	var at := 0
	for _n in range(count):
		if at + 46 > cd.size() or cd.decode_u32(at) != 0x02014b50:
			return {}
		var uncompressed := cd.decode_u32(at + 24)
		var name_len := cd.decode_u16(at + 28)
		var extra_len := cd.decode_u16(at + 30)
		var comment_len := cd.decode_u16(at + 32)
		if at + 46 + name_len > cd.size():
			return {}
		sizes[cd.slice(at + 46, at + 46 + name_len).get_string_from_utf8()] = uncompressed
		at += 46 + name_len + extra_len + comment_len
	return sizes

## "" when `left` bytes free are enough for `needed` bytes plus the margin,
## otherwise why not. A reported 0 is taken at its word: Godot answers 0 both
## for a full disk and for a failed query (dir_access_unix.cpp:476-480).
static func space_problem(needed: int, left: int) -> String:
	if left >= needed + SPACE_MARGIN:
		return ""
	return "not enough disk space next to the game: the update needs %.1f MB (plus %d MB to spare), %.1f MB is free" % [
		needed / 1048576.0, SPACE_MARGIN / 1048576, left / 1048576.0]

## Unpacks zip_path into staging_dir. Returns {ok, reason}. On failure the
## staging folder is gone and the install is untouched.
func stage(zip_path: String, staging_dir: String, space_dir: String) -> Dictionary:
	var sizes := zip_entry_sizes(zip_path)
	if sizes.is_empty():
		return _fail(staging_dir, "the downloaded archive's directory cannot be read")
	var needed := 0
	for name in sizes:
		needed += int(sizes[name])
	var space := space_problem(needed, fs.space_left(space_dir))
	# QA hook (OURS): skip the free-space check, so a test on a small disk
	# reaches the second line of defence, the read-back of every write.
	if space != "" and OS.get_environment("OPENSRO_QA_UPDATE_IGNORE_SPACE") == "1":
		lines.append("free-space check skipped (OPENSRO_QA_UPDATE_IGNORE_SPACE): " + space)
		space = ""
	if space != "":
		return _fail(staging_dir, space)
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return _fail(staging_dir, "could not open the downloaded archive")
	fs.make_dir(staging_dir)
	for name in reader.get_files():
		if name.ends_with("/"):
			continue
		var expected := int(sizes.get(name, -1))
		if expected < 0:
			reader.close()
			return _fail(staging_dir, "%s is not in the archive's directory" % name)
		var data := reader.read_file(name)
		if data.size() != expected:
			reader.close()
			return _fail(staging_dir, "%s came out of the archive as %d bytes, the archive says %d (damaged download?)" % [name, data.size(), expected])
		var dest := staging_dir.path_join(name)
		fs.make_dir(dest.get_base_dir())
		# Read the length back: a full disk cuts the write short without an
		# error reaching GDScript.
		if not fs.write_file(dest, data) or fs.size(dest) != data.size():
			fs.remove(dest)
			# Antivirus refusing the native library must not stop the rest of
			# the update: the installer reports it missing and keeps the old
			# one. Anything else -- a full disk above all -- is fatal.
			if UpdateInstaller.is_native_library(name):
				lines.append("could not unpack %s (blocked by antivirus?) -- updating the rest" % name)
				continue
			reader.close()
			return _fail(staging_dir, "could not write %s whole into the staging folder (disk full?)" % name)
	reader.close()
	return {"ok": true, "reason": ""}

func _fail(staging_dir: String, reason: String) -> Dictionary:
	fs.remove_tree(staging_dir)
	lines.append("refused: " + reason)
	return {"ok": false, "reason": reason}
