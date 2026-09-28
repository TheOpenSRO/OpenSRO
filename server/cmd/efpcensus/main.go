// Command efpcensus measures how much of a real Particles.pk2 the typed .efp
// decoder (internal/efp) reads: headers parsed, trees decoded to the exact
// byte, what fails and why, and which features the files use. It reads the
// player's own archive at runtime and prints only counts and paths, never
// file contents (docs/LEGAL.md).
//
// Usage:
//
//	go run ./cmd/efpcensus -pk2 /opt/sro-files/client/Particles.pk2
//	go run ./cmd/efpcensus -pk2 Particles.pk2 -show "skill\china\water_hide_keep_a.efp"
//	go run ./cmd/efpcensus -pk2 Particles.pk2 -dump   # one md5 per file, for efp_dump_diff.sh
package main

import (
	"crypto/md5"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/OpenSRO/srrevamp/server/internal/efp"
	"github.com/OpenSRO/srrevamp/server/internal/pk2"
)

func main() {
	pk2Path := flag.String("pk2", "", "path to Particles.pk2 (required)")
	show := flag.String("show", "", "print the decoded node tree of this one .efp instead of the census")
	dump := flag.Bool("dump", false, "print '<md5 of the canonical dump> <path>' for every decoded file (compare with client/tools/efp_dump.gd)")
	dumpOne := flag.String("dumpone", "", "print the full canonical dump of this one .efp")
	flag.Parse()
	if *pk2Path == "" {
		fmt.Fprintln(os.Stderr, "usage: efpcensus -pk2 <Particles.pk2> [-show <path>]")
		os.Exit(1)
	}
	a, err := pk2.Open(*pk2Path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "opening archive:", err)
		os.Exit(1)
	}
	defer a.Close()
	root, err := a.ReadDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "reading root:", err)
		os.Exit(1)
	}
	c := efp.NewCensus()
	var walk func([]pk2.Entry, string)
	walk = func(es []pk2.Entry, prefix string) {
		for _, e := range es {
			if e.Name == "." || e.Name == ".." {
				continue
			}
			p := e.Name
			if prefix != "" {
				p = prefix + "\\" + e.Name
			}
			if e.IsDir {
				kids, err := a.ReadDirAt(e)
				if err != nil {
					fmt.Fprintf(os.Stderr, "reading %s: %v\n", p, err)
					continue
				}
				walk(kids, p)
				continue
			}
			if !strings.HasSuffix(strings.ToLower(p), ".efp") {
				continue
			}
			if *show != "" && !strings.EqualFold(p, *show) {
				continue
			}
			if *dumpOne != "" && !strings.EqualFold(p, *dumpOne) {
				continue
			}
			data, err := a.ReadFile(e)
			if err != nil {
				fmt.Fprintf(os.Stderr, "reading %s: %v\n", p, err)
				continue
			}
			if *show != "" {
				printTree(p, data)
				continue
			}
			if *dump || *dumpOne != "" {
				f, err := efp.Decode(data)
				if err != nil {
					continue
				}
				if *dumpOne != "" {
					fmt.Print(efp.Dump(f))
				} else {
					fmt.Printf("%x %s\n", md5.Sum([]byte(efp.Dump(f))), p)
				}
				continue
			}
			c.Add(p, data)
		}
	}
	walk(root, "")
	if *show == "" && !*dump && *dumpOne == "" {
		c.Report(os.Stdout)
	}
}

func printTree(path string, data []byte) {
	f, err := efp.Decode(data)
	if err != nil {
		fmt.Printf("%s: %v\n", path, err)
		return
	}
	fmt.Printf("%s  version %s  trailing %d\n", path, f.Version, f.Trailing)
	var show func(n *efp.Node, depth int)
	show = func(n *efp.Node, depth int) {
		ind := strings.Repeat("  ", depth)
		fmt.Printf("%snode %q headlen=%d frames=%d view=%s render=%s src/dest=%d/%d\n",
			ind, n.Name, n.HeadLen, n.Frames, n.ViewMode(), n.RenderMode(), n.State.SrcBlend, n.State.DestBlend)
		if n.Extinct != nil {
			fmt.Printf("%s  life: %s\n", ind, n.Extinct.Name)
		}
		if e := n.Emission(); e != nil {
			// Run the emitter over the node's frames at full quality with
			// no deaths: what the first life spawns, frame by frame.
			var acc float32
			var spawns []int
			for age := 0; age < int(n.Frames); age++ {
				k, next, stopped := e.Tick(age, acc, efp.DefaultEmitGlobals)
				acc = next
				if stopped {
					break
				}
				if k != 0 {
					spawns = append(spawns, age, k)
				}
			}
			fmt.Printf("%s  emit: %+v; spawns (frame, count) with no deaths: %v\n", ind, *e, spawns)
		}
		for _, m := range n.Meshes {
			fmt.Printf("%s  mesh %q textures %q\n", ind, m.Mesh, m.Textures)
		}
		for _, cm := range n.Commands {
			s, e, st, ok := cm.FrameRange(int(n.Frames))
			fmt.Printf("%s  %s space=%d frames %d..%d step %g ok=%v", ind, cm.Name, cm.Space, s, e, st, ok)
			if cm.Value != nil {
				fmt.Printf(" %s", cm.Value.TypeName())
			}
			fmt.Println()
		}
		for _, k := range n.Children {
			show(k, depth+1)
		}
	}
	show(f.Root, 0)
}
