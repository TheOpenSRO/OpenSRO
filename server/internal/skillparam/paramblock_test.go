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

// Run and Kind must describe the same vocabulary. Every code now has a run --
// markers and the terminator are run 1 (the code word, no values) -- and the
// two maps must cover exactly the same set.
func TestRunAndKindAgreeOnEveryCode(t *testing.T) {
	for code, kind := range Kind {
		run, hasRun := Run[code]
		if !hasRun {
			t.Errorf("%q is %v but has no Run", code, kind)
		}
		if (kind == KindMarker || kind == KindTerminator) && run != 1 {
			t.Errorf("%q is a marker/terminator but Run is %d, want 1", code, run)
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
		{KindMarker, 19, "marker"},
		{KindTerminator, 1, "terminator"},
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
// A marker does NOT stop a walk -- the parser advances past it and so does the
// walk. The terminator ('ssou') completes it. An unknown word stops it
// incomplete. All three are exercised here.
func TestWalkHandlesMarkersTerminatorAndUnknowns(t *testing.T) {
	// A marker between two fixed runs: the walk passes it and finds both.
	var marker Code
	for c, k := range Kind {
		if k == KindMarker {
			marker = c
			break
		}
	}
	if marker == "" {
		t.Fatal("no marker in the table")
	}
	words := append(block("att"), codeWord(marker))
	words = append(words, block("pdmg")...)
	entries, _, complete := Walk(words)
	if !complete {
		t.Error("walk stopped at a marker; markers must not stop a walk")
	}
	if _, found, complete := Find(words, "pdmg"); !found || !complete {
		t.Errorf("Find past a marker returned found=%v complete=%v, want true/true", found, complete)
	}

	// The terminator completes the walk and IS recorded as the last run.
	term := append(block("att"), codeWord("ssou"), 1, 2, 3)
	entries, _, complete = Walk(term)
	if !complete {
		t.Error("walk did not complete at the terminator")
	}
	if entries[len(entries)-1].Code != "ssou" {
		t.Errorf("last entry is %q, want ssou", entries[len(entries)-1].Code)
	}

	// An unknown word stops the walk incomplete -- the only remaining way for a
	// walk to be undecided, and the one Find must report so a caller can fall
	// back.
	junk := append(block("att"), 0x7fffffff, 0x7ffffffe)
	entries, stopped, complete := Walk(junk)
	if complete {
		t.Error("walk reported complete despite an unknown word")
	}
	if stopped == "" {
		t.Error("walk did not report what stopped it")
	}
	if len(entries) != 1 {
		t.Errorf("consumed %d runs before the unknown word, want 1", len(entries))
	}
	if _, found, complete := Find(junk, "pdmg"); found || complete {
		t.Errorf("Find past an unknown word returned found=%v complete=%v, want false/false", found, complete)
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

// The 33 field offsets Combat_ResolveDamage (0x0058e5f0) tests, transcribed
// from its opening condition. Freezing them here is the cross-check: they were
// read off a function that had no part in building Field, so if Field ever
// drifts, this fails.
func TestCombatParametersMatchTheOffsetsResolveDamageTests(t *testing.T) {
	tested := map[int]bool{
		0x230: true, 0x234: true, 0x238: true, 0x248: true, 0x28c: true,
		0x30c: true, 0x310: true, 0x314: true, 0x318: true, 0x31c: true,
		0x320: true, 0x3c8: true, 0x3cc: true, 0x3d0: true, 0x400: true,
		0x424: true, 0x430: true, 0x434: true, 0x438: true, 0x43c: true,
		0x440: true, 0x444: true, 0x44c: true, 0x450: true, 0x454: true,
		0x458: true, 0x45c: true, 0x460: true, 0x464: true, 0x468: true,
		0x46c: true, 0x470: true, 0x474: true,
	}
	if len(CombatParameters) != len(tested) {
		t.Fatalf("%d codes for %d tested offsets", len(CombatParameters), len(tested))
	}
	for _, c := range CombatParameters {
		off, ok := Field[c]
		if !ok {
			t.Errorf("%q has no field", c)
			continue
		}
		// 'efr' is the one code whose field Combat_ResolveDamage reads is not
		// the one Field happens to record, because efr has three.
		if c == "efr" {
			if !tested[EfrField[1]] {
				t.Errorf("efr's first field %#x is not among the offsets tested", EfrField[1])
			}
			continue
		}
		if !tested[off] {
			t.Errorf("Field[%q] = %#x, which Combat_ResolveDamage does not test", c, off)
		}
		delete(tested, off)
	}
	delete(tested, EfrField[1])
	if len(tested) != 0 {
		var left []int
		for o := range tested {
			left = append(left, o)
		}
		t.Errorf("offsets tested by Combat_ResolveDamage with no code: %#x", left)
	}
}

// Every combat parameter must be a code the parser recognises, and none may be
// variable-length: the walk has to be able to pass them to decide whether a
// skill carries any.
func TestCombatParametersAreWalkable(t *testing.T) {
	for _, c := range CombatParameters {
		k, ok := Kind[c]
		if !ok {
			t.Errorf("%q is not a top-level code", c)
			continue
		}
		if _, hasRun := Run[c]; !hasRun {
			t.Errorf("%q has no run; a walk cannot pass it to decide the rest", c)
		}
		_ = k
	}
	if EfrCombatSelector != 6 {
		t.Errorf("EfrCombatSelector = %d, want 6 -- `if (*(int *)(efr + 4) != 6) return`", EfrCombatSelector)
	}
}

func TestCarriesCombatParameter(t *testing.T) {
	// 'att' is a combat parameter, so a block with one carries.
	if carries, decided := CarriesCombatParameter(block("att")); !carries || !decided {
		t.Errorf("att: carries=%v decided=%v, want true/true", carries, decided)
	}
	// 'bl' is in the list too. A skill with no 'att' is NOT automatically a
	// non-combat skill -- that conflation is the mistake this guards.
	if carries, decided := CarriesCombatParameter(block("bl")); !carries || !decided {
		t.Errorf("bl without att: carries=%v decided=%v, want true/true", carries, decided)
	}
	// 'dura' is not in the list, so a block with only that carries nothing.
	if carries, decided := CarriesCombatParameter(block("dura")); carries || !decided {
		t.Errorf("dura only: carries=%v decided=%v, want false/true", carries, decided)
	}
	if carries, decided := CarriesCombatParameter(nil); carries || !decided {
		t.Errorf("empty block: carries=%v decided=%v, want false/true", carries, decided)
	}
}

// 'efr' counts only with the right second value, which is the engine's own
// extra condition and not a detail to round off.
func TestEfrCountsOnlyWithItsSelector(t *testing.T) {
	efr := func(second int32) []int32 {
		w := block("efr") // run 7: code + 6 values
		w[2] = second     // values start at index 1, so the second value is 2
		return w
	}
	if carries, _ := CarriesCombatParameter(efr(EfrCombatSelector)); !carries {
		t.Errorf("efr with second value %d should carry", EfrCombatSelector)
	}
	if carries, decided := CarriesCombatParameter(efr(EfrCombatSelector + 1)); carries || !decided {
		t.Errorf("efr with the wrong second value: carries=%v decided=%v, want false/true", carries, decided)
	}
}

// A walk that cannot finish has not proved the skill carries nothing, and must
// say so -- otherwise 1,265 real rows would be silenced on no evidence.
func TestCarriesCombatParameterDoesNotDecidePastAVarLenCode(t *testing.T) {
	// An unknown word (not a marker -- markers no longer stop a walk) is the
	// only thing that leaves a walk undecided.
	words := []int32{0x7fffffff, 1, 2, 3}
	carries, decided := CarriesCombatParameter(words)
	if carries || decided {
		t.Errorf("stopped walk: carries=%v decided=%v, want false/false", carries, decided)
	}
	// But a combat parameter BEFORE the unknown word still settles it.
	words = append(block("att"), 0x7fffffff, 1, 2, 3)
	if carries, decided := CarriesCombatParameter(words); !carries || !decided {
		t.Errorf("att before the stop: carries=%v decided=%v, want true/true", carries, decided)
	}
}

func TestDealsZeroDamage(t *testing.T) {
	// 'att' means the blow is computed.
	if zero, decided := DealsZeroDamage(block("att")); zero || !decided {
		t.Errorf("att: zero=%v decided=%v, want false/true", zero, decided)
	}
	// 'ck' alone is enough to keep local_d0 at 0, which is why it is exported
	// rather than inferred from the attack percent.
	if zero, decided := DealsZeroDamage(block("ck")); zero || !decided {
		t.Errorf("ck: zero=%v decided=%v, want false/true", zero, decided)
	}
	// A combat parameter that is NEITHER of the two still deals zero: it gets
	// past the early return and then has both halves written zero.
	if zero, decided := DealsZeroDamage(block("bl")); !zero || !decided {
		t.Errorf("bl: zero=%v decided=%v, want true/true", zero, decided)
	}
	// Which makes the two rules nest: everything CarriesCombatParameter calls
	// non-combat must also be zero-damage, never the other way round.
	for _, c := range []Code{"dura", "bl", "mc"} {
		carries, _ := CarriesCombatParameter(block(c))
		zero, _ := DealsZeroDamage(block(c))
		if !carries && !zero {
			t.Errorf("%q carries no combat parameter but is not zero-damage; the first must be inside the second", c)
		}
	}
}

func TestDealsZeroDamageDoesNotDecidePastAVarLenCode(t *testing.T) {
	// An unknown word leaves the walk undecided.
	if zero, decided := DealsZeroDamage([]int32{0x7fffffff, 1, 2}); !zero || decided {
		t.Errorf("stopped walk: zero=%v decided=%v, want true/false (undecided)", zero, decided)
	}
	// An 'att' before the stop settles it.
	words := append(block("att"), 0x7fffffff, 1, 2)
	if zero, decided := DealsZeroDamage(words); zero || !decided {
		t.Errorf("att before the stop: zero=%v decided=%v, want false/true", zero, decided)
	}
}

func TestWordOfIsTheInverseOfCodeOf(t *testing.T) {
	for c := range Kind {
		if got := CodeOf(WordOf(c)); got != c {
			t.Errorf("CodeOf(WordOf(%q)) = %q", c, got)
		}
	}
	if WordOf("att") != 0x00617474 {
		t.Errorf("WordOf(att) = %#x, want 0x617474", WordOf("att"))
	}
}

// The three ways a computed blow is identically zero, and the two ways it is
// not. Each case is one the mitigation formulas settle on their own.
func TestBlowIsFloor(t *testing.T) {
	for _, c := range []struct {
		name               string
		hasAtt             bool
		attType, attPct    int32
		carriesCk, isFloor bool
	}{
		{"ordinary physical skill", true, 5, 143, false, false},
		{"ordinary magical skill", true, 10, 200, false, false},
		{"att with a percent of 0", true, 8, 0, false, true},
		{"att with a percent but neither damage bit", true, 1, 121, false, true},
		{"att type 0", true, 0, 0, false, true},
		{"ck with no att", false, 0, 0, true, true},
		{"neither parameter -- that is zero damage, not a floor", false, 0, 0, false, false},
	} {
		if got := BlowIsFloor(c.hasAtt, c.attType, c.attPct, c.carriesCk); got != c.isFloor {
			t.Errorf("%s: BlowIsFloor = %v, want %v", c.name, got, c.isFloor)
		}
	}
}

// The healing-received chain must stay joined: the params the heal formula reads
// are exactly the ones the 'rhru' buff drives, at the base slot. If any of the
// three tables drifts, this fails -- they were recovered from different
// functions (Skill_ApplyHealToObject reads, ApplySkillParamsToChar writes) and
// only agree because both are right.
func TestHealScaleChainIsJoined(t *testing.T) {
	driven := DrivesParams[HealScaleBuffCode]
	if len(driven) != 2 || driven[0] != HealHPScaleParam || driven[1] != HealMPScaleParam {
		t.Fatalf("DrivesParams[%q] = %v, want [%d %d]", HealScaleBuffCode, driven, HealHPScaleParam, HealMPScaleParam)
	}
	for _, c := range Contributions[HealScaleBuffCode] {
		if c.Slot != SlotBase {
			t.Errorf("%q writes param %d at slot %d, want the base slot 0", HealScaleBuffCode, c.Param, c.Slot)
		}
	}
	// 'rhru' carries exactly the two values it files into 170/171.
	if Run[HealScaleBuffCode] != 3 {
		t.Errorf("Run[%q] = %d, want 3 (code + two values)", HealScaleBuffCode, Run[HealScaleBuffCode])
	}
}

// The area falloff: with the retail table's usual 35 %, the second target
// takes 65 %, the third 42 %, the fourth 27 %; with 0 % every target takes
// the whole blow.
func TestAreaTargetShare(t *testing.T) {
	for i, want := range []int{100, 65, 42, 27, 18} {
		if got := AreaTargetShare(i, 35); got != want {
			t.Errorf("target %d at 35 %%: %d; want %d", i, got, want)
		}
	}
	if got := AreaTargetShare(3, 0); got != 100 {
		t.Errorf("no falloff: %d; want 100", got)
	}
}

// A 30 s fire shield cast at tick 1000 with no extension is over once the
// clock passes 31000 (the engine tests `elapsed > dura`, so 31000 itself is
// still inside).
func TestBuffEndsAt(t *testing.T) {
	if got := BuffEndsAt(1000, 30000, 0); got != 31000 {
		t.Fatalf("BuffEndsAt = %d; want 31000", got)
	}
	if got := BuffEndsAt(1000, 30000, 5000); got != 36000 {
		t.Fatalf("with a 5 s extension: %d; want 36000", got)
	}
}

// Round 503: the self-heal shape. Only an instant (kind 0), untargeted row whose
// completed walk carries a flat 'heal' and none of the terms srrevamp does not
// compute returns an amount; everything else returns (0, 0).
func TestSelfHealAmounts(t *testing.T) {
	heal := WordOf("heal")
	efr := WordOf("efr")
	nmh := WordOf("nmh")
	mwhh := WordOf("mwhh")
	att := WordOf("att")
	dura := WordOf("dura")
	getv := WordOf("getv")
	hlru := WordOf("HLRU")
	for _, c := range []struct {
		name           string
		kind           int32
		targetRequired bool
		words          []int32
		hp, mp         int
	}{
		// SKILL_CH_WATER_SELFHEAL's shape: a flat HP amount.
		{"flat HP", ActionKindInstant, false, []int32{heal, 300, 0, 0, 0}, 300, 0},
		// SKILL_EU_BARD_RECOVERA_ABNORMALTIME's shape: a flat MP amount.
		{"flat MP", ActionKindInstant, false, []int32{heal, 0, 0, 200, 0}, 0, 200},
		// 0x5941f1: any other action kind skips the heal branch.
		{"timed buff kind", ActionKindBuff, false, []int32{heal, 300, 0, 0, 0}, 0, 0},
		// 0x5942b1: a Target_Required row never takes the caster branch. With
		// an empty target vector it heals nothing (0x5942b8 `jne 0x594664`);
		// only the non-empty-vector path heals, and it heals the targets
		// (0x5942fd -> 0x59459f, the loop to 0x59463c).
		{"target required", ActionKindInstant, true, []int32{heal, 300, 0, 0, 0}, 0, 0},
		{"efr collects targets", ActionKindInstant, false, []int32{heal, 300, 0, 0, 0, efr, 1, 1, 300, 8, 0, 5}, 0, 0},
		{"nmh is percent mode", ActionKindInstant, false, []int32{nmh, heal, 0, 10, 0, 0}, 0, 0},
		{"mwhh adds a weapon term", ActionKindInstant, false, []int32{heal, 300, 0, 0, 0, mwhh, 50}, 0, 0},
		{"getv HLRU bonus", ActionKindInstant, false, []int32{heal, 300, 0, 0, 0, getv, hlru}, 0, 0},
		// v1 is a +% bonus on v0 (the -100.0 at 0xb462d0); not carried.
		{"v1 bonus", ActionKindInstant, false, []int32{heal, 300, 10, 0, 0}, 0, 0},
		// The halves are independent: an MP bonus does not void the flat HP.
		{"v3 bonus leaves HP", ActionKindInstant, false, []int32{heal, 300, 0, 200, 5}, 300, 0},
		{"with a combat parameter", ActionKindInstant, false, []int32{heal, 300, 0, 0, 0, att, 5, 143, 15, 18, 0}, 0, 0},
		{"undecided walk", ActionKindInstant, false, []int32{0x7fffffff, heal, 300, 0, 0, 0}, 0, 0},
		{"no heal at all", ActionKindInstant, false, []int32{dura, 30000}, 0, 0},
		{"two heal runs", ActionKindInstant, false, []int32{heal, 300, 0, 0, 0, heal, 50, 0, 0, 0}, 0, 0},
		{"heal run cut off", ActionKindInstant, false, []int32{heal, 300, 0}, 0, 0},
	} {
		hp, mp := SelfHealAmounts(c.kind, c.targetRequired, c.words)
		if hp != c.hp || mp != c.mp {
			t.Errorf("%s: SelfHealAmounts = (%d, %d), want (%d, %d)", c.name, hp, mp, c.hp, c.mp)
		}
	}
}
