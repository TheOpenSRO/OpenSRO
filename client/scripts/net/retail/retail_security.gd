extends RefCounted
class_name RetailSecurity

## The original gateway protocol's per-connection security and framing
## (round 681), READ from the retail client's network engine and written up
## in docs/protocol/opcodes/handshake.md. server/internal/proto's
## retail_security.go and retail_frame.go are the same rules in Go, and the
## transcripts in frontend/testdata hold the two to identical bytes.
##
## The frame:  u16 size (bit 15 = encrypted) | u16 opcode | u8 count | u8 check
## | payload. A client fills count from the rolling byte and check from the
## checksum of the whole plain frame (check zero, the size word as sent),
## then encrypts bytes 2.. zero-padded to 8-byte blocks; a server's count and
## check are 0, and a client refuses anything else (sro_client 0x4b0d70,
## 0x4b0f60). Nothing here was copied from a binary: the checksum tables are
## generated from the public CRC-32 polynomial (docs/LEGAL.md policy #2).

const MASK32 := 0xFFFFFFFF
const ENCRYPTED := 0x8000
## READ for encrypted frames (0x4b0f60: error 0x800d past 0x1000); OURS for
## plain ones too.
const MAX_FRAME := 0x1000

const FLAG_NONE := 0x01
const FLAG_BLOWFISH := 0x02
const FLAG_SECURITY := 0x04
const FLAG_HANDSHAKE := 0x08
const FLAG_CHALLENGE := 0x10

## READ (0x4b0cf7): a count seed of 0 is replaced by this.
const DEFAULT_COUNT_SEED := 0x9abfb3b6

## The checksum table indices whose polynomial is NOT the standard CRC-32
## table's entry at that index. MEASURED (round 681): the client's list
## (built by 0x4bf900 from 0xee44a0) compared on the render box with the table
## computed from 0xedb88320 -- 218 of 255 usable entries equal, these 37 not
## (and 0, never used). GatewayServer.exe holds the identical list. Their
## values were not taken: a session given one of these is ended before it
## sends anything, and the caller reconnects.
const UNKNOWN_CRC_INDICES := [18, 19, 55, 58, 73, 88, 121, 123, 125, 145, 175, 176, 177, 182, 184,
	192, 193, 198, 199, 200, 208, 216, 217, 240, 241, 242, 243, 244, 245, 246, 248, 250, 251, 252,
	253, 254, 255]

static var _tables := {}
static var _crc32 := PackedInt64Array()

var flags := 0
var count := PackedByteArray([0, 0, 0])
var crc_table := PackedInt64Array()
var cipher: Blowfish = null

# --- The primitives -------------------------------------------------------------

## The 32-round generator (handshake.md point 1; READ 0x4afb80), the whole
## register.
static func lfsr32(v: int) -> int:
	v &= MASK32
	for _i in range(32):
		var tap := (v >> 2) ^ v
		tap = (tap >> 2) ^ v
		tap = (tap >> 1) ^ v
		tap = (tap >> 1) ^ v
		tap = (tap >> 1) ^ v
		v = ((((v >> 1) | (v << 31)) & MASK32) & ~1) | (tap & 1)
	return v

## The rolling byte's three state bytes from a count seed (READ
## 0x4b0cc0..0x4b0d51): four chained runs; a = v1 ^ v2, b = v4 ^ v3 (low
## bytes, 0 -> 1); {a ^ b, a, b}.
static func count_seeds(seed: int) -> PackedByteArray:
	seed &= MASK32
	if seed == 0:
		seed = DEFAULT_COUNT_SEED
	var v1 := lfsr32(seed)
	var v2 := lfsr32(v1)
	var v3 := lfsr32(v2)
	var v4 := lfsr32(v3)
	var a := (v1 ^ v2) & 0xFF
	var b := (v4 ^ v3) & 0xFF
	if a == 0:
		a = 1
	if b == 0:
		b = 1
	return PackedByteArray([a ^ b, a, b])

## The next rolling byte (READ 0x4b1eb6): ((~s0 + s1) * s2), then x ^ x >> 4.
static func next_count(state: PackedByteArray) -> int:
	var b: int = (((~state[0]) + state[1]) * state[2]) & 0xFF
	b = ((b >> 4) ^ b) & 0xFF
	state[0] = b
	return b

## READ (0x4bf9c0): the crc seed's low byte, 0 -> 1.
static func crc_index(crc_seed: int) -> int:
	var i := crc_seed & 0xFF
	return 1 if i == 0 else i

static func crc_index_known(index: int) -> bool:
	return index >= 1 and index <= 255 and not (index in UNKNOWN_CRC_INDICES)

static func _reflected_table(poly: int) -> PackedInt64Array:
	var t := PackedInt64Array()
	t.resize(256)
	for i in range(256):
		var v := i
		for _k in range(8):
			if v & 1:
				v = (v >> 1) ^ poly
			else:
				v >>= 1
		t[i] = v
	return t

## Table `index` (READ 0x4bf900: the textbook reflected-CRC table of the
## index'th polynomial; the polynomial of a known index is the standard
## CRC-32 table's entry there, MEASURED). Empty for an unknown index.
static func crc_table_for(index: int) -> PackedInt64Array:
	if not crc_index_known(index):
		return PackedInt64Array()
	if _tables.has(index):
		return _tables[index]
	if _crc32.is_empty():
		_crc32 = _reflected_table(0xEDB88320)
	var t := _reflected_table(_crc32[index])
	_tables[index] = t
	return t

