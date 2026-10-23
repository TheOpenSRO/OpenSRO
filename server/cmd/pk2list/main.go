// Command pk2list lists file paths inside a real pk2 archive, optionally
// filtered by a case-insensitive substring, and can extract one real file
// out to disk -- a small diagnostic tool for finding and pulling real
// asset paths (e.g. terrain/ground textures) out of a real client install
// this project doesn't have a sample of, without needing to commit or
// transmit any real game data (see docs/LEGAL.md): only the printed path
// list or the one extracted file leaves the machine that already has it.
//
// Round 789: -pk2 also takes a `.pk3`/`.zip`, and -archives reads a whole
// folder through the layered asset file system (docs/protocol/asset_packs.md):
// custom/, the packs, then the base archives, as every reader sees them.
//
// Usage:
//
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2"
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2" -filter grass
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2" -extract "minimap\100x100.ddj" -out tile.ddj
//	go run ./cmd/pk2list -archives /srv/sro/client -layers
//	go run ./cmd/pk2list -archives /srv/sro/client -which "prim\mtrl\foo.ddj"
//	go run ./cmd/pk2list -archives /srv/sro/client -volume Media -extract "server_dep\silkroad\textdata\itemdata.txt" -out itemdata.txt
//	go run ./cmd/pk2list -archives /srv/sro/client -overrides
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/assetfs"
)

func main() {
	pk2Path := flag.String("pk2", "", "path to one archive: a real .pk2, or a .pk3/.zip")
	archives := flag.String("archives", "", "a folder of archives, read through the layered file system (custom/, packs, base archives)")
	source := flag.String("source", "mixed", "with -archives: the source mode, pk2, pk3 or mixed")
	custom := flag.String("custom", "", "with -archives: the loose overlay folder (default the custom folder beside <archives>, as the client has it, when it exists)")
	noCustom := flag.Bool("no-custom", false, "with -archives: no loose overlay folder")
	volume := flag.String("volume", "", "with -archives: look up as a reader of this base archive does (Data, Map, Media, Music or Particles): the packs, then only that archive")
	filter := flag.String("filter", "", "only print paths containing this substring (case-insensitive)")
	extract := flag.String("extract", "", "exact path (as printed by a plain listing) of one file to extract")
	out := flag.String("out", "", "local file path to write -extract's file to (required with -extract)")
	which := flag.String("which", "", "with -archives: print every layer that has this path, the one that serves it first")
	layers := flag.Bool("layers", false, "with -archives: print the layer stack, highest first")
	overrides := flag.Bool("overrides", false, "with -archives: print every custom/ or pack file that overrides a lower layer's")
	showLayer := flag.Bool("l", false, "print the serving layer after each listed path")
	flag.Parse()

	if (*pk2Path == "") == (*archives == "") {
		fmt.Fprintln(os.Stderr, "usage: pk2list -pk2 <archive> [-filter <substring>] [-extract <exact path> -out <local path>]")
		fmt.Fprintln(os.Stderr, "       pk2list -archives <folder> [-source pk2|pk3|mixed] [-custom <dir>|-no-custom] [-volume <base>]")
		fmt.Fprintln(os.Stderr, "               [-filter s] [-l] [-extract p -out f] [-which p] [-layers] [-overrides]")
		os.Exit(1)
	}

	var fsys *assetfs.FS
	var err error
	if *pk2Path != "" {
		fsys, err = assetfs.OpenArchive(*pk2Path, nil)
	} else {
		mode, merr := assetfs.ParseMode(*source)
		if merr != nil {
			fmt.Fprintln(os.Stderr, merr)
			os.Exit(1)
		}
		fsys, err = assetfs.Open(*archives, assetfs.Options{
			Mode: mode, CustomDir: *custom, NoCustom: *noCustom,
			Logf: func(format string, a ...any) {
				if !strings.Contains(format, "overrides") { // -overrides prints those
					fmt.Fprintf(os.Stderr, format+"\n", a...)
				}
			},
		})
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "opening archive:", err)
		os.Exit(1)
	}
	defer fsys.Close()
	for _, l := range fsys.Layers() {
		if *pk2Path != "" {
			for _, r := range l.Rejected {
				fmt.Fprintf(os.Stderr, "%s: refused entry %s\n", l.Name, r)
			}
		}
	}
	view := fsys.View
	if *volume != "" {
		if view, err = fsys.In(*volume); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}

	switch {
	case *layers:
		for i, l := range view.Layers() {
			extra := ""
			if l.Volume != "" {
				extra = " (" + l.Volume + ")"
			}
			if n := len(l.Rejected); n > 0 {
				extra += fmt.Sprintf(", %d entries refused", n)
			}
			if a := fsys.Added(l); a > 0 {
				extra += fmt.Sprintf(", %d files no lower layer has", a)
			}
			fmt.Printf("%2d  %-6s  %s%s\n", i+1, l.Kind, l.Path, extra)
		}
		return
	case *overrides:
		for _, o := range fsys.Overrides() {
			fmt.Printf("%s  %s  over %s\n", o.Layer.Name, o.Path, o.Over.Name)
		}
		fmt.Fprintf(os.Stderr, "\n%d override(s)\n", len(fsys.Overrides()))
		return
	case *which != "":
		hits, err := view.WhichAll(*which)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if len(hits) == 0 {
			fmt.Fprintf(os.Stderr, "%s: no layer has it\n", *which)
			os.Exit(1)
		}
		for i, h := range hits {
			mark := "serves"
			if i > 0 {
				mark = "hidden"
			}
			kind := "file"
			if h.IsDir {
				kind = "folder"
			}
			fmt.Printf("%-6s  %-14s  %10d  %s  (%s)\n", mark, h.Layer.Name, h.Size, h.Path, kind)
		}
		return
	case *extract != "":
		if *out == "" {
			fmt.Fprintln(os.Stderr, "-extract requires -out")
			os.Exit(1)
		}
		data, err := view.ReadFile(*extract)
		if err != nil {
			fmt.Fprintln(os.Stderr, "extracting:", err)
			os.Exit(1)
		}
		if err := os.WriteFile(*out, data, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "extracting:", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "wrote %s\n", *out)
		return
	}

	filterLower := strings.ToLower(*filter)
	count := 0
	err = view.Walk(func(i assetfs.Info) error {
		if i.IsDir {
			return nil
		}
		if filterLower == "" || strings.Contains(strings.ToLower(i.Path), filterLower) {
			if *showLayer {
				fmt.Printf("%10d  %s  %s\n", i.Size, i.Path, i.Layer.Name)
			} else {
				fmt.Printf("%10d  %s\n", i.Size, i.Path)
			}
			count++
		}
		return nil
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "listing:", err)
	}
	fmt.Fprintf(os.Stderr, "\n%d matching file(s)\n", count)
}
