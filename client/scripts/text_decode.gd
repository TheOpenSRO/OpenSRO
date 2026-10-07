extends RefCounted
class_name TextDecode

## Round 760 (blocker 4 of the Godot 4.7.2 upgrade): UTF-16 bytes to a String
## without the engine's uninitialised character.
##
## **The engine bug (READ, Godot 4.7.2-stable core/string/ustring.cpp).**
## `PackedByteArray.get_string_from_utf16()` is String::append_utf16, which
## counts the characters in one pass and writes them in a second. The first
## pass counts an unpaired LEAD surrogate (U+D800..DBFF) as a character; the
## second drops it when the next unit is a plain character (l. 2053-2072
## against 2098-2113). So the String is one character longer than what is
## written and its last character is uninitialised heap memory (4.2.2 alike:
## round 671 saw "Invalid unicode codepoint (6db3bc40)"). Encoding such a
## character then overflows the heap: String::utf8() sizes a character above
## 0x7FFFFFFF as 1 byte and writes 3 (l. 1951-1953 / 2001-2006), String::utf16()
## sizes one above 0x10FFFF as 1 unit and writes 2 (l. 2148-2150 / 2172-2175).
## Any print, var_to_bytes, to_utf8_buffer or GString handed to the native
## library can do it. MEASURED round 760: tools/table_parity.gd aborted with
## `free(): invalid pointer` after reading the encrypted `skilldata_*enc.txt`
## (bytes that are no text) through the GDScript readers, and
## tools/utf16_garbage_probe.gd shows the garbage character directly.
##
## **The decode here:** every unpaired surrogate (lead or trail) is replaced
## by U+FFFD before the engine decodes, so the counting and the writing agree
## and the text holds no lone surrogate. Text with none (every plain table) is
## decoded exactly as get_string_from_utf16 decodes it, from the same bytes: a
## leading FEFF / FFFE byte-order mark, little-endian by default, the stop at
## the first NUL unit. The surrogates are found with PackedByteArray.find (a
## surrogate's high byte is 0xD8..0xDF), so a plain table costs eight scans in
## C++ and no per-unit GDScript loop.
##
## tests: text_decode_test.gd; text_decode_lint_test.gd holds every client
## script to it (no bare get_string_from_utf16).

const REPLACEMENT := 0xFFFD

## `data` decoded as get_string_from_utf16 would, with every unpaired surrogate
## read as U+FFFD.
static func utf16(data: PackedByteArray) -> String:
	return safe_utf16_bytes(data).get_string_from_utf16() # text-decode: the safe bytes

## `data` itself when it holds no unpaired surrogate, else a copy with each
## replaced by U+FFFD in the same byte order.
static func safe_utf16_bytes(data: PackedByteArray) -> PackedByteArray:
	var n := data.size() / 2
	if n == 0:
		return data
	var swapped := data[0] == 0xFE and data[1] == 0xFF
	var hi_byte := 0 if swapped else 1
	var units := PackedInt32Array()
	for b in range(0xD8, 0xE0):
		var at := data.find(b)
		while at >= 0 and at < n * 2:
			if (at & 1) == hi_byte:
				units.append(at >> 1)
			at = data.find(b, at + 1)
	if units.is_empty():
		return data
	units.sort()
	var bad := PackedInt32Array()
	var k := 0
	while k < units.size():
		var i := units[k]
		var u := _unit(data, i, swapped)
		if u < 0xDC00:
			# A lead: paired only with a trail right after it.
			if k + 1 < units.size() and units[k + 1] == i + 1 and _unit(data, i + 1, swapped) >= 0xDC00:
				k += 2
				continue
		bad.append(i)
		k += 1
	if bad.is_empty():
		return data
	var out := data.duplicate()
	for i in bad:
		if swapped:
			out[i * 2] = REPLACEMENT >> 8
			out[i * 2 + 1] = REPLACEMENT & 0xFF
		else:
			out[i * 2] = REPLACEMENT & 0xFF
			out[i * 2 + 1] = REPLACEMENT >> 8
	return out

static func _unit(data: PackedByteArray, i: int, swapped: bool) -> int:
	if swapped:
		return (data[i * 2] << 8) | data[i * 2 + 1]
	return data[i * 2] | (data[i * 2 + 1] << 8)
