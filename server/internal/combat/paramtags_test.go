package combat

import "testing"

// TestPackTagMatchesTheTableConstants holds each tag against the packed value
// the real MagicOption.txt carries for it, which is also the constant the
// server binary compares against in Stat_ApplyTaggedModifier (`0x00498690`).
//
// These numbers are the ONE thing in this file worth transcribing, because
// they are what a reader will meet in a disassembly. Everything else is
// derived from the string.
func TestPackTagMatchesTheTableConstants(t *testing.T) {
	for _, tc := range []struct {
		tag    string
		packed uint32
		code   string
	}{
		{TagStr, 7566450, "MATTR_STR"},
		{TagInt, 6909556, "MATTR_INT"},
		{TagHP, 26736, "MATTR_HP"},
		{TagMP, 28016, "MATTR_MP"},
		{TagHitRate, 26738, "MATTR_HR"},
		{TagParry, 25970, "MATTR_ER"},
		{TagBlock, 6451817, "MATTR_BLOCKRATE"},
		{TagCritical, 6517353, "MATTR_CRITICAL"},
		{TagEvadeBlk, 1702257260, "MATTR_EVADE_BLOCK"},
		{TagEvadeCri, 1702257522, "MATTR_EVADE_CRITICAL"},
		{TagAvatarParry, 6648417, "MATTR_AVATAR_ER"},
		{TagAvatarHitRate, 6845025, "MATTR_AVATAR_HR"},
	} {
		if got := PackTag(tc.tag); got != tc.packed {
			t.Errorf("%s (%s): PackTag = %d (%#x), want %d (%#x)",
				tc.tag, tc.code, got, got, tc.packed, tc.packed)
		}
		if got := UnpackTag(tc.packed); got != tc.tag {
			t.Errorf("%s (%s): UnpackTag(%d) = %q, want %q", tc.tag, tc.code, tc.packed, got, tc.tag)
		}
	}
}

// TestPackTagIsBigEndian pins the byte order explicitly. The engine stores
// these as multi-character literals, which MSVC lays out big-endian -- getting
// this backwards is how a tag probe silently finds nothing.
func TestPackTagIsBigEndian(t *testing.T) {
	if got := PackTag("cri"); got != 0x637269 {
		t.Errorf(`PackTag("cri") = %#x, want 0x637269 ('c','r','i')`, got)
	}
	if got := PackTag("evbl"); got != 0x6576626c {
		t.Errorf(`PackTag("evbl") = %#x, want 0x6576626c`, got)
	}
	// Round-trip every tag this package names.
	for _, tag := range []string{
		TagStr, TagInt, TagHP, TagMP, TagHitRate, TagParry, TagBlock,
		TagCritical, TagEvadeBlk, TagEvadeCri, TagAvatarParry, TagAvatarHitRate,
	} {
		if got := UnpackTag(PackTag(tag)); got != tag {
			t.Errorf("round trip %q -> %q", tag, got)
		}
	}
}

// TestPackTagRejectsWhatCannotFit keeps the helper from quietly truncating a
// tag that is too long for the field.
func TestPackTagRejectsWhatCannotFit(t *testing.T) {
	if got := PackTag("toolong"); got != 0 {
		t.Errorf("a seven-character tag packed to %#x; it does not fit 32 bits", got)
	}
	if got := PackTag(""); got != 0 {
		t.Errorf("the empty tag packed to %#x", got)
	}
	// A word that is not printable ASCII is not a tag.
	if got := UnpackTag(0xdeadbeef); got != "" {
		t.Errorf("UnpackTag(0xdeadbeef) = %q, want \"\"", got)
	}
}

// TestAvatarTagsAreDistinctFromTheBaseOnes is the distinction that stopped a
// wrong correction. 'era'/'hra' are MATTR_AVATAR_ER/HR, which appear on avatar
// pieces; 'er'/'hr' are MATTR_ER/HR, which appear on armour and weapons. They
// are four different tags, and reading the avatar pair as the base pair (or
// expanding "ER" to "evasion" rather than the parry ratio the armour column
// shows) would mis-name a shipped value.
func TestAvatarTagsAreDistinctFromTheBaseOnes(t *testing.T) {
	pairs := [][2]string{{TagParry, TagAvatarParry}, {TagHitRate, TagAvatarHitRate}}
	for _, p := range pairs {
		if p[0] == p[1] || PackTag(p[0]) == PackTag(p[1]) {
			t.Errorf("%q and %q must be different tags", p[0], p[1])
		}
		if p[1] != p[0]+"a" {
			t.Errorf("the avatar variant of %q is %q, not %q", p[0], p[0]+"a", p[1])
		}
	}
}

// TestParamForHoldsTheIndependentlyKnownSix is the control that validated the
// disassembly walk in the first place, kept standing. Each of these six param
// ids was established by earlier work from a function the dispatcher had
// nothing to do with -- GObjMob_PublishStats' consecutive publish run,
// Combat_ResolveDamage's block/critical rolls, and the damage pipeline's own
// GetParam calls. If a future re-read of the dispatcher disagrees with one of
// them, the re-read is what to doubt.
func TestParamForHoldsTheIndependentlyKnownSix(t *testing.T) {
	for _, tc := range []struct {
		tag   string
		param int
		from  string
	}{
		{TagBlock, 10, "GObjMob_PublishStats consecutive run (characterdata col 76)"},
		{TagCritical, 12, "GObjMob_PublishStats consecutive run (characterdata col 78)"},
		{TagEvadeBlk, 56, "Combat_ResolveDamage, opposes block"},
		{TagEvadeCri, 57, "Combat_ResolveDamage, opposes critical"},
		{TagStr, 1, "the damage pipeline's GetParam(1)"},
		{TagInt, 2, "the damage pipeline's GetParam(2)"},
	} {
		got, ok := ParamFor[tc.tag]
		if !ok {
			t.Errorf("%q has no param; it was known to be %d from %s", tc.tag, tc.param, tc.from)
			continue
		}
		if got != tc.param {
			t.Errorf("%q -> param %d, want %d (%s)", tc.tag, got, tc.param, tc.from)
		}
	}
}

