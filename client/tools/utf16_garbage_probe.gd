extends SceneTree
## Round 760 (blocker 4): the engine path behind table_parity.gd's heap corruption on Godot 4.7.2.
##
## `PackedByteArray.get_string_from_utf16()` (String::append_utf16) sizes the String counting an
## unpaired LEAD surrogate as a character, then drops it when the next unit is a plain character,
## so the string's last character is never written: uninitialised heap memory (READ, 4.7.2
## core/string/ustring.cpp l. 2045-2122; 4.2.2 alike). String::utf8() sizes a character above
## 0x7FFFFFFF as 1 byte but writes 3 (the replacement character), and String::utf16() sizes one
## above 0x10FFFF as 1 unit but writes 2 (l. 1951-1953 against 2001-2006; l. 2148-2150 against
## 2172-2175): a heap overflow when that garbage is encoded (print, var_to_bytes, a GString handed
## to the native library, to_utf8_buffer, ...).
##
##   remote_godot.sh script res://tools/utf16_garbage_probe.gd -- [--rounds=N] [--encode=0|1] [--safe=0|1]
##
## `--safe=1` decodes through TextDecode.utf16 (the round's fix) instead. Prints how many decodes
## ended in a character no Unicode text has, and `UTF16 PROBE DONE` if it survived.
func _initialize() -> void:
	var rounds := 200000
	var encode := true
	var safe := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rounds="):
			rounds = int(a.substr(9))
		elif a.begins_with("--encode="):
			encode = a.substr(9) == "1"
		elif a.begins_with("--safe="):
			safe = a.substr(7) == "1"
	# FF FE, then "A", an unpaired lead surrogate, "B" -- the shape of decrypted-as-text garbage.
	var raw := PackedByteArray([0xFF, 0xFE, 0x41, 0x00, 0x00, 0xD8, 0x42, 0x00])
	var bad_over_10ffff := 0
	var bad_over_7fffffff := 0
	var lone := 0
	var lengths := {}
	# Some churn so the uninitialised slot lands on reused heap memory.
	var junk: Array = []
	for r in range(rounds):
		var s: String = TextDecode.utf16(raw) if safe else raw.slice(2).get_string_from_utf16() # text-decode: the probe's negative
		lengths[s.length()] = true
		for i in range(s.length()):
			var c := s.unicode_at(i)
			if c > 0x10FFFF or c < 0:
				bad_over_10ffff += 1
			if c > 0x7FFFFFFF or c < 0:
				bad_over_7fffffff += 1
			if c >= 0xD800 and c < 0xE000:
				lone += 1
		if encode:
			var _u8 := s.to_utf8_buffer()
			var _u16 := s.to_utf16_buffer()
		junk.append(str(r) + "xyzw")
		if junk.size() > 64:
			junk.clear()
	print("UTF16 PROBE %s safe=%s encode=%s rounds %d: lengths %s, chars > 0x10FFFF %d, > 0x7FFFFFFF %d, lone surrogates %d" % [
		Engine.get_version_info().string, safe, encode, rounds, str(lengths.keys()), bad_over_10ffff, bad_over_7fffffff, lone])
	print("UTF16 PROBE DONE")
	quit()
