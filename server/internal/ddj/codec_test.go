package ddj

import (
	"encoding/binary"
	"image"
	"image/color"
	"testing"
)

// synthetic is a test image (never game data): a colour gradient with an
// alpha ramp and a few hard-edged squares, the kind of content a painted
// texture has.
func synthetic(w, h int, withAlpha bool) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.NRGBA{uint8(x * 255 / max(w-1, 1)), uint8(y * 255 / max(h-1, 1)), uint8((x + y) * 127 / max(w+h-2, 1)), 255}
			if (x/8+y/8)%5 == 0 {
				c = color.NRGBA{0xb0, 0x18, 0x1e, 255}
			}
			if withAlpha {
				c.A = uint8(x * 255 / max(w-1, 1))
			}
			img.SetNRGBA(x, y, c)
		}
	}
	return img
}

// meanErr is the mean absolute channel difference (alpha included).
func meanErr(a, b *image.NRGBA) float64 {
	sum := 0
	for i := range a.Pix {
		d := int(a.Pix[i]) - int(b.Pix[i])
		if d < 0 {
			d = -d
		}
		sum += d
	}
	return float64(sum) / float64(len(a.Pix))
}

func TestEncodeDecodeRoundTrip(t *testing.T) {
	for _, tc := range []struct {
		f       Format
		alpha   bool
		maxMean float64
	}{
		{FormatARGB8, true, 0},
		{FormatDXT1, false, 6},
		{FormatDXT3, true, 7},
		{FormatDXT5, true, 6},
	} {
		src := synthetic(64, 32, tc.alpha)
		data, err := Encode(src, EncodeOptions{Format: tc.f, Mips: -1})
		if err != nil {
			t.Fatalf("%v: Encode: %v", tc.f, err)
		}
		tex, err := Parse(data)
		if err != nil {
			t.Fatalf("%v: Parse: %v", tc.f, err)
		}
		if tex.Width != 64 || tex.Height != 32 || tex.MipMapCount != 7 {
			t.Fatalf("%v: header %dx%d mips %d, want 64x32 mips 7", tc.f, tex.Width, tex.Height, tex.MipMapCount)
		}
		got, err := FormatOf(tex)
		if err != nil || got != tc.f {
			t.Fatalf("%v: FormatOf = %v, %v", tc.f, got, err)
		}
		top, err := tex.Level(0)
		if err != nil {
			t.Fatalf("%v: Level(0): %v", tc.f, err)
		}
		if e := meanErr(src, top); e > tc.maxMean {
			t.Errorf("%v: mean error %.2f over %.2f", tc.f, e, tc.maxMean)
		}
		// The last level is 1x1 and the data ends exactly after it.
		last, err := tex.Level(6)
		if err != nil || last.Rect.Dx() != 1 || last.Rect.Dy() != 1 {
			t.Fatalf("%v: last level %v, %v", tc.f, last.Rect, err)
		}
		size := 0
		w, h := 64, 32
		for l := 0; l < 7; l++ {
			n, _ := tex.levelSize(w, h)
			size += n
			w, h = max(w/2, 1), max(h/2, 1)
		}
		if len(tex.DDS) != ddsDataOff+size {
			t.Errorf("%v: DDS is %d bytes, the chain needs %d", tc.f, len(tex.DDS), ddsDataOff+size)
		}
	}
}

