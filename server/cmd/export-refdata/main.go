// Command export-refdata turns a client's own itemdata text tables (the
// Media.pk2 `server_dep\silkroad\textdata\itemdata*.txt` files, which are
// the game's _RefObjItem table dumped tab-separated) into the headerless
// CSV that import-refdata loads. No game data ships with this tool or the
// repo -- the operator points it at their own extracted tables, exactly as
// the client is pointed at their own pk2.
//
//	export-refdata -out items.csv itemdata_1000.txt itemdata_5000.txt ...
//	import-refdata -items-csv items.csv -postgres-dsn ...
//
// Column mapping. The itemdata fields are 0-indexed here (field 0 is the
// leading "service" column, field 1 the id). Each mapping below is either
// measured against real rows and, where a ground truth existed, verified,
// or left at an honest default when this project has not established the
// column yet -- never a guess dressed as data. The verification: a real
// Copper Sword (+5) tooltip a player sent reads exactly the physical
// attack (field 96/98, base 15/16), magical attack (101/103, 25/28),
// durability (64/65, 62/76), attack rate (114) and critical (117) these
// columns hold; the attack columns are the same for the bow and spear.
// See docs/protocol/ITEM_FORMAT.md and WORLD_ISSUES.md.
//
// Left at defaults, and why it is safe: MaxStack is 1 for every row --
// the server's current (no-refdata) behaviour already treats every item
// as one-to-a-slot, so this changes nothing there, and the real per-item
// stack sizes are not yet mapped. Physical/magical DEFENCE is 0: armour
// stores its defence in different columns than a weapon's attack, and this
// project has no ground-truth armour tooltip to label them, so rather than
// guess they are left empty -- combat does not read defence, and the only
// effect is that the shop prices armour at its base price. ItemClass and
// TwoHanded are 0/false, no worse than the "unknown item" the server sees
// today. When an armour tooltip or the _RefObjItem schema pins the rest,
// fill these in here.
package main

import (
	"bufio"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"unicode/utf16"
)

// Field indices into a tab-split itemdata row (0-indexed; field 0 is the
// leading service column).
const (
	fID            = 1
	fTypeID1       = 9  // TypeID1..4 run 9..12
	fCountry       = 14
	fReqLevelType1 = 32
	fReqLevel1     = 33
	fReqGender     = 58
	fReqStr        = 59
	fReqInt        = 60
	fDurabilityMin = 63 // and 64 for max
	fPhysAttackMin = 95 // and 97 for max (96/98 one-indexed)
	fPhysAttackMax = 97
	fMagAttackMin  = 100
	fMagAttackMax  = 102
	fHitRate       = 113
	fCritical      = 116
	// The highest field any mapping reads: a row shorter than this is not a
	// real item row and is skipped.
	fMax = 116
)

func main() {
	out := flag.String("out", "-", "output CSV path, or - for stdout")
	flag.Parse()
	if flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: export-refdata -out items.csv <itemdata_*.txt> ...")
		os.Exit(2)
	}

	var sink *os.File
	if *out == "-" {
		sink = os.Stdout
	} else {
		f, err := os.Create(*out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "creating %s: %v\n", *out, err)
			os.Exit(1)
		}
		defer f.Close()
		sink = f
	}
	w := csv.NewWriter(sink)
	defer w.Flush()

	written, skipped := 0, 0
	for _, path := range flag.Args() {
		rows, err := readTable(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "reading %s: %v\n", path, err)
			os.Exit(1)
		}
		for _, cols := range rows {
			rec, ok := itemRecord(cols)
			if !ok {
				skipped++
				continue
			}
			if err := w.Write(rec); err != nil {
				fmt.Fprintf(os.Stderr, "writing: %v\n", err)
				os.Exit(1)
			}
			written++
		}
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d item rows, skipped %d non-item rows\n", written, skipped)
}

// itemRecord maps one tab-split itemdata row to the 28-column CSV
// import-refdata expects, or (nil, false) if the row is not a real item.
func itemRecord(cols []string) ([]string, bool) {
	if len(cols) <= fMax {
		return nil, false
	}
	if _, err := strconv.Atoi(strings.TrimSpace(cols[fID])); err != nil {
		return nil, false
	}
	get := func(i int) string {
		s := strings.TrimSpace(cols[i])
		if s == "" {
			return "0"
		}
		return s
	}
	// A float field: itemdata writes some as "2.4"; keep as-is, default 0.
	num := func(i int) string {
		s := strings.TrimSpace(cols[i])
		if _, err := strconv.ParseFloat(s, 64); err != nil {
			return "0"
		}
		return s
	}
	return []string{
		get(fID),          // 0  ID
		"1",               // 1  MaxStack (default -- see package doc)
		get(fReqStr),      // 2  ReqStr
		get(fReqInt),      // 3  ReqInt
		"0",               // 4  ItemClass (not mapped)
		"0",               // 5  TwoHanded (not mapped)
		num(fDurabilityMin),     // 6  DurabilityMin
		num(fDurabilityMin + 1), // 7  DurabilityMax
		"0", "0",          // 8,9   PhysDefenseMin/Max (armour, not verified)
		"0", "0",          // 10,11 MagDefenseMin/Max
		num(fPhysAttackMin), // 12 PhysAttackMin
		num(fPhysAttackMax), // 13 PhysAttackMax
		num(fMagAttackMin),  // 14 MagAttackMin
		num(fMagAttackMax),  // 15 MagAttackMax
		num(fHitRate),       // 16 HitRateMin
		num(fHitRate + 1),   // 17 HitRateMax
		num(fCritical),      // 18 CriticalMin
		num(fCritical + 1),  // 19 CriticalMax
		get(fTypeID1),       // 20 TypeID1
		get(fTypeID1 + 1),   // 21 TypeID2
		get(fTypeID1 + 2),   // 22 TypeID3
		get(fTypeID1 + 3),   // 23 TypeID4
		get(fCountry),       // 24 Country
		get(fReqGender),     // 25 ReqGender
		get(fReqLevelType1), // 26 ReqLevelType1
		get(fReqLevel1),     // 27 ReqLevel1
	}, true
}

// readTable reads a tab-separated itemdata file, decoding UTF-16LE (with or
// without a BOM) or UTF-8, and returns each non-empty, non-comment line
// split on tabs.
func readTable(path string) ([][]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := decode(raw)
	var out [][]string
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		out = append(out, strings.Split(line, "\t"))
	}
	return out, sc.Err()
}

// decode turns raw bytes into a string, honouring a UTF-16LE BOM (the form
// the Media text tables use) and falling back to UTF-8.
func decode(raw []byte) string {
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		u16 := make([]uint16, 0, (len(raw)-2)/2)
		for i := 2; i+1 < len(raw); i += 2 {
			u16 = append(u16, uint16(raw[i])|uint16(raw[i+1])<<8)
		}
		return string(utf16.Decode(u16))
	}
	return string(raw)
}
