package namefilter

import (
	"strings"
	"testing"
	"unicode/utf16"
)

// The tests build their own small AbuseFilter.txt (never the real one, which
// is game data): UTF-16LE with a BOM, CR LF lines, 36 tab-separated cells.

// row is one line: groups[g] is that group's 6 cells (nil = 6 empty cells).
func row(groups map[int][]string) string {
	cells := make([]string, 36)
	for g, cs := range groups {
		copy(cells[g*6:g*6+6], cs)
	}
	return strings.Join(cells, "\t")
}

func file(lines ...string) []byte {
	text := strings.Join(lines, "\r\n") + "\r\n"
	units := utf16.Encode([]rune(text))
	out := []byte{0xff, 0xfe}
	for _, u := range units {
		out = append(out, byte(u), byte(u>>8))
	}
	return out
}

func allow(from, to string) []string { return []string{"#ALLOW_ID_TABLE", from, to, "", "", ""} }

func word(w, f1 string) []string { return []string{w, f1, "0", "0", "0", ""} }

// english is group 4's charset, as the retail file has it (MEASURED).
var english = []string{
	row(map[int][]string{4: allow("0x0030", "0x0039"), 5: allow("0x0030", "0x0039")}),
	row(map[int][]string{4: allow("0x0041", "0x005A"), 5: allow("0x0041", "0x005A")}),
	row(map[int][]string{4: allow("0x005F", "0x005F"), 5: allow("0x005F", "0x005F")}),
	row(map[int][]string{4: allow("0x0061", "0x007A"), 5: allow("0x0061", "0x007A")}),
	row(map[int][]string{5: allow("0x00C0", "0x00D6")}),
}

