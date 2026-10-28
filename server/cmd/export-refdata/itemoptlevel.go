package main

import (
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// exportItemOptLevel joins the three by-opt-level tables (round 838):
// refabilitybyitemoptleveldata.txt (Service, AbilityID, RefItemID, OptLevel),
// refmagicoptbyitemoptleveldata.txt (AbilityID, magic option id, value, ...)
// and refskillbyitemoptleveldata.txt (AbilityID, skill id) -- what an awake
// devil's spirit gives at its plus level (GObjPC FUN_00498020: FUN_00498160
// reads the ability by RefItemID + OptLevel, then each magic option row's id
// (+0x10) and value (+0x14); FUN_00498370 each skill row; READ). One CSV row
// per grant: RefItemID, OptLevel, "opt" or "skill", the id, the value (0 for
// a skill). A row of Service 0 is left out.
func exportItemOptLevel(out string, paths []string) error {
	var abilityPath, optPath, skillPath string
	for _, p := range paths {
		switch strings.ToLower(filepath.Base(p)) {
		case "refabilitybyitemoptleveldata.txt":
			abilityPath = p
		case "refmagicoptbyitemoptleveldata.txt":
			optPath = p
		case "refskillbyitemoptleveldata.txt":
			skillPath = p
		}
	}
	if abilityPath == "" || optPath == "" || skillPath == "" {
		return fmt.Errorf("-mode itemoptlevel reads refabilitybyitemoptleveldata.txt, refmagicoptbyitemoptleveldata.txt and refskillbyitemoptleveldata.txt (got %q)", paths)
	}
	if out == "-" || out == "" {
		return fmt.Errorf("-mode itemoptlevel writes a file: -out must name it")
	}
	num := func(path string, row int, s string) (int64, error) {
		v, err := strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(s, "\uFEFF")), 10, 64)
		if err != nil {
			return 0, fmt.Errorf("%s: row %d: %q is not a number", path, row, s)
		}
		return v, nil
	}
	type ability struct{ item, level int64 }
	abilities := map[int64]ability{}
	var order []int64
	rows, err := readTable(abilityPath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", abilityPath, err)
	}
	for i, cols := range rows {
		if len(cols) < 4 {
			return fmt.Errorf("%s: row %d has %d fields, want 4", abilityPath, i+1, len(cols))
		}
		var v [4]int64
		for k := 0; k < 4; k++ {
			if v[k], err = num(abilityPath, i+1, cols[k]); err != nil {
				return err
			}
		}
		if v[0] == 0 {
			continue
		}
		if _, dup := abilities[v[1]]; !dup {
			order = append(order, v[1])
		}
		abilities[v[1]] = ability{item: v[2], level: v[3]}
	}
	grants := map[int64][][]string{}
	rows, err = readTable(optPath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", optPath, err)
	}
	for i, cols := range rows {
		if len(cols) < 3 {
			return fmt.Errorf("%s: row %d has %d fields, want 3 or more", optPath, i+1, len(cols))
		}
		var v [3]int64
		for k := 0; k < 3; k++ {
			if v[k], err = num(optPath, i+1, cols[k]); err != nil {
				return err
			}
		}
		grants[v[0]] = append(grants[v[0]], []string{"opt", strconv.FormatInt(v[1], 10), strconv.FormatInt(v[2], 10)})
	}
	rows, err = readTable(skillPath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", skillPath, err)
	}
	for i, cols := range rows {
		if len(cols) < 2 {
			return fmt.Errorf("%s: row %d has %d fields, want 2", skillPath, i+1, len(cols))
		}
		a, err := num(skillPath, i+1, cols[0])
		if err != nil {
			return err
		}
		s, err := num(skillPath, i+1, cols[1])
		if err != nil {
			return err
		}
		grants[a] = append(grants[a], []string{"skill", strconv.FormatInt(s, 10), "0"})
	}
	var recs [][]string
	for _, id := range order {
		a := abilities[id]
		for _, g := range grants[id] {
			recs = append(recs, append([]string{strconv.FormatInt(a.item, 10), strconv.FormatInt(a.level, 10)}, g...))
		}
	}
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	w := csv.NewWriter(f)
	if err := w.WriteAll(recs); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d by-opt-level grants for %d abilities\n", len(recs), len(order))
	return nil
}
