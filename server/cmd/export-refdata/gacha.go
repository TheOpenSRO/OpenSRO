package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gacha"
)

// exportGacha writes the Magic POP tables (round 838, internal/gacha):
// gachaitemset.txt and gachanpcmap.txt in, told apart by their file names.
func exportGacha(out string, paths []string) error {
	var items, npcs [][]string
	for _, path := range paths {
		tab, err := readTable(path)
		if err != nil {
			return fmt.Errorf("reading %s: %w", path, err)
		}
		switch base := strings.ToLower(filepath.Base(path)); {
		case strings.Contains(base, "gachaitemset"):
			items = append(items, tab...)
		case strings.Contains(base, "gachanpcmap"):
			npcs = append(npcs, tab...)
		default:
			return fmt.Errorf("-mode gacha takes gachaitemset.txt and gachanpcmap.txt, not %s", base)
		}
	}
	t, err := gacha.FromTextdata(items, npcs)
	if err != nil {
		return err
	}
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	if err := gacha.WriteCSV(f, t); err != nil {
		f.Close()
		return err
	}
	n, m := t.Len()
	fmt.Fprintf(os.Stderr, "export-refdata: %d gacha rows, %d machines -> %s\n", n, m, out)
	return f.Close()
}
