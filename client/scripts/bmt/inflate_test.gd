extends SceneTree

## Exercises Inflate directly against known-good raw DEFLATE streams
## (generated once via Python's zlib, an independent implementation -- see
## inflate.gd for why Godot's own decompressor isn't trusted here), run
## headless: `godot4 --headless --path client --script res://scripts/bmt/inflate_test.gd`

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	# "Hello, DEFLATE world! Hello, DEFLATE world!" compressed with Python's
	# zlib at compresslevel=9 (raw deflate, wbits=-15), verified to
	# decompress correctly with zlib itself before being hardcoded here.
	var plain := "Hello, DEFLATE world! Hello, DEFLATE world!"
	var compressed_hex := "f348cdc9c9d751707175f3710c715528cf2fca495154f0c0260a00"
	var out := Inflate.inflate(compressed_hex.hex_decode())
	_check(out.get_string_from_ascii() == plain, "decodes a small repeating fixed/dynamic-Huffman stream (got %s)" % out.get_string_from_ascii())

	# Highly repetitive input forces long length/distance back-references,
	# exercising the LZ77 copy loop with distance > current chunk size.
	var repeated := "abcdefgh".repeat(50)
	var repeated_hex := "4b4c4a4e494d4bcf481ca507050d00"
	var out2 := Inflate.inflate(repeated_hex.hex_decode())
	_check(out2.get_string_from_ascii() == repeated, "decodes a long back-reference run (got %d bytes, want %d)" % [out2.size(), repeated.length()])

	var garbage := PackedByteArray([0xFF, 0xFF, 0xFF, 0xFF])
	var out3 := Inflate.inflate(garbage)
	_check(out3.size() == 0, "returns empty on garbage input rather than crashing")

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