// TestParamForOppositionsArePaired keeps the two rolls the engine actually
// makes legible: each is a stat opposed by another, and the pair must not
// collapse onto one param.
func TestParamForOppositionsArePaired(t *testing.T) {
	for _, p := range [][2]string{{TagBlock, TagEvadeBlk}, {TagCritical, TagEvadeCri}} {
		a, b := ParamFor[p[0]], ParamFor[p[1]]
		if a == 0 || b == 0 {
			t.Fatalf("%q/%q: one of the pair is missing (%d/%d)", p[0], p[1], a, b)
		}
		if a == b {
			t.Errorf("%q and %q both map to param %d; they oppose each other", p[0], p[1], a)
		}
	}
}

// TestParamForExcludesTheAmbiguousResists documents a deliberate absence. The
// frostbite/poison/zombie tags share a tail block and the walk cannot say which
// of params 27..32 each takes, so they are left out rather than guessed. A
// later tick that separates them should delete this test, not work around it.
func TestParamForExcludesTheAmbiguousResists(t *testing.T) {
	for _, tag := range []string{"fz", "ps", "zb"} {
		if p, ok := ParamFor[tag]; ok {
			t.Errorf("%q maps to param %d, but the walk that produced this table "+
				"reaches five different params from it -- if this is now known, "+
				"say how in the comment and remove it from this test", tag, p)
		}
	}
}

// TestEveryParamForTagPacks keeps the map's keys real tags: each must survive
// the pack/unpack round trip, which a typo would not.
func TestEveryParamForTagPacks(t *testing.T) {
	for tag, param := range ParamFor {
		if UnpackTag(PackTag(tag)) != tag {
			t.Errorf("%q is not a packable tag (param %d)", tag, param)
		}
		if param <= 0 {
			t.Errorf("%q -> param %d; param ids are positive", tag, param)
		}
	}
}

// TestBonusUnitIsAboutTheBonusNotTheStat guards the misreading the comment
// warns about. Block rate's bonus is flat -- the option adds points -- while
// the stat it adds to is a percentage srrevamp rolls against 0..100. If some
// future change reads "flat" as "not a percentage" and stops rolling block as
// a chance, this is the test that should have stopped it.
func TestBonusUnitIsAboutTheBonusNotTheStat(t *testing.T) {
	if BonusUnit[TagBlock] != "flat" {
		t.Fatalf("block rate's bonus is %q; the engine prints \"block rate +%%d\"", BonusUnit[TagBlock])
	}
	// The stat is still one this package rolls as a percentage: Monster.Block
	// feeds RollChance. Nothing here should imply otherwise.
	if BonusUnit[TagEvadeBlk] != "percent" {
		t.Errorf("evade-block's bonus is %q; the engine prints \"evbl +%%d%%%%\"", BonusUnit[TagEvadeBlk])
	}
	// Critical and its opposer differ the same way, which is the asymmetry
	// worth keeping visible.
	if BonusUnit[TagCritical] == BonusUnit[TagEvadeCri] {
		t.Errorf("critical (%q) and evade-critical (%q) print differently in the engine",
			BonusUnit[TagCritical], BonusUnit[TagEvadeCri])
	}
}

// TestBonusUnitExcludesHP pins a deliberate absence: the two debug formatters
// disagree about 'hp', one printing "hp +%d%%" and the other "hp +%d". Both
// literals are really in the binary, so it is the engine that disagrees, not
// the probe. A later tick that settles it should remove this test, not the
// comment explaining why.
func TestBonusUnitExcludesHP(t *testing.T) {
	if u, ok := BonusUnit[TagHP]; ok {
		t.Errorf("'hp' has unit %q, but 0x004909f0 prints it as a percentage and "+
			"0x00491bd0 as flat -- say which governs before listing it", u)
	}
}

// TestLabelForCoversWhatSpellingDoesNot keeps the map to its purpose: a tag
// whose label is just the tag teaches nothing and should not be listed, while
// every tag that needs one should have it.
func TestLabelForCoversWhatSpellingDoesNot(t *testing.T) {
	for tag, label := range LabelFor {
		if label == tag {
			t.Errorf("%q maps to itself; only tags whose label differs belong here", tag)
		}
		if UnpackTag(PackTag(tag)) != tag {
			t.Errorf("%q is not a packable tag", tag)
		}
	}
	// 'dura' is the negative one, and the reason it is here at all.
	if LabelFor["dura"] != "flaw" {
		t.Errorf("'dura' prints as %q; the engine's literal is \"flaw -%%d%%%%\"", LabelFor["dura"])
	}
	// The five elemental resists must all be named -- they are the tags whose
	// param ids the previous tick could NOT separate, so the names are the only
	// thing known about them.
	for _, tag := range []string{"ps", "fz", "bu", "es", "zb"} {
		if LabelFor[tag] == "" {
			t.Errorf("resist tag %q has no label", tag)
		}
	}
}
