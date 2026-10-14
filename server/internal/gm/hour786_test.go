package gm

import (
	"context"
	"strings"
	"testing"
)

type fakeClock struct{ set []int }

func (f *fakeClock) SetHour(hour int) (int, int, int, int) {
	f.set = append(f.set, hour)
	return 3, hour, 41, 2
}

// /hour drives the game clock's set-hour (round 786); a bad argument is
// refused without touching the clock, and no clock refuses.
func TestRound786Hour(t *testing.T) {
	ctx := context.Background()
	clock := &fakeClock{}
	d := &Deps{Clock: clock}
	res := d.Run(ctx, Actor{Name: "GM"}, "/hour 18")
	if res.Refused || !strings.Contains(res.Text, "day 3 18:41") || !strings.Contains(res.Text, "2 character") {
		t.Fatalf("/hour 18: %+v", res)
	}
	for _, bad := range []string{"/hour", "/hour 24", "/hour -1", "/hour noon", "/hour 1 2"} {
		if res := d.Run(ctx, Actor{Name: "GM"}, bad); !res.Refused {
			t.Errorf("%q accepted: %+v", bad, res)
		}
	}
	if len(clock.set) != 1 || clock.set[0] != 18 {
		t.Fatalf("the clock was set %v, want [18]", clock.set)
	}
	if res := (&Deps{}).Run(ctx, Actor{Name: "GM"}, "/hour 5"); !res.Refused {
		t.Fatalf("no clock: %+v", res)
	}
	if !strings.Contains(Help, "/hour") {
		t.Fatalf("Help does not list /hour")
	}
}
