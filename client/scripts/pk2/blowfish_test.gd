extends SceneTree

## Known-answer test for the Blowfish implementation in blowfish.gd, run
## headless: `godot4 --headless --path client --script res://scripts/pk2/blowfish_test.gd`
## Exits 0 and prints "ALL PASS" if every vector matches, exits 1 otherwise.
##
## Vectors were generated with golang.org/x/crypto/blowfish (an independent,
## widely-used reference implementation) rather than hand-copied from memory,
## so a mismatch here means our GDScript port has a bug, not a bad expected
## value.

func _hex_to_bytes(h: String) -> PackedByteArray:
	var out := PackedByteArray()
	for i in range(0, h.length(), 2):
		out.append(("0x" + h.substr(i, 2)).hex_to_int())
	return out

func _bytes_to_hex(b: PackedByteArray) -> String:
	var s := ""
	for byte in b:
		s += "%02x" % byte
	return s

func _init() -> void:
	var vectors := [
		["0000000000000000", "0000000000000000", "4ef997456198dd78"],
		["ffffffffffffffff", "ffffffffffffffff", "51866fd5b85ecb8a"],
		["3000000000000000", "1000000000000001", "7d856f9a613063f2"],
		["1111111111111111", "1111111111111111", "2466dd878b963c9d"],
		["0123456789abcdef", "1111111111111111", "61f9c3802281b096"],
		["fedcba9876543210", "0123456789abcdef", "0aceab0fc6a0a28d"],
		["7ca110454a1a6e57", "01a1d6d039776742", "59c68245eb05282b"],
		["0131d9619dc1376e", "5cd54ca83def57da", "b1b8cc0b250f09a0"],
		["169841", "48656c6c6f217878", "3422c5f34a212581"],
	]

	var ok := true
	for v in vectors:
		var key: PackedByteArray = _hex_to_bytes(v[0])
		var pt: PackedByteArray = _hex_to_bytes(v[1])
		var want: String = v[2]

		var bf := Blowfish.new(key)
		# We only implement decrypt (see blowfish.gd docstring), so verify by
		# decrypting the known ciphertext and checking we recover the known
		# plaintext — equivalent coverage to an encrypt test, exercising the
		# same key schedule and Feistel rounds.
		var ct: PackedByteArray = _hex_to_bytes(want)
		var got: PackedByteArray = bf.decrypt_block(ct)
		var got_hex := _bytes_to_hex(got)

		if got_hex != v[1]:
			print("FAIL key=%s: decrypt(%s) = %s, want %s" % [v[0], want, got_hex, v[1]])
			ok = false
		else:
			print("ok  key=%s" % v[0])

	if ok:
		print("ALL PASS")
		quit(0)
	else:
		print("FAILURES")
		quit(1)
