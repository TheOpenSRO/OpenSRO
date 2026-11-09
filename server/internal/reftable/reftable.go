// Package reftable reads a reference table the way an operator exports one
// from the shard database: a header row of column names and one row per
// record, separated by '~', '|', a tab or a comma (quoted CSV), with or
// without the dashes line a SQL console prints under the header and with or
// without a UTF-8 byte-order mark. It is what cmd/export-refdata's
// -mode gameworlds reads (round 869) and what internal/gameworld and
// internal/trigger read the normalised CSVs back with. OURS: the format is
// OpenSRO's own; the tables and their columns are the shard database's.
package reftable

import (
	"bufio"
	"bytes"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// Table is one table: its columns and its rows, every row as long as the
// header (a short row is padded with "").
type Table struct {
	Columns []string
	Rows    [][]string
	index   map[string]int
}

// New makes a table of columns with no rows.
func New(columns ...string) *Table {
	t := &Table{Columns: append([]string(nil), columns...)}
	t.reindex()
	return t
}

func (t *Table) reindex() {
	t.index = make(map[string]int, len(t.Columns))
	for i, c := range t.Columns {
		t.index[strings.ToLower(strings.TrimSpace(c))] = i
	}
}

// Has reports whether the table has the column (case-insensitive).
func (t *Table) Has(col string) bool {
	_, ok := t.index[strings.ToLower(col)]
	return ok
}

// Get is row's value in col ("" for a column the table lacks), trimmed.
func (t *Table) Get(row []string, col string) string {
	i, ok := t.index[strings.ToLower(col)]
	if !ok || i >= len(row) {
		return ""
	}
	return strings.TrimSpace(row[i])
}

// Int is Get as an integer; "", "NULL" and a value that does not parse are 0
// (a float such as "3.0" is truncated).
func (t *Table) Int(row []string, col string) int64 {
	s := t.Get(row, col)
	if s == "" || strings.EqualFold(s, "NULL") {
		return 0
	}
	if v, err := strconv.ParseInt(s, 10, 64); err == nil {
		return v
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return int64(f)
	}
	return 0
}

// Float is Get as a float; "" and "NULL" are 0.
func (t *Table) Float(row []string, col string) float64 {
	s := t.Get(row, col)
	if s == "" || strings.EqualFold(s, "NULL") {
		return 0
	}
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

// Append adds a row (padded or cut to the header's length).
func (t *Table) Append(row ...string) {
	r := make([]string, len(t.Columns))
	copy(r, row)
	t.Rows = append(t.Rows, r)
}

// ReadFile reads the table in path.
func ReadFile(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	t, err := Read(f)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return t, nil
}

// Read reads a table. The separator is the first of '~', '|', tab and ','
// found in the header line.
func Read(r io.Reader) (*Table, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	nl := strings.IndexByte(text, '\n')
	header := text
	if nl >= 0 {
		header = text[:nl]
	}
	if strings.TrimSpace(header) == "" {
		return nil, fmt.Errorf("reftable: no header row")
	}
	sep := ','
	for _, c := range []rune{'~', '|', '\t'} {
		if strings.ContainsRune(header, c) {
			sep = c
			break
		}
	}
	t := &Table{}
	if sep == ',' {
		cr := csv.NewReader(strings.NewReader(text))
		cr.LazyQuotes = true
		cr.FieldsPerRecord = -1
		recs, err := cr.ReadAll()
		if err != nil {
			return nil, err
		}
		if len(recs) == 0 {
			return nil, fmt.Errorf("reftable: no header row")
		}
		t.Columns = recs[0]
		t.reindex()
		for _, rec := range recs[1:] {
			if dashes(rec) {
				continue
			}
			t.Append(rec...)
		}
		return t, nil
	}
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first {
			t.Columns = strings.Split(line, string(sep))
			t.reindex()
			first = false
			continue
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		rec := strings.Split(line, string(sep))
		if dashes(rec) {
			continue
		}
		t.Append(rec...)
	}
	return t, sc.Err()
}

// dashes reports a SQL console's underline row (every field only dashes).
func dashes(rec []string) bool {
	any := false
	for _, f := range rec {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		if strings.Trim(f, "-") != "" {
			return false
		}
		any = true
	}
	return any
}

// WriteCSV writes the table as a comma-separated file with a header row.
func (t *Table) WriteCSV(w io.Writer) error {
	cw := csv.NewWriter(w)
	if err := cw.Write(t.Columns); err != nil {
		return err
	}
	for _, r := range t.Rows {
		if err := cw.Write(r); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}
