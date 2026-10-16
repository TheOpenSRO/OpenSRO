package ddj

// Decoding and encoding the pixels of a .ddj (round 789, lane X: the
// retexture tools). The pixel formats are Microsoft's public DDS ones (DXT1,
// DXT3, DXT5 block compression; uncompressed RGB with channel masks), not
// anything reverse engineered from the game. What IS the game's is only the
// header shape the encoder copies, MEASURED on retail textures:
//
//   - a mipmapped DXT texture (avatar_m_knight_3.ddj, avatar_w_fur.ddj,
//     e060823_satgat_hp.ddj): DDS flags 0x21007 (CAPS | HEIGHT | WIDTH |
//     PIXELFORMAT | MIPMAPCOUNT), pitch 0, caps 0x401008 (COMPLEX | TEXTURE |
//     MIPMAP), the chain down to 1x1;
//   - an item icon (icon\item\Avatar\mall_avatar_*.ddj): 32x32 A8R8G8B8,
//     flags 0x1007, mip count 0, pixel-format flags 0x41 (RGB | ALPHAPIXELS),
//     masks 0xff0000/0xff00/0xff/0xff000000, caps 0x1002;
//   - the wrapper's size word is the file length minus 12 and its second word
//     3 in all of them (DDJ_FORMAT.md; the loader reads size-8 DDS bytes).

import (
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"math/bits"
)

// Format is a pixel format the encoder writes.
type Format int

const (
	FormatDXT1 Format = iota + 1
	FormatDXT3
	FormatDXT5
	FormatARGB8 // uncompressed A8R8G8B8, B G R A in memory
)

// ParseFormat maps a name ("dxt1", "dxt3", "dxt5", "argb8") to a Format.
func ParseFormat(s string) (Format, error) {
	switch s {
	case "dxt1", "DXT1":
		return FormatDXT1, nil
	case "dxt3", "DXT3":
		return FormatDXT3, nil
	case "dxt5", "DXT5":
		return FormatDXT5, nil
	case "argb8", "ARGB8", "a8r8g8b8":
		return FormatARGB8, nil
	}
	return 0, fmt.Errorf("ddj: unknown format %q (dxt1, dxt3, dxt5, argb8)", s)
}

func (f Format) String() string {
	switch f {
	case FormatDXT1:
		return "DXT1"
	case FormatDXT3:
		return "DXT3"
	case FormatDXT5:
		return "DXT5"
	case FormatARGB8:
		return "ARGB8"
	}
	return "unknown"
}

// FormatOf is the Format a parsed texture is stored in, or an error for one
// the encoder does not write (it can still be decoded).
func FormatOf(t *Texture) (Format, error) {
	switch t.FourCC {
	case "DXT1":
		return FormatDXT1, nil
	case "DXT3":
		return FormatDXT3, nil
	case "DXT5":
		return FormatDXT5, nil
	case "":
		if t.RGBBitCount == 32 && t.RMask == 0xff0000 && t.GMask == 0xff00 && t.BMask == 0xff {
			return FormatARGB8, nil
		}
	}
	return 0, fmt.Errorf("ddj: no encoder for fourcc %q / %d-bit masks %#x %#x %#x %#x",
		t.FourCC, t.RGBBitCount, t.RMask, t.GMask, t.BMask, t.AMask)
}

// Levels is the number of images the texture stores: its mip count, or 1
// when the header says 0 (a texture without a chain).
func (t *Texture) Levels() int {
	if t.MipMapCount == 0 {
		return 1
	}
	return int(t.MipMapCount)
}

// levelSize is the byte size of one w x h level in the texture's format.
func (t *Texture) levelSize(w, h int) (int, error) {
	switch t.FourCC {
	case "DXT1":
		return ((w + 3) / 4) * ((h + 3) / 4) * 8, nil
	case "DXT3", "DXT5":
		return ((w + 3) / 4) * ((h + 3) / 4) * 16, nil
	case "":
		if t.RGBBitCount%8 != 0 || t.RGBBitCount == 0 || t.RGBBitCount > 32 {
			return 0, fmt.Errorf("ddj: unsupported bit count %d", t.RGBBitCount)
		}
		return w * h * int(t.RGBBitCount/8), nil
	}
	return 0, fmt.Errorf("ddj: no decoder for fourcc %q", t.FourCC)
}

