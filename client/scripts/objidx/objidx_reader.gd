extends RefCounted
class_name ObjidxReader

## Read-only parser for .ifo (JMXVOBJI) object-index tables -- the real
## answer to a long-standing open question in this project: what a
## .mapo region-file's per-placement type ID actually resolves to. See
## docs/protocol/MAPO_FORMAT.md for the full derivation (found by browsing
## a real Data.pk2 after fixing Pk2Reader's directory-chain bug, then
## confirmed by cross-checking real .mapo type IDs from a real region
## against this table and getting real, sensible scenery paths back).
## Mirrors server/internal/objidx's Go implementation; keep the two in
## sync if the format understanding changes.
##
## Unlike every other JMXV*-prefixed format in this project, .ifo is not a
## binary container: after the magic line, it's a plain ASCII text table,
## one real object type per line.

const MAGIC := "JMXVOBJI1000"

## One real object type: a real, resolvable .bsr resource path
## (Windows-style backslashes, as stored -- resolve case-insensitively
## against a real archive, same as every other real path in this
## project), plus an unconfirmed per-entry flags word (observed values
## seen so far: 0 and 1; not decompiled, meaning not yet promoted past
## "raw flags").
class Entry:
	var type_id: int
	var flags: int
	var path: String

## Parsed .ifo object-index. entries is indexed by type_id directly
## (confirmed real: every real file checked has entries in strict
## sequential order starting at 0, so type_id always equals its own array
## index) -- lookup() still bounds-checks rather than assuming that holds
## for every possible real file.
class Table:
	var entries: Array[Entry] = []

	## Returns the real entry for type_id (as found in a real .mapo
	## placement record), or null if type_id is out of range for this
	## table.
	func lookup(type_id: int) -> Entry:
		if type_id < 0 or type_id >= entries.size():
			return null
		var e := entries[type_id]
		if e.type_id != type_id:
			return null
		return e

## Parses a real .ifo file's raw bytes. Returns null (and pushes an
## error) if the magic line, declared count, or any record line doesn't
## match the real, confirmed format: "JMXVOBJI1000\n<count>\n" followed
## by exactly <count> lines shaped "%05d 0x%08x \"<path>\"".
static func parse(data: PackedByteArray) -> Table:
	var _pp := ParseProfile.t0()
	var _out: Table = _pp_parse(data)
	ParseProfile.add("objidx.parse", _pp)
	return _out

## The body of parse, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse(data: PackedByteArray) -> Table:
	var text := data.get_string_from_ascii()
	var lines := text.split("\n")
	if lines.size() < 2:
		push_error("objidx: file too short to contain a header")
		return null
	if lines[0] != MAGIC:
		push_error("objidx: bad magic %s, want %s" % [lines[0], MAGIC])
		return null

	if not lines[1].strip_edges().is_valid_int():
		push_error("objidx: bad count line %s" % lines[1])
		return null
	var count := lines[1].strip_edges().to_int()
	if count < 0:
		push_error("objidx: bad count line %s" % lines[1])
		return null
	if lines.size() < 2 + count:
		push_error("objidx: declared %d records but file only has %d body lines" % [count, lines.size() - 2])
		return null

	var table := Table.new()
	for i in range(count):
		var e := _parse_line(lines[2 + i])
		if e == null:
			push_error("objidx: record %d: malformed line %s" % [i, lines[2 + i]])
			return null
		table.entries.append(e)

	return table

static func _parse_line(line: String) -> Entry:
	# Real shape: "%05d 0x%08X \"<path>\"" -- three space-separated
	# fields, the third quoted (a real path can't itself contain a
	# literal double-quote in any file checked, so a naive split-on-quote
	# is sufficient rather than needing real escape handling).
	var first_space := line.find(" ")
	if first_space < 0:
		return null
	var id_field := line.substr(0, first_space)
	if not id_field.is_valid_int():
		return null

	var rest := line.substr(first_space + 1)
	var second_space := rest.find(" ")
	if second_space < 0:
		return null
	var flags_field := rest.substr(0, second_space)
	if not flags_field.begins_with("0x"):
		return null
	var flags_hex := flags_field.substr(2)
	if not flags_hex.is_valid_hex_number():
		return null

	var path_field := rest.substr(second_space + 1).strip_edges()
	if path_field.length() < 2 or path_field[0] != "\"" or path_field[path_field.length() - 1] != "\"":
		return null

	var e := Entry.new()
	e.type_id = id_field.to_int()
	e.flags = flags_hex.hex_to_int()
	e.path = path_field.substr(1, path_field.length() - 2)
	return e
