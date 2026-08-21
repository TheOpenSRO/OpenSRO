extends RefCounted
class_name AssetSource

## Small helper for loading a real asset file from either of the two real
## places this project has found them: a loose file on disk (every real
## .bsk/.ban sample found during reverse-engineering was a loose file, not
## packed in any pk2 -- see docs/protocol/BSK_FORMAT.md), or a path inside
## an already-open pk2 archive (where .bms/.bsr/.bmt/.ddj live). Lets a
## single path value work either way without the caller needing to know
## which kind of source it's dealing with.

## Tries path as a loose file first; if that fails and archive is not
## null, tries it as a path inside archive instead. Returns an empty
## PackedByteArray if path is empty or neither source has it.
static func read_bytes(path: String, archive: Pk2Reader = null) -> PackedByteArray:
	if path == "":
		return PackedByteArray()

	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		return f.get_buffer(f.get_length())

	if archive != null:
		var entry := ObjectLoader.find_file(archive, path)
		if entry != null:
			return archive.read_file(entry)

	return PackedByteArray()