const ddsDataOff = 4 + ddsHeaderSize

// Level decodes mip level n (0 is the full size) to straight RGBA.
func (t *Texture) Level(n int) (*image.NRGBA, error) {
	if n < 0 || n >= t.Levels() {
		return nil, fmt.Errorf("ddj: level %d of %d", n, t.Levels())
	}
	off := ddsDataOff
	w, h := int(t.Width), int(t.Height)
	for i := 0; i < n; i++ {
		sz, err := t.levelSize(w, h)
		if err != nil {
			return nil, err
		}
		off += sz
		w, h = max(w/2, 1), max(h/2, 1)
	}
	sz, err := t.levelSize(w, h)
	if err != nil {
		return nil, err
	}
	if off+sz > len(t.DDS) {
		return nil, fmt.Errorf("ddj: level %d (%dx%d) runs past the data (%d > %d)", n, w, h, off+sz, len(t.DDS))
	}
	data := t.DDS[off : off+sz]
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	switch t.FourCC {
	case "DXT1", "DXT3", "DXT5":
		decodeBlocks(img, data, t.FourCC)
	default:
		decodeMasked(img, data, t)
	}
	return img, nil
}

func decodeMasked(img *image.NRGBA, data []byte, t *Texture) {
	bpp := int(t.RGBBitCount / 8)
	ch := func(v, mask uint32, def uint8) uint8 {
		if mask == 0 {
			return def
		}
		shift := bits.TrailingZeros32(mask)
		width := bits.OnesCount32(mask)
		x := (v & mask) >> shift
		maxv := uint32(1)<<width - 1
		return uint8((x*255 + maxv/2) / maxv)
	}
	w, h := img.Rect.Dx(), img.Rect.Dy()
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			p := (y*w + x) * bpp
			var v uint32
			for k := 0; k < bpp; k++ {
				v |= uint32(data[p+k]) << (8 * k)
			}
			i := img.PixOffset(x, y)
			img.Pix[i] = ch(v, t.RMask, 0)
			img.Pix[i+1] = ch(v, t.GMask, 0)
			img.Pix[i+2] = ch(v, t.BMask, 0)
			img.Pix[i+3] = ch(v, t.AMask, 255)
		}
	}
}

func rgb565(c uint16) [3]int {
	r := int(c>>11) & 31
	g := int(c>>5) & 63
	b := int(c) & 31
	return [3]int{r<<3 | r>>2, g<<2 | g>>4, b<<3 | b>>2}
}

// colourPalette is a DXT colour block's four colours (alpha in [3]); in
// DXT1's three-colour mode index 3 is transparent black.
func colourPalette(c0, c1 uint16, dxt1 bool) [4][4]int {
	a, b := rgb565(c0), rgb565(c1)
	var p [4][4]int
	p[0] = [4]int{a[0], a[1], a[2], 255}
	p[1] = [4]int{b[0], b[1], b[2], 255}
	if c0 > c1 || !dxt1 {
		for k := 0; k < 3; k++ {
			p[2][k] = (2*a[k] + b[k]) / 3
			p[3][k] = (a[k] + 2*b[k]) / 3
		}
		p[2][3], p[3][3] = 255, 255
	} else {
		for k := 0; k < 3; k++ {
			p[2][k] = (a[k] + b[k]) / 2
		}
		p[2][3] = 255
		p[3] = [4]int{0, 0, 0, 0}
	}
	return p
}

func alphaPalette(a0, a1 int) [8]int {
	var p [8]int
	p[0], p[1] = a0, a1
	if a0 > a1 {
		for i := 1; i < 7; i++ {
			p[i+1] = ((7-i)*a0 + i*a1) / 7
		}
	} else {
		for i := 1; i < 5; i++ {
			p[i+1] = ((5-i)*a0 + i*a1) / 5
		}
		p[6], p[7] = 0, 255
	}
	return p
}

