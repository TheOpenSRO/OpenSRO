package skillparam

import "testing"

// The parser clears [0x230, 0x230+0x37c) before it fills anything, so a field
// outside that window cannot be one it writes. This is the cheapest check that
// the dispatch tree was walked correctly, and it is the one that would fail if
// a leaf ran into its neighbour -- the failure this table has already had once.
func TestEveryFieldLiesInTheClearedRegion(t *testing.T) {
	end := ParsedRegionStart + ParsedRegionLen
	for code, off := range Field {
		if off < ParsedRegionStart || off >= end {
			t.Errorf("Field[%q] = %#x, outside the memset region [%#x, %#x)", code, off, ParsedRegionStart, end)
		}
	}
	for code, off := range GetvSub {
		if off < ParsedRegionStart || off >= end {
			t.Errorf("GetvSub[%q] = %#x, outside the memset region [%#x, %#x)", code, off, ParsedRegionStart, end)
		}
	}
}

// Controls taken from docs/protocol/skill_params.md, which recovered these
// independently and earlier. The extraction that produced Run reproduced all
// 131 of that table's rows with zero disagreements; these five are the ones the
// document itself nominated as its controls, so they are the ones worth
// freezing here.
func TestRunsMatchTheIndependentlyRecoveredControls(t *testing.T) {
	for _, c := range []struct {
		code  Code
		field int
		run   int
	}{
		{"att", 0x230, 6},
		{"defp", 0x25c, 4},
		{"defr", 0x260, 3},
		{"spda", 0x264, 3},
		{"odar", 0x270, 3},
	} {
		if got := Field[c.code]; got != c.field {
			t.Errorf("Field[%q] = %#x, want %#x", c.code, got, c.field)
		}
		if got := Run[c.code]; got != c.run {
			t.Errorf("Run[%q] = %d, want %d", c.code, got, c.run)
		}
	}
}

// 'att' is the one run this project reads a real value out of, and it is read
// by two paths that never consulted each other: cmd/export-refdata walks the
// text skilldata and takes five values after the code, and this table walks the
// server's parser and gets a run of six. Six words minus the code word is five
// values. If those two ever disagree, one of them is wrong.
func TestAttCarriesTheFiveValuesTheExporterReads(t *testing.T) {
	const valuesTheExporterReads = 4 // percent, min, max -- plus the type at +1
	if Run["att"]-1 != valuesTheExporterReads+1 {
		t.Fatalf("Run[att]-1 = %d values, but export-refdata reads (type, percent, min, max, percent) = 5",
			Run["att"]-1)
	}
	if Kind["att"] != KindFixed {
		t.Error("att must be a fixed run; a variable-length att would mean the exporter cannot know where its values end")
	}
}

// Run and Kind must describe the same vocabulary, and a variable-length code
// must NOT have a run -- claiming one would silently invent a length the parser
// never states, which is the exact failure this file exists to avoid.
func TestRunAndKindAgreeOnEveryCode(t *testing.T) {
	for code, kind := range Kind {
		_, hasRun := Run[code]
		switch kind {
		case KindVarLen:
			if hasRun {
				t.Errorf("%q is variable-length but Run claims a length of %d", code, Run[code])
			}
		default:
			if !hasRun {
				t.Errorf("%q is %v but has no Run", code, kind)
			}
		}
	}
	for code := range Run {
		if _, ok := Kind[code]; !ok {
			t.Errorf("Run has %q but Kind does not classify it", code)
		}
	}
}

// The counts the extraction settled on. These are a tripwire: the vocabulary
// was reported as ~105 and then ~145 by earlier passes that each missed a
// branch shape, so a change in these numbers should be deliberate.
func TestVocabularyCounts(t *testing.T) {
	counts := map[ParamKind]int{}
	for _, k := range Kind {
		counts[k]++
	}
	for _, c := range []struct {
		kind ParamKind
		want int
		what string
	}{
		{KindFixed, 146, "fixed-run"},
		{KindVarLen, 20, "variable-length"},
		{KindArray, 2, "array"},
		{KindPrefix, 1, "two-word prefix"},
	} {
		if counts[c.kind] != c.want {
			t.Errorf("%d %s codes, want %d", counts[c.kind], c.what, c.want)
		}
	}
	if len(Kind) != 169 {
		t.Errorf("%d top-level codes, want 169", len(Kind))
	}
	if len(GetvSub) != 40 {
		t.Errorf("%d getv sub-codes, want 40", len(GetvSub))
	}
}

// A sub-code is a SECOND word, never a code in its own right. If one collided
// with a top-level code, a walk could mistake a getv value for a new run.
func TestGetvSubCodesAreNotAlsoTopLevelCodes(t *testing.T) {
	for sub := range GetvSub {
		if _, clash := Kind[sub]; clash {
			t.Errorf("%q is both a getv sub-code and a top-level code", sub)
		}
	}
	if Run["getv"] != 2 {
		t.Errorf("Run[getv] = %d, want 2 -- the code word and the sub-code", Run["getv"])
	}
	if Kind["getv"] != KindPrefix {
		t.Error("getv must be KindPrefix")
	}
}

// 'efr' selects its target from its first value. Field can only hold one of the
// three, so the two must not drift apart.
func TestEfrFieldsIncludeTheOneFieldRecords(t *testing.T) {
	if Run["efr"] != 7 || Kind["efr"] != KindFixed {
		t.Fatalf("efr = run %d kind %v, want a fixed run of 7", Run["efr"], Kind["efr"])
	}
	found := false
	for _, off := range EfrField {
		if off == Field["efr"] {
			found = true
		}
	}
	if !found {
		t.Errorf("Field[efr] = %#x is not one of the three fields efr selects between: %v", Field["efr"], EfrField)
	}
}

