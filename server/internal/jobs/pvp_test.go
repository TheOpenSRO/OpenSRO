package jobs

import (
	"testing"
	"time"
)

func TestOpposed(t *testing.T) {
	for _, c := range []struct {
		a, b byte
		want bool
	}{
		{StateTrader, StateThief, true}, {StateThief, StateTrader, true},
		{StateHunter, StateThief, true}, {StateThief, StateHunter, true},
		{StateTrader, StateHunter, false}, {StateThief, StateThief, false},
		{StateTrader, StateNone, false}, {StateNone, StateThief, false},
	} {
		if got := Opposed(c.a, c.b); got != c.want {
			t.Fatalf("Opposed(%d, %d) = %v", c.a, c.b, got)
		}
	}
}

func TestAttackCode(t *testing.T) {
	thief := Fighter{Job: StateThief, Level: 50}
	trader := Fighter{Job: StateTrader, Level: 50}
	hunter := Fighter{Job: StateHunter, Level: 50}
	none := Fighter{Job: StateNone, Level: 50}
	cases := []struct {
		name string
		a, t Fighter
		own  bool
		area bool
		want uint16
	}{
		{"opposed", thief, trader, false, false, 0},
		{"own COS", thief, thief, true, false, ErrWrongTarget},
		{"town", Fighter{Job: StateThief, Level: 50, InTown: true}, trader, false, false, ErrNoBattleField},
		{"party", Fighter{Job: StateThief, Level: 50, PartyID: 7}, Fighter{Job: StateTrader, Level: 50, PartyID: 7}, false, false, ErrPartyMember},
		{"caravan", thief, Fighter{Job: StateTrader, Level: 50, TradeGoods: true, SafeTrade: true, TradeScale: 1}, false, false, ErrCaravanLevel1},
		{"caravan two stars", thief, Fighter{Job: StateTrader, Level: 50, TradeGoods: true, SafeTrade: true, TradeScale: 2}, false, false, 0},
		{"protected trader on a thief", Fighter{Job: StateTrader, Level: 50, TradeGoods: true, SafeTrade: true, TradeScale: 1}, thief, false, false, ErrWrongTarget},
		{"same side", trader, hunter, false, false, ErrWrongTarget},
		{"same side area", trader, hunter, false, true, SilentRefusal},
		{"low attacker", Fighter{Job: StateTrader, Level: 19}, hunter, false, false, ErrYourLevelLow},
		{"low target", trader, Fighter{Job: StateHunter, Level: 19}, false, false, ErrTargetLevelLow},
		{"plain PK", none, trader, false, false, ErrPKProhibited},
		{"opposed area", thief, trader, false, true, 0},
	}
	for _, c := range cases {
		if got := AttackCode(c.a, c.t, c.own, c.area); got != c.want {
			t.Fatalf("%s: 0x%x, want 0x%x", c.name, got, c.want)
		}
	}
}

func TestMonsterRules(t *testing.T) {
	if MonsterAttackCode(StateThief, MobNPCThief) != ErrWrongTarget || MonsterAttackCode(StateThief, MobNPCHunter) != 0 ||
		MonsterAttackCode(StateTrader, MobNPCHunter) != ErrWrongTarget || MonsterAttackCode(StateNone, MobNPCThief) != ErrWrongTarget ||
		MonsterAttackCode(StateNone, 0) != 0 {
		t.Fatal("MonsterAttackCode")
	}
	if !MobMayTarget(MobNPCHunter, StateThief) || MobMayTarget(MobNPCHunter, StateTrader) ||
		!MobMayTarget(MobNPCThief, StateHunter) || MobMayTarget(MobNPCThief, StateNone) || !MobMayTarget(0, StateNone) {
		t.Fatal("MobMayTarget")
	}
	if !JobDeathByMonster(StateTrader, MobNPCThief) || JobDeathByMonster(StateThief, MobNPCThief) ||
		!JobDeathByMonster(StateThief, MobNPCHunter) || JobDeathByMonster(StateNone, MobNPCHunter) {
		t.Fatal("JobDeathByMonster")
	}
	if !JobDeathByPlayer(true, StateThief, StateTrader) || JobDeathByPlayer(false, StateThief, StateTrader) {
		t.Fatal("JobDeathByPlayer")
	}
}

func TestJobDeathAndKillNumbers(t *testing.T) {
	if JobDeathExpLoss(24, 0) != 144 || JobDeathExpLoss(100, 50) != 300 || JobKillCharExp(24) != 72 {
		t.Fatal("exp numbers")
	}
	// Three members of levels 30, 40, 50 (sum 120): a 1000 share at level 40
	// is 1000 x 40/120 x 1.1 = 366.
	if got := PartyJobShare(1000, 40, 120, 3); got != 366 {
		t.Fatalf("party share %d", got)
	}
}

func TestSafeTrade(t *testing.T) {
	var s SafeTrade
	day := time.Date(2026, 10, 20, 15, 0, 0, 0, time.UTC)
	if !s.DailyReset(day, SafeTradeCounted) || s.Count != 0 || s.Last.Hour() != 0 {
		t.Fatalf("first reset %+v", s)
	}
	if s.DailyReset(day.Add(time.Hour), SafeTradeCounted) {
		t.Fatal("the same day reset again")
	}
	if s.Decide(false, 2, SafeTradeCounted, 8) != SafeLost || s.Status {
		t.Fatal("two stars granted")
	}
	if s.Decide(true, 1, SafeTradeCounted, 8) != SafeLost {
		t.Fatal("bargain goods granted")
	}
	if s.Decide(false, 1, SafeTradeCounted, 8) != SafeGranted || !s.Status || s.Count != 1 {
		t.Fatalf("grant %+v", s)
	}
	// Granted again while safe: not counted again.
	if s.Decide(false, 1, SafeTradeCounted, 8) != SafeGranted || s.Count != 1 {
		t.Fatalf("regrant %+v", s)
	}
	s.Status, s.Count = false, 8
	if s.Decide(false, 1, SafeTradeCounted, 8) != SafeLimit || s.Status {
		t.Fatalf("limit %+v", s)
	}
	if s.Decide(false, 1, SafeTradeAlways, 0) != SafeGranted || s.Decide(false, 1, SafeTradeNever, 8) != SafeLost {
		t.Fatal("options")
	}
	if !s.DailyReset(day.AddDate(0, 0, 1), SafeTradeCounted) || s.Count != 0 {
		t.Fatal("a new day")
	}
}
