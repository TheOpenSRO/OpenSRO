package skillparam

// Runs (round 785): a walked Param block with its values, so a mechanic can
// ask "does this row carry code X, and with what values" the way the engine's
// fields answer it -- RefSkill_ParseParams (0x587630) stores, for a fixed
// run, a pointer to the word after the code, and a reader takes value[i] as
// the i-th word there. An array code ('reqi') fills a slot per occurrence;
// for the others only the first run counts, as a second occurrence would
// overwrite the same field with a later pointer -- the LAST one wins in the
// engine. Values therefore answers the last run of a code, All every run.

// Runs is a walked block.
type Runs struct {
	words   []int32
	entries []Entry
	// Complete is the walk's answer: false when it stopped on a word that is
	// no code (never on a retail row).
	Complete bool
}

// WalkRuns walks words (the block after the action kind).
func WalkRuns(words []int32) Runs {
	e, _, complete := Walk(words)
	return Runs{words: words, entries: e, Complete: complete}
}

// valuesOf returns the values of one entry: the Run-1 words after its code.
func (r Runs) valuesOf(e Entry) []int32 {
	start := e.Index + 1
	end := e.Index + e.Run
	if end > len(r.words) {
		end = len(r.words)
	}
	if start > end {
		return nil
	}
	return r.words[start:end]
}

// Has reports whether the block carries code.
func (r Runs) Has(code Code) bool {
	for _, e := range r.entries {
		if e.Code == code {
			return true
		}
	}
	return false
}

// Values returns the values of the LAST run of code (the field the engine
// keeps), and whether there is one.
func (r Runs) Values(code Code) ([]int32, bool) {
	var out []int32
	found := false
	for _, e := range r.entries {
		if e.Code == code {
			out, found = r.valuesOf(e), true
		}
	}
	return out, found
}

// Value returns value[i] of code's run, 0 when absent or short.
func (r Runs) Value(code Code, i int) int32 {
	v, ok := r.Values(code)
	if !ok || i < 0 || i >= len(v) {
		return 0
	}
	return v[i]
}

// All returns the values of every run of code, in block order.
func (r Runs) All(code Code) [][]int32 {
	var out [][]int32
	for _, e := range r.entries {
		if e.Code == code {
			out = append(out, r.valuesOf(e))
		}
	}
	return out
}

// Codes returns every code the block carries, in order, once each.
func (r Runs) Codes() []Code {
	seen := map[Code]bool{}
	var out []Code
	for _, e := range r.entries {
		if !seen[e.Code] {
			seen[e.Code] = true
			out = append(out, e.Code)
		}
	}
	return out
}

// GetvValue returns the values after a 'getv' prefix run whose sub-code is
// sub (e.g. "MAAT"), and whether one is present.
func (r Runs) GetvValue(sub Code) ([]int32, bool) {
	for _, e := range r.entries {
		if e.Code != "getv" {
			continue
		}
		v := r.valuesOf(e)
		if len(v) > 0 && CodeOf(v[0]) == sub {
			return v[1:], true
		}
	}
	return nil, false
}