func decodeBlocks(img *image.NRGBA, data []byte, fourCC string) {
	w, h := img.Rect.Dx(), img.Rect.Dy()
	bw := (w + 3) / 4
	blockSize := 16
	if fourCC == "DXT1" {
		blockSize = 8
	}
	for by := 0; by < (h+3)/4; by++ {
		for bx := 0; bx < bw; bx++ {
			blk := data[(by*bw+bx)*blockSize:]
			var alpha [16]int
			hasAlpha := false
			switch fourCC {
			case "DXT3":
				for i := 0; i < 16; i++ {
					v := int(blk[i/2]>>(4*(i%2))) & 0xf
					alpha[i] = v * 17
				}
				hasAlpha = true
				blk = blk[8:]
			case "DXT5":
				pal := alphaPalette(int(blk[0]), int(blk[1]))
				var idx uint64
				for k := 0; k < 6; k++ {
					idx |= uint64(blk[2+k]) << (8 * k)
				}
				for i := 0; i < 16; i++ {
					alpha[i] = pal[(idx>>(3*i))&7]
				}
				hasAlpha = true
				blk = blk[8:]
			}
			c0 := binary.LittleEndian.Uint16(blk[0:])
			c1 := binary.LittleEndian.Uint16(blk[2:])
			pal := colourPalette(c0, c1, fourCC == "DXT1")
			idx := binary.LittleEndian.Uint32(blk[4:])
			for i := 0; i < 16; i++ {
				x, y := bx*4+i%4, by*4+i/4
				if x >= w || y >= h {
					continue
				}
				c := pal[(idx>>(2*i))&3]
				a := c[3]
				if hasAlpha {
					a = alpha[i]
				}
				o := img.PixOffset(x, y)
				img.Pix[o], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3] = uint8(c[0]), uint8(c[1]), uint8(c[2]), uint8(a)
			}
		}
	}
}

// EncodeOptions says how Encode writes a texture.
type EncodeOptions struct {
	Format Format
	// Mips is the number of levels to store: 0 writes a single level with a
	// header mip count of 0 (the icons' shape), -1 the whole chain down to
	// 1x1, n > 0 exactly n levels (header count n).
	Mips int
}

// Encode writes img as a complete .ddj file (wrapper + DDS). Each level is
// a 2x2 box filter of the one above (OURS: the retail chains' filter is not
// known). DXT endpoints are each block's colour bounding box corners,
// the diagonal picked by the texels' covariance with the widest channel
// (OURS; any valid block decodes everywhere).
func Encode(img image.Image, opt EncodeOptions) ([]byte, error) {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= 0 || h <= 0 {
		return nil, errors.New("ddj: empty image")
	}
	if opt.Format < FormatDXT1 || opt.Format > FormatARGB8 {
		return nil, fmt.Errorf("ddj: bad format %d", opt.Format)
	}
	full := 1
	for s := max(w, h); s > 1; s /= 2 {
		full++
	}
	levels := opt.Mips
	switch {
	case levels < 0:
		levels = full
	case levels == 0:
		levels = 1
	case levels > full:
		return nil, fmt.Errorf("ddj: %d mips asked of a %dx%d image (at most %d)", opt.Mips, w, h, full)
	}

	cur := toNRGBA(img)
	var payload []byte
	for l := 0; l < levels; l++ {
		if l > 0 {
			cur = halve(cur)
		}
		switch opt.Format {
		case FormatARGB8:
			payload = append(payload, encodeARGB8(cur)...)
		default:
			payload = append(payload, encodeBlocks(cur, opt.Format)...)
		}
	}

	dds := make([]byte, ddsDataOff, ddsDataOff+len(payload))
	copy(dds, "DDS ")
	hdr := dds[4:]
	le := binary.LittleEndian
	le.PutUint32(hdr[0:], ddsHeaderSize)
	flags := uint32(0x1 | 0x2 | 0x4 | 0x1000) // CAPS HEIGHT WIDTH PIXELFORMAT
	caps := uint32(0x1000)                    // TEXTURE
	mipCount := uint32(0)
	if opt.Mips != 0 {
		flags |= 0x20000 // MIPMAPCOUNT
		caps |= 0x8 | 0x400000
		mipCount = uint32(levels)
	}
	pf := hdr[72:]
	le.PutUint32(pf[0:], 32)
	if opt.Format == FormatARGB8 {
		caps |= 0x2 // the icons' caps word is 0x1002 (MEASURED)
		le.PutUint32(pf[4:], 0x41)
		le.PutUint32(pf[12:], 32)
		le.PutUint32(pf[16:], 0xff0000)
		le.PutUint32(pf[20:], 0xff00)
		le.PutUint32(pf[24:], 0xff)
		le.PutUint32(pf[28:], 0xff000000)
	} else {
		le.PutUint32(pf[4:], 0x4)
		copy(pf[8:12], opt.Format.String())
	}
	le.PutUint32(hdr[4:], flags)
	le.PutUint32(hdr[8:], uint32(h))
	le.PutUint32(hdr[12:], uint32(w))
	le.PutUint32(hdr[24:], mipCount)
	le.PutUint32(hdr[104:], caps)
	dds = append(dds, payload...)

	out := make([]byte, wrapperSize, wrapperSize+len(dds))
	copy(out, magic)
	le.PutUint32(out[12:], uint32(wrapperSize+len(dds)-magicLen))
	le.PutUint32(out[16:], 3)
	return append(out, dds...), nil
}

