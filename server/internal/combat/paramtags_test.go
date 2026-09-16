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