// The arrays sit where their slots do, and the slots are inside the region.
func TestArrayParametersClaimContiguousSlots(t *testing.T) {
	for _, a := range []struct {
		code  Code
		base  int
		slots int
	}{
		{"setv", SetvArrayBase, SetvArraySlots},
		{"reqi", ReqiArrayBase, ReqiArraySlots},
	} {
		if Kind[a.code] != KindArray {
			t.Errorf("%q should be KindArray", a.code)
		}
		end := a.base + a.slots*4
		if end > ParsedRegionStart+ParsedRegionLen {
			t.Errorf("%q slots run to %#x, past the cleared region", a.code, end)
		}
	}
}

// The codes are big-endian multi-character literals. Decoding the stored
// integer little-endian spells every one of them backwards, which is a mistake
// this project has made twice.
func TestCodeOfDecodesBigEndian(t *testing.T) {
	for _, c := range []struct {
		word int32
		want Code
	}{
		{0x00617474, "att"},
		{0x70646d67, "pdmg"},
		{0x00006d63, "mc"},
		{0x67657476, "getv"},
	} {
		if got := CodeOf(c.word); got != c.want {
			t.Errorf("CodeOf(%#x) = %q, want %q", c.word, got, c.want)
		}
	}
	if CodeOf(0x00617474) == "tta" {
		t.Fatal("CodeOf decoded little-endian -- every code comes out backwards")
	}
}

// block builds a Param block out of the table itself: each code followed by the
// right number of zero values. No real skill row is used as a fixture.
func block(codes ...Code) []int32 {
	var out []int32
	for _, c := range codes {
		var w int32
		for _, b := range []byte(c) {
			w = w<<8 | int32(b)
		}
		out = append(out, w)
		for i := 1; i < Run[c]; i++ {
			out = append(out, 0x7fffffff) // a value that is not a valid code
		}
	}
	return out
}

func TestWalkConsumesEveryFixedRun(t *testing.T) {
	entries, stopped, complete := Walk(block("att", "mc", "pdmg"))
	if !complete {
		t.Fatalf("walk stopped at %q, want a complete walk", stopped)
	}
	if len(entries) != 3 {
		t.Fatalf("consumed %d runs, want 3: %v", len(entries), entries)
	}
	if entries[0].Code != "att" || entries[0].Index != 0 || entries[0].Run != 6 {
		t.Errorf("first run = %+v, want att at 0 with run 6", entries[0])
	}
	// 'mc' starts immediately after att's six words.
	if entries[1].Index != 6 {
		t.Errorf("mc at word %d, want 6", entries[1].Index)
	}
}

// A walk must stop at a variable-length code rather than guess, and must say so
// -- a caller that reads "not found" as "the skill has not got it" would be
// wrong for the 1,265 real rows that stop this way.
func TestWalkStopsAtAVariableLengthCode(t *testing.T) {
	var varlen Code
	for c, k := range Kind {
		if k == KindVarLen {
			varlen = c
			break
		}
	}
	if varlen == "" {
		t.Fatal("no variable-length code in the table")
	}
	words := append(block("att"), codeWord(varlen), 1, 2, 3)
	entries, stopped, complete := Walk(words)
	if complete {
		t.Error("walk reported complete despite a variable-length code")
	}
	if stopped != varlen {
		t.Errorf("stopped at %q, want %q", stopped, varlen)
	}
	if len(entries) != 1 {
		t.Errorf("consumed %d runs before stopping, want 1", len(entries))
	}
	// Find must report the incomplete walk so the caller can fall back.
	if _, found, complete := Find(words, "pdmg"); found || complete {
		t.Errorf("Find past a variable-length code returned found=%v complete=%v, want false/false", found, complete)
	}
}

func codeWord(c Code) int32 {
	var w int32
	for _, b := range []byte(c) {
		w = w<<8 | int32(b)
	}
	return w
}

// An unrecognised word is a different failure from a variable-length stop: it
// means the block does not start where the caller thinks. Across 33,632 real
// rows it never happens at ParamBlockColumn, and it happens on 11,907 of them
// one column earlier -- so this constant is load-bearing and gets a guard.
func TestParamBlockStartsAtColumnSeventy(t *testing.T) {
	if ParamBlockColumn != 69 {
		t.Errorf("ParamBlockColumn = %d; column 70 counting from 1 is index 69. "+
			"At index 68, 11,907 of 33,632 real rows read a neighbouring value as a code.",
			ParamBlockColumn)
	}
	if ParamBlockMaxWords != 50 {
		t.Errorf("ParamBlockMaxWords = %d, want 50 -- the parser returns once its word index passes 0x31", ParamBlockMaxWords)
	}
}

func TestWalkRejectsAWordThatIsNoCode(t *testing.T) {
	_, stopped, complete := Walk([]int32{0x7fffffff})
	if complete {
		t.Error("walk accepted a word that is not a code")
	}
	if stopped == "" {
		t.Error("walk did not report what stopped it")
	}
}

// Zero words are padding the parser skips, not terminators.
func TestWalkSkipsPadding(t *testing.T) {
	words := append([]int32{0, 0}, block("pdmg")...)
	entries, _, complete := Walk(words)
	if !complete || len(entries) != 1 {
		t.Fatalf("walk over padded block: complete=%v entries=%v", complete, entries)
	}
	if entries[0].Index != 2 {
		t.Errorf("pdmg at word %d, want 2", entries[0].Index)
	}
}