func toNRGBA(img image.Image) *image.NRGBA {
	b := img.Bounds()
	out := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			c := color.NRGBAModel.Convert(img.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
			o := out.PixOffset(x, y)
			out.Pix[o], out.Pix[o+1], out.Pix[o+2], out.Pix[o+3] = c.R, c.G, c.B, c.A
		}
	}
	return out
}

// halve is the next mip level: each texel the mean of its 2x2 (or 2x1 on a
// side already 1 wide).
func halve(src *image.NRGBA) *image.NRGBA {
	w, h := src.Rect.Dx(), src.Rect.Dy()
	nw, nh := max(w/2, 1), max(h/2, 1)
	out := image.NewNRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		for x := 0; x < nw; x++ {
			var sum [4]int
			n := 0
			for dy := 0; dy < 2; dy++ {
				for dx := 0; dx < 2; dx++ {
					sx, sy := min(2*x+dx, w-1), min(2*y+dy, h-1)
					o := src.PixOffset(sx, sy)
					for k := 0; k < 4; k++ {
						sum[k] += int(src.Pix[o+k])
					}
					n++
				}
			}
			o := out.PixOffset(x, y)
			for k := 0; k < 4; k++ {
				out.Pix[o+k] = uint8((sum[k] + n/2) / n)
			}
		}
	}
	return out
}

func encodeARGB8(img *image.NRGBA) []byte {
	w, h := img.Rect.Dx(), img.Rect.Dy()
	out := make([]byte, 0, w*h*4)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			o := img.PixOffset(x, y)
			out = append(out, img.Pix[o+2], img.Pix[o+1], img.Pix[o], img.Pix[o+3])
		}
	}
	return out
}

func to565(c [3]int) uint16 {
	r := (c[0]*31 + 127) / 255
	g := (c[1]*63 + 127) / 255
	b := (c[2]*31 + 127) / 255
	return uint16(r<<11 | g<<5 | b)
}

func encodeBlocks(img *image.NRGBA, f Format) []byte {
	w, h := img.Rect.Dx(), img.Rect.Dy()
	bw, bh := (w+3)/4, (h+3)/4
	size := 16
	if f == FormatDXT1 {
		size = 8
	}
	out := make([]byte, 0, bw*bh*size)
	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			var px [16][4]int
			for i := 0; i < 16; i++ {
				// Clamp at the edge for a level smaller than a block.
				x, y := min(bx*4+i%4, w-1), min(by*4+i/4, h-1)
				o := img.PixOffset(x, y)
				px[i] = [4]int{int(img.Pix[o]), int(img.Pix[o+1]), int(img.Pix[o+2]), int(img.Pix[o+3])}
			}
			switch f {
			case FormatDXT3:
				var a [8]byte
				for i := 0; i < 16; i++ {
					v := (px[i][3]*15 + 127) / 255
					a[i/2] |= byte(v << (4 * (i % 2)))
				}
				out = append(out, a[:]...)
			case FormatDXT5:
				out = append(out, encodeAlpha5(px)...)
			}
			out = append(out, encodeColour(px, f == FormatDXT1)...)
		}
	}
	return out
}

