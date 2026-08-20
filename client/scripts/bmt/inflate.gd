extends RefCounted
class_name Inflate

## A from-scratch, standalone RFC 1951 (DEFLATE) decompressor in pure
## GDScript. Exists because Godot's own built-in
## PackedByteArray.decompress(..., FileAccess.COMPRESSION_DEFLATE) was
## confirmed to fail (returns 0 bytes, "Condition err != 1") on at least one
## real, valid zlib-compressed stream (a real .bmt file) that a standard
## zlib implementation decodes correctly -- likely a correctness gap in the
## engine's bundled decompressor for some class of valid DEFLATE streams,
## not anything about the file being malformed. See docs/protocol/
## BMT_FORMAT.md and bmt_reader.gd, the only current caller.
##
## Implements only decompression (inflate), only what .bmt needs: stored,
## fixed-Huffman, and dynamic-Huffman blocks per RFC 1951 section 3.2.

class BitReader:
	var data: PackedByteArray
	var byte_pos: int = 0
	var bit_pos: int = 0 # 0-7, next bit to read within data[byte_pos], LSB-first

	func _init(d: PackedByteArray) -> void:
		data = d

	func read_bit() -> int:
		if byte_pos >= data.size():
			return -1
		var bit := (data[byte_pos] >> bit_pos) & 1
		bit_pos += 1
		if bit_pos == 8:
			bit_pos = 0
			byte_pos += 1
		return bit

	## Reads n bits, LSB-first, returning them as an integer with the first
	## bit read as the least-significant bit (DEFLATE's convention for
	## multi-bit values other than Huffman codes).
	func read_bits(n: int) -> int:
		var v := 0
		for i in range(n):
			v |= read_bit() << i
		return v

	func align_to_byte() -> void:
		if bit_pos != 0:
			bit_pos = 0
			byte_pos += 1

## A canonical Huffman decoder built from a list of code lengths (one per
## symbol, 0 = symbol unused), per RFC 1951 section 3.2.2.
class HuffmanTable:
	# Maps "code as int" -> symbol, keyed per code length, for simplicity
	# (not the fastest approach, but .bmt files are tiny).
	var _codes_by_length: Dictionary = {} # length(int) -> Dictionary(code(int) -> symbol(int))
	var _max_length: int = 0

	func _init(code_lengths: Array) -> void:
		var max_len := 0
		for l in code_lengths:
			if l > max_len:
				max_len = l
		_max_length = max_len
		if max_len == 0:
			return

		var length_count := {}
		for l in code_lengths:
			if l > 0:
				length_count[l] = length_count.get(l, 0) + 1

		var code := 0
		var next_code := {}
		for length in range(1, max_len + 1):
			code = (code + length_count.get(length - 1, 0)) << 1
			next_code[length] = code

		for symbol in range(code_lengths.size()):
			var length: int = code_lengths[symbol]
			if length == 0:
				continue
			var c: int = next_code[length]
			next_code[length] += 1
			if not _codes_by_length.has(length):
				_codes_by_length[length] = {}
			_codes_by_length[length][c] = symbol

	## Reads one Huffman-coded symbol from br. Huffman codes are read
	## MSB-first (unlike other DEFLATE fields), per spec.
	func read_symbol(br: BitReader) -> int:
		var code := 0
		for length in range(1, _max_length + 1):
			code = (code << 1) | br.read_bit()
			if _codes_by_length.has(length) and _codes_by_length[length].has(code):
				return _codes_by_length[length][code]
		return -1 # malformed stream


