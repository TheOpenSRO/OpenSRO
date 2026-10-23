package session

import (
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 712's review, hand-computed from the asm: a three-member exp-share
// party (levels 30/25/20, Chinese, no masteries, within 1000) kills a level-28
// monster whose ExpToGive is 749 (= exp_unit 28), the leader dealing all the
// damage. The engine pays 36/35/39 EXP and the leader 83 SP: the base is the
// monster's ExpToGive for every receiver (finding 2) and the SP lag scale is
// clamped at 1.9 (finding 1).
func TestKillShareReviewThreeMembers(t *testing.T) {
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n" +
		"20,100000000,1,470\n25,100000000,1,629\n28,100000000,1,749\n30,100000000,1,842\n"))
	if err != nil {
		t.Fatal(err)
	}
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })
	ctx := context.Background()
	chars, hub, parties := character.NewMemStore(), world.NewHub(), party.NewHub()
	var ids []int64
	var members []party.Member
	for i, lvl := range []int{30, 25, 20} {
		c, err := chars.Create(ctx, int64(300+i), "rev"+string(rune('a'+i)))
		if err != nil {
			t.Fatal(err)
		}
		chars.SetLeveling(ctx, c.ID, lvl, 0, 0, c.Str, c.Int)
		s := gateway.NewTestSession(uint64(99000 + i))
		hub.Enter(s, c.ID, c.Name, lvl, "jangan", world.Position{X: float64(10 * i)})
		ids = append(ids, c.ID)
		members = append(members, party.Member{Session: s, CharacterID: c.ID, Level: lvl})
	}
	p, err := parties.Form(members[0], members[1], party.FlagExpShare)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parties.Add(p.ID, members[2]); err != nil {
		t.Fatal(err)
	}
	m := combat.Monster{ID: 1, Zone: "jangan", Level: 28, MaxHP: 1535, ExpToGive: 749, HasExpToGive: true}
	d := combatDeps{chars: chars, hub: hub, parties: parties, skills: skill.NewMemStore()}
	paid, err := payKill(ctx, d, m, planKill(hub, parties, m, []combat.Hit{{AttackerID: ids[0], Damage: 1535}}, nil))
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range []int64{36, 35, 39} {
		if got := paid[ids[i]].exp; got != want {
			t.Errorf("member L%d paid %d EXP, want %d", []int{30, 25, 20}[i], got, want)
		}
	}
	if got := paid[ids[0]].sp; got != 83 {
		t.Errorf("the leader paid %d SP, want 83", got)
	}
}

// Without col 79 (an old monsters CSV) the base falls back to KillBase.
func TestKillShareExpToGiveFallback(t *testing.T) {
	r := newShareRig(t, 0)
	m := shareMonster
	m.Level = 51 // the receiver is 50: KillBase takes the unit at 50 (1000)
	paid, err := payKill(r.ctx, r.deps(), m, planKill(r.hub, r.parties, m, []combat.Hit{{AttackerID: r.ids[0], Damage: 100}}, nil))
	if err != nil {
		t.Fatal(err)
	}
	// 1000 x Diff f32(1 + 4*0.03) = 1.12 -> 1120.
	if got := paid[r.ids[0]].exp; got != 1120 {
		t.Fatalf("fallback paid %d, want 1120", got)
	}
	m.ExpToGive, m.HasExpToGive = 1100, true
	paid, err = payKill(r.ctx, r.deps(), m, planKill(r.hub, r.parties, m, []combat.Hit{{AttackerID: r.ids[0], Damage: 100}}, nil))
	if err != nil {
		t.Fatal(err)
	}
	// The monster's own 1100 x 1.12 = 1232.
	if got := paid[r.ids[0]].exp; got != 1232 {
		t.Fatalf("ExpToGive paid %d, want 1232", got)
	}
}

// The leveling lock (finding 3): fifty awards for one member from fifty
// goroutines lose none.
func TestKillShareNoLostUpdate(t *testing.T) {
	r := newShareRig(t, 0)
	a := killAward{characterID: r.ids[0], damage: 100, multiplier: 1}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := payAward(r.ctx, r.deps(), shareMonster, a); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if got := r.exp(t, r.ids[0]); got != 50*1090 {
		t.Fatalf("after 50 concurrent awards the row holds %d, want %d", got, 50*1090)
	}
}

// 0x3068 reaches every member but the recipient (finding 5).
func TestItemNoticeSkipsTheRecipient(t *testing.T) {
	w := newPartyWorld(t)
	w.form(t, "Aria", "Bram", party.FlagExpShare|party.FlagItemShare)
	p, ok := w.parties.Get(w.ids["Aria"])
	if !ok {
		t.Fatal("no party")
	}
	sendItemNotice(w.hub, p, w.ids["Aria"], party.ItemNotice{RecipientJID: w.jid("Aria"), RefItemID: 62, Class: party.ItemNoticeExpendable, Amount: 5})
	got := w.c["Bram"].next(party.OpItemNotice)
	n, err := party.DecodeItemNotice(got.Data, party.ItemNoticeExpendable)
	if err != nil || n.RecipientJID != w.jid("Aria") || n.Amount != 5 {
		t.Fatalf("Bram's notice %+v %v", n, err)
	}
	w.c["Aria"].none(party.OpItemNotice)
}