func mustLoad(t *testing.T, group int, lines ...string) *Filter {
	t.Helper()
	f, err := Load(file(lines...), group)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func TestDefaultCharsetAndSQLWords(t *testing.T) {
	f := Default()
	for name, want := range map[string]bool{
		"Tester": true, "Bob_1": true, "GMBob": true, "ab": true,
		"a b":         false, // a space (0x40f234)
		"it's":        false, // a quote (0x527390)
		"say\"hi":     false,
		"Bob-1":       false, // '-' is outside [0-9A-Za-z_]
		"Krämer":      false, // a byte >= 0x80
		"xp_bob":      false, // "xp_"
		"my_char":     false, // "_char"
		"BOB_CHAR":    false, // lower-cased before the find
		"Al_Ref":      false, // "_ref"
		"Al_Refs":     false,
		"sysobjects1": false,
	} {
		if got := f.NameOK(name); got != want {
			t.Errorf("Default().NameOK(%q) = %v, want %v", name, got, want)
		}
	}
	if rows, sub, whole := f.Counts(); rows != 0 || sub != 0 || whole != 0 {
		t.Errorf("Default holds %d allow rows, %d and %d words; want none from a file", rows, sub, whole)
	}
}

func TestSQLWordsAreTheBinarysFiftyFour(t *testing.T) {
	if len(SQLWords) != 54 {
		t.Fatalf("%d SQL words, want 54 (0x5261c0's inserts)", len(SQLWords))
	}
	capitals := 0
	for _, w := range SQLWords {
		if w != strings.ToLower(w) {
			capitals++
			// A mixed-case entry never matches a lower-cased name by itself
			// ("_ChestInfo" is still refused, by "_chest").
			if strings.Contains(lowerDBCS(w), w) {
				t.Errorf("mixed-case %q matched itself after lower-casing", w)
			}
		}
	}
	if capitals != 11 {
		t.Errorf("%d words with a capital, want 11", capitals)
	}
}

func TestLoadGroupWordsAndFlags(t *testing.T) {
	lines := append([]string{}, english...)
	lines = append(lines,
		row(map[int][]string{4: word("GM", "2"), 5: word("viet", "2")}),
		row(map[int][]string{4: word("Admin", "1")}),
		row(map[int][]string{4: word("bad", "0")}),
		row(map[int][]string{4: word("**Monster**", "0")}),
	)
	f := mustLoad(t, 4, lines...)
	if rows, sub, whole := f.Counts(); rows != 4 || sub != 1 || whole != 1 {
		t.Fatalf("Counts() = %d, %d, %d; want 4 allow rows, 1 substring, 1 whole word", rows, sub, whole)
	}
	for name, want := range map[string]bool{
		"Tester":  true,
		"GMBob":   false, // "gm" anywhere, case folded
		"Bobgm":   false,
		"Admin":   false, // the whole word
		"ADMIN":   false,
		"Admins":  true, // not the whole word
		"Badguy":  true, // f1 0: in no list
		"Vietnam": true, // group 5's word is not group 4's
		"Bob_1":   true,
		"Bob-1":   false,
	} {
		if got := f.NameOK(name); got != want {
			t.Errorf("NameOK(%q) = %v, want %v", name, got, want)
		}
	}

	g5 := mustLoad(t, 5, lines...)
	if g5.NameOK("Vietnam") {
		t.Error("group 5 let its own substring word through")
	}
	if !g5.NameOK("GMBob") {
		t.Error("group 5 refused group 4's word")
	}
	// Group 5 allows 0xC0..0xD6, all below 0x100, but a byte >= 0x80 is read
	// as a two-byte code: such a name never passes (READ 0x6df7f0).
	if g5.NameOK("Ab\xc0") || g5.NameOK("\xc0\xc1ab") {
		t.Error("a byte >= 0x80 passed group 5's bitmap")
	}
}

func TestDBCSBitmapAndCharacterBoundaries(t *testing.T) {
	// A DBCS group: 0x8161 is the pair 81 61; 'b' and 'c' alone.
	f := mustLoad(t, 0,
		row(map[int][]string{0: allow("0x8161", "0x8161")}),
		row(map[int][]string{0: allow("0x0062", "0x0063")}),
		row(map[int][]string{0: word("ab", "2")}),
	)
	// 81 61 62 63: the windows start at 0 and 2 (the lead byte steps two), so
	// "ab" at offset 1 is not found (READ 0x6df850).
	if !f.NameOK("\x81abc") {
		t.Error(`"ab" matched across a DBCS pair's trail byte`)
	}
	// 62 61 62: "ab" at offset 1 is a character boundary here -- but 'a' alone
	// is not allowed, so add it and try again.
	f2 := mustLoad(t, 0,
		row(map[int][]string{0: allow("0x0061", "0x0063")}),
		row(map[int][]string{0: word("ab", "2")}),
	)
	if f2.NameOK("bab") {
		t.Error(`"ab" not found at a single-byte boundary`)
	}
	// The trail byte is not lower-cased (0x6df010): 81 41 is code 0x8141.
	f3 := mustLoad(t, 0, row(map[int][]string{0: allow("0x8141", "0x8141")}), row(map[int][]string{0: allow("0x0061", "0x0061")}))
	if !f3.NameOK("\x81Aa") {
		t.Error("the pair 81 41 was not read as code 0x8141")
	}
	if f3.NameOK("\x81a") {
		t.Error("code 0x8161 passed though only 0x8141 is allowed")
	}
}

func TestCommentsEmptyFlagsAndCRLF(t *testing.T) {
	lines := append([]string{}, english...)
	lines = append(lines,
		"// a comment line",
		row(map[int][]string{4: word("one", "2")})+"\t// trailing",
		"/* a block",
		row(map[int][]string{4: word("two", "2")}),
		"still in it */",
		row(map[int][]string{4: word("three", "2")}),
		// An empty f1 cell: the number is read from the next cell (READ
		// 0x6e1970 skips tabs as whitespace).
		row(map[int][]string{4: {"four", "", "2", "0", "0", ""}}),
		// A lone LF does not end a line: the word is "fi\nve".
		row(map[int][]string{4: word("fi\nve", "2")}),
	)
	f := mustLoad(t, 4, lines...)
	for name, want := range map[string]bool{
		"Oneill": false, // read before its "//"
		"Twofer": true,  // inside the block
		"Three3": false, // after the block's end
		"Fourth": false, // f1 borrowed from f2
		"Five":   true,
	} {
		if got := f.NameOK(name); got != want {
			t.Errorf("NameOK(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestReadIntForms(t *testing.T) {
	for in, want := range map[string]int32{
		"0x0030": 0x30, "0X7a": 0x7a, "48": 48, "-5": -5, "+7": 7, "\t\t 2": 2,
		"abc": 0, "": 0, "12ab": 12, "0x1F\t3": 0x1f,
	} {
		c := &cursor{s: in}
		if got := c.readInt(); got != want {
			t.Errorf("readInt(%q) = %d, want %d", in, got, want)
		}
	}
	// A non-number leaves the cursor where it was.
	c := &cursor{s: "\tword"}
	c.readInt()
	if c.pos != 0 {
		t.Errorf("a failed read moved the cursor to %d", c.pos)
	}
}

func TestGroupOutOfRangeReadsGroupZero(t *testing.T) {
	f := mustLoad(t, 9, row(map[int][]string{0: allow("0x0061", "0x0061"), 4: allow("0x0062", "0x0062")}))
	if !f.NameOK("aa") || f.NameOK("bb") {
		t.Error("a group above 5 did not read group 0")
	}
}

func TestShortLinesAndNonCP1252Words(t *testing.T) {
	lines := append([]string{}, english...)
	lines = append(lines,
		"short\t1", // too few cells for group 4: nothing
		row(map[int][]string{4: word("凸ab", "2")}),
	)
	f := mustLoad(t, 4, lines...)
	if _, sub, _ := f.Counts(); sub != 1 {
		t.Fatalf("%d substring words, want 1", sub)
	}
	// The CJK character became '?' (OURS: Windows-1252), so "ab" alone passes.
	if !f.NameOK("Xab") {
		t.Error(`"?ab" matched "Xab"`)
	}
}

func TestGroupForLocale(t *testing.T) {
	for in, want := range map[string]int{
		"KOREA": 0, "LOCALE_CHINA": 1, "taiwan": 2, "Locale_Japan": 3,
		"VIETNAM": 5, "LOCALE_VIETNAM": 5, "ENGLISH": 4,
	} {
		if g, known := GroupForLocale(in); g != want || !known {
			t.Errorf("GroupForLocale(%q) = %d, %v; want %d, true", in, g, known, want)
		}
	}
	if g, known := GroupForLocale("THAILAND"); g != GroupEnglish || known {
		t.Errorf("an unknown locale gave %d, %v; want %d, false", g, known, GroupEnglish)
	}
}

func TestFirstUnitIsAlwaysSkipped(t *testing.T) {
	if _, err := Load([]byte{0xff}, 4); err == nil {
		t.Error("a 1-byte file loaded")
	}
	// No BOM: the first unit is dropped all the same (READ: the conversion
	// starts at byte 2). Here it is a junk line's first character.
	lines := append([]string{"XX"}, english...)
	f, err := Load(file(lines...)[2:], 4)
	if err != nil {
		t.Fatal(err)
	}
	if rows, _, _ := f.Counts(); rows != 4 {
		t.Errorf("%d allow rows, want 4", rows)
	}
	// With the BOM missing and the first line a data row, its '#' goes.
	g, err := Load(file(row(map[int][]string{0: allow("0x0061", "0x0061")}))[2:], 0)
	if err != nil {
		t.Fatal(err)
	}
	if rows, _, _ := g.Counts(); rows != 0 {
		t.Errorf("a row that lost its '#' still counted (%d)", rows)
	}
}

// flags is a word with all four flag cells (f1 name, f2 chat, f3 guild, f4
// stall).
func flags(w, f1, f2, f3, f4 string) []string { return []string{w, f1, f2, f3, f4, ""} }

// Round 840: the stall title's word test is f4's lists (c:0x8c3f10), with no
// character bitmap: the substring list found anywhere in the lower-cased
// title, the whole-word set against each space-separated token.
func TestStallTitleUsesTheFourthFlag(t *testing.T) {
	lines := append([]string{}, english...)
	lines = append(lines,
		row(map[int][]string{4: flags("Scam", "0", "0", "0", "2")}),
		row(map[int][]string{4: flags("cheap", "0", "0", "0", "1")}),
		row(map[int][]string{4: flags("gm", "2", "0", "0", "0")}),
		row(map[int][]string{4: flags("guildword", "0", "0", "1", "0")}),
	)
	f := mustLoad(t, 4, lines...)
	if sub, whole := f.StallCounts(); sub != 1 || whole != 1 {
		t.Fatalf("StallCounts() = %d, %d; want 1 and 1", sub, whole)
	}
	for title, want := range map[string]bool{
		"My stall":         true,
		"No SCAMS here":    false, // f4 substring, case folded by the lower-casing
		"Cheap":            false, // f4 whole word, the whole title
		"all cheap stuff":  false, // a token
		"cheaper goods":    true,  // not the whole token
		"GM's goods":       true,  // f1's word is not the stall's
		"guildword":        true,  // f3's whole word is not the stall's
		"[Aria]'s stall!!": true,  // no character bitmap
		"":                 true,
	} {
		if got := f.StallTitleOK(title); got != want {
			t.Errorf("StallTitleOK(%q) = %v, want %v", title, got, want)
		}
	}
	if !Default().StallTitleOK("Scam cheap") {
		t.Error("the no-file filter refused a title")
	}
	// f1 still reads as before.
	if f.NameOK("Gmbob") || !f.NameOK("Scambob") {
		t.Error("the name test changed")
	}
}
