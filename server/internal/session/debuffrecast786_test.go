package session

import (
	"testing"
	"time"
)

// forgetR786Passives puts the passive set back as it was before the world
// was built (its learn gave the character the review rows' 'defp', and its
// handler became the set's source), so the package's later stat tests do
// not read them.
func forgetR786Passives(t *testing.T) {
	passives.Lock()
	skills, ref := passives.skills, passives.ref
	passives.Unlock()
	t.Cleanup(func() {
		passives.Lock()
		passives.skills, passives.ref = skills, ref
		passives.m = map[int64]passiveState{}
		passives.Unlock()
	})
}

func TestRound786DebuffRecastReplacesNotStacks(t *testing.T) {
	forgetR786Passives(t)
	w := startReviewSkillWorld(t)
	p := w.spawn(10, 0, 1000000)
	d, ok := skillDeps()
	if !ok {
		w.cast(t, &UseSkillRequest{SkillID: reviewDotLks2, TargetMonsterID: w.spawn(500, 500, 1000000)})
		if d, ok = skillDeps(); !ok {
			t.Fatal("no skill deps")
		}
	}
	defer monsterBooks.EndAll(p)
	row := *reviewRows()[reviewStrikeK3]
	row.ID, row.GroupID, row.BasicCode = 950901, 950901, "SKILL_TEST_CURSE_01"
	row.ParamWords = words(3, run("dura", 5000))
	if !startsMonsterDebuff(&row) {
		t.Fatal("the curse row is not a debuff")
	}
	m, _ := w.monsters.Get(p)
	t0 := time.Now()
	if !startMonsterDebuff(d, &row, w.aria, m, t0) {
		t.Fatal("first cast refused")
	}
	first := monsterBooks.Active(p)
	for i, caster := range []int64{w.aria, 777777} {
		if !startMonsterDebuff(d, &row, caster, m, t0.Add(time.Duration(i+1)*time.Second)) {
			t.Fatalf("recast %d refused", i)
		}
		recs := monsterBooks.Active(p)
		if len(recs) != 1 {
			t.Fatalf("recast %d: the monster holds %d records of the curse; want 1", i, len(recs))
		}
		if recs[0].Token == first[0].Token || !recs[0].Start.After(first[0].Start) {
			t.Fatalf("recast %d did not refresh the record: %+v", i, recs[0])
		}
		first = recs
	}
}

// The retail DOT rows carry Basic_Activity 2 (MEASURED on the export: 259 of
// the 262 serviced Target_Required 'lnks' rows; the link test passes over a
// record whose skill has Activity 0).
func TestRound786LinkedDotIsRefusedWhileItRunsAndLandsAfter(t *testing.T) {
	for _, id := range []int64{r785Dot, reviewDotLks2} {
		forgetR786Passives(t)
		w := startReviewSkillWorld(t)
		p := w.spawn(10, 0, 100000000)
		w.cast(t, &UseSkillRequest{SkillID: reviewStrikeK3, TargetMonsterID: w.spawn(500, 500, 100000000)})
		d, ok := skillDeps()
		if !ok {
			t.Fatal("no skill deps")
		}
		row := *reviewRows()[id]
		row.Activity = 2
		m, _ := w.monsters.Get(p)
		if !startMonsterDebuff(d, &row, w.aria, m, time.Now()) {
			t.Fatalf("%d: first cast refused", id)
		}
		if startMonsterDebuff(d, &row, w.aria, m, time.Now()) {
			t.Fatalf("%d: the same DOT landed twice on one monster while its link runs", id)
		}
		if n := len(monsterBooks.Active(p)); n != 1 {
			t.Fatalf("%d: records %d; want 1", id, n)
		}
		deadline := time.Now().Add(3 * time.Second)
		for len(monsterBooks.Active(p)) != 0 {
			if time.Now().After(deadline) {
				t.Fatalf("%d: the DOT never ended", id)
			}
			time.Sleep(20 * time.Millisecond)
		}
		m, _ = w.monsters.Get(p)
		if !startMonsterDebuff(d, &row, w.aria, m, time.Now()) {
			t.Fatalf("%d: the DOT is refused after its record ended (the caster's link was never freed)", id)
		}
		monsterBooks.EndAll(p)
	}
}