func encodeAlpha5(px [16][4]int) []byte {
	lo, hi := 255, 0
	for _, p := range px {
		lo, hi = min(lo, p[3]), max(hi, p[3])
	}
	out := []byte{byte(hi), byte(lo), 0, 0, 0, 0, 0, 0}
	if hi == lo {
		return out // every index 0: alpha = hi
	}
	pal := alphaPalette(hi, lo)
	var idx uint64
	for i, p := range px {
		best, bd := 0, 1<<30
		for k := 0; k < 8; k++ {
			if d := abs(pal[k] - p[3]); d < bd {
				best, bd = k, d
			}
		}
		idx |= uint64(best) << (3 * i)
	}
	for k := 0; k < 6; k++ {
		out[2+k] = byte(idx >> (8 * k))
	}
	return out
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// encodeColour writes one 8-byte colour block. A DXT1 block with a texel
// under alpha 128 uses three-colour mode, those texels index 3 (transparent).
func encodeColour(px [16][4]int, dxt1 bool) []byte {
	punch := false
	if dxt1 {
		for _, p := range px {
			if p[3] < 128 {
				punch = true
			}
		}
	}
	// Endpoints: the extremes of the opaque texels along the box diagonal.
	var lo, hi [3]int
	lo = [3]int{255, 255, 255}
	n := 0
	for _, p := range px {
		if punch && p[3] < 128 {
			continue
		}
		n++
		for k := 0; k < 3; k++ {
			lo[k], hi[k] = min(lo[k], p[k]), max(hi[k], p[k])
		}
	}
	out := make([]byte, 8)
	if n == 0 {
		// Every texel transparent: c0 <= c1, all indices 3.
		binary.LittleEndian.PutUint32(out[4:], 0xffffffff)
		return out
	}
	// Order the box diagonal by the texels' covariance so a block whose
	// colours run "red up, green down" picks the other diagonal.
	var mean [3]float64
	for _, p := range px {
		if punch && p[3] < 128 {
			continue
		}
		for k := 0; k < 3; k++ {
			mean[k] += float64(p[k])
		}
	}
	for k := 0; k < 3; k++ {
		mean[k] /= float64(n)
	}
	var cov [3]float64 // r-g, r-b, g-b
	for _, p := range px {
		if punch && p[3] < 128 {
			continue
		}
		d := [3]float64{float64(p[0]) - mean[0], float64(p[1]) - mean[1], float64(p[2]) - mean[2]}
		cov[0] += d[0] * d[1]
		cov[1] += d[0] * d[2]
		cov[2] += d[1] * d[2]
	}
	a, b := lo, hi
	// Pick the main channel (largest range) and flip the others against it
	// when they are anti-correlated with it.
	ranges := [3]int{hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]}
	main := 0
	for k := 1; k < 3; k++ {
		if ranges[k] > ranges[main] {
			main = k
		}
	}
	corr := func(i, j int) float64 {
		if i == j {
			return 1
		}
		switch {
		case (i == 0 && j == 1) || (i == 1 && j == 0):
			return cov[0]
		case (i == 0 && j == 2) || (i == 2 && j == 0):
			return cov[1]
		}
		return cov[2]
	}
	for k := 0; k < 3; k++ {
		if k != main && corr(main, k) < 0 {
			a[k], b[k] = b[k], a[k]
		}
	}
	c0, c1 := to565(b), to565(a)
	var pal [4][4]int
	if punch {
		if c0 > c1 {
			c0, c1 = c1, c0
		}
		pal = colourPalette(c0, c1, true)
	} else {
		if c0 < c1 {
			c0, c1 = c1, c0
		}
		if c0 == c1 {
			// A flat block: four-colour mode needs c0 > c1.
			if c1 > 0 {
				c1--
			} else {
				c0++
			}
		}
		pal = colourPalette(c0, c1, dxt1)
	}
	var idx uint32
	for i, p := range px {
		if punch && p[3] < 128 {
			idx |= 3 << (2 * i)
			continue
		}
		best, bd := 0, 1<<30
		limit := 4
		if punch {
			limit = 3
		}
		for k := 0; k < limit; k++ {
			d := 0
			for c := 0; c < 3; c++ {
				e := pal[k][c] - p[c]
				d += e * e
			}
			if d < bd {
				best, bd = k, d
			}
		}
		idx |= uint32(best) << (2 * i)
	}
	binary.LittleEndian.PutUint16(out[0:], c0)
	binary.LittleEndian.PutUint16(out[2:], c1)
	binary.LittleEndian.PutUint32(out[4:], idx)
	return out
}
