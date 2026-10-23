// Command ddjtool reads and writes .ddj textures (round 789, lane X: the
// retexture tools; docs/protocol/DDJ_FORMAT.md). It runs on the operator's own
// files; nothing it reads or writes belongs in the repo.
//
//	ddjtool info base.ddj [more.ddj ...]
//	ddjtool decode -in base.ddj -out base.png [-level 0]
//	ddjtool encode -in painted.png -out new.ddj -like base.ddj
//	ddjtool encode -in icon.png -out icon.ddj -format argb8 -mips 0
//
// `encode -like` copies the base's pixel format and mip count, so a
// retexture matches what the client already loads for that slot; `-format`
// (dxt1, dxt3, dxt5, argb8) and `-mips` (-1 the whole chain, 0 one level with
// a mip count of 0 as the icons have, n exactly n) override it. The image
// must be the base's size when `-like` is given, unless `-resize-ok`.
package main

import (
	"flag"
	"fmt"
	"image"
	"image/png"
	"os"

	"github.com/TheOpenSRO/OpenSRO/server/internal/ddj"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "info":
		err = info(os.Args[2:])
	case "decode":
		err = decode(os.Args[2:])
	case "encode":
		err = encode(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "ddjtool:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: ddjtool info <file.ddj>...")
	fmt.Fprintln(os.Stderr, "       ddjtool decode -in <file.ddj> -out <file.png> [-level n]")
	fmt.Fprintln(os.Stderr, "       ddjtool encode -in <file.png> -out <file.ddj> [-like <base.ddj>] [-format dxt1|dxt3|dxt5|argb8] [-mips n]")
	os.Exit(2)
}

func load(path string) (*ddj.Texture, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ddj.Parse(data)
}

func info(paths []string) error {
	if len(paths) == 0 {
		usage()
	}
	for _, p := range paths {
		t, err := load(p)
		if err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
		f := t.FourCC
		if f == "" {
			f = fmt.Sprintf("%d-bit masks %#x/%#x/%#x/%#x", t.RGBBitCount, t.RMask, t.GMask, t.BMask, t.AMask)
		}
		fmt.Printf("%s: %dx%d %s, mip count %d (%d levels), %d DDS bytes\n", p, t.Width, t.Height, f, t.MipMapCount, t.Levels(), len(t.DDS))
	}
	return nil
}

func decode(args []string) error {
	fs := flag.NewFlagSet("decode", flag.ExitOnError)
	in := fs.String("in", "", "the .ddj")
	out := fs.String("out", "", "the .png to write")
	level := fs.Int("level", 0, "the mip level (0 is full size)")
	fs.Parse(args)
	if *in == "" || *out == "" {
		usage()
	}
	t, err := load(*in)
	if err != nil {
		return err
	}
	img, err := t.Level(*level)
	if err != nil {
		return err
	}
	f, err := os.Create(*out)
	if err != nil {
		return err
	}
	defer f.Close()
	return png.Encode(f, img)
}

func encode(args []string) error {
	fs := flag.NewFlagSet("encode", flag.ExitOnError)
	in := fs.String("in", "", "the .png")
	out := fs.String("out", "", "the .ddj to write")
	like := fs.String("like", "", "a base .ddj whose format and mip count to copy")
	format := fs.String("format", "", "dxt1, dxt3, dxt5 or argb8 (overrides -like)")
	mips := fs.Int("mips", -2, "-1 the whole chain, 0 one level (mip count 0), n exactly n (overrides -like)")
	resizeOK := fs.Bool("resize-ok", false, "allow an image of another size than the -like base")
	fs.Parse(args)
	if *in == "" || *out == "" {
		usage()
	}
	pf, err := os.Open(*in)
	if err != nil {
		return err
	}
	img, _, err := image.Decode(pf)
	pf.Close()
	if err != nil {
		return err
	}
	opt := ddj.EncodeOptions{Format: ddj.FormatDXT5, Mips: -1}
	if *like != "" {
		base, err := load(*like)
		if err != nil {
			return fmt.Errorf("%s: %w", *like, err)
		}
		if opt.Format, err = ddj.FormatOf(base); err != nil {
			return err
		}
		opt.Mips = int(base.MipMapCount)
		if !*resizeOK && (img.Bounds().Dx() != int(base.Width) || img.Bounds().Dy() != int(base.Height)) {
			return fmt.Errorf("%s is %dx%d, the base %dx%d (-resize-ok to allow)", *in, img.Bounds().Dx(), img.Bounds().Dy(), base.Width, base.Height)
		}
	}
	if *format != "" {
		if opt.Format, err = ddj.ParseFormat(*format); err != nil {
			return err
		}
	}
	if *mips != -2 {
		opt.Mips = *mips
	}
	data, err := ddj.Encode(img, opt)
	if err != nil {
		return err
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s: %dx%d %v, mips %d, %d bytes\n", *out, img.Bounds().Dx(), img.Bounds().Dy(), opt.Format, opt.Mips, len(data))
	return nil
}