// The header words the encoder copies from retail textures (codec.go's
// comment has the MEASURED values).
func TestEncodeHeaderShapes(t *testing.T) {
	le := binary.LittleEndian
	dxt, err := Encode(synthetic(512, 512, false), EncodeOptions{Format: FormatDXT1, Mips: -1})
	if err != nil {
		t.Fatal(err)
	}
	// A 512x512 DXT1 with its 10 levels is 174,924 bytes, as avatar_w_fur.ddj.
	if len(dxt) != 174924 {
		t.Errorf("512 DXT1 chain is %d bytes, want 174924", len(dxt))
	}
	if got := le.Uint32(dxt[12:]); got != uint32(len(dxt)-12) {
		t.Errorf("size word %d, want %d", got, len(dxt)-12)
	}
	if le.Uint32(dxt[16:]) != 3 {
		t.Errorf("wrapper word 2 is %d, want 3", le.Uint32(dxt[16:]))
	}
	h := dxt[24:] // the DDS_HEADER: dwSize at 0, flags 4, mips 24, pixel format 72, caps 104
	if le.Uint32(h[4:]) != 0x21007 || le.Uint32(h[104:]) != 0x401008 || le.Uint32(h[24:]) != 10 {
		t.Errorf("DXT flags %#x caps %#x mips %d, want 0x21007 0x401008 10", le.Uint32(h[4:]), le.Uint32(h[104:]), le.Uint32(h[24:]))
	}

	icon, err := Encode(synthetic(32, 32, true), EncodeOptions{Format: FormatARGB8, Mips: 0})
	if err != nil {
		t.Fatal(err)
	}
	if len(icon) != 4244 {
		t.Errorf("32x32 icon is %d bytes, want 4244", len(icon))
	}
	h = icon[24:]
	pf := h[72:]
	if le.Uint32(h[4:]) != 0x1007 || le.Uint32(h[104:]) != 0x1002 || le.Uint32(h[24:]) != 0 ||
		le.Uint32(pf[4:]) != 0x41 || le.Uint32(pf[28:]) != 0xff000000 {
		t.Errorf("icon flags %#x caps %#x mips %d pf %#x amask %#x", le.Uint32(h[4:]), le.Uint32(h[104:]), le.Uint32(h[24:]), le.Uint32(pf[4:]), le.Uint32(pf[28:]))
	}
	tex, _ := Parse(icon)
	if tex.Levels() != 1 {
		t.Errorf("a mip count of 0 is %d levels, want 1", tex.Levels())
	}
}

// A hand-built DXT1 block (Microsoft's layout): c0 pure red > c1 pure blue,
// indices 0,1,2,3 across the first row.
func TestDecodeDXT1Block(t *testing.T) {
	blk := []byte{0x00, 0xf8, 0x1f, 0x00, 0xe4, 0, 0, 0}
	img := image.NewNRGBA(image.Rect(0, 0, 4, 4))
	decodeBlocks(img, blk, "DXT1")
	want := []color.NRGBA{{255, 0, 0, 255}, {0, 0, 255, 255}, {170, 0, 85, 255}, {85, 0, 170, 255}}
	for x, w := range want {
		if got := img.NRGBAAt(x, 0); got != w {
			t.Errorf("texel %d = %v, want %v", x, got, w)
		}
	}
	// Three-colour mode (c0 <= c1): index 3 is transparent black.
	blk = []byte{0x1f, 0x00, 0x00, 0xf8, 0xc0, 0, 0, 0}
	decodeBlocks(img, blk, "DXT1")
	if got := img.NRGBAAt(3, 0); got != (color.NRGBA{}) {
		t.Errorf("index 3 in three-colour mode = %v, want transparent", got)
	}
}

// A DXT1 texel under alpha 128 survives as transparent (punch-through).
func TestEncodeDXT1PunchThrough(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 4, 4))
	for i := 0; i < 16; i++ {
		img.SetNRGBA(i%4, i/4, color.NRGBA{200, 100, 50, 255})
	}
	img.SetNRGBA(1, 1, color.NRGBA{0, 0, 0, 0})
	data, err := Encode(img, EncodeOptions{Format: FormatDXT1})
	if err != nil {
		t.Fatal(err)
	}
	tex, _ := Parse(data)
	out, _ := tex.Level(0)
	if out.NRGBAAt(1, 1).A != 0 || out.NRGBAAt(0, 0).A != 255 {
		t.Errorf("punch-through: %v %v", out.NRGBAAt(1, 1), out.NRGBAAt(0, 0))
	}
}

func TestEncodeRejects(t *testing.T) {
	if _, err := Encode(synthetic(8, 8, false), EncodeOptions{Format: FormatDXT1, Mips: 9}); err == nil {
		t.Error("9 mips of an 8x8 image accepted")
	}
	if _, err := ParseFormat("bc7"); err == nil {
		t.Error("unknown format accepted")
	}
}
