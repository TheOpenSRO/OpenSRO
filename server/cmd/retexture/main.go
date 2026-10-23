// Command retexture copies a .bsr or .bmt with path strings renamed and every
// other byte kept (round 789, lane X; internal/retexture has the rules). It
// is the "new item, retail mesh, new texture" step: a new .bsr naming a new
// .bmt, and a new .bmt naming a new .ddj.
//
//	retexture -in avatar_m_knight_3.bsr -list
//	retexture -in avatar_m_knight_3.bsr -out opensro_akatsuki_m.bsr \
//	    -set 'prim\mtrl\item\etc\avatar_m_knight_3.bmt=prim\mtrl\item\etc\opensro_akatsuki_m.bmt'
//
// -set may be given more than once. The output is re-parsed with the
// server's own .bsr / .bmt readers and its paths printed.
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/bmt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/bsr"
	"github.com/TheOpenSRO/OpenSRO/server/internal/retexture"
)

type sets []retexture.Replacement

func (s *sets) String() string { return fmt.Sprint(*s) }
func (s *sets) Set(v string) error {
	i := strings.Index(v, "=")
	if i <= 0 || i == len(v)-1 {
		return fmt.Errorf("want old=new, got %q", v)
	}
	*s = append(*s, retexture.Replacement{Old: v[:i], New: v[i+1:]})
	return nil
}

func main() {
	in := flag.String("in", "", "the base .bsr or .bmt")
	out := flag.String("out", "", "the file to write")
	list := flag.Bool("list", false, "list the file's strings and stop")
	var repl sets
	flag.Var(&repl, "set", "old=new, a string to rename (repeatable)")
	flag.Parse()
	if *in == "" || (!*list && (*out == "" || len(repl) == 0)) {
		fmt.Fprintln(os.Stderr, "usage: retexture -in <base> (-list | -out <new> -set old=new [-set ...])")
		os.Exit(2)
	}
	data, err := os.ReadFile(*in)
	if err != nil {
		fail(err)
	}
	if *list {
		strs, err := retexture.Strings(data)
		if err != nil {
			fail(err)
		}
		for _, s := range strs {
			fmt.Printf("%6d  %s\n", s.Offset, s.Old)
		}
		return
	}
	res, changes, err := retexture.Patch(data, repl)
	if err != nil {
		fail(err)
	}
	for _, c := range changes {
		fmt.Printf("@%d  %s -> %s\n", c.Offset, c.Old, c.New)
	}
	if err := os.WriteFile(*out, res, 0o644); err != nil {
		fail(err)
	}
	kind, _ := retexture.Kind(res)
	switch kind {
	case "bsr":
		obj, err := bsr.Parse(res)
		if err != nil {
			fail(fmt.Errorf("the output does not parse: %w", err))
		}
		fmt.Printf("wrote %s (%d bytes): material %s, meshes %v\n", *out, len(res), obj.MaterialPath, obj.AllMeshPaths())
	default:
		m, err := bmt.Parse(res)
		if err != nil {
			fail(fmt.Errorf("the output does not parse: %w", err))
		}
		for _, l := range m.Layers {
			fmt.Printf("wrote %s (%d bytes): layer %s texture %s trailer %x\n", *out, len(res), l.Name, l.TexturePath, l.TextureBytes)
		}
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "retexture:", err)
	os.Exit(1)
}