## A frame's check byte (READ 0x4bf9e0): acc from 0xffffffff, per byte
## acc = acc >> 8 ^ t[(b ^ acc) & 0xff], folded by adding its four bytes.
static func check_byte(t: PackedInt64Array, frame: PackedByteArray) -> int:
	var acc := MASK32
	for b in frame:
		acc = (acc >> 8) ^ t[(b ^ acc) & 0xFF]
	return ((acc & 0xFF) + ((acc >> 8) & 0xFF) + ((acc >> 16) & 0xFF) + ((acc >> 24) & 0xFF)) & 0xFF

## The handshake's key mixing (READ 0x4c4230): v[i] ^= v[i] + key byte
## (i % 4, little-endian) + key_byte.
static func key_transform(v: PackedByteArray, key: int, key_byte: int) -> PackedByteArray:
	var out := v.duplicate()
	for i in range(8):
		var k := (key >> (8 * (i % 4))) & 0xFF
		out[i] = out[i] ^ ((out[i] + k + key_byte) & 0xFF)
	return out

## Two u32s little-endian in 8 bytes.
static func pair(lo: int, hi: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u32(0, lo & MASK32)
	b.encode_u32(4, hi & MASK32)
	return b

## a * b % m for a, b < 2^32 without leaving 63 bits.
static func _mulmod(a: int, b: int, m: int) -> int:
	var hi := (a * (b >> 16)) % m
	return ((hi << 16) + a * (b & 0xFFFF)) % m

## base^exp mod m (READ 0x4c6e50: square-and-multiply, exp 0 gives 1).
static func modpow(base: int, exp: int, m: int) -> int:
	if exp == 0:
		return 1
	var result := 1
	var b := (base & MASK32) % m
	var e := exp & MASK32
	while e != 0:
		if e & 1:
			result = _mulmod(result, b, m)
		e >>= 1
		b = _mulmod(b, b, m)
	return result

static func padded_len(n: int) -> int:
	return (n + 7) & ~7

# --- Frames ---------------------------------------------------------------------

func secured() -> bool:
	return flags & FLAG_SECURITY != 0

func encrypting() -> bool:
	return flags & FLAG_BLOWFISH != 0 and cipher != null

## The wire length of the frame at the start of buf: > 0 when whole, 0 to
## wait for more, -1 when its size word is over MAX_FRAME.
static func frame_len(buf: PackedByteArray) -> int:
	if buf.size() < 2:
		return 0
	var raw := buf.decode_u16(0)
	var size := raw & ~ENCRYPTED
	var n := 6 + size
	if raw & ENCRYPTED:
		n = 2 + padded_len(size + 4)
	if n > MAX_FRAME:
		return -1
	return n if buf.size() >= n else 0

## One whole frame: {opcode, payload, encrypted, count, check, plain} or
## {"error"}.
func decode(frame: PackedByteArray) -> Dictionary:
	if frame.size() < 6:
		return {"error": "a %d-byte frame is shorter than its header" % frame.size()}
	var raw := frame.decode_u16(0)
	var size := raw & ~ENCRYPTED
	var body := frame.slice(2)
	var enc := raw & ENCRYPTED != 0
	if enc:
		if not encrypting():
			return {"error": "an encrypted frame before Blowfish was agreed (the client's error 0x8011)"}
		if body.size() != padded_len(size + 4):
			return {"error": "encrypted frame body %d bytes, want %d" % [body.size(), padded_len(size + 4)]}
		body = cipher.decrypt_le(body)
	elif body.size() != size + 4:
		return {"error": "frame body %d bytes, want %d" % [body.size(), size + 4]}
	var plain := PackedByteArray()
	plain.resize(6 + size)
	plain.encode_u16(0, raw)
	for i in range(4 + size):
		plain[2 + i] = body[i]
	plain[5] = 0
	return {"opcode": body.decode_u16(0), "payload": body.slice(4, 4 + size), "encrypted": enc,
		"count": body[2], "check": body[3], "plain": plain}

## The client's rule for a server's frame (READ 0x4b0f60): with security on,
## count and check are 0, except on a plain 0x1001. "" when it passes.
func check_from_server(f: Dictionary) -> String:
	if not secured() or (not f["encrypted"] and int(f["opcode"]) == 0x1001):
		return ""
	if int(f["count"]) != 0:
		return "opcode 0x%04x from the server has count byte 0x%02x, not 0 (the client's error 0x800b)" % [f["opcode"], f["count"]]
	if int(f["check"]) != 0:
		return "opcode 0x%04x from the server has check byte 0x%02x, not 0 (the client's error 0x800c)" % [f["opcode"], f["check"]]
	return ""

## A client frame (READ 0x4b0d70): count and check when secured, then
## encrypted when asked and Blowfish is on (OURS: asked without Blowfish it
## goes plain with bit 15 clear -- see retail_frame.go).
func encode_client(opcode: int, payload: PackedByteArray, encrypt: bool) -> PackedByteArray:
	var enc := encrypt and encrypting()
	var raw := payload.size() | (ENCRYPTED if enc else 0)
	var plain := PackedByteArray()
	plain.resize(6)
	plain.encode_u16(0, raw)
	plain.encode_u16(2, opcode)
	plain.append_array(payload)
	if secured():
		plain[4] = next_count(count)
		plain[5] = check_byte(crc_table, plain)
	if not enc:
		return plain
	var tail := plain.slice(2)
	tail.resize(padded_len(tail.size()))
	var out := plain.slice(0, 2)
	out.append_array(cipher.encrypt_le(tail))
	return out
