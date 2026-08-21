// Command pk2list lists file paths inside a real pk2 archive, optionally
// filtered by a case-insensitive substring -- a small diagnostic tool for
// finding real asset paths (e.g. terrain/ground textures) in a real client
// install this project doesn't have a sample of, without needing to commit
// or transmit any real game data (see docs/LEGAL.md): the archive stays on
// the machine that already has it, only the printed path list leaves it.
//
// Usage:
//
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2"
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2" -filter grass
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/OpenSRO/srrevamp/server/internal/pk2"
)

func main() {
	pk2Path := flag.String("pk2", "", "path to a real pk2 archive (required)")
	filter := flag.String("filter", "", "only print paths containing this substring (case-insensitive)")
	flag.Parse()

	if *pk2Path == "" {
		fmt.Fprintln(os.Stderr, "usage: pk2list -pk2 <path to .pk2> [-filter <substring>]")
		os.Exit(1)
	}

	archive, err := pk2.Open(*pk2Path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "opening archive:", err)
		os.Exit(1)
	}
	defer archive.Close()

	root, err := archive.ReadDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "reading root:", err)
		os.Exit(1)
	}

	filterLower := strings.ToLower(*filter)
	count := 0
	walk(archive, root, "", filterLower, &count)
	fmt.Fprintf(os.Stderr, "\n%d matching file(s)\n", count)
}

func walk(archive *pk2.Archive, entries []pk2.Entry, prefix string, filterLower string, count *int) {
	for _, e := range entries {
		if e.Name == "." || e.Name == ".." {
			continue
		}
		path := e.Name
		if prefix != "" {
			path = prefix + "\\" + e.Name
		}
		if e.IsDir {
			children, err := archive.ReadDirAt(e)
			if err != nil {
				fmt.Fprintf(os.Stderr, "reading %s: %v\n", path, err)
				continue
			}
			walk(archive, children, path, filterLower, count)
			continue
		}
		if filterLower == "" || strings.Contains(strings.ToLower(path), filterLower) {
			fmt.Printf("%10d  %s\n", e.Size, path)
			*count++
		}
	}
}
