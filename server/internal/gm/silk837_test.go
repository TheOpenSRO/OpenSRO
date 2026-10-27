package gm

import (
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
)

// Round 837: /silk moves one of the GM's account's balances (own by default),
// floored at 0, and hands the session layer the 0x3154 it sends: reason 2 for
// an addition, 1 for a subtraction, the cash type of the balance, the amount
// that actually moved.
func TestSilkCommand(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/silk 10"); !res.Refused || !strings.Contains(res.Text, "no silk store") {
		t.Fatalf("no store: %+v", res)
	}
	accts := account.NewMemStore()
	a, _ := accts.Add("gm", "pw")
	f.deps.Silk = accts
	f.actor.AccountID = a.ID
	for _, bad := range []string{"/silk", "/silk x", "/silk 5 beta", "/silk 1 own extra"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q: %+v", bad, res)
		}
	}
	res := f.run(t, "/silk 1000")
	if res.Refused || res.Silk == nil || *res.Silk != (SilkChange{Reason: 2, CashType: 0, Offset: 1000, After: account.Silk{Own: 1000}}) {
		t.Fatalf("/silk 1000: %+v %+v", res, res.Silk)
	}
	res = f.run(t, "/silk 300 gift")
	if res.Silk == nil || res.Silk.CashType != 1 || res.Silk.After != (account.Silk{Own: 1000, Gift: 300}) {
		t.Fatalf("/silk 300 gift: %+v", res.Silk)
	}
	res = f.run(t, "/silk 40 point")
	if res.Silk == nil || res.Silk.CashType != 2 || res.Silk.After.Point != 40 {
		t.Fatalf("/silk 40 point: %+v", res.Silk)
	}
	res = f.run(t, "/silk -5000")
	if res.Silk == nil || *res.Silk != (SilkChange{Reason: 1, Offset: 1000, After: account.Silk{Gift: 300, Point: 40}}) {
		t.Fatalf("/silk -5000: %+v", res.Silk)
	}
}
