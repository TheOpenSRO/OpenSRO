package session

import (
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// TestRecastRuleCensus (round 636) drives the recast rule over EVERY row of
// the player's own skill export when OPENSRO_SKILLS_CSV names it (the CSV
// cmd/export-refdata -mode skills writes from Media.pk2), and is skipped
// otherwise (CI has no game data). Run it with -v for the report.
//
// For every action-kind-3 row it classifies which of FUN_0059d870's rules
// governs a recast (docs/protocol/skill_buffs.md, "Every row, by rule"),
// then casts the row twice on an empty book -- by its owner, and for a
// Target_Required 1 row also by another caster -- and requires that the
// second cast never leaves two records of the same skill, except where READ
// code allows it: the 'dttp' branch's owner-cast stack, and the rows whose
// gate check is FUN_0059dc80 (an 'lnks' row with Target_Required 0) and
// which carry no 'efr' of kind 3, for which the gate runs no check at all
// (0x58e308). The 'lnks' rows are listed. It also casts every
// pair of rows that share a state byte and different groups, and requires
// the second to be refused.
func TestRecastRuleCensus(t *testing.T) {
	path := os.Getenv("OPENSRO_SKILLS_CSV")
	if path == "" {
		t.Skip("OPENSRO_SKILLS_CSV not set; the census needs the player's own skill export")
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows, err := refdata.LoadSkillsCSV(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) == 0 || rows[0].BasicGroup == "" && rows[len(rows)-1].BasicGroup == "" {
		t.Fatal("the export has no recast-rule columns (64..76): re-export with this round's export-refdata")
	}
	t0 := time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)
	class := map[string]int{}
	var stacked, open []string
	byByte := map[byte][]*refdata.Skill{}
	kind3, notStarted, linkRows := 0, 0, 0
	for i := range rows {
		r := &rows[i]
		if r.ActionKind != 3 {
			if r.ActionOverlap&0xffffff != 0 {
				t.Errorf("%s: a state byte on a kind-%d row", r.BasicCode, r.ActionKind)
			}
			continue
		}
		kind3++
		c := recastClass(r)
		class[c]++
		for sh := 0; sh < 24; sh += 8 {
			if b := byte(r.ActionOverlap >> sh); b != 0 && b != 0x1d && b != 0x23 {
				byByte[b] = append(byByte[b], r)
			}
		}
		// Who can cast it at whom, as OpenSRO starts it (startsCasterBuff,
		// friendlyTargetRefusal = FUN_0058d7a0 steps 4-5): the owner on
		// itself for a Target_Required 0 row or one with Self; another
		// character for a Target_Required 1 row with Ally or Party. A
		// Target_Required 1 row with only hostile groups is not a buff
		// OpenSRO starts (a debuff on a monster; not modelled).
		var casters []int64
		if !r.TargetRequired || r.TargetSelf {
			casters = append(casters, 1)
		}
		if r.TargetRequired && (r.TargetAlly || r.TargetParty) {
			casters = append(casters, 2)
		}
		if !startsCasterBuff(r) {
			notStarted++
		}
		for _, caster := range casters {
			b := buff.NewBooks(50)
			spec := buffSpec(r, caster)
			if _, _, rf, _ := b.Start(1, spec, t0); rf != buff.NotRefused {
				t.Errorf("%s: the first cast on an empty book was refused", r.BasicCode)
				continue
			}
			b.Start(1, spec, t0.Add(time.Second))
			if n := len(b.Active(1)); n > 1 {
				why := "UNEXPLAINED"
				switch {
				case r.HasDttp && caster == 1:
					why = "dttp: the owner's own cast stacks (READ, 0x59d937)"
				case r.Lnks && !r.TargetRequired && !r.Efr3:
					why = "lnks, Target_Required 0, no efr 3: the gate runs no check (READ, 0x58e308)"
				case strings.Contains(recastClass(r), "nothing stops"):
					why = "READ: " + recastClass(r)
				}
				line := r.BasicCode + " by caster " + map[int64]string{1: "owner", 2: "other"}[caster] + ": " + why
				if why == "UNEXPLAINED" {
					t.Errorf("%s stacks", line)
				}
				stacked = append(stacked, line)
			}
		}
		// A friendly Target_Required 1 'lnks' row (the round 636 review's
		// target-test FUN_0059dc80): one caster, lnks value[2] targets pass,
		// the next is 0x3029; the same target again is 0x300c.
		if r.Lnks && r.TargetRequired && (r.TargetAlly || r.TargetParty) && r.LnksMax > 0 && !r.Lks2 {
			b := buff.NewBooks(50)
			for i := int64(0); i < r.LnksMax; i++ {
				if _, _, rf, _ := b.Start(10+i, buffSpec(r, 2), t0); rf != buff.NotRefused {
					t.Errorf("%s: target %d of %d refused %v", r.BasicCode, i+1, r.LnksMax, rf)
				}
			}
			if rf := b.CheckOverlap(100, buffSpec(r, 2)); rf != buff.RefusedOverlapCount {
				t.Errorf("%s: target %d past lnks value[2]: %v, want RefusedOverlapCount", r.BasicCode, r.LnksMax+1, rf)
			}
			if rf := b.CheckOverlap(10, buffSpec(r, 2)); rf != buff.RefusedOverlap {
				t.Errorf("%s: the same target again: %v, want RefusedOverlap", r.BasicCode, rf)
			}
			linkRows++
		}
		if r.Lnks && !r.TargetRequired {
			open = append(open, r.BasicCode)
		}
	}
	// Pairs sharing a state byte, different groups: the second is refused.
	pairs, refused := 0, 0
	for bt, rs := range byByte {
		for _, a := range rs {
			for _, c := range rs {
				if a.GroupID == c.GroupID || a.GroupID == 0 {
					continue
				}
				pairs++
				b := buff.NewBooks(50)
				if _, _, rf, _ := b.Start(1, buffSpec(a, 1), t0); rf != buff.NotRefused {
					continue
				}
				_, _, rf, _ := b.Start(1, buffSpec(c, 1), t0)
				if rf == buff.RefusedOverlap || rf == buff.RefusedEngage {
					refused++
					continue
				}
				// An 'lnks' row cast on oneself sets no Action_Overlap bits
				// (engageBits, READ), so it cannot block the second.
				if !(c.HasDttp || (c.Lnks && !c.TargetRequired) || a.Lnks) {
					t.Errorf("byte %d: %s then %s both run", bt, a.BasicCode, c.BasicCode)
				}
			}
		}
	}
	var keys []string
	for k := range class {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	t.Logf("%d kind-3 rows of %d; %d of them Target_Required 1 with only hostile groups (not started by OpenSRO)", kind3, len(rows), notStarted)
	for _, k := range keys {
		t.Logf("  %5d  %s", class[k], k)
	}
	t.Logf("state-byte pairs of different groups: %d, refused %d", pairs, refused)
	t.Logf("friendly Target_Required 1 lnks rows driven to their lnks value[2]: %d", linkRows)
	sort.Strings(stacked)
	t.Logf("a same-skill recast leaves two records (%d):", len(stacked))
	for _, s := range dedupeStrip(stacked) {
		t.Logf("  %s", s)
	}
	t.Logf("rows whose gate check is FUN_0059dc80 (linkLocked): %d, e.g. %s", len(open), strings.Join(first(open, 8), ", "))
}

// recastClass names the rule that decides a recast of r against its own
// earlier record, in FUN_0059d870's order.
func recastClass(r *refdata.Skill) string {
	bits := r.ActionOverlap&0xffffff != 0 || r.Ovl2 != 0
	switch {
	case r.Lnks && r.TargetRequired:
		return "lnks, TR 1: FUN_0059dc80 on the caster's book (the target test), then FUN_0059d870 on the target's"
	case r.Lnks && !r.TargetRequired && r.Efr3:
		return "lnks, TR 0, efr 3: FUN_0059dc80 (linkLocked)"
	case r.Lnks && !r.TargetRequired:
		return "lnks, TR 0, no efr 3: no check (READ, 0x58e308)"
	case r.Msch1:
		return "msch 1: the bit test only"
	case r.Cbuf && bits:
		return "cbuf: the list passes it over; the bit test refuses"
	case r.Cbuf:
		return "cbuf, no state byte: nothing stops a recast"
	case r.HasDttp:
		return "dttp branch"
	case r.Efr2 && !r.Offensive:
		return "efr 2 branch (then the bit test)"
	case r.Lks2 && bits:
		return "lks2: the GroupID branch skipped; the bit test"
	case r.Lks2:
		return "lks2, no state byte: nothing stops a recast"
	case r.GroupID != 0:
		return "GroupID branch (other groups: the bit test)"
	case bits:
		return "GroupID 0: the bit test only"
	default:
		return "GroupID 0, no state byte: nothing stops a recast"
	}
}

func dedupeStrip(in []string) []string {
	var out []string
	for i, s := range in {
		if i == 0 || s != in[i-1] {
			out = append(out, s)
		}
	}
	return out
}

func first(in []string, n int) []string {
	if len(in) < n {
		return in
	}
	return in[:n]
}
