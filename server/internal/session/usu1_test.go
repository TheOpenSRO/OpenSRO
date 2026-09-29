package session

import (
	"testing"
	"time"
)

// Round 638 review: a composite item's USU1 entry starts its skill's buff on
// the user (GObjPC::FUN_0049f590's USU1 branch -> a type-0 CTJ_SkillKeeper
// job whose start engages the skill and broadcasts 0xB0BD). Synthetic rows
// with the premium's SHAPE (a 3/3/13/4 premium time, a USU1 skill whose
// 'dura' is 2,419,200,000 ms held signed, a BFI1); no retail row is copied.
const (
	testPremium        = 99101
	testPremiumTime    = 99102
	testOnlyUnmodelled = 99103
	testPremiumSkill   = 99201
)

func TestUsu1StartsTheSkillBuff(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	t.Cleanup(func() { buffBooks.EndAll(f.charID) })
	if err := f.inv.AddItem(f.ctx, f.charID, testPremium, 1); err != nil {
		t.Fatal(err)
	}
	if err := f.inv.AddItem(f.ctx, f.charID, testPremium, 1); err != nil {
		t.Fatal(err)
	}
	slot, _ := f.slotOf(testPremium)
	res := f.use(slot)
	if res.Error != "" {
		t.Fatalf("premium: %q, want used (UIU1 3/3/13/4 and BFI1 skipped, USU1 started)", res.Error)
	}
	if p := f.recv(); p.Opcode != OpCompositeState {
		t.Fatalf("after the premium: opcode %#x, want the composite state", p.Opcode)
	}
	var rec *struct {
		skill int64
		dura  time.Duration
	}
	for _, r := range buffBooks.Active(f.charID) {
		if r.SkillID == testPremiumSkill {
			rec = &struct {
				skill int64
				dura  time.Duration
			}{r.SkillID, r.Dura}
		}
	}
	if rec == nil {
		t.Fatalf("no buff of skill %d on the user's book after the USU1 item", testPremiumSkill)
	}
	if rec.dura != 2419200*time.Second {
		t.Errorf("the buff lasts %v, want 2,419,200 s: 'dura' read unsigned / 1000 (0x49fb11)", rec.dura)
	}
	if n := f.countOf(testPremium); n != 1 {
		t.Errorf("premiums left %d, want 1 (one spent)", n)
	}
	// FUN_00411560(0, skill id): the same skill's job still running is 0x1894.
	slot, _ = f.slotOf(testPremium)
	if res := f.use(slot); res.Error != compositeOverlapRefusal {
		t.Errorf("a second premium while its buff runs got %q, want 0x1894's text", res.Error)
	}
	if n := f.countOf(testPremium); n != 1 {
		t.Errorf("the refused premium was spent: %d left", n)
	}
}

// An item none of whose entries srrevamp models is refused and not spent.
func TestCompositeWithNothingModelledIsRefused(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	if err := f.inv.AddItem(f.ctx, f.charID, testOnlyUnmodelled, 1); err != nil {
		t.Fatal(err)
	}
	slot, _ := f.slotOf(testOnlyUnmodelled)
	if res := f.use(slot); res.Error != "that cannot be used" {
		t.Errorf("a BFI1-only item got %q, want refused", res.Error)
	}
	if n := f.countOf(testOnlyUnmodelled); n != 1 {
		t.Errorf("the refused item was spent: %d left", n)
	}
}

func TestUsu1DurationIsUnsigned(t *testing.T) {
	if got := usu1Duration(-1875767296); got != 2419200*time.Second {
		t.Errorf("usu1Duration(-1875767296) = %v, want 28 days", got)
	}
	if got := usu1Duration(604800000); got != 604800*time.Second {
		t.Errorf("usu1Duration(604800000) = %v, want 7 days", got)
	}
}
