extends RefCounted
class_name Blowfish

## Minimal Blowfish-ECB cipher. Blowfish is a public-domain block cipher
## (Bruce Schneier, 1993). Needed to read the pk2 (JMXVFS) container format's
## directory-entry obfuscation — see docs/protocol/PK2_FORMAT.md. Decrypt-only:
## this project never re-encrypts a pk2's directory table.
##
## Standard 64-bit Blowfish arithmetic doesn't fit GDScript's signed 64-bit
## int cleanly at the top bit, so every intermediate value is masked to
## MASK32 after each operation to stay within unsigned-32-bit semantics.

const MASK32 := 0xFFFFFFFF

var _p: PackedInt64Array
var _s: Array # Array of 4 PackedInt64Array, 256 entries each

func _init(key: PackedByteArray) -> void:
	_p = PackedInt64Array(BlowfishConstants.P_INIT)
	_s = [
		PackedInt64Array(BlowfishConstants.S0_INIT),
		PackedInt64Array(BlowfishConstants.S1_INIT),
		PackedInt64Array(BlowfishConstants.S2_INIT),
		PackedInt64Array(BlowfishConstants.S3_INIT),
	]
	_expand_key(key)

func _expand_key(key: PackedByteArray) -> void:
	assert(key.size() > 0, "Blowfish key must not be empty")

	var j := 0
	for i in range(18):
		var d := 0
		for _k in range(4):
			d = ((d << 8) | key[j]) & MASK32
			j = (j + 1) % key.size()
		_p[i] = (_p[i] ^ d) & MASK32

	var lr := [0, 0]
	for i in range(0, 18, 2):
		_encrypt_block(lr)
		_p[i] = lr[0]
		_p[i + 1] = lr[1]

	for box in range(4):
		for i in range(0, 256, 2):
			_encrypt_block(lr)
			_s[box][i] = lr[0]
			_s[box][i + 1] = lr[1]

func _f(x: int) -> int:
	var a := (x >> 24) & 0xFF
	var b := (x >> 16) & 0xFF
	var c := (x >> 8) & 0xFF
	var d := x & 0xFF
	return ((( _s[0][a] + _s[1][b]) & MASK32) ^ _s[2][c]) + _s[3][d] & MASK32

# lr is a 2-element array [L, R], mutated in place.
func _encrypt_block(lr: Array) -> void:
	var l: int = lr[0]
	var r: int = lr[1]
	for i in range(0, 16, 2):
		l = (l ^ _p[i]) & MASK32
		r = (r ^ _f(l)) & MASK32
		r = (r ^ _p[i + 1]) & MASK32
		l = (l ^ _f(r)) & MASK32
	l = (l ^ _p[16]) & MASK32
	r = (r ^ _p[17]) & MASK32
	lr[0] = r
	lr[1] = l

func _decrypt_block(lr: Array) -> void:
	var l: int = lr[0]
	var r: int = lr[1]
	for i in range(17, 1, -2):
		l = (l ^ _p[i]) & MASK32
		r = (r ^ _f(l)) & MASK32
		r = (r ^ _p[i - 1]) & MASK32
		l = (l ^ _f(r)) & MASK32
	l = (l ^ _p[1]) & MASK32
	r = (r ^ _p[0]) & MASK32
	lr[0] = r
	lr[1] = l

## Decrypts one 8-byte ECB block, returning a new 8-byte PackedByteArray.
func decrypt_block(data: PackedByteArray) -> PackedByteArray:
	assert(data.size() == 8, "Blowfish operates on 8-byte blocks")
	var lr := [_be_u32(data, 0), _be_u32(data, 4)]
	_decrypt_block(lr)
	var out := PackedByteArray()
	out.resize(8)
	_put_be_u32(out, 0, lr[0])
	_put_be_u32(out, 4, lr[1])
	return out

## Decrypts data in place, 8 bytes at a time, starting at byte offset
## `start`. len(data) - start must be a multiple of 8.
func decrypt_ecb_in_place(data: PackedByteArray, start: int = 0) -> void:
	var off := start
	while off + 8 <= data.size():
		var block := decrypt_block(data.slice(off, off + 8))
		for i in range(8):
			data[off + i] = block[i]
		off += 8

func _be_u32(b: PackedByteArray, off: int) -> int:
	return ((b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3]) & MASK32

func _put_be_u32(b: PackedByteArray, off: int, v: int) -> void:
	b[off] = (v >> 24) & 0xFF
	b[off + 1] = (v >> 16) & 0xFF
	b[off + 2] = (v >> 8) & 0xFF
	b[off + 3] = v & 0xFF
