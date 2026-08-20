extends RefCounted
class_name BskReader

## Read-only parser for the .bsk (JMXVBSK) skeleton format.
## See docs/protocol/BSK_FORMAT.md for the on-disk layout. Mirrors
## server/internal/bsk's Go implementation; keep the two in sync if the
## format understanding changes.

const MAGIC := "JMXVBSK 0101"
const MAGIC_LEN := 12
const ROOT_TRANSFORM_LEN := 92 # root, and any bone using the parent-less "Type A" record shape
const BONE_TRANSFORM_LEN := 88 # the ordinary "Type B" record shape (explicit parent name field)
const MAX_NAME_LEN := 60

class Bone:
	var bone_name: String
	## Empty only for bones using the parent-less, 92-byte record shape
	## (see transform) -- every other bone has an explicit parent name in
	## its own record, which is the only reliable source of truth for the
	## tree structure. A bone's name can be *announced* far earlier in the
	## file than its real record appears, and the announcing position does
	## not reliably indicate the real parent -- see
	## docs/protocol/BSK_FORMAT.md.
	var parent_name: String
	## 88 raw bytes (ordinary bones, explicit parent_name) or 92 (bones
	## with no parent_name) -- check transform.size() or parent_name to
	## tell them apart. See docs/protocol/BSK_FORMAT.md for the
	## confirmed-but-not-fully-labeled float layout (two unit quaternions,
	## one the conjugate of the other, plus two position vectors).
	var transform: PackedByteArray

class ParsedSkeleton:
	var root_name: String
	var bones: Array[Bone] = []

## Parses a .bsk file's raw bytes. Returns null (and pushes an error) on
## failure.
##
## The bone list isn't a simple linear scan: every bone name in the file is
## first *announced* (a bare length-prefixed name with nothing recognizable
## immediately after it) and later *resolved* -- the same name reappears,
## this time followed by its real record. An announcement's resolution can
## be immediately next (the common case for a bone with no further nested
## announcements), or thousands of bytes later, after many other bones'
## announcements and resolutions have interleaved -- real files were checked
## with both. There's no distinct "alias table" as earlier analysis in this
## project assumed; what looked like one is just every real file's opening
## run of announcements before the first resolution, the same mechanism
## applied everywhere else in the file.
##
## A resolution can take one of two shapes, and -- confirmed on real Biped
## files -- both can appear within the same file, decided per-bone, not
## per-file:
## - Type A: no parent name, straight into a 92-byte transform.
## - Type B: a parent name, then an 88-byte transform.
## There's no tag saying which shape applies; the reader tries Type A first
## and accepts it only if what immediately follows looks like a valid next
## token (or the file's constant 8-byte trailer) -- otherwise it falls back
## to Type B. Verified against 8 real files (2 distinct skeleton styles,
## 38-265 bones each): every one parses to completion with zero leftover
## announcements and lands exactly on the trailer.
static func parse(data: PackedByteArray) -> ParsedSkeleton:
	if data.size() < MAGIC_LEN + 5:
		push_error("bsk: file too small to contain a header")
		return null
	var magic := data.slice(0, MAGIC_LEN).get_string_from_ascii()
	if magic != MAGIC:
		push_error("bsk: bad magic %s, want %s" % [magic, MAGIC])
		return null

	var root_result = _read_len_prefixed_string(data, MAGIC_LEN + 5)
	if root_result == null:
		push_error("bsk: reading root name")
		return null
	var off: int = root_result[1]
	if off + ROOT_TRANSFORM_LEN > data.size():
		push_error("bsk: truncated before root transform")
		return null
	off += ROOT_TRANSFORM_LEN

	var s := ParsedSkeleton.new()
	s.root_name = root_result[0]
	var pending := {}

	while off < data.size():
		var n1 = _read_len_prefixed_string_flex(data, off)
		if n1 == null:
			break # the constant zero trailer, or truncation
		var name: String = n1[0]
		var next: int = n1[1]

		if pending.has(name):
			pending.erase(name)
			var resolved = _resolve_bone(data, name, next)
			if resolved == null:
				push_error("bsk: resolving bone %s" % name)
				return null
			s.bones.append(resolved[0])
			off = resolved[1]
			continue

		# Not a pending announcement being resolved -- check whether this
		# is the common case of a bone resolving immediately (its name is
		# repeated right away, with no other announcements interleaved).
		var n2 = _read_len_prefixed_string_flex(data, next)
		if n2 != null and n2[0] == name:
			var resolved2 = _resolve_bone(data, name, n2[1])
			if resolved2 == null:
				push_error("bsk: resolving bone %s" % name)
				return null
			s.bones.append(resolved2[0])
			off = resolved2[1]
			continue

		pending[name] = true
		off = next

	if not pending.is_empty():
		push_error("bsk: %d bone name(s) announced but never resolved: %s" % [pending.size(), pending.keys()])
		return null
	if s.bones.is_empty():
		push_error("bsk: no bones parsed")
		return null

	return s

## Reads a bone's record starting right after its resolving name
## occurrence, trying the parent-less "Type A" shape first and falling back
## to the with-parent "Type B" shape -- see parse()'s doc comment. Returns
## [Bone, next_offset] or null.
static func _resolve_bone(data: PackedByteArray, name: String, off: int):
	var a_end := off + ROOT_TRANSFORM_LEN
	if a_end <= data.size() and _looks_synced(data, a_end):
		var b := Bone.new()
		b.bone_name = name
		b.transform = data.slice(off, a_end)
		return [b, a_end]

	var n3 = _read_len_prefixed_string_flex(data, off)
	if n3 == null:
		return null
	var parent: String = n3[0]
	var parent_end: int = n3[1]
	var b_end := parent_end + BONE_TRANSFORM_LEN
	if b_end > data.size():
		return null
	var b := Bone.new()
	b.bone_name = name
	b.parent_name = parent
	b.transform = data.slice(parent_end, b_end)
	return [b, b_end]

## Reports whether off is a plausible boundary between two records: either
## the file's constant 8-byte trailer starts there, or a valid
## length-prefixed name can be read from there.
static func _looks_synced(data: PackedByteArray, off: int) -> bool:
	if off + 8 == data.size():
		return true
	return _read_len_prefixed_string_flex(data, off) != null

static func _read_len_prefixed_string(data: PackedByteArray, off: int):
	if off + 4 > data.size():
		return null
	var n := _le_u32(data, off)
	off += 4
	if n <= 0 or n > MAX_NAME_LEN or off + n > data.size():
		return null
	var s := data.slice(off, off + n)
	for c in s:
		var ok := (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) \
			or c == 40 or c == 41 or c == 91 or c == 93 or c == 95 or c == 45 or c == 32
		if not ok:
			return null
	return [s.get_string_from_ascii(), off + n]

## Tries off directly, then off+1 -- real files were seen with both a
## 0-byte and a 1-byte gap before a name depending on what precedes it.
static func _read_len_prefixed_string_flex(data: PackedByteArray, off: int):
	var r = _read_len_prefixed_string(data, off)
	if r != null:
		return r
	return _read_len_prefixed_string(data, off + 1)

static func _le_u32(b: PackedByteArray, off: int) -> int:
	return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
