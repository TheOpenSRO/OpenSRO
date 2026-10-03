// Command pk2list lists file paths inside a real pk2 archive, optionally
// filtered by a case-insensitive substring, and can extract one real file
// out to disk -- a small diagnostic tool for finding and pulling real
// asset paths (e.g. terrain/ground textures) out of a real client install
// this project doesn't have a sample of, without needing to commit or
// transmit any real game data (see docs/LEGAL.md): only the printed path
// list or the one extracted file leaves the machine that already has it.
//
// Usage:
//
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2"
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2" -filter grass
//	go run ./cmd/pk2list -pk2 "C:\Silkroad\Media.pk2" -extract "minimap\100x100.ddj" -out tile.ddj
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

func main() {
	pk2Path := flag.String("pk2", "", "path to a real pk2 archive (required)")
	filter := flag.String("filter", "", "only print paths containing this substring (case-insensitive)")
	extract := flag.String("extract", "", "exact path (as printed by a plain listing) of one file to extract")
	out := flag.String("out", "", "local file path to write -extract's file to (required with -extract)")
	flag.Parse()

	if *pk2Path == "" {
		fmt.Fprintln(os.Stderr, "usage: pk2list -pk2 <path to .pk2> [-filter <substring>] [-extract <exact path> -out <local path>]")
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

	if *extract != "" {
		if *out == "" {
			fmt.Fprintln(os.Stderr, "-extract requires -out")
			os.Exit(1)
		}
		if err := extractFile(archive, root, *extract, *out); err != nil {
			fmt.Fprintln(os.Stderr, "extracting:", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "wrote %s\n", *out)
		return
	}

	filterLower := strings.ToLower(*filter)
	count := 0
	walk(archive, root, "", filterLower, &count)
	fmt.Fprintf(os.Stderr, "\n%d matching file(s)\n", count)
}

// extractFile resolves a Windows-style backslash path (as printed by a
// plain listing) against the archive, walking one directory level at a
// time, and writes that file's real bytes to localPath.
func extractFile(archive *pk2.Archive, root []pk2.Entry, path, localPath string) error {
	parts := strings.Split(strings.ReplaceAll(path, "\\", "/"), "/")
	entries := root
	for i, part := range parts {
		var found *pk2.Entry
		for j := range entries {
			if strings.EqualFold(entries[j].Name, part) {
				found = &entries[j]
				break
			}
		}
		if found == nil {
			return fmt.Errorf("%s not found", path)
		}
		if i == len(parts)-1 {
			if found.IsDir {
				return fmt.Errorf("%s is a directory, not a file", path)
			}
			data, err := archive.ReadFile(*found)
			if err != nil {
				return err
			}
			return os.WriteFile(localPath, data, 0o644)
		}
		if !found.IsDir {
			return fmt.Errorf("%s is not a directory", strings.Join(parts[:i+1], "\\"))
		}
		children, err := archive.ReadDirAt(*found)
		if err != nil {
			return err
		}
		entries = children
	}
	return fmt.Errorf("%s not found", path)
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
