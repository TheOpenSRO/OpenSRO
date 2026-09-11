// Command export-leveldata turns a client's own
// server_dep\silkroad\textdata\leveldata.txt (UTF-16LE, tab-separated) into
// the small CSV the server loads for its EXP curve -- one "level,expToNext"
// row per level, where column 1 of leveldata.txt is the experience needed to
// advance from that level (verified: level 9's value is 17978, exactly the
// "Next Exp" a real level-9 character showed; see docs/LEVELING.md).
//
// No game data is committed: the operator runs this against their own client
// and points the server at the CSV (SRREVAMP_LEVELDATA_CSV).
//
// Usage:
//
//	export-leveldata -out leveldata.csv leveldata.txt
package main

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"os"
	"strconv"
	"strings"
	"unicode/utf16"
)

// Column indices in leveldata.txt: level, then the exp to advance from it.
const (
	colLevel  = 0
	colExpNext = 1
)

func main() {
	out := ""
	var inputs []string
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-out":
			if i+1 >= len(args) {
				fatal("-out needs a path")
			}
			i++
			out = args[i]
		default:
			inputs = append(inputs, args[i])
		}
	}
	if out == "" || len(inputs) == 0 {
		fatal("usage: export-leveldata -out leveldata.csv leveldata.txt")
	}

	rows, err := readRows(inputs[0])
	if err != nil {
		fatal("reading %s: %v", inputs[0], err)
	}

	records := toRecords(rows)
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

// toRecords turns leveldata rows into "level,exp" CSV records (with a header),
// skipping any row whose level or exp column is not a number (a header line or
// a comment).
func toRecords(rows [][]string) [][]string {
	records := [][]string{{"level", "exp"}}
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
		records = append(records, []string{strconv.Itoa(level), strconv.FormatInt(exp, 10)})
	}
	return records
}

// readRows reads a tab-separated leveldata file, decoding UTF-16LE (with BOM)
// or UTF-8, and returns each non-empty line split on tabs.
func readRows(path string) ([][]string, error) {
	raw, err := os.ReadFile(path)
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
