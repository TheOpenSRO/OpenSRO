// Command export-leveldata turns a client's own
// server_dep\silkroad\textdata\leveldata.txt (UTF-16LE, tab-separated) into
// the small CSV the server loads for its EXP curve -- one "level,expToNext"
// row per level, where column 1 of leveldata.txt is the experience needed to
// advance from that level (verified: level 9's value is 17978, exactly the
// "Next Exp" a real level-9 character showed; see docs/LEVELING.md).
//
// No game data is committed: the operator runs this against their own client
// and points the server at the CSV (OPENSRO_LEVELDATA_CSV).
//
// Usage:
//
//	export-leveldata -out leveldata.csv [-levelgold levelgold.txt] leveldata.txt
//
// Round 799 appends the job exp columns (leveldata.txt 6..8) and, with
// -levelgold, the level's gold minimum (levelgold.txt column 1): the job
// system's curve and its level unit.
package main

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"os"
	"strconv"
	"strings"
	"unicode/utf16"

	"github.com/OpenSRO/OpenSRO/server/internal/assetfs"
)

// Column indices in leveldata.txt: level, then the exp to advance from it.
const (
	colLevel   = 0
	colExpNext = 1
	// Column 2 is the skill-point cost to raise a mastery one level. The
	// server's mastery level-up handler sums exactly this field over the
	// levels being raised; see leveldata.Table.MasteryUpCost.
	colMasterySP = 2
	// colExpUnit is the per-level standard EXP unit -- what a kill is worth
	// before the level-gap scalers. RECOVERED: the server's own
	// Formula_MonsterExpReward reads the level record's +0x1c, and
	// FUN_00631050 hands `entry[0x1c] * multiplier` straight to
	// GObjPC_GainExpAndLevel as an exp amount. See docs/RE_COMPLETION.md for
	// why +0x1c is column 5 (every other packing puts a provably impossible
	// value there). Verified identical in the ORIGINAL client's leveldata.txt
	// and the pserver's: 24, 47, 71, 94 ... 470 at level 20, 12550 at 110.
	colExpUnit = 5
	// colJobTrader..colJobHunter are the job exp columns 6, 7 and 8 (round
	// 799; READ the server's FUN_0060dd90 reading the level record's +0x20,
	// +0x24, +0x28 by job kind, docs/protocol/jobs.md).
	colJobTrader = 6
	colJobHunter = 8
)

func main() {
	out := ""
	levelGold := ""
	var inputs []string
	// Round 789: -archives reads leveldata.txt through the layered file
	// system (docs/protocol/asset_packs.md) instead of a loose file.
	af := assetfs.InputFlags{Source: "mixed", Volume: "Media", TextData: assetfs.TextDataDir}
	strFlags := map[string]*string{"-out": &out, "-levelgold": &levelGold, "-archives": &af.Archives, "-source": &af.Source,
		"-custom": &af.Custom, "-volume": &af.Volume, "-textdata": &af.TextData}
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		if dst, ok := strFlags[args[i]]; ok {
			if i+1 >= len(args) {
				fatal("%s needs a value", args[i])
			}
			i++
			*dst = args[i]
			continue
		}
		if args[i] == "-no-custom" {
			af.NoCustom = true
			continue
		}
		inputs = append(inputs, args[i])
	}
	if out == "" || len(inputs) == 0 {
		fatal("usage: export-leveldata [-archives <folder> [-source pk2|pk3|mixed] [-volume Media]] -out leveldata.csv leveldata.txt")
	}
	in, fsys, err := af.Open(func(format string, a ...any) {
		fmt.Fprintf(os.Stderr, "export-leveldata: "+format+"\n", a...)
	})
	if err != nil {
		fatal("-archives: %v", err)
	}
	if fsys != nil {
		defer fsys.Close()
	}
	readInput = in.ReadFile

	rows, err := readRows(inputs[0])
	if err != nil {
		fatal("reading %s: %v", inputs[0], err)
	}

	var gold map[int]string
	if levelGold != "" {
		grows, err := readRows(levelGold)
		if err != nil {
			fatal("reading %s: %v", levelGold, err)
		}
		gold = goldMins(grows)
	}
	records := toRecords(rows, gold)
	if len(records) == 1 {
		fatal("no level rows parsed from %s", inputs[0])
	}

	f, err := os.Create(out)
	if err != nil {
		fatal("creating %s: %v", out, err)
	}
	defer f.Close()
	w := csv.NewWriter(f)
	if err := w.WriteAll(records); err != nil {
		fatal("writing %s: %v", out, err)
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "wrote %d levels to %s\n", len(records)-1, out)
}

// toRecords turns leveldata rows into "level,exp,mastery_sp" CSV records (with
// a header), skipping any row whose level or exp column is not a number (a
// header line or a comment).
func toRecords(rows [][]string, gold map[int]string) [][]string {
	records := [][]string{{"level", "exp", "mastery_sp", "exp_unit", "job_trader", "job_robber", "job_hunter", "gold_min"}}
	for _, cols := range rows {
		if len(cols) <= colExpNext {
			continue
		}
		level, err := strconv.Atoi(strings.TrimSpace(cols[colLevel]))
		if err != nil {
			continue
		}
		exp, err := strconv.ParseInt(strings.TrimSpace(cols[colExpNext]), 10, 64)
		if err != nil {
			continue
		}
		masterySP := "0"
		if len(cols) > colMasterySP {
			if v, err := strconv.Atoi(strings.TrimSpace(cols[colMasterySP])); err == nil {
				masterySP = strconv.Itoa(v)
			}
		}
		expUnit := "0"
		if len(cols) > colExpUnit {
			if v, err := strconv.Atoi(strings.TrimSpace(cols[colExpUnit])); err == nil {
				expUnit = strconv.Itoa(v)
			}
		}
		rec := []string{strconv.Itoa(level), strconv.FormatInt(exp, 10), masterySP, expUnit}
		for c := colJobTrader; c <= colJobHunter; c++ {
			v := "0"
			if len(cols) > c {
				if n, err := strconv.ParseInt(strings.TrimSpace(cols[c]), 10, 64); err == nil {
					v = strconv.FormatInt(n, 10)
				}
			}
			rec = append(rec, v)
		}
		g := gold[level]
		if g == "" {
			g = "0"
		}
		records = append(records, append(rec, g))
	}
	return records
}

// goldMins is levelgold.txt's level -> minimum (columns 0 and 1).
func goldMins(rows [][]string) map[int]string {
	out := map[int]string{}
	for _, cols := range rows {
		if len(cols) < 2 {
			continue
		}
		level, err := strconv.Atoi(strings.TrimSpace(cols[0]))
		if err != nil {
			continue
		}
		if v, err := strconv.ParseInt(strings.TrimSpace(cols[1]), 10, 64); err == nil {
			out[level] = strconv.FormatInt(v, 10)
		}
	}
	return out
}

// readInput reads an input: a loose file, or through -archives (round 789).
var readInput = os.ReadFile

// readRows reads a tab-separated leveldata file, decoding UTF-16LE (with BOM)
// or UTF-8, and returns each non-empty line split on tabs.
func readRows(path string) ([][]string, error) {
	raw, err := readInput(path)
	if err != nil {
		return nil, err
	}
	return readRowsFromBytes(raw)
}

func readRowsFromBytes(raw []byte) ([][]string, error) {
	text := decode(raw)
	var out [][]string
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" {
			continue
		}
		out = append(out, strings.Split(line, "\t"))
	}
	return out, sc.Err()
}

// decode honours a UTF-16LE BOM (what the Media text tables use), falling back
// to UTF-8.
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

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
