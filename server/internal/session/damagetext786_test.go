package session

import (
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 786 (damage numbers): the client draws retail's "Resist" word for an
// entry whose hitFlags carry 0x10 and whose statusBits are 0
// (sro_client.exe FUN_00a47720, READ: `(flags & 0x10) && statusBits == 0`
// -> the resist art). A debuff entry must therefore carry 0x10 only when
// its row lands states at the cast: a linked debuff ('lnks' + 'att') lands
// them with its pulses, and a row with no state runs lands none -- neither
// was resisted, and neither may read as a resist.

// TestRound786LinkedDebuffEntryIsNoResist: the e2e cast of a linked debuff
// answers with an entry the client does not draw as "Resist".
func TestRound786LinkedDebuffEntryIsNoResist(t *testing.T) {
	// The world's learn hands the character r785Passive's 'defp' 50, and
	// the passive set is package-wide: put it back after (the defence tests
	// that run later read it otherwise).
	forgetR786Passives(t)
	w := startR785World(t)
	p := w.spawn(10, 0, 100000)
	// The books are package-wide and monster ids restart per hub: the
	// record must not outlive the test (debuffrecast786_test spawns the
	// same id).
	t.Cleanup(func() { forgetMonsterBuffs(p) })
	ar := w.cast(t, &UseSkillRequest{SkillID: r785Dot, TargetMonsterID: p})
	if ar.Action == nil || len(ar.Action.Targets) != 1 || len(ar.Action.Targets[0].Hits) != 1 {
		t.Fatalf("the debuff's block: %+v", ar.Action)
	}
	h := ar.Action.Targets[0].Hits[0]
	if h.Flags&0x10 != 0 && h.Status == 0 {
		t.Fatalf("a linked debuff's entry reads as a resist on the client: flags %#x, states %#x", h.Flags, h.Status)
	}
	if h.Kind != HitKindDamage || h.Damage != 0 {
		t.Fatalf("entry %+v: want a kind-0 entry of no damage", h)
	}
}

// TestRound786DebuffEntryFlags: the entry for each kind of debuff row.
func TestRound786DebuffEntryFlags(t *testing.T) {
	withStates := &refdata.Skill{ID: 1, StatusParams: "st:60000,100,2"}
	statOnly := &refdata.Skill{ID: 2}
	cases := []struct {
		name   string
		row    *refdata.Skill
		linked bool
		bits   uint32
		flags  uint8
	}{
		{"states landed", withStates, false, 0x4, 0x10},
		{"states rolled and missed: a resist", withStates, false, 0, 0x10},
		{"linked: its states land with its pulses", withStates, true, 0, HitFlagNormal},
		{"no state runs: nothing to resist", statOnly, false, 0, HitFlagNormal},
	}
	for _, c := range cases {
		h := debuffEntryHit(c.row, c.linked, c.bits)
		if h.Kind != HitKindDamage || h.Flags != c.flags || h.Status != c.bits || h.Damage != 0 {
			t.Errorf("%s: %+v, want flags %#x states %#x", c.name, h, c.flags, c.bits)
		}
	}
}