const LENGTH_BASE := [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
const LENGTH_EXTRA_BITS := [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
const DIST_BASE := [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
const DIST_EXTRA_BITS := [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
const CODE_LENGTH_ORDER := [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

## Inflates raw DEFLATE-compressed data (no zlib/gzip wrapper). Returns an
## empty PackedByteArray on a malformed stream.
static func inflate(compressed: PackedByteArray) -> PackedByteArray:
	var br := BitReader.new(compressed)
	var out := PackedByteArray()

	while true:
		var bfinal := br.read_bit()
		var btype := br.read_bits(2)
		if bfinal < 0 or btype < 0:
			return PackedByteArray() # truncated stream

		if btype == 0:
			_inflate_stored(br, out)
		elif btype == 1:
			var tables := _fixed_huffman_tables()
			if not _inflate_block(br, out, tables[0], tables[1]):
				return PackedByteArray()
		elif btype == 2:
			var tables := _read_dynamic_huffman_tables(br)
			if tables.is_empty():
				return PackedByteArray()
			if not _inflate_block(br, out, tables[0], tables[1]):
				return PackedByteArray()
		else:
			return PackedByteArray() # btype == 3 is reserved/invalid

		if bfinal == 1:
			break

	return out

static func _inflate_stored(br: BitReader, out: PackedByteArray) -> void:
	br.align_to_byte()
	var len_lo := br.data[br.byte_pos] if br.byte_pos < br.data.size() else 0
	var len_hi := br.data[br.byte_pos + 1] if br.byte_pos + 1 < br.data.size() else 0
	var length := len_lo | (len_hi << 8)
	br.byte_pos += 4 # LEN (2 bytes) + NLEN (2 bytes, ~LEN, unchecked here)
	for i in range(length):
		out.append(br.data[br.byte_pos + i])
	br.byte_pos += length

static func _fixed_huffman_tables() -> Array:
	var lit_lengths := []
	lit_lengths.resize(288)
	for i in range(288):
		if i <= 143:
			lit_lengths[i] = 8
		elif i <= 255:
			lit_lengths[i] = 9
		elif i <= 279:
			lit_lengths[i] = 7
		else:
			lit_lengths[i] = 8
	var dist_lengths := []
	dist_lengths.resize(30)
	for i in range(30):
		dist_lengths[i] = 5
	return [HuffmanTable.new(lit_lengths), HuffmanTable.new(dist_lengths)]

static func _read_dynamic_huffman_tables(br: BitReader) -> Array:
	var hlit := br.read_bits(5) + 257
	var hdist := br.read_bits(5) + 1
	var hclen := br.read_bits(4) + 4

	var cl_lengths := []
	cl_lengths.resize(19)
	for i in range(19):
		cl_lengths[i] = 0
	for i in range(hclen):
		cl_lengths[CODE_LENGTH_ORDER[i]] = br.read_bits(3)
	var cl_table := HuffmanTable.new(cl_lengths)

	var all_lengths := []
	while all_lengths.size() < hlit + hdist:
		var sym := cl_table.read_symbol(br)
		if sym < 0:
			return []
		if sym < 16:
			all_lengths.append(sym)
		elif sym == 16:
			if all_lengths.is_empty():
				return []
			var prev = all_lengths[all_lengths.size() - 1]
			var repeat := br.read_bits(2) + 3
			for _i in range(repeat):
				all_lengths.append(prev)
		elif sym == 17:
			var repeat := br.read_bits(3) + 3
			for _i in range(repeat):
				all_lengths.append(0)
		else: # sym == 18
			var repeat := br.read_bits(7) + 11
			for _i in range(repeat):
				all_lengths.append(0)

	var lit_lengths: Array = all_lengths.slice(0, hlit)
	var dist_lengths: Array = all_lengths.slice(hlit, hlit + hdist)
	return [HuffmanTable.new(lit_lengths), HuffmanTable.new(dist_lengths)]

static func _inflate_block(br: BitReader, out: PackedByteArray, lit_table: HuffmanTable, dist_table: HuffmanTable) -> bool:
	while true:
		var sym := lit_table.read_symbol(br)
		if sym < 0:
			return false
		if sym < 256:
			out.append(sym)
		elif sym == 256:
			return true # end of block
		else:
			var idx := sym - 257
			if idx < 0 or idx >= LENGTH_BASE.size():
				return false
			var length: int = LENGTH_BASE[idx] + br.read_bits(LENGTH_EXTRA_BITS[idx])
			var dist_sym := dist_table.read_symbol(br)
			if dist_sym < 0 or dist_sym >= DIST_BASE.size():
				return false
			var distance: int = DIST_BASE[dist_sym] + br.read_bits(DIST_EXTRA_BITS[dist_sym])
			var start: int = out.size() - distance
			if start < 0:
				return false
			for i in range(length):
				out.append(out[start + i])
	return false
