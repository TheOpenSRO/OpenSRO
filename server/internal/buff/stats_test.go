package buff

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/skillparam"
)

func runsOf(codes ...[]int32) skillparam.Runs {
	var w []int32
	for _, c := range codes {
		w = append(w, c...)
	}
	return skillparam.WalkRuns(w)
}

func code(c string, v ...int32) []int32 {
	return append([]int32{skillparam.WordOf(skillparam.Code(c))}, v...)
}

// TestStatContributions pins the corrected join (READ, ApplySkillParamsToChar
// 0x594ac0): 'hr' writes p11 only, 'defp' p5/p6 flat, 'cr' only on a
// passive, 'odar' a multiplier on 174..177 by mask.
func TestStatContributions(t *testing.T) {
	cs := StatContributions(runsOf(code("hr", 20, 10), code("defp", 50, 30, 0), code("cr", 5, 0)), 3, 2)
	want := map[int]bool{ParamHitRate: true, ParamPhysDefFlat: true, ParamMagDefFlat: true}
	for _, c := range cs {
		if !want[c.Param] {
			t.Fatalf("unexpected write %+v", c)
		}
	}
	if cs := StatContributions(runsOf(code("cr", 5, 0)), 0, 0); len(cs) != 1 || cs[0].Param != ParamCritical {
		t.Fatalf("passive 'cr': %+v", cs)
	}
	cs = StatContributions(runsOf(code("odar", 5, 20)), 3, 2) // mask 4|1: physical, axis 1
	if len(cs) != 1 || cs[0].Param != ParamDefenderMult || cs[0].Slot != skillparam.SlotMult || cs[0].Value != -20 {
		t.Fatalf("odar %+v", cs)
	}
}

// TestParamTotals: EvaluateParam's (base + flat)(1 + pct/100) x mult.
func TestParamTotals(t *testing.T) {
	b := NewBooks(50)
	now := time.Now()
	b.Start(1, Spec{SkillID: 10, CasterID: 1, DuraMs: 60000, Stats: StatContributions(runsOf(code("defp", 100, 0, 0), code("defr", 10, 0)), 3, 2)}, now)
	tot := b.ParamTotals(1)[ParamPhysDefFlat]
	if got := tot.Apply(200); got != 330 {
		t.Fatalf("(200 + 100) x 1.1 = %v", got)
	}
	b.EndAll(1)
	if len(b.ParamTotals(1)) != 0 {
		t.Fatal("an ended buff still counts")
	}
}
