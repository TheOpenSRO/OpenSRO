extends RefCounted
class_name RetailCaptcha

## The image code's picture (round 788): 0x2322's blob, READ on both sides --
## the writer is GatewayServer's IBUV module calling ImageTrans.dll
## (fnImageTransToMemW; compress2 at 0x10007b2b..0x10007b65), the reader the
## image-code window's CIFBltImage (0x62c6a0, 0x62c500):
##
##   u16 compressed length, u16 output buffer size, u16 width, u16 height,
##   then a zlib stream (header and Adler-32 trailer: the client's
##   decompressor is zlib 1.1.4's uncompress(), 0x4d8e00, nowrap 0, wbits 15)
##
## The picture is 1 bit a pixel, rows top-down, width / 8 bytes a row with no
## other padding; pixel (x, y) is bit (x & 7) of byte (y * width + x) >> 3,
## least significant first; a set bit is opaque white, a clear one opaque
## black (READ 0x62c500). The writer sends width 200, height 64 and an
## output size of (height + 1) * width (READ; larger than the 1600 bytes the
## picture needs -- the client sizes its buffer from it and checks nothing).
## The client draws it unscaled at the control's origin.

## OURS: the largest output buffer taken (the writer's is 13000; 64 KiB is
## a 512 x 1024 picture).
const MAX_OUT := 0x10000

## The blob -> {"width", "height", "image": Image (RGBA8)} or {"error"}.
static func decode(blob: PackedByteArray) -> Dictionary:
	if blob.size() < 8:
		return {"error": "0x2322 image: %d bytes, under its 8-byte header" % blob.size()}
	var comp := blob.decode_u16(0)
	var out_size := blob.decode_u16(2)
	var w := blob.decode_u16(4)
	var h := blob.decode_u16(6)
	if comp == 0 or 8 + comp > blob.size():
		return {"error": "0x2322 image: %d compressed bytes announced, %d there" % [comp, blob.size() - 8]}
	if w == 0 or h == 0 or w % 8 != 0:
		return {"error": "0x2322 image: %d x %d (the width must be a multiple of 8, READ 0x62c500)" % [w, h]}
	var need := w * h / 8
	if out_size < need or out_size > MAX_OUT:
		return {"error": "0x2322 image: an output size of %d for %d x %d" % [out_size, w, h]}
	var bits := blob.slice(8, 8 + comp).decompress(out_size, FileAccess.COMPRESSION_DEFLATE)
	if bits.size() < need:
		return {"error": "0x2322 image: the zlib stream gave %d bytes, %d needed" % [bits.size(), need]}
	var px := PackedByteArray()
	px.resize(w * h * 4)
	for y in range(h):
		for x in range(w):
			var on := (bits[(y * w + x) >> 3] >> (x & 7)) & 1
			var v := 255 if on else 0
			var o := (y * w + x) * 4
			px[o] = v
			px[o + 1] = v
			px[o + 2] = v
			px[o + 3] = 255
	return {"width": w, "height": h, "image": Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)}

## A blob from a picture of 0/1 bytes (row-major), for tests: the writer's
## layout with Godot's own zlib.
static func encode(w: int, h: int, pixels: PackedByteArray) -> PackedByteArray:
	var bits := PackedByteArray()
	bits.resize(w * h / 8)
	for i in range(w * h):
		if pixels[i] != 0:
			bits[i >> 3] |= 1 << ((i % w) & 7)
	var z := bits.compress(FileAccess.COMPRESSION_DEFLATE)
	var out := PackedByteArray()
	out.resize(8)
	out.encode_u16(0, z.size())
	out.encode_u16(2, (h + 1) * w)
	out.encode_u16(4, w)
	out.encode_u16(6, h)
	out.append_array(z)
	return out
